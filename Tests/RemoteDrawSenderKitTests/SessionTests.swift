import Combine
import XCTest

@testable import RemoteDrawSenderKit

/// The lifecycle rules, verified against a fake transport.
///
/// These are the rules that decide whether a customer's integration works, and
/// none of them are visible in a request body — they are all about what the
/// sender does with an answer. `docs/plans/ios-sender-sdk.md` §2.10 is the list.
@MainActor
final class SessionTests: XCTestCase {
  private func joined(
    _ transport: FakeTransport,
    capabilities: [String] = ["draw", "undo", "clear", "submit", "viewExisting", "moveViewport"],
    lastSequence: Int? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil
  ) async throws -> RemoteDrawSenderSession {
    transport.joinResult = .success(
      RemoteDrawJoinResponse(
        senderToken: "rd_send_1", senderId: "sender_1", capabilities: capabilities,
        lastSequence: lastSequence, session: .stub(capabilities: capabilities)))
    return try await RemoteDrawSenderSession.join(
      token: .join("rd_join_abc"), transport: transport, tokenProvider: tokenProvider)
  }

  func testSnapshotBeforeAcknowledgmentDoesNotReinsertEcho() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitAsyncHook = { _ in
      session.reconcileDrawingIDs(["drawing_1"])
    }
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "client-1")
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(session.drawingOperations["client-1"], .acknowledged)
  }

  func testSnapshotRemovalBeforeAcknowledgmentDoesNotResurrectEcho() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitAsyncHook = { _ in
      session.reconcileDrawingIDs(["drawing_1"])
      session.reconcileDrawingIDs([])
    }
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "client-1")
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(session.drawingOperations["client-1"], .removed)
  }

  func testUndoBeforeSnapshotRemovesAcknowledgedEcho() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.undoResult = RemoteDrawUndoResult(removed: true, drawingId: "drawing_1")
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "client-1")
    _ = try await session.undo()
    session.reconcileDrawingIDs([])
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(session.drawingOperations["client-1"], .removed)
  }

  func testPermanentCommitFailureRemovesPreview() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitResult = .failure(RemoteDrawError.server(
      status: 400, code: "invalid_points", message: "Invalid points"))
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    do { _ = try await session.end(stroke: "client-1"); XCTFail("Expected failure") }
    catch {}
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(session.drawingOperations["client-1"], .failed)
    XCTAssertEqual(session.pendingCommitCount, 0)
  }

  func testUncertainDeliveryStaysPendingUntilRetryAcknowledgesIt() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitResult = .failure(RemoteDrawError.offline)
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    do { _ = try await session.end(stroke: "client-1"); XCTFail("Expected failure") }
    catch {}
    XCTAssertEqual(session.drawingOperations["client-1"], .pending)
    XCTAssertEqual(session.strokes.count, 1)
    XCTAssertTrue(session.strokes[0].isLocalEcho)
    session.reconcileDrawingIDs([])
    XCTAssertEqual(session.strokes.count, 1)
    transport.commitResult = nil
    await session.retryPendingCommits()
    XCTAssertEqual(session.drawingOperations["client-1"], .acknowledged)
    XCTAssertEqual(session.pendingCommitCount, 0)
  }

  func testReadStartedBeforeCommitDoesNotRemoveNewAcknowledgment() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    let beforeRead = session.acknowledgedOperationIDs
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "client-1")
    session.reconcileDrawingIDs([], acknowledgedBeforeRead: beforeRead)
    XCTAssertEqual(session.strokes.count, 1)
    session.reconcileDrawingIDs([], acknowledgedBeforeRead: session.acknowledgedOperationIDs)
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(session.drawingOperations["client-1"], .removed)
  }

  func testTextSnapshotBeforeAcknowledgmentDoesNotReinsertEcho() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitAsyncHook = { _ in session.reconcileDrawingIDs(["drawing_1"]) }
    _ = try await session.commitText("Hello", at: sample(0.1, 0.1))
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(Array(session.drawingOperations.values), [.acknowledged])
  }

  func testPendingPreviewUsesBoardMappingWithoutChangingWirePoints() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    session.strokeSpace = {
      RemoteDrawStrokeSpace(isBoardSpace: true, boardPreview: { points in
        points.map { RemoteDrawNormalizedPoint(x: $0.x / 2, y: $0.y / 2, t: $0.t) }
      })
    }
    transport.commitAsyncHook = { request in
      XCTAssertTrue(session.strokes[0].isBoardSpace)
      XCTAssertEqual(session.strokes[0].points[0].x, 0.1, accuracy: 0.001)
      let points = try PointCodec.unpack(request.packedPoints)
      XCTAssertEqual(points[0].x, 0.2, accuracy: 0.001)
    }
    session.begin(stroke: "client-1", tool: .freehand)
    session.append([sample(0.2, 0.2), sample(0.8, 0.8)])
    _ = try await session.end(stroke: "client-1")
  }

  func testTextFailureRemovesPreview() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      capabilities: ["draw", "undo", "clear", "viewExisting"],
      automaticallyRefreshDrawings: false)
    transport.commitResult = .failure(RemoteDrawError.server(
      status: 400, code: "invalid_text", message: "Invalid text"))
    do { _ = try await session.commitText("Hello", at: sample(0.1, 0.1)); XCTFail("Expected failure") }
    catch {}
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertEqual(Array(session.drawingOperations.values), [.failed])
  }

  // MARK: - Entering

  func testJoinSpendsTheJoinTokenAndAdoptsWhatItAnswers() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport, capabilities: ["draw", "undo"])

    XCTAssertEqual(transport.calls.first?.route, .join)
    XCTAssertEqual(session.senderId, "sender_1")
    XCTAssertEqual(session.capabilities, [.draw, .undo])
    XCTAssertEqual(session.phase, .ready)
  }

  func testASenderTokenSkipsTheJoinEntirely() async throws {
    // Joining revokes every other active sender on the session. A host that was
    // handed a token by its own backend has already joined, and re-joining would
    // kick another device off the board for no reason.
    let transport = FakeTransport()
    _ = try await RemoteDrawSenderSession.join(
      token: .sender("rd_send_direct"), transport: transport)

    XCTAssertFalse(transport.calls.contains { $0.route == .join })
    XCTAssertEqual(transport.calls.first?.route, .session)
  }

  func testAdoptResumesAJoinThatAlreadyHappenedWithNoRoundTrip() async throws {
    // The first-party app's path: it makes the join itself, because it decodes a
    // richer session than this SDK publishes, and re-reading `/v1/sender/session`
    // only to be told the same four facts would put a second round trip between
    // a QR scan and a usable surface.
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_direct",
      transport: transport,
      senderId: "sender_9",
      capabilities: ["draw", "submit"],
      lastSequence: 41
    )

    XCTAssertFalse(transport.calls.contains { $0.route == .join })
    XCTAssertFalse(transport.calls.contains { $0.route == .session })
    XCTAssertEqual(session.senderId, "sender_9")
    XCTAssertEqual(session.capabilities, [.draw, .submit])
    XCTAssertEqual(session.senderToken, "rd_send_direct")
    XCTAssertEqual(session.phase, .ready)

    // And the sequence high-water mark came with it: the server refuses any
    // input at or below what it already holds, so a resumed token that restarted
    // at zero would have every draft rejected as stale until it caught up.
    session.begin(stroke: "s1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "s1")
    let commit = transport.calls.first { $0.route == .commit }
    XCTAssertEqual(commit?.sequence, 42)
  }

  func testACommitReducesAShapeToItsEndpoints() async throws {
    // The board paints a rectangle from the bounding box of its points, so a
    // drag that wandered would otherwise store a different rectangle from the
    // one that was dragged out. See `CommitGeometryTests`.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1", tool: .rectangle)
    session.append([sample(0.2, 0.2), sample(0.9, 0.1), sample(0.6, 0.6)])
    _ = try await session.end(stroke: "stroke-1")

    XCTAssertEqual(transport.lastCommitTool, "rectangle")
    XCTAssertEqual(transport.lastCommitPoints?.count, 2)
    XCTAssertEqual(transport.lastCommitPoints?.first?.x ?? 0, 0.2, accuracy: 0.002)
    XCTAssertEqual(transport.lastCommitPoints?.last?.x ?? 0, 0.6, accuracy: 0.002)
    // The echo is the committed geometry too, or the board paints a box the size
    // of the whole wander for one round trip and then snaps.
    XCTAssertEqual(session.strokes.first?.points.count, 2)
  }

  func testAMalformedTokenIsRefusedBeforeAnyNetworkCall() async {
    let transport = FakeTransport()
    do {
      _ = try await RemoteDrawSenderSession.join(rawToken: "not-a-token", transport: transport)
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? RemoteDrawError, .malformedToken)
    }
    XCTAssertTrue(transport.calls.isEmpty)
  }

  func testUnknownCapabilitiesSurviveDecoding() async throws {
    // The capabilities array is the protocol's forward-compatibility mechanism,
    // so a grant this build has never heard of must arrive intact rather than
    // being dropped at the boundary.
    let transport = FakeTransport()
    let session = try await joined(transport, capabilities: ["draw", "timeTravel"])
    XCTAssertTrue(session.capabilities.contains(.other("timeTravel")))
  }

  // MARK: - Sequence

  func testSeedsItsCounterFromTheServersLastSequence() async throws {
    // A resumed token that restarts at zero has every draft rejected as stale
    // until it catches up — live ink vanishes while commits keep working.
    let transport = FakeTransport()
    let session = try await joined(transport, lastSequence: 40)

    session.begin(stroke: "stroke-1")
    session.append([sample(0.1, 0.1), sample(0.2, 0.2)])
    await settle()

    let draft = try XCTUnwrap(transport.calls.first { $0.route == .draft })
    XCTAssertEqual(draft.sequence, 41)
  }

  func testHealsFromAStaleSequenceRejectionWithoutASecondRoundTrip() async throws {
    // The rejection carries the counter to beat. Adopting it here is what stops
    // every subsequent frame bouncing — the hardest class of bug to report,
    // because commits keep working and only the live ink disappears.
    let transport = FakeTransport()
    transport.draftResults = [
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 500)
    ]
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1")
    session.append([sample(0.1, 0.1)])
    await settle()
    session.append([sample(0.5, 0.5)])
    await settle()

    let drafts = transport.calls.filter { $0.route == .draft }
    XCTAssertGreaterThanOrEqual(drafts.count, 2)
    XCTAssertEqual(drafts[0].sequence, 1)
    XCTAssertEqual(
      drafts[1].sequence, 501,
      "the second frame must continue from the server's counter, not from the local one")
  }

  func testAdoptingAServerSequenceNeverRewinds() async throws {
    // A late answer carrying an older high-water mark must not walk the counter
    // back onto sequences this run has already spent.
    let transport = FakeTransport()
    transport.draftResults = [
      RemoteDrawDraftAck(accepted: false, reason: "stale_sequence", lastSequence: 0)
    ]
    let session = try await joined(transport, lastSequence: 100)

    session.begin(stroke: "s")
    session.append([sample(0.1, 0.1)])
    await settle()
    session.append([sample(0.4, 0.4)])
    await settle()

    let drafts = transport.calls.filter { $0.route == .draft }
    XCTAssertEqual(drafts[0].sequence, 101)
    XCTAssertEqual(drafts[1].sequence, 102)
  }

  // MARK: - Cadence

  func testRejectedSamplesDoNotSendOrPublishAnUnchangedStroke() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)
    defer { session.leave() }
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "still")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)

    var publications = 0
    let observation = session.$live.dropFirst().sink { _ in publications += 1 }
    defer { observation.cancel() }
    // Each append runs after the prior draft's cadence has elapsed, so a
    // redundant re-offer would start another request rather than coalesce.
    for _ in 0..<3 {
      session.append([sample(0.1, 0.1)])
      await settle()
    }
    XCTAssertEqual(transport.callCount(.draft), 1)
    XCTAssertEqual(publications, 0)
    XCTAssertEqual(session.draftDiagnostics.offered, 1)

    session.append([sample(0.5, 0.5)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    XCTAssertEqual(publications, 1)
    XCTAssertEqual(session.draftDiagnostics.offered, 2)
    XCTAssertEqual(session.live?.points.count, 2)
  }

  func testUnchangedInputRenewsTheDraftAtFiveSecondsWithoutPublication() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "held")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    let packed = transport.lastDraftPacked
    var publications = 0
    let observation = session.$live.dropFirst().sink { _ in publications += 1 }
    defer { observation.cancel() }

    // Binary-exact increments exercise the boundary without accumulated decimal
    // rounding making the second renewal land just below ten seconds.
    await clock.advance(by: 4.875)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 0.125)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)

    await clock.advance(by: 4.875)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await clock.advance(by: 0.125)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 3)
    XCTAssertEqual(transport.lastDraftPacked, packed)
    XCTAssertEqual(publications, 0)
    XCTAssertEqual(session.draftDiagnostics.offered, 1)
    XCTAssertEqual(session.draftDiagnostics.sent, 3)
  }

  func testUnchangedRenewalDoesNotQueueBehindAnInFlightDraft() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    let gate = DraftCompletionGate()
    transport.draftHook = { await gate.wait() }
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.begin(stroke: "pending")
    session.append([sample(0.1, 0.1)])
    await settle()
    await clock.advance(by: 5)
    session.append([sample(0.1, 0.1)])
    await gate.releaseAll()
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1, "an unchanged offer must not become a pending frame")
    transport.draftHook = nil
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
  }

  func testUnchangedRenewalHonorsHTTPRetryAfter() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 20, bucket: "sender_writes")
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.begin(stroke: "limited")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 5)
    session.append([sample(0.1, 0.1)])
    await settle()
    await clock.advance(by: 14.999)
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 0.001)
    transport.draftError = nil
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
  }

  func testCancelledDraftRefusalStillLimitsTheNextStrokesUnchangedRenewal() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    let gate = DraftCompletionGate()
    transport.draftHook = {
      await gate.wait()
      throw RemoteDrawError.rateLimited(retryAfter: 20, bucket: "sender_writes")
    }
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.recordsDraftDiagnostics = true
    session.begin(stroke: "first")
    session.append([sample(0.1, 0.1)])
    await gate.waitForEntry()
    _ = try await session.end(stroke: "first")

    // The first request ignores cancellation and finishes after the next
    // stroke's first frame. Only that late refusal's renewal wait survives.
    transport.draftHook = nil
    session.begin(stroke: "second")
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await clock.advance(by: 1)
    await gate.releaseAll()
    await settle()
    XCTAssertEqual(session.draftDiagnostics.failed, 1)
    XCTAssertNil(session.lastError, "a canceled drain must not recover or publish an error")

    await clock.advance(by: 4)
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2, "five-second renewal must respect the late refusal")
    await clock.advance(by: 15.875)
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await clock.advance(by: 0.125)
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 3, "Retry-After starts when the refusal arrives")
  }

  func testCancelledOldCredentialRefusalCannotLimitTheRotatedCredentialsRenewal() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    let gate = DraftCompletionGate()
    transport.draftHook = {
      await gate.wait()
      throw RemoteDrawError.rateLimited(retryAfter: 30, bucket: "sender_writes")
    }
    transport.refreshResult = .success(RemoteDrawRefreshResponse(
      senderToken: "rd_send_rotated", senderId: "sender_1",
      capabilities: ["draw"], lastSequence: 2))
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.begin(stroke: "old")
    session.append([sample(0.1, 0.1)])
    await gate.waitForEntry()
    _ = try await session.end(stroke: "old")
    let recovered = await session.recoverRejectedCredential("rd_send_1")
    XCTAssertTrue(recovered)

    transport.draftHook = nil
    session.begin(stroke: "rotated")
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await clock.advance(by: 1)
    await gate.releaseAll()
    await settle()
    await clock.advance(by: 4)
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 3, "the old credential's refusal must not floor the current one")
    XCTAssertEqual(transport.calls.last { $0.route == .draft }?.senderToken, "rd_send_rotated")
    XCTAssertNil(session.lastError)
  }

  func testHTTPDraftRefusalWaitsForItsFullFloorAndSendsOnlyLatestGeometry() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 90, bucket: "sender_writes")
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    let backgroundSleepers = clock.sleeperCount
    session.begin(stroke: "quota")
    session.append([sample(0.1, 0.1)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    transport.draftError = nil
    session.append([sample(0.3, 0.3)])
    await clock.settle()
    session.append([sample(0.8, 0.8)])
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers + 1)

    // Long HTTP floors retain their full duration across bounded sleeps.
    await clock.advance(by: 60)
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 29.875)
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 0.125)
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    let sent = try PointCodec.unpack(XCTUnwrap(transport.lastDraftPacked))
    XCTAssertEqual(sent.count, 3)
    XCTAssertEqual(sent.last?.x ?? 0, 0.8, accuracy: 1.0 / 65535)
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers)
    session.stopLocally()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testTextHTTPRefusalDropsTextAndWaitsLatestGeometryUntilTheSameFloor() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 20, bucket: "sender_writes")
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    await session.draftText("first", at: point)
    XCTAssertEqual(transport.callCount(.draft), 1)
    transport.draftError = nil
    await session.draftText("dropped", at: point)
    session.begin(stroke: "after-text")
    session.append([sample(0.2, 0.2)])
    session.append([sample(0.8, 0.8)])
    await clock.settle()
    await clock.advance(by: 19.875)
    await session.draftText("still dropped", at: point)
    XCTAssertEqual(transport.callCount(.draft), 1)
    await clock.advance(by: 0.125)
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    let sent = try PointCodec.unpack(XCTUnwrap(transport.lastDraftPacked))
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent.last?.x ?? 0, 0.8, accuracy: 1.0 / 65535)
    await session.draftText("after floor", at: point)
    XCTAssertEqual(transport.callCount(.draft), 3)
  }

  func testHTTPDraftFloorLeavesStrokeAndTextCommitsAvailable() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 30, bucket: "sender_writes")
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    let backgroundSleepers = clock.sleeperCount
    session.begin(stroke: "commit")
    session.append([sample(0.1, 0.1)])
    await settle()
    transport.draftError = nil
    session.append([sample(0.8, 0.8)])
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers + 1)
    let stroke = try await session.end(stroke: "commit")
    XCTAssertNotNil(stroke)
    XCTAssertEqual(transport.callCount(.commit), 1)
    let point = RemoteDrawNormalizedPoint(x: 0.4, y: 0.4)
    await session.draftText("dropped", at: point)
    _ = try await session.commitText("committed", at: point)
    await clock.settle()
    XCTAssertEqual(transport.callCount(.commit), 2)
    XCTAssertEqual(transport.callCount(.draft), 1)
    XCTAssertEqual(clock.now, 0)
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers, "pen-up must cancel the queued quota wait")
    session.stopLocally()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testCredentialRotationWakesHTTPWaitWithOnlyLatestPendingGeometry() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 30, bucket: "sender_writes")
    transport.refreshResult = .success(RemoteDrawRefreshResponse(
      senderToken: "rd_send_rotated", senderId: "sender_1",
      capabilities: ["draw"], lastSequence: 1))
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    let backgroundSleepers = clock.sleeperCount
    session.begin(stroke: "rotating")
    session.append([sample(0.1, 0.1)])
    await settle()
    transport.draftError = nil
    session.append([sample(0.3, 0.3)])
    await clock.settle()
    session.append([sample(0.8, 0.8)])
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers + 1)
    let recovered = await session.recoverRejectedCredential("rd_send_1")
    XCTAssertTrue(recovered)
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    XCTAssertEqual(transport.calls.last { $0.route == .draft }?.senderToken, "rd_send_rotated")
    let sent = try PointCodec.unpack(XCTUnwrap(transport.lastDraftPacked))
    XCTAssertEqual(sent.count, 3)
    XCTAssertEqual(sent.last?.x ?? 0, 0.8, accuracy: 1.0 / 65535)
    XCTAssertEqual(clock.now, 0, "rotation must not wait out the previous credential's floor")
    XCTAssertEqual(clock.sleeperCount, backgroundSleepers)
    session.stopLocally()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testInactiveHTTPWaitPreservesLatestGeometryAndTheFloorUntilActivation() async throws {
    let transport = FakeTransport()
    let automaticClock = transport.holdAutomaticPolling()
    let clock = ManualPollClock()
    transport.draftError = RemoteDrawError.rateLimited(retryAfter: 30, bucket: "sender_writes")
    let session = RemoteDrawSenderSession.adopt(
      senderToken: "rd_send_1", transport: transport, senderId: "sender_1",
      session: .stub(capabilities: ["draw"]), automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { session.stopLocally() }
    await automaticClock.settle()
    session.begin(stroke: "paused")
    session.append([sample(0.1, 0.1)])
    await settle()
    transport.draftError = nil
    session.append([sample(0.3, 0.3)])
    session.append([sample(0.8, 0.8)])
    await clock.settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    await session.markInactive()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0, "backgrounding must cancel the HTTP waiter and heartbeat")

    // An early activation keeps the original credential's complete floor.
    await clock.advance(by: 5)
    await session.markActive()
    await clock.settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    session.append([sample(0.9, 0.9)])
    await session.markInactive()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0)

    // Expiry alone cannot send a queued frame while the sender is inactive.
    await clock.advance(by: 25)
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 1)
    await session.markActive()
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    let sent = try PointCodec.unpack(XCTUnwrap(transport.lastDraftPacked))
    XCTAssertEqual(sent.count, 4)
    XCTAssertEqual(sent.last?.x ?? 0, 0.9, accuracy: 1.0 / 65535)
    session.stopLocally()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0)
  }

  func testDraftsAreNeverSentFasterThanTheProtocolCadence() async throws {
    // 31.25 Hz is the number PERFORMANCE_BUDGETS pins. Faster does not make the
    // board smoother; it spends the sender's rate-limit budget on frames nobody
    // can see, and a tenant that hits sender_writes_per_token stops drawing.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "s")
    let started = Date()
    // Twenty appends as fast as the runtime will deliver them, over a window
    // that could only honestly carry a handful of frames.
    for index in 0..<20 {
      session.append([sample(Double(index) / 20, 0.5)])
      try? await Task.sleep(nanoseconds: 5_000_000)
    }
    await settle()
    let elapsed = Date().timeIntervalSince(started)

    let drafts = transport.calls.filter { $0.route == .draft }.count
    let ceiling = Int((elapsed / RemoteDrawProtocolLimits.draftSendInterval).rounded(.up)) + 1
    XCTAssertLessThanOrEqual(drafts, ceiling, "\(drafts) frames in \(elapsed)s")
    XCTAssertGreaterThan(drafts, 0, "a stroke that sends nothing is not paced, it is broken")
  }

  func testTheLatestFrameSupersedesAWaitingOneRatherThanQueueingBehindIt() async throws {
    // A draft describes where the finger *is*. A backlog would keep paying for
    // positions the finger has already moved past.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "s")
    for index in 0..<10 {
      session.append([sample(Double(index) / 10, 0.5)])
    }
    await settle()

    let packed = try XCTUnwrap(transport.lastDraftPacked)
    let points = try PointCodec.unpack(packed)
    XCTAssertEqual(
      points.count, 10,
      "the frame that went out must carry the whole stroke as it stands, not one queued slice")
  }

  func testDelayedCancellationCannotAbandonANewerStroke() async throws {
    let session = try await joined(FakeTransport())
    session.begin(stroke: "old")
    session.append([sample(0.1, 0.1)])
    session.begin(stroke: "new")
    session.append([sample(0.6, 0.7)])
    await session.cancelStroke(stroke: "old")
    XCTAssertEqual(session.live?.id, "new")
    XCTAssertEqual(session.live?.points.count, 1)
    await session.cancelStroke(stroke: "new")
    XCTAssertNil(session.live)
    session.leave()
  }

  func testCanceledTransportCannotClearTheNextStrokesDraftDrain() async throws {
    let transport = FakeTransport()
    let gate = DraftCompletionGate()
    transport.draftHook = { await gate.wait() }
    let session = try await joined(transport)
    session.begin(stroke: "first")
    session.append([sample(0.1, 0.1)])
    await settle()
    await session.cancelStroke()
    session.begin(stroke: "second")
    session.append([sample(0.2, 0.2)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    // This fake deliberately completes despite cancellation, like an HTTP
    // request already accepted by the server. Its defer must not release the
    // newer drain, which is still waiting for its own response.
    await gate.releaseFirst()
    await settle()
    session.append([sample(0.4, 0.4)])
    await settle()
    XCTAssertEqual(transport.callCount(.draft), 2)
    await session.cancelStroke()
    await gate.releaseAll()
    session.leave()
  }

  func testDelayedHTTPDraftsMeasureRTTCeilingAndCommitSequenceOrdering() async throws {
    for rtt: UInt64 in [100_000_000, 200_000_000] {
      let transport = FakeTransport()
      transport.draftDelayNanoseconds = rtt
      let session = try await joined(transport)
      session.begin(stroke: "latency")
      for index in 0..<20 {
        session.append([sample(Double(index) / 22, 0.4)])
        try await Task.sleep(nanoseconds: 32_000_000)
      }
      let starts = transport.draftStartedAt
      XCTAssertGreaterThanOrEqual(starts.count, 3)
      for (previous, next) in zip(starts, starts.dropFirst()) {
        XCTAssertGreaterThanOrEqual(next - previous, Double(rtt) / 1_000_000_000 * 0.9,
          "one outstanding HTTP draft, latest-only: updates remain RTT-limited")
      }
      let measuredHz = Double(starts.count - 1) / (starts.last! - starts.first!)
      print("Draft RTT baseline: \(rtt / 1_000_000) ms, \(String(format: "%.1f", measuredHz)) Hz")
      _ = try await session.end(stroke: "latency")
      let commit = try XCTUnwrap(transport.calls.last { $0.route == .commit })
      XCTAssertTrue(transport.calls.filter { $0.route == .draft }.allSatisfy {
        ($0.sequence ?? 0) < (commit.sequence ?? 0)
      }, "reliable commit must carry a sequence newer than every live draft")
      session.leave()
    }
  }

  // MARK: - Strokes

  func testAStrokeCommitsPackedAndKeepsALocalEchoUntilTheServerAnswers() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1", tool: .freehand)
    session.append([sample(0.1, 0.1), sample(0.6, 0.6), sample(0.9, 0.2)])
    XCTAssertEqual(session.live?.points.count, 3)
    XCTAssertEqual(session.phase, .drawing)

    _ = try await session.end(stroke: "stroke-1")

    XCTAssertNil(session.live)
    XCTAssertEqual(session.strokes.count, 1)
    XCTAssertFalse(session.strokes[0].isLocalEcho, "the server's version replaces the echo")
    XCTAssertEqual(session.strokes[0].id, "drawing_1")
    XCTAssertEqual(transport.lastCommitClientStrokeId, "stroke-1")
  }

  func testATapCommitsADotRatherThanNothing() async throws {
    // Every shipped RemoteDraw sender pads a one-sample stroke into two: the
    // web sender commits `[dot, dot]` as freehand, and the iOS board offsets
    // the second sample so the ribbon has a direction to be extruded along.
    // Discarding it instead means the person taps the board and nothing
    // happens. See `RemoteDrawCommitGeometry`.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1", tool: .freehand)
    session.append([sample(0.5, 0.5)])
    _ = try await session.end(stroke: "stroke-1")

    XCTAssertTrue(transport.calls.contains { $0.route == .commit })
    XCTAssertFalse(transport.calls.contains { $0.route == .clearDraft })
    XCTAssertEqual(session.strokes.count, 1)
  }

  func testAStrokeWithNoSamplesClearsTheDraftInstead() async throws {
    // Otherwise the board keeps showing a live draft nothing will ever replace.
    // This is what is left of the too-short case now that a tap is a dot: a
    // stroke that began and never got a sample at all — a touch the host stood
    // down before the finger moved.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1", tool: .freehand)
    _ = try await session.end(stroke: "stroke-1")

    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertFalse(transport.calls.contains { $0.route == .commit })
    XCTAssertTrue(transport.calls.contains { $0.route == .clearDraft })
  }

  func testCancellingAStrokeDropsItAndClearsTheDraft() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1")
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    await session.cancelStroke()

    XCTAssertNil(session.live)
    XCTAssertTrue(session.strokes.isEmpty)
    XCTAssertFalse(transport.calls.contains { $0.route == .commit })
    XCTAssertTrue(transport.calls.contains { $0.route == .clearDraft })
  }

  func testACommitLostToTheRadioIsRetriedUnderTheSameIdempotencyKey() async throws {
    // Commits deduplicate on (sessionId, senderId, clientStrokeId) and a replay
    // answers duplicate: true, which is the whole reason retrying is safe.
    let transport = FakeTransport()
    transport.commitHook = { attempt in
      if attempt <= 2 { throw RemoteDrawError.offline }
    }
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1")
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    _ = try await session.end(stroke: "stroke-1")

    XCTAssertEqual(transport.commitAttempts, 3)
    XCTAssertEqual(
      Set(transport.calls.filter { $0.route == .commit }.map(\.sequence)).count, 1,
      "a retry must not burn a new sequence — the server would see two strokes")
  }

  func testAFailedCommitLeavesTheStrokeOnScreen() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.server(status: 500, code: nil, message: nil))
    let session = try await joined(transport)

    session.begin(stroke: "stroke-1")
    session.append([sample(0.1, 0.1), sample(0.9, 0.9)])
    do {
      _ = try await session.end(stroke: "stroke-1")
      XCTFail("expected a throw")
    } catch {}

    // The user drew it. Removing it on a network hiccup is how ink appears to
    // vanish for reasons nobody can explain.
    XCTAssertEqual(session.strokes.count, 1)
    XCTAssertTrue(session.strokes[0].isLocalEcho)
  }

  // MARK: - Capabilities

  func testControlsThatTheSessionDidNotGrantAreRefusedWithoutARequest() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport, capabilities: ["draw"])

    do {
      _ = try await session.undo()
      XCTFail("expected a refusal")
    } catch {
      XCTAssertEqual(error as? RemoteDrawError, .notPermitted(.undo))
    }
    XCTAssertFalse(transport.calls.contains { $0.route == .undo })
    // A missing grant is not a broken credential: the session stays usable.
    XCTAssertEqual(session.phase, .ready)
  }

  func testSubmitNeedsNoCapabilityGrantBecauseTheServerNeverSendsOne() async throws {
    // The real server's capability set has no "submit" (convex
    // capabilityValidator); it accepts a submit from any live sender. A local
    // grant check therefore refused every real submit with notPermitted.
    let transport = FakeTransport()
    let session = try await joined(transport, capabilities: ["draw", "undo", "clear"])

    _ = try await session.submit()
    XCTAssertEqual(session.phase, .submitted)
    XCTAssertTrue(transport.calls.contains { $0.route == .submit })
  }

  func testSubmitIsIdempotentAcrossItsOwnRetries() async throws {
    let transport = FakeTransport()
    transport.submitHook = { attempt, _ in
      if attempt == 1 { throw RemoteDrawError.offline }
    }
    let session = try await joined(transport)

    _ = try await session.submit()
    XCTAssertEqual(session.phase, .submitted)
    XCTAssertEqual(
      transport.submissionIds.count, 1,
      "a retry that mints a new clientSubmissionId is a second submission")
  }

  // MARK: - Presence and exit

  func testLeavingDisconnectsRatherThanJustGoingQuiet() async throws {
    // Presence is a heartbeat, not a leave signal: the receiver's window is 60s,
    // so a phone that simply stops pinging keeps showing as connected and the
    // customer's board lies about who is there.
    let transport = FakeTransport()
    let session = try await joined(transport)

    session.leave()
    XCTAssertEqual(session.phase, .ended(.left))
    try await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertTrue(transport.calls.contains { $0.route == .closeProjection })
    XCTAssertEqual(transport.lastCloseWasDisconnect, true)
  }

  func testMarkingActiveAndInactivePingsWithTheRightFlag() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)

    await session.markActive()
    XCTAssertEqual(transport.lastPingWasActive, true)
    await session.markInactive()
    XCTAssertEqual(transport.lastPingWasActive, false)
  }

  // MARK: - Credential recovery

  func testARejectedCredentialRotatesThroughRefreshRatherThanReJoining() async throws {
    // Re-joining would revoke every other active sender on the session. Refresh
    // touches only this sender's token document, so nobody else is disturbed.
    let transport = FakeTransport()
    transport.refreshResult = .success(
      RemoteDrawRefreshResponse(
        senderToken: "rd_send_rotated", senderId: "sender_1",
        capabilities: ["draw", "undo", "clear", "submit"], lastSequence: 77))
    transport.draftError = RemoteDrawError.tokenRejected
    let session = try await joined(transport)

    session.begin(stroke: "s")
    session.append([sample(0.2, 0.2)])
    await settle()

    XCTAssertEqual(transport.refreshAttempts, 1)
    XCTAssertEqual(
      transport.calls.filter { $0.route == .join }.count, 1,
      "the only join is the one that started the session")
    XCTAssertNotEqual(session.phase, .ended(.tokenLost))

    // And the rotated token's sequence history is adopted with it.
    transport.draftError = nil
    session.append([sample(0.7, 0.7)])
    await settle()
    let lastDraft = try XCTUnwrap(transport.calls.last { $0.route == .draft })
    XCTAssertEqual(lastDraft.senderToken, "rd_send_rotated")
    XCTAssertEqual(lastDraft.sequence, 78)
  }

  func testRefreshIsAttemptedExactlyOncePerFailureAndNeverRetried() async throws {
    // Refresh is not idempotent: the old token dies the instant the response is
    // minted, so a second attempt carries a credential the server has already
    // rotated away. Retrying cannot help and destroys the evidence.
    let transport = FakeTransport()
    transport.refreshResult = .failure(RemoteDrawError.offline)
    transport.draftError = RemoteDrawError.tokenRejected
    let session = try await joined(transport)

    session.begin(stroke: "s")
    session.append([sample(0.2, 0.2)])
    await settle()

    XCTAssertEqual(
      transport.refreshAttempts, 1,
      "an offline refresh is exactly the failure a blind retry would make worse")
    XCTAssertEqual(session.phase, .ended(.tokenLost))
  }

  func testRepeatedRejectionsDoNotBurnTheRefreshRateLimit() async throws {
    // sender_refresh_per_token allows 10/min. A session whose every call fails
    // would otherwise rotate on each one and turn a recoverable credential
    // problem into a 429 storm.
    let transport = FakeTransport()
    transport.refreshResult = .failure(RemoteDrawError.offline)
    let session = try await joined(transport)
    transport.draftError = RemoteDrawError.tokenRejected

    session.begin(stroke: "s")
    for index in 0..<6 {
      session.append([sample(0.1 + Double(index) / 10, 0.5)])
      await settle()
    }

    XCTAssertEqual(transport.refreshAttempts, 1)
  }

  func testTheHostsTokenProviderCoversWhatRefreshStructurallyCannot() async throws {
    // A refresh whose *response* was lost spends the old token without
    // delivering the new one. Nothing the SDK holds can recover that.
    let transport = FakeTransport()
    transport.refreshResult = .failure(RemoteDrawError.offline)
    transport.draftError = RemoteDrawError.tokenRejected
    let session = try await joined(transport, tokenProvider: { "rd_send_from_host" })

    session.begin(stroke: "s")
    session.append([sample(0.2, 0.2)])
    await settle()

    XCTAssertNotEqual(session.phase, .ended(.tokenLost))
    transport.draftError = nil
    session.append([sample(0.8, 0.8)])
    await settle()
    XCTAssertEqual(transport.calls.last { $0.route == .draft }?.senderToken, "rd_send_from_host")
  }

  func testAFinishedSessionIsTerminalAndIsNeverReJoined() async throws {
    // `session_not_active` is authentication-adjacent but the board is over:
    // re-joining loops forever, which is why shouldReJoin is false for it.
    let transport = FakeTransport()
    transport.draftError = RemoteDrawError.sessionEnded
    let session = try await joined(transport)

    session.begin(stroke: "s")
    session.append([sample(0.2, 0.2)])
    await settle()

    XCTAssertEqual(session.phase, .ended(.ended))
    XCTAssertEqual(transport.refreshAttempts, 0)
    XCTAssertEqual(transport.calls.filter { $0.route == .join }.count, 1)
  }

  func testAFinishedBoardPastItsOwnExpiryIsReportedAsExpired() async throws {
    // The API answers `session_not_active` for both; the session holds the
    // `expiresAt` it was given (the stub's is epoch + 1 s, long past), so the
    // refusal is refined into the one a person can act on.
    let transport = FakeTransport()
    transport.draftError = RemoteDrawError.sessionEnded
    let session = try await joined(transport)

    session.begin(stroke: "s")
    session.append([sample(0.2, 0.2)])
    await settle()

    XCTAssertEqual(session.phase, .ended(.ended))
    XCTAssertEqual(session.lastError, .sessionExpired)
  }

  func testJoiningHeartbeatsAtOnceSoTheBoardSeesThePhoneArrive() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)
    await settle()
    XCTAssertEqual(transport.callCount(.ping), 1)
    XCTAssertEqual(transport.lastPingWasActive, false)
    // Held to here on purpose: the first beat is weak on the session, so a
    // session nobody keeps sends nothing — which is the right behaviour, and
    // is why a host that joins and drops the object sees no presence.
    XCTAssertEqual(session.phase, .ready)
  }

  func testAnExplicitMarkActiveIsNotFollowedByADemotingBeat() async throws {
    let transport = FakeTransport()
    let session = try await joined(transport)
    await session.markActive()
    await settle()
    XCTAssertEqual(transport.lastPingWasActive, true)
  }

  // MARK: - Helpers

  private func sample(_ x: Double, _ y: Double) -> RemoteDrawSample {
    RemoteDrawSample(x: x, y: y, t: x * 1000, pressure: 0.5)
  }

  /// Lets the draft drain task run. The pacing is real time, so a test that
  /// wants to observe two frames has to wait out one interval.
  private func settle() async {
    try? await Task.sleep(nanoseconds: 60_000_000)
  }
}

private actor DraftCompletionGate {
  private var pending: [CheckedContinuation<Void, Never>] = []
  private var entered = false
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  func wait() async {
    entered = true
    let arrivals = entryWaiters
    entryWaiters = []
    for arrival in arrivals { arrival.resume() }
    await withCheckedContinuation { pending.append($0) }
  }
  func waitForEntry() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func releaseFirst() {
    if !pending.isEmpty { pending.removeFirst().resume() }
  }
  func releaseAll() {
    let completions = pending
    pending = []
    for completion in completions { completion.resume() }
  }
}
