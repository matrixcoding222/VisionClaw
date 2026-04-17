import Foundation
import AVFoundation
import Speech
import SwiftUI

enum OpenClawConnectionState: Equatable {
  case notConfigured
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class OpenClawBridge: ObservableObject {
  @Published var lastToolCallStatus: ToolCallStatus = .idle
  @Published var connectionState: OpenClawConnectionState = .notConfigured

  private let session: URLSession
  private let pingSession: URLSession
  private var sessionKey: String
  private var conversationHistory: [[String: String]] = []
  private let maxHistoryTurns = 10

  private static let stableSessionKey = "agent:main:glass"

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)

    self.sessionKey = OpenClawBridge.stableSessionKey
  }

  func checkConnection() async {
    guard GeminiConfig.isOpenClawConfigured else {
      connectionState = .notConfigured
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")
    do {
      let (_, response) = try await pingSession.data(for: request)
      if let http = response as? HTTPURLResponse, (200...499).contains(http.statusCode) {
        connectionState = .connected
        NSLog("[OpenClaw] Gateway reachable (HTTP %d)", http.statusCode)
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[OpenClaw] Gateway unreachable: %@", error.localizedDescription)
    }
  }

  func resetSession() {
    conversationHistory = []
    NSLog("[OpenClaw] Session reset (key retained: %@)", sessionKey)
  }

  // MARK: - Agent Chat (session continuity via x-openclaw-session-key header)

  func delegateTask(
    task: String,
    toolName: String = "execute"
  ) async -> ToolResult {
    lastToolCallStatus = .executing(toolName)

    guard let url = URL(string: "\(GeminiConfig.openClawHost):\(GeminiConfig.openClawPort)/v1/chat/completions") else {
      lastToolCallStatus = .failed(toolName, "Invalid URL")
      return .failure("Invalid gateway URL")
    }

    // Append the new user message to conversation history
    conversationHistory.append(["role": "user", "content": task])

    // Trim history to keep only the most recent turns (user+assistant pairs)
    if conversationHistory.count > maxHistoryTurns * 2 {
      conversationHistory = Array(conversationHistory.suffix(maxHistoryTurns * 2))
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("Bearer \(GeminiConfig.openClawGatewayToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue(sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    request.setValue("glass", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": conversationHistory,
      "stream": false
    ]

    NSLog("[OpenClaw] Sending %d messages in conversation", conversationHistory.count)

    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: body)
      let (data, response) = try await session.data(for: request)
      let httpResponse = response as? HTTPURLResponse

      guard let statusCode = httpResponse?.statusCode, (200...299).contains(statusCode) else {
        let code = httpResponse?.statusCode ?? 0
        let bodyStr = String(data: data, encoding: .utf8) ?? "no body"
        NSLog("[OpenClaw] Chat failed: HTTP %d - %@", code, String(bodyStr.prefix(200)))
        lastToolCallStatus = .failed(toolName, "HTTP \(code)")
        return .failure("Agent returned HTTP \(code)")
      }

      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let choices = json["choices"] as? [[String: Any]],
         let first = choices.first,
         let message = first["message"] as? [String: Any],
         let content = message["content"] as? String {
        // Append assistant response to history for continuity
        conversationHistory.append(["role": "assistant", "content": content])
        NSLog("[OpenClaw] Agent result: %@", String(content.prefix(200)))
        lastToolCallStatus = .completed(toolName)
        return .success(content)
      }

      let raw = String(data: data, encoding: .utf8) ?? "OK"
      conversationHistory.append(["role": "assistant", "content": raw])
      NSLog("[OpenClaw] Agent raw: %@", String(raw.prefix(200)))
      lastToolCallStatus = .completed(toolName)
      return .success(raw)
    } catch {
      NSLog("[OpenClaw] Agent error: %@", error.localizedDescription)
      lastToolCallStatus = .failed(toolName, error.localizedDescription)
      return .failure("Agent error: \(error.localizedDescription)")
    }
  }
}


// MARK: - Direct JARVIS (bypasses Gemini)
// Pipeline: iOS STT -> OpenClaw bridge -> Cartesia TTS -> AVAudioEngine

enum DirectJarvisConfig {
  // All traffic goes to port 443 behind Tailscale Serve with path-based routing.
  static let bridgeURL = "https://jarvis-prime.tail89fc92.ts.net/bridge/v1/chat/completions"
  static let bridgeToken = "C0ah61_XpQP2a3sziw6cNWr-ZoIGBbUDAadQJPdnhfs"
  // HTTP streaming TTS — bridge proxies to Cartesia HTTP and chunks PCM back.
  // (iOS URLSession WebSocket was unreliable on Tailscale Serve.)
  static let ttsURL = "https://jarvis-prime.tail89fc92.ts.net/bridge/v1/tts/synth"
  static let sessionKey = "agent:main:direct-jarvis"
}

// MARK: Audio session helper
enum DJAudio {
  static func activate() throws {
    let s = AVAudioSession.sharedInstance()
    try s.setCategory(.playAndRecord,
                      mode: .spokenAudio,
                      options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
    try s.setActive(true, options: .notifyOthersOnDeactivation)
  }

  static func deactivate() {
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}

// MARK: TTS HTTP Streaming Client
// Replaces the WebSocket-based client. We POST to the bridge with JSON {"text"}
// and receive a chunked HTTP response of raw PCM s16le 24kHz mono.
// iOS URLSession streams the body via URLSessionDataDelegate callbacks.
final class TTSStreamClient: NSObject, URLSessionDataDelegate {
  private var session: URLSession!
  private var task: URLSessionDataTask?

  var onPCM: ((Data) -> Void)?
  var onDone: (() -> Void)?
  var onError: ((String) -> Void)?
  var onOpen: (() -> Void)?

  override init() {
    super.init()
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    cfg.timeoutIntervalForResource = 120
    self.session = URLSession(configuration: cfg, delegate: self, delegateQueue: .main)
  }

  // Idempotent; HTTP is request/response so "connect" just signals readiness.
  func connect() {
    onOpen?()
  }

  func speak(_ text: String) {
    guard let url = URL(string: DirectJarvisConfig.ttsURL) else {
      onError?("Invalid TTS URL")
      return
    }
    task?.cancel()
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.setValue("Bearer \(DirectJarvisConfig.bridgeToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
    let body: [String: Any] = ["text": text]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)
    NSLog("[DJ] TTS POST: %@", String(text.prefix(80)))
    task = session.dataTask(with: req)
    task?.resume()
  }

  func close() {
    task?.cancel()
    task = nil
  }

  // MARK: URLSessionDataDelegate
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    onPCM?(data)
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error = error {
      let nsErr = error as NSError
      // Ignore cancels from us
      if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled { return }
      NSLog("[DJ] TTS stream error: %@", error.localizedDescription)
      onError?("\(nsErr.domain) #\(nsErr.code): \(error.localizedDescription)")
    } else {
      onDone?()
    }
  }

  // Observe HTTP response so we can surface non-200 errors cleanly.
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                  didReceive response: URLResponse,
                  completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
      onError?("HTTP \(http.statusCode)")
      completionHandler(.cancel)
      return
    }
    completionHandler(.allow)
  }
}

// MARK: Shared audio engine (mic in + player out)
@MainActor
final class DJAudioEngine {
  let engine = AVAudioEngine()
  let player = AVAudioPlayerNode()
  private(set) var isStarted = false

  init() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: nil)
  }

  func start() throws {
    guard !isStarted else { return }
    engine.prepare()
    try engine.start()
    player.play()
    isStarted = true
    NSLog("[DJ] audio engine started")
  }

  func append(pcm: Data, sampleRate: Double = 24000) {
    guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: sampleRate, channels: 1,
                                     interleaved: true) else { return }
    let frames = UInt32(pcm.count / 2)
    guard frames > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
    buf.frameLength = frames
    pcm.withUnsafeBytes { raw in
      guard let src = raw.bindMemory(to: Int16.self).baseAddress,
            let dst = buf.int16ChannelData?[0] else { return }
      for i in 0..<Int(frames) { dst[i] = src[i] }
    }
    player.scheduleBuffer(buf, at: nil, options: [], completionHandler: nil)
  }

  func stop() {
    if isStarted {
      player.stop()
      engine.stop()
      isStarted = false
      NSLog("[DJ] audio engine stopped")
    }
  }

  func installInputTap(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) -> Bool {
    let inputNode = engine.inputNode
    let fmt = inputNode.outputFormat(forBus: 0)
    guard fmt.sampleRate > 0 else {
      NSLog("[DJ] input format invalid: %@", fmt)
      return false
    }
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { buffer, _ in
      onBuffer(buffer)
    }
    NSLog("[DJ] input tap installed at %.0fHz", fmt.sampleRate)
    return true
  }

  func removeInputTap() {
    engine.inputNode.removeTap(onBus: 0)
  }
}

// MARK: Speech Recognizer
final class LiveSpeechRecognizer: NSObject {
  private let recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  var onPartial: ((String) -> Void)?
  var onFinal: ((String) -> Void)?
  var onError: ((String) -> Void)?

  override init() {
    // Prefer en-AU, fall back to device default if unavailable
    self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
      ?? SFSpeechRecognizer()
    super.init()
  }

  func requestAuth(_ done: @escaping (Bool, String?) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else {
        done(false, "speech auth: \(status.rawValue)")
        return
      }
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        done(granted, granted ? nil : "mic denied")
      }
    }
  }

  // Returns (true, nil) on success; (false, reason) on failure
  func begin() -> (Bool, String?) {
    guard let recognizer = recognizer else { return (false, "no recognizer") }
    guard recognizer.isAvailable else { return (false, "recognizer unavailable") }
    end()
    let req = SFSpeechAudioBufferRecognitionRequest()
    req.shouldReportPartialResults = true
    // NOT forcing on-device — falls back to Apple's cloud STT which is more reliable
    self.request = req
    self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      guard let self = self else { return }
      if let result = result {
        let text = result.bestTranscription.formattedString
        if result.isFinal {
          self.onFinal?(text)
        } else {
          self.onPartial?(text)
        }
      }
      if let error = error {
        let nsErr = error as NSError
        // 1110 = no speech; 216/301 = canceled
        if nsErr.code != 1110 && nsErr.code != 216 && nsErr.code != 301 {
          NSLog("[DJ] STT err %d: %@", nsErr.code, error.localizedDescription)
          self.onError?(error.localizedDescription)
        }
      }
    }
    NSLog("[DJ] STT session started")
    return (true, nil)
  }

  func feed(_ buffer: AVAudioPCMBuffer) {
    request?.append(buffer)
  }

  func end() {
    request?.endAudio()
    task?.cancel()
    request = nil
    task = nil
  }
}

// MARK: Orchestrator
@MainActor
final class DirectJarvisService: ObservableObject {
  @Published var status: String = "idle"
  @Published var userText: String = ""
  @Published var jarvisText: String = ""
  @Published var isActive: Bool = false

  private let audio = DJAudioEngine()
  private let recognizer = LiveSpeechRecognizer()
  private let tts = TTSStreamClient()
  private var history: [[String: String]] = []
  private var lastFinalAt: Date = .distantPast

  func start() {
    NSLog("[DJ] start()")
    status = "requesting permissions"
    recognizer.requestAuth { [weak self] ok, err in
      Task { @MainActor in
        guard let self = self else { return }
        guard ok else { self.status = err ?? "permission denied"; return }
        self.boot()
      }
    }
  }

  private func boot() {
    NSLog("[DJ] boot()")
    status = "starting audio"
    do {
      try DJAudio.activate()
    } catch {
      status = "audio session: \(error.localizedDescription)"
      NSLog("[DJ] audio session failed: %@", error.localizedDescription)
      return
    }

    do {
      try audio.start()
    } catch {
      status = "engine: \(error.localizedDescription)"
      NSLog("[DJ] audio engine start failed: %@", error.localizedDescription)
      return
    }

    tts.onPCM = { [weak self] data in
      Task { @MainActor in self?.audio.append(pcm: data) }
    }
    tts.onDone = { [weak self] in
      Task { @MainActor in
        self?.status = "listening"
        self?.startListening()
      }
    }
    tts.onError = { [weak self] e in
      Task { @MainActor in self?.status = "tts: \(e)" }
    }
    tts.connect()

    recognizer.onPartial = { [weak self] text in
      Task { @MainActor in self?.userText = text }
    }
    recognizer.onFinal = { [weak self] text in
      Task { @MainActor in
        guard let self = self else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
          self.startListening()
          return
        }
        if Date().timeIntervalSince(self.lastFinalAt) < 0.5 { return }
        self.lastFinalAt = Date()
        self.userText = trimmed
        self.stopListening()
        await self.ask(trimmed)
      }
    }
    recognizer.onError = { [weak self] e in
      Task { @MainActor in self?.status = "stt: \(e)" }
    }

    isActive = true
    startListening()
  }

  private func startListening() {
    status = "listening"
    let (ok, reason) = recognizer.begin()
    guard ok else {
      status = "stt begin: \(reason ?? "?")"
      return
    }
    let tapOk = audio.installInputTap { [weak self] buffer in
      self?.recognizer.feed(buffer)
    }
    if !tapOk {
      status = "input tap failed"
    }
  }

  private func stopListening() {
    audio.removeInputTap()
    recognizer.end()
  }

  private func ask(_ text: String) async {
    status = "thinking"
    NSLog("[DJ] ask: %@", text)
    history.append(["role": "user", "content": text])
    if history.count > 20 { history = Array(history.suffix(20)) }

    guard let url = URL(string: DirectJarvisConfig.bridgeURL) else {
      status = "bad bridge URL"; return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue("Bearer \(DirectJarvisConfig.bridgeToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(DirectJarvisConfig.sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    req.setValue("phone-direct", forHTTPHeaderField: "x-openclaw-message-channel")
    let body: [String: Any] = ["model": "openclaw", "messages": history, "stream": false]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse else {
        status = "no http response"; startListening(); return
      }
      guard (200...299).contains(http.statusCode) else {
        let bodyStr = String(data: data, encoding: .utf8) ?? ""
        NSLog("[DJ] bridge HTTP %d: %@", http.statusCode, String(bodyStr.prefix(200)))
        status = "bridge \(http.statusCode)"; startListening(); return
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let msg = first["message"] as? [String: Any],
            let content = msg["content"] as? String, !content.isEmpty else {
        let preview = String(data: data, encoding: .utf8).map { String($0.prefix(300)) } ?? "(binary)"
        NSLog("[DJ] bridge parse fail: %@", preview)
        status = "parse fail"; startListening(); return
      }
      history.append(["role": "assistant", "content": content])
      jarvisText = content
      status = "speaking"
      tts.speak(content)
    } catch {
      NSLog("[DJ] bridge error: %@", error.localizedDescription)
      status = "net: \(error.localizedDescription)"
      startListening()
    }
  }

  func stop() {
    NSLog("[DJ] stop()")
    isActive = false
    stopListening()
    tts.close()
    audio.stop()
    DJAudio.deactivate()
    status = "idle"
  }
}

// MARK: UI
struct DirectJarvisView: View {
  @StateObject private var service = DirectJarvisService()
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    ZStack {
      Color.black.ignoresSafeArea()
      VStack(spacing: 24) {
        HStack {
          Button(action: { service.stop(); dismiss() }) {
            Image(systemName: "xmark")
              .foregroundColor(.white)
              .padding(8)
          }
          Spacer()
          Text(service.status)
            .foregroundColor(.green)
            .font(.caption.monospaced())
            .lineLimit(2)
        }
        .padding()

        Spacer()

        Text("JARVIS")
          .font(.system(size: 48, weight: .thin, design: .monospaced))
          .foregroundColor(.white)
          .padding(.bottom, 40)

        VStack(spacing: 20) {
          if !service.userText.isEmpty {
            Text(service.userText)
              .foregroundColor(.gray)
              .italic()
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
          if !service.jarvisText.isEmpty {
            Text(service.jarvisText)
              .foregroundColor(.white)
              .font(.title3)
              .multilineTextAlignment(.center)
              .padding(.horizontal)
          }
        }

        Spacer()

        // Status orb (visual only, no button press required — matches VisionClaw continuous mode)
        ZStack {
          Circle()
            .fill(orbColor)
            .frame(width: 120, height: 120)
            .shadow(color: orbColor.opacity(0.5), radius: 20)
          Image(systemName: orbIcon)
            .font(.system(size: 44))
            .foregroundColor(.white)
        }
        .padding(.bottom, 60)
      }
    }
    .onAppear { service.start() }
    .onDisappear { service.stop() }
  }

  private var orbColor: Color {
    switch service.status {
    case let s where s.starts(with: "listening"): return .blue
    case let s where s.starts(with: "thinking"): return .yellow
    case let s where s.starts(with: "speaking"): return .green
    case let s where s.starts(with: "idle"): return .gray
    default: return .red
    }
  }

  private var orbIcon: String {
    switch service.status {
    case let s where s.starts(with: "listening"): return "waveform"
    case let s where s.starts(with: "thinking"): return "ellipsis"
    case let s where s.starts(with: "speaking"): return "speaker.wave.2.fill"
    case let s where s.starts(with: "idle"): return "power"
    default: return "exclamationmark.triangle"
    }
  }
}
