import Foundation
import SwiftUI

struct TranscriptSegment: Identifiable {
  let id: String
  var text: String
  let isFinal: Bool
  let timestamp: Date
  let speaker: Int?
}

@MainActor
class TranscriptionViewModel: ObservableObject {
  @Published var isActive = false
  @Published var connectionState: DeepgramConnectionState = .disconnected
  @Published var segments: [TranscriptSegment] = []
  @Published var errorMessage: String?

  // Current partial transcript being updated in real-time
  @Published var currentPartialText: String = ""

  private var deepgramService: DeepgramService?
  private let audioManager = AudioManager()
  private var currentPartialId: String?

  var streamingMode: StreamingMode = .glasses

  var fullTranscript: String {
    segments.filter(\.isFinal).map(\.text).joined(separator: " ")
  }

  func startSession() async {
    guard !isActive else { return }

    let apiKey = SettingsManager.shared.deepgramAPIKey
    guard apiKey != "YOUR_DEEPGRAM_API_KEY" && !apiKey.isEmpty else {
      errorMessage = "Deepgram API key not configured. Add your key in Settings."
      return
    }

    isActive = true
    segments = []
    currentPartialText = ""
    currentPartialId = nil

    deepgramService = DeepgramService(apiKey: apiKey)

    deepgramService?.onConnectionStateChanged = { [weak self] state in
      guard let self else { return }
      Task { @MainActor in
        self.connectionState = state
        if case .error(let msg) = state {
          self.errorMessage = "Deepgram: \(msg)"
        }
      }
    }

    deepgramService?.onTranscript = { [weak self] transcript in
      guard let self else { return }
      Task { @MainActor in
        self.handleTranscript(transcript)
      }
    }

    // Setup audio
    do {
      try audioManager.setupAudioSession(useIPhoneMode: streamingMode == .iPhone)
    } catch {
      errorMessage = "Audio setup failed: \(error.localizedDescription)"
      isActive = false
      return
    }

    // Wire audio to Deepgram
    audioManager.onAudioCaptured = { [weak self] data in
      self?.deepgramService?.sendAudio(data: data)
    }

    // Connect to Deepgram
    deepgramService?.connect()

    // Start mic capture
    do {
      try audioManager.startCapture()
    } catch {
      errorMessage = "Mic capture failed: \(error.localizedDescription)"
      deepgramService?.disconnect()
      isActive = false
      return
    }
  }

  func stopSession() {
    audioManager.stopCapture()
    deepgramService?.disconnect()
    deepgramService = nil
    isActive = false
    connectionState = .disconnected
    currentPartialText = ""
    currentPartialId = nil
  }

  func clearTranscript() {
    segments = []
    currentPartialText = ""
    currentPartialId = nil
  }

  // MARK: - Transcript Handling

  private func handleTranscript(_ transcript: DeepgramTranscript) {
    if transcript.isFinal {
      // Finalize: replace partial with final segment
      if let partialId = currentPartialId,
         let idx = segments.firstIndex(where: { $0.id == partialId }) {
        segments[idx] = TranscriptSegment(
          id: transcript.id,
          text: transcript.text,
          isFinal: true,
          timestamp: transcript.timestamp,
          speaker: transcript.speaker
        )
      } else {
        segments.append(TranscriptSegment(
          id: transcript.id,
          text: transcript.text,
          isFinal: true,
          timestamp: transcript.timestamp,
          speaker: transcript.speaker
        ))
      }
      currentPartialText = ""
      currentPartialId = nil
    } else {
      // Partial: update or insert
      currentPartialText = transcript.text
      if let partialId = currentPartialId,
         let idx = segments.firstIndex(where: { $0.id == partialId }) {
        segments[idx] = TranscriptSegment(
          id: partialId,
          text: transcript.text,
          isFinal: false,
          timestamp: transcript.timestamp,
          speaker: transcript.speaker
        )
      } else {
        let id = transcript.id
        currentPartialId = id
        segments.append(TranscriptSegment(
          id: id,
          text: transcript.text,
          isFinal: false,
          timestamp: transcript.timestamp,
          speaker: transcript.speaker
        ))
      }
    }
  }
}
