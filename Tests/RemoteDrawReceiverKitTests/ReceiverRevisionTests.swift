import XCTest
@testable import RemoteDrawReceiverKit

private actor RevisionTransport: RemoteDrawReceiverTransport {
  var revision = 0
  var copies = 0
  func advance() { revision += 1 }
  func count() -> Int { copies }
  func fetchRevisions(_ c: RemoteDrawReceiverCredentials) async throws -> RemoteDrawSyncRevisions? {
    RemoteDrawSyncRevisions(drawings: String(revision), drafts: "0", files: "0", metadata: "0")
  }
  func fetchSession(_ c: RemoteDrawReceiverCredentials) async throws -> RemoteDrawReceiverSession {
    try JSONDecoder().decode(RemoteDrawReceiverSession.self, from: Data("{\"id\":\"board\",\"status\":\"active\"}".utf8))
  }
  func fetchDrawings(_ c: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDrawing] {
    copies += 1
    if revision == 2 { return [] }
    return try JSONDecoder().decode([RemoteDrawReceiverDrawing].self, from: Data("[{\"id\":\"stroke-\(revision)\",\"type\":\"freehand\",\"points\":[]}]".utf8))
  }
  func fetchDrafts(_ c: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverDraft] { [] }
  func fetchSenders(_ c: RemoteDrawReceiverCredentials) async throws -> [RemoteDrawReceiverSenderRecord] { [] }
  func undo(_ c: RemoteDrawReceiverCredentials) async throws {}
  func clear(_ c: RemoteDrawReceiverCredentials) async throws {}
}
final class ReceiverRevisionTests: XCTestCase {
  @MainActor func testIdleChangesClearAndReconnect() async throws {
    let transport = RevisionTransport()
    let store = RemoteDrawReceiverStore(transport: transport, idleIntervalMs: 60_000)
    store.start(credentials: .init(sessionId: "board", receiverToken: "token"))
    defer { store.stop() }
    try await Task.sleep(nanoseconds: 20_000_000)
    for _ in 0..<500 { _ = await store.refetch() }
    let firstCount = await transport.count()
    XCTAssertEqual(firstCount, 1)
    await transport.advance()
    let changed = await store.refetch()
    XCTAssertEqual(changed.drawings.first?.id, "stroke-1")
    await transport.advance()
    let cleared = await store.refetch()
    XCTAssertTrue(cleared.drawings.isEmpty)
    store.start(credentials: .init(sessionId: "board", receiverToken: "rotated"))
    try await Task.sleep(nanoseconds: 20_000_000)
    let finalCount = await transport.count()
    XCTAssertEqual(finalCount, 4)
  }
}
