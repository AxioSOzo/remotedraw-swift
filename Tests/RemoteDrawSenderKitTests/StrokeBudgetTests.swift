import XCTest

@testable import RemoteDrawSenderKit

/// `thinStrokeForBudget` and `draftPointsForTransport`, which exist in
/// TypeScript (`packages/client/src/strokeTransport.ts`) and here.
///
/// The rule both encode: **keep the head, decimate the middle, send the tail
/// verbatim**. Every naive alternative loses something a receiver cannot get
/// back — a plain `suffix` discards where the stroke began, and stopping at the
/// cap makes a long stroke quit following the pen mid-draw while the hand is
/// still moving.
final class StrokeBudgetTests: XCTestCase {
  private func stroke(_ count: Int) -> [Int] { Array(0..<count) }

  // MARK: - Draft

  func testAStrokeUnderTheDraftBudgetIsSentWhole() {
    XCTAssertEqual(RemoteDrawStrokeBudget.forDraft(stroke(50), limit: 180), stroke(50))
    XCTAssertEqual(RemoteDrawStrokeBudget.forDraft(stroke(180), limit: 180), stroke(180))
  }

  func testADraftKeepsItsOriginItsEndAndFitsTheBudget() {
    let thinned = RemoteDrawStrokeBudget.forDraft(stroke(1000), limit: 180)
    XCTAssertLessThanOrEqual(thinned.count, 180)
    XCTAssertEqual(thinned.first, 0, "the origin is the one point a receiver can never infer")
    XCTAssertEqual(thinned.last, 999)
  }

  func testADraftsTailIsVerbatim() {
    // The moving end of the stroke is where the finger actually is, so it keeps
    // full fidelity; only the settled head is decimated.
    let thinned = RemoteDrawStrokeBudget.forDraft(stroke(1000), limit: 180)
    let tail = Array(thinned.suffix(90))
    XCTAssertEqual(tail, Array(910..<1000))
  }

  func testADraftIsMonotonicWithNoRepeats() {
    // Even spacing computed by rounding can land twice on the same index; a
    // repeated sample is a zero-length segment the renderer has to special-case.
    let thinned = RemoteDrawStrokeBudget.forDraft(stroke(217), limit: 180)
    XCTAssertEqual(thinned, thinned.sorted())
    XCTAssertEqual(Set(thinned).count, thinned.count)
  }

  func testAZeroDraftBudgetSendsNothingRatherThanEverything() {
    XCTAssertTrue(RemoteDrawStrokeBudget.forDraft(stroke(50), limit: 0).isEmpty)
  }

  /// Inherited from `apps/ios/RemoteDrawTests/DraftTransportTests.swift`, which
  /// this file replaces.
  ///
  /// The sweep matters because the head budget is computed by rounding across
  /// the settled samples: a length that lands two steps on the same index
  /// returns *fewer* points than the budget, and a length just past the cap
  /// exercises a one-sample head. Testing a single long stroke checks neither.
  func testNoStrokeLengthEverExceedsTheDraftBudget() {
    for count in [181, 217, 250, 400, 437, 500, 1000] {
      let thinned = RemoteDrawStrokeBudget.forDraft(stroke(count), limit: 180)
      XCTAssertLessThanOrEqual(thinned.count, 180, "\(count) points")
      XCTAssertEqual(thinned.first, 0, "\(count) points lost its origin")
      XCTAssertEqual(thinned.last, count - 1, "\(count) points lost its newest sample")
      XCTAssertEqual(thinned, thinned.sorted(), "\(count) points came back out of order")
      XCTAssertEqual(Set(thinned).count, thinned.count, "\(count) points repeated a sample")
    }
  }

  /// A budget of one or two cannot hold a decimated head *and* a tail. Both
  /// answers have to be exact rather than merely bounded: the tail is
  /// `max(1, limit * 0.5)`, so a budget of 1 spends everything on the tail and
  /// a budget of 2 spends one sample on each end.
  func testTinyDraftBudgetsAreExactRatherThanApproximate() {
    XCTAssertEqual(RemoteDrawStrokeBudget.forDraft(stroke(10), limit: 1), [9])
    XCTAssertEqual(RemoteDrawStrokeBudget.forDraft(stroke(10), limit: 2), [0, 9])
  }

  // MARK: - Commit

  func testThinningLeavesAStrokeUnderTheCapSoAppendingDoesNotReThinEveryFrame() {
    let thinned = RemoteDrawStrokeBudget.thin(stroke(1200), limit: 1200)
    XCTAssertLessThan(thinned.count, 1200)
    XCTAssertEqual(thinned.first, 0)
    XCTAssertEqual(thinned.last, 1199)
  }

  func testAVeryLongStrokeIsThinnedRepeatedlyUntilItActuallyFits() {
    // One pass halves the head, which is enough when a sender thins at the cap.
    // An SDK takes whatever the host app collected, so it can be handed a stroke
    // several passes too long.
    let thinned = RemoteDrawStrokeBudget.thin(stroke(40_000), limit: 1200)
    XCTAssertLessThan(thinned.count, 1200)
    XCTAssertEqual(thinned.first, 0)
    XCTAssertEqual(thinned.last, 39_999)
  }

  func testThinningNeverTouchesTheTail() {
    let thinned = RemoteDrawStrokeBudget.thin(stroke(5000), limit: 1200)
    XCTAssertEqual(Array(thinned.suffix(600)), Array(4400..<5000))
  }

  func testADegenerateBudgetIsRefusedRatherThanLooping() {
    // limit <= 2 cannot hold a head and a tail; returning the input is the only
    // answer that terminates.
    XCTAssertEqual(RemoteDrawStrokeBudget.thin(stroke(10), limit: 2), stroke(10))
    XCTAssertEqual(RemoteDrawStrokeBudget.thin(stroke(10), limit: 0), stroke(10))
  }

  // MARK: - Applied at the boundary

  func testRequestsApplyTheirOwnBudgetSoACallerCannotOverspend() throws {
    let overlong = (0..<5000).map {
      RemoteDrawNormalizedPoint(x: Double($0 % 100) / 100, y: 0.5, t: Double($0))
    }
    let draft = RemoteDrawDraftRequest(senderToken: "t", sequence: 1, points: overlong)
    let commit = RemoteDrawCommitRequest(
      senderToken: "t", clientStrokeId: "c", sequence: 2, points: overlong)

    XCTAssertLessThanOrEqual(
      try PointCodec.unpack(draft.packedPoints).count, RemoteDrawProtocolLimits.maxDraftPoints)
    XCTAssertLessThan(
      try PointCodec.unpack(commit.packedPoints).count, RemoteDrawProtocolLimits.maxCommitPoints)
  }

  func testWorstCasePayloadsStayInsideTheServersByteCeilings() throws {
    // The point caps and the byte caps are separate limits and a stroke can
    // satisfy one while blowing the other: six channels of high-entropy data
    // defeat delta coding, which is the case worth measuring.
    let hostile = (0..<RemoteDrawProtocolLimits.maxCommitPoints).map { index -> RemoteDrawNormalizedPoint in
      let i = Double(index)
      return RemoteDrawNormalizedPoint(
        x: index % 2 == 0 ? 0 : 1, y: index % 3 == 0 ? 0 : 1, t: i * 997,
        pressure: index % 2 == 0 ? 0 : 1, tiltX: index % 2 == 0 ? -90 : 90,
        tiltY: index % 2 == 0 ? 90 : -90)
    }
    let commit = RemoteDrawCommitRequest(
      senderToken: String(repeating: "t", count: 64), clientStrokeId: "c", sequence: 1,
      points: hostile)
    let body = try JSONEncoder().encode(commit)
    XCTAssertLessThanOrEqual(body.count, RemoteDrawProtocolLimits.maxCommitPayloadBytes)

    let draft = RemoteDrawDraftRequest(
      senderToken: String(repeating: "t", count: 64), sequence: 1, points: hostile)
    XCTAssertLessThanOrEqual(
      try JSONEncoder().encode(draft).count, RemoteDrawProtocolLimits.maxDraftPayloadBytes)
  }

  func testTheCadenceConstantsAreTheOnesTheProtocolPins() {
    // Pinned here as well as in scripts/performance-budgets.ts, because a
    // customer who can raise the draft rate can get their own tenant
    // rate-limited, and these are the numbers that stop that.
    XCTAssertEqual(RemoteDrawProtocolLimits.draftSendInterval, 0.032)
    XCTAssertEqual(RemoteDrawProtocolLimits.projectionSyncInterval, 0.045)
    XCTAssertEqual(RemoteDrawProtocolLimits.presenceInterval, 5)
    XCTAssertEqual(RemoteDrawProtocolLimits.maxDraftPoints, 180)
    XCTAssertEqual(RemoteDrawProtocolLimits.maxCommitPoints, 1200)
  }
}
