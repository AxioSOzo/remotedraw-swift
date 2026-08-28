//
//  What coalesced touches are actually worth, measured in pixels.
//
//  Stage 3 has to decide whether the first-party app abandons its
//  `DragGesture` + window-monitor capture for `RemoteDrawStrokeCapture`. The
//  argument for is that `UIEvent.coalescedTouches(for:)` hands over the samples
//  the digitiser took *between* display refreshes — up to 240 Hz on an iPad with
//  a Pencil against the ~60–120 Hz a `DragGesture` yields — and that throwing
//  them away "shortens tight curves into corners at exactly the speed people
//  write at". That is a claim about ink, and this repository's rule for claims
//  about ink is that they are settled by rendering, not by reading
//  (`SurfaceRenderParityTests`, and the tooth mask that was a no-op for weeks).
//
//  So: take one continuous gesture, sample the *same* curve at the two rates,
//  push both through the sampler every RemoteDraw buffer runs
//  (`RemoteDrawInkGeometry.shouldAppendSample`), paint both at 1:1, and count
//  the pixels that differ.
//
//  This is a measurement, not a gate. It prints a table and asserts only the
//  things that would invalidate the measurement itself.
//
import SwiftUI
import XCTest

@testable import RemoteDrawInk
import RemoteDrawSenderKit

@MainActor
final class CaptureDensityTests: XCTestCase {
  private let extent: CGFloat = 512

  /// The gesture, as a continuous function of time rather than as samples.
  ///
  /// A cursive double loop — the shape the coalesced-touch argument is about,
  /// because it is all corner. Drawn across 0.6 s, which is a brisk but
  /// unremarkable handwriting speed for a mark this size, so the two sampling
  /// rates are being compared at the speed where they should differ most.
  private let duration = 0.6

  private func position(at time: Double) -> CGPoint {
    let u = time / duration
    // Two overlapping loops with a fast reversal between them: curvature that
    // peaks well inside a single 16 ms refresh.
    let angle = u * .pi * 4
    return CGPoint(
      x: 0.5 + 0.34 * sin(angle) * (0.55 + 0.45 * u),
      y: 0.5 + 0.30 * sin(angle * 2) * (0.9 - 0.4 * u)
    )
  }

  private func pressure(at time: Double) -> Double {
    let u = time / duration
    return 0.2 + 0.65 * sin(u * .pi)
  }

  /// The gesture as one capture layer would report it.
  ///
  /// `hertz` is the rate samples arrive at, which is the only thing that
  /// differs between a `DragGesture` (one location per event) and
  /// `coalescedTouches` (everything the digitiser took since the last event).
  private func samples(hertz: Double) -> [RemoteDrawNormalizedPoint] {
    let count = max(2, Int((duration * hertz).rounded()))
    return (0...count).map { index in
      let time = duration * Double(index) / Double(count)
      let point = position(at: time)
      return RemoteDrawNormalizedPoint(
        x: Double(point.x),
        y: Double(point.y),
        t: time * 1000,
        pressure: pressure(at: time),
        tiltX: -30 + 60 * (time / duration),
        tiltY: 20 - 40 * (time / duration)
      )
    }
  }

  /// What survives into the transport buffer, which is the only array that is
  /// ever drafted, committed or drawn.
  ///
  /// Identical to the loop in ``RemoteDrawSenderSession/append(_:)`` and to the
  /// one the first-party board runs on its own buffer — deliberately, because
  /// the question is what the *sampler* does with a denser feed, not what a
  /// renderer would do with raw hardware output nobody keeps.
  private func buffered(_ incoming: [RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint] {
    var buffer: [RemoteDrawNormalizedPoint] = []
    for sample in incoming {
      guard RemoteDrawInkGeometry.shouldAppendSample(buffer, candidate: sample) else { continue }
      if buffer.count >= RemoteDrawProtocolLimits.maxCommitPoints {
        buffer = RemoteDrawStrokeBudget.thin(buffer, limit: RemoteDrawProtocolLimits.maxCommitPoints)
      }
      buffer.append(sample)
    }
    return buffer
  }

  /// The measurement.
  ///
  /// 60 Hz is what a `DragGesture` delivers on the phones this app ships to;
  /// 120 Hz is a ProMotion refresh; 240 Hz is the Pencil's digitiser rate, i.e.
  /// the ceiling `coalescedTouches` can reach.
  func testHowMuchInkTheCoalescedSamplesAreWorth() throws {
    try warmFields()

    let rates: [(label: String, hertz: Double)] = [
      ("60Hz (DragGesture)", 60),
      ("120Hz (ProMotion)", 120),
      ("240Hz (coalesced)", 240),
    ]

    var rendered: [(label: String, captured: Int, buffered: Int, pixels: [UInt8])] = []
    for rate in rates {
      let incoming = samples(hertz: rate.hertz)
      let buffer = buffered(incoming)
      let pixels = try renderStroke(buffer)
      rendered.append((rate.label, incoming.count, buffer.count, pixels))
    }

    guard let reference = rendered.last else { return XCTFail("no renders") }
    var report: [String] = [
      "=== capture density: one 0.6s cursive gesture, painted at 512x512 ==="
    ]
    for entry in rendered {
      let (differing, worst) = difference(entry.pixels, reference.pixels)
      report.append(
        String(
          format: "%-20s captured %4d  buffered %4d  vs 240Hz: %6d px differ (%.3f%%), worst %3d/255",
          (entry.label as NSString).utf8String!,
          entry.captured,
          entry.buffered,
          differing,
          100 * Double(differing) / Double(reference.pixels.count / 4),
          worst))
    }
    print(report.joined(separator: "\n"))

    // The measurement is only meaningful if the sampler is actually keeping the
    // extra samples. If `shouldAppendSample` decimated a 240 Hz feed back down
    // to the 60 Hz one, the two images would be identical for an uninteresting
    // reason and nothing could be concluded from the pixel count.
    let sparse = rendered[0]
    XCTAssertGreaterThan(
      reference.buffered, sparse.buffered,
      "A 240Hz feed did not survive the sampler as more points than a 60Hz one — "
        + "the pixel comparison below is measuring nothing.")

    // And the conclusion Stage 3 acted on, pinned so it cannot quietly stop
    // being true. This is the whole justification for the first-party board
    // abandoning `DragGesture` locations in favour of the gesture monitor's
    // coalesced channel: the two feeds are not a rounding difference, they are
    // visibly different ink. If a future change to the sampler or the painter
    // makes this small, the capture change has stopped paying for itself and
    // the decision should be revisited rather than inherited.
    let (differing, worst) = difference(sparse.pixels, reference.pixels)
    let fraction = Double(differing) / Double(reference.pixels.count / 4)
    XCTAssertGreaterThan(
      fraction, 0.01,
      "One-sample-per-frame capture now paints within 1% of the coalesced feed.")
    XCTAssertGreaterThan(
      worst, 32,
      "The worst channel difference between the two feeds is no longer visible.")
  }

  /// Guards the conclusion the way `testTheHarnessReproducesItself` guards the
  /// parity suite: a comparison harness that cannot reproduce its own output
  /// cannot attribute a difference to the input.
  func testTheDensityHarnessReproducesItself() throws {
    try warmFields()
    let buffer = buffered(samples(hertz: 120))
    let first = try renderStroke(buffer)
    let second = try renderStroke(buffer)
    let (differing, worst) = difference(first, second)
    XCTAssertLessThan(
      differing, first.count / 400,
      "The density harness does not reproduce itself (worst \(worst)/255).")
  }

  // MARK: Harness

  private func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> (differing: Int, worst: Int) {
    var differing = 0
    var worst = 0
    var index = 0
    while index < min(lhs.count, rhs.count) {
      var pixelDiffers = false
      var pixelWorst = 0
      for channel in 0..<4 where lhs[index + channel] != rhs[index + channel] {
        pixelDiffers = true
        pixelWorst = max(pixelWorst, abs(Int(lhs[index + channel]) - Int(rhs[index + channel])))
      }
      if pixelDiffers {
        differing += 1
        worst = max(worst, pixelWorst)
      }
      index += 4
    }
    return (differing, worst)
  }

  private func renderStroke(_ points: [RemoteDrawNormalizedPoint]) throws -> [UInt8] {
    try renderView(
      RemoteDrawBoardCanvas(
        ground: .paper,
        surface: .paper,
        sections: [
          RemoteDrawBoardSection(marks: [
            RemoteDrawBoardMark(
              id: "gesture",
              type: "freehand",
              points: points,
              style: RemoteDrawDrawingStyle(kind: .pencil, color: "#111827", width: 9),
              lineWidth: 9)
          ])
        ]
      ))
  }

  private func warmFields() throws {
    _ = try? renderView(Color.white)
    RemoteDrawPaperGround.prepareTile(grain: RemoteDrawInkSurface.grain(.paper))
    RemoteDrawInk.prepareToothImage(for: .paper, extent: extent)
    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      let tileReady = RemoteDrawPaperGround.tile(grain: RemoteDrawInkSurface.grain(.paper)) != nil
      let toothReady = RemoteDrawInk.toothImage(for: .paper, extent: extent) != nil
      if tileReady && toothReady { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    throw XCTSkip("The paper and tooth fields did not rasterise within 10s.")
  }

  private func renderView<V: View>(_ view: V) throws -> [UInt8] {
    let renderer = ImageRenderer(content: view.frame(width: extent, height: extent))
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
