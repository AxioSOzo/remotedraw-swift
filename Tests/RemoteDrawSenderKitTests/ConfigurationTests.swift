import XCTest

@testable import RemoteDrawSenderKit

/// Forgetting `configure` must never be a crash.
///
/// The trap this replaces was reached from `.remoteDrawSurface`'s `.task` —
/// inside a `do`/`catch` that could not catch it, because a `preconditionFailure`
/// is not an `Error`. The customer in
/// `docs/friction/2026-08-30-domucortex-run2-notes.md` hit it as a production
/// crash on their user's tap, with `RemoteDrawError.notConfigured` unreachable
/// from the documented one-liner.
final class ConfigurationTests: XCTestCase {
  override func setUp() {
    super.setUp()
    RemoteDraw.reset()
  }

  override func tearDown() {
    RemoteDraw.reset()
    super.tearDown()
  }

  func testSharedConfiguresItselfAgainstProductionRatherThanTrapping() {
    XCTAssertFalse(RemoteDraw.isConfigured)

    let instance = RemoteDraw.shared

    XCTAssertTrue(RemoteDraw.isConfigured, "reading `shared` installs the defaults")
    XCTAssertEqual(instance.configuration.apiBaseURL.url, RemoteDrawAPIBaseURL.production.url)
    XCTAssertNil(instance.configuration.device, "the SDK describes the device itself")
    XCTAssertNil(instance.configuration.tokenProvider)
  }

  func testTheAutoConfiguredInstanceIsStableAcrossReads() {
    XCTAssertTrue(RemoteDraw.shared === RemoteDraw.shared)
  }

  func testConfigureStillWinsBeforeAndAfterAutoConfiguration() {
    let custom = RemoteDrawAPIBaseURL.custom(URL(string: "https://example.test")!)

    RemoteDraw.configure(.init(apiBaseURL: custom))
    XCTAssertEqual(RemoteDraw.shared.configuration.apiBaseURL.url, custom.url)

    RemoteDraw.reset()
    _ = RemoteDraw.shared  // auto-configures
    RemoteDraw.configure(.init(apiBaseURL: custom))
    XCTAssertEqual(
      RemoteDraw.shared.configuration.apiBaseURL.url, custom.url,
      "an explicit configure replaces an auto-configured instance")
  }

  /// The strict path, for a host that wants a missing `configure` to be an
  /// error it can report rather than a default it did not choose. This is the
  /// one place `.notConfigured` is still reachable — and it is thrown, so it can
  /// travel out through `onOutcome` like any other error.
  func testRequireConfiguredThrowsNotConfiguredAndNeverAutoConfigures() {
    XCTAssertThrowsError(try RemoteDraw.requireConfigured()) { error in
      XCTAssertEqual(error as? RemoteDrawError, .notConfigured)
    }
    XCTAssertFalse(
      RemoteDraw.isConfigured, "the strict accessor must not install anything on its way out")

    RemoteDraw.configure(.init())
    XCTAssertNoThrow(try RemoteDraw.requireConfigured())
  }

  func testNotConfiguredStillCarriesTheFixInItsMessage() {
    XCTAssertEqual(RemoteDrawError.notConfigured.errorDescription, "RemoteDraw is not configured.")
    XCTAssertEqual(
      RemoteDrawError.notConfigured.recoverySuggestion,
      "Call RemoteDraw.configure(.init(apiBaseURL: .production)) from your App's init.")
  }
}
