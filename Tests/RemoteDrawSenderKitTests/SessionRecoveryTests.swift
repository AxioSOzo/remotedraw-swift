import XCTest
@testable import RemoteDrawSenderKit

/// Deferred transport answers exercise races that immediate canned responses hide.
@MainActor
final class SessionRecoveryTests: XCTestCase {
  private func session(_ transport: FakeTransport,
    tokenProvider: (@Sendable () async throws -> String)? = nil,
    pollClock: any RemoteDrawPollClock = RemoteDrawSystemPollClock()
  ) -> RemoteDrawSenderSession {
    .adopt(senderToken: "rd_send_old", transport: transport, senderId: "sender_1",
      session: .stub(), capabilities: ["draw", "undo", "clear", "submit"],
      tokenProvider: tokenProvider, pollClock: pollClock)
  }

  private func configureRefresh(_ transport: FakeTransport) {
    transport.refreshResult = .success(RemoteDrawRefreshResponse(
      senderToken: "rd_send_new", senderId: "sender_1", capabilities: ["draw"], lastSequence: 20))
  }

  func testCredentialRecoveryPreservesLiveStrokeUntilCommit() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    transport.pingHook = { token, active in
      if active && token == "rd_send_old" { throw RemoteDrawError.tokenRejected }
    }
    let sender = session(transport)
    sender.begin(stroke: "rotation-live")
    sender.append([.init(x: 0.1, y: 0.2), .init(x: 0.3, y: 0.4)])
    await sender.markActive()
    XCTAssertEqual(sender.senderToken, "rd_send_new")
    XCTAssertNotNil(sender.live)
    _ = try await sender.end(stroke: "rotation-live")
    XCTAssertNil(sender.live)
    XCTAssertEqual(transport.commitAttempts, 1)
    sender.stopLocally()
  }

  func testForegroundReopensProjectionAfterCredentialRecovery() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    var activeTokens: [String] = []
    transport.pingHook = { token, active in
      guard active else { return }
      activeTokens.append(token)
      if token == "rd_send_old" { throw RemoteDrawError.tokenRejected }
    }
    let sender = session(transport)
    await sender.markActive()
    XCTAssertEqual(activeTokens, ["rd_send_old", "rd_send_new"])
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertNil(sender.lastError)
    XCTAssertNotEqual(sender.phase, .ended(.tokenLost))
    sender.stopLocally()
  }

  func testBackgroundDuringForegroundRecoveryDoesNotReplayActivation() async throws {
    let transport = FakeTransport()
    let clock = transport.holdAutomaticPolling()
    configureRefresh(transport)
    let gate = RecoveryGate()
    transport.refreshHook = { await gate.enter() }
    var activeTokens: [String] = []
    transport.pingHook = { token, active in
      guard active else { return }
      activeTokens.append(token)
      if token == "rd_send_old" { throw RemoteDrawError.tokenRejected }
    }
    let sender = session(transport, pollClock: clock)
    // Begin from the background so this foreground task owns the activation
    // and its recovery, without racing the automatic startup presence request.
    await sender.markInactive()
    let foreground = Task { await sender.markActive() }
    await gate.waitForEntry()
    await sender.markInactive()
    await gate.release()
    await foreground.value
    XCTAssertEqual(activeTokens, ["rd_send_old"])
    XCTAssertEqual(sender.senderToken, "rd_send_new")
    XCTAssertEqual(transport.lastPingWasActive, false)
    sender.stopLocally()
  }

  func testHeartbeatRetriesForegroundActivationAfterOfflineFailure() async throws {
    let transport = FakeTransport()
    var activeAttempts = 0
    let restored = expectation(description: "Heartbeat restores the active projection")
    transport.pingHook = { _, active in
      guard active else { return }
      activeAttempts += 1
      if activeAttempts == 1 { throw RemoteDrawError.offline }
      restored.fulfill()
    }
    let sender = session(transport)
    await sender.markActive()
    XCTAssertEqual(activeAttempts, 1)
    await fulfillment(of: [restored], timeout: RemoteDrawProtocolLimits.presenceInterval + 2)
    XCTAssertEqual(activeAttempts, 2)
    XCTAssertEqual(transport.refreshAttempts, 0)
    sender.stopLocally()
  }

  func testTerminalFailureOnPresenceReplayEndsTheSession() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    transport.pingHook = { token, active in
      guard active else { return }
      if token == "rd_send_old" { throw RemoteDrawError.tokenRejected }
      throw RemoteDrawError.sessionEnded
    }
    let sender = session(transport)
    await sender.markActive()
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(sender.phase, .ended(.ended))
  }

  func testConcurrentAuthenticationFailuresShareOneRefreshAndReplayEachCommit() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    let refresh = RecoveryGate()
    transport.refreshHook = { await refresh.enter() }
    transport.commitAsyncHook = { request in
      if request.senderToken == "rd_send_old" { throw RemoteDrawError.tokenRejected }
    }
    let sender = session(transport)
    let first = Task { try await sender.commitText("one", at: .init(x: 0.1, y: 0.2)) }
    await refresh.waitForEntry()
    let second = Task { try await sender.commitText("two", at: .init(x: 0.3, y: 0.4)) }
    while transport.commitAttempts < 2 { await Task.yield() }
    XCTAssertNotEqual(sender.phase, .ended(.tokenLost))
    await refresh.release()
    _ = try await first.value
    _ = try await second.value
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(transport.commitAttempts, 4)
    XCTAssertEqual(Set(transport.commitRequests.map(\.clientStrokeId)).count, 2)
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(sender.senderToken, "rd_send_new")
    sender.stopLocally()
  }

  func testHostPollRecoverySharesSDKRefreshAndIgnoresLateOldTokenFailures() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    let gate = RecoveryGate()
    transport.refreshHook = { await gate.enter() }
    let sender = session(transport)
    let firstPoll = Task { await sender.recoverRejectedCredential("rd_send_old") }
    await gate.waitForEntry()
    let secondPoll = Task { await sender.recoverRejectedCredential("rd_send_old") }
    await gate.release()
    let firstRecovered = await firstPoll.value
    let secondRecovered = await secondPoll.value
    XCTAssertTrue(firstRecovered)
    XCTAssertTrue(secondRecovered)
    let lateRecovered = await sender.recoverRejectedCredential("rd_send_old")
    XCTAssertTrue(lateRecovered)
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(sender.senderToken, "rd_send_new")
    XCTAssertNotEqual(sender.phase, .ended(.tokenLost))
    sender.stopLocally()
  }

  func testTerminalFailureOfCommitReplayEndsTheSession() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    transport.commitAsyncHook = { request in
      if request.senderToken == "rd_send_old" { throw RemoteDrawError.tokenRejected }
      throw RemoteDrawError.sessionEnded
    }
    let sender = session(transport)
    _ = try? await sender.commitText("pending", at: .init(x: 0.1, y: 0.2))
    XCTAssertEqual(sender.phase, .ended(.ended))
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(transport.commitAttempts, 2)
  }

  func testLateOldCredentialFailureCannotInvalidateTheRotatedToken() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    let late = RecoveryGate()
    transport.commitAsyncHook = { request in
      guard request.senderToken == "rd_send_old" else { return }
      if request.text == "late" { await late.enter() }
      throw RemoteDrawError.tokenRejected
    }
    let sender = session(transport)
    let delayed = Task { try await sender.commitText("late", at: .init(x: 0.1, y: 0.2)) }
    await late.waitForEntry()
    _ = try await sender.commitText("first", at: .init(x: 0.3, y: 0.4))
    await late.release()
    _ = try await delayed.value
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(sender.senderToken, "rd_send_new")
    XCTAssertNotEqual(sender.phase, .ended(.tokenLost))
    XCTAssertNil(sender.lastError)
    sender.stopLocally()
  }

  func testLeavingDuringRefreshDoesNotAdoptLateCredentialsOrReplayInk() async throws {
    let transport = FakeTransport()
    configureRefresh(transport)
    let gate = RecoveryGate()
    transport.refreshHook = { await gate.enter() }
    transport.commitResult = .failure(RemoteDrawError.tokenRejected)
    let sender = session(transport)
    let commit = Task { try? await sender.commitText("pending", at: .init(x: 0.1, y: 0.2)) }
    await gate.waitForEntry()
    sender.leave()
    await gate.release()
    _ = await commit.value
    XCTAssertEqual(sender.phase, .ended(.left))
    XCTAssertEqual(sender.senderToken, "rd_send_old")
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(transport.commitAttempts, 1)
    for _ in 0..<1000 {
      if transport.calls.contains(where: { $0.route == .closeProjection && $0.senderToken == "rd_send_new" }) { break }
      await Task.yield()
    }
    XCTAssertTrue(transport.calls.contains { $0.route == .closeProjection && $0.senderToken == "rd_send_new" })
    let pings = transport.callCount(.ping)
    await sender.markActive()
    XCTAssertEqual(transport.callCount(.ping), pings)
  }

  func testHandoffWaitsForRefreshAndDoesNotRevokeTheTransferredToken() async throws {
    let transport = FakeTransport()
    let clock = transport.holdAutomaticPolling()
    configureRefresh(transport)
    let gate = RecoveryGate()
    transport.refreshHook = { await gate.enter() }
    let sender = session(transport, pollClock: clock)
    await transport.settleStartup()
    // Start recovery without a finger-down stroke: an unfinished stroke must
    // prevent handoff, independently of the credential transfer guarantee.
    let recovery = Task { await sender.recoverRejectedCredential("rd_send_old") }
    await gate.waitForEntry()
    var handoffStarted = false
    var transferred = false
    let handoff = Task {
      handoffStarted = true
      let token = try await sender.handoff()
      transferred = true
      return token
    }
    while !handoffStarted { await Task.yield() }
    XCTAssertFalse(transferred, "handoff must wait until rotation finishes")
    await gate.release()
    let token = try await handoff.value
    _ = await recovery.value
    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(token, "rd_send_new")
    XCTAssertEqual(sender.phase, .ended(.left))
    let pings = transport.callCount(.ping)
    await sender.markActive()
    await sender.closeProjection()
    XCTAssertFalse(transport.calls.contains { $0.route == .closeProjection })
    XCTAssertEqual(transport.callCount(.ping), pings)
  }

  func testForegroundReplaysFailedInkWithIdenticalWirePayloadAndDeduplicatesEcho() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.offline)
    let sender = session(transport)
    do {
      _ = try await sender.commitText("lost response", at: .init(x: 0.1, y: 0.2))
      XCTFail("Expected offline failure")
    } catch {}
    XCTAssertEqual(sender.pendingCommitCount, 1)
    XCTAssertTrue(try XCTUnwrap(sender.strokes.first).isLocalEcho)
    // The server had accepted an earlier attempt but its response was lost.
    transport.commitResult = .success(try .decoded(fromJSON:
      #"{"id":"server_1","duplicate":true,"type":"text","points":[{"x":0.1,"y":0.2}],"text":"lost response"}"#))
    await sender.markActive()
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(sender.strokes.count, 1)
    XCTAssertFalse(try XCTUnwrap(sender.strokes.first).isLocalEcho)
    let bodies = try transport.commitRequests.map { try JSONEncoder().encode($0) }
    // JSON key order is unspecified; compare the decoded dictionaries.
    let first = try XCTUnwrap(try JSONSerialization.jsonObject(with: bodies[0]) as? NSDictionary)
    for body in bodies.dropFirst() {
      XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? NSDictionary, first)
    }
    XCTAssertEqual(transport.commitAttempts, 4)
    sender.stopLocally()
  }

  func testConcurrentOutboxDrainsDoNotDuplicateAnInFlightReplay() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.offline)
    let sender = session(transport)
    _ = try? await sender.commitText("pending", at: .init(x: 0.1, y: 0.2))
    transport.commitResult = nil
    let replay = RecoveryGate()
    transport.commitAsyncHook = { _ in await replay.enter() }
    let first = Task { await sender.retryPendingCommits() }
    await replay.waitForEntry()
    await sender.retryPendingCommits()
    XCTAssertEqual(transport.commitAttempts, 4)
    await replay.release()
    await first.value
    XCTAssertEqual(sender.pendingCommitCount, 0)
    sender.stopLocally()
  }

  func testHandoffAndClearRefuseToDiscardUndeliveredInk() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.offline)
    let sender = session(transport)
    _ = try? await sender.commitText("pending", at: .init(x: 0.1, y: 0.2))
    do { _ = try await sender.handoff(); XCTFail("Expected blocked handoff") } catch {}
    do { _ = try await sender.clear(); XCTFail("Expected blocked clear") } catch {}
    XCTAssertEqual(sender.pendingCommitCount, 1)
    XCTAssertNotEqual(sender.phase, .ended(.left))
    XCTAssertFalse(transport.calls.contains { $0.route == .clear || $0.route == .closeProjection })
    transport.commitResult = nil
    _ = try await sender.clear()
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertTrue(sender.strokes.isEmpty)
    XCTAssertEqual(transport.calls.last?.route, .clear)
    sender.stopLocally()
  }

  func testHostCanRecoverWithANewSenderWhenNoInkIsPending() async throws {
    let transport = FakeTransport()
    transport.sessionResult = .success(.init(senderId: "sender_new", session: .stub(),
      capabilities: ["draw"], lastSequence: 0))
    transport.draftError = RemoteDrawError.tokenRejected
    let sender = session(transport, tokenProvider: { "rd_send_host" })
    sender.begin(stroke: "live")
    sender.append([.init(x: 0.1, y: 0.2)])
    for _ in 0..<1000 {
      if sender.senderToken == "rd_send_host" { break }
      await Task.yield()
    }
    XCTAssertEqual(sender.senderToken, "rd_send_host")
    XCTAssertEqual(sender.senderId, "sender_new")
    sender.stopLocally()
  }

  func testHostNewSenderCannotReplayAmbiguousInkInADifferentDeduplicationNamespace() async throws {
    let transport = FakeTransport()
    transport.sessionResult = .success(.init(senderId: "sender_new", session: .stub(),
      capabilities: ["draw"], lastSequence: 0))
    transport.commitResult = .failure(RemoteDrawError.tokenRejected)
    let sender = session(transport, tokenProvider: { "rd_send_host" })
    _ = try? await sender.commitText("pending", at: .init(x: 0.1, y: 0.2))
    XCTAssertEqual(sender.phase, .ended(.tokenLost))
    XCTAssertEqual(transport.commitAttempts, 1)
    XCTAssertEqual(sender.senderToken, "rd_send_old")
  }
}

private actor RecoveryGate {
  private var arrived = false
  private var opened = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var entries: [CheckedContinuation<Void, Never>] = []

  func enter() async {
    arrived = true
    entries.forEach { $0.resume() }
    entries.removeAll()
    if opened { return }
    await withCheckedContinuation { waiters.append($0) }
  }

  func waitForEntry() async {
    if arrived { return }
    await withCheckedContinuation { entries.append($0) }
  }

  func release() {
    opened = true
    waiters.forEach { $0.resume() }
    waiters.removeAll()
  }
}
