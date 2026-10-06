#if canImport(UIKit) && !os(watchOS)
import XCTest
@testable import RemoteDrawSenderKit

final class SurfacePuckTests: XCTestCase {
  func testTheSDKArcIsTheSixteenInstrumentsAndThreeTiers() {
    let menu = RemoteDrawSurfacePuck.menu(kind: .pencil, color: "#1f7a8c", thickness: 10,
      tool: .line, tools: [.auto, .freehand, .line, .rectangle, .text])
    XCTAssertEqual(menu.pens.map(\.id), RemoteDrawPuckDefaults.pens.map { "tip.\($0.rawValue)" })
    XCTAssertEqual(menu.pens.first { $0.isCurrent }?.id, "tip.pencil")
    XCTAssertEqual(menu.pens.first?.detail, "Pens")
    XCTAssertEqual(menu.widths.map(\.id), ["size.2", "size.4", "size.6", "size.10", "size.16"])
    XCTAssertEqual(menu.widths.first { $0.isCurrent }?.id, "size.10")
    XCTAssertEqual(menu.colors.count, 7, "six swatches and the palette well")
    XCTAssertEqual(menu.colors.last?.id, "color.more")
    XCTAssertEqual(menu.colors.first { $0.isCurrent }?.id, "color.#1f7a8c")
    XCTAssertEqual(menu.shapes.map(\.id),
      ["shape.auto", "shape.freehand", "shape.line", "shape.rectangle", "shape.more"])
    XCTAssertEqual(menu.shapes.first { $0.isCurrent }?.id, "shape.line")
    XCTAssertTrue(menu.isPresentable)
  }

  func testUngrantedShapesAreOmitted() {
    let menu = RemoteDrawSurfacePuck.menu(kind: .ink, color: "#151512", thickness: 6,
      tool: .freehand, tools: [.freehand])
    XCTAssertEqual(menu.shapes.map(\.id), ["shape.freehand", "shape.more"])
  }

  func testPointOnlyBoardShowsOnlyThePointTool() {
    let menu = RemoteDrawSurfacePuck.menu(kind: .ink, color: "#151512", thickness: 6,
      tool: .point, tools: [.point])
    XCTAssertEqual(menu.pens.map(\.id), ["shape.point"])
    XCTAssertTrue(menu.widths.isEmpty)
    XCTAssertEqual(menu.shapes.map(\.id), ["shape.more"])
    XCTAssertFalse(RemoteDrawSurfacePuck.menu(kind: .ink, color: "#151512", thickness: 6,
      tool: .auto, tools: []).isPresentable)
  }
}
#endif
