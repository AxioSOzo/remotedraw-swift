import CoreGraphics
import Foundation

/// Board space <-> geography <-> surface points, for `kind: "map"` boards.
///
/// The Swift half of `@remotedraw/geometry`'s `mapGeometry.ts`, and it must stay
/// bit-identical to it: a stored point means one place on Earth no matter who
/// drew it, so a sender that rounds differently from the receiver draws in the
/// wrong street. `Tests/RemoteDrawSenderKitTests/Fixtures/mapBoardGeometryVectors.json`
/// is the shared table both sides check themselves against.
///
/// Three spaces meet here and mixing them is what misplaces ink:
///
/// - **board space** — the normalized rectangle the wire carries. `x` is linear
///   in longitude across the board's bounds; `y` is linear in *Web Mercator*
///   between the bounds' north and south edges, **not** linear in latitude.
/// - **geography** — lon/lat.
/// - **surface space** — the `0…1` square of the phone's screen, which shows
///   whatever the map camera is currently looking at. That is not the board's
///   bounds: the camera pans and zooms freely, so board space has to be resolved
///   through geography before it can become a point on this screen.
///
/// Board space is deliberately **unbounded**. A point outside `0…1` is a point
/// outside the board's geographic fence, which is legal on the wire — the server
/// validates map-board points against ±100 rather than `0…1` — and is exactly
/// what a phone panned off the initial camera produces. Nothing here clamps
/// except the Mercator cut-off, which is a property of the projection rather
/// than of the board.
public enum RemoteDrawMapGeometry {
  /// Web Mercator is undefined at the poles; this is the standard cut-off.
  public static let maxMercatorLatitude = 85.05112878

  /// The smallest span any ratio is divided by.
  ///
  /// `1e-6`, matching the TypeScript's `Math.max(span, 0.000001)` exactly. The
  /// first-party app's private copy special-cased `span == 0` to `0` instead,
  /// which agrees with this for every non-degenerate fence and disagrees for a
  /// degenerate one. The shared table is the authority, so this is the
  /// behaviour that ships.
  public static let minimumSpan = 0.000001

  // MARK: Mercator

  public static func mercatorY(fromLatitude latitude: Double) -> Double {
    let clamped = min(maxMercatorLatitude, max(-maxMercatorLatitude, latitude))
    let radians = (clamped * Double.pi) / 180
    return log(tan(Double.pi / 4 + radians / 2))
  }

  public static func latitude(fromMercatorY value: Double) -> Double {
    ((2 * atan(exp(value)) - Double.pi / 2) * 180) / Double.pi
  }

  // MARK: Board space <-> geography

  public static func longitude(fromBoardX x: Double, bounds: RemoteDrawMapBounds) -> Double {
    bounds.minX + x * (bounds.maxX - bounds.minX)
  }

  public static func latitude(fromBoardY y: Double, bounds: RemoteDrawMapBounds) -> Double {
    let mercatorNorth = mercatorY(fromLatitude: bounds.maxY)
    let mercatorSouth = mercatorY(fromLatitude: bounds.minY)
    return latitude(fromMercatorY: mercatorNorth - y * (mercatorNorth - mercatorSouth))
  }

  /// The board point a place on Earth sits at.
  ///
  /// Longitude first, the order every map library takes it in: reversing lon/lat
  /// is the one mistake that produces plausible-looking ink in the wrong
  /// hemisphere.
  public static func boardPoint(
    longitude: Double,
    latitude: Double,
    bounds: RemoteDrawMapBounds
  ) -> CGPoint {
    let longitudeSpan = max(bounds.maxX - bounds.minX, minimumSpan)
    let mercatorNorth = mercatorY(fromLatitude: bounds.maxY)
    let mercatorSouth = mercatorY(fromLatitude: bounds.minY)
    let mercatorSpan = max(mercatorNorth - mercatorSouth, minimumSpan)
    return CGPoint(
      x: (longitude - bounds.minX) / longitudeSpan,
      y: (mercatorNorth - mercatorY(fromLatitude: latitude)) / mercatorSpan
    )
  }

  /// The place on Earth a board point means. The inverse of
  /// ``boardPoint(longitude:latitude:bounds:)``.
  public static func coordinate(
    fromBoardPoint point: CGPoint,
    bounds: RemoteDrawMapBounds
  ) -> (longitude: Double, latitude: Double) {
    (
      longitude: longitude(fromBoardX: Double(point.x), bounds: bounds),
      latitude: latitude(fromBoardY: Double(point.y), bounds: bounds)
    )
  }

  // MARK: Viewports

  /// The board rectangle a set of visible map bounds covers.
  public static func boardViewport(
    base: RemoteDrawMapBounds,
    visible: RemoteDrawMapBounds
  ) -> RemoteDrawBoardViewport {
    let topLeft = boardPoint(longitude: visible.minX, latitude: visible.maxY, bounds: base)
    let bottomRight = boardPoint(longitude: visible.maxX, latitude: visible.minY, bounds: base)
    return boardViewport(spanning: [topLeft, bottomRight])
  }

  /// The board rectangle a set of already-projected board points spans.
  ///
  /// The corner form, for a camera whose four screen corners were converted
  /// individually — which is what a `MapProxy` gives and what stays correct if
  /// the camera is ever rotated.
  public static func boardViewport(spanning points: [CGPoint]) -> RemoteDrawBoardViewport {
    let xs = points.map { Double($0.x) }
    let ys = points.map { Double($0.y) }
    let left = xs.min() ?? 0
    let right = xs.max() ?? 1
    let top = ys.min() ?? 0
    let bottom = ys.max() ?? 1
    return RemoteDrawBoardViewport(
      x: left,
      y: top,
      width: max(right - left, minimumSpan),
      height: max(bottom - top, minimumSpan)
    )
  }

  /// The geographic bounds a board rectangle covers. The inverse of
  /// ``boardViewport(base:visible:)``.
  public static func mapBounds(
    base: RemoteDrawMapBounds,
    viewport: RemoteDrawBoardViewport
  ) -> RemoteDrawMapBounds {
    let west = longitude(fromBoardX: viewport.x, bounds: base)
    let east = longitude(fromBoardX: viewport.x + viewport.width, bounds: base)
    let north = latitude(fromBoardY: viewport.y, bounds: base)
    let south = latitude(fromBoardY: viewport.y + viewport.height, bounds: base)
    return RemoteDrawMapBounds(
      minX: min(west, east),
      minY: min(south, north),
      maxX: max(west, east),
      maxY: max(south, north)
    )
  }

  // MARK: Board space <-> pixels, through a live camera

  /// Board space -> surface pixels on a map board: resolve the point to lon/lat
  /// against the **board's** fence, then place that on the surface through the
  /// bounds the camera is currently **showing**.
  ///
  /// Exact only for a north-up, unpitched camera — the visible bounds of a
  /// rotated or tilted map are not the rectangle it is showing. A host with
  /// rotation enabled projects through its own map instead and reports the
  /// result with ``RemoteDrawGroundContext/reportViewport``.
  public static func screenPoint(
    fromBoard point: CGPoint,
    base: RemoteDrawMapBounds,
    visible: RemoteDrawMapBounds,
    size: CGSize
  ) -> CGPoint {
    let longitudeSpan = max(visible.maxX - visible.minX, minimumSpan)
    let mercatorNorth = mercatorY(fromLatitude: visible.maxY)
    let mercatorSouth = mercatorY(fromLatitude: visible.minY)
    let mercatorSpan = max(mercatorNorth - mercatorSouth, minimumSpan)
    let lon = longitude(fromBoardX: Double(point.x), bounds: base)
    let lat = latitude(fromBoardY: Double(point.y), bounds: base)
    return CGPoint(
      x: ((lon - visible.minX) / longitudeSpan) * Double(size.width),
      y: ((mercatorNorth - mercatorY(fromLatitude: lat)) / mercatorSpan) * Double(size.height)
    )
  }

  /// The inverse of ``screenPoint(fromBoard:base:visible:size:)``.
  public static func boardPoint(
    fromScreen point: CGPoint,
    base: RemoteDrawMapBounds,
    visible: RemoteDrawMapBounds,
    size: CGSize
  ) -> CGPoint? {
    let longitudeSpan = max(visible.maxX - visible.minX, minimumSpan)
    let mercatorNorth = mercatorY(fromLatitude: visible.maxY)
    let mercatorSouth = mercatorY(fromLatitude: visible.minY)
    let mercatorSpan = max(mercatorNorth - mercatorSouth, minimumSpan)
    let lon = visible.minX + (Double(point.x) / max(Double(size.width), 1)) * longitudeSpan
    let mercator = mercatorNorth - (Double(point.y) / max(Double(size.height), 1)) * mercatorSpan
    let board = boardPoint(
      longitude: lon, latitude: latitude(fromMercatorY: mercator), bounds: base)
    guard board.x.isFinite, board.y.isFinite else { return nil }
    return board
  }

  // MARK: Surface space <-> board space

  /// A point on this screen, as a board point, given what the camera is showing.
  ///
  /// The **native map contract**: these are the coordinates a map sender puts on
  /// the wire, with **no `phoneProjection` alongside**. The server reads a map
  /// session's points as board space verbatim when no projection travels with
  /// them (`convex/sender.ts`), which is what makes drawing off the initial
  /// camera legal — and why sending a projection too would be a second,
  /// conflicting answer.
  public static func boardPoint(
    fromSurface point: RemoteDrawNormalizedPoint,
    viewport: RemoteDrawBoardViewport
  ) -> RemoteDrawNormalizedPoint {
    RemoteDrawNormalizedPoint(
      x: viewport.x + point.x * viewport.width,
      y: viewport.y + point.y * viewport.height,
      t: point.t,
      pressure: point.pressure,
      tiltX: point.tiltX,
      tiltY: point.tiltY
    )
  }

  /// The way back, for painting the board's own ink on this screen.
  ///
  /// `nil` when the viewport is degenerate, so the caller drops the mark rather
  /// than painting a divide-by-zero.
  public static func surfacePoint(
    fromBoard point: RemoteDrawNormalizedPoint,
    viewport: RemoteDrawBoardViewport
  ) -> RemoteDrawNormalizedPoint? {
    guard viewport.width.isFinite, viewport.height.isFinite,
      viewport.width > 0, viewport.height > 0
    else { return nil }
    let x = (point.x - viewport.x) / viewport.width
    let y = (point.y - viewport.y) / viewport.height
    guard x.isFinite, y.isFinite else { return nil }
    return RemoteDrawNormalizedPoint(
      x: x, y: y, t: point.t, pressure: point.pressure, tiltX: point.tiltX, tiltY: point.tiltY)
  }
}

/// A board's geographic fence: `minX`/`maxX` are **longitude**, `minY`/`maxY`
/// are **latitude**.
///
/// Fixed for the life of the session — no public route changes a session's
/// `coordinateSpace.bounds` once it exists — so a session's bounds must be sized
/// larger than the camera it opens on. ``padded(by:)`` is the one-liner for
/// that.
public struct RemoteDrawMapBounds: Equatable, Sendable {
  public let minX: Double
  public let minY: Double
  public let maxX: Double
  public let maxY: Double

  public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
    self.minX = minX
    self.minY = minY
    self.maxX = maxX
    self.maxY = maxY
  }

  /// The board's fence, or `nil` when the board declares none.
  ///
  /// `nil` rather than a default, deliberately: the web's fallback for a
  /// bounds-less map board is Manhattan, and a native sender silently drawing on
  /// Manhattan is worse than one that says it has no geography.
  public init?(_ bounds: RemoteDrawCoordinateSpace.Bounds?) {
    guard let bounds,
      let minX = bounds.minX, let minY = bounds.minY,
      let maxX = bounds.maxX, let maxY = bounds.maxY,
      minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite
    else { return nil }
    self.init(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
  }

  /// The fence of a target, when that target is a map board that declared one.
  public init?(target: RemoteDrawTarget?) {
    self.init(target?.coordinateSpace?.bounds)
  }

  /// Grown outward by a fraction of its own span, per side.
  ///
  /// `0.5` adds half a span on each side (a 2× fence), `1` adds a full span
  /// (3×). Latitude is clamped to the Mercator cut-off and longitude to ±180,
  /// because a fence outside those is not a place.
  public func padded(by padding: Double) -> RemoteDrawMapBounds {
    let amount = padding.isFinite ? max(0, padding) : 0
    let longitudePad = (maxX - minX) * amount
    let latitudePad = (maxY - minY) * amount
    return RemoteDrawMapBounds(
      minX: max(-180, minX - longitudePad),
      minY: max(-RemoteDrawMapGeometry.maxMercatorLatitude, minY - latitudePad),
      maxX: min(180, maxX + longitudePad),
      maxY: min(RemoteDrawMapGeometry.maxMercatorLatitude, maxY + latitudePad)
    )
  }

  public var isDegenerate: Bool { maxX <= minX || maxY <= minY }
}

/// The board rectangle a screen is currently showing, in board space.
public struct RemoteDrawBoardViewport: Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }

  /// The whole board, which is what a camera that has not reported yet is
  /// showing as far as anyone knows.
  public static let full = RemoteDrawBoardViewport(x: 0, y: 0, width: 1, height: 1)

  /// Whether two viewports are the same camera, to within the tolerance the
  /// first-party board uses before it re-installs the stroke space.
  ///
  /// A map camera reports continuously; re-installing the stroke space on every
  /// pixel of drift would rebuild the closure under the finger dozens of times a
  /// second for no visible difference.
  public func isClose(to other: RemoteDrawBoardViewport, epsilon: Double = 0.0005) -> Bool {
    abs(x - other.x) < epsilon && abs(y - other.y) < epsilon
      && abs(width - other.width) < epsilon && abs(height - other.height) < epsilon
  }
}

extension RemoteDrawStrokeSpace {
  /// A map board: the visible geography *is* the window.
  ///
  /// No `phoneProjection` travels — see
  /// ``RemoteDrawMapGeometry/boardPoint(fromSurface:viewport:)`` for why that is
  /// the contract rather than an omission — and `isBoardSpace` is true, so
  /// content that comes back from the board is unprojected through the same
  /// camera before it is painted.
  ///
  /// Build a fresh one whenever the camera moves. A map board re-reads its space
  /// continuously rather than freezing it at touch-down, because the map is
  /// still sliding under the finger and the ink has to stay on the geography.
  public static func map(viewport: RemoteDrawBoardViewport) -> RemoteDrawStrokeSpace {
    RemoteDrawStrokeSpace(
      phoneProjection: nil,
      isBoardSpace: true,
      project: { points in
        points.map { RemoteDrawMapGeometry.boardPoint(fromSurface: $0, viewport: viewport) }
      },
      unproject: { point in
        RemoteDrawMapGeometry.surfacePoint(fromBoard: point, viewport: viewport)
      }
    )
  }
}
