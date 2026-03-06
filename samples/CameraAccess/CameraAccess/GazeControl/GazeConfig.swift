import Foundation

enum GazeConfig {
  // QR code marker content strings (must match calibration_overlay.py)
  static let markerTopLeft = "TL"
  static let markerTopRight = "TR"
  static let markerBottomLeft = "BL"
  static let markerBottomRight = "BR"

  static let allMarkerIDs: Set<String> = [markerTopLeft, markerTopRight, markerBottomLeft, markerBottomRight]

  // Cursor server (Mac companion)
  static var cursorServerHost: String { SettingsManager.shared.cursorServerHost }
  static var cursorServerPort: Int { SettingsManager.shared.cursorServerPort }

  static var cursorServerBaseURL: String {
    "\(cursorServerHost):\(cursorServerPort)"
  }

  static var isCursorServerConfigured: Bool {
    return cursorServerHost != "http://YOUR_MAC_HOSTNAME.local"
      && !cursorServerHost.isEmpty
  }

  // Frame processing
  static let gazeUpdateInterval: TimeInterval = 1.0 / 15.0  // 15 fps
  static let smoothingFactor: Double = 0.3  // Exponential moving average (lower = smoother)
}
