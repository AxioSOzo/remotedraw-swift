import CoreGraphics
import Foundation
import SwiftUI

/// Where the surface stores what a person picked.
///
/// **The SDK's first `UserDefaults` access**, and the reason
/// `PrivacyInfo.xcprivacy` now declares `CA92.1`. Stage 1's manifest said in
/// so many words that the headless core read no defaults and that the
/// declaration would arrive with the surface rather than before it; this is
/// that change.
///
/// Five keys, all of them a person's own preference about their own drawing:
/// which hand, which instrument, how thick, what colour, whether shapes fill.
/// Nothing here is transmitted, nothing is an identifier, and the reason code
/// is `CA92.1` — access to defaults the app itself wrote — because every one
/// of these was written by this SDK inside its host's own container.
///
/// The keys are namespaced under `remotedraw.` and are the same strings the
/// first-party app has been writing since before the extraction, so a person
/// upgrading keeps their pencil.
public enum RemoteDrawPreferences {
  public static let handednessKey = "remotedraw.ergonomics.handedness"
  public static let drawingStyleKey = "remotedraw.drawing.style"
  public static let drawingThicknessKey = "remotedraw.drawing.thickness"
  public static let drawingColorKey = "remotedraw.drawing.color"
  public static let drawingFillKey = "remotedraw.drawing.fill"

  /// The instrument a fresh install leads with.
  public static let defaultStyleKind = DrawingStyleKind.whiteboardMarker
  public static let defaultThickness = 6.0

  /// Clamped to what the wire and the renderer both accept.
  public static func normalizedThickness(_ value: Double) -> Double {
    min(48, max(1, value.isFinite ? value : defaultThickness))
  }
}

/// Bidirectional mapping for the drawing surface.
///
/// Input and rendering must use the **same** `size`. Mixing a safe-area size
/// with an edge-to-edge one creates a scale error that is zero only at the
/// centre — ink that lands under the finger in the middle of the screen and
/// drifts further off the further out you draw.
public enum RemoteDrawDrawingSurfaceGeometry {
  public static func aspectFitSize(
    aspectRatio: CGFloat,
    in containerSize: CGSize
  ) -> CGSize {
    guard isUsable(containerSize), aspectRatio.isFinite, aspectRatio > 0 else { return .zero }
    if containerSize.width / containerSize.height > aspectRatio {
      return CGSize(width: containerSize.height * aspectRatio, height: containerSize.height)
    }
    return CGSize(width: containerSize.width, height: containerSize.width / aspectRatio)
  }

  public static func normalizedPoint(for location: CGPoint, in size: CGSize) -> CGPoint {
    guard isUsable(size) else { return .zero }
    return CGPoint(x: location.x / size.width, y: location.y / size.height)
  }

  public static func surfacePoint(for normalizedPoint: CGPoint, in size: CGSize) -> CGPoint {
    guard isUsable(size) else { return .zero }
    return CGPoint(x: normalizedPoint.x * size.width, y: normalizedPoint.y * size.height)
  }

  public static func isUsable(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
  }
}

/// Decision logic for the bottom-corner swipe that opens the controls sheet.
///
/// Pure functions so the thresholds stay unit-testable: the view supplies its
/// constants and the current broad-edge-contact hint.
public enum RemoteDrawCornerSwipe {
  public static func isBottomCornerStart(
    _ location: CGPoint,
    in size: CGSize,
    cornerSize: CGFloat
  ) -> Bool {
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
      return false
    }
    let isBottom = location.y >= size.height - cornerSize
    let isCorner = location.x <= cornerSize || location.x >= size.width - cornerSize
    return isBottom && isCorner
  }

  public static func shouldOpenControls(
    translation: CGSize,
    requiredTravel: CGFloat,
    maxHorizontalDrift: CGFloat,
    hasBroadEdgeContact: Bool,
    broadContactTravelFactor: CGFloat
  ) -> Bool {
    let travel = hasBroadEdgeContact ? requiredTravel * broadContactTravelFactor : requiredTravel
    return translation.height <= -travel && abs(translation.width) <= maxHorizontalDrift
  }

  public static func shouldResolveAsDrawing(
    translation: CGSize,
    resolveDistance: CGFloat,
    maxHorizontalDrift: CGFloat
  ) -> Bool {
    let distance = hypot(translation.width, translation.height)
    guard distance >= resolveDistance else { return false }
    if abs(translation.width) > maxHorizontalDrift { return true }
    return translation.height > -resolveDistance * 0.7
  }
}

// MARK: - Touch classification & samples

/// One active touch as seen by the ergonomic monitor, in the monitor's own
/// coordinate space.
///
/// Pressure is normalized `0...1` when the hardware reports force; tilt is in
/// degrees, PointerEvents convention.
public struct RemoteDrawTouchSample: Equatable, Sendable {
  public var location: CGPoint
  public var majorRadius: CGFloat
  public var pressure: Double?
  public var tiltX: Double?
  public var tiltY: Double?
  public var isPencil = false
  public var isPalm = false

  public init(
    location: CGPoint,
    majorRadius: CGFloat = 0,
    pressure: Double? = nil,
    tiltX: Double? = nil,
    tiltY: Double? = nil,
    isPencil: Bool = false,
    isPalm: Bool = false
  ) {
    self.location = location
    self.majorRadius = majorRadius
    self.pressure = pressure
    self.tiltX = tiltX
    self.tiltY = tiltY
    self.isPencil = isPencil
    self.isPalm = isPalm
  }
}

public enum RemoteDrawTouchSampleMatcher {
  /// Pairs a gesture location — a SwiftUI drag, say — with the monitor touch
  /// it most plausibly belongs to, so stroke points can inherit pressure,
  /// tilt and palm classification.
  ///
  /// This exists because `DragGesture` hands over a `CGPoint` and no
  /// `UITouch`: the hardware channels have to be matched back by position.
  public static func nearestSample(
    to location: CGPoint,
    in samples: [RemoteDrawTouchSample],
    maxDistance: CGFloat = 64
  ) -> RemoteDrawTouchSample? {
    var best: (sample: RemoteDrawTouchSample, distance: CGFloat)?
    for sample in samples {
      let distance = hypot(sample.location.x - location.x, sample.location.y - location.y)
      if best == nil || distance < best!.distance {
        best = (sample, distance)
      }
    }
    guard let best, best.distance <= maxDistance else { return nil }
    return best.sample
  }
}

// MARK: - Radial menu layout

public enum RemoteDrawRadialMetrics {
  public static let itemDiameter: CGFloat = 54
  public static let itemGap: CGFloat = 8
  public static let preferredRadius: CGFloat = 112
  public static let maxRadius: CGFloat = 168
  public static let edgeMargin: CGFloat = 10
  public static let hubDeadZone: CGFloat = 30
  public static let hitSlop: CGFloat = 16
}

/// A solved menu: hub anchor plus one screen-space centre per item.
public struct RemoteDrawRadialLayout: Equatable, Sendable {
  public let anchor: CGPoint
  public let itemCenters: [CGPoint]
  public let radius: CGFloat

  public init(anchor: CGPoint, itemCenters: [CGPoint], radius: CGFloat) {
    self.anchor = anchor
    self.itemCenters = itemCenters
    self.radius = radius
  }

  /// Nearest item the finger is on, or `nil` in the hub dead zone (cancel) or
  /// off the fan entirely.
  public func highlightedIndex(for location: CGPoint) -> Int? {
    guard !itemCenters.isEmpty else { return nil }
    let anchorDistance = hypot(location.x - anchor.x, location.y - anchor.y)
    guard anchorDistance >= RemoteDrawRadialMetrics.hubDeadZone else { return nil }
    var best: (index: Int, distance: CGFloat)?
    for (index, center) in itemCenters.enumerated() {
      let distance = hypot(center.x - location.x, center.y - location.y)
      if best == nil || distance < best!.distance {
        best = (index, distance)
      }
    }
    guard
      let best,
      best.distance <= RemoteDrawRadialMetrics.itemDiameter / 2 + RemoteDrawRadialMetrics.hitSlop
    else { return nil }
    return best.index
  }
}

/// Places items on an arc around the summon point.
///
/// Adjacent centres stay at least one item diameter plus gap apart (never
/// overlapping), the arc gathers toward the direction with the most screen
/// space, and the radius grows only when the feasible arc is too tight. When
/// even the largest radius cannot fit the fan — a corner press — the hub walks
/// inward until it does, the way a context menu stays on screen.
public enum RemoteDrawRadialSolver {
  public static func solve(
    anchor rawAnchor: CGPoint,
    in size: CGSize,
    itemCount: Int,
    itemDiameter: CGFloat = RemoteDrawRadialMetrics.itemDiameter,
    itemGap: CGFloat = RemoteDrawRadialMetrics.itemGap,
    preferredRadius: CGFloat = RemoteDrawRadialMetrics.preferredRadius,
    maxRadius: CGFloat = RemoteDrawRadialMetrics.maxRadius,
    edgeMargin: CGFloat = RemoteDrawRadialMetrics.edgeMargin
  ) -> RemoteDrawRadialLayout {
    guard itemCount > 0, size.width > 0, size.height > 0 else {
      return RemoteDrawRadialLayout(
        anchor: rawAnchor, itemCenters: [], radius: preferredRadius)
    }

    let margin = itemDiameter / 2 + edgeMargin
    let bounds = CGRect(origin: .zero, size: size).insetBy(dx: margin, dy: margin)
    var anchor = CGPoint(
      x: min(max(rawAnchor.x, 24), size.width - 24),
      y: min(max(rawAnchor.y, 24), size.height - 24)
    )
    guard bounds.width > 0, bounds.height > 0 else {
      return ring(anchor: anchor, itemCount: itemCount, radius: preferredRadius)
    }

    let chord = Double(itemDiameter + itemGap)
    let center = CGPoint(x: size.width / 2, y: size.height / 2)
    for _ in 0..<14 {
      if let layout = solveFixedAnchor(
        anchor: anchor, in: size, bounds: bounds, itemCount: itemCount,
        chord: chord, preferredRadius: preferredRadius, maxRadius: maxRadius
      ) {
        return layout
      }
      let dx = center.x - anchor.x
      let dy = center.y - anchor.y
      let distance = hypot(dx, dy)
      guard distance > 1 else { break }
      let stepLength = min(28, distance)
      anchor.x += stepLength * dx / distance
      anchor.y += stepLength * dy / distance
    }

    // Should be unreachable for realistic item counts; spread what we can.
    if let squeezed = squeeze(
      anchor: anchor, in: size, bounds: bounds, itemCount: itemCount, radius: maxRadius
    ) {
      return squeezed
    }
    return ring(anchor: anchor, itemCount: itemCount, radius: preferredRadius)
  }

  private static func solveFixedAnchor(
    anchor: CGPoint,
    in size: CGSize,
    bounds: CGRect,
    itemCount: Int,
    chord: Double,
    preferredRadius: CGFloat,
    maxRadius: CGFloat
  ) -> RemoteDrawRadialLayout? {
    let target = targetAngle(from: anchor, in: size)
    var radius = preferredRadius
    while radius <= maxRadius + 0.5 {
      let step = 2 * asin(min(1, chord / Double(2 * radius)))
      let needed = step * Double(itemCount - 1)
      if let window = feasibleWindow(
        around: target, anchor: anchor, radius: radius, bounds: bounds),
        window.end - window.start >= needed
      {
        let arcCenter = min(max(target, window.start + needed / 2), window.end - needed / 2)
        let centers = arcCenters(
          anchor: anchor, radius: radius, start: arcCenter - needed / 2,
          step: step, count: itemCount
        )
        return RemoteDrawRadialLayout(anchor: anchor, itemCenters: centers, radius: radius)
      }
      radius += 14
    }
    return nil
  }

  private static func squeeze(
    anchor: CGPoint,
    in size: CGSize,
    bounds: CGRect,
    itemCount: Int,
    radius: CGFloat
  ) -> RemoteDrawRadialLayout? {
    let target = targetAngle(from: anchor, in: size)
    guard
      let window = feasibleWindow(
        around: target, anchor: anchor, radius: radius, bounds: bounds)
    else { return nil }
    let span = window.end - window.start
    let step = itemCount > 1 ? span / Double(itemCount - 1) : 0
    let centers = arcCenters(
      anchor: anchor, radius: radius, start: window.start, step: step, count: itemCount)
    return RemoteDrawRadialLayout(anchor: anchor, itemCenters: centers, radius: radius)
  }

  private static func arcCenters(
    anchor: CGPoint,
    radius: CGFloat,
    start: Double,
    step: Double,
    count: Int
  ) -> [CGPoint] {
    (0..<count).map { index in
      let angle = start + step * Double(index)
      return CGPoint(
        x: anchor.x + radius * CGFloat(cos(angle)),
        y: anchor.y + radius * CGFloat(sin(angle))
      )
    }
  }

  private static func ring(
    anchor: CGPoint, itemCount: Int, radius: CGFloat
  ) -> RemoteDrawRadialLayout {
    let step = (2 * Double.pi) / Double(max(itemCount, 1))
    return RemoteDrawRadialLayout(
      anchor: anchor,
      itemCenters: arcCenters(
        anchor: anchor, radius: radius, start: -.pi / 2, step: step, count: itemCount),
      radius: radius
    )
  }

  /// Direction with the most room: toward the screen centre. Dead-centre
  /// presses open upward.
  private static func targetAngle(from anchor: CGPoint, in size: CGSize) -> Double {
    let dx = Double(size.width / 2 - anchor.x)
    let dy = Double(size.height / 2 - anchor.y)
    guard abs(dx) > 1 || abs(dy) > 1 else { return -.pi / 2 }
    return atan2(dy, dx)
  }

  /// Contiguous range of angles (sampled at 1.5°) around `target` where an
  /// item centre at `radius` stays inside `bounds`. Angles are unbounded
  /// reals so wrap-around needs no special casing.
  private static func feasibleWindow(
    around target: Double,
    anchor: CGPoint,
    radius: CGFloat,
    bounds: CGRect
  ) -> (start: Double, end: Double)? {
    let sample = (2 * Double.pi) / 240
    func fits(_ angle: Double) -> Bool {
      let point = CGPoint(
        x: anchor.x + radius * CGFloat(cos(angle)),
        y: anchor.y + radius * CGFloat(sin(angle))
      )
      return bounds.contains(point)
    }

    var seed = target
    if !fits(seed) {
      var offset = sample
      var found: Double?
      while offset <= .pi {
        if fits(target + offset) {
          found = target + offset
          break
        }
        if fits(target - offset) {
          found = target - offset
          break
        }
        offset += sample
      }
      guard let nearest = found else { return nil }
      seed = nearest
    }

    var start = seed
    var end = seed
    while end - start < 2 * .pi - sample, fits(end + sample) {
      end += sample
    }
    while end - start < 2 * .pi - sample, fits(start - sample) {
      start -= sample
    }
    return (start, end)
  }
}
