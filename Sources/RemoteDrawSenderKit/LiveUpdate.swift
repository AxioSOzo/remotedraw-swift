import Foundation

/// A live-update tier a session can be created with.
///
/// **Experimental and opt-in.** Only the API that creates a session can ask for
/// a tier above ``normal``, and only a deployment with the tier and the tenant
/// both explicitly allowlisted grants one, including production. A sender
/// never chooses: it reads what the session negotiated and paces to it.
/// A higher tier is a *ceiling*
/// on how often a draft may be sent, not a promise that it will be — one
/// request is in flight at a time, so the achieved rate is also bounded by the
/// round trip.
public enum RemoteDrawLiveUpdateTier: String, CaseIterable, Equatable, Sendable {
  case normal
  case experimental60
  case experimental120
  case experimental240

  /// The draft ceiling this tier stands for, in hertz. `normal` is 1000/32.
  public var maxDraftHz: Double {
    switch self {
    case .normal: return 31.25
    case .experimental60: return 60
    case .experimental120: return 120
    case .experimental240: return 240
    }
  }

  public var isExperimental: Bool { self != .normal }
}

/// `session.liveUpdate`, and the same block on a draft acknowledgement.
///
/// Absent on every session that negotiated nothing, including sessions from
/// older servers. Production grants also require explicit allowlisting.
/// Absent means 32 ms.
///
/// **Decoded forgivingly, trusted strictly.** Nothing in here can fail a join
/// or a refresh: a field this build cannot read decodes as `nil`, and a block
/// that is not an object decodes with every field `nil`. What the sender
/// actually paces to is ``draftSendInterval``, which is 32 ms unless the whole
/// block agrees with itself — see ``negotiatedTier``.
public struct RemoteDrawLiveUpdateState: Decodable, Equatable, Sendable {
  /// What the session was created asking for. Always experimental on the wire.
  public let requestedTier: RemoteDrawLiveUpdateTier?
  /// What the server grants right now. `normal` when an operator turned the
  /// tier off after the session was created.
  public let tier: RemoteDrawLiveUpdateTier?
  public let maxDraftHz: Double?
  public let minDraftIntervalMs: Double?
  /// Always `true` on the wire. Anything else is not a block this build knows.
  public let experimental: Bool?
  /// Always `false` on the wire: a tier is a ceiling, never a guarantee.
  public let guaranteed: Bool?
  /// Why ``tier`` is `normal` although an experimental tier was requested.
  /// Kept verbatim; `disabled_by_operator` is the only value today.
  public let fallbackReason: String?
  /// An unreadable optional field must not turn into an absent field and make
  /// an otherwise malformed grant eligible for accelerated pacing.
  private let malformedFallbackReason: Bool

  public init(
    requestedTier: RemoteDrawLiveUpdateTier?,
    tier: RemoteDrawLiveUpdateTier?,
    maxDraftHz: Double?,
    minDraftIntervalMs: Double?,
    experimental: Bool? = true,
    guaranteed: Bool? = false,
    fallbackReason: String? = nil
  ) {
    self.requestedTier = requestedTier
    self.tier = tier
    self.maxDraftHz = maxDraftHz
    self.minDraftIntervalMs = minDraftIntervalMs
    self.experimental = experimental
    self.guaranteed = guaranteed
    self.fallbackReason = fallbackReason
    self.malformedFallbackReason = false
  }

  /// The state the server reports for a granted tier. For tests and for a host
  /// that wants to compare against the wire.
  public static func granted(_ tier: RemoteDrawLiveUpdateTier) -> RemoteDrawLiveUpdateState {
    RemoteDrawLiveUpdateState(
      requestedTier: tier, tier: tier, maxDraftHz: tier.maxDraftHz,
      minDraftIntervalMs: 1000 / tier.maxDraftHz)
  }

  private enum CodingKeys: String, CodingKey {
    case requestedTier, tier, maxDraftHz, minDraftIntervalMs, experimental, guaranteed
    case fallbackReason
  }

  public init(from decoder: Decoder) throws {
    guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
      self = RemoteDrawLiveUpdateState(
        requestedTier: nil, tier: nil, maxDraftHz: nil, minDraftIntervalMs: nil,
        experimental: nil, guaranteed: nil)
      return
    }
    func decodeTier(_ key: CodingKeys) -> RemoteDrawLiveUpdateTier? {
      ((try? container.decodeIfPresent(String.self, forKey: key)) ?? nil)
        .flatMap(RemoteDrawLiveUpdateTier.init(rawValue:))
    }
    requestedTier = decodeTier(.requestedTier)
    tier = decodeTier(.tier)
    maxDraftHz = (try? container.decodeIfPresent(Double.self, forKey: .maxDraftHz)) ?? nil
    minDraftIntervalMs = (try? container.decodeIfPresent(Double.self, forKey: .minDraftIntervalMs)) ?? nil
    experimental = (try? container.decodeIfPresent(Bool.self, forKey: .experimental)) ?? nil
    guaranteed = (try? container.decodeIfPresent(Bool.self, forKey: .guaranteed)) ?? nil
    if container.contains(.fallbackReason) {
      let reason = try? container.decode(String.self, forKey: .fallbackReason)
      fallbackReason = reason
      malformedFallbackReason = reason == nil
    } else {
      fallbackReason = nil
      malformedFallbackReason = false
    }
  }

  /// The tier this block grants, or `nil` when it does not agree with itself.
  ///
  /// Every field has to line up: an experimental request, the flags the wire
  /// always carries, and a ceiling and interval that are exactly the tier's
  /// (`1000 / hz`, no rounding). A granted experimental tier must be the one
  /// requested and carry no fallback reason. Anything else — an unknown tier, a
  /// hertz figure that belongs to another tier, a missing interval — is data
  /// this build cannot vouch for, and pacing to it could exceed what the server
  /// allows. `nil` paces at 32 ms.
  public var negotiatedTier: RemoteDrawLiveUpdateTier? {
    guard let tier, let requestedTier, requestedTier.isExperimental,
      experimental == true, guaranteed == false, !malformedFallbackReason,
      let maxDraftHz, let minDraftIntervalMs, maxDraftHz.isFinite, minDraftIntervalMs.isFinite,
      abs(maxDraftHz - tier.maxDraftHz) <= 1e-9,
      abs(minDraftIntervalMs - 1000 / tier.maxDraftHz) <= 1e-9
    else { return nil }
    if tier.isExperimental {
      guard tier == requestedTier, fallbackReason == nil else { return nil }
    } else {
      guard fallbackReason == "disabled_by_operator" else { return nil }
    }
    return tier
  }

  /// The minimum spacing between draft sends this block permits, in seconds.
  ///
  /// `1 / hz` for a consistent experimental grant — 1/60, 1/120 or 1/240 s,
  /// fractional on purpose — and ``RemoteDrawProtocolLimits/draftSendInterval``
  /// for everything else, including a downgrade to `normal`.
  public var draftSendInterval: TimeInterval {
    guard let tier = negotiatedTier, tier.isExperimental else {
      return RemoteDrawProtocolLimits.draftSendInterval
    }
    return 1 / tier.maxDraftHz
  }

  /// ``draftSendInterval`` for a session that may not carry the block at all.
  public static func draftSendInterval(for state: RemoteDrawLiveUpdateState?) -> TimeInterval {
    state?.draftSendInterval ?? RemoteDrawProtocolLimits.draftSendInterval
  }
}

/// What happened to this sender's stroke drafts, counted on the device.
///
/// **Opt-in and local.** Nothing is counted unless the host sets
/// ``RemoteDrawSenderSession/recordsDraftDiagnostics``, nothing runs on a timer,
/// and none of it is sent anywhere — there is no request field for it. Text
/// drafts are not counted; they are not paced by the drain.
///
/// The counts are deliberately separate, because they answer different
/// questions and are easy to conflate:
///
/// - ``offered``: stroke states the host appended. Latest-only, so most are
///   superseded before they are sent.
/// - ``sent``: requests that *started*. ``sendStartHz`` is measured from these.
/// - ``completed``: requests that came back with an answer, whatever it said.
/// - ``accepted``: answers that said `accepted: true`. A resolved
///   `accepted: false` is completed and refused, never accepted.
/// - ``failed``: requests that threw — offline, an HTTP error, a rejected
///   credential.
public struct RemoteDrawDraftDiagnostics: Equatable, Sendable {
  public internal(set) var offered = 0
  public internal(set) var sent = 0
  public internal(set) var completed = 0
  public internal(set) var accepted = 0
  public internal(set) var refusedStaleSequence = 0
  /// `live_update_rate` refusals: the server's experimental ceiling said wait.
  public internal(set) var refusedRateLimited = 0
  public internal(set) var refusedOther = 0
  public internal(set) var failed = 0
  /// Monotonic seconds on this device's uptime clock. Meaningful only as the
  /// difference between two of them.
  public internal(set) var firstSendStartedAt: TimeInterval?
  public internal(set) var lastSendStartedAt: TimeInterval?
  /// Send start to answer, in seconds, for the last request that completed.
  /// Client-observed round trip — not server processing time.
  public internal(set) var lastRoundTrip: TimeInterval?

  public init() {}

  /// How often draft requests *started*: the average since the last reset,
  /// from the first to the last send start, **idle time included**. Two
  /// strokes ten seconds apart average close to 0 Hz; reset right before the
  /// window you want to measure (one stroke, say) to read a drawing rate.
  /// It is not how often the board rendered, not how many were accepted, not
  /// a latency, and not what the device or network could sustain.
  /// `nil` until two sends have started.
  public var sendStartHz: Double? {
    guard sent >= 2, let first = firstSendStartedAt, let last = lastSendStartedAt, last > first
    else { return nil }
    return Double(sent - 1) / (last - first)
  }

  mutating func recordSend(at time: TimeInterval) {
    sent += 1
    if firstSendStartedAt == nil { firstSendStartedAt = time }
    lastSendStartedAt = time
  }

  mutating func recordAnswer(_ ack: RemoteDrawDraftAck, roundTrip: TimeInterval) {
    completed += 1
    lastRoundTrip = roundTrip
    if ack.accepted {
      accepted += 1
    } else if ack.isStaleSequence {
      refusedStaleSequence += 1
    } else if ack.isLiveUpdateRateLimited {
      refusedRateLimited += 1
    } else {
      refusedOther += 1
    }
  }
}
