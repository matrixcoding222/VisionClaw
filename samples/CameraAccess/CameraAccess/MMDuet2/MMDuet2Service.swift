import Foundation
import UIKit

enum MMDuet2ConnectionState: Equatable {
  case disconnected
  case connecting
  case ready
  case error(String)
}

@MainActor
class MMDuet2Service: ObservableObject {
  @Published var connectionState: MMDuet2ConnectionState = .disconnected

  var onProactiveResponse: ((String, Double) -> Void)?
  var onAutoReset: (() -> Void)?
  var lastQuestion: String = ""

  private let sendQueue = DispatchQueue(label: "mmduet2.send", qos: .userInitiated)
  private var serverURL: String { SettingsManager.shared.mmDuet2ServerURL }
  private let kvCacheResetThreshold = 15000

  // MARK: - Connection

  func connect() async -> Bool {
    connectionState = .connecting
    // Test connectivity with a reset call
    let url = URL(string: "\(serverURL)/reset")!
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        connectionState = .error("Server returned non-200")
        return false
      }
      connectionState = .ready
      return true
    } catch {
      connectionState = .error(error.localizedDescription)
      return false
    }
  }

  func disconnect() {
    connectionState = .disconnected
  }

  func reset() async {
    let url = URL(string: "\(serverURL)/reset")!
    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "POST"
    _ = try? await URLSession.shared.data(for: request)
  }

  // MARK: - Send Video Frame

  func sendVideoFrame(image: UIImage) {
    guard connectionState == .ready else { return }
    sendQueue.async { [weak self] in
      guard let self else { return }
      guard let jpegData = image.jpegData(compressionQuality: 0.5) else { return }

      let boundary = UUID().uuidString
      let url = URL(string: "\(self.serverURL)/add_image")!
      var request = URLRequest(url: url, timeoutInterval: 30)
      request.httpMethod = "POST"
      request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

      var body = Data()
      body.append("--\(boundary)\r\n".data(using: .utf8)!)
      body.append("Content-Disposition: form-data; name=\"image\"; filename=\"frame.jpg\"\r\n".data(using: .utf8)!)
      body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
      body.append(jpegData)
      body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
      request.httpBody = body

      let task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
        if let error {
          print("[MMDuet2] send frame error: \(error.localizedDescription)")
          return
        }
        guard let data else { print("[MMDuet2] no data in response"); return }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
          print("[MMDuet2] failed to parse JSON")
          return
        }
        // Check KV cache and auto-reset if too large
        if let kvLength = json["kv_length"] as? Int, kvLength > self.kvCacheResetThreshold {
          print("[MMDuet2] KV cache at \(kvLength), auto-resetting...")
          Task { @MainActor [weak self] in
            self?.onAutoReset?()
          }
          return
        }

        if let hasResponse = json["response"] as? Bool, hasResponse,
           let content = json["content"] as? String,
           let time = json["time"] as? Double {
          print("[MMDuet2] PROACTIVE RESPONSE: [\(Int(time))s] \(content)")
          Task { @MainActor [weak self] in
            self?.onProactiveResponse?(content, time)
          }
        }
      }
      task.resume()
    }
  }

  // MARK: - Send Text

  func sendText(_ text: String) {
    print("[MMDuet2] sendText: \(text)")
    guard connectionState == .ready else { print("[MMDuet2] not ready, skipping text"); return }
    sendQueue.async { [weak self] in
      guard let self else { return }
      let url = URL(string: "\(self.serverURL)/add_text")!
      var request = URLRequest(url: url, timeoutInterval: 10)
      request.httpMethod = "POST"
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      let body = try? JSONSerialization.data(withJSONObject: ["text": text])
      request.httpBody = body
      URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }
  }
}
