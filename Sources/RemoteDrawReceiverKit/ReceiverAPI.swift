import Foundation

public enum RemoteDrawReceiverRoute: String, CaseIterable, Sendable {
  case sync = "/v1/receiver/sync"
  case session = "/v1/receiver/session"
  case drawings = "/v1/receiver/drawings"
  case drafts = "/v1/receiver/drafts"
  case senders = "/v1/receiver/senders"
  case undo = "/v1/receiver/undo"
  case clear = "/v1/receiver/clear"
  case joinToken = "/v1/receiver/join-token"
  case surface = "/v1/receiver/surface"
  case end = "/v1/receiver/end"
}

/// A freshly minted pairing code.
public struct RemoteDrawJoinTokenResult: Codable, Equatable, Sendable {
  public let joinToken: String?
  public let joinUrl: String?
  /// Milliseconds since the epoch. Join tokens live ten minutes.
  public let expiresAt: Double?

  public var expiryDate: Date? {
    expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) }
  }

  /// A public struct still gets an *internal* memberwise initializer, so
  /// without this a host app cannot build one — which makes
  /// ``RemoteDrawReceiverControl`` impossible to fake in a test. The sender
  /// DTOs already carry public initializers for the same reason.
  public init(joinToken: String?, joinUrl: String?, expiresAt: Double?) {
    self.joinToken = joinToken
    self.joinUrl = joinUrl
    self.expiresAt = expiresAt
  }
}

/// The two receiver routes a *displaying* receiver needs beyond reading state:
/// re-arming its own pairing code, and telling the session how big its surface
/// currently is. Kept separate from ``RemoteDrawReceiverTransport`` so a test
/// fake for the polling loop does not have to implement them.
public protocol RemoteDrawReceiverControl: Sendable {
  func issueJoinToken(
    _ credentials: RemoteDrawReceiverCredentials,
    capabilities: [String]?
  ) async throws -> RemoteDrawJoinTokenResult

  func updateSurface(
    _ credentials: RemoteDrawReceiverCredentials,
    width: Int,
    height: Int
  ) async throws

  /// Ends the session on the server.
  ///
  /// Without this a client can only stop *listening*: the session stays active
  /// for its full TTL, still counting against the account's active-board
  /// allowance. On the free tier that is one board, so a user who finishes with
  /// one surface and starts another is refused for the next half hour.
  func endSession(_ credentials: RemoteDrawReceiverCredentials) async throws
}

public enum RemoteDrawReceiverError: Error, Equatable, Sendable {
  /// The session ended, expired, or the receiver token was revoked. Fail closed:
  /// a receiver that keeps polling a dead session just burns requests.
  case unauthorized
  case notFound
  case server(status: Int, message: String?)
  case transport(String)
  case decoding(String)

  public var isTerminal: Bool {
    switch self {
    case .unauthorized, .notFound: return true
    case .server(let status, _): return status == 410
    default: return false
    }
  }
}

/// What the polling store needs from the network. A protocol so tests can drive
/// the store with a fake and so a reactive implementation (ConvexMobile) can be
/// swapped in later without touching the store.
public struct RemoteDrawSyncRevisions: Codable, Equatable, Sendable {
  public let drawings: String
  public let drafts: String
  public let files: String
  public let metadata: String
}
public protocol RemoteDrawReceiverTransport: Sendable {
  func fetchRevisions(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawSyncRevisions?

  func fetchSession(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> RemoteDrawReceiverSession
  func fetchDrawings(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDrawing]
  func fetchDrafts(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDraft]
  func fetchSenders(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverSenderRecord]
  func undo(_ credentials: RemoteDrawReceiverCredentials) async throws
  func clear(_ credentials: RemoteDrawReceiverCredentials) async throws
}

public extension RemoteDrawReceiverTransport {
  func fetchRevisions(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawSyncRevisions? { nil }
}

/// The six documented receiver routes over HTTPS.
///
/// Deliberately the *only* thing in the app that knows a network exists. It
/// speaks to `api.remotedraw.com` and nothing else — no Convex client, no Clerk,
/// no API key — which keeps the client's trusted surface as small as the
/// protocol allows.
public struct RemoteDrawReceiverHTTPTransport: RemoteDrawReceiverTransport, RemoteDrawReceiverControl {
  public let baseURL: URL
  private let session: URLSession
  private let decoder: JSONDecoder

  public init(baseURL: URL, session: URLSession = .shared) {
    self.baseURL = baseURL
    self.session = session
    self.decoder = JSONDecoder()
  }

  private struct ItemsEnvelope<Item: Decodable>: Decodable {
    let items: [Item]
  }

  private struct ErrorEnvelope: Decodable {
    let error: String?
    let message: String?
  }

  public func fetchRevisions(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawSyncRevisions? {
    try await post(.sync, credentials, as: RemoteDrawSyncRevisions.self)
  }

  public func fetchSession(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> RemoteDrawReceiverSession
  {
    try await post(.session, credentials, as: RemoteDrawReceiverSession.self)
  }

  public func fetchDrawings(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDrawing]
  {
    try await post(.drawings, credentials, as: ItemsEnvelope<RemoteDrawReceiverDrawing>.self).items
  }

  public func fetchDrafts(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverDraft]
  {
    try await post(.drafts, credentials, as: ItemsEnvelope<RemoteDrawReceiverDraft>.self).items
  }

  public func fetchSenders(_ credentials: RemoteDrawReceiverCredentials) async throws
    -> [RemoteDrawReceiverSenderRecord]
  {
    try await post(.senders, credentials, as: ItemsEnvelope<RemoteDrawReceiverSenderRecord>.self)
      .items
  }

  public func undo(_ credentials: RemoteDrawReceiverCredentials) async throws {
    _ = try await postRaw(.undo, credentials)
  }

  public func clear(_ credentials: RemoteDrawReceiverCredentials) async throws {
    _ = try await postRaw(.clear, credentials)
  }

  public func issueJoinToken(
    _ credentials: RemoteDrawReceiverCredentials,
    capabilities: [String]? = nil
  ) async throws -> RemoteDrawJoinTokenResult {
    struct Body: Encodable {
      let sessionId: String
      let receiverToken: String
      let capabilities: [String]?
    }
    let data = try await postRaw(
      .joinToken,
      body: Body(
        sessionId: credentials.sessionId,
        receiverToken: credentials.receiverToken,
        capabilities: capabilities
      )
    )
    do {
      return try decoder.decode(RemoteDrawJoinTokenResult.self, from: data)
    } catch {
      throw RemoteDrawReceiverError.decoding("join-token: \(error)")
    }
  }

  public func updateSurface(
    _ credentials: RemoteDrawReceiverCredentials,
    width: Int,
    height: Int
  ) async throws {
    struct Body: Encodable {
      let sessionId: String
      let receiverToken: String
      let width: Int
      let height: Int
    }
    _ = try await postRaw(
      .surface,
      body: Body(
        sessionId: credentials.sessionId,
        receiverToken: credentials.receiverToken,
        width: width,
        height: height
      )
    )
  }

  public func endSession(_ credentials: RemoteDrawReceiverCredentials) async throws {
    do {
      _ = try await postRaw(.end, credentials)
    } catch RemoteDrawReceiverError.server(status: 410, message: _) {
      // Only an authenticated inactive-session response proves the session is
      // already gone. Invalid credentials or a wrong route must remain errors.
      return
    }
  }

  // MARK: Plumbing

  private func post<Response: Decodable>(
    _ route: RemoteDrawReceiverRoute,
    _ credentials: RemoteDrawReceiverCredentials,
    as type: Response.Type
  ) async throws -> Response {
    let data = try await postRaw(route, credentials)
    do {
      return try decoder.decode(Response.self, from: data)
    } catch {
      throw RemoteDrawReceiverError.decoding("\(route.rawValue): \(error)")
    }
  }

  private func postRaw(
    _ route: RemoteDrawReceiverRoute,
    _ credentials: RemoteDrawReceiverCredentials
  ) async throws -> Data {
    try await postRaw(route, body: credentials)
  }

  private func postRaw(
    _ route: RemoteDrawReceiverRoute,
    body: some Encodable
  ) async throws -> Data {
    var request = URLRequest(url: baseURL.appendingPathComponent(route.rawValue))
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.httpBody = try JSONEncoder().encode(body)
    // Shorter than the URLSession default of 60s on purpose: a receiver poll
    // that has not answered within a few seconds is already useless, and
    // holding the slot blocks the next poll.
    request.timeoutInterval = 12

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await session.data(for: request)
    } catch {
      throw RemoteDrawReceiverError.transport(error.localizedDescription)
    }

    guard let http = response as? HTTPURLResponse else {
      throw RemoteDrawReceiverError.transport("Non-HTTP response")
    }
    switch http.statusCode {
    case 200..<300:
      return data
    case 401, 403:
      throw RemoteDrawReceiverError.unauthorized
    case 404:
      throw RemoteDrawReceiverError.notFound
    default:
      let envelope = try? decoder.decode(ErrorEnvelope.self, from: data)
      throw RemoteDrawReceiverError.server(
        status: http.statusCode,
        message: envelope?.message ?? envelope?.error
      )
    }
  }
}

extension URL {
  /// `appendingPathComponent` percent-escapes the slashes in a multi-segment
  /// route, turning `/v1/receiver/session` into one component. Routes are
  /// literals from an enum, so joining the strings directly is both correct and
  /// the only thing that produces a working URL here.
  fileprivate func appendingPathComponent(_ route: String) -> URL {
    let base = absoluteString.hasSuffix("/") ? String(absoluteString.dropLast()) : absoluteString
    return URL(string: base + route) ?? self
  }
}
