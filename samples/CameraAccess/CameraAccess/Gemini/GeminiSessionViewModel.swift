import Foundation
import SwiftUI

@MainActor
class GeminiSessionViewModel: ObservableObject {
  @Published var isGeminiActive: Bool = false
  @Published var connectionState: GeminiConnectionState = .disconnected
  @Published var isModelSpeaking: Bool = false
  @Published var errorMessage: String?
  @Published var userTranscript: String = ""
  @Published var aiTranscript: String = ""
  @Published var toolCallStatus: ToolCallStatus = .idle
  @Published var openClawConnectionState: OpenClawConnectionState = .notConfigured
  // TTS diagnostic surface — shown on overlay so we can see what's actually happening
  @Published var ttsDebug: String = "tts: idle"
  private let geminiService = GeminiLiveService()
  private let openClawBridge = OpenClawBridge()
  private var toolCallRouter: ToolCallRouter?
  private let audioManager = AudioManager()
  private let eventClient = OpenClawEventClient()
  private let tts = TTSStreamClient()
  private var lastVideoFrameTime: Date = .distantPast
  private var stateObservation: Task<Void, Never>?
  // Text buffered across a Gemini turn; flushed to Cartesia TTS on turnComplete
  private var turnTextBuffer: String = ""
  private var ttsPCMBytesReceived: Int = 0

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }

    guard GeminiConfig.isConfigured else {
      errorMessage = "Gemini API key not configured."
      return
    }

    isGeminiActive = true

    audioManager.onAudioCaptured = { [weak self] data in
      guard let self else { return }
      Task { @MainActor in
        let speakerOnPhone = self.streamingMode == .iPhone || SettingsManager.shared.speakerOutputEnabled
        if speakerOnPhone && self.geminiService.isModelSpeaking { return }
        self.geminiService.sendAudio(data: data)
      }
    }

    // Gemini is AUDIO modality (TEXT is rejected by 3.x Live models). We drop its
    // audio and use outputAudioTranscription text → Cartesia TTS for JARVIS voice.
    geminiService.onAudioReceived = { _ in
      // intentionally discard Gemini's audio output
    }

    geminiService.onInterrupted = { [weak self] in
      self?.audioManager.stopPlayback()
      self?.turnTextBuffer = ""
    }

    geminiService.onTurnComplete = { [weak self] in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript = ""
        let text = self.turnTextBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        self.turnTextBuffer = ""
        if !text.isEmpty {
          self.ttsPCMBytesReceived = 0
          self.ttsDebug = "tts: speak \(text.count)ch"
          NSLog("[TTS] flushing turn (%d chars): %@", text.count, String(text.prefix(120)))
          self.geminiService.markModelSpeakingStarted()
          self.tts.speak(text)
        } else {
          self.ttsDebug = "tts: no text to speak"
        }
      }
    }

    geminiService.onInputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.userTranscript += text
        self.aiTranscript = ""
      }
    }

    geminiService.onOutputTranscription = { [weak self] text in
      guard let self else { return }
      Task { @MainActor in
        self.aiTranscript += text
        self.turnTextBuffer += text
      }
    }

    // Wire Cartesia TTS — force main-queue playback and surface status to UI.
    tts.onOpen = { [weak self] in
      Task { @MainActor in self?.ttsDebug = "tts: open" }
      NSLog("[TTS] ws OPEN")
    }
    tts.onPCM = { [weak self] data in
      Task { @MainActor in
        guard let self else { return }
        self.ttsPCMBytesReceived += data.count
        self.ttsDebug = "tts: playing (\(self.ttsPCMBytesReceived)b)"
        self.audioManager.playAudio(data: data)
      }
    }
    tts.onDone = { [weak self] in
      Task { @MainActor in
        self?.ttsDebug = "tts: done"
        self?.geminiService.markModelSpeakingFinished()
      }
    }
    tts.onError = { [weak self] e in
      Task { @MainActor in self?.ttsDebug = "tts err: \(e.prefix(40))" }
      NSLog("[TTS] err: %@", e)
    }
    tts.connect()
    ttsDebug = "tts: connecting"

    geminiService.onDisconnected = { [weak self] reason in
      guard let self else { return }
      Task { @MainActor in
        guard self.isGeminiActive else { return }
        self.stopSession()
        self.errorMessage = "Connection lost: \(reason ?? "Unknown error")"
      }
    }

    await openClawBridge.checkConnection()
    openClawBridge.resetSession()

    toolCallRouter = ToolCallRouter(bridge: openClawBridge)

    geminiService.onToolCall = { [weak self] toolCall in
      guard let self else { return }
      Task { @MainActor in
        for call in toolCall.functionCalls {
          self.toolCallRouter?.handleToolCall(call) { [weak self] response in
            self?.geminiService.sendToolResponse(response)
          }
        }
      }
    }

    geminiService.onToolCallCancellation = { [weak self] cancellation in
      guard let self else { return }
      Task { @MainActor in
        self.toolCallRouter?.cancelToolCalls(ids: cancellation.ids)
      }
    }

    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 100_000_000)
        guard !Task.isCancelled else { break }
        self.connectionState = self.geminiService.connectionState
        self.isModelSpeaking = self.geminiService.isModelSpeaking
        self.toolCallStatus = self.openClawBridge.lastToolCallStatus
        self.openClawConnectionState = self.openClawBridge.connectionState
      }
    }

    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isGeminiActive = false
      return
    }

    let setupOk = await geminiService.connect()

    if !setupOk {
      var msg: String
      switch geminiService.connectionState {
      case .error(let err): msg = "Gemini error: \(err)"
      case .disconnected: msg = "Gemini .disconnected (state wasn't .error — receive loop race)"
      case .connecting: msg = "Gemini stuck in .connecting (no WS open)"
      case .settingUp: msg = "Gemini stuck in .settingUp (no setupComplete)"
      case .ready: msg = "Gemini ready but setupOk=false (continuation race)"
      }
      NSLog("[Gemini] connect failed: %@", msg)
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected

      // Fetch models FIRST, THEN show the alert — iOS alerts don't update after
      // they're displayed, so we need the full content before presenting.
      Task { @MainActor in
        let live = await self.fetchLiveCapableModels() ?? "(fetch failed)"
        self.errorMessage = "\(msg)\n\nTried: \(GeminiConfig.model)\n\nAvailable:\n\(live)"
      }
      return
    }

    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      geminiService.disconnect()
      stateObservation?.cancel()
      stateObservation = nil
      isGeminiActive = false
      connectionState = .disconnected
      return
    }

    if SettingsManager.shared.proactiveNotificationsEnabled {
      eventClient.onNotification = { [weak self] text in
        guard let self else { return }
        Task { @MainActor in
          guard self.isGeminiActive, self.connectionState == .ready else { return }
          self.geminiService.sendTextMessage(text)
        }
      }
      eventClient.connect()
    }
  }

  func stopSession() {
    eventClient.disconnect()
    toolCallRouter?.cancelAll()
    toolCallRouter = nil
    audioManager.stopCapture()
    tts.close()
    turnTextBuffer = ""
    geminiService.disconnect()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  func sendVideoFrameIfThrottled(image: UIImage) {
    guard SettingsManager.shared.videoStreamingEnabled else { return }
    guard isGeminiActive, connectionState == .ready else { return }
    let now = Date()
    guard now.timeIntervalSince(lastVideoFrameTime) >= GeminiConfig.videoFrameInterval else { return }
    lastVideoFrameTime = now
    geminiService.sendVideoFrame(image: image)
  }

  // Queries Google's Gemini API for models accessible with the configured key,
  // filters to those that support bidiGenerateContent (Live API), returns
  // a newline-separated string of their names.
  private func fetchLiveCapableModels() async -> String? {
    let key = GeminiConfig.apiKey
    guard !key.isEmpty, key != "YOUR_GEMINI_API_KEY" else { return nil }
    guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(key)&pageSize=100") else { return nil }
    do {
      let (data, _) = try await URLSession.shared.data(from: url)
      guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]] else { return nil }
      var names: [String] = []
      for m in models {
        guard let name = m["name"] as? String,
              let methods = m["supportedGenerationMethods"] as? [String] else { continue }
        if methods.contains("bidiGenerateContent") {
          names.append(name)
        }
      }
      return names.isEmpty ? "(none support bidiGenerateContent)" : names.joined(separator: "\n")
    } catch {
      return "fetch failed: \(error.localizedDescription)"
    }
  }
}
