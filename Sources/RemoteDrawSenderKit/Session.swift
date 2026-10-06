import Combine
import Foundation

/// One stroke, live or committed.
public struct RemoteDrawStroke: Identifiable, Equatable, Sendable {
  public let id: String
  public let type: String
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let imageUrl: String?
  public let style: RemoteDrawDrawingStyle?
  /// True until the server answered the commit. A local echo keeps the ink on
  /// screen through the round trip; the server's version replaces it, because
  /// the board runs shape assistance and endpoint snapping before it stores.
  public let isLocalEcho: Bool
  /// Whether ``points`` are board coordinates rather than surface ones.
  ///
  /// A fresh echo is surface-space unless the stroke space supplies a board
  /// preview mapping, and becomes board-space when the server replaces it. A renderer has to
  /// know which, or a settled stroke jumps on a projected board the instant the
  /// commit lands. See ``RemoteDrawStrokeSpace/unproject``.
  public let isBoardSpace: Bool

  public init(
    id: String,
    type: String = "freehand",
    points: [RemoteDrawNormalizedPoint],
    text: String? = nil,
    imageUrl: String? = nil,
    style: RemoteDrawDrawingStyle? = nil,
    isLocalEcho: Bool = false,
    isBoardSpace: Bool = false
  ) {
    self.id = id
    self.type = type
    self.points = points
    self.text = text
    self.imageUrl = imageUrl
    self.style = style
    self.isLocalEcho = isLocalEcho
    self.isBoardSpace = isBoardSpace
  }
}

/// A standing offer to straighten the stroke that just landed.
public struct RemoteDrawShapeOffer: Identifiable, Equatable, Sendable {
  public let id = UUID()
  /// The stroke the board would replace.
  public let strokeId: String
  public let suggestion: RemoteDrawShapeSuggestion
  /// The style the stroke was drawn in, carried so the replacement is the same
  /// instrument: a straightened pencil line has to stay a pencil line.
  public let style: RemoteDrawDrawingStyle?
  /// Whether ``RemoteDrawShapeSuggestion/points`` are board coordinates.
  public let isBoardSpace: Bool

  public static func == (lhs: RemoteDrawShapeOffer, rhs: RemoteDrawShapeOffer) -> Bool {
    lhs.id == rhs.id
  }
}

/// The stroke the finger is still making.
public struct RemoteDrawLiveStroke: Equatable, Sendable {
  public let id: String
  public let tool: RemoteDrawTool
  public let style: RemoteDrawDrawingStyle?
  public let points: [RemoteDrawNormalizedPoint]

  public init(
    id: String,
    tool: RemoteDrawTool,
    style: RemoteDrawDrawingStyle?,
    points: [RemoteDrawNormalizedPoint]
  ) {
    self.id = id
    self.tool = tool
    self.style = style
    self.points = points
  }
}

/// One captured touch sample, already normalized to the drawing surface.
///
/// The same type as a protocol point on purpose. The session is headless — it
/// has no view, no bounds, and therefore no way to normalize anything — so
/// normalization belongs to the capture layer, and a second near-identical
/// struct here would only be a conversion nobody can get wrong in one direction.
public typealias RemoteDrawSample = RemoteDrawNormalizedPoint

/// The style a stroke is drawn in. Named for what a caller is choosing.
public typealias RemoteDrawInkStyle = RemoteDrawDrawingStyle

public typealias RemoteDrawStrokeID = String

/// Why a session stopped.
public enum RemoteDrawSessionEnd: Equatable, Sendable {
  /// The host called ``RemoteDrawSenderSession/leave()``.
  case left
  /// The board finished, or the session timed out.
  case ended
  /// The credential is gone and could not be recovered.
  case tokenLost
  case failed(String)
}

/// Where the session is.
public enum RemoteDrawPhase: Equatable, Sendable {
  case joining
  case ready
  case drawing
  case submitted
  case ended(RemoteDrawSessionEnd)
}

/// How the buffer the finger filled becomes the geometry the board stores.
///
/// **The seam that keeps decimation honest.** Capture reports points in the
/// *surface's* own space — 0…1 across the screen the person is touching — and
/// that is the space this session decimates and budgets in, because it is the
/// space the sampler was tuned for: ``RemoteDrawInkGeometry/shouldAppendSample``
/// keeps samples through corners measured against a stroke that spans the
/// screen. Run it after a board transform instead and the same gesture is a
/// different number of points on a zoomed-out map than on a zoomed-in one — the
/// stroke would be sampled by how far away the board is.
///
/// So the transform happens **last**, on the way to the wire, and never to the
/// buffer. The buffer stays surface-space for its whole life: decimation,
/// budget thinning, the live preview, and the local echo all read it unchanged.
///
/// The default is ``surface`` — identity, which is exactly right for a board
/// whose `inputMapping` is `surface`, and for a first draft before any
/// projection exists.
///
/// ## Why a provider and not a value
///
/// ``RemoteDrawSenderSession/strokeSpace`` is a closure the session calls once
/// per draft and once per commit, rather than something frozen at
/// ``RemoteDrawSenderSession/begin(stroke:tool:style:)``. The two board kinds
/// want opposite things and only the host knows which it is on:
///
/// - A **projected** board freezes its projection at touch-down, so a stroke
///   drawn while the window is settling lands where the person saw it.
/// - A **map** board reads the live camera on every frame, because the map is
///   still moving under the finger and the ink has to stay on the geography.
///
/// A value would have forced one of those on both. The provider lets the host
/// implement the rule it already has — which is what "the same scale as today"
/// means in practice.
public struct RemoteDrawStrokeSpace: Sendable {
  /// Maps surface-space points into board space. Called with the whole stroke.
  public let project: @Sendable ([RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint]
  /// The way back, for drawing board-space content on this screen.
  ///
  /// Needed because a commit does not come back the way it went out: the server
  /// runs shape assistance and endpoint snapping, and the stored points arrive
  /// in board space. Without an inverse the local echo would have to be thrown
  /// away at exactly the moment it is holding the ink on screen — the one thing
  /// §5.5 calls non-negotiable.
  ///
  /// Returns `nil` for a point that has no image on this screen (a mapping that
  /// is degenerate, or geometry currently off-window), which is why it is
  /// per-point rather than per-stroke: the caller drops what it cannot place
  /// instead of dropping the mark.
  public let unproject: @Sendable (RemoteDrawNormalizedPoint) -> RemoteDrawNormalizedPoint?
  /// The window this stroke was made through, sent alongside so the board can
  /// place it. `nil` on a board that has no window — a `surface` mapping, or a
  /// map board, where the geography *is* the mapping and a projection would be
  /// a second, conflicting answer.
  public let phoneProjection: RemoteDrawProjection?

  /// Whether what comes back from the board needs ``unproject`` before it can
  /// be drawn on this screen.
  ///
  /// Declared rather than inferred. It would be tempting to probe ``project``
  /// with a test point and call it identity if the point survives — and that
  /// probe is wrong for a projection that happens to be centred and unrotated,
  /// which is the *default* state of a fresh board. A space that lies about
  /// this puts every settled stroke in the wrong place exactly once, on the
  /// first board anyone opens.
  public let isBoardSpace: Bool

  /// Optional board-space preview mapping. Unlike `project`, this also applies
  /// any window transform that the server normally resolves on commit.
  public let boardPreview: (@Sendable ([RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint])?

  public init(
    phoneProjection: RemoteDrawProjection? = nil,
    isBoardSpace: Bool = false,
    boardPreview: (@Sendable ([RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint])? = nil,
    project: @escaping @Sendable ([RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint] = { $0 },
    unproject: @escaping @Sendable (RemoteDrawNormalizedPoint) -> RemoteDrawNormalizedPoint? = { $0 }
  ) {
    self.phoneProjection = phoneProjection
    self.boardPreview = boardPreview
    self.isBoardSpace = isBoardSpace
    self.project = project
    self.unproject = unproject
  }

  /// The surface *is* the board. Identity both ways, no window.
  public static let surface = RemoteDrawStrokeSpace()

  /// A window onto a larger board: points pass through unchanged and the
  /// projection travels with them, which is how the receiver places them.
  ///
  /// `isBoardSpace` is still true — the *reply* is in board space even though
  /// the request was not, because the receiver resolves the window server-side.
  public static func window(_ projection: RemoteDrawProjection) -> RemoteDrawStrokeSpace {
    RemoteDrawStrokeSpace(phoneProjection: projection, isBoardSpace: true)
  }
}

/// The headless sender: everything the wire needs, nothing about UI.
///
/// A host that wants its own drawing surface talks to this and nothing else.
/// Capture feeds it samples, it handles cadence, thinning, packing, sequence,
/// idempotency, presence and the credential — the parts that are wrong in
/// every hand-rolled integration.
///
/// ## Two lifecycle facts that decide whether an integration works
///
/// **Sequence healing.** Every input carries a strictly increasing sequence per
/// token. A draft below the server's high-water mark is answered
/// `{accepted: false, reason: "stale_sequence", lastSequence}` — a 200, not an
/// error — and this session adopts the counter without a second round trip.
/// Skip that and live ink silently vanishes while commits keep working.
///
/// **Presence is not a leave signal.** ``leave()`` posts
/// `/v1/sender/projection/close` with `disconnect: true`. A phone that merely
/// stops pinging reads `present` on the board for up to
/// ``RemoteDrawProtocolLimits/presenceWindow`` (60 s) before it turns `stale`;
/// only a leave turns it `disconnected` at once.
@MainActor
public final class RemoteDrawSenderSession: ObservableObject {
  // MARK: Published state

  @Published public private(set) var phase: RemoteDrawPhase = .joining
  @Published public private(set) var capabilities: Set<RemoteDrawCapability> = []
  /// Local echo plus server truth, in the order they landed.
  public enum DrawingOperationState: Equatable, Sendable {
    case pending, acknowledged, failed, removed
  }

  /// Delivery state keyed by the original client operation ID. A lost response
  /// stays pending until retry or a board snapshot establishes its outcome.
  @Published public private(set) var drawingOperations: [String: DrawingOperationState] = [:]
  private var acknowledgedDrawingIDs: [String: String] = [:]
  private var observedDrawingIDs: Set<String> = []
  private var drawingReadRevision = 0
  private var nextDrawingRead = 0
  private var lastPublishedDrawingRead = 0
  private var removedDrawingIDs: Set<String> = []

  /// Reconcile snapshots read by a host that owns board polling. Remember IDs
  /// even before their commit response supplies the client/server ID mapping.
  public var acknowledgedOperationIDs: Set<String> {
    Set(drawingOperations.compactMap { $0.value == .acknowledged ? $0.key : nil })
  }

  public func reconcileDrawingIDs(
    _ ids: Set<String>, acknowledgedBeforeRead: Set<String> = []
  ) {
    for operation in acknowledgedBeforeRead {
      if let serverID = acknowledgedDrawingIDs[operation], !ids.contains(serverID) {
        removedDrawingIDs.insert(serverID)
      }
    }
    removedDrawingIDs.formUnion(observedDrawingIDs.subtracting(ids))
    observedDrawingIDs.formUnion(ids)
    for (operation, serverID) in acknowledgedDrawingIDs {
      if removedDrawingIDs.contains(serverID) {
        drawingOperations[operation] = .removed
      }
    }
    strokes.removeAll { ids.contains($0.id) || removedDrawingIDs.contains($0.id) }
  }

  private func removeDrawing(_ id: String) {
    removedDrawingIDs.insert(id)
    for (operation, serverID) in acknowledgedDrawingIDs where serverID == id {
      drawingOperations[operation] = .removed
    }
    if drawingOperations[id] != nil { drawingOperations[id] = .removed }
    strokes.removeAll { $0.id == id }
  }

  @Published public private(set) var strokes: [RemoteDrawStroke] = []
  /// The stroke the finger is still making, or `nil`.
  @Published public private(set) var live: RemoteDrawLiveStroke?
  @Published public private(set) var session: RemoteDrawSession?
  /// Authoritative full board snapshot, published only after lifecycle and read
  /// ordering checks. Hosts adapt this rather than independently polling.
  @Published public private(set) var drawingSnapshot: RemoteDrawDrawingsResponse?
  @Published public private(set) var maintenanceState: RemoteDrawMaintenanceState = .checking
  /// Kept separately from interactive failures; a successful commit cannot
  /// declare a refused metadata/drawing read healthy.
  @Published public private(set) var maintenanceError: RemoteDrawError?
  /// Monotonic start time of the read publishing `session`. A host can fence
  /// local projection edits made while that read was in flight.
  public private(set) var sessionSnapshotReadStartedAt: TimeInterval = 0
  /// The last thing that went wrong, for a host that wants to show it. Cleared
  /// by the next successful call.
  @Published public private(set) var lastError: RemoteDrawError?
  /// The board's standing offer to straighten the stroke that just landed.
  ///
  /// Published as well as drawn, so a Tier 3 host that wants its own affordance
  /// is not reduced to re-deriving it. ``RemoteDrawSurface`` shows the built-in
  /// pill from exactly this value.
  ///
  /// Cleared by ``applyShapeSuggestion()``, by ``dismissShapeSuggestion()``, and
  /// by the next ``begin(stroke:tool:style:)`` — starting to draw again is an
  /// answer, and an offer that outlived the mark it was about would apply to
  /// the wrong stroke.
  @Published public private(set) var shapeSuggestion: RemoteDrawShapeOffer?
  /// The experimental live-update state this sender is pacing to, or `nil`.
  ///
  /// Taken from the session at join, adoption and every adopted refresh, and
  /// from any stroke or text draft answer that carries one — which is how a
  /// server downgrade to `normal` lands mid-stroke. Neither source can raise a
  /// ceiling the other lowered while its request was in flight. `nil` for
  /// every session that negotiated nothing. What it means for pacing is
  /// ``effectiveDraftInterval``. Read this, not `session?.liveUpdate`, which is
  /// the last snapshot verbatim and can be older.
  @Published public private(set) var liveUpdate: RemoteDrawLiveUpdateState?

  // MARK: Inspectable, never settable

  public static let draftInterval = RemoteDrawProtocolLimits.draftSendInterval

  /// The spacing this session's stroke drafts are actually paced at.
  ///
  /// ``draftInterval`` (32 ms) unless the session negotiated a consistent
  /// experimental tier, then exactly `1 / hz` of it. Read, never set: the tier
  /// comes from whoever created the session, and the server enforces it. A
  /// ceiling on the send rate, not a promise — one request is in flight at a
  /// time, so a slow round trip sends less often than this.
  public var effectiveDraftInterval: TimeInterval {
    RemoteDrawLiveUpdateState.draftSendInterval(for: liveUpdate)
  }

  /// Counts stroke drafts into ``draftDiagnostics``. Off by default, and off
  /// costs nothing but this flag. Local only — see ``RemoteDrawDraftDiagnostics``.
  public var recordsDraftDiagnostics = false
  /// What this session's stroke drafts did since the last reset. Not published:
  /// read it when you want it rather than re-rendering on every frame.
  public private(set) var draftDiagnostics = RemoteDrawDraftDiagnostics()

  public func resetDraftDiagnostics() {
    draftDiagnostics = RemoteDrawDraftDiagnostics()
    draftDiagnosticsEpoch += 1
  }
  public static let maxDraftPoints = RemoteDrawProtocolLimits.maxDraftPoints
  public static let maxCommitPoints = RemoteDrawProtocolLimits.maxCommitPoints
  public static let presenceInterval = RemoteDrawProtocolLimits.presenceInterval

  public private(set) var senderId: String?

  /// Where the stroke buffer goes on its way to the wire. See
  /// ``RemoteDrawStrokeSpace``.
  ///
  /// `nil` means ``RemoteDrawStrokeSpace/surface`` with whatever projection
  /// ``updateProjection(_:)`` last set — the Stage 1 behaviour, unchanged for
  /// anyone who never sets this.
  public var strokeSpace: (@MainActor () -> RemoteDrawStrokeSpace)?

  // MARK: Internals

  private let transport: any RemoteDrawSenderTransport
  /// The credential this session is using **right now**.
  ///
  /// Readable, never settable. A host hands a token in and the SDK may rotate
  /// it out from under them (``rotateToken()`` on a rejection), so a host that
  /// kept the string it passed to ``join(token:transport:device:tokenProvider:)``
  /// is holding a credential that can silently stop working. The first-party
  /// app is exactly that case: it opens the hosted web sender at a URL built
  /// from this token and records board visits against it, both of which have to
  /// follow a rotation.
  ///
  /// Exposed rather than mirrored through a callback because there is nothing
  /// to react to — a caller needs the value at the moment it builds a request,
  /// and reading it then is always current.
  @Published public private(set) var senderToken: String
  /// Where a fresh credential can come from when the current one dies. See
  /// ``RemoteDrawSenderSession/join(token:transport:device:tokenProvider:)``.
  private let tokenProvider: (@Sendable () async throws -> String)?

  private var sequence = 0
  private var lastDraftSentAt: Date = .distantPast
  /// Renewal age uses the monotonic clock, separate from the existing pacer.
  private var lastDraftSentAtMonotonic: TimeInterval = -.infinity
  /// HTTP Retry-After applies to every draft on the credential that was refused.
  private var draftHTTPNotBefore: (generation: Int, until: TimeInterval)?
  /// Keep a held stroke inside the server's 10 s draft freshness window.
  private static let unchangedDraftRenewalInterval: TimeInterval = 5
  private var pendingDraft: PendingDraft?
  private var draftTask: Task<Void, Never>?
  private var draftGeneration = 0
  private var draftHTTPWaitingGeneration: Int?
  /// No stroke or text draft starts before this: the server's `retryAfterMs`
  /// on a `live_update_rate` refusal. Distant past on every session that was never
  /// refused, which leaves the 32 ms gate exactly as it was.
  private var draftNotBefore: Date = .distantPast
  /// Refused frames re-offered since the last accepted one. Bounded so a
  /// server that keeps refusing cannot turn a resting finger into a loop.
  private var draftRefusalReplays = 0
  private static let maxDraftRefusalReplays = 3
  /// A refusal's wait is honoured up to this, so a malformed hint cannot park
  /// live ink for the rest of the stroke. Commits never wait on it.
  private static let maxDraftBackoff: TimeInterval = 1
  /// Bumped per draft answer whose live-update state was taken, so a session
  /// read that was already in flight cannot raise a ceiling the answer lowered.
  private var liveUpdateAnswers = 0
  /// A cancelled request can complete after the next stroke's request, and
  /// host-owned text calls can overlap. Order their policy answers by the
  /// sequence sent, within the credential that owned it, not completion time.
  private var liveUpdateAnswerOrder: (credentialGeneration: Int, sequence: Int)?
  /// Bumped per snapshot whose live-update state was taken, so a draft answer
  /// that left before it cannot raise a ceiling the snapshot lowered.
  private var liveUpdateSnapshots = 0
  private var draftDiagnosticsEpoch = 0
  private var heartbeatTask: Task<Void, Never>?
  /// One revision-gated loop for board metadata and drawings. See
  /// ``startBoardPolling()``.
  private var syncTask: Task<Void, Never>?
  private var initialDrawingsTask: Task<Void, Never>?
  private var startedInitialDrawingsRead = false
  /// The unconditional snapshot loops, only for a transport without sync.
  private var legacySessionTask: Task<Void, Never>?
  private var legacyDrawingsTask: Task<Void, Never>?
  private var syncUnsupported = false
  private var lastSyncStartedAt: TimeInterval?
  /// Bumped whenever a cursor may no longer describe what this session shows:
  /// a new credential, or polling stopped. A read that began under an older
  /// epoch can neither publish content nor advance a cursor.
  private var syncEpoch = 0
  private var latestSync: SyncObservation?
  /// The revision the last *published* read is known to be at least as new as.
  private var metadataCursor: String?
  private var drawingsCursor: String?
  private var nextSessionRead = 0
  private var nextSnapshotRead = 0
  private var lastSessionSnapshotRead = 0
  private var drawingsReadTask: Task<[RemoteDrawDrawing], Error>?
  private var drawingsReadTaskID = 0
  private var drawingsReadTaskRevision = 0
  private var maintenanceRetryAt: TimeInterval = -.infinity
  private var maintenanceFailureID = 0
  private var presenceCloseTask: Task<Void, Never>?
  private var presenceRequest: Task<Void, Error>?
  private var handingOff = false
  private var foreground = true
  /// The newest session read whose grants were adopted.
  private var lastGrantRead = 0
  private let pollClock: any RemoteDrawPollClock
  private let automaticallyRefreshDrawings: Bool

  private struct SyncObservation {
    let revisions: RemoteDrawSyncRevisions
    let epoch: Int
  }

  /// Target period between sync ticks, measured from the start of each tick.
  static let syncInterval: TimeInterval = 1.0
  /// No tick starts sooner than this after the previous one, including the
  /// first tick after a foreground resume.
  static let syncFloor: TimeInterval = 0.9
  /// Snapshot cadence for a transport that throws ``RemoteDrawSyncUnsupportedError``.
  static let legacyPollInterval: TimeInterval = 5
  private var strokePoints: [RemoteDrawNormalizedPoint] = []
  private var textDraftAnnotationRevision: Int?
  private var hasTextDraft = false
  private var activeStroke: ActiveStroke?
  private var projection: RemoteDrawProjection?
  /// Bumped per ``updateProjection(_:)`` so a slower, older answer cannot
  /// overwrite the window a newer call already set.
  private var projectionGeneration = 0
  /// When rotation was last attempted, so a storm of failures cannot spend the
  /// route's 10/min budget. See ``rotateToken()``.
  private var lastRefreshAttemptAt: Date = .distantPast
  private var credentialGeneration = 0
  private var refreshTask: Task<Bool, Never>?
  private var disconnectOnCompletion = false
  private var pendingCommits: [PendingCommit] = []
  private var commitsInFlight: Set<String> = []
  private var commitDrainWaiters: [CheckedContinuation<Void, Never>] = []
  private var drainingCommits = false
  private static let maxPendingCommits = 128

  /// Unacknowledged commits retained in memory until delivery or departure.
  public var pendingCommitCount: Int { pendingCommits.count }

  private struct PendingCommit {
    let request: RemoteDrawCommitRequest
    let space: RemoteDrawStrokeSpace
  }

  private var isEnded: Bool {
    if case .ended = phase { return true }
    return false
  }

  private struct ActiveStroke {
    let annotationRevision: Int?
    let id: RemoteDrawStrokeID
    let tool: RemoteDrawTool
    let style: RemoteDrawDrawingStyle?
  }

  private struct PendingDraft {
    let annotationRevision: Int?
    let tool: RemoteDrawTool
    let style: RemoteDrawDrawingStyle?
    let points: [RemoteDrawNormalizedPoint]
    let text: String?
  }

  private init(
    transport: any RemoteDrawSenderTransport,
    senderToken: String,
    tokenProvider: (@Sendable () async throws -> String)?,
    automaticallyRefreshDrawings: Bool = true,
    pollClock: any RemoteDrawPollClock = RemoteDrawSystemPollClock()
  ) {
    self.automaticallyRefreshDrawings = automaticallyRefreshDrawings
    self.pollClock = pollClock
    self.transport = transport
    self.senderToken = senderToken
    self.tokenProvider = tokenProvider
  }

  // MARK: - Entering

  /// Enters a session and returns a live sender.
  ///
  /// A `.join(rd_join_…)` token is spent here and **revokes every other active
  /// sender token on the session** — one live sender per board. A
  /// `.sender(rd_send_…)` token was minted by the host's backend and is used
  /// as-is, with no join round trip and nobody kicked off.
  ///
  /// - Parameter tokenProvider: a last resort, and normally `nil`.
  ///
  ///   Token lifetime is the SDK's problem, not the host's:
  ///   `POST /v1/sender/refresh` rotates this sender's own credential without
  ///   disturbing anyone else on the board, and ``recover(from:)`` calls it on
  ///   a rejection. This closure only covers what refresh structurally cannot —
  ///   a refresh whose *response* was lost, which spends the old token without
  ///   delivering the new one, and any case where the token document itself is
  ///   gone. A host with no way to mint tokens on demand should leave this nil
  ///   and handle ``RemoteDrawSessionEnd/tokenLost``.
  public static func join(
    token: RemoteDrawToken,
    transport: any RemoteDrawSenderTransport,
    device: RemoteDrawSenderDevice? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil
  ) async throws -> RemoteDrawSenderSession {
    switch token {
    case .sender(let senderToken):
      let sender = RemoteDrawSenderSession(
        transport: transport, senderToken: senderToken, tokenProvider: tokenProvider)
      try await sender.adoptExistingToken()
      return sender
    case .join(let joinToken):
      let response = try await transport.join(joinToken: joinToken, device: device)
      let sender = RemoteDrawSenderSession(
        transport: transport, senderToken: response.senderToken, tokenProvider: tokenProvider)
      sender.adopt(
        senderId: response.senderId,
        session: response.session,
        capabilities: response.capabilities,
        lastSequence: response.lastSequence
      )
      sender.start()
      return sender
    }
  }

  /// Convenience for the common case: a raw token string of either kind.
  public static func join(
    rawToken: String,
    transport: any RemoteDrawSenderTransport,
    device: RemoteDrawSenderDevice? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil
  ) async throws -> RemoteDrawSenderSession {
    guard let token = RemoteDrawToken(raw: rawToken) else {
      throw RemoteDrawError.malformedToken
    }
    return try await join(
      token: token, transport: transport, device: device, tokenProvider: tokenProvider)
  }

  /// Resumes a session whose join has **already happened**, with no round trip.
  ///
  /// ``join(token:transport:device:tokenProvider:)`` with a `.sender` token
  /// re-reads `/v1/sender/session` to learn the sender id, the capabilities and
  /// the sequence high-water mark. A host that already holds a join response
  /// has all three, and paying for a second call to be told them again costs a
  /// round trip on the one screen where latency is most visible — the moment
  /// between a QR scan and a usable drawing surface.
  ///
  /// This is the seam the first-party app needs, and the reason it is public
  /// rather than a private overload: that app decodes the join response into a
  /// **richer** session type than this SDK publishes (it reads
  /// `senderIntegrationMode` and target metadata, both deliberately outside the
  /// SDK's subset), so it cannot hand the response object over — only the four
  /// facts the wire agreed on.
  ///
  /// - Parameter lastSequence: the server's high-water mark from the join
  ///   response. Skipping it is not harmless: the server rejects any input at
  ///   or below the sequence it already holds, so a resumed token whose counter
  ///   restarts at zero has every draft refused until it catches up.
  /// - Parameter automaticallyRefreshDrawings: suppresses automatic drawing
  ///   snapshots only. The SDK still owns revision and metadata maintenance;
  ///   this is NOT permission to start a second host-owned maintenance loop.
  @MainActor
  public static func adopt(
    senderToken: String,
    transport: any RemoteDrawSenderTransport,
    senderId: String? = nil,
    session: RemoteDrawSession? = nil,
    capabilities: [String]? = nil,
    lastSequence: Int? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil,
    automaticallyRefreshDrawings: Bool = true
  ) -> RemoteDrawSenderSession {
    adopt(
      senderToken: senderToken, transport: transport, senderId: senderId, session: session,
      capabilities: capabilities, lastSequence: lastSequence, tokenProvider: tokenProvider,
      automaticallyRefreshDrawings: automaticallyRefreshDrawings,
      pollClock: RemoteDrawSystemPollClock())
  }

  /// The same entry point with an injectable clock, so polling cadence is
  /// testable through the real host composition without waiting on wall time.
  public static func adopt(
    senderToken: String,
    transport: any RemoteDrawSenderTransport,
    senderId: String? = nil,
    session: RemoteDrawSession? = nil,
    capabilities: [String]? = nil,
    lastSequence: Int? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil,
    automaticallyRefreshDrawings: Bool = true,
    pollClock: any RemoteDrawPollClock
  ) -> RemoteDrawSenderSession {
    let sender = RemoteDrawSenderSession(
      transport: transport, senderToken: senderToken, tokenProvider: tokenProvider,
      automaticallyRefreshDrawings: automaticallyRefreshDrawings, pollClock: pollClock)
    sender.adopt(
      senderId: senderId,
      session: session,
      capabilities: capabilities,
      lastSequence: lastSequence
    )
    sender.start()
    return sender
  }

  private func adoptExistingToken() async throws {
    let response = try await transport.session(senderToken: senderToken)
    adopt(
      senderId: response.senderId,
      session: response.session,
      capabilities: response.capabilities,
      lastSequence: response.lastSequence
    )
    start()
  }

  private func adopt(
    senderId: String?,
    session: RemoteDrawSession?,
    capabilities: [String]?,
    lastSequence: Int?
  ) {
    self.senderId = senderId ?? self.senderId
    if let session {
      adoptSessionSnapshot(session)
      // The join's own `capabilities` win where present; a session payload
      // carries the same list and is the only source on the resume path.
      if capabilities == nil {
        self.capabilities = Set(session.capabilities.map(RemoteDrawCapability.init(rawValue:)))
      }
    }
    if let capabilities {
      self.capabilities = Set(capabilities.map(RemoteDrawCapability.init(rawValue:)))
    }
    adoptServerSequence(lastSequence)
    if case .ended = phase {} else { phase = .ready }
  }

  /// Publish snapshots only for this board and never rewind its geometry.
  /// A stale geometry snapshot is discarded as a whole, including its metadata.
  ///
  /// `liveUpdateAnswersAtStart` is ``liveUpdateAnswers`` when the read left;
  /// `nil` for a snapshot taken in hand, which is current by construction.
  @discardableResult
  private func adoptSessionSnapshot(
    _ snapshot: RemoteDrawSession, readID: Int? = nil, startedAt: TimeInterval? = nil,
    liveUpdateAnswersAtStart: Int? = nil
  ) -> Bool {
    if let readID, readID < lastSessionSnapshotRead { return false }
    if let current = session {
      guard snapshot.id == current.id,
        snapshot.geometryRevision >= current.geometryRevision,
        (snapshot.annotationInput?.revision ?? 0) >= (current.annotationInput?.revision ?? 0) else { return false }
    }
    if session?.annotationInput != snapshot.annotationInput {
      drawingReadRevision += 1
      drawingSnapshot = nil
      drawingsCursor = nil
      strokes = []
      shapeSuggestion = nil
      activeStroke = nil
      strokePoints = []
      live = nil
      // The note being placed belonged to the old region, and the server
      // deleted its draft with it. Keeping its revision would drop every draft
      // of the next note and refuse its commit once.
      resetTextDraft()
      stopDraftDrain()
      if case .drawing = phase { phase = .ready }
    }
    if let readID { lastSessionSnapshotRead = readID }
    sessionSnapshotReadStartedAt = startedAt ?? pollClock.now
    session = snapshot
    adoptLiveUpdate(snapshot.liveUpdate, answersAtStart: liveUpdateAnswersAtStart)
    return true
  }

  /// Takes the live-update state an adopted snapshot carried.
  ///
  /// A snapshot read that was in flight when a draft answer's state landed may
  /// only *lower* the ceiling — it can be older than the answer, and an older
  /// experimental state must not undo a downgrade. Once the answer is behind
  /// it, the next refresh is authoritative again, including an absent block
  /// meaning `normal`.
  private func adoptLiveUpdate(_ next: RemoteDrawLiveUpdateState?, answersAtStart: Int?) {
    if let answersAtStart, answersAtStart != liveUpdateAnswers,
      RemoteDrawLiveUpdateState.draftSendInterval(for: next) < effectiveDraftInterval
    {
      return
    }
    liveUpdateSnapshots += 1
    if liveUpdate != next { liveUpdate = next }
  }

  /// Takes the live-update state a draft answer (stroke or text) carried.
  ///
  /// The mirror of the snapshot rule: an answer to a request that left before
  /// a snapshot's state was taken may only *lower* the ceiling, so an older
  /// 120 Hz answer cannot undo a downgrade a newer read already applied. The
  /// next answer is authoritative again. Only for the credential the request
  /// was sent with, and never after the session ended.
  private func adoptAnsweredLiveUpdate(
    _ ack: RemoteDrawDraftAck, credentialGeneration requestGeneration: Int,
    sequence requestSequence: Int, snapshotsAtStart: Int
  ) {
    guard let state = ack.liveUpdate, requestGeneration == credentialGeneration, !isEnded else { return }
    if let previous = liveUpdateAnswerOrder, previous.credentialGeneration == requestGeneration,
      requestSequence < previous.sequence { return }
    // Remember even a grant rejected by the snapshot rule below: an answer
    // older than that grant must not become authoritative on a later arrival.
    liveUpdateAnswerOrder = (requestGeneration, requestSequence)
    if snapshotsAtStart != liveUpdateSnapshots, state.draftSendInterval < effectiveDraftInterval { return }
    liveUpdateAnswers += 1
    if liveUpdate != state { liveUpdate = state }
  }

  /// Refresh board geometry without requiring access to existing drawings.
  /// This read never replaces the credential, sender identity, or input sequence.
  public func refreshSession() async throws {
    try requireMaintenanceAdmission()
    try await readSession(revision: observedRevision(\.metadata))
  }

  /// `revision` must come from a sync that *returned before this read started*,
  /// so the snapshot is at least as new as the revision. Only then may the read
  /// advance the cursor; the reverse order could skip a change forever.
  ///
  /// `adoptGrants` is set only by the sync-gated tick. A manual
  /// ``refreshSession()`` leaves grants alone; both owned polling paths adopt
  /// them so a host never needs an independent capability watcher.
  private func readSession(revision: (value: String, epoch: Int)?, adoptGrants: Bool = false)
    async throws
  {
    guard !isEnded else { throw RemoteDrawError.sessionEnded }
    let generation = credentialGeneration
    let epoch = syncEpoch
    let startedAt = pollClock.now
    nextSnapshotRead += 1
    let snapshotRead = nextSnapshotRead
    nextSessionRead += 1
    let readID = nextSessionRead
    let answersAtStart = liveUpdateAnswers
    let response = try await transport.session(senderToken: senderToken)
    try Task.checkCancellation()
    guard !isEnded, generation == credentialGeneration, epoch == syncEpoch else { return }
    let adopted = adoptSessionSnapshot(response.session, readID: snapshotRead, startedAt: startedAt,
      liveUpdateAnswersAtStart: answersAtStart)
    // Grants follow the same rules as the snapshot they arrived with: this
    // board, not older geometry, and no older read overwriting a newer one.
    // Identity and sequence are never taken from here.
    if adoptGrants, adopted, readID > lastGrantRead {
      lastGrantRead = readID
      adoptGrantsFromSnapshot(response)
    }
    // A discarded snapshot cannot prove this revision has been adopted.
    if adopted, let revision, revision.epoch == syncEpoch { metadataCursor = revision.value }
  }

  /// Replaces ``capabilities`` with the grants a session read carried: the
  /// response's own list, else the session's. A session list that is absent
  /// decodes as empty, and absence is not a revocation, so an empty fallback
  /// changes nothing.
  private func adoptGrantsFromSnapshot(_ response: RemoteDrawSessionResponse) {
    let raw = response.capabilities
      ?? (response.session.capabilities.isEmpty ? nil : response.session.capabilities)
    guard let raw else { return }
    let next = Set(raw.map(RemoteDrawCapability.init(rawValue:)))
    guard next != capabilities else { return }
    // Losing or regaining the right to read drawings means the cursor no longer
    // describes what is on screen: nothing was read while it was withheld.
    if next.contains(.viewExisting) != capabilities.contains(.viewExisting) {
      drawingsCursor = nil
      drawingReadRevision += 1
      if !next.contains(.viewExisting) {
        drawingSnapshot = nil
        strokes.removeAll { !$0.isLocalEcho }
      }
    }
    capabilities = next
  }

  /// The newest revision a completed sync reported under the current epoch.
  private func observedRevision(_ key: KeyPath<RemoteDrawSyncRevisions, String>)
    -> (value: String, epoch: Int)?
  {
    guard let latestSync, latestSync.epoch == syncEpoch else { return nil }
    return (latestSync.revisions[keyPath: key], latestSync.epoch)
  }

  /// Adopts the sender token's server-side sequence history.
  ///
  /// The server rejects any input at or below the highest sequence it holds for
  /// the token, so a relaunched app that restarts its counter at zero has every
  /// draft refused until it catches up. `max` rather than assignment: a session
  /// that has already sent input this run must not rewind onto sequences it has
  /// spent. Malformed counters cannot poison the next increment or exceed
  /// JavaScript's safe integer range; leave room for the next wire sequence.
  @discardableResult
  private func adoptServerSequence(_ lastSequence: Int?) -> Bool {
    guard let lastSequence, lastSequence >= 0, lastSequence < 9_007_199_254_740_991 else { return false }
    sequence = max(sequence, lastSequence)
    return true
  }

  private func nextSequence() -> Int {
    sequence += 1
    return sequence
  }

  private func start() {
    startHeartbeat()
    // The first beat goes out now rather than one interval from now. A direct
    // sender's record exists on the board from the moment the customer's
    // backend minted it, and the receiver's "the phone has arrived" signal is
    // the first write that stamps `lastSeenAt` past `connectedAt` — waiting
    // five seconds to send it is five seconds of a launch button that cannot
    // tell an opened app from one that never launched. Skipped if the host's
    // own ``markActive()`` got there first, so its `active: true` is not
    // followed by a bare beat that reads as a demotion.
    Task { [weak self] in
      guard let self, !self.sentFirstBeat else { return }
      await self.beat()
    }
  }

  /// Whether any presence ping has left this session yet. See ``start()``.
  private var sentFirstBeat = false
  private var presenceGeneration = 0
  private var activationPending = false

  // MARK: - Drawing

  /// Starts a stroke. Nothing is sent until the first ``append(_:)``.
  public func begin(stroke id: RemoteDrawStrokeID, tool: RemoteDrawTool = .auto, style: RemoteDrawInkStyle? = nil) {
    // Drawing again answers the offer. It never blocks input, so it has to get
    // out of the way on its own.
    shapeSuggestion = nil
    // A surface still mounted after Leave or a remote end can still be touched.
    // Nothing may reach the wire with the dead credential or stick on screen.
    guard !isEnded, !handingOff, foreground, maintenanceError == nil else { return }
    guard session?.annotationInput?.paused != true else { return }
    activeStroke = ActiveStroke(annotationRevision: session?.annotationInput?.revision, id: id, tool: tool, style: style)
    strokePoints = []
    live = RemoteDrawLiveStroke(id: id, tool: tool, style: style, points: [])
    if case .ended = phase {} else { phase = .drawing }
  }

  /// Adds captured samples to the live stroke.
  ///
  /// Paced, thinned and packed for you: samples are accepted as fast as the
  /// hardware produces them, and at most one draft frame leaves every 32 ms
  /// (``effectiveDraftInterval`` on a session that negotiated an experimental
  /// tier) carrying the newest state of the whole stroke. The achieved rate also
  /// depends on request completion time; it does not promise the receiver's
  /// displayed frame rate.
  ///
  /// Predicted touches must never come through here — they describe positions
  /// the finger has not reached. Give those to the renderer only.
  public func append(_ samples: [RemoteDrawSample]) {
    guard !isEnded, let stroke = activeStroke, !samples.isEmpty else { return }
    var appended = false
    for sample in samples {
      // The renderer's own sampler: decimate straight motion, keep near samples
      // through corners and pressure ramps.
      guard RemoteDrawInkGeometry.shouldAppendSample(strokePoints, candidate: sample) else {
        continue
      }
      // Thin the settled head rather than stop appending: a stroke that hits its
      // budget used to quit following the pen mid-draw.
      if strokePoints.count >= Self.maxCommitPoints {
        strokePoints = RemoteDrawStrokeBudget.thin(strokePoints, limit: Self.maxCommitPoints)
      }
      strokePoints.append(sample)
      appended = true
    }
    // Unchanged geometry needs no publication or high-rate draft update. A
    // continuing held/jittering input still renews the server's 10 s draft
    // lease occasionally; presence pings do not refresh that lease.
    guard appended else {
      renewUnchangedDraftIfNeeded()
      return
    }
    live = RemoteDrawLiveStroke(
      id: stroke.id, tool: stroke.tool, style: stroke.style, points: strokePoints)
    // Only a stroke state that changed is offered; samples the sampler dropped
    // re-queue the same state and are not a new frame.
    if appended { draftRefusalReplays = 0 }
    if recordsDraftDiagnostics, appended { draftDiagnostics.offered += 1 }
    enqueueDraft()
  }

  /// Ends the stroke and commits it.
  ///
  /// The commit is idempotent on `clientStrokeId`, so a timeout can be retried
  /// safely — and is, three times, before this throws.
  @discardableResult
  public func end(stroke id: RemoteDrawStrokeID) async throws -> RemoteDrawCommitResult? {
    guard let stroke = activeStroke, stroke.id == id else { return nil }
    // The finger is up whatever happens next: clear the live stroke before any
    // refusal, or a thrown commit leaves it drawn on screen.
    activeStroke = nil
    let points = strokePoints
    strokePoints = []
    live = nil
    stopDraftDrain()
    if case .ended = phase {} else { phase = .ready }
    do {
      try requireCommitCapacity()
    } catch {
      if !isEnded { try? await clearDraftRequest() }
      throw error
    }

    // What the tool actually commits: a shape is its endpoints, and a tap is a
    // dot rather than nothing. See ``RemoteDrawCommitGeometry`` for why both
    // rules have to run here and not in the host.
    let committed = RemoteDrawCommitGeometry.forCommit(points, tool: stroke.tool)
    guard committed.count >= RemoteDrawCommitGeometry.minimumPointCount(for: stroke.tool) else {
      // Nothing worth committing, but the board is still showing the draft.
      try? await clearDraftRequest()
      return nil
    }

    let commitSequence = nextSequence()
    // The buffer stays surface-space; only what leaves is projected. See
    // ``RemoteDrawStrokeSpace``.
    let space = currentStrokeSpace()
    // The echo is the committed geometry, not the raw buffer: a `rectangle`
    // echoed as the polyline the finger travelled would paint a box the size of
    // the whole wander for one round trip, then snap to the real one.
    strokes.append(
      RemoteDrawStroke(
        id: id, type: stroke.tool.rawValue, points: space.boardPreview?(committed) ?? committed, style: stroke.style,
        isLocalEcho: true, isBoardSpace: space.boardPreview != nil))

    let pending = PendingCommit(
      request: RemoteDrawCommitRequest(
        senderToken: senderToken, clientStrokeId: id, sequence: commitSequence,
        tool: stroke.tool, points: space.project(committed), style: stroke.style,
        phoneProjection: space.phoneProjection, annotationRevision: stroke.annotationRevision), space: space)
    drawingOperations[id] = .pending
    pendingCommits.append(pending)
    return try await deliverCommit(pending, offerSuggestion: true)
  }

  /// Abandons the live stroke without committing it — a palm landing, a pinch
  /// starting, the surface going away mid-stroke.
  public func cancelStroke(stroke id: RemoteDrawStrokeID? = nil) async {
    guard let active = activeStroke, id == nil || active.id == id else { return }
    activeStroke = nil
    strokePoints = []
    live = nil
    stopDraftDrain()
    if case .ended = phase {} else { phase = .ready }
    try? await clearDraftRequest()
  }

  private func replaceEcho(
    id: String,
    with result: RemoteDrawCommitResult,
    fallbackStyle: RemoteDrawDrawingStyle?,
    space: RemoteDrawStrokeSpace
  ) {
    guard let index = strokes.firstIndex(where: { $0.id == id }) else { return }
    guard let points = result.points, let serverId = result.id else {
      strokes[index] = RemoteDrawStroke(
        id: strokes[index].id, type: strokes[index].type, points: strokes[index].points,
        text: strokes[index].text, style: strokes[index].style, isLocalEcho: false,
        isBoardSpace: strokes[index].isBoardSpace)
      return
    }
    strokes[index] = RemoteDrawStroke(
      id: serverId,
      type: result.type ?? strokes[index].type,
      points: points,
      text: result.text,
      style: result.style ?? fallbackStyle,
      isLocalEcho: false,
      isBoardSpace: space.isBoardSpace
    )
  }

  /// The space in force right now. Asked per draft and per commit, never frozen
  /// — see ``RemoteDrawStrokeSpace``.
  private func currentStrokeSpace() -> RemoteDrawStrokeSpace {
    if let strokeSpace { return strokeSpace() }
    // A static board with a movable window has a window before the host ever
    // moves it: the server's opening projection, which it projects commits
    // through. Fall back to that snapshot so the settled reply is known to be
    // board-space. The same window travels on the wire, so a sender allowed to
    // move the viewport is projected through exactly the window this space
    // unprojects with (the server only promotes it if it is not older than its
    // own); one that is not keeps the token's window, which the snapshot is.
    if session?.target?.staticBackground != nil, session?.target?.mapsInputToSurface != true,
      let window = projection ?? session?.phoneProjection {
      return RemoteDrawStrokeSpace(phoneProjection: window, isBoardSpace: true,
        unproject: { RemoteDrawStaticBackground.phonePoint($0, projection: window) })
    }
    return RemoteDrawStrokeSpace(phoneProjection: projection, isBoardSpace: false)
  }

  // MARK: - Draft pacing

  private func renewUnchangedDraftIfNeeded() {
    guard foreground, maintenanceError == nil, pendingDraft == nil, draftTask == nil,
      pollClock.now - lastDraftSentAtMonotonic >= Self.unchangedDraftRenewalInterval,
      Date() >= draftNotBefore, draftHTTPDelay == 0 else { return }
    // Neither a new geometry offer nor a renewed refusal replay budget.
    enqueueDraft()
  }

  private var draftHTTPDelay: TimeInterval {
    guard let floor = draftHTTPNotBefore, floor.generation == credentialGeneration else { return 0 }
    return max(0, floor.until - pollClock.now)
  }

  private func holdDrafts(afterHTTPError error: RemoteDrawError, credentialGeneration requestGeneration: Int) {
    guard requestGeneration == credentialGeneration,
      case .rateLimited(let after, _) = error, after.isFinite, after > 0 else { return }
    let until = pollClock.now + after
    let previous = draftHTTPNotBefore?.generation == requestGeneration
      ? draftHTTPNotBefore?.until ?? -.infinity : -.infinity
    draftHTTPNotBefore = (requestGeneration, max(previous, until))
  }

  /// Rotation must wake a quota wait owned by the previous credential. Keep
  /// only the latest queued geometry, with the same cadence and replay budget.
  private func restartDraftHTTPWaitAfterCredentialRotation() {
    guard cancelDraftHTTPWait() else { return }
    if pendingDraft != nil { startDraftDrain() }
  }

  /// Pause a quota wait without discarding the latest geometry or its floor.
  @discardableResult
  private func cancelDraftHTTPWait() -> Bool {
    guard draftHTTPWaitingGeneration == draftGeneration else { return false }
    draftGeneration += 1
    draftTask?.cancel()
    draftTask = nil
    draftHTTPWaitingGeneration = nil
    return true
  }

  /// Queues the newest state of the stroke.
  ///
  /// **Latest-only, never a backlog.** A draft describes where the finger *is*,
  /// so a frame that arrives while one is in flight replaces the waiting one
  /// rather than joining a queue: sending a stale position late is worse than
  /// not sending it, and a backlog would keep paying for frames the finger has
  /// already moved past.
  private func enqueueDraft() {
    guard let stroke = activeStroke, !strokePoints.isEmpty else { return }
    pendingDraft = PendingDraft(
      annotationRevision: stroke.annotationRevision, tool: stroke.tool, style: stroke.style, points: strokePoints, text: nil)
    startDraftDrain()
  }

  private func startDraftDrain() {
    guard foreground, draftTask == nil else { return }
    let generation = draftGeneration
    draftTask = Task { [weak self] in
      await self?.drainDrafts(generation: generation)
    }
  }

  private func stopDraftDrain() {
    draftGeneration += 1
    draftTask?.cancel()
    draftTask = nil
    draftHTTPWaitingGeneration = nil
    pendingDraft = nil
    draftRefusalReplays = 0
  }

  /// Sends at most one frame per ``effectiveDraftInterval`` (32 ms unless the
  /// session negotiated otherwise), measured from the last send rather than
  /// from the last completion. There is one HTTP request in flight: at
  /// 100/200 ms RTT the ceiling is approximately 10/5 Hz, not 31 Hz, and no tier
  /// changes that. The interval is re-read on every pass, so a downgrade takes
  /// effect at the next frame. A faster transport needs its own ordered
  /// sequencing contract; commits retain priority.
  private func drainDrafts(generation: Int) async {
    defer {
      // A canceled HTTP transport may finish after the next stroke starts.
      // It must not clear that stroke's drain ownership.
      if generation == draftGeneration {
        draftTask = nil
        draftHTTPWaitingGeneration = nil
      }
    }
    while !Task.isCancelled, let queued = pendingDraft {
      guard foreground else { return }
      let httpWait = draftHTTPDelay
      if httpWait > 0 {
        draftHTTPWaitingGeneration = generation
        // Preserve the complete floor without converting an untrusted large
        // delay into an overflowing sleep duration.
        do { try await pollClock.sleep(seconds: min(httpWait, 60)) }
        catch { return }
        if Task.isCancelled { return }
        draftHTTPWaitingGeneration = nil
        // Geometry and credentials may have changed while waiting.
        continue
      }
      let now = Date()
      let wait = max(
        effectiveDraftInterval - now.timeIntervalSince(lastDraftSentAt),
        draftNotBefore.timeIntervalSince(now))
      if wait > 0 {
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        if Task.isCancelled { return }
        // The stroke may have grown while we waited; take the newest state.
        continue
      }
      pendingDraft = nil
      lastDraftSentAt = Date()
      lastDraftSentAtMonotonic = pollClock.now
      await sendDraft(queued, generation: generation)
    }
  }

  private func sendDraft(_ queued: PendingDraft, generation: Int) async {
    let draftSequence = nextSequence()
    let space = currentStrokeSpace()
    let requestGeneration = credentialGeneration
    let snapshotsAtStart = liveUpdateSnapshots
    let diagnosing = recordsDraftDiagnostics
    let diagnosticsEpoch = draftDiagnosticsEpoch
    let sendStartedAt = diagnosing ? ProcessInfo.processInfo.systemUptime : 0
    if diagnosing { draftDiagnostics.recordSend(at: sendStartedAt) }
    do {
      let ack = try await transport.updateDraft(
        RemoteDrawDraftRequest(
          senderToken: senderToken,
          sequence: draftSequence,
          tool: queued.tool,
          // Projected here and nowhere earlier: the queued buffer is the same
          // surface-space array the renderer is drawing from, and a map board
          // re-reads its camera on every one of these.
          points: space.project(queued.points),
          style: queued.style,
          text: queued.text,
          phoneProjection: space.phoneProjection,
          annotationRevision: queued.annotationRevision
        ))
      if diagnosing, diagnosticsEpoch == draftDiagnosticsEpoch {
        draftDiagnostics.recordAnswer(ack, roundTrip: ProcessInfo.processInfo.systemUptime - sendStartedAt)
      }
      // Before the cancellation check: ending a stroke cancels its drain, and
      // the answer to its last frame is the usual place a downgrade or a
      // `retryAfterMs` arrives. Dropping it would start the next stroke at the
      // old rate. Only the state and the wait survive a cancelled drain — the
      // re-offer is refused by the generation check in ``backOffDrafts``.
      adoptAnsweredLiveUpdate(ack, credentialGeneration: requestGeneration,
        sequence: draftSequence, snapshotsAtStart: snapshotsAtStart)
      if ack.isLiveUpdateRateLimited, !ack.isStaleSequence, requestGeneration == credentialGeneration {
        backOffDrafts(afterRefusal: ack, generation: generation)
      }
      guard !Task.isCancelled, !isEnded, requestGeneration == credentialGeneration else { return }
      // Self-healing by design: the rejection carries the counter to beat, so a
      // resumed sender adopts it here instead of bouncing every frame until
      // something else happens to re-read the session.
      if ack.isStaleSequence {
        let hasUsableCounter = adoptServerSequence(ack.lastSequence)
        // A useful counter can recover a stationary finger too. Re-offer the
        // current stroke with a fresh sequence, sharing the bounded refusal
        // budget so alternating stale/rate answers cannot loop indefinitely.
        if hasUsableCounter, let lastSequence = ack.lastSequence, lastSequence >= draftSequence {
          reofferDraft(afterRefusalIn: generation)
        }
      } else if ack.isLiveUpdateRateLimited {
        // Handled above.
      } else if !ack.accepted, let reason = ack.reason {
        lastError = .server(status: 200, code: reason, message: nil)
      } else {
        lastError = nil
      }
      if ack.accepted { draftRefusalReplays = 0 }
    } catch {
      if diagnosing, diagnosticsEpoch == draftDiagnosticsEpoch { draftDiagnostics.failed += 1 }
      let remoteError = normalize(error)
      // Pen-up cancels the drain, but a transport may still return a refusal.
      // Its wait applies to the next stroke on this credential; recovery and
      // stroke-specific work remain canceled below.
      holdDrafts(afterHTTPError: remoteError, credentialGeneration: requestGeneration)
      guard !Task.isCancelled else { return }
      try? await recover(from: remoteError, generation: requestGeneration)
    }
  }

  /// A `live_update_rate` refusal: the server's experimental ceiling says wait.
  ///
  /// Not an error — nothing was stored, charged or advanced, and ``lastError``
  /// is left alone. The next draft waits out `retryAfterMs` (at least one
  /// interval, at most ``maxDraftBackoff``). If the finger has not moved since,
  /// nothing newer is queued and the board would keep the older frame, so the
  /// stroke's *current* state is re-offered — rebuilt from the buffer, never
  /// the refused request, and only for the stroke that was refused. At most
  /// ``maxDraftRefusalReplays`` times in a row, shared with sequence recovery.
  private func backOffDrafts(afterRefusal ack: RemoteDrawDraftAck, generation: Int) {
    holdDrafts(afterRefusal: ack)
    reofferDraft(afterRefusalIn: generation)
  }

  private func reofferDraft(afterRefusalIn generation: Int) {
    guard generation == draftGeneration, pendingDraft == nil,
      draftRefusalReplays < Self.maxDraftRefusalReplays else { return }
    draftRefusalReplays += 1
    enqueueDraft()
  }

  /// The wait half of a `live_update_rate` refusal, shared by stroke and text
  /// drafts: `retryAfterMs`, at least one interval, at most ``maxDraftBackoff``.
  private func holdDrafts(afterRefusal ack: RemoteDrawDraftAck) {
    let hinted = ack.retryAfterMs.flatMap { $0.isFinite && $0 > 0 ? $0 / 1000 : nil }
    let delay = min(max(hinted ?? 0, effectiveDraftInterval), Self.maxDraftBackoff)
    draftNotBefore = max(draftNotBefore, Date().addingTimeInterval(delay))
  }

  private func clearDraftRequest() async throws {
    _ = try await transport.clearDraft(senderToken: senderToken, sequence: nextSequence())
  }

  // MARK: - Text

  /// Shows where a text annotation is about to land, without committing it.
  ///
  /// A draft rather than a commit because placing text is a conversation: the
  /// person is looking at the board while they type, and the board should show
  /// them what they are about to say.
  public func draftText(_ text: String, at point: RemoteDrawNormalizedPoint) async {
    guard capabilities.contains(.draw), session?.annotationInput?.paused != true else { return }
    if !hasTextDraft { textDraftAnnotationRevision = session?.annotationInput?.revision; hasTextDraft = true }
    guard textDraftAnnotationRevision == session?.annotationInput?.revision else { return }
    // A caption is paced like a stroke: inside a server draft wait this
    // keystroke is dropped, never queued or replayed — the next keystroke or
    // the commit carries the text. Distant past on a session never refused.
    guard Date() >= draftNotBefore, draftHTTPDelay == 0 else { return }
    let space = currentStrokeSpace()
    let requestGeneration = credentialGeneration
    let snapshotsAtStart = liveUpdateSnapshots
    let draftSequence = nextSequence()
    let ack: RemoteDrawDraftAck
    do {
      ack = try await transport.updateDraft(
        RemoteDrawDraftRequest(
          senderToken: senderToken,
          sequence: draftSequence,
          tool: .text,
          points: space.project([point]),
          style: nil,
          text: text,
          phoneProjection: space.phoneProjection, annotationRevision: textDraftAnnotationRevision
        ))
    } catch {
      holdDrafts(afterHTTPError: normalize(error), credentialGeneration: requestGeneration)
      return
    }
    guard !isEnded, requestGeneration == credentialGeneration else { return }
    adoptAnsweredLiveUpdate(ack, credentialGeneration: requestGeneration,
      sequence: draftSequence, snapshotsAtStart: snapshotsAtStart)
    if ack.isStaleSequence { adoptServerSequence(ack.lastSequence) }
    if ack.isLiveUpdateRateLimited { holdDrafts(afterRefusal: ack) }
  }

  /// Commits a text annotation at a point.
  ///
  /// Its own call rather than a flag on ``end(stroke:)`` because text has no
  /// stroke: there is one point, no pressure, no velocity and nothing to
  /// decimate. Folding it into the stroke path would mean a buffer that is
  /// sometimes geometry and sometimes a caption.
  @discardableResult
  public func commitText(
    _ text: String,
    at point: RemoteDrawNormalizedPoint,
    style: RemoteDrawInkStyle? = nil
  ) async throws -> RemoteDrawCommitResult? {
    try requireCapability(.draw)
    let annotationRevision = hasTextDraft ? textDraftAnnotationRevision : session?.annotationInput?.revision
    defer { resetTextDraft() }
    guard session?.annotationInput?.paused != true, annotationRevision == session?.annotationInput?.revision else {
      throw RemoteDrawError.server(status: 409, code: "annotation_revision_conflict", message: "The drawing region moved. Place the note again.")
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      try? await clearDraftRequest()
      return nil
    }
    try requireCommitCapacity()
    let id = "ios-\(UUID().uuidString)"
    let space = currentStrokeSpace()
    let commitSequence = nextSequence()
    strokes.append(
      RemoteDrawStroke(
        id: id, type: RemoteDrawTool.text.rawValue, points: space.boardPreview?([point]) ?? [point], text: trimmed,
        style: style, isLocalEcho: true, isBoardSpace: space.boardPreview != nil))
    let pending = PendingCommit(
      request: RemoteDrawCommitRequest(
        senderToken: senderToken, clientStrokeId: id, sequence: commitSequence,
        tool: .text, points: space.project([point]), style: style, text: trimmed,
        phoneProjection: space.phoneProjection, annotationRevision: annotationRevision), space: space)
    drawingOperations[id] = .pending
    pendingCommits.append(pending)
    return try await deliverCommit(pending)
  }

  private func resetTextDraft() {
    hasTextDraft = false
    textDraftAnnotationRevision = nil
  }

  private func requireCommitCapacity() throws {
    guard !isEnded else { throw RemoteDrawError.sessionEnded }
    guard !handingOff else { throw RemoteDrawError.transport("Sender mode is changing; no new work was sent.") }
    guard pendingCommits.count < Self.maxPendingCommits else {
      throw RemoteDrawError.server(status: 409, code: "pending_commit_limit",
        message: "Reconnect to deliver pending ink before adding more strokes.")
    }
  }

  private func deliverCommit(_ pending: PendingCommit, offerSuggestion: Bool = false)
    async throws -> RemoteDrawCommitResult
  {
    let id = pending.request.clientStrokeId
    commitsInFlight.insert(id)
    defer {
      commitsInFlight.remove(id)
      if commitsInFlight.isEmpty {
        let waiters = commitDrainWaiters
        commitDrainWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
      }
    }
    var requestGeneration = credentialGeneration
    do {
      // One credential recovery, then replay only the idempotent commit.
      let result: RemoteDrawCommitResult
      do {
        result = try await sendRetainedCommit(pending, generation: &requestGeneration)
      } catch {
        let remoteError = normalize(error)
        try await recover(from: remoteError, generation: requestGeneration)
        guard remoteError.shouldReJoin, !isEnded,
          requestGeneration != credentialGeneration else { throw error }
        result = try await sendRetainedCommit(pending, generation: &requestGeneration)
      }
      guard !isEnded else { throw RemoteDrawError.sessionEnded }
      if let serverID = result.id {
        pendingCommits.removeAll { $0.request.clientStrokeId == id }
        acknowledgedDrawingIDs[id] = serverID
        drawingOperations[id] = removedDrawingIDs.contains(serverID) ? .removed : .acknowledged
        if observedDrawingIDs.contains(serverID) || removedDrawingIDs.contains(serverID) {
          strokes.removeAll { $0.id == id }
        } else {
          replaceEcho(id: id, with: result, fallbackStyle: pending.request.style, space: pending.space)
        }
      }
      // A successful response without an ID cannot prove which drawing landed.
      // Leave the preview pending rather than presenting it as saved.
      if offerSuggestion, activeStroke == nil, !result.isDuplicate,
        let suggestion = result.suggestion, let strokeId = result.id {
        shapeSuggestion = RemoteDrawShapeOffer(strokeId: strokeId, suggestion: suggestion,
          style: result.style ?? pending.request.style, isBoardSpace: pending.space.isBoardSpace)
      }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      if !remoteError.isRetriable && !remoteError.shouldReJoin {
        pendingCommits.removeAll { $0.request.clientStrokeId == id }
        drawingOperations[id] = .failed
        strokes.removeAll { $0.id == id }
      }
      try await recover(from: remoteError, generation: requestGeneration)
      throw error
    }
  }

  private func sendRetainedCommit(_ pending: PendingCommit, generation: inout Int)
    async throws -> RemoteDrawCommitResult
  {
    try await retryIdempotentRequest {
      try Task.checkCancellation()
      guard !isEnded else { throw RemoteDrawError.sessionEnded }
      generation = credentialGeneration
      var request = pending.request
      request.senderToken = senderToken
      return try await transport.commitStroke(request)
    }
  }

  /// Retries retained ink with its original idempotency key and wire geometry.
  /// Heartbeats and foreground activation call this after connectivity returns.
  /// Retention is bounded and session-local; it does not survive process exit.
  public func retryPendingCommits() async {
    guard !isEnded, !drainingCommits else { return }
    drainingCommits = true
    defer { drainingCommits = false }
    for pending in pendingCommits {
      guard !isEnded, !Task.isCancelled else { break }
      let id = pending.request.clientStrokeId
      guard pendingCommits.contains(where: { $0.request.clientStrokeId == id }),
        !commitsInFlight.contains(id) else { continue }
      do { _ = try await deliverCommit(pending) } catch { break }
    }
  }

  // MARK: - Shape snapping

  /// Accepts the board's offer and replaces the stroke with the straightened
  /// shape.
  ///
  /// Idempotent from the caller's side: the offer is cleared first, so a double
  /// tap on the pill posts once.
  ///
  /// The replacement rides the *same* style, which is the whole reason this is
  /// a replace and not a delete-and-draw — a snapped rectangle drawn in pencil
  /// is still pencil, tooth and grain and all, because
  /// ``RemoteDrawStrokePainter`` runs shape geometry through the same freehand
  /// assembler.
  @discardableResult
  public func applyShapeSuggestion() async throws -> RemoteDrawReplaceResult? {
    guard let offer = shapeSuggestion else { return nil }
    shapeSuggestion = nil
    let result = try await replaceStroke(
      id: offer.strokeId,
      tool: offer.suggestion.replacementTool,
      points: offer.suggestion.points,
      style: offer.style,
      isBoardSpace: offer.isBoardSpace
    )
    return result
  }

  /// Turns the offer down. Nothing is sent — the stroke already stands as drawn.
  public func dismissShapeSuggestion() {
    shapeSuggestion = nil
  }

  /// Replaces a committed stroke's geometry in place.
  ///
  /// - Parameter isBoardSpace: whether `points` are already board coordinates.
  ///   `false` runs them through the current
  ///   ``RemoteDrawStrokeSpace/project``. A shape suggestion arrives in the
  ///   space the commit was posted in, which is why the offer carries the
  ///   answer rather than making the caller guess.
  ///
  /// Not idempotent and deliberately not retried: a replace is keyed on the
  /// stroke, so a retry after a *successful* call that lost its response would
  /// replace geometry the board had already replaced. One attempt, and the
  /// stroke that stands is the one the person drew.
  @discardableResult
  public func replaceStroke(
    id strokeId: String,
    tool: RemoteDrawTool,
    points: [RemoteDrawNormalizedPoint],
    style: RemoteDrawDrawingStyle? = nil,
    isBoardSpace: Bool = true
  ) async throws -> RemoteDrawReplaceResult {
    try requireCapability(.draw)
    let space = currentStrokeSpace()
    let wirePoints = isBoardSpace ? points : space.project(points)
    let requestGeneration = credentialGeneration
    do {
      let result = try await transport.replaceStroke(
        RemoteDrawReplaceRequest(
          senderToken: senderToken,
          strokeId: strokeId,
          tool: tool.rawValue,
          points: wirePoints,
          style: style
        ))
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      drawingReadRevision += 1
      if result.accepted, let index = strokes.firstIndex(where: { $0.id == strokeId }) {
        strokes[index] = RemoteDrawStroke(
          id: result.id ?? strokeId,
          type: result.type ?? tool.rawValue,
          points: result.points ?? wirePoints,
          text: strokes[index].text,
          style: result.style ?? style ?? strokes[index].style,
          isLocalEcho: false,
          isBoardSpace: space.isBoardSpace || isBoardSpace
        )
      }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError, generation: requestGeneration)
      throw remoteError
    }
  }

  // MARK: - Board controls

  public func undo() async throws -> RemoteDrawUndoResult {
    try requireCapability(.undo)
    await retryPendingCommits()
    guard pendingCommits.isEmpty else {
      throw lastError ?? RemoteDrawError.offline
    }
    let requestGeneration = credentialGeneration
    do {
      let result = try await transport.undo(senderToken: senderToken)
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      drawingReadRevision += 1
      if result.removed, result.undone == nil || result.undone == "create", let id = result.drawingId {
        removeDrawing(id)
      }
      if capabilities.contains(.viewExisting) { _ = try? await refreshDrawings() }
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError, generation: requestGeneration)
      throw remoteError
    }
  }

  public func clear() async throws -> RemoteDrawClearResult {
    try requireCapability(.clear)
    await retryPendingCommits()
    guard pendingCommits.isEmpty else {
      throw lastError ?? RemoteDrawError.offline
    }
    let requestGeneration = credentialGeneration
    do {
      let result = try await transport.clear(senderToken: senderToken)
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      drawingReadRevision += 1
      for id in strokes.map(\.id) { removeDrawing(id) }
      for id in acknowledgedDrawingIDs.values { removeDrawing(id) }
      strokes = []
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError, generation: requestGeneration)
      throw remoteError
    }
  }

  /// Submits the drawing.
  ///
  /// Idempotent on `clientSubmissionId`, which is generated here and reused
  /// across the three retry attempts, so a submission lost to a dropped radio
  /// is resent rather than double-counted.
  @discardableResult
  public func submit(metadata: [String: RemoteDrawJSONValue]? = nil) async throws
    -> RemoteDrawReceipt
  {
    // No capability gate: the server accepts a submit from any live sender and
    // never lists "submit" among the session's capabilities.
    try requireLive()
    await retryPendingCommits()
    guard pendingCommits.isEmpty else {
      throw lastError ?? RemoteDrawError.offline
    }
    let submissionId = "ios-\(UUID().uuidString)"
    var requestGeneration = credentialGeneration
    do {
      let receipt = try await retryIdempotentRequest {
        requestGeneration = credentialGeneration
        return try await transport.submit(
          senderToken: senderToken, clientSubmissionId: submissionId, metadata: metadata)
      }
      phase = .submitted
      lastError = nil
      return receipt
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError, generation: requestGeneration)
      throw remoteError
    }
  }

  /// Re-reads the board's committed elements.
  @discardableResult
  public func refreshDrawings() async throws -> [RemoteDrawDrawing] {
    try requireMaintenanceAdmission()
    let epoch = syncEpoch
    let generation = credentialGeneration
    do {
      return try await readDrawings(revision: observedRevision(\.drawings))
    } catch {
      if !(error is CancellationError), epoch == syncEpoch, generation == credentialGeneration, !isEnded {
        await recordMaintenanceFailure(error, generation: generation)
      }
      throw error
    }
  }

  /// An interactive write invalidates the owned snapshot; the existing sync
  /// loop services it. Multiple commits before the next tick buy one snapshot,
  /// not a new sync/read pair for each app callback.
  public func requestDrawingsRefresh() {
    guard !isEnded else { return }
    drawingReadRevision += 1
    drawingsCursor = nil
  }

  /// Same ordering rule as ``readSession(revision:)``. The cursor advances only
  /// when this read is the one published: a read superseded by a local edit or a
  /// newer read proves nothing about what is on screen.
  @discardableResult
  private func readDrawings(revision: (value: String, epoch: Int)?) async throws
    -> [RemoteDrawDrawing]
  {
    try requireCapability(.viewExisting, isMaintenance: true)
    if let existing = drawingsReadTask {
      let taskID = drawingsReadTaskID
      let before = drawingsReadTaskRevision
      let epoch = syncEpoch
      let result = try await existing.value
      guard !isEnded, epoch == syncEpoch else { throw CancellationError() }
      if before != drawingReadRevision {
        // An undo/edit joined a read that left before the write. Its discarded
        // answer is not refresh completion; share one *post-write* read.
        if taskID == drawingsReadTaskID { drawingsReadTask = nil }
        return try await readDrawings(revision: revision)
      }
      return result
    }
    drawingsReadTaskID += 1
    drawingsReadTaskRevision = drawingReadRevision
    let taskID = drawingsReadTaskID
    let task = Task { try await self.performDrawingsRead(revision: revision) }
    drawingsReadTask = task
    defer { if taskID == drawingsReadTaskID { drawingsReadTask = nil } }
    return try await task.value
  }

  private func performDrawingsRead(revision: (value: String, epoch: Int)?) async throws
    -> [RemoteDrawDrawing]
  {
    let epoch = syncEpoch
    let startedAt = pollClock.now
    nextSnapshotRead += 1
    let snapshotRead = nextSnapshotRead
    nextDrawingRead += 1
    let readID = nextDrawingRead
    let readRevision = drawingReadRevision
    let requestGeneration = credentialGeneration
    let settledBeforeRead = Set(strokes.filter { !$0.isLocalEcho }.map(\.id))
    let acknowledgedBeforeRead = acknowledgedOperationIDs
    let answersAtStart = liveUpdateAnswers
    let response = try await transport.drawings(senderToken: senderToken)
    try Task.checkCancellation()
    guard !isEnded, requestGeneration == credentialGeneration, epoch == syncEpoch,
      capabilities.contains(.viewExisting) else { throw CancellationError() }
    guard readRevision == drawingReadRevision, readID >= lastPublishedDrawingRead else {
      return response.items.paintable
    }
    if let incoming = response.session, let current = session {
      guard incoming.id == current.id, incoming.geometryRevision >= current.geometryRevision,
        (incoming.annotationInput?.revision ?? 0) >= (current.annotationInput?.revision ?? 0)
      else { return [] }
    }
    lastPublishedDrawingRead = readID
    if let revision, revision.epoch == syncEpoch { drawingsCursor = revision.value }
    if let session = response.session {
      adoptSessionSnapshot(session, readID: snapshotRead, startedAt: startedAt,
        liveUpdateAnswersAtStart: answersAtStart)
    }
    let existing = response.items.paintable
    let ids = Set(existing.map(\.id))
    reconcileDrawingIDs(Set(response.items.map(\.id)), acknowledgedBeforeRead: acknowledgedBeforeRead)
    let echoes = strokes.filter { ($0.isLocalEcho || !settledBeforeRead.contains($0.id)) && !ids.contains($0.id) }
    strokes = existing.map { drawing in
      RemoteDrawStroke(id: drawing.id, type: drawing.type, points: drawing.points,
        text: drawing.text, imageUrl: drawing.imageUrl, style: drawing.style, isBoardSpace: true)
    } + echoes
    drawingSnapshot = response
    return existing
  }

  /// Moves or deletes elements already on the board.
  ///
  /// Returns the outcome rather than a `Bool` because the interesting case is
  /// neither success nor a thrown error: it is a 200 that says
  /// `accepted: false`. The caller owns the selection, so the caller is the only
  /// party that can decide what to drop.
  @discardableResult
  public func edit(_ edit: RemoteDrawElementEdit) async throws -> RemoteDrawEditResult {
    try requireCapability(.editElements)
    let requestGeneration = credentialGeneration
    do {
      let result = try await transport.editElements(senderToken: senderToken, edit: edit)
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      drawingReadRevision += 1
      for element in result.elements where element.removed == true { removeDrawing(element.drawingId) }
      // Points on the drawings endpoint already include the authoritative edit.
      if capabilities.contains(.viewExisting) { _ = try? await refreshDrawings() }
      guard !isEnded, requestGeneration == credentialGeneration else { throw RemoteDrawError.sessionEnded }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError, generation: requestGeneration)
      throw remoteError
    }
  }

  /// Moves the phone's window on the board.
  ///
  /// Returns the projection the **board** now holds, which is not always the
  /// one that was sent: the receiver clamps a window to the board's bounds and
  /// stamps `updatedAt`. A caller that keeps showing what it asked for rather
  /// than what it got drifts out of agreement with the board it is a window
  /// onto, one clamped drag at a time.
  @discardableResult
  public func updateProjection(_ next: RemoteDrawProjection) async throws
    -> RemoteDrawProjection
  {
    try requireCapability(.moveViewport)
    projectionGeneration += 1
    let generation = projectionGeneration
    projection = next
    let resolved = try await transport.updateProjection(
      senderToken: senderToken, projection: next)
    // Only the newest call owns the window; an older reply landing late would
    // put ink through a window the person has already moved away from.
    if generation == projectionGeneration, !isEnded { projection = resolved }
    return resolved
  }

  /// Takes the live draft off the board without committing anything.
  ///
  /// ``cancelStroke()`` is the call for abandoning a *stroke*; this is for the
  /// draft alone — a text composer that was emptied, a placement the person
  /// backed out of. Non-throwing because there is nothing a caller could do
  /// about a failure: the draft expires on the receiver regardless, and
  /// reporting it would put an error on screen for something the person already
  /// stopped caring about.
  public func clearDraft() async {
    guard !isEnded else { return }
    try? await clearDraftRequest()
  }

  /// Leaves cleanly: closes the projection, stops the heartbeat, drops the
  /// live stroke.
  ///
  /// Not optional housekeeping. Presence is a heartbeat and not a leave signal,
  /// so a phone that just goes quiet keeps showing as connected on the board for
  /// up to a minute — the customer's board would lie about who is present.
  public func leave() {
    disconnectOnCompletion = true
    stopLocally()
    disconnect(senderToken)
  }

  private func disconnect(_ token: String) {
    let transport = self.transport
    Task.detached {
      try? await transport.closeProjection(senderToken: token, disconnect: true)
    }
  }

  /// Stops local ownership without revoking the credential used by another UI.
  public func stopLocally() {
    live = nil
    activeStroke = nil
    strokePoints = []
    end(.left)
  }

  /// Completes an already-started rotation before handing its credential over.
  public func handoff() async throws -> String {
    guard !handingOff else { throw RemoteDrawError.transport("A sender handoff is already in progress.") }
    guard maintenanceError == nil else { throw maintenanceError! }
    // Do not discard a finger-down stroke. Ask the host to finish it first.
    guard activeStroke == nil, !hasTextDraft else { throw RemoteDrawError.transport("Finish the current stroke or text before switching sender mode.") }
    handingOff = true
    let oldTasks = [syncTask, initialDrawingsTask, legacySessionTask, legacyDrawingsTask, heartbeatTask].compactMap { $0 }
    let oldRead = drawingsReadTask
    let oldPresence = presenceRequest
    stopHeartbeat()
    var transferred = false
    defer {
      handingOff = false
      if !transferred, !isEnded, foreground { startHeartbeat() }
    }
    if let refreshTask { _ = await refreshTask.value }
    guard !isEnded else { throw lastError ?? RemoteDrawError.tokenRejected }
    if !commitsInFlight.isEmpty {
      await withCheckedContinuation { commitDrainWaiters.append($0) }
    }
    guard !isEnded else { throw lastError ?? RemoteDrawError.tokenRejected }
    await retryPendingCommits()
    guard !isEnded else { throw lastError ?? RemoteDrawError.tokenRejected }
    guard pendingCommits.isEmpty else { throw lastError ?? RemoteDrawError.offline }
    if let presenceCloseTask { await presenceCloseTask.value }
    for task in oldTasks { await task.value }
    if let oldRead { _ = try? await oldRead.value }
    if let oldPresence { _ = try? await oldPresence.value }
    guard !isEnded else { throw lastError ?? RemoteDrawError.tokenRejected }
    transferred = true
    stopLocally()
    return senderToken
  }

  // MARK: - Presence

  /// Takes this phone's window off the board without leaving the session.
  ///
  /// The distinction the `disconnect` flag on `/v1/sender/projection/close`
  /// exists for, and the SDK previously only exposed one half of. ``leave()``
  /// says "this sender is gone"; this says "stop drawing my window" — what a
  /// surface does when it goes off screen and expects to come back, so the board
  /// stops showing a phone frame hovering over nothing while the person is in
  /// another app.
  public func closeProjection() async {
    guard !isEnded else { return }
    try? await transport.closeProjection(senderToken: senderToken, disconnect: false)
  }

  /// Tells the board this sender is on screen and interacting.
  public func markActive() async {
    guard !isEnded else { return }
    foreground = true
    presenceGeneration += 1
    activationPending = true
    startHeartbeat()
    sentFirstBeat = true
    await beat()
    if !isEnded, foreground, pendingDraft != nil { startDraftDrain() }
  }

  /// Tells the board this sender went to the background. Stops the heartbeat:
  /// a backgrounded phone that keeps pinging holds a session open against the
  /// customer's quota for nothing.
  public func markInactive() async {
    guard !isEnded else { return }
    foreground = false
    cancelDraftHTTPWait()
    presenceGeneration += 1
    activationPending = false
    stopHeartbeat()
    if maintenanceError == nil { maintenanceState = .paused("Synchronization is paused while the sender is in the background.") }
    sentFirstBeat = true
    try? await transport.ping(senderToken: senderToken, active: false)
  }

  private func startHeartbeat() {
    startBoardPolling()
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task { [weak self, pollClock = self.pollClock] in
      let interval = RemoteDrawProtocolLimits.presenceInterval
      while !Task.isCancelled {
        try? await pollClock.sleep(seconds: interval)
        if Task.isCancelled { break }
        guard let sender = self else { return }
        await sender.beat()
      }
    }
  }

  // MARK: - Board polling

  /// Keeps board metadata and drawings current without paying for snapshots
  /// nobody needs.
  ///
  /// One loop asks `/v1/sender/sync` about once a second and reads
  /// `/v1/sender/session` or `/v1/sender/drawings` only when that revision moved
  /// past what this session last published. Two unconditional 0.9 s loops used
  /// to read both snapshots whether anything changed or not.
  ///
  /// Drawing never waits on this. Drafts and commits have their own tasks, and
  /// the first drawings read at session start is its own task too, so a slow
  /// sync cannot hold back the first paint of an existing board.
  private func startBoardPolling() {
    guard foreground, !isEnded else { return }
    if !startedInitialDrawingsRead, automaticallyRefreshDrawings,
      capabilities.contains(.viewExisting), pollClock.now >= maintenanceRetryAt
    {
      startedInitialDrawingsRead = true
      // No cursor: this read may have started before the board's revision was
      // known, so it cannot prove which revision it shows. The first sync
      // therefore reads once more, and from then on only on change.
      initialDrawingsTask = Task { [weak self] in
        _ = try? await self?.refreshDrawings()
      }
    }
    if syncUnsupported {
      startLegacyPolling(readDrawingsImmediately: true)
      return
    }
    guard syncTask == nil else { return }
    let initialDelay = max(maintenanceRetryAt - pollClock.now,
      lastSyncStartedAt.map { max(0, $0 + Self.syncFloor - pollClock.now) } ?? 0)
    syncTask = Task { [weak self, pollClock = self.pollClock] in
      var delay = initialDelay
      while !Task.isCancelled {
        if delay > 0 {
          do { try await pollClock.sleep(seconds: delay) } catch { return }
        }
        // Strong only for the tick, never across the sleep.
        guard let sender = self, !Task.isCancelled,
          let next = await sender.syncTick() else { return }
        delay = next
      }
    }
  }

  /// One sync, then the reads it justifies, in order. Returns the delay before
  /// the next tick, or `nil` when this loop is finished.
  private func syncTick() async -> TimeInterval? {
    guard !isEnded, foreground else { return nil }
    if maintenanceRetryAt > pollClock.now { return maintenanceRetryAt - pollClock.now }
    let startedAt = pollClock.now
    let failureID = maintenanceFailureID
    lastSyncStartedAt = startedAt
    let epoch = syncEpoch
    let generation = credentialGeneration
    let revisions: RemoteDrawSyncRevisions
    do {
      revisions = try await transport.sync(senderToken: senderToken)
    } catch is RemoteDrawSyncUnsupportedError {
      guard !Task.isCancelled, !isEnded, epoch == syncEpoch, generation == credentialGeneration else { return nil }
      syncUnsupported = true
      syncTask = nil
      // The initial drawings read is already out; the metadata read is not.
      startLegacyPolling(readDrawingsImmediately: false)
      return nil
    } catch {
      guard !Task.isCancelled, !isEnded else { return nil }
      guard epoch == syncEpoch, generation == credentialGeneration else { return nextSyncDelay(since: startedAt) }
      await recordMaintenanceFailure(error, generation: generation)
      if isEnded { return nil }
      return nextSyncDelay(since: startedAt)
    }
    guard !Task.isCancelled, !isEnded else { return nil }
    // Answered for a credential or epoch this session has since left.
    guard epoch == syncEpoch, generation == credentialGeneration else {
      return nextSyncDelay(since: startedAt)
    }
    latestSync = SyncObservation(revisions: revisions, epoch: epoch)

    if revisions.metadata != metadataCursor {
      do {
        try await readSession(
          revision: (value: revisions.metadata, epoch: epoch), adoptGrants: true)
      }
      catch is CancellationError {
        return Task.isCancelled || !foreground || isEnded ? nil : nextSyncDelay(since: startedAt)
      }
      catch {
        guard epoch == syncEpoch, generation == credentialGeneration else { return nextSyncDelay(since: startedAt) }
        await recordMaintenanceFailure(error, generation: generation)
        return isEnded ? nil : nextSyncDelay(since: startedAt)
      }
      guard !Task.isCancelled, !isEnded else { return nil }
    }
    // Decided after the metadata read, so a grant that read removed stops this
    // read and a grant it restored resumes it (the cursor was cleared on either).
    if automaticallyRefreshDrawings, capabilities.contains(.viewExisting),
      epoch == syncEpoch, revisions.drawings != drawingsCursor
    {
      do { try await readDrawings(revision: (value: revisions.drawings, epoch: epoch)) }
      catch is CancellationError {
        return Task.isCancelled || !foreground || isEnded ? nil : nextSyncDelay(since: startedAt)
      }
      catch {
        guard epoch == syncEpoch, generation == credentialGeneration else { return nextSyncDelay(since: startedAt) }
        await recordMaintenanceFailure(error, generation: generation)
        return isEnded ? nil : nextSyncDelay(since: startedAt)
      }
      guard !Task.isCancelled, !isEnded else { return nil }
    }
    if epoch == syncEpoch, generation == credentialGeneration, failureID == maintenanceFailureID,
      metadataCursor == revisions.metadata,
      (!automaticallyRefreshDrawings || !capabilities.contains(.viewExisting) || drawingsCursor == revisions.drawings) {
      await markMaintenanceCurrent()
    }
    return nextSyncDelay(since: startedAt)
  }

  /// Period measured from the start of the tick, so slow reads do not stretch
  /// the cadence and a tick that overran starts the next one at once.
  private func nextSyncDelay(since startedAt: TimeInterval)
    -> TimeInterval
  {
    max(0, max(maintenanceRetryAt - pollClock.now, Self.syncInterval - (pollClock.now - startedAt)))
  }

  private func requireMaintenanceAdmission() throws {
    guard !isEnded, foreground else { throw CancellationError() }
    if pollClock.now < maintenanceRetryAt { throw maintenanceError ?? RemoteDrawError.offline }
  }

  /// A host adapter that cannot adopt an admitted payload must not leave a
  /// healthy presence behind. This uses the same owner/retry path, not a poll.
  public func reportSnapshotAdoptionFailure(_ message: String) {
    let generation = credentialGeneration
    let epoch = syncEpoch
    Task { [weak self] in
      guard let self, !self.isEnded, generation == self.credentialGeneration,
        epoch == self.syncEpoch, self.foreground else { return }
      self.metadataCursor = nil
      self.drawingsCursor = nil
      await self.recordMaintenanceFailure(RemoteDrawError.decoding(message), generation: generation)
    }
  }

  private func recordMaintenanceFailure(_ error: Error, generation: Int) async {
    guard !isEnded, generation == credentialGeneration else { return }
    let remote = normalize(error)
    maintenanceFailureID += 1
    maintenanceError = remote
    var delay = Self.syncInterval
    switch remote {
    case .rateLimited(let after, _):
      delay = after.isFinite ? max(delay, after) : delay
      maintenanceState = .retryLater(until: pollClock.now + delay,
        message: "Synchronization is waiting to retry. \(remote.localizedDescription)")
    case .server(_, let code, _) where code == "included_capacity_exhausted":
      delay = 30
      maintenanceState = .capacityExhausted("Synchronization is blocked by included capacity. \(remote.localizedDescription)")
    case .server(_, let code, _) where code == "billing_limit_reached" || code == "session_paused":
      delay = 30
      maintenanceState = .paused("Synchronization is paused. \(remote.localizedDescription)")
    default:
      maintenanceState = .retryLater(until: pollClock.now + delay,
        message: "Synchronization is unavailable. \(remote.localizedDescription)")
    }
    maintenanceRetryAt = max(maintenanceRetryAt, pollClock.now + delay)
    // No healthy heartbeat while geometry cannot be adopted. Closing only the
    // projection retains the credential and shared server ledger for recovery.
    presenceGeneration += 1
    activationPending = true
    if presenceCloseTask == nil {
      let token = senderToken
      let priorPing = presenceRequest
      presenceCloseTask = Task { [transport] in
        // An already-dispatched active ping can otherwise reopen the projection
        // after our close. No new beat starts while maintenanceError is set.
        if let priorPing { _ = try? await priorPing.value }
        try? await transport.closeProjection(senderToken: token, disconnect: false)
      }
    }
    try? await recover(from: remote, generation: generation)
  }

  private func markMaintenanceCurrent() async {
    let epoch = syncEpoch
    let failureID = maintenanceFailureID
    if let presenceCloseTask { await presenceCloseTask.value }
    guard !isEnded, foreground, epoch == syncEpoch, failureID == maintenanceFailureID else { return }
    presenceCloseTask = nil
    maintenanceRetryAt = -.infinity
    maintenanceError = nil
    maintenanceState = .current
  }

  /// The pre-sync behaviour, slowed to 5 s, for a transport that throws
  /// ``RemoteDrawSyncUnsupportedError``. Nothing else selects it.
  private func startLegacyPolling(readDrawingsImmediately: Bool) {
    guard legacySessionTask == nil else { return }
    legacySessionTask = Task { [weak self, pollClock = self.pollClock] in
      var delay: TimeInterval = 0
      while !Task.isCancelled {
        if delay > 0 {
          do { try await pollClock.sleep(seconds: delay) } catch { return }
        }
        guard let sender = self, !sender.isEnded, sender.foreground, !Task.isCancelled else { return }
        if sender.maintenanceRetryAt > pollClock.now {
          delay = sender.maintenanceRetryAt - pollClock.now
          continue
        }
        let epoch = sender.syncEpoch
        let generation = sender.credentialGeneration
        do {
          try await sender.readSession(revision: nil, adoptGrants: true)
          guard !Task.isCancelled else { return }
          if epoch != sender.syncEpoch { delay = Self.legacyPollInterval; continue }
          if sender.automaticallyRefreshDrawings, sender.capabilities.contains(.viewExisting) {
            try await sender.readDrawings(revision: nil)
          }
          await sender.markMaintenanceCurrent()
        } catch is CancellationError {
          if Task.isCancelled || !sender.foreground || sender.isEnded { return }
        } catch {
          if epoch == sender.syncEpoch, generation == sender.credentialGeneration {
            await sender.recordMaintenanceFailure(error, generation: generation)
          }
        }
        delay = max(Self.legacyPollInterval, sender.maintenanceRetryAt - pollClock.now)
      }
    }
  }

  /// Forgets what the cursors claimed. The next tick reads whatever it gates.
  private func invalidateSyncCursors() {
    syncEpoch += 1
    latestSync = nil
    metadataCursor = nil
    drawingsCursor = nil
  }

  private func beat() async {
    guard !isEnded, foreground, maintenanceError == nil, !handingOff, presenceRequest == nil else { return }
    sentFirstBeat = true
    let presenceRequestGeneration = presenceGeneration
    let active = activationPending
    var requestGeneration = credentialGeneration
    do {
      do {
        try await sendPresence(active: active)
      } catch {
        let remoteError = normalize(error)
        try await recover(from: remoteError, generation: requestGeneration)
        // A renewed credential alone does not reopen the receiver's projection.
        // Replay this idempotent presence update once, while the same foreground
        // intent is current. Transient failures retain activation for the next beat.
        guard !isEnded, presenceRequestGeneration == presenceGeneration,
          requestGeneration != credentialGeneration else { return }
        requestGeneration = credentialGeneration
        try await sendPresence(active: active)
      }
      guard !isEnded, presenceRequestGeneration == presenceGeneration else { return }
      if active { activationPending = false }
      await retryPendingCommits()
    } catch {
      let remoteError = normalize(error)
      try? await recover(from: remoteError, generation: requestGeneration)
    }
  }

  private func sendPresence(active: Bool) async throws {
    let token = senderToken
    let task = Task { [transport] in try await transport.ping(senderToken: token, active: active) }
    presenceRequest = task
    defer { presenceRequest = nil }
    try await task.value
  }

  private func stopHeartbeat() {
    drawingsReadTask?.cancel()
    drawingsReadTask = nil
    drawingsReadTaskID += 1
    syncTask?.cancel()
    syncTask = nil
    initialDrawingsTask?.cancel()
    initialDrawingsTask = nil
    legacySessionTask?.cancel()
    legacySessionTask = nil
    legacyDrawingsTask?.cancel()
    legacyDrawingsTask = nil
    heartbeatTask?.cancel()
    heartbeatTask = nil
    // Whatever happens while nothing polls is unobserved, so a resume reads once
    // rather than trusting a revision from before the gap.
    invalidateSyncCursors()
  }

  // MARK: - Recovery

  /// Shares SDK credential recovery with host-owned sender requests.
  /// Pass the token captured before the failed request. A late rejection for
  /// an older credential is already recovered; it must not rotate the new one.
  /// This never repeats the host operation (which may be non-idempotent).
  @discardableResult
  public func recoverRejectedCredential(_ rejectedToken: String) async -> Bool {
    guard !isEnded else { return false }
    guard rejectedToken == senderToken else { return true }
    try? await recover(from: .tokenRejected, generation: credentialGeneration)
    return !isEnded && rejectedToken != senderToken
  }

  private func requireLive(isMaintenance: Bool = false) throws {
    guard !isEnded else { throw RemoteDrawError.sessionEnded }
    guard !handingOff else { throw RemoteDrawError.transport("Sender mode is changing; no new work was sent.") }
    if !isMaintenance, let maintenanceError { throw maintenanceError }
  }

  private func requireCapability(_ capability: RemoteDrawCapability, isMaintenance: Bool = false) throws {
    try requireLive(isMaintenance: isMaintenance)
    guard capabilities.contains(capability) else {
      throw RemoteDrawError.notPermitted(capability)
    }
  }

  private func normalize(_ error: Error) -> RemoteDrawError {
    (error as? RemoteDrawError) ?? .transport(error.localizedDescription)
  }

  /// What to do about a failure, in the order the plan specifies.
  ///
  /// 1. A dead session is terminal. `session_not_active` and a spent join token
  ///    are deliberately *not* re-join cases: re-joining either loops forever.
  /// 2. A 403 is terminal for that call and harmless for the session — the
  ///    credential was fine, the grant was not.
  /// 3. A rejected credential rotates via `POST /v1/sender/refresh`, then falls
  ///    back to the host's `tokenProvider`. **Never a silent re-join**:
  ///    `/v1/join` revokes every other active sender on the session, so healing
  ///    this device would kick another one off the board.
  private func recover(from error: RemoteDrawError, generation: Int) async throws {
    guard !isEnded, generation == credentialGeneration else { return }
    lastError = refinedSessionEnd(error)
    switch lastError ?? error {
    case .sessionEnded, .sessionExpired:
      end(.ended)
    case .notPermitted:
      break
    default:
      guard error.shouldReJoin else { return }
      if await rotateToken(generation: generation) {
        lastError = nil
        return
      }
      if !isEnded, generation == credentialGeneration { end(.tokenLost) }
    }
  }

  /// Turns the wire's one "board is over" answer into the two a host can
  /// explain.
  ///
  /// `session_not_active` (410) covers both an ended board and an expired one,
  /// on purpose — the API keeps that distinction on the session payload's
  /// `status` rather than in the error. The transport cannot tell them apart,
  /// but this session holds the `expiresAt` it last read: a refusal that lands
  /// after that instant is an expiry, and the message a person sees should say
  /// "ran out of time" rather than "finished". Before this, `.sessionExpired`
  /// was unreachable — the transport matched a code the server never sent —
  /// so every timeout read as the board having been closed.
  private func refinedSessionEnd(_ error: RemoteDrawError) -> RemoteDrawError {
    guard case .sessionEnded = error,
      let expiresAt = session?.expiresAt,
      Date().timeIntervalSince1970 * 1000 >= expiresAt
    else { return error }
    return .sessionExpired
  }

  private func end(_ reason: RemoteDrawSessionEnd) {
    stopDraftDrain()
    stopHeartbeat()
    // A remote end mid-stroke must not leave the stroke drawn on a surface
    // that keeps rendering `live`.
    activeStroke = nil
    strokePoints = []
    live = nil
    resetTextDraft()
    if case .ended = phase { return }
    refreshTask?.cancel()
    pendingCommits.removeAll()
    phase = .ended(reason)
    maintenanceState = .ended
    let waiters = commitDrainWaiters
    commitDrainWaiters.removeAll()
    for waiter in waiters { waiter.resume() }
  }

  /// How long to wait before another rotation is worth attempting.
  ///
  /// `sender_refresh_per_token` allows 10/min. A session whose every call is
  /// failing would otherwise rotate on each one and burn that budget in
  /// seconds, turning a recoverable credential problem into a 429 storm. One
  /// attempt per window is plenty: a rotation that worked fixes every
  /// subsequent call, and one that failed will not succeed six seconds later.
  private static let refreshCooldown: TimeInterval = 10

  /// Swaps in a fresh sender token, or reports that it could not.
  ///
  /// **Called on a rejection and never on a timer.** Two properties of the
  /// route make that the only correct cadence:
  ///
  /// - It is **not idempotent**. The old token dies the moment the response is
  ///   minted, so a lost response costs this client its credential with nothing
  ///   left to retry with. That is why the call below is a bare `try?` and not
  ///   wrapped in ``retryIdempotentRequest``: a second attempt would carry a
  ///   token the server has already rotated away, guaranteeing a 401 and
  ///   destroying the evidence of what actually happened.
  /// - It **extends nothing**. Refresh copies the session's expiry onto the
  ///   token; it does not move the session. Refreshing in a loop to stay alive
  ///   does not work, and this is the code that must not try.
  ///
  /// Rotation rather than extension so a leaked token has a bounded life, and
  /// rotation rather than re-join so the other senders on the board survive it.
  private func rotateToken(generation: Int) async -> Bool {
    guard !isEnded else { return false }
    if generation != credentialGeneration { return true }
    if let refreshTask { return await refreshTask.value }
    let now = Date()
    guard now.timeIntervalSince(lastRefreshAttemptAt) >= Self.refreshCooldown else { return false }
    lastRefreshAttemptAt = now
    let task = Task { await performRotation(generation: generation) }
    refreshTask = task
    let result = await task.value
    refreshTask = nil
    return result
  }

  private func performRotation(generation: Int) async -> Bool {
    // Exactly one non-idempotent refresh, including when its response is lost.
    if let rotated = try? await transport.refresh(senderToken: senderToken) {
      if isEnded {
        // Cancellation cannot undo a server rotation. Explicit departure must
        // revoke a late successful result as well as the old credential.
        if disconnectOnCompletion { disconnect(rotated.senderToken) }
        return false
      }
      guard generation == credentialGeneration else { return false }
      senderToken = rotated.senderToken
      credentialGeneration += 1
      invalidateSyncCursors()
      adopt(senderId: rotated.senderId, session: rotated.session,
        capabilities: rotated.capabilities, lastSequence: rotated.lastSequence)
      restartDraftHTTPWaitAfterCredentialRotation()
      return true
    }
    guard !isEnded, !Task.isCancelled, let tokenProvider,
      let fresh = try? await tokenProvider() else { return false }
    if isEnded {
      if disconnectOnCompletion { disconnect(fresh) }
      return false
    }
    let response = try? await transport.session(senderToken: fresh)
    if isEnded {
      if disconnectOnCompletion { disconnect(fresh) }
      return false
    }
    guard let response, generation == credentialGeneration else { return false }
    // Verify a host credential before publishing it. Never move retained ink
    // to another board (or another sender's idempotency namespace).
    guard response.session.id == session?.id else { return false }
    // A newly minted sender has a different deduplication namespace. It is safe
    // when no ink is pending; ambiguous commits require explicit recovery.
    guard pendingCommits.isEmpty || response.senderId == senderId else { return false }
    senderToken = fresh
    credentialGeneration += 1
    invalidateSyncCursors()
    adopt(senderId: response.senderId, session: response.session,
      capabilities: response.capabilities, lastSequence: response.lastSequence)
    restartDraftHTTPWaitAfterCredentialRotation()
    return true
  }
}

// MARK: - Poll clock

/// The time source behind the session's background loops (sync, legacy
/// snapshots, presence). Injected so cadence tests advance virtual time instead
/// of sleeping. Draft cadence keeps wall-clock pacing; quota waits and lease
/// renewal use this monotonic clock as well.
public protocol RemoteDrawPollClock: Sendable {
  /// Monotonic seconds.
  var now: TimeInterval { get }
  /// Throws `CancellationError` when the calling task is cancelled.
  func sleep(seconds: TimeInterval) async throws
}

struct RemoteDrawSystemPollClock: RemoteDrawPollClock {
  var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

  func sleep(seconds: TimeInterval) async throws {
    guard seconds > 0 else { return try Task.checkCancellation() }
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
  }
}
