// The embeddable drawing surface.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  /// RemoteDraw's drawing board, as a `View` you can put anywhere.
  ///
  /// Paper and its tooth, the ink pass with its group ceiling, capture with
  /// pressure and tilt and palm rejection, the one-handed control cluster, the
  /// long-press tool fan, the controls sheet, text placement, the board's
  /// shape-snap offer, and — for a `kind: "map"` board — the geography itself.
  /// Everything the first-party app's board is, minus the one thing §4 of the
  /// design keeps first-party: element selection.
  ///
  /// ```swift
  /// RemoteDrawSurface(session: session)
  /// ```
  ///
  /// ## What is behind the ink
  ///
  /// Three answers, in this order:
  ///
  /// 1. **`background:`** — whatever the host builds. Wins over everything, on
  ///    every board kind. This is how a customer keeps their own cartography
  ///    (Mapbox, Google Maps, a satellite raster) instead of Apple's, or puts
  ///    the ink over a floor plan the SDK has never heard of. A background that
  ///    moves reports its board rectangle back through
  ///    ``RemoteDrawGroundContext/reportViewport``, and the surface re-projects
  ///    every stroke through it.
  /// 2. **The built-in MapKit ground** — for a `kind: "map"` board that declared
  ///    `coordinateSpace.bounds`. Same geography as the first-party app, same
  ///    board↔geo transform as `@remotedraw/geometry`.
  /// 3. **The canvas's own ground** — paper, whiteboard or a flat tone, from
  ///    ``RemoteDrawAppearance/ground`` or the board's `target.kind`.
  ///
  /// ## Embeddable first, takeover second
  ///
  /// This is a plain `View` with no presentation of its own — no cover, no
  /// navigation, no assumption that it owns the screen. ``RemoteDrawTakeover``
  /// is this view plus a `fullScreenCover`, scene-phase wiring and an exit.
  /// That order is deliberate: shipping only the takeover guarantees the first
  /// customer who wants the board inside their own layout forks the SDK.
  ///
  /// ## What it does to the host's environment, and what it does not
  ///
  /// It locks its **own** subtree to the light colour scheme, because the ink,
  /// the paper and the chrome are one drawing and a half-dark board is not a
  /// board. It does **not** stamp the host's window — the first-party app does
  /// exactly that, and an SDK that did it inside a dark-mode host would be
  /// reaching outside its own presentation.
  ///
  /// It clamps Dynamic Type at `.xxxLarge` for the same reason the app does:
  /// past that, chrome swallows the paper. Both are
  /// ``RemoteDrawAppearance`` values.
  public struct RemoteDrawSurface: View {
    @ObservedObject private var session: RemoteDrawSenderSession
    private let appearance: RemoteDrawAppearance
    private let strings: RemoteDrawStrings
    private let onLeave: (() -> Void)?
    private let background: ((RemoteDrawGroundContext) -> AnyView)?

    // Preferences. `@AppStorage` on the same keys the first-party app has always
    // written, so a person upgrading keeps their instrument.
    @AppStorage(RemoteDrawPreferences.handednessKey)
    private var handednessRaw = RemoteDrawHandedness.automatic.rawValue
    @AppStorage(RemoteDrawPreferences.drawingStyleKey)
    private var styleKindRaw = RemoteDrawPreferences.defaultStyleKind.rawValue
    @AppStorage(RemoteDrawPreferences.drawingThicknessKey)
    private var thickness = RemoteDrawPreferences.defaultThickness
    @AppStorage(RemoteDrawPreferences.drawingColorKey)
    private var colorRaw = RemoteDrawColorPalette.defaultColor
    @AppStorage(RemoteDrawPreferences.drawingFillKey)
    private var isFillEnabled = false

    @State private var selectedTool: RemoteDrawTool = .auto
    @State private var strokeId: RemoteDrawStrokeID?
    @State private var predicted: [CGPoint] = []
    @State private var touches = RemoteDrawTouchSnapshot()
    @State private var dragIntent: DragIntent = .none
    @State private var suppressUntil = Date.distantPast
    @State private var isControlsPresented = false
    @State private var summon: RemoteDrawRadialSummon?
    @State private var textEntry: TextEntry?
    @State private var isTextTapActive = false
    @State private var isUndoing = false
    @State private var visibleError: RemoteDrawError?
    @State private var lastTextDraftAt = Date.distantPast
    /// What the ground is currently showing, in board space. ``RemoteDrawBoardViewport/full``
    /// until something says otherwise, which is the identity mapping and right
    /// for every ground that does not move.
    @State private var boardViewport = RemoteDrawBoardViewport.full
    @State private var hasBoardViewport = false
    @FocusState private var isTextFocused: Bool

    private let suppressionDuration: TimeInterval = 0.22
    private let cornerControlsSize: CGFloat = 72
    private let cornerControlsTravel: CGFloat = 30
    private let cornerControlsMaxHorizontalDrift: CGFloat = 58
    private let cornerControlsResolveDistance: CGFloat = 16

    public init(
      session: RemoteDrawSenderSession,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      onLeave: (() -> Void)? = nil
    ) {
      self.session = session
      self.appearance = appearance
      self.strings = strings
      self.onLeave = onLeave
      self.background = nil
    }

    /// The board with a ground of your own behind it.
    ///
    /// ```swift
    /// RemoteDrawSurface(session: session) { ground in
    ///   MyMapView(bounds: ground.mapBounds)
    ///     .onCameraChange { ground.reportViewport(myBoardRectangle()) }
    /// }
    /// ```
    ///
    /// The builder replaces the built-in ground entirely — including the MapKit
    /// one — for as long as it is supplied. See the type's own documentation for
    /// the precedence rules, and ``RemoteDrawGroundContext`` for the one thing a
    /// moving ground owes the surface.
    public init<Background: View>(
      session: RemoteDrawSenderSession,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      onLeave: (() -> Void)? = nil,
      @ViewBuilder background: @escaping (RemoteDrawGroundContext) -> Background
    ) {
      self.session = session
      self.appearance = appearance
      self.strings = strings
      self.onLeave = onLeave
      self.background = { AnyView(background($0)) }
    }

    /// What a drag on this surface is for.
    ///
    /// The bottom corners are a swipe-to-open-controls affordance, so a drag
    /// that starts there has to stay undecided until it has travelled far
    /// enough to mean one thing or the other. Guessing early is how a stroke
    /// that begins in the corner disappears into a sheet.
    private enum DragIntent {
      case none
      case drawing
      case cornerControls
      case suppressing
    }

    private struct TextEntry: Identifiable, Equatable {
      let id = UUID()
      var surfacePoint: RemoteDrawNormalizedPoint
      var text: String
    }

    public var body: some View {
      ZStack {
        GeometryReader { proxy in
          let size = proxy.size
          ZStack {
            groundLayer(in: size)

            RemoteDrawBoardCanvas(
              ground: ground,
              surface: surfaceKind,
              guide: fieldGuide,
              sections: [RemoteDrawBoardSection(marks: marks)],
              appearance: appearance
            )
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(drag(in: size))
            .accessibilityElement()
            .accessibilityLabel(strings.drawingAreaLabel)
            .accessibilityHint(strings.drawingAreaHint)
            .accessibilityAddTraits(.allowsDirectInteraction)

            // Fills the same rectangle as the canvas, so UIKit samples and
            // SwiftUI drag locations are both in surface-local points.
            RemoteDrawGestureInstaller(
              onTouchChange: { touches = $0 },
              onTwoFingerTap: undoFromGesture,
              onThreeFingerTap: openControlsFromGesture,
              onPredictedTouches: { predicted = $0 },
              // The stroke grows from **here**, not from the drag. A
              // `DragGesture` reports one location per display refresh and
              // cannot see a `UITouch` at all, so growing the buffer from its
              // locations threw away three samples in four on a Pencil — 7.7% of
              // the pixels of a brisk cursive mark, measured at 1:1. The drag
              // decides what the touch *means*; this channel supplies the
              // geometry, with the force and attitude already attached.
              onCoalescedSamples: { appendCoalesced($0, in: size) },
              onLongPressBegan: { summon = RemoteDrawRadialSummon(anchor: $0, location: $0) },
              onLongPressMoved: { summon?.location = $0 },
              onLongPressEnded: { location in
                summon?.location = location
                summon?.phase = .ended
              },
              onLongPressCancelled: { summon?.phase = .cancelled },
              isLongPressEnabled: !isControlsPresented && strokeId == nil,
              longPressCancelsTouches: false,
              // The controls sheet owns every touch while it is up.
              isActive: !isControlsPresented
            )
            .frame(width: size.width, height: size.height)
            .allowsHitTesting(false)

            RemoteDrawRadialToolMenu(items: radialItems, summon: $summon)
              .frame(maxWidth: .infinity, maxHeight: .infinity)

            textPin(in: size)

            RemoteDrawLiveInkGlow(isActive: session.live != nil)
              .frame(width: size.width, height: size.height)
          }
          .onAppear {
            lastSurfaceSize = size
            ground.prepare(toothExtent: max(size.width, size.height))
            installStrokeSpace()
          }
          .onChange(of: size) { _, next in lastSurfaceSize = next }
          .onChange(of: styleKindRaw) { _, _ in warmTooth(max(size.width, size.height)) }
        }
        .ignoresSafeArea()

        controlsOverlay
        errorBanner

        if let unsupported = unsupportedSurface {
          RemoteDrawUnsupportedSurfaceView(unsupported: unsupported, onLeave: onLeave)
        }
      }
      .environment(\.remoteDrawAppearance, resolvedAppearance)
      .environment(\.remoteDrawStrings, strings)
      // Scoped to this subtree. Never `UIWindow.overrideUserInterfaceStyle` —
      // that is the host's window, not ours.
      .preferredColorScheme(.light)
      .dynamicTypeSize(...appearance.maximumDynamicTypeSize)
      .sheet(isPresented: $isControlsPresented) {
        RemoteDrawControlsSheet(
          session: session,
          selectedTool: $selectedTool,
          styleKindRaw: $styleKindRaw,
          thickness: $thickness,
          colorRaw: $colorRaw,
          isFillEnabled: $isFillEnabled,
          handednessRaw: $handednessRaw,
          onLeave: onLeave
        )
        .environment(\.remoteDrawAppearance, resolvedAppearance)
        .environment(\.remoteDrawStrings, strings)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.regularMaterial)
        .tint(resolvedAppearance.accent)
      }
      .onAppear {
        normalizeSelectedTool()
        // A screen that dims mid-stroke is a bug report.
        UIApplication.shared.isIdleTimerDisabled = true
        Task { await session.markActive() }
      }
      .onDisappear {
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await session.markInactive() }
      }
      .onChange(of: session.capabilities) { _, _ in normalizeSelectedTool() }
      // A host that mounts this view before it has joined gets the board's
      // geography as soon as the board describes itself, rather than never.
      .onChange(of: session.session) { _, _ in installStrokeSpace() }
      .onChange(of: selectedTool) { _, tool in
        if tool != .text { commitText() }
      }
      .onChange(of: session.phase) { _, phase in
        // One soft impact on submit; one warning when the board goes away
        // under you. Never per stroke.
        switch phase {
        case .submitted:
          UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        case .ended(let reason) where reason != .left:
          UINotificationFeedbackGenerator().notificationOccurred(.warning)
        default:
          break
        }
      }
      .onChange(of: session.lastError) { _, error in
        withAnimation(.easeOut(duration: 0.18)) { visibleError = error }
      }
      .onChange(of: textEntry?.id) { _, id in
        guard id != nil else { return }
        isTextFocused = true
      }
    }

    // MARK: Appearance

    /// The board's own surface wins unless the host named one.
    ///
    /// A whiteboard board should not draw on paper because the SDK's default
    /// said so — the ground is a fact about the board, and `target.kind` *is*
    /// the surface.
    private var ground: RemoteDrawGround {
      appearance.ground ?? session.session?.target?.ground ?? .paper
    }

    /// The render axis. The board's own `target.kind`, not the ground's — see
    /// ``RemoteDrawBoardCanvas``.
    private var surfaceKind: RemoteDrawInkSurface.Kind {
      RemoteDrawInkSurface.kind(forProtocolName: session.session?.target?.kind)
    }

    private var resolvedAppearance: RemoteDrawAppearance {
      var resolved = appearance
      resolved.ground = ground
      return resolved
    }

    private var handedness: RemoteDrawHandedness {
      RemoteDrawHandedness(rawValue: handednessRaw) ?? appearance.handedness
    }

    private var styleKind: DrawingStyleKind {
      DrawingStyleKind(rawValue: styleKindRaw) ?? RemoteDrawPreferences.defaultStyleKind
    }

    private var style: RemoteDrawDrawingStyle {
      RemoteDrawDrawingStyle(
        kind: styleKind,
        color: RemoteDrawColorPalette.wireColor(colorRaw),
        width: RemoteDrawPreferences.normalizedThickness(thickness),
        fill: isFillEnabled ? RemoteDrawDrawingFill() : nil
      )
    }

    private var strokeWidth: CGFloat {
      CGFloat(RemoteDrawPreferences.normalizedThickness(thickness))
    }

    private func warmTooth(_ extent: CGFloat) {
      RemoteDrawInkComposer.prepareTooth(
        for: style, surface: surfaceKind, extent: extent)
    }

    // MARK: Marks

    /// Settled ink and the live stroke, in one section.
    ///
    /// One section and not two: shading is stroke after stroke of one
    /// instrument, so the mark under the finger has to accumulate into the same
    /// buffer the settled ones did, or it sits on top of the ceiling instead of
    /// under it.
    private var marks: [RemoteDrawBoardMark] {
      let space = session.strokeSpace?() ?? .surface
      var marks = session.strokes.compactMap {
        RemoteDrawBoardMark($0, space: space, lineWidth: $0.isLocalEcho ? strokeWidth : 6)
      }
      if let live = session.live {
        marks.append(
          RemoteDrawBoardMark(
            id: live.id,
            type: live.tool.rawValue,
            points: RemoteDrawInkGeometry.previewPointsWithPrediction(
              live.points, predicted: predictedPoints),
            style: live.style,
            lineWidth: strokeWidth
          ))
      }
      return marks
    }

    /// Predicted locations, normalized against the surface.
    ///
    /// A separate channel from the captured buffer and it stays that way: these
    /// are positions the finger has not reached, and a predicted sample that
    /// never enters ``RemoteDrawSenderSession/append(_:)`` can never reach the
    /// wire.
    private var predictedPoints: [RemoteDrawNormalizedPoint] {
      guard let size = lastSurfaceSize, RemoteDrawDrawingSurfaceGeometry.isUsable(size)
      else { return [] }
      return predicted.map {
        let point = RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: $0, in: size)
        return RemoteDrawNormalizedPoint(
          x: RemoteDrawSurfaceGeometry.clamp01(Double(point.x)),
          y: RemoteDrawSurfaceGeometry.clamp01(Double(point.y))
        )
      }
    }

    @State private var lastSurfaceSize: CGSize?

    // MARK: Capture

    private func drag(in size: CGSize) -> some Gesture {
      DragGesture(minimumDistance: 0)
        .onChanged { value in
          lastSurfaceSize = size
          guard !shouldSuppress else {
            cancelStroke()
            return
          }
          guard resolveDragIntent(value, in: size) else { return }
          guard session.capabilities.contains(.draw) else { return }
          guard !isPalmDriven(at: value.location) else {
            cancelStroke()
            return
          }
          let point = normalized(value.location, in: size)
          if selectedTool == .text {
            guard !isTextTapActive else { return }
            isTextTapActive = true
            beginText(at: point)
            return
          }
          guard strokeId == nil else {
            // Nothing else happens here. The samples come from the monitor's
            // coalesced channel (`appendCoalesced`), which sees every one of
            // them and the hardware attached to each.
            return
          }
          let id = "ios-\(UUID().uuidString)"
          strokeId = id
          session.begin(stroke: id, tool: selectedTool, style: style)
          session.append([point])
        }
        .onEnded { value in
          defer { dragIntent = .none }
          if selectedTool == .text {
            isTextTapActive = false
            return
          }
          guard !shouldSuppress, dragIntent == .drawing || dragIntent == .none else {
            cancelStroke()
            return
          }
          guard let id = strokeId else { return }
          strokeId = nil
          Task { try? await session.end(stroke: id) }
        }
    }

    /// The gesture location, enriched with the hardware channels the monitor
    /// saw for the touch it belongs to.
    ///
    /// `DragGesture` hands over a `CGPoint` and no `UITouch`, so force, azimuth
    /// and altitude have to be matched back by position — which is what
    /// ``RemoteDrawTouchSampleMatcher`` is for. A sender that skips this reports
    /// no pressure and no tilt, and draws a visibly different mark from every
    /// other client on the same board.
    private func normalized(_ location: CGPoint, in size: CGSize) -> RemoteDrawNormalizedPoint {
      let point = RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: location, in: size)
      let sample = RemoteDrawTouchSampleMatcher.nearestSample(to: location, in: touches.samples)
      return RemoteDrawNormalizedPoint(
        x: RemoteDrawSurfaceGeometry.clamp01(Double(point.x)),
        y: RemoteDrawSurfaceGeometry.clamp01(Double(point.y)),
        // Milliseconds since process start — never an epoch stamp. See
        // `RemoteDrawInkClock`.
        t: RemoteDrawInkClock.milliseconds,
        pressure: sample?.pressure,
        tiltX: sample?.tiltX,
        tiltY: sample?.tiltY
      )
    }

    private func isPalmDriven(at location: CGPoint) -> Bool {
      guard let sample = RemoteDrawTouchSampleMatcher.nearestSample(to: location, in: touches.samples)
      else { return false }
      return sample.isPalm
    }

    /// Every sample UIKit saw for the touch that is already drawing.
    ///
    /// Gated on there *being* a stroke: this channel fires for any single touch
    /// on the surface, including the moment before the drag gesture has decided
    /// what the touch means.
    private func appendCoalesced(_ samples: [RemoteDrawTouchSample], in size: CGSize) {
      guard let id = strokeId, session.live?.id == id else { return }
      guard dragIntent == .drawing || dragIntent == .none else { return }
      guard !shouldSuppress else { return }
      // A point is one sample by definition; a text tap places a pin, not ink.
      guard selectedTool != .point, selectedTool != .text else { return }
      guard RemoteDrawDrawingSurfaceGeometry.isUsable(size) else { return }
      let points = samples.filter { !$0.isPalm }.map { normalized($0, in: size) }
      guard !points.isEmpty else { return }
      session.append(points)
    }

    /// A monitor sample as a protocol point.
    ///
    /// Unlike ``normalized(_:in:)`` there is nothing to match back: the sample
    /// *is* the `UITouch`, so its force and attitude arrive with it rather than
    /// being paired to a drag location by proximity.
    private func normalized(_ sample: RemoteDrawTouchSample, in size: CGSize)
      -> RemoteDrawNormalizedPoint
    {
      let point = RemoteDrawDrawingSurfaceGeometry.normalizedPoint(for: sample.location, in: size)
      return RemoteDrawNormalizedPoint(
        x: RemoteDrawSurfaceGeometry.clamp01(Double(point.x)),
        y: RemoteDrawSurfaceGeometry.clamp01(Double(point.y)),
        t: RemoteDrawInkClock.milliseconds,
        pressure: sample.pressure,
        tiltX: sample.tiltX,
        tiltY: sample.tiltY
      )
    }

    private var shouldSuppress: Bool {
      touches.hasPalmContact || Date() < suppressUntil || dragIntent == .suppressing
    }

    private func suppress() {
      suppressUntil = Date().addingTimeInterval(suppressionDuration)
    }

    private func cancelStroke() {
      guard strokeId != nil else { return }
      strokeId = nil
      Task { await session.cancelStroke() }
    }

    private func resolveDragIntent(_ value: DragGesture.Value, in size: CGSize) -> Bool {
      switch dragIntent {
      case .drawing:
        return true
      case .suppressing:
        return false
      case .cornerControls:
        if RemoteDrawCornerSwipe.shouldOpenControls(
          translation: value.translation,
          requiredTravel: cornerControlsTravel,
          maxHorizontalDrift: cornerControlsMaxHorizontalDrift,
          hasBroadEdgeContact: touches.hasBroadEdgeContact,
          // Broad edge contact is a **thumb**, and a thumb rooted in the corner
          // is the gesture this affordance is for. It travels a short way, so it
          // needs *less* distance to count, not more. This shipped at 1.6 — 48pt
          // of thumb travel — which asked for a stretch most thumbs cannot make
          // and quietly turned the corner swipe into a stroke. 0.72 is the
          // first-party board's tuned value; the two now agree.
          broadContactTravelFactor: 0.72
        ) {
          openControlsFromGesture()
          return false
        }
        if RemoteDrawCornerSwipe.shouldResolveAsDrawing(
          translation: value.translation,
          resolveDistance: cornerControlsResolveDistance,
          maxHorizontalDrift: cornerControlsMaxHorizontalDrift
        ) {
          dragIntent = .drawing
          return true
        }
        return false
      case .none:
        if RemoteDrawCornerSwipe.isBottomCornerStart(
          value.startLocation, in: size, cornerSize: cornerControlsSize)
        {
          dragIntent = .cornerControls
          return false
        }
        dragIntent = .drawing
        return true
      }
    }

    // MARK: Chrome

    private var controlsOverlay: some View {
      VStack(spacing: 12) {
        Spacer(minLength: 0)
        if session.shapeSuggestion != nil {
          RemoteDrawShapeSnapPill(onTap: applyShapeSuggestion)
            .transition(.scale(scale: 0.94).combined(with: .opacity))
            // Four seconds, the same as the first-party board. An offer about a
            // stroke made a minute ago is an offer about the wrong stroke, and
            // the pill sits where a thumb rests.
            .task(id: session.shapeSuggestion?.id) {
              let id = session.shapeSuggestion?.id
              try? await Task.sleep(nanoseconds: 4_000_000_000)
              guard !Task.isCancelled, session.shapeSuggestion?.id == id else { return }
              session.dismissShapeSuggestion()
            }
        }
        HStack {
          if handedness.resolvedSide == .right { Spacer(minLength: 0) }
          RemoteDrawControlCluster(
            side: handedness.resolvedSide,
            isHidden: session.live != nil && textEntry == nil,
            showsUndo: session.capabilities.contains(.undo),
            // While one is in flight. A second tap before the first answers
            // undoes two strokes for one gesture.
            isUndoDisabled: isUndoing,
            toolSystemImage: styleKind.systemImage,
            textComposer: textComposer,
            onUndo: { Task { await undo() } },
            onOpenControls: { isControlsPresented = true }
          )
          if handedness.resolvedSide == .left { Spacer(minLength: 0) }
        }
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 18)
      .animation(.easeOut(duration: 0.18), value: session.shapeSuggestion)
    }

    private var radialItems: [RemoteDrawRadialMenuItem] {
      var items = session.capabilities.grantedTools.map { tool in
        RemoteDrawRadialMenuItem(
          id: tool.rawValue,
          systemImage: tool.systemImage,
          title: tool.title,
          isSelected: tool == selectedTool,
          action: { selectedTool = tool }
        )
      }
      if session.capabilities.contains(.undo) {
        items.append(
          RemoteDrawRadialMenuItem(
            id: "undo", systemImage: "arrow.uturn.backward", title: strings.undo,
            action: { Task { await undo() } }))
      }
      // Deliberately no destructive item: `clear` is one release of a finger
      // away from every other item on the fan, and it cannot be undone into
      // existence again.
      return items
    }

    private func undoFromGesture() {
      suppress()
      dragIntent = .suppressing
      cancelStroke()
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      Task { await undo() }
    }

    private func undo() async {
      guard !isUndoing else { return }
      isUndoing = true
      defer { isUndoing = false }
      _ = try? await session.undo()
    }

    /// Accepting the board's offer is a decision, so it gets the same light
    /// impact the first-party board gives it — a straightened shape that
    /// appears with no confirmation reads as a glitch.
    private func applyShapeSuggestion() {
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      Task { try? await session.applyShapeSuggestion() }
    }

    private func openControlsFromGesture() {
      suppress()
      dragIntent = .suppressing
      cancelStroke()
      UIImpactFeedbackGenerator(style: .light).impactOccurred()
      isControlsPresented = true
    }

    private func normalizeSelectedTool() {
      let tools = session.capabilities.grantedTools
      guard !tools.isEmpty else { return }
      if !tools.contains(selectedTool) {
        selectedTool = tools.first ?? .auto
      }
    }

    // MARK: Ground

    /// Whatever goes behind the ink. See the precedence note on
    /// ``RemoteDrawSurface``.
    @ViewBuilder
    private func groundLayer(in size: CGSize) -> some View {
      if let background {
        background(groundContext(in: size))
          .frame(width: size.width, height: size.height)
          .clipped()
      } else if let bounds = mapBounds {
        #if canImport(MapKit)
          RemoteDrawMapBoardGround(
            bounds: bounds,
            projection: session.session?.phoneProjection,
            onViewportChange: adoptViewport
          )
          .frame(width: size.width, height: size.height)
        #else
          RemoteDrawSurface.mapFallbackTone
        #endif
      } else if isMapBoard {
        // A map board that declared no `coordinateSpace.bounds` has no
        // geography anyone can name — the web falls back to Manhattan, which is
        // worse than admitting it. Draw the tone a map would have had rather
        // than the white the transparent ground leaves.
        RemoteDrawSurface.mapFallbackTone
      }
    }

    /// The tone under ink when a map board has no fence to draw.
    static let mapFallbackTone = Color(red: 0.86, green: 0.91, blue: 0.87)

    private func groundContext(in size: CGSize) -> RemoteDrawGroundContext {
      RemoteDrawGroundContext(
        session: session.session,
        mapBounds: mapBounds,
        phoneProjection: session.session?.phoneProjection,
        size: size,
        reportViewport: adoptViewport
      )
    }

    private var isMapBoard: Bool { session.session?.target?.kind == "map" }

    /// The board's geographic fence, on a map board that declared one.
    private var mapBounds: RemoteDrawMapBounds? {
      guard isMapBoard else { return nil }
      guard let bounds = RemoteDrawMapBounds(target: session.session?.target),
        !bounds.isDegenerate
      else { return nil }
      return bounds
    }

    /// Adopt what the ground says it is showing, and re-project through it.
    ///
    /// Re-installed rather than read live, because the SDK calls the space from
    /// a `@Sendable` context and a closure that reached back into this view
    /// would be reading a copy SwiftUI has since thrown away.
    private func adoptViewport(_ viewport: RemoteDrawBoardViewport) {
      guard !hasBoardViewport || !boardViewport.isClose(to: viewport) else { return }
      boardViewport = viewport
      hasBoardViewport = true
      installStrokeSpace()
    }

    /// Points leave this surface in board space **only** when something behind
    /// the ink has claimed a rectangle of it. Every other board keeps the
    /// Stage 1 behaviour, untouched.
    private func installStrokeSpace() {
      guard hasBoardViewport || mapBounds != nil else { return }
      let viewport = boardViewport
      session.strokeSpace = { .map(viewport: viewport) }
    }

    /// Field furniture: the host's choice, else the board's own preset, else
    /// nothing.
    private var fieldGuide: RemoteDrawFieldGuide {
      if let declared = appearance.fieldGuide { return declared }
      // The geography is the field on a map board; furniture over it is clutter.
      guard !isMapBoard else { return .none }
      switch session.session?.markupPreset {
      case "approval": return .approvalBox
      case "pointer": return .pointerCrosshair
      default: return .none
      }
    }

    // MARK: Boards this SDK cannot draw

    /// Set when the board asked for something this package has no renderer for.
    ///
    /// Today that is exactly one thing: a session that wants the receiver's
    /// pixels streamed under the ink. This SDK has no WebRTC, no video decoder
    /// and no `WKWebView`, by the same decision that keeps its dependency count
    /// at zero — so it says so, loudly, instead of painting an empty pad and
    /// letting the customer guess.
    private var unsupportedSurface: RemoteDrawUnsupportedSurface? {
      guard session.session?.requestsStreaming == true else { return nil }
      return .streaming(senderToken: session.senderToken)
    }

    // MARK: Failures

    /// The last thing that went wrong, shown rather than swallowed.
    ///
    /// ``RemoteDrawSenderSession/lastError`` was published from the first
    /// release and read by nothing: every control in this surface routes its
    /// failure into it and then discards the throw, so a failed undo, commit or
    /// submit was completely invisible in the built-in UI.
    @ViewBuilder
    private var errorBanner: some View {
      if let error = visibleError {
        VStack {
          Text(error.errorDescription ?? "Something went wrong.")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
              Capsule().fill(Color(red: 0.55, green: 0.16, blue: 0.13).opacity(0.94)))
            .padding(.top, 14)
          Spacer(minLength: 0)
        }
        .allowsHitTesting(false)
        .transition(.move(edge: .top).combined(with: .opacity))
        // Four seconds and gone. `lastError` is cleared by the next *successful*
        // call, which on a board nobody is drawing on may be never — a red bar
        // that outlives the failure it describes is chrome, not information.
        .task(id: error) {
          try? await Task.sleep(nanoseconds: 4_000_000_000)
          guard !Task.isCancelled else { return }
          visibleError = nil
        }
      }
    }

    // MARK: Text

    /// The board's own ceiling for a caption. A pin is a label, not a document,
    /// and 280 is what the first-party board enforces.
    private static let maximumTextLength = 280
    /// One text draft per draft frame, not one per keystroke.
    ///
    /// Placing a caption has no stroke buffer behind it, so nothing else paces
    /// it: every character typed was its own request, spending the sender's
    /// rate-limit budget on frames nobody can read.
    private static let textDraftInterval = RemoteDrawProtocolLimits.draftSendInterval

    private var textComposer: RemoteDrawTextComposerConfiguration? {
      guard textEntry != nil else { return nil }
      return RemoteDrawTextComposerConfiguration(
        text: Binding(
          get: { textEntry?.text ?? "" },
          set: { next in
            let clamped = String(next.prefix(RemoteDrawSurface.maximumTextLength))
            textEntry?.text = clamped
            guard let entry = textEntry else { return }
            let now = Date()
            guard now.timeIntervalSince(lastTextDraftAt) >= RemoteDrawSurface.textDraftInterval
            else { return }
            lastTextDraftAt = now
            Task { await session.draftText(clamped, at: entry.surfacePoint) }
          }
        ),
        focus: $isTextFocused,
        isCommitDisabled: (textEntry?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
          .isEmpty,
        onCommit: commitText
      )
    }

    private func beginText(at point: RemoteDrawNormalizedPoint) {
      commitText()
      textEntry = TextEntry(surfacePoint: point, text: "")
    }

    private func commitText() {
      guard let entry = textEntry else { return }
      textEntry = nil
      isTextFocused = false
      lastTextDraftAt = .distantPast
      Task { try? await session.commitText(entry.text, at: entry.surfacePoint, style: style) }
    }

    @ViewBuilder
    private func textPin(in size: CGSize) -> some View {
      if let entry = textEntry {
        let point = RemoteDrawDrawingSurfaceGeometry.surfacePoint(
          for: CGPoint(x: entry.surfacePoint.x, y: entry.surfacePoint.y), in: size)
        RemoteDrawTextPlacementPin()
          .position(x: point.x, y: max(24, point.y - 24))
          .allowsHitTesting(false)
      }
    }
  }
#endif
