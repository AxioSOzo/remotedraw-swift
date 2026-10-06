import Foundation

/// What a sender needs from the network.
///
/// A protocol so the session can be driven by a fake in tests — every lifecycle
/// rule in ``RemoteDrawSenderSession`` (sequence healing, presence, re-join,
/// clean exit) is verifiable without a socket — and so a reactive
/// implementation could replace the polling one without the drawing code
/// noticing.
public protocol RemoteDrawSenderTransport: Sendable {
  func join(joinToken: String, device: RemoteDrawSenderDevice?) async throws
    -> RemoteDrawJoinResponse
  func session(senderToken: String) async throws -> RemoteDrawSessionResponse
  func ping(senderToken: String, active: Bool) async throws
  func updateDraft(_ request: RemoteDrawDraftRequest) async throws -> RemoteDrawDraftAck
  func commitStroke(_ request: RemoteDrawCommitRequest) async throws -> RemoteDrawCommitResult
  func replaceStroke(_ request: RemoteDrawReplaceRequest) async throws -> RemoteDrawReplaceResult
  func clearDraft(senderToken: String, sequence: Int?) async throws
  func undo(senderToken: String) async throws -> RemoteDrawUndoResult
  func clear(senderToken: String) async throws -> RemoteDrawClearResult
  func submit(senderToken: String, clientSubmissionId: String, metadata: [String: RemoteDrawJSONValue]?)
    async throws -> RemoteDrawReceipt
  /// Moves or deletes elements already on the board.
  ///
  /// One route for every arm of the union, because the mutation behind it is one
  /// call — and because a compound gesture stays one atomic edit with one undo.
  /// Undo needs no route of its own: `/v1/sender/undo` reverses moves and
  /// deletes through the same journal that reverses strokes.
  ///
  /// **A 200 does not mean the edit landed.** Read
  /// ``RemoteDrawEditResult/accepted``.
  func editElements(senderToken: String, edit: RemoteDrawElementEdit) async throws
    -> RemoteDrawEditResult

  func drawings(senderToken: String) async throws -> RemoteDrawDrawingsResponse
  func updateProjection(senderToken: String, projection: RemoteDrawProjection) async throws
    -> RemoteDrawProjection
  /// Rotates the sender token.
  ///
  /// **Not idempotent, and that is the whole design of it.** The old token dies
  /// the instant the response is minted, so a response lost in flight costs the
  /// client its credential outright — there is nothing left to retry *with*.
  /// Never put this in a blind-retry set: a second attempt with the token you
  /// just spent is guaranteed to 401, and the only honest recovery from a lost
  /// response is a fresh token from outside the SDK.
  ///
  /// It also **buys no time**. Refresh re-syncs the token's expiry to the
  /// session's; it never extends the session. A client that refreshes on a
  /// timer to stay alive is spending its 10/min budget to achieve nothing.
  /// Rare and event-driven — on a rejected credential — is the only correct
  /// cadence.
  func refresh(senderToken: String) async throws -> RemoteDrawRefreshResponse

  /// Closes the phone's window on the board.
  ///
  /// - Parameter disconnect: `true` is the app's "Leave session". Presence is a
  ///   heartbeat, not a leave signal — a phone that simply stops pinging shows
  ///   as connected for up to the receiver's 60 s window, so an SDK that exits
  ///   cleanly must call this or the customer's board lies about who is there.
  func closeProjection(senderToken: String, disconnect: Bool) async throws

  /// Reads the board's revision tokens: `POST /v1/sender/sync`.
  ///
  /// The session polls this about once a second and reads a snapshot only when
  /// a token moved. A transport that cannot answer must throw
  /// ``RemoteDrawSyncUnsupportedError`` — the default does — and the session
  /// falls back to unconditional snapshots every five seconds. Any other error
  /// is a transient failure and the next tick retries.
  func sync(senderToken: String) async throws -> RemoteDrawSyncRevisions
}

/// Thrown by a transport that has no `/v1/sender/sync`.
///
/// Its own type rather than a ``RemoteDrawError`` case, because it is a
/// statement about the transport and never about the session: nothing recovers
/// from it, and the session only uses it to choose the legacy snapshot cadence.
public struct RemoteDrawSyncUnsupportedError: Error, Equatable, Sendable {
  public init() {}
}

extension RemoteDrawSenderTransport {
  /// Custom transports written before sync existed keep compiling and keep
  /// working, on the slower snapshot cadence.
  public func sync(senderToken: String) async throws -> RemoteDrawSyncRevisions {
    throw RemoteDrawSyncUnsupportedError()
  }
}

// MARK: - Requests

/// The body of `/v1/sender/draft`.
///
/// Points travel as ``packedPoints`` — base64url columnar delta + zigzag
/// varint, ~13x smaller than the JSON array it replaces. There is no
/// plain-`points` path in this SDK on purpose: a second wire dialect is how
/// clients drift apart, and the 32 KiB draft ceiling arrives far sooner in JSON.
public struct RemoteDrawDraftRequest: Encodable, Sendable {
  public let senderToken: String
  public let sequence: Int
  public let pointerType: String
  public let tool: String
  public let style: RemoteDrawDrawingStyle?
  public let packedPoints: String
  public let text: String?
  public let phoneProjection: RemoteDrawProjection?
  public let annotationRevision: Int?
  public let occurredAt: Double

  public init(
    senderToken: String,
    sequence: Int,
    tool: RemoteDrawTool = .auto,
    points: [RemoteDrawNormalizedPoint],
    style: RemoteDrawDrawingStyle? = nil,
    text: String? = nil,
    phoneProjection: RemoteDrawProjection? = nil,
    annotationRevision: Int? = nil,
    pointerType: String = "touch",
    occurredAt: Double = Date().timeIntervalSince1970 * 1000
  ) {
    self.senderToken = senderToken
    self.sequence = max(0, sequence)
    self.pointerType = pointerType
    self.tool = tool.rawValue
    self.style = style
    // Decimated, never truncated: a `suffix` makes a long stroke look like it
    // erases itself from the start while the pen is still down.
    self.packedPoints = PointCodec.pack(
      RemoteDrawStrokeBudget.forDraft(points, limit: RemoteDrawProtocolLimits.maxDraftPoints))
    self.text = text.map { String($0.prefix(RemoteDrawProtocolLimits.maxTextLength)) }
    self.phoneProjection = phoneProjection
    self.annotationRevision = annotationRevision
    self.occurredAt = occurredAt.rounded(.down)
  }
}

/// The body of `/v1/sender/commit`.
///
/// `clientStrokeId` is the idempotency key: commits deduplicate on
/// `(sessionId, senderId, clientStrokeId)` and a replay answers
/// `duplicate: true`, which is what makes retrying a timed-out commit safe.
public struct RemoteDrawCommitRequest: Encodable, Sendable {
  public internal(set) var senderToken: String
  public let clientStrokeId: String
  public let sequence: Int
  public let pointerType: String
  public let tool: String
  public let style: RemoteDrawDrawingStyle?
  public let packedPoints: String
  public let text: String?
  public let phoneProjection: RemoteDrawProjection?
  public let annotationRevision: Int?
  public let occurredAt: Double

  public init(
    senderToken: String,
    clientStrokeId: String,
    sequence: Int,
    tool: RemoteDrawTool = .auto,
    points: [RemoteDrawNormalizedPoint],
    style: RemoteDrawDrawingStyle? = nil,
    text: String? = nil,
    phoneProjection: RemoteDrawProjection? = nil,
    annotationRevision: Int? = nil,
    pointerType: String = "touch",
    occurredAt: Double = Date().timeIntervalSince1970 * 1000
  ) {
    self.senderToken = senderToken
    self.clientStrokeId = String(
      clientStrokeId.prefix(RemoteDrawProtocolLimits.maxClientStrokeIdLength))
    self.sequence = max(0, sequence)
    self.pointerType = pointerType
    self.tool = tool.rawValue
    self.style = style
    // Thinned rather than tail-clipped: `suffix` silently drops where the
    // stroke began, which no receiver can recover.
    self.packedPoints = PointCodec.pack(
      RemoteDrawStrokeBudget.thin(points, limit: RemoteDrawProtocolLimits.maxCommitPoints))
    self.text = text.map { String($0.prefix(RemoteDrawProtocolLimits.maxTextLength)) }
    self.phoneProjection = phoneProjection
    self.annotationRevision = annotationRevision
    self.occurredAt = occurredAt.rounded(.down)
  }
}

/// The body of `/v1/sender/replace` — the route behind "snap that to a circle".
public struct RemoteDrawReplaceRequest: Encodable, Sendable {
  public let senderToken: String
  public let strokeId: String
  public let tool: String
  public let style: RemoteDrawDrawingStyle?
  public let packedPoints: String

  public init(
    senderToken: String,
    strokeId: String,
    tool: String,
    points: [RemoteDrawNormalizedPoint],
    style: RemoteDrawDrawingStyle? = nil
  ) {
    self.senderToken = senderToken
    self.strokeId = strokeId
    self.tool = tool
    self.style = style
    self.packedPoints = PointCodec.pack(
      RemoteDrawStrokeBudget.thin(points, limit: RemoteDrawProtocolLimits.maxCommitPoints))
  }
}

// MARK: - HTTP

/// Where the SDK talks to.
public enum RemoteDrawAPIBaseURL: Equatable, Sendable {
  case production
  case custom(URL)

  public var url: URL {
    switch self {
    case .production: return URL(string: "https://api.remotedraw.com")!
    case .custom(let url): return url
    }
  }
}

/// The sixteen sender routes (``RemoteDrawSenderRoute``) over HTTPS.
///
/// The only thing in the package that knows a network exists.
public struct RemoteDrawSenderHTTPTransport: RemoteDrawSenderTransport {
  public let baseURL: URL
  private let session: URLSession
  private let sdkVersion: String
  private let appDeviceToken: (@Sendable () -> String?)?
  private let advisories: RemoteDrawAdvisoryReporter
  private let decoder = JSONDecoder()
  /// Incremental-sync state for the board being read (shared by copies).
  private let drawingChanges = RemoteDrawDrawingChangesState()

  /// - Parameter appDeviceToken: a RemoteDraw **account** credential, forwarded
  ///   verbatim on `/v1/join` and on no other route.
  ///
  ///   It is on the transport and deliberately **not** on
  ///   ``RemoteDrawConfiguration``, because §6.6 of the design settled that this
  ///   SDK authenticates no end user, and a field in the twelve-line
  ///   integration would say the opposite. There is no third-party use for it:
  ///   an SDK host has no RemoteDraw account for their user to have, and leaving
  ///   it `nil` — the default — sends the historical body with the key absent.
  ///
  ///   What it is for is the seam the first-party app needs. That app signs a
  ///   person in with Clerk, keeps the resulting app-device token in the
  ///   keychain, and passes it on join so the board lands in that account's
  ///   history. None of that is the SDK's: it does not mint this token, store
  ///   it, read it, refresh it, retry with it, or notice when it is rejected —
  ///   a join that fails on account grounds is a join failure like any other.
  ///   It forwards a string a host already had.
  ///
  ///   A closure rather than a value because the app signs in and out while the
  ///   transport lives, and a captured `String?` would go stale at the first
  ///   sign-in.
  /// - Parameter onClientAdvisory: called once when the API reports that this
  ///   SDK build is being retired or has been refused. See
  ///   ``RemoteDrawClientAdvisory``. Never called more than once for the same
  ///   advisory, whatever the request rate. Advisories are written to the
  ///   unified log with or without a handler.
  public init(
    baseURL: RemoteDrawAPIBaseURL = .production,
    urlSession: URLSession? = nil,
    sdkVersion: String = RemoteDraw.sdkVersion,
    appDeviceToken: (@Sendable () -> String?)? = nil,
    onClientAdvisory: (@Sendable (RemoteDrawClientAdvisory) -> Void)? = nil
  ) {
    self.baseURL = baseURL.url
    self.sdkVersion = sdkVersion
    self.appDeviceToken = appDeviceToken
    self.advisories = RemoteDrawAdvisoryReporter(handler: onClientAdvisory)
    if let urlSession {
      self.session = urlSession
    } else {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.timeoutIntervalForRequest = 15
      configuration.timeoutIntervalForResource = 30
      configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      configuration.waitsForConnectivity = true
      self.session = URLSession(configuration: configuration)
    }
  }

  // MARK: Routes

  public func join(joinToken: String, device: RemoteDrawSenderDevice?) async throws
    -> RemoteDrawJoinResponse
  {
    struct Body: Encodable {
      let joinToken: String
      let device: RemoteDrawSenderDevice?
      /// Absent, not null, when there is none — `Encodable` drops a nil
      /// `Optional`, which is what keeps an anonymous join byte-identical to
      /// the body this route has always received.
      let appDeviceToken: String?
    }
    return try await post(
      .join,
      body: Body(joinToken: joinToken, device: device, appDeviceToken: appDeviceToken?()))
  }

  public func session(senderToken: String) async throws -> RemoteDrawSessionResponse {
    try await post(.session, body: TokenBody(senderToken: senderToken))
  }

  public func ping(senderToken: String, active: Bool) async throws {
    struct Body: Encodable {
      let senderToken: String
      /// Omitted when false, matching the first-party app: the server reads the
      /// key's presence, and sending `false` is not the same as not sending it.
      let active: Bool?
    }
    _ = try await postRaw(.ping, body: Body(senderToken: senderToken, active: active ? true : nil))
  }

  public func updateDraft(_ request: RemoteDrawDraftRequest) async throws -> RemoteDrawDraftAck {
    try await post(.draft, body: request)
  }

  public func commitStroke(_ request: RemoteDrawCommitRequest) async throws
    -> RemoteDrawCommitResult
  {
    // Answered 201, not 200 — see the success range in `postRaw`.
    try await post(.commit, body: request)
  }

  public func replaceStroke(_ request: RemoteDrawReplaceRequest) async throws
    -> RemoteDrawReplaceResult
  {
    try await post(.replace, body: request)
  }

  public func clearDraft(senderToken: String, sequence: Int?) async throws {
    struct Body: Encodable {
      let senderToken: String
      let sequence: Int?
    }
    _ = try await postRaw(.clearDraft, body: Body(senderToken: senderToken, sequence: sequence))
  }

  public func undo(senderToken: String) async throws -> RemoteDrawUndoResult {
    try await post(.undo, body: TokenBody(senderToken: senderToken))
  }

  public func clear(senderToken: String) async throws -> RemoteDrawClearResult {
    try await post(.clear, body: TokenBody(senderToken: senderToken))
  }

  public func submit(
    senderToken: String,
    clientSubmissionId: String,
    metadata: [String: RemoteDrawJSONValue]?
  ) async throws -> RemoteDrawReceipt {
    struct Metadata: Encodable {
      let clientSubmissionId: String
      let occurredAt: Double
      let extra: [String: RemoteDrawJSONValue]?

      func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: RemoteDrawDynamicKey.self)
        // Host metadata first, so the two reserved keys cannot be overwritten
        // by a caller that happens to use the same names.
        for (key, value) in extra ?? [:] {
          try container.encode(value, forKey: RemoteDrawDynamicKey(key))
        }
        try container.encode(clientSubmissionId, forKey: RemoteDrawDynamicKey("clientSubmissionId"))
        try container.encode(occurredAt, forKey: RemoteDrawDynamicKey("occurredAt"))
      }
    }
    struct Body: Encodable {
      let senderToken: String
      let metadata: Metadata
    }
    return try await post(
      .submit,
      body: Body(
        senderToken: senderToken,
        metadata: Metadata(
          clientSubmissionId: clientSubmissionId,
          occurredAt: (Date().timeIntervalSince1970 * 1000).rounded(.down),
          extra: metadata
        )
      )
    )
  }

  public func editElements(senderToken: String, edit: RemoteDrawElementEdit) async throws
    -> RemoteDrawEditResult
  {
    struct Body: Encodable {
      let senderToken: String
      let edit: RemoteDrawElementEdit
    }
    return try await post(.edit, body: Body(senderToken: senderToken, edit: edit))
  }

  /// Asks for packed points (~8 B/point instead of ~50 as JSON). The response
  /// decodes either dialect, so a server that predates `encoding` — and so
  /// ignores it — still works.
  ///
  /// Incremental too: after the first read (`since: ""`) it sends the previous
  /// answer's `cursor` as `since` and applies what changed (`items` upserted,
  /// `removedIds` gone, or the whole board on `reset`), so a commit costs one
  /// stroke rather than the board. A board too big for one answer arrives in
  /// pages (`pageSize`), followed in the same call, then settled by one more
  /// delta. It still returns the whole board, in paint order, with a
  /// whole-list `payload`. If the result disagrees with `activeCount` it reads
  /// the whole board again in the same call; a server without `since` answers
  /// a plain whole list, returned as is. A delta read refused as malformed
  /// (`400 invalid_request`) or for a token or session that is gone drops the
  /// cursor, so the next call reads the whole board; other failures keep it
  /// (`refusesDrawingsRequest`). See `RemoteDrawDrawingChangesState`.
  public func drawings(senderToken: String) async throws -> RemoteDrawDrawingsResponse {
    struct Body: Encodable {
      let senderToken: String
      let encoding = "packed"
      let since: String
      let pageSize = RemoteDrawDrawingChangesState.pageSize
      let pageToken: String?
    }
    let held = drawingChanges.begin(key: senderToken)
    for _ in 0..<RemoteDrawDrawingChangesState.maxRequests {
      let request = drawingChanges.request(for: senderToken)
      let data: Data
      do {
        data = try await postRaw(
          .drawings,
          body: Body(senderToken: senderToken, since: request.since, pageToken: request.pageToken))
      } catch {
        // A refused request drops the cursor; see `refusesDrawingsRequest`.
        let refused = (error as? RemoteDrawError)?.refusesDrawingsRequest ?? false
        drawingChanges.failed(key: senderToken, held: held, refused: refused)
        throw error
      }
      let answer: RemoteDrawDrawingChangesAnswer
      do {
        answer = try decoder.decode(RemoteDrawDrawingChangesAnswer.self, from: data)
      } catch {
        drawingChanges.failed(key: senderToken, held: held, refused: false)
        throw RemoteDrawError.decoding("\(RemoteDrawSenderRoute.drawings.rawValue): \(error)")
      }
      if case .board(let response) = drawingChanges.apply(answer, key: senderToken, request: request) {
        return response
      }
    }
    drawingChanges.abandon(key: senderToken)
    throw RemoteDrawError.decoding(
      "\(RemoteDrawSenderRoute.drawings.rawValue): the read did not settle; it will start over")
  }

  public func updateProjection(senderToken: String, projection: RemoteDrawProjection) async throws
    -> RemoteDrawProjection
  {
    struct Body: Encodable {
      let senderToken: String
      let projection: RemoteDrawProjection
    }
    return try await post(.projection, body: Body(senderToken: senderToken, projection: projection))
  }

  public func closeProjection(senderToken: String, disconnect: Bool) async throws {
    struct Body: Encodable {
      let senderToken: String
      let disconnect: Bool?
    }
    _ = try await postRaw(
      .closeProjection, body: Body(senderToken: senderToken, disconnect: disconnect ? true : nil))
  }

  /// `POST /v1/sender/refresh`.
  ///
  /// Called exactly once per rejected credential, never on a timer, and never
  /// through ``retryIdempotentRequest``. See the protocol requirement for why.
  public func refresh(senderToken: String) async throws -> RemoteDrawRefreshResponse {
    try await post(.refresh, body: TokenBody(senderToken: senderToken))
  }

  /// `POST /v1/sender/sync`.
  ///
  /// A bare 404 — no error code, which is the router's "no such route" rather
  /// than the API's `session_not_found` — means a deployment that predates the
  /// route, and is reported as unsupported so the session falls back instead of
  /// retrying a route that will never answer.
  public func sync(senderToken: String) async throws -> RemoteDrawSyncRevisions {
    do {
      return try await post(.sync, body: TokenBody(senderToken: senderToken))
    } catch RemoteDrawError.server(let status, let code, _) where status == 404 && code == nil {
      throw RemoteDrawSyncUnsupportedError()
    }
  }

  // MARK: Plumbing

  private struct TokenBody: Encodable {
    let senderToken: String
  }

  /// The error shape every failing route shares, plus the two degraded forms a
  /// proxy in front of it can produce.
  ///
  /// A decoder that reads `error` as a string finds nothing in the real shape,
  /// which turns a server explanation the user could act on ("Session is not
  /// active.") into a bare status code.
  private struct ErrorEnvelope: Decodable {
    let message: String?
    let code: String?
    let retryAfter: Double?

    private struct ErrorObject: Decodable {
      let message: String?
      let code: String?
      let retryAfter: Double?
    }

    private enum CodingKeys: String, CodingKey {
      case error, message, code, retryAfter
    }

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      if let object = try? container.decode(ErrorObject.self, forKey: .error) {
        message = object.message
        code = object.code
        retryAfter = object.retryAfter
        return
      }
      // A bare `{"error":"..."}` is not what this API emits, but a gateway in
      // front of it may, and losing the message there is the same failure.
      if let flat = try? container.decode(String.self, forKey: .error) {
        message = flat
        code = nil
        retryAfter = nil
        return
      }
      message = try? container.decode(String.self, forKey: .message)
      code = try? container.decode(String.self, forKey: .code)
      retryAfter = try? container.decode(Double.self, forKey: .retryAfter)
    }
  }

  private func post<Response: Decodable>(
    _ route: RemoteDrawSenderRoute,
    body: some Encodable
  ) async throws -> Response {
    let data = try await postRaw(route, body: body)
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw RemoteDrawError.decoding("\(route.rawValue): \(error)")
    }
  }

  private func postRaw(
    _ route: RemoteDrawSenderRoute,
    body: some Encodable
  ) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingRoute(route.rawValue))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    // So the server can tell one SDK version from another, and tell an old one
    // to stop — see `clientAdvisory` below.
    request.setValue("swift/\(sdkVersion)", forHTTPHeaderField: "X-RemoteDraw-SDK")
    do {
      request.httpBody = try JSONEncoder().encode(body)
    } catch {
      // A non-finite coordinate is the realistic cause; the codec clamps them
      // out of packed points, but a projection or a style could still carry one.
      throw RemoteDrawError.decoding("\(route.rawValue) request: \(error)")
    }

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch let error as URLError where Self.offlineCodes.contains(error.code) {
      throw RemoteDrawError.offline
    } catch {
      throw RemoteDrawError.transport(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw RemoteDrawError.transport("RemoteDraw returned a non-HTTP response.")
    }

    // Read before the status is branched on, because a refusal is *also* an
    // advisory: the API answers 426 with the same field rather than performing
    // the work. Reading it only on 2xx would turn the refusal into a bare
    // `server(status: 426)` the host cannot act on.
    if let advisory = decodedAdvisory(from: data, current: sdkVersion) {
      advisories.report(advisory)
      if advisory.level == .blocked {
        throw RemoteDrawError.sdkTooOld(minimum: advisory.minimum, message: advisory.message)
      }
    }

    switch http.statusCode {
    // Commit answers 201; the rest answer 200. The whole success range is
    // accepted so the exact code stays the server's business.
    case 200..<300:
      return data
    case 401:
      throw RemoteDrawError.tokenRejected
    case 403:
      let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
      throw RemoteDrawError.notPermitted(
        RemoteDrawCapability(rawValue: route.requiredCapability?.rawValue ?? envelope?.code ?? "draw"))
    case 410:
      throw RemoteDrawError.sessionEnded
    case 429:
      let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
      let header = http.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init)
      throw RemoteDrawError.rateLimited(
        retryAfter: envelope?.retryAfter ?? header ?? 1, bucket: envelope?.code)
    default:
      let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
      // The API has one code for a finished board, `session_not_active`, and
      // deliberately does not say whether it ended or expired: the distinction
      // lives on the session payload's `status`, which a sender already holds.
      // `RemoteDrawSenderSession` refines this into `.sessionExpired` from the
      // `expiresAt` it last read — see `recover(from:)` — because the transport
      // has no session to compare against. (A `session_expired` code was
      // matched here for a while; the server never sent it.)
      if envelope?.code == "session_not_active" {
        throw RemoteDrawError.sessionEnded
      }
      throw RemoteDrawError.server(
        status: http.statusCode, code: envelope?.code, message: envelope?.message)
    }
  }

  /// One optional response field lets the server retire an SDK version.
  ///
  /// Without it, "old SDK meets new API" means a silently degraded drawing —
  /// the failure mode neither end can detect.
  private struct AdvisoryEnvelope: Decodable {
    struct Advisory: Decodable {
      let level: String?
      let message: String?
      let minimum: String?
      let current: String?
    }
    let clientAdvisory: Advisory?
  }

  /// The advisory in a response body, if it carries a level this build knows.
  ///
  /// An unrecognized level is ignored rather than guessed at. A future
  /// deployment inventing a third level must not have it read as a block by an
  /// SDK that has never heard of it — that is the failure this gate exists to
  /// avoid, arriving from the other direction.
  private func decodedAdvisory(from data: Data, current: String)
    -> RemoteDrawClientAdvisory?
  {
    guard let envelope = try? decoder.decode(AdvisoryEnvelope.self, from: data),
      let advisory = envelope.clientAdvisory,
      let level = advisory.level.flatMap(RemoteDrawClientAdvisory.Level.init(rawValue:))
    else { return nil }
    return RemoteDrawClientAdvisory(
      level: level,
      minimum: advisory.minimum ?? "unknown",
      message: advisory.message
        ?? (level == .blocked
          ? "This SDK is too old." : "This SDK version is being retired."),
      current: advisory.current ?? current
    )
  }

  private static let offlineCodes: Set<URLError.Code> = [
    .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost,
    .cannotFindHost, .dataNotAllowed, .internationalRoamingOff, .timedOut,
  ]
}

/// The rotated credential, and the session state that travels with it.
///
/// The same shape as a join, minus the part that makes a join expensive: a
/// rotation touches only this sender's token document, so nobody else on the
/// board is disturbed. `/v1/join` revokes every other active sender on the
/// session; that is the difference this route exists to buy.
public struct RemoteDrawRefreshResponse: Decodable, Equatable, Sendable {
  public let senderToken: String
  public let senderId: String?
  public let session: RemoteDrawSession?
  public let capabilities: [String]?
  /// Epoch milliseconds, re-synced to the session's own expiry.
  ///
  /// Advisory only: the SDK does not schedule against it. Refresh **extends
  /// nothing** — it copies the session's expiry onto the token — so a client
  /// that woke on this timestamp to refresh again would find the same number
  /// waiting for it and would spend its 10/min budget discovering that.
  public let expiresAt: Double?
  /// The sequence survives rotation, so a resuming sender continues where it
  /// left off instead of restarting at 0 and having every draft rejected.
  public let lastSequence: Int?

  private enum CodingKeys: String, CodingKey {
    case senderToken, senderId, session, capabilities, expiresAt, lastSequence
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    senderToken = try container.decode(String.self, forKey: .senderToken)
    senderId = try container.decodeIfPresent(String.self, forKey: .senderId)
    session = try? container.decodeIfPresent(RemoteDrawSession.self, forKey: .session)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
    expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
    lastSequence = try container.decodeIfPresent(Int.self, forKey: .lastSequence)
  }

  public init(
    senderToken: String,
    senderId: String? = nil,
    session: RemoteDrawSession? = nil,
    capabilities: [String]? = nil,
    expiresAt: Double? = nil,
    lastSequence: Int? = nil
  ) {
    self.senderToken = senderToken
    self.senderId = senderId
    self.session = session
    self.capabilities = capabilities
    self.expiresAt = expiresAt
    self.lastSequence = lastSequence
  }
}

/// A `CodingKey` for metadata whose keys the host chooses.
struct RemoteDrawDynamicKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }

  init(_ stringValue: String) { self.stringValue = stringValue }
  init?(stringValue: String) { self.stringValue = stringValue }
  init?(intValue: Int) { return nil }
}

extension URL {
  /// `appendingPathComponent` percent-escapes the slashes in a multi-segment
  /// route, turning `/v1/sender/draft` into one component. Routes are literals
  /// from an enum, so joining the strings is both correct and the only thing
  /// that produces a working URL.
  fileprivate func appendingRoute(_ route: String) -> URL {
    let base = absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
    return URL(string: base + route) ?? self
  }
}
