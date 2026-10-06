import XCTest
@testable import RemoteDrawSenderKit

@MainActor
final class SessionGeometryTests: XCTestCase {
  private func response(_ revision: Int, width: Int = 200, id: String = "session_1") throws -> RemoteDrawSessionResponse {
    try .decoded(fromJSON: """
      {"senderId":"unexpected_sender","lastSequence":9999,"session":{
       "id":"\(id)","geometryRevision":\(revision),"capabilities":["draw"],
       "target":{"kind":"paper","coordinateSpace":{"width":\(width),"height":100}}}}
      """)
  }

  func testContainPresentationKeepsCanonicalUnitsIncludingMapAndRetainsViewportCamera() throws {
    func snapshot(kind: String = "paper", mapping: String = "surface", width: Int = 300) throws -> RemoteDrawSession {
      try .decoded(fromJSON: """
        {"id":"s","geometryRevision":2,"surfacePresentation":{"width":\(width),"height":600},
         "target":{"kind":"\(kind)","inputMapping":"\(mapping)",
          "coordinateSpace":{"width":1000,"height":500}}}
        """)
    }
    let value = try snapshot()
    XCTAssertTrue(value.usesContainedSurfacePresentation)
    XCTAssertEqual(value.target?.coordinateSpace?.aspectRatio, 2)
    XCTAssertEqual(value.surfacePresentation?.aspectRatio, 0.5)
    XCTAssertTrue(try snapshot(kind: "map").usesContainedSurfacePresentation)
    XCTAssertFalse(try snapshot(kind: "map", mapping: "viewport").usesContainedSurfacePresentation)
    XCTAssertFalse(try snapshot(mapping: "viewport").usesContainedSurfacePresentation)
    XCTAssertFalse(try snapshot(width: 0).usesContainedSurfacePresentation)
  }

  func testPresentationRefreshPreservesCanonicalMapAndViewportState() async throws {
    for kind in ["paper", "screen", "whiteboard", "map", "custom"] {
      for mapping in ["surface", "viewport"] {
        func snapshot(_ revision: Int, width: Int) throws -> RemoteDrawSessionResponse {
          try .decoded(fromJSON: """
            {"session":{"id":"session_1","geometryRevision":\(revision),
             "surfacePresentation":{"width":\(width),"height":600},
             "target":{"kind":"\(kind)","inputMapping":"\(mapping)",
              "coordinateSpace":{"width":1000,"height":500,
               "bounds":{"minX":4,"minY":50,"maxX":5,"maxY":51}}},
             "phoneProjection":{"centerX":0.3,"centerY":0.4,"width":0.2,"height":0.3,
              "rotationDegrees":15,"aspectRatio":0.5,"updatedAt":1}}}
            """)
        }
        let initial = try snapshot(1, width: 1000).session
        let transport = FakeTransport()
        transport.sessionResult = .success(try snapshot(2, width: 300))
        let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
          senderId: "sender_1", session: initial, automaticallyRefreshDrawings: false,
          pollClock: transport.holdAutomaticPolling())
        defer { session.stopLocally() }
        await transport.settleStartup()
        try await session.refreshSession()
        XCTAssertEqual(session.session?.geometryRevision, 2)
        XCTAssertEqual(session.session?.target?.coordinateSpace, initial.target?.coordinateSpace)
        XCTAssertEqual(session.session?.phoneProjection, initial.phoneProjection)
        XCTAssertEqual(session.session?.surfacePresentation?.aspectRatio, 0.5)
        XCTAssertEqual(session.senderId, "sender_1")
        XCTAssertEqual(session.session?.usesContainedSurfacePresentation, mapping == "surface")
      }
    }
  }

  func testLegacySessionRevisionDefaultsToZero() throws {
    XCTAssertEqual(try RemoteDrawSession.decoded(fromJSON: #"{"id":"s"}"#).geometryRevision, 0)
  }

  func testRefreshDoesNotRequireDrawingAccessOrReplaceIdentity() async throws {
    let transport = FakeTransport()
    transport.sessionResult = .success(try response(2))
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      senderId: "sender_1", session: .stub(), lastSequence: 40, automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { session.stopLocally() }
    await transport.settleStartup()
    try await session.refreshSession()
    XCTAssertEqual(session.session?.geometryRevision, 2)
    XCTAssertEqual(session.session?.target?.coordinateSpace?.width, 200)
    XCTAssertEqual(session.senderToken, "rd_send_1")
    XCTAssertEqual(session.senderId, "sender_1")
    XCTAssertEqual(transport.callCount(.drawings), 0)
    session.begin(stroke: "ink", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    _ = try await session.end(stroke: "ink")
    XCTAssertTrue(transport.calls.compactMap(\.sequence).allSatisfy { $0 > 40 && $0 < 9999 })
  }

  func testOutOfOrderSessionAndDrawingSnapshotsCannotRewindGeometry() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: .stub(), capabilities: ["draw", "viewExisting"], automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { session.stopLocally() }
    await transport.settleStartup()
    var pending: CheckedContinuation<RemoteDrawSessionResponse, Error>?
    transport.sessionHook = { try await withCheckedThrowingContinuation { pending = $0 } }
    let oldRead = Task { try await session.refreshSession() }
    while pending == nil { await Task.yield() }
    transport.sessionHook = nil
    transport.sessionResult = .success(try response(3, width: 300))
    try await session.refreshSession()
    pending?.resume(returning: try response(1))
    try await oldRead.value
    transport.drawingsJSON = #"{"items":[],"session":{"id":"session_1","geometryRevision":2}}"#
    _ = try await session.refreshDrawings()
    XCTAssertEqual(session.session?.geometryRevision, 3)
    XCTAssertEqual(session.session?.target?.coordinateSpace?.width, 300)
    transport.sessionResult = .success(try response(8, id: "another_board"))
    try await session.refreshSession()
    XCTAssertEqual(session.session?.id, "session_1")
  }

  func testLateSessionResponseAfterRemoteEndCannotResurrectSession() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: .stub(), automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { session.stopLocally() }
    await transport.settleStartup()
    var pending: CheckedContinuation<RemoteDrawSessionResponse, Error>?
    transport.sessionHook = { try await withCheckedThrowingContinuation { pending = $0 } }
    let read = Task { try await session.refreshSession() }
    while pending == nil { await Task.yield() }
    transport.pingHook = { _, _ in throw RemoteDrawError.sessionEnded }
    await session.markActive()
    XCTAssertEqual(session.phase, .ended(.ended))
    pending?.resume(returning: try response(10))
    try await read.value
    XCTAssertEqual(session.phase, .ended(.ended))
    XCTAssertEqual(session.session?.geometryRevision, 0)
  }

  func testLateResponseFromRotatedCredentialCannotAdoptGeometry() async throws {
    let transport = FakeTransport()
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      senderId: "sender_1", session: .stub(), automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    defer { session.stopLocally() }
    await transport.settleStartup()
    var pending: CheckedContinuation<RemoteDrawSessionResponse, Error>?
    transport.sessionHook = { try await withCheckedThrowingContinuation { pending = $0 } }
    let read = Task { try await session.refreshSession() }
    while pending == nil { await Task.yield() }
    transport.refreshResult = .success(RemoteDrawRefreshResponse(
      senderToken: "rd_send_new", senderId: "sender_1", capabilities: ["draw"], lastSequence: 20))
    let recovered = await session.recoverRejectedCredential("rd_send_1")
    XCTAssertTrue(recovered)
    pending?.resume(returning: try response(10))
    try await read.value
    XCTAssertEqual(session.senderToken, "rd_send_new")
    XCTAssertEqual(session.session?.geometryRevision, 0)
  }

  func testAutomaticRefreshWorksWhenDrawingPollingIsDisabledAndStopsInactive() async throws {
    let transport = FakeTransport()
    transport.sessionResult = .success(try response(4))
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: .stub(), automaticallyRefreshDrawings: false)
    try await Task.sleep(nanoseconds: 1_100_000_000)
    XCTAssertEqual(session.session?.geometryRevision, 4)
    XCTAssertEqual(transport.callCount(.drawings), 0)
    await session.markInactive()
    let count = transport.callCount(.session)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    XCTAssertEqual(transport.callCount(.session), count)
  }
}
