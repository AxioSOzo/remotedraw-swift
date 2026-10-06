import XCTest
@testable import RemoteDrawInk

final class ToothRasterBudgetTests: XCTestCase {
  func testExtremeZoomBoundsPixelsWithoutShrinkingCanonicalSheet() throws {
    for extent in [1.0, 512, 1024, 4096, 40_000, 1_000_000] {
      let plan = try XCTUnwrap(RemoteDrawInk.ToothRasterPlan(extent: extent))
      XCTAssertLessThanOrEqual(plan.side, 1024)
      XCTAssertLessThanOrEqual(plan.side * plan.side, 1_048_576)
      XCTAssertEqual(plan.logicalExtent, extent)
      XCTAssertEqual(Double(plan.side) * plan.unitsPerPixel, extent, accuracy: 1e-8)
    }
  }

  func testInvalidExtentsCannotTrapOrAllocate() {
    for extent in [Double.nan, .infinity, -.infinity, -1, 0, .greatestFiniteMagnitude] {
      XCTAssertNil(RemoteDrawInk.ToothRasterPlan(extent: extent))
    }
  }

  func testContinuousZoomBoundsCachedAndQueuedMasks() {
    var budget = RemoteDrawInk.ToothCacheBudget()
    for index in 0..<1000 {
      let key = "zoom-\(index)"
      XCTAssertTrue(budget.begin(key))
      XCTAssertFalse(budget.begin(key))
      _ = budget.finish(key)
      XCTAssertLessThanOrEqual(budget.completed.count, 12)
      XCTAssertTrue(budget.pending.isEmpty)
    }
    XCTAssertFalse(budget.begin("zoom-999"))
    for index in 0..<4 { XCTAssertTrue(budget.begin("pending-\(index)")) }
    XCTAssertFalse(budget.begin("queue-overflow"))
    XCTAssertEqual(budget.pending.count, 4)
    _ = budget.finish("pending-0")
    XCTAssertTrue(budget.begin("queue-overflow"))
  }
}
