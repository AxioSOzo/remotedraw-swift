//
//  A dash shorter than 2.5 nib widths is a capsule, not a ribbon.
//
//  Mirrors the web's `isShortStroke` in packages/client/src/inkGeometry.ts;
//  `tests/api/inkSwiftParity.test.ts` pins the threshold on both sides. Checked
//  by rendering, not by reading: the painter's output for a short dash has to
//  be pixel-identical to the stroked centerline at the nominal nib.
//
import SwiftUI
import XCTest

@testable import RemoteDrawInk

@MainActor
final class ShortStrokeCapsuleTests: XCTestCase {
  private let extent: CGFloat = 200

  func testShortnessIsArcLengthInNibWidths() {
    let dash = [CGPoint(x: 10, y: 10), CGPoint(x: 17, y: 10), CGPoint(x: 24, y: 10)]
    // 14 units of centerline against a 6-unit nib: 2.33 widths.
    XCTAssertTrue(InkRenderer.isShortStroke(dash, lineWidth: 6))
    // 14 units against a 5-unit nib: 2.8 widths.
    XCTAssertFalse(InkRenderer.isShortStroke(dash, lineWidth: 5))
    // Out and back: the ends meet, but 28 units of ink were laid.
    XCTAssertFalse(InkRenderer.isShortStroke(dash + [CGPoint(x: 10, y: 11)], lineWidth: 6))
    XCTAssertTrue(InkRenderer.isShortStroke([CGPoint(x: 3, y: 3)], lineWidth: 6))
  }

  func testAShortMarkerDashPaintsTheStrokedCenterline() throws {
    let points = dash(length: 0.07)  // 14 units at extent 200
    let style = RemoteDrawDrawingStyle(kind: .whiteboardMarker, color: "#1f7a8c", width: 8)
    let painted = try render { context, size in
      RemoteDrawStrokePainter.draw(
        .init(points: points, style: style), in: &context, size: size, surface: .whiteboard)
    }
    let capsule = try render { context, size in
      Self.strokeCenterline(points, style: style, in: &context, size: size)
    }
    XCTAssertEqual(painted, capsule)
    XCTAssertTrue(painted.contains { $0 < 250 }, "the dash painted nothing")
  }

  func testALongerDashIsStillARibbon() throws {
    let points = dash(length: 0.2)  // 40 units: 5 widths
    let style = RemoteDrawDrawingStyle(kind: .whiteboardMarker, color: "#1f7a8c", width: 8)
    let painted = try render { context, size in
      RemoteDrawStrokePainter.draw(
        .init(points: points, style: style), in: &context, size: size, surface: .whiteboard)
    }
    let capsule = try render { context, size in
      Self.strokeCenterline(points, style: style, in: &context, size: size)
    }
    XCTAssertNotEqual(painted, capsule)
  }

  func testABroadNibKeepsItsDirectionalRibbonWhenShort() throws {
    let points = dash(length: 0.05)
    let style = RemoteDrawDrawingStyle(kind: .chiselMarker, color: "#1f7a8c", width: 8)
    let painted = try render { context, size in
      RemoteDrawStrokePainter.draw(
        .init(points: points, style: style), in: &context, size: size, surface: .whiteboard)
    }
    let capsule = try render { context, size in
      Self.strokeCenterline(points, style: style, in: &context, size: size)
    }
    XCTAssertNotEqual(painted, capsule)
  }

  // MARK: Helpers

  /// A straight, timed dash of `length` normalized units from rest.
  private func dash(length: Double) -> [NormalizedPoint] {
    (0..<6).map { index in
      let u = Double(index) / 5
      return NormalizedPoint(x: 0.3 + length * u, y: 0.5 + length * 0.3 * u, t: Double(index) * 10)
    }
  }

  private static func strokeCenterline(
    _ points: [NormalizedPoint], style: RemoteDrawDrawingStyle,
    in context: inout GraphicsContext, size: CGSize
  ) {
    let kind = style.kind.flatMap(DrawingStyleKind.init(rawValue:))
    let lineWidth = RemoteDrawStrokePainter.resolvedLineWidth(for: style, kind: kind, fallback: 4)
    let color = RemoteDrawStrokePainter.resolvedBaseColor(
      for: style, kind: kind, defaults: .standard)
    let opacity = RemoteDrawStrokePainter.resolvedOpacity(for: style, kind: kind)
    context.stroke(
      InkRenderer.smoothPath(through: points.map { RemoteDrawStrokePainter.scaled($0, in: size) }),
      with: .color(color.opacity(opacity)),
      style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    )
  }

  private func render(_ draw: @escaping (inout GraphicsContext, CGSize) -> Void) throws -> [UInt8] {
    let view = Canvas(rendersAsynchronously: false) { context, size in draw(&context, size) }
      .frame(width: extent, height: extent)
      .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = true
    guard let image = renderer.cgImage else {
      throw XCTSkip("ImageRenderer produced no image on this host.")
    }
    let side = Int(extent)
    var pixels = [UInt8](repeating: 0, count: side * side * 4)
    guard
      let context = CGContext(
        data: &pixels, width: side, height: side, bitsPerComponent: 8,
        bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw XCTSkip("Could not build the readback bitmap.") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
    return pixels
  }
}
