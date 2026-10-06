import XCTest

@testable import RemoteDrawSenderKit

/// A `URLProtocol` that answers every request from a script and records what it
/// was asked. Hermetic: no socket is opened.
final class StubURLProtocol: URLProtocol {
  struct Exchange {
    var status: Int = 200
    var body: String = "{}"
    var headers: [String: String] = [:]
  }

  nonisolated(unsafe) static var nextExchange = Exchange()
  nonisolated(unsafe) static private(set) var requests: [(URLRequest, Data)] = []

  static func reset(_ exchange: Exchange = Exchange()) {
    nextExchange = exchange
    requests = []
  }

  static var lastRequest: (URLRequest, Data)? { requests.last }

  static func lastBody() throws -> [String: Any] {
    guard let (_, data) = lastRequest,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw CocoaError(.coderInvalidValue) }
    return object
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    // `URLProtocol` strips the body into a stream, so read it back out.
    var body = Data()
    if let stream = request.httpBodyStream {
      stream.open()
      let size = 64 * 1024
      let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
      defer { buffer.deallocate() }
      while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: size)
        if read <= 0 { break }
        body.append(buffer, count: read)
      }
      stream.close()
    } else if let httpBody = request.httpBody {
      body = httpBody
    }
    Self.requests.append((request, body))

    let exchange = Self.nextExchange
    let response = HTTPURLResponse(
      url: request.url!, statusCode: exchange.status, httpVersion: "HTTP/1.1",
      headerFields: exchange.headers.merging(["Content-Type": "application/json"]) { a, _ in a })!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data(exchange.body.utf8))
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

/// What actually goes over the wire.
final class TransportTests: XCTestCase {
  private func makeTransport(
    onClientAdvisory: (@Sendable (RemoteDrawClientAdvisory) -> Void)? = nil
  ) -> RemoteDrawSenderHTTPTransport {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return RemoteDrawSenderHTTPTransport(
      baseURL: .custom(URL(string: "https://api.example.test")!),
      urlSession: URLSession(configuration: configuration),
      onClientAdvisory: onClientAdvisory)
  }

  /// Collects advisories from the transport's callback across threads.
  private final class AdvisoryLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [RemoteDrawClientAdvisory] = []
    func record(_ advisory: RemoteDrawClientAdvisory) {
      lock.lock()
      entries.append(advisory)
      lock.unlock()
    }
    var all: [RemoteDrawClientAdvisory] {
      lock.lock()
      defer { lock.unlock() }
      return entries
    }
  }

  override func setUp() {
    super.setUp()
    StubURLProtocol.reset()
  }

  // MARK: - Shape

  func testEveryRouteIsAPostWithTheCredentialInTheBody() async throws {
    // The `Authorization` header belongs to API keys, which a sender never
    // holds. A sender token in a header would be a different wire dialect and
    // the server would refuse it.
    StubURLProtocol.reset(.init(status: 200, body: #"{"accepted":true}"#))
    let transport = makeTransport()
    _ = try await transport.updateDraft(
      RemoteDrawDraftRequest(
        senderToken: "rd_send_1", sequence: 3, points: [
          RemoteDrawNormalizedPoint(x: 0.1, y: 0.2)
        ]))

    let (request, _) = try XCTUnwrap(StubURLProtocol.lastRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/sender/draft")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(try StubURLProtocol.lastBody()["senderToken"] as? String, "rd_send_1")
  }

  func testDraftsCarryPackedPointsAndNeverAPlainPointsArray() async throws {
    // The plain-points path is ~13x larger and is a second wire dialect. There
    // is deliberately no way to send one from this SDK.
    StubURLProtocol.reset(.init(status: 200, body: #"{"accepted":true}"#))
    let transport = makeTransport()
    let points = (0..<20).map {
      RemoteDrawNormalizedPoint(x: Double($0) / 20, y: 0.5, t: Double($0) * 8, pressure: 0.5)
    }
    _ = try await transport.updateDraft(
      RemoteDrawDraftRequest(senderToken: "rd_send_1", sequence: 1, points: points))

    let body = try StubURLProtocol.lastBody()
    let packed = try XCTUnwrap(body["packedPoints"] as? String)
    XCTAssertNil(body["points"])
    XCTAssertEqual(try PointCodec.unpack(packed).count, 20)
  }

  func testAMultiSegmentRouteIsNotPercentEscapedIntoOneComponent() async throws {
    // `appendingPathComponent` would turn /v1/sender/projection/close into a
    // single escaped component and every request would 404.
    StubURLProtocol.reset()
    let transport = makeTransport()
    try await transport.closeProjection(senderToken: "rd_send_1", disconnect: true)
    XCTAssertEqual(
      StubURLProtocol.lastRequest?.0.url?.absoluteString,
      "https://api.example.test/v1/sender/projection/close")
  }

  func testDrawingsAsksForPackedPoints() async throws {
    StubURLProtocol.reset(.init(status: 200, body: #"{"items":[]}"#))
    let transport = makeTransport()
    _ = try await transport.drawings(senderToken: "rd_send_1")
    XCTAssertEqual(StubURLProtocol.lastRequest?.0.url?.path, "/v1/sender/drawings")
    let body = try StubURLProtocol.lastBody()
    XCTAssertEqual(body["senderToken"] as? String, "rd_send_1")
    XCTAssertEqual(body["encoding"] as? String, "packed")
  }

  func testEveryRequestIdentifiesTheSDK() async throws {
    // Without this, "old SDK meets new API" is a silently degraded drawing —
    // the failure mode neither end can detect.
    StubURLProtocol.reset()
    let transport = makeTransport()
    try await transport.ping(senderToken: "rd_send_1", active: true)
    XCTAssertEqual(
      StubURLProtocol.lastRequest?.0.value(forHTTPHeaderField: "X-RemoteDraw-SDK"),
      "swift/\(RemoteDraw.sdkVersion)")
  }

  func testPingOmitsTheActiveFlagWhenItIsFalse() async throws {
    // The server reads the key's presence; sending `false` is not the same as
    // not sending it, and the first-party app omits it.
    StubURLProtocol.reset()
    let transport = makeTransport()
    try await transport.ping(senderToken: "rd_send_1", active: false)
    XCTAssertNil(try StubURLProtocol.lastBody()["active"])

    try await transport.ping(senderToken: "rd_send_1", active: true)
    XCTAssertEqual(try StubURLProtocol.lastBody()["active"] as? Bool, true)
  }

  func testSubmitMetadataCannotOverwriteTheIdempotencyKey() async throws {
    StubURLProtocol.reset(.init(status: 200, body: #"{"id":"s1","accepted":true}"#))
    let transport = makeTransport()
    _ = try await transport.submit(
      senderToken: "rd_send_1", clientSubmissionId: "real-id",
      metadata: ["clientSubmissionId": .string("hijacked"), "stepId": .string("step_4")])

    let metadata = try XCTUnwrap(try StubURLProtocol.lastBody()["metadata"] as? [String: Any])
    XCTAssertEqual(metadata["clientSubmissionId"] as? String, "real-id")
    XCTAssertEqual(metadata["stepId"] as? String, "step_4")
    XCTAssertNotNil(metadata["occurredAt"])
  }

  func testCommitPostsToItsOwnRouteAndAcceptsA201() async throws {
    // Commit answers 201 and everything else answers 200; the whole 2xx range
    // is accepted so the exact code stays the server's business.
    StubURLProtocol.reset(
      .init(status: 201, body: #"{"id":"d1","duplicate":false,"type":"freehand"}"#))
    let transport = makeTransport()
    let result = try await transport.commitStroke(
      RemoteDrawCommitRequest(
        senderToken: "rd_send_1", clientStrokeId: "c1", sequence: 2,
        points: [
          RemoteDrawNormalizedPoint(x: 0, y: 0), RemoteDrawNormalizedPoint(x: 1, y: 1),
        ]))
    XCTAssertEqual(result.id, "d1")
    XCTAssertFalse(result.isDuplicate)
  }

  func testRefreshPostsToItsOwnRouteAndReturnsTheRotatedCredential() async throws {
    StubURLProtocol.reset(
      .init(
        status: 200,
        body: #"{"senderToken":"rd_send_2","senderId":"s1","expiresAt":42,"lastSequence":9}"#))
    let transport = makeTransport()
    let rotated = try await transport.refresh(senderToken: "rd_send_1")

    XCTAssertEqual(StubURLProtocol.lastRequest?.0.url?.path, "/v1/sender/refresh")
    XCTAssertEqual(rotated.senderToken, "rd_send_2")
    // The sequence survives rotation, so a resuming sender continues where it
    // left off rather than restarting at 0 and having every draft rejected.
    XCTAssertEqual(rotated.lastSequence, 9)
  }

  func testSyncPostsTheCredentialToItsOwnRouteAndDecodesTheRevisionShape() async throws {
    // The shape `convex/lib/syncRevisions.ts` answers: four opaque strings.
    StubURLProtocol.reset(
      .init(status: 200, body: #"{"drawings":"3:1:0","drafts":"9:1:0","files":"0","metadata":"abc:2:17"}"#))
    let transport = makeTransport()
    let revisions = try await transport.sync(senderToken: "rd_send_1")

    let (request, _) = try XCTUnwrap(StubURLProtocol.lastRequest)
    XCTAssertEqual(request.httpMethod, "POST")
    XCTAssertEqual(request.url?.path, "/v1/sender/sync")
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    let body = try StubURLProtocol.lastBody()
    XCTAssertEqual(body["senderToken"] as? String, "rd_send_1")
    XCTAssertEqual(body.count, 1)
    XCTAssertEqual(
      revisions,
      RemoteDrawSyncRevisions(drawings: "3:1:0", metadata: "abc:2:17", drafts: "9:1:0", files: "0"))
  }

  func testOnlyABareRouter404MeansSyncIsUnsupported() async throws {
    let transport = makeTransport()
    StubURLProtocol.reset(.init(status: 404, body: "No matching routes found"))
    do {
      _ = try await transport.sync(senderToken: "rd_send_1")
      XCTFail("Expected unsupported")
    } catch is RemoteDrawSyncUnsupportedError {}

    // The API's own 404 names a code and is a real answer about this session.
    StubURLProtocol.reset(
      .init(status: 404, body: #"{"error":{"code":"session_not_found","message":"Gone."}}"#))
    do {
      _ = try await transport.sync(senderToken: "rd_send_1")
      XCTFail("Expected a server error")
    } catch RemoteDrawError.server(let status, let code, _) {
      XCTAssertEqual(status, 404)
      XCTAssertEqual(code, "session_not_found")
    }
  }

  // MARK: - Errors

  func testTheNestedErrorEnvelopeIsRead() async throws {
    // A decoder that reads `error` as a string finds nothing in the real shape,
    // turning "Session is not active." into a bare status code.
    StubURLProtocol.reset(
      .init(status: 400, body: #"{"error":{"code":"bad_request","message":"Points are required."}}"#))
    let transport = makeTransport()
    do {
      _ = try await transport.undo(senderToken: "rd_send_1")
      XCTFail("expected a throw")
    } catch {
      XCTAssertEqual(
        error as? RemoteDrawError,
        .server(status: 400, code: "bad_request", message: "Points are required."))
    }
  }

  func testADegradedProxyEnvelopeStillYieldsItsMessage() async throws {
    // Not what this API emits, but a gateway in front of it may, and losing the
    // message there is the same failure as losing the nested one.
    StubURLProtocol.reset(.init(status: 502, body: #"{"error":"upstream unavailable"}"#))
    let transport = makeTransport()
    do {
      _ = try await transport.undo(senderToken: "rd_send_1")
      XCTFail("expected a throw")
    } catch {
      guard case .server(_, _, let message) = try XCTUnwrap(error as? RemoteDrawError) else {
        return XCTFail("wrong case")
      }
      XCTAssertEqual(message, "upstream unavailable")
    }
  }

  func testStatusCodesMapOntoTheCasesThatDecideRecovery() async throws {
    let transport = makeTransport()

    StubURLProtocol.reset(.init(status: 401, body: #"{"error":{"code":"invalid_sender_token"}}"#))
    await assertThrows(.tokenRejected) { _ = try await transport.undo(senderToken: "t") }

    StubURLProtocol.reset(.init(status: 410, body: "{}"))
    await assertThrows(.sessionEnded) { _ = try await transport.undo(senderToken: "t") }

    StubURLProtocol.reset(
      .init(status: 400, body: #"{"error":{"code":"session_not_active","message":"over"}}"#))
    await assertThrows(.sessionEnded) { _ = try await transport.undo(senderToken: "t") }

    StubURLProtocol.reset(.init(status: 403, body: #"{"error":{"code":"forbidden"}}"#))
    await assertThrows(.notPermitted(.undo)) { _ = try await transport.undo(senderToken: "t") }
  }

  func testRateLimitingCarriesTheBucketSoARetryCanTellItApartFromABadToken() async throws {
    // `auth_failures_per_ip` answers 429 in place of 401 once an IP has burned
    // its budget. A caller that reads that as "slow down" is waiting out a
    // wrong token, forever.
    StubURLProtocol.reset(
      .init(
        status: 429, body: #"{"error":{"code":"auth_failures_per_ip","retryAfter":12}}"#,
        headers: ["Retry-After": "30"]))
    let transport = makeTransport()
    do {
      _ = try await transport.undo(senderToken: "t")
      XCTFail("expected a throw")
    } catch {
      XCTAssertEqual(
        error as? RemoteDrawError,
        .rateLimited(retryAfter: 12, bucket: "auth_failures_per_ip"))
    }
  }

  func testABlockingClientAdvisoryStopsTheSDKEvenOnA200() async throws {
    StubURLProtocol.reset(
      .init(
        status: 200,
        body: #"{"removed":true,"clientAdvisory":{"level":"blocked","minimum":"2.1.0","message":"Update required."}}"#
      ))
    let transport = makeTransport()
    do {
      _ = try await transport.undo(senderToken: "t")
      XCTFail("expected a throw")
    } catch {
      XCTAssertEqual(
        error as? RemoteDrawError, .sdkTooOld(minimum: "2.1.0", message: "Update required."))
    }
  }

  func testAWarningAdvisoryDoesNotStopAnything() async throws {
    StubURLProtocol.reset(
      .init(status: 200, body: #"{"removed":true,"clientAdvisory":{"level":"warn"}}"#))
    let transport = makeTransport()
    let result = try await transport.undo(senderToken: "t")
    XCTAssertTrue(result.removed)
  }

  /// The `warn` level exists to reach a human before the app breaks. It was
  /// decoded and discarded, which made it indistinguishable from silence.
  func testAWarningReachesTheDiagnosticsHandler() async throws {
    let log = AdvisoryLog()
    StubURLProtocol.reset(.init(status: 200, body: #"{"removed":true,"clientAdvisory":{"level":"warn","minimum":"0.3.0","message":"Retiring soon.","current":"0.1.0"}}"#))
    let transport = makeTransport(onClientAdvisory: { log.record($0) })
    _ = try await transport.undo(senderToken: "t")
    XCTAssertEqual(
      log.all,
      [
        RemoteDrawClientAdvisory(
          level: .warn, minimum: "0.3.0", message: "Retiring soon.", current: "0.1.0")
      ])
  }

  /// A drawing sender makes a request every 32 ms and the advisory rides on
  /// every response. Reporting each one would bury the message.
  func testTheSameAdvisoryIsReportedOnceHoweverManyRequestsCarryIt() async throws {
    let log = AdvisoryLog()
    StubURLProtocol.reset(.init(status: 200, body: #"{"removed":true,"clientAdvisory":{"level":"warn","minimum":"0.3.0","message":"Retiring soon.","current":"0.1.0"}}"#))
    let transport = makeTransport(onClientAdvisory: { log.record($0) })
    for _ in 0..<5 { _ = try await transport.undo(senderToken: "t") }
    XCTAssertEqual(log.all.count, 1)
  }

  /// The server refuses a retired build outright rather than doing the work and
  /// complaining afterwards, so the advisory has to be read off the error
  /// response too — otherwise a refusal arrives as a bare `server(status: 426)`
  /// the host cannot act on.
  func testARefusalCarriesTheAdvisoryOnA426() async throws {
    let log = AdvisoryLog()
    StubURLProtocol.reset(.init(status: 426, body: #"{"error":{"code":"sdk_too_old","message":"Update to 0.2.0 or newer."},"clientAdvisory":{"level":"blocked","minimum":"0.2.0","message":"Update to 0.2.0 or newer.","current":"0.1.0"}}"#))
    let transport = makeTransport(onClientAdvisory: { log.record($0) })
    do {
      _ = try await transport.undo(senderToken: "t")
      XCTFail("expected a throw")
    } catch {
      XCTAssertEqual(
        error as? RemoteDrawError,
        .sdkTooOld(minimum: "0.2.0", message: "Update to 0.2.0 or newer."))
    }
    XCTAssertEqual(log.all.first?.level, .blocked)
  }

  /// A deployment that invents a third level must not have it read as a block
  /// by an SDK that has never heard of it — that is this gate's own failure
  /// mode arriving from the other direction.
  func testAnUnknownAdvisoryLevelIsIgnored() async throws {
    let log = AdvisoryLog()
    StubURLProtocol.reset(
      .init(
        status: 200,
        body: #"{"removed":true,"clientAdvisory":{"level":"deprecated","minimum":"9.0.0"}}"#))
    let transport = makeTransport(onClientAdvisory: { log.record($0) })
    let result = try await transport.undo(senderToken: "t")
    XCTAssertTrue(result.removed)
    XCTAssertTrue(log.all.isEmpty)
  }

  /// An ordinary response has no advisory, and the callback must stay silent —
  /// a handler that fires on every request is a handler a host turns off.
  func testAnOrdinaryResponseReportsNothing() async throws {
    let log = AdvisoryLog()
    StubURLProtocol.reset(.init(status: 200, body: #"{"removed":true}"#))
    let transport = makeTransport(onClientAdvisory: { log.record($0) })
    _ = try await transport.undo(senderToken: "t")
    XCTAssertTrue(log.all.isEmpty)
  }

  private func assertThrows(
    _ expected: RemoteDrawError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> Void
  ) async {
    do {
      try await body()
      XCTFail("expected \(expected)", file: file, line: line)
    } catch {
      XCTAssertEqual(error as? RemoteDrawError, expected, file: file, line: line)
    }
  }
}
