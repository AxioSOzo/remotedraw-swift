//
//  How a recognized shape looks once painted, checked by rendering.
//
//  A shape's outline is closed: `shapeInkStrokes` walks a rectangle or an
//  ellipse back to its first sample, and shape assist's fitted polygons end on
//  their seam. Painted as an open stroke, the seam drew a round entry blob
//  against a thin exit taper (a knot at a rectangle's top-left corner) and a
//  flat nib's butt caps cut a notch out of the corner. And an arrow is two
//  outlines but one mark, so a translucent instrument must not lay its alpha
//  twice where the head overlaps the shaft.
//
//  Mirrors `packages/client/tests/shapeInk.test.ts` ("a shape's closed outline
//  has no ends") and `packages/react/tests/receiverShapeComposite.test.tsx`.
//  Rendered comparisons: docs/plans/2026-09-23-shape-ink.md.
//
import AppKit
import SwiftUI
import XCTest

@testable import RemoteDrawInk

@MainActor
final class ClosedShapeOutlineTests: XCTestCase {
  private let extent: CGFloat = 200
  private let box = [NormalizedPoint(x: 0.2, y: 0.2), NormalizedPoint(x: 0.7, y: 0.6)]

  func testShapeOutlinesAreClosedAndHandLoopsAreNot() throws {
    let scale = { (points: [NormalizedPoint]) in
      points.map { CGPoint(x: $0.x * 200, y: $0.y * 200) }
    }
    for type in ["rectangle", "ellipse"] {
      let outline = try XCTUnwrap(InkRenderer.shapeInkStrokes(type: type, points: box, strokeWidth: 0.01)?.first)
      XCTAssertTrue(InkRenderer.isClosedOutline(scale(outline), extent: 200), type)
    }
    let line = try XCTUnwrap(InkRenderer.shapeInkStrokes(type: "line", points: box, strokeWidth: 0.01)?.first)
    XCTAssertFalse(InkRenderer.isClosedOutline(scale(line), extent: 200))
    let loop = (0...48).map { index -> CGPoint in
      let angle = Double(index) / 48 * .pi * 2 * 0.995
      return CGPoint(x: 100 + cos(angle) * 40, y: 100 + sin(angle) * 40)
    }
    XCTAssertFalse(InkRenderer.isClosedOutline(loop, extent: 200))
    // A hand loop whose ends quantize to one position is read as closed —
    // nothing on a stored drawing says a freehand path was fitted — and painted
    // as the ring it is. A stroke that doubles back onto its start encloses
    // nothing and keeps its ends. Mirrors shapeInk.test.ts.
    var exact = loop
    exact[exact.count - 1] = exact[0]
    XCTAssertTrue(InkRenderer.isClosedOutline(exact, extent: 200))
    let out = (0..<12).map { CGPoint(x: 120 + CGFloat($0) * 2, y: 32 + CGFloat($0) * 3.6) }
    let back = (1..<11).map { CGPoint(x: 142 - CGFloat($0) * 2 + 0.6 * sin(CGFloat($0)), y: 71.6 - CGFloat($0) * 3.6) }
    XCTAssertFalse(InkRenderer.isClosedOutline(out + back + [out[0]], extent: 200))
  }

  /// A highlighter's butt caps used to leave the outer quadrant of the seam
  /// corner bare. Closed, the corner is joined like the other three.
  func testAFlatNibRectangleHasNoNotchAtItsSeamCorner() throws {
    let pixels = try render(type: "rectangle", points: box, style: .init(kind: .highlighter, color: "#1f7a8c"))
    // (40, 40) is the seam corner, (140, 40) the next one. Just outside each
    // corner on the diagonal, inside the join's reach; pixel column `c` mirrors
    // to `179 - c` about the rectangle's axis at x = 90.
    let seam = luminance(pixels, x: 37, y: 37)
    let other = luminance(pixels, x: 142, y: 37)
    XCTAssertLessThan(other, 250, "the reference corner painted nothing")
    XCTAssertEqual(seam, other, accuracy: 3)
  }

  /// A marker rectangle's seam corner is the same mark as its other corners:
  /// no entry blob, no tapered tail.
  func testAMarkerRectangleSeamCornerMatchesTheOthers() throws {
    let pixels = try render(type: "rectangle", points: box, style: .init(kind: .whiteboardMarker, color: "#1f7a8c"))
    // Top-left (seam) against top-right, mirrored about the rectangle's axis
    // (pixel column `c` mirrors to `179 - c`).
    var difference = 0
    var inked = 0
    for dy in -8...8 {
      for dx in -8...8 {
        let seam = luminance(pixels, x: 40 + dx, y: 40 + dy) < 128
        let mirror = luminance(pixels, x: 139 - dx, y: 40 + dy) < 128
        if seam != mirror { difference += 1 }
        if mirror { inked += 1 }
      }
    }
    XCTAssertGreaterThan(inked, 40)
    XCTAssertLessThanOrEqual(difference, inked / 20)
  }

  /// Chalk and charcoal paint grain — a faint body and a stack of streaks —
  /// rather than a ribbon, and every pass is butt-capped. Built open, each one
  /// ended at the seam and the corner kept a notch after the ribbon was fixed.
  func testGrainInstrumentsHaveNoNotchAtTheSeamCorner() throws {
    for kind in [DrawingStyleKind.chalk, .charcoal] {
      let pixels = try render(type: "rectangle", points: box, style: .init(kind: kind, color: "#1f2a30"))
      XCTAssertLessThan(
        seamDifference(pixels), 0.12, "\(kind.rawValue): the seam corner is not the corner opposite it")
    }
  }

  /// Every instrument's seam corner against the corner opposite it, rendered.
  /// A half turn keeps each instrument's geometry (a broad nib's width goes
  /// with the heading's axis, which 180° does not change). Grain differs by
  /// seeded noise, so textured marks get a looser bound; airbrush dots share no
  /// geometry with the opposite corner and are not compared. Mirrors
  /// tests/api/shapeInkSeam.test.ts.
  func testEverySeamCornerMatchesTheCornerOppositeIt() throws {
    for kind in DrawingStyleKind.allCases where kind != .airbrush {
      let pixels = try render(type: "rectangle", points: box, style: .init(kind: kind, color: "#1f2a30"))
      let profile = RemoteDrawInk.profile(for: kind, surface: .whiteboard)
      let textured =
        profile.grain != nil || profile.glow != nil || kind == .italicNib || kind == .chiselMarker
      let difference = seamDifference(pixels)
      if ProcessInfo.processInfo.environment["RD_DUMP"] != nil { print("seam \(kind.rawValue) \(difference)") }
      XCTAssertLessThan(difference, textured ? 0.12 : 0.04, kind.rawValue)
    }
  }

  /// Where a highlighter arrow's head overlaps its shaft the tone is the
  /// shaft's, not the shaft's composited twice.
  func testATranslucentArrowHeadDoesNotDoubleOverItsShaft() throws {
    let arrow = [NormalizedPoint(x: 0.15, y: 0.7, t: 0), NormalizedPoint(x: 0.75, y: 0.4, t: 300)]
    let pixels = try render(type: "arrow", points: arrow, style: .init(kind: .highlighter, color: "#1f7a8c"))
    let shaft = luminance(pixels, x: 60, y: 125)  // a third of the way along
    let tip = luminance(pixels, x: 148, y: 81)  // just behind the tip: shaft and head
    XCTAssertLessThan(shaft, 245, "the shaft painted nothing")
    XCTAssertEqual(tip, shaft, accuracy: 3)
  }

  // MARK: Helpers

  /// Summed |seam - opposite| darkness around the seam corner (40, 40), against
  /// the bottom-right corner (140, 120) turned through 180° about the
  /// rectangle's centre: pixel (40 + dx, 40 + dy) against (139 - dx, 119 - dy).
  private func seamDifference(_ pixels: [UInt8]) -> Double {
    var difference = 0.0
    var ink = 0.0
    for dy in -8..<8 {
      for dx in -8..<8 {
        let seam = 255 - luminance(pixels, x: 40 + dx, y: 40 + dy)
        let opposite = 255 - luminance(pixels, x: 139 - dx, y: 119 - dy)
        difference += abs(seam - opposite)
        ink += opposite
      }
    }
    XCTAssertGreaterThan(ink, 16 * 16 * 255 * 0.05, "the opposite corner painted nothing")
    return difference / max(ink, 1)
  }

  private func luminance(_ pixels: [UInt8], x: Int, y: Int) -> Double {
    let index = (y * Int(extent) + x) * 4
    return (Double(pixels[index]) + Double(pixels[index + 1]) + Double(pixels[index + 2])) / 3
  }

  private func render(type: String, points: [NormalizedPoint], style: RemoteDrawDrawingStyle) throws -> [UInt8] {
    let view = Canvas(rendersAsynchronously: false) { context, size in
      RemoteDrawStrokePainter.draw(
        .init(points: points, type: type, style: style), in: &context, size: size, surface: .whiteboard)
    }
    .frame(width: extent, height: extent)
    .background(Color.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 1
    renderer.isOpaque = true
    guard let image = renderer.cgImage else {
      throw XCTSkip("ImageRenderer produced no image on this host.")
    }
    // `RD_DUMP=<dir> swift test --filter ClosedShapeOutlineTests` writes what
    // was rendered, for looking at rather than trusting the pixel reads.
    if let dir = ProcessInfo.processInfo.environment["RD_DUMP"] {
      let rep = NSBitmapImageRep(cgImage: image)
      try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(type)-\(style.kind ?? "").png"))
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
