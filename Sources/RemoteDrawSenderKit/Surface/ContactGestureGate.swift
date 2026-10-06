import CoreGraphics
import Foundation

public enum RemoteDrawContactAction: Equatable {
  case undo
  case controls
}

/// Certifies shortcuts from a complete physical contact sequence. Camera
/// changes are deliberately irrelevant: pinching at a zoom limit is still a
/// pinch. The latch survives UIKit resets and staggered finger lifts.
public struct RemoteDrawContactGestureGate {
  public static let contactTravelLimit: CGFloat = 6
  public static let pairDistanceLimit: CGFloat = 4
  public static let centroidLimit: CGFloat = 4
  public static let durationLimit: TimeInterval = 0.3

  private struct Contact {
    let start: CGPoint
    var last: CGPoint
  }
  private var contacts: [Int: Contact] = [:]
  private var seen: Set<Int> = []
  private var startTime: TimeInterval = 0
  private var poisoned = false
  private var hasLifted = false
  private var maximumContacts = 0
  private var holdClaimed = false

  public init() {}
  public var hasLiveContacts: Bool { !contacts.isEmpty }
  public var navigationLatched: Bool { poisoned && hasLiveContacts }
  /// Idle permits installing a recognizer for the next touch. Once a second
  /// contact has landed, a trailing stationary finger cannot summon controls.
  public var allowsLongPress: Bool {
    !hasLiveContacts || (!poisoned && maximumContacts == 1 && seen.count == 1)
  }

  public mutating func began(contact: Int, position: CGPoint,
    timestamp: TimeInterval, isPencilLike: Bool = false) {
    if contacts.isEmpty {
      seen = []
      startTime = timestamp
      poisoned = false
      hasLifted = false
      maximumContacts = 0
      holdClaimed = false
    }
    if holdClaimed { invalidate() }
    guard contacts[contact] == nil else { invalidate(); return }
    if hasLifted || seen.contains(contact) || isPencilLike || !finite(position) || !timestamp.isFinite {
      invalidate()
    }
    seen.insert(contact)
    contacts[contact] = Contact(start: position, last: position)
    maximumContacts = max(maximumContacts, contacts.count)
    if seen.count > 3 { invalidate() }
  }

  public mutating func moved(contact: Int, position: CGPoint, timestamp: TimeInterval) {
    guard var value = contacts[contact] else { return }
    value.last = position
    contacts[contact] = value
    // Once a hold opened the dial, its one finger is meant to slide between
    // choices. Only additional contacts or cancellation can take it away.
    if holdClaimed && finite(position) && timestamp.isFinite { return }
    if !finite(position) || !timestamp.isFinite || timestamp < startTime ||
      distance(value.start, position) > Self.contactTravelLimit {
      invalidate()
    }
    // Compare every pair, including the three-finger shortcut. Per-finger
    // travel alone misses small opposing movements that are plainly a pinch.
    let values = Array(contacts.values)
    for i in values.indices {
      for j in values.indices where j > i {
        let a = values[i], b = values[j]
        let startCenter = CGPoint(x: (a.start.x + b.start.x) / 2, y: (a.start.y + b.start.y) / 2)
        let center = CGPoint(x: (a.last.x + b.last.x) / 2, y: (a.last.y + b.last.y) / 2)
        if abs(distance(a.last, b.last) - distance(a.start, b.start)) > Self.pairDistanceLimit ||
          distance(startCenter, center) > Self.centroidLimit { invalidate() }
      }
    }
  }

  public mutating func ended(contact: Int, position: CGPoint, timestamp: TimeInterval) -> RemoteDrawContactAction? {
    guard contacts[contact] != nil else { return nil }
    moved(contact: contact, position: position, timestamp: timestamp)
    contacts.removeValue(forKey: contact)
    hasLifted = true
    guard contacts.isEmpty else { return nil }
    let duration = timestamp - startTime
    guard !poisoned, duration.isFinite, duration >= 0, duration <= Self.durationLimit,
      maximumContacts == seen.count else { return nil }
    switch seen.count {
    case 2: return .undo
    case 3: return .controls
    default: return nil
    }
  }

  public mutating func cancelled(contact: Int) {
    guard contacts.removeValue(forKey: contact) != nil else { return }
    hasLifted = true
    invalidate()
  }

  public mutating func claimLongPress() -> Bool {
    guard allowsLongPress, contacts.count == 1 else { return false }
    holdClaimed = true
    return true
  }

  public mutating func invalidate() { poisoned = true; holdClaimed = false }
  /// UIKit can reset while a physical finger remains on the glass.
  public mutating func resetForRecognizer() { invalidate() }

  private func finite(_ point: CGPoint) -> Bool { point.x.isFinite && point.y.isFinite }
  private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
}
