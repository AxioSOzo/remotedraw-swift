import Combine
import CoreGraphics
import SwiftUI

/// The public face of `InkRenderer.swift`.
///
/// `RemoteDrawInk` is the sole source of truth for the renderer: the first-party
/// app compiles this target's source directly (see `apps/ios/project.yml`) and
/// there is no other copy. Nearly every declaration in the renderer is still
/// internal — its surface is diffed against the web twin as a unit, and its
/// tests reach the internals through `@testable import` — so the handful of
/// entry points a sender outside this module needs are re-exported here, one
/// thin forwarding call each.
///
/// Nothing here adds behaviour. If a call needs logic it belongs in the
/// renderer, where the web twin can be diffed against it.
public enum RemoteDrawInkGeometry {
  /// Whether a freshly captured sample is worth keeping.
  ///
  /// The sampler decimates straight motion hard and keeps near samples through
  /// direction changes and pressure ramps, so a stroke spends points where the
  /// shape actually is. A capture layer that skips this sends several times the
  /// points for the same mark and hits the budget that much sooner.
  public static func shouldAppendSample(
    _ points: [RemoteDrawNormalizedPoint],
    candidate: RemoteDrawNormalizedPoint
  ) -> Bool {
    InkRenderer.shouldAppendSample(points, candidate: candidate)
  }

  /// Extends a live stroke past the finger, for **preview only**.
  ///
  /// The returned array must never be drafted, committed or replaced with — it
  /// contains positions the finger has not reached. Keep the captured array for
  /// the wire and hand this one to the renderer. Same invariant
  /// `packages/client/src/pointerInput.ts` states for the web senders.
  public static func previewPointsWithPrediction(
    _ points: [RemoteDrawNormalizedPoint],
    predicted: [RemoteDrawNormalizedPoint]
  ) -> [RemoteDrawNormalizedPoint] {
    InkRenderer.previewPointsWithPrediction(points, predicted: predicted)
  }

  /// Whether a protocol drawing type paints as ink rather than as a plain path.
  public static func isInkShapeType(_ type: String) -> Bool {
    InkRenderer.isInkShapeType(type)
  }

  /// The instrument palette a surface leads with, best first.
  public static func toolOrder(
    for surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind
  ) -> [DrawingStyleKind] {
    RemoteDrawInkSurface.toolOrder(surface)
  }
}

/// What the marks are being made on.
///
/// The paper tooth belongs to the **surface**, not to the instrument: dry media
/// skip the same valleys wherever they cross the page, which is why hatching
/// does not fill in. See `docs/plans/2026-08-08-texture-fidelity.md`.
///
/// A host that paints its own background — a form, a photo, a screenshot —
/// wants ``transparent``, which is also what the `custom` protocol surface
/// resolves to: inventing a paper tooth over someone else's artwork is worse
/// than having none.
public enum RemoteDrawGround: Equatable, Sendable {
  /// Cartridge paper with its tooth.
  case paper
  /// A flat sheet, no tooth. What a whiteboard target gets.
  case flat(red: Double, green: Double, blue: Double)
  /// The host paints the ground; the canvas paints only ink.
  case transparent

  /// A whiteboard's white.
  public static let whiteboard = RemoteDrawGround.flat(red: 1, green: 1, blue: 1)

  /// The ground a session's `target.kind` asks for.
  ///
  /// Unknown names resolve to paper rather than failing, matching
  /// `RemoteDrawInkSurface.kind(forProtocolName:)`: a board with an unfamiliar
  /// surface still has to draw.
  public static func forProtocolSurface(_ name: String?) -> RemoteDrawGround {
    switch RemoteDrawInkSurface.kind(forProtocolName: name) {
    case .paper: return .paper
    case .whiteboard: return .whiteboard
    case .map, .custom: return .transparent
    }
  }

  /// The render axis this ground draws on, which is what decides tooth and
  /// instrument palette.
  public var surfaceKind: RemoteDrawInkSurface.Kind {
    switch self {
    case .paper: return .paper
    case .flat: return .whiteboard
    case .transparent: return .custom
    }
  }

  /// The flat tone to paint before — or instead of — the rasterised sheet.
  public var flatColor: Color {
    switch self {
    case .paper: return RemoteDrawPaperGround.color
    case .flat(let red, let green, let blue): return Color(red: red, green: green, blue: blue)
    case .transparent: return .clear
    }
  }

  /// The rasterised paper sheet, once it exists. `nil` until then — paint
  /// ``flatColor`` meanwhile and redraw when ``RemoteDrawGroundCache/revision``
  /// changes, which is what publishes its arrival.
  public var tile: CGImage? {
    guard case .paper = self else { return nil }
    return RemoteDrawPaperGround.tile(grain: RemoteDrawInkSurface.grain(.paper))
  }

  /// Starts both rasterisations — the sheet and the tooth mask the marks on it
  /// are cut by — before the first board needs them. Cheap to call twice.
  public func prepare(toothExtent: CGFloat = 1024) {
    guard case .paper = self else { return }
    RemoteDrawPaperGround.prepareTile(grain: RemoteDrawInkSurface.grain(.paper))
    RemoteDrawInk.prepareToothImage(for: RemoteDrawInkSurface.Kind.paper, extent: toothExtent)
  }
}

/// Publishes the arrival of a rasterised paper or tooth field, so a view that
/// painted the flat tone redraws with the real one.
///
/// Re-exported from the renderer's own `ToothFieldCache`, which stays internal
/// like the rest of the renderer (see above). Without an observer the first dry stroke on
/// a fresh board paints unmasked and stays that way until something else
/// happens to invalidate the view.
@MainActor
public final class RemoteDrawGroundCache: ObservableObject {
  public static let shared = RemoteDrawGroundCache()

  /// Bumped whenever a field lands.
  @Published public private(set) var revision = 0

  private var observation: AnyCancellable?

  private init() {
    observation = ToothFieldCache.shared.$revision
      .receive(on: DispatchQueue.main)
      .sink { [weak self] value in
        self?.revision = value
      }
  }
}
