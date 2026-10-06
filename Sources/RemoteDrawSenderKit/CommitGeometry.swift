import Foundation

/// What a finished gesture becomes on the wire.
///
/// Two rules, both of them behaviour the first-party board has shipped since
/// before this SDK existed (`commitPoints` and `minimumCommitPoints` in
/// `apps/ios/RemoteDraw/DrawingBoardView.swift`). They live here so the app and
/// ``RemoteDrawSurface`` cannot disagree about what a rectangle *is*, which is
/// exactly the kind of divergence a second implementation produces silently.
///
/// Neither rule is cosmetic:
///
/// **A shape is its endpoints.** A `rectangle` and an `ellipse` are painted
/// from the axis-aligned bounding box of their points, and a `line` and an
/// `arrow` from their first and last
/// (``RemoteDrawInkRenderer/shapeInkStrokes(type:points:strokeWidth:)``). So a
/// drag that wanders — out to the right, up, then back down-left to finish —
/// commits a *different rectangle* depending on whether the wander travels with
/// it. Sending the whole buffer means the box is the extent of the hand's
/// journey rather than the extent of the drag, which is not what the person saw
/// under their finger. Reducing to the two endpoints also drops the wander from
/// the payload, where for a `line` it was never read at all.
///
/// **A tap still leaves a mark.** A stroke that never moved has one sample, and
/// every shipped RemoteDraw sender pads it into two rather than discarding it:
/// the web sender commits `[dot, dot]` as freehand
/// (`packages/react/src/SenderPad.tsx`), and the iOS board offsets the second
/// sample by 0.001 so the ribbon has a direction to be built along. Without the
/// padding a deliberate dot is silently dropped by the two-point minimum, and
/// the person taps the board and nothing happens.
public enum RemoteDrawCommitGeometry: Sendable {
  /// How far the padded second sample sits from the first.
  ///
  /// Small enough to be invisible and large enough that the ribbon assembler
  /// has a non-degenerate direction to extrude along — a duplicated point has
  /// none, and a zero-length segment is what makes a dot render as nothing.
  public static let dotOffset = 0.001

  /// The geometry a tool's committed stroke is made of.
  ///
  /// - `line`, `arrow`, `rectangle`, `ellipse`: the first and last sample.
  /// - `point`, `text`: the first sample.
  /// - `freehand`, `auto`: everything, unchanged.
  public static func shaped<Point: RemoteDrawCommitPoint>(
    _ points: [Point],
    tool: RemoteDrawTool
  ) -> [Point] {
    guard let first = points.first, let last = points.last else { return points }
    switch tool {
    case .line, .arrow, .rectangle, .ellipse:
      // One sample reduces to *one*, not to `[first, first]`. Returning the
      // duplicate here would satisfy the two-point minimum without ever
      // reaching ``padded(_:tool:)``, and commit the zero-length segment that
      // renders as nothing — a shape tool tapped without moving would leave no
      // mark while the same tap in freehand left a dot.
      return points.count == 1 ? [first] : [first, last]
    case .point, .text:
      return [first]
    case .auto, .freehand:
      return points
    }
  }

  /// Pads a single-sample stroke so a tap commits a dot instead of nothing.
  ///
  /// A no-op for `point` and `text`, which are *defined* as one sample, and for
  /// anything that already has two.
  public static func padded<Point: RemoteDrawCommitPoint>(
    _ points: [Point],
    tool: RemoteDrawTool
  ) -> [Point] {
    guard tool != .point, tool != .text, points.count == 1, let point = points.first else {
      return points
    }
    return [point, point.offsetForDot(by: dotOffset)]
  }

  /// Both rules, in the order the board applies them: shape first, then pad —
  /// because reducing a one-sample `line` is what creates the single-point case
  /// the padding exists for.
  public static func forCommit<Point: RemoteDrawCommitPoint>(
    _ points: [Point],
    tool: RemoteDrawTool
  ) -> [Point] {
    padded(shaped(points, tool: tool), tool: tool)
  }

  /// The fewest samples a tool's commit can carry and still be a mark.
  public static func minimumPointCount(for tool: RemoteDrawTool) -> Int {
    tool == .point || tool == .text ? 1 : 2
  }
}

/// A point ``RemoteDrawCommitGeometry`` can nudge.
///
/// A protocol rather than a concrete type so a host with its own sample type
/// can run the same rules over it, and so the padding stays *one*
/// implementation instead of one per point struct.
public protocol RemoteDrawCommitPoint {
  /// A copy displaced by `offset` in both axes, clamped to the unit square,
  /// carrying this point's dynamics forward.
  ///
  /// The dynamics matter: a fabricated pressure would change the dot's width,
  /// and the whole reason the pad exists is to draw the mark the finger made.
  func offsetForDot(by offset: Double) -> Self
}

extension RemoteDrawNormalizedPoint: RemoteDrawCommitPoint {
  public func offsetForDot(by offset: Double) -> RemoteDrawNormalizedPoint {
    RemoteDrawNormalizedPoint(
      x: min(1, x + offset),
      y: min(1, y + offset),
      // One millisecond later, so velocity reads a real interval rather than
      // dividing by zero.
      t: t.map { $0 + 1 },
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY
    )
  }
}
