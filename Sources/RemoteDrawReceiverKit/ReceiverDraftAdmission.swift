import Foundation

/// Which drafts a receiver should actually paint.
///
/// A direct port of `renderableDrafts` in `@remotedraw/client`
/// (`packages/client/src/strokeTransport.ts`). This is the handoff between a
/// live draft and its committed stroke, and getting it wrong is visible: too
/// permissive and the stroke draws twice, too strict and it blinks out for a
/// poll cycle at the exact moment the pen lifts.
///
/// The server deletes a draft inside the same transaction that inserts its
/// committed stroke, so the pair is atomic on the server. A polling receiver
/// reads the two through separate requests and can therefore still observe them
/// out of order — which is what this filter exists to absorb.
public enum RemoteDrawDraftAdmission: Sendable {
  /// Matches `DRAFT_STALE_AFTER_MS` in `convex/lib/validators.ts` and the same
  /// constant in `@remotedraw/client`. All three must agree.
  public static let staleAfterMs: Double = 10_000

  /// Highest committed sequence per sender.
  public static func committedSequencesBySender(
    _ drawings: [RemoteDrawReceiverDrawing]
  ) -> [String: Int] {
    var sequences: [String: Int] = [:]
    for drawing in drawings {
      guard let senderId = drawing.senderId, let sequence = drawing.sequence else { continue }
      if let current = sequences[senderId] {
        if sequence > current { sequences[senderId] = sequence }
      } else {
        sequences[senderId] = sequence
      }
    }
    return sequences
  }

  /// A draft with no `updatedAt` is treated as fresh rather than dropped: the
  /// field is optional in the protocol, and discarding an un-timestamped draft
  /// would silently hide live ink from any sender that omits it.
  public static func isFresh(
    _ draft: RemoteDrawReceiverDraft,
    now: Double,
    staleAfterMs: Double = staleAfterMs
  ) -> Bool {
    guard let updatedAt = draft.updatedAt, updatedAt.isFinite else { return true }
    return now - updatedAt <= staleAfterMs
  }

  /// Fresh drafts that no committed stroke has superseded.
  ///
  /// `now` is milliseconds since the epoch, matching the protocol's timestamps
  /// rather than Swift's reference date.
  public static func renderable(
    drafts: [RemoteDrawReceiverDraft],
    drawings: [RemoteDrawReceiverDrawing],
    now: Double,
    staleAfterMs: Double = staleAfterMs
  ) -> [RemoteDrawReceiverDraft] {
    let committed = committedSequencesBySender(drawings)
    return drafts.filter { draft in
      guard isFresh(draft, now: now, staleAfterMs: staleAfterMs) else { return false }
      guard let senderId = draft.senderId, let sequence = draft.sequence else { return true }
      guard let committedSequence = committed[senderId] else { return true }
      return sequence > committedSequence
    }
  }
}

extension Date {
  /// Milliseconds since the epoch, which is the protocol's time unit.
  public var remoteDrawEpochMs: Double { timeIntervalSince1970 * 1000 }
}
