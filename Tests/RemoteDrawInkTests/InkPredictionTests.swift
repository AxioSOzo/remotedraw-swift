//
//  Moved here from `apps/ios/RemoteDrawTests/` by Stage 2.
//
//  These are the renderer's tests, not the app's: they reach `InkRenderer`,
//  `RemoteDrawInk` and `RemoteDrawInkSurface` internals, which the app can no
//  longer see now that it imports the module instead of compiling its source.
//  The right home for a test that needs a target's internals is that target's
//  own test bundle — and `swift test` runs them in two seconds on macOS with no
//  simulator, which is a better place for a parity check than an app build.
//
import XCTest
@testable import RemoteDrawInk

/// Preview prediction, which is the same function on both senders and has to
/// stay that way.
///
/// `packages/client/tests/inkGeometry.test.ts` pins the identical cases against
/// `previewPointsWithPrediction`; these are the Swift half of that parity, in
/// the same vector-per-vector style the point codec uses. The two senders draw
/// the same ink from the same hand, so they must run ahead of it by the same
/// amount and clamp a bad guess the same way.
final class InkPredictionTests: XCTestCase {
  private let committed = [
    NormalizedPoint(x: 0, y: 0),
    NormalizedPoint(x: 10, y: 0),
    NormalizedPoint(x: 20, y: 0),
  ]

  func testAppendsAtMostTwoPredictedSamplesWithoutMutatingTheInput() {
    let predicted = [
      NormalizedPoint(x: 30, y: 0),
      NormalizedPoint(x: 40, y: 0),
      NormalizedPoint(x: 50, y: 0),
    ]
    let preview = InkRenderer.previewPointsWithPrediction(committed, predicted: predicted)
    XCTAssertEqual(preview.count, 5)
    XCTAssertEqual(preview[3].x, 30, accuracy: 1e-9)
    XCTAssertEqual(preview[4].x, 40, accuracy: 1e-9)
    XCTAssertEqual(committed.count, 3)
  }

  /// The clamp is what makes prediction safe to ship: a predictor that guesses
  /// wildly can only ever be wrong by twice the distance the finger just
  /// covered, so the ink cannot shoot off across the board and snap back.
  func testClampsAWildPredictionToTwiceTheLastRealSegment() {
    let preview = InkRenderer.previewPointsWithPrediction(
      committed,
      predicted: [NormalizedPoint(x: 220, y: 0)]
    )
    // Last real segment is 10 units, so the predicted step caps at 20.
    XCTAssertEqual(preview[3].x, 40, accuracy: 1e-9)
  }

  func testNoPredictionsOrTooFewRealPointsIsANoOpCopy() {
    XCTAssertEqual(
      InkRenderer.previewPointsWithPrediction(committed, predicted: []),
      committed
    )
    let single = [NormalizedPoint(x: 1, y: 1)]
    XCTAssertEqual(
      InkRenderer.previewPointsWithPrediction(
        single,
        predicted: [NormalizedPoint(x: 2, y: 2)]
      ),
      single
    )
  }

  /// A stationary finger has no direction to run ahead in, and dividing by that
  /// zero would put a NaN into the ribbon.
  func testAStrokeThatHasNotMovedPredictsNothing() {
    let still = [NormalizedPoint(x: 5, y: 5), NormalizedPoint(x: 5, y: 5)]
    XCTAssertEqual(
      InkRenderer.previewPointsWithPrediction(
        still,
        predicted: [NormalizedPoint(x: 9, y: 9)]
      ),
      still
    )
  }

  /// Each predicted step is measured from the *previous predicted* point, not
  /// from the last real one, so two samples ahead cannot compound into four
  /// segments of overshoot.
  func testTheSecondPredictedStepIsClampedAgainstTheFirst() {
    let preview = InkRenderer.previewPointsWithPrediction(
      committed,
      predicted: [NormalizedPoint(x: 25, y: 0), NormalizedPoint(x: 300, y: 0)]
    )
    XCTAssertEqual(preview[3].x, 25, accuracy: 1e-9)
    XCTAssertEqual(preview[4].x, 45, accuracy: 1e-9)
  }

  /// Predicted samples carry no dynamics of their own: whatever the caller
  /// hands in is what comes back, so the board never invents a pressure.
  func testPredictedSamplesKeepTheDynamicsTheyWereGiven() {
    let preview = InkRenderer.previewPointsWithPrediction(
      committed,
      predicted: [NormalizedPoint(x: 30, y: 0, t: 1234, pressure: 0.42)]
    )
    XCTAssertEqual(preview[3].t, 1234)
    XCTAssertEqual(preview[3].pressure, 0.42)
  }
}
