import Foundation
import UIKit
import Vision

struct DetectedMarker {
  let id: String
  let center: CGPoint  // In image coordinates (0..1 normalized, origin bottom-left)
  let corners: [CGPoint]
}

struct MarkerDetectionResult {
  let markers: [String: DetectedMarker]  // keyed by marker ID (TL, TR, BL, BR)

  var isFullyCalibrated: Bool {
    GazeConfig.allMarkerIDs.allSatisfy { markers[$0] != nil }
  }

  var detectedCount: Int {
    markers.count
  }
}

class MarkerDetectionService {
  private let requestHandler: VNSequenceRequestHandler

  init() {
    self.requestHandler = VNSequenceRequestHandler()
  }

  func detectMarkers(in image: UIImage) async -> MarkerDetectionResult {
    guard let cgImage = image.cgImage else {
      return MarkerDetectionResult(markers: [:])
    }

    return await withCheckedContinuation { continuation in
      let request = VNDetectBarcodesRequest { request, error in
        if let error = error {
          NSLog("[GazeMarker] Detection error: %@", error.localizedDescription)
          continuation.resume(returning: MarkerDetectionResult(markers: [:]))
          return
        }

        guard let results = request.results as? [VNBarcodeObservation] else {
          continuation.resume(returning: MarkerDetectionResult(markers: [:]))
          return
        }

        var markers: [String: DetectedMarker] = [:]

        for observation in results {
          guard observation.symbology == .qr,
                let payload = observation.payloadStringValue,
                GazeConfig.allMarkerIDs.contains(payload)
          else { continue }

          let corners = [
            observation.topLeft,
            observation.topRight,
            observation.bottomRight,
            observation.bottomLeft,
          ]

          let centerX = corners.map(\.x).reduce(0, +) / Double(corners.count)
          let centerY = corners.map(\.y).reduce(0, +) / Double(corners.count)

          markers[payload] = DetectedMarker(
            id: payload,
            center: CGPoint(x: centerX, y: centerY),
            corners: corners
          )
        }

        continuation.resume(returning: MarkerDetectionResult(markers: markers))
      }

      request.symbologies = [.qr]

      let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
      do {
        try handler.perform([request])
      } catch {
        NSLog("[GazeMarker] Handler error: %@", error.localizedDescription)
        continuation.resume(returning: MarkerDetectionResult(markers: [:]))
      }
    }
  }
}
