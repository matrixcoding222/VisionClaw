import Foundation
import SwiftUI

enum GazeMode: String {
  case calibrating
  case tracking
  case dragging
}

@MainActor
class GazeControlViewModel: ObservableObject {
  @Published var isActive = false
  @Published var mode: GazeMode = .calibrating
  @Published var calibrationCount = 0  // 0-4 markers detected
  @Published var gazeScreenPoint: CGPoint?  // Current estimated screen position
  @Published var isDragging = false
  @Published var errorMessage: String?

  let cursorBridge = CursorControlBridge()

  private let markerDetector = MarkerDetectionService()
  private let homography = HomographyService()
  private var lastSendTime: Date = .distantPast
  private var smoothedPoint: CGPoint?
  private var dragStartPoint: CGPoint?

  // MARK: - Session Control

  func startSession() async {
    isActive = true
    mode = .calibrating
    calibrationCount = 0
    gazeScreenPoint = nil
    smoothedPoint = nil
    homography.reset()

    await cursorBridge.checkConnection()

    if cursorBridge.connectionState != .connected {
      errorMessage = "Cannot reach cursor server at \(GazeConfig.cursorServerBaseURL)"
      isActive = false
      return
    }

    NSLog("[GazeControl] Session started, awaiting calibration")
  }

  func stopSession() {
    if isDragging, let pt = smoothedPoint {
      cursorBridge.mouseUp(at: pt)
      isDragging = false
    }
    isActive = false
    mode = .calibrating
    calibrationCount = 0
    gazeScreenPoint = nil
    smoothedPoint = nil
    homography.reset()
    NSLog("[GazeControl] Session stopped")
  }

  // MARK: - Frame Processing

  func processFrame(_ image: UIImage) {
    guard isActive else { return }

    // Throttle frame processing
    let now = Date()
    guard now.timeIntervalSince(lastSendTime) >= GazeConfig.gazeUpdateInterval else { return }
    lastSendTime = now

    Task {
      let result = await markerDetector.detectMarkers(in: image)

      await MainActor.run {
        self.calibrationCount = result.detectedCount

        if result.isFullyCalibrated {
          self.updateCalibration(result)
          self.updateGazePoint(image: image)
        } else if self.mode == .calibrating {
          // Still waiting for all 4 markers
        } else {
          // Lost calibration - use last known homography if available
          if self.homography.isCalibrated {
            self.updateGazePoint(image: image)
          }
        }
      }
    }
  }

  // MARK: - Drag Mode

  func toggleDrag() {
    guard mode == .tracking || mode == .dragging else { return }

    if isDragging {
      // Release drag
      if let pt = smoothedPoint {
        cursorBridge.mouseUp(at: pt)
      }
      isDragging = false
      mode = .tracking
      NSLog("[GazeControl] Drag released")
    } else {
      // Start drag
      if let pt = smoothedPoint {
        cursorBridge.mouseDown(at: pt)
        dragStartPoint = pt
        isDragging = true
        mode = .dragging
        NSLog("[GazeControl] Drag started at %.0f, %.0f", pt.x, pt.y)
      }
    }
  }

  func triggerClick() {
    guard mode == .tracking, let pt = smoothedPoint else { return }
    cursorBridge.click(at: pt)
    NSLog("[GazeControl] Click at %.0f, %.0f", pt.x, pt.y)
  }

  // MARK: - Internal

  private func updateCalibration(_ result: MarkerDetectionResult) {
    guard let screenSize = cursorBridge.remoteScreenSize else {
      NSLog("[GazeControl] No screen size from server yet")
      return
    }

    let centers = result.markers.mapValues { $0.center }

    if homography.calibrate(markerCenters: centers, screenSize: screenSize) {
      if mode == .calibrating {
        mode = .tracking
        NSLog("[GazeControl] Calibrated for %.0fx%.0f screen", screenSize.width, screenSize.height)
      }
    }
  }

  private func updateGazePoint(image: UIImage) {
    guard homography.isCalibrated else { return }

    // The "gaze point" is the center of the camera frame
    // In Vision normalized coordinates (0..1, origin bottom-left):
    // center = (0.5, 0.5)
    let frameCenter = CGPoint(x: 0.5, y: 0.5)

    guard let screenPoint = homography.mapPoint(frameCenter) else { return }

    // Clamp to screen bounds
    let screenSize = cursorBridge.remoteScreenSize ?? CGSize(width: 1920, height: 1080)
    let clampedX = max(0, min(screenSize.width, screenPoint.x))
    let clampedY = max(0, min(screenSize.height, screenPoint.y))
    let clamped = CGPoint(x: clampedX, y: clampedY)

    // Exponential moving average for smoothing
    if let prev = smoothedPoint {
      let alpha = GazeConfig.smoothingFactor
      smoothedPoint = CGPoint(
        x: prev.x + alpha * (clamped.x - prev.x),
        y: prev.y + alpha * (clamped.y - prev.y)
      )
    } else {
      smoothedPoint = clamped
    }

    gazeScreenPoint = smoothedPoint

    // Send to Mac
    guard let point = smoothedPoint else { return }

    if isDragging {
      cursorBridge.mouseDragTo(point)
    } else {
      cursorBridge.moveCursor(to: point)
    }
  }
}
