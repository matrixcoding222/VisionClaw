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
// Pipeline: iOS on-device STT -> OpenClaw bridge -> Cartesia TTS WebSocket -> AVAudioEngine playback

enum DirectJarvisConfig {
  // Tailscale-served endpoints on the VPS
  static let bridgeURL = "https://jarvis-prime.tail89fc92.ts.net:9443/v1/chat/completions"
  static let bridgeToken = "C0ah61_XpQP2a3sziw6cNWr-ZoIGBbUDAadQJPdnhfs"
  static let ttsURL = "wss://jarvis-prime.tail89fc92.ts.net:8443/v1/tts/stream"
  static let ttsToken = "hYZB5CC9FFAdMNpABbEhSWfjjE4ilfti"
  static let sessionKey = "agent:main:direct-jarvis"
}

// MARK: PCM Player (24kHz s16le mono)
final class PCMPlayer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private let format = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                     sampleRate: 24000, channels: 1, interleaved: true)!

  init() {
    engine.attach(player)
    engine.connect(player, to: engine.mainMixerNode, format: format)
  }

  func start() {
    do {
      try engine.start()
      player.play()
    } catch {
      NSLog("[PCM] start failed: %@", error.localizedDescription)
    }
  }

  func append(_ pcm: Data) {
    let frames = UInt32(pcm.count / 2)
    guard frames > 0,
          let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return }
    buf.frameLength = frames
    pcm.withUnsafeBytes { raw in
      let src = raw.bindMemory(to: Int16.self).baseAddress!
      let dst = buf.int16ChannelData![0]
      for i in 0..<Int(frames) { dst[i] = src[i] }
    }
    player.scheduleBuffer(buf, completionHandler: nil)
  }

  func stop() {
    player.stop()
    engine.stop()
  }
}

// MARK: TTS WebSocket Client
final class TTSStreamClient: NSObject {
  private let session: URLSession
  private var task: URLSessionWebSocketTask?

  var onPCM: ((Data) -> Void)?
  var onDone: (() -> Void)?
  var onError: ((String) -> Void)?

  override init() {
    let cfg = URLSessionConfiguration.default
    cfg.timeoutIntervalForRequest = 30
    self.session = URLSession(configuration: cfg)
    super.init()
  }

  func connect() {
    let urlStr = "\(DirectJarvisConfig.ttsURL)?token=\(DirectJarvisConfig.ttsToken)"
    guard let url = URL(string: urlStr) else {
      onError?("Invalid TTS URL")
      return
    }
    task = session.webSocketTask(with: url)
    task?.resume()
    receive()
  }

  func speak(_ text: String) {
    let escaped = text
      .replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: " ")
    let msg = URLSessionWebSocketTask.Message.string("{\"text\":\"\(escaped)\"}")
    task?.send(msg) { [weak self] err in
      if let err = err { self?.onError?("send: \(err.localizedDescription)") }
    }
  }

  private func receive() {
    task?.receive { [weak self] result in
      guard let self = self else { return }
      switch result {
      case .success(let message):
        switch message {
        case .data(let d):
          self.onPCM?(d)
        case .string(let s):
          if s.contains("\"done\":true") { self.onDone?() }
        @unknown default:
          break
        }
        self.receive()
      case .failure(let err):
        self.onError?("ws: \(err.localizedDescription)")
      }
    }
  }

  func close() {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
  }
}

// MARK: Live Speech Recognizer (iOS on-device)
final class LiveSpeechRecognizer: NSObject {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-AU"))
  private let audioEngine = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?

  var onPartial: ((String) -> Void)?
  var onFinal: ((String) -> Void)?
  var onError: ((String) -> Void)?

  func requestAuth(_ done: @escaping (Bool) -> Void) {
    SFSpeechRecognizer.requestAuthorization { status in
      guard status == .authorized else { done(false); return }
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        done(granted)
      }
    }
  }

  func start() {
    guard let recognizer = recognizer, recognizer.isAvailable else {
      onError?("Speech recognizer unavailable")
      return
    }
    stop()
    request = SFSpeechAudioBufferRecognitionRequest()
    request?.shouldReportPartialResults = true
    if #available(iOS 13.0, *) {
      request?.requiresOnDeviceRecognition = true
    }

    let inputNode = audioEngine.inputNode
    let fmt = inputNode.outputFormat(forBus: 0)
    inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
      self?.request?.append(buffer)
    }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .voiceChat,
                              options: [.defaultToSpeaker, .allowBluetooth])
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      audioEngine.prepare()
      try audioEngine.start()
    } catch {
      onError?("audio: \(error.localizedDescription)")
      return
    }

    task = recognizer.recognitionTask(with: request!) { [weak self] result, error in
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
        // Code 1110 = no speech detected, 216 = canceled — not real errors
        if nsErr.code != 1110 && nsErr.code != 216 {
          self.onError?(error.localizedDescription)
        }
      }
    }
  }

  func stop() {
    if audioEngine.isRunning {
      audioEngine.stop()
      audioEngine.inputNode.removeTap(onBus: 0)
    }
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

  private let recognizer = LiveSpeechRecognizer()
  private let tts = TTSStreamClient()
  private let player = PCMPlayer()
  private var history: [[String: String]] = []
  private var lastFinalAt: Date = .distantPast

  func start() {
    recognizer.requestAuth { [weak self] ok in
      Task { @MainActor in
        guard let self = self else { return }
        guard ok else { self.status = "permission denied"; return }
        self.boot()
      }
    }
  }

  private func boot() {
    isActive = true
    status = "connecting"
    player.start()

    tts.onPCM = { [weak self] data in
      Task { @MainActor in self?.player.append(data) }
    }
    tts.onDone = { [weak self] in
      Task { @MainActor in
        self?.status = "listening"
        self?.recognizer.start()
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
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
          self.recognizer.start()
          return
        }
        // Debounce: ignore finals within 500ms
        if Date().timeIntervalSince(self.lastFinalAt) < 0.5 { return }
        self.lastFinalAt = Date()
        self.userText = text
        self.recognizer.stop()
        await self.ask(text)
      }
    }
    recognizer.onError = { [weak self] e in
      Task { @MainActor in self?.status = "stt: \(e)" }
    }
    status = "listening"
    recognizer.start()
  }

  private func ask(_ text: String) async {
    status = "thinking"
    history.append(["role": "user", "content": text])
    if history.count > 20 {
      history = Array(history.suffix(20))
    }

    guard let url = URL(string: DirectJarvisConfig.bridgeURL) else {
      status = "bad url"; return
    }
    var req = URLRequest(url: url)
    req.httpMethod = "POST"
    req.timeoutInterval = 120
    req.setValue("Bearer \(DirectJarvisConfig.bridgeToken)", forHTTPHeaderField: "Authorization")
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue(DirectJarvisConfig.sessionKey, forHTTPHeaderField: "x-openclaw-session-key")
    req.setValue("phone-direct", forHTTPHeaderField: "x-openclaw-message-channel")

    let body: [String: Any] = [
      "model": "openclaw",
      "messages": history,
      "stream": false
    ]
    req.httpBody = try? JSONSerialization.data(withJSONObject: body)

    do {
      let (data, response) = try await URLSession.shared.data(for: req)
      guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        status = "bridge HTTP \(code)"
        recognizer.start()
        return
      }
      guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let first = choices.first,
            let msg = first["message"] as? [String: Any],
            let content = msg["content"] as? String, !content.isEmpty else {
        status = "parse fail"
        recognizer.start()
        return
      }
      history.append(["role": "assistant", "content": content])
      jarvisText = content
      status = "speaking"
      tts.speak(content)
    } catch {
      status = "net: \(error.localizedDescription)"
      recognizer.start()
    }
  }

  func stop() {
    isActive = false
    recognizer.stop()
    tts.close()
    player.stop()
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

        Button(action: {
          if service.isActive { service.stop() } else { service.start() }
        }) {
          Image(systemName: service.isActive ? "stop.circle.fill" : "mic.circle.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 100, height: 100)
            .foregroundColor(service.isActive ? .red : .blue)
        }
        .padding(.bottom, 60)
      }
    }
  }
}
