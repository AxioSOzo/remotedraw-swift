import XCTest

@testable import RemoteDrawReceiverKit

/// The draft/commit handoff and the polling contract, tested against the same
/// cases as the TypeScript twin in `packages/client`.
final class ReceiverDraftAdmissionTests: XCTestCase {
  private let now: Double = 1_700_000_000_000

  private func draft(
    id: String = "d1",
    senderId: String? = "sender-a",
    sequence: Int? = 5,
    updatedAt: Double? = nil
  ) -> RemoteDrawReceiverDraft {
    decode(
      """
      {"id":"\(id)","senderId":\(json(senderId)),"sequence":\(json(sequence)),
       "updatedAt":\(json(updatedAt)),"points":[{"x":0.1,"y":0.1}]}
      """
    )
  }

  private func drawing(
    id: String = "s1",
    senderId: String? = "sender-a",
    sequence: Int? = 5
  ) -> RemoteDrawReceiverDrawing {
    decode(
      """
      {"id":"\(id)","senderId":\(json(senderId)),"sequence":\(json(sequence)),
       "type":"stroke","points":[{"x":0.1,"y":0.1}]}
      """
    )
  }

  func testFreshUncommittedDraftRenders() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(updatedAt: now - 100)],
      drawings: [],
      now: now
    )
    XCTAssertEqual(admitted.count, 1)
  }

  func testDraftSupersededByItsOwnCommitIsDropped() {
    // The exact race the poll ordering exists to absorb: the draft and its
    // committed stroke are both visible, at the same sequence.
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(sequence: 5, updatedAt: now)],
      drawings: [drawing(sequence: 5)],
      now: now
    )
    XCTAssertTrue(admitted.isEmpty, "A draft at or below the committed sequence must not double-draw")
  }

  func testDraftAheadOfTheCommittedSequenceStillRenders() {
    // The pen lifted on stroke 5 and is already down on stroke 6.
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(sequence: 6, updatedAt: now)],
      drawings: [drawing(sequence: 5)],
      now: now
    )
    XCTAssertEqual(admitted.count, 1)
  }

  func testAnotherSendersCommitDoesNotSuppressThisSendersDraft() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(senderId: "sender-a", sequence: 2, updatedAt: now)],
      drawings: [drawing(senderId: "sender-b", sequence: 9)],
      now: now
    )
    XCTAssertEqual(admitted.count, 1)
  }

  func testStaleDraftIsDropped() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(updatedAt: now - RemoteDrawDraftAdmission.staleAfterMs - 1)],
      drawings: [],
      now: now
    )
    XCTAssertTrue(admitted.isEmpty, "A sender that vanished mid-stroke must not leave a ghost")
  }

  func testDraftExactlyAtTheStalenessBoundaryStillRenders() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(updatedAt: now - RemoteDrawDraftAdmission.staleAfterMs)],
      drawings: [],
      now: now
    )
    XCTAssertEqual(admitted.count, 1, "The window is inclusive, matching the TypeScript twin")
  }

  func testDraftWithoutATimestampIsTreatedAsFresh() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(updatedAt: nil)],
      drawings: [],
      now: now
    )
    XCTAssertEqual(admitted.count, 1)
  }

  func testDraftWithoutASenderOrSequenceIsAdmitted() {
    let admitted = RemoteDrawDraftAdmission.renderable(
      drafts: [draft(senderId: nil, sequence: nil, updatedAt: now)],
      drawings: [drawing(sequence: 99)],
      now: now
    )
    XCTAssertEqual(admitted.count, 1)
  }

  func testCommittedSequencesTakeTheHighestPerSender() {
    let sequences = RemoteDrawDraftAdmission.committedSequencesBySender([
      drawing(id: "a", senderId: "s1", sequence: 3),
      drawing(id: "b", senderId: "s1", sequence: 11),
      drawing(id: "c", senderId: "s1", sequence: 7),
      drawing(id: "d", senderId: "s2", sequence: 1),
    ])
    XCTAssertEqual(sequences["s1"], 11)
    XCTAssertEqual(sequences["s2"], 1)
  }

  func testStaleConstantMatchesTheServer() {
    // `DRAFT_STALE_AFTER_MS` in convex/lib/validators.ts. If the server ever
    // moves, this test is the tripwire.
    XCTAssertEqual(RemoteDrawDraftAdmission.staleAfterMs, 10_000)
  }
}

final class ReceiverCadenceTests: XCTestCase {
  func testIdleCadenceIsOneSecond() {
    XCTAssertEqual(RemoteDrawReceiverCadence.intervalMs(hasDrafts: false), 1000)
  }

  func testDraftingCadenceDropsToQuarterSecond() {
    XCTAssertEqual(RemoteDrawReceiverCadence.intervalMs(hasDrafts: true), 250)
  }

  func testDraftingNeverPollsSlowerThanIdle() {
    // A misconfiguration must not make live ink *slower* than idle.
    XCTAssertEqual(
      RemoteDrawReceiverCadence.intervalMs(hasDrafts: true, idle: 200, drafting: 900),
      200
    )
  }
}

@MainActor
final class ReceiverStoreTests: XCTestCase {
  func testRefetchAdmitsDraftsAgainstFreshlyFetchedDrawings() async {
    let transport = FakeTransport()
    transport.drafts = [Fixtures.draft(sequence: 4, updatedAt: Fixtures.now)]
    transport.drawings = [Fixtures.drawing(sequence: 4)]

    let store = RemoteDrawReceiverStore(
      transport: transport,
      now: { Date(timeIntervalSince1970: Fixtures.now / 1000) }
    )
    store.start(credentials: Fixtures.credentials)
    let snapshot = await store.refetch()
    store.stop()

    XCTAssertEqual(snapshot.drawings.count, 1)
    XCTAssertTrue(snapshot.drafts.isEmpty, "The committed stroke supersedes its own draft")
  }

  func testDraftsAreFetchedBeforeDrawings() async {
    // Ordering is load-bearing, not stylistic: reversing it makes a stroke
    // vanish for one poll cycle at the moment of commit.
    let transport = FakeTransport()
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: Fixtures.credentials)
    await store.refetch()
    store.stop()

    let draftsIndex = transport.callOrder.firstIndex(of: "drafts")
    let drawingsIndex = transport.callOrder.firstIndex(of: "drawings")
    XCTAssertNotNil(draftsIndex)
    XCTAssertNotNil(drawingsIndex)
    XCTAssertLessThan(draftsIndex!, drawingsIndex!)
  }

  func testUnauthorizedTerminatesInsteadOfRetryingForever() async {
    let transport = FakeTransport()
    transport.sessionError = .unauthorized
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: Fixtures.credentials)
    await store.refetch()

    XCTAssertTrue(store.isTerminated)
    XCTAssertEqual(store.lastError, .unauthorized)
    store.stop()
  }

  func testTransientTransportErrorDoesNotTerminate() async {
    let transport = FakeTransport()
    transport.sessionError = .transport("offline")
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: Fixtures.credentials)
    await store.refetch()

    XCTAssertFalse(store.isTerminated, "A dropped connection is recoverable; keep polling")
    XCTAssertEqual(store.lastError, .transport("offline"))
    store.stop()
  }

  func testEndedSessionTerminatesPolling() async {
    let transport = FakeTransport()
    transport.session = Fixtures.session(status: "ended")
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: Fixtures.credentials)
    await store.refetch()

    XCTAssertTrue(store.isTerminated)
    store.stop()
  }

  func testStopClearsTheSnapshotSoInkDoesNotLinger() async {
    let transport = FakeTransport()
    transport.drawings = [Fixtures.drawing(sequence: 1)]
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: Fixtures.credentials)
    await store.refetch()
    XCTAssertEqual(store.snapshot.drawings.count, 1)

    store.stop()
    XCTAssertTrue(store.snapshot.drawings.isEmpty)
    XCTAssertNil(store.credentials)
  }
}

// MARK: - Fixtures

private enum Fixtures {
  static let now: Double = 1_700_000_000_000
  static let credentials = RemoteDrawReceiverCredentials(
    sessionId: "session-1",
    receiverToken: "rd_recv_test"
  )

  static func session(status: String = "active") -> RemoteDrawReceiverSession {
    decode(#"{"id":"session-1","status":"\#(status)"}"#)
  }

  static func draft(sequence: Int, updatedAt: Double) -> RemoteDrawReceiverDraft {
    decode(
      #"{"id":"d","senderId":"s","sequence":\#(sequence),"updatedAt":\#(updatedAt),"points":[]}"#
    )
  }

  static func drawing(sequence: Int) -> RemoteDrawReceiverDrawing {
    decode(#"{"id":"c","senderId":"s","sequence":\#(sequence),"type":"stroke","points":[]}"#)
  }
}

/// `RemoteDrawReceiverTransport` is `Sendable`, and `refetch()` deliberately
/// overlaps `fetchSession` with `fetchSenders` through `async let` — so a
/// conformer is called *concurrently* from off the main actor. A test double
/// that records call order therefore has to synchronise that recording: two
/// unguarded `Array.append`s from two child tasks corrupt the buffer, and this
/// suite crashed the whole `swift test` process with signal 11 until this lock
/// existed. The lock is the double being honest about the `@unchecked` it claims.
private final class FakeTransport: RemoteDrawReceiverTransport, @unchecked Sendable {
  var session = Fixtures.session()
  var drawings: [RemoteDrawReceiverDrawing] = []
  var drafts: [RemoteDrawReceiverDraft] = []
  var senders: [RemoteDrawReceiverSenderRecord] = []
  var sessionError: RemoteDrawReceiverError?

  private let lock = NSLock()
  private var recordedCalls: [String] = []

  var callOrder: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedCalls
  }

  private func record(_ call: String) {
    lock.lock()
    recordedCalls.append(call)
    lock.unlock()
  }

  func fetchSession(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> RemoteDrawReceiverSession
  {
    record("session")
    if let sessionError { throw sessionError }
    return session
  }

  func fetchDrawings(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDrawing]
  {
    record("drawings")
    return drawings
  }

  func fetchDrafts(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDraft]
  {
    record("drafts")
    return drafts
  }

  func fetchSenders(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverSenderRecord]
  {
    record("senders")
    return senders
  }

  func undo(_ credentials: RemoteDrawReceiverCredentials) async throws {
    record("undo")
  }

  func clear(_ credentials: RemoteDrawReceiverCredentials) async throws {
    record("clear")
  }
}

// MARK: - JSON helpers

/// Fixtures are built by decoding JSON rather than by calling initialisers, so
/// the tests exercise the same decode path a real response takes — including
/// the optionality that a hand-built value would quietly bypass.
private func decode<T: Decodable>(_ json: String) -> T {
  // swiftlint:disable:next force_try
  try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}

private func json(_ value: String?) -> String {
  value.map { "\"\($0)\"" } ?? "null"
}

private func json(_ value: Int?) -> String {
  value.map(String.init) ?? "null"
}

private func json(_ value: Double?) -> String {
  value.map { String($0) } ?? "null"
}
