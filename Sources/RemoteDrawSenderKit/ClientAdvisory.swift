import Foundation
import os

/// What the API says about the SDK build that made the request.
///
/// Every request identifies itself with `X-RemoteDraw-SDK: swift/<version>`,
/// and the deployment answers with one optional field when that build is on its
/// way out. `convex/lib/clientAdvisory.ts` is the other half, including the two
/// environment variables an operator sets to move the line.
///
/// Two levels, and the difference is the whole point:
///
/// - ``Level/blocked`` is refused. The request did not happen — the API answers
///   426 before touching anything — and the SDK raises
///   ``RemoteDrawError/sdkTooOld(minimum:message:)``.
/// - ``Level/warn`` changes nothing about the request, which succeeds normally.
///   It is the notice that a future release will be refused, delivered while
///   there is still time to ship an update.
///
/// A warning used to be decoded and dropped on the floor, which made it
/// indistinguishable from no warning at all: the one signal designed to reach
/// an integrator before their app breaks reached nobody. It now goes to
/// ``RemoteDrawConfiguration/onClientAdvisory`` when a host wired one up, and to
/// the unified log either way.
public struct RemoteDrawClientAdvisory: Sendable, Equatable {
  public enum Level: String, Sendable {
    case warn
    case blocked
  }

  public let level: Level
  /// The oldest version this deployment accepts, or advises upgrading to.
  public let minimum: String
  /// A complete sentence, safe to show a developer. Not end-user copy.
  public let message: String
  /// The version this build reported, echoed back.
  public let current: String

  public init(level: Level, minimum: String, message: String, current: String) {
    self.level = level
    self.minimum = minimum
    self.message = message
    self.current = current
  }
}

/// Delivers an advisory once, however many requests carry it.
///
/// A `warn` rides on *every* response while the policy is in force, and a
/// drawing sender makes one request every 32 ms. Logging or calling back at
/// that rate would bury the message it exists to deliver, so this reports only
/// when the advisory changes — which for a stable policy means exactly once per
/// process.
final class RemoteDrawAdvisoryReporter: @unchecked Sendable {
  private let logger = Logger(subsystem: "com.remotedraw.senderkit", category: "advisory")
  private let handler: (@Sendable (RemoteDrawClientAdvisory) -> Void)?
  private let lock = NSLock()
  private var reported: RemoteDrawClientAdvisory?

  init(handler: (@Sendable (RemoteDrawClientAdvisory) -> Void)? = nil) {
    self.handler = handler
  }

  func report(_ advisory: RemoteDrawClientAdvisory) {
    lock.lock()
    let isNew = reported != advisory
    if isNew { reported = advisory }
    lock.unlock()
    guard isNew else { return }
    switch advisory.level {
    case .warn:
      logger.warning(
        """
        RemoteDrawSenderKit \(advisory.current, privacy: .public) is being retired: \
        \(advisory.message, privacy: .public) Update the dependency to \
        \(advisory.minimum, privacy: .public) or newer.
        """)
    case .blocked:
      logger.error(
        """
        RemoteDrawSenderKit \(advisory.current, privacy: .public) is refused by this API: \
        \(advisory.message, privacy: .public) Requests will keep failing until the \
        dependency is updated to \(advisory.minimum, privacy: .public) or newer.
        """)
    }
    handler?(advisory)
  }
}
