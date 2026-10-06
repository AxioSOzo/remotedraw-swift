// The receiver draws with the sender's renderer — one `RemoteDrawInk`, not a
// vendored copy — and re-exports it, so a host writes one `import` and an app
// importing both kits sees a single `RemoteDrawNormalizedPoint`.
@_exported import RemoteDrawInk
import Foundation

/// The receiver half of the protocol, as a native client sees it.
///
/// These mirror `RemoteDrawDrawing`, `RemoteDrawDraft`, `RemoteDrawSenderRecord`
/// and the session projection in `@remotedraw/client`. Every field is optional
/// except the ones the server has always sent, because a receiver that fails to
/// decode a response drops the whole poll — a forward-compatible decode is worth
/// more here than a strict one.
///
/// Note that `packedPoints` deliberately has no Swift decoder: the server
/// unpacks in `drawingPoints()` before it serialises, so receiver responses only
/// ever carry plain `points`. The packed codec is a write-path concern.
public enum RemoteDrawReceiver {}

/// Session id plus receiver token. Every receiver route takes both, in the body
/// rather than in an `Authorization` header.
public struct RemoteDrawReceiverCredentials: Equatable, Sendable, Codable {
  public let sessionId: String
  public let receiverToken: String

  public init(sessionId: String, receiverToken: String) {
    self.sessionId = sessionId
    self.receiverToken = receiverToken
  }
}

public struct RemoteDrawCoordinateSpace: Codable, Equatable, Sendable {
  public let width: Double?
  public let height: Double?

  public init(width: Double?, height: Double?) {
    self.width = width
    self.height = height
  }
}

public struct RemoteDrawReceiverTarget: Codable, Equatable, Sendable {
  public let kind: String?
  public let inputMapping: String?
  public let coordinateSpace: RemoteDrawCoordinateSpace?
  /// The board's human name. Already on the wire — the server passes `target`
  /// through whole — but previously dropped on the floor here, which is why a
  /// native client had nothing to title a board with.
  public let label: String?
}

public struct RemoteDrawReceiverSession: Codable, Equatable, Sendable {
  public let id: String
  public let status: String?
  public let target: RemoteDrawReceiverTarget?
  public let capabilities: [String]?
  public let drawingCount: Int?
  public let createdAt: Double?
  public let expiresAt: Double?
  public let endedAt: Double?

  public var isActive: Bool { (status ?? "active") == "active" }
}

/// A committed stroke.
public struct RemoteDrawReceiverDrawing: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let hidden: Bool?
  public let sessionId: String?
  public let senderId: String?
  public let clientStrokeId: String?
  public let sequence: Int?
  public let type: String
  public let tool: String?
  public let pointerType: String?
  public let style: RemoteDrawDrawingStyle?
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let occurredAt: Double?
  public let createdAt: Double?
  public let updatedAt: Double?
}

/// A stroke still under the finger. Drafts are ephemeral: the server deletes one
/// in the same transaction that inserts its committed stroke.
public struct RemoteDrawReceiverDraft: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let sessionId: String?
  public let senderId: String?
  public let sequence: Int?
  public let pointerType: String?
  public let pointerId: String?
  public let tool: String?
  public let style: RemoteDrawDrawingStyle?
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let occurredAt: Double?
  public let updatedAt: Double?
}

public struct RemoteDrawReceiverSenderRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let senderId: String?
  public let status: String?
  public let presence: String?
  public let connectedAt: Double?
  public let lastSeenAt: Double?

  public var isActive: Bool { (status ?? "active") == "active" }

  /// Token validity and device presence are different: an active sender can
  /// stop heartbeating. Match the protocol's 60-second presence window.
  public func isPresent(at date: Date = .now) -> Bool {
    guard isActive, presence == nil || presence == "present" else { return false }
    guard let lastSeenAt else { return true }
    return date.timeIntervalSince1970 * 1000 - lastSeenAt <= 60_000
  }
}

/// Everything a receiver knows at one instant.
public struct RemoteDrawReceiverSnapshot: Equatable, Sendable {
  public var session: RemoteDrawReceiverSession?
  public var drawings: [RemoteDrawReceiverDrawing]
  public var drafts: [RemoteDrawReceiverDraft]
  public var senders: [RemoteDrawReceiverSenderRecord]

  public init(
    session: RemoteDrawReceiverSession? = nil,
    drawings: [RemoteDrawReceiverDrawing] = [],
    drafts: [RemoteDrawReceiverDraft] = [],
    senders: [RemoteDrawReceiverSenderRecord] = []
  ) {
    self.session = session
    self.drawings = drawings
    self.drafts = drafts
    self.senders = senders
  }

  public var isEmpty: Bool { drawings.isEmpty && drafts.isEmpty }

  /// Image and future drawing types are retained in state but require a host
  /// renderer; feeding them to the ink painter would invent a connecting line.
  public var visibleInkDrawings: [RemoteDrawReceiverDrawing] {
    let supported = Set(["point", "line", "arrow", "freehand", "rectangle", "ellipse", "text"])
    return drawings.filter { $0.hidden != true && supported.contains($0.type) }
  }
}
