import SwiftUI
import ImageIO

/// Reconstruct the board rectangle before any view projection. Wire points
/// already contain the element edit transform; applying it again is incorrect.
public enum RemoteDrawImageGeometry {
  public static func corners(_ points: [RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint] {
    guard let first = points.first, let last = points.last,
      [first.x, first.y, last.x, last.y].allSatisfy({ $0.isFinite }) else { return [] }
    let left = min(first.x, last.x), right = max(first.x, last.x)
    let top = min(first.y, last.y), bottom = max(first.y, last.y)
    guard left < right, top < bottom else { return [] }
    return [.init(x: left, y: top), .init(x: right, y: top),
      .init(x: right, y: bottom), .init(x: left, y: bottom)]
  }

  static func placement(_ points: [RemoteDrawNormalizedPoint], size: CGSize) -> CGAffineTransform? {
    guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
    let a = points[1].x - points[0].x, b = points[1].y - points[0].y
    let c = points[3].x - points[0].x, d = points[3].y - points[0].y
    guard abs(a * d - b * c) > 1e-12 else { return nil }
    return CGAffineTransform(a: a * size.width, b: b * size.height,
      c: c * size.width, d: d * size.height,
      tx: points[0].x * size.width, ty: points[0].y * size.height)
  }

  static func pixelBudget(_ points: [RemoteDrawNormalizedPoint], size: CGSize, scale: Double = 1) -> Int? {
    guard let transform = placement(points, size: size), scale.isFinite else { return nil }
    let edge = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d)) * 2 * abs(scale)
    return [256, 512, 1024, 2048].first { Double($0) >= edge } ?? 2048
  }

  static func visible(_ points: [RemoteDrawNormalizedPoint]) -> Bool {
    guard points.count == 4 else { return false }
    return points.map(\.x).max()! > 0 && points.map(\.x).min()! < 1
      && points.map(\.y).max()! > 0 && points.map(\.y).min()! < 1
  }
}

struct RemoteDrawImageRequest: Hashable {
  let url: String
  let maxPixelSize: Int
}

final class BoardImagePixels: @unchecked Sendable {
  let image: CGImage
  init(_ image: CGImage) { self.image = image }
}

/// Only visible images are requested, at most four at a time. ImageIO downsamples
/// before decoding; the cache has a 64 MiB cost budget and encoded assets a 32 MiB
/// limit. No full-board bitmap or unbounded full-resolution decode is created.
@MainActor
final class RemoteDrawBoardImageStore: ObservableObject {
  @Published private(set) var images: [RemoteDrawImageRequest: CGImage] = [:]
  @Published private(set) var failures: Set<RemoteDrawImageRequest> = []
  private static let cache: NSCache<NSString, BoardImagePixels> = {
    let cache = NSCache<NSString, BoardImagePixels>()
    cache.totalCostLimit = 64 * 1024 * 1024
    return cache
  }()

  func load(_ requests: [RemoteDrawImageRequest]) async {
    let desired = Set(requests)
    images = images.filter { desired.contains($0.key) }
    failures = failures.intersection(desired)
    let pending = requests.filter { images[$0] == nil }
    for start in stride(from: 0, to: pending.count, by: 4) {
      guard !Task.isCancelled else { return }
      let batch = Array(pending[start..<min(start + 4, pending.count)])
      await withTaskGroup(of: (RemoteDrawImageRequest, BoardImagePixels?).self) { group in
        for request in batch {
          let key = "\(request.maxPixelSize):\(request.url)" as NSString
          if let cached = Self.cache.object(forKey: key) {
            retain(cached.image, for: request)
          } else {
            group.addTask { (request, try? await Self.fetch(request)) }
          }
        }
        for await (request, result) in group {
          guard !Task.isCancelled else { continue }
          if let result {
            guard retain(result.image, for: request) else { continue }
            Self.cache.setObject(result, forKey: "\(request.maxPixelSize):\(request.url)" as NSString,
              cost: result.image.bytesPerRow * result.image.height)
          } else { failures.insert(request) }
        }
      }
    }
  }

  @discardableResult
  private func retain(_ image: CGImage, for request: RemoteDrawImageRequest) -> Bool {
    let retainedBytes = images.values.reduce(0) { $0 + $1.bytesPerRow * $1.height }
    guard retainedBytes + image.bytesPerRow * image.height <= 64 * 1024 * 1024 else {
      failures.insert(request)
      return false
    }
    images[request] = image
    failures.remove(request)
    return true
  }

  nonisolated static func fetch(_ request: RemoteDrawImageRequest, cachePolicy: URLRequest.CachePolicy = .useProtocolCachePolicy) async throws -> BoardImagePixels {
    guard let url = URL(string: request.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw URLError(.badURL) }
    var urlRequest = URLRequest(url: url, cachePolicy: cachePolicy)
    urlRequest.timeoutInterval = 20
    let (bytes, response) = try await URLSession.shared.bytes(for: urlRequest)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      response.expectedContentLength <= 32 * 1024 * 1024 else { throw URLError(.badServerResponse) }
    var data = Data()
    for try await byte in bytes {
      try Task.checkCancellation()
      guard data.count < 32 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
      data.append(byte)
    }
    return try decode(data, maxPixelSize: request.maxPixelSize)
  }

  nonisolated static func decode(_ data: Data, maxPixelSize: Int) throws -> BoardImagePixels {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: max(1, min(2048, maxPixelSize)),
        kCGImageSourceShouldCacheImmediately: true,
      ] as CFDictionary) else { throw URLError(.cannotDecodeContentData) }
    return BoardImagePixels(image)
  }
}
