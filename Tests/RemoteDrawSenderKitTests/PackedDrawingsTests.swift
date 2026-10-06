import XCTest

@testable import RemoteDrawSenderKit

/// `/v1/sender/drawings` with `encoding: "packed"`: the SDK asks for it, reads
/// either dialect, and publishes the plain one to hosts.
final class PackedDrawingsTests: XCTestCase {
  private let stroke = (0..<24).map {
    RemoteDrawNormalizedPoint(x: Double($0) / 30, y: 0.5, t: Double($0) * 8, pressure: 0.5)
  }

  private func decode(_ json: String) throws -> RemoteDrawDrawingsResponse {
    try JSONDecoder().decode(RemoteDrawDrawingsResponse.self, from: Data(json.utf8))
  }

  func testAPackedAnswerDecodesToTheCodecsPoints() throws {
    let packed = PointCodec.pack(stroke)
    let response = try decode(
      #"{"session":null,"encoding":"packed","items":[{"id":"a","type":"freehand","packedPoints":"\#(packed)"},{"id":"b","type":"line","points":[{"x":1.5,"y":2}]}]}"#
    )
    XCTAssertEqual(response.items[0].points, try PointCodec.unpack(packed))
    XCTAssertEqual(response.items[1].points, [RemoteDrawNormalizedPoint(x: 1.5, y: 2)])
  }

  func testThePayloadHostsDecodeIsAlwaysPlain() throws {
    struct HostDrawing: Decodable { let id: String; let points: [RemoteDrawNormalizedPoint]; let locked: Bool? }
    struct HostSnapshot: Decodable { let items: [HostDrawing] }
    struct Marker: Decodable { let encoding: String? }
    let packed = PointCodec.pack(stroke)
    let response = try decode(
      #"{"encoding":"packed","items":[{"id":"a","type":"freehand","locked":true,"packedPoints":"\#(packed)"}]}"#
    )
    let payload = try XCTUnwrap(response.payload)
    let host = try payload.decode(HostSnapshot.self)
    XCTAssertEqual(host.items[0].points, try PointCodec.unpack(packed))
    XCTAssertEqual(host.items[0].locked, true)
    XCTAssertNil(try payload.decode(Marker.self).encoding)
  }

  func testAnOlderServersPlainAnswerIsUnchanged() throws {
    let json = #"{"items":[{"id":"a","type":"freehand","points":[{"x":0.25,"y":0.5}]}]}"#
    let response = try decode(json)
    XCTAssertEqual(response.items[0].points, [RemoteDrawNormalizedPoint(x: 0.25, y: 0.5)])
    let plain = try decode(json).payload
    XCTAssertEqual(response.payload, plain)
  }

  func testACorruptStreamCostsOneElementNotTheBoard() throws {
    let response = try decode(
      #"{"encoding":"packed","items":[{"id":"bad","type":"freehand","packedPoints":"!!!"},{"id":"ok","type":"freehand","points":[{"x":0.1,"y":0.1}]}]}"#
    )
    XCTAssertEqual(response.items.map(\.id), ["bad", "ok"])
    XCTAssertEqual(response.items[0].points, [])
  }

  func testAnItemWithNoPointsAtAllIsStillAnError() {
    XCTAssertThrowsError(try decode(#"{"items":[{"id":"a","type":"freehand"}]}"#))
  }
}
