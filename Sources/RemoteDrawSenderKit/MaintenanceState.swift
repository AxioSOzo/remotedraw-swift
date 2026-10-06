import Foundation

/// Synchronization health is independent of whether the last stroke succeeded.
/// The deadline uses the session's monotonic poll clock, never wall-clock time.
public enum RemoteDrawMaintenanceState: Equatable, Sendable {
  case checking
  case current
  case paused(String)
  case retryLater(until: TimeInterval, message: String)
  case capacityExhausted(String)
  case ended

  public var issue: String? {
    switch self {
    case .paused(let message), .capacityExhausted(let message), .retryLater(_, let message):
      return message
    case .checking, .current, .ended: return nil
    }
  }
}
