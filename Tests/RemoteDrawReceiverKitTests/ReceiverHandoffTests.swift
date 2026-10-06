import Foundation
import XCTest
@testable import RemoteDrawReceiverKit

/// Drive the real async store across the non-atomic sync/content boundary.
/// Revision replies are captured before the gate, then the server-side commit
/// removes its draft and inserts its drawing while the reply is in flight.
@MainActor
final class ReceiverHandoffTests: XCTestCase {
  private let credentials = RemoteDrawReceiverCredentials(
    sessionId: "handoff-session", receiverToken: "handoff-token")

  func testCommitAfterSyncKeepsInkInTheSameRefetch() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()
    XCTAssertEqual(store.snapshot.drafts.map(\.id), ["draft-old"])

    let gate = await prepareRace(transport)
    let pending = Task { await store.refetch() }
    await fulfillment(of: [gate.entered], timeout: 2)
    await transport.commit()
    await gate.release()
    let snapshot = await pending.value

    XCTAssertEqual(snapshot.drawings.map(\.id), ["committed"])
    XCTAssertTrue(snapshot.drafts.isEmpty)
    let drawingsReads = await transport.count("drawings")
    XCTAssertEqual(drawingsReads, 2, "A vanished draft must trigger the drawings read")
    let order = await transport.callOrder()
    XCTAssertEqual(Array(order.suffix(3)), ["revisions", "drafts", "drawings"])
  }

  func testNextStrokeWithTheSameDraftCountStillRefreshesCommittedInk() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()

    let gate = await prepareRace(transport)
    let pending = Task { await store.refetch() }
    await fulfillment(of: [gate.entered], timeout: 2)
    await transport.commit(startNextStroke: true)
    await gate.release()
    let snapshot = await pending.value

    XCTAssertEqual(snapshot.drawings.map(\.id), ["committed"])
    XCTAssertEqual(snapshot.drafts.map(\.id), ["draft-next"],
      "A new draft cannot hide the disappeared previous draft")
  }

  func testSurvivingDraftAndUnchangedRevisionsSkipDrawingReads() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()

    await transport.advanceDraft()
    await store.refetch()
    await store.refetch()

    let drawingReads = await transport.count("drawings")
    let draftReads = await transport.count("drafts")
    let revisionReads = await transport.count("revisions")
    XCTAssertEqual(drawingReads, 1, "A moving draft with the same ID uses cached drawings")
    XCTAssertEqual(draftReads, 2, "An unchanged revision skips the draft read")
    XCTAssertEqual(revisionReads, 3)
    XCTAssertEqual(store.snapshot.drafts.map(\.id), ["draft-old"])
  }

  func testFailedForcedReadPreservesDraftUntilACompleteRetry() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()

    let gate = await prepareRace(transport)
    let pending = Task { await store.refetch() }
    await fulfillment(of: [gate.entered], timeout: 2)
    await transport.commit()
    await transport.failDrawingRead(with: .transport("offline"))
    await gate.release()
    let snapshot = await pending.value

    XCTAssertEqual(snapshot.drafts.map(\.id), ["draft-old"],
      "Failed reads must not publish an empty handoff")
    XCTAssertTrue(snapshot.drawings.isEmpty)
    XCTAssertEqual(store.lastError, .transport("offline"))
    XCTAssertFalse(store.isTerminated)

    await transport.failDrawingRead(with: nil)
    let recovered = await store.refetch()
    XCTAssertEqual(recovered.drawings.map(\.id), ["committed"])
    XCTAssertTrue(recovered.drafts.isEmpty)
    XCTAssertNil(store.lastError)
  }

  func testForcedReadStillHonorsRevokedCredentials() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()

    let gate = await prepareRace(transport)
    let pending = Task { await store.refetch() }
    await fulfillment(of: [gate.entered], timeout: 2)
    await transport.commit()
    await transport.failDrawingRead(with: .unauthorized)
    await gate.release()
    _ = await pending.value

    XCTAssertTrue(store.isTerminated)
    XCTAssertEqual(store.lastError, .unauthorized)
  }

  func testRetiredForcedReadCannotPublishIntoReplacementConnection() async {
    let transport = ReceiverHandoffTransport()
    let store = makeStore(transport)
    store.start(credentials: credentials)
    defer { store.stop() }
    await store.refetch()

    let syncGate = await prepareRace(transport)
    let drawingGate = ReceiverHandoffGate()
    await transport.pauseNextDrawing(drawingGate)
    let pending = Task { await store.refetch() }
    await fulfillment(of: [syncGate.entered], timeout: 2)
    await transport.commit()
    await syncGate.release()
    await fulfillment(of: [drawingGate.entered], timeout: 2)

    let replacement = RemoteDrawReceiverCredentials(
      sessionId: "replacement-session", receiverToken: "replacement-token")
    store.start(credentials: replacement)
    await store.refetch()
    await drawingGate.release()
    _ = await pending.value

    XCTAssertEqual(store.credentials, replacement)
    XCTAssertEqual(store.snapshot.session?.id, replacement.sessionId)
    XCTAssertTrue(store.snapshot.drawings.isEmpty,
      "The retired connection must not publish its late committed stroke")
    XCTAssertNil(store.lastError)
  }

  private func makeStore(_ transport: ReceiverHandoffTransport) -> RemoteDrawReceiverStore {
    RemoteDrawReceiverStore(
      transport: transport, idleIntervalMs: 60_000,
      now: { Date(timeIntervalSince1970: 1_700_000_000) })
  }

  private func prepareRace(_ transport: ReceiverHandoffTransport) async -> ReceiverHandoffGate {
    // A movement makes drafts dirty while drawings remain at the cached
    // revision. The commit then lands after that sync reply was captured.
    await transport.advanceDraft()
    let gate = ReceiverHandoffGate()
    await transport.pauseNextRevision(gate)
    return gate
  }
}

private actor ReceiverHandoffGate {
  nonisolated let entered = XCTestExpectation(description: "handoff reply captured")
  private var continuation: CheckedContinuation<Void, Never>?
  private var released = false

  func wait() async {
    entered.fulfill()
    guard !released else { return }
    await withCheckedContinuation { continuation = $0 }
  }

  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

/// Separate revision domains matter: advancing every revision together would
/// always fetch drawings and hide the cache race. Actor isolation also makes
/// the intentionally overlapping replacement-connection test data-race free.
private actor ReceiverHandoffTransport: RemoteDrawReceiverTransport {
  private var drawingsRevision = 0
  private var draftsRevision = 1
  private var drafts: [RemoteDrawReceiverDraft] = [
    decodeHandoff(#"{"id":"draft-old","senderId":"sender","sequence":4,"updatedAt":1700000000000,"points":[]}"#)
  ]
  private var drawings: [RemoteDrawReceiverDrawing] = []
  private var drawingError: RemoteDrawReceiverError?
  private var revisionGate: ReceiverHandoffGate?
  private var drawingGate: ReceiverHandoffGate?
  private var calls: [String] = []

  func advanceDraft() { draftsRevision += 1 }
  func pauseNextRevision(_ gate: ReceiverHandoffGate) { revisionGate = gate }
  func pauseNextDrawing(_ gate: ReceiverHandoffGate) { drawingGate = gate }
  func failDrawingRead(with error: RemoteDrawReceiverError?) { drawingError = error }
  func count(_ endpoint: String) -> Int { calls.filter { $0 == endpoint }.count }
  func callOrder() -> [String] { calls }

  func commit(startNextStroke: Bool = false) {
    drawings = [
      decodeHandoff(#"{"id":"committed","senderId":"sender","sequence":4,"type":"stroke","points":[]}"#)
    ]
    drafts = startNextStroke
      ? [decodeHandoff(#"{"id":"draft-next","senderId":"sender","sequence":5,"updatedAt":1700000000000,"points":[]}"#)]
      : []
    drawingsRevision += 1
    draftsRevision += 1
  }

  func fetchRevisions(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawSyncRevisions? {
    calls.append("revisions")
    let captured: RemoteDrawSyncRevisions = decodeHandoff(
      #"{"drawings":"\#(drawingsRevision)","drafts":"\#(draftsRevision)","metadata":"0","files":"0"}"#)
    if let gate = revisionGate {
      revisionGate = nil
      await gate.wait()
    }
    return captured
  }

  func fetchSession(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawReceiverSession {
    calls.append("session")
    return decodeHandoff(#"{"id":"\#(credentials.sessionId)","status":"active"}"#)
  }

  func fetchSenders(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverSenderRecord] {
    calls.append("senders")
    return []
  }

  func fetchDrafts(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDraft] {
    calls.append("drafts")
    return credentials.sessionId == "handoff-session" ? drafts : []
  }

  func fetchDrawings(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDrawing] {
    calls.append("drawings")
    let captured = credentials.sessionId == "handoff-session" ? drawings : []
    let failure = drawingError
    if let gate = drawingGate {
      drawingGate = nil
      await gate.wait()
    }
    if let failure { throw failure }
    return captured
  }

  func undo(_ credentials: RemoteDrawReceiverCredentials) async throws {}
  func clear(_ credentials: RemoteDrawReceiverCredentials) async throws {}
}

private func decodeHandoff<T: Decodable>(_ json: String) -> T {
  try! JSONDecoder().decode(T.self, from: Data(json.utf8))
}
