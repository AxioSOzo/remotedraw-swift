import XCTest
@testable import RemoteDrawReceiverKit

@MainActor
final class ReceiverLifecycleTests: XCTestCase {
  func testConcurrentRefetchDoesNotStartAnotherBatch() async {
    let transport = PausedTransport()
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: .init(sessionId: "old", receiverToken: "token"))
    await transport.waitUntilStarted()
    _ = await store.refetch()
    let count = await transport.calls
    XCTAssertEqual(count, 1)
    store.stop()
    await transport.release()
  }

  func testStoppedInFlightPollCannotRestoreOldInk() async {
    let transport = PausedTransport()
    let store = RemoteDrawReceiverStore(transport: transport)
    store.start(credentials: .init(sessionId: "old", receiverToken: "token"))
    // A manual refresh racing with the background poll must also respect stop.
    let poll = Task { await store.refetch() }
    await transport.waitUntilStarted()
    store.stop()
    await transport.release()
    _ = await poll.value
    XCTAssertNil(store.snapshot.session)
    XCTAssertTrue(store.snapshot.isEmpty)
    XCTAssertEqual(store.status, .idle)
  }
}

private actor PausedTransport: RemoteDrawReceiverTransport {
  var calls = 0
  private var gate: CheckedContinuation<Void, Never>?
  private var startedWaiter: CheckedContinuation<Void, Never>?

  func waitUntilStarted() async {
    if gate != nil { return }
    await withCheckedContinuation { startedWaiter = $0 }
  }
  func release() { gate?.resume(); gate = nil }
  func fetchSession(_ credentials: RemoteDrawReceiverCredentials) async throws -> RemoteDrawReceiverSession {
    calls += 1
    await withCheckedContinuation { continuation in
      gate = continuation
      startedWaiter?.resume()
      startedWaiter = nil
    }
    return try JSONDecoder().decode(RemoteDrawReceiverSession.self, from: Data(#"{"id":"old","status":"active"}"#.utf8))
  }
  func fetchDrafts(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDraft] { [] }
  func fetchDrawings(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDrawing] { [] }
  func fetchSenders(_ credentials: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverSenderRecord] { [] }
  func undo(_ credentials: RemoteDrawReceiverCredentials) async throws {}
  func clear(_ credentials: RemoteDrawReceiverCredentials) async throws {}
}
