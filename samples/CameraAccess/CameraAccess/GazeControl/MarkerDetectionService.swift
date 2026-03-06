import CoreGraphics
import Foundation
import UIKit

struct DetectedMarker {
  let id: String
  let center: CGPoint  // Normalized 0..1 (origin top-left, matching image coords)
  let pixelCount: Int
}

struct MarkerDetectionResult {
  let markers: [String: DetectedMarker]

  var isFullyCalibrated: Bool {
    GazeConfig.allMarkerIDs.allSatisfy { markers[$0] != nil }
  }

  var detectedCount: Int {
    markers.count
  }
}

class MarkerDetectionService {

  func detectMarkers(in image: UIImage) -> MarkerDetectionResult {
    guard let cgImage = image.cgImage else {
      return MarkerDetectionResult(markers: [:])
    }

    let width = cgImage.width
    let height = cgImage.height
    let totalPixels = width * height

    guard let data = cgImage.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data)
    else {
      return MarkerDetectionResult(markers: [:])
    }

    let bytesPerPixel = cgImage.bitsPerPixel / 8
    let bytesPerRow = cgImage.bytesPerRow

    // Downsample for speed: check every Nth pixel
    let step = max(1, min(width, height) / 80)

    // For each color range, accumulate (x, y) and count
    var sumX = [String: Double]()
    var sumY = [String: Double]()
    var count = [String: Int]()

    for range in GazeConfig.colorRanges {
      sumX[range.id] = 0
      sumY[range.id] = 0
      count[range.id] = 0
    }

    for y in stride(from: 0, to: height, by: step) {
      for x in stride(from: 0, to: width, by: step) {
        let offset = y * bytesPerRow + x * bytesPerPixel

        let r = CGFloat(ptr[offset]) / 255.0
        let g = CGFloat(ptr[offset + 1]) / 255.0
        let b = CGFloat(ptr[offset + 2]) / 255.0

        let (h, s, v) = rgbToHSV(r: r, g: g, b: b)
        let hDeg = h * 360.0

        for range in GazeConfig.colorRanges {
          guard s >= range.satMin, v >= range.valMin else { continue }

          let hueMatch: Bool
          if range.hueMin > range.hueMax {
            // Wraps around 0 (red)
            hueMatch = hDeg >= range.hueMin || hDeg <= range.hueMax
          } else {
            hueMatch = hDeg >= range.hueMin && hDeg <= range.hueMax
          }

          if hueMatch {
            sumX[range.id]! += Double(x)
            sumY[range.id]! += Double(y)
            count[range.id]! += 1
            break  // Each pixel matches at most one color
          }
        }
      }
    }

    let minCount = Int(Double(totalPixels) / Double(step * step) * GazeConfig.minBlobFraction)
    let maxCount = Int(Double(totalPixels) / Double(step * step) * GazeConfig.maxBlobFraction)

    var markers: [String: DetectedMarker] = [:]

    for range in GazeConfig.colorRanges {
      let c = count[range.id] ?? 0
      guard c >= minCount, c <= maxCount else { continue }

      let cx = sumX[range.id]! / Double(c) / Double(width)
      let cy = sumY[range.id]! / Double(c) / Double(height)

      markers[range.id] = DetectedMarker(
        id: range.id,
        center: CGPoint(x: cx, y: cy),
        pixelCount: c
      )
    }

    return MarkerDetectionResult(markers: markers)
  }

  // MARK: - RGB to HSV conversion

  private func rgbToHSV(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
    let maxC = max(r, g, b)
    let minC = min(r, g, b)
    let delta = maxC - minC

    let v = maxC

    guard delta > 0.001 else {
      return (0, 0, v)
    }

    let s = delta / maxC

    var h: CGFloat
    if r == maxC {
      h = (g - b) / delta
    } else if g == maxC {
      h = 2.0 + (b - r) / delta
    } else {
      h = 4.0 + (r - g) / delta
    }

    h /= 6.0
    if h < 0 { h += 1.0 }

    return (h, s, v)
  }
}
