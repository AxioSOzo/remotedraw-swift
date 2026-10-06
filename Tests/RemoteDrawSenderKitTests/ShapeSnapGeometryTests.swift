import XCTest
@testable import RemoteDrawSenderKit

/// The chip placement rules, the same cases `tests/api/shapeSnapPlacement.test.ts`
/// runs against the web copy.
final class ShapeSnapGeometryTests: XCTestCase {
  private let pad = CGSize(width: 390, height: 844)
  private let chip = CGSize(width: 150, height: 48)
  /// The control cluster floating in the bottom-right corner.
  private var reserve: CGRect {
    CGRect(x: pad.width - 216, y: pad.height - 90, width: 216, height: 90)
  }

  func testSitsCentredJustBelowAShapeInTheMiddle() {
    let anchor = CGRect(x: 100, y: 300, width: 120, height: 80)
    let origin = RemoteDrawShapeSnapGeometry.chipOrigin(pad: pad, anchor: anchor, chip: chip, avoid: nil)
    XCTAssertEqual(origin, CGPoint(x: 100 + 60 - 75, y: 300 + 80 + 12))
  }

  func testMovesAboveAShapeAlongTheBottomEdge() {
    let anchor = CGRect(x: 40, y: 760, width: 120, height: 70)
    let origin = RemoteDrawShapeSnapGeometry.chipOrigin(pad: pad, anchor: anchor, chip: chip, avoid: nil)
    XCTAssertEqual(origin.y, 760 - 12 - 48)
  }

  func testNeverLeavesThePadHorizontally() {
    let right = RemoteDrawShapeSnapGeometry.chipOrigin(
      pad: pad, anchor: CGRect(x: 360, y: 200, width: 60, height: 60), chip: chip, avoid: nil)
    XCTAssertLessThanOrEqual(right.x + chip.width, pad.width - 10)
    let left = RemoteDrawShapeSnapGeometry.chipOrigin(
      pad: pad, anchor: CGRect(x: -30, y: 200, width: 60, height: 60), chip: chip, avoid: nil)
    XCTAssertEqual(left.x, 10)
  }

  func testStepsAboveWhenTheBelowSlotLandsOnTheControls() {
    let anchor = CGRect(x: 260, y: 640, width: 100, height: 90)
    let origin = RemoteDrawShapeSnapGeometry.chipOrigin(pad: pad, anchor: anchor, chip: chip, avoid: reserve)
    XCTAssertFalse(CGRect(origin: origin, size: chip).intersects(reserve))
    XCTAssertEqual(origin.y, anchor.minY - 12 - chip.height)
  }

  func testNudgesBesideTheControlsWhenNeitherSlotIsClear() {
    let anchor = CGRect(x: 300, y: 720, width: 80, height: 120)
    let origin = RemoteDrawShapeSnapGeometry.chipOrigin(pad: pad, anchor: anchor, chip: chip, avoid: reserve)
    XCTAssertFalse(CGRect(origin: origin, size: chip).intersects(reserve))
    XCTAssertGreaterThanOrEqual(origin.x, 10)
    XCTAssertLessThanOrEqual(origin.y + chip.height, pad.height - 10)
  }

  func testLeftHandedClusterPushesTheChipRight() {
    let leftReserve = CGRect(x: 0, y: pad.height - 90, width: 216, height: 90)
    let anchor = CGRect(x: 10, y: 720, width: 80, height: 120)
    let origin = RemoteDrawShapeSnapGeometry.chipOrigin(pad: pad, anchor: anchor, chip: chip, avoid: leftReserve)
    XCTAssertFalse(CGRect(origin: origin, size: chip).intersects(leftReserve))
    XCTAssertLessThanOrEqual(origin.x + chip.width, pad.width - 10)
  }

  func testAnchorGrowsByHalfTheInkAndOutlineFollowsTheShape() {
    let points = [
      RemoteDrawNormalizedPoint(x: 0.2, y: 0.3), RemoteDrawNormalizedPoint(x: 0.6, y: 0.5),
    ]
    let size = CGSize(width: 400, height: 800)
    let anchor = RemoteDrawShapeSnapGeometry.anchorRect(type: "rectangle", points: points, in: size, inkWidth: 6)
    XCTAssertEqual(anchor, CGRect(x: 80 - 3, y: 240 - 3, width: 160 + 6, height: 160 + 6))
    let outline = RemoteDrawShapeSnapGeometry.outlinePath(type: "rectangle", points: points, in: size)
    XCTAssertEqual(outline.boundingRect, CGRect(x: 80, y: 240, width: 160, height: 160))
    let line = RemoteDrawShapeSnapGeometry.outlinePath(type: "line", points: points, in: size)
    XCTAssertEqual(line.boundingRect, CGRect(x: 80, y: 240, width: 160, height: 160))
    XCTAssertTrue(RemoteDrawShapeSnapGeometry.outlinePath(type: "line", points: [], in: size).isEmpty)
    XCTAssertEqual(RemoteDrawShapeSnapGeometry.shapeName(for: "ellipse"), "Ellipse")
    XCTAssertEqual(RemoteDrawShapeSnapGeometry.shapeName(for: "squiggle"), "Shape")
  }
}
