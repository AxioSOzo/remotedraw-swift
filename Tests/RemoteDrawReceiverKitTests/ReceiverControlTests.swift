import XCTest

@testable import RemoteDrawReceiverKit

/// The receiver-side control routes, driven through a stubbed `URLProtocol`.
final class ReceiverControlTests: XCTestCase {
  private var transport: RemoteDrawReceiverHTTPTransport!

  private let credentials = RemoteDrawReceiverCredentials(
    sessionId: "sess_1", receiverToken: "rd_recv_abc")

  override func setUp() {
    super.setUp()
    ReceiverStubURLProtocol.reset()
    transport = RemoteDrawReceiverHTTPTransport(
      baseURL: URL(string: "https://api.remotedraw.com")!,
      session: ReceiverStubURLProtocol.makeSession()
    )
  }

  override func tearDown() {
    ReceiverStubURLProtocol.reset()
    transport = nil
    super.tearDown()
  }

  func testEndSessionPostsCredentialsToTheEndRoute() async throws {
    ReceiverStubURLProtocol.respond(to: "/v1/receiver/end", status: 200, json: #"{"ended":true}"#)

    try await transport.endSession(credentials)

    let request = try XCTUnwrap(ReceiverStubURLProtocol.lastRequest)
    XCTAssertEqual(request.path, "/v1/receiver/end")
    XCTAssertEqual(request.method, "POST")

    let body = try XCTUnwrap(request.jsonBody)
    XCTAssertEqual(body["sessionId"] as? String, "sess_1")
    XCTAssertEqual(body["receiverToken"] as? String, "rd_recv_abc")
    // Tokens travel in the body on every route in this API; a bearer header
    // here would be silently ignored by the server.
    XCTAssertNil(request.authorizationHeader)
  }

  /// Ending runs on teardown paths. A session that is already gone is the
  /// outcome the caller wanted, so it must not throw and make cleanup noisy.
  func testEndSessionTreatsAnAlreadyDeadSessionAsSuccess() async throws {
    ReceiverStubURLProtocol.respond(
      to: "/v1/receiver/end", status: 410,
      json: #"{"error":{"message":"Session receiver token is invalid."}}"#)

    try await transport.endSession(credentials)
  }

  func testEndDoesNotClaimSuccessForInvalidCredentials() async {
    ReceiverStubURLProtocol.respond(to: "/v1/receiver/end", status: 401, json: "{}")
    do {
      try await transport.endSession(credentials)
      XCTFail("Invalid credentials do not prove a session was ended")
    } catch {
      XCTAssertEqual(error as? RemoteDrawReceiverError, .unauthorized)
    }
  }

  func testInactiveSession410IsTerminalButServerFailureIsRecoverable() {
    XCTAssertTrue(RemoteDrawReceiverError.server(status: 410, message: nil).isTerminal)
    XCTAssertFalse(RemoteDrawReceiverError.server(status: 500, message: nil).isTerminal)
  }

  func testEndSessionStillReportsRealServerFailures() async {
    ReceiverStubURLProtocol.respond(
      to: "/v1/receiver/end", status: 500, json: #"{"error":{"message":"boom"}}"#)

    do {
      try await transport.endSession(credentials)
      XCTFail("expected a server error to propagate")
    } catch let error as RemoteDrawReceiverError {
      guard case .server(let status, _) = error else {
        return XCTFail("expected .server, got \(error)")
      }
      XCTAssertEqual(status, 500)
    } catch {
      XCTFail("unexpected error \(error)")
    }
  }

  func testRouteURLsJoinWithoutEscapingTheirSlashes() async throws {
    ReceiverStubURLProtocol.respond(to: "/v1/receiver/end", status: 200, json: "{}")

    try await transport.endSession(credentials)

    let request = try XCTUnwrap(ReceiverStubURLProtocol.lastRequest)
    XCTAssertEqual(
      request.url?.absoluteString, "https://api.remotedraw.com/v1/receiver/end")
  }

  /// The board's name rides along on `target`. It was on the wire long before
  /// anything decoded it, so this guards the field rather than the transport.
  func testSessionDecodesTheTargetLabel() throws {
    let json = #"""
      {"id":"sess_1","status":"active",
       "target":{"kind":"whiteboard","label":"Sprint planning",
                 "coordinateSpace":{"width":1000,"height":1000}}}
      """#
    let session = try JSONDecoder().decode(
      RemoteDrawReceiverSession.self, from: Data(json.utf8))

    XCTAssertEqual(session.target?.label, "Sprint planning")
    XCTAssertEqual(session.target?.kind, "whiteboard")
  }

  func testSessionWithoutATargetLabelStillDecodes() throws {
    let json = #"{"id":"sess_1","status":"active","target":{"kind":"paper"}}"#
    let session = try JSONDecoder().decode(
      RemoteDrawReceiverSession.self, from: Data(json.utf8))

    XCTAssertNil(session.target?.label)
    XCTAssertEqual(session.target?.kind, "paper")
  }
}

/// A tiny hermetic stub. Deliberately separate from the sender tests' stub,
/// which is file-private there — copying the scaffolding is cheaper than
/// sharing mutable static state between two test classes.
private final class ReceiverStubURLProtocol: URLProtocol {
  struct Recorded {
    let url: URL?
    let method: String?
    let path: String?
    let body: Data?
    let authorizationHeader: String?

    var jsonBody: [String: Any]? {
      guard let body else { return nil }
      return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
  }

  private struct Response {
    let status: Int
    let json: String
  }

  private static let lock = NSLock()
  private static var responses: [String: Response] = [:]
  private static var recorded: Recorded?

  static var lastRequest: Recorded? {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  static func reset() {
    lock.lock()
    responses = [:]
    recorded = nil
    lock.unlock()
  }

  static func respond(to path: String, status: Int, json: String) {
    lock.lock()
    responses[path] = Response(status: status, json: json)
    lock.unlock()
  }

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ReceiverStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // `URLSession` moves the body onto `httpBodyStream` before a protocol sees
    // it, so reading `httpBody` alone would "prove" the token was never sent.
    let body = request.httpBody ?? Self.drain(request.httpBodyStream)
    let path = request.url?.path
    Self.lock.lock()
    Self.recorded = Recorded(
      url: request.url,
      method: request.httpMethod,
      path: path,
      body: body,
      authorizationHeader: request.value(forHTTPHeaderField: "Authorization")
    )
    let response = path.flatMap { Self.responses[$0] }
    Self.lock.unlock()

    let stub = response ?? Response(status: 404, json: "{}")
    let http = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.remotedraw.com")!,
      statusCode: stub.status,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"]
    )!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(stub.json.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func drain(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let size = 4096
    var buffer = [UInt8](repeating: 0, count: size)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: size)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
