import XCTest

@testable import RemoteDrawSenderKit

/// The opt-in experimental live-update tiers, as a sender sees them.
///
/// Everything here runs against a fake transport with a round trip of about
/// zero. The pacing tests prove a *ceiling* — that no tier sends faster than
/// it negotiated — and nothing about what a device or a network achieves.
@MainActor
final class LiveUpdateTests: XCTestCase {
  // MARK: - Decoding

  func testAnOlderSessionWithoutTheBlockPacesAtTheProtocolCadence() throws {
    let session = try RemoteDrawSession.decoded(fromJSON: #"{"id":"legacy"}"#)
    XCTAssertNil(session.liveUpdate)
    XCTAssertEqual(RemoteDrawLiveUpdateState.draftSendInterval(for: session.liveUpdate), 0.032)
    XCTAssertEqual(
      RemoteDrawLiveUpdateState.draftSendInterval(for: nil), RemoteDrawProtocolLimits.draftSendInterval)
    XCTAssertNil(try RemoteDrawSession.decoded(fromJSON: #"{"id":"s","liveUpdate":null}"#).liveUpdate)
  }

  func testEachGrantedTierPacesAtExactlyOneThousandOverItsHertz() throws {
    for (tier, hz, wireInterval) in Self.wireGrants {
      let state = try XCTUnwrap(try Self.session(liveUpdate: Self.granted(tier, hz, wireInterval)).liveUpdate)
      XCTAssertEqual(state.requestedTier, tier)
      XCTAssertEqual(state.tier, tier)
      XCTAssertEqual(state.negotiatedTier, tier)
      XCTAssertEqual(state, .granted(tier))
      // Fractional on purpose: no rounding to 16/8/4 ms and no ceiling to 17/9/5.
      XCTAssertEqual(state.draftSendInterval, 1 / hz, accuracy: 1e-12)
      XCTAssertNotEqual(state.draftSendInterval, (1 / hz * 1000).rounded() / 1000)
    }
    XCTAssertEqual(RemoteDrawLiveUpdateState.granted(.experimental60).draftSendInterval * 1000, 1000 / 60, accuracy: 1e-9)
  }

  func testADowngradeToNormalPacesAtTheProtocolCadence() throws {
    let state = try XCTUnwrap(try Self.session(liveUpdate: Self.fallback).liveUpdate)
    XCTAssertEqual(state.requestedTier, .experimental120)
    XCTAssertEqual(state.tier, .normal)
    XCTAssertEqual(state.fallbackReason, "disabled_by_operator")
    XCTAssertEqual(state.negotiatedTier, .normal)
    XCTAssertEqual(state.draftSendInterval, 0.032)
  }

  func testUnreadableOrInconsistentBlocksFailSafeTo32ms() throws {
    let cases: [(String, String)] = [
      ("not an object", #""fast""#),
      ("an array", #"[240]"#),
      ("empty", #"{}"#),
      ("an unknown tier", #"{"requestedTier":"experimental480","tier":"experimental480","maxDraftHz":480,"minDraftIntervalMs":2.0833333333333335,"experimental":true,"guaranteed":false}"#),
      ("hertz from another tier", #"{"requestedTier":"experimental240","tier":"experimental240","maxDraftHz":120,"minDraftIntervalMs":8.333333333333334,"experimental":true,"guaranteed":false}"#),
      ("a rounded interval", #"{"requestedTier":"experimental240","tier":"experimental240","maxDraftHz":240,"minDraftIntervalMs":4,"experimental":true,"guaranteed":false}"#),
      ("a missing interval", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"experimental":true,"guaranteed":false}"#),
      ("a string hertz", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":"60","minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false}"#),
      ("a guarantee", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":true}"#),
      ("not experimental", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":false,"guaranteed":false}"#),
      ("missing flags", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668}"#),
      ("a grant above the request", #"{"requestedTier":"experimental60","tier":"experimental240","maxDraftHz":240,"minDraftIntervalMs":4.166666666666667,"experimental":true,"guaranteed":false}"#),
      ("a grant below the request", #"{"requestedTier":"experimental240","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false}"#),
      ("a normal request", #"{"requestedTier":"normal","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false}"#),
      ("a fallback reason on a grant", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false,"fallbackReason":"disabled_by_operator"}"#),
      ("a null fallback reason", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false,"fallbackReason":null}"#),
      ("an unreadable fallback reason", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false,"fallbackReason":{}}"#),
      ("a boolean fallback reason", #"{"requestedTier":"experimental60","tier":"experimental60","maxDraftHz":60,"minDraftIntervalMs":16.666666666666668,"experimental":true,"guaranteed":false,"fallbackReason":false}"#),
      ("an unexplained normal fallback", #"{"requestedTier":"experimental60","tier":"normal","maxDraftHz":31.25,"minDraftIntervalMs":32,"experimental":true,"guaranteed":false}"#),
      ("an unknown normal fallback", #"{"requestedTier":"experimental60","tier":"normal","maxDraftHz":31.25,"minDraftIntervalMs":32,"experimental":true,"guaranteed":false,"fallbackReason":"unknown"}"#),
      ("an interval outside protocol tolerance", #"{"requestedTier":"experimental240","tier":"experimental240","maxDraftHz":240,"minDraftIntervalMs":4.1666667,"experimental":true,"guaranteed":false}"#),
    ]
    for (label, block) in cases {
      let session = try Self.session(liveUpdate: block)
      XCTAssertEqual(session.id, "session_1", "\(label): the session itself must still decode")
      XCTAssertEqual(session.capabilities, ["draw"], label)
      XCTAssertNotNil(session.liveUpdate, "\(label): present is not the same as absent")
      XCTAssertNil(session.liveUpdate?.negotiatedTier, label)
      XCTAssertEqual(RemoteDrawLiveUpdateState.draftSendInterval(for: session.liveUpdate), 0.032, label)
    }
  }

  func testTheJoinAndRefreshResponsesCarryTheBlock() throws {
    let block = Self.grantedJSON(.experimental120)
    let join = try RemoteDrawJoinResponse.decoded(
      fromJSON: #"{"senderToken":"rd_send_1","session":{"id":"session_1","liveUpdate":\#(block)}}"#)
    XCTAssertEqual(join.session?.liveUpdate?.negotiatedTier, .experimental120)
    let refresh = try RemoteDrawRefreshResponse.decoded(
      fromJSON: #"{"senderToken":"rd_send_2","session":{"id":"session_1","liveUpdate":\#(block)}}"#)
    XCTAssertEqual(refresh.session?.liveUpdate?.negotiatedTier, .experimental120)
  }

  func testDraftAnswersDecodeOldAndNewShapes() throws {
    let old = try RemoteDrawDraftAck.decoded(fromJSON: #"{"accepted":true}"#)
    XCTAssertNil(old.liveUpdate)
    XCTAssertNil(old.retryAfterMs)
    XCTAssertFalse(old.isLiveUpdateRateLimited)

    let explicitNull = try RemoteDrawDraftAck.decoded(fromJSON: #"{"accepted":true,"liveUpdate":null}"#)
    XCTAssertNotNil(explicitNull.liveUpdate, "an explicit null must not be confused with an omitted policy")
    XCTAssertNil(explicitNull.liveUpdate?.negotiatedTier)
    XCTAssertEqual(explicitNull.liveUpdate?.draftSendInterval, 0.032)

    let refused = try RemoteDrawDraftAck.decoded(
      fromJSON: #"{"accepted":false,"reason":"live_update_rate","retryAfterMs":17,"liveUpdate":\#(Self.grantedJSON(.experimental60))}"#)
    XCTAssertTrue(refused.isLiveUpdateRateLimited)
    XCTAssertFalse(refused.isStaleSequence)
    XCTAssertEqual(refused.retryAfterMs, 17)
    XCTAssertEqual(refused.liveUpdate?.negotiatedTier, .experimental60)

    let downgraded = try RemoteDrawDraftAck.decoded(
      fromJSON: #"{"accepted":true,"liveUpdate":\#(Self.fallback)}"#)
    XCTAssertEqual(downgraded.liveUpdate?.tier, .normal)

    // Neither new field can cost the answer.
    let unreadable = try RemoteDrawDraftAck.decoded(
      fromJSON: #"{"accepted":false,"reason":"live_update_rate","retryAfterMs":"soon","liveUpdate":7}"#)
    XCTAssertTrue(unreadable.isLiveUpdateRateLimited)
    XCTAssertNil(unreadable.retryAfterMs)
    XCTAssertEqual(RemoteDrawLiveUpdateState.draftSendInterval(for: unreadable.liveUpdate), 0.032)

    // The stale-sequence contract is untouched.
    let stale = try RemoteDrawDraftAck.decoded(
      fromJSON: #"{"accepted":false,"reason":"stale_sequence","lastSequence":9}"#)
    XCTAssertTrue(stale.isStaleSequence)
    XCTAssertEqual(stale.lastSequence, 9)
  }

  // MARK: - Pacing

  func testASessionThatNegotiatedNothingKeepsTheStaticCadence() async throws {
    let transport = FakeTransport()
    transport.joinResult = .success(RemoteDrawJoinResponse(
      senderToken: "rd_send_1", senderId: "sender_1", capabilities: ["draw"], session: .stub()))
    let session = try await RemoteDrawSenderSession.join(token: .join("rd_join_abc"), transport: transport)
    addTeardownBlock { await session.stopLocally() }
    XCTAssertNil(session.liveUpdate)
    XCTAssertEqual(session.effectiveDraftInterval, RemoteDrawSenderSession.draftInterval)
    XCTAssertEqual(RemoteDrawSenderSession.draftInterval, 0.032)
  }

  func testDraftsNeverOutpaceTheNegotiatedCeiling() async throws {
    let tiers: [RemoteDrawLiveUpdateTier?] = [nil, .experimental60, .experimental120, .experimental240]
    for tier in tiers {
      let transport = FakeTransport()
      let session = try await adopt(transport, liveUpdate: tier.map { Self.grantedJSON($0) })
      let interval = tier.map { 1 / $0.maxDraftHz } ?? RemoteDrawProtocolLimits.draftSendInterval
      XCTAssertEqual(session.effectiveDraftInterval, interval, accuracy: 1e-12)

      session.begin(stroke: "s")
      let started = Date()
      for index in 0..<20 {
        session.append([sample(Double(index) / 20, 0.5)])
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
      await settle()
      let elapsed = Date().timeIntervalSince(started)

      let starts = transport.draftStartedAt
      let ceiling = Int((elapsed / interval).rounded(.up)) + 1
      let label = tier?.rawValue ?? "normal"
      XCTAssertLessThanOrEqual(starts.count, ceiling, "\(label): \(starts.count) frames in \(elapsed)s")
      XCTAssertGreaterThan(starts.count, 0, label)
      for (earlier, later) in zip(starts, starts.dropFirst()) {
        XCTAssertGreaterThanOrEqual(later - earlier, interval - 0.003, label)
      }
      session.stopLocally()
    }
  }

  /// The other half of the ceiling test: the drain really does use the
  /// negotiated interval, rather than keeping 32 ms and passing the ceiling
  /// check by being slow. Samples arrive every millisecond or so, far faster
  /// than any tier, so the pacer and not the appends sets the rate. The fake
  /// answers at once, so this says what the pacer permits, not what a device,
  /// its display or a network achieves.
  func testAnExperimentalTierActuallySendsMoreOftenThan32ms() async throws {
    for tier in [RemoteDrawLiveUpdateTier.experimental60, .experimental240] {
      let transport = FakeTransport()
      let session = try await adopt(transport, liveUpdate: Self.grantedJSON(tier))
      session.begin(stroke: "s")
      let started = Date()
      var index = 0
      while Date().timeIntervalSince(started) < 0.3 {
        session.append([sample(0.1 + Double(index % 400) * 0.002, 0.5 + Double(index % 2) * 0.02)])
        index += 1
        try? await Task.sleep(nanoseconds: 1_000_000)
      }
      let starts = transport.draftStartedAt
      await session.cancelStroke()

      let label = tier.rawValue
      guard let first = starts.first, let last = starts.last, starts.count > 2 else {
        XCTFail("\(label): only \(starts.count) frames"); continue
      }
      let span = last - first
      let at32ms = Int((span / RemoteDrawProtocolLimits.draftSendInterval).rounded(.down)) + 1
      XCTAssertGreaterThan(starts.count, at32ms, "\(label): \(starts.count) frames in \(span)s")
      let gaps = zip(starts, starts.dropFirst()).map { $1 - $0 }.sorted()
      XCTAssertLessThan(gaps[gaps.count / 2], 0.025, "\(label): median gap")
      XCTAssertGreaterThanOrEqual(gaps[0], 1 / tier.maxDraftHz - 0.003, "\(label): still a ceiling")
      session.stopLocally()
    }
  }

  func testADowngradingAnswerSlowsTheSameStrokeAtOnce() async throws {
    let transport = FakeTransport()
    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.fallback)}"#)]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 240, accuracy: 1e-12)

    session.begin(stroke: "s")
    for index in 0..<20 {
      session.append([sample(Double(index) / 20, 0.5)])
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    await settle()

    XCTAssertEqual(session.liveUpdate?.tier, .normal)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)
    XCTAssertNil(session.lastError, "a downgrade is state, not a failure")
    let starts = transport.draftStartedAt
    XCTAssertGreaterThan(starts.count, 1)
    for (earlier, later) in zip(starts, starts.dropFirst()) {
      XCTAssertGreaterThanOrEqual(later - earlier, 0.032 - 0.003)
    }
  }

  func testAnAnswerWithoutTheBlockChangesNothing() async throws {
    let transport = FakeTransport()
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    XCTAssertEqual(session.liveUpdate?.negotiatedTier, .experimental120)
  }

  func testPresentUnreadableAnswersLowerAnExperimentalCeiling() async throws {
    for block in ["null", "false", #""unreadable""#] {
      let transport = FakeTransport()
      transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(block)}"#)]
      let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
      session.begin(stroke: "s")
      session.append([sample(0.1, 0.1)])
      try await waitUntil { session.effectiveDraftInterval == 0.032 }
      XCTAssertNotNil(session.liveUpdate, block)
      XCTAssertNil(session.liveUpdate?.negotiatedTier, block)
      XCTAssertNil(session.lastError, block)
      session.stopLocally()
    }
  }

  func testRefreshesFollowTheServerBothWays() async throws {
    let transport = FakeTransport()
    let session = try await adopt(transport, liveUpdate: nil)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    transport.sessionResult = .success(try Self.response(liveUpdate: Self.grantedJSON(.experimental120)))
    try await session.refreshSession()
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 120, accuracy: 1e-12)

    transport.sessionResult = .success(try Self.response(liveUpdate: Self.fallback))
    try await session.refreshSession()
    XCTAssertEqual(session.liveUpdate?.fallbackReason, "disabled_by_operator")
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    transport.sessionResult = .success(try Self.response(liveUpdate: #""garbage""#))
    try await session.refreshSession()
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    transport.sessionResult = .success(try Self.response(liveUpdate: nil))
    try await session.refreshSession()
    XCTAssertNil(session.liveUpdate)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)
  }

  func testAReadInFlightDuringADowngradeCannotRaiseTheCeilingAgain() async throws {
    let transport = FakeTransport()
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    let stale = try Self.response(liveUpdate: Self.grantedJSON(.experimental120))
    let gate = LiveUpdateGate()
    transport.sessionHook = {
      await gate.wait()
      return stale
    }
    let read = Task { try await session.refreshSession() }
    try await waitUntil { transport.callCount(.session) == 1 }

    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.fallback)}"#)]
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    await gate.releaseAll()
    try await read.value
    XCTAssertEqual(session.effectiveDraftInterval, 0.032, "a read older than the downgrade must not undo it")

    // A read that left after the answer is authoritative again: the operator
    // re-enabled the tier.
    transport.sessionHook = nil
    transport.sessionResult = .success(try Self.response(liveUpdate: Self.grantedJSON(.experimental120)))
    try await session.refreshSession()
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 120, accuracy: 1e-12)
    await session.cancelStroke()
  }

  func testAnAnswerOlderThanADowngradingReadCannotRaiseTheCeilingAgain() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    let stillGranted = try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)
    transport.draftResults = [stillGranted, stillGranted]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    try await waitUntil { transport.callCount(.draft) == 1 }

    // The operator turns the tier off; a read that left after the draft sees it.
    transport.sessionResult = .success(try Self.response(liveUpdate: Self.fallback))
    try await session.refreshSession()
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    await gate.releaseAll()
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    XCTAssertEqual(session.liveUpdate?.tier, .normal, "an answer older than the read must not undo it")
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    // An answer to a draft that left after the read is authoritative again.
    session.append([sample(0.5, 0.5)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 120, accuracy: 1e-12)
    await session.cancelStroke()
  }

  func testAnOlderCancelledStrokeAnswerCannotUndoANewerAnswerDowngrade() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    session.begin(stroke: "first")
    session.append([sample(0.1, 0.1)])
    try await waitUntil { transport.callCount(.draft) == 1 }
    _ = try await session.end(stroke: "first")

    // The cancelled first request deliberately ignores cancellation. The next
    // stroke gets the server's newer policy while that request is still held.
    transport.draftHook = nil
    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.fallback)}"#)]
    session.begin(stroke: "second")
    session.append([sample(0.2, 0.2)])
    try await waitUntil { session.liveUpdate?.tier == .normal }

    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)]
    await gate.releaseAll()
    try await waitUntil { transport.draftResults.isEmpty }
    XCTAssertEqual(transport.callCount(.draft), 2)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032, "completion order must not rewind policy")
    await session.cancelStroke()
  }

  func testConcurrentTextAnswersCannotRewindANewerDowngrade() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    let first = Task { await session.draftText("H", at: point) }
    try await waitUntil { transport.callCount(.draft) == 1 }

    transport.draftHook = nil
    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.fallback)}"#)]
    await session.draftText("He", at: point)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)]
    await gate.releaseAll()
    await first.value
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    // A genuinely newer request may observe an operator re-enabling the tier.
    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)]
    await session.draftText("Hel", at: point)
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 120, accuracy: 1e-12)
  }

  func testAnOldCredentialAnswerCannotChangePolicyAfterRotation() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    let first = Task { await session.draftText("H", at: point) }
    try await waitUntil { transport.callCount(.draft) == 1 }

    transport.refreshResult = .success(try RemoteDrawRefreshResponse.decoded(
      fromJSON: #"{"senderToken":"rd_send_rotated","senderId":"sender_1","capabilities":["draw"],"lastSequence":0,"session":\#(Self.sessionBody(liveUpdate: Self.fallback))}"#))
    let recovered = await session.recoverRejectedCredential("rd_send_1")
    XCTAssertTrue(recovered)
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    transport.draftHook = nil
    transport.draftResults = [try Self.ack(#"{"accepted":false,"reason":"stale_sequence","lastSequence":500,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)]
    await gate.releaseAll()
    await first.value
    XCTAssertEqual(session.effectiveDraftInterval, 0.032, "the old token cannot alter the new token's policy")

    transport.draftResults = [try Self.ack(#"{"accepted":true,"liveUpdate":\#(Self.grantedJSON(.experimental120))}"#)]
    await session.draftText("He", at: point)
    XCTAssertEqual(session.effectiveDraftInterval, 1.0 / 120, accuracy: 1e-12)
    XCTAssertEqual(transport.calls.last { $0.route == .draft }?.senderToken, "rd_send_rotated")
    XCTAssertEqual(transport.calls.last { $0.route == .draft }?.sequence, 2,
      "an old credential's stale answer must not alter the current counter")
  }

  // MARK: - Rate-limit refusals

  func testAStaleSequenceReoffersStationaryInkWithTheRecoveredCounter() async throws {
    let transport = FakeTransport()
    transport.draftResults = [RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 500)]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1), sample(0.5, 0.5)])
    try await waitUntil { transport.callCount(.draft) == 2 }
    await settle()
    let drafts = transport.calls.filter { $0.route == .draft }
    XCTAssertEqual(drafts.count, 2, "stationary ink recovers once, then stops")
    XCTAssertEqual(drafts.map { $0.sequence ?? -1 }, [1, 501])
    XCTAssertEqual(try PointCodec.unpack(try XCTUnwrap(transport.lastDraftPacked)).count, 2)
    XCTAssertNil(session.lastError)
    await session.cancelStroke()
  }

  func testStaleAndRateRefusalsShareOneBoundedReplayBudget() async throws {
    let transport = FakeTransport()
    let rate = RemoteDrawDraftAck(accepted: false, reason: "live_update_rate", retryAfterMs: 5)
    transport.draftResults = [
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 100), rate,
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 200), rate,
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 300),
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    try await waitUntil { transport.callCount(.draft) == 4 }
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 4, "alternating refusal kinds must not renew the retry budget")
    XCTAssertEqual(transport.draftResults.count, 1)
    XCTAssertNil(session.lastError)
    await session.cancelStroke()
  }

  func testAStaleReplyWithoutAUsefulCounterDoesNotReplay() async throws {
    let counters: [Int?] = [nil, 0, -1, Int.max, 9_007_199_254_740_991, 9_007_199_254_740_992]
    for counter in counters {
      let transport = FakeTransport()
      transport.draftResults = [RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: counter)]
      let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
      session.begin(stroke: "s")
      session.append([sample(0.1, 0.1)])
      await settle()
      XCTAssertEqual(transport.callCount(.draft), 1)
      session.append([sample(0.5, 0.5)])
      try await waitUntil { transport.callCount(.draft) == 2 }
      XCTAssertEqual(transport.calls.last { $0.route == .draft }?.sequence, 2,
        "a malformed counter must not poison subsequent input")
      session.stopLocally()
    }
  }

  func testAStaleTextReplyRecoversTheNextPreviewCounter() async throws {
    let transport = FakeTransport()
    transport.draftResults = [RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 500)]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    await session.draftText("H", at: point)
    XCTAssertEqual(transport.callCount(.draft), 1, "text is not replayed")
    await session.draftText("He", at: point)
    let drafts = transport.calls.filter { $0.route == .draft }
    XCTAssertEqual(drafts.map { $0.sequence ?? -1 }, [1, 501])
  }

  func testMalformedStaleTextCountersCannotPoisonTheNextPreview() async throws {
    for counter in [-1, Int.max, 9_007_199_254_740_991, 9_007_199_254_740_992] {
      let transport = FakeTransport()
      transport.draftResults = [try Self.ack(
        #"{"accepted":false,"reason":"stale_sequence","lastSequence":\#(counter)}"#)]
      let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
      let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
      await session.draftText("H", at: point)
      await session.draftText("He", at: point)
      let drafts = transport.calls.filter { $0.route == .draft }
      XCTAssertEqual(drafts.map { $0.sequence ?? -1 }, [1, 2])
      session.stopLocally()
    }
  }

  func testARateLimitRefusalBacksOffAndReoffersTheCurrentStrokeOnce() async throws {
    let transport = FakeTransport()
    transport.draftResults = [
      try Self.ack(#"{"accepted":false,"reason":"live_update_rate","retryAfterMs":50}"#)
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1), sample(0.5, 0.5)])
    try await Task.sleep(nanoseconds: 200_000_000)

    let starts = transport.draftStartedAt
    XCTAssertEqual(starts.count, 2, "the refused frame is re-offered once the wait is over, then accepted")
    guard starts.count == 2 else { return }
    XCTAssertGreaterThanOrEqual(starts[1] - starts[0], 0.050 - 0.003)
    XCTAssertNil(session.lastError, "a rate refusal is routine, not an error")
    let drafts = transport.calls.filter { $0.route == .draft }
    XCTAssertEqual(drafts[1].sequence ?? 0, (drafts[0].sequence ?? 0) + 1)
    let replayed = try PointCodec.unpack(try XCTUnwrap(transport.lastDraftPacked))
    XCTAssertEqual(replayed.count, 2, "the replay is the stroke as it stands")
    await session.cancelStroke()
  }

  func testRepeatedRefusalsAreReplayedABoundedNumberOfTimes() async throws {
    let transport = FakeTransport()
    let refusal = try Self.ack(#"{"accepted":false,"reason":"live_update_rate","retryAfterMs":5}"#)
    transport.draftResults = Array(repeating: refusal, count: 10)
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(transport.callCount(.draft), 4, "one send and three replays, then it waits for new ink")

    // New ink gets its own bounded budget even before an accepted answer.
    // Leave four refusals: the send and its three retries then stop again.
    transport.draftResults = Array(repeating: refusal, count: 4)
    session.append([sample(0.6, 0.6)])
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(transport.callCount(.draft), 8)

    // An identical sample is discarded and cannot renew that retry budget.
    transport.draftResults = Array(repeating: refusal, count: 4)
    session.append([sample(0.6, 0.6)])
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(transport.callCount(.draft), 8, "unchanged input must neither queue a frame nor buy more retries")
    await session.cancelStroke()
  }

  func testUnchangedRenewalDoesNotRenewTheRefusalReplayBudget() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    let refusal = RemoteDrawDraftAck(accepted: false, reason: "live_update_rate", retryAfterMs: 5)
    transport.draftResults = Array(repeating: refusal, count: 12)
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: try Self.session(liveUpdate: Self.grantedJSON(.experimental240)),
      automaticallyRefreshDrawings: false, pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "held")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 4, "one geometry offer plus three bounded retries")

    await clock.advance(by: 5)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 5, "renewal offers once without another retry budget")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 5)
    await clock.advance(by: 5)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 6)
    XCTAssertEqual(session.draftDiagnostics.offered, 1)
  }

  func testARefusalAnsweredAfterTheStrokeEndedReplaysNothing() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    transport.draftResults = [
      try Self.ack(#"{"accepted":false,"reason":"live_update_rate","retryAfterMs":5}"#)
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1), sample(0.5, 0.5)])
    try await waitUntil { transport.callCount(.draft) == 1 }
    _ = try await session.end(stroke: "s")
    await gate.releaseAll()
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1, "a finished stroke's refusal must not resurrect its draft")
    XCTAssertEqual(transport.callCount(.commit), 1)
  }

  /// Ending a stroke cancels its drain, and the answer to its last frame is
  /// where a downgrade or a wait usually arrives. Same credential, so the state
  /// and the wait are taken; the stroke is over, so nothing is replayed.
  func testALateAnswerToACancelledDraftStillDowngradesAndHoldsButReplaysNothing() async throws {
    let transport = FakeTransport()
    let gate = LiveUpdateGate()
    transport.draftHook = { await gate.wait() }
    transport.draftResults = [
      try Self.ack(
        #"{"accepted":false,"reason":"live_update_rate","retryAfterMs":300,"liveUpdate":\#(Self.fallback)}"#)
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental240))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1), sample(0.5, 0.5)])
    try await waitUntil { transport.callCount(.draft) == 1 }
    _ = try await session.end(stroke: "s")
    await gate.releaseAll()
    await settle()

    XCTAssertEqual(session.liveUpdate?.tier, .normal, "the cancelled draft's answer is the server's newest word")
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)
    XCTAssertNil(session.lastError)
    XCTAssertEqual(transport.callCount(.draft), 1, "no replay of a finished stroke")
    XCTAssertEqual(transport.callCount(.commit), 1)

    // The next stroke honours the wait the late answer carried…
    session.begin(stroke: "t")
    session.append([sample(0.2, 0.2)])
    try await Task.sleep(nanoseconds: 100_000_000)
    XCTAssertEqual(transport.callCount(.draft), 1, "retryAfterMs from the cancelled draft still holds")
    // …and then sends, once, at the downgraded pace.
    try await waitUntil { transport.callCount(.draft) == 2 }
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await session.cancelStroke()
  }

  func testARefusedTextDraftDowngradesAndHoldsTextWithoutReplaying() async throws {
    let transport = FakeTransport()
    transport.draftResults = [
      try Self.ack(
        #"{"accepted":false,"reason":"live_update_rate","retryAfterMs":200,"liveUpdate":\#(Self.fallback)}"#)
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental120))
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    await session.draftText("H", at: point)
    XCTAssertEqual(transport.callCount(.draft), 1)
    XCTAssertEqual(session.liveUpdate?.tier, .normal, "a text answer carries the same state")
    XCTAssertEqual(session.effectiveDraftInterval, 0.032)

    await session.draftText("He", at: point)
    XCTAssertEqual(transport.callCount(.draft), 1, "a keystroke inside the wait is dropped")
    try await Task.sleep(nanoseconds: 300_000_000)
    XCTAssertEqual(transport.callCount(.draft), 1, "and never replayed on its own")

    await session.draftText("Hel", at: point)
    XCTAssertEqual(transport.callCount(.draft), 2, "the next keystroke after the wait goes out")
  }

  func testAnAppendTheSamplerDropsIsNotOffered() async throws {
    let transport = FakeTransport()
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental60))
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    session.append([sample(0.1, 0.1)])
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(session.draftDiagnostics.offered, 1, "an unchanged stroke is not a new frame")
    await session.cancelStroke()
  }

  // MARK: - Diagnostics

  func testDiagnosticsAreOffByDefault() async throws {
    let transport = FakeTransport()
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental60))
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertFalse(session.recordsDraftDiagnostics)
    XCTAssertEqual(session.draftDiagnostics, RemoteDrawDraftDiagnostics())
    await session.cancelStroke()
  }

  func testDiagnosticsSeparateSentCompletedAndAccepted() async throws {
    let transport = FakeTransport()
    transport.draftResults = [
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 0),
      try Self.ack(#"{"accepted":false,"reason":"live_update_rate","retryAfterMs":5}"#),
      RemoteDrawDraftAck(accepted: true),
    ]
    let session = try await adopt(transport, liveUpdate: Self.grantedJSON(.experimental60))
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    await settle()
    session.append([sample(0.5, 0.5)])
    await settle()

    let stats = session.draftDiagnostics
    XCTAssertEqual(stats.offered, 2)
    XCTAssertEqual(stats.sent, 3, "two frames and one re-offer after the rate refusal")
    XCTAssertEqual(stats.completed, 3)
    XCTAssertEqual(stats.accepted, 1, "a resolved accepted:false is not accepted")
    XCTAssertEqual(stats.refusedStaleSequence, 1)
    XCTAssertEqual(stats.refusedRateLimited, 1)
    XCTAssertEqual(stats.failed, 0)
    XCTAssertNotNil(stats.lastRoundTrip)
    XCTAssertNotNil(stats.sendStartHz)

    transport.draftError = RemoteDrawError.offline
    session.append([sample(0.9, 0.9)])
    await settle()
    XCTAssertEqual(session.draftDiagnostics.failed, 1)
    XCTAssertEqual(session.draftDiagnostics.completed, 3, "a thrown request did not complete")

    session.resetDraftDiagnostics()
    XCTAssertEqual(session.draftDiagnostics, RemoteDrawDraftDiagnostics())
    transport.draftError = nil
    await session.cancelStroke()
  }

  func testSendStartRateIsMeasuredBetweenSendStarts() {
    var stats = RemoteDrawDraftDiagnostics()
    XCTAssertNil(stats.sendStartHz)
    stats.recordSend(at: 10)
    XCTAssertNil(stats.sendStartHz, "one send is not a rate")
    stats.recordSend(at: 10.5)
    stats.recordSend(at: 11)
    XCTAssertEqual(stats.sendStartHz ?? 0, 2, accuracy: 1e-9)
  }

  // MARK: - Fixtures

  /// `(tier, hz, minDraftIntervalMs)` exactly as a JavaScript server prints
  /// `1000 / hz`.
  private static let wireGrants: [(RemoteDrawLiveUpdateTier, Double, String)] = [
    (.experimental60, 60, "16.666666666666668"),
    (.experimental120, 120, "8.333333333333334"),
    (.experimental240, 240, "4.166666666666667"),
  ]

  private static func granted(_ tier: RemoteDrawLiveUpdateTier, _ hz: Double, _ interval: String) -> String {
    #"{"requestedTier":"\#(tier.rawValue)","tier":"\#(tier.rawValue)","maxDraftHz":\#(Int(hz)),"minDraftIntervalMs":\#(interval),"experimental":true,"guaranteed":false}"#
  }

  private static func grantedJSON(_ tier: RemoteDrawLiveUpdateTier) -> String {
    let grant = wireGrants.first { $0.0 == tier }!
    return granted(grant.0, grant.1, grant.2)
  }

  private static let fallback =
    #"{"requestedTier":"experimental120","tier":"normal","maxDraftHz":31.25,"minDraftIntervalMs":32,"experimental":true,"guaranteed":false,"fallbackReason":"disabled_by_operator"}"#

  private static func sessionBody(liveUpdate: String?) -> String {
    let block = liveUpdate.map { #","liveUpdate":\#($0)"# } ?? ""
    return #"{"id":"session_1","capabilities":["draw"],"target":{"kind":"paper"}\#(block)}"#
  }

  private static func session(liveUpdate: String?) throws -> RemoteDrawSession {
    try .decoded(fromJSON: sessionBody(liveUpdate: liveUpdate))
  }

  private static func response(liveUpdate: String?) throws -> RemoteDrawSessionResponse {
    try .decoded(fromJSON: #"{"session":\#(sessionBody(liveUpdate: liveUpdate))}"#)
  }

  private static func ack(_ json: String) throws -> RemoteDrawDraftAck {
    try .decoded(fromJSON: json)
  }

  private func adopt(_ transport: FakeTransport, liveUpdate: String?) async throws
    -> RemoteDrawSenderSession
  {
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: try Self.session(liveUpdate: liveUpdate), automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    addTeardownBlock { await session.stopLocally() }
    await transport.settleStartup()
    return session
  }

  private func sample(_ x: Double, _ y: Double) -> RemoteDrawSample {
    RemoteDrawSample(x: x, y: y, t: x * 1000, pressure: 0.5)
  }

  /// Lets the draft drain run. Pacing is real time.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 60_000_000)
  }

  private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
    XCTAssertTrue(condition(), "the expected request never started")
  }
}

private actor LiveUpdateGate {
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var open = false

  func wait() async {
    guard !open else { return }
    await withCheckedContinuation { pending.append($0) }
  }

  func releaseAll() {
    open = true
    let waiting = pending
    pending = []
    for continuation in waiting { continuation.resume() }
  }
}
