// The embeddable drawing surface.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  /// RemoteDraw's drawing board, as a `View` you can put anywhere.
  ///
  /// Paper and its tooth, the ink pass with its group ceiling, capture with
  /// pressure and tilt and palm rejection, the one-handed control cluster, the
  /// long-press tool fan, the controls sheet, text placement, and the board's
  /// shape-snap offer. Everything the first-party app's board is, minus the two
  /// things §4 of the design keeps first-party: the MapKit ground and element
  /// selection.
  ///
  /// ```swift
  /// RemoteDrawSurface(session: session)
  /// ```
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
            RemoteDrawBoardCanvas(
              ground: ground,
              surface: surfaceKind,
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
          .onAppear { ground.prepare(toothExtent: max(size.width, size.height)) }
          .onChange(of: styleKindRaw) { _, _ in warmTooth(max(size.width, size.height)) }
        }
        .ignoresSafeArea()

        controlsOverlay
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
          if strokeId == nil {
            let id = "ios-\(UUID().uuidString)"
            strokeId = id
            session.begin(stroke: id, tool: selectedTool, style: style)
          }
          guard selectedTool != .point || session.live?.points.isEmpty != false else { return }
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
          broadContactTravelFactor: 1.6
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
          RemoteDrawShapeSnapPill { Task { try? await session.applyShapeSuggestion() } }
            .transition(.scale(scale: 0.94).combined(with: .opacity))
        }
        HStack {
          if handedness.resolvedSide == .right { Spacer(minLength: 0) }
          RemoteDrawControlCluster(
            side: handedness.resolvedSide,
            isHidden: session.live != nil && textEntry == nil,
            showsUndo: session.capabilities.contains(.undo),
            toolSystemImage: styleKind.systemImage,
            textComposer: textComposer,
            onUndo: { Task { try? await session.undo() } },
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
            action: { Task { try? await session.undo() } }))
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
      Task { try? await session.undo() }
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

    // MARK: Text

    private var textComposer: RemoteDrawTextComposerConfiguration? {
      guard textEntry != nil else { return nil }
      return RemoteDrawTextComposerConfiguration(
        text: Binding(
          get: { textEntry?.text ?? "" },
          set: { next in
            textEntry?.text = next
            guard let entry = textEntry else { return }
            Task { await session.draftText(next, at: entry.surfacePoint) }
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
