import XCTest
@testable import RemoteDrawSenderKit

@MainActor
final class UndoSynchronizationTests: XCTestCase {
  private func sender(_ transport: FakeTransport, capabilities: [String]) -> RemoteDrawSenderSession {
    .adopt(senderToken: "sender-a", transport: transport, capabilities: capabilities,
      automaticallyRefreshDrawings: false, pollClock: transport.holdAutomaticPolling())
  }

  func testEveryUndoKindDecodesAndReportsSuccess() throws {
    for kind in ["create", "clear", "delete", "setProperties", "reorder"] {
      let json = #"{"removed":false,"undone":"\#(kind)","elements":[{"drawingId":"drawing_1","revision":2,"removed":false}]}"#
      let result = try JSONDecoder().decode(RemoteDrawUndoResult.self, from: Data(json.utf8))
      XCTAssertTrue(result.didUndo)
      XCTAssertNotEqual(result.statusText, "Nothing to undo.")
      XCTAssertEqual(result.elements?.first?.drawingId, "drawing_1")
    }
    XCTAssertFalse(RemoteDrawUndoResult(removed: false, drawingId: nil).didUndo)
  }

  func testUndoRestorationAndPropertyChangeRefreshGeometryByID() async throws {
    for kind in ["clear", "delete", "setProperties"] {
      let transport = FakeTransport()
      let session = sender(transport, capabilities: ["undo", "viewExisting"])
      transport.undoResult = RemoteDrawUndoResult(removed: false, drawingId: nil, undone: kind)
      transport.drawingsJSON = #"{"items":[{"id":"restored","type":"freehand","points":[{"x":0.2,"y":0.8},{"x":0.8,"y":0.2}]}]}"#
      let result = try await session.undo()
      XCTAssertTrue(result.didUndo)
      XCTAssertEqual(session.strokes.map(\.id), ["restored"])
      XCTAssertEqual(session.strokes.first?.points.first?.y, 0.8)
      session.leave()
    }
  }

  func testUndoWithoutDrawingIDNeverGuessesTheLastStroke() async throws {
    let transport = FakeTransport()
    let session = sender(transport, capabilities: ["draw", "undo"])
    _ = try await session.commitText("keep", at: RemoteDrawNormalizedPoint(x: 0.2, y: 0.3))
    transport.undoResult = RemoteDrawUndoResult(removed: true, drawingId: nil)
    _ = try await session.undo()
    XCTAssertEqual(session.strokes.map(\.id), ["drawing_1"])
    session.leave()
  }
  func testOlderReadCannotResurrectDeletedInk() async throws {
    let transport = FakeTransport()
    let session = sender(transport, capabilities: ["viewExisting"])
    transport.drawingsJSON = #"{"items":[{"id":"deleted","type":"freehand","points":[{"x":0.1,"y":0.1}]}]}"#
    var release: CheckedContinuation<Void, Never>?
    transport.drawingsAsyncHook = { await withCheckedContinuation { release = $0 } }
    let oldRead = Task { try await session.refreshDrawings() }
    while release == nil { await Task.yield() }
    transport.drawingsAsyncHook = nil
    transport.drawingsJSON = #"{"items":[]}"#
    // A deletion invalidates the accepted revision. Concurrent reads now
    // share the in-flight request, so queue the fresh read before releasing
    // the stale answer rather than waiting for a second network request.
    session.requestDrawingsRefresh()
    var newerReadStarted = false
    let newerRead = Task {
      newerReadStarted = true
      return try await session.refreshDrawings()
    }
    while !newerReadStarted { await Task.yield() }
    XCTAssertEqual(transport.callCount(.drawings), 1)
    release?.resume()
    _ = try await oldRead.value
    _ = try await newerRead.value
    XCTAssertEqual(transport.callCount(.drawings), 2)
    XCTAssertTrue(session.strokes.isEmpty)
    session.leave()
  }

  func testReadCompletionAfterLeaveIsRejected() async throws {
    let transport = FakeTransport()
    let session = sender(transport, capabilities: ["viewExisting"])
    transport.drawingsAsyncHook = { session.leave() }
    do {
      _ = try await session.refreshDrawings()
      XCTFail("An ended session accepted an old response")
    } catch { XCTAssertTrue(session.strokes.isEmpty) }
  }

  func testCommitCompletionAfterLeaveIsRejected() async throws {
    let transport = FakeTransport()
    let session = sender(transport, capabilities: ["draw"])
    transport.commitAsyncHook = { _ in session.leave() }
    do {
      _ = try await session.commitText("old", at: RemoteDrawNormalizedPoint(x: 0.2, y: 0.3))
      XCTFail("An ended session accepted an old commit")
    } catch { XCTAssertFalse(session.strokes.contains { !$0.isLocalEcho }) }
  }

}
