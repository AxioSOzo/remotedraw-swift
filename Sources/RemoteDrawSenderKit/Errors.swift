import Foundation

/// Everything that can go wrong, with the fix in the message.
///
/// The reader is often an agent that will act on `recoverySuggestion`
/// verbatim, so every case names the action rather than describing the state.
public enum RemoteDrawError: LocalizedError, Equatable {
  /// `RemoteDraw.configure(_:)` has not been called.
  case notConfigured
  /// A capability that needs a system permission is enabled and the host's
  /// `Info.plist` does not declare it.
  case missingInfoPlistKey(String, requiredBy: String)
  /// The string handed in is neither `rd_join_…` nor `rd_send_…`.
  case malformedToken
  /// The session ran out of time. Nothing to re-join.
  case sessionExpired
  /// The board finished. Nothing to re-join.
  case sessionEnded
  /// 401 / `invalid_sender_token` / `sender_token_expired`. Re-join.
  case tokenRejected
  /// 403. The credential was fine and the grant was not.
  case notPermitted(RemoteDrawCapability)
  /// 429, with the wait the server asked for.
  ///
  /// **Read `bucket` before you retry.** `auth_failures_per_ip` answers 429 in
  /// place of 401 once an IP has burned its budget, so a blind back-off there
  /// is waiting out a wrong token.
  case rateLimited(retryAfter: TimeInterval, bucket: String?)
  /// The request never reached the API.
  case offline
  /// The server told this SDK version to stop.
  case sdkTooOld(minimum: String, message: String)
  /// Anything the server refused with an explanation of its own.
  case server(status: Int, code: String?, message: String?)
  /// URLSession, JSON, or anything else below the protocol.
  case transport(String)
  /// A response this build could not read.
  case decoding(String)

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "RemoteDraw is not configured."
    case .missingInfoPlistKey(let key, let requiredBy):
      return "\(key) is missing from Info.plist, and \(requiredBy) needs it."
    case .malformedToken:
      return "That is not a RemoteDraw token."
    case .sessionExpired:
      return "This RemoteDraw session has expired."
    case .sessionEnded:
      return "This RemoteDraw session has finished."
    case .tokenRejected:
      return "The sender token is no longer valid."
    case .notPermitted(let capability):
      return "This session was created without the '\(capability.rawValue)' capability."
    case .rateLimited(let retryAfter, let bucket):
      let where_ = bucket.map { " (\($0))" } ?? ""
      return "RemoteDraw is rate limiting this client\(where_); retry in \(Int(retryAfter.rounded()))s."
    case .offline:
      return "RemoteDraw is unreachable."
    case .sdkTooOld(let minimum, let message):
      return "\(message) (RemoteDrawSenderKit \(minimum) or newer is required.)"
    case .server(let status, let code, let message):
      return message ?? "RemoteDraw returned HTTP \(status)\(code.map { " (\($0))" } ?? "")."
    case .transport(let message):
      return message
    case .decoding(let detail):
      return "RemoteDraw returned a response this SDK could not read: \(detail)"
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .notConfigured:
      return "Call RemoteDraw.configure(.init(apiBaseURL: .production)) from your App's init."
    case .missingInfoPlistKey(let key, let requiredBy):
      return "Add \(key) to your app's Info.plist, or remove \(requiredBy) from RemoteDrawConfiguration."
    case .malformedToken:
      return
        "A join token starts with rd_join_ and a sender token with rd_send_. Pass the whole string, not a URL."
    case .sessionExpired, .sessionEnded:
      return
        "Create a new session on your server, then hand this app a fresh token. Do not retry with the old one — it will fail the same way every time."
    case .tokenRejected:
      return
        "Ask your backend for a new token from POST /v1/sessions/direct-sender. Do not call that endpoint from the app — it requires your API key."
    case .notPermitted(let capability):
      return
        "Add '\(capability.rawValue)' to the capabilities when you create the session on your server, or hide the control that calls it."
    case .rateLimited:
      return
        "Wait the interval, then retry once. If the bucket is auth_failures_per_ip the token is wrong, not the pace — fix the token instead."
    case .offline:
      return "Check the device's connection. The SDK retries idempotent requests three times on its own before reporting this."
    case .sdkTooOld:
      return "Update the RemoteDrawSenderKit dependency and ship a new build."
    case .server, .transport, .decoding:
      return nil
    }
  }

  /// The question every sender integration has to answer: *should I throw away
  /// this token and join again?*
  ///
  /// The Swift half of the contract in `packages/client/src/httpClient.ts`,
  /// which had none until now. Answered from `code` where the server sent one
  /// and from `status` where it did not, so it keeps working against a
  /// deployment older than the codes.
  ///
  /// Deliberately **false** for a finished session and for a spent join token:
  /// both are also authentication-adjacent refusals, and re-joining either
  /// loops forever. Deliberately false for every 403 — the credential was fine
  /// and the grant was not, so another join reproduces it exactly.
  ///
  /// And note what re-joining costs, which is the reason this must not be
  /// over-eager: `/v1/join` revokes every other active sender token on the
  /// session, so an SDK that "reconnects" by re-joining silently kicks off any
  /// other device on the same board.
  public var shouldReJoin: Bool {
    switch self {
    case .tokenRejected:
      return true
    case .server(let status, let code, _):
      if let code {
        return Self.rejoinableCodes.contains(code)
      }
      return status == 401
    default:
      return false
    }
  }

  static let rejoinableCodes: Set<String> = [
    "invalid_sender_token",
    "sender_token_expired",
    "invalid_receiver_token",
  ]

  /// Whether another attempt could plausibly succeed.
  ///
  /// Network faults and server-side transients are worth another try; anything
  /// the server deliberately refused is not. Every 4xx below 408 stays
  /// non-retriable, which is the point: a 401 returns the same 401 on every
  /// attempt, and a caller that mistook it for a transient would burn its
  /// budget instead of re-joining.
  public var isRetriable: Bool {
    switch self {
    case .offline, .transport:
      return true
    case .rateLimited:
      return true
    case .server(let status, _, _):
      return status == 408 || status == 429 || status >= 500
    default:
      return false
    }
  }
}

/// Retries a request the server deduplicates.
///
/// `commitStroke` is keyed by `clientStrokeId` and answers a replay with
/// `duplicate: true`; `submit` is keyed by `clientSubmissionId`. So a stroke
/// lost to a flaky mobile radio can be resent rather than silently vanishing
/// from a board the sender has already erased it from.
///
/// Three attempts, linear 120 ms — the same shape as `retryIdempotentRequest`
/// in `packages/client/src/strokeTransport.ts`. Only transport-level failures
/// and server transients retry; a rejection the server reasoned about comes
/// straight back.
public func retryIdempotentRequest<T>(
  attempts: Int = 3,
  delay: TimeInterval = 0.12,
  sleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
  _ run: () async throws -> T
) async throws -> T {
  let total = max(1, attempts)
  var lastError: Error?
  for attempt in 1...total {
    do {
      return try await run()
    } catch {
      lastError = error
      let retriable = (error as? RemoteDrawError)?.isRetriable ?? false
      if attempt >= total || !retriable { throw error }
      try await sleep(delay * Double(attempt))
    }
  }
  throw lastError ?? RemoteDrawError.transport("Request failed with no error.")
}
