import XCTest

@testable import RemoteDrawSenderKit

/// Every response type must decode forward.
///
/// The rule from §8.2 of the plan: an installed SDK cannot be recalled, so a
/// response shape this build has never seen must not cost a sender its session.
/// New behaviour arrives as new optional fields and new `capabilities` strings —
/// never as a field that changes meaning.
final class ForwardCompatibilityTests: XCTestCase {
  private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
  }

  func testAJoinSurvivesUnknownFieldsAndAnUnreadableSession() throws {
    // The token is the only thing a sender cannot work without, so it is the
    // only required field. A `session` shaped in some way this build does not
    // recognise is decoded with `try?` — losing the board's description is
    // survivable, losing the credential is not.
    let response = try decode(
      RemoteDrawJoinResponse.self,
      """
      {"senderToken":"rd_send_1","senderId":"s1","capabilities":["draw","timeTravel"],
       "lastSequence":7,"session":{"unexpected":"shape"},
       "somethingAddedNextYear":{"nested":[1,2,3]}}
      """)
    XCTAssertEqual(response.senderToken, "rd_send_1")
    XCTAssertEqual(response.capabilities, ["draw", "timeTravel"])
    XCTAssertEqual(response.lastSequence, 7)
    XCTAssertNil(response.session)
  }

  func testASessionMissingEverythingOptionalStillDecodes() throws {
    let session = try decode(RemoteDrawSession.self, #"{"id":"session_1"}"#)
    XCTAssertEqual(session.id, "session_1")
    XCTAssertTrue(session.isActive, "a session that does not say otherwise is active")
    XCTAssertTrue(session.capabilities.isEmpty)
    XCTAssertNil(session.target)
  }

  func testAnUnknownSurfaceStillDraws() throws {
    // A board with an unfamiliar surface still has to render. Unknown names
    // resolve to the default ground rather than failing the decode.
    let session = try decode(
      RemoteDrawSession.self,
      #"{"id":"s","target":{"kind":"holograph","label":"Table"},"capabilities":["draw"]}"#)
    XCTAssertEqual(session.target?.kind, "holograph")
    XCTAssertEqual(session.target?.ground, .paper)
  }

  func testTheKnownSurfacesMapOntoTheGroundsTheRendererHas() throws {
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("paper"), .paper)
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("whiteboard"), .whiteboard)
    // `plain` is the protocol's deprecated alias for a whiteboard and must not
    // be treated as an unknown name.
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("plain"), .whiteboard)
    // The SDK's own case: the host renders the ground, so inventing a paper
    // tooth over their artwork would be worse than having none.
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("custom"), .transparent)
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("pdf"), .transparent)
    XCTAssertEqual(RemoteDrawGround.forProtocolSurface("map"), .transparent)
  }

  func testAnUnknownCapabilityRoundTripsThroughItsRawValue() {
    let capability = RemoteDrawCapability(rawValue: "annotatePdf")
    XCTAssertEqual(capability, .other("annotatePdf"))
    XCTAssertEqual(capability.rawValue, "annotatePdf")
  }

  func testADraftRejectionCarriesAReasonThisBuildHasNeverSeen() throws {
    // Deliberately a String and not an enum: an unfamiliar reason must arrive
    // intact instead of failing the decode at the wire boundary.
    let ack = try decode(
      RemoteDrawDraftAck.self,
      #"{"accepted":false,"reason":"quota_exhausted","lastSequence":12,"extra":true}"#)
    XCTAssertFalse(ack.accepted)
    XCTAssertEqual(ack.reason, "quota_exhausted")
    XCTAssertFalse(ack.isStaleSequence)
  }

  func testACommitResultWithNothingButAnIdDecodes() throws {
    let result = try decode(RemoteDrawCommitResult.self, #"{"id":"d1"}"#)
    XCTAssertEqual(result.id, "d1")
    XCTAssertFalse(result.isDuplicate)
    XCTAssertNil(result.points)
  }

  func testARefreshResponseSurvivesAnUnreadableSession() throws {
    let rotated = try decode(
      RemoteDrawRefreshResponse.self,
      #"{"senderToken":"rd_send_2","session":42,"newFieldNextYear":true}"#)
    XCTAssertEqual(rotated.senderToken, "rd_send_2")
    XCTAssertNil(rotated.session)
  }

  func testHiddenElementsAreNotPainted() throws {
    // `listDrawings` serves hidden elements too — hiding is a property, not a
    // deletion — but a hidden element is by definition not on the board, so
    // painting it shows ink the receiver is not showing.
    let response = try decode(
      RemoteDrawDrawingsResponse.self,
      """
      {"items":[
        {"id":"a","type":"freehand","points":[{"x":0,"y":0}]},
        {"id":"b","type":"freehand","points":[{"x":0,"y":0}],"hidden":true},
        {"id":"c","type":"freehand","points":[{"x":0,"y":0}],"hidden":false}
      ]}
      """)
    XCTAssertEqual(response.items.paintable.map(\.id), ["a", "c"])
  }

  func testATokenIsRecognisedByItsPrefixAndNothingElse() {
    XCTAssertEqual(RemoteDrawToken(raw: "  rd_join_abc  "), .join("rd_join_abc"))
    XCTAssertEqual(RemoteDrawToken(raw: "rd_send_abc"), .sender("rd_send_abc"))
    // Guessing would be worse than refusing: a join token handed to a route
    // that wants a sender token produces a 401, which an SDK answers by
    // re-joining, which loops.
    XCTAssertNil(RemoteDrawToken(raw: "https://remotedraw.com/join?token=rd_join_abc"))
    XCTAssertNil(RemoteDrawToken(raw: "rd_key_abc"))
    XCTAssertNil(RemoteDrawToken(raw: ""))
  }

  func testAnErasingTransformIsAnExplicitNullAndNotAnOmittedKey() throws {
    // Omitting the key means "leave the transform alone" — the opposite of what
    // an erase means, and the kind of difference JSON encoders paper over.
    let erase = RemoteDrawElementEdit.setProperties([
      .init(drawingId: "d1", expectedRevision: 3, transform: nil)
    ])
    let json = try XCTUnwrap(String(data: JSONEncoder().encode(erase), encoding: .utf8))
    XCTAssertTrue(json.contains("\"transform\":null"), json)

    let move = RemoteDrawElementEdit.setProperties([
      .init(
        drawingId: "d1", expectedRevision: 3,
        transform: RemoteDrawTransform(translateX: 0.1, translateY: -0.2))
    ])
    let moveJSON = try XCTUnwrap(String(data: JSONEncoder().encode(move), encoding: .utf8))
    XCTAssertFalse(moveJSON.contains("\"transform\":null"))
    XCTAssertTrue(moveJSON.contains("\"expectedRevision\":3"))
  }

  func testADeleteCarriesNoRevision() throws {
    // "Get rid of that" means the same thing however the element has moved.
    let json = try XCTUnwrap(
      String(data: JSONEncoder().encode(RemoteDrawElementEdit.delete(["a", "b"])), encoding: .utf8))
    XCTAssertTrue(json.contains("\"kind\":\"delete\""))
    XCTAssertFalse(json.contains("expectedRevision"))
  }

  func testAnUnderstoodRefusalIsA200AndMustBeRead() throws {
    // Only a malformed body or a dead token is a 4xx. A caller that treats the
    // absence of a throw as success silently ignores every stale-revision
    // rejection the board makes.
    let refused = try decode(
      RemoteDrawEditResult.self,
      #"{"accepted":false,"reason":"revision_mismatch","drawingId":"d1","elements":[{"drawingId":"d1","revision":9}]}"#
    )
    XCTAssertFalse(refused.accepted)
    XCTAssertEqual(refused.reason, "revision_mismatch")
    XCTAssertEqual(refused.elements.first?.revision, 9)

    // A refusal this build has never heard of arrives intact rather than
    // failing the decode.
    let novel = try decode(
      RemoteDrawEditResult.self, #"{"accepted":false,"reason":"frozen_by_moderator"}"#)
    XCTAssertEqual(novel.reason, "frozen_by_moderator")
    XCTAssertTrue(novel.elements.isEmpty)
  }

  func testEveryRouteThatNeedsAGrantNamesIt() {
    // So a 403 can be reported as the capability that was missing rather than
    // as a bare status code.
    XCTAssertEqual(RemoteDrawSenderRoute.undo.requiredCapability, .undo)
    XCTAssertEqual(RemoteDrawSenderRoute.clear.requiredCapability, .clear)
    XCTAssertNil(RemoteDrawSenderRoute.submit.requiredCapability)
    XCTAssertEqual(RemoteDrawSenderRoute.drawings.requiredCapability, .viewExisting)
    XCTAssertEqual(RemoteDrawSenderRoute.projection.requiredCapability, .moveViewport)
    XCTAssertNil(RemoteDrawSenderRoute.draft.requiredCapability)
    XCTAssertNil(RemoteDrawSenderRoute.commit.requiredCapability)
  }

  func testTheRouteTableIsTheDocumentedSenderSurfaceAndNothingMore() {
    // 107 routes exist. These are the ones a phone holding only a sender token
    // may call; anything else needs an API key, a receiver token, or an account
    // and has no business in an SDK that ships inside somebody else's app.
    XCTAssertEqual(
      Set(RemoteDrawSenderRoute.allCases.map(\.rawValue)),
      [
        "/v1/join",
      "/v1/sender/session",
      "/v1/sender/sync",
        "/v1/sender/ping",
        "/v1/sender/draft",
        "/v1/sender/commit",
        "/v1/sender/replace",
        "/v1/sender/edit",
        "/v1/sender/clear-draft",
        "/v1/sender/undo",
        "/v1/sender/clear",
        "/v1/sender/submit",
        "/v1/sender/drawings",
        "/v1/sender/projection",
        "/v1/sender/projection/close",
        "/v1/sender/refresh",
      ])
  }
}
