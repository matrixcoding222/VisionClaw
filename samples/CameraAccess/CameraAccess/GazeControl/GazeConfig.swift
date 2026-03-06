import Foundation
import UIKit

enum GazeConfig {
  // Color marker IDs (must match calibration_overlay.py)
  static let markerTopLeft = "TL"      // Red
  static let markerTopRight = "TR"     // Green
  static let markerBottomLeft = "BL"   // Blue
  static let markerBottomRight = "BR"  // Yellow

  static let allMarkerIDs: Set<String> = [markerTopLeft, markerTopRight, markerBottomLeft, markerBottomRight]

  // HSV ranges for color detection (H: 0-360, S: 0-1, V: 0-1)
  // Each entry: (hueMin, hueMax, satMin, valMin)
  struct ColorRange {
    let id: String
    let hueMin: CGFloat
    let hueMax: CGFloat
    let satMin: CGFloat
    let valMin: CGFloat
  }

  static let colorRanges: [ColorRange] = [
    ColorRange(id: markerTopLeft,     hueMin: 340, hueMax: 20,  satMin: 0.4, valMin: 0.3),  // Red (wraps around 0)
    ColorRange(id: markerTopRight,    hueMin: 90,  hueMax: 150, satMin: 0.4, valMin: 0.3),  // Green
    ColorRange(id: markerBottomLeft,  hueMin: 200, hueMax: 260, satMin: 0.4, valMin: 0.3),  // Blue
    ColorRange(id: markerBottomRight, hueMin: 40,  hueMax: 70,  satMin: 0.4, valMin: 0.3),  // Yellow
  ]

  // Minimum blob size as fraction of image area (filter out noise)
  static let minBlobFraction: Double = 0.005
  // Maximum blob size (filter out if entire image is one color)
  static let maxBlobFraction: Double = 0.25

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
