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
  /// ## What it does not render
  ///
  /// - **2.5D materials.** Strokes whose style has `textureMode:
  ///   "experimental-3d"` keep their material metadata but are drawn flat, and
  ///   this surface cannot author materials. While settled ink carries one, a
  ///   notice says so and points at the board.
  /// - **Streamed boards.** A session that asks for the receiver's pixels gets
  ///   an explicit unsupported screen, not an empty pad.
  ///
  /// When the board parks its drawing region (`annotationInput.paused`) the
  /// surface shows a "Paused by board" pill and starts no stroke or note. Any
  /// region change ends the stroke or note in progress; nothing is restored on
  /// resume.
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

    @AppStorage(RemoteDrawPreferences.holdControlsKey) private var holdControlsEnabled = true
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOverEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedTool: RemoteDrawTool = .auto
    @State private var strokeId: RemoteDrawStrokeID?
    @State private var predicted: [CGPoint] = []
    @State private var touches = RemoteDrawTouchSnapshot()
    /// The shape-snap chip's measured size, for placing it by its centre.
    @State private var shapeSnapChipSize: CGSize = .zero
    @State private var dragIntent: DragIntent = .none
    @State private var suppressUntil = Date.distantPast
    @State private var isControlsPresented = false
    @State private var summon: RemoteDrawPuckSummon?
    @State private var holdGate = RemoteDrawHoldGate()
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
    @State private var installedMapStrokeSpace = false
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
        presentationContainer {
          GeometryReader { proxy in
            let size = proxy.size
            ZStack {
              groundLayer(in: size)

              RemoteDrawBoardCanvas(
                ground: session.session?.target?.staticBackground == nil ? ground : .transparent,
                surface: surfaceKind,
                guide: fieldGuide,
                sections: boardSections.map { $0.withContentPixelScale(contentPixelScale(in: size),
                  referenceExtent: 1000 * max(session.session?.target?.coordinateSpace?.aspectRatio ?? size.width / max(size.height, 1), 1)) },
                appearance: appearance,
                overlay: shapeSnapOutlineOverlay
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
                onTouchSequenceBegan: { _ in
                  if holdGate.hasBegun { cancelStroke() }
                  // A cancelled SwiftUI drag need not deliver onEnded. Only
                  // a new physical touch may release that suppression latch.
                  if dragIntent == .suppressing { dragIntent = .none }
                },
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
                onLongPressBegan: summonPuck,
                onLongPressMoved: { summon?.location = $0 },
                onLongPressEnded: { location in
                  summon?.location = location
                  summon?.phase = .ended
                },
                onLongPressCancelled: { summon?.phase = .cancelled },
                isLongPressEnabled: holdControlsEnabled && !isControlsPresented && textEntry == nil,
                longPressCancelsTouches: false,
                // The controls sheet owns every touch while it is up.
                isActive: !isControlsPresented
              )
              .frame(width: size.width, height: size.height)
              .allowsHitTesting(false)

              RemoteDrawPuck(menu: puckMenu, summon: $summon,
                safeAreaInsets: proxy.safeAreaInsets,
                pendingHold: holdGate.isPending ? holdGate.contactOrigin : nil,
                onCommit: { commit in commit.items.forEach(performPuckItem) },
                onUnavailable: openControlsFromGesture)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

              textPin(in: size)

              shapeSnapChip(in: size)

              RemoteDrawLiveInkGlow(isActive: session.live != nil)
                .frame(width: size.width, height: size.height)
            }
            .onAppear {
              lastSurfaceSize = size
              ground.prepare(toothExtent: max(size.width, size.height))
              installStrokeSpace()
            }
            .onChange(of: size) { _, next in
              // A held finger must not append points normalized against a new
              // fitted rectangle to the stroke begun in the previous rectangle.
              if strokeId != nil || dragIntent != .none || isTextTapActive {
                dragIntent = .suppressing
                isTextTapActive = false
                cancelStroke()
              }
              predicted = []
              summon = nil
              lastSurfaceSize = next
            }
            .onChange(of: session.session?.geometryRevision) { _, _ in
              // The presentation may reposition a same-sized fitted canvas.
              // Keep the held touch suppressed until it lifts.
              if strokeId != nil || dragIntent != .none || isTextTapActive {
                dragIntent = .suppressing
                isTextTapActive = false
                cancelStroke()
              }
              predicted = []
              summon = nil
            }
            .onChange(of: styleKindRaw) { _, _ in warmTooth(max(size.width, size.height)) }
          }
        }
        .ignoresSafeArea()

        controlsOverlay
        topNotices

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
        // Detents are the sheet's own: it measures its content and asks for
        // exactly that height.
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
        cancelStroke()
        UIApplication.shared.isIdleTimerDisabled = false
        Task { await session.markInactive() }
      }
      .onChange(of: session.capabilities) { _, _ in normalizeSelectedTool() }
      // A host that mounts this view before it has joined gets the board's
      // geography as soon as the board describes itself, rather than never.
      .onChange(of: session.session) { _, _ in installStrokeSpace() }
      .onChange(of: session.session?.annotationInput) { old, next in
        handleAnnotationInputChange(from: old, to: next)
      }
      .onChange(of: selectedTool) { _, tool in
        if tool != .text { commitText() }
      }
      .onChange(of: session.phase) { _, phase in
        // An ended session refuses the note; a composer left open would only
        // accept typing that can never land.
        if case .ended = phase { discardTextEntry() }
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

    /// Fit the entire canonical scene, including its touch surface, inside the
    /// receiver's presentation bounds. Letterboxing belongs outside that scene,
    /// so ink, backgrounds and inverse touch coordinates share one rectangle.
    @ViewBuilder
    private func presentationContainer<Content: View>(@ViewBuilder content: () -> Content) -> some View {
      if let snapshot = session.session, snapshot.usesContainedSurfacePresentation,
        let canonical = snapshot.target?.coordinateSpace?.aspectRatio,
        let presentation = snapshot.surfacePresentation?.aspectRatio {
        ZStack {
          Color(uiColor: .secondarySystemBackground)
          content().aspectRatio(CGFloat(canonical), contentMode: .fit)
        }
        .aspectRatio(CGFloat(presentation), contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        content()
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
    private var displayStrokeSpace: RemoteDrawStrokeSpace {
      if let custom = session.strokeSpace { return custom() }
      guard session.session?.target?.staticBackground != nil,
        session.session?.target?.mapsInputToSurface != true,
        let projection = session.session?.phoneProjection else { return .surface }
      return RemoteDrawStrokeSpace(phoneProjection: projection, isBoardSpace: true,
        unproject: { RemoteDrawStaticBackground.phonePoint($0, projection: projection) })
    }

    private var marks: [RemoteDrawBoardMark] {
      let space = displayStrokeSpace
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
          guard session.capabilities.grantedTools.contains(selectedTool) else { return }
          if let descriptor = session.session?.target?.staticBackground {
            guard RemoteDrawStaticBackground.contains(normalized(value.startLocation, in: size),
              corners: descriptor.region.corners.compactMap(displayStrokeSpace.unproject)) else { return }
          }
          guard !isPalmDriven(at: value.location) else {
            cancelStroke()
            return
          }
          let point = normalized(value.location, in: size)
          if holdGate.hasBegun {
            applyHoldDecision(holdGate.move(to: value.location))
            return
          }
          // Parked by the board: the touch never reaches the gate, so nothing
          // is previewed or sent. A hold still summons the dial (an idle gate
          // summons), and the corner swipe resolved above.
          guard !isInputPaused else { return }
          let sample = RemoteDrawTouchSampleMatcher.nearestSample(to: value.location, in: touches.samples)
          applyHoldDecision(holdGate.begin(
            RemoteDrawHoldSample(location: value.location, point: point),
            mode: sample?.isPencil == true || !holdControlsEnabled || voiceOverEnabled || dynamicTypeSize.isAccessibilitySize
              ? .immediate : .deferUntilMovement))
        }
        .onEnded { value in
          defer { dragIntent = .none; holdGate.cancel() }
          if selectedTool == .text {
            if !shouldSuppress, summon == nil, holdGate.hasBegun {
              beginText(at: normalized(value.startLocation, in: size))
            }
            isTextTapActive = false
            return
          }
          guard !shouldSuppress, dragIntent == .drawing || dragIntent == .none else {
            cancelStroke()
            return
          }
          applyHoldDecision(holdGate.end())
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
      guard holdGate.hasBegun, !isInputPaused else { return }
      guard dragIntent == .drawing || dragIntent == .none else { return }
      guard !shouldSuppress else { return }
      // A point is one sample by definition; a text tap places a pin, not ink.
      if selectedTool == .point {
        if let last = samples.last { applyHoldDecision(holdGate.move(to: last.location)) }
        return
      }
      guard selectedTool != .text else { return }
      guard RemoteDrawDrawingSurfaceGeometry.isUsable(size) else { return }
      let points = samples.filter { !$0.isPalm }.map { normalized($0, in: size) }
      guard !points.isEmpty else { return }
      if holdGate.isPending {
        applyHoldDecision(holdGate.append(samples.filter { !$0.isPalm }.map {
          RemoteDrawHoldSample(location: $0.location, point: normalized($0, in: size))
        }))
      } else if let id = strokeId, session.live?.id == id {
        session.append(points)
      }
    }

    private func applyHoldDecision(_ decision: RemoteDrawHoldGate.Decision) {
      switch decision {
      case .beginDrawing(let points), .deposit(let points):
        guard selectedTool != .text, !points.isEmpty, !isInputPaused else { return }
        if strokeId == nil {
          let id = "ios-\(UUID().uuidString)"
          strokeId = id
          session.begin(stroke: id, tool: selectedTool, style: style)
        }
        session.append(selectedTool == .point ? Array(points.prefix(1)) : points)
      case .buffer, .summon, .ignore: break
      }
    }

    private func summonPuck(_ location: CGPoint) {
      guard !isControlsPresented, !shouldSuppress,
        holdGate.holdRecognized() == .summon, puckMenu.isPresentable else { return }
      if voiceOverEnabled || dynamicTypeSize.isAccessibilitySize { openControlsFromGesture(); return }
      let anchor = holdGate.contactOrigin ?? location
      cancelStroke()
      dragIntent = .suppressing
      summon = RemoteDrawPuckSummon(anchor: anchor, location: location)
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
      holdGate.cancel()
      guard let id = strokeId else { return }
      strokeId = nil
      Task { await session.cancelStroke(stroke: id) }
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
            onOpenControls: openControlsFromGesture
          )
          if handedness.resolvedSide == .left { Spacer(minLength: 0) }
        }
      }
      .padding(.horizontal, 18)
      .padding(.bottom, 18)
      .animation(.easeOut(duration: 0.18), value: session.shapeSuggestion)
    }

    private var puckMenu: RemoteDrawPuckMenu {
      RemoteDrawSurfacePuck.menu(kind: styleKind, color: colorRaw,
        thickness: thickness, tool: selectedTool, tools: session.capabilities.grantedTools)
    }

    private func performPuckItem(_ item: RemoteDrawPuckItem) {
      let parts = item.id.split(separator: ".", maxSplits: 1).map(String.init)
      guard parts.count == 2 else { return }
      switch parts[0] {
      case "tip":
        if let kind = DrawingStyleKind(rawValue: parts[1]) { styleKindRaw = kind.rawValue }
        else { openControlsFromGesture() }
      case "color":
        if parts[1].hasPrefix("#") { colorRaw = parts[1] }
        else { openControlsFromGesture() }
      case "size":
        if let size = Double(parts[1]) { thickness = size }
      case "shape":
        if let tool = RemoteDrawTool(rawValue: parts[1]), session.capabilities.grantedTools.contains(tool) {
          selectedTool = tool
        } else { openControlsFromGesture() }
      default: break
      }
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
      } else if let descriptor = session.session?.target?.staticBackground {
        RemoteDrawStaticBackgroundView(descriptor: descriptor,
          corners: descriptor.region.corners.compactMap(displayStrokeSpace.unproject),
          ground: session.session?.target?.ground ?? .whiteboard)
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
      guard isMapBoard, session.session?.target?.staticBackground == nil else { return nil }
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
      guard session.session?.target?.staticBackground == nil || background != nil else {
        if installedMapStrokeSpace {
          session.strokeSpace = nil
          installedMapStrokeSpace = false
          hasBoardViewport = false
        }
        return
      }
      guard hasBoardViewport || mapBounds != nil else { return }
      let viewport = boardViewport
      session.strokeSpace = { .map(viewport: viewport) }
      installedMapStrokeSpace = true
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

    // MARK: Parked input

    private var isInputPaused: Bool {
      RemoteDrawSurfaceNotices.isInputPaused(session.session)
    }

    /// Any change of drawing region — pause, move or resume — ends the input
    /// in progress. The session already dropped its live stroke and text-draft
    /// revision, and the server deleted the drafts; this is the view's half.
    ///
    /// A finger still down stays suppressed until it lifts: the latch releases
    /// only on the next physical touch (`onTouchSequenceBegan`), exactly as for
    /// a geometry change. An open dial is left alone — it changes the tool,
    /// not the board. Resume restores nothing; the next touch draws against
    /// the new revision.
    private func handleAnnotationInputChange(
      from old: RemoteDrawAnnotationInput?, to next: RemoteDrawAnnotationInput?
    ) {
      if strokeId != nil || holdGate.hasBegun || dragIntent != .none || isTextTapActive {
        dragIntent = .suppressing
        isTextTapActive = false
        cancelStroke()
      }
      predicted = []
      discardTextEntry()
      let wasPaused = old?.paused == true
      let isPaused = next?.paused == true
      if voiceOverEnabled, wasPaused != isPaused {
        UIAccessibility.post(notification: .announcement,
          argument: isPaused ? Self.pausedAnnouncement : Self.resumedAnnouncement)
      }
    }

    // The same copy as the first-party board. `RemoteDrawStrings` has no keys
    // for these yet, so they are not host-overridable.
    private static let pausedNotice = "Paused by board"
    private static let pausedAnnouncement = "Drawing paused by the board"
    private static let resumedAnnouncement = "Drawing resumed"
    private static let flatMaterialNotice =
      "2.5D materials appear flat on this phone. View their full appearance on the board."

    // MARK: Notices

    /// Status that sits over the top of the board: the last failure, then the
    /// parked-input pill, then the flat-preview disclosure. Never hit-testable;
    /// the board under it stays touchable.
    private var topNotices: some View {
      VStack(spacing: 6) {
        errorBanner
        if isInputPaused {
          Label(Self.pausedNotice, systemImage: "pause.fill")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(appearance.ink.opacity(0.72))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.10), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.pausedAnnouncement)
            .accessibilityIdentifier("remotedraw.annotationPausedNotice")
            .transition(.opacity)
        }
        if RemoteDrawSurfaceNotices.showsFlatMaterialPreview(session.strokes) {
          Text(Self.flatMaterialNotice)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(appearance.ink.opacity(0.72))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .accessibilityLabel(Self.flatMaterialNotice)
            .accessibilityIdentifier("remotedraw.materialPreviewNotice")
        }
        Spacer(minLength: 0)
      }
      .padding(.top, 14)
      .padding(.horizontal, 18)
      .allowsHitTesting(false)
      .animation(.easeOut(duration: 0.18), value: isInputPaused)
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
        Text(error.errorDescription ?? "Something went wrong.")
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 16)
          .padding(.vertical, 10)
          .background(
            Capsule().fill(Color(red: 0.55, green: 0.16, blue: 0.13).opacity(0.94)))
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
    /// rate-limit budget on frames nobody can read. The frame is the session's
    /// ``RemoteDrawSenderSession/effectiveDraftInterval`` — 32 ms unless the
    /// session negotiated an experimental tier.
    private var textDraftInterval: TimeInterval { session.effectiveDraftInterval }

    private var textComposer: RemoteDrawTextComposerConfiguration? {
      guard textEntry != nil else { return nil }
      // Read here, not in the setter: the composer is rebuilt whenever the
      // session publishes, including a change of tier.
      let interval = self.textDraftInterval
      return RemoteDrawTextComposerConfiguration(
        text: Binding(
          get: { textEntry?.text ?? "" },
          set: { next in
            let clamped = String(next.prefix(RemoteDrawSurface.maximumTextLength))
            textEntry?.text = clamped
            guard let entry = textEntry else { return }
            let now = Date()
            guard now.timeIntervalSince(lastTextDraftAt) >= interval
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
      guard !isInputPaused else { return }
      commitText()
      textEntry = TextEntry(surfacePoint: point, text: "")
    }

    /// Drops the composer without committing. Its placement and revision
    /// belonged to a region that is gone, and the server already deleted its
    /// draft, so there is nothing to clear.
    private func discardTextEntry() {
      guard textEntry != nil else { return }
      textEntry = nil
      isTextFocused = false
      lastTextDraftAt = .distantPast
    }

    private func commitText() {
      guard let entry = textEntry else { return }
      textEntry = nil
      isTextFocused = false
      lastTextDraftAt = .distantPast
      Task { try? await session.commitText(entry.text, at: entry.surfacePoint, style: style) }
    }

    // MARK: Shape snap

    /// The offer's lifetime. Longer than the old pill's four seconds because
    /// there is now something to look at: the ghost has to be read against the
    /// stroke before the choice is made. Still short — an offer about a stroke
    /// made a minute ago is an offer about the wrong stroke.
    private static let shapeSnapLifetime: UInt64 = 6_000_000_000

    /// The id the ghost is painted under; never a real stroke.
    private static let shapeSnapGhostId = "rd-shape-snap-ghost"

    /// The offered shape as the mark a snap would store, in surface space.
    /// `nil` when nothing of it lands on this screen.
    private var shapeSnapGhost: RemoteDrawBoardMark? {
      guard let offer = session.shapeSuggestion else { return nil }
      return RemoteDrawBoardMark(
        RemoteDrawStroke(
          id: Self.shapeSnapGhostId,
          type: offer.suggestion.replacementTool.rawValue,
          points: offer.suggestion.points,
          style: offer.style,
          isBoardSpace: offer.isBoardSpace
        ),
        space: displayStrokeSpace,
        // The committed weight, not the live one: the ghost is the stroke the
        // board would keep.
        lineWidth: 6
      )
    }

    /// The canvas passes. One, normally. While an offer stands, three: the rest
    /// of the board, the hand-drawn stroke stepped back, and the ghost over it —
    /// so the pair says "this becomes that" without a word of copy.
    private var boardSections: [RemoteDrawBoardSection] {
      let all = marks
      guard let offer = session.shapeSuggestion, let ghost = shapeSnapGhost else {
        return [RemoteDrawBoardSection(marks: all)]
      }
      return [
        RemoteDrawBoardSection(marks: all.filter { $0.id != offer.strokeId }),
        RemoteDrawBoardSection(marks: all.filter { $0.id == offer.strokeId }, opacity: 0.28),
        RemoteDrawBoardSection(marks: [ghost], opacity: 0.78),
      ]
    }

    private func contentPixelScale(in size: CGSize) -> Double {
      let space = displayStrokeSpace
      let height = 1000.0
      let width = height * (session.session?.target?.coordinateSpace?.aspectRatio ?? size.width / max(size.height, 1))
      guard let origin = space.unproject(.init(x: 0, y: 0)),
        let x = space.unproject(.init(x: 1, y: 0)),
        let y = space.unproject(.init(x: 0, y: 1)) else { return 1 }
      let scale = min(hypot((x.x - origin.x) * size.width, (x.y - origin.y) * size.height) / width,
        hypot((y.x - origin.x) * size.width, (y.y - origin.y) * size.height) / height)
      return scale.isFinite && scale > 0 ? scale : 1
    }

    /// The fine dashed trace around the ghost, so it reads as a proposal and
    /// not as a second stroke. Drawn above the ink, below the chrome.
    private var shapeSnapOutlineOverlay: ((inout GraphicsContext, CGSize) -> Void)? {
      guard let ghost = shapeSnapGhost else { return nil }
      let accent = appearance.accent
      return { context, size in
        let path = RemoteDrawShapeSnapGeometry.outlinePath(type: ghost.type, points: ghost.points, in: size)
        context.stroke(
          path,
          with: .color(accent.opacity(0.85)),
          style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [7, 6])
        )
      }
    }

    /// Where the floating control cluster is, so the chip keeps clear of it.
    private func controlClusterReserve(in size: CGSize) -> CGRect {
      // Up to three 56pt circles at 10pt spacing, floated 18pt off the edges,
      // plus a little air.
      let reserve = CGSize(width: 3 * 56 + 2 * 10 + 18 + 12, height: 56 + 18 + 12)
      let x = handedness.resolvedSide == .right ? size.width - reserve.width : 0
      return CGRect(x: x, y: size.height - reserve.height, width: reserve.width, height: reserve.height)
    }

    /// Accept or decline, right next to the ghost.
    ///
    /// Anchored to the shape rather than to the bottom edge so the control and
    /// the change it governs read as one thing, and placed by
    /// ``RemoteDrawShapeSnapGeometry/chipOrigin`` so it stays on screen and
    /// out of the thumb's corner. The offer expires on its own; drawing again
    /// dismisses it at once, as before.
    @ViewBuilder
    private func shapeSnapChip(in size: CGSize) -> some View {
      ZStack {
        if let offer = session.shapeSuggestion, let ghost = shapeSnapGhost {
          let anchor = RemoteDrawShapeSnapGeometry.anchorRect(
            type: ghost.type, points: ghost.points, in: size, inkWidth: 6)
          // Until the chip has reported its size, a typical one stands in; the
          // first layout pass corrects it before anyone can tap.
          let chipSize = shapeSnapChipSize == .zero ? CGSize(width: 150, height: 48) : shapeSnapChipSize
          let origin = RemoteDrawShapeSnapGeometry.chipOrigin(
            pad: size, anchor: anchor, chip: chipSize, avoid: controlClusterReserve(in: size))
          RemoteDrawShapeSnapPill(
            shapeName: strings.shapeName(for: ghost.type),
            onAccept: applyShapeSuggestion,
            onDismiss: session.dismissShapeSuggestion
          )
          .fixedSize()
          .background(
            GeometryReader { proxy in
              Color.clear.preference(key: ShapeSnapChipSizeKey.self, value: proxy.size)
            }
          )
          .onPreferenceChange(ShapeSnapChipSizeKey.self) { shapeSnapChipSize = $0 }
          .position(x: origin.x + chipSize.width / 2, y: origin.y + chipSize.height / 2)
          .transition(.scale(scale: 0.94).combined(with: .opacity))
          .task(id: offer.id) {
            try? await Task.sleep(nanoseconds: Self.shapeSnapLifetime)
            guard !Task.isCancelled, session.shapeSuggestion?.id == offer.id else { return }
            session.dismissShapeSuggestion()
          }
        }
      }
      .animation(.easeOut(duration: 0.18), value: session.shapeSuggestion)
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

/// What ``RemoteDrawSurface`` discloses over the ink, decided from session
/// state alone. Outside the UIKit guard so the rules run in headless tests.
enum RemoteDrawSurfaceNotices {
  /// The only texture mode that carries a 2.5D material on the wire.
  static let materialTextureMode = "experimental-3d"

  /// The board parked the drawing region. The surface starts nothing while
  /// this holds, and the session refuses anything that gets past it.
  static func isInputPaused(_ session: RemoteDrawSession?) -> Bool {
    session?.annotationInput?.paused == true
  }

  /// Whether settled ink carries a 2.5D material. This SDK has no material
  /// renderer, so such a stroke is drawn flat. Local echoes do not count: the
  /// surface cannot author materials, and the board's copy of a stroke is
  /// the one whose style is known.
  static func showsFlatMaterialPreview(_ strokes: [RemoteDrawStroke]) -> Bool {
    strokes.contains { !$0.isLocalEcho && $0.style?.textureMode == materialTextureMode }
  }
}
