import XCTest
@testable import RemoteDrawSenderKit

@MainActor
final class FixturePollingTests: XCTestCase {
  func testHeldPollingKeepsManualReadsAndDrawingActiveAndCancelsCleanly() async throws {
    let transport = FakeTransport()
    let clock = transport.holdAutomaticPolling()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_fixture", transport: transport,
      session: .stub(), capabilities: ["draw", "viewExisting"], automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { sender.stopLocally() }
    await clock.settle()
    XCTAssertEqual(transport.callCount(.session), 0)
    XCTAssertEqual(transport.callCount(.drawings), 0)

    try await sender.refreshSession()
    _ = try await sender.refreshDrawings()
    sender.begin(stroke: "foreground", tool: .freehand)
    sender.append([.init(x: 0.1, y: 0.1), .init(x: 0.4, y: 0.4)])
    _ = try await sender.end(stroke: "foreground")
    XCTAssertEqual(transport.callCount(.session), 1)
    XCTAssertEqual(transport.callCount(.drawings), 1)
    XCTAssertEqual(transport.callCount(.commit), 1)

    sender.stopLocally()
    await clock.settle()
    XCTAssertEqual(clock.sleeperCount, 0, "teardown must release both held sync and heartbeat")
  }

  func testActualBackgroundStillRejectsDrawingAndManualMaintenance() async throws {
    let transport = FakeTransport()
    let clock = transport.holdAutomaticPolling()
    let sender = RemoteDrawSenderSession.adopt(senderToken: "rd_send_fixture", transport: transport,
      session: .stub(), capabilities: ["draw", "viewExisting"], automaticallyRefreshDrawings: false,
      pollClock: clock)
    defer { sender.stopLocally() }
    await clock.settle()
    await sender.markInactive()
    sender.begin(stroke: "background", tool: .freehand)
    sender.append([.init(x: 0.1, y: 0.1), .init(x: 0.4, y: 0.4)])
    let result = try await sender.end(stroke: "background")
    XCTAssertNil(result)
    XCTAssertNil(sender.live)
    do { try await sender.refreshSession(); XCTFail("background metadata read was admitted") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    do { _ = try await sender.refreshDrawings(); XCTFail("background drawing read was admitted") }
    catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    XCTAssertEqual(transport.callCount(.session), 0)
    XCTAssertEqual(transport.callCount(.drawings), 0)
    XCTAssertEqual(transport.callCount(.draft), 0)
    XCTAssertEqual(transport.callCount(.commit), 0)
  }
}
