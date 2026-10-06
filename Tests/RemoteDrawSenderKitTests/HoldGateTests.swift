//
//  The hold gate: is this touch a mark, or a summon?
//
//  These are the assertions the input contract asks for by name — nothing
//  reaches the stroke buffer during arbitration, a tap still makes its dot, a
//  recognizer that fails after movement cannot erase the mark, and an
//  established stroke can never be turned back into a menu by dwelling.
//
import XCTest

@testable import RemoteDrawSenderKit

final class HoldGateTests: XCTestCase {
  private func sample(_ x: CGFloat, _ y: CGFloat, t: Double = 0) -> RemoteDrawHoldSample {
    RemoteDrawHoldSample(
      location: CGPoint(x: x, y: y),
      point: RemoteDrawNormalizedPoint(x: Double(x) / 390, y: Double(y) / 844, t: t, pressure: 0.5)
    )
  }

  private func points(_ decision: RemoteDrawHoldGate.Decision) -> [RemoteDrawNormalizedPoint] {
    switch decision {
    case .beginDrawing(let points), .deposit(let points): return points
    case .buffer, .summon, .ignore: return []
    }
  }

  // MARK: - Arbitration

  func testFirstContactDepositsNothingWhileTheHoldCanStillWin() {
    var gate = RemoteDrawHoldGate()
    XCTAssertEqual(gate.begin(sample(100, 100), mode: .deferUntilMovement), .buffer)
    XCTAssertTrue(gate.isPending)
    XCTAssertFalse(gate.isDrawing)
    XCTAssertEqual(gate.append([sample(102, 101, t: 8)]), .buffer)
  }

  func testMovementPastTheThresholdFlushesEverySampleInOrder() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.append([sample(103, 100, t: 8), sample(106, 100, t: 16)])
    let decision = gate.append([sample(109, 100, t: 24), sample(112, 100, t: 32)])

    guard case .beginDrawing(let flushed) = decision else {
      return XCTFail("crossing 10pt has to start the mark, got \(decision)")
    }
    XCTAssertEqual(flushed.count, 5, "the contact sample and every buffered one")
    XCTAssertEqual(flushed.map(\.t), [0, 8, 16, 24, 32], "original capture order and times")
    XCTAssertTrue(gate.isDrawing)
    XCTAssertFalse(gate.isPending)
  }

  func testTheDragsOwnLocationIsABackstopForMovement() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    XCTAssertEqual(gate.move(to: CGPoint(x: 104, y: 100)), .buffer)
    guard case .beginDrawing(let flushed) = gate.move(to: CGPoint(x: 100, y: 111)) else {
      return XCTFail("11pt of travel is movement")
    }
    XCTAssertEqual(flushed.count, 1)
  }

  func testOnceDrawingSamplesFlowStraightThrough() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.move(to: CGPoint(x: 120, y: 100))
    let decision = gate.append([sample(122, 100, t: 40)])
    XCTAssertEqual(points(decision).count, 1, "no second flush of the buffer")
  }

  // MARK: - The hold

  func testHoldWhilePendingSummonsAndLeavesNothingBehind() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.append([sample(101, 100, t: 8)])
    XCTAssertEqual(gate.holdRecognized(), .summon)
    XCTAssertFalse(gate.isPending)
    XCTAssertEqual(gate.end(), .ignore, "the buffered samples were discarded, not deposited")
  }

  func testAnEstablishedStrokeIgnoresALaterHold() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.move(to: CGPoint(x: 140, y: 140))
    XCTAssertEqual(gate.holdRecognized(), .ignore, "dwelling mid-stroke keeps drawing")
    XCTAssertTrue(gate.isDrawing)
  }

  func testAnExcursionAndReturnStaysDrawing() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.append([sample(140, 100, t: 8)])
    _ = gate.append([sample(100, 100, t: 16)])
    XCTAssertTrue(gate.isDrawing, "the latch is for the whole touch, not for the moment")
    XCTAssertEqual(gate.holdRecognized(), .ignore)
  }

  // MARK: - Lifts

  func testAQuickTapStillMakesItsDot() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.append([sample(102, 101, t: 8)])
    guard case .deposit(let deposited) = gate.end() else {
      return XCTFail("a lift before the hold has to deposit what it captured")
    }
    XCTAssertEqual(deposited.count, 2)
    XCTAssertFalse(gate.hasBegun, "the gate is idle again for the next touch")
  }

  func testCancellationDepositsNothing() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    gate.cancel()
    XCTAssertFalse(gate.hasBegun)
    XCTAssertEqual(gate.end(), .ignore)
  }

  func testAReleaseAfterTheMenuOpenedDoesNothingToTheInkPath() {
    var gate = RemoteDrawHoldGate()
    _ = gate.begin(sample(100, 100), mode: .deferUntilMovement)
    _ = gate.holdRecognized()
    XCTAssertEqual(gate.end(), .ignore)
  }

  // MARK: - Immediate mode

  func testImmediateModeDepositsAtFirstContact() {
    var gate = RemoteDrawHoldGate()
    guard case .beginDrawing(let first) = gate.begin(sample(100, 100), mode: .immediate) else {
      return XCTFail("hold-off, Pencil and accessibility modes draw from the first sample")
    }
    XCTAssertEqual(first.count, 1)
    XCTAssertTrue(gate.isDrawing)
    XCTAssertEqual(gate.holdRecognized(), .ignore, "and can never be interrupted by a hold")
  }

  func testAHoldWithNoTouchOfItsOwnStillSummons() {
    var gate = RemoteDrawHoldGate()
    XCTAssertEqual(gate.holdRecognized(), .summon)
  }
}

final class PuckPreferenceMemoryTests: XCTestCase {
  func testWidthIsRememberedPerTipAndColourIsNot() {
    var raw = ""
    raw = RemoteDrawPreferences.rememberingThickness(12, for: .pencil, in: raw)
    raw = RemoteDrawPreferences.rememberingThickness(3, for: .fineliner, in: raw)

    XCTAssertEqual(RemoteDrawPreferences.thickness(for: .pencil, in: raw, fallback: 6), 12)
    XCTAssertEqual(RemoteDrawPreferences.thickness(for: .fineliner, in: raw, fallback: 6), 3)
    XCTAssertEqual(
      RemoteDrawPreferences.thickness(for: .charcoal, in: raw, fallback: 6), 6,
      "an instrument nobody has used yet keeps the current width")
  }

  func testRememberedWidthsAreClampedToWhatTheWireAccepts() {
    let raw = RemoteDrawPreferences.rememberingThickness(9_999, for: .chalk, in: "")
    XCTAssertEqual(RemoteDrawPreferences.thickness(for: .chalk, in: raw, fallback: 6), 48)
    let low = RemoteDrawPreferences.rememberingThickness(0, for: .chalk, in: raw)
    XCTAssertEqual(RemoteDrawPreferences.thickness(for: .chalk, in: low, fallback: 6), 1)
  }

  func testCorruptedMemoryFallsBackInsteadOfThrowing() {
    XCTAssertTrue(RemoteDrawPreferences.decodeThicknessMemory("not json").isEmpty)
    XCTAssertEqual(
      RemoteDrawPreferences.thickness(for: .ink, in: "{{{", fallback: 7), 7)
  }

  func testMemorySurvivesARoundTrip() {
    let raw = RemoteDrawPreferences.encodeThicknessMemory(["pencil": 5, "ink": 2])
    XCTAssertEqual(
      RemoteDrawPreferences.decodeThicknessMemory(raw), ["pencil": 5, "ink": 2])
  }
}
