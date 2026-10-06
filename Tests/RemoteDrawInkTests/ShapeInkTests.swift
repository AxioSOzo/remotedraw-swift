//
//  Moved here from `apps/ios/RemoteDrawTests/` by Stage 2.
//
//  These are the renderer's tests, not the app's: they reach `InkRenderer`,
//  `RemoteDrawInk` and `RemoteDrawInkSurface` internals, which the app can no
//  longer see now that it imports the module instead of compiling its source.
//  The right home for a test that needs a target's internals is that target's
//  own test bundle — and `swift test` runs them in two seconds on macOS with no
//  simulator, which is a better place for a parity check than an app build.
//
import XCTest
@testable import RemoteDrawInk

/// Shape assist rewrites a recognised stroke to line / arrow / rectangle /
/// ellipse, and this board used to draw those as a bare stroked polyline —
/// dropping the instrument entirely. `packages/client/tests/shapeInk.test.ts`
/// pins the identical cases on the web: a shape snapped here and the same
/// shape replayed on a receiver must be the same mark.
final class ShapeInkTests: XCTestCase {
  private let line = [
    NormalizedPoint(x: 0.12, y: 0.5, t: 0),
    NormalizedPoint(x: 0.82, y: 0.5, t: 560),
  ]
  private let boxDiagonal = [
    NormalizedPoint(x: 0.2, y: 0.2),
    NormalizedPoint(x: 0.7, y: 0.6),
  ]

  func testPressurelessInkDynamicsDoNotChangeWithProjectionZoom() {
    let board = [NormalizedPoint(x: 0.2, y: 0.3, t: 0),
      NormalizedPoint(x: 0.35, y: 0.5, t: 24), NormalizedPoint(x: 0.5, y: 0.6, t: 48)]
    let expected = InkRenderer.widthFactors(for: board)
    for zoom in [0.1, 0.5, 2.0, 8.0] {
      let phone = board.map { NormalizedPoint(x: ($0.x - 0.5) / zoom,
        y: ($0.y - 0.5) / zoom, t: $0.t) }
      let actual = InkRenderer.widthFactors(for: phone,
        coordinateScale: CGSize(width: zoom, height: zoom))
      for (left, right) in zip(actual, expected) { XCTAssertEqual(left, right, accuracy: 1e-12) }
    }
  }

  func testClaimsExactlyTheTypesShapeAssistSnapsTo() {
    for type in ["line", "arrow", "rectangle", "ellipse"] {
      XCTAssertTrue(InkRenderer.isInkShapeType(type))
    }
    for type in ["freehand", "point", "text", "auto"] {
      XCTAssertFalse(InkRenderer.isInkShapeType(type))
      XCTAssertNil(InkRenderer.shapeInkStrokes(type: type, points: line, strokeWidth: 0.01))
    }
  }

  func testTwoPointLineBecomesADenselySampledPolyline() {
    let strokes = InkRenderer.shapeInkStrokes(type: "line", points: line, strokeWidth: 0.01)
    XCTAssertEqual(strokes?.count, 1)
    let shaft = try! XCTUnwrap(strokes?.first)
    // Grain streaks wander once every few samples and the ribbon needs three
    // points before it varies at all, so two endpoints are not a stroke.
    XCTAssertGreaterThan(shaft.count, 40)
    XCTAssertEqual(shaft.first?.x ?? 0, 0.12, accuracy: 1e-9)
    XCTAssertEqual(shaft.last?.x ?? 0, 0.82, accuracy: 1e-9)
    for point in shaft {
      XCTAssertEqual(point.y, 0.5, accuracy: 1e-9)
    }
  }

  func testCarriesTimingAlongTheShape() {
    let shaft = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "line", points: line, strokeWidth: 0.01)?.first
    )
    XCTAssertEqual(shaft.first?.t, 0)
    XCTAssertEqual(shaft.last?.t ?? 0, 560, accuracy: 1e-9)
    for index in 1..<shaft.count {
      XCTAssertGreaterThan(shaft[index].t ?? 0, shaft[index - 1].t ?? 0)
    }
  }

  func testInventsNoDynamicsWhenTheEndpointsCarryNone() {
    let outline = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "rectangle", points: boxDiagonal, strokeWidth: 0.01)?.first
    )
    for point in outline {
      XCTAssertNil(point.t)
      XCTAssertNil(point.pressure)
    }
  }

  func testExpandsATwoPointDiagonalRectangleIntoItsCornerLoop() {
    // Senders store a snapped rectangle as a diagonal; only the server
    // expands it. Walking the stored trail would draw a diagonal stroke.
    let outline = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "rectangle", points: boxDiagonal, strokeWidth: 0.01)?.first
    )
    for corner in [(0.2, 0.2), (0.7, 0.2), (0.7, 0.6), (0.2, 0.6)] {
      XCTAssertTrue(
        outline.contains { abs($0.x - corner.0) < 1e-9 && abs($0.y - corner.1) < 1e-9 },
        "missing corner \(corner)"
      )
    }
    XCTAssertEqual(outline.first?.x ?? 0, 0.2, accuracy: 1e-9)
    XCTAssertEqual(outline.last?.x ?? 0, 0.2, accuracy: 1e-9)
    // Every sample sits on a box edge, never across the diagonal.
    for point in outline {
      let onVertical = abs(point.x - 0.2) < 1e-9 || abs(point.x - 0.7) < 1e-9
      let onHorizontal = abs(point.y - 0.2) < 1e-9 || abs(point.y - 0.6) < 1e-9
      XCTAssertTrue(onVertical || onHorizontal)
    }
  }

  func testExpandsATwoPointDiagonalEllipseOntoTheBoundingEllipse() {
    let outline = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "ellipse", points: boxDiagonal, strokeWidth: 0.01)?.first
    )
    XCTAssertGreaterThanOrEqual(outline.count, 49)
    for point in outline {
      let dx = (point.x - 0.45) / 0.25
      let dy = (point.y - 0.4) / 0.2
      XCTAssertEqual(dx * dx + dy * dy, 1, accuracy: 1e-9)
    }
  }

  func testArrowIsTwoMarksShaftThenBarbTipBarbHead() {
    let strokes = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "arrow", points: line, strokeWidth: 0.012)
    )
    XCTAssertEqual(strokes.count, 2)
    let shaft = strokes[0]
    let head = strokes[1]
    XCTAssertEqual(shaft.last?.x ?? 0, 0.82, accuracy: 1e-9)
    let tipIndex = head.firstIndex { abs($0.x - 0.82) < 1e-9 && abs($0.y - 0.5) < 1e-9 }
    XCTAssertNotNil(tipIndex)
    XCTAssertGreaterThan(tipIndex ?? 0, 0)
    XCTAssertLessThan(tipIndex ?? 0, head.count - 1)
    // The barbs straddle the shaft and trail behind the tip.
    let barbs = [head.first!, head.last!]
    XCTAssertLessThan(barbs.map(\.y).min() ?? 0, 0.5)
    XCTAssertGreaterThan(barbs.map(\.y).max() ?? 0, 0.5)
    for barb in barbs {
      XCTAssertLessThan(barb.x, 0.82)
    }
  }

  func testDegenerateShapesFallBackRatherThanDrawingASpike() {
    let dot = [NormalizedPoint(x: 0.5, y: 0.5), NormalizedPoint(x: 0.5, y: 0.5)]
    XCTAssertNil(InkRenderer.shapeInkStrokes(type: "line", points: dot, strokeWidth: 0.01))
    XCTAssertNil(InkRenderer.shapeInkStrokes(type: "ellipse", points: dot, strokeWidth: 0.01))
    XCTAssertNil(
      InkRenderer.shapeInkStrokes(
        type: "line",
        points: [NormalizedPoint(x: 0.5, y: 0.5)],
        strokeWidth: 0.01
      )
    )
  }

  func testTheWalkMatchesTheWebPortExactly() {
    // Pinned against packages/client/tests/shapeInk.test.ts, which asserts the
    // same numbers. If this drifts, the native board and the receiver draw
    // different geometry from the same snapped shape.
    let rectangle = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "rectangle", points: boxDiagonal, strokeWidth: 0.01)?.first
    )
    XCTAssertEqual(rectangle.count, 163)
    XCTAssertEqual(rectangle[1].x, 0.211111, accuracy: 1e-6)
    let ellipse = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "ellipse", points: boxDiagonal, strokeWidth: 0.01)?.first
    )
    XCTAssertEqual(ellipse.count, 129)
    XCTAssertEqual(ellipse[1].x, 0.699699, accuracy: 1e-6)
    XCTAssertEqual(ellipse[1].y, 0.409814, accuracy: 1e-6)
    let arrow = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(type: "arrow", points: line, strokeWidth: 0.012)
    )
    XCTAssertEqual(arrow[0].count, 64)
    XCTAssertEqual(arrow[1].count, 15)
    XCTAssertEqual(arrow[1][0].x, 0.75513, accuracy: 1e-5)
    XCTAssertEqual(arrow[1][0].y, 0.53124, accuracy: 1e-5)
  }

  func testSampleCountStaysBoundedOnAFullSurfaceEllipse() {
    let outline = try! XCTUnwrap(
      InkRenderer.shapeInkStrokes(
        type: "ellipse",
        points: [NormalizedPoint(x: 0, y: 0), NormalizedPoint(x: 1, y: 1)],
        strokeWidth: 0.01
      )?.first
    )
    XCTAssertLessThanOrEqual(outline.count, 401)
  }
}

/// The ported ink math, pinned against the web's own numbers.
///
/// `tests/api/inkSwiftParity.test.ts` reads `InkRenderer.swift` and diffs its
/// instrument *table* against the live TypeScript. The math around the table
/// had no such tripwire, which is how the taper drifted: the web grew an
/// asymmetric exit and a nib-relative length cap while Swift kept a symmetric
/// absolute one, and every suite stayed green. The same vectors are asserted
/// from the RemoteDrawKit twin in `StrokePainterTests.swift`.
final class InkGeometryParityTests: XCTestCase {
  private let line = (0...10).map { CGPoint(x: Double($0) * 10, y: 0) }

  func testTheMarkerLandsHarderThanItLifts() {
    // freehandTaperMultipliers(line, 1000, MARKER_TAPER, 6) on the web: a felt
    // wedge floods at once (0.74) and is dragged off over three times the
    // distance (0.44). A symmetric profile cannot produce this vector.
    let expected: [Double] = [0.74, 1, 1, 1, 1, 1, 1, 1, 1, 0.83532, 0.44]
    let actual = InkRenderer.taperMultipliers(
      for: line, surfaceExtent: 1000, profile: InkRenderer.markerTaper, strokeWidth: 6)
    XCTAssertEqual(actual.count, expected.count)
    for (index, value) in expected.enumerated() {
      XCTAssertEqual(actual[index], value, accuracy: 1e-6, "sample \(index)")
    }
  }

  func testTaperLengthIsMeasuredInNibWidths() {
    // How far a nib takes to seat belongs to the nib, not to the board, so an
    // instrument keeps its shape as the width slider moves. Under the old
    // absolute cap the marker's landing ran 3.7 nib widths at width 3 and 0.6
    // at width 24 — a needle at one end of the slider and a stub at the other.
    func sampledInNibWidths(_ width: Double) -> [Double] {
      let points = (0...200).map { CGPoint(x: Double($0) * width * 0.1, y: 0) }
      return InkRenderer.taperMultipliers(
        for: points, surfaceExtent: 1000, profile: InkRenderer.markerTaper,
        strokeWidth: CGFloat(width))
    }
    let thin = sampledInNibWidths(3)
    let thick = sampledInNibWidths(24)
    for (index, value) in thin.enumerated() {
      XCTAssertEqual(value, thick[index], accuracy: 1e-9, "sample \(index)")
    }
    XCTAssertEqual(thin.first ?? 0, 0.74, accuracy: 1e-9)
    XCTAssertEqual(thin.last ?? 0, 0.44, accuracy: 1e-9)
  }

  func testOmittingTheWidthFallsBackToTheAbsoluteCap() {
    let expected: [Double] = [0.74, 1, 1, 1, 1, 1, 1, 1, 1, 0.958519, 0.44]
    let actual = InkRenderer.taperMultipliers(
      for: line, surfaceExtent: 1000, profile: InkRenderer.markerTaper)
    for (index, value) in expected.enumerated() {
      XCTAssertEqual(actual[index], value, accuracy: 1e-6, "sample \(index)")
    }
  }

  func testAnOrdinaryStrokeDrawsAtTheNominalNib() {
    // VELOCITY_REFERENCE = 0.0068 normalized units per ms puts factor 1.0 at
    // 100 mm/s. Under the old 0.004 the same stroke came out at 0.86 — every
    // ordinary mark thinner than the nib that was asked for.
    let step = 0.00136 * 16.0
    let points = (0...20).map {
      NormalizedPoint(x: 0.1 + Double($0) * step, y: 0.5, t: Double($0) * 16)
    }
    let factors = InkRenderer.widthFactors(for: points, range: InkRenderer.markerFactorRange)
    for (index, factor) in factors.enumerated() {
      XCTAssertEqual(factor, 1, accuracy: 1e-9, "sample \(index)")
    }
    // The band is the ink bead's, not a subtle wobble: 0.72...1.12.
    XCTAssertEqual(InkRenderer.markerFactorRange.lowerBound, 0.72, accuracy: 1e-9)
    XCTAssertEqual(InkRenderer.markerFactorRange.upperBound, 1.12, accuracy: 1e-9)
  }

  func testTheRightAngleControlPointsMatchTheWeb() {
    // The vector pinned in packages/geometry/tests/smoothing.test.ts:
    //   M 0 0 C 16.6667 0 100 0 100 0 C 100 0 100 100 100 100
    //   C 100 100 16.6667 100 0 100
    // Without the turn attenuation the handles run 16.6667 units *past* each
    // corner and a board painted the 12.5% overshoot the web no longer does.
    let square = [
      CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0),
      CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100),
    ]
    let sixth = 100.0 / 6
    let expected: [(CGPoint, CGPoint, CGPoint)] = [
      (CGPoint(x: sixth, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 0)),
      (CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 100, y: 100)),
      (CGPoint(x: 100, y: 100), CGPoint(x: sixth, y: 100), CGPoint(x: 0, y: 100)),
    ]
    var curves: [(CGPoint, CGPoint, CGPoint)] = []
    InkRenderer.smoothPath(through: square).forEach { element in
      if case .curve(let to, let control1, let control2) = element {
        curves.append((control1, control2, to))
      }
    }
    XCTAssertEqual(curves.count, expected.count)
    // SwiftUI's Path stores its points at single precision, so the comparison
    // is to a ten-thousandth rather than to the last bit.
    for (index, row) in expected.enumerated() {
      XCTAssertEqual(curves[index].0.x, row.0.x, accuracy: 1e-4, "c1x \(index)")
      XCTAssertEqual(curves[index].0.y, row.0.y, accuracy: 1e-4, "c1y \(index)")
      XCTAssertEqual(curves[index].1.x, row.1.x, accuracy: 1e-4, "c2x \(index)")
      XCTAssertEqual(curves[index].1.y, row.1.y, accuracy: 1e-4, "c2y \(index)")
      XCTAssertEqual(curves[index].2.x, row.2.x, accuracy: 1e-4, "end x \(index)")
      XCTAssertEqual(curves[index].2.y, row.2.y, accuracy: 1e-4, "end y \(index)")
    }
  }

  func testACornerStaysInsideItsOwnBox() {
    // The reported artefact: a calibration square at 0.05-0.95 of a 1412-wide
    // board whose smoothed path ran x: -24 ... 1502.
    let near = 0.05 * 1412.0
    let far = 0.95 * 1412.0
    let square = [
      CGPoint(x: near, y: near), CGPoint(x: far, y: near),
      CGPoint(x: far, y: far), CGPoint(x: near, y: far),
      CGPoint(x: near, y: near),
    ]
    let box = InkRenderer.smoothPath(through: square).boundingRect
    let slack = (far - near) * 0.001
    XCTAssertGreaterThanOrEqual(box.minX, near - slack)
    XCTAssertGreaterThanOrEqual(box.minY, near - slack)
    XCTAssertLessThanOrEqual(box.maxX, far + slack)
    XCTAssertLessThanOrEqual(box.maxY, far + slack)
  }

  func testTheSpraysDepositSurvivesTheMarkBudget() throws {
    let scatter = try XCTUnwrap(RemoteDrawInk.profile(for: .airbrush).scatter)
    XCTAssertEqual(scatter.dotWidth, 0.125, "the spray's own mark width")
    let points = (0..<40).map { CGPoint(x: Double($0) * 4, y: 100) }
    let short = InkRenderer.scatterPath(
      centerline: points, pressures: [Double](repeating: 0.6, count: points.count),
      width: 10, scatter: scatter)
    XCTAssertEqual(Double(short?.dotWidth ?? 0), 1.25, accuracy: 1e-9)

    // A 700-sample stroke is allowed 2 of the marks per sample it wants — the
    // airbrush fading out as you keep drawing — and each mark grows by
    // sqrt(wanted / allowed) so the deposit is conserved instead.
    //
    // **`wanted` is 8.64, not 9, and this test said 9.** `density` is 9 marks per
    // sample at the *reference* nib, and the number actually asked for is
    // `density * (scatterReferenceWidth / width)` — the areal term that arrived
    // with the width slider so the shipped airbrush at the shipped weight stayed
    // put while only the slider's ends moved. At the 10-unit width this case
    // passes, that factor is 9.6 / 10 = 0.96, so the spray wants 8.64 and the
    // conserving growth is sqrt(8.64 / 2) = 2.0785, not sqrt(9 / 2) = 2.1213.
    //
    // The invariant was always right and the renderer has always satisfied it;
    // the literal was written before the areal term existed and nothing caught
    // it, because this file is Xcode-only — `bun test` cannot see it and
    // `swift test` on the kit does not build it. It failed the first time the
    // simulator suite was run on a clean DerivedData after that change.
    let long = (0..<700).map { CGPoint(x: Double($0), y: 100) }
    let sprayed = InkRenderer.scatterPath(
      centerline: long, pressures: [Double](repeating: 0.6, count: long.count),
      width: 10, scatter: scatter)
    let wanted = 9.0 * (Double(RemoteDrawInk.scatterReferenceWidth) / 10.0)
    XCTAssertEqual(wanted, 8.64, accuracy: 1e-12, "the areal term at this width")
    XCTAssertEqual(
      Double(sprayed?.dotWidth ?? 0), 1.25 * (wanted / 2.0).squareRoot(), accuracy: 1e-9)
  }
}
