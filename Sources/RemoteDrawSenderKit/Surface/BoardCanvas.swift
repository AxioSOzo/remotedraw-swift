import SwiftUI

/// One mark to paint, in **surface** coordinates.
///
/// Surface coordinates, not board ones, and that is the contract: whoever
/// builds these has already decided what "here" means. On a plain board that
/// is the identity; on a projected board it is
/// ``RemoteDrawStrokeSpace/unproject``; on a map board it is the live camera.
/// Keeping the transform on the caller's side of this line is what lets the
/// MapKit ground and the projection maths stay in the first-party app, per §4
/// of the design, while the *painting* is shared.
public struct RemoteDrawBoardMark: Identifiable, Equatable, Sendable {
  public let id: String
  /// Protocol drawing type: `freehand`, `line`, `rectangle`, `ellipse`,
  /// `arrow`, `point`, `text`, `auto`.
  public let type: String
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let style: RemoteDrawDrawingStyle?
  /// Overrides the appearance's default width. The board's own committed
  /// content is painted at 6 the way the first-party app paints it; the live
  /// stroke is painted at whatever the person picked.
  public let lineWidth: CGFloat?

  public init(
    id: String,
    type: String = "freehand",
    points: [RemoteDrawNormalizedPoint],
    text: String? = nil,
    style: RemoteDrawDrawingStyle? = nil,
    lineWidth: CGFloat? = nil
  ) {
    self.id = id
    self.type = type
    self.points = points
    self.text = text
    self.style = style
    self.lineWidth = lineWidth
  }
}

/// A translate-then-scale applied to a whole section's context.
///
/// Both of this board's mappings are affine in board space, and an affine map
/// takes "scale about a board point" to "scale about that point's image"
/// exactly — so previewing a drag or a pinch in surface points is the same
/// picture the board will send back, not an approximation of it.
public struct RemoteDrawBoardTransform: Equatable, Sendable {
  public var translation: CGSize
  public var scale: Double
  /// The surface point the scale grows about.
  public var pivot: CGPoint

  public init(translation: CGSize = .zero, scale: Double = 1, pivot: CGPoint = .zero) {
    self.translation = translation
    self.scale = scale
    self.pivot = pivot
  }
}

/// One accumulation pass.
///
/// Sections exist so the group ceiling batches the way it does today and not
/// one mark further. Marks that share a film are painted into one isolated
/// layer — that is the whole point, it is what stops twenty pencil passes
/// going black where the board's dab engine would have stopped — but a run
/// must not silently span from the board's settled content into the ink under
/// the finger, because those are painted through different transforms.
public struct RemoteDrawBoardSection: Equatable, Sendable {
  public var marks: [RemoteDrawBoardMark]
  public var transform: RemoteDrawBoardTransform?

  public init(marks: [RemoteDrawBoardMark], transform: RemoteDrawBoardTransform? = nil) {
    self.marks = marks
    self.transform = transform
  }
}

/// Field furniture drawn over the ground and under the ink.
///
/// An explicit enum rather than a preset name, so no use-case vocabulary
/// crosses into the SDK: a host says "draw a box" or "draw a crosshair", and
/// what that box *means* stays where the meaning is. The first-party app maps
/// its own `targetPreset` onto these.
public enum RemoteDrawFieldGuide: Equatable, Sendable {
  case none
  /// A rounded box with a faint tick inside it, centred.
  case approvalBox
  /// A crosshair with a dot, centred.
  case pointerCrosshair
}

/// The board's ink, painted.
///
/// Everything visual the drawing surface does, and nothing that decides what
/// is on it: ground, field guides, the group ceiling, the ink pass, and an
/// escape hatch above it for whatever the host draws on top. It is a plain
/// `View`, so it can be placed over a MapKit view, inside a form, or as the
/// whole screen.
public struct RemoteDrawBoardCanvas: View {
  private let ground: RemoteDrawGround
  private let surface: RemoteDrawInkSurface.Kind
  private let guide: RemoteDrawFieldGuide
  private let sections: [RemoteDrawBoardSection]
  private let appearance: RemoteDrawAppearance
  private let overlay: ((inout GraphicsContext, CGSize) -> Void)?

  /// Redraws when a paper or tooth field finishes rasterising. Without it the
  /// first dry stroke on a fresh board paints unmasked and stays that way
  /// until something else happens to invalidate the view — the exact failure
  /// mode the recorded tooth-mask incident produced, only slower.
  @ObservedObject private var groundCache = RemoteDrawGroundCache.shared

  /// - Parameter surface: the render axis — which tooth, which instrument
  ///   palette. Defaults to whatever the ground implies, which is right for
  ///   every host that let the board pick its own ground.
  ///
  ///   It is a separate parameter because the two are not the same question and
  ///   the protocol proves it: an `svg`, `image`, `pdf` or `screen` board paints
  ///   a flat ground *and* has no tooth, because the ground belongs to someone
  ///   else's artwork. Deriving the axis from the ground would give all four of
  ///   them the whiteboard's, and every dry instrument would start biting paper
  ///   that is not there.
  public init(
    ground: RemoteDrawGround = .paper,
    surface: RemoteDrawInkSurface.Kind? = nil,
    guide: RemoteDrawFieldGuide = .none,
    sections: [RemoteDrawBoardSection],
    appearance: RemoteDrawAppearance = .default,
    overlay: ((inout GraphicsContext, CGSize) -> Void)? = nil
  ) {
    self.ground = ground
    self.surface = surface ?? ground.surfaceKind
    self.guide = guide
    self.sections = sections
    self.appearance = appearance
    self.overlay = overlay
  }

  public var body: some View {
    Canvas(rendersAsynchronously: false) { context, size in
      paintGround(&context, size: size)
      paintGuide(&context, size: size)
      let defaults = appearance.painterDefaults
      for section in sections {
        var target = context
        if let transform = section.transform {
          target.translateBy(x: transform.translation.width, y: transform.translation.height)
          if transform.scale != 1 {
            target.translateBy(x: transform.pivot.x, y: transform.pivot.y)
            target.scaleBy(x: transform.scale, y: transform.scale)
            target.translateBy(x: -transform.pivot.x, y: -transform.pivot.y)
          }
        }
        RemoteDrawInkComposer.draw(
          section.marks,
          in: &target,
          size: size,
          surface: surface,
          film: {
            RemoteDrawInkComposer.film(
              forType: $0.type, pointCount: $0.points.count, style: $0.style, surface: surface)
          },
          paint: { mark, layer in
            RemoteDrawStrokePainter.draw(
              RemoteDrawStrokePainter.Stroke(
                points: mark.points, type: mark.type, text: mark.text, style: mark.style),
              in: &layer,
              size: size,
              defaults: mark.lineWidth.map {
                RemoteDrawStrokePainter.Defaults(
                  color: defaults.color, lineWidth: $0,
                  highlighterColor: defaults.highlighterColor)
              } ?? defaults,
              surface: surface
            )
          }
        )
      }
      overlay?(&context, size)
    }
    .onAppear { ground.prepare() }
  }

  // MARK: Ground

  /// Cartridge paper: the base tone, then the tooth **tiled** over it.
  ///
  /// One page unit to one point, which is what the web board does at rest, so
  /// the grain is the same size on a phone as it is in the room. Tiled rather
  /// than stretched to fill: stretching would change the paper's period with
  /// the view's size, and two strokes made at two zoom levels would bite
  /// different paper.
  private func paintGround(_ context: inout GraphicsContext, size: CGSize) {
    guard case .transparent = ground else {
      let page = Path(CGRect(origin: .zero, size: size))
      context.fill(page, with: .color(ground.flatColor))
      guard let tile = ground.tile else { return }
      let edge = CGFloat(tile.width)
      guard edge > 0 else { return }
      let image = Image(decorative: tile, scale: 1)
      var y: CGFloat = 0
      while y < size.height {
        var x: CGFloat = 0
        while x < size.width {
          context.draw(image, in: CGRect(x: x, y: y, width: edge, height: edge))
          x += edge
        }
        y += edge
      }
      return
    }
  }

  private func paintGuide(_ context: inout GraphicsContext, size: CGSize) {
    switch guide {
    case .none:
      return
    case .approvalBox:
      let boxSize = min(size.width, size.height) * 0.30
      let rect = CGRect(
        x: (size.width - boxSize) / 2, y: (size.height - boxSize) / 2,
        width: boxSize, height: boxSize)
      var box = Path()
      box.addRoundedRect(in: rect, cornerSize: CGSize(width: 18, height: 18))
      context.stroke(box, with: .color(appearance.accent.opacity(0.35)), lineWidth: 4)

      var check = Path()
      check.move(to: CGPoint(x: rect.minX + boxSize * 0.23, y: rect.midY))
      check.addLine(to: CGPoint(x: rect.minX + boxSize * 0.43, y: rect.maxY - boxSize * 0.24))
      check.addLine(to: CGPoint(x: rect.maxX - boxSize * 0.18, y: rect.minY + boxSize * 0.26))
      context.stroke(
        check, with: .color(appearance.accent.opacity(0.24)),
        style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
    case .pointerCrosshair:
      let center = CGPoint(x: size.width / 2, y: size.height / 2)
      var horizontal = Path()
      horizontal.move(to: CGPoint(x: center.x - 56, y: center.y))
      horizontal.addLine(to: CGPoint(x: center.x + 56, y: center.y))
      var vertical = Path()
      vertical.move(to: CGPoint(x: center.x, y: center.y - 56))
      vertical.addLine(to: CGPoint(x: center.x, y: center.y + 56))
      context.stroke(
        horizontal, with: .color(appearance.accent.opacity(0.32)),
        style: StrokeStyle(lineWidth: 4, lineCap: .round))
      context.stroke(
        vertical, with: .color(appearance.accent.opacity(0.32)),
        style: StrokeStyle(lineWidth: 4, lineCap: .round))
      context.fill(
        Path(ellipseIn: CGRect(x: center.x - 8, y: center.y - 8, width: 16, height: 16)),
        with: .color(appearance.accent.opacity(0.38)))
    }
  }
}

extension RemoteDrawBoardMark {
  /// A settled stroke, mapped into surface space by `space` when it needs to
  /// be.
  ///
  /// Returns `nil` when nothing of it lands on this screen — a stroke that is
  /// entirely outside the phone's window — so the caller drops the mark rather
  /// than painting a degenerate one.
  public init?(
    _ stroke: RemoteDrawStroke,
    space: RemoteDrawStrokeSpace,
    lineWidth: CGFloat? = nil
  ) {
    let points: [RemoteDrawNormalizedPoint]
    if stroke.isBoardSpace {
      let mapped = stroke.points.compactMap(space.unproject)
      guard !mapped.isEmpty else { return nil }
      points = mapped
    } else {
      points = stroke.points
    }
    guard !points.isEmpty else { return nil }
    self.init(
      id: stroke.id, type: stroke.type, points: points, text: stroke.text,
      style: stroke.style, lineWidth: lineWidth)
  }
}
