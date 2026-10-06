import CoreGraphics
import XCTest

@testable import RemoteDrawSenderKit

/// The board↔geography transform, checked against the table the TypeScript half
/// checks itself against.
///
/// `Fixtures/mapBoardGeometryVectors.json` is a verbatim copy of
/// `packages/geometry/tests/fixtures/mapBoardGeometryVectors.json`. Two
/// implementations of one projection is how ink ends up in the wrong street, and
/// prose parity ("keep these in sync") is what let the previous two copies drift
/// on their span clamps unnoticed. Re-copy the file when the shared table
/// changes:
///
/// ```sh
/// cp packages/geometry/tests/fixtures/mapBoardGeometryVectors.json \
///    apps/ios/RemoteDrawSenderKit/Tests/RemoteDrawSenderKitTests/Fixtures/
/// ```
final class MapGeometryTests: XCTestCase {
  /// The table's own tolerance, which is `1e-9` on board units and degrees.
  private var tolerance: (board: Double, degrees: Double, screenPixels: Double) = (
    1e-9, 1e-9, 1e-6
  )

  private struct Bounds: Decodable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double
    var kit: RemoteDrawMapBounds {
      RemoteDrawMapBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY)
    }
  }
  private struct XY: Decodable {
    let x: Double
    let y: Double
  }
  private struct LngLat: Decodable {
    let lng: Double
    let lat: Double
  }
  private struct Size: Decodable {
    let width: Double
    let height: Double
  }
  private struct MercatorRow: Decodable {
    let latitude: Double
    let mercatorY: Double
  }
  private struct BoardRow: Decodable {
    struct Point: Decodable {
      let board: XY
      let lngLat: LngLat
      let boardFromLngLat: XY
    }
    let label: String
    let bounds: Bounds
    let points: [Point]
  }
  private struct ScreenRow: Decodable {
    struct Point: Decodable {
      let board: XY
      let screen: XY
    }
    struct Viewport: Decodable {
      let x: Double
      let y: Double
      let width: Double
      let height: Double
    }
    let label: String
    let bounds: Bounds
    let viewportBounds: Bounds
    let coordinateSize: Size
    let boardViewport: Viewport
    let mapBoundsFromBoardViewport: Bounds
    let points: [Point]
  }
  private struct Tolerance: Decodable {
    let board: Double
    let degrees: Double
    let screenPixels: Double
  }
  private struct Vectors: Decodable {
    let version: Int
    let tolerance: Tolerance
    let maxMercatorLatitude: Double
    let mercator: [MercatorRow]
    let boards: [BoardRow]
    let screen: [ScreenRow]
  }

  private func loadVectors() throws -> Vectors {
    guard
      let url = Bundle.module.url(
        forResource: "mapBoardGeometryVectors", withExtension: "json")
    else {
      throw XCTSkip("mapBoardGeometryVectors.json is not in the test bundle.")
    }
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    tolerance = (
      vectors.tolerance.board, vectors.tolerance.degrees, vectors.tolerance.screenPixels
    )
    return vectors
  }

  func testTheCutOffMatchesTheSharedTable() throws {
    let vectors = try loadVectors()
    XCTAssertEqual(vectors.version, 1, "a new fixture version needs a look at this test")
    XCTAssertEqual(
      RemoteDrawMapGeometry.maxMercatorLatitude, vectors.maxMercatorLatitude, accuracy: 0)
  }

  func testEveryMercatorVector() throws {
    let vectors = try loadVectors()
    XCTAssertFalse(vectors.mercator.isEmpty)
    for row in vectors.mercator {
      XCTAssertEqual(
        RemoteDrawMapGeometry.mercatorY(fromLatitude: row.latitude), row.mercatorY,
        accuracy: tolerance.board,
        "mercatorY(\(row.latitude))")
      // Only round-trip inside the cut-off: past it the projection is not
      // injective, which is the whole reason the cut-off exists.
      guard abs(row.latitude) < RemoteDrawMapGeometry.maxMercatorLatitude else { continue }
      XCTAssertEqual(
        RemoteDrawMapGeometry.latitude(fromMercatorY: row.mercatorY), row.latitude,
        accuracy: tolerance.degrees,
        "latitude(fromMercatorY: \(row.mercatorY))")
    }
  }

  func testEveryBoardVector() throws {
    let vectors = try loadVectors()
    XCTAssertFalse(vectors.boards.isEmpty)
    var checked = 0
    for board in vectors.boards {
      let bounds = board.bounds.kit
      for point in board.points {
        let coordinate = RemoteDrawMapGeometry.coordinate(
          fromBoardPoint: CGPoint(x: point.board.x, y: point.board.y), bounds: bounds)
        XCTAssertEqual(
          coordinate.longitude, point.lngLat.lng, accuracy: tolerance.degrees,
          "\(board.label) lng at board \(point.board.x),\(point.board.y)")
        XCTAssertEqual(
          coordinate.latitude, point.lngLat.lat, accuracy: tolerance.degrees,
          "\(board.label) lat at board \(point.board.x),\(point.board.y)")

        let back = RemoteDrawMapGeometry.boardPoint(
          longitude: point.lngLat.lng, latitude: point.lngLat.lat, bounds: bounds)
        XCTAssertEqual(
          Double(back.x), point.boardFromLngLat.x, accuracy: tolerance.board,
          "\(board.label) board x from \(point.lngLat.lng),\(point.lngLat.lat)")
        XCTAssertEqual(
          Double(back.y), point.boardFromLngLat.y, accuracy: tolerance.board,
          "\(board.label) board y from \(point.lngLat.lng),\(point.lngLat.lat)")
        checked += 1
      }
    }
    XCTAssertGreaterThanOrEqual(checked, 6, "the table should carry more than a token row")
  }

  func testEveryScreenVector() throws {
    let vectors = try loadVectors()
    XCTAssertFalse(vectors.screen.isEmpty)
    for row in vectors.screen {
      let base = row.bounds.kit
      let visible = row.viewportBounds.kit
      let size = CGSize(width: row.coordinateSize.width, height: row.coordinateSize.height)

      let viewport = RemoteDrawMapGeometry.boardViewport(base: base, visible: visible)
      XCTAssertEqual(
        viewport.x, row.boardViewport.x, accuracy: tolerance.board, "\(row.label) viewport x")
      XCTAssertEqual(
        viewport.y, row.boardViewport.y, accuracy: tolerance.board, "\(row.label) viewport y")
      XCTAssertEqual(
        viewport.width, row.boardViewport.width, accuracy: tolerance.board,
        "\(row.label) viewport width")
      XCTAssertEqual(
        viewport.height, row.boardViewport.height, accuracy: tolerance.board,
        "\(row.label) viewport height")

      let bounds = RemoteDrawMapGeometry.mapBounds(base: base, viewport: viewport)
      XCTAssertEqual(
        bounds.minX, row.mapBoundsFromBoardViewport.minX, accuracy: tolerance.degrees,
        "\(row.label) minX")
      XCTAssertEqual(
        bounds.maxX, row.mapBoundsFromBoardViewport.maxX, accuracy: tolerance.degrees,
        "\(row.label) maxX")
      XCTAssertEqual(
        bounds.minY, row.mapBoundsFromBoardViewport.minY, accuracy: tolerance.degrees,
        "\(row.label) minY")
      XCTAssertEqual(
        bounds.maxY, row.mapBoundsFromBoardViewport.maxY, accuracy: tolerance.degrees,
        "\(row.label) maxY")

      for point in row.points {
        let screen = RemoteDrawMapGeometry.screenPoint(
          fromBoard: CGPoint(x: point.board.x, y: point.board.y),
          base: base, visible: visible, size: size)
        XCTAssertEqual(
          Double(screen.x), point.screen.x, accuracy: tolerance.screenPixels,
          "\(row.label) screen x for board \(point.board.x)")
        XCTAssertEqual(
          Double(screen.y), point.screen.y, accuracy: tolerance.screenPixels,
          "\(row.label) screen y for board \(point.board.y)")

        // And back. A projection that only goes one way cannot paint the
        // board's own ink on this screen, which is half of what a sender does.
        let round = try XCTUnwrap(
          RemoteDrawMapGeometry.boardPoint(
            fromScreen: screen, base: base, visible: visible, size: size))
        XCTAssertEqual(
          Double(round.x), point.board.x, accuracy: 1e-8, "\(row.label) round-trip x")
        XCTAssertEqual(
          Double(round.y), point.board.y, accuracy: 1e-8, "\(row.label) round-trip y")
      }
    }
  }

  // MARK: The stroke space the surface installs

  func testMapStrokeSpaceSendsBoardPointsAndNoProjection() {
    // The native map contract: points are board space verbatim, and **no**
    // `phoneProjection` travels — the server reads a map session's points as
    // board space precisely when no projection is alongside them.
    let viewport = RemoteDrawBoardViewport(x: 0.25, y: 0.5, width: 0.25, height: 0.125)
    let space = RemoteDrawStrokeSpace.map(viewport: viewport)

    XCTAssertNil(space.phoneProjection)
    XCTAssertTrue(space.isBoardSpace)

    let projected = space.project([
      RemoteDrawNormalizedPoint(x: 0, y: 0),
      RemoteDrawNormalizedPoint(x: 1, y: 1),
      RemoteDrawNormalizedPoint(x: 0.5, y: 0.5, t: 12, pressure: 0.4, tiltX: 3, tiltY: -4),
    ])
    XCTAssertEqual(projected[0].x, 0.25, accuracy: 1e-12)
    XCTAssertEqual(projected[0].y, 0.5, accuracy: 1e-12)
    XCTAssertEqual(projected[1].x, 0.5, accuracy: 1e-12)
    XCTAssertEqual(projected[1].y, 0.625, accuracy: 1e-12)
    XCTAssertEqual(projected[2].x, 0.375, accuracy: 1e-12)
    XCTAssertEqual(projected[2].y, 0.5625, accuracy: 1e-12)
    // The hardware channels survive the transform; a projected point that lost
    // its pressure draws a different mark from every other client.
    XCTAssertEqual(projected[2].t, 12)
    XCTAssertEqual(projected[2].pressure, 0.4)
    XCTAssertEqual(projected[2].tiltX, 3)
    XCTAssertEqual(projected[2].tiltY, -4)

    for point in projected {
      let back = space.unproject(point)
      XCTAssertNotNil(back)
    }
    let back = space.unproject(projected[2])
    XCTAssertEqual(back?.x ?? .nan, 0.5, accuracy: 1e-12)
    XCTAssertEqual(back?.y ?? .nan, 0.5, accuracy: 1e-12)
  }

  func testABoardPointOffTheCameraStillProjectsRatherThanBeingClamped() {
    // Board space is unbounded on purpose: a phone panned off the fence draws
    // legally at x > 1, and the server validates map points against ±100.
    let space = RemoteDrawStrokeSpace.map(
      viewport: RemoteDrawBoardViewport(x: 0.9, y: 0.9, width: 0.5, height: 0.5))
    let projected = space.project([RemoteDrawNormalizedPoint(x: 1, y: 1)])
    XCTAssertEqual(projected[0].x, 1.4, accuracy: 1e-12)
    XCTAssertEqual(projected[0].y, 1.4, accuracy: 1e-12)
  }

  func testADegenerateViewportDropsThePointRatherThanPaintingInfinity() {
    let space = RemoteDrawStrokeSpace.map(
      viewport: RemoteDrawBoardViewport(x: 0, y: 0, width: 0, height: 1))
    XCTAssertNil(space.unproject(RemoteDrawNormalizedPoint(x: 0.5, y: 0.5)))
  }

  // MARK: Bounds from the wire

  func testBoundsRequireAllFourNumbersRatherThanDefaultingToManhattan() {
    XCTAssertNil(RemoteDrawMapBounds(nil))
    XCTAssertNil(
      RemoteDrawMapBounds(RemoteDrawCoordinateSpace.Bounds(minX: -74, minY: 40, maxX: -73)))
    let bounds = try? XCTUnwrap(
      RemoteDrawMapBounds(
        RemoteDrawCoordinateSpace.Bounds(minX: -74, minY: 40.7, maxX: -73.9, maxY: 40.8)))
    XCTAssertEqual(bounds?.minX, -74)
    XCTAssertEqual(bounds?.maxY, 40.8)
  }

  func testATargetWithoutACoordinateSpaceHasNoFence() {
    XCTAssertNil(RemoteDrawMapBounds(target: RemoteDrawTarget(kind: "map")))
    XCTAssertNotNil(
      RemoteDrawMapBounds(
        target: RemoteDrawTarget(
          kind: "map",
          coordinateSpace: RemoteDrawCoordinateSpace(
            bounds: RemoteDrawCoordinateSpace.Bounds(
              minX: -74, minY: 40.7, maxX: -73.9, maxY: 40.8)))))
  }

  func testPaddingGrowsTheFenceAndClampsToRealPlaces() {
    let bounds = RemoteDrawMapBounds(minX: -10, minY: -10, maxX: 10, maxY: 10)
    let padded = bounds.padded(by: 1)
    XCTAssertEqual(padded.minX, -30)
    XCTAssertEqual(padded.maxX, 30)
    XCTAssertEqual(padded.minY, -30)
    XCTAssertEqual(padded.maxY, 30)

    let wide = RemoteDrawMapBounds(minX: -170, minY: -80, maxX: 170, maxY: 80).padded(by: 5)
    XCTAssertEqual(wide.minX, -180)
    XCTAssertEqual(wide.maxX, 180)
    XCTAssertEqual(wide.minY, -RemoteDrawMapGeometry.maxMercatorLatitude)
    XCTAssertEqual(wide.maxY, RemoteDrawMapGeometry.maxMercatorLatitude)
  }
}
