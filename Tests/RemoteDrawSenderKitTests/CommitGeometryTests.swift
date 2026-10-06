import XCTest

@testable import RemoteDrawSenderKit

/// What a finished gesture becomes on the wire.
///
/// Both rules here are behaviour the first-party board shipped for years before
/// the SDK existed, and both were missing from ``RemoteDrawSenderSession/end``
/// until Stage 3 moved the app onto it. They are tested against the *tool*
/// rather than against a point count, because a point count cannot tell a
/// rectangle drawn corner-to-corner from one drawn the long way round — which is
/// the whole difference the first rule exists to remove.
final class CommitGeometryTests: XCTestCase {
  private func point(_ x: Double, _ y: Double, t: Double = 0) -> RemoteDrawNormalizedPoint {
    RemoteDrawNormalizedPoint(x: x, y: y, t: t, pressure: 0.5, tiltX: 10, tiltY: -10)
  }

  /// A drag that wanders on its way to the far corner.
  ///
  /// The point of the fixture: its *extent* is much larger than the box between
  /// its first and last sample, so committing the whole buffer stores a
  /// different rectangle from the one the person dragged out.
  private var wanderingDrag: [RemoteDrawNormalizedPoint] {
    [
      point(0.2, 0.2, t: 0),
      point(0.9, 0.1, t: 10),
      point(0.95, 0.8, t: 20),
      point(0.1, 0.75, t: 30),
      point(0.6, 0.6, t: 40),
    ]
  }

  // MARK: A shape is its endpoints

  func testShapeToolsCommitTheirEndpointsAndNotTheWander() {
    for tool: RemoteDrawTool in [.line, .arrow, .rectangle, .ellipse] {
      let committed = RemoteDrawCommitGeometry.forCommit(wanderingDrag, tool: tool)
      XCTAssertEqual(committed.count, 2, "\(tool.rawValue) should commit two points")
      XCTAssertEqual(committed.first?.x, 0.2)
      XCTAssertEqual(committed.first?.y, 0.2)
      XCTAssertEqual(committed.last?.x, 0.6)
      XCTAssertEqual(committed.last?.y, 0.6)
    }
  }

  /// The reason the rule is about geometry and not about bytes.
  ///
  /// `rectangle` and `ellipse` paint from the axis-aligned bounding box of their
  /// points, so the wander does not merely cost payload — it changes the shape.
  func testTheWanderWouldOtherwiseChangeTheRectangle() {
    let raw = wanderingDrag
    let committed = RemoteDrawCommitGeometry.forCommit(raw, tool: .rectangle)
    let rawWidth = (raw.map(\.x).max() ?? 0) - (raw.map(\.x).min() ?? 0)
    let committedWidth = abs((committed.last?.x ?? 0) - (committed.first?.x ?? 0))
    XCTAssertGreaterThan(
      rawWidth, committedWidth + 0.4,
      "The fixture must actually distinguish the two boxes, or this proves nothing.")
  }

  func testFreehandKeepsEveryPointItWasGiven() {
    for tool: RemoteDrawTool in [.freehand, .auto] {
      XCTAssertEqual(RemoteDrawCommitGeometry.forCommit(wanderingDrag, tool: tool), wanderingDrag)
    }
  }

  func testPointAndTextCommitOneSample() {
    for tool: RemoteDrawTool in [.point, .text] {
      let committed = RemoteDrawCommitGeometry.forCommit(wanderingDrag, tool: tool)
      XCTAssertEqual(committed.count, 1)
      XCTAssertEqual(committed.first?.x, 0.2)
    }
  }

  // MARK: A tap still leaves a mark

  func testATapIsPaddedIntoADot() {
    let committed = RemoteDrawCommitGeometry.forCommit([point(0.4, 0.4, t: 7)], tool: .freehand)
    XCTAssertEqual(committed.count, 2)
    XCTAssertEqual(committed[0].x, 0.4)
    XCTAssertEqual(committed[1].x, 0.4 + RemoteDrawCommitGeometry.dotOffset, accuracy: 1e-12)
    XCTAssertEqual(committed[1].y, 0.4 + RemoteDrawCommitGeometry.dotOffset, accuracy: 1e-12)
    // The dynamics carry, so the dot is the width the finger pressed. A
    // fabricated pressure would change the mark.
    XCTAssertEqual(committed[1].pressure, 0.5)
    XCTAssertEqual(committed[1].tiltX, 10)
    // One millisecond later, so velocity reads an interval rather than dividing
    // by zero.
    XCTAssertEqual(committed[1].t, 8)
  }

  func testThePaddedSampleStaysInsideTheSurface() {
    let committed = RemoteDrawCommitGeometry.forCommit([point(1, 1)], tool: .freehand)
    XCTAssertEqual(committed[1].x, 1)
    XCTAssertEqual(committed[1].y, 1)
  }

  func testAShapeDrawnWithoutMovingIsAlsoPadded() {
    // The order the two rules run in: reducing a one-sample line to
    // `[first, last]` is what *creates* the single-point case the padding
    // exists for.
    let committed = RemoteDrawCommitGeometry.forCommit([point(0.3, 0.3)], tool: .line)
    XCTAssertEqual(committed.count, 2)
    // Displaced, not duplicated. `count == 2` alone passes for the wrong
    // reason: `[first, last]` of a one-sample buffer is the same point twice,
    // which clears the two-point minimum and draws nothing.
    XCTAssertEqual(committed[1].x, 0.3 + RemoteDrawCommitGeometry.dotOffset, accuracy: 1e-12)
    XCTAssertNotEqual(committed[0].x, committed[1].x)
  }

  func testPointAndTextAreNeverPadded() {
    for tool: RemoteDrawTool in [.point, .text] {
      XCTAssertEqual(
        RemoteDrawCommitGeometry.forCommit([point(0.3, 0.3)], tool: tool).count, 1,
        "\(tool.rawValue) is defined as one sample")
    }
  }

  func testAnEmptyBufferStaysEmpty() {
    for tool: RemoteDrawTool in RemoteDrawTool.allCases {
      let empty: [RemoteDrawNormalizedPoint] = []
      XCTAssertTrue(RemoteDrawCommitGeometry.forCommit(empty, tool: tool).isEmpty)
    }
  }
}
