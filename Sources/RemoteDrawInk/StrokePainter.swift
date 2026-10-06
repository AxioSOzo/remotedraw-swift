import SwiftUI

/// Paints RemoteDraw strokes into a SwiftUI `GraphicsContext`.
///
/// Extracted from `DrawingBoardView.drawStroke` in the iOS app, which is ~500
/// lines of painting logic trapped inside a UIKit- and MapKit-bound view. The
/// logic itself never needed either: it takes normalized points and a style and
/// draws. Lifting it here gives the Mac receiver pixel-identical ink for free,
/// gives the renderer headless test coverage it has never had, and is the
/// prerequisite for any other platform ever sharing this.
///
/// The instrument geometry lives in `InkRenderer` / `RemoteDrawInk`, which is a
/// verbatim copy of the app's file (see `InkCompatibility.swift`). This type is
/// the assembler on top of it — the part that decides *which* marks to make.
public enum RemoteDrawStrokePainter {
  /// Cap on samples drawn per stroke. A committed stroke can carry 1200 points
  /// and the difference above this is invisible, but the cost is not.
  static let maxRenderPoints = 320

  /// Everything the painter needs about one stroke.
  public struct Stroke {
    /// Normalized `0...1`, top-left origin.
    public let points: [RemoteDrawNormalizedPoint]
    /// Protocol drawing type: `freehand`, `line`, `rectangle`, `ellipse`,
    /// `arrow`, `point`, `text`, `auto`.
    public let type: String
    public let text: String?
    public let style: RemoteDrawDrawingStyle?

    public init(
      points: [RemoteDrawNormalizedPoint],
      type: String = "freehand",
      text: String? = nil,
      style: RemoteDrawDrawingStyle? = nil
    ) {
      self.points = points
      self.type = type
      self.text = text
      self.style = style
    }
  }

  /// Fallbacks for anything the stroke's own style does not specify.
  public struct Defaults {
    public let color: Color
    public let lineWidth: CGFloat
    /// The colour a highlighter falls back to when the style names none.
    /// Matches `RemoteDrawTheme.gold` in the iOS app.
    public let highlighterColor: Color

    public init(
      color: Color = Color(red: 0.09, green: 0.09, blue: 0.08),
      lineWidth: CGFloat = 4,
      highlighterColor: Color = Color(red: 0.95, green: 0.79, blue: 0.41)
    ) {
      self.color = color
      self.lineWidth = lineWidth
      self.highlighterColor = highlighterColor
    }

    public static let standard = Defaults()
  }

  // MARK: Entry point

  /// Draws one stroke. `size` is the surface in points; normalized coordinates
  /// are scaled onto it directly, so the caller owns any letterboxing.
  ///
  /// `surface` is **what the marks are being made on**, and it decides whether
  /// a dry instrument bites a paper tooth at all. It used not to be here: the
  /// painter reached `RemoteDrawInk.profile(for:)` with no surface, which
  /// defaults to paper, so an SDK host drawing on a whiteboard or over their
  /// own content got graphite skipping valleys that were not there. It carries
  /// that same default, so a caller that has nothing to say about the board
  /// keeps the behaviour it had.
  ///
  /// `RemoteDrawInkSurface.kind(forProtocolName:)` maps a surface name off the
  /// wire onto this, which is how a host with a `Target` answers it.
  public static func draw(
    _ stroke: Stroke,
    in context: inout GraphicsContext,
    size: CGSize,
    defaults: Defaults = .standard,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind,
    dynamicsScale: CGSize = CGSize(width: 1, height: 1)
  ) {
    let points = decimated(stroke.points)
    guard let first = points.first else { return }

    let kind = styleKind(stroke.style)
    let lineWidth = resolvedLineWidth(for: stroke.style, kind: kind, fallback: defaults.lineWidth)
    let baseColor = resolvedBaseColor(for: stroke.style, kind: kind, defaults: defaults)
    let opacity = resolvedOpacity(for: stroke.style, kind: kind)
    let color = baseColor.opacity(opacity)

    if stroke.type == "text" {
      guard let text = stroke.text, !text.isEmpty else { return }
      var resolved = context.resolve(Text(text).font(.system(size: 28, weight: .bold)))
      resolved.shading = .color(color)
      context.draw(resolved, at: scaled(first, in: size), anchor: .leading)
      return
    }

    // The point tool is a deliberate marker: oversized so a tap reads from
    // across the room on the receiver.
    if stroke.type == "point" {
      fillDot(at: scaled(first, in: size), radius: max(8, lineWidth * 2.6), color: color, in: &context)
      return
    }

    // A just-started stroke has only its first sample: show ink at finger
    // scale, not a point-tool blob. Mirrors the web renderer so the head of a
    // stroke does not pop from 2.6× width down to the line width on sample two.
    if points.count == 1 {
      fillDot(at: scaled(first, in: size), radius: max(lineWidth / 2, 2.5), color: color, in: &context)
      return
    }

    // A snapped shape is still ink: a straightened pencil line has to stay a
    // pencil line. `shapeInkStrokes` gives back the polyline a hand would have
    // travelled, so the shape goes through the same freehand assembler as
    // everything else and picks up grain, tooth, taper and dynamics for free.
    let surfaceExtent = max(size.width, size.height)
    if surfaceExtent > 0,
      let outlines = InkRenderer.shapeInkStrokes(
        type: stroke.type,
        points: points,
        strokeWidth: Double(lineWidth / surfaceExtent)
      ),
      drawShapeAsInk(
        outlines: outlines,
        stroke: stroke,
        kind: kind,
        in: &context,
        size: size,
        color: color,
        baseColor: baseColor,
        opacity: opacity,
        lineWidth: lineWidth,
        defaults: defaults,
        surface: surface,
        dynamicsScale: dynamicsScale
      )
    {
      return
    }

    if stroke.type == "arrow", let start = points.first, let end = points.last {
      drawArrow(
        from: scaled(start, in: size),
        to: scaled(end, in: size),
        in: &context,
        color: color,
        lineWidth: lineWidth
      )
      return
    }

    let screenPoints = points.map { scaled($0, in: size) }
    let isFreehand = stroke.type == "freehand" || stroke.type == "auto"

    if let fillColor = resolvedFillColor(for: stroke.style, kind: kind, defaults: defaults) {
      fill(
        type: stroke.type,
        screenPoints: screenPoints,
        isFreehand: isFreehand,
        fillColor: fillColor,
        surfaceExtent: surfaceExtent,
        in: &context
      )
    }

    if isFreehand,
      drawFreehandMark(
        points: points,
        screenPoints: screenPoints,
        kind: kind,
        baseColor: baseColor,
        strokeOpacity: opacity,
        lineWidth: lineWidth,
        size: size,
        in: &context,
        surface: surface,
        dynamicsScale: dynamicsScale
      )
    {
      return
    }

    // Freehand ink follows a Catmull-Rom curve through the samples; shape
    // primitives (rectangle corners, ellipse polygon, line) stay literal.
    let path: Path
    if isFreehand {
      path = InkRenderer.smoothPath(through: screenPoints)
    } else {
      var polyline = Path()
      polyline.move(to: screenPoints[0])
      for point in screenPoints.dropFirst() { polyline.addLine(to: point) }
      path = polyline
    }
    // Flat nibs: a highlighter's chisel and chalk's crumbling end.
    let isFlatNib = kind == .highlighter || kind == .chalk
    context.stroke(
      path,
      with: .color(color),
      style: StrokeStyle(
        lineWidth: lineWidth,
        lineCap: isFreehand && isFlatNib ? .butt : .round,
        lineJoin: .round
      )
    )
  }

  // MARK: Freehand assembly

  /// Assembles one freehand mark from the instrument profile — the same table
  /// the web resolves through, so a stroke drawn on a phone and a stroke
  /// replayed on a receiver are the same mark. Returns false when nothing could
  /// be painted, so the caller falls back to a plain stroked path.
  static func drawFreehandMark(
    points: [RemoteDrawNormalizedPoint],
    screenPoints: [CGPoint],
    kind: DrawingStyleKind?,
    baseColor: Color,
    strokeOpacity: Double,
    lineWidth: CGFloat,
    size: CGSize,
    in context: inout GraphicsContext,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind,
    dynamicsScale: CGSize = CGSize(width: 1, height: 1)
  ) -> Bool {
    // The surface supplies the sheet and the instrument declares whether it
    // rides one, so a pencil on a whiteboard draws an even line rather than
    // borrowing a tooth it is not on.
    let profile = RemoteDrawInk.profile(for: kind, surface: surface)
    // How much of the paper's ceiling one pass of this instrument takes. It
    // rides with the tooth rather than with the instrument: a dry medium on a
    // surface with no tooth has no `capacity` to approach — nothing masks it and
    // nothing caps it — so scaling its alpha there would just draw a faint
    // pencil on a whiteboard. See `RemoteDrawInk.Profile.toneScale`.
    let tone = profile.tooth == nil ? 1 : profile.toneScale
    // Flattened instruments paint opaque and let the layer carry the alpha;
    // everything else bakes it into the colour.
    let color =
      profile.multiply || profile.flatten
      ? baseColor : baseColor.opacity(strokeOpacity * tone)
    let surfaceExtent = max(size.width, size.height)

    // Which axis drives width: a broad-edge nib reads stroke direction, tilt
    // reads how far the stylus is laid over, everything else uses pressure.
    let axisFactors: [Double]?
    if let nib = profile.nib {
      axisFactors = InkRenderer.nibFactors(for: screenPoints, nib: nib)
    } else if let tilt = profile.tilt {
      axisFactors = InkRenderer.tiltFactors(for: points, tilt: tilt)
    } else {
      axisFactors = nil
    }

    // Tilt lightens as it broadens: the same graphite over more paper.
    var markColor = color
    if let tilt = profile.tilt {
      let mean = InkRenderer.meanTiltAmount(points)
      let alpha = tilt.alphaUpright + (tilt.alphaFlat - tilt.alphaUpright) * mean
      markColor = color.opacity(min(1, max(0.05, alpha)))
    }

    let widths = perPointWidths(
      points: points,
      screenPoints: screenPoints,
      profile: profile,
      axisFactors: axisFactors,
      lineWidth: lineWidth,
      surfaceExtent: surfaceExtent,
      dynamicsScale: dynamicsScale
    )
    // A shape's closed outline has no ends: no caps, no taper, and the curve
    // wraps across the seam. See `InkRenderer.isClosedOutline`.
    let closed = InkRenderer.isClosedOutline(screenPoints, extent: surfaceExtent)
    let centerline =
      closed
      ? InkRenderer.closedSmoothPath(through: Array(screenPoints.dropLast()))
      : InkRenderer.smoothPath(through: screenPoints)

    let paint: (inout GraphicsContext) -> Bool = { layer in
      if let glow = profile.glow {
        layer.stroke(
          centerline,
          with: .color(markColor.opacity(glow.opacity)),
          style: StrokeStyle(lineWidth: lineWidth * glow.width, lineCap: .round, lineJoin: .round)
        )
      }

      if let scatter = profile.scatter {
        guard
          let spray = InkRenderer.scatterPath(
            centerline: screenPoints,
            pressures: points.map { $0.pressure ?? 0.6 },
            width: lineWidth,
            scatter: scatter
          )
        else { return false }
        layer.fill(spray.path, with: .color(markColor))
        return true
      }

      if let grain = profile.grain {
        guard
          let streaks = InkRenderer.grainStreaks(
            centerline: screenPoints,
            widths: widths ?? [lineWidth],
            grain: grain,
            closed: closed
          )
        else { return false }
        for streak in streaks {
          layer.stroke(
            streak.path,
            with: .color(markColor.opacity(streak.alpha)),
            style: StrokeStyle(
              lineWidth: streak.width,
              lineCap: .butt,
              lineJoin: .round,
              dash: streak.dash
            )
          )
        }
        return true
      }

      // A dash shorter than a couple of nib widths is a capsule: it falls
      // through to the uniform stroke below at the nominal nib. Not for a broad
      // nib or a tilted pencil, whose width axis is real on a short mark too.
      let capsule =
        axisFactors == nil && InkRenderer.isShortStroke(screenPoints, lineWidth: lineWidth)
      let halfWidths = widths?.map { max($0 / 2, lineWidth * 0.04) }
      if let halfWidths, !capsule,
        let ribbon = closed
          ? InkRenderer.closedRibbonPath(centerline: screenPoints, halfWidths: halfWidths)
          : InkRenderer.ribbonPath(
            centerline: screenPoints,
            halfWidths: halfWidths,
            flatNib: profile.flatNib,
            allowShortAxis: axisFactors != nil
          )
      {
        layer.fill(ribbon, with: .color(markColor))
        return true
      }

      // Uniform instruments, and the fallback when a ribbon degenerates.
      guard screenPoints.count >= 2 else { return false }
      layer.stroke(
        centerline,
        with: .color(markColor),
        style: StrokeStyle(
          lineWidth: lineWidth,
          lineCap: profile.flatNib ? .butt : .round,
          lineJoin: .round
        )
      )
      return true
    }

    // The tooth is page-registered: it masks the finished mark rather than
    // being folded into the geometry, so two strokes over the same patch of
    // board skip the same valleys and bare paper survives the overlap.
    //
    // **The ramp is `1 - depth * (1 - h)`, composited from the raw field.**
    // `RemoteDrawInk.toothImage` carries the sheet's own height in its alpha and
    // nothing else, because the group ceiling in `withCapacity` needs the same
    // field at a different ramp and cannot recover `h` from a pre-flattened one.
    // A flat alpha of `1 - depth` under the field at full opacity composites
    // source-over to exactly `(1 - depth) + depth * h`, which is that ramp; at
    // the old depth of 1 the flat rect degenerates to nothing and this is the
    // field, as before.
    //
    // **What must NOT go here is `capacity(h)`, and it has been tried twice.**
    // The board's law is `capacity(h) * (1 - transmittance)` and it is tempting
    // to fold the ceiling into this mask, which is cheap. Measured, it buys
    // nothing: `capacity` is a ceiling on the board because a whole *group* of
    // strokes accumulates into one transmittance buffer, and a per-stroke
    // multiplier still leaves `1 - ∏(1 - aᵢ·c)` climbing to 1 — grey 23.4 with
    // the capacity mask against 23.7 without it, over a hatch drawn 32 times.
    // It belongs one level up, on a buffer a group has already accumulated
    // into, which is what `withCapacity` is.
    let masked: (inout GraphicsContext) -> Bool = { target in
      // `profile.tooth` is the instrument's half of the question — does this
      // medium ride the paper — and the field is the surface's half.
      guard let tooth = profile.tooth,
        let field = RemoteDrawInk.toothImage(for: surface, extent: surfaceExtent)
      else { return paint(&target) }
      var painted = false
      let sheet = CGRect(origin: .zero, size: CGSize(width: surfaceExtent, height: surfaceExtent))
      target.drawLayer { layer in
        layer.clipToLayer { mask in
          let reserve = 1 - min(1, max(0, tooth.depth))
          if reserve > 0 {
            mask.fill(Path(sheet), with: .color(.black.opacity(reserve)))
          }
          mask.draw(Image(decorative: field, scale: 1), in: sheet)
        }
        painted = paint(&layer)
      }
      return painted
    }

    // Wet media on an absorbent sheet wick past the nib.
    //
    // **The halo is `blur(mark)` clipped to the *inverse* of the mark, which is
    // the whole safety argument.** It keeps only what the blur put outside the
    // mark's own silhouette and nothing at all inside it, so the body is
    // untouched by construction: no absorbency setting can move a wet block's
    // mean, and the four open web-vs-native wet divergences — all of them in how
    // the body rasterises — are left exactly as they were. It also means this
    // cannot make a lift *fail*, which is why dry-out lives in the taper
    // (`InkRenderer.dryOutExit`) instead of here.
    //
    // Mirrors the SVG filter `FreehandToothDefs` emits, primitive for primitive:
    // `feGaussianBlur` is `.blur`, `feComposite operator="out"` is the inverse
    // clip, and `feComposite operator="in"` against the fibre ramp is the field
    // clip below. The web merges the mark over the halo; here the halo is simply
    // painted first.
    let wicked: (inout GraphicsContext) -> Bool = { target in
      guard let edge = profile.edge else { return masked(&target) }
      let sheet = CGRect(origin: .zero, size: CGSize(width: surfaceExtent, height: surfaceExtent))
      let field = RemoteDrawInk.toothImage(for: surface, extent: surfaceExtent)
      target.drawLayer { halo in
        // The sheet decides how far the halo got along each fibre. The same
        // affine the tooth mask uses — a flat `1 - bleed` under the raw height
        // field composites source-over to `(1 - bleed) + bleed*h` — because the
        // field image carries `h` in its alpha and nothing else.
        //
        // With no field the clip is skipped and the halo is a smooth feather,
        // which is the same all-pass degradation the web's mask fallback takes.
        if let field {
          halo.clipToLayer { mask in
            let reserve = 1 - min(1, max(0, edge.bleed))
            if reserve > 0 {
              mask.fill(Path(sheet), with: .color(.black.opacity(reserve)))
            }
            mask.draw(Image(decorative: field, scale: 1), in: sheet)
          }
        }
        halo.drawLayer { band in
          // Everything outside the mark: the inverse clip is `A out B`.
          band.clipToLayer(options: .inverse) { cut in _ = paint(&cut) }
          band.addFilter(.blur(radius: edge.feather))
          band.drawLayer { spread in _ = paint(&spread) }
        }
      }
      // The mark last, so its own pixels are the ones that survive.
      return masked(&target)
    }

    guard profile.multiply || profile.flatten else { return wicked(&context) }
    // Opaque into an isolated layer whose alpha is the stroke's, so a stroke
    // crossing itself stays one density.
    //
    // **The blend used to be set here and is not any more.** Set on a layer it
    // governs what is drawn *into* that layer — whose backdrop is empty — so it
    // never reached the page and the highlighter was silently source-over. It
    // belongs to the run, both because that is the only placement that
    // composites against the page and because a per-stroke multiply compounds
    // without bound. See `RemoteDrawInkComposer.draw` and `RemoteDrawInk.Film`.
    //
    // The layer itself stays: each stroke inside the run must carry its own
    // alpha, which is what makes the run's buffer accumulate `1 - ∏(1 - aᵢ)`
    // rather than one flat wash.
    var painted = false
    context.drawLayer { layer in
      layer.opacity = strokeOpacity
      painted = wicked(&layer)
    }
    return painted
  }

  /// The width the stroke reaches at each sample; nil for uniform instruments.
  static func perPointWidths(
    points: [RemoteDrawNormalizedPoint],
    screenPoints: [CGPoint],
    profile: RemoteDrawInk.Profile,
    axisFactors: [Double]?,
    lineWidth: CGFloat,
    surfaceExtent: CGFloat,
    dynamicsScale: CGSize = CGSize(width: 1, height: 1)
  ) -> [CGFloat]? {
    let factors: [Double]
    if let axisFactors {
      factors = axisFactors
    } else if let band = profile.band {
      factors = InkRenderer.widthFactors(for: points, range: band, coordinateScale: dynamicsScale)
    } else {
      return nil
    }
    guard factors.count == screenPoints.count else { return nil }
    // A closed outline has no ends to taper; see `InkRenderer.isClosedOutline`.
    let closed = InkRenderer.isClosedOutline(screenPoints, extent: surfaceExtent)
    let tapers = (closed ? nil : profile.taper).map {
      // The stroke width goes with it: each end's length is capped in nib
      // widths, which is what keeps an instrument the same shape at every
      // width. Mirrors `perPointStrokeWidths` on the web.
      InkRenderer.taperMultipliers(
        for: screenPoints, surfaceExtent: surfaceExtent, profile: $0, strokeWidth: lineWidth)
    }
    return factors.enumerated().map { index, factor in
      let taper = tapers?[index] ?? 1
      return max(CGFloat(factor * taper) * lineWidth, lineWidth * 0.08)
    }
  }

  // MARK: Shapes

  /// Paints a snapped shape as ink, one mark per outline — an arrow is two,
  /// shaft then head.
  private static func drawShapeAsInk(
    outlines: [[RemoteDrawNormalizedPoint]],
    stroke: Stroke,
    kind: DrawingStyleKind?,
    in context: inout GraphicsContext,
    size: CGSize,
    color: Color,
    baseColor: Color,
    opacity: Double,
    lineWidth: CGFloat,
    defaults: Defaults,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind,
    dynamicsScale: CGSize = CGSize(width: 1, height: 1)
  ) -> Bool {
    if stroke.type == "rectangle" || stroke.type == "ellipse",
      let fillColor = resolvedFillColor(for: stroke.style, kind: kind, defaults: defaults),
      let outline = outlines.first
    {
      let screenPoints = outline.map { scaled($0, in: size) }
      if screenPoints.count >= 3 {
        context.fill(
          washPath(screenPoints, extent: max(size.width, size.height)), with: .color(fillColor))
      }
    }

    let isFlatNib = kind == .highlighter || kind == .chalk
    func paintOutlines(_ target: inout GraphicsContext, strokeOpacity: Double, color: Color) -> Bool {
      var painted = false
      for outline in outlines {
        let screenPoints = outline.map { scaled($0, in: size) }
        guard screenPoints.count >= 2 else { continue }
        if drawFreehandMark(
          points: outline,
          screenPoints: screenPoints,
          kind: kind,
          baseColor: baseColor,
          strokeOpacity: strokeOpacity,
          lineWidth: lineWidth,
          size: size,
          in: &target,
          surface: surface,
          dynamicsScale: dynamicsScale
        ) {
          painted = true
          continue
        }
        target.stroke(
          InkRenderer.smoothPath(through: screenPoints),
          with: .color(color),
          style: StrokeStyle(
            lineWidth: lineWidth,
            lineCap: isFlatNib ? .butt : .round,
            lineJoin: .round
          )
        )
        painted = true
      }
      return painted
    }

    // An arrow is two outlines — shaft, then head — but one mark. Painted one
    // after the other, a translucent instrument laid its alpha twice where the
    // head overlaps the shaft (a dark knot at a highlighter arrow's tip), so the
    // outlines paint at full strength into one layer that carries the alpha.
    // Only where that cannot change anything else: a flattened instrument
    // already paints into its own layer, and a single-path one bakes the alpha
    // into its one fill. Mirrors `freehandMarkGroupPaths` on the web.
    let profile = RemoteDrawInk.profile(for: kind, surface: surface)
    let singlePath =
      profile.grain == nil && profile.scatter == nil && profile.glow == nil
      && profile.tooth == nil
    if outlines.count > 1, opacity < 1, profile.multiply || profile.flatten || singlePath {
      // The alpha goes on the context the layer is composited *from*; set
      // inside the layer it would apply to each outline drawn there, which is
      // the doubling this exists to remove.
      var painted = false
      var group = context
      group.opacity *= opacity
      group.drawLayer { layer in
        layer.opacity = 1
        painted = paintOutlines(&layer, strokeOpacity: 1, color: baseColor)
      }
      return painted
    }
    return paintOutlines(&context, strokeOpacity: opacity, color: color)
  }

  private static func fill(
    type: String,
    screenPoints: [CGPoint],
    isFreehand: Bool,
    fillColor: Color,
    surfaceExtent: CGFloat,
    in context: inout GraphicsContext
  ) {
    if type == "rectangle" || type == "ellipse" {
      // Diagonal-pair encodings (legacy replacements) have zero loop area;
      // fill their bounding box instead of the literal point trail.
      if screenPoints.count < 4 {
        let xs = screenPoints.map(\.x)
        let ys = screenPoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max(),
          maxX > minX, maxY > minY
        else { return }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        context.fill(type == "ellipse" ? Path(ellipseIn: rect) : Path(rect), with: .color(fillColor))
      } else {
        var loop = Path()
        loop.move(to: screenPoints[0])
        for point in screenPoints.dropFirst() { loop.addLine(to: point) }
        loop.closeSubpath()
        context.fill(loop, with: .color(fillColor))
      }
    } else if isFreehand, isClosedLoop(screenPoints) {
      context.fill(washPath(screenPoints, extent: surfaceExtent), with: .color(fillColor))
    }
  }

  /// The wash under a closed stroke. A shape's closed outline gets the same
  /// wrapped curve its ribbon is built on, so the wash meets the centerline all
  /// the way round, seam included; a hand-closed loop gets its open curve,
  /// closed straight across the gap. Mirrors `closedLoopFillPath` on the web.
  private static func washPath(_ screenPoints: [CGPoint], extent: CGFloat) -> Path {
    if InkRenderer.isClosedOutline(screenPoints, extent: extent) {
      return InkRenderer.closedSmoothPath(through: Array(screenPoints.dropLast()))
    }
    var loop = InkRenderer.smoothPath(through: screenPoints)
    loop.closeSubpath()
    return loop
  }

  private static func drawArrow(
    from start: CGPoint,
    to end: CGPoint,
    in context: inout GraphicsContext,
    color: Color,
    lineWidth: CGFloat
  ) {
    var shaft = Path()
    shaft.move(to: start)
    shaft.addLine(to: end)
    context.stroke(shaft, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))

    let angle = atan2(end.y - start.y, end.x - start.x)
    let headLength: CGFloat = 24
    let spread = CGFloat.pi / 7
    let left = CGPoint(
      x: end.x - cos(angle - spread) * headLength,
      y: end.y - sin(angle - spread) * headLength
    )
    let right = CGPoint(
      x: end.x - cos(angle + spread) * headLength,
      y: end.y - sin(angle + spread) * headLength
    )
    var head = Path()
    head.move(to: left)
    head.addLine(to: end)
    head.addLine(to: right)
    context.stroke(
      head,
      with: .color(color),
      style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
    )
  }

  // MARK: Style resolution

  static func styleKind(_ style: RemoteDrawDrawingStyle?) -> DrawingStyleKind? {
    style?.kind.flatMap(DrawingStyleKind.init(rawValue:))
  }

  /// Mirrors `resolveFreehandStyle` on the web: the nominal nib width, then the
  /// instrument's own weight on top of it — applied whether or not the width
  /// rode in on the wire, so `{highlighter}` and `{highlighter, width: 6}` stay
  /// the same instrument.
  static func resolvedLineWidth(
    for style: RemoteDrawDrawingStyle?,
    kind: DrawingStyleKind?,
    fallback: CGFloat
  ) -> CGFloat {
    let profile = RemoteDrawInk.profile(for: kind)
    let nominal: CGFloat
    if let width = style?.width, width.isFinite {
      nominal = CGFloat(min(48, max(1, width)))
    } else {
      nominal = fallback * profile.fallbackWidthScale
    }
    return min(48, max(0.5, nominal * profile.widthScale))
  }

  /// The instrument's colour before its opacity is applied. Kept separate so a
  /// flattened stroke can paint opaque into a layer that carries the alpha.
  static func resolvedBaseColor(
    for style: RemoteDrawDrawingStyle?,
    kind: DrawingStyleKind?,
    defaults: Defaults
  ) -> Color {
    if let hex = style?.color, let parsed = color(fromHex: hex) { return parsed }
    if kind == .highlighter { return defaults.highlighterColor }
    return defaults.color
  }

  static func resolvedOpacity(for style: RemoteDrawDrawingStyle?, kind: DrawingStyleKind?) -> Double {
    if let requested = style?.opacity, requested.isFinite {
      return min(1, max(0.05, requested))
    }
    return RemoteDrawInk.profile(for: kind).opacity
  }

  /// Fill wash colour: `fill.color ?? stroke color`, at `fill.opacity ?? 0.16`.
  /// Nil when the style requests no fill.
  static func resolvedFillColor(
    for style: RemoteDrawDrawingStyle?,
    kind: DrawingStyleKind?,
    defaults: Defaults
  ) -> Color? {
    guard let fill = style?.fill else { return nil }
    let base: Color
    if let hex = fill.color, let parsed = color(fromHex: hex) {
      base = parsed
    } else if let hex = style?.color, let parsed = color(fromHex: hex) {
      base = parsed
    } else if kind == .highlighter {
      base = defaults.highlighterColor
    } else {
      base = defaults.color
    }
    let opacity: Double
    if let requested = fill.opacity, requested.isFinite {
      opacity = min(1, max(0.05, requested))
    } else {
      opacity = 0.16
    }
    return base.opacity(opacity)
  }

  public static func color(fromHex value: String) -> Color? {
    let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let number = Int(raw, radix: 16) else { return nil }
    return Color(
      red: Double((number >> 16) & 0xff) / 255,
      green: Double((number >> 8) & 0xff) / 255,
      blue: Double(number & 0xff) / 255
    )
  }

  // MARK: Geometry helpers

  /// Evenly decimates a stroke that exceeds the render budget, always keeping
  /// the first and last sample so the mark neither loses its origin nor its
  /// current head.
  static func decimated(_ points: [RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint] {
    let limit = maxRenderPoints
    guard points.count > limit else { return points }
    let step = Double(points.count - 1) / Double(limit - 1)
    var out: [RemoteDrawNormalizedPoint] = []
    out.reserveCapacity(limit)
    for index in 0..<limit {
      out.append(points[min(points.count - 1, Int((Double(index) * step).rounded()))])
    }
    return out
  }

  /// Same closed-loop rule as the web renderers and shapeAssist: endpoints meet
  /// within 16% of the bounding-box diagonal.
  static func isClosedLoop(_ points: [CGPoint]) -> Bool {
    guard points.count >= 3, let first = points.first, let last = points.last else { return false }
    var minX = CGFloat.infinity
    var minY = CGFloat.infinity
    var maxX = -CGFloat.infinity
    var maxY = -CGFloat.infinity
    for point in points {
      minX = min(minX, point.x)
      minY = min(minY, point.y)
      maxX = max(maxX, point.x)
      maxY = max(maxY, point.y)
    }
    let diagonal = hypot(maxX - minX, maxY - minY)
    guard diagonal > 0 else { return false }
    return hypot(last.x - first.x, last.y - first.y) <= diagonal * 0.16
  }

  static func scaled(_ point: RemoteDrawNormalizedPoint, in size: CGSize) -> CGPoint {
    CGPoint(x: point.x * size.width, y: point.y * size.height)
  }

  private static func fillDot(
    at point: CGPoint,
    radius: CGFloat,
    color: Color,
    in context: inout GraphicsContext
  ) {
    context.fill(
      Path(
        ellipseIn: CGRect(
          x: point.x - radius,
          y: point.y - radius,
          width: radius * 2,
          height: radius * 2
        )
      ),
      with: .color(color)
    )
  }
}
