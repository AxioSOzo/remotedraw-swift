import XCTest
@testable import RemoteDrawReceiverKit

final class ReceiverVisibilityTests: XCTestCase {
  func testHiddenAndUnsupportedImageElementsAreNotPaintedAsInk() throws {
    let drawings = try JSONDecoder().decode([RemoteDrawReceiverDrawing].self, from: Data(#"[{"id":"visible","type":"freehand","points":[]},{"id":"hidden","type":"line","hidden":true,"points":[]},{"id":"image","type":"image","points":[]}]"#.utf8))
    let snapshot = RemoteDrawReceiverSnapshot(drawings: drawings)
    XCTAssertEqual(snapshot.visibleInkDrawings.map(\.id), ["visible"])
    XCTAssertEqual(snapshot.drawings.count, 3)
  }

  func testActiveTokenDoesNotImplyPresentPhone() throws {
    let now = Date(timeIntervalSince1970: 1000)
    func sender(_ fields: String) throws -> RemoteDrawReceiverSenderRecord {
      try JSONDecoder().decode(RemoteDrawReceiverSenderRecord.self, from: Data("{\"id\":\"s\",\"status\":\"active\",\(fields)}".utf8))
    }
    XCTAssertFalse(try sender(#""presence":"stale","lastSeenAt":1000000"#).isPresent(at: now))
    XCTAssertFalse(try sender(#""presence":"present","lastSeenAt":939999"#).isPresent(at: now))
    XCTAssertTrue(try sender(#""presence":"present","lastSeenAt":940000"#).isPresent(at: now))
  }
}
