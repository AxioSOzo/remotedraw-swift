import SwiftUI

/// The renderer, placeable anywhere.
///
/// Committed strokes plus the live one, painted with the same tapered dynamic
/// ribbons the first-party app and the web board use — so a mark made through
/// this SDK is the same mark, not a lookalike.
///
/// Headless in the sense that matters: no chrome, no gestures, no opinions
/// about layout. Put ``RemoteDrawStrokeCapture`` over it and you have a drawing
/// surface; put it inside your own view and you have a preview.
///
/// **Tier 3.** For a whole board — ground, field guides, the group ceiling that
/// stops shading going black, and a place to draw your own overlay — reach for
/// ``RemoteDrawBoardCanvas``, which this is now a thin arrangement of. They were
/// two implementations of the same paint until Stage 2, and the divergence was
/// not theoretical: this one stretched the paper tile across the whole view
/// instead of tiling it, so the grain's period changed with the view's size and
/// the SDK's paper was a different paper from the app's.
///
/// ```swift
/// ZStack {
///   RemoteDrawInkCanvas(strokes: session.strokes, live: session.live, ground: .paper)
///   RemoteDrawStrokeCapture(
///     onBegin: { session.begin(stroke: $0) },
///     onSamples: { session.append($0) },
///     onPredicted: { predicted = $0 },
///     onEnd: { id, reason in
///       Task {
///         reason == .finished ? try await session.end(stroke: id) : await session.cancelStroke()
///       }
///     })
/// }
/// ```
public struct RemoteDrawInkCanvas: View {
  private let strokes: [RemoteDrawStroke]
  private let live: RemoteDrawLiveStroke?
  private let predicted: [RemoteDrawNormalizedPoint]
  private let ground: RemoteDrawGround
  private let defaults: RemoteDrawStrokePainter.Defaults

  public init(
    strokes: [RemoteDrawStroke],
    live: RemoteDrawLiveStroke? = nil,
    predicted: [RemoteDrawNormalizedPoint] = [],
    ground: RemoteDrawGround = .paper,
    defaults: RemoteDrawStrokePainter.Defaults = .standard
  ) {
    self.strokes = strokes
    self.live = live
    self.predicted = predicted
    self.ground = ground
    self.defaults = defaults
  }

  public var body: some View {
    RemoteDrawBoardCanvas(
      ground: ground,
      sections: [RemoteDrawBoardSection(marks: marks)],
      appearance: RemoteDrawAppearance(
        ink: defaults.color, highlighter: defaults.highlighterColor, ground: ground)
    )
  }

  /// Settled ink and the live stroke in one section, which is not an
  /// arrangement detail: shading is stroke after stroke of one instrument, so
  /// the mark under the finger has to accumulate into the same buffer the
  /// settled ones did or it sits on top of the ceiling instead of under it.
  private var marks: [RemoteDrawBoardMark] {
    var marks = strokes.map {
      RemoteDrawBoardMark(
        id: $0.id, type: $0.type, points: $0.type == "image" ? RemoteDrawImageGeometry.corners($0.points) : $0.points, text: $0.text, imageUrl: $0.imageUrl, style: $0.style,
        lineWidth: defaults.lineWidth)
    }
    if let live {
      // Prediction is applied here and nowhere else: the renderer draws a
      // sample or two past the finger, and the array that went on the wire
      // stays exactly what the hardware reported.
      marks.append(
        RemoteDrawBoardMark(
          id: live.id,
          type: live.tool.rawValue,
          points: RemoteDrawInkGeometry.previewPointsWithPrediction(
            live.points, predicted: predicted),
          style: live.style,
          lineWidth: defaults.lineWidth
        ))
    }
    return marks
  }
}
