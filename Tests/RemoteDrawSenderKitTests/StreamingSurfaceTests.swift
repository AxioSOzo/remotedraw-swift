import XCTest

@testable import RemoteDrawSenderKit

/// What the wire says about streaming, and what this SDK says back.
///
/// The customer's blank white pad in
/// `docs/plans/2026-08-30-audit-connection-and-streaming.md` §2.6 started here:
/// `RemoteDrawSession`'s `CodingKeys` did not include `visualContext` or
/// `senderIntegrationMode`, so a session created with
/// `senderIntegrationMode: "streaming"` produced **no behaviour change
/// whatsoever** in this SDK — a silent trap.
final class StreamingSurfaceTests: XCTestCase {
  private func decode(_ json: String) throws -> RemoteDrawSession {
    try JSONDecoder().decode(RemoteDrawSession.self, from: Data(json.utf8))
  }

  func testExplicitNativeModeWinsOverOptionalPixelAvailability() throws {
    for kind in ["whiteboard", "map", "custom"] {
      let session = try decode("""
        {"id":"s","target":{"kind":"\(kind)"},"senderIntegrationMode":"native",
         "visualContext":{"enabled":true}}
        """)
      XCTAssertFalse(session.requestsStreaming, "Explicit native \(kind) must not be redirected")
    }
  }

  func testASessionDecodesTheFieldsTheSenderPayloadActuallyCarries() throws {
    // Every key here is one `publicSessionForSender` emits
    // (`convex/lib/senderActivation.ts`).
    let session = try decode(
      """
      {"id":"session_1","boardId":"board_9","status":"active","markupPreset":"mapMarkup",
       "senderIntegrationMode":"streaming","capabilities":["draw","undo"],
       "visualContext":{"enabled":true,"maxFps":12,"maxLongEdge":960,
         "redact":[{"x":0.1,"y":0.2,"width":0.3,"height":0.4}],
         "iceServers":[{"urls":"stun:stun.example.com:3478"},
                       {"urls":["turn:turn.example.com:3478"],"username":"u","credential":"c"}]},
       "expiresAt":1750000000000}
      """)

    XCTAssertEqual(session.boardId, "board_9")
    XCTAssertEqual(session.markupPreset, "mapMarkup")
    XCTAssertEqual(session.senderIntegrationMode, .streaming)
    XCTAssertEqual(session.visualContext?.enabled, true)
    XCTAssertEqual(session.visualContext?.maxFps, 12)
    XCTAssertEqual(session.visualContext?.maxLongEdge, 960)
    XCTAssertEqual(session.visualContext?.redact?.count, 1)
    XCTAssertEqual(session.visualContext?.redact?.first?.width, 0.3)

    // `urls` arrives as a bare string or a list; a consumer should not care.
    XCTAssertEqual(session.visualContext?.iceServers?.count, 2)
    XCTAssertEqual(session.visualContext?.iceServers?[0].urls, ["stun:stun.example.com:3478"])
    XCTAssertNil(session.visualContext?.iceServers?[0].username)
    XCTAssertEqual(session.visualContext?.iceServers?[1].urls, ["turn:turn.example.com:3478"])
    XCTAssertEqual(session.visualContext?.iceServers?[1].credential, "c")
  }

  func testEitherHalfOfTheStreamingRequestCounts() throws {
    // The two say the same thing from opposite ends, and answering "no" to half
    // of it is how the blank pad happened.
    XCTAssertTrue(
      try decode(#"{"id":"s","senderIntegrationMode":"streaming"}"#).requestsStreaming)
    XCTAssertTrue(
      try decode(#"{"id":"s","visualContext":{"enabled":true}}"#).requestsStreaming)
    XCTAssertFalse(
      try decode(#"{"id":"s","senderIntegrationMode":"native"}"#).requestsStreaming)
    XCTAssertFalse(
      try decode(#"{"id":"s","visualContext":{"enabled":false}}"#).requestsStreaming)
    XCTAssertFalse(try decode(#"{"id":"s"}"#).requestsStreaming)
  }

  func testAnUnknownIntegrationModeKeepsItsNameRatherThanBecomingNative() throws {
    let session = try decode(#"{"id":"s","senderIntegrationMode":"holographic"}"#)
    XCTAssertEqual(session.senderIntegrationMode, .other("holographic"))
    XCTAssertFalse(session.requestsStreaming, "an unknown mode is not a streaming request")
  }

  func testAnUnreadableVisualContextCostsTheFieldAndNotTheSession() throws {
    // Forward-decoding, like every other optional on this type: losing the
    // board's description is survivable, losing the credential is not.
    let session = try decode(#"{"id":"s","visualContext":"who knows","capabilities":["draw"]}"#)
    XCTAssertEqual(session.id, "s")
    XCTAssertEqual(session.capabilities, ["draw"])
    XCTAssertNil(session.visualContext)
  }

  func testTheUnsupportedSurfaceNamesTheProblemAndTheWayOut() {
    let unsupported = RemoteDrawUnsupportedSurface.streaming(senderToken: "rd_send_abc123")

    XCTAssertEqual(unsupported.reason, .streamingRequested)
    XCTAssertFalse(unsupported.message.isEmpty)
    XCTAssertTrue(
      unsupported.recoverySuggestion.contains("hostedSenderURL"),
      "the suggestion has to name the action, not describe the state")

    let url = unsupported.hostedSenderURL?.absoluteString
    XCTAssertEqual(url, "https://app.remotedraw.com/join#senderToken=rd_send_abc123")
    // In the fragment, so the credential never reaches a server log; and
    // without `native=1`, so the page keeps the controls a customer app has no
    // native chrome to supply.
    XCTAssertEqual(unsupported.hostedSenderURL?.query, nil)
    XCTAssertFalse(url?.contains("native=1") ?? true)
  }
}
