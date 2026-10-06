import XCTest
@testable import RemoteDrawSenderKit

final class ContactGestureGateTests: XCTestCase {
  private let a = CGPoint(x: 100, y: 100)
  private let b = CGPoint(x: 200, y: 100)
  private func pair() -> RemoteDrawContactGestureGate {
    var gate = RemoteDrawContactGestureGate()
    gate.began(contact: 1, position: a, timestamp: 0)
    gate.began(contact: 2, position: b, timestamp: 0.02)
    return gate
  }
  private func lift(_ gate: inout RemoteDrawContactGestureGate, at time: Double = 0.2,
    first: CGPoint? = nil, second: CGPoint? = nil) -> RemoteDrawContactAction? {
    XCTAssertNil(gate.ended(contact: 1, position: first ?? a, timestamp: time))
    return gate.ended(contact: 2, position: second ?? b, timestamp: time + 0.01)
  }

  func testTwoFingerTapEmitsUndoOnlyOnLastLift() {
    var gate = pair()
    XCTAssertFalse(gate.allowsLongPress)
    XCTAssertEqual(lift(&gate), .undo)
    XCTAssertNil(gate.ended(contact: 2, position: b, timestamp: 0.22))
  }
  func testThreeFingerTapEmitsControls() {
    var gate = pair()
    gate.began(contact: 3, position: CGPoint(x: 300, y: 100), timestamp: 0.04)
    XCTAssertNil(lift(&gate))
    XCTAssertEqual(gate.ended(contact: 3, position: CGPoint(x: 300, y: 100), timestamp: 0.25), .controls)
  }
  func testSmallOpposingPinchDoesNotUndoEvenThoughEachFingerMovedUnderTapSlop() {
    var gate = pair()
    let first = CGPoint(x: 97, y: 100), second = CGPoint(x: 203, y: 100)
    gate.moved(contact: 1, position: first, timestamp: 0.1)
    gate.moved(contact: 2, position: second, timestamp: 0.1)
    XCTAssertTrue(gate.navigationLatched)
    XCTAssertNil(lift(&gate, first: first, second: second))
  }
  func testRepeatedPinchesAtZoomLimitCannotEmitUndo() {
    var gate = RemoteDrawContactGestureGate()
    for round in 0..<100 {
      let start = Double(round)
      gate.began(contact: 1, position: a, timestamp: start)
      gate.began(contact: 2, position: b, timestamp: start)
      gate.moved(contact: 2, position: CGPoint(x: 210, y: 100), timestamp: start + 0.1)
      // Returning to the original positions must not make it a tap again.
      XCTAssertNil(lift(&gate, at: start + 0.2))
    }
  }
  func testSlowTinyPinchCannotUndo() {
    var gate = pair()
    gate.moved(contact: 2, position: CGPoint(x: 202, y: 100), timestamp: 0.4)
    XCTAssertNil(lift(&gate, at: 0.5))
  }
  func testPanCannotUndo() {
    var gate = pair()
    gate.moved(contact: 1, position: CGPoint(x: 100, y: 105), timestamp: 0.1)
    gate.moved(contact: 2, position: CGPoint(x: 200, y: 105), timestamp: 0.1)
    XCTAssertNil(lift(&gate))
  }
  func testStaggeredLiftAndReplacementRemainSameDisqualifiedSequence() {
    var gate = pair()
    XCTAssertNil(gate.ended(contact: 1, position: a, timestamp: 0.1))
    XCTAssertFalse(gate.allowsLongPress)
    gate.began(contact: 3, position: a, timestamp: 0.12)
    XCTAssertNil(gate.ended(contact: 2, position: b, timestamp: 0.15))
    XCTAssertNil(gate.ended(contact: 3, position: a, timestamp: 0.2))
  }
  func testRecognizerResetDoesNotForgetHeldContacts() {
    var gate = pair()
    gate.resetForRecognizer()
    XCTAssertTrue(gate.hasLiveContacts)
    XCTAssertFalse(gate.allowsLongPress)
    XCTAssertNil(lift(&gate))
  }
  func testCancellationAndPalmCannotEmitShortcut() {
    var gate = pair()
    gate.cancelled(contact: 1)
    XCTAssertNil(gate.ended(contact: 2, position: b, timestamp: 0.2))
    gate.began(contact: 3, position: a, timestamp: 1, isPencilLike: true)
    gate.began(contact: 4, position: b, timestamp: 1)
    XCTAssertFalse(gate.allowsLongPress)
    XCTAssertNil(gate.ended(contact: 3, position: a, timestamp: 1.1))
    XCTAssertNil(gate.ended(contact: 4, position: b, timestamp: 1.2))
  }
  func testReleaseOnlyMovementCannotBecomeUndo() {
    var gate = pair()
    XCTAssertNil(lift(&gate, first: CGPoint(x: 50, y: 100)))
  }
  func testNewPhysicalSequenceCanTapAndHoldAfterPinch() {
    var gate = pair()
    gate.moved(contact: 2, position: CGPoint(x: 250, y: 100), timestamp: 0.1)
    XCTAssertNil(lift(&gate))
    gate.began(contact: 1, position: a, timestamp: 1)
    XCTAssertTrue(gate.allowsLongPress)
    gate.began(contact: 2, position: b, timestamp: 1)
    XCTAssertEqual(lift(&gate, at: 1.1), .undo)
  }
  func testInvalidCoordinatesFailClosed() {
    var gate = pair()
    gate.moved(contact: 2, position: CGPoint(x: CGFloat.nan, y: 100), timestamp: 0.1)
    XCTAssertNil(lift(&gate))
  }

  func testClaimedHoldCanSlideButSecondFingerCancelsIt() {
    var gate = RemoteDrawContactGestureGate()
    gate.began(contact: 1, position: a, timestamp: 0)
    XCTAssertTrue(gate.claimLongPress())
    gate.moved(contact: 1, position: CGPoint(x: 250, y: 300), timestamp: 0.7)
    XCTAssertTrue(gate.allowsLongPress)
    gate.began(contact: 2, position: b, timestamp: 0.8)
    XCTAssertFalse(gate.allowsLongPress)
    XCTAssertNil(lift(&gate, at: 1))
  }
}
