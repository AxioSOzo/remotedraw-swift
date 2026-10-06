import XCTest
@testable import RemoteDrawSenderKit

@MainActor
final class AnnotationInputTests: XCTestCase {
  private func response(_ revision: Int, paused: Bool = false) throws -> RemoteDrawSessionResponse {
    try .decoded(fromJSON: """
      {"session":{"id":"session_1","geometryRevision":1,"capabilities":["draw"],
       "annotationInput":{"revision":\(revision),"paused":\(paused)},
       "target":{"kind":"screen","coordinateSpace":{"width":200,"height":100}}}}
      """)
  }

  private func makeSession(_ transport: FakeTransport, revision: Int = 4, paused: Bool = false)
    async throws -> RemoteDrawSenderSession
  {
    let session = RemoteDrawSenderSession.adopt(senderToken: "rd_send_1", transport: transport,
      session: try response(revision, paused: paused).session, automaticallyRefreshDrawings: false,
      pollClock: transport.holdAutomaticPolling())
    addTeardownBlock { await session.stopLocally() }
    await transport.settleStartup()
    return session
  }

  func testLegacyAndAnnotationSessionDecoding() throws {
    XCTAssertNil(try RemoteDrawSession.decoded(fromJSON: #"{"id":"legacy"}"#).annotationInput)
    let input = try XCTUnwrap(response(7, paused: true).session.annotationInput)
    XCTAssertEqual(input.revision, 7)
    XCTAssertTrue(input.paused)
  }

  func testRevisionIsEncodedForDraftAndCommitAndOmittedForLegacyRequests() throws {
    func body<T: Encodable>(_ request: T) throws -> [String: Any] {
      try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
    }
    let points = [RemoteDrawNormalizedPoint(x: 0.1, y: 0.2)]
    XCTAssertEqual(try body(RemoteDrawDraftRequest(senderToken: "t", sequence: 1,
      points: points, annotationRevision: 7))["annotationRevision"] as? Int, 7)
    XCTAssertEqual(try body(RemoteDrawCommitRequest(senderToken: "t", clientStrokeId: "s",
      sequence: 2, points: points, annotationRevision: 7))["annotationRevision"] as? Int, 7)
    XCTAssertNil(try body(RemoteDrawDraftRequest(senderToken: "t", sequence: 1,
      points: points))["annotationRevision"])
    XCTAssertNil(try body(RemoteDrawCommitRequest(senderToken: "t", clientStrokeId: "s",
      sequence: 2, points: points))["annotationRevision"])
  }

  func testPausedInputDoesNotStartStrokeOrSendTextDraft() async throws {
    let transport = FakeTransport()
    let session = try await makeSession(transport, paused: true)
    session.begin(stroke: "paused", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    XCTAssertNil(session.live)
    let result = try await session.end(stroke: "paused")
    XCTAssertNil(result)
    await session.draftText("note", at: .init(x: 0.1, y: 0.1))
    XCTAssertEqual(transport.callCount(.draft), 0)
    XCTAssertEqual(transport.callCount(.commit), 0)
  }

  func testUnchangedAnnotationSnapshotPreservesStrokeAndRevision() async throws {
    let transport = FakeTransport()
    let session = try await makeSession(transport)
    session.begin(stroke: "kept", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    transport.sessionResult = .success(try response(4))
    try await session.refreshSession()
    XCTAssertEqual(session.live?.id, "kept")
    _ = try await session.end(stroke: "kept")
    XCTAssertEqual(transport.commitRequests.count, 1)
    XCTAssertEqual(transport.commitRequests.first?.annotationRevision, 4)
  }

  func testNewAnnotationRevisionCancelsStrokeAndNextStrokeUsesNewRevision() async throws {
    let transport = FakeTransport()
    let session = try await makeSession(transport)
    session.begin(stroke: "old", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    transport.sessionResult = .success(try response(5))
    try await session.refreshSession()
    XCTAssertNil(session.live)
    let oldResult = try await session.end(stroke: "old")
    XCTAssertNil(oldResult)
    XCTAssertEqual(transport.callCount(.commit), 0)
    session.begin(stroke: "new", tool: .freehand)
    session.append([.init(x: 0.3, y: 0.3), .init(x: 0.4, y: 0.4)])
    _ = try await session.end(stroke: "new")
    XCTAssertEqual(transport.commitRequests.first?.annotationRevision, 5)
  }

  func testPauseSnapshotCancelsActiveStrokeEvenAtSameRevision() async throws {
    let transport = FakeTransport()
    let session = try await makeSession(transport)
    session.begin(stroke: "old", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    transport.sessionResult = .success(try response(4, paused: true))
    try await session.refreshSession()
    XCTAssertNil(session.live)
    let result = try await session.end(stroke: "old")
    XCTAssertNil(result)
    XCTAssertEqual(transport.callCount(.commit), 0)
  }

  func testStaleAnnotationSnapshotCannotRewindMappingOrCancelCurrentStroke() async throws {
    let transport = FakeTransport()
    let session = try await makeSession(transport)
    session.begin(stroke: "kept", tool: .freehand)
    session.append([.init(x: 0.1, y: 0.1), .init(x: 0.2, y: 0.2)])
    transport.sessionResult = .success(try response(3, paused: true))
    try await session.refreshSession()
    XCTAssertEqual(session.session?.annotationInput?.revision, 4)
    XCTAssertEqual(session.session?.annotationInput?.paused, false)
    XCTAssertEqual(session.live?.id, "kept")
    _ = try await session.end(stroke: "kept")
    XCTAssertEqual(transport.commitRequests.first?.annotationRevision, 4)
  }
}
