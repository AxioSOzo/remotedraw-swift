import XCTest
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
@testable import RemoteDrawSenderKit

@MainActor
final class ImageParityTests: XCTestCase {
  private let wire = #"{"id":"image","type":"image","points":[{"x":0.2,"y":0.3},{"x":0.8,"y":0.7}],"imageAssetId":"asset","imageMimeType":"image/png","imageUrl":"https://assets.example/image.png"}"#

  func testWireRetainsAssetsAndOldInkStillDecodes() throws {
    let drawing = try JSONDecoder().decode(RemoteDrawDrawing.self, from: Data(wire.utf8))
    XCTAssertEqual(drawing.imageAssetId, "asset")
    XCTAssertEqual(drawing.imageMimeType, "image/png")
    XCTAssertEqual(drawing.imageUrl, "https://assets.example/image.png")
    let ink = try JSONDecoder().decode(RemoteDrawDrawing.self,
      from: Data(#"{"id":"ink","type":"line","points":[{"x":0,"y":0},{"x":1,"y":1}]}"#.utf8))
    XCTAssertNil(ink.imageUrl)
  }

  func testImageProjectionPreservesAllCornersAt45And90Degrees() throws {
    for angle in [0.0, 45.0, 90.0] {
      let radians = angle * .pi / 180
      let space = RemoteDrawStrokeSpace(isBoardSpace: true, unproject: { point in
        .init(x: 0.5 + (point.x - 0.5) * cos(radians) - (point.y - 0.5) * sin(radians),
          y: 0.5 + (point.x - 0.5) * sin(radians) + (point.y - 0.5) * cos(radians))
      })
      let stroke = RemoteDrawStroke(id: "image", type: "image",
        points: [.init(x: 0.2, y: 0.3), .init(x: 0.8, y: 0.7)],
        imageUrl: "https://assets.example/image.png", isBoardSpace: true)
      let mark = try XCTUnwrap(RemoteDrawBoardMark(stroke, space: space))
      XCTAssertEqual(mark.points.count, 4)
      XCTAssertEqual(mark.imageUrl, stroke.imageUrl)
      let transform = try XCTUnwrap(RemoteDrawImageGeometry.placement(mark.points, size: CGSize(width: 1000, height: 1000)))
      let br = CGPoint(x: 1, y: 1).applying(transform)
      XCTAssertEqual(br.x, mark.points[2].x * 1000, accuracy: 0.00001)
      XCTAssertEqual(br.y, mark.points[2].y * 1000, accuracy: 0.00001)
      XCTAssertEqual(hypot(transform.a, transform.b), 600, accuracy: 0.00001)
      XCTAssertEqual(hypot(transform.c, transform.d), 400, accuracy: 0.00001)
    }
  }

  func testCullingKeepsSurroundingImageButDropsOffscreenOriginal() {
    XCTAssertTrue(RemoteDrawImageGeometry.visible(RemoteDrawImageGeometry.corners([.init(x: -2,y: -2), .init(x: 2,y: 2)])))
    XCTAssertFalse(RemoteDrawImageGeometry.visible(RemoteDrawImageGeometry.corners([.init(x: 2,y: 2), .init(x: 3,y: 3)])))
    XCTAssertTrue(RemoteDrawImageGeometry.corners([.init(x: 0,y: 0), .init(x: .infinity,y: 1)]).isEmpty)
  }

  func testDecodeDownsamplesLargeOriginalAndRejectsCorruptData() throws {
    let context = try XCTUnwrap(CGContext(data: nil, width: 4096, height: 2048, bitsPerComponent: 8,
      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4096, height: 2048))
    let original = try XCTUnwrap(context.makeImage())
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, original, nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    let decoded = try RemoteDrawBoardImageStore.decode(data as Data, maxPixelSize: 512)
    XCTAssertEqual(decoded.image.width, 512)
    XCTAssertEqual(decoded.image.height, 256)
    XCTAssertThrowsError(try RemoteDrawBoardImageStore.decode(Data("bad image".utf8), maxPixelSize: 512))
  }

  func testSectionZoomRequestsMoreImagePixelsWithABoundedCeiling() {
    let corners = RemoteDrawImageGeometry.corners([.init(x: 0.1, y: 0.1), .init(x: 0.3, y: 0.3)])
    let size = CGSize(width: 1000, height: 1000)
    XCTAssertEqual(RemoteDrawImageGeometry.pixelBudget(corners, size: size), 512)
    XCTAssertEqual(RemoteDrawImageGeometry.pixelBudget(corners, size: size, scale: 4), 2048)
    XCTAssertEqual(RemoteDrawImageGeometry.pixelBudget(corners, size: size, scale: 100), 2048)
  }

  func testHostOwnedRefreshDoesNotStartADuplicatePoll() async throws {
    let transport = FakeTransport()
    let clock = ManualPollClock()
    // Metadata maintenance adopts grants. The fixture must not revoke the
    // very viewExisting permission whose manual refresh this test exercises.
    transport.sessionResult = .success(RemoteDrawSessionResponse(senderId: "sender_1",
      session: .stub(capabilities: ["viewExisting"]), capabilities: ["viewExisting"], lastSequence: nil))
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_host", transport: transport,
      capabilities: ["viewExisting"], automaticallyRefreshDrawings: false, pollClock: clock)
    defer { session.stopLocally() }
    await session.markActive()
    await clock.settle()
    XCTAssertTrue(session.capabilities.contains(.viewExisting))
    XCTAssertEqual(transport.callCount(.drawings), 0)
    _ = try await session.refreshDrawings()
    XCTAssertEqual(transport.callCount(.drawings), 1)
    await session.markInactive()
  }

  func testFailedLoadIsExplicitAndReleasedAfterImageLeavesViewport() async {
    let store = RemoteDrawBoardImageStore()
    let invalid = RemoteDrawImageRequest(url: "invalid://image", maxPixelSize: 256)
    await store.load([invalid])
    XCTAssertTrue(store.failures.contains(invalid))
    XCTAssertTrue(store.images.isEmpty)
    await store.load([])
    XCTAssertTrue(store.failures.isEmpty)
  }

  func testMissingImageRendersABoxAndKeepsInkAboveIt() throws {
    let image = RemoteDrawBoardMark(id: "image", type: "image", points: [.init(x: 0.1,y: 0.1), .init(x: 0.9,y: 0.9)])
    let ink = RemoteDrawBoardMark(id: "ink", type: "line", points: [.init(x: 0.2,y: 0.2), .init(x: 0.8,y: 0.2)], style: .init(kind: .whiteboardMarker, color: "#000000"), lineWidth: 8)
    let renderer = ImageRenderer(content: RemoteDrawBoardCanvas(ground: .whiteboard,
      sections: [.init(marks: [image, ink])]).frame(width: 100,height: 100))
    let pixels = try XCTUnwrap(renderer.cgImage)
    var bytes = [UInt8](repeating: 0, count: 100 * 100 * 4)
    let context = try XCTUnwrap(CGContext(data: &bytes, width: 100, height: 100, bitsPerComponent: 8,
      bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.draw(pixels, in: CGRect(x: 0,y: 0,width: 100,height: 100))
    // The placeholder fills the image interior, not the diagonal its two wire corners describe.
    let interior = (35 * 100 + 35) * 4
    XCTAssertLessThan(bytes[interior], 245)
    XCTAssertGreaterThan(bytes[interior], 200)
    // Ink survives above the image regardless of bitmap orientation.
    let darkPixels = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 80 && bytes[$0 + 3] > 0 }.count
    XCTAssertGreaterThan(darkPixels, 200)
  }

  func testRefreshPopulatesMixedBoardAndNeverKeepsHiddenImages() async throws {
    let transport = FakeTransport()
    transport.joinResult = .success(RemoteDrawJoinResponse(senderToken: "rd_send_image", capabilities: ["viewExisting"]))
    transport.sessionResult = .success(RemoteDrawSessionResponse(senderId: "sender_1",
      session: .stub(capabilities: ["viewExisting"]), capabilities: ["viewExisting"], lastSequence: nil))
    transport.drawingsJSON = "{\"items\":[\(wire),{\"id\":\"ink\",\"type\":\"line\",\"points\":[{\"x\":0,\"y\":0},{\"x\":1,\"y\":1}]},{\"id\":\"hidden\",\"type\":\"image\",\"hidden\":true,\"points\":[]}]}"
    let session = try await RemoteDrawSenderSession.join(token: .join("rd_join_image"), transport: transport)
    defer { session.stopLocally() }
    _ = try await session.refreshDrawings()
    XCTAssertEqual(session.strokes.map(\.id), ["image", "ink"])
    XCTAssertEqual(session.strokes.first?.imageUrl, "https://assets.example/image.png")
    XCTAssertTrue(session.strokes.allSatisfy(\.isBoardSpace))
    await session.markInactive()
  }
}
