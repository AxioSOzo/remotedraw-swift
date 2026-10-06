import Foundation
import XCTest

@testable import RemoteDrawSenderKit

/// Incremental `/v1/sender/drawings` (`since`), driven by the delta fixtures
/// the TypeScript reader and RemoteDrawKit run too.
///
/// `Fixtures/drawingChanges.json` is a verbatim copy of
/// `packages/protocol/tests/fixtures/drawingChanges.json`: this package is
/// exported on its own, so it cannot read the original by path.
/// `packages/protocol/tests/drawingChanges.test.ts` fails if the two drift.
/// Re-copy it when the shared scenarios change:
///
/// ```sh
/// cp packages/protocol/tests/fixtures/drawingChanges.json \
///    apps/ios/RemoteDrawSenderKit/Tests/RemoteDrawSenderKitTests/Fixtures/
/// ```
final class DrawingChangesTests: XCTestCase {
  private struct Fixture: Decodable {
    struct Step: Decodable {
      let answers: [AnyJSON]
      let sent: [String]
      /// The `pageToken` of each request (nil: none), where the scenario pages.
      let pageTokens: [String?]?
      let ids: [String]
    }
    struct Scenario: Decodable {
      let name: String
      let steps: [Step]
    }
    let scenarios: [Scenario]
  }

  /// Keeps an answer's raw JSON so the stub serves exactly the fixture bytes.
  private struct AnyJSON: Decodable {
    let data: Data
    init(from decoder: Decoder) throws {
      let value = try decoder.singleValueContainer().decode(JSONValue.self)
      data = try JSONEncoder().encode(value)
    }
  }

  private enum JSONValue: Codable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double)
    case bool(Bool), null
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if c.decodeNil() { self = .null }
      else if let v = try? c.decode(Bool.self) { self = .bool(v) }
      else if let v = try? c.decode(Double.self) { self = .number(v) }
      else if let v = try? c.decode(String.self) { self = .string(v) }
      else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
      else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      switch self {
      case .object(let v): try c.encode(v)
      case .array(let v): try c.encode(v)
      case .string(let v): try c.encode(v)
      case .number(let v): try c.encode(v)
      case .bool(let v): try c.encode(v)
      case .null: try c.encodeNil()
      }
    }
  }

  private func fixture() throws -> Fixture {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "drawingChanges", withExtension: "json"),
      "drawingChanges.json is not in the test bundle")
    return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
  }

  override func setUp() {
    super.setUp()
    QueueStubURLProtocol.reset()
  }

  override func tearDown() {
    QueueStubURLProtocol.reset()
    super.tearDown()
  }

  private func makeTransport() -> RemoteDrawSenderHTTPTransport {
    RemoteDrawSenderHTTPTransport(
      baseURL: .custom(URL(string: "https://api.example.test")!),
      urlSession: QueueStubURLProtocol.makeSession())
  }

  private func enqueue(_ bodies: String..., status: Int = 200) {
    QueueStubURLProtocol.enqueue(bodies.map { Data($0.utf8) }, status: status)
  }

  private func stroke(_ id: String, createdAt: Double, extra: String = "") -> String {
    #"{"id":"\#(id)","type":"freehand","createdAt":\#(createdAt),"points":[{"x":0.1,"y":0.2}]\#(extra)}"#
  }

  private var boardAnswer: String {
    #"{"items":[\#(stroke("a", createdAt: 1))],"removedIds":[],"cursor":"1:0:0","reset":true,"activeCount":1}"#
  }

  // MARK: - The shared fixtures

  func testTheSharedFixturesApplyExactlyAsTheTypeScriptReaderDoes() async throws {
    let scenarios = try fixture().scenarios
    XCTAssertGreaterThanOrEqual(scenarios.count, 5)
    for scenario in scenarios {
      QueueStubURLProtocol.reset()
      let transport = makeTransport()
      for (index, step) in scenario.steps.enumerated() {
        let label = "\(scenario.name) step \(index)"
        QueueStubURLProtocol.enqueue(step.answers.map(\.data))
        let response = try await transport.drawings(senderToken: "rd_send_1")
        XCTAssertEqual(response.items.map(\.id), step.ids, label)
        // The host payload lists the same elements, in the same order.
        struct Ids: Decodable { struct Item: Decodable { let id: String }; let items: [Item] }
        XCTAssertEqual(
          try XCTUnwrap(response.payload).decode(Ids.self).items.map(\.id), step.ids, label)
        XCTAssertEqual(QueueStubURLProtocol.takeSent(), step.sent, label)
        let tokens = QueueStubURLProtocol.takePageTokens()
        XCTAssertEqual(tokens, step.pageTokens ?? Array(repeating: nil, count: tokens.count), label)
        XCTAssertEqual(QueueStubURLProtocol.pending, 0, label)
      }
    }
  }

  // MARK: - The request

  func testTheFirstRequestAsksForPackedWithAnEmptyCursor() async throws {
    enqueue(#"{"items":[]}"#)
    _ = try await makeTransport().drawings(senderToken: "rd_send_1")
    let body = try XCTUnwrap(QueueStubURLProtocol.lastBody)
    XCTAssertEqual(body["senderToken"] as? String, "rd_send_1")
    XCTAssertEqual(body["encoding"] as? String, "packed")
    XCTAssertEqual(body["since"] as? String, "")
    XCTAssertEqual(body["pageSize"] as? Int, 1000)
    XCTAssertNil(body["pageToken"])
  }

  func testAFailurePartWayThroughThePagesKeepsTheBoardAndStartsOver() async throws {
    let transport = makeTransport()
    let session = #""session":{"id":"s","status":"active"}"#
    let page1 = #"{"#+session+#","items":[{"id":"a","type":"freehand","createdAt":1,"points":[]}],"removedIds":[],"cursor":"4:1:0","reset":true,"activeCount":1,"nextPageToken":"p1.1"}"#
    let page2 = #"{"#+session+#","items":[{"id":"b","type":"freehand","createdAt":2,"points":[]}],"removedIds":[],"cursor":"4:1:0","reset":false,"activeCount":1}"#
    let closing = #"{"#+session+#","items":[],"removedIds":[],"cursor":"4:1:0","reset":false,"activeCount":2}"#
    enqueue(boardAnswer, page1)
    enqueue(#"{"error":{"code":"unavailable"}}"#, status: 503)
    enqueue(page1, page2, closing)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    do {
      _ = try await transport.drawings(senderToken: "rd_send_1")
      XCTFail("the unavailable page should throw")
    } catch {}
    let response = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(response.items.map(\.id), ["a", "b"])
    struct Ids: Decodable { struct Item: Decodable { let id: String }; let items: [Item] }
    XCTAssertEqual(try XCTUnwrap(response.payload).decode(Ids.self).items.map(\.id), ["a", "b"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "1:0:0", "4:1:0", "1:0:0", "4:1:0", "4:1:0"])
    XCTAssertEqual(QueueStubURLProtocol.takePageTokens(), [nil, nil, "p1.1", nil, "p1.1", nil])
  }

  func testCopiesOfTheTransportShareTheCursor() async throws {
    let transport = makeTransport()
    let copy = transport
    enqueue(boardAnswer, #"{"items":[],"removedIds":[],"cursor":"1:0:0","reset":false,"activeCount":1}"#)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    let response = try await copy.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(response.items.map(\.id), ["a"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "1:0:0"])
  }

  func testAnotherSenderTokenStartsOver() async throws {
    let transport = makeTransport()
    enqueue(boardAnswer, boardAnswer)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    _ = try await transport.drawings(senderToken: "rd_send_2")
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", ""])
  }

  // MARK: - What the app receives

  /// `drawingSnapshot` feeds the app's own snapshot type from `payload`, which
  /// must stay the whole board however little the answer carried.
  func testADeltaAnswerStillPublishesTheWholeBoardAndAPlainPayload() async throws {
    struct HostDrawing: Decodable {
      let id: String
      let points: [RemoteDrawNormalizedPoint]
      let locked: Bool?
    }
    struct HostSnapshot: Decodable {
      let session: RemoteDrawSession?
      let items: [HostDrawing]
    }
    struct DeltaFields: Decodable {
      let encoding: String?
      let removedIds: [String]?
      let cursor: String?
      let reset: Bool?
      let activeCount: Int?
    }
    let packed = PointCodec.pack([
      RemoteDrawNormalizedPoint(x: 0.25, y: 0.5), RemoteDrawNormalizedPoint(x: 0.75, y: 0.125),
    ])
    let session = #"{"id":"session_1","geometryRevision":1,"capabilities":["draw","viewExisting"]}"#
    enqueue(
      #"{"session":\#(session),"encoding":"packed","items":[\#(stroke("a", createdAt: 1, extra: #","locked":true"#)),\#(stroke("b", createdAt: 2))],"removedIds":[],"cursor":"2:0:0","reset":true,"activeCount":2}"#,
      #"{"session":\#(session),"encoding":"packed","items":[{"id":"c","type":"freehand","createdAt":3,"zIndex":-1,"packedPoints":"\#(packed)"}],"removedIds":["b"],"cursor":"3:0:0","reset":false,"activeCount":2}"#
    )
    let transport = makeTransport()
    _ = try await transport.drawings(senderToken: "rd_send_1")
    let response = try await transport.drawings(senderToken: "rd_send_1")

    XCTAssertEqual(response.session?.id, "session_1")
    XCTAssertEqual(response.items.map(\.id), ["c", "a"])
    XCTAssertEqual(response.items[0].points, try PointCodec.unpack(packed))

    let payload = try XCTUnwrap(response.payload)
    let host = try payload.decode(HostSnapshot.self)
    XCTAssertEqual(host.session?.id, "session_1")
    XCTAssertEqual(host.items.map(\.id), ["c", "a"])
    XCTAssertEqual(host.items[0].points, try PointCodec.unpack(packed))
    XCTAssertEqual(host.items[1].locked, true)
    let fields = try payload.decode(DeltaFields.self)
    XCTAssertNil(fields.encoding)
    XCTAssertNil(fields.removedIds)
    XCTAssertNil(fields.cursor)
    XCTAssertNil(fields.reset)
    XCTAssertNil(fields.activeCount)
  }

  func testAnOlderServersAnswerIsReturnedExactlyAsItWasServed() async throws {
    let json = #"{"items":[\#(stroke("b", createdAt: 2)),\#(stroke("a", createdAt: 1))]}"#
    enqueue(json, json)
    let transport = makeTransport()
    let first = try await transport.drawings(senderToken: "rd_send_1")
    let second = try await transport.drawings(senderToken: "rd_send_1")
    let decoded = try JSONDecoder().decode(RemoteDrawDrawingsResponse.self, from: Data(json.utf8))
    XCTAssertEqual(first, decoded)
    XCTAssertEqual(second, decoded)
    XCTAssertEqual(second.items.map(\.id), ["b", "a"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", ""])
  }

  /// The server answers every read of a session with annotation input as a
  /// reset (the phone's view is filtered by placement), cursor or not.
  func testAnAnnotationSessionsResetsReplaceTheBoardEveryTime() async throws {
    let session =
      #"{"id":"session_1","geometryRevision":1,"capabilities":["draw"],"annotationInput":{"revision":1,"paused":false}}"#
    enqueue(
      #"{"session":\#(session),"items":[\#(stroke("a", createdAt: 1)),\#(stroke("b", createdAt: 2))],"removedIds":[],"cursor":"2:0:1","reset":true,"activeCount":2}"#,
      #"{"session":\#(session),"items":[\#(stroke("b", createdAt: 2))],"removedIds":[],"cursor":"3:0:1","reset":true,"activeCount":1}"#
    )
    let transport = makeTransport()
    let first = try await transport.drawings(senderToken: "rd_send_1")
    let second = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(first.items.map(\.id), ["a", "b"])
    XCTAssertNotNil(first.session?.annotationInput)
    XCTAssertEqual(second.items.map(\.id), ["b"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "2:0:1"])
  }

  /// A server whose count has drifted: the second mismatch in a row is shown
  /// and its cursor kept (`applyDrawingChanges`), so the next read is a delta
  /// again rather than a whole board every time.
  func testTwoMismatchesInARowShowTheLastAnswerAndKeepItsCursor() async throws {
    let wrong = #"{"items":[\#(stroke("b", createdAt: 2)),\#(stroke("a", createdAt: 1))],"removedIds":[],"cursor":"2:0:0","reset":true,"activeCount":5}"#
    enqueue(wrong, wrong, boardAnswer)
    let transport = makeTransport()
    let response = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(response.items.map(\.id), ["a", "b"])
    _ = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "", "2:0:0"])
  }

  // MARK: - Failures

  func testARefusedDeltaReadDropsTheCursor() async throws {
    let transport = makeTransport()
    enqueue(boardAnswer)
    enqueue(
      #"{"error":{"code":"invalid_request","message":"Database snapshot exceeds its admitted size."}}"#,
      status: 400)
    enqueue(#"{"items":[],"removedIds":[],"cursor":"9:0:0","reset":true,"activeCount":0}"#)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    do {
      _ = try await transport.drawings(senderToken: "rd_send_1")
      XCTFail("the refused read should throw")
    } catch let error as RemoteDrawError {
      XCTAssertTrue(error.refusesDrawingsRequest)
    }
    let response = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(response.items.map(\.id), [])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "1:0:0", ""])
  }

  func testTransientFailuresKeepTheCursorButNotForever() async throws {
    let transport = makeTransport()
    let attempts = RemoteDrawDrawingChangesState.cursorAttempts
    enqueue(boardAnswer)
    QueueStubURLProtocol.enqueue(
      Array(repeating: Data(#"{"error":{"code":"unavailable","message":"Try again."}}"#.utf8), count: attempts),
      status: 503)
    enqueue(boardAnswer)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    for _ in 0..<attempts {
      do {
        _ = try await transport.drawings(senderToken: "rd_send_1")
        XCTFail("the unavailable read should throw")
      } catch let error as RemoteDrawError {
        XCTAssertFalse(error.refusesDrawingsRequest)
      }
    }
    _ = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(
      QueueStubURLProtocol.takeSent(),
      [""] + Array(repeating: "1:0:0", count: attempts) + [""])
  }

  func testARateLimitedReadKeepsTheCursorAndASuccessResetsTheCount() async throws {
    let transport = makeTransport()
    let unchanged = #"{"items":[],"removedIds":[],"cursor":"1:0:0","reset":false,"activeCount":1}"#
    enqueue(boardAnswer)
    enqueue(#"{"error":{"code":"rate_limited"},"retryAfter":1}"#, #"{"error":{"code":"rate_limited"}}"#, status: 429)
    enqueue(unchanged)
    enqueue(#"{"error":{"code":"unavailable"}}"#, #"{"error":{"code":"unavailable"}}"#, status: 503)
    enqueue(unchanged)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    for _ in 0..<2 { _ = try? await transport.drawings(senderToken: "rd_send_1") }
    let held = try await transport.drawings(senderToken: "rd_send_1")
    for _ in 0..<2 { _ = try? await transport.drawings(senderToken: "rd_send_1") }
    // Four failures from one cursor, but never three in a row.
    let still = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(held.items.map(\.id), ["a"])
    XCTAssertEqual(still.items.map(\.id), ["a"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), [""] + Array(repeating: "1:0:0", count: 6))
  }

  func testACapacityRefusalKeepsTheCursor() async throws {
    // About the account, not the cursor: a full read would be refused too.
    let transport = makeTransport()
    let unchanged = #"{"items":[],"removedIds":[],"cursor":"1:0:0","reset":false,"activeCount":1}"#
    enqueue(boardAnswer)
    enqueue(
      #"{"error":{"code":"included_capacity_exhausted","message":"Included capacity is used up."}}"#,
      status: 409)
    enqueue(unchanged)
    _ = try await transport.drawings(senderToken: "rd_send_1")
    do {
      _ = try await transport.drawings(senderToken: "rd_send_1")
      XCTFail("the refused read should throw")
    } catch let error as RemoteDrawError {
      XCTAssertFalse(error.refusesDrawingsRequest)
    }
    let response = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(response.items.map(\.id), ["a"])
    XCTAssertEqual(QueueStubURLProtocol.takeSent(), ["", "1:0:0", "1:0:0"])
  }

  func testOnlyAMalformedRequestOrAGoneTokenOrSessionDropsTheCursor() {
    func server(_ status: Int, _ code: String? = nil) -> RemoteDrawError {
      .server(status: status, code: code, message: nil)
    }
    // Dropped: the request was malformed, or its credentials or board are gone.
    XCTAssertTrue(server(400).refusesDrawingsRequest)
    XCTAssertTrue(server(400, "invalid_request").refusesDrawingsRequest)
    XCTAssertTrue(server(500, "invalid_request").refusesDrawingsRequest)
    XCTAssertTrue(server(404).refusesDrawingsRequest)
    XCTAssertTrue(server(404, "session_not_found").refusesDrawingsRequest)
    XCTAssertTrue(RemoteDrawError.tokenRejected.refusesDrawingsRequest)
    XCTAssertTrue(RemoteDrawError.sessionEnded.refusesDrawingsRequest)
    XCTAssertTrue(RemoteDrawError.sessionExpired.refusesDrawingsRequest)
    // Kept: capacity, billing and grants, timeouts, rate limits, the network.
    XCTAssertFalse(server(409, "included_capacity_exhausted").refusesDrawingsRequest)
    XCTAssertFalse(server(402, "billing_limit_reached").refusesDrawingsRequest)
    XCTAssertFalse(server(402).refusesDrawingsRequest)
    XCTAssertFalse(RemoteDrawError.notPermitted(.viewExisting).refusesDrawingsRequest)
    XCTAssertFalse(RemoteDrawError.sdkTooOld(minimum: "1.0.0", message: "Update.").refusesDrawingsRequest)
    XCTAssertFalse(server(408).refusesDrawingsRequest)
    XCTAssertFalse(server(425).refusesDrawingsRequest)
    XCTAssertFalse(server(503).refusesDrawingsRequest)
    XCTAssertFalse(RemoteDrawError.rateLimited(retryAfter: 1, bucket: nil).refusesDrawingsRequest)
    XCTAssertFalse(RemoteDrawError.offline.refusesDrawingsRequest)
    XCTAssertFalse(RemoteDrawError.transport("lost").refusesDrawingsRequest)
  }
}

/// Serves queued bodies (200 unless enqueued with another status) in order to
/// every request and records each `since`.
private final class QueueStubURLProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var queue: [(status: Int, body: Data)] = []
  nonisolated(unsafe) private static var sent: [String] = []
  nonisolated(unsafe) private static var pageTokens: [String?] = []
  nonisolated(unsafe) private static var body: [String: Any]?

  static func reset() {
    lock.lock()
    queue = []
    sent = []
    pageTokens = []
    body = nil
    lock.unlock()
  }

  static func takePageTokens() -> [String?] {
    lock.lock()
    defer {
      pageTokens = []
      lock.unlock()
    }
    return pageTokens
  }

  static func enqueue(_ bodies: [Data], status: Int = 200) {
    lock.lock()
    queue.append(contentsOf: bodies.map { (status, $0) })
    lock.unlock()
  }

  static func takeSent() -> [String] {
    lock.lock()
    defer {
      sent = []
      lock.unlock()
    }
    return sent
  }

  static var pending: Int {
    lock.lock()
    defer { lock.unlock() }
    return queue.count
  }

  static var lastBody: [String: Any]? {
    lock.lock()
    defer { lock.unlock() }
    return body
  }

  static func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [QueueStubURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let raw = request.httpBody ?? Self.drain(request.httpBodyStream)
    let json = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    Self.lock.lock()
    Self.body = json
    if let since = json?["since"] as? String {
      Self.sent.append(since)
      Self.pageTokens.append(json?["pageToken"] as? String)
    }
    let next = Self.queue.isEmpty ? nil : Self.queue.removeFirst()
    Self.lock.unlock()

    let http = HTTPURLResponse(
      url: request.url ?? URL(string: "https://api.example.test")!,
      statusCode: next?.status ?? 500,
      httpVersion: "HTTP/1.1",
      headerFields: ["Content-Type": "application/json"])!
    client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: next?.body ?? Data("{}".utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}

  private static func drain(_ stream: InputStream?) -> Data? {
    guard let stream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while stream.hasBytesAvailable {
      let read = stream.read(&buffer, maxLength: buffer.count)
      guard read > 0 else { break }
      data.append(buffer, count: read)
    }
    return data
  }
}
