import SwiftUI
import XCTest
@testable import RemoteDrawInk

final class NibTipTests: XCTestCase {
  func testFlatNibEndsAtContactWhileRoundNibExtendsByItsRadius() throws {
    let points = [CGPoint(x: 20, y: 40), CGPoint(x: 50, y: 40), CGPoint(x: 80, y: 40)]
    let flat = try XCTUnwrap(InkRenderer.ribbonPath(
      centerline: points, halfWidths: [4, 4, 4], flatNib: true))
    let round = try XCTUnwrap(InkRenderer.ribbonPath(
      centerline: points, halfWidths: [4, 4, 4]))
    XCTAssertEqual(flat.boundingRect.minX, 20, accuracy: 0.001)
    XCTAssertEqual(flat.boundingRect.maxX, 80, accuracy: 0.001)
    XCTAssertEqual(round.boundingRect.minX, 16, accuracy: 0.001)
    XCTAssertEqual(round.boundingRect.maxX, 84, accuracy: 0.001)
  }

  func testShortNibRetainsItsWidthBeforeThirdSample() throws {
    let points = [CGPoint(x: 20, y: 40), CGPoint(x: 80, y: 40)]
    let short = try XCTUnwrap(InkRenderer.ribbonPath(
      centerline: points, halfWidths: [1.5, 1.5], flatNib: true, allowShortAxis: true))
    let sampled = try XCTUnwrap(InkRenderer.ribbonPath(
      centerline: [points[0], CGPoint(x: 50, y: 40), points[1]],
      halfWidths: [1.5, 1.5, 1.5], flatNib: true, allowShortAxis: true))
    XCTAssertEqual(short.boundingRect, sampled.boundingRect)
    XCTAssertEqual(short.boundingRect.height, 3, accuracy: 0.001)
    // Keep the pressure/velocity-only two-point fallback unchanged.
    XCTAssertNil(InkRenderer.ribbonPath(centerline: points, halfWidths: [1.5, 1.5]))
  }
}
