//
//  The Pencil Pro arc's geometry.
//
//  Pure, and deliberately in a file with no `canImport(UIKit)` guard: every
//  number the arc is made of has to be checkable by `swift test` on a machine
//  with no simulator. `PuckView.swift` reads this and draws it; it decides
//  nothing.
//
//  The numbers are the spec's, `docs/design/2026-09-24-pencil-pro-arc-puck.md`,
//  and they are shared one for one with the hosted web sender
//  (`apps/web/src/sender/senderPuck.ts`). Change one here and the two senders
//  stop feeling like the same instrument.
//
//  Three things this geometry never does:
//
//  1. **Move the anchor.** The thumb is where the finger is. The arc's centre
//     slides sideways to keep the band on screen and every angle is measured
//     from that centre, but the thumb itself is never nudged.
//  2. **Re-solve during a gesture.** Everything here is solved once, at summon,
//     and frozen with the menu.
//  3. **Put a choice under the hand.** The tray opens above the thumb and is
//     chosen by angle, so the finger stays below what it is choosing. Only when
//     there is no room above does it mirror below, and occlusion is then the
//     accepted cost.
//
//  The mirror reflects *places*, never *things*: the band hangs below the thumb,
//  but every pen still stands tip up, leaning in at the thumb, and "lifted" is
//  still up the screen. An upside-down pen reads as a broken tray.
//
import CoreGraphics
import Foundation

/// Every dimension of the arc, in points and radians. The defaults are the
/// spec's table; a struct rather than constants so a test can state them.
public struct RemoteDrawPuckMetrics: Equatable, Sendable {
  /// `R`, the tray radius.
  public var radius: CGFloat = 330
  /// Radians per slot.
  public var step: Double = 0.142
  /// The tray's apex sits this far above the thumb: `o.y = thumb.y + R − 110`.
  public var apexAboveThumb: CGFloat = 110

  /// Pens are laid out in `off ∈ [−window, window]`…
  public var penWindow: Double = 2.5
  /// …and fade as `clamp((fadeEdge − |off|) / fadeWidth, 0, 1)`.
  public var penFadeEdge: Double = 2.6
  public var penFadeWidth: Double = 0.5

  /// The fixed slots, in slot units. They never scroll, and they bookend the
  /// wheel: shapes at the left end, the colour well at the right, each behind
  /// a hairline divider at `±dividerOffset`.
  public var dividerOffset: Double = 2.85
  public var wellOffset: Double = 3.5
  public var shapesOffset: Double = -3.5

  /// The tray band, in slot units and points. Symmetric about the thumb; an
  /// end whose slot a menu does not have is trimmed to `±capless`.
  public var bandStart: Double = -3.95
  public var bandEnd: Double = 3.95
  public var capless: Double = 2.95
  public var bandInnerInset: CGFloat = 58
  public var bandOuterOutset: CGFloat = 50
  public var bandCorner: CGFloat = 30
  /// The band keeps at least this far from both screen edges.
  public var edgeMargin: CGFloat = 22

  /// A pen's centre sits at `R − 24 + lift`, rotated tip-outward (above; the
  /// mirror reflects that across the band's middle, see `penRadius`).
  public var penRadiusInset: CGFloat = 24
  public var liftHovered: CGFloat = 18
  public var liftNeighbour: CGFloat = 5
  public var liftCurrent: CGFloat = 10

  /// Half a slot between families, and the wheel's length is the last pen's
  /// position plus this tail (one slot plus the wrap-around breath).
  public var familyBreath: Double = 0.5
  public var wheelTail: Double = 1.5

  /// The second tier: `Rs = R + 88`, its own step, a ±30pt band, nudged in
  /// 0.02 rad steps until every item is ≥ 28pt from the screen edges.
  public var tierRadiusOutset: CGFloat = 88
  public var tierStep: Double = 0.135
  public var tierHalfBand: CGFloat = 30
  public var tierNudge: Double = 0.02
  public var tierEdgeMargin: CGFloat = 28

  /// The tooltip rides outside what it names; its x is clamped this far from
  /// the edges.
  public var tooltipPenOutset: CGFloat = 94
  public var tooltipSlotOutset: CGFloat = 70
  public var tooltipTierOutset: CGFloat = 50
  public var tooltipEdgeInset: CGFloat = 110

  /// Slide up: a tier opens past `R − 72` and closes inside `R − 92`.
  public var tierOpenInset: CGFloat = 72
  public var tierCloseInset: CGFloat = 92

  /// Edge scroll: dwell in `|off| ∈ (1.95, 2.75)` for 0.22 s, then turn at
  /// `3.4 slot/s · min(1, (|off| − 1.95) / 0.4 + 0.4)`.
  public var edgeZoneStart: Double = 1.95
  public var edgeZoneEnd: Double = 2.75
  public var edgeDwell: TimeInterval = 0.22
  public var edgeSpeed: Double = 3.4
  public var edgeRamp: Double = 0.4
  public var edgeFloor: Double = 0.4

  /// Hover: the nearest visible pen within 0.75 slot; past a divider, that
  /// end's slot; a 0.15-slot hysteresis so a boundary does not strobe.
  public var hoverReach: Double = 0.75
  public var hoverHysteresis: Double = 0.15

  /// The ledge: the pens stand on it, `ledgeInset` inside `R` (their bases
  /// are cut there, not at the band's edge), and the scroll track runs along
  /// it, `trackInset` inside `R` — a hairline over `±trackSpan` slots showing
  /// the whole wheel (one segment per family) and, brighter, the part in view.
  public var ledgeInset: CGFloat = 44
  public var trackInset: CGFloat = 51
  public var trackSpan: Double = 2.4
  /// On summon the wheel turns in from this many slots to the right.
  public var summonSpin: Double = 0.9

  /// Only a release after ≥ 24pt of travel from the summon point commits.
  public var commitTravel: CGFloat = 24
  /// Dragged this far inside `R` (`|touch − o| < R − 200`) hovers nothing.
  public var cancelInset: CGFloat = 200

  /// What the whole instrument needs above the thumb (tray, tier, tooltip).
  /// Less than this plus the top safe area mirrors the arc below the thumb.
  public var roomAbove: CGFloat = 270
  /// A mirrored band rises toward its ends; they stay this far under the top
  /// safe area (the centre moves down, never the thumb).
  public var topClearance: CGFloat = 8
  /// The confirmation chip floats this far above the touch point.
  public var chipAbove: CGFloat = 64
  /// The long press that summons — `UILongPressGestureRecognizer`'s 0.5 s —
  /// which the hold ring fills over.
  public var holdDuration: TimeInterval = 0.5

  public init() {}

  public static let standard = RemoteDrawPuckMetrics()

  /// These metrics with the band trimmed at any end whose slot is missing
  /// (no colours: no well; no shapes granted: no shapes slot).
  public func fitted(hasWell: Bool, hasShapes: Bool) -> RemoteDrawPuckMetrics {
    var fitted = self
    if !hasShapes { fitted.bandStart = max(bandStart, -capless) }
    if !hasWell { fitted.bandEnd = min(bandEnd, capless) }
    return fitted
  }

  public var tierRadius: CGFloat { radius + tierRadiusOutset }
  public var bandInnerRadius: CGFloat { radius - bandInnerInset }
  public var bandOuterRadius: CGFloat { radius + bandOuterOutset }
}

// MARK: - The wheel

/// The pens' positions along the wheel: one slot per pen, plus a half-slot
/// breath wherever the family changes. Wraps when it is long enough to fill the
/// window, so any tip is reachable in either direction.
public struct RemoteDrawPuckWheel: Equatable, Sendable {
  /// `pos(i)`, in slot units.
  public let positions: [Double]
  /// One full turn.
  public let length: Double
  /// A wheel too short to fill the window does not wrap — a wrapped two-pen
  /// wheel would show each pen three times — and does not edge-scroll.
  public let wraps: Bool
  /// The family boundary index of each pen (0 for the first family seen).
  public let groups: [Int]

  /// `groups[i]` is any stable family key for pen `i`; `nil` is its own group.
  public init(groups rawGroups: [String?], metrics: RemoteDrawPuckMetrics = .standard) {
    var groups: [Int] = []
    var positions: [Double] = []
    var group = 0
    for (index, key) in rawGroups.enumerated() {
      if index > 0, key != rawGroups[index - 1] { group += 1 }
      groups.append(group)
      positions.append(Double(index) + metrics.familyBreath * Double(group))
    }
    self.positions = positions
    self.groups = groups
    self.length = (positions.last ?? -metrics.wheelTail) + metrics.wheelTail
    // Nothing may be visible twice: a copy one turn away must sit past the
    // fade on both sides.
    self.wraps = length >= 2 * (metrics.penFadeEdge + 0.6)
  }

  public var count: Int { positions.count }

  /// Brings `x` into `[−length/2, length/2)`.
  public func wrap(_ x: Double) -> Double {
    guard wraps, length > 0 else { return x }
    return x - length * ((x + length / 2) / length).rounded(.down)
  }

  /// Where pen `i` sits in slot units, relative to the slot above the arc's
  /// apex, for a wheel turned to `wheel`.
  public func offset(ofPen index: Int, wheel: Double) -> Double {
    guard positions.indices.contains(index) else { return .infinity }
    return wrap(positions[index] - wheel)
  }

  /// The wheel laid flat for the scroll track: each family's span in wheel
  /// units, starting half the seam's breath before the first pen, so the
  /// track reads `[family][gap][family]…` end to end over `length`.
  public var trackOrigin: Double {
    (positions.first ?? 0) - 0.5 - (length - (positions.last ?? 0) + (positions.first ?? 0) - 1) / 2
  }

  public var familySpans: [ClosedRange<Double>] {
    var spans: [ClosedRange<Double>] = []
    var start = 0
    for index in positions.indices where index == positions.count - 1 || groups[index + 1] != groups[index] {
      spans.append((positions[start] - 0.5)...(positions[index] + 0.5))
      start = index + 1
    }
    return spans
  }

  /// The part of `familySpans` in view for a wheel turned to `wheel`, with a
  /// window of `±window` slots — split in two where it crosses the seam.
  public func visibleSpans(wheel: Double, window: Double) -> [ClosedRange<Double>] {
    let origin = trackOrigin
    // The window, brought into the track's one turn.
    var from = wheel - window
    if wraps {
      from = origin + (from - origin).truncatingRemainder(dividingBy: length)
      if from < origin { from += length }
    }
    let to = from + 2 * window
    var windows = [from...min(to, origin + length)]
    if wraps, to > origin + length { windows.append(origin...(to - length)) }
    var result: [ClosedRange<Double>] = []
    for span in familySpans {
      for w in windows where w.lowerBound < span.upperBound && w.upperBound > span.lowerBound {
        result.append(max(w.lowerBound, span.lowerBound)...min(w.upperBound, span.upperBound))
      }
    }
    return result
  }

  /// Where a wheel position lands on the track, in slot offsets
  /// (`−span … span`, left to right).
  public func trackOffset(of u: Double, span: Double) -> Double {
    guard length > 0 else { return 0 }
    return -span + 2 * span * (u - trackOrigin) / length
  }

  /// Where a family's breath dot sits (between its first pen and the pen
  /// before it), or `nil` for the first family on a wheel that does not wrap.
  public func breathOffsets(wheel: Double) -> [Double] {
    guard let first = positions.first, let last = positions.last, positions.count > 1 else {
      return []
    }
    var result: [Double] = []
    for index in 1..<positions.count where groups[index] != groups[index - 1] {
      result.append(wrap((positions[index - 1] + positions[index]) / 2 - wheel))
    }
    // The seam: the last family runs back into the first.
    if wraps, groups.first != groups.last {
      result.append(wrap((last + first + length) / 2 - wheel))
    }
    return result
  }
}

// MARK: - The solved arc

/// Which way the tray opens from the thumb.
public enum RemoteDrawPuckOrientation: Equatable, Sendable {
  /// The normal case: the tray above the thumb, angles about `−π/2`.
  case above
  /// No room above: mirrored below, angles about `+π/2`, tier below the tray.
  /// Places mirror; the pens do not (they stand tip up, leaning in).
  case below
}

/// What a finger can be over in the tray.
public enum RemoteDrawPuckTarget: Equatable, Hashable, Sendable {
  /// A pen on the wheel, by its index in ``RemoteDrawPuckMenu/pens``.
  case pen(Int)
  /// The colour well.
  case well
  /// The shapes slot.
  case shapes
}

/// One solved tray, frozen for the life of a gesture.
public struct RemoteDrawPuckLayout: Equatable, Sendable {
  public let thumb: CGPoint
  /// `o`, the arc's centre. Every angle is measured from here.
  public let center: CGPoint
  public let orientation: RemoteDrawPuckOrientation
  public let size: CGSize
  public let metrics: RemoteDrawPuckMetrics

  public init(
    thumb: CGPoint, center: CGPoint, orientation: RemoteDrawPuckOrientation, size: CGSize,
    metrics: RemoteDrawPuckMetrics
  ) {
    self.thumb = thumb
    self.center = center
    self.orientation = orientation
    self.size = size
    self.metrics = metrics
  }

  /// `+1` above, `−1` mirrored: slot offsets always run left to right.
  public var sign: Double { orientation == .above ? 1 : -1 }
  public var baseAngle: Double { orientation == .above ? -.pi / 2 : .pi / 2 }

  /// `−π/2 + off·step` (above) or its mirror.
  public func angle(ofOffset offset: Double) -> Double {
    baseAngle + sign * offset * metrics.step
  }

  /// The slot offset of an angle.
  public func offset(ofAngle angle: Double) -> Double {
    sign * RemoteDrawPuckLayout.normalized(angle - baseAngle) / metrics.step
  }

  public func angle(of point: CGPoint) -> Double {
    Double(atan2(point.y - center.y, point.x - center.x))
  }

  /// The slot offset under a point.
  public func offset(of point: CGPoint) -> Double {
    offset(ofAngle: angle(of: point))
  }

  /// `|point − o|`.
  public func distance(of point: CGPoint) -> CGFloat {
    hypot(point.x - center.x, point.y - center.y)
  }

  public func point(radius: CGFloat, angle: Double) -> CGPoint {
    CGPoint(x: center.x + radius * CGFloat(cos(angle)), y: center.y + radius * CGFloat(sin(angle)))
  }

  public func point(radius: CGFloat, offset: Double) -> CGPoint {
    point(radius: radius, angle: angle(ofOffset: offset))
  }

  /// A unit vector pointing away from `o` at `angle`.
  public func outward(at angle: Double) -> CGVector {
    CGVector(dx: cos(angle), dy: sin(angle))
  }

  /// `+1` when a pen's tip points away from `o` (above), `−1` when it points
  /// back at it (the mirror): either way the tip points up the screen, at the
  /// thumb.
  public var tipSign: CGFloat { orientation == .above ? 1 : -1 }

  /// Up the screen for something in the arc, along its radius: where a lift
  /// goes, whichever way the arc opens.
  public func up(at angle: Double) -> CGVector {
    let out = outward(at: angle)
    return CGVector(dx: out.dx * tipSign, dy: out.dy * tipSign)
  }

  /// A pen's rotation: normal to the band, tip up. Above that is tip-outward;
  /// in the mirror the pens lean in at the thumb instead of hanging tip down.
  public func penRotation(at angle: Double) -> Double {
    angle + Double(tipSign) * .pi / 2
  }

  /// A radius on the pens' side of the band, measured as if the arc opened
  /// above. The mirror reflects it across the band's middle, so what sits at a
  /// pen's base (its clipped end, the family dots) stays at its base.
  public func baseSide(_ radius: CGFloat) -> CGFloat {
    orientation == .above ? radius : metrics.bandInnerRadius + metrics.bandOuterRadius - radius
  }

  /// A pen's centre: `R − 24`, moved tip-first by `lift` and base-first by
  /// `sink`. Both are up/down the screen either way up.
  public func penRadius(lift: CGFloat, sink: CGFloat = 0) -> CGFloat {
    baseSide(metrics.radius - metrics.penRadiusInset) + tipSign * (lift - sink)
  }

  public var bandStartAngle: Double { angle(ofOffset: metrics.bandStart) }
  public var bandEndAngle: Double { angle(ofOffset: metrics.bandEnd) }

  /// Where the tooltip goes for a point at `radius`/`angle`, x clamped away
  /// from the edges.
  public func tooltipPoint(radius: CGFloat, angle: Double) -> CGPoint {
    var p = point(radius: radius, angle: angle)
    let inset = min(metrics.tooltipEdgeInset, size.width / 2)
    p.x = min(max(p.x, inset), size.width - inset)
    return p
  }

  /// Angles to `(−π, π]`.
  static func normalized(_ angle: Double) -> Double {
    atan2(sin(angle), cos(angle))
  }
}

/// Places the tray for a thumb.
public enum RemoteDrawPuckSolver {
  /// Insets that keep the tray clear of the notch and the home indicator.
  /// Plain numbers so the solver stays free of SwiftUI.
  public struct Insets: Equatable, Sendable {
    public var top: CGFloat
    public var leading: CGFloat
    public var bottom: CGFloat
    public var trailing: CGFloat

    public init(top: CGFloat = 0, leading: CGFloat = 0, bottom: CGFloat = 0, trailing: CGFloat = 0) {
      self.top = top
      self.leading = leading
      self.bottom = bottom
      self.trailing = trailing
    }

    public static let zero = Insets()
  }

  /// Solves the tray, or `nil` for a surface that cannot hold one at all
  /// (degenerate sizes, a non-finite thumb). The thumb is never moved.
  public static func solve(
    thumb: CGPoint,
    in size: CGSize,
    insets: Insets = .zero,
    metrics: RemoteDrawPuckMetrics = .standard
  ) -> RemoteDrawPuckLayout? {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
      thumb.x.isFinite, thumb.y.isFinite, metrics.radius > 0, metrics.step > 0
    else { return nil }

    let orientation = orientation(for: thumb, in: size, insets: insets, metrics: metrics)
    let apexToCenter = metrics.radius - metrics.apexAboveThumb
    var y = orientation == .above ? thumb.y + apexToCenter : thumb.y - apexToCenter
    if orientation == .below {
      // A band hanging below the thumb curls up at its ends, the right one
      // (well and shapes) past the thumb itself. Near the top edge that would
      // put it under the status bar, so the centre moves down instead.
      let widest = max(-metrics.bandStart, metrics.bandEnd) * metrics.step
      let rise = metrics.bandInnerRadius * CGFloat(cos(widest))
      y = max(y, insets.top + metrics.topClearance - rise)
    }
    return RemoteDrawPuckLayout(
      thumb: thumb,
      center: CGPoint(x: clampX(thumb.x, width: size.width, metrics: metrics), y: y),
      orientation: orientation,
      size: size,
      metrics: metrics)
  }

  /// Above when there is room for the whole instrument above the thumb plus
  /// the top safe area; otherwise mirrored below. On a surface too short for
  /// either, whichever side has more room.
  public static func orientation(
    for thumb: CGPoint, in size: CGSize, insets: Insets = .zero,
    metrics: RemoteDrawPuckMetrics = .standard
  ) -> RemoteDrawPuckOrientation {
    let above = thumb.y - insets.top
    if above >= metrics.roomAbove { return .above }
    let below = size.height - insets.bottom - thumb.y
    if below >= metrics.roomAbove { return .below }
    return above >= below ? .above : .below
  }

  /// The arc's apex follows the thumb only as far as the band stays
  /// `edgeMargin` from both edges. Measured at `R`, as the prototype does, so
  /// the rounded band ends sit just inside that margin.
  ///
  /// The two limits are symmetric in the mirror (offsets still run left to
  /// right), so this does not depend on orientation. When the screen is too
  /// narrow for both, the right-hand limit wins — the colour well lives on
  /// that side, and it is what may not be cut off.
  public static func clampX(_ x: CGFloat, width: CGFloat, metrics: RemoteDrawPuckMetrics = .standard)
    -> CGFloat
  {
    let left = metrics.radius * CGFloat(sin(-metrics.bandStart * metrics.step)) + metrics.edgeMargin
    let right = metrics.radius * CGFloat(sin(metrics.bandEnd * metrics.step)) + metrics.edgeMargin
    return min(max(x, left), width - right)
  }
}

// MARK: - The second tier

/// Which tier a source opens.
public enum RemoteDrawPuckTierKind: Equatable, Hashable, Sendable {
  case widths
  case colors
  case shapes
}

/// A second tier, placed: the widths, colours or shapes that bloomed from one
/// source.
public struct RemoteDrawPuckTier: Equatable, Sendable {
  public let source: RemoteDrawPuckTarget
  public let kind: RemoteDrawPuckTierKind
  public let count: Int
  /// The centre angle after nudging on screen.
  public let angle: Double
  /// The source's own angle, where the tier blooms from.
  public let sourceAngle: Double
  public let layout: RemoteDrawPuckLayout

  public init(
    source: RemoteDrawPuckTarget, kind: RemoteDrawPuckTierKind, count: Int, sourceAngle: Double,
    layout: RemoteDrawPuckLayout
  ) {
    self.source = source
    self.kind = kind
    self.count = count
    self.sourceAngle = sourceAngle
    self.layout = layout
    self.angle = RemoteDrawPuckTier.placedAngle(
      around: sourceAngle, count: count, layout: layout)
  }

  public var radius: CGFloat { layout.metrics.tierRadius }

  /// Item `k`'s angle. Items run left to right in index order either way up.
  public func angle(ofItem index: Int) -> Double {
    angle(ofItem: index, around: angle)
  }

  public func point(ofItem index: Int) -> CGPoint {
    layout.point(radius: radius, angle: angle(ofItem: index))
  }

  /// The tier's band ends, a little past the outer items.
  public var bandStartAngle: Double { angle(ofItem: 0) - layout.sign * 0.08 }
  public var bandEndAngle: Double { angle(ofItem: count - 1) + layout.sign * 0.08 }

  /// The item under an angle, before hysteresis, or `nil` past either end.
  public func item(atAngle a: Double) -> Int? {
    let raw = itemPosition(atAngle: a)
    let index = Int(raw.rounded())
    return (0..<count).contains(index) ? index : nil
  }

  /// A continuous item index for an angle: `2.0` is dead on item 2.
  public func itemPosition(atAngle a: Double) -> Double {
    layout.sign * RemoteDrawPuckLayout.normalized(a - angle) / layout.metrics.tierStep
      + Double(count - 1) / 2
  }

  private func angle(ofItem index: Int, around centre: Double) -> Double {
    centre + layout.sign * (Double(index) - Double(count - 1) / 2) * layout.metrics.tierStep
  }

  /// Centred on the source, then nudged 0.02 rad at a time until every item
  /// clears the edges by `tierEdgeMargin`. A tier wider than the screen allows
  /// cannot clear both; it keeps the angle with the smallest overflow, which
  /// centres it.
  static func placedAngle(around source: Double, count: Int, layout: RemoteDrawPuckLayout)
    -> Double
  {
    guard count > 0 else { return source }
    let metrics = layout.metrics
    func centre(_ index: Int, _ a: Double) -> CGFloat {
      let itemAngle =
        a + layout.sign * (Double(index) - Double(count - 1) / 2) * metrics.tierStep
      return layout.point(radius: metrics.tierRadius, angle: itemAngle).x
    }
    func overflow(_ a: Double) -> (left: CGFloat, right: CGFloat) {
      let xs = (0..<count).map { centre($0, a) }
      return (
        max(0, metrics.tierEdgeMargin - (xs.min() ?? 0)),
        max(0, (xs.max() ?? 0) - (layout.size.width - metrics.tierEdgeMargin))
      )
    }
    var a = source
    var best = (angle: a, worst: CGFloat.infinity)
    for _ in 0..<120 {
      let (left, right) = overflow(a)
      let worst = max(left, right)
      if worst < best.worst - 1e-6 { best = (a, worst) }
      if worst <= 0 { return a }
      // `sign` turns "further right" into the right angular direction in the
      // mirror, where increasing angle runs right to left.
      if right > left {
        a -= layout.sign * metrics.tierNudge
      } else {
        a += layout.sign * metrics.tierNudge
      }
    }
    return best.angle
  }
}
