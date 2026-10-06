//
//  What the arc offers, what a finger is doing to it, and when a mark is
//  allowed to start.
//
//  Pure like `PuckGeometry.swift`, and for the same reason: the release rules
//  are the part that can lose someone's work, so they are decided by a value
//  type a test can drive frame by frame rather than by a `View` that needs a
//  window to exist.
//
import CoreGraphics
import Foundation

// MARK: - Menu

/// One choice: a pen on the wheel, or an item in a second tier.
///
/// Carries no closure. The host is handed the item back on commit and decides
/// what it means, which keeps this whole model `Equatable` — a menu that can be
/// compared is a menu a test can assert on and SwiftUI can diff.
public struct RemoteDrawPuckItem: Equatable, Identifiable, Sendable {
  /// What the item shows. Every case is a *real* sample rather than an
  /// illustration of one: the instrument is dipped in the ink that will be
  /// used, the swatch is the colour, the width is the width in points.
  public enum Content: Equatable, Sendable {
    case symbol(String)
    case swatch(hex: String)
    case width(points: Double, hex: String)
    /// A renderer specimen: used by the tip library and the controls sheet.
    case specimen(kind: DrawingStyleKind, hex: String, width: Double)
    /// The instrument itself, its working end in the menu's current ink —
    /// the wheel's pens.
    case instrument(DrawingStyleKind)
    /// UIColorWell's face around the current ink: opens the full palette.
    case colorWell
  }

  public var id: String
  public var title: String
  /// The tooltip's secondary text: a pen's family, for example.
  public var detail: String?
  public var content: Content
  /// Whether this is what the board is set to right now. Drawn as a ring or a
  /// resting lift, never as a coloured badge — selection is a lift.
  public var isCurrent: Bool
  /// A choice whose release dismisses the arc and opens a sheet, rather than
  /// changing a value. It gets no confirmation chip: the sheet is the answer.
  public var opensSheet: Bool

  public init(
    id: String,
    title: String,
    detail: String? = nil,
    content: Content,
    isCurrent: Bool = false,
    opensSheet: Bool = false
  ) {
    self.id = id
    self.title = title
    self.detail = detail
    self.content = content
    self.isCurrent = isCurrent
    self.opensSheet = opensSheet
  }

  /// The instrument a pen stands for, if it is one.
  public var instrument: DrawingStyleKind? {
    if case .instrument(let kind) = content { return kind }
    return nil
  }
}

/// The arc's contents, frozen at summon for the life of a gesture.
///
/// - `pens` are the wheel, in wheel order (normally the sixteen
///   ``DrawingStyleKind``s in ``DrawingStyleKind/Family`` order). A board that
///   only grants pointing puts its one Point tool here instead.
/// - `widths` bloom from a pen, `colors` from the well, `shapes` from the
///   shapes slot. An item with ``RemoteDrawPuckItem/opensSheet`` in `colors` or
///   `shapes` is also what a release on the tray's well or shapes slot does.
public struct RemoteDrawPuckMenu: Equatable, Sendable {
  public var pens: [RemoteDrawPuckItem]
  public var widths: [RemoteDrawPuckItem]
  public var colors: [RemoteDrawPuckItem]
  public var shapes: [RemoteDrawPuckItem]
  /// The ink every tip is dipped in.
  public var inkHex: String
  /// The current width, for the tooltip's live sample.
  public var width: Double
  /// The tooltip's detail over the well ("Teal") and the shapes slot
  /// ("Smart").
  public var colorTitle: String
  public var shapeTitle: String

  public init(
    pens: [RemoteDrawPuckItem],
    widths: [RemoteDrawPuckItem] = [],
    colors: [RemoteDrawPuckItem] = [],
    shapes: [RemoteDrawPuckItem] = [],
    inkHex: String,
    width: Double,
    colorTitle: String = "",
    shapeTitle: String = ""
  ) {
    self.pens = pens
    self.widths = widths
    self.colors = colors
    self.shapes = shapes
    self.inkHex = inkHex
    self.width = width
    self.colorTitle = colorTitle
    self.shapeTitle = shapeTitle
  }

  public static let empty = RemoteDrawPuckMenu(pens: [], inkHex: "#151512", width: 6)

  /// Whether this menu can be shown at all. A wheel with nothing on it is not
  /// a wheel.
  public var isPresentable: Bool { !pens.isEmpty }

  /// The pen the wheel opens centred on.
  public var currentPenIndex: Int? { pens.firstIndex { $0.isCurrent } }

  public var hasWell: Bool { !colors.isEmpty }
  public var hasShapes: Bool { !shapes.isEmpty }

  /// The family key the wheel breathes between.
  public var penGroups: [String?] {
    pens.map { pen in
      pen.instrument.flatMap { kind in
        DrawingStyleKind.Family.allCases.first { $0.members.contains(kind) }?.rawValue
      }
    }
  }

  /// Which tier a source opens, or `nil` when it opens none: only instruments
  /// have widths, and an empty tier is not a tier.
  public func tierKind(for source: RemoteDrawPuckTarget) -> RemoteDrawPuckTierKind? {
    switch source {
    case .pen(let index):
      guard pens.indices.contains(index), pens[index].instrument != nil, !widths.isEmpty
      else { return nil }
      return .widths
    case .well: return colors.isEmpty ? nil : .colors
    case .shapes: return shapes.isEmpty ? nil : .shapes
    }
  }

  public func items(in tier: RemoteDrawPuckTierKind) -> [RemoteDrawPuckItem] {
    switch tier {
    case .widths: return widths
    case .colors: return colors
    case .shapes: return shapes
    }
  }

  /// What a selection means, in the order the host should apply it, and what
  /// the confirmation chip says (`nil` for a sheet opener: no chip).
  ///
  /// A width from a pen's tier is *two* choices, the pen and then its width —
  /// applied in that order, so a host that resets a tip to its default width
  /// still ends on the width that was chosen.
  public func commit(for selection: RemoteDrawPuckSelection) -> RemoteDrawPuckCommit? {
    switch (selection.source, selection.tierItem) {
    case (.pen(let index), nil):
      guard pens.indices.contains(index) else { return nil }
      return RemoteDrawPuckCommit(selection: selection, items: [pens[index]],
        label: pens[index].opensSheet ? nil : pens[index].title)
    case (.pen(let index), .some(let item)):
      guard pens.indices.contains(index), widths.indices.contains(item) else { return nil }
      return RemoteDrawPuckCommit(selection: selection, items: [pens[index], widths[item]],
        label: "\(pens[index].title) · \(widths[item].title)")
    case (.well, .some(let item)):
      guard colors.indices.contains(item) else { return nil }
      return RemoteDrawPuckCommit(selection: selection, items: [colors[item]],
        label: colors[item].opensSheet ? nil : colors[item].title)
    case (.shapes, .some(let item)):
      guard shapes.indices.contains(item) else { return nil }
      return RemoteDrawPuckCommit(selection: selection, items: [shapes[item]],
        label: shapes[item].opensSheet ? nil : shapes[item].title)
    case (.well, nil), (.shapes, nil):
      return nil
    }
  }

  /// The sheet opener a release on the tray's well or shapes slot means.
  public func openerIndex(for source: RemoteDrawPuckTarget) -> Int? {
    switch source {
    case .well: return colors.firstIndex { $0.opensSheet }
    case .shapes: return shapes.firstIndex { $0.opensSheet }
    case .pen: return nil
    }
  }
}

/// Which source, and which item of its tier (`nil`: the source itself).
public struct RemoteDrawPuckSelection: Equatable, Hashable, Sendable {
  public var source: RemoteDrawPuckTarget
  public var tierItem: Int?

  public init(source: RemoteDrawPuckTarget, tierItem: Int? = nil) {
    self.source = source
    self.tierItem = tierItem
  }
}

/// A release that chose something.
public struct RemoteDrawPuckCommit: Equatable, Sendable {
  public var selection: RemoteDrawPuckSelection
  /// Apply these, in order. One item, or a pen and its width.
  public var items: [RemoteDrawPuckItem]
  /// The confirmation chip's text, or `nil` for no chip.
  public var label: String?

  public init(selection: RemoteDrawPuckSelection, items: [RemoteDrawPuckItem], label: String?) {
    self.selection = selection
    self.items = items
    self.label = label
  }
}

/// The widths, colours and shapes both first-party menus offer, so the SDK
/// surface and the app cannot drift apart.
public enum RemoteDrawPuckDefaults {
  /// Every instrument, in family order: the wheel.
  public static let pens: [DrawingStyleKind] = DrawingStyleKind.Family.allCases.flatMap(\.members)
  public static let widths: [Double] = [2, 4, 6, 10, 16]
  /// Six swatches from ``RemoteDrawColorPalette``, ordered dark → cool → warm
  /// like the prototype's tier. The seventh (Warm gray) is one release away in
  /// the full palette behind the tier's own well.
  public static let colors: [String] = [
    "#151512", "#1e40af", "#1f7a8c", "#2f6b4f", "#b45309", "#9f1239",
  ]

  public static func nearestWidth(to thickness: Double) -> Double {
    widths.min(by: { abs($0 - thickness) < abs($1 - thickness) }) ?? thickness
  }
}

// MARK: - Summon

/// The host's handle on one press: where it landed, where the finger is now,
/// and whether it is still down.
public struct RemoteDrawPuckSummon: Equatable, Sendable {
  public enum Phase: Equatable, Sendable {
    case active
    case ended
    case cancelled
  }

  /// Where the finger physically touched down: the thumb. Never adjusted.
  public var anchor: CGPoint
  public var location: CGPoint
  public var phase: Phase

  public init(anchor: CGPoint, location: CGPoint, phase: Phase = .active) {
    self.anchor = anchor
    self.location = location
    self.phase = phase
  }
}

// MARK: - Session

/// What one update changed, for haptics and animation.
public struct RemoteDrawPuckChange: OptionSet, Equatable, Hashable, Sendable {
  public let rawValue: Int
  public init(rawValue: Int) { self.rawValue = rawValue }

  /// The hovered tray item changed (a selection tick).
  public static let hover = RemoteDrawPuckChange(rawValue: 1 << 0)
  /// …and crossed into another family (a light impact instead).
  public static let family = RemoteDrawPuckChange(rawValue: 1 << 1)
  public static let tierOpened = RemoteDrawPuckChange(rawValue: 1 << 2)
  public static let tierClosed = RemoteDrawPuckChange(rawValue: 1 << 3)
  /// The hovered tier item changed (a selection tick).
  public static let tierHover = RemoteDrawPuckChange(rawValue: 1 << 4)
  /// The wheel turned under an edge dwell. Continuous: no animation.
  public static let scrolled = RemoteDrawPuckChange(rawValue: 1 << 5)
  /// The finger left the edge zone and the wheel settled on the hovered pen.
  public static let snapped = RemoteDrawPuckChange(rawValue: 1 << 6)
}

public enum RemoteDrawPuckOutcome: Equatable, Sendable {
  case commit(RemoteDrawPuckCommit)
  case cancelled
}

/// The arc's state while a finger is down.
///
/// Every rule that can cost someone a stroke lives here:
///
/// - hover is by **angle** from the arc's centre, with a 0.15-slot hysteresis;
/// - sliding out past `R − 72` over a source opens its tier, and only coming
///   back inside `R − 92` closes it; while it is open the tray is frozen on the
///   source;
/// - dwelling at either end of the pen window turns the wheel;
/// - **only a release after ≥ 24pt of travel from the summon point, with
///   something hovered, commits.** Release in place, off the band, or dragged
///   far down (`|touch − o| < R − 200`) cancels; release with a tier open
///   commits the hovered tier item or cancels.
public struct RemoteDrawPuckSession: Equatable, Sendable {
  public let menu: RemoteDrawPuckMenu
  public let layout: RemoteDrawPuckLayout
  public let wheelModel: RemoteDrawPuckWheel
  /// Where the hold landed; travel is measured from here.
  public let summonPoint: CGPoint

  /// How far the wheel has turned, in slot units: pen `i` sits at
  /// `wrap(pos(i) − wheel)`.
  public private(set) var wheel: Double
  public private(set) var location: CGPoint
  public private(set) var hover: RemoteDrawPuckTarget?
  public private(set) var tier: RemoteDrawPuckTier?
  public private(set) var tierHover: Int?
  /// The wheel is turning under an edge dwell.
  public private(set) var isScrolling = false
  /// The finger has been ≥ `commitTravel` from the summon point at some time.
  public private(set) var hasTravelled = false
  /// The gesture is over; nothing reopens or moves.
  public private(set) var isReleased = false

  private var edgeSince: TimeInterval?
  private var lastHoveredPen: Int?

  public init(
    menu: RemoteDrawPuckMenu, layout: RemoteDrawPuckLayout, location: CGPoint? = nil,
    at time: TimeInterval = 0
  ) {
    self.menu = menu
    self.layout = layout
    self.wheelModel = RemoteDrawPuckWheel(groups: menu.penGroups, metrics: layout.metrics)
    self.summonPoint = layout.thumb
    self.location = location ?? layout.thumb
    // Centred on the current pen, directly above the thumb — which is not at
    // offset 0 when the centre was clamped sideways. A thumb so far over that
    // "above it" is the well, the shapes slot or an edge zone puts the current
    // pen at the nearest calm slot instead: fully visible, and not already
    // dwelling in an edge that would start the wheel turning.
    let current = menu.currentPenIndex ?? 0
    let position = wheelModel.positions.indices.contains(current) ? wheelModel.positions[current] : 0
    let calm = layout.metrics.edgeZoneStart - 0.45
    self.wheel = position - min(max(layout.offset(of: layout.thumb), -calm), calm)
    _ = update(location: self.location, at: time)
  }

  // MARK: Reading

  public var metrics: RemoteDrawPuckMetrics { layout.metrics }

  /// Pen `i`'s offset in slot units.
  public func offset(ofPen index: Int) -> Double {
    wheelModel.offset(ofPen: index, wheel: wheel)
  }

  /// `clamp((2.6 − |off|) / 0.5, 0, 1)`.
  public func opacity(ofPen index: Int) -> Double {
    let off = offset(ofPen: index)
    return min(1, max(0, (metrics.penFadeEdge - abs(off)) / metrics.penFadeWidth))
  }

  /// Hovered 18, its neighbours (±1 slot, not across a breath) 5, the current
  /// pen 10 when nothing is hovered.
  public func lift(ofPen index: Int) -> CGFloat {
    if case .pen(let hovered) = hover {
      let distance = abs(wheelModel.wrap(
        wheelModel.positions[index] - wheelModel.positions[hovered]))
      if distance < 0.1 { return metrics.liftHovered }
      if distance < 1.1 { return metrics.liftNeighbour }
      return 0
    }
    return index == menu.currentPenIndex ? metrics.liftCurrent : 0
  }

  /// The ink a hovered swatch would dip every tip in, while it is hovered.
  public var previewHex: String? {
    guard let tier, tier.kind == .colors, let k = tierHover,
      menu.colors.indices.contains(k), case .swatch(let hex) = menu.colors[k].content
    else { return nil }
    return hex
  }

  /// The ink to paint tips in right now.
  public var tipHex: String { previewHex ?? menu.inkHex }

  /// The width a hovered width item would apply.
  public var previewWidth: Double? {
    guard let tier, tier.kind == .widths, let k = tierHover,
      menu.widths.indices.contains(k), case .width(let points, _) = menu.widths[k].content
    else { return nil }
    return points
  }

  /// The slot offset a target is centred on.
  public func centreOffset(of target: RemoteDrawPuckTarget) -> Double {
    switch target {
    case .pen(let index): return offset(ofPen: index)
    case .well: return metrics.wellOffset
    case .shapes: return metrics.shapesOffset
    }
  }

  /// What the finger's slot offset and radius hover, before hysteresis.
  public func target(atOffset t: Double, radius: CGFloat) -> RemoteDrawPuckTarget? {
    guard radius >= metrics.radius - metrics.cancelInset else { return nil }
    guard t >= metrics.bandStart, t <= metrics.bandEnd else { return nil }
    if t > metrics.dividerOffset { return menu.hasWell ? .well : nil }
    if t < -metrics.dividerOffset { return menu.hasShapes ? .shapes : nil }
    var best: (index: Int, distance: Double)?
    for index in menu.pens.indices {
      let off = offset(ofPen: index)
      guard abs(off) < metrics.penFadeEdge else { continue }
      let distance = abs(off - t)
      if best == nil || distance < best!.distance { best = (index, distance) }
    }
    guard let best, best.distance < metrics.hoverReach else { return nil }
    return .pen(best.index)
  }

  // MARK: Driving

  /// The finger moved.
  @discardableResult
  public mutating func update(location: CGPoint, at time: TimeInterval) -> RemoteDrawPuckChange {
    guard !isReleased else { return [] }
    self.location = location
    if hypot(location.x - summonPoint.x, location.y - summonPoint.y) >= metrics.commitTravel {
      hasTravelled = true
    }
    var change: RemoteDrawPuckChange = []
    let radius = layout.distance(of: location)

    // Back down closes the tier.
    if tier != nil, radius < metrics.radius - metrics.tierCloseInset {
      tier = nil
      tierHover = nil
      change.insert(.tierClosed)
    }

    if tier == nil {
      change.formUnion(refreshHover())
      // Slide up opens the source's tier.
      if radius > metrics.radius - metrics.tierOpenInset, let source = hover,
        let kind = menu.tierKind(for: source)
      {
        tier = RemoteDrawPuckTier(
          source: source, kind: kind, count: menu.items(in: kind).count,
          sourceAngle: layout.angle(ofOffset: centreOffset(of: source)), layout: layout)
        edgeSince = nil
        isScrolling = false
        change.insert(.tierOpened)
      }
    }

    if tier != nil {
      change.formUnion(refreshTierHover())
    } else {
      change.formUnion(trackEdge(at: time, radius: radius))
    }
    return change
  }

  /// Time passed without the finger moving: the edge scroll turns the wheel.
  /// `dt` is the time since the host's previous tick (clamped to 50 ms, so a
  /// stalled frame never jumps the wheel). Mutates nothing unless the wheel
  /// actually turns, so a host can tick every frame for free.
  @discardableResult
  public mutating func advance(by dt: TimeInterval, at time: TimeInterval) -> RemoteDrawPuckChange {
    guard !isReleased, tier == nil, wheelModel.wraps, dt > 0, let since = edgeSince,
      time - since >= metrics.edgeDwell
    else { return [] }
    let t = layout.offset(of: location)
    let direction: Double = t > 0 ? 1 : -1
    let speed = metrics.edgeSpeed
      * min(1, (abs(t) - metrics.edgeZoneStart) / metrics.edgeRamp + metrics.edgeFloor)
    wheel += direction * speed * min(dt, 0.05)
    isScrolling = true
    var change: RemoteDrawPuckChange = [.scrolled]
    change.formUnion(refreshHover())
    return change
  }

  /// What a lift at `location` does.
  public mutating func release(at location: CGPoint, at time: TimeInterval) -> RemoteDrawPuckOutcome {
    update(location: location, at: time)
    isReleased = true
    isScrolling = false
    edgeSince = nil
    guard hasTravelled else { return .cancelled }
    let selection: RemoteDrawPuckSelection
    if let tier {
      guard let item = tierHover else { return .cancelled }
      selection = RemoteDrawPuckSelection(source: tier.source, tierItem: item)
    } else {
      guard let hover else { return .cancelled }
      switch hover {
      case .pen:
        selection = RemoteDrawPuckSelection(source: hover)
      case .well, .shapes:
        guard let opener = menu.openerIndex(for: hover) else { return .cancelled }
        selection = RemoteDrawPuckSelection(source: hover, tierItem: opener)
      }
    }
    guard let commit = menu.commit(for: selection) else { return .cancelled }
    return .commit(commit)
  }

  /// A cancel from outside (a menu change, a cancelled recognizer).
  public mutating func cancel() {
    isReleased = true
    isScrolling = false
    edgeSince = nil
  }

  // MARK: Rules

  private mutating func refreshHover() -> RemoteDrawPuckChange {
    let t = layout.offset(of: location)
    let radius = layout.distance(of: location)
    var next = target(atOffset: t, radius: radius)
    if next != hover, let current = hover, isStillReachable(current) {
      // Hysteresis: judge the finger as if it were 0.15 slot nearer the item
      // it is on. If that still lands on it, it stays.
      let centre = centreOffset(of: current)
      let nudged = t + metrics.hoverHysteresis * (centre >= t ? 1 : -1)
      if target(atOffset: nudged, radius: radius) == current { next = current }
    }
    guard next != hover else { return [] }
    hover = next
    var change: RemoteDrawPuckChange = [.hover]
    if case .pen(let index) = next {
      if let previous = lastHoveredPen, wheelModel.groups[previous] != wheelModel.groups[index] {
        change.insert(.family)
      }
      lastHoveredPen = index
    }
    return change
  }

  /// A pen that scrolled out of the window cannot be held by hysteresis.
  private func isStillReachable(_ target: RemoteDrawPuckTarget) -> Bool {
    if case .pen(let index) = target { return abs(offset(ofPen: index)) < metrics.penFadeEdge }
    return true
  }

  private mutating func refreshTierHover() -> RemoteDrawPuckChange {
    guard let tier else { return [] }
    let position = tier.itemPosition(atAngle: layout.angle(of: location))
    var next = tier.item(atAngle: layout.angle(of: location))
    if next != tierHover, let current = tierHover {
      let nudged = position + metrics.hoverHysteresis * (Double(current) >= position ? 1 : -1)
      if Int(nudged.rounded()) == current { next = current }
    }
    guard next != tierHover else { return [] }
    tierHover = next
    return [.tierHover]
  }

  private mutating func trackEdge(at time: TimeInterval, radius: CGFloat) -> RemoteDrawPuckChange {
    let t = layout.offset(of: location)
    // Only a finger that has deliberately moved can dwell: a thumb that
    // happens to land in an edge zone must not start the wheel by holding still.
    let inZone = wheelModel.wraps && hasTravelled
      && abs(t) > metrics.edgeZoneStart && abs(t) < metrics.edgeZoneEnd
      && radius >= metrics.radius - metrics.cancelInset
    if inZone {
      if edgeSince == nil { edgeSince = time }
      return []
    }
    edgeSince = nil
    guard isScrolling else { return [] }
    isScrolling = false
    // Leaving the edge: settle the hovered pen under the finger.
    guard case .pen(let index) = hover else { return [] }
    let target = min(max(t, -metrics.penWindow), metrics.penWindow)
    wheel += offset(ofPen: index) - target
    var change: RemoteDrawPuckChange = [.snapped]
    change.formUnion(refreshHover())
    return change
  }
}

// MARK: - Hold gate

/// One captured sample on its way to the stroke buffer: where the finger is on
/// screen, and the protocol point that came from it.
public struct RemoteDrawHoldSample: Equatable, Sendable {
  public var location: CGPoint
  public var point: RemoteDrawNormalizedPoint

  public init(location: CGPoint, point: RemoteDrawNormalizedPoint) {
    self.location = location
    self.point = point
  }
}

/// Decides whether a touch is a mark or a summon, **before** either has
/// happened.
///
/// The problem it exists for: a hold that opens the dial starts as an ordinary
/// contact, so a board that deposits ink at first contact deposits a mark that
/// the summon then has to take back — a flick of ink, a draft on the wire, and a
/// cancel chasing it.
///
/// The rule, stated exactly:
///
/// - **Movement is established at `movementThreshold` points of travel from the
///   contact point, which is the same 10pt as
///   `UILongPressGestureRecognizer.allowableMovement`.** The two can therefore
///   never both win: crossing the threshold is precisely what makes the
///   recognizer fail, and the recognizer firing is precisely what proves the
///   threshold was never crossed.
/// - Until then samples are *buffered here* and nothing is appended, drafted or
///   sent. On movement they flush in order, timestamps intact, so the mark still
///   begins at the point the finger touched down.
/// - If the hold fires first the buffer is discarded. Nothing was deposited, so
///   there is nothing to cancel.
/// - A lift before either — a tap — flushes the buffer, so a tap still makes its
///   dot.
/// - Once movement is established the gate latches: a later hold is ignored, and
///   a finger that stops mid-stroke keeps drawing.
///
/// The tradeoff is real and worth naming: with the hold enabled, ink appears at
/// the moment movement is established rather than at first contact. At writing
/// speed the threshold is crossed within a frame or two; a deliberately slow
/// line shows its first 10pt arrive at once. Hosts that would rather have the
/// mark immediately turn the hold off (``Mode/immediate``) and reach controls
/// through their own chrome.
public struct RemoteDrawHoldGate: Equatable, Sendable {
  public enum Mode: Equatable, Sendable {
    /// Buffer until movement or an early lift. The hold can summon.
    case deferUntilMovement
    /// Deposit immediately: the hold is off, or this touch can never summon
    /// (a Pencil, or an accessibility configuration that uses persistent
    /// controls instead).
    case immediate
  }

  public enum Decision: Equatable, Sendable {
    /// Hold the samples back; nothing may reach the stroke buffer yet.
    case buffer
    /// Movement established. Append these, oldest first, and carry on.
    case beginDrawing([RemoteDrawNormalizedPoint])
    /// A lift before movement. Deposit these — a tap is a dot.
    case deposit([RemoteDrawNormalizedPoint])
    /// The hold won. The buffer is dropped; open the dial.
    case summon
    /// Nothing to do.
    case ignore
  }

  private enum Phase: Equatable, Sendable {
    case idle
    case pending
    case drawing
    case summoned
  }

  public var movementThreshold: CGFloat = 10

  private var phase: Phase = .idle
  private var origin: CGPoint = .zero
  private var buffer: [RemoteDrawNormalizedPoint] = []

  public init(movementThreshold: CGFloat = 10) {
    self.movementThreshold = movementThreshold
  }

  public var isPending: Bool { phase == .pending }
  /// Where this touch physically landed, while it is still undecided.
  ///
  /// The dial anchors here rather than at the recognizer's own location: a long
  /// press may fire up to its 10pt allowance away from the contact point, and a
  /// dial that opens 10pt from the finger is a dial that moved.
  public var contactOrigin: CGPoint? { phase == .idle ? nil : origin }
  public var hasBegun: Bool { phase != .idle }
  /// True once this touch is committed to being a mark — the latch the summon
  /// checks so an established stroke is never interrupted by dwelling.
  public var isDrawing: Bool { phase == .drawing }

  public mutating func begin(_ sample: RemoteDrawHoldSample, mode: Mode) -> Decision {
    origin = sample.location
    buffer = [sample.point]
    switch mode {
    case .immediate:
      phase = .drawing
      return flush(as: Decision.beginDrawing)
    case .deferUntilMovement:
      phase = .pending
      return .buffer
    }
  }

  public mutating func append(_ samples: [RemoteDrawHoldSample]) -> Decision {
    switch phase {
    case .idle, .summoned:
      return .ignore
    case .drawing:
      return .beginDrawing(samples.map(\.point))
    case .pending:
      buffer.append(contentsOf: samples.map(\.point))
      guard samples.contains(where: { travelled(to: $0.location) }) else { return .buffer }
      phase = .drawing
      return flush(as: Decision.beginDrawing)
    }
  }

  /// The drag's own location, which arrives once per display refresh and is the
  /// backstop for a touch whose coalesced samples the host is not consuming.
  public mutating func move(to location: CGPoint) -> Decision {
    guard phase == .pending else { return phase == .drawing ? .ignore : .ignore }
    guard travelled(to: location) else { return .buffer }
    phase = .drawing
    return flush(as: Decision.beginDrawing)
  }

  /// The long press fired. `.summon` only while the touch is still undecided.
  public mutating func holdRecognized() -> Decision {
    switch phase {
    case .idle:
      // No touch was ever handed to the gate — a press on chrome, or a host
      // that does not buffer. Summoning is still right.
      phase = .summoned
      return .summon
    case .pending:
      phase = .summoned
      buffer.removeAll()
      return .summon
    case .drawing, .summoned:
      return .ignore
    }
  }

  public mutating func end() -> Decision {
    defer { reset() }
    guard phase == .pending else { return .ignore }
    return buffer.isEmpty ? .ignore : .deposit(buffer)
  }

  public mutating func cancel() {
    reset()
  }

  private mutating func reset() {
    phase = .idle
    buffer.removeAll()
    origin = .zero
  }

  private func travelled(to location: CGPoint) -> Bool {
    hypot(location.x - origin.x, location.y - origin.y) >= movementThreshold
  }

  private mutating func flush(as make: ([RemoteDrawNormalizedPoint]) -> Decision) -> Decision {
    let points = buffer
    buffer.removeAll()
    return make(points)
  }
}

// MARK: - Per-instrument thickness memory

extension RemoteDrawPreferences {
  /// Which width each instrument was last used at, as a JSON object keyed by
  /// ``DrawingStyleKind``'s raw value.
  ///
  /// A sixth key under the same `remotedraw.` namespace the other five use, and
  /// covered by the same `CA92.1` declaration: it is a person's own preference
  /// about their own drawing, written by this SDK into its host's container and
  /// transmitted nowhere.
  ///
  /// One string rather than a key per instrument so `@AppStorage` can hold it,
  /// and so switching tips is one read and one write.
  public static let thicknessByStyleKey = "remotedraw.drawing.thicknessByStyle"

  public static func decodeThicknessMemory(_ raw: String) -> [String: Double] {
    guard let data = raw.data(using: .utf8),
      let decoded = try? JSONDecoder().decode([String: Double].self, from: data)
    else { return [:] }
    return decoded.compactMapValues { value in
      value.isFinite ? normalizedThickness(value) : nil
    }
  }

  public static func encodeThicknessMemory(_ memory: [String: Double]) -> String {
    guard let data = try? JSONEncoder().encode(memory.mapValues { normalizedThickness($0) }),
      let string = String(data: data, encoding: .utf8)
    else { return "" }
    return string
  }

  /// The width to restore for `kind`, or `fallback` when this instrument has
  /// never been used.
  public static func thickness(
    for kind: DrawingStyleKind, in raw: String, fallback: Double
  ) -> Double {
    decodeThicknessMemory(raw)[kind.rawValue] ?? normalizedThickness(fallback)
  }

  public static func rememberingThickness(
    _ value: Double, for kind: DrawingStyleKind, in raw: String
  ) -> String {
    var memory = decodeThicknessMemory(raw)
    memory[kind.rawValue] = normalizedThickness(value)
    return encodeThicknessMemory(memory)
  }

  /// Whether the hold summons the dial at all. Off leaves the first contact
  /// depositing immediately and sends people to the persistent controls.
  public static let holdControlsKey = "remotedraw.ergonomics.holdControls"
}
