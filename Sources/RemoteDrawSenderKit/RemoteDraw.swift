@_exported import RemoteDrawInk
import Foundation

/// The one entry point.
///
/// Configured once, everything else defaulted:
///
/// ```swift
/// RemoteDraw.configure(.init(apiBaseURL: .production))
/// let session = try await RemoteDraw.shared.join(rawToken: senderToken)
/// ```
///
/// This is the Stage 1 surface — the headless core. The presentation,
/// initiator and appearance halves of `RemoteDrawConfiguration` described in
/// `docs/plans/ios-sender-sdk.md` §6.2 arrive with the surface in Stage 2, and
/// are deliberately absent rather than stubbed: an option that does nothing is
/// worse than one that is not there.
public final class RemoteDraw: @unchecked Sendable {
  /// The version this build reports in `X-RemoteDraw-SDK`, and the one a
  /// `clientAdvisory` compares against.
  public static let sdkVersion = "0.1.0"

  private static let lock = NSLock()
  nonisolated(unsafe) private static var _shared: RemoteDraw?

  /// The configured instance.
  ///
  /// Traps with an actionable message rather than returning an optional every
  /// call site would have to unwrap: forgetting to configure is a wiring
  /// mistake caught on the first run, not a runtime condition to handle.
  public static var shared: RemoteDraw {
    lock.lock()
    defer { lock.unlock() }
    guard let _shared else {
      preconditionFailure(
        "RemoteDraw is not configured. Call RemoteDraw.configure(.init(apiBaseURL: .production)) from your App's init.")
    }
    return _shared
  }

  /// Whether ``shared`` is usable, for a host that wants to check rather than
  /// trap.
  public static var isConfigured: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _shared != nil
  }

  public static func configure(_ configuration: RemoteDrawConfiguration) {
    lock.lock()
    defer { lock.unlock() }
    _shared = RemoteDraw(configuration: configuration)
  }

  public let configuration: RemoteDrawConfiguration
  public let transport: any RemoteDrawSenderTransport

  public init(
    configuration: RemoteDrawConfiguration,
    transport: (any RemoteDrawSenderTransport)? = nil
  ) {
    self.configuration = configuration
    self.transport =
      transport
      ?? RemoteDrawSenderHTTPTransport(
        baseURL: configuration.apiBaseURL, urlSession: configuration.urlSession,
        onClientAdvisory: configuration.onClientAdvisory)
  }

  /// Enters a session from a raw `rd_join_…` or `rd_send_…` string.
  @MainActor
  public func join(
    rawToken: String,
    device: RemoteDrawSenderDevice? = nil
  ) async throws -> RemoteDrawSenderSession {
    try await RemoteDrawSenderSession.join(
      rawToken: rawToken,
      transport: transport,
      device: device ?? configuration.device ?? .describingThisDevice(),
      tokenProvider: configuration.tokenProvider
    )
  }

  @MainActor
  public func join(
    token: RemoteDrawToken,
    device: RemoteDrawSenderDevice? = nil
  ) async throws -> RemoteDrawSenderSession {
    try await RemoteDrawSenderSession.join(
      token: token,
      transport: transport,
      device: device ?? configuration.device ?? .describingThisDevice(),
      tokenProvider: configuration.tokenProvider
    )
  }

  /// Forgets the configuration. Tests only; a shipping app configures once.
  public static func reset() {
    lock.lock()
    defer { lock.unlock() }
    _shared = nil
  }
}

/// Everything the headless core can be told.
///
/// Every field has a default that works: `RemoteDrawConfiguration()` alone is
/// valid and talks to production.
public struct RemoteDrawConfiguration: @unchecked Sendable {
  public let apiBaseURL: RemoteDrawAPIBaseURL
  /// What the board is told about this phone.
  ///
  /// `nil` means the SDK describes the device itself
  /// (``RemoteDrawSenderDevice/current(bundle:)``), which is what the
  /// first-party app sends and what makes a board show "Ada's iPhone" rather
  /// than "a phone". Pass
  /// ``RemoteDrawSenderDevice/anonymous(aspectRatio:screen:)`` to send the
  /// geometry the receiver needs and no identifier at all — a supported
  /// configuration, and the reason this SDK's privacy manifest declares
  /// `NSPrivacyCollectedDataTypeDeviceID` as an opt-out rather than a condition
  /// of use.
  public let device: RemoteDrawSenderDevice?
  /// Where a replacement sender token comes from when the current one dies.
  ///
  /// Optional, and worth understanding before you skip it: a sender token's
  /// expiry is pinned to the session's expiry **at join time** and never
  /// patched, while the session's own expiry slides forward while someone
  /// draws. A surface a host keeps mounted for a long board will outlive its
  /// credential. `POST /v1/sender/refresh` fixes that server-side; until it
  /// ships this closure is the only recovery, and without either the session
  /// ends as ``RemoteDrawSessionEnd/tokenLost``.
  public let tokenProvider: (@Sendable () async throws -> String)?
  /// Injectable for tests and for a host with its own URLSession policy.
  public let urlSession: URLSession?
  /// Called when the API reports that this SDK build is being retired.
  ///
  /// The diagnostics channel for ``RemoteDrawClientAdvisory``, and the reason a
  /// `warn` is worth sending at all: a warning nobody can observe is the same
  /// as no warning. Called at most once per distinct advisory, on whatever
  /// thread the response arrived on, so a handler that touches UI must hop to
  /// the main actor itself.
  ///
  /// Optional — a `blocked` advisory still surfaces as
  /// ``RemoteDrawError/sdkTooOld(minimum:message:)`` from the call that hit it,
  /// and both levels are written to the unified log regardless.
  public let onClientAdvisory: (@Sendable (RemoteDrawClientAdvisory) -> Void)?

  public init(
    apiBaseURL: RemoteDrawAPIBaseURL = .production,
    device: RemoteDrawSenderDevice? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil,
    urlSession: URLSession? = nil,
    onClientAdvisory: (@Sendable (RemoteDrawClientAdvisory) -> Void)? = nil
  ) {
    self.apiBaseURL = apiBaseURL
    self.device = device
    self.tokenProvider = tokenProvider
    self.urlSession = urlSession
    self.onClientAdvisory = onClientAdvisory
  }
}
