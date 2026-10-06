import Foundation
import XCTest

@testable import RemoteDrawSenderKit

/// Virtual time for the session's background loops.
///
/// Sleepers park until ``advance(by:)`` moves the clock past their deadline, so
/// a minute of cadence runs in well under a second and the counts are exact.
/// ``settle()`` lets the woken main-actor work and the fake transport's hops run
/// before the next deadline is released.
final class ManualPollClock: RemoteDrawPollClock, @unchecked Sendable {
  private struct Sleeper {
    let id: Int
    let deadline: TimeInterval
    let continuation: CheckedContinuation<Void, Error>
  }

  private let lock = NSLock()
  private var current: TimeInterval = 0
  private var nextID = 0
  private var sleepers: [Sleeper] = []
  private var cancelledBeforeRegistering: Set<Int> = []

  var now: TimeInterval {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  /// Tasks parked on this clock. Zero after teardown means no loop survived.
  var sleeperCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sleepers.count
  }

  func sleep(seconds: TimeInterval) async throws {
    let id = allocateID()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        self.register(id: id, seconds: seconds, continuation: continuation)
      }
    } onCancel: {
      self.cancel(id: id)
    }
  }

  private func allocateID() -> Int {
    lock.lock()
    defer { lock.unlock() }
    nextID += 1
    return nextID
  }

  private func register(id: Int, seconds: TimeInterval, continuation: CheckedContinuation<Void, Error>) {
    lock.lock()
    if cancelledBeforeRegistering.remove(id) != nil {
      lock.unlock()
      continuation.resume(throwing: CancellationError())
      return
    }
    sleepers.append(Sleeper(id: id, deadline: current + max(0, seconds), continuation: continuation))
    lock.unlock()
  }

  private func cancel(id: Int) {
    lock.lock()
    guard let index = sleepers.firstIndex(where: { $0.id == id }) else {
      cancelledBeforeRegistering.insert(id)
      lock.unlock()
      return
    }
    let sleeper = sleepers.remove(at: index)
    lock.unlock()
    sleeper.continuation.resume(throwing: CancellationError())
  }

  private func popDue(upTo target: TimeInterval) -> [Sleeper]? {
    lock.lock()
    defer { lock.unlock() }
    guard let earliest = sleepers.map(\.deadline).min(), earliest <= target else { return nil }
    current = max(current, earliest)
    let due = sleepers.filter { $0.deadline <= current }
    sleepers.removeAll { $0.deadline <= current }
    return due
  }

  private func setNow(_ value: TimeInterval) {
    lock.lock()
    current = max(current, value)
    lock.unlock()
  }

  @MainActor
  func settle() async {
    for _ in 0..<4 {
      for _ in 0..<50 { await Task.yield() }
      try? await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  /// Releases every deadline up to and including `now + seconds`, in order.
  @MainActor
  func advance(by seconds: TimeInterval) async {
    let target = now + seconds
    await settle()
    var wakes = 0
    while let due = popDue(upTo: target) {
      for sleeper in due { sleeper.continuation.resume() }
      await settle()
      wakes += 1
      precondition(wakes < 10_000, "a loop is sleeping for zero seconds")
    }
    setNow(target)
    await settle()
  }
}

/// A one-shot latch a transport call can park on.
final class SyncGate: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, Never>?
  private var opened = false
  private var _entered = false

  var entered: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _entered
  }

  func wait() async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      self.park(continuation)
    }
  }

  private func park(_ continuation: CheckedContinuation<Void, Never>) {
    lock.lock()
    _entered = true
    if opened {
      lock.unlock()
      continuation.resume()
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func open() {
    lock.lock()
    opened = true
    let waiting = continuation
    continuation = nil
    lock.unlock()
    waiting?.resume()
  }
}

/// ``FakeTransport`` plus `/v1/sender/sync`. Every other route delegates, so
/// its call log stays the single record of snapshot reads.
@MainActor
final class SyncTransport: RemoteDrawSenderTransport {
  let base = FakeTransport()
  private let lock = NSLock()
  private var _syncTokens: [String] = []
  private var _revisions = RemoteDrawSyncRevisions(drawings: "d0", metadata: "m0")

  /// Runs before the answer. Throw to fail the tick; suspend to make it slow.
  var syncHook: ((String) async throws -> Void)?
  /// When set, replaces the stored metadata revision — used to mimic the
  /// server's ten-second clock bucket.
  var metadataProvider: (() -> String)?

  var syncTokens: [String] {
    lock.lock()
    defer { lock.unlock() }
    return _syncTokens
  }

  var syncCount: Int { syncTokens.count }

  func set(drawings: String? = nil, metadata: String? = nil) {
    lock.lock()
    _revisions = RemoteDrawSyncRevisions(
      drawings: drawings ?? _revisions.drawings, metadata: metadata ?? _revisions.metadata)
    lock.unlock()
  }

  private func recordSync(_ token: String) {
    lock.lock()
    _syncTokens.append(token)
    lock.unlock()
  }

  private var currentRevisions: RemoteDrawSyncRevisions {
    lock.lock()
    defer { lock.unlock() }
    return _revisions
  }

  /// Revisions are read *after* the hook, so a parked sync answers with
  /// whatever the board became while it was parked — like a slow server.
  func sync(senderToken: String) async throws -> RemoteDrawSyncRevisions {
    recordSync(senderToken)
    try await syncHook?(senderToken)
    let stored = currentRevisions
    guard let metadataProvider else { return stored }
    return RemoteDrawSyncRevisions(drawings: stored.drawings, metadata: metadataProvider())
  }

  // MARK: Delegated

  func join(joinToken: String, device: RemoteDrawSenderDevice?) async throws -> RemoteDrawJoinResponse {
    try await base.join(joinToken: joinToken, device: device)
  }
  func session(senderToken: String) async throws -> RemoteDrawSessionResponse {
    try await base.session(senderToken: senderToken)
  }
  func ping(senderToken: String, active: Bool) async throws {
    try await base.ping(senderToken: senderToken, active: active)
  }
  func updateDraft(_ request: RemoteDrawDraftRequest) async throws -> RemoteDrawDraftAck {
    try await base.updateDraft(request)
  }
  func commitStroke(_ request: RemoteDrawCommitRequest) async throws -> RemoteDrawCommitResult {
    try await base.commitStroke(request)
  }
  func replaceStroke(_ request: RemoteDrawReplaceRequest) async throws -> RemoteDrawReplaceResult {
    try await base.replaceStroke(request)
  }
  func clearDraft(senderToken: String, sequence: Int?) async throws {
    try await base.clearDraft(senderToken: senderToken, sequence: sequence)
  }
  func undo(senderToken: String) async throws -> RemoteDrawUndoResult {
    try await base.undo(senderToken: senderToken)
  }
  func clear(senderToken: String) async throws -> RemoteDrawClearResult {
    try await base.clear(senderToken: senderToken)
  }
  func submit(senderToken: String, clientSubmissionId: String, metadata: [String: RemoteDrawJSONValue]?)
    async throws -> RemoteDrawReceipt
  {
    try await base.submit(senderToken: senderToken, clientSubmissionId: clientSubmissionId, metadata: metadata)
  }
  func editElements(senderToken: String, edit: RemoteDrawElementEdit) async throws -> RemoteDrawEditResult {
    try await base.editElements(senderToken: senderToken, edit: edit)
  }
  func drawings(senderToken: String) async throws -> RemoteDrawDrawingsResponse {
    try await base.drawings(senderToken: senderToken)
  }
  func updateProjection(senderToken: String, projection: RemoteDrawProjection) async throws
    -> RemoteDrawProjection
  {
    try await base.updateProjection(senderToken: senderToken, projection: projection)
  }
  func refresh(senderToken: String) async throws -> RemoteDrawRefreshResponse {
    try await base.refresh(senderToken: senderToken)
  }
  func closeProjection(senderToken: String, disconnect: Bool) async throws {
    try await base.closeProjection(senderToken: senderToken, disconnect: disconnect)
  }
}

/// The launch P0: board polling is one revision-gated sync loop, not two
/// unconditional 0.9 s snapshot loops.
@MainActor
final class SyncPollingTests: XCTestCase {
  private func makeSender(
    _ transport: any RemoteDrawSenderTransport,
    clock: ManualPollClock,
    capabilities: [String] = ["draw", "viewExisting"],
    automaticallyRefreshDrawings: Bool = true
  ) -> RemoteDrawSenderSession {
    // Sync-gated session reads adopt grants, so the fixture's session answer
    // grants exactly what the sender was adopted with unless a test says so.
    if let sync = transport as? SyncTransport { grant(capabilities, on: sync.base) }
    if let legacy = transport as? FakeTransport, legacy.sessionResult == nil {
      grant(capabilities, on: legacy)
    }
    return .adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1", session: .stub(),
      capabilities: capabilities, automaticallyRefreshDrawings: automaticallyRefreshDrawings,
      pollClock: clock)
  }

  private func grant(_ capabilities: [String], on transport: FakeTransport) {
    transport.sessionResult = .success(RemoteDrawSessionResponse(
      senderId: "sender_1", session: .stub(capabilities: capabilities),
      capabilities: capabilities, lastSequence: nil))
  }

  private func counts(_ transport: SyncTransport) -> String {
    "sync=\(transport.syncCount) session=\(transport.base.callCount(.session)) "
      + "drawings=\(transport.base.callCount(.drawings)) ping=\(transport.base.callCount(.ping))"
  }

  func testH01SnapshotRetryAfterBlocksAllMaintenanceAndSurvivesResume() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    transport.set(metadata: "m1")
    transport.base.sessionHook = { throw RemoteDrawError.rateLimited(retryAfter: 12, bucket: "snapshots") }
    await clock.advance(by: 1)
    guard case .retryLater(let until, _) = sender.maintenanceState else { return XCTFail("read failure was swallowed") }
    let syncs = transport.syncCount
    await sender.markInactive()
    await sender.markActive()
    await clock.advance(by: 10)
    XCTAssertEqual(transport.syncCount, syncs, "foreground cannot shorten a snapshot's Retry-After")
    XCTAssertGreaterThan(until, clock.now)
    transport.base.sessionHook = nil
    await clock.advance(by: 3)
    XCTAssertEqual(sender.maintenanceState, .current)
    XCTAssertNil(sender.maintenanceError)
    sender.leave()
  }

  func testH01IncludedCapacityRefusalStopsHealthyHeartbeats() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    transport.syncHook = { _ in throw RemoteDrawError.server(status: 409,
      code: "included_capacity_exhausted", message: "Synchronization maintenance capacity is exhausted.") }
    await clock.advance(by: 1)
    guard case .capacityExhausted = sender.maintenanceState else { return XCTFail("maintenance was reported healthy") }
    let pings = transport.base.callCount(.ping)
    let syncs = transport.syncCount
    await clock.advance(by: 20)
    XCTAssertEqual(transport.base.callCount(.ping), pings)
    XCTAssertEqual(transport.syncCount, syncs)
    sender.leave()
  }

  func testH01HandoffWaitsForAnOldReadThatIgnoresCancellation() async throws {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let gate = SyncGate()
    transport.set(drawings: "d1")
    transport.base.drawingsAsyncHook = { await gate.wait() }
    await clock.advance(by: 1)
    XCTAssertTrue(gate.entered)
    var complete = false
    let handoff = Task { let token = try await sender.handoff(); complete = true; return token }
    await clock.settle()
    XCTAssertFalse(complete)
    gate.open()
    let token = try await handoff.value
    XCTAssertEqual(token, "rd_send_1")
    XCTAssertTrue(complete)
    let syncs = transport.syncCount
    await clock.advance(by: 5)
    XCTAssertEqual(transport.syncCount, syncs)
    XCTAssertEqual(sender.phase, .ended(.left))
  }

  func testH01LateDrawingAnswerCannotPublishAfterBackground() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let original = sender.drawingSnapshot?.payload
    let gate = SyncGate()
    transport.base.drawingsJSON = #"{"items":[{"id":"late","type":"freehand","points":[]}] }"#
    transport.base.drawingsAsyncHook = { await gate.wait() }
    transport.set(drawings: "d1")
    await clock.advance(by: 1)
    XCTAssertTrue(gate.entered)
    await sender.markInactive()
    gate.open()
    await clock.settle()
    XCTAssertEqual(sender.drawingSnapshot?.payload, original)
    XCTAssertFalse(sender.strokes.contains { $0.id == "late" })
    sender.leave()
  }

  // MARK: - Idle budget

  func testAnIdleMinuteSyncsOncePerSecondAndReadsSnapshotsOnlyOnChange() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    // The server folds a ten-second clock bucket into `metadata`.
    transport.metadataProvider = { "m:\(Int(clock.now / 10))" }
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 1)

    // Startup: the first tick may coalesce with the immediate read. Let the
    // next tick confirm its revision before measuring unchanged snapshots.
    let startupDrawings = transport.base.callCount(.drawings)
    XCTAssertEqual(startupDrawings, 2)
    XCTAssertEqual(transport.syncCount, 2)

    await clock.advance(by: 58.9)
    XCTAssertTrue((59...61).contains(transport.syncCount), "sync count \(transport.syncCount)")
    XCTAssertLessThanOrEqual(transport.base.callCount(.session), 7)
    XCTAssertLessThanOrEqual(transport.base.callCount(.drawings), 2)
    XCTAssertEqual(
      transport.base.callCount(.drawings), startupDrawings,
      "an unchanged drawings revision never buys another snapshot")
    // For the report. Synthetic: a 10 s metadata fixture and an instant fake
    // transport on a virtual clock, not counts measured against a real server.
    print("[SyncPollingTests] idle 59.9 s, metadata every 10 s (synthetic): \(counts(transport))")
    sender.leave()
  }

  func testMetadataMovingEveryFiveSecondsStillBuysNoExtraDrawingReads() async {
    // Sliding expiry: every 5 s heartbeat moves `expiresAt`, which is part of
    // the public session the metadata fingerprint hashes.
    let transport = SyncTransport()
    let clock = ManualPollClock()
    transport.metadataProvider = { "m:\(Int(clock.now / 5))" }
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 1)
    let startupDrawings = transport.base.callCount(.drawings)
    XCTAssertEqual(startupDrawings, 2)

    await clock.advance(by: 58.9)
    XCTAssertTrue((59...61).contains(transport.syncCount), "sync count \(transport.syncCount)")
    XCTAssertLessThanOrEqual(transport.base.callCount(.session), 13)
    XCTAssertEqual(transport.base.callCount(.drawings), startupDrawings, "metadata churn is not a drawings change")
    print("[SyncPollingTests] idle 59.9 s, metadata every 5 s (synthetic): \(counts(transport))")
    sender.leave()
  }

  func testACommitBetweenTheInitialReadAndTheFirstSyncIsShownByTheConfirmingRead() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let gate = SyncGate()
    transport.syncHook = { _ in await gate.wait() }
    let sender = makeSender(transport, clock: clock)
    await clock.settle()

    // The immediate read has finished and shows an empty board.
    XCTAssertTrue(gate.entered)
    XCTAssertEqual(transport.base.callCount(.drawings), 1)
    XCTAssertTrue(sender.strokes.isEmpty)

    // Another sender commits; the first sync, still in flight, reports it.
    transport.base.drawingsJSON = #"{"items":[{"id":"remote_commit","type":"freehand","points":[{"x":0.1,"y":0.1},{"x":0.2,"y":0.2}]}]}"#
    transport.set(drawings: "d1")
    transport.syncHook = nil
    gate.open()
    await clock.settle()

    XCTAssertEqual(transport.base.callCount(.drawings), 2, "the confirming read")
    XCTAssertEqual(sender.strokes.map(\.id), ["remote_commit"])
    await clock.advance(by: 5)
    XCTAssertEqual(transport.base.callCount(.drawings), 2)
    sender.leave()
  }

  // MARK: - Grants

  func testLosingViewExistingStopsDrawingReadsEvenWhenTheBoardChanges() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let drawings = transport.base.callCount(.drawings)

    grant(["draw"], on: transport.base)
    transport.set(metadata: "m1")
    await clock.advance(by: 1)
    XCTAssertFalse(sender.capabilities.contains(.viewExisting))
    XCTAssertEqual(sender.session?.id, "session_1")
    XCTAssertEqual(sender.senderId, "sender_1")

    transport.set(drawings: "d1")
    await clock.advance(by: 5)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)
    sender.leave()
  }

  func testRegainingViewExistingReadsOnceEvenWhenTheDrawingRevisionIsUnchanged() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let drawings = transport.base.callCount(.drawings)

    grant(["draw"], on: transport.base)
    transport.set(metadata: "m1")
    await clock.advance(by: 3)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)

    // Drawings stay at "d0", the revision the last read recorded.
    grant(["draw", "viewExisting"], on: transport.base)
    transport.set(metadata: "m2")
    await clock.advance(by: 1)
    XCTAssertTrue(sender.capabilities.contains(.viewExisting))
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    await clock.advance(by: 5)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    sender.leave()
  }

  func testTheLegacyOwnerAdoptsGrantsWithoutRequiringAnAppSideWatcher() async {
    let transport = FakeTransport()
    grant(["draw", "viewExisting"], on: transport)
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock, capabilities: ["draw"])
    await clock.advance(by: 29.9)
    XCTAssertEqual(sender.capabilities, [.draw, .viewExisting])
    XCTAssertTrue((6...7).contains(transport.callCount(.drawings)))
    XCTAssertTrue((6...7).contains(transport.callCount(.session)))
    sender.leave()
  }

  func testDrawingOptOutDoesNotTransferTheSDKsMaintenanceOwnership() async {
    for (capabilities, automatic) in [(["draw"], true), (["draw", "viewExisting"], false)] {
      let transport = SyncTransport()
      let clock = ManualPollClock()
      let sender = makeSender(
        transport, clock: clock, capabilities: capabilities, automaticallyRefreshDrawings: automatic)
      await clock.advance(by: 2.5)
      transport.set(drawings: "d1")
      await clock.advance(by: 2)
      transport.set(drawings: "d2")
      await clock.advance(by: 2)
      XCTAssertEqual(transport.base.callCount(.drawings), 0)
      XCTAssertGreaterThanOrEqual(transport.syncCount, 6)
      sender.leave()
    }
  }

  // MARK: - Change gating

  func testAChangedRevisionBuysExactlyOneReadOfWhatChanged() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 3.5)
    let drawings = transport.base.callCount(.drawings)
    let sessions = transport.base.callCount(.session)

    transport.set(drawings: "d1")
    await clock.advance(by: 5)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    XCTAssertEqual(transport.base.callCount(.session), sessions, "metadata did not move")

    transport.set(metadata: "m1")
    await clock.advance(by: 5)
    XCTAssertEqual(transport.base.callCount(.session), sessions + 1)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1, "drawings did not move")
    sender.leave()
  }

  // MARK: - Failure

  func testAFailedSyncRetriesOnCadenceWithoutLosingTheChange() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let drawings = transport.base.callCount(.drawings)
    let sessions = transport.base.callCount(.session)
    let syncs = transport.syncCount

    transport.syncHook = { _ in throw RemoteDrawError.offline }
    transport.set(drawings: "d1", metadata: "m1")
    await clock.advance(by: 3)
    XCTAssertEqual(transport.syncCount, syncs + 3, "retried once per second")
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)
    XCTAssertEqual(transport.base.callCount(.session), sessions)

    transport.syncHook = nil
    await clock.advance(by: 1)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    XCTAssertEqual(transport.base.callCount(.session), sessions + 1)
    XCTAssertEqual(sender.phase, .ready)
    sender.leave()
  }

  func testAFailedSnapshotReadKeepsItsCursorAndRetriesUntilItLands() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let drawings = transport.base.callCount(.drawings)
    let sessions = transport.base.callCount(.session)

    transport.base.drawingsAsyncHook = { throw RemoteDrawError.offline }
    transport.base.sessionHook = { throw RemoteDrawError.offline }
    transport.set(drawings: "d1", metadata: "m1")
    await clock.advance(by: 2)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings, "failed metadata gates dependent drawing reads")
    XCTAssertEqual(transport.base.callCount(.session), sessions + 2)

    transport.base.drawingsAsyncHook = nil
    transport.base.sessionHook = nil
    await clock.advance(by: 1)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    XCTAssertEqual(transport.base.callCount(.session), sessions + 3)

    await clock.advance(by: 4)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1, "landed, so no more reads")
    XCTAssertEqual(transport.base.callCount(.session), sessions + 3)
    sender.leave()
  }

  func testARateLimitedSyncWaitsForRetryAfter() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let syncs = transport.syncCount

    transport.syncHook = { _ in throw RemoteDrawError.rateLimited(retryAfter: 4, bucket: "sender_sync") }
    await clock.advance(by: 3.5)
    XCTAssertEqual(transport.syncCount, syncs + 1, "one refused tick, then a four-second wait")

    transport.syncHook = nil
    await clock.advance(by: 1)
    XCTAssertEqual(transport.syncCount, syncs + 2)
    sender.leave()
  }

  func testARetryAfterLongerThanThirtySecondsIsHonouredInFull() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let syncs = transport.syncCount

    // Refused at t = 3 with 45 s: nothing may be sent before t = 48.
    transport.syncHook = { _ in throw RemoteDrawError.rateLimited(retryAfter: 45, bucket: "sender_sync") }
    await clock.advance(by: 1)
    XCTAssertEqual(transport.syncCount, syncs + 1)
    transport.syncHook = nil
    await clock.advance(by: 44.4)
    XCTAssertEqual(transport.syncCount, syncs + 1, "no retry before the server's retryAfter")
    await clock.advance(by: 0.2)
    XCTAssertEqual(transport.syncCount, syncs + 2)
    sender.leave()
  }

  // MARK: - Drawing never waits

  func testRetryAfterStartsWhenTheSlowRefusalArrives() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let previous = transport.syncCount
    let gate = SyncGate()
    transport.syncHook = { _ in
      await gate.wait()
      throw RemoteDrawError.rateLimited(retryAfter: 4, bucket: "sender_sync")
    }
    await clock.advance(by: 2.5)
    XCTAssertTrue(gate.entered)
    XCTAssertEqual(transport.syncCount, previous + 1)
    transport.syncHook = nil
    gate.open()
    await clock.settle()
    await clock.advance(by: 3.9)
    XCTAssertEqual(transport.syncCount, previous + 1, "wait four seconds after the refusal, excluding its RTT")
    await clock.advance(by: 0.1)
    XCTAssertEqual(transport.syncCount, previous + 2)
    sender.leave()
  }

  func testASlowSyncNeverDelaysTheInitialReadTheFirstDraftOrTheCommit() async throws {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let gate = SyncGate()
    transport.syncHook = { _ in await gate.wait() }
    let sender = makeSender(transport, clock: clock)
    await clock.settle()

    XCTAssertTrue(gate.entered)
    XCTAssertEqual(transport.base.callCount(.drawings), 1, "the first paint does not wait for sync")

    sender.begin(stroke: "first", tool: .freehand)
    sender.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    await clock.settle()
    XCTAssertGreaterThanOrEqual(transport.base.callCount(.draft), 1)
    _ = try await sender.end(stroke: "first")
    XCTAssertEqual(transport.base.callCount(.commit), 1)

    // A hung tick is not stacked on: no second sync while the first is out.
    await clock.advance(by: 5)
    XCTAssertEqual(transport.syncCount, 1)

    transport.syncHook = nil
    gate.open()
    await clock.settle()
    sender.leave()
  }

  // MARK: - Fallback

  func testACustomTransportWithoutSyncFallsBackToFiveSecondSnapshots() async {
    let transport = FakeTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.settle()
    XCTAssertEqual(transport.callCount(.session), 1, "metadata is read at once on fallback")
    XCTAssertEqual(transport.callCount(.drawings), 1, "the initial read is not repeated")

    await clock.advance(by: 59.9)
    XCTAssertTrue((11...13).contains(transport.callCount(.session)), "\(transport.callCount(.session))")
    XCTAssertTrue((11...13).contains(transport.callCount(.drawings)), "\(transport.callCount(.drawings))")
    sender.leave()
  }

  func testOnlyTheExplicitUnsupportedErrorSelectsTheLegacyCadence() async {
    let unsupported = SyncTransport()
    unsupported.syncHook = { _ in throw RemoteDrawSyncUnsupportedError() }
    let unsupportedClock = ManualPollClock()
    let legacy = makeSender(unsupported, clock: unsupportedClock)
    await unsupportedClock.advance(by: 29.9)
    XCTAssertEqual(unsupported.syncCount, 1, "never asked again")
    XCTAssertTrue((6...7).contains(unsupported.base.callCount(.session)))
    legacy.leave()

    let failing = SyncTransport()
    failing.syncHook = { _ in
      throw RemoteDrawError.server(status: 404, code: "session_not_found", message: nil)
    }
    let failingClock = ManualPollClock()
    let gated = makeSender(failing, clock: failingClock)
    await failingClock.advance(by: 29.9)
    XCTAssertGreaterThanOrEqual(failing.syncCount, 29, "an ordinary failure keeps the sync loop")
    XCTAssertEqual(failing.base.callCount(.session), 0, "and buys no unconditional snapshots")
    gated.leave()
  }

  // MARK: - Lifecycle

  func testLeaveStopsEveryLoopAndParksNothing() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    sender.leave()
    await clock.settle()
    let syncs = transport.syncCount
    let sessions = transport.base.callCount(.session)
    let drawings = transport.base.callCount(.drawings)
    let pings = transport.base.callCount(.ping)

    await clock.advance(by: 30)
    XCTAssertEqual(transport.syncCount, syncs)
    XCTAssertEqual(transport.base.callCount(.session), sessions)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)
    XCTAssertEqual(transport.base.callCount(.ping), pings)
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testAReleasedSessionIsNotKeptAliveByItsLoops() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    weak var released: RemoteDrawSenderSession?
    do {
      let sender = makeSender(transport, clock: clock)
      released = sender
      await clock.advance(by: 1.5)
    }
    await clock.advance(by: 6)
    XCTAssertNil(released)
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testBackgroundStopsPollingAndForegroundReadsOnceWithinTheFloor() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)

    await sender.markInactive()
    let syncs = transport.syncCount
    let sessions = transport.base.callCount(.session)
    let drawings = transport.base.callCount(.drawings)
    await clock.advance(by: 10)
    XCTAssertEqual(transport.syncCount, syncs, "nothing polls in the background")
    XCTAssertEqual(transport.base.callCount(.session), sessions)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)

    // Revisions did not move, but nothing watched them: resume reads once.
    await sender.markActive()
    await clock.settle()
    XCTAssertEqual(transport.syncCount, syncs + 1)
    XCTAssertEqual(transport.base.callCount(.session), sessions + 1)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings + 1)
    await clock.advance(by: 0.5)
    XCTAssertEqual(transport.syncCount, syncs + 1)

    // A flap inside the floor cannot start a tick early.
    await sender.markInactive()
    await sender.markActive()
    await clock.settle()
    XCTAssertEqual(transport.syncCount, syncs + 1)
    await clock.advance(by: 0.45)
    XCTAssertEqual(transport.syncCount, syncs + 2)
    sender.leave()
  }

  func testARotatedCredentialDropsTheInFlightAnswerAndRereadsWithTheNewToken() async {
    let transport = SyncTransport()
    let clock = ManualPollClock()
    let sender = makeSender(transport, clock: clock)
    await clock.advance(by: 2.5)
    let sessions = transport.base.callCount(.session)
    let drawings = transport.base.callCount(.drawings)

    let gate = SyncGate()
    transport.syncHook = { _ in await gate.wait() }
    await clock.advance(by: 0.6)
    XCTAssertTrue(gate.entered)

    transport.base.refreshResult = .success(RemoteDrawRefreshResponse(
      senderToken: "rd_send_new", senderId: "sender_1",
      capabilities: ["draw", "viewExisting"], lastSequence: 1))
    let recovered = await sender.recoverRejectedCredential("rd_send_1")
    XCTAssertTrue(recovered)

    // Rotation cleared the cursors, so the old credential's late answer differs
    // from them. Acting on it would read with a revision nobody can vouch for.
    transport.syncHook = nil
    gate.open()
    await clock.settle()
    XCTAssertEqual(transport.base.callCount(.session), sessions)
    XCTAssertEqual(transport.base.callCount(.drawings), drawings)

    // The next tick is due at t = 4 and runs under the new credential.
    await clock.advance(by: 1)
    XCTAssertEqual(transport.syncTokens.last, "rd_send_new")
    let newSessions = transport.base.calls.filter { $0.route == .session }.dropFirst(sessions)
    let newDrawings = transport.base.calls.filter { $0.route == .drawings }.dropFirst(drawings)
    XCTAssertEqual(newSessions.map(\.senderToken), ["rd_send_new"])
    XCTAssertEqual(newDrawings.map(\.senderToken), ["rd_send_new"])
    sender.leave()
  }
}
