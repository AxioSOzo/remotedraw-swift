import Foundation

/// Calibrated attitude controls a portal like an aiming pointer, never by
/// integrating acceleration into an invented physical position.
public struct RemoteDrawPhoneMotionPose: Equatable, Sendable {
  /// Optional motion is capped separately from ink: at most 36,000 projection
  /// publications per continuously moving hour, before transport coalescing.
  public static let updateInterval: TimeInterval = 0.1
  public let centerX: Double
  public let centerY: Double
  public let tiltXDegrees: Double
  public let tiltYDegrees: Double

  public static func relative(
    yawRadians: Double, pitchRadians: Double, rollRadians: Double,
    origin: RemoteDrawProjection, screenRotationDegrees: Double = 0
  ) -> Self? {
    guard [yawRadians, pitchRadians, rollRadians, screenRotationDegrees,
      origin.centerX, origin.centerY, origin.width, origin.height,
      origin.tiltXDegrees ?? 0, origin.tiltYDegrees ?? 0].allSatisfy(\.isFinite),
      origin.width > 0, origin.height > 0 else { return nil }
    func bounded(_ value: Double, _ limit: Double) -> Double { min(limit, max(-limit, value)) }
    let degrees = 180 / Double.pi
    let angle = screenRotationDegrees * .pi / 180
    let yaw = bounded(yawRadians * degrees, 30)
    let pitch = bounded(pitchRadians * degrees, 30)
    let aimX = yaw * cos(angle) - pitch * sin(angle)
    let aimY = yaw * sin(angle) + pitch * cos(angle)
    // Match the API's half-board center margin, including neutral calibration
    // after a valid off-board touch or receiver pan.
    return Self(
      centerX: min(1.5, max(-0.5, origin.centerX + bounded(aimX / 30, 1) * origin.width * 1.5)),
      centerY: min(1.5, max(-0.5, origin.centerY - bounded(aimY / 30, 1) * origin.height * 1.5)),
      tiltXDegrees: bounded((origin.tiltXDegrees ?? 0) + pitchRadians * degrees, 45),
      tiltYDegrees: bounded((origin.tiltYDegrees ?? 0) + rollRadians * degrees, 45)
    )
  }

  public func meaningfullyDiffers(from previous: Self) -> Bool {
    abs(centerX - previous.centerX) >= 0.001 || abs(centerY - previous.centerY) >= 0.001
      || abs(tiltXDegrees - previous.tiltXDegrees) >= 0.35
      || abs(tiltYDegrees - previous.tiltYDegrees) >= 0.35
  }
}
