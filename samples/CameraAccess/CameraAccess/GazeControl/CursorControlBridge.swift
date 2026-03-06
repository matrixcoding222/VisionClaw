import Foundation

enum CursorServerConnectionState: Equatable {
  case disconnected
  case checking
  case connected
  case unreachable(String)
}

@MainActor
class CursorControlBridge: ObservableObject {
  @Published var connectionState: CursorServerConnectionState = .disconnected
  @Published var remoteScreenSize: CGSize?

  private let session: URLSession
  private let pingSession: URLSession

  init() {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = 2  // Fast timeout for real-time control
    self.session = URLSession(configuration: config)

    let pingConfig = URLSessionConfiguration.default
    pingConfig.timeoutIntervalForRequest = 5
    self.pingSession = URLSession(configuration: pingConfig)
  }

  // MARK: - Connection

  func checkConnection() async {
    guard GazeConfig.isCursorServerConfigured else {
      connectionState = .disconnected
      return
    }
    connectionState = .checking
    guard let url = URL(string: "\(GazeConfig.cursorServerBaseURL)/health") else {
      connectionState = .unreachable("Invalid URL")
      return
    }
    do {
      let (data, response) = try await pingSession.data(for: URLRequest(url: url))
      if let http = response as? HTTPURLResponse, http.statusCode == 200 {
        connectionState = .connected
        NSLog("[GazeCursor] Server reachable")
        await fetchScreenSize()
      } else {
        connectionState = .unreachable("Unexpected response")
      }
    } catch {
      connectionState = .unreachable(error.localizedDescription)
      NSLog("[GazeCursor] Server unreachable: %@", error.localizedDescription)
    }
  }

  func fetchScreenSize() async {
    guard let url = URL(string: "\(GazeConfig.cursorServerBaseURL)/screen") else { return }
    do {
      let (data, _) = try await session.data(for: URLRequest(url: url))
      if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let w = json["width"] as? Double,
         let h = json["height"] as? Double {
        remoteScreenSize = CGSize(width: w, height: h)
        NSLog("[GazeCursor] Screen size: %.0fx%.0f", w, h)
      }
    } catch {
      NSLog("[GazeCursor] Failed to get screen size: %@", error.localizedDescription)
    }
  }

  // MARK: - Cursor Control (fire-and-forget)

  func moveCursor(to point: CGPoint) {
    sendCommand("move", body: ["x": point.x, "y": point.y])
  }

  func click(at point: CGPoint) {
    sendCommand("click", body: ["x": point.x, "y": point.y])
  }

  func mouseDown(at point: CGPoint) {
    sendCommand("mouse_down", body: ["x": point.x, "y": point.y])
  }

  func mouseDragTo(_ point: CGPoint) {
    sendCommand("mouse_drag_to", body: ["x": point.x, "y": point.y])
  }

  func mouseUp(at point: CGPoint) {
    sendCommand("mouse_up", body: ["x": point.x, "y": point.y])
  }

  // MARK: - Internal

  private func sendCommand(_ endpoint: String, body: [String: Any]) {
    guard let url = URL(string: "\(GazeConfig.cursorServerBaseURL)/\(endpoint)") else { return }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: body)

    // Fire-and-forget: don't block the frame pipeline
    Task.detached { [session] in
      _ = try? await session.data(for: request)
    }
  }
}
