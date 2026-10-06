// The sixteen instruments, the colour well and the arc band the Pencil Pro arc
// is drawn with. Ported from the approved prototype's `Tool16`
// (`output/puck-arc-20260924/ArcProto.swift`): a white, softly lit barrel, a
// thin ink band on inked tools, and the working end dipped in the current ink.
//
// Every inked surface is a flat ink fill with the cylinder's light laid over it
// as white/black alpha, rather than a gradient built from mixed colours. The
// two are the same pixels (mixing toward white by `a` *is* white at alpha `a`
// over the base), but a flat `Color` fill animates when the ink changes, which
// is what lets every tip re-dip smoothly under a hovered swatch — and it needs
// no iOS 18 `Color.mix`.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  // MARK: - Light

  /// The cylinder's lighting as an overlay: dark rim, bright highlight a third
  /// of the way across, dark far rim.
  private let cylinderLight = LinearGradient(
    stops: [
      .init(color: .black.opacity(0.2), location: 0),
      .init(color: .white.opacity(0.55), location: 0.3),
      .init(color: .white.opacity(0.7), location: 0.42),
      .init(color: .clear, location: 0.72),
      .init(color: .black.opacity(0.25), location: 1),
    ], startPoint: .leading, endPoint: .trailing)

  private func cylinder(_ base: Color) -> LinearGradient {
    LinearGradient(
      stops: [
        .init(color: base.puckMixed(with: .black, by: 0.2), location: 0),
        .init(color: base.puckMixed(with: .white, by: 0.55), location: 0.3),
        .init(color: base.puckMixed(with: .white, by: 0.7), location: 0.42),
        .init(color: base, location: 0.72),
        .init(color: base.puckMixed(with: .black, by: 0.25), location: 1),
      ], startPoint: .leading, endPoint: .trailing)
  }

  private let whiteBarrel = cylinder(Color(white: 0.9))
  private let metalBarrel = cylinder(Color(white: 0.62))
  private let darkBarrel = cylinder(Color(white: 0.2))
  private let nibHolder = cylinder(Color(white: 0.25))
  private let wrapperPaper = cylinder(Color(red: 0.96, green: 0.94, blue: 0.88))
  private let wood = LinearGradient(
    colors: [
      Color(red: 0.83, green: 0.66, blue: 0.45), Color(red: 0.96, green: 0.86, blue: 0.70),
      Color(red: 0.80, green: 0.62, blue: 0.40),
    ], startPoint: .leading, endPoint: .trailing)
  private let gold = LinearGradient(
    colors: [
      Color(red: 0.72, green: 0.6, blue: 0.35), Color(red: 0.95, green: 0.85, blue: 0.6),
      Color(red: 0.7, green: 0.58, blue: 0.33),
    ], startPoint: .leading, endPoint: .trailing)

  extension Color {
    /// Mixes toward a static colour for gradients that never animate. Resolved
    /// in sRGB; iOS 17 has no `Color.mix`.
    fileprivate func puckMixed(with other: Color, by amount: Double) -> Color {
      let a = UIColor(self), b = UIColor(other)
      var (r1, g1, b1, a1): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
      var (r2, g2, b2, a2): (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
      a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
      b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
      let t = CGFloat(amount)
      return Color(
        red: Double(r1 + (r2 - r1) * t), green: Double(g1 + (g2 - g1) * t),
        blue: Double(b1 + (b2 - b1) * t), opacity: Double(a1 + (a2 - a1) * t))
    }
  }

  /// An inked surface: the ink, optionally lightened or darkened first (chalk
  /// is the ink in pastel, charcoal the ink burnt), then lit as a cylinder.
  private struct InkedShape<S: Shape>: View {
    let shape: S
    let ink: Color
    var lighten: Double = 0
    var darken: Double = 0
    var lit = true

    var body: some View {
      ZStack {
        shape.fill(ink)
        if lighten > 0 { shape.fill(Color.white.opacity(lighten)) }
        if darken > 0 { shape.fill(Color.black.opacity(darken)) }
        if lit { shape.fill(cylinderLight) }
      }
    }
  }

  // MARK: - The instrument

  /// One of the sixteen instruments, upright, tip at the top. About 24pt wide
  /// and 120pt tall; the arc rotates it normal to the band, tip up.
  struct RemoteDrawPuckInstrument: View {
    let kind: DrawingStyleKind
    let ink: Color

    var body: some View {
      VStack(spacing: 0) {
        tip
        barrel
      }
      .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
    }

    private func inked<S: Shape>(_ shape: S, lighten: Double = 0, darken: Double = 0) -> some View {
      InkedShape(shape: shape, ink: ink, lighten: lighten, darken: darken)
    }

    @ViewBuilder private var barrel: some View {
      switch kind {
      case .chalk:
        inked(Rectangle(), lighten: 0.45).frame(width: 20, height: 90)
      case .charcoal:
        inked(Rectangle(), darken: 0.55).frame(width: 16, height: 90)
      case .crayon:
        ZStack(alignment: .top) {
          inked(Rectangle())
          Rectangle().fill(wrapperPaper).frame(height: 70).offset(y: 14)
          inked(Rectangle()).frame(height: 2).offset(y: 22)
          inked(Rectangle()).frame(height: 2).offset(y: 76)
        }
        .frame(width: 22, height: 90)
      case .neon:
        ZStack(alignment: .top) {
          Rectangle().fill(darkBarrel)
          inked(Rectangle()).frame(height: 3).offset(y: 12)
        }
        .frame(width: 22, height: 90)
      case .airbrush:
        Rectangle().fill(metalBarrel).frame(width: 18, height: 90)
      default:
        ZStack(alignment: .top) {
          Rectangle().fill(whiteBarrel)
          Rectangle().fill(Color.black.opacity(0.07)).frame(height: 0.5).offset(y: 10)
          if ![.pencil, .tiltPencil, .italicNib].contains(kind) {
            inked(Rectangle())
              .frame(height: kind == .highlighter ? 8 : 4)
              .opacity(kind == .highlighter ? 0.7 : 1)
              .offset(y: 14)
          }
        }
        .frame(width: barrelWidth, height: 90)
      }
    }

    private var barrelWidth: CGFloat {
      switch kind {
      case .highlighter: return 30
      case .chiselMarker: return 27
      case .ballpoint: return 17
      case .fineliner, .italicNib: return 19
      default: return 23
      }
    }

    @ViewBuilder private var tip: some View {
      switch kind {
      case .ink:
        VStack(spacing: 0) {
          inked(Capsule()).frame(width: 2.2, height: 7)
          PuckTrapezoid(top: 5, bottom: 23).fill(whiteBarrel).frame(width: 23, height: 26)
        }
      case .whiteboardMarker:
        VStack(spacing: 0) {
          inked(UnevenRoundedRectangle(topLeadingRadius: 5, topTrailingRadius: 5))
            .frame(width: 10, height: 10)
          Rectangle().fill(metalBarrel).frame(width: 13, height: 5)
          PuckTrapezoid(top: 13, bottom: 23).fill(whiteBarrel).frame(width: 23, height: 12)
        }
      case .brushPen:
        VStack(spacing: 0) {
          inked(PuckBristle()).frame(width: 9, height: 20)
          PuckTrapezoid(top: 9, bottom: 23).fill(whiteBarrel).frame(width: 23, height: 14)
        }
      case .fineliner:
        VStack(spacing: 0) {
          inked(Rectangle()).frame(width: 1.4, height: 4)
          Rectangle().fill(metalBarrel).frame(width: 3, height: 11)
          PuckTrapezoid(top: 5, bottom: 19).fill(whiteBarrel).frame(width: 19, height: 20)
        }
      case .ballpoint:
        VStack(spacing: 0) {
          inked(Circle()).frame(width: 2.5, height: 2.5)
          PuckTrapezoid(top: 2.5, bottom: 9).fill(metalBarrel).frame(width: 9, height: 9)
          PuckTrapezoid(top: 9, bottom: 17).fill(whiteBarrel).frame(width: 17, height: 16)
        }
      case .pencil, .tiltPencil:
        ZStack(alignment: .top) {
          PuckTrapezoid(top: kind == .tiltPencil ? 5 : 1.5, bottom: 23, scallop: true)
            .fill(wood)
            .frame(width: 23, height: 30)
            .offset(y: kind == .tiltPencil ? 4 : 0)
          if kind == .tiltPencil {
            inked(PuckChisel()).frame(width: 7, height: 10)
          } else {
            inked(PuckTrapezoid(top: 1.5, bottom: 7)).frame(width: 7, height: 9)
          }
        }
        .frame(height: 34, alignment: .bottom)
      case .chalk:
        inked(UnevenRoundedRectangle(topLeadingRadius: 7, topTrailingRadius: 9), lighten: 0.45)
          .frame(width: 20, height: 22)
      case .charcoal:
        inked(PuckChisel(), darken: 0.55).frame(width: 16, height: 18)
      case .crayon:
        inked(PuckTrapezoid(top: 7, bottom: 22)).frame(width: 22, height: 18)
      case .dryBrush:
        VStack(spacing: 0) {
          HStack(alignment: .bottom, spacing: 1) {
            ForEach(0..<6, id: \.self) { k in
              inked(Capsule()).frame(width: 2.2, height: [12, 16, 14, 17, 13, 15][k])
            }
          }
          .frame(width: 20, height: 17, alignment: .bottom)
          Rectangle().fill(metalBarrel).frame(width: 18, height: 13)
          PuckTrapezoid(top: 18, bottom: 23).fill(whiteBarrel).frame(width: 23, height: 6)
        }
      case .italicNib:
        VStack(spacing: 0) {
          ZStack {
            PuckTrapezoid(top: 9, bottom: 13).fill(gold)
            Rectangle().fill(Color.black.opacity(0.35)).frame(width: 0.7, height: 12).offset(y: -4)
            Circle().fill(Color.black.opacity(0.35)).frame(width: 2.5, height: 2.5).offset(y: 3)
            inked(Rectangle()).frame(width: 9, height: 3).offset(y: -10.5)
          }
          .frame(width: 13, height: 24)
          PuckTrapezoid(top: 13, bottom: 19).fill(nibHolder).frame(width: 19, height: 12)
        }
      case .chiselMarker:
        VStack(spacing: 0) {
          inked(PuckChisel()).frame(width: 15, height: 12)
          Rectangle().fill(metalBarrel).frame(width: 17, height: 5)
          PuckTrapezoid(top: 17, bottom: 27).fill(whiteBarrel).frame(width: 27, height: 12)
        }
      case .highlighter:
        VStack(spacing: 0) {
          inked(PuckChisel()).opacity(0.72).frame(width: 18, height: 12)
          PuckTrapezoid(top: 20, bottom: 30).fill(whiteBarrel).frame(width: 30, height: 14)
        }
      case .airbrush:
        VStack(spacing: 0) {
          ZStack {
            ForEach(0..<9, id: \.self) { k in
              Circle().fill(ink.opacity(0.55)).frame(width: 2, height: 2)
                .offset(
                  x: CGFloat([-5, 3, -1, 6, -6, 1, 4, -3, 0][k]),
                  y: CGFloat([-2, -4, -7, 1, 3, 2, -8, 0, -3][k]))
            }
          }
          .frame(width: 18, height: 10)
          PuckTrapezoid(top: 3, bottom: 18).fill(metalBarrel).frame(width: 18, height: 22)
        }
      case .neon:
        VStack(spacing: 0) {
          ZStack {
            Capsule().fill(ink)
            Capsule().fill(Color.white.opacity(0.5))
          }
          .frame(width: 5, height: 16)
          .shadow(color: ink, radius: 5)
          .shadow(color: ink, radius: 2)
          PuckTrapezoid(top: 9, bottom: 22).fill(darkBarrel).frame(width: 22, height: 14)
        }
      }
    }
  }

  // MARK: - Shapes

  struct PuckTrapezoid: Shape {
    var top: CGFloat
    var bottom: CGFloat
    var scallop = false

    func path(in r: CGRect) -> Path {
      var p = Path()
      p.move(to: CGPoint(x: r.midX - top / 2, y: r.minY))
      p.addLine(to: CGPoint(x: r.midX + top / 2, y: r.minY))
      p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
      if scallop {
        // The sharpened edge where the lacquer meets the wood.
        let n = 4
        for k in 0..<n {
          let x0 = r.maxX - r.width * CGFloat(k) / CGFloat(n)
          let x1 = r.maxX - r.width * CGFloat(k + 1) / CGFloat(n)
          p.addQuadCurve(
            to: CGPoint(x: x1, y: r.maxY), control: CGPoint(x: (x0 + x1) / 2, y: r.maxY - 5))
        }
      } else {
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
      }
      p.closeSubpath()
      return p
    }
  }

  struct PuckChisel: Shape {
    func path(in r: CGRect) -> Path {
      var p = Path()
      p.move(to: CGPoint(x: r.minX + 1, y: r.minY + r.height * 0.45))
      p.addLine(to: CGPoint(x: r.maxX - 1, y: r.minY))
      p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
      p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
      p.closeSubpath()
      return p
    }
  }

  struct PuckBristle: Shape {
    func path(in r: CGRect) -> Path {
      var p = Path()
      p.move(to: CGPoint(x: r.midX, y: r.minY))
      p.addQuadCurve(
        to: CGPoint(x: r.maxX, y: r.maxY),
        control: CGPoint(x: r.maxX + 1, y: r.minY + r.height * 0.45))
      p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
      p.addQuadCurve(
        to: CGPoint(x: r.midX, y: r.minY),
        control: CGPoint(x: r.minX - 1, y: r.minY + r.height * 0.45))
      return p
    }
  }

  /// UIColorWell's face: a spectrum ring around the current colour.
  struct RemoteDrawPuckColorWell: View {
    let ink: Color
    var size: CGFloat = 30

    var body: some View {
      ZStack {
        Circle().strokeBorder(
          AngularGradient(
            colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center),
          lineWidth: size * 0.12)
        Circle().fill(ink).padding(size * 0.2)
      }
      .frame(width: size, height: size)
    }
  }

  /// The shapes slot, weighted like the colour well beside it at the other
  /// end of the tray: the same diameter, a quiet disc instead of the spectrum
  /// ring, the glyph inside.
  struct RemoteDrawPuckShapesWell: View {
    var size: CGFloat = 30

    var body: some View {
      ZStack {
        Circle().fill(Color.primary.opacity(0.07))
        Circle().strokeBorder(Color.primary.opacity(0.16), lineWidth: 0.75)
        Image(systemName: "square.on.circle")
          .font(.system(size: size * 0.5, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(.primary)
      }
      .frame(width: size, height: size)
    }
  }

  /// The wheel's scroll track, like a crown's on the Watch: a hairline arc on
  /// the ledge the pens stand on, one segment per family, the part in view
  /// drawn brighter. It says there are more tips than five, how many, and
  /// where these are.
  struct PuckScrollTrack: View {
    let layout: RemoteDrawPuckLayout
    let wheel: RemoteDrawPuckWheel
    /// The wheel as drawn (the session's, less the summon spin).
    let turned: Double
    let isScrolling: Bool
    let contrast: ColorSchemeContrast

    var body: some View {
      let style = StrokeStyle(lineWidth: 2.5, lineCap: .round)
      ZStack {
        PuckTrackPath(layout: layout, wheel: wheel, turned: turned, visibleOnly: false)
          .stroke(Color.primary.opacity(contrast == .increased ? 0.24 : 0.1), style: style)
        PuckTrackPath(layout: layout, wheel: wheel, turned: turned, visibleOnly: true)
          .stroke(Color.primary.opacity(isScrolling ? 0.5 : 0.3), style: style)
          .animation(.easeOut(duration: 0.2), value: isScrolling)
      }
      .accessibilityHidden(true)
    }
  }

  /// Track segments as arcs about the tray's centre, animatable in the turn
  /// so a snap slides the bright part rather than jumping it.
  struct PuckTrackPath: Shape {
    let layout: RemoteDrawPuckLayout
    let wheel: RemoteDrawPuckWheel
    var turned: Double
    let visibleOnly: Bool

    var animatableData: Double {
      get { turned }
      set { turned = newValue }
    }

    func path(in _: CGRect) -> Path {
      let metrics = layout.metrics
      let radius = layout.baseSide(metrics.radius - metrics.trackInset)
      let spans =
        visibleOnly
        ? wheel.visibleSpans(wheel: turned, window: metrics.penWindow) : wheel.familySpans
      var path = Path()
      for span in spans {
        let a = wheel.trackOffset(of: span.lowerBound, span: metrics.trackSpan)
        let b = wheel.trackOffset(of: span.upperBound, span: metrics.trackSpan)
        // Round caps reach past each end; pull the ends in to keep the gaps.
        let inset = 1.6 / (Double(radius) * metrics.step)
        let from = a + inset, to = b - inset
        guard to > from else { continue }
        let steps = max(2, Int((to - from) * 8))
        for k in 0...steps {
          let p = layout.point(radius: radius, offset: from + (to - from) * Double(k) / Double(steps))
          if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
      }
      return path
    }
  }

  /// Everything on one side of a circle about the tray's centre: `outside`,
  /// everything farther than `radius`; otherwise everything nearer. Cuts the
  /// pens at the ledge.
  struct PuckLedgeClip: Shape {
    var center: CGPoint
    var radius: CGFloat
    var outside: Bool

    func path(in rect: CGRect) -> Path {
      let disc = Path(ellipseIn: CGRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
      guard outside else { return disc }
      var p = Path(rect.insetBy(dx: -2000, dy: -2000))
      p.addPath(disc)
      return p
    }
  }

  /// An annular band with continuous rounded ends: the tray and the tier.
  /// `start < end`, in radians, measured from `center`.
  struct PuckArcBand: Shape {
    var center: CGPoint
    var inner: CGFloat
    var outer: CGFloat
    var start: Double
    var end: Double
    var corner: CGFloat

    func path(in _: CGRect) -> Path {
      var p = Path()
      p.addArc(
        center: center, radius: outer - corner,
        startAngle: .radians(start + Double(corner / outer)),
        endAngle: .radians(end - Double(corner / outer)), clockwise: false)
      p.addArc(
        center: center, radius: inner + corner,
        startAngle: .radians(end - Double(corner / inner)),
        endAngle: .radians(start + Double(corner / inner)), clockwise: true)
      p.closeSubpath()
      return p.union(p.strokedPath(StrokeStyle(lineWidth: corner * 2, lineJoin: .round)))
    }
  }

  /// A short live mark by the shipping renderer: the tooltip's and the chip's
  /// sample.
  struct RemoteDrawPuckInkSample: View {
    let kind: DrawingStyleKind
    let hex: String
    let width: Double
    var span = CGSize(width: 56, height: 22)

    var body: some View {
      Canvas { context, size in
        var canvas = context
        let f = min(size.width / span.width, size.height / span.height)
        canvas.translateBy(x: (size.width - span.width * f) / 2, y: (size.height - span.height * f) / 2)
        canvas.scaleBy(x: f, y: f)
        RemoteDrawStrokePainter.draw(
          RemoteDrawStrokePainter.Stroke(
            points: Self.wave, type: "freehand",
            style: RemoteDrawDrawingStyle(kind: kind.rawValue, color: hex, width: width)),
          in: &canvas, size: span,
          defaults: RemoteDrawStrokePainter.Defaults(
            color: .black, lineWidth: CGFloat(width), highlighterColor: .black))
      }
      .allowsHitTesting(false)
    }

    static let wave: [RemoteDrawNormalizedPoint] = (0...28).map { s in
      let t = Double(s) / 28
      return RemoteDrawNormalizedPoint(
        x: 0.07 + 0.86 * t, y: 0.5 + 0.2 * sin(t * .pi * 2), t: Double(s) * 12,
        pressure: 0.3 + 0.55 * sin(t * .pi))
    }
  }
#endif
