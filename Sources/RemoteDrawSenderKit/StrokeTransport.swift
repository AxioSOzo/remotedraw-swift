import Foundation

/// The numbers the wire is made of.
///
/// All `let`, all public, none settable. This is the rule from
/// `docs/plans/ios-sender-sdk.md` §5.3: a customer who can raise the draft rate
/// can get their own tenant rate-limited, and a customer who can raise the
/// point cap can get their strokes refused. They are public so an integrator
/// can *read* them — size a buffer, write an assertion — not so anyone can turn
/// them up.
///
/// Every value here is pinned on the TypeScript side too:
/// `REMOTEDRAW_LIMITS` in `@remotedraw/protocol` and `PERFORMANCE_BUDGETS` in
/// `scripts/performance-budgets.ts`, whose test greps the sender sources for
/// these literals.
public enum RemoteDrawProtocolLimits: Sendable {
  /// Live draft cadence: 32 ms, i.e. 31.25 Hz.
  ///
  /// Matches `DRAFT_SEND_INTERVAL_MS = 32` and
  /// `PERFORMANCE_BUDGETS.minDraftSendIntervalMs`. Faster does not make the
  /// board smoother — it makes the sender spend its rate-limit budget on frames
  /// nobody can see.
  public static let draftSendInterval: TimeInterval = 0.032
  /// Viewport sync cadence: 45 ms.
  public static let projectionSyncInterval: TimeInterval = 0.045
  /// Presence heartbeat: 5 s. Matches `REMOTEDRAW_LIMITS.senderHeartbeatIntervalMs`.
  public static let presenceInterval: TimeInterval = 5
  /// How long the board keeps calling this phone `present` after its last
  /// heartbeat: 60 s, twelve beats. Matches
  /// `REMOTEDRAW_LIMITS.senderPresenceWindowMs`, which the API's `presence`
  /// field on `POST /v1/receiver/senders` is derived from — so what a host
  /// reads here is exactly what the customer's receiver will show.
  public static let presenceWindow: TimeInterval = 60

  /// Points in one live draft frame.
  public static let maxDraftPoints = 180
  /// Points in one committed stroke.
  public static let maxCommitPoints = 1200

  /// Byte ceilings the server enforces, for a caller that wants to check before
  /// it sends.
  public static let maxDraftPayloadBytes = 32 * 1024
  public static let maxCommitPayloadBytes = 96 * 1024
  public static let maxProjectionPayloadBytes = 1024

  public static let maxPointerIdLength = 80
  public static let maxClientStrokeIdLength = 120
  public static let maxTextLength = 280
}

/// Fits a stroke into a point budget without dropping where it started.
///
/// Mirrors `draftPointsForTransport` and `thinStrokeForBudget` in
/// `packages/client/src/strokeTransport.ts`, and `DraftTransport` in
/// `apps/ios/RemoteDraw`. Both entry points replace a plain `suffix`, which
/// silently discarded the beginning of a long stroke — the one part a receiver
/// can never reconstruct, and the reason a long stroke appeared to erase itself
/// from the start while the pen was still down.
public enum RemoteDrawStrokeBudget: Sendable {
  /// Fraction of the budget reserved for the newest samples, transmitted
  /// verbatim so the moving end of the stroke keeps full fidelity.
  public static let tailFraction = 0.5

  /// Fits a live stroke into the draft point budget without dropping its head.
  ///
  /// Keeping only the tail makes a long stroke look like it erases itself from
  /// the start while the pen is still down, then snap back to full length at
  /// commit. Decimating the head instead keeps the stroke anchored where it
  /// began: coarser near the beginning, exact where the pen actually is.
  public static func forDraft<Point>(
    _ points: [Point],
    limit: Int = RemoteDrawProtocolLimits.maxDraftPoints
  ) -> [Point] {
    guard limit > 0 else { return [] }
    guard points.count > limit else { return points }

    let tailCount = max(1, Int(Double(limit) * tailFraction))
    let headBudget = limit - tailCount
    let headSourceCount = points.count - tailCount
    var head: [Point] = []
    if headBudget > 0 && headSourceCount > 0 {
      if headBudget >= headSourceCount {
        head = Array(points.prefix(headSourceCount))
      } else {
        // Even spacing across the older samples, always including the very
        // first one so the stroke keeps its origin.
        let lastHeadIndex = headSourceCount - 1
        var previousIndex = -1
        head.reserveCapacity(headBudget)
        for step in 0..<headBudget {
          let index =
            headBudget == 1
            ? 0
            : Int((Double(step * lastHeadIndex) / Double(headBudget - 1)).rounded())
          if index == previousIndex { continue }
          previousIndex = index
          head.append(points[index])
        }
      }
    }
    return head + points.suffix(tailCount)
  }

  /// Makes room in a stroke that has filled its commit budget.
  ///
  /// The board used to simply stop appending at the cap, so a long stroke quit
  /// following the pen mid-draw while the hand kept moving. Thinning the settled
  /// head instead lets a stroke run as long as the hand does, and costs
  /// resolution only where the ink has already been laid down — logarithmically:
  /// each pass halves the head, so a stroke twice as long loses one more level
  /// of detail at its start rather than losing its end.
  public static func thin<Point>(
    _ points: [Point],
    limit: Int = RemoteDrawProtocolLimits.maxCommitPoints
  ) -> [Point] {
    guard limit > 2 else { return points }
    guard points.count >= limit else { return points }

    let tailCount = max(1, Int(Double(limit) * tailFraction))
    let headCount = max(0, points.count - tailCount)
    var thinned: [Point] = []
    thinned.reserveCapacity(headCount / 2 + tailCount + 1)
    // Every other settled sample, with the first always kept so the stroke
    // keeps its origin — the one point a receiver can never infer.
    var index = 0
    while index < headCount {
      thinned.append(points[index])
      index += 2
    }
    thinned.append(contentsOf: points[headCount...])
    // One pass is enough when the sender thins at the cap; a caller handing over
    // an already-long stroke — an SDK takes whatever the host collected — needs
    // several, so recurse until it actually fits.
    guard thinned.count < points.count else { return thinned }
    return thinned.count >= limit ? thin(thinned, limit: limit) : thinned
  }
}

/// The clock behind ``RemoteDrawNormalizedPoint/t``.
///
/// Monotonic, so it cannot jump backwards when the wall clock is corrected
/// mid-stroke, and small, because the packed codec quantises this channel into
/// an `Int32`.
///
/// It is deliberately *launch*-relative rather than boot-relative, and this is
/// the one detail in the SDK that must survive every future simplification.
/// `t` goes on the wire. `ProcessInfo.systemUptime` is system boot time — a
/// required-reason API whose only applicable reason code, `35F9.1`, forbids
/// sending the value or anything derived from it off-device *except* as "the
/// amount of time that has elapsed between events that occurred within the
/// app". Anchoring to process start is what makes every transmitted `t` exactly
/// that. A bare `ProcessInfo.systemUptime` would not be, and would make the
/// package's `PrivacyInfo.xcprivacy` a false declaration in the host app's
/// privacy report.
///
/// It also matches the web sender, whose `event.timeStamp` is already relative
/// to its own time origin, so a stroke drawn on a phone and one drawn in a
/// browser carry the same kind of number.
public enum RemoteDrawInkClock {
  private static let origin = ProcessInfo.processInfo.systemUptime

  /// Milliseconds since this process started.
  public static var milliseconds: Double {
    (ProcessInfo.processInfo.systemUptime - origin) * 1000
  }
}
