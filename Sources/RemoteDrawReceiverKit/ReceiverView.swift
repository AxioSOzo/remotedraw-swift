import SwiftUI
import CoreImage.CIFilterBuiltins

/// A native QR code for the scoped, expiring join URL. No external service
/// receives the URL; Core Image generates its pixels entirely on device.
public struct RemoteDrawReceiverQRCode: View {
  public let url: URL
  public init(url: URL) { self.url = url }

  public var body: some View {
    if let image = Self.image(for: url) {
      Image(decorative: image, scale: 1)
        .interpolation(.none).resizable().scaledToFit()
        .frame(width: 144, height: 144).padding(12).background(.white)
        .accessibilityLabel("Scan this QR code with your phone to pair")
    }
  }

  static func image(for url: URL) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(url.absoluteString.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    return CIContext().createCGImage(scaled, from: scaled.extent)
  }
}

/// Development receiver for normalized drawing surfaces. Map/world projection
/// and visual streaming require a host-specific renderer.
@MainActor
public struct RemoteDrawReceiverBoard: View {
  @ObservedObject private var store: RemoteDrawReceiverStore
  @ObservedObject private var groundCache = RemoteDrawGroundCache.shared

  public init(store: RemoteDrawReceiverStore) { self.store = store }

  public var body: some View {
    let ground = RemoteDrawGround.forProtocolSurface(store.snapshot.session?.target?.kind)
    let strokes = store.snapshot.visibleInkDrawings.map {
      RemoteDrawStrokePainter.Stroke(points: $0.points, type: $0.type, text: $0.text, style: $0.style)
    } + store.snapshot.drafts.map {
      RemoteDrawStrokePainter.Stroke(points: $0.points, type: $0.tool ?? "freehand", text: $0.text, style: $0.style)
    }
    let _ = groundCache.revision
    Canvas { context, size in
      guard size.width > 0, size.height > 0 else { return }
      context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(ground.flatColor))
      if let tile = ground.tile {
        context.fill(Path(CGRect(origin: .zero, size: size)), with: .tiledImage(Image(decorative: tile, scale: 1)))
      }
      // Wire widths use a 1000-unit-high page, shared with the native receiver.
      let scale = size.height / 1000
      context.scaleBy(x: scale, y: scale)
      let page = CGSize(width: size.width / scale, height: 1000)
      RemoteDrawInkComposer.draw(strokes, in: &context, size: page, surface: ground.surfaceKind,
        film: { RemoteDrawInkComposer.film(forType: $0.type, pointCount: $0.points.count, style: $0.style, surface: ground.surfaceKind) },
        paint: { stroke, layer in
          RemoteDrawStrokePainter.draw(stroke, in: &layer, size: page, surface: ground.surfaceKind,
            dynamicsScale: CGSize(width: size.width / max(size.width, size.height), height: size.height / max(size.width, size.height)))
        })
    }
    .clipped()
    .task { ground.prepare() }
    .accessibilityLabel("RemoteDraw drawing surface")
  }
}

/// Pairing and board controls. Start/stop the store in the host lifecycle.
@MainActor
public struct RemoteDrawReceiverView: View {
  @ObservedObject private var store: RemoteDrawReceiverStore
  private let control: any RemoteDrawReceiverControl
  @State private var join: RemoteDrawJoinTokenResult?
  @State private var failure: String?
  @State private var issuing = false

  public init(store: RemoteDrawReceiverStore, control: any RemoteDrawReceiverControl) {
    self.store = store
    self.control = control
  }

  public var body: some View {
    VStack(spacing: 12) {
      HStack {
        Text("RemoteDraw · In development").font(.headline)
        Spacer()
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
          Text("\(store.snapshot.senders.filter { $0.isPresent(at: timeline.date) }.count) connected")
        }
      }
      GeometryReader { geometry in
        RemoteDrawReceiverBoard(store: store)
          .task(id: SurfaceKey(size: geometry.size, session: store.credentials?.sessionId)) {
            guard let credentials = store.credentials, geometry.size.width > 0, geometry.size.height > 0 else { return }
            do {
              try await Task.sleep(nanoseconds: 250_000_000)
              try Task.checkCancellation()
              try await control.updateSurface(credentials, width: Int(geometry.size.width.rounded()), height: Int(geometry.size.height.rounded()))
            } catch is CancellationError {} catch { failure = error.localizedDescription }
          }
      }
      HStack {
        Button("Pair phone") { Task { await pair() } }.disabled(issuing || store.credentials == nil || store.isTerminated)
        Button("Undo") { Task { await store.undo() } }.disabled(store.credentials == nil || store.isTerminated)
        Button("Clear") { Task { await store.clear() } }.disabled(store.credentials == nil || store.isTerminated)
        Button("End session") {
          Task {
            guard let credentials = store.credentials else { return }
            do { try await control.endSession(credentials); store.stop(); join = nil }
            catch { failure = error.localizedDescription }
          }
        }.disabled(store.credentials == nil)
      }
      TimelineView(.periodic(from: .now, by: 1)) { timeline in
        pairingDetails(at: timeline.date)
      }
      if store.isTerminated { Text("Session ended or credentials expired.").foregroundStyle(.red) }
      if let error = failure ?? store.lastError.map({ String(describing: $0) }) {
        Text(error).font(.caption).foregroundStyle(.red)
      }
    }
    .onChange(of: store.credentials) { _, _ in join = nil; failure = nil }
  }

  @ViewBuilder
  private func pairingDetails(at date: Date) -> some View {
        if let join {
          if let expiry = join.expiryDate, expiry <= date {
            Text("Pairing code expired. Tap Pair phone for a new code.")
          } else {
            if let token = join.joinToken { Text(token).font(.title.monospaced()).textSelection(.enabled) }
            if let raw = join.joinUrl, let url = URL(string: raw), ["https", "http"].contains(url.scheme) {
              RemoteDrawReceiverQRCode(url: url)
              ShareLink("Share pairing link", item: url)
              Text(raw).font(.caption).textSelection(.enabled)
            }
          }
        }
  }

  private struct SurfaceKey: Hashable {
    let width: Int
    let height: Int
    let session: String?
    init(size: CGSize, session: String?) {
      width = Int(size.width.rounded()); height = Int(size.height.rounded()); self.session = session
    }
  }

  private func pair() async {
    guard let credentials = store.credentials else { return }
    issuing = true
    defer { issuing = false }
    do {
      let result = try await control.issueJoinToken(credentials, capabilities: nil)
      guard store.credentials == credentials else { return }
      join = result
      failure = nil
    } catch { failure = error.localizedDescription }
  }
}
