import CoreGraphics
import Foundation

/// UIKit reports Pencil attitude as azimuth + altitude; the stroke protocol
/// carries PointerEvents-style `tiltX` / `tiltY` in degrees.
///
/// Ported from `apps/ios/RemoteDraw/ErgonomicsCore.swift`, which is the
/// conversion every first-party stroke has gone through. It matters because
/// RemoteDraw's ink is tapered dynamic ribbons driven by pressure, tilt and
/// velocity: a sender that reports no tilt draws a visibly different mark from
/// every other client on the same board, side by side in the same drawing.
public enum RemoteDrawPencilTilt {
  public static func tilt(azimuthRadians: Double, altitudeRadians: Double) -> (
    tiltX: Double, tiltY: Double
  ) {
    let altitude = max(0.0001, min(.pi / 2, altitudeRadians))
    let tiltX = atan2(cos(azimuthRadians) * cos(altitude), sin(altitude)) * 180 / .pi
    let tiltY = atan2(sin(azimuthRadians) * cos(altitude), sin(altitude)) * 180 / .pi
    return (tiltX, tiltY)
  }
}

/// Whether a contact patch is a fingertip or the side of a hand.
public enum RemoteDrawTouchClassifier {
  /// Direct touches at or above this contact radius are treated as palm/heel
  /// contact. Fingertips usually report ~10-25pt but firm or flat presses can
  /// spike toward the mid-30s; palms and heels read ~55pt and up.
  ///
  /// Biased high on purpose: palm rejection here is a hint that cancels a
  /// draft, never something that deletes committed ink, so the cost of a false
  /// negative is a stray mark and the cost of a false positive is a lost
  /// stroke.
  public static let palmRadiusThreshold: CGFloat = 58

  public static func isPalm(majorRadius: CGFloat) -> Bool {
    majorRadius >= palmRadiusThreshold
  }
}

/// Turns a point in a view into a normalized protocol sample.
///
/// Input and rendering must use the **same** size. Mixing a safe-area size with
/// an edge-to-edge one creates a scale error that is zero only at the centre —
/// ink that lands under the finger in the middle of the screen and drifts
/// further off the further out you draw.
public enum RemoteDrawSurfaceGeometry {
  public static func normalized(_ location: CGPoint, in size: CGSize) -> CGPoint {
    guard isUsable(size) else { return .zero }
    return CGPoint(x: location.x / size.width, y: location.y / size.height)
  }

  public static func surfacePoint(_ normalized: CGPoint, in size: CGSize) -> CGPoint {
    guard isUsable(size) else { return .zero }
    return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
  }

  public static func isUsable(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }

  /// Clamps to `0...1` **and eats NaN**, which is the half people forget.
  ///
  /// `min(1, max(0, .nan))` returns 0 in Swift because every comparison against
  /// NaN is false — that accident is the only reason the first-party app never
  /// hit the codec's NaN trap. Doing it deliberately here means the SDK does
  /// not depend on an accident in somebody else's capture code.
  public static func clamp01(_ value: Double) -> Double {
    guard value.isFinite else { return 0 }
    return min(1, max(0, value))
  }
}

#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  /// The capture layer: coalesced touches, hardware pressure, Pencil tilt,
  /// prediction, and palm rejection.
  ///
  /// Place it over the drawing area and it reports normalized samples. It is a
  /// `UIViewRepresentable` and not a SwiftUI `DragGesture` for a reason that is
  /// not stylistic: a `DragGesture` yields one location per event and no
  /// `UITouch` at all, so it cannot see force, azimuth, altitude, contact
  /// radius, coalesced samples, or predicted ones. A sender built on it drops
  /// every sample the hardware gathered between two display refreshes and
  /// reports no pressure or tilt — which produces ink that visibly differs from
  /// every other RemoteDraw client on the same board.
  ///
  /// ## The four callbacks
  ///
  /// - `onBegin` — a stroke started. Call
  ///   ``RemoteDrawSenderSession/begin(stroke:tool:style:)``.
  /// - `onSamples` — **committed** samples, in order, including the coalesced
  ///   ones UIKit gathered since the last event. These go on the wire.
  /// - `onPredicted` — where UIKit thinks the finger is about to be. Preview
  ///   only; these must never reach ``RemoteDrawSenderSession/append(_:)``.
  ///   They are a separate channel rather than a flag on a sample precisely so
  ///   the two cannot be confused at a call site.
  /// - `onEnd` — the stroke finished (`ended`) or was abandoned (`cancelled`,
  ///   or a palm landing).
  public struct RemoteDrawStrokeCapture: UIViewRepresentable {
    public typealias SampleHandler = ([RemoteDrawSample]) -> Void

    let onBegin: (RemoteDrawStrokeID) -> Void
    let onSamples: SampleHandler
    let onPredicted: SampleHandler
    let onEnd: (RemoteDrawStrokeID, RemoteDrawStrokeCaptureEnd) -> Void
    let rejectsPalms: Bool

    public init(
      rejectsPalms: Bool = true,
      onBegin: @escaping (RemoteDrawStrokeID) -> Void,
      onSamples: @escaping SampleHandler,
      onPredicted: @escaping SampleHandler = { _ in },
      onEnd: @escaping (RemoteDrawStrokeID, RemoteDrawStrokeCaptureEnd) -> Void
    ) {
      self.rejectsPalms = rejectsPalms
      self.onBegin = onBegin
      self.onSamples = onSamples
      self.onPredicted = onPredicted
      self.onEnd = onEnd
    }

    public func makeUIView(context: Context) -> RemoteDrawStrokeCaptureView {
      let view = RemoteDrawStrokeCaptureView()
      view.apply(self)
      return view
    }

    public func updateUIView(_ uiView: RemoteDrawStrokeCaptureView, context: Context) {
      uiView.apply(self)
    }
  }

  /// How a stroke stopped.
  public enum RemoteDrawStrokeCaptureEnd: Equatable, Sendable {
    /// The finger lifted. Commit it.
    case finished
    /// The system took the touch away, or a palm landed. Drop it — call
    /// ``RemoteDrawSenderSession/cancelStroke()``, not `end(stroke:)`.
    case cancelled
  }

  /// The `UIView` behind ``RemoteDrawStrokeCapture``.
  ///
  /// Public so a UIKit host can use it directly, without SwiftUI.
  public final class RemoteDrawStrokeCaptureView: UIView {
    private var onBegin: ((RemoteDrawStrokeID) -> Void)?
    private var onSamples: (([RemoteDrawSample]) -> Void)?
    private var onPredicted: (([RemoteDrawSample]) -> Void)?
    private var onEnd: ((RemoteDrawStrokeID, RemoteDrawStrokeCaptureEnd) -> Void)?
    private var rejectsPalms = true

    private var activeTouch: UITouch?
    private var activeStrokeId: RemoteDrawStrokeID?

    public override init(frame: CGRect) {
      super.init(frame: frame)
      backgroundColor = .clear
      isMultipleTouchEnabled = true
      isExclusiveTouch = false
    }

    public required init?(coder: NSCoder) {
      super.init(coder: coder)
      backgroundColor = .clear
      isMultipleTouchEnabled = true
      isExclusiveTouch = false
    }

    func apply(_ capture: RemoteDrawStrokeCapture) {
      onBegin = capture.onBegin
      onSamples = capture.onSamples
      onPredicted = capture.onPredicted
      onEnd = capture.onEnd
      rejectsPalms = capture.rejectsPalms
    }

    // MARK: Touch handling

    public override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesBegan(touches, with: event)
      // One drawing touch at a time. A second finger is a pinch, and a pinch
      // has no ink: it must not append to the stroke the first finger is making.
      guard activeTouch == nil, let touch = touches.first else { return }
      guard !isRejected(touch) else { return }
      let id = "ios-\(UUID().uuidString)"
      activeTouch = touch
      activeStrokeId = id
      onBegin?(id)
      emit(touch, event: event)
    }

    public override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesMoved(touches, with: event)
      guard let active = activeTouch, touches.contains(active) else { return }
      if isRejected(active) {
        finish(.cancelled)
        return
      }
      emit(active, event: event)
    }

    public override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesEnded(touches, with: event)
      guard let active = activeTouch, touches.contains(active) else { return }
      emit(active, event: event)
      finish(.finished)
    }

    public override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      super.touchesCancelled(touches, with: event)
      guard let active = activeTouch, touches.contains(active) else { return }
      finish(.cancelled)
    }

    private func finish(_ reason: RemoteDrawStrokeCaptureEnd) {
      let id = activeStrokeId
      activeTouch = nil
      activeStrokeId = nil
      onPredicted?([])
      if let id { onEnd?(id, reason) }
    }

    private func isRejected(_ touch: UITouch) -> Bool {
      guard rejectsPalms, touch.type == .direct else { return false }
      return RemoteDrawTouchClassifier.isPalm(majorRadius: touch.majorRadius)
    }

    /// Publishes everything the hardware gathered since the last event.
    ///
    /// `coalescedTouches` is the point of this method. UIKit delivers one
    /// `touchesMoved` per display refresh but the digitiser samples several
    /// times faster than that — up to 240 Hz on an iPad with a Pencil — and
    /// hands over the intermediate samples here. Reading only
    /// `touch.location(in:)` throws them away, which shortens tight curves into
    /// corners at exactly the speed people write at.
    private func emit(_ touch: UITouch, event: UIEvent?) {
      let coalesced = event?.coalescedTouches(for: touch) ?? [touch]
      let samples = coalesced.map(sample(from:))
      if !samples.isEmpty { onSamples?(samples) }

      let predicted = event?.predictedTouches(for: touch) ?? []
      onPredicted?(predicted.map(sample(from:)))
    }

    private func sample(from touch: UITouch) -> RemoteDrawSample {
      let location = touch.location(in: self)
      let normalized = RemoteDrawSurfaceGeometry.normalized(location, in: bounds.size)
      let pressure: Double? =
        touch.maximumPossibleForce > 0
        ? min(1, max(0, Double(touch.force / touch.maximumPossibleForce)))
        : nil
      var tiltX: Double?
      var tiltY: Double?
      if touch.type == .pencil {
        let tilt = RemoteDrawPencilTilt.tilt(
          azimuthRadians: Double(touch.azimuthAngle(in: self)),
          altitudeRadians: Double(touch.altitudeAngle)
        )
        tiltX = tilt.tiltX
        tiltY = tilt.tiltY
      }
      return RemoteDrawSample(
        x: RemoteDrawSurfaceGeometry.clamp01(Double(normalized.x)),
        y: RemoteDrawSurfaceGeometry.clamp01(Double(normalized.y)),
        // Milliseconds since process start, never since 1970 and never since
        // boot. See ``RemoteDrawInkClock`` — this is both a correctness
        // constraint (the codec quantises `t` into an Int32) and a privacy one
        // (required-reason code 35F9.1).
        t: RemoteDrawInkClock.milliseconds,
        pressure: pressure,
        tiltX: tiltX,
        tiltY: tiltY
      )
    }
  }
#endif

#if canImport(UIKit) && !os(watchOS)
  import UIKit

  extension RemoteDrawSenderDevice {
    /// This device, described the way the first-party app describes it.
    ///
    /// The receiver uses every field: the geometry places the phone's viewport
    /// on the board and sizes the ink, and the name tells one connected phone
    /// from another. A host that would rather not send an identifier at all
    /// uses ``anonymous(aspectRatio:screen:)`` instead — that is a supported
    /// configuration, not a degraded one, and it is what makes the SDK's
    /// `NSPrivacyCollectedDataTypeDeviceID` declaration an opt-out rather than
    /// a condition of use.
    @MainActor
    public static func current(bundle: Bundle = .main) -> RemoteDrawSenderDevice {
      let screen = RemoteDrawSenderDeviceScreen.current()
      return RemoteDrawSenderDevice(
        deviceId: UIDevice.current.identifierForVendor?.uuidString,
        platform: "ios",
        appVersion: bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
        // The model name, not a user-chosen one, absent the
        // user-assigned-device-name entitlement.
        displayName: UIDevice.current.name,
        modelIdentifier: modelIdentifier(),
        aspectRatio: screen.map { $0.width / max(1, $0.height) } ?? 393.0 / 852.0,
        screen: screen
      )
    }

    /// `iPhone17,1` and friends, from `uname`.
    static func modelIdentifier() -> String? {
      #if targetEnvironment(simulator)
        let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"]?
          .trimmingCharacters(in: .whitespacesAndNewlines)
        if let simulated, !simulated.isEmpty { return simulated }
      #endif
      var info = utsname()
      uname(&info)
      let identifier = withUnsafeBytes(of: info.machine) { buffer in
        String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
      }
      return identifier.isEmpty ? nil : identifier
    }
  }

  extension RemoteDrawSenderDeviceScreen {
    /// The active window's geometry, or `nil` before there is one.
    @MainActor
    public static func current() -> RemoteDrawSenderDeviceScreen? {
      let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      guard
        let window = scenes.first(where: { $0.activationState == .foregroundActive })?.keyWindow
          ?? scenes.first?.keyWindow
      else { return nil }
      let bounds = window.bounds
      let scale = window.screen.scale
      let insets = window.safeAreaInsets
      return RemoteDrawSenderDeviceScreen(
        width: bounds.width,
        height: bounds.height,
        scale: scale,
        pixelWidth: bounds.width * scale,
        pixelHeight: bounds.height * scale,
        safeAreaTop: insets.top,
        safeAreaRight: insets.right,
        safeAreaBottom: insets.bottom,
        safeAreaLeft: insets.left,
        cutout: cutoutKind(topInset: insets.top, scale: scale)
      )
    }

    /// Which hole the receiver should draw in the phone frame.
    ///
    /// Inferred from the top safe-area inset because there is no API that
    /// reports it. The thresholds are the ones the web sender uses
    /// (`packages/client/src/phoneFrames.ts`), so a phone described by either
    /// client draws the same frame on the board.
    static func cutoutKind(topInset: CGFloat, scale: CGFloat) -> String {
      if topInset >= 54 { return "dynamicIsland" }
      if topInset >= 44 { return "notch" }
      return "none"
    }
  }
#endif
