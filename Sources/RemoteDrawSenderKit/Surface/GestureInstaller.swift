//
//  Installed on the *window*, not on the drawing surface.
//
//  Shared by the native app, SDK surface and embedded web sender. Shortcut
//  arbitration follows physical contacts instead of independent tap recognizers
//  so a pinch cannot also undo, including when zoom has reached its limit.
//
#if canImport(UIKit) && !os(watchOS)
import SwiftUI
import UIKit

/// How far past the surface's edge a touch still counts as being on it: a
/// finger that lands a hair outside the bounds is drawing, not dismissing.
private let touchBoundsSlop: CGFloat = 12

/// Whether `touch` is on `boundsView`, within ``touchBoundsSlop``. No bounds
/// view means nothing to be outside of.
private func touchIsInsideBounds(_ touch: UITouch, of boundsView: UIView?) -> Bool {
  guard let boundsView else { return true }
  let location = touch.location(in: boundsView)
  return boundsView.bounds.insetBy(dx: -touchBoundsSlop, dy: -touchBoundsSlop).contains(location)
}

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
  /// A genuine new physical touch sequence, before its coalesced samples and
  /// snapshot. Only a single non-palm contact beginning on this surface fires
  /// it. Added fingers, leaving/reentering bounds, resets and synthetic empty
  /// snapshots never begin a new sequence. A host may reset cancellation latches
  /// here instead of treating a zero-touch snapshot as proof of a new gesture.
  public var onTouchSequenceBegan: (RemoteDrawTouchSample) -> Void = { _ in }
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
    onTouchSequenceBegan: @escaping (RemoteDrawTouchSample) -> Void = { _ in },
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
    self.onTouchSequenceBegan = onTouchSequenceBegan
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
    context.coordinator.onTouchSequenceBegan = onTouchSequenceBegan
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
    var onTouchSequenceBegan: (RemoteDrawTouchSample) -> Void = { _ in }
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
      monitor.onTouchSequenceBegan = { [weak self] sample in
        self?.onTouchSequenceBegan(sample)
      }
      monitor.onSnapshot = { [weak self] snapshot in
        self?.onTouchChange(snapshot)
      }
      monitor.onPredictedTouches = { [weak self] locations in
        self?.onPredictedTouches(locations)
      }
      monitor.onCoalescedSamples = { [weak self] samples in
        self?.onCoalescedSamples(samples)
      }
      monitor.onContactAction = { [weak self] action in
        guard let self, self.isActive else { return }
        switch action {
        case .undo: if self.isTwoFingerTapEnabled { self.onTwoFingerTap() }
        case .controls: self.onThreeFingerTap()
        }
      }
      monitor.onLongPressEligibilityChange = { [weak self] allowed in
        // A second contact owns the rest of this physical sequence, even if
        // the camera is already clamped and no visible zoom occurs.
        guard let self else { return }
        self.longPress?.isEnabled = self.isActive && self.isLongPressEnabled && allowed
      }
      monitor.delegate = self
      monitor.cancelsTouchesInView = false
      monitor.delaysTouchesBegan = false
      monitor.delaysTouchesEnded = false
      view.addGestureRecognizer(monitor)
      touchMonitor = monitor

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
      if !isActive { touchMonitor?.invalidateContactActions() }
      longPress?.isEnabled = isActive && isLongPressEnabled
        && (touchMonitor?.allowsLongPress ?? true)
    }

    func detach() {
      if let touchMonitor, let view = touchMonitor.view {
        view.removeGestureRecognizer(touchMonitor)
      }
      if let longPress, let view = longPress.view {
        view.removeGestureRecognizer(longPress)
      }
      touchMonitor = nil
      longPress = nil
      attachedView = nil
      onTouchChange(RemoteDrawTouchSnapshot())
      onPredictedTouches([])
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
      guard let boundsView else { return }
      let location = recognizer.location(in: boundsView)
      switch recognizer.state {
      case .began:
        guard touchMonitor?.claimLongPress() == true else { return }
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

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
      gestureRecognizer !== longPress || touchMonitor?.allowsLongPress == true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
      guard touchIsInsideBounds(touch, of: boundsView) else { return false }
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
  var onTouchSequenceBegan: ((RemoteDrawTouchSample) -> Void)?
  /// Physical identity is independent of surface bounds and palm classification.
  /// Keep it through recognizer resets; reconcile against each real UIEvent so
  /// touches that ended while the recognizer was disabled cannot stay stale.
  private var physicalTouches: Set<UITouch> = []
  private var contactGate = RemoteDrawContactGestureGate()
  private var contactIds: [UITouch: Int] = [:]
  private var nextContactId = 0
  var onContactAction: ((RemoteDrawContactAction) -> Void)?
  var onLongPressEligibilityChange: ((Bool) -> Void)?
  var allowsLongPress: Bool { contactGate.allowsLongPress }

  func invalidateContactActions() {
    contactGate.invalidate()
  }

  func claimLongPress() -> Bool { contactGate.claimLongPress() }

  private func updateContactActions(_ touches: Set<UITouch>, event: UIEvent) {
    // Reconcile contacts which ended while this monitor was disabled. A UIKit
    // reset alone never releases a physical contact or resets the gate.
    let present = event.allTouches ?? touches
    for (touch, id) in contactIds where !present.contains(touch) {
      contactGate.cancelled(contact: id)
      contactIds.removeValue(forKey: touch)
    }
    for touch in touches {
      let point = touch.location(in: boundsView)
      switch touch.phase {
      case .began:
        guard touchIsInsideBounds(touch, of: boundsView), contactIds[touch] == nil else { continue }
        nextContactId += 1
        contactIds[touch] = nextContactId
        contactGate.began(contact: nextContactId, position: point, timestamp: touch.timestamp,
          isPencilLike: touch.type != .direct || RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius))
      case .moved, .stationary:
        guard let id = contactIds[touch] else { continue }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
          contactGate.moved(contact: id, position: sample.location(in: boundsView), timestamp: sample.timestamp)
        }
        if RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius) { contactGate.invalidate() }
      case .ended:
        guard let id = contactIds.removeValue(forKey: touch) else { continue }
        if let action = contactGate.ended(contact: id, position: point, timestamp: touch.timestamp) {
          onContactAction?(action)
        }
      case .cancelled:
        guard let id = contactIds.removeValue(forKey: touch) else { continue }
        contactGate.cancelled(contact: id)
      default: break
      }
    }
    onLongPressEligibilityChange?(allowsLongPress)
  }
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
    let active = physicalContacts(in: event, fallback: touches)
    let prior = physicalTouches.intersection(active).union(active.subtracting(touches))
    physicalTouches = active
    updateContactActions(touches, event: event)
    if prior.isEmpty, active.count == 1, touches.count == 1,
      let touch = touches.first, touch.phase == .began,
      touchIsInsideBounds(touch, of: boundsView) {
      let captured = sample(from: touch)
      if !captured.isPalm { onTouchSequenceBegan?(captured) }
    }
    publishCoalesced(from: event)
    publishSnapshot(from: event)
    publishPredicted(from: event)
  }

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
    physicalTouches = physicalContacts(in: event, fallback: physicalTouches.union(touches))
    updateContactActions(touches, event: event)
    // Before the snapshot, deliberately: the snapshot is what a host uses to
    // decide a touch is a palm or a pinch and stand the stroke down, so the
    // samples for the event have to be in the host's hands by the time it makes
    // that call rather than one event behind it.
    publishCoalesced(from: event)
    publishSnapshot(from: event)
    publishPredicted(from: event)
  }

  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
    physicalTouches = physicalContacts(in: event, fallback: physicalTouches.subtracting(touches))
    updateContactActions(touches, event: event)
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
    physicalTouches = physicalContacts(in: event, fallback: physicalTouches.subtracting(touches))
    updateContactActions(touches, event: event)
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

  private func physicalContacts(in event: UIEvent, fallback: Set<UITouch>) -> Set<UITouch> {
    Set((event.allTouches ?? fallback).filter {
      $0.phase != .ended && $0.phase != .cancelled
    })
  }

  override func reset() {
    // UIKit resets the recognizer, not necessarily the physical contact. Never
    // emit a new sequence or clear physical identity from this synthetic path.
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
        && touchIsInsideBounds(touch, of: boundsView)
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
        && touchIsInsideBounds(touch, of: boundsView)
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
