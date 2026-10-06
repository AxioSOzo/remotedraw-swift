import SwiftUI

/// A published raster in normalized board coordinates. Optional on older sessions.
public struct RemoteDrawStaticBackground: Decodable, Hashable, Sendable {
  public struct Asset: Decodable, Hashable, Sendable {
    public let url: String
    public let mimeType: String
    public let pixelWidth: Int
    public let pixelHeight: Int
  }
  public struct Region: Decodable, Hashable, Sendable {
    public let minX: Double
    public let minY: Double
    public let maxX: Double
    public let maxY: Double
    public var corners: [RemoteDrawNormalizedPoint] {
      guard [minX, minY, maxX, maxY].allSatisfy({ $0.isFinite }), minX < maxX, minY < maxY else { return [] }
      return [.init(x: minX, y: minY), .init(x: maxX, y: minY),
        .init(x: maxX, y: maxY), .init(x: minX, y: maxY)]
    }
  }
  public struct Interaction: Decodable, Hashable, Sendable {
    public let pan: Bool
    public let zoom: Bool
    public let overzoom: Double
  }
  public struct Opening: Decodable, Hashable, Sendable {
    public struct Viewport: Decodable, Hashable, Sendable {
      public let centerX: Double
      public let centerY: Double
      public let height: Double
    }
    public let fit: String
    public let view: Viewport?
  }
  public let opening: Opening?
  public let version: Int
  public let image: Asset
  public let region: Region
  public let backdrop: String
  public let interaction: Interaction
  public let northUp: Bool?
  public let publishedAt: Double
  public let expiresAt: Double

  public static func contains(_ point: RemoteDrawNormalizedPoint, corners: [RemoteDrawNormalizedPoint]) -> Bool {
    guard let transform = RemoteDrawImageGeometry.placement(corners, size: CGSize(width: 1, height: 1)) else { return false }
    let local = CGPoint(x: point.x, y: point.y).applying(transform.inverted())
    return local.x >= 0 && local.x <= 1 && local.y >= 0 && local.y <= 1
  }

  /// The same inverse affine mapping as native ink, including board aspect and rotation.
  public static func phonePoint(_ point: RemoteDrawNormalizedPoint, projection: RemoteDrawProjection) -> RemoteDrawNormalizedPoint {
    let aspect = projection.coordinateAspectRatio ?? 1
    let angle = -projection.rotationDegrees * .pi / 180
    let dx = (point.x - projection.centerX) * aspect
    let dy = point.y - projection.centerY
    return .init(x: 0.5 + (dx * cos(angle) - dy * sin(angle)) / max(projection.width * aspect, 0.0001),
      y: 0.5 + (dx * sin(angle) + dy * cos(angle)) / max(projection.height, 0.0001),
      t: point.t, pressure: point.pressure, tiltX: point.tiltX, tiltY: point.tiltY)
  }
}

/// Shared native background: no streaming connection, and no second fit transform.
/// A new publication clears old pixels before loading so they cannot be registered
/// against the replacement's region. Pan/zoom only change the four projected corners.
public struct RemoteDrawStaticBackgroundView: View {
  private let descriptor: RemoteDrawStaticBackground
  private let corners: [RemoteDrawNormalizedPoint]
  private let ground: RemoteDrawGround
  @StateObject private var loader = RemoteDrawStaticImageLoader()

  public init(descriptor: RemoteDrawStaticBackground, corners: [RemoteDrawNormalizedPoint], ground: RemoteDrawGround = .whiteboard) {
    self.descriptor = descriptor
    self.corners = corners
    self.ground = ground
  }

  public var body: some View {
    GeometryReader { geometry in
      ZStack {
        if descriptor.backdrop == "surface" {
          RemoteDrawBoardCanvas(ground: ground, sections: [])
        } else { backdrop }
        if loader.descriptor == descriptor, let pixels = loader.pixels {
          if descriptor.backdrop == "blur" {
            Image(decorative: pixels, scale: 1).resizable().scaledToFill()
              .frame(width: geometry.size.width, height: geometry.size.height)
              .blur(radius: 24).clipped()
          }
          Canvas { context, size in
            guard let transform = RemoteDrawImageGeometry.placement(corners, size: size) else { return }
            context.concatenate(transform)
            context.draw(Image(decorative: pixels, scale: 1), in: CGRect(x: 0, y: 0, width: 1, height: 1))
          }
        } else if loader.failed && loader.descriptor == descriptor {
          Label("Afbeelding niet beschikbaar", systemImage: "photo.badge.exclamationmark")
            .font(.caption).foregroundStyle(.secondary)
        } else {
          ProgressView().accessibilityLabel("Afbeelding laden")
        }
      }
      .clipped()
    }
    .allowsHitTesting(false)
    .task(id: descriptor) { await loader.load(descriptor) }
  }

  private var backdrop: Color {
    let value = descriptor.backdrop
    let hex = value.count == 4 && value.hasPrefix("#") ? "#" + value.dropFirst().map { "\($0)\($0)" }.joined() : value
    guard hex.hasPrefix("#"), hex.count == 7, let rgb = UInt32(hex.dropFirst(), radix: 16) else { return .white }
    return Color(red: Double((rgb >> 16) & 255) / 255,
      green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
  }
}

/// Publication-scoped pixels; a late old request can never overwrite a new one.
@MainActor
final class RemoteDrawStaticImageLoader: ObservableObject {
  @Published private(set) var descriptor: RemoteDrawStaticBackground?
  @Published private(set) var pixels: CGImage?
  @Published private(set) var failed = false
  private var generation = 0

  func load(_ next: RemoteDrawStaticBackground,
    fetch: (RemoteDrawImageRequest) async throws -> BoardImagePixels = {
      try await RemoteDrawBoardImageStore.fetch($0, cachePolicy: .reloadIgnoringLocalCacheData)
    }) async {
    generation += 1
    let current = generation
    descriptor = next
    pixels = nil
    failed = false
    do {
      guard !next.region.corners.isEmpty else { throw URLError(.badURL) }
      let result = try await fetch(.init(url: next.image.url, maxPixelSize: 2048))
      guard !Task.isCancelled, generation == current else { return }
      pixels = result.image
    } catch {
      guard !Task.isCancelled, generation == current else { return }
      failed = true
    }
  }
}
