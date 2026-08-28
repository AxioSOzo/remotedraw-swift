import Combine
import Foundation

/// One stroke, live or committed.
public struct RemoteDrawStroke: Identifiable, Equatable, Sendable {
  public let id: String
  public let type: String
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let style: RemoteDrawDrawingStyle?
  /// True until the server answered the commit. A local echo keeps the ink on
  /// screen through the round trip; the server's version replaces it, because
  /// the board runs shape assistance and endpoint snapping before it stores.
  public let isLocalEcho: Bool
  /// Whether ``points`` are board coordinates rather than surface ones.
  ///
  /// A fresh echo is surface-space — it *is* what the finger drew — and becomes
  /// board-space the moment the server's version replaces it. A renderer has to
  /// know which, or a settled stroke jumps on a projected board the instant the
  /// commit lands. See ``RemoteDrawStrokeSpace/unproject``.
  public let isBoardSpace: Bool

  public init(
    id: String,
    type: String = "freehand",
    points: [RemoteDrawNormalizedPoint],
    text: String? = nil,
    style: RemoteDrawDrawingStyle? = nil,
    isLocalEcho: Bool = false,
    isBoardSpace: Bool = false
  ) {
    self.id = id
    self.type = type
    self.points = points
    self.text = text
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

  public init(
    phoneProjection: RemoteDrawProjection? = nil,
    isBoardSpace: Bool = false,
    project: @escaping @Sendable ([RemoteDrawNormalizedPoint]) -> [RemoteDrawNormalizedPoint] = { $0 },
    unproject: @escaping @Sendable (RemoteDrawNormalizedPoint) -> RemoteDrawNormalizedPoint? = { $0 }
  ) {
    self.phoneProjection = phoneProjection
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
/// stops pinging shows as connected on the board for up to the receiver's 60 s
/// window.
@MainActor
public final class RemoteDrawSenderSession: ObservableObject {
  // MARK: Published state

  @Published public private(set) var phase: RemoteDrawPhase = .joining
  @Published public private(set) var capabilities: Set<RemoteDrawCapability> = []
  /// Local echo plus server truth, in the order they landed.
  @Published public private(set) var strokes: [RemoteDrawStroke] = []
  /// The stroke the finger is still making, or `nil`.
  @Published public private(set) var live: RemoteDrawLiveStroke?
  @Published public private(set) var session: RemoteDrawSession?
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

  // MARK: Inspectable, never settable

  public static let draftInterval = RemoteDrawProtocolLimits.draftSendInterval
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
  public private(set) var senderToken: String
  /// Where a fresh credential can come from when the current one dies. See
  /// ``RemoteDrawSenderSession/join(token:transport:device:tokenProvider:)``.
  private let tokenProvider: (@Sendable () async throws -> String)?

  private var sequence = 0
  private var lastDraftSentAt: Date = .distantPast
  private var pendingDraft: PendingDraft?
  private var draftTask: Task<Void, Never>?
  private var heartbeatTask: Task<Void, Never>?
  private var strokePoints: [RemoteDrawNormalizedPoint] = []
  private var activeStroke: ActiveStroke?
  private var projection: RemoteDrawProjection?
  /// When rotation was last attempted, so a storm of failures cannot spend the
  /// route's 10/min budget. See ``rotateToken()``.
  private var lastRefreshAttemptAt: Date = .distantPast

  private struct ActiveStroke {
    let id: RemoteDrawStrokeID
    let tool: RemoteDrawTool
    let style: RemoteDrawDrawingStyle?
  }

  private struct PendingDraft {
    let tool: RemoteDrawTool
    let style: RemoteDrawDrawingStyle?
    let points: [RemoteDrawNormalizedPoint]
    let text: String?
  }

  private init(
    transport: any RemoteDrawSenderTransport,
    senderToken: String,
    tokenProvider: (@Sendable () async throws -> String)?
  ) {
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
  @MainActor
  public static func adopt(
    senderToken: String,
    transport: any RemoteDrawSenderTransport,
    senderId: String? = nil,
    session: RemoteDrawSession? = nil,
    capabilities: [String]? = nil,
    lastSequence: Int? = nil,
    tokenProvider: (@Sendable () async throws -> String)? = nil
  ) -> RemoteDrawSenderSession {
    let sender = RemoteDrawSenderSession(
      transport: transport, senderToken: senderToken, tokenProvider: tokenProvider)
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
      self.session = session
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

  /// Adopts the sender token's server-side sequence history.
  ///
  /// The server rejects any input at or below the highest sequence it holds for
  /// the token, so a relaunched app that restarts its counter at zero has every
  /// draft refused until it catches up. `max` rather than assignment: a session
  /// that has already sent input this run must not rewind onto sequences it has
  /// spent.
  private func adoptServerSequence(_ lastSequence: Int?) {
    guard let lastSequence else { return }
    sequence = max(sequence, lastSequence)
  }

  private func nextSequence() -> Int {
    sequence += 1
    return sequence
  }

  private func start() {
    startHeartbeat()
  }

  // MARK: - Drawing

  /// Starts a stroke. Nothing is sent until the first ``append(_:)``.
  public func begin(stroke id: RemoteDrawStrokeID, tool: RemoteDrawTool = .auto, style: RemoteDrawInkStyle? = nil) {
    // Drawing again answers the offer. It never blocks input, so it has to get
    // out of the way on its own.
    shapeSuggestion = nil
    activeStroke = ActiveStroke(id: id, tool: tool, style: style)
    strokePoints = []
    live = RemoteDrawLiveStroke(id: id, tool: tool, style: style, points: [])
    if case .ended = phase {} else { phase = .drawing }
  }

  /// Adds captured samples to the live stroke.
  ///
  /// Paced, thinned and packed for you: samples are accepted as fast as the
  /// hardware produces them, and at most one draft frame leaves every 32 ms
  /// carrying the newest state of the whole stroke. Sending more often does not
  /// make the board smoother, it spends the sender's rate-limit budget on frames
  /// nobody can see.
  ///
  /// Predicted touches must never come through here — they describe positions
  /// the finger has not reached. Give those to the renderer only.
  public func append(_ samples: [RemoteDrawSample]) {
    guard let stroke = activeStroke, !samples.isEmpty else { return }
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
    }
    live = RemoteDrawLiveStroke(
      id: stroke.id, tool: stroke.tool, style: stroke.style, points: strokePoints)
    enqueueDraft()
  }

  /// Ends the stroke and commits it.
  ///
  /// The commit is idempotent on `clientStrokeId`, so a timeout can be retried
  /// safely — and is, three times, before this throws.
  @discardableResult
  public func end(stroke id: RemoteDrawStrokeID) async throws -> RemoteDrawCommitResult? {
    guard let stroke = activeStroke, stroke.id == id else { return nil }
    activeStroke = nil
    let points = strokePoints
    strokePoints = []
    live = nil
    stopDraftDrain()
    if case .ended = phase {} else { phase = .ready }

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
        id: id, type: stroke.tool.rawValue, points: committed, style: stroke.style,
        isLocalEcho: true, isBoardSpace: false))

    do {
      let result = try await retryIdempotentRequest {
        try await transport.commitStroke(
          RemoteDrawCommitRequest(
            senderToken: senderToken,
            clientStrokeId: id,
            sequence: commitSequence,
            tool: stroke.tool,
            points: space.project(committed),
            style: stroke.style,
            phoneProjection: space.phoneProjection
          ))
      }
      replaceEcho(id: id, with: result, fallbackStyle: stroke.style, space: space)
      if !result.isDuplicate, let suggestion = result.suggestion, let strokeId = result.id {
        shapeSuggestion = RemoteDrawShapeOffer(
          strokeId: strokeId,
          suggestion: suggestion,
          style: result.style ?? stroke.style,
          isBoardSpace: space.isBoardSpace
        )
      }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      // The echo stays. The stroke is on screen because the user drew it, and
      // removing it on a network hiccup is how ink appears to vanish.
      try await recover(from: remoteError)
      throw remoteError
    }
  }

  /// Abandons the live stroke without committing it — a palm landing, a pinch
  /// starting, the surface going away mid-stroke.
  public func cancelStroke() async {
    guard activeStroke != nil else { return }
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
    strokeSpace?() ?? RemoteDrawStrokeSpace(phoneProjection: projection, isBoardSpace: false)
  }

  // MARK: - Draft pacing

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
      tool: stroke.tool, style: stroke.style, points: strokePoints, text: nil)
    startDraftDrain()
  }

  private func startDraftDrain() {
    guard draftTask == nil else { return }
    draftTask = Task { [weak self] in
      await self?.drainDrafts()
    }
  }

  private func stopDraftDrain() {
    draftTask?.cancel()
    draftTask = nil
    pendingDraft = nil
  }

  /// Sends at most one frame per ``draftInterval``, measured from the last send
  /// rather than from the last *completion* — a round trip is not a reason to
  /// draw slower, and 32 ms is the number `PERFORMANCE_BUDGETS` pins.
  private func drainDrafts() async {
    defer { draftTask = nil }
    while !Task.isCancelled, let queued = pendingDraft {
      let wait = Self.draftInterval - Date().timeIntervalSince(lastDraftSentAt)
      if wait > 0 {
        try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        if Task.isCancelled { return }
        // The stroke may have grown while we waited; take the newest state.
        continue
      }
      pendingDraft = nil
      lastDraftSentAt = Date()
      await sendDraft(queued)
    }
  }

  private func sendDraft(_ queued: PendingDraft) async {
    let draftSequence = nextSequence()
    let space = currentStrokeSpace()
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
          phoneProjection: space.phoneProjection
        ))
      // Self-healing by design: the rejection carries the counter to beat, so a
      // resumed sender adopts it here instead of bouncing every frame until
      // something else happens to re-read the session.
      if ack.isStaleSequence {
        adoptServerSequence(ack.lastSequence)
      } else if !ack.accepted, let reason = ack.reason {
        lastError = .server(status: 200, code: reason, message: nil)
      } else {
        lastError = nil
      }
    } catch {
      let remoteError = normalize(error)
      try? await recover(from: remoteError)
    }
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
    guard capabilities.contains(.draw) else { return }
    let space = currentStrokeSpace()
    _ = try? await transport.updateDraft(
      RemoteDrawDraftRequest(
        senderToken: senderToken,
        sequence: nextSequence(),
        tool: .text,
        points: space.project([point]),
        style: nil,
        text: text,
        phoneProjection: space.phoneProjection
      ))
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
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      try? await clearDraftRequest()
      return nil
    }
    let id = "ios-\(UUID().uuidString)"
    let space = currentStrokeSpace()
    let commitSequence = nextSequence()
    strokes.append(
      RemoteDrawStroke(
        id: id, type: RemoteDrawTool.text.rawValue, points: [point], text: trimmed,
        style: style, isLocalEcho: true, isBoardSpace: false))
    do {
      let result = try await retryIdempotentRequest {
        try await transport.commitStroke(
          RemoteDrawCommitRequest(
            senderToken: senderToken,
            clientStrokeId: id,
            sequence: commitSequence,
            tool: .text,
            points: space.project([point]),
            style: style,
            text: trimmed,
            phoneProjection: space.phoneProjection
          ))
      }
      replaceEcho(id: id, with: result, fallbackStyle: style, space: space)
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError)
      throw remoteError
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
    do {
      let result = try await transport.replaceStroke(
        RemoteDrawReplaceRequest(
          senderToken: senderToken,
          strokeId: strokeId,
          tool: tool.rawValue,
          points: wirePoints,
          style: style
        ))
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
      try await recover(from: remoteError)
      throw remoteError
    }
  }

  // MARK: - Board controls

  public func undo() async throws -> RemoteDrawUndoResult {
    try requireCapability(.undo)
    do {
      let result = try await transport.undo(senderToken: senderToken)
      if result.removed, let id = result.drawingId {
        strokes.removeAll { $0.id == id }
      } else if result.removed {
        strokes.removeLast(strokes.isEmpty ? 0 : 1)
      }
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError)
      throw remoteError
    }
  }

  public func clear() async throws -> RemoteDrawClearResult {
    try requireCapability(.clear)
    do {
      let result = try await transport.clear(senderToken: senderToken)
      strokes = []
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError)
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
    try requireCapability(.submit)
    let submissionId = "ios-\(UUID().uuidString)"
    do {
      let receipt = try await retryIdempotentRequest {
        try await transport.submit(
          senderToken: senderToken, clientSubmissionId: submissionId, metadata: metadata)
      }
      phase = .submitted
      lastError = nil
      return receipt
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError)
      throw remoteError
    }
  }

  /// Re-reads the board's committed elements.
  @discardableResult
  public func refreshDrawings() async throws -> [RemoteDrawDrawing] {
    try requireCapability(.viewExisting)
    let response = try await transport.drawings(senderToken: senderToken)
    if let session = response.session { self.session = session }
    return response.items.paintable
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
    do {
      let result = try await transport.editElements(senderToken: senderToken, edit: edit)
      lastError = nil
      return result
    } catch {
      let remoteError = normalize(error)
      try await recover(from: remoteError)
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
    projection = next
    let resolved = try await transport.updateProjection(
      senderToken: senderToken, projection: next)
    projection = resolved
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
    try? await clearDraftRequest()
  }

  /// Leaves cleanly: closes the projection, stops the heartbeat, drops the
  /// live stroke.
  ///
  /// Not optional housekeeping. Presence is a heartbeat and not a leave signal,
  /// so a phone that just goes quiet keeps showing as connected on the board for
  /// up to a minute — the customer's board would lie about who is present.
  public func leave() {
    let token = senderToken
    let transport = self.transport
    live = nil
    activeStroke = nil
    strokePoints = []
    end(.left)
    Task.detached {
      try? await transport.closeProjection(senderToken: token, disconnect: true)
    }
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
    try? await transport.closeProjection(senderToken: senderToken, disconnect: false)
  }

  /// Tells the board this sender is on screen and interacting.
  public func markActive() async {
    startHeartbeat()
    try? await transport.ping(senderToken: senderToken, active: true)
  }

  /// Tells the board this sender went to the background. Stops the heartbeat:
  /// a backgrounded phone that keeps pinging holds a session open against the
  /// customer's quota for nothing.
  public func markInactive() async {
    stopHeartbeat()
    try? await transport.ping(senderToken: senderToken, active: false)
  }

  private func startHeartbeat() {
    guard heartbeatTask == nil else { return }
    heartbeatTask = Task { [weak self] in
      let interval = UInt64(RemoteDrawProtocolLimits.presenceInterval * 1_000_000_000)
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        if Task.isCancelled { break }
        await self?.beat()
      }
    }
  }

  private func beat() async {
    do {
      try await transport.ping(senderToken: senderToken, active: false)
    } catch {
      let remoteError = normalize(error)
      try? await recover(from: remoteError)
    }
  }

  private func stopHeartbeat() {
    heartbeatTask?.cancel()
    heartbeatTask = nil
  }

  // MARK: - Recovery

  private func requireCapability(_ capability: RemoteDrawCapability) throws {
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
  private func recover(from error: RemoteDrawError) async throws {
    lastError = error
    switch error {
    case .sessionEnded, .sessionExpired:
      end(.ended)
    case .notPermitted:
      break
    default:
      guard error.shouldReJoin else { return }
      if await rotateToken() {
        lastError = nil
        return
      }
      end(.tokenLost)
    }
  }

  private func end(_ reason: RemoteDrawSessionEnd) {
    stopDraftDrain()
    stopHeartbeat()
    if case .ended = phase { return }
    phase = .ended(reason)
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
  private func rotateToken() async -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastRefreshAttemptAt) >= Self.refreshCooldown else {
      return false
    }
    lastRefreshAttemptAt = now

    // One attempt. See the note above: retrying a spent token cannot work.
    if let rotated = try? await transport.refresh(senderToken: senderToken) {
      senderToken = rotated.senderToken
      adopt(
        senderId: rotated.senderId,
        session: rotated.session,
        capabilities: rotated.capabilities,
        lastSequence: rotated.lastSequence
      )
      return true
    }

    guard let tokenProvider, let fresh = try? await tokenProvider() else { return false }
    senderToken = fresh
    // A token the host minted has its own sequence history, usually empty. Ask
    // rather than assume: a reused one would reject every draft as stale.
    if let response = try? await transport.session(senderToken: fresh) {
      adopt(
        senderId: response.senderId,
        session: response.session,
        capabilities: response.capabilities,
        lastSequence: response.lastSequence
      )
    }
    return true
  }
}
