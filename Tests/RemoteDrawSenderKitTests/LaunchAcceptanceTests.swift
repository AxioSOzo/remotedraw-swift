import XCTest
@testable import RemoteDrawSenderKit

/// Launch acceptance for the native sender's public lifecycle contracts that
/// the existing suites do not pin: static-board geometry on the headless path,
/// retained ink across Leave and region moves, parked (paused) input, and 2.5D
/// metadata reaching a host that has to disclose a flat preview.
///
/// The B1 and B4 tests are written against the contract a customer relies on
/// and were predicted to FAIL on the source as audited on 2026-09-16.
/// `Session.swift` now carries a fix, not yet executed — see
/// docs/research/2026-09-16-launch-native-opus.md. They are not
/// snapshot or source-text tests: each drives `RemoteDrawSenderSession` through
/// `FakeTransport` and asserts what the session publishes or puts on the wire.
@MainActor
final class LaunchAcceptanceTests: XCTestCase {
  // MARK: Fixtures

  private static let projectionJSON = """
    {"centerX":0.5,"centerY":0.5,"width":0.2,"height":0.4,"rotationDegrees":0,
     "aspectRatio":0.5,"coordinateAspectRatio":1,"connected":true,"updatedAt":1000}
    """

  private static let staticJSON = """
    {"version":1,"image":{"url":"https://example.com/plan.png","mimeType":"image/png",
     "pixelWidth":800,"pixelHeight":600},"region":{"minX":0.2,"minY":0.3,"maxX":0.8,"maxY":0.7},
     "backdrop":"#ffffff","opening":{"fit":"contain"},"interaction":{"pan":true,"zoom":true,"overzoom":2},
     "publishedAt":1000,"expiresAt":9999999999999}
    """

  private func staticResponse(inputMapping: String, capabilities: [String])
    throws -> RemoteDrawSessionResponse
  {
    let caps = capabilities.map { "\"\($0)\"" }.joined(separator: ",")
    return try .decoded(fromJSON: """
      {"senderId":"sender_1","capabilities":[\(caps)],"session":{"id":"session_static",
       "geometryRevision":1,"capabilities":[\(caps)],
       "target":{"kind":"image","inputMapping":"\(inputMapping)",
         "coordinateSpace":{"width":1000,"height":1000},"static":\(Self.staticJSON)},
       "phoneProjection":\(Self.projectionJSON)}}
      """)
  }

  /// An active session whose automatic polling is held by the fixture clock.
  /// Do not use markInactive() to stop timers: background input is forbidden.
  private func staticSession(_ transport: FakeTransport, inputMapping: String,
    capabilities: [String] = ["draw"]) async throws -> RemoteDrawSenderSession
  {
    let response = try staticResponse(inputMapping: inputMapping, capabilities: capabilities)
    transport.sessionResult = .success(response)
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      senderId: "sender_1", session: response.session, capabilities: capabilities,
      automaticallyRefreshDrawings: false, pollClock: transport.holdAutomaticPolling())
    addTeardownBlock { await sender.stopLocally() }
    await transport.settleStartup()
    return sender
  }

  private func annotationResponse(_ revision: Int, paused: Bool = false) throws
    -> RemoteDrawSessionResponse
  {
    try .decoded(fromJSON: """
      {"session":{"id":"session_1","geometryRevision":1,"capabilities":["draw"],
       "annotationInput":{"revision":\(revision),"paused":\(paused)},
       "target":{"kind":"screen","coordinateSpace":{"width":200,"height":100}}}}
      """)
  }

  private func plainSession(_ transport: FakeTransport,
    capabilities: [String] = ["draw", "undo", "clear", "submit"]) async -> RemoteDrawSenderSession
  {
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      senderId: "sender_1", session: .stub(capabilities: capabilities), capabilities: capabilities,
      automaticallyRefreshDrawings: false, pollClock: transport.holdAutomaticPolling())
    addTeardownBlock { await sender.stopLocally() }
    await transport.settleStartup()
    return sender
  }

  private func drawAndEnd(_ sender: RemoteDrawSenderSession, id: String,
    style: RemoteDrawDrawingStyle? = nil) async throws -> RemoteDrawCommitResult?
  {
    sender.begin(stroke: id, tool: .freehand, style: style)
    sender.append([.init(x: 0.4, y: 0.45), .init(x: 0.6, y: 0.55)])
    return try await sender.end(stroke: id)
  }

  private func pendingCount(_ sender: RemoteDrawSenderSession) -> Int {
    // The first-party app's Leave warning uses exactly this formula
    // (AppState.adoptSenderSession → pendingDrawingCount).
    sender.drawingOperations.values.filter { $0 == .pending }.count
  }

  // MARK: Static image / background geometry

  /// B1. A viewport static board gets its phone window from the server (the
  /// token's opening projection), and the server projects the commit through
  /// it, so the stored points it answers with are board coordinates. A host
  /// that only mounts `RemoteDrawSurface` never calls `updateProjection`, and
  /// the surface's own renderer unprojects only strokes marked board-space. A
  /// settled stroke marked surface-space is drawn at its board coordinates as
  /// if they were screen coordinates — and without `viewExisting` no drawings
  /// read ever corrects it.
  func testStaticViewportSettledStrokeIsBoardSpaceWithoutAHostProjectionCall() async throws {
    let transport = FakeTransport()
    let sender = try await staticSession(transport, inputMapping: "viewport")
    XCTAssertNotNil(sender.session?.target?.staticBackground, "fixture must decode the static ground")
    XCTAssertNotNil(sender.session?.phoneProjection, "fixture must carry the server window")
    transport.commitResult = .success(try .decoded(fromJSON: """
      {"id":"server_static","type":"freehand",
       "points":[{"x":0.48,"y":0.49},{"x":0.52,"y":0.51}]}
      """))

    _ = try await drawAndEnd(sender, id: "static-1")

    let settled = try XCTUnwrap(sender.strokes.first)
    XCTAssertEqual(settled.id, "server_static")
    XCTAssertFalse(settled.isLocalEcho)
    XCTAssertTrue(settled.isBoardSpace,
      "Server-projected static-board points must be unprojected through the session's phoneProjection")
    // The window this space unprojects with is the one the commit names, so
    // the server cannot project through a different one than the phone assumes.
    let request = try XCTUnwrap(transport.commitRequests.last)
    XCTAssertEqual(request.phoneProjection, sender.session?.phoneProjection)
    let wire = try PointCodec.unpack(request.packedPoints)
    XCTAssertEqual(wire.first?.x ?? -1, 0.4, accuracy: 1e-3, "the wire stays surface-space; the server projects")
    sender.stopLocally()
  }

  /// The working half of B1: once the host has moved the window, the commit
  /// carries it and the settled stroke is board-space.
  func testStaticViewportCommitCarriesTheResolvedWindowAfterUpdateProjection() async throws {
    let transport = FakeTransport()
    let sender = try await staticSession(transport, inputMapping: "viewport",
      capabilities: ["draw", "moveViewport"])
    let window = RemoteDrawProjection(centerX: 0.4, centerY: 0.6, width: 0.3, height: 0.3,
      aspectRatio: 1, coordinateAspectRatio: 1, connected: true, updatedAt: 2000)
    _ = try await sender.updateProjection(window)
    transport.commitResult = .success(try .decoded(fromJSON: """
      {"id":"server_static","type":"freehand","points":[{"x":0.35,"y":0.55},{"x":0.45,"y":0.65}]}
      """))

    _ = try await drawAndEnd(sender, id: "static-2")

    let request = try XCTUnwrap(transport.commitRequests.last)
    XCTAssertEqual(request.phoneProjection, window)
    XCTAssertTrue(try XCTUnwrap(sender.strokes.first).isBoardSpace)
    // The echo was surface-space; the wire geometry must still be the surface
    // buffer (the server projects), not a second client-side projection.
    let wire = try PointCodec.unpack(request.packedPoints)
    XCTAssertEqual(wire.first?.x ?? -1, 0.4, accuracy: 1e-3)
    sender.stopLocally()
  }

  /// A surface-mapped static board: the phone *is* the board, so nothing is
  /// projected and nothing may claim to be board-space.
  func testSurfaceMappedStaticBoardSendsNoWindowAndSettlesInSurfaceSpace() async throws {
    let transport = FakeTransport()
    let sender = try await staticSession(transport, inputMapping: "surface")

    _ = try await drawAndEnd(sender, id: "surface-static")

    let request = try XCTUnwrap(transport.commitRequests.last)
    XCTAssertNil(request.phoneProjection)
    XCTAssertFalse(try XCTUnwrap(sender.strokes.first).isBoardSpace)
    sender.stopLocally()
  }

  // MARK: Pending writes, Leave

  /// The Leave warning's count must rise for undelivered ink and fall once a
  /// replay is acknowledged — otherwise the dialog either never appears or
  /// never goes away.
  func testPendingCountTracksUndeliveredInkThroughReplay() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.offline)
    let sender = await plainSession(transport)

    do {
      _ = try await drawAndEnd(sender, id: "pending-1")
      XCTFail("Expected the offline commit to throw")
    } catch {}
    XCTAssertEqual(sender.pendingCommitCount, 1)
    XCTAssertEqual(pendingCount(sender), 1)
    XCTAssertEqual(sender.drawingOperations["pending-1"], .pending)
    XCTAssertTrue(try XCTUnwrap(sender.strokes.first).isLocalEcho, "undelivered ink stays visible")

    transport.commitResult = nil
    await sender.retryPendingCommits()

    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(pendingCount(sender), 0)
    XCTAssertEqual(sender.drawingOperations["pending-1"], .acknowledged)
    XCTAssertEqual(Set(transport.commitRequests.map(\.clientStrokeId)), ["pending-1"])
    sender.stopLocally()
  }

  /// "Leave and discard pending drawings" must mean exactly that: the retained
  /// commits are dropped, nothing replays later, and the board is told the
  /// sender left.
  func testLeaveDiscardsRetainedInkDisconnectsAndNeverReplays() async throws {
    let transport = FakeTransport()
    transport.commitResult = .failure(RemoteDrawError.offline)
    let sender = await plainSession(transport)
    _ = try? await drawAndEnd(sender, id: "discarded")
    XCTAssertEqual(sender.pendingCommitCount, 1)
    let attemptsBeforeLeave = transport.commitAttempts

    transport.commitResult = nil
    sender.leave()

    XCTAssertEqual(sender.phase, .ended(.left))
    XCTAssertEqual(sender.pendingCommitCount, 0)
    await sender.retryPendingCommits()
    await sender.markActive()
    XCTAssertEqual(transport.commitAttempts, attemptsBeforeLeave)
    for _ in 0..<1000 where transport.callCount(.closeProjection) == 0 { await Task.yield() }
    XCTAssertEqual(transport.calls.filter { $0.route == .closeProjection }.map(\.senderToken), ["rd_send_1"])
    XCTAssertEqual(transport.lastCloseWasDisconnect, true)
  }

  /// B4. A surface that is still mounted for a frame after Leave (a SwiftUI
  /// transition, a host that keeps the view) can still receive touches. They
  /// must not put drafts on the wire with the credential that was just
  /// disconnected, and must not leave a live stroke stuck on screen.
  func testInputAfterLeaveSendsNothingAndLeavesNoLiveStroke() async throws {
    let transport = FakeTransport()
    let sender = await plainSession(transport)
    sender.leave()

    sender.begin(stroke: "after-leave", tool: .freehand)
    sender.append([.init(x: 0.1, y: 0.1), .init(x: 0.3, y: 0.3)])
    try await Task.sleep(nanoseconds: 150_000_000)
    _ = try? await sender.end(stroke: "after-leave")

    XCTAssertEqual(transport.callCount(.draft), 0, "no draft may use a disconnected sender token")
    XCTAssertEqual(transport.callCount(.commit), 0)
    XCTAssertNil(sender.live, "an ended session must not keep a stroke on screen")
    XCTAssertEqual(sender.phase, .ended(.left))
  }

  /// B4, remote variant. The board ends while the finger is still down: the
  /// draft is refused with `session_not_active`. The live stroke must leave the
  /// screen at once, the rest of the gesture must stay off the wire, and
  /// lifting the finger must not commit or throw.
  func testRemoteEndMidStrokeClearsTheLiveStrokeAndMakesTheRestOfTheGestureInert() async throws {
    let transport = FakeTransport()
    transport.draftError = RemoteDrawError.sessionEnded
    let sender = await plainSession(transport)

    sender.begin(stroke: "mid-stroke", tool: .freehand)
    sender.append([.init(x: 0.1, y: 0.1), .init(x: 0.3, y: 0.3)])
    XCTAssertNotNil(sender.live, "fixture: the stroke is on screen before the refusal")
    for _ in 0..<1000 where !isEnded(sender) { await Task.yield() }
    if !isEnded(sender) { try await Task.sleep(nanoseconds: 150_000_000) }

    XCTAssertEqual(sender.phase, .ended(.ended))
    XCTAssertNil(sender.live, "a remote end mid-stroke must not leave the stroke drawn")
    let draftsAtEnd = transport.callCount(.draft)
    XCTAssertEqual(draftsAtEnd, 1)

    sender.append([.init(x: 0.5, y: 0.5), .init(x: 0.7, y: 0.7)])
    try await Task.sleep(nanoseconds: 150_000_000)
    let result = try await sender.end(stroke: "mid-stroke")

    XCTAssertNil(result)
    XCTAssertNil(sender.live)
    XCTAssertEqual(transport.callCount(.draft), draftsAtEnd, "no draft after the board ended")
    XCTAssertEqual(transport.callCount(.commit), 0)
    XCTAssertEqual(transport.callCount(.clearDraft), 0)
    XCTAssertTrue(sender.strokes.isEmpty, "nothing is echoed for a stroke that was never committed")
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(pendingCount(sender), 0)

    // A new touch on the still-mounted surface is inert too.
    sender.begin(stroke: "after-remote-end", tool: .freehand)
    sender.append([.init(x: 0.2, y: 0.2), .init(x: 0.4, y: 0.4)])
    XCTAssertNil(sender.live)
    let secondResult = try await sender.end(stroke: "after-remote-end")
    XCTAssertNil(secondResult)
    XCTAssertEqual(transport.callCount(.draft), draftsAtEnd)
    XCTAssertEqual(transport.callCount(.commit), 0)
  }

  private func isEnded(_ sender: RemoteDrawSenderSession) -> Bool {
    if case .ended = sender.phase { return true }
    return false
  }

  // MARK: Parked (paused) input and region moves

  /// Retained ink is never rebased into a moved annotation region: the replay
  /// carries the revision it was drawn under, and the server's fail-closed
  /// refusal resolves the operation instead of pinning the Leave warning.
  func testRetainedInkIsNotRebasedAcrossARegionMoveAndResolvesAsFailed() async throws {
    let transport = FakeTransport()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: try annotationResponse(4).session, automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { sender.stopLocally() }
    await transport.settleStartup()
    transport.commitResult = .failure(RemoteDrawError.offline)
    _ = try? await drawAndEnd(sender, id: "moved-region")
    XCTAssertEqual(pendingCount(sender), 1)

    transport.sessionResult = .success(try annotationResponse(5))
    try await sender.refreshSession()
    XCTAssertEqual(sender.session?.annotationInput?.revision, 5)
    transport.commitResult = .failure(RemoteDrawError.server(status: 409,
      code: "annotation_revision_conflict", message: "The annotation region changed. Start a new stroke."))
    await sender.retryPendingCommits()

    XCTAssertTrue(transport.commitRequests.allSatisfy { $0.annotationRevision == 4 })
    XCTAssertEqual(sender.drawingOperations["moved-region"], .failed)
    XCTAssertEqual(sender.pendingCommitCount, 0)
    XCTAssertEqual(pendingCount(sender), 0)
    XCTAssertFalse(sender.strokes.contains { $0.id == "moved-region" })
    if case .ended = sender.phase { XCTFail("A region conflict must not end the session") }
    sender.stopLocally()
  }

  /// Parked input refuses a text commit locally, with a reason a host can
  /// show, and without a request the server would refuse anyway.
  func testPausedInputRefusesTextCommitWithAConflictAndNoRequest() async throws {
    let transport = FakeTransport()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      capabilities: ["draw"], automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { sender.stopLocally() }
    await transport.settleStartup()
    transport.sessionResult = .success(try annotationResponse(2, paused: true))
    try await sender.refreshSession()
    XCTAssertEqual(sender.session?.annotationInput?.paused, true)

    do {
      _ = try await sender.commitText("parked", at: .init(x: 0.5, y: 0.5))
      XCTFail("Expected a paused-region refusal")
    } catch let RemoteDrawError.server(status, code, _) {
      XCTAssertEqual(status, 409)
      XCTAssertEqual(code, "annotation_revision_conflict")
    }
    XCTAssertEqual(transport.callCount(.commit), 0)
    XCTAssertTrue(sender.strokes.isEmpty)
    XCTAssertEqual(pendingCount(sender), 0)
    sender.stopLocally()
  }

  /// Un-parking at the same revision lets the next stroke through with that
  /// revision; the stroke refused while parked is not resurrected.
  func testResumingParkedInputAcceptsTheNextStrokeOnly() async throws {
    let transport = FakeTransport()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: try annotationResponse(3, paused: true).session, automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { sender.stopLocally() }
    await transport.settleStartup()
    let parked = try await drawAndEnd(sender, id: "while-parked")
    XCTAssertNil(parked)

    transport.sessionResult = .success(try annotationResponse(3, paused: false))
    try await sender.refreshSession()
    _ = try await drawAndEnd(sender, id: "after-resume")

    XCTAssertEqual(transport.commitRequests.map(\.clientStrokeId), ["after-resume"])
    XCTAssertEqual(transport.commitRequests.first?.annotationRevision, 3)
    sender.stopLocally()
  }

  /// A pause interrupts a note that already drafted. Once the region is back,
  /// the *next* note must draft and commit under the new revision. Before the
  /// reset, the session kept the interrupted note's revision: every draft of
  /// the next note was dropped and its commit was refused once, losing it.
  func testNoteAfterARegionChangeDraftsAndCommitsUnderTheNewRevision() async throws {
    let transport = FakeTransport()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: try annotationResponse(4).session, automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { sender.stopLocally() }
    await transport.settleStartup()

    await sender.draftText("interrupted", at: .init(x: 0.2, y: 0.2))
    XCTAssertEqual(transport.callCount(.draft), 1, "fixture: the first note drafted")

    // The protocol bumps the revision with every pause and resume.
    transport.sessionResult = .success(try annotationResponse(5, paused: true))
    try await sender.refreshSession()
    await sender.draftText("while parked", at: .init(x: 0.2, y: 0.2))
    XCTAssertEqual(transport.callCount(.draft), 1, "nothing is drafted while parked")

    transport.sessionResult = .success(try annotationResponse(6))
    try await sender.refreshSession()
    await sender.draftText("next note", at: .init(x: 0.6, y: 0.6))
    XCTAssertEqual(transport.callCount(.draft), 2, "the next note's draft reaches the board")

    _ = try await sender.commitText("next note", at: .init(x: 0.6, y: 0.6))

    XCTAssertEqual(transport.commitRequests.count, 1)
    XCTAssertEqual(transport.commitRequests.first?.annotationRevision, 6)
    XCTAssertEqual(sender.pendingCommitCount, 0)
    sender.stopLocally()
  }

  /// The surface's parked-input pill and flat-preview disclosure, decided from
  /// the same session state the surface renders.
  func testSurfaceNoticesFollowParkedInputAndSettledMaterialInk() throws {
    XCTAssertFalse(RemoteDrawSurfaceNotices.isInputPaused(nil))
    XCTAssertFalse(RemoteDrawSurfaceNotices.isInputPaused(.stub(capabilities: ["draw"])),
      "a board with no drawing region is never parked")
    XCTAssertFalse(RemoteDrawSurfaceNotices.isInputPaused(try annotationResponse(2).session))
    XCTAssertTrue(RemoteDrawSurfaceNotices.isInputPaused(try annotationResponse(3, paused: true).session))

    let material = RemoteDrawDrawingStyle(kind: .ink, textureMode: "experimental-3d",
      textureMaterial: "oil", textureSurface: "glass")
    let points: [RemoteDrawNormalizedPoint] = [.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)]
    let plain = RemoteDrawStroke(id: "plain", points: points, style: RemoteDrawDrawingStyle(kind: .pencil))
    let echo = RemoteDrawStroke(id: "echo", points: points, style: material, isLocalEcho: true)
    let settled = RemoteDrawStroke(id: "settled", points: points, style: material, isBoardSpace: true)

    XCTAssertFalse(RemoteDrawSurfaceNotices.showsFlatMaterialPreview([]))
    XCTAssertFalse(RemoteDrawSurfaceNotices.showsFlatMaterialPreview([plain]))
    XCTAssertFalse(RemoteDrawSurfaceNotices.showsFlatMaterialPreview([plain, echo]),
      "an unacknowledged echo is not yet the board's stroke")
    XCTAssertTrue(RemoteDrawSurfaceNotices.showsFlatMaterialPreview([plain, settled]))
  }

  // MARK: 2.5D metadata and flat-preview disclosure

  /// A host can only disclose "2.5D appears flat" if the metadata survives
  /// every path ink takes into `strokes`: the commit it sends, the style the
  /// board answers with, and the drawings read of other senders' ink.
  func testPhysicalMaterialMetadataReachesTheWireAndEverySettledStroke() async throws {
    let transport = FakeTransport()
    let sender = await plainSession(transport, capabilities: ["draw", "viewExisting"])
    let oil = RemoteDrawDrawingStyle(kind: .ink, color: "#236DAD", width: 16,
      textureMode: "experimental-3d", textureMaterial: "oil", textureSurface: "glass")
    // The board answers without a style: the fallback must keep the material.
    _ = try await drawAndEnd(sender, id: "oil-1", style: oil)

    let body = try XCTUnwrap(JSONSerialization.jsonObject(
      with: JSONEncoder().encode(try XCTUnwrap(transport.commitRequests.last))) as? [String: Any])
    let wireStyle = try XCTUnwrap(body["style"] as? [String: Any])
    XCTAssertEqual(wireStyle["textureMode"] as? String, "experimental-3d")
    XCTAssertEqual(wireStyle["textureMaterial"] as? String, "oil")
    XCTAssertEqual(wireStyle["textureSurface"] as? String, "glass")
    XCTAssertEqual(sender.strokes.first?.style?.textureMaterial, "oil")

    transport.drawingsJSON = """
      {"items":[{"id":"web_oil","type":"freehand","points":[{"x":0.1,"y":0.1},{"x":0.2,"y":0.2}],
        "style":{"kind":"ink","textureMode":"experimental-3d","textureMaterial":"future-material",
        "textureSurface":"future-surface"}},
       {"id":"plain","type":"freehand","points":[{"x":0.3,"y":0.3},{"x":0.4,"y":0.4}],
        "style":{"kind":"pencil"}}]}
      """
    try await sender.refreshDrawings()

    let web = try XCTUnwrap(sender.strokes.first { $0.id == "web_oil" })
    XCTAssertEqual(web.style?.textureMode, "experimental-3d")
    XCTAssertEqual(web.style?.textureMaterial, "future-material", "unknown materials are kept, not dropped")
    XCTAssertNil(sender.strokes.first { $0.id == "plain" }?.style?.textureMode)
    XCTAssertTrue(sender.strokes.contains { $0.style?.textureMode == "experimental-3d" })
    sender.stopLocally()
  }
}
