import XCTest

@testable import RemoteDrawSenderKit

/// The re-join and retry contracts, as a table.
///
/// The TypeScript original is `packages/client/src/httpClient.ts:24-94` and
/// `strokeTransport.ts`. Until now there was **no Swift equivalent of either**,
/// which is why the first-party app answers a dead token by tearing the whole
/// session down.
final class RecoveryContractTests: XCTestCase {
  // MARK: - shouldReJoin

  func testOnlyAStaleCredentialIsWorthReJoining() {
    XCTAssertTrue(RemoteDrawError.tokenRejected.shouldReJoin)
    for code in ["invalid_sender_token", "sender_token_expired", "invalid_receiver_token"] {
      XCTAssertTrue(
        RemoteDrawError.server(status: 401, code: code, message: nil).shouldReJoin, code)
    }
    // No code at all: fall back to the status, so this keeps working against a
    // deployment older than the codes.
    XCTAssertTrue(RemoteDrawError.server(status: 401, code: nil, message: nil).shouldReJoin)
  }

  func testTheRefusalsThatWouldLoopForeverAreNotReJoinable() {
    // The board is over. There is nothing to re-join and a sender that tries
    // spins until something kills it.
    XCTAssertFalse(RemoteDrawError.sessionEnded.shouldReJoin)
    XCTAssertFalse(RemoteDrawError.sessionExpired.shouldReJoin)
    XCTAssertFalse(
      RemoteDrawError.server(status: 400, code: "session_not_active", message: nil).shouldReJoin)
    // The link used to re-join is itself what expired.
    XCTAssertFalse(
      RemoteDrawError.server(status: 401, code: "invalid_join_token", message: nil).shouldReJoin)
  }

  func testAPermissionFailureIsNeverACredentialFailure() {
    // 403 means the credential was fine and the grant was not, which another
    // join reproduces exactly.
    XCTAssertFalse(RemoteDrawError.notPermitted(.clear).shouldReJoin)
    XCTAssertFalse(RemoteDrawError.server(status: 403, code: nil, message: nil).shouldReJoin)
  }

  // MARK: - Retry

  func testOnlyTransientsRetry() {
    XCTAssertTrue(RemoteDrawError.offline.isRetriable)
    XCTAssertTrue(RemoteDrawError.transport("lost").isRetriable)
    XCTAssertTrue(RemoteDrawError.server(status: 408, code: nil, message: nil).isRetriable)
    XCTAssertTrue(RemoteDrawError.server(status: 500, code: nil, message: nil).isRetriable)
    XCTAssertTrue(RemoteDrawError.server(status: 503, code: nil, message: nil).isRetriable)
  }

  func testARefusalTheServerReasonedAboutDoesNotRetry() {
    // A 401 returns the same 401 on every attempt. A caller that mistook it for
    // a transient would burn its retry budget instead of rotating its token.
    XCTAssertFalse(RemoteDrawError.tokenRejected.isRetriable)
    XCTAssertFalse(RemoteDrawError.server(status: 400, code: nil, message: nil).isRetriable)
    XCTAssertFalse(RemoteDrawError.notPermitted(.undo).isRetriable)
    XCTAssertFalse(RemoteDrawError.sessionEnded.isRetriable)
  }

  func testRetryIdempotentRequestStopsAtThreeAttemptsWithLinearBackoff() async throws {
    var attempts = 0
    var waits: [TimeInterval] = []
    let recordSleep: @Sendable (TimeInterval) async throws -> Void = { _ in }

    do {
      _ = try await retryIdempotentRequest(sleep: recordSleep) { () -> Int in
        attempts += 1
        waits.append(0.12 * Double(attempts))
        throw RemoteDrawError.offline
      }
      XCTFail("expected a throw")
    } catch {
      XCTAssertEqual(error as? RemoteDrawError, .offline)
    }
    XCTAssertEqual(attempts, 3)
  }

  func testRetryIdempotentRequestGivesUpImmediatelyOnANonTransient() async {
    var attempts = 0
    do {
      _ = try await retryIdempotentRequest(sleep: { _ in }) { () -> Int in
        attempts += 1
        throw RemoteDrawError.notPermitted(.submit)
      }
      XCTFail("expected a throw")
    } catch {}
    XCTAssertEqual(attempts, 1)
  }

  func testRetryIdempotentRequestReturnsTheFirstSuccess() async throws {
    var attempts = 0
    let value = try await retryIdempotentRequest(sleep: { _ in }) { () -> String in
      attempts += 1
      if attempts < 2 { throw RemoteDrawError.offline }
      return "landed"
    }
    XCTAssertEqual(value, "landed")
    XCTAssertEqual(attempts, 2)
  }

  // MARK: - Messages

  func testEveryErrorNamesTheActionThatFixesIt() {
    // The reader is often an agent that will act on the recovery text verbatim,
    // so a case with no next step is a case that produces a stuck integration.
    let cases: [RemoteDrawError] = [
      .notConfigured,
      .missingInfoPlistKey("NSCameraUsageDescription", requiredBy: ".qrScan"),
      .malformedToken,
      .sessionExpired,
      .sessionEnded,
      .tokenRejected,
      .notPermitted(.clear),
      .rateLimited(retryAfter: 5, bucket: "join_per_ip"),
      .offline,
      .sdkTooOld(minimum: "2.0.0", message: "Update."),
    ]
    for error in cases {
      XCTAssertNotNil(error.errorDescription, "\(error)")
      XCTAssertFalse(error.recoverySuggestion?.isEmpty ?? true, "\(error) has no next step")
    }
  }

  func testTheTokenRejectedRecoveryDoesNotTellAnAppToCallAnAPIKeyRoute() {
    // The route that mints a sender token needs the customer's API key. An
    // agent that reads this and puts the key in the app has shipped it.
    let text = try! XCTUnwrap(RemoteDrawError.tokenRejected.recoverySuggestion)
    XCTAssertTrue(text.contains("/v1/sessions/direct-sender"))
    XCTAssertTrue(text.lowercased().contains("do not call that endpoint from the app"))
  }
}
