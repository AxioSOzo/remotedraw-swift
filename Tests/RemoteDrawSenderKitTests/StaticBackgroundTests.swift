import XCTest
import CoreGraphics
@testable import RemoteDrawSenderKit

final class StaticBackgroundTests: XCTestCase {
  private func descriptor(version: Int = 1) throws -> RemoteDrawStaticBackground {
    try JSONDecoder().decode(RemoteDrawStaticBackground.self, from: Data("""
      {"version":\(version),"image":{"url":"https://example.com/image.png","mimeType":"image/png","pixelWidth":800,"pixelHeight":600},"region":{"minX":0.2,"minY":0.3,"maxX":0.8,"maxY":0.7},"backdrop":"#123456","opening":{"fit":"contain"},"interaction":{"pan":true,"zoom":false,"overzoom":2},"northUp":true,"publishedAt":1000,"expiresAt":2000}
      """.utf8))
  }

  func testTargetDecodesStaticAndOldSessions() throws {
    let value = try descriptor()
    XCTAssertEqual(value.interaction.overzoom, 2)
    XCTAssertFalse(value.interaction.zoom)
    XCTAssertEqual(value.region.corners.count, 4)
    let old = try JSONDecoder().decode(RemoteDrawTarget.self, from: Data(#"{"kind":"image"}"#.utf8))
    XCTAssertNil(old.staticBackground)
    let target = try JSONDecoder().decode(RemoteDrawTarget.self, from: Data(#"{"kind":"image","static":{"future":true}}"#.utf8))
    XCTAssertNil(target.staticBackground)
    XCTAssertNotEqual(value, try descriptor(version: 2))
  }

  func testPartialBoardPlacementKeepsOffscreenCorners() throws {
    let value = try descriptor()
    let projection = RemoteDrawProjection(centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.4, aspectRatio: 0.5)
    let points = value.region.corners.map { RemoteDrawStaticBackground.phonePoint($0, projection: projection) }
    XCTAssertEqual(points[0].x, -1, accuracy: 1e-8)
    XCTAssertEqual(points[0].y, 0, accuracy: 1e-8)
    XCTAssertEqual(points[2].x, 2, accuracy: 1e-8)
    let placement = try XCTUnwrap(RemoteDrawImageGeometry.placement(points, size: CGSize(width: 200, height: 400)))
    XCTAssertEqual(placement.tx, -200, accuracy: 1e-8)
    XCTAssertEqual(placement.a, 600, accuracy: 1e-8)
  }

  func testBackdropCannotStartInkAndRegionEdgesRemainDrawable() throws {
    let corners = try descriptor().region.corners
    XCTAssertFalse(RemoteDrawStaticBackground.contains(.init(x: 0.1, y: 0.5), corners: corners))
    XCTAssertTrue(RemoteDrawStaticBackground.contains(.init(x: 0.5, y: 0.5), corners: corners))
    XCTAssertTrue(RemoteDrawStaticBackground.contains(corners[0], corners: corners))
  }

  func testRotatedProjectionUsesBoardAspect() {
    let projection = RemoteDrawProjection(centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.4, rotationDegrees: 90, aspectRatio: 1, coordinateAspectRatio: 2)
    let point = RemoteDrawStaticBackground.phonePoint(.init(x: 0.6, y: 0.5), projection: projection)
    XCTAssertEqual(point.x, 0.5, accuracy: 1e-8)
    XCTAssertEqual(point.y, 0, accuracy: 1e-8)
  }

  func testInkDynamicsSurviveProjection() {
    let sample = RemoteDrawNormalizedPoint(x: 0.6, y: 0.5, t: 123, pressure: 0.37, tiltX: 21, tiltY: -14)
    let projection = RemoteDrawProjection(centerX: 0.5, centerY: 0.5, width: 0.2, height: 0.4, rotationDegrees: 90, aspectRatio: 1, coordinateAspectRatio: 2)
    let projected = RemoteDrawStaticBackground.phonePoint(sample, projection: projection)
    XCTAssertEqual(projected.t, sample.t)
    XCTAssertEqual(projected.pressure, sample.pressure)
    XCTAssertEqual(projected.tiltX, sample.tiltX)
    XCTAssertEqual(projected.tiltY, sample.tiltY)
  }

  @MainActor
  func testReplacementFailureClearsPreviousPixels() async throws {
    let loader = RemoteDrawStaticImageLoader()
    let pixels = try makePixels()
    await loader.load(try descriptor()) { _ in pixels }
    XCTAssertNotNil(loader.pixels)
    await loader.load(try descriptor(version: 2)) { _ in throw URLError(.badServerResponse) }
    XCTAssertNil(loader.pixels)
    XCTAssertTrue(loader.failed)
    XCTAssertEqual(loader.descriptor?.version, 2)
  }

  @MainActor
  func testLateOldResponseCannotOverwriteNewPublication() async throws {
    let loader = RemoteDrawStaticImageLoader()
    let first = try descriptor(), second = try descriptor(version: 2)
    let pixels = try makePixels()
    var pending: CheckedContinuation<BoardImagePixels, Never>?
    let old = Task { await loader.load(first) { _ in
      await withCheckedContinuation { pending = $0 }
    } }
    while pending == nil { await Task.yield() }
    XCTAssertNil(loader.pixels)
    XCTAssertFalse(loader.failed)
    await loader.load(second) { _ in throw URLError(.badURL) }
    pending?.resume(returning: pixels)
    await old.value
    XCTAssertEqual(loader.descriptor?.version, 2)
    XCTAssertNil(loader.pixels)
    XCTAssertTrue(loader.failed)
  }

  private func makePixels() throws -> BoardImagePixels {
    let context = try XCTUnwrap(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 8,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return BoardImagePixels(try XCTUnwrap(context.makeImage()))
  }
}
