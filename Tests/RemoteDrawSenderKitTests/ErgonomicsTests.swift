//
//  Moved here from `apps/ios/RemoteDrawTests/ErgonomicsCoreTests.swift` by
//  Stage 2, along with the code it tests.
//
//  Every one of these is a pure function about a gesture — the corner-swipe
//  thresholds, the radial fan's packing, the palm radius, the Pencil tilt
//  conversion — and none of them ever needed an app, a simulator or a window.
//
import XCTest
@testable import RemoteDrawSenderKit

final class ErgonomicsTests: XCTestCase {
  // Mirrors the constants used by DrawingBoardView.
  private let cornerSize: CGFloat = 72
  private let requiredTravel: CGFloat = 30
  private let maxHorizontalDrift: CGFloat = 58
  private let resolveDistance: CGFloat = 16
  private let broadContactTravelFactor: CGFloat = 0.72
  private let surface = CGSize(width: 390, height: 844)

  // MARK: - Drawing surface coordinates

  func testDrawingSurfaceCoordinatesRoundTripAtEdgesAndCenter() {
    let sizes = [
      CGSize(width: 393, height: 852),
      CGSize(width: 430, height: 932),
      CGSize(width: 852, height: 393),
      CGSize(width: 1024, height: 1366),
    ]
    let normalizedPoints = [
      CGPoint(x: 0, y: 0),
      CGPoint(x: 0.12, y: 0.08),
      CGPoint(x: 0.5, y: 0.5),
      CGPoint(x: 0.88, y: 0.92),
      CGPoint(x: 1, y: 1),
    ]

    for size in sizes {
      for expected in normalizedPoints {
        let surfacePoint = RemoteDrawDrawingSurfaceGeometry.surfacePoint(for: expected, in: size)
        let actual = RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: surfacePoint, in: size)
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001, "size \(size)")
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001, "size \(size)")
      }
    }
  }

  func testDrawingSurfaceCoordinatesDoNotAccelerateAwayFromFinger() {
    let size = CGSize(width: 393, height: 852)
    let touches = [
      CGPoint(x: 40, y: 72),
      CGPoint(x: 196.5, y: 426),
      CGPoint(x: 353, y: 780),
    ]

    for touch in touches {
      let normalized = RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: touch, in: size)
      let rendered = RemoteDrawDrawingSurfaceGeometry.surfacePoint(for: normalized, in: size)
      XCTAssertEqual(rendered.x, touch.x, accuracy: 0.000_001)
      XCTAssertEqual(rendered.y, touch.y, accuracy: 0.000_001)
    }
  }

  func testDrawingSurfaceCoordinatesRejectInvalidSizes() {
    XCTAssertEqual(
      RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: CGPoint(x: 10, y: 20), in: .zero),
      .zero
    )
    XCTAssertEqual(
      RemoteDrawDrawingSurfaceGeometry.surfacePoint(for: CGPoint(x: 0.5, y: 0.5), in: .zero),
      .zero
    )
  }

  func testWideSurfaceAspectFitsPortraitAndLandscapeWithoutCropping() {
    let aspect: CGFloat = 16.0 / 5.0
    let portrait = RemoteDrawDrawingSurfaceGeometry.aspectFitSize(
      aspectRatio: aspect,
      in: CGSize(width: 393, height: 662)
    )
    let landscape = RemoteDrawDrawingSurfaceGeometry.aspectFitSize(
      aspectRatio: aspect,
      in: CGSize(width: 820, height: 203)
    )

    XCTAssertEqual(portrait.width, 393, accuracy: 0.000_001)
    XCTAssertEqual(portrait.height, 393 / aspect, accuracy: 0.000_001)
    XCTAssertEqual(landscape.width, 203 * aspect, accuracy: 0.000_001)
    XCTAssertEqual(landscape.height, 203, accuracy: 0.000_001)
    XCTAssertEqual(portrait.width / portrait.height, aspect, accuracy: 0.000_001)
    XCTAssertEqual(landscape.width / landscape.height, aspect, accuracy: 0.000_001)
  }

  // MARK: - Handedness

  func testHandednessResolvedSide() {
    XCTAssertEqual(RemoteDrawHandedness.automatic.resolvedSide, .right)
    XCTAssertEqual(RemoteDrawHandedness.right.resolvedSide, .right)
    XCTAssertEqual(RemoteDrawHandedness.left.resolvedSide, .left)
  }

  func testHandednessRawValueRoundTrips() {
    for handedness in RemoteDrawHandedness.allCases {
      XCTAssertEqual(RemoteDrawHandedness(rawValue: handedness.rawValue), handedness)
    }
    XCTAssertNil(RemoteDrawHandedness(rawValue: "garbage"))
  }

  // MARK: - RemoteDrawCornerSwipe

  func testBottomCornersAreControlStarts() {
    XCTAssertTrue(
      RemoteDrawCornerSwipe.isBottomCornerStart(
        CGPoint(x: 10, y: surface.height - 10), in: surface, cornerSize: cornerSize
      )
    )
    XCTAssertTrue(
      RemoteDrawCornerSwipe.isBottomCornerStart(
        CGPoint(x: surface.width - 10, y: surface.height - 10), in: surface, cornerSize: cornerSize
      )
    )
    XCTAssertFalse(
      RemoteDrawCornerSwipe.isBottomCornerStart(
        CGPoint(x: surface.width / 2, y: surface.height - 10), in: surface, cornerSize: cornerSize
      )
    )
    XCTAssertFalse(
      RemoteDrawCornerSwipe.isBottomCornerStart(
        CGPoint(x: 10, y: 10), in: surface, cornerSize: cornerSize
      )
    )
    XCTAssertFalse(
      RemoteDrawCornerSwipe.isBottomCornerStart(.zero, in: .zero, cornerSize: cornerSize)
    )
  }

  func testUpwardTravelThresholdAndBroadContactHint() {
    XCTAssertTrue(
      RemoteDrawCornerSwipe.shouldOpenControls(
        translation: CGSize(width: 0, height: -requiredTravel),
        requiredTravel: requiredTravel,
        maxHorizontalDrift: maxHorizontalDrift,
        hasBroadEdgeContact: false,
        broadContactTravelFactor: broadContactTravelFactor
      )
    )
    let reducedTravel = CGSize(width: 0, height: -requiredTravel * broadContactTravelFactor)
    XCTAssertTrue(
      RemoteDrawCornerSwipe.shouldOpenControls(
        translation: reducedTravel,
        requiredTravel: requiredTravel,
        maxHorizontalDrift: maxHorizontalDrift,
        hasBroadEdgeContact: true,
        broadContactTravelFactor: broadContactTravelFactor
      )
    )
    XCTAssertFalse(
      RemoteDrawCornerSwipe.shouldOpenControls(
        translation: reducedTravel,
        requiredTravel: requiredTravel,
        maxHorizontalDrift: maxHorizontalDrift,
        hasBroadEdgeContact: false,
        broadContactTravelFactor: broadContactTravelFactor
      )
    )
    // Broad contact alone (no travel) never opens controls.
    XCTAssertFalse(
      RemoteDrawCornerSwipe.shouldOpenControls(
        translation: .zero,
        requiredTravel: requiredTravel,
        maxHorizontalDrift: maxHorizontalDrift,
        hasBroadEdgeContact: true,
        broadContactTravelFactor: broadContactTravelFactor
      )
    )
  }

  func testCornerGestureResolution() {
    XCTAssertFalse(
      RemoteDrawCornerSwipe.shouldResolveAsDrawing(
        translation: CGSize(width: 5, height: 5),
        resolveDistance: resolveDistance,
        maxHorizontalDrift: maxHorizontalDrift
      )
    )
    XCTAssertTrue(
      RemoteDrawCornerSwipe.shouldResolveAsDrawing(
        translation: CGSize(width: maxHorizontalDrift + 1, height: 0),
        resolveDistance: resolveDistance,
        maxHorizontalDrift: maxHorizontalDrift
      )
    )
    XCTAssertTrue(
      RemoteDrawCornerSwipe.shouldResolveAsDrawing(
        translation: CGSize(width: 0, height: resolveDistance),
        resolveDistance: resolveDistance,
        maxHorizontalDrift: maxHorizontalDrift
      )
    )
    XCTAssertFalse(
      RemoteDrawCornerSwipe.shouldResolveAsDrawing(
        translation: CGSize(width: 4, height: -20),
        resolveDistance: resolveDistance,
        maxHorizontalDrift: maxHorizontalDrift
      )
    )
  }

  // MARK: - RemoteDrawRadialSolver

  private let anchors: [CGPoint] = [
    CGPoint(x: 195, y: 422),  // center
    CGPoint(x: 30, y: 400),   // left edge
    CGPoint(x: 380, y: 100),  // top right
    CGPoint(x: 20, y: 20),    // top-left corner
    CGPoint(x: 370, y: 830),  // bottom-right corner
    CGPoint(x: 195, y: 830),  // bottom edge
  ]

  func testSolverPlacesAllItemsWithoutOverlap() {
    for anchor in anchors {
      for count in 1...9 {
        let layout = RemoteDrawRadialSolver.solve(anchor: anchor, in: surface, itemCount: count)
        XCTAssertEqual(layout.itemCenters.count, count)
        for i in 0..<layout.itemCenters.count {
          for j in (i + 1)..<layout.itemCenters.count {
            let a = layout.itemCenters[i]
            let b = layout.itemCenters[j]
            let distance = hypot(a.x - b.x, a.y - b.y)
            XCTAssertGreaterThanOrEqual(
              distance,
              RemoteDrawRadialMetrics.itemDiameter - 0.5,
              "anchor \(anchor) count \(count) items \(i)/\(j)"
            )
          }
        }
      }
    }
  }

  func testSolverKeepsItemsOnScreen() {
    let margin = RemoteDrawRadialMetrics.itemDiameter / 2
    for anchor in anchors {
      for count in [1, 4, 8, 9] {
        let layout = RemoteDrawRadialSolver.solve(anchor: anchor, in: surface, itemCount: count)
        for center in layout.itemCenters {
          XCTAssertGreaterThanOrEqual(center.x, margin - 1, "anchor \(anchor) count \(count)")
          XCTAssertLessThanOrEqual(center.x, surface.width - margin + 1, "anchor \(anchor) count \(count)")
          XCTAssertGreaterThanOrEqual(center.y, margin - 1, "anchor \(anchor) count \(count)")
          XCTAssertLessThanOrEqual(center.y, surface.height - margin + 1, "anchor \(anchor) count \(count)")
        }
      }
    }
  }

  func testSolverWalksHubInwardFromCorners() {
    let layout = RemoteDrawRadialSolver.solve(
      anchor: CGPoint(x: 370, y: 830), in: surface, itemCount: 9
    )
    // The corner press cannot fit nine non-overlapping items, so the hub must
    // move toward the screen center.
    XCTAssertLessThan(layout.anchor.x, 366)
    XCTAssertLessThan(layout.anchor.y, 820)
  }

  func testSolverGathersItemsTowardOpenSpace() {
    let nearLeft = RemoteDrawRadialSolver.solve(
      anchor: CGPoint(x: 30, y: 400), in: surface, itemCount: 6
    )
    let meanX = nearLeft.itemCenters.map(\.x).reduce(0, +) / 6
    XCTAssertGreaterThan(meanX, nearLeft.anchor.x, "items should open rightward from the left edge")

    let nearBottom = RemoteDrawRadialSolver.solve(
      anchor: CGPoint(x: 195, y: 830), in: surface, itemCount: 6
    )
    let meanY = nearBottom.itemCenters.map(\.y).reduce(0, +) / 6
    XCTAssertLessThan(meanY, nearBottom.anchor.y, "items should open upward from the bottom edge")
  }

  func testHighlightUsesNearestItemWithDeadZoneAndSlop() {
    let layout = RemoteDrawRadialSolver.solve(
      anchor: CGPoint(x: 195, y: 422), in: surface, itemCount: 5
    )
    for (index, center) in layout.itemCenters.enumerated() {
      XCTAssertEqual(layout.highlightedIndex(for: center), index)
    }
    XCTAssertNil(layout.highlightedIndex(for: layout.anchor))
    XCTAssertNil(
      layout.highlightedIndex(
        for: CGPoint(x: layout.anchor.x + 10, y: layout.anchor.y - 10)
      )
    )
    XCTAssertNil(layout.highlightedIndex(for: CGPoint(x: 0, y: 0)))
  }

  // MARK: - Touch classification

  func testPalmClassificationByContactRadius() {
    XCTAssertFalse(RemoteDrawTouchClassifier.isPalm(majorRadius: 12))
    XCTAssertFalse(RemoteDrawTouchClassifier.isPalm(majorRadius: RemoteDrawTouchClassifier.palmRadiusThreshold - 1))
    XCTAssertTrue(RemoteDrawTouchClassifier.isPalm(majorRadius: RemoteDrawTouchClassifier.palmRadiusThreshold))
    XCTAssertTrue(RemoteDrawTouchClassifier.isPalm(majorRadius: 60))
  }

  func testNearestSampleMatching() {
    let finger = RemoteDrawTouchSample(location: CGPoint(x: 100, y: 100), majorRadius: 14)
    let palm = RemoteDrawTouchSample(location: CGPoint(x: 300, y: 700), majorRadius: 48, isPalm: true)
    let samples = [finger, palm]
    XCTAssertEqual(
      RemoteDrawTouchSampleMatcher.nearestSample(to: CGPoint(x: 110, y: 95), in: samples),
      finger
    )
    XCTAssertEqual(
      RemoteDrawTouchSampleMatcher.nearestSample(to: CGPoint(x: 290, y: 710), in: samples),
      palm
    )
    XCTAssertNil(
      RemoteDrawTouchSampleMatcher.nearestSample(to: CGPoint(x: 200, y: 400), in: samples)
    )
    XCTAssertNil(RemoteDrawTouchSampleMatcher.nearestSample(to: .zero, in: []))
  }

  // MARK: - Pencil tilt conversion

  func testVerticalPencilHasNoTilt() {
    let tilt = RemoteDrawPencilTilt.tilt(azimuthRadians: 1.2, altitudeRadians: .pi / 2)
    XCTAssertEqual(tilt.tiltX, 0, accuracy: 0.01)
    XCTAssertEqual(tilt.tiltY, 0, accuracy: 0.01)
  }

  func testTiltFollowsAzimuthAtFortyFiveDegrees() {
    let alongX = RemoteDrawPencilTilt.tilt(azimuthRadians: 0, altitudeRadians: .pi / 4)
    XCTAssertEqual(alongX.tiltX, 45, accuracy: 0.01)
    XCTAssertEqual(alongX.tiltY, 0, accuracy: 0.01)

    let alongY = RemoteDrawPencilTilt.tilt(azimuthRadians: .pi / 2, altitudeRadians: .pi / 4)
    XCTAssertEqual(alongY.tiltX, 0, accuracy: 0.01)
    XCTAssertEqual(alongY.tiltY, 45, accuracy: 0.01)

    let negativeX = RemoteDrawPencilTilt.tilt(azimuthRadians: .pi, altitudeRadians: .pi / 4)
    XCTAssertEqual(negativeX.tiltX, -45, accuracy: 0.01)
  }

  func testFlatPencilTiltStaysBounded() {
    let tilt = RemoteDrawPencilTilt.tilt(azimuthRadians: 0, altitudeRadians: 0)
    XCTAssertLessThanOrEqual(tilt.tiltX, 90)
    XCTAssertGreaterThan(tilt.tiltX, 89)
  }
}
