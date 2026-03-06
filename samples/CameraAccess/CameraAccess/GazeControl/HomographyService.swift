import Foundation
import simd

/// Computes a perspective transform (homography) from 4 source points to 4 destination points.
/// Uses the DLT (Direct Linear Transform) algorithm with SIMD for matrix operations.
class HomographyService {
  private var homographyMatrix: simd_double3x3?

  /// Calibrate the homography from detected marker centers (normalized 0..1 Vision coords)
  /// to screen coordinates (pixels).
  func calibrate(
    markerCenters: [String: CGPoint],
    screenSize: CGSize
  ) -> Bool {
    guard let tl = markerCenters[GazeConfig.markerTopLeft],
          let tr = markerCenters[GazeConfig.markerTopRight],
          let bl = markerCenters[GazeConfig.markerBottomLeft],
          let br = markerCenters[GazeConfig.markerBottomRight]
    else {
      return false
    }

    // Source points: marker centers in Vision normalized coords (origin bottom-left)
    let srcPoints = [tl, tr, bl, br]

    // Destination points: corresponding screen corners (origin top-left)
    // Vision coords have Y flipped relative to screen coords
    // TL marker -> screen (0, 0), TR -> (w, 0), BL -> (0, h), BR -> (w, h)
    let dstPoints = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: screenSize.width, y: 0),
      CGPoint(x: 0, y: screenSize.height),
      CGPoint(x: screenSize.width, y: screenSize.height),
    ]

    homographyMatrix = computeHomography(from: srcPoints, to: dstPoints)
    return homographyMatrix != nil
  }

  /// Map a point from camera/Vision normalized coordinates to screen coordinates.
  func mapPoint(_ point: CGPoint) -> CGPoint? {
    guard let H = homographyMatrix else { return nil }

    let src = simd_double3(Double(point.x), Double(point.y), 1.0)
    let dst = H * src

    guard abs(dst.z) > 1e-10 else { return nil }

    return CGPoint(
      x: dst.x / dst.z,
      y: dst.y / dst.z
    )
  }

  var isCalibrated: Bool {
    homographyMatrix != nil
  }

  func reset() {
    homographyMatrix = nil
  }

  // MARK: - DLT Homography Computation

  /// Compute 3x3 homography matrix from 4+ point correspondences using DLT.
  /// src and dst must have the same count (>= 4).
  private func computeHomography(from src: [CGPoint], to dst: [CGPoint]) -> simd_double3x3? {
    guard src.count >= 4, src.count == dst.count else { return nil }

    // We solve: for each pair (s, d), d = H * s
    // Using the DLT formulation, we build an Ax = 0 system and solve via SVD.
    // For 4 points we get 8 equations for 8 unknowns (h9 = 1).

    // Build the 8x8 system Ah = b (non-homogeneous, setting h33 = 1)
    let n = src.count
    var A = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 2 * n)
    var b = [Double](repeating: 0, count: 2 * n)

    for i in 0..<n {
      let sx = Double(src[i].x)
      let sy = Double(src[i].y)
      let dx = Double(dst[i].x)
      let dy = Double(dst[i].y)

      let row1 = 2 * i
      let row2 = 2 * i + 1

      // -sx, -sy, -1,   0,   0,  0,  dx*sx,  dx*sy  | -dx
      A[row1] = [sx, sy, 1, 0, 0, 0, -dx * sx, -dx * sy]
      b[row1] = dx

      //   0,   0,  0, -sx, -sy, -1,  dy*sx,  dy*sy  | -dy
      A[row2] = [0, 0, 0, sx, sy, 1, -dy * sx, -dy * sy]
      b[row2] = dy
    }

    // Solve 8x8 system using Gaussian elimination
    guard let solution = solveLinearSystem(A, b) else { return nil }

    let h = solution
    // h = [h11, h12, h13, h21, h22, h23, h31, h32], h33 = 1
    let matrix = simd_double3x3(rows: [
      simd_double3(h[0], h[1], h[2]),
      simd_double3(h[3], h[4], h[5]),
      simd_double3(h[6], h[7], 1.0),
    ])

    return matrix
  }

  /// Gaussian elimination with partial pivoting for Ax = b.
  private func solveLinearSystem(_ A: [[Double]], _ b: [Double]) -> [Double]? {
    let n = A.count
    guard n == b.count, n > 0, A[0].count == n else { return nil }

    // Augmented matrix
    var M = [[Double]](repeating: [Double](repeating: 0, count: n + 1), count: n)
    for i in 0..<n {
      for j in 0..<n {
        M[i][j] = A[i][j]
      }
      M[i][n] = b[i]
    }

    // Forward elimination with partial pivoting
    for col in 0..<n {
      var maxRow = col
      var maxVal = abs(M[col][col])
      for row in (col + 1)..<n {
        if abs(M[row][col]) > maxVal {
          maxVal = abs(M[row][col])
          maxRow = row
        }
      }
      if maxVal < 1e-12 { return nil }  // Singular
      if maxRow != col { M.swapAt(col, maxRow) }

      for row in (col + 1)..<n {
        let factor = M[row][col] / M[col][col]
        for j in col..<(n + 1) {
          M[row][j] -= factor * M[col][j]
        }
      }
    }

    // Back substitution
    var x = [Double](repeating: 0, count: n)
    for i in stride(from: n - 1, through: 0, by: -1) {
      var sum = M[i][n]
      for j in (i + 1)..<n {
        sum -= M[i][j] * x[j]
      }
      x[i] = sum / M[i][i]
    }

    return x
  }
}
