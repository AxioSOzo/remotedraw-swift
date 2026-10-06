// The hold-and-slide thumb puck: the Pencil Pro arc.
//
// A Liquid Glass tray that opens above the thumb, holding a wrapping wheel of
// all sixteen instruments beside a colour well and a shapes slot; a second tier
// of widths, colours or shapes blooms above it when the finger slides up.
// Spec: `docs/design/2026-09-24-pencil-pro-arc-puck.md`.
//
// This view paints and animates. It decides nothing: geometry is
// `PuckGeometry.swift`, every rule that can commit or lose a choice is
// `RemoteDrawPuckSession` in `PuckModel.swift`, and both are frozen at summon.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  // MARK: - The puck

  /// The thumb puck.
  ///
  /// Drive it with a ``RemoteDrawPuckSummon`` from a long press (see
  /// ``RemoteDrawHoldGate``); it reports a ``RemoteDrawPuckCommit`` on a
  /// deliberate release, or cancels. Never hit-testable: every touch it reacts
  /// to arrives through `summon`.
  public struct RemoteDrawPuck: View {
    let menu: RemoteDrawPuckMenu
    @Binding var summon: RemoteDrawPuckSummon?
    /// The window's safe area. Decides whether the arc has room above the thumb
    /// (the tray itself uses the whole surface: it is transient and sits above
    /// everything) and keeps the confirmation chip out of the Dynamic Island.
    var safeAreaInsets: EdgeInsets
    /// Where a hold is pending — a finger down and still, not yet a mark or a
    /// summon — so the hold ring can fill around it. `nil` otherwise.
    var pendingHold: CGPoint?
    var metrics: RemoteDrawPuckMetrics
    let onCommit: (RemoteDrawPuckCommit) -> Void
    var onCancel: () -> Void
    /// This press has no arc: the menu is empty, or the surface is degenerate.
    /// The host shows its persistent controls instead.
    var onUnavailable: () -> Void

    public init(
      menu: RemoteDrawPuckMenu,
      summon: Binding<RemoteDrawPuckSummon?>,
      safeAreaInsets: EdgeInsets = EdgeInsets(),
      pendingHold: CGPoint? = nil,
      metrics: RemoteDrawPuckMetrics = .standard,
      onCommit: @escaping (RemoteDrawPuckCommit) -> Void,
      onCancel: @escaping () -> Void = {},
      onUnavailable: @escaping () -> Void = {}
    ) {
      self.menu = menu
      self._summon = summon
      self.safeAreaInsets = safeAreaInsets
      self.pendingHold = pendingHold
      self.metrics = metrics
      self.onCommit = onCommit
      self.onCancel = onCancel
      self.onUnavailable = onUnavailable
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var session: RemoteDrawPuckSession?
    /// The tray is presented (drives the summon/fold scale, blur and fade).
    @State private var isOpen = false
    /// The tooltip waits until the tray has grown out of the thumb.
    @State private var isTooltipReady = false
    /// How the arc is leaving, once the gesture is over.
    @State private var exit: ExitStyle = .none
    /// The committed pen's "click".
    @State private var clickedPen: Int?
    /// The tier closes on its own clock during a commit.
    @State private var isTierDismissed = false
    /// Slots the wheel is drawn turned past where it is: set on summon and
    /// sprung back to 0, so the tray opens with the wheel turning — the first
    /// thing it shows is that it turns.
    @State private var spin: Double = 0
    @State private var chip: PuckChip?
    @State private var generation = 0
    @State private var ticker: Task<Void, Never>?
    @State private var exitTask: Task<Void, Never>?
    @State private var chipTask: Task<Void, Never>?
    @State private var ring = HoldRing()
    @State private var ringTask: Task<Void, Never>?

    enum ExitStyle: Equatable { case none, commit, cancel }

    struct HoldRing: Equatable {
      var center: CGPoint?
      var progress: CGFloat = 0
      var isVisible = false
    }

    public var body: some View {
      GeometryReader { proxy in
        ZStack {
          if let ringCenter = ring.center {
            holdRing(at: ringCenter)
          }
          if let session {
            arc(session, in: proxy.size)
          }
          if let chip {
            chipView(chip, in: proxy.size)
              .id(chip.id)
              .transition(chipTransition)
          }
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
        .onChange(of: summon) { _, next in
          handle(next, in: proxy.size)
        }
        .onChange(of: menu) { _, next in
          guard let session, !session.isReleased, session.menu != next else { return }
          cancelForMenuChange()
        }
        .onChange(of: pendingHold) { _, next in
          handlePendingHold(next)
        }
      }
      .allowsHitTesting(false)
      .accessibilityIdentifier("remotedraw.puck")
    }

    // MARK: Lifecycle

    private func handle(_ next: RemoteDrawPuckSummon?, in size: CGSize) {
      guard let next else {
        // The host took the gesture away (a sheet, an abandoned touch). It
        // already knows; leave quietly.
        if let session, !session.isReleased { beginExit(.cancel) }
        return
      }
      // SwiftUI may deliver the menu and release changes in either order.
      if let session, !session.isReleased, session.menu != menu {
        cancelForMenuChange()
        return
      }
      let now = CACurrentMediaTime()
      switch next.phase {
      case .active:
        guard var current = session, !current.isReleased else {
          open(next, in: size)
          return
        }
        let change = current.update(location: next.location, at: now)
        apply(current, change)
      case .ended:
        guard var current = session, !current.isReleased else {
          summon = nil
          return
        }
        let outcome = current.release(at: next.location, at: now)
        session = current
        switch outcome {
        case .commit(let commit):
          UIImpactFeedbackGenerator(style: .light).impactOccurred()
          onCommit(commit)
          beginExit(.commit, commit: commit)
        case .cancelled:
          onCancel()
          beginExit(.cancel)
        }
        summon = nil
      case .cancelled:
        if var current = session, !current.isReleased {
          current.cancel()
          session = current
          onCancel()
          beginExit(.cancel)
        }
        summon = nil
      }
    }

    private func open(_ next: RemoteDrawPuckSummon, in size: CGSize) {
      guard menu.isPresentable,
        let layout = RemoteDrawPuckSolver.solve(
          thumb: next.anchor, in: size,
          insets: .init(
            top: safeAreaInsets.top, leading: safeAreaInsets.leading,
            bottom: safeAreaInsets.bottom, trailing: safeAreaInsets.trailing),
          metrics: metrics.fitted(hasWell: menu.hasWell, hasShapes: menu.hasShapes))
      else {
        summon = nil
        onUnavailable()
        return
      }
      exitTask?.cancel()
      generation += 1
      hideRing()
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) {
        session = RemoteDrawPuckSession(
          menu: menu, layout: layout, location: next.location, at: CACurrentMediaTime())
        isOpen = false
        isTooltipReady = false
        exit = .none
        clickedPen = nil
        isTierDismissed = false
        let wheel = RemoteDrawPuckWheel(groups: menu.penGroups, metrics: layout.metrics)
        spin = reduceMotion || !wheel.wraps ? 0 : layout.metrics.summonSpin
      }
      UIImpactFeedbackGenerator(style: .medium).impactOccurred()
      // One render at rest, then the summon: the tray scales out of the thumb
      // and the pens rise into it.
      let opening = generation
      DispatchQueue.main.async {
        guard opening == generation else { return }
        withAnimation(
          reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.42, dampingFraction: 0.76)
        ) {
          isOpen = true
        }
        withAnimation(.spring(response: 0.62, dampingFraction: 0.88)) {
          spin = 0
        }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.14)) {
        guard opening == generation else { return }
        isTooltipReady = true
      }
      startTicker()
    }

    /// Stores an update and says what it meant, in animation and in haptics.
    private func apply(_ next: RemoteDrawPuckSession, _ change: RemoteDrawPuckChange) {
      if change.contains(.tierOpened) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.36, dampingFraction: 0.72)) {
          session = next
        }
      } else if change.contains(.tierClosed) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.16) : .spring(response: 0.30, dampingFraction: 0.85)) {
          session = next
        }
      } else if change.contains(.snapped) {
        withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.85)) {
          session = next
        }
      } else if next != session {
        session = next
      }
      feedback(change, next)
    }

    /// Summon medium (in `open`), hover a selection tick, a family boundary a
    /// light impact, tier open a soft impact, commit light, cancel nothing.
    private func feedback(_ change: RemoteDrawPuckChange, _ state: RemoteDrawPuckSession) {
      if change.contains(.tierOpened) {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
      } else if change.contains(.family), state.hover != nil {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
      } else if change.contains(.hover), state.hover != nil {
        UISelectionFeedbackGenerator().selectionChanged()
      } else if change.contains(.tierHover), state.tierHover != nil {
        UISelectionFeedbackGenerator().selectionChanged()
      }
    }

    /// The edge scroll needs time to pass while the finger is still.
    private func startTicker() {
      ticker?.cancel()
      ticker = Task { @MainActor in
        var last = CACurrentMediaTime()
        while !Task.isCancelled {
          try? await Task.sleep(nanoseconds: 16_666_667)
          guard !Task.isCancelled, var current = session, !current.isReleased else { return }
          let now = CACurrentMediaTime()
          let change = current.advance(by: now - last, at: now)
          last = now
          guard !change.isEmpty else { continue }
          apply(current, change)
        }
      }
    }

    private func cancelForMenuChange() {
      if var current = session, !current.isReleased {
        current.cancel()
        session = current
      }
      onCancel()
      beginExit(.cancel)
      summon = nil
    }

    /// Commit: the pen clicks, the tier closes, the other pens sink, the tray
    /// folds into the thumb, the chip pops. Cancel: everything sinks and fades
    /// together, no chip.
    private func beginExit(_ style: ExitStyle, commit: RemoteDrawPuckCommit? = nil) {
      ticker?.cancel()
      exitTask?.cancel()
      let leaving = generation
      guard let session else { return }
      if var released = self.session, !released.isReleased {
        released.cancel()
        self.session = released
      }
      if style == .cancel {
        exit = .cancel
        withAnimation(.easeIn(duration: 0.18)) { isTierDismissed = true }
        withAnimation(.easeIn(duration: 0.24)) { isOpen = false }
        exitTask = Task { @MainActor in
          try? await Task.sleep(nanoseconds: 300_000_000)
          guard !Task.isCancelled, leaving == generation else { return }
          self.session = nil
        }
        return
      }

      // Commit.
      let clicked: Int? = {
        if case .pen(let index) = commit?.selection.source { return index }
        return session.menu.currentPenIndex
      }()
      if !reduceMotion {
        withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { clickedPen = clicked }
      } else {
        clickedPen = clicked
      }
      withAnimation(.easeOut(duration: 0.2)) { isTierDismissed = true }
      exitTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 120_000_000)
        guard !Task.isCancelled, leaving == generation else { return }
        exit = .commit
        try? await Task.sleep(nanoseconds: 160_000_000)
        guard !Task.isCancelled, leaving == generation else { return }
        withAnimation(
          reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.38, dampingFraction: 0.9)
        ) {
          isOpen = false
        }
        if let label = commit?.label {
          showChip(label, thumb: session.layout.thumb)
        }
        try? await Task.sleep(nanoseconds: 450_000_000)
        guard !Task.isCancelled, leaving == generation else { return }
        self.session = nil
        clickedPen = nil
      }
    }

    private func showChip(_ label: String, thumb: CGPoint) {
      chipTask?.cancel()
      let next = PuckChip(label: label, thumb: thumb)
      withAnimation(
        reduceMotion
          ? .easeOut(duration: 0.2).delay(0.08)
          : .spring(response: 0.35, dampingFraction: 0.70).delay(0.08)
      ) {
        chip = next
      }
      chipTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_180_000_000)
        guard !Task.isCancelled, chip?.id == next.id else { return }
        withAnimation(.easeIn(duration: 0.3)) { chip = nil }
      }
    }

    // MARK: Hold ring

    /// Visible only once a hold has been pending for a moment, so a tap or the
    /// first frames of a stroke never flash it; then it fills to the end of the
    /// long press.
    private func handlePendingHold(_ next: CGPoint?) {
      ringTask?.cancel()
      guard let next, session == nil || session?.isReleased == true else {
        hideRing()
        return
      }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { ring = HoldRing(center: next, progress: 0, isVisible: false) }
      let delay = 0.12
      let remaining = max(0.05, metrics.holdDuration - delay)
      ringTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        guard !Task.isCancelled, ring.center == next else { return }
        withTransaction(transaction) { ring.progress = CGFloat(delay / metrics.holdDuration) }
        withAnimation(.easeOut(duration: 0.08)) { ring.isVisible = true }
        withAnimation(.linear(duration: remaining)) { ring.progress = 1 }
      }
    }

    private func hideRing() {
      ringTask?.cancel()
      guard ring.center != nil else { return }
      withAnimation(.easeOut(duration: 0.1)) { ring.isVisible = false }
      ring.center = nil
    }

    private func holdRing(at center: CGPoint) -> some View {
      Circle()
        .trim(from: 0, to: ring.progress)
        .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .frame(width: 52, height: 52)
        // A white ring on white paper needs an edge to exist at all.
        .shadow(color: .black.opacity(0.28), radius: 1.5)
        .opacity(ring.isVisible ? 1 : 0)
        .position(center)
        .accessibilityHidden(true)
    }

    // MARK: Paint

    private func unit(_ point: CGPoint, in size: CGSize) -> UnitPoint {
      UnitPoint(
        x: size.width > 0 ? point.x / size.width : 0.5,
        y: size.height > 0 ? point.y / size.height : 0.5)
    }

    private func arc(_ session: RemoteDrawPuckSession, in size: CGSize) -> some View {
      let layout = session.layout
      let tierVisible = session.tier != nil && !isTierDismissed
      return ZStack {
        PuckTray(
          session: session, isOpen: isOpen, exit: exit, clickedPen: clickedPen, spin: spin,
          reduceMotion: reduceMotion, size: size)
          .scaleEffect(
            reduceMotion ? 1 : (isOpen ? 1 : 0.18), anchor: unit(layout.thumb, in: size))
          .blur(radius: reduceMotion || isOpen ? 0 : 6)
          .opacity(isOpen ? 1 : 0)

        if tierVisible, let tier = session.tier {
          PuckTierView(session: session, tier: tier, size: size, reduceMotion: reduceMotion)
            .id(tier.source)
            .transition(tierTransition(tier, in: size))
        }

        // Always present, so a release fades it with everything else rather
        // than cutting it.
        PuckTooltip(session: session, isOpen: isOpen && isTooltipReady, size: size, reduceMotion: reduceMotion)
      }
      .frame(width: size.width, height: size.height)
    }

    private func tierTransition(_ tier: RemoteDrawPuckTier, in size: CGSize) -> AnyTransition {
      let anchor = unit(
        tier.layout.point(radius: tier.layout.metrics.radius, angle: tier.sourceAngle), in: size)
      if reduceMotion { return .opacity }
      return .asymmetric(
        insertion: .scale(scale: 0.6, anchor: anchor).combined(with: .opacity),
        removal: .scale(scale: 0.85, anchor: anchor).combined(with: .opacity))
    }

    // MARK: Chip

    private var chipTransition: AnyTransition {
      if reduceMotion { return .opacity }
      return .asymmetric(
        insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity),
        removal: .offset(y: -14).combined(with: .opacity))
    }

    private func chipView(_ chip: PuckChip, in size: CGSize) -> some View {
      // Rendered from the live menu, after the host applied the commit: the
      // sample is what the next mark will be, not what the arc assumed.
      let pen = menu.pens.first { $0.isCurrent }?.instrument
      return HStack(spacing: 8) {
        if let pen {
          RemoteDrawPuckInkSample(kind: pen, hex: menu.inkHex, width: min(menu.width, 8))
            .frame(width: 40, height: 16)
        }
        Text(chip.label)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.primary)
          .lineLimit(1)
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 9)
      .fixedSize()
      .puckGlass(Capsule())
      .position(
        x: min(max(chip.thumb.x, 96), size.width - 96),
        y: max(safeAreaInsets.top + 26, chip.thumb.y - metrics.chipAbove))
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("remotedraw.puck.chip")
    }
  }

  struct PuckChip: Equatable, Identifiable {
    let id = UUID()
    let label: String
    let thumb: CGPoint
  }

  // MARK: - The tray

  private struct PuckTray: View {
    let session: RemoteDrawPuckSession
    let isOpen: Bool
    let exit: RemoteDrawPuck.ExitStyle
    let clickedPen: Int?
    let spin: Double
    let reduceMotion: Bool
    let size: CGSize

    @Environment(\.colorSchemeContrast) private var contrast

    private var layout: RemoteDrawPuckLayout { session.layout }
    private var metrics: RemoteDrawPuckMetrics { layout.metrics }
    private var ink: Color { RemoteDrawColorPalette.color(session.tipHex) }

    private var band: PuckArcBand {
      let a0 = layout.bandStartAngle, a1 = layout.bandEndAngle
      return PuckArcBand(
        center: layout.center, inner: metrics.bandInnerRadius, outer: metrics.bandOuterRadius,
        start: min(a0, a1), end: max(a0, a1), corner: metrics.bandCorner)
    }

    var body: some View {
      ZStack {
        if session.wheelModel.wraps {
          PuckScrollTrack(
            layout: layout, wheel: session.wheelModel, turned: session.wheel - spin,
            isScrolling: session.isScrolling, contrast: contrast)
        }
        ZStack {
          ForEach(session.menu.pens.indices, id: \.self) { index in
            pen(index)
          }
        }
        .frame(width: size.width, height: size.height)
        // The pens stand on the ledge: their bases end there, above the track.
        .clipShape(
          PuckLedgeClip(
            center: layout.center, radius: layout.baseSide(metrics.radius - metrics.ledgeInset),
            outside: layout.orientation == .above),
          style: FillStyle(eoFill: true))
        if !session.wheelModel.wraps { breaths }
        if session.menu.hasShapes {
          divider(at: -metrics.dividerOffset)
          shapes
        }
        if session.menu.hasWell {
          divider(at: metrics.dividerOffset)
          well
        }
      }
      .frame(width: size.width, height: size.height)
      .clipShape(band)
      .puckGlass(band)
    }

    // MARK: Pens

    @ViewBuilder private func pen(_ index: Int) -> some View {
      // Drawn where the summon spin has it; chosen where the session has it.
      let off = session.offset(ofPen: index) + spin
      if abs(off) < 3.2 {
        let item = session.menu.pens[index]
        let hovered = session.hover == .pen(index)
        let lift = session.lift(ofPen: index)
        let clicked = clickedPen == index
        let sunk = !isOpen || (exit != .none && !clicked)
        let angle = layout.angle(ofOffset: off)
        let radius = layout.penRadius(lift: lift, sink: sunk && !reduceMotion ? 70 : 0)
        penFace(item)
          .scaleEffect(clicked && !reduceMotion ? 1.08 : 1, anchor: .bottom)
          .rotationEffect(.radians(layout.penRotation(at: angle)))
          .position(layout.point(radius: radius, angle: angle))
          .opacity(min(1, max(0, (metrics.penFadeEdge - abs(off)) / metrics.penFadeWidth)))
          .zIndex(hovered ? 2 : 0)
          .animation(liftAnimation, value: lift)
          .animation(sinkAnimation(index), value: sunk)
          .animation(.spring(response: 0.2, dampingFraction: 0.5), value: clicked)
          .animation(.easeInOut(duration: 0.22), value: session.tipHex)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(Text(item.title))
          .accessibilityAddTraits(item.isCurrent ? [.isSelected] : [])
          .accessibilityIdentifier("remotedraw.puck.value.\(item.id)")
      }
    }

    @ViewBuilder private func penFace(_ item: RemoteDrawPuckItem) -> some View {
      if let kind = item.instrument {
        RemoteDrawPuckInstrument(kind: kind, ink: ink)
      } else if case .symbol(let name) = item.content {
        // A board that only points: its one tool, upright in the wheel.
        Image(systemName: name)
          .font(.system(size: 24, weight: .medium))
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(ink)
          .frame(width: 44, height: 120, alignment: .top)
          .padding(.top, 8)
      }
    }

    /// Lifts: spring 0.28/0.62; Reduce Motion: an instant 0.12s change.
    private var liftAnimation: Animation {
      reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.62)
    }

    /// Rising in: staggered 20 ms per slot from the current pen. Sinking after
    /// a commit: 15 ms per slot from the clicked pen. Cancel: all together.
    private func sinkAnimation(_ index: Int) -> Animation {
      if reduceMotion { return .easeOut(duration: 0.12) }
      let positions = session.wheelModel.positions
      func distance(to other: Int?) -> Double {
        guard let other, positions.indices.contains(other) else { return 0 }
        return abs(session.wheelModel.wrap(positions[index] - positions[other]))
      }
      switch exit {
      case .none:
        return .spring(response: 0.42, dampingFraction: 0.78)
          .delay(0.02 * distance(to: session.menu.currentPenIndex))
      case .commit:
        return .spring(response: 0.34, dampingFraction: 0.90).delay(0.015 * distance(to: clickedPen))
      case .cancel:
        return .easeIn(duration: 0.18)
      }
    }

    // MARK: Fixed slots

    private var breaths: some View {
      ForEach(Array(session.wheelModel.breathOffsets(wheel: session.wheel - spin).enumerated()), id: \.offset) {
        _, off in
        Circle()
          .fill(Color.primary.opacity(0.3))
          .frame(width: 3.5, height: 3.5)
          .position(layout.point(radius: layout.baseSide(metrics.radius - 44), offset: off))
          .opacity(min(1, max(0, (metrics.penFadeEdge - abs(off)) / metrics.penFadeWidth)))
      }
    }

    private func divider(at offset: Double) -> some View {
      Path { path in
        path.move(to: layout.point(radius: layout.baseSide(metrics.radius - 22), offset: offset))
        path.addLine(to: layout.point(radius: layout.baseSide(metrics.radius + 22), offset: offset))
      }
      .stroke(
        Color(uiColor: .separator).opacity(contrast == .increased ? 1 : 0.8),
        lineWidth: contrast == .increased ? 1 : 0.5)
    }

    private func slotPosition(_ offset: Double, hovered: Bool) -> CGPoint {
      let angle = layout.angle(ofOffset: offset)
      let base = layout.point(radius: metrics.radius - 4, angle: angle)
      guard hovered else { return base }
      // "6pt up" is up the screen, whichever way the arc opens.
      let up = layout.up(at: angle)
      return CGPoint(x: base.x + up.dx * 6, y: base.y + up.dy * 6)
    }

    private var well: some View {
      let hovered = session.hover == .well
      return RemoteDrawPuckColorWell(ink: ink, size: 32)
        .scaleEffect(hovered && !reduceMotion ? 1.14 : 1)
        .position(slotPosition(metrics.wellOffset, hovered: hovered && !reduceMotion))
        .animation(slotAnimation, value: hovered)
        .animation(.easeInOut(duration: 0.22), value: session.tipHex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Color"))
        .accessibilityIdentifier("remotedraw.puck.well")
    }

    private var shapes: some View {
      let hovered = session.hover == .shapes
      return RemoteDrawPuckShapesWell(size: 32)
        .scaleEffect(hovered && !reduceMotion ? 1.14 : 1)
        .position(slotPosition(metrics.shapesOffset, hovered: hovered && !reduceMotion))
        .animation(slotAnimation, value: hovered)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Shapes"))
        .accessibilityIdentifier("remotedraw.puck.shapes")
    }

    private var slotAnimation: Animation {
      reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.65)
    }
  }

  // MARK: - The second tier

  private struct PuckTierView: View {
    let session: RemoteDrawPuckSession
    let tier: RemoteDrawPuckTier
    let size: CGSize
    let reduceMotion: Bool

    private var layout: RemoteDrawPuckLayout { tier.layout }
    private var metrics: RemoteDrawPuckMetrics { layout.metrics }
    private var items: [RemoteDrawPuckItem] { session.menu.items(in: tier.kind) }
    private var ink: Color { RemoteDrawColorPalette.color(session.tipHex) }

    var body: some View {
      let a0 = tier.bandStartAngle, a1 = tier.bandEndAngle
      let band = PuckArcBand(
        center: layout.center, inner: tier.radius - metrics.tierHalfBand,
        outer: tier.radius + metrics.tierHalfBand, start: min(a0, a1), end: max(a0, a1),
        corner: metrics.tierHalfBand)
      return ZStack {
        ForEach(items.indices, id: \.self) { index in
          itemView(index)
        }
      }
      .frame(width: size.width, height: size.height)
      .puckGlass(band)
    }

    @ViewBuilder private func itemView(_ index: Int) -> some View {
      let item = items[index]
      let hovered = session.tierHover == index
      let angle = tier.angle(ofItem: index)
      let base = layout.point(radius: tier.radius, angle: angle)
      let out = layout.up(at: angle)
      let lift: CGFloat = hovered && !reduceMotion ? 4 : 0
      face(item, hovered: hovered)
        .scaleEffect(hovered && !reduceMotion ? 1.28 : 1)
        .shadow(color: .black.opacity(hovered ? 0.18 : 0), radius: 3, y: 1)
        .position(x: base.x + out.dx * lift, y: base.y + out.dy * lift)
        .animation(
          reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.26, dampingFraction: 0.60),
          value: hovered)
        .animation(.easeInOut(duration: 0.22), value: session.tipHex)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.title))
        .accessibilityAddTraits(item.isCurrent ? [.isSelected] : [])
        .accessibilityIdentifier("remotedraw.puck.value.\(item.id)")
    }

    @ViewBuilder private func face(_ item: RemoteDrawPuckItem, hovered: Bool) -> some View {
      switch item.content {
      case .width(let points, _):
        // True size in the tip colour; the current width ringed.
        ZStack {
          if item.isCurrent {
            Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
              .frame(width: 34, height: 34)
          }
          Circle().fill(ink)
            .frame(width: 3 + CGFloat(points) * 1.15, height: 3 + CGFloat(points) * 1.15)
        }
        .frame(width: 40, height: 40)
      case .swatch(let hex):
        ZStack {
          Circle().fill(RemoteDrawColorPalette.color(hex)).frame(width: 28, height: 28)
          Circle().strokeBorder(Color.black.opacity(0.1), lineWidth: 0.5).frame(width: 28, height: 28)
          if item.isCurrent {
            Circle().strokeBorder(Color.white, lineWidth: 2.5).frame(width: 21, height: 21)
          }
          if hovered {
            Circle().strokeBorder(Color.white, lineWidth: 2).frame(width: 28, height: 28)
          }
        }
        .frame(width: 40, height: 40)
      case .colorWell:
        RemoteDrawPuckColorWell(ink: RemoteDrawColorPalette.color(session.menu.inkHex), size: 26)
          .frame(width: 40, height: 40)
      case .symbol(let name):
        ZStack {
          if item.isCurrent {
            Circle().strokeBorder(Color.primary.opacity(0.28), lineWidth: 1)
              .frame(width: 34, height: 34)
          }
          Image(systemName: name)
            .font(.system(size: 17, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.primary)
        }
        .frame(width: 40, height: 40)
      case .instrument(let kind), .specimen(let kind, _, _):
        RemoteDrawPuckInkSample(kind: kind, hex: session.tipHex, width: session.menu.width)
          .frame(width: 36, height: 20)
      }
    }
  }

  // MARK: - Tooltip

  private struct PuckTooltip: View {
    let session: RemoteDrawPuckSession
    /// The tooltip arrives with the tray, not before it.
    let isOpen: Bool
    let size: CGSize
    let reduceMotion: Bool

    private struct Content: Equatable {
      var sample: DrawingStyleKind?
      var title: String
      var detail: String?
      var width: Double
      var point: CGPoint
    }

    private var content: Content? {
      guard isOpen, !session.isReleased else { return nil }
      let layout = session.layout
      let metrics = layout.metrics
      let menu = session.menu
      if let tier = session.tier {
        guard let k = session.tierHover else { return nil }
        let point = layout.tooltipPoint(
          radius: tier.radius + metrics.tooltipTierOutset, angle: tier.angle(ofItem: k))
        let current = menu.currentPenIndex.flatMap { menu.pens[$0].instrument }
        switch tier.kind {
        case .widths:
          guard case .pen(let source) = tier.source, menu.pens.indices.contains(source),
            menu.widths.indices.contains(k)
          else { return nil }
          return Content(
            sample: menu.pens[source].instrument, title: menu.pens[source].title,
            detail: menu.widths[k].title, width: session.previewWidth ?? menu.width, point: point)
        case .colors:
          guard menu.colors.indices.contains(k) else { return nil }
          let item = menu.colors[k]
          return Content(
            sample: item.opensSheet ? nil : current, title: item.title, detail: nil,
            width: menu.width, point: point)
        case .shapes:
          guard menu.shapes.indices.contains(k) else { return nil }
          return Content(sample: nil, title: menu.shapes[k].title, detail: nil, width: menu.width, point: point)
        }
      }
      switch session.hover {
      case .pen(let index):
        let item = menu.pens[index]
        return Content(
          sample: item.instrument, title: item.title, detail: item.detail, width: menu.width,
          point: layout.tooltipPoint(
            radius: metrics.radius + metrics.tooltipPenOutset,
            angle: layout.angle(ofOffset: session.offset(ofPen: index))))
      case .well:
        return Content(
          sample: nil, title: "Color", detail: menu.colorTitle.isEmpty ? nil : menu.colorTitle,
          width: menu.width,
          point: layout.tooltipPoint(
            radius: metrics.radius + metrics.tooltipSlotOutset,
            angle: layout.angle(ofOffset: metrics.wellOffset)))
      case .shapes:
        return Content(
          sample: nil, title: "Shapes", detail: menu.shapeTitle.isEmpty ? nil : menu.shapeTitle,
          width: menu.width,
          point: layout.tooltipPoint(
            radius: metrics.radius + metrics.tooltipSlotOutset,
            angle: layout.angle(ofOffset: metrics.shapesOffset)))
      case nil:
        return nil
      }
    }

    var body: some View {
      ZStack {
        if let content {
          HStack(spacing: 8) {
            if let sample = content.sample {
              RemoteDrawPuckInkSample(kind: sample, hex: session.tipHex, width: min(content.width, 9))
                .frame(width: 42, height: 17)
                .id("\(sample.rawValue)\(session.tipHex)\(content.width)")
                .transition(.opacity)
            }
            Text(content.title)
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.primary)
              .contentTransition(.interpolate)
              .accessibilityIdentifier("remotedraw.puck.readout.title")
            if let detail = content.detail {
              Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.interpolate)
            }
          }
          .lineLimit(1)
          .padding(.horizontal, 14)
          .padding(.vertical, 8)
          .fixedSize()
          .puckGlass(Capsule())
          .position(content.point)
          .animation(.spring(response: 0.3, dampingFraction: 0.8), value: content.title)
          .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.30, dampingFraction: 0.85),
            value: content.point)
          .transition(reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity))
          .accessibilityElement(children: .combine)
          .accessibilityIdentifier("remotedraw.puck.readout")
        }
      }
      .frame(width: size.width, height: size.height)
      .animation(.easeOut(duration: 0.14), value: content == nil)
    }
  }

  // MARK: - Glass

  /// Liquid Glass on iOS 26; `.regularMaterial` with a light tint before it;
  /// an opaque light fill under Reduce Transparency. Increase Contrast adds a
  /// stronger hairline everywhere.
  private struct PuckGlass<S: Shape>: ViewModifier {
    let shape: S

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
      glass(content)
        .overlay {
          if contrast == .increased {
            shape.stroke(Color.primary.opacity(0.45), lineWidth: 1)
          }
        }
    }

    @ViewBuilder private func glass(_ content: Content) -> some View {
      if reduceTransparency {
        content
          .background(shape.fill(Color(uiColor: .secondarySystemBackground)))
          .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
          .compositingGroup()
          .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
      } else if #available(iOS 26, *) {
        liquid(content)
      } else {
        material(content)
      }
    }

    @ViewBuilder private func liquid(_ content: Content) -> some View {
      #if compiler(>=6.2)
        if #available(iOS 26, *) {
          content.glassEffect(.regular, in: shape)
        } else {
          material(content)
        }
      #else
        material(content)
      #endif
    }

    private func material(_ content: Content) -> some View {
      content
        .background {
          shape.fill(.regularMaterial)
          shape.fill(Color.white.opacity(colorScheme == .dark ? 0.04 : 0.35))
        }
        .overlay(shape.stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.6), lineWidth: 0.5))
        .compositingGroup()
        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
    }
  }

  extension View {
    fileprivate func puckGlass<S: Shape>(_ shape: S) -> some View {
      modifier(PuckGlass(shape: shape))
    }
  }
#endif
