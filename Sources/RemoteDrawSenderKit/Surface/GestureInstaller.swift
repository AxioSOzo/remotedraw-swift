//
//  Installed on the *window*, not on the drawing surface.
//
//  Ported verbatim from `apps/ios/RemoteDraw/ErgonomicGestures.swift`, which is
//  where every one of the comments below was paid for. The only edits are the
//  `RemoteDraw` prefixes the public names need and the `#if canImport(UIKit)`
//  guard the package needs to keep compiling on macOS for `swift test`.
//
#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

public struct RemoteDrawTouchSnapshot: Equatable, Sendable {
  /// Active touches with classification; palms are kept (they matter for
  /// matching) but excluded from `activeTouchCount`.
  public var samples: [RemoteDrawTouchSample] = []
  public var hasBroadEdgeContact = false

  public init(samples: [RemoteDrawTouchSample] = [], hasBroadEdgeContact: Bool = false) {
    self.samples = samples
    self.hasBroadEdgeContact = hasBroadEdgeContact
  }

  /// Number of deliberate (non-palm) touches on the surface.
  public var activeTouchCount: Int {
    samples.lazy.filter { !$0.isPalm }.count
  }

  public var hasPalmContact: Bool {
    samples.contains { $0.isPalm }
  }
}

/// Installs non-consuming UIKit recognizers on the window so ergonomic
/// gestures (touch monitoring, two/three-finger taps) coexist with the
/// SwiftUI drawing gestures and with WKWebView content without stealing
/// touches from either.
public struct RemoteDrawGestureInstaller: UIViewRepresentable {
  public var onTouchChange: (RemoteDrawTouchSnapshot) -> Void
  public var onTwoFingerTap: () -> Void
  public var onThreeFingerTap: () -> Void
  /// Hardware-predicted locations for the drawing touch, in this view's space.
  /// The board renders ink one or two samples ahead of the finger with them;
  /// nothing else may. See `RemoteDrawTouchMonitorRecognizer`.
  public var onPredictedTouches: ([CGPoint]) -> Void = { _ in }
  /// Every sample the digitiser took for the drawing touch since the last
  /// event, oldest first, in this view's space. See
  /// `RemoteDrawTouchMonitorRecognizer.publishCoalesced`.
  public var onCoalescedSamples: ([RemoteDrawTouchSample]) -> Void = { _ in }
  public var isTwoFingerTapEnabled = true
  /// Long-press summon: a stationary one-finger hold (the gesture that used to
  /// trigger the system loupe over web content) opens the radial tool menu at
  /// the finger. Locations are in the bounds view's coordinate space.
  public var onLongPressBegan: ((CGPoint) -> Void)? = nil
  public var onLongPressMoved: ((CGPoint) -> Void)? = nil
  public var onLongPressEnded: ((CGPoint) -> Void)? = nil
  public var onLongPressCancelled: (() -> Void)? = nil
  public var isLongPressEnabled = true
  public var longPressCancelsTouches = true
  /// Suspends every recognizer at once. They live on the *window*, so without
  /// this they keep reporting touches that land on presented sheets: a
  /// two-finger scroll in a Form would fire undo, and — worse — the per-touch
  /// snapshots re-render the presenting view, tearing down the sheet's
  /// contents mid-interaction (which is what made menu pickers there need
  /// several taps before a choice registered).
  public var isActive = true

  public init(
    onTouchChange: @escaping (RemoteDrawTouchSnapshot) -> Void,
    onTwoFingerTap: @escaping () -> Void = {},
    onThreeFingerTap: @escaping () -> Void = {},
    onPredictedTouches: @escaping ([CGPoint]) -> Void = { _ in },
    onCoalescedSamples: @escaping ([RemoteDrawTouchSample]) -> Void = { _ in },
    isTwoFingerTapEnabled: Bool = true,
    onLongPressBegan: ((CGPoint) -> Void)? = nil,
    onLongPressMoved: ((CGPoint) -> Void)? = nil,
    onLongPressEnded: ((CGPoint) -> Void)? = nil,
    onLongPressCancelled: (() -> Void)? = nil,
    isLongPressEnabled: Bool = true,
    longPressCancelsTouches: Bool = true,
    isActive: Bool = true
  ) {
    self.onTouchChange = onTouchChange
    self.onTwoFingerTap = onTwoFingerTap
    self.onThreeFingerTap = onThreeFingerTap
    self.onPredictedTouches = onPredictedTouches
    self.onCoalescedSamples = onCoalescedSamples
    self.isTwoFingerTapEnabled = isTwoFingerTapEnabled
    self.onLongPressBegan = onLongPressBegan
    self.onLongPressMoved = onLongPressMoved
    self.onLongPressEnded = onLongPressEnded
    self.onLongPressCancelled = onLongPressCancelled
    self.isLongPressEnabled = isLongPressEnabled
    self.longPressCancelsTouches = longPressCancelsTouches
    self.isActive = isActive
  }

  public func makeCoordinator() -> Coordinator {
    Coordinator(
      onTouchChange: onTouchChange,
      onTwoFingerTap: onTwoFingerTap,
      onThreeFingerTap: onThreeFingerTap
    )
  }

  public func makeUIView(context: Context) -> RemoteDrawGestureHostView {
    let view = RemoteDrawGestureHostView()
    view.coordinator = context.coordinator
    context.coordinator.boundsView = view
    return view
  }

  public func updateUIView(_ uiView: RemoteDrawGestureHostView, context: Context) {
    context.coordinator.onTouchChange = onTouchChange
    context.coordinator.onTwoFingerTap = onTwoFingerTap
    context.coordinator.onThreeFingerTap = onThreeFingerTap
    context.coordinator.onPredictedTouches = onPredictedTouches
    context.coordinator.onCoalescedSamples = onCoalescedSamples
    context.coordinator.onLongPressBegan = onLongPressBegan
    context.coordinator.onLongPressMoved = onLongPressMoved
    context.coordinator.onLongPressEnded = onLongPressEnded
    context.coordinator.onLongPressCancelled = onLongPressCancelled
    context.coordinator.boundsView = uiView
    context.coordinator.attach(to: uiView.window, boundsView: uiView)
    context.coordinator.isTwoFingerTapEnabled = isTwoFingerTapEnabled
    context.coordinator.isLongPressEnabled = isLongPressEnabled
    context.coordinator.longPressCancelsTouches = longPressCancelsTouches
    context.coordinator.isActive = isActive
  }

  public static func dismantleUIView(_ uiView: RemoteDrawGestureHostView, coordinator: Coordinator) {
    coordinator.detach()
  }

  public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
    var onTouchChange: (RemoteDrawTouchSnapshot) -> Void
    var onTwoFingerTap: () -> Void
    var onThreeFingerTap: () -> Void
    var onPredictedTouches: ([CGPoint]) -> Void = { _ in }
    var onCoalescedSamples: ([RemoteDrawTouchSample]) -> Void = { _ in }
    weak var boundsView: UIView?

    var onLongPressBegan: ((CGPoint) -> Void)?
    var onLongPressMoved: ((CGPoint) -> Void)?
    var onLongPressEnded: ((CGPoint) -> Void)?
    var onLongPressCancelled: (() -> Void)?

    var isTwoFingerTapEnabled = true {
      didSet { applyEnabledStates() }
    }

    var isLongPressEnabled = true {
      didSet { applyEnabledStates() }
    }

    /// When false every recognizer stands down — see `isActive` on the
    /// installer for why that matters while a sheet is up.
    var isActive = true {
      didSet {
        guard isActive != oldValue else { return }
        applyEnabledStates()
        // Disabling a recognizer does not deliver a final touchesEnded, so
        // publish the empty snapshot ourselves or the board stays convinced a
        // finger is still down. Async: this runs inside a SwiftUI update.
        if !isActive {
          DispatchQueue.main.async { [weak self] in
            self?.onTouchChange(RemoteDrawTouchSnapshot())
            self?.onPredictedTouches([])
          }
        }
      }
    }

    var longPressCancelsTouches = true {
      didSet { longPress?.cancelsTouchesInView = longPressCancelsTouches }
    }

    private weak var attachedView: UIView?
    private var touchMonitor: RemoteDrawTouchMonitorRecognizer?
    private var twoFingerTap: UITapGestureRecognizer?
    private var threeFingerTap: UITapGestureRecognizer?
    private var longPress: UILongPressGestureRecognizer?

    init(
      onTouchChange: @escaping (RemoteDrawTouchSnapshot) -> Void,
      onTwoFingerTap: @escaping () -> Void,
      onThreeFingerTap: @escaping () -> Void
    ) {
      self.onTouchChange = onTouchChange
      self.onTwoFingerTap = onTwoFingerTap
      self.onThreeFingerTap = onThreeFingerTap
    }

    func attach(to view: UIView?, boundsView: UIView) {
      guard let view else {
        detach()
        return
      }
      self.boundsView = boundsView
      guard attachedView !== view else { return }

      detach()
      attachedView = view

      let monitor = RemoteDrawTouchMonitorRecognizer()
      monitor.boundsView = boundsView
      monitor.onSnapshot = { [weak self] snapshot in
        self?.onTouchChange(snapshot)
      }
      monitor.onPredictedTouches = { [weak self] locations in
        self?.onPredictedTouches(locations)
      }
      monitor.onCoalescedSamples = { [weak self] samples in
        self?.onCoalescedSamples(samples)
      }
      monitor.delegate = self
      monitor.cancelsTouchesInView = false
      monitor.delaysTouchesBegan = false
      monitor.delaysTouchesEnded = false
      view.addGestureRecognizer(monitor)
      touchMonitor = monitor

      let twoTap = UITapGestureRecognizer(target: self, action: #selector(handleTwoFingerTap(_:)))
      configureTapRecognizer(twoTap, touches: 2)
      view.addGestureRecognizer(twoTap)
      twoFingerTap = twoTap

      let threeTap = UITapGestureRecognizer(target: self, action: #selector(handleThreeFingerTap(_:)))
      configureTapRecognizer(threeTap, touches: 3)
      view.addGestureRecognizer(threeTap)
      threeFingerTap = threeTap

      // The summon must cancel touch delivery to the views below it when it
      // recognizes (so a WKWebView draft or a budding stroke dies cleanly),
      // unlike every other ergonomic recognizer here.
      let longPressRecognizer = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleLongPress(_:))
      )
      longPressRecognizer.minimumPressDuration = 0.5
      longPressRecognizer.allowableMovement = 10
      longPressRecognizer.numberOfTouchesRequired = 1
      longPressRecognizer.cancelsTouchesInView = longPressCancelsTouches
      longPressRecognizer.delaysTouchesBegan = false
      longPressRecognizer.delaysTouchesEnded = false
      longPressRecognizer.delegate = self
      view.addGestureRecognizer(longPressRecognizer)
      longPress = longPressRecognizer

      applyEnabledStates()
    }

    /// Single place that decides which recognizers are live: the per-gesture
    /// flags, gated by `isActive`.
    private func applyEnabledStates() {
      touchMonitor?.isEnabled = isActive
      twoFingerTap?.isEnabled = isActive && isTwoFingerTapEnabled
      threeFingerTap?.isEnabled = isActive
      longPress?.isEnabled = isActive && isLongPressEnabled
    }

    func detach() {
      if let touchMonitor, let view = touchMonitor.view {
        view.removeGestureRecognizer(touchMonitor)
      }
      if let twoFingerTap, let view = twoFingerTap.view {
        view.removeGestureRecognizer(twoFingerTap)
      }
      if let threeFingerTap, let view = threeFingerTap.view {
        view.removeGestureRecognizer(threeFingerTap)
      }
      if let longPress, let view = longPress.view {
        view.removeGestureRecognizer(longPress)
      }
      touchMonitor = nil
      twoFingerTap = nil
      threeFingerTap = nil
      longPress = nil
      attachedView = nil
      onTouchChange(RemoteDrawTouchSnapshot())
      onPredictedTouches([])
    }

    private func configureTapRecognizer(_ recognizer: UITapGestureRecognizer, touches: Int) {
      recognizer.numberOfTouchesRequired = touches
      recognizer.numberOfTapsRequired = 1
      recognizer.cancelsTouchesInView = false
      recognizer.delaysTouchesBegan = false
      recognizer.delaysTouchesEnded = false
      recognizer.delegate = self
    }

    @objc private func handleTwoFingerTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .recognized, recognizerIsInsideBounds(recognizer) else { return }
      onTwoFingerTap()
    }

    @objc private func handleThreeFingerTap(_ recognizer: UITapGestureRecognizer) {
      guard recognizer.state == .recognized, recognizerIsInsideBounds(recognizer) else { return }
      onThreeFingerTap()
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
      guard let boundsView else { return }
      let location = recognizer.location(in: boundsView)
      switch recognizer.state {
      case .began:
        onLongPressBegan?(location)
      case .changed:
        onLongPressMoved?(location)
      case .ended:
        onLongPressEnded?(location)
      case .cancelled, .failed:
        onLongPressCancelled?()
      default:
        break
      }
    }

    private func recognizerIsInsideBounds(_ recognizer: UIGestureRecognizer) -> Bool {
      guard let boundsView else { return true }
      return boundsView.bounds.contains(recognizer.location(in: boundsView))
    }

    fileprivate func touchIsInsideBounds(_ touch: UITouch) -> Bool {
      guard let boundsView else { return true }
      let location = touch.location(in: boundsView)
      return boundsView.bounds.insetBy(dx: -12, dy: -12).contains(location)
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard touchIsInsideBounds(touch) else { return false }
      if gestureRecognizer === longPress {
        // Pencil users rest the tip while thinking; never summon for pencil.
        guard touch.type != .pencil else { return false }
        // Palm/heel contact must not open menus either.
        guard !RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius) else { return false }
      }
      return true
    }

    public func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}

public final class RemoteDrawGestureHostView: UIView {
  weak var coordinator: RemoteDrawGestureInstaller.Coordinator?

  public override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  public required init?(coder: NSCoder) {
    super.init(coder: coder)
    backgroundColor = .clear
    isUserInteractionEnabled = false
  }

  public override func didMoveToWindow() {
    super.didMoveToWindow()
    coordinator?.attach(to: window, boundsView: self)
  }
}

final class RemoteDrawTouchMonitorRecognizer: UIGestureRecognizer {
  weak var boundsView: UIView?
  var onSnapshot: ((RemoteDrawTouchSnapshot) -> Void)?
  /// Where UIKit thinks the drawing finger is about to be, in `boundsView`
  /// space. Preview-only latency compensation; see
  /// `InkRenderer.previewPointsWithPrediction`.
  ///
  /// A channel of its own rather than a field on `RemoteDrawTouchSnapshot`, and
  /// that is deliberate: the snapshot is `Equatable` and drives the controls
  /// sheet, and pushing a value that changes on every `touchesMoved` through it
  /// is exactly the churn that made pickers in that sheet need several taps
  /// before a choice registered.
  var onPredictedTouches: (([CGPoint]) -> Void)?
  /// Every sample the digitiser took for the drawing touch since the last
  /// event, oldest first. See ``publishCoalesced(from:)``.
  var onCoalescedSamples: (([RemoteDrawTouchSample]) -> Void)?
  private var lastSnapshot = RemoteDrawTouchSnapshot()
  private var lastPredicted: [CGPoint] = []

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
    publishCoalesced(from: event)
    publishSnapshot(from: event)
    publishPredicted(from: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    // Before the snapshot, deliberately: the snapshot is what a host uses to
    // decide a touch is a palm or a pinch and stand the stroke down, so the
    // samples for the event have to be in the host's hands by the time it makes
    // that call rather than one event behind it.
    publishCoalesced(from: event)
    publishSnapshot(from: event)
    publishPredicted(from: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    // The lift carries samples too — the last few millimetres of a flick live
    // in this event and nowhere else.
    publishCoalesced(from: event)
    let snapshot = publishSnapshot(from: event)
    publishPredicted([])
    if snapshot.activeTouchCount == 0 {
      state = .failed
    }
  }

  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
    let snapshot = publishSnapshot(from: event)
    publishPredicted([])
    if snapshot.activeTouchCount == 0 {
      state = .failed
    }
  }

  override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
    false
  }

  override func reset() {
    publishSnapshot(RemoteDrawTouchSnapshot())
    publishPredicted([])
  }

  /// Everything the digitiser recorded for the drawing touch since the last
  /// event, oldest first.
  ///
  /// **This is the sample density, and it is not a detail.** UIKit delivers one
  /// `touchesMoved` per display refresh, but the digitiser samples several times
  /// faster than that — up to 240 Hz with a Pencil — and hands the intermediate
  /// samples over here and nowhere else. A host that reads only
  /// `touch.location(in:)` (or a SwiftUI `DragGesture`, which cannot see a
  /// `UITouch` at all) keeps one sample in four and shortens tight curves into
  /// corners at exactly the speed people write at. Rendered at 1:1 the two feeds
  /// differ across 7.7% of the pixels of a brisk cursive gesture, peaking at 166
  /// of 255 on a channel — see `CaptureDensityTests`.
  ///
  /// A channel of its own rather than a field on ``RemoteDrawTouchSnapshot`` for
  /// the same reason the predicted trail is: the snapshot is `Equatable` and
  /// drives presented UI, and pushing a value through it that changes on every
  /// event is what made pickers in the controls sheet need several taps.
  ///
  /// Same one-touch filter as the predicted trail — two fingers is a pinch and a
  /// pinch has no ink — with one difference: an *ending* touch still carries
  /// samples, and they are the last few millimetres of the mark.
  private func publishCoalesced(from event: UIEvent) {
    guard let touch = drawingTouch(in: event, includingEnding: true) else { return }
    guard let coalesced = event.coalescedTouches(for: touch), !coalesced.isEmpty else { return }
    onCoalescedSamples?(coalesced.map(sample(from:)))
  }

  /// The predicted trail for the one touch that could be drawing.
  ///
  /// One touch, because two fingers on the surface is a pinch and a pinch has
  /// no ink to run ahead of; and no palm, for the same reason the sampler
  /// rejects them. Anything else publishes an empty trail, which stops the
  /// preview extending rather than leaving it stuck on a stale guess.
  private func publishPredicted(from event: UIEvent) {
    guard let touch = drawingTouch(in: event, includingEnding: false) else {
      publishPredicted([])
      return
    }
    let predicted = event.predictedTouches(for: touch) ?? []
    publishPredicted(predicted.map { $0.location(in: boundsView) })
  }

  /// The single touch that could be making a mark, or `nil`.
  private func drawingTouch(in event: UIEvent, includingEnding: Bool) -> UITouch? {
    guard let allTouches = event.allTouches else { return nil }
    let drawing = allTouches.filter { touch in
      let isFinishing = touch.phase == .ended || touch.phase == .cancelled
      return (includingEnding || !isFinishing)
        && touch.phase != .cancelled
        && touchIsInsideBounds(touch)
        && !(touch.type == .direct && RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius))
    }
    guard drawing.count == 1 else { return nil }
    return drawing.first
  }

  private func publishPredicted(_ locations: [CGPoint]) {
    guard locations != lastPredicted else { return }
    lastPredicted = locations
    onPredictedTouches?(locations)
  }

  @discardableResult
  private func publishSnapshot(from event: UIEvent) -> RemoteDrawTouchSnapshot {
    guard let allTouches = event.allTouches else {
      let snapshot = RemoteDrawTouchSnapshot()
      publishSnapshot(snapshot)
      return snapshot
    }

    let activeTouches: [UITouch] = allTouches.filter { touch in
      touch.phase != .ended
        && touch.phase != .cancelled
        && touchIsInsideBounds(touch)
    }
    var samples: [RemoteDrawTouchSample] = []
    samples.reserveCapacity(activeTouches.count)
    for touch in activeTouches {
      samples.append(sample(from: touch))
    }
    // Stable order keeps Equatable snapshots from flapping between events.
    samples.sort { (lhs: RemoteDrawTouchSample, rhs: RemoteDrawTouchSample) -> Bool in
      if lhs.location.x != rhs.location.x {
        return lhs.location.x < rhs.location.x
      }
      return lhs.location.y < rhs.location.y
    }
    let snapshot = RemoteDrawTouchSnapshot(
      samples: samples,
      hasBroadEdgeContact: activeTouches.contains(where: isBroadEdgeContact)
    )
    publishSnapshot(snapshot)
    return snapshot
  }

  private func sample(from touch: UITouch) -> RemoteDrawTouchSample {
    let location = touch.location(in: boundsView)
    let pressure: Double? = touch.maximumPossibleForce > 0
      ? min(1, max(0, Double(touch.force / touch.maximumPossibleForce)))
      : nil
    var tiltX: Double?
    var tiltY: Double?
    let isPencil = touch.type == .pencil
    if isPencil {
      let tilt = RemoteDrawPencilTilt.tilt(
        azimuthRadians: Double(touch.azimuthAngle(in: boundsView)),
        altitudeRadians: Double(touch.altitudeAngle)
      )
      tiltX = tilt.tiltX
      tiltY = tilt.tiltY
    }
    return RemoteDrawTouchSample(
      location: location,
      majorRadius: touch.majorRadius,
      pressure: pressure,
      tiltX: tiltX,
      tiltY: tiltY,
      isPencil: isPencil,
      isPalm: touch.type == .direct && RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius)
    )
  }

  private func publishSnapshot(_ snapshot: RemoteDrawTouchSnapshot) {
    guard snapshot != lastSnapshot else { return }
    lastSnapshot = snapshot
    onSnapshot?(snapshot)
  }

  private func touchIsInsideBounds(_ touch: UITouch) -> Bool {
    guard let boundsView else { return true }
    let location = touch.location(in: boundsView)
    return boundsView.bounds.insetBy(dx: -12, dy: -12).contains(location)
  }

  private func isBroadEdgeContact(_ touch: UITouch) -> Bool {
    guard touch.type == .direct, touch.majorRadius >= 24, let boundsView else { return false }
    let location = touch.location(in: boundsView)
    let bounds = boundsView.bounds
    let edgeInset: CGFloat = 48
    return location.x <= edgeInset
      || location.x >= bounds.width - edgeInset
      || location.y <= edgeInset
      || location.y >= bounds.height - edgeInset
  }
}

#endif
