import CoreGraphics
import XCTest

@testable import RemoteDrawSenderKit

/// The parts of the capture layer that are pure functions.
///
/// The `UITouch` plumbing itself needs a device; these are the conversions it
/// performs, and they are where the interesting mistakes live — a sender that
/// reports no tilt, or a geometry that is right only at the centre of the
/// screen, produces ink that visibly differs from every other client on the
/// same board.
final class CaptureTests: XCTestCase {
  // MARK: - Tilt

  func testAnUprightStylusHasNoTilt() {
    let tilt = RemoteDrawPencilTilt.tilt(azimuthRadians: 1.2, altitudeRadians: .pi / 2)
    XCTAssertEqual(tilt.tiltX, 0, accuracy: 0.001)
    XCTAssertEqual(tilt.tiltY, 0, accuracy: 0.001)
  }

  func testTiltSeparatesTheTwoAxesTheWayPointerEventsDoes() {
    // Laid over along +x at 45 degrees: all of the tilt is on tiltX.
    let alongX = RemoteDrawPencilTilt.tilt(azimuthRadians: 0, altitudeRadians: .pi / 4)
    XCTAssertEqual(alongX.tiltX, 45, accuracy: 0.001)
    XCTAssertEqual(alongX.tiltY, 0, accuracy: 0.001)

    let alongY = RemoteDrawPencilTilt.tilt(azimuthRadians: .pi / 2, altitudeRadians: .pi / 4)
    XCTAssertEqual(alongY.tiltX, 0, accuracy: 0.001)
    XCTAssertEqual(alongY.tiltY, 45, accuracy: 0.001)

    let negativeX = RemoteDrawPencilTilt.tilt(azimuthRadians: .pi, altitudeRadians: .pi / 4)
    XCTAssertEqual(negativeX.tiltX, -45, accuracy: 0.001)
  }

  func testAFlatStylusDoesNotDivideByZero() {
    // altitude 0 is the pencil flat on the glass. The clamp is what stops
    // tan(0) taking the conversion to infinity, and an infinite tilt would take
    // the codec's Int32 conversion with it.
    let tilt = RemoteDrawPencilTilt.tilt(azimuthRadians: 0, altitudeRadians: 0)
    XCTAssertTrue(tilt.tiltX.isFinite)
    XCTAssertTrue(tilt.tiltY.isFinite)
    XCTAssertEqual(tilt.tiltX, 90, accuracy: 0.01)
  }

  func testTiltStaysInsideTheRangeTheCodecQuantises() {
    for azimuthStep in 0..<32 {
      for altitudeStep in 0...16 {
        let tilt = RemoteDrawPencilTilt.tilt(
          azimuthRadians: Double(azimuthStep) * .pi / 16,
          altitudeRadians: Double(altitudeStep) * .pi / 32)
        XCTAssertTrue((-90...90).contains(tilt.tiltX), "tiltX \(tilt.tiltX)")
        XCTAssertTrue((-90...90).contains(tilt.tiltY), "tiltY \(tilt.tiltY)")
      }
    }
  }

  // MARK: - Palm

  func testPalmClassificationIsBiasedTowardKeepingRealStrokes() {
    // A false positive loses a stroke; a false negative leaves a stray mark that
    // undo can remove. The threshold is set accordingly.
    XCTAssertFalse(RemoteDrawTouchClassifier.isPalm(majorRadius: 12))
    XCTAssertFalse(RemoteDrawTouchClassifier.isPalm(majorRadius: 35))
    XCTAssertFalse(
      RemoteDrawTouchClassifier.isPalm(
        majorRadius: RemoteDrawTouchClassifier.palmRadiusThreshold - 1))
    XCTAssertTrue(
      RemoteDrawTouchClassifier.isPalm(majorRadius: RemoteDrawTouchClassifier.palmRadiusThreshold))
    XCTAssertTrue(RemoteDrawTouchClassifier.isPalm(majorRadius: 80))
  }

  // MARK: - Geometry

  func testNormalizationRoundTrips() {
    let size = CGSize(width: 390, height: 844)
    let point = CGPoint(x: 123, y: 456)
    let normalized = RemoteDrawSurfaceGeometry.normalized(point, in: size)
    let back = RemoteDrawSurfaceGeometry.surfacePoint(normalized, in: size)
    XCTAssertEqual(back.x, point.x, accuracy: 0.0001)
    XCTAssertEqual(back.y, point.y, accuracy: 0.0001)
  }

  func testADegenerateSizeYieldsTheOriginRatherThanInfinity() {
    // A layout pass before the view has a size is not exotic, and a divide by
    // zero here would put an infinity into a channel the codec converts to
    // Int32 — which traps.
    XCTAssertEqual(RemoteDrawSurfaceGeometry.normalized(CGPoint(x: 5, y: 5), in: .zero), .zero)
    XCTAssertFalse(RemoteDrawSurfaceGeometry.isUsable(CGSize(width: 0, height: 100)))
    XCTAssertFalse(
      RemoteDrawSurfaceGeometry.isUsable(CGSize(width: CGFloat.nan, height: 100)))
  }

  func testClampEatsNaNDeliberatelyRatherThanByAccident() {
    // `min(1, max(0, .nan))` returns 0 because every comparison against NaN is
    // false. That accident is the only reason the first-party app never hit the
    // codec's NaN trap; an SDK cannot rely on an accident in somebody else's
    // capture code, so this is explicit.
    XCTAssertEqual(RemoteDrawSurfaceGeometry.clamp01(.nan), 0)
    XCTAssertEqual(RemoteDrawSurfaceGeometry.clamp01(.infinity), 0)
    XCTAssertEqual(RemoteDrawSurfaceGeometry.clamp01(-5), 0)
    XCTAssertEqual(RemoteDrawSurfaceGeometry.clamp01(5), 1)
    XCTAssertEqual(RemoteDrawSurfaceGeometry.clamp01(0.25), 0.25)
  }

  // MARK: - Clock

  func testTheInkClockIsLaunchRelativeAndMonotonic() {
    // Both a correctness constraint (the codec quantises `t` into an Int32,
    // whose ceiling an epoch timestamp blows past) and a privacy one: required
    // reason 35F9.1 permits transmitting elapsed time between in-app events and
    // nothing else derived from boot time.
    let first = RemoteDrawInkClock.milliseconds
    let second = RemoteDrawInkClock.milliseconds
    XCTAssertGreaterThanOrEqual(second, first)
    XCTAssertLessThan(
      second, 2_147_483_647,
      "a `t` past the Int32 ceiling is the value that killed the app on first touch")
    XCTAssertLessThan(second, 60 * 60 * 1000, "launch-relative, not boot-relative")
  }

  // MARK: - Device

  func testAnAnonymousDeviceSendsGeometryAndNoIdentifier() throws {
    // The receiver needs the geometry to place the viewport; it does not need to
    // know whose phone it is. This is the difference between a linked and an
    // unlinked data type in the host app's privacy report.
    let device = RemoteDrawSenderDevice.anonymous(aspectRatio: 0.46)
    let json =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any]
    XCTAssertNil(json?["deviceId"], "an omitted key is what makes the declaration honest")
    XCTAssertNil(json?["displayName"])
    XCTAssertNil(json?["modelIdentifier"])
    XCTAssertEqual(json?["aspectRatio"] as? Double, 0.46)
    XCTAssertEqual(json?["platform"] as? String, "ios")
  }
}
