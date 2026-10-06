// The map board's ground: a live MapKit view behind the ink canvas.
#if canImport(MapKit) && canImport(UIKit) && !os(watchOS)
  import MapKit
  import SwiftUI

  /// The geography of a `kind: "map"` board, drawn behind the ink.
  ///
  /// The port of the first-party app's `NativeMapBoardBackground`, and the thing
  /// whose absence made a customer's map session a blank white pad: a map
  /// board's ground resolves to ``RemoteDrawGround/transparent`` because MapKit
  /// *is* the ground, and until now the SDK had no MapKit.
  ///
  /// ## Not interactive by default
  ///
  /// `interactionModes` defaults to **empty**, which is what the first-party
  /// board ships: every touch belongs to the canvas, because a drag cannot be
  /// told apart from the gesture it might have been, and guessing wrong on a map
  /// board is not recoverable the way a mode switch is. A host that wants the
  /// person to move the camera passes its own modes — or supplies its own map
  /// entirely through `background:`, which is the supported way to keep your own
  /// cartography.
  ///
  /// Whatever moves the camera, the surface re-reads it: `onMapCameraChange`
  /// reports the visible rectangle continuously and the stroke space is
  /// re-installed from it, so ink lands on the geography actually on screen
  /// rather than the geography something asked for.
  public struct RemoteDrawMapBoardGround: View {
    private let bounds: RemoteDrawMapBounds
    private let projection: RemoteDrawProjection?
    private let interactionModes: MapInteractionModes
    private let onViewportChange: @MainActor (RemoteDrawBoardViewport) -> Void

    @State private var position: MapCameraPosition
    @State private var lastReported: RemoteDrawBoardViewport?

    public init(
      bounds: RemoteDrawMapBounds,
      projection: RemoteDrawProjection? = nil,
      interactionModes: MapInteractionModes = [],
      onViewportChange: @escaping @MainActor (RemoteDrawBoardViewport) -> Void = { _ in }
    ) {
      self.bounds = bounds
      self.projection = projection
      self.interactionModes = interactionModes
      self.onViewportChange = onViewportChange
      _position = State(
        initialValue: .region(
          RemoteDrawMapCamera(bounds: bounds, projection: projection).region))
    }

    private var camera: RemoteDrawMapCamera {
      RemoteDrawMapCamera(bounds: bounds, projection: projection)
    }

    public var body: some View {
      GeometryReader { geometry in
        MapReader { proxy in
          Map(position: $position, interactionModes: interactionModes)
            .allowsHitTesting(!interactionModes.isEmpty)
            // The board is drawn on, so the basemap is knocked back: full-tone
            // cartography under ink reads as two pictures rather than one.
            .overlay {
              LinearGradient(
                colors: [
                  .white.opacity(0.20),
                  .white.opacity(0.04),
                  .white.opacity(0.28),
                ],
                startPoint: .top,
                endPoint: .bottom
              )
              .allowsHitTesting(false)
            }
            .onAppear { position = .region(camera.region) }
            .onChange(of: camera) { _, next in position = .region(next.region) }
            .onMapCameraChange(frequency: .continuous) { context in
              report(visibleViewport(context: context, proxy: proxy, size: geometry.size))
            }
        }
      }
    }

    /// The board rectangle the camera is showing.
    ///
    /// Preferring the four **screen corners** over the reported region, the way
    /// the first-party board does: a corner conversion stays correct if the
    /// camera is ever rotated, and a region's span does not.
    private func visibleViewport(
      context: MapCameraUpdateContext,
      proxy: MapProxy,
      size: CGSize
    ) -> RemoteDrawBoardViewport {
      if size.width > 0, size.height > 0,
        let topLeft = proxy.convert(CGPoint(x: 0, y: 0), from: .local),
        let topRight = proxy.convert(CGPoint(x: size.width, y: 0), from: .local),
        let bottomRight = proxy.convert(CGPoint(x: size.width, y: size.height), from: .local),
        let bottomLeft = proxy.convert(CGPoint(x: 0, y: size.height), from: .local)
      {
        let corners = [topLeft, topRight, bottomRight, bottomLeft].map {
          RemoteDrawMapGeometry.boardPoint(
            longitude: $0.longitude, latitude: $0.latitude, bounds: bounds)
        }
        return RemoteDrawMapGeometry.boardViewport(spanning: corners)
      }
      let region = context.region
      return RemoteDrawMapGeometry.boardViewport(
        base: bounds,
        visible: RemoteDrawMapBounds(
          minX: region.center.longitude - region.span.longitudeDelta / 2,
          minY: region.center.latitude - region.span.latitudeDelta / 2,
          maxX: region.center.longitude + region.span.longitudeDelta / 2,
          maxY: region.center.latitude + region.span.latitudeDelta / 2
        ))
    }

    private func report(_ viewport: RemoteDrawBoardViewport) {
      if let lastReported, lastReported.isClose(to: viewport) { return }
      lastReported = viewport
      onViewportChange(viewport)
    }
  }

  /// Where a map board's camera starts, and where a receiver's window moves it.
  ///
  /// A pure value so it can be compared: SwiftUI drives the camera from
  /// `onChange`, and a snapshot that was not `Equatable` would re-seat the map on
  /// every render.
  public struct RemoteDrawMapCamera: Equatable, Sendable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    /// The camera for a board fence, optionally narrowed to the receiver's
    /// current window.
    ///
    /// With no projection the camera is the whole fence, which is the right
    /// opening shot: the person sees everything they are allowed to draw on.
    public init(bounds: RemoteDrawMapBounds, projection: RemoteDrawProjection? = nil) {
      let corners = Self.windowCorners(projection)
      let xs = corners.map(\.x)
      let ys = corners.map(\.y)
      let west = RemoteDrawMapGeometry.longitude(fromBoardX: xs.min() ?? 0, bounds: bounds)
      let east = RemoteDrawMapGeometry.longitude(fromBoardX: xs.max() ?? 1, bounds: bounds)
      let north = RemoteDrawMapGeometry.latitude(fromBoardY: ys.min() ?? 0, bounds: bounds)
      let south = RemoteDrawMapGeometry.latitude(fromBoardY: ys.max() ?? 1, bounds: bounds)
      self.init(
        centerLatitude: (north + south) / 2,
        centerLongitude: (west + east) / 2,
        // A floor, not a fit: a degenerate span asks MapKit for an infinite
        // zoom, and the map answers with a grey square.
        latitudeDelta: max(0.002, abs(north - south)),
        longitudeDelta: max(0.002, abs(east - west))
      )
    }

    public init(
      centerLatitude: Double,
      centerLongitude: Double,
      latitudeDelta: Double,
      longitudeDelta: Double
    ) {
      self.centerLatitude = centerLatitude
      self.centerLongitude = centerLongitude
      self.latitudeDelta = latitudeDelta
      self.longitudeDelta = longitudeDelta
    }

    public var region: MKCoordinateRegion {
      MKCoordinateRegion(
        center: CLLocationCoordinate2D(
          latitude: centerLatitude.isFinite ? centerLatitude : 0,
          longitude: centerLongitude.isFinite ? centerLongitude : 0),
        span: MKCoordinateSpan(
          latitudeDelta: latitudeDelta.isFinite ? latitudeDelta : 1,
          longitudeDelta: longitudeDelta.isFinite ? longitudeDelta : 1)
      )
    }

    /// The four corners of the receiver's window, in board space.
    ///
    /// Rotation is applied about the window's centre in the projection's own
    /// aspect-corrected space, which is the same arithmetic the receiver used to
    /// place the window in the first place.
    private static func windowCorners(_ projection: RemoteDrawProjection?) -> [CGPoint] {
      guard let projection else {
        return [
          CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
          CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
        ]
      }
      let declared = projection.coordinateAspectRatio ?? 1
      let safe = declared.isFinite && declared > 0 ? declared : 1
      let aspect = min(10, max(0.1, safe))
      let radians = normalizedRotationRadians(projection.rotationDegrees)
      return [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)].map { x, y in
        let localX = (x - 0.5) * projection.width * aspect
        let localY = (y - 0.5) * projection.height
        let rotatedX = localX * cos(radians) - localY * sin(radians)
        let rotatedY = localX * sin(radians) + localY * cos(radians)
        return CGPoint(
          x: projection.centerX + rotatedX / aspect,
          y: projection.centerY + rotatedY
        )
      }
    }

    private static func normalizedRotationRadians(_ degrees: Double) -> Double {
      let normalized =
        ((degrees.truncatingRemainder(dividingBy: 360)) + 360).truncatingRemainder(dividingBy: 360)
      return (normalized * Double.pi) / 180
    }
  }
#endif
