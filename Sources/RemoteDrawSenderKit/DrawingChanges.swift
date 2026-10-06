import Foundation

/// The answer to `POST /v1/sender/drawings` sent with `since` (incremental
/// sync). A server that predates `since` answers `{ session, items }` only,
/// which decodes here with every delta field `nil`.
struct RemoteDrawDrawingChangesAnswer: Decodable {
  /// What paint order needs of an element, read from the same `items`.
  struct Order: Decodable, Sendable {
    let id: String
    let zIndex: Double?
    let createdAt: Double?

    private enum CodingKeys: String, CodingKey { case id, zIndex, createdAt }

    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: CodingKeys.self)
      id = try c.decode(String.self, forKey: .id)
      zIndex = (try? c.decodeIfPresent(Double.self, forKey: .zIndex)) ?? nil
      createdAt = (try? c.decodeIfPresent(Double.self, forKey: .createdAt)) ?? nil
    }
  }

  /// One element as held: the parsed drawing, its sort key, and its host
  /// payload (plain dialect).
  struct Entry: Sendable {
    let drawing: RemoteDrawDrawing
    let order: Order
    let item: RemoteDrawSnapshotPayload?
  }

  /// `session` and plain `items`/`payload`, exactly as a whole-list answer
  /// decodes.
  let response: RemoteDrawDrawingsResponse
  let entries: [Entry]
  let removedIds: [String]?
  let cursor: String?
  let reset: Bool?
  let activeCount: Int?
  /// Only when the request sent `pageSize`: this answer is one page of a full read.
  let nextPageToken: String?

  private enum CodingKeys: String, CodingKey { case items, removedIds, cursor, reset, activeCount, nextPageToken }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    response = try RemoteDrawDrawingsResponse(from: decoder)
    let order = try c.decode([Order].self, forKey: .items)
    let items = response.payload?.drawingItems
    let payloads = items?.count == order.count ? items : nil
    entries = zip(response.items, order).enumerated().map { index, pair in
      Entry(drawing: pair.0, order: pair.1, item: payloads?[index])
    }
    removedIds = try c.decodeIfPresent([String].self, forKey: .removedIds)
    cursor = try c.decodeIfPresent(String.self, forKey: .cursor)
    reset = try c.decodeIfPresent(Bool.self, forKey: .reset)
    activeCount = try c.decodeIfPresent(Int.self, forKey: .activeCount)
    nextPageToken = try c.decodeIfPresent(String.self, forKey: .nextPageToken)
  }

  /// This answer's `session` with `entries` as the whole board: `items` and
  /// the host `payload` both list exactly those elements, in that order, and
  /// the payload loses the delta fields. The shape a whole-list read has always
  /// published.
  func whole(_ entries: [Entry]) -> RemoteDrawDrawingsResponse {
    RemoteDrawDrawingsResponse(
      session: response.session,
      items: entries.map(\.drawing),
      payload: response.payload?.wholeDrawingsList(entries.compactMap(\.item)))
  }
}

/// What to send next: `since`, and `pageToken` while following pages.
struct RemoteDrawDrawingChangesRequest: Equatable {
  let since: String
  let pageToken: String?
}

/// One board's incremental-sync state: the drawings held and the cursor they
/// are current at, and a paged full read in progress. The SenderKit twin of
/// `RemoteDrawDrawingChangesState` in RemoteDrawKit and of
/// `applyDrawingChanges` / `createDrawingChangesReader` in
/// `@remotedraw/protocol`, rule for rule, duplicated rather than shared because
/// this package is exported on its own. All three run the shared fixtures in
/// `packages/protocol/tests/fixtures/drawingChanges.json` (a verbatim copy
/// lives in this package's test fixtures).
///
/// - `reset` replaces the board, otherwise `removedIds` go and `items` are
///   upserted.
/// - An answer with `nextPageToken` is one page of a full read: the next
///   request asks for the following page with the same `since`, and after the
///   last page (an answer to a `pageToken` without one) it asks `since` the
///   first page's cursor once more — the closing delta that settles whatever
///   changed while the pages were read. Pages are not checked against
///   `activeCount`; the closing delta is.
/// - An answer that does not add up to its `activeCount` drops the cursor and
///   asks for the whole board again; a second one in a row is accepted rather
///   than looping.
/// - An answer without `cursor` (a server that predates `since`) is a whole
///   list, returned as it was served, and no cursor is kept.
///
/// A failed read never changes the board, and a paged read that fails part
/// way starts over next time. A malformed request or a token or session that
/// is gone (`refusesDrawingsRequest`: `400 invalid_request`, `401`, `404`,
/// `410`) drops the cursor, so the next read is a full one. Any other failure
/// (capacity and billing refusals included) keeps the cursor for up to
/// `cursorAttempts` failures in a row.
///
/// A reference type so that copies of the (value-type) transport share it.
/// Reads are not serialized. Instead an answer is applied only if it answers
/// the request the state asks for now. If another read got there first, the
/// caller gets the board as that read left it, which is a consistent (at most
/// one poll older) snapshot.
///
/// A session with annotation input always answers `reset` whole (the phone's
/// view is filtered by placement, and never paged), which this handles like
/// any other reset.
final class RemoteDrawDrawingChangesState: @unchecked Sendable {
  typealias Entry = RemoteDrawDrawingChangesAnswer.Entry

  enum Outcome {
    /// The whole board after the answer, in paint order (or, for an older
    /// server's whole list, the answer as it was served).
    case board(RemoteDrawDrawingsResponse)
    /// More to read before there is a board (the next page, the closing
    /// delta, or the whole board again after a mismatch): ask `request(for:)`.
    case more
  }

  /// Failed reads in a row from one cursor before it is dropped
  /// (`DRAWING_CHANGES_CURSOR_ATTEMPTS`).
  static let cursorAttempts = 3
  /// Requests one read may make (`DRAWING_CHANGES_MAX_REQUESTS`).
  static let maxRequests = 64
  /// Items per page a read asks for (`DRAWINGS_PAGE_SIZE`).
  static let pageSize = 1000

  private struct Pending {
    let cursor: String
    let board: [String: Entry]
    let pageToken: String?
  }

  private let lock = NSLock()
  private var key: String?
  private var cursor: String?
  private var board: [String: Entry] = [:]
  private var pending: Pending?
  /// Answers in a row that did not add up to their `activeCount`.
  private var mismatches = 0
  /// Failed reads in a row from the cursor held.
  private var failures = 0

  /// Starts a read of this board: the cursor held now (nil: none), which
  /// `failed` compares against. A different key (another sender token)
  /// starts over.
  func begin(key: String) -> String? {
    lock.lock()
    defer { lock.unlock() }
    if self.key != key {
      self.key = key
      forget()
    }
    return cursor
  }

  /// What to send next for this board.
  func request(for key: String) -> RemoteDrawDrawingChangesRequest {
    lock.lock()
    defer { lock.unlock() }
    guard self.key == key else { return RemoteDrawDrawingChangesRequest(since: "", pageToken: nil) }
    return currentRequest()
  }

  /// Call with the lock held.
  private func currentRequest() -> RemoteDrawDrawingChangesRequest {
    if let pending {
      return RemoteDrawDrawingChangesRequest(since: pending.cursor, pageToken: pending.pageToken)
    }
    return RemoteDrawDrawingChangesRequest(since: cursor ?? "", pageToken: nil)
  }

  /// A request of a read that `begin` returned `held` for failed (`refused`:
  /// the server refused it rather than it being lost on the way).
  func failed(key: String, held: String?, refused: Bool) {
    lock.lock()
    defer { lock.unlock() }
    guard self.key == key else { return }
    pending = nil
    guard let held, cursor == held else { return }
    failures += 1
    if refused || failures >= Self.cursorAttempts { forget() }
  }

  /// A read that made `maxRequests` requests without a board: start over next time.
  func abandon(key: String) {
    lock.lock()
    defer { lock.unlock() }
    if self.key == key { pending = nil }
  }

  /// Call with the lock held.
  private func forget() {
    cursor = nil
    board = [:]
    pending = nil
    mismatches = 0
    failures = 0
  }

  func apply(
    _ answer: RemoteDrawDrawingChangesAnswer, key: String, request: RemoteDrawDrawingChangesRequest
  ) -> Outcome {
    lock.lock()
    defer { lock.unlock() }
    guard let nextCursor = answer.cursor, let reset = answer.reset else {
      // A server without `since`: a whole list, and no cursor to keep.
      if self.key == key { forget() }
      return .board(answer.response)
    }
    guard self.key == key, currentRequest() == request else {
      return .board(answer.whole(Self.painted(board.values)))
    }
    failures = 0
    var next = reset ? [:] : (pending?.board ?? board)
    if !reset {
      for id in answer.removedIds ?? [] { next.removeValue(forKey: id) }
    }
    for entry in answer.entries { next[entry.drawing.id] = entry }
    let pageToken = answer.nextPageToken.flatMap { $0.isEmpty ? nil : $0 }
    // A page: more to come, or (the last one answering a `pageToken`) the
    // closing delta. A first page that is also the last is a whole board.
    if pageToken != nil || (request.pageToken != nil && !reset) {
      pending = Pending(cursor: nextCursor, board: next, pageToken: pageToken)
      return .more
    }
    if let activeCount = answer.activeCount, activeCount != next.count, mismatches == 0 {
      // Something was missed. Start over.
      forget()
      mismatches = 1
      return .more
    }
    board = next
    cursor = nextCursor
    pending = nil
    mismatches = 0
    return .board(answer.whole(Self.painted(next.values)))
  }

  /// Back to front: `zIndex` (absent or non-finite is 0), then `createdAt`,
  /// then `id` compared by UTF-16 code unit, which is how JavaScript's `<`
  /// compares strings (`compareDrawingZOrder`). The same comparator as
  /// RemoteDrawKit's `RemoteDrawDrawingChangesState.painted`.
  static func painted<S: Sequence>(_ entries: S) -> [Entry] where S.Element == Entry {
    entries.sorted { a, b in
      let za = a.order.zIndex.flatMap { $0.isFinite ? $0 : nil } ?? 0
      let zb = b.order.zIndex.flatMap { $0.isFinite ? $0 : nil } ?? 0
      if za != zb { return za < zb }
      let ca = a.order.createdAt ?? 0
      let cb = b.order.createdAt ?? 0
      if ca != cb { return ca < cb }
      return a.order.id.utf16.lexicographicallyPrecedes(b.order.id.utf16)
    }
  }
}

/// The codes after which a reader drops its cursor: the request was
/// malformed, or the credentials or the session it was read with are gone.
/// Every other code keeps it. Mirrors `DRAWINGS_READ_REFUSAL_CODES` in
/// `@remotedraw/protocol`.
let drawingsReadRefusalCodes: Set<String> = [
  "invalid_request",
  "invalid_session_id",
  "missing_authorization",
  "invalid_receiver_token",
  "invalid_sender_token",
  "sender_token_expired",
  "session_not_found",
  "resource_not_found",
  "session_not_active",
]

/// The statuses of those codes, for a failure that carries no code.
let drawingsReadRefusalStatuses: Set<Int> = [400, 401, 404, 410]

extension RemoteDrawError {
  /// Whether a failed drawings read should drop its cursor: a malformed
  /// request (`400`, `invalid_request`) or a token or session that is gone
  /// (`401`, `404`, `410` and their codes). A code decides when there is one,
  /// so `409 included_capacity_exhausted`, `402` billing and `403` grants —
  /// about the account, not the cursor — keep it, as do timeouts, `429`, `5xx`
  /// and network failures. The Swift twin of `isDrawingsReadRefusal` in
  /// `@remotedraw/protocol`.
  var refusesDrawingsRequest: Bool {
    switch self {
    case .server(let status, let code, _):
      if let code, !code.isEmpty { return drawingsReadRefusalCodes.contains(code) }
      return drawingsReadRefusalStatuses.contains(status)
    // 401 (`invalid_sender_token`, `sender_token_expired`), and a board that
    // is over (410, `session_not_active`).
    case .tokenRejected, .sessionEnded, .sessionExpired:
      return true
    // 403 is a grant, not the cursor; 426 is this build, not the request.
    case .notPermitted, .sdkTooOld:
      return false
    case .rateLimited, .offline, .transport, .decoding:
      return false
    case .notConfigured, .missingInfoPlistKey, .malformedToken:
      return false
    }
  }
}
