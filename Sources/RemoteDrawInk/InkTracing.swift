import Foundation
import OSLog

/// The two tracing helpers `InkRenderer.swift` calls. They were first supplied
/// so that file could stay a byte-identical copy of the iOS app's; the app's
/// copy is gone and `RemoteDrawInk` is the sole source of truth, but the
/// renderer still only needs this small shape.
///
/// The app's versions (`apps/ios/RemoteDraw/Diagnostics.swift`) do more — a
/// once-only marker, a hang monitor, an uptime-relative clock shared across the
/// whole app. The renderer only ever uses `mark` and `measure`, so only those
/// are here. Anything richer belongs in the app, not in a package that other
/// people's code links against.
enum RDLog {
  static let subsystem = "com.remotedraw.kit"
  static let render = Logger(subsystem: subsystem, category: "render")
}

enum RDTrace {
  static func mark(_ logger: Logger, _ message: String) {
    logger.debug("\(message, privacy: .public)")
  }

  /// Runs `body` and reports how long it took in milliseconds.
  static func measure<T>(_ body: () throws -> T) rethrows -> (value: T, milliseconds: Double) {
    let started = DispatchTime.now().uptimeNanoseconds
    let value = try body()
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    return (value, Double(elapsed) / 1_000_000)
  }
}
