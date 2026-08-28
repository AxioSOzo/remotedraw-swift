//
//  The pre-Stage-2 draw pass, kept verbatim so the new one can be proved
//  identical **by rendering**, not by review.
//
//  This repository has a recorded incident where a tooth mask was a total
//  no-op for weeks: the source read correctly, the tests were green, and every
//  dry mark on iOS painted unbroken because `clipToLayer` clips by alpha and
//  the field carried its tooth in luminance. Nothing short of a rendered image
//  would have caught it. So when Stage 2 moved `DrawingBoardView`'s ~640-line
//  draw pass out of the app and into `RemoteDrawStrokePainter` /
//  `RemoteDrawInkComposer`, "it compiles and the tests pass" was not evidence
//  that the ink was unchanged.
//
//  What is below is `apps/ios/RemoteDraw/DrawingBoardView.swift` at the commit
//  before this stage — `drawCapped`, `capacityFor`, `pointsForRendering`,
//  `drawStroke`, `drawShapeAsInk`, `drawFreehandMark`, `perPointWidths`,
//  `fillDot`, `drawArrow`, the style resolvers and `drawPaperSheet` — lifted
//  out of the view. Three adaptations, and only three, each marked at the point
//  it happens in the extraction script's own record:
//
//    1. the app's `DrawingStyle` (whose `kind` is an enum) becomes the
//       package's `RemoteDrawDrawingStyle` (whose `kind` is a `String`, for
//       forward compatibility), so `style?.kind` becomes `kindOf(style)`;
//    2. `RemoteDrawTheme.ink` / `.gold` become the same two literals, because
//       the theme is the app's;
//    3. `RemoteDrawSurface` is spelled `RemoteDrawInkSurface` after the rename
//       that freed the old name for the public `View`;
//    4. `scaled` inlines the two lines of `DrawingSurfaceGeometry.surfacePoint`,
//       which now lives in the sibling target this one cannot import.
//
//  Nothing else was touched — not a constant, not an order of operations, not
//  a blend mode. `SurfaceRenderParityTests` renders both paths at 1:1 into the
//  same bitmap and compares them pixel for pixel.
//
//  **Do not "clean this up".** Its only value is being the old code. If the new
//  renderer changes deliberately, this file changes with it in the same commit,
//  and the diff is the record of what moved.
//
import SwiftUI

@testable import RemoteDrawInk

struct LegacyBoardRenderer {
  static let ink = Color(red: 0.09, green: 0.09, blue: 0.08)
  static let gold = Color(red: 0.95, green: 0.79, blue: 0.41)

  let boardDrawingSurface: RemoteDrawInkSurface.Kind
  let groundColor: Color

  /// Adaptation (1): the package's style keeps `kind` a `String` so a board
  /// that learns a new instrument does not fail to decode on an older sender.
  /// Every `style?.kind == …` in the original becomes this.
  private func kindOf(_ style: RemoteDrawDrawingStyle?) -> DrawingStyleKind? {
    style?.kind.flatMap(DrawingStyleKind.init(rawValue:))
  }

  /// see `RemoteDrawPaperGround.tileEdge` — and until the first one lands the
  /// tone alone is painted, which is what the sheet mostly is anyway.
  func drawPaperSheet(in context: inout GraphicsContext, size: CGSize) {
    let page = Path(CGRect(origin: .zero, size: size))
    context.fill(page, with: .color(groundColor))
    guard
      let tile = RemoteDrawPaperGround.tile(
        grain: RemoteDrawInkSurface.grain(boardDrawingSurface))
    else { return }
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
  }

  func drawCapped<Item>(
    _ items: [Item],
    in context: inout GraphicsContext,
    size: CGSize,
    ceiling: (Item) -> RemoteDrawInk.Film?,
    paint: (Item, inout GraphicsContext) -> Void
  ) {
    let extent = max(size.width, size.height)
    let field = RemoteDrawInk.toothImage(for: boardDrawingSurface, extent: extent)
    let sheet = CGRect(origin: .zero, size: CGSize(width: extent, height: extent))
    var index = 0
    while index < items.count {
      let film = ceiling(items[index])
      var end = index + 1
      while end < items.count, ceiling(items[end]) == film { end += 1 }
      let run = items[index..<end]
      // `floor + gain * h` as alpha: a flat floor, then the height field at the
      // opacity that leaves exactly `gain` of headroom. Every instrument holds
      // `floor + gain` below 1 in `DEPOSIT_BY_KIND`, so this never clips. Nil
      // when the film has no ceiling, and also when the sheet's field is not
      // built yet — an uncapped run is the mark this renderer drew before the
      // ceiling existed, where a dropped run would not be.
      var capped: (floor: Double, scale: Double, field: CGImage)?
      if let capacity = film?.capacity, let field, extent > 0 {
        let floor = min(1, max(0, capacity.floor))
        capped = (
          floor: floor,
          scale: floor >= 1 ? 0 : min(1, max(0, capacity.gain / (1 - floor))),
          field: field
        )
      }
      guard capped != nil || film?.multiply == true else {
        for item in run { paint(item, &context) }
        index = end
        continue
      }
      var target = context
      if film?.multiply == true { target.blendMode = .multiply }
      target.drawLayer { outer in
        if let capped {
          outer.clipToLayer { mask in
            if capped.floor > 0 {
              mask.fill(Path(sheet), with: .color(.black.opacity(capped.floor)))
            }
            mask.opacity = capped.scale
            mask.draw(Image(decorative: capped.field, scale: 1), in: sheet)
          }
        }
        outer.drawLayer { inner in
          for item in run { paint(item, &inner) }
        }
      }
      index = end
    }
  }

  /// The film a mark belongs to, or nil for anything that needs no wrapper at
  /// all. Text and the point tool are excluded even under a dry style: neither is
  /// masked by the tooth, so neither is approaching a capacity and folding them
  /// into a group would only dim them.
  func capacityFor(type: String, points: [NormalizedPoint], style: RemoteDrawDrawingStyle?)
    -> RemoteDrawInk.Film?
  {
    guard type != "text", type != "point", points.count > 1 else { return nil }
    return RemoteDrawInk.film(for: kindOf(style), surface: boardDrawingSurface)
  }

  /// How many points a stroke is *drawn* from, however many it stores.
  ///
  /// `Canvas` rebuilds every stroke's geometry every frame — nothing is cached —
  /// so the cost of a frame is (strokes on the board) x (points in each). At the
  /// full point cap that measured 4.1ms for a single dry-media stroke against an
  /// 8.3ms budget at 120Hz, on the simulator; a phone is several times slower,
  /// and iOS kills an app whose main thread stalls.
  ///
  /// Capping the *stored* points was the wrong lever: it throws away fidelity
  /// that the receiver and the exported artwork both want, to solve a problem
  /// that only exists in this preview. On a phone-sized canvas the points of a
  /// 1200-point stroke are far below a pixel apart, so drawing from a decimated
  /// copy is visually indistinguishable and several times cheaper. Storage,
  /// transport and commits keep every sample.
  static let maxRenderPoints = 320

  /// Evenly decimates for drawing only, always keeping the first and last point
  /// so the stroke neither shifts its origin nor stops short of the finger.
  func pointsForRendering(_ points: [NormalizedPoint]) -> [NormalizedPoint] {
    let limit = Self.maxRenderPoints
    guard points.count > limit else { return points }
    let step = Double(points.count - 1) / Double(limit - 1)
    var out: [NormalizedPoint] = []
    out.reserveCapacity(limit)
    for index in 0..<limit {
      out.append(points[min(points.count - 1, Int((Double(index) * step).rounded()))])
    }
    return out
  }

  func drawStroke(
    points: [NormalizedPoint],
    type: String,
    text: String?,
    in context: inout GraphicsContext,
    size: CGSize,
    color: Color,
    style: RemoteDrawDrawingStyle? = nil,
    lineWidth: CGFloat
  ) {
    let points = pointsForRendering(points)
    guard let first = points.first else { return }
    let resolvedLineWidth = resolvedLineWidth(for: style, fallback: lineWidth)
    let resolvedColor = resolvedColor(for: style, fallback: color)
    if type == "text" {
      guard let text, !text.isEmpty else { return }
      let point = scaled(first, in: size)
      var resolved = context.resolve(
        Text(text)
          .font(.system(size: 28, weight: .bold))
      )
      resolved.shading = .color(resolvedColor)
      context.draw(resolved, at: point, anchor: .leading)
      return
    }
    // The point tool is a deliberate marker: oversized so a tap reads from
    // across the room on the receiver.
    if type == "point" {
      fillDot(at: scaled(first, in: size), radius: max(8, resolvedLineWidth * 2.6), color: resolvedColor, in: &context)
      return
    }
    // A just-started stroke has only its first sample: show ink at finger
    // scale, not a point-tool blob. Mirrors the web renderer so the head of a
    // stroke doesn't pop from 2.6x width down to the line width on sample two.
    if points.count == 1 {
      fillDot(at: scaled(first, in: size), radius: max(resolvedLineWidth / 2, 2.5), color: resolvedColor, in: &context)
      return
    }

    // A snapped shape is still ink: a straightened pencil line has to stay a
    // pencil line. `shapeInkStrokes` gives back the polyline a hand would have
    // travelled, so the shape goes through the same freehand mark assembler as
    // everything else and picks up grain, tooth, taper and dynamics for free.
    let surfaceExtent = max(size.width, size.height)
    if surfaceExtent > 0,
       let outlines = InkRenderer.shapeInkStrokes(
         type: type,
         points: points,
         strokeWidth: Double(resolvedLineWidth / surfaceExtent)
       ),
       drawShapeAsInk(
         outlines: outlines,
         type: type,
         in: &context,
         size: size,
         color: color,
         resolvedColor: resolvedColor,
         style: style,
         lineWidth: resolvedLineWidth
       ) {
      return
    }

    if type == "arrow", let start = points.first, let end = points.last {
      drawArrow(from: scaled(start, in: size), to: scaled(end, in: size), in: &context, color: resolvedColor, lineWidth: resolvedLineWidth)
      return
    }

    let screenPoints = points.map { scaled($0, in: size) }
    let isFreehand = type == "freehand" || type == "auto"

    // Enclosed-area wash painted beneath the stroke when the style requests a
    // fill: shape primitives always, freehand only when the loop closes.
    if let fillColor = resolvedFillColor(for: style, fallback: color) {
      if type == "rectangle" || type == "ellipse" {
        // Diagonal-pair encodings (legacy replacements) have zero loop area;
        // fill their bounding box instead of the literal point trail.
        if screenPoints.count < 4 {
          let xs = screenPoints.map(\.x)
          let ys = screenPoints.map(\.y)
          if let minX = xs.min(), let maxX = xs.max(),
             let minY = ys.min(), let maxY = ys.max(), maxX > minX, maxY > minY {
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let loop = type == "ellipse" ? Path(ellipseIn: rect) : Path(rect)
            context.fill(loop, with: .color(fillColor))
          }
        } else {
          var loop = Path()
          loop.move(to: screenPoints[0])
          for point in screenPoints.dropFirst() {
            loop.addLine(to: point)
          }
          loop.closeSubpath()
          context.fill(loop, with: .color(fillColor))
        }
      } else if isFreehand, isClosedLoop(screenPoints) {
        var loop = InkRenderer.smoothPath(through: screenPoints)
        loop.closeSubpath()
        context.fill(loop, with: .color(fillColor))
      }
    }

    // Freehand marks are assembled from the instrument profile — the same
    // table the web resolves through, so a stroke drawn here and a stroke
    // replayed on a receiver are the same mark.
    if isFreehand,
       drawFreehandMark(
         points: points,
         screenPoints: screenPoints,
         style: style,
         baseColor: resolvedBaseColor(for: style, fallback: color),
         strokeOpacity: resolvedOpacity(for: style),
         lineWidth: resolvedLineWidth,
         size: size,
         in: &context
       ) {
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
      for point in screenPoints.dropFirst() {
        polyline.addLine(to: point)
      }
      path = polyline
    }
    // Flat nibs: a highlighter's chisel and chalk's crumbling end.
    let isFlatNib = kindOf(style) == .highlighter || kindOf(style) == .chalk
    let lineCap: CGLineCap = isFreehand && isFlatNib ? .butt : .round
    context.stroke(
      path,
      with: .color(resolvedColor),
      style: StrokeStyle(lineWidth: resolvedLineWidth, lineCap: lineCap, lineJoin: .round)
    )
  }

  /// Paints a snapped shape as ink, one mark per outline — an arrow is two,
  /// shaft then head. Returns false when nothing could be painted, so the
  /// caller falls back to its primitive.
  func drawShapeAsInk(
    outlines: [[NormalizedPoint]],
    type: String,
    in context: inout GraphicsContext,
    size: CGSize,
    color: Color,
    resolvedColor: Color,
    style: RemoteDrawDrawingStyle?,
    lineWidth: CGFloat
  ) -> Bool {
    // Enclosed-area wash beneath the shape when the style requests a fill.
    // The ink outline is the loop, so a two-point diagonal fills its box.
    if (type == "rectangle" || type == "ellipse"),
       let fillColor = resolvedFillColor(for: style, fallback: color),
       let outline = outlines.first {
      let screenPoints = outline.map { scaled($0, in: size) }
      if screenPoints.count >= 3 {
        var loop = Path()
        loop.move(to: screenPoints[0])
        for point in screenPoints.dropFirst() {
          loop.addLine(to: point)
        }
        loop.closeSubpath()
        context.fill(loop, with: .color(fillColor))
      }
    }

    var painted = false
    let isFlatNib = kindOf(style) == .highlighter || kindOf(style) == .chalk
    for outline in outlines {
      let screenPoints = outline.map { scaled($0, in: size) }
      guard screenPoints.count >= 2 else { continue }
      if drawFreehandMark(
        points: outline,
        screenPoints: screenPoints,
        style: style,
        baseColor: resolvedBaseColor(for: style, fallback: color),
        strokeOpacity: resolvedOpacity(for: style),
        lineWidth: lineWidth,
        size: size,
        in: &context
      ) {
        painted = true
        continue
      }
      // The profile's primitive could not take this geometry: stroke the
      // outline plainly rather than dropping the mark entirely.
      context.stroke(
        InkRenderer.smoothPath(through: screenPoints),
        with: .color(resolvedColor),
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

  /// Paints one freehand mark from its instrument profile. Returns false when
  /// the geometry is too degenerate for the profile's primitive, so the caller
  /// falls back to a plain stroked path.
  func drawFreehandMark(
    points: [NormalizedPoint],
    screenPoints: [CGPoint],
    style: RemoteDrawDrawingStyle?,
    baseColor: Color,
    strokeOpacity: Double,
    lineWidth: CGFloat,
    size: CGSize,
    in context: inout GraphicsContext
  ) -> Bool {
    let profile = RemoteDrawInk.profile(for: kindOf(style), surface: boardDrawingSurface)
    // How much of the paper's ceiling one pass of this instrument takes. It
    // rides with the tooth rather than with the instrument: a dry medium on a
    // surface with no tooth has no `capacity` to approach — nothing masks it and
    // nothing caps it — so scaling its alpha there would just draw a faint
    // pencil on a whiteboard. See `RemoteDrawInk.Profile.toneScale`.
    let tone = profile.tooth == nil ? 1 : profile.toneScale
    // Flattened instruments paint opaque and let the layer carry the alpha;
    // everything else bakes it into the colour as before.
    let color = profile.multiply || profile.flatten
      ? baseColor
      : baseColor.opacity(strokeOpacity * tone)
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
      surfaceExtent: surfaceExtent
    )

    // A flattened stroke paints opaque into an isolated layer that carries the
    // alpha, so self-overlap does not double in density; multiply makes a pass
    // over existing ink tint it rather than grey it out.
    let paint: (inout GraphicsContext) -> Bool = { layer in
      if let glow = profile.glow {
        layer.stroke(
          InkRenderer.smoothPath(through: screenPoints),
          with: .color(markColor.opacity(glow.opacity)),
          style: StrokeStyle(lineWidth: lineWidth * glow.width, lineCap: .round, lineJoin: .round)
        )
      }

      if let scatter = profile.scatter {
        guard let spray = InkRenderer.scatterPath(
          centerline: screenPoints,
          pressures: points.map { $0.pressure ?? 0.6 },
          width: lineWidth,
          scatter: scatter
        ) else { return false }
        layer.fill(spray.path, with: .color(markColor))
        return true
      }

      if let grain = profile.grain {
        guard let streaks = InkRenderer.grainStreaks(
          centerline: screenPoints,
          widths: widths ?? [lineWidth],
          grain: grain
        ) else { return false }
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

      if let widths, let ribbon = InkRenderer.ribbonPath(
        centerline: screenPoints,
        halfWidths: widths.map { max($0 / 2, lineWidth * 0.04) }
      ) {
        layer.fill(ribbon, with: .color(markColor))
        return true
      }

      // Uniform instruments, and the fallback when a ribbon degenerates.
      guard screenPoints.count >= 2 else { return false }
      layer.stroke(
        InkRenderer.smoothPath(through: screenPoints),
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
    // The ramp is `1 - depth * (1 - h)`, composited from the raw field:
    // `RemoteDrawInk.toothImage` carries the sheet's own height and nothing
    // else, because the group ceiling needs the same field at a different ramp.
    // A flat alpha of `1 - depth` under it at full opacity is that ramp exactly.
    //
    // What must NOT go here is `capacity(h)`. A per-stroke multiplier is not a
    // ceiling — see `StrokePainter.drawFreehandMark`, where it was built and
    // measured twice — and the ceiling lives in `capacityGroups` below.
    let masked: (inout GraphicsContext) -> Bool = { target in
      // `profile.tooth` is the instrument's half of the question — does this
      // medium ride the paper — and the field is the surface's half.
      guard let tooth = profile.tooth,
            let field = RemoteDrawInk.toothImage(
              for: boardDrawingSurface, extent: surfaceExtent)
      else { return paint(&target) }
      var painted = false
      let sheet = CGRect(origin: .zero, size: CGSize(width: surfaceExtent, height: surfaceExtent))
      target.drawLayer { layer in
        layer.clipToLayer { mask in
          let reserve = 1 - min(1, max(0, tooth.depth))
          if reserve > 0 { mask.fill(Path(sheet), with: .color(.black.opacity(reserve))) }
          mask.draw(Image(decorative: field, scale: 1), in: sheet)
        }
        painted = paint(&layer)
      }
      return painted
    }

    guard profile.multiply || profile.flatten else {
      return masked(&context)
    }
    // Opaque into an isolated layer whose alpha is the stroke's, so a stroke
    // crossing itself stays one density.
    //
    // **The blend used to be set here and is not any more.** Set on a layer it
    // governs what is drawn *into* that layer — whose backdrop is empty — so it
    // never reached the page and the highlighter was silently source-over. It
    // belongs to the run: see `drawCapped` and `RemoteDrawInk.Film`.
    var painted = false
    context.drawLayer { layer in
      layer.opacity = strokeOpacity
      painted = masked(&layer)
    }
    return painted
  }

  /// The width the stroke reaches at each sample; nil for uniform instruments.
  func perPointWidths(
    points: [NormalizedPoint],
    screenPoints: [CGPoint],
    profile: RemoteDrawInk.Profile,
    axisFactors: [Double]?,
    lineWidth: CGFloat,
    surfaceExtent: CGFloat
  ) -> [CGFloat]? {
    let factors: [Double]
    if let axisFactors {
      factors = axisFactors
    } else if let band = profile.band {
      factors = InkRenderer.widthFactors(for: points, range: band)
    } else {
      return nil
    }
    guard factors.count == screenPoints.count else { return nil }
    let tapers = profile.taper.map {
      // The stroke width goes with it: each end's length is capped in nib
      // widths, which is what keeps an instrument the same shape at every
      // width. Mirrors `perPointStrokeWidths` on the web.
      InkRenderer.taperMultipliers(
        for: screenPoints, surfaceExtent: surfaceExtent, profile: $0,
        strokeWidth: lineWidth)
    }
    return factors.enumerated().map { index, factor in
      let taper = tapers?[index] ?? 1
      return max(CGFloat(factor * taper) * lineWidth, lineWidth * 0.08)
    }
  }

  func fillDot(at point: CGPoint, radius: CGFloat, color: Color, in context: inout GraphicsContext) {
    context.fill(
      Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
      with: .color(color)
    )
  }

  func drawArrow(
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
    let left = CGPoint(x: end.x - cos(angle - spread) * headLength, y: end.y - sin(angle - spread) * headLength)
    let right = CGPoint(x: end.x - cos(angle + spread) * headLength, y: end.y - sin(angle + spread) * headLength)
    var head = Path()
    head.move(to: left)
    head.addLine(to: end)
    head.addLine(to: right)
    context.stroke(head, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
  }

  /// Mirrors resolveFreehandStyle on the web: the nominal nib width, then the
  /// instrument's own weight on top of it — applied whether or not the width
  /// rode in on the wire, so `{highlighter}` and `{highlighter, width: 6}`
  /// stay the same instrument.
  func resolvedLineWidth(for style: RemoteDrawDrawingStyle?, fallback: CGFloat) -> CGFloat {
    let profile = RemoteDrawInk.profile(for: kindOf(style))
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
  func resolvedBaseColor(for style: RemoteDrawDrawingStyle?, fallback: Color) -> Color {
    if let color = style?.color, let parsed = colorFromHex(color) {
      return parsed
    }
    if kindOf(style) == .highlighter {
      return LegacyBoardRenderer.gold
    }
    return fallback
  }

  func resolvedOpacity(for style: RemoteDrawDrawingStyle?) -> Double {
    if let requestedOpacity = style?.opacity, requestedOpacity.isFinite {
      return min(1, max(0.05, requestedOpacity))
    }
    return RemoteDrawInk.profile(for: kindOf(style)).opacity
  }

  func resolvedColor(for style: RemoteDrawDrawingStyle?, fallback: Color) -> Color {
    resolvedBaseColor(for: style, fallback: fallback)
      .opacity(resolvedOpacity(for: style))
  }

  /// Fill wash color: fill.color ?? stroke color, at fill.opacity ?? 0.16.
  /// Returns nil when the style requests no fill.
  func resolvedFillColor(for style: RemoteDrawDrawingStyle?, fallback: Color) -> Color? {
    guard let fill = style?.fill else { return nil }
    let base: Color
    if let hex = fill.color, let parsed = colorFromHex(hex) {
      base = parsed
    } else if let hex = style?.color, let parsed = colorFromHex(hex) {
      base = parsed
    } else if kindOf(style) == .highlighter {
      base = LegacyBoardRenderer.gold
    } else {
      base = fallback
    }
    let opacity: Double
    if let requested = fill.opacity, requested.isFinite {
      opacity = min(1, max(0.05, requested))
    } else {
      opacity = 0.16
    }
    return base.opacity(opacity)
  }

  /// Same closed-loop rule as the web renderers and shapeAssist: endpoints
  /// meet within 16% of the bounding-box diagonal.
  func isClosedLoop(_ points: [CGPoint]) -> Bool {
    guard points.count >= 3, let first = points.first, let last = points.last else {
      return false
    }
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

  func colorFromHex(_ value: String) -> Color? {
    let raw = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let number = Int(raw, radix: 16) else { return nil }
    return Color(
      red: Double((number >> 16) & 0xff) / 255.0,
      green: Double((number >> 8) & 0xff) / 255.0,
      blue: Double(number & 0xff) / 255.0
    )
  }

  /// Adaptation (4): `DrawingSurfaceGeometry` moved into the package as
  /// `RemoteDrawDrawingSurfaceGeometry`, which is a different *target* from
  /// this one, so the two lines it was are inlined rather than imported. The
  /// arithmetic is character for character what that function does.
  func scaled(_ point: NormalizedPoint, in size: CGSize) -> CGPoint {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0
    else { return .zero }
    return CGPoint(x: point.x * size.width, y: point.y * size.height)
  }
}
