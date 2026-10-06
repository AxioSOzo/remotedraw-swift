import XCTest
@testable import RemoteDrawSenderKit

final class PhoneMotionTests: XCTestCase {
  private let origin = RemoteDrawProjection(centerX: 0.5, centerY: 0.5,
    width: 0.1, height: 0.2, aspectRatio: 0.5)

  func testNeutralRecenterAndBoundedAim() throws {
    let zero = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0,
      pitchRadians: 0, rollRadians: 0, origin: origin))
    XCTAssertEqual(zero.centerX, origin.centerX)
    XCTAssertEqual(zero.centerY, origin.centerY)
    XCTAssertEqual(zero.tiltXDegrees, 0)
    let pose = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: .pi,
      pitchRadians: .pi, rollRadians: -.pi, origin: origin))
    XCTAssertEqual(pose.centerX, 0.65, accuracy: 1e-9)
    XCTAssertEqual(pose.centerY, 0.2, accuracy: 1e-9)
    XCTAssertEqual(pose.tiltXDegrees, 45)
    XCTAssertEqual(pose.tiltYDegrees, -45)
  }

  func testLandscapeRotatesAimButNotPhysicalTiltAxes() throws {
    let pose = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: .pi / 6,
      pitchRadians: 0, rollRadians: .pi / 12, origin: origin, screenRotationDegrees: 90))
    XCTAssertEqual(pose.centerX, 0.5, accuracy: 1e-9)
    XCTAssertEqual(pose.centerY, 0.2, accuracy: 1e-9)
    XCTAssertEqual(pose.tiltYDegrees, 15, accuracy: 1e-9)
  }

  func testInvalidSamplesRejectedAndSensorNoiseSuppressed() throws {
    XCTAssertNil(RemoteDrawPhoneMotionPose.relative(yawRadians: .nan,
      pitchRadians: 0, rollRadians: 0, origin: origin))
    let zero = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0,
      pitchRadians: 0, rollRadians: 0, origin: origin))
    let noise = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0.0001,
      pitchRadians: 0.0001, rollRadians: 0.0001, origin: origin))
    XCTAssertFalse(noise.meaningfullyDiffers(from: zero))
  }

  func testWireRoundTripPreservesTiltAndOldPayloadIsNeutral() throws {
    let value = RemoteDrawProjection(centerX: 0.5, centerY: 0.5, width: 0.1,
      height: 0.2, tiltXDegrees: 12, tiltYDegrees: -8, aspectRatio: 0.5)
    XCTAssertEqual(try JSONDecoder().decode(RemoteDrawProjection.self,
      from: JSONEncoder().encode(value)), value)
    XCTAssertNil(origin.tiltXDegrees)
    XCTAssertNil(origin.tiltYDegrees)
  }

  func testResumePreservesCurrentTiltUntilRecenter() throws {
    let tilted = RemoteDrawProjection(centerX: 0.6, centerY: 0.4, width: 0.1,
      height: 0.2, tiltXDegrees: 15, tiltYDegrees: -10, aspectRatio: 0.5)
    let resumed = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0,
      pitchRadians: 0, rollRadians: 0, origin: tilted))
    XCTAssertEqual(resumed.centerX, tilted.centerX)
    XCTAssertEqual(resumed.centerY, tilted.centerY)
    XCTAssertEqual(resumed.tiltXDegrees, 15)
    XCTAssertEqual(resumed.tiltYDegrees, -10)
    let moved = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0,
      pitchRadians: .pi / 18, rollRadians: .pi / 18, origin: tilted))
    XCTAssertEqual(moved.tiltXDegrees, 25, accuracy: 1e-9)
    XCTAssertEqual(moved.tiltYDegrees, 0, accuracy: 1e-9)
  }

  func testMotionPublicationBudgetDoesNotChangeInkTransport() {
    XCTAssertEqual(RemoteDrawPhoneMotionPose.updateInterval, 0.1)
    XCTAssertEqual(RemoteDrawProtocolLimits.projectionSyncInterval, 0.045)
  }

  func testOffBoardPanRemainsNeutralAndAimUsesAPICenterMargin() throws {
    for (centerX, centerY) in [(-0.1, 1.1), (1.1, -0.1), (-0.5, 1.5), (1.5, -0.5)] {
      let panned = RemoteDrawProjection(centerX: centerX, centerY: centerY,
        width: 0.2, height: 0.4, tiltXDegrees: 8, tiltYDegrees: -6, aspectRatio: 0.5)
      let neutral = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: 0,
        pitchRadians: 0, rollRadians: 0, origin: panned))
      XCTAssertEqual(neutral.centerX, centerX)
      XCTAssertEqual(neutral.centerY, centerY)
      XCTAssertEqual(neutral.tiltXDegrees, 8)
      XCTAssertEqual(neutral.tiltYDegrees, -6)
    }
    let nearEdge = RemoteDrawProjection(centerX: 1.4, centerY: -0.4,
      width: 0.2, height: 0.4, aspectRatio: 0.5)
    let moved = try XCTUnwrap(RemoteDrawPhoneMotionPose.relative(yawRadians: .pi / 6,
      pitchRadians: .pi / 6, rollRadians: 0, origin: nearEdge))
    XCTAssertEqual(moved.centerX, 1.5)
    XCTAssertEqual(moved.centerY, -0.5)
  }
}
