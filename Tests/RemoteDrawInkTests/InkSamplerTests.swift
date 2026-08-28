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

/// The sampler decides which digitizer samples become stroke geometry, and it
/// runs on every sender. `packages/client/tests/strokeFeel.test.ts` pins the
/// identical cases; a stroke drawn on the app and the same stroke drawn on the
/// web must survive decimation the same way, or the two senders produce
/// different ink from the same hand.
final class InkSamplerTests: XCTestCase {
  private func point(_ x: Double, _ y: Double, pressure: Double? = nil) -> NormalizedPoint {
    NormalizedPoint(x: x, y: y, pressure: pressure)
  }

  func testAlwaysKeepsTheFirstPoint() {
    XCTAssertTrue(InkRenderer.shouldAppendSample([], candidate: point(0.5, 0.5)))
  }

  func testDropsSamplesCloserThanTheMinimumSpacing() {
    XCTAssertFalse(
      InkRenderer.shouldAppendSample([point(0.5, 0.5)], candidate: point(0.5005, 0.5))
    )
  }

  func testKeepsSamplesPastTheFlatSpacingThreshold() {
    XCTAssertTrue(
      InkRenderer.shouldAppendSample([point(0.5, 0.5)], candidate: point(0.506, 0.5))
    )
  }

  func testDropsNearSamplesThatContinueAStraightLine() {
    XCTAssertFalse(
      InkRenderer.shouldAppendSample(
        [point(0.5, 0.5), point(0.504, 0.5)],
        candidate: point(0.506, 0.5)
      )
    )
  }

  func testKeepsNearSamplesWhereTheStrokeTurns() {
    XCTAssertTrue(
      InkRenderer.shouldAppendSample(
        [point(0.5, 0.5), point(0.504, 0.5)],
        candidate: point(0.506, 0.502)
      )
    )
  }

  /// The geometry tests are blind to the nib: a pen landing or lifting ramps
  /// through most of its pressure range in ~40ms while barely moving, and every
  /// sample carrying that ramp used to be dropped as "a straight line".
  func testKeepsANearSampleWhereOnlyThePressureMoves() {
    let straight = [point(0.5, 0.5, pressure: 0.2), point(0.502, 0.5, pressure: 0.2)]
    XCTAssertFalse(
      InkRenderer.shouldAppendSample(straight, candidate: point(0.504, 0.5, pressure: 0.2))
    )
    XCTAssertTrue(
      InkRenderer.shouldAppendSample(straight, candidate: point(0.504, 0.5, pressure: 0.26))
    )
  }

  func testIgnoresPressureDriftBelowTheThreshold() {
    XCTAssertFalse(
      InkRenderer.shouldAppendSample(
        [point(0.5, 0.5, pressure: 0.4), point(0.502, 0.5, pressure: 0.4)],
        candidate: point(0.504, 0.5, pressure: 0.405)
      )
    )
  }

  /// A resting hand on a jittering sensor must not stream samples: the distance
  /// rejection runs first, so the pressure test never sees this.
  func testNeverLetsPressureAloneDefeatTheMinimumSpacing() {
    XCTAssertFalse(
      InkRenderer.shouldAppendSample(
        [point(0.5, 0.5, pressure: 0.1)],
        candidate: point(0.5001, 0.5, pressure: 0.9)
      )
    )
  }

  /// A finger carries no pressure; the sampler must behave exactly as it did
  /// before the gate existed.
  func testFallsBackToGeometryWhenADeviceReportsNoPressure() {
    XCTAssertFalse(
      InkRenderer.shouldAppendSample(
        [point(0.5, 0.5), point(0.502, 0.5)],
        candidate: point(0.504, 0.5)
      )
    )
  }

  /// 0.0012 normalized is ~0.3mm of glass. The previous 0.0015 floor rejected
  /// this sample outright.
  func testResolvesDetailFinerThanTheOldSamplerCould() {
    XCTAssertTrue(
      InkRenderer.shouldAppendSample([point(0.5, 0.5)], candidate: point(0.5013, 0.5))
    )
  }
}
