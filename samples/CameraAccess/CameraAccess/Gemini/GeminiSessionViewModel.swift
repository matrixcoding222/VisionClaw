import Foundation
import SwiftUI

// Kept name `GeminiSessionViewModel` for minimal disruption; the brain is now
// OpenClaw via DirectJarvisService. Same @Published surface so existing views
// (StreamView, StreamSessionView, GeminiOverlayView) continue to work unchanged.
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

  private let direct = DirectJarvisService()
  private var stateObservation: Task<Void, Never>?

  var streamingMode: StreamingMode = .glasses

  func startSession() async {
    guard !isGeminiActive else { return }
    isGeminiActive = true
    connectionState = .connecting
    openClawConnectionState = .checking
    errorMessage = nil
    userTranscript = ""
    aiTranscript = ""

    direct.start()

    // Mirror direct service state into the @Published surface the UI reads.
    stateObservation = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled, self.isGeminiActive else { break }
        self.userTranscript = self.direct.userText
        self.aiTranscript = self.direct.jarvisText
        let s = self.direct.status
        if s.starts(with: "listening") || s.starts(with: "speaking") || s.starts(with: "thinking") {
          self.connectionState = .ready
          self.openClawConnectionState = .connected
        } else if s.starts(with: "requesting") || s.starts(with: "starting") || s.starts(with: "connecting") {
          self.connectionState = .connecting
          self.openClawConnectionState = .checking
        } else if s == "idle" {
          self.connectionState = .disconnected
        } else {
          // Any other status is an error message from the service
          self.connectionState = .error(s)
          self.openClawConnectionState = .unreachable(s)
        }
        self.isModelSpeaking = s.starts(with: "speaking")
      }
    }
  }

  func stopSession() {
    direct.stop()
    stateObservation?.cancel()
    stateObservation = nil
    isGeminiActive = false
    connectionState = .disconnected
    openClawConnectionState = .notConfigured
    isModelSpeaking = false
    userTranscript = ""
    aiTranscript = ""
    toolCallStatus = .idle
  }

  // Video frames — OpenClaw bridge doesn't currently accept image input per-turn.
  // Keeping the signature so callers (StreamView) don't need to change.
  // When/if we wire vision context into OpenClaw turns, this is the hook.
  func sendVideoFrameIfThrottled(image: UIImage) {
    // no-op for now; visual context will be handled via separate context capture
    _ = image
  }
}
