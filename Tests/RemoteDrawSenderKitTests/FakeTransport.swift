import Foundation

@testable import RemoteDrawSenderKit

/// A scriptable stand-in for the network.
///
/// Every lifecycle rule that matters — sequence seeding, `stale_sequence`
/// healing, the re-join contract, presence, clean exit — is a rule about *what
/// the sender does with an answer*, so it is verifiable without a socket. That
/// is the whole reason ``RemoteDrawSenderTransport`` is a protocol.
// Tests configure and inspect this script on the main actor. Keep request
// bookkeeping there too: concurrent replays must not mutate its arrays from
// different transport executor threads.
@MainActor
final class FakeTransport: RemoteDrawSenderTransport {
  struct Call: Equatable {
    let route: RemoteDrawSenderRoute
    let senderToken: String
    let sequence: Int?
  }

  private let lock = NSLock()
  private var _calls: [Call] = []

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return _calls
  }

  var callCount: (RemoteDrawSenderRoute) -> Int {
    { route in self.calls.filter { $0.route == route }.count }
  }

  private func record(_ route: RemoteDrawSenderRoute, _ token: String, _ sequence: Int? = nil) {
    lock.lock()
    _calls.append(Call(route: route, senderToken: token, sequence: sequence))
    lock.unlock()
  }

  // MARK: Script

  var joinResult: Result<RemoteDrawJoinResponse, Error> = .success(
    RemoteDrawJoinResponse(senderToken: "rd_send_1", senderId: "sender_1", capabilities: ["draw"]))
  var sessionResult: Result<RemoteDrawSessionResponse, Error>?
  var sessionHook: (() async throws -> RemoteDrawSessionResponse)?
  private var automaticPollClock: ManualPollClock?

  /// Park automatic sync and heartbeat work without backgrounding the sender.
  /// Manual reads and drawing still exercise normal foreground admission. The
  /// first sync has no initial timer, so freezing just the sleep clock is not
  /// enough: hold that request too. Cancellation releases it on teardown.
  func holdAutomaticPolling() -> ManualPollClock {
    let clock = ManualPollClock()
    automaticPollClock = clock
    return clock
  }

  /// The first presence beat does not sleep. Let it finish before a fixture
  /// creates pending ink, or that startup beat can race its explicit retry.
  @MainActor
  func settleStartup() async {
    guard let clock = automaticPollClock else {
      preconditionFailure("Hold automatic polling before settling fixture startup")
    }
    await clock.settle()
  }

  var draftResults: [RemoteDrawDraftAck] = []
  var draftError: Error?
  var draftDelayNanoseconds: UInt64 = 0
  private var _draftStartedAt: [TimeInterval] = []
  var draftStartedAt: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return _draftStartedAt
  }
  private func recordDraftStart() {
    lock.lock()
    _draftStartedAt.append(ProcessInfo.processInfo.systemUptime)
    lock.unlock()
  }
  var commitResult: Result<RemoteDrawCommitResult, Error>?
  /// Runs before the canned answer, so a test can fail the first N attempts.
  /// A closure rather than a subclass because the failure is per-test and the
  /// recording underneath it is not.
  var commitHook: ((Int) throws -> Void)?
  var commitAsyncHook: ((RemoteDrawCommitRequest) async throws -> Void)?
  var refreshHook: (() async throws -> Void)?
  var pingHook: ((String, Bool) async throws -> Void)?
  var draftHook: (() async throws -> Void)?
  private(set) var commitRequests: [RemoteDrawCommitRequest] = []
  var submitHook: ((Int, String) throws -> Void)?
  var undoResult = RemoteDrawUndoResult(removed: true, drawingId: nil)
  var clearResult = RemoteDrawClearResult(removed: 3)
  var submitResult: Result<RemoteDrawReceipt, Error>?
  var refreshResult: Result<RemoteDrawRefreshResponse, Error> = .failure(
    RemoteDrawError.server(status: 404, code: nil, message: "no route"))
  /// Bumped every time `submit` is called, so an idempotent retry is visible.
  private(set) var submitAttempts = 0
  private(set) var commitAttempts = 0
  private(set) var refreshAttempts = 0
  private(set) var lastDraftPacked: String?
  private(set) var lastCommitClientStrokeId: String?
  /// The geometry the last commit actually carried, unpacked. What the *tool*
  /// reduced the buffer to is invisible in a point count alone.
  private(set) var lastCommitPoints: [RemoteDrawNormalizedPoint]?
  private(set) var lastCommitTool: String?
  private(set) var lastSubmissionId: String?
  /// Every distinct idempotency key the session used. More than one across a
  /// retry means a second submission, not a retry.
  private(set) var submissionIds: Set<String> = []
  var drawingsAsyncHook: (() async throws -> Void)?
  var drawingsJSON = #"{"items":[]}"#
  var editResultJSON = #"{"accepted":true,"kind":"setProperties","editId":"e1","elements":[]}"#
  private(set) var lastEditBody: String??
  private(set) var lastPingWasActive: Bool?
  private(set) var lastCloseWasDisconnect: Bool?

  // MARK: Conformance

  func sync(senderToken: String) async throws -> RemoteDrawSyncRevisions {
    if let clock = automaticPollClock { try await clock.sleep(seconds: 1) }
    // Preserve the legacy fake's default behavior for all other fixtures.
    throw RemoteDrawSyncUnsupportedError()
  }

  func join(joinToken: String, device: RemoteDrawSenderDevice?) async throws
    -> RemoteDrawJoinResponse
  {
    record(.join, joinToken)
    return try joinResult.get()
  }

  func session(senderToken: String) async throws -> RemoteDrawSessionResponse {
    record(.session, senderToken)
    if let sessionHook { return try await sessionHook() }
    guard let sessionResult else {
      return RemoteDrawSessionResponse(
        senderId: "sender_1",
        session: RemoteDrawSession.stub(capabilities: ["draw", "undo", "clear", "submit"]),
        capabilities: ["draw", "undo", "clear", "submit"],
        lastSequence: nil
      )
    }
    return try sessionResult.get()
  }

  func ping(senderToken: String, active: Bool) async throws {
    record(.ping, senderToken)
    lastPingWasActive = active
    try await pingHook?(senderToken, active)
  }

  func updateDraft(_ request: RemoteDrawDraftRequest) async throws -> RemoteDrawDraftAck {
    record(.draft, request.senderToken, request.sequence)
    lastDraftPacked = request.packedPoints
    recordDraftStart()
    try await draftHook?()
    if draftDelayNanoseconds > 0 { try await Task.sleep(nanoseconds: draftDelayNanoseconds) }
    if let draftError { throw draftError }
    if draftResults.isEmpty { return RemoteDrawDraftAck(accepted: true) }
    return draftResults.removeFirst()
  }

  func commitStroke(_ request: RemoteDrawCommitRequest) async throws -> RemoteDrawCommitResult {
    record(.commit, request.senderToken, request.sequence)
    commitAttempts += 1
    commitRequests.append(request)
    lastCommitClientStrokeId = request.clientStrokeId
    lastCommitPoints = try? PointCodec.unpack(request.packedPoints)
    lastCommitTool = request.tool
    try await commitAsyncHook?(request)
    try commitHook?(commitAttempts)
    guard let commitResult else {
      return RemoteDrawCommitResult(
        id: "drawing_1", duplicate: false, type: "freehand",
        style: nil, points: try? PointCodec.unpack(request.packedPoints), text: nil)
    }
    return try commitResult.get()
  }

  func replaceStroke(_ request: RemoteDrawReplaceRequest) async throws -> RemoteDrawReplaceResult {
    record(.replace, request.senderToken)
    return RemoteDrawReplaceResult(
      accepted: true, reason: nil, id: request.strokeId, type: request.tool, points: nil, style: nil)
  }

  func clearDraft(senderToken: String, sequence: Int?) async throws {
    record(.clearDraft, senderToken, sequence)
  }

  func undo(senderToken: String) async throws -> RemoteDrawUndoResult {
    record(.undo, senderToken)
    return undoResult
  }

  func clear(senderToken: String) async throws -> RemoteDrawClearResult {
    record(.clear, senderToken)
    return clearResult
  }

  func submit(
    senderToken: String, clientSubmissionId: String, metadata: [String: RemoteDrawJSONValue]?
  ) async throws -> RemoteDrawReceipt {
    record(.submit, senderToken)
    submitAttempts += 1
    lastSubmissionId = clientSubmissionId
    submissionIds.insert(clientSubmissionId)
    try submitHook?(submitAttempts, clientSubmissionId)
    guard let submitResult else {
      return RemoteDrawReceipt(
        id: "submission_1", status: "submitted", accepted: true, duplicate: false, message: nil,
        submittedAt: 0)
    }
    return try submitResult.get()
  }

  func editElements(senderToken: String, edit: RemoteDrawElementEdit) async throws
    -> RemoteDrawEditResult
  {
    record(.edit, senderToken)
    lastEditBody = try? String(data: JSONEncoder().encode(edit), encoding: .utf8)
    return try! RemoteDrawEditResult.decoded(fromJSON: editResultJSON)
  }

  func drawings(senderToken: String) async throws -> RemoteDrawDrawingsResponse {
    record(.drawings, senderToken)
    let response = try JSONDecoder().decode(RemoteDrawDrawingsResponse.self, from: Data(drawingsJSON.utf8))
    try await drawingsAsyncHook?()
    return response
  }

  func updateProjection(senderToken: String, projection: RemoteDrawProjection) async throws
    -> RemoteDrawProjection
  {
    record(.projection, senderToken)
    return projection
  }

  func refresh(senderToken: String) async throws -> RemoteDrawRefreshResponse {
    record(.refresh, senderToken)
    refreshAttempts += 1
    try await refreshHook?()
    return try refreshResult.get()
  }

  func closeProjection(senderToken: String, disconnect: Bool) async throws {
    record(.closeProjection, senderToken)
    lastCloseWasDisconnect = disconnect
  }
}

// MARK: - Decodable stubs

/// The wire types are `Decodable` because they only ever arrive from a server.
/// Tests need to *make* one, so they go in through JSON — which has the useful
/// side effect that every stub exercises the real decoder.
extension Decodable {
  static func decoded(fromJSON json: String) throws -> Self {
    try JSONDecoder().decode(Self.self, from: Data(json.utf8))
  }
}

extension RemoteDrawSession {
  static func stub(
    id: String = "session_1",
    status: String = "active",
    capabilities: [String] = ["draw"],
    targetKind: String = "paper"
  ) -> RemoteDrawSession {
    let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
    return try! RemoteDrawSession.decoded(
      fromJSON: """
        {"id":"\(id)","status":"\(status)","capabilities":[\(caps)],
         "target":{"kind":"\(targetKind)"},"expiresAt":1000}
        """)
  }
}

extension RemoteDrawSessionResponse {
  init(
    senderId: String?, session: RemoteDrawSession, capabilities: [String]?, lastSequence: Int?
  ) {
    let caps = capabilities.map { list in
      ",\"capabilities\":[\(list.map { "\"\($0)\"" }.joined(separator: ","))]"
    } ?? ""
    let seq = lastSequence.map { ",\"lastSequence\":\($0)" } ?? ""
    let json = """
      {"senderId":\(senderId.map { "\"\($0)\"" } ?? "null"),
       "session":{"id":"\(session.id)","status":"\(session.status)",
       "capabilities":[\(session.capabilities.map { "\"\($0)\"" }.joined(separator: ","))]}\(caps)\(seq)}
      """
    self = try! RemoteDrawSessionResponse.decoded(fromJSON: json)
  }
}

extension RemoteDrawCommitResult {
  init(
    id: String?, duplicate: Bool?, type: String?, style: RemoteDrawDrawingStyle?,
    points: [RemoteDrawNormalizedPoint]?, text: String?
  ) {
    let pointsJSON =
      points.map { list in
        "[" + list.map { "{\"x\":\($0.x),\"y\":\($0.y)}" }.joined(separator: ",") + "]"
      } ?? "null"
    self = try! RemoteDrawCommitResult.decoded(
      fromJSON: """
        {"id":\(id.map { "\"\($0)\"" } ?? "null"),"duplicate":\(duplicate ?? false),
         "type":\(type.map { "\"\($0)\"" } ?? "null"),"points":\(pointsJSON)}
        """)
  }
}

extension RemoteDrawUndoResult {
  init(removed: Bool, drawingId: String?) {
    self = try! RemoteDrawUndoResult.decoded(
      fromJSON: """
        {"removed":\(removed),"drawingId":\(drawingId.map { "\"\($0)\"" } ?? "null")}
        """)
  }
}

extension RemoteDrawClearResult {
  init(removed: Int) {
    self = try! RemoteDrawClearResult.decoded(fromJSON: "{\"removed\":\(removed)}")
  }
}

extension RemoteDrawReceipt {
  init(
    id: String?, status: String?, accepted: Bool?, duplicate: Bool?, message: String?,
    submittedAt: Double?
  ) {
    self = try! RemoteDrawReceipt.decoded(
      fromJSON: """
        {"id":\(id.map { "\"\($0)\"" } ?? "null"),"status":\(status.map { "\"\($0)\"" } ?? "null"),
         "accepted":\(accepted ?? true),"duplicate":\(duplicate ?? false),
         "submittedAt":\(submittedAt ?? 0)}
        """)
  }
}

extension RemoteDrawReplaceResult {
  init(
    accepted: Bool, reason: String?, id: String?, type: String?,
    points: [RemoteDrawNormalizedPoint]?, style: RemoteDrawDrawingStyle?
  ) {
    self = try! RemoteDrawReplaceResult.decoded(
      fromJSON: """
        {"accepted":\(accepted),"id":\(id.map { "\"\($0)\"" } ?? "null"),
         "type":\(type.map { "\"\($0)\"" } ?? "null")}
        """)
  }
}

extension RemoteDrawDrawingsResponse {
  init(session: RemoteDrawSession?, items: [RemoteDrawDrawing]) {
    self = try! RemoteDrawDrawingsResponse.decoded(fromJSON: "{\"items\":[]}")
  }
}
