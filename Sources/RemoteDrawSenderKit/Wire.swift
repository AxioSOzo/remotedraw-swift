import Foundation

// MARK: - Routes

/// Every route a phone holding only a sender token may call.
///
/// Fourteen shipping today: thirteen sender routes plus `/v1/join`, which is
/// the one that mints the token the other thirteen carry. `convex/http.ts`
/// registers 107 routes; the rest need an API key, a receiver token, or an
/// account, and none of them belong in an SDK that ships inside somebody else's
/// app.
///
/// ``refresh`` is the fifteenth and is **not live yet**: it is item 3 of
/// `docs/plans/ios-sender-sdk.md` §4.0, and a deployment without it answers
/// 404, which ``RemoteDrawSenderSession`` treats as "fall through to the host's
/// token provider" rather than as a failure.
///
/// Everything is `POST` with a JSON object body, and **the credential travels in
/// the body, never in an `Authorization` header** — that header belongs to API
/// keys, which a sender never holds.
public enum RemoteDrawSenderRoute: String, CaseIterable, Sendable {
  case join = "/v1/join"
  case session = "/v1/sender/session"
  case ping = "/v1/sender/ping"
  case draft = "/v1/sender/draft"
  case commit = "/v1/sender/commit"
  case replace = "/v1/sender/replace"
  case edit = "/v1/sender/edit"
  case clearDraft = "/v1/sender/clear-draft"
  case undo = "/v1/sender/undo"
  case clear = "/v1/sender/clear"
  case submit = "/v1/sender/submit"
  case drawings = "/v1/sender/drawings"
  case projection = "/v1/sender/projection"
  case closeProjection = "/v1/sender/projection/close"
  case refresh = "/v1/sender/refresh"

  /// The capability a session must grant before this route will answer.
  /// `nil` means every sender may call it.
  ///
  /// A 403 from one of these is **not** a re-join case: the credential was fine
  /// and the grant was not, so another join reproduces it exactly.
  public var requiredCapability: RemoteDrawCapability? {
    switch self {
    case .undo: return .undo
    case .clear: return .clear
    case .submit: return .submit
    case .drawings: return .viewExisting
    case .projection, .closeProjection: return .moveViewport
    default: return nil
    }
  }
}

/// What a session lets this sender do. The array on the wire is the
/// forward-compatibility mechanism the protocol already has, so an unfamiliar
/// grant is kept verbatim rather than dropped.
public enum RemoteDrawCapability: Hashable, Sendable, RawRepresentable {
  case draw
  case undo
  case clear
  case submit
  case viewExisting
  case moveViewport
  case editElements
  case other(String)

  public init(rawValue: String) {
    switch rawValue {
    case "draw": self = .draw
    case "undo": self = .undo
    case "clear": self = .clear
    case "submit": self = .submit
    case "viewExisting": self = .viewExisting
    case "moveViewport": self = .moveViewport
    case "editElements": self = .editElements
    default: self = .other(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .draw: return "draw"
    case .undo: return "undo"
    case .clear: return "clear"
    case .submit: return "submit"
    case .viewExisting: return "viewExisting"
    case .moveViewport: return "moveViewport"
    case .editElements: return "editElements"
    case .other(let name): return name
    }
  }
}

/// The drawing tools the protocol names.
public enum RemoteDrawTool: String, CaseIterable, Codable, Sendable {
  /// Let the board decide between freehand and a snapped shape.
  case auto
  case freehand
  case line
  case arrow
  case rectangle
  case ellipse
  case point
  case text
}

// MARK: - Credentials

/// How a session is entered.
///
/// Two forms, and the difference matters at every later step. A **join token**
/// (`rd_join_…`) is a one-shot pairing code from a QR or a link: spending it
/// mints a sender token *and revokes every other active sender on that
/// session*. A **sender token** (`rd_send_…`) is the credential itself, minted
/// by the customer's backend through `POST /v1/sessions/direct-sender`, and
/// joining is already done.
public enum RemoteDrawToken: Equatable, Sendable {
  /// `rd_join_…` — from a QR code, a Universal Link, or a custom scheme.
  case join(String)
  /// `rd_send_…` — from the host's own backend. No join round trip.
  case sender(String)

  /// Reads whichever form a raw string is, by its prefix.
  ///
  /// Returns `nil` rather than guessing: handing a join token to a route that
  /// wants a sender token produces a 401, which an SDK would then answer by
  /// re-joining, which would loop.
  public init?(raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("rd_join_") {
      self = .join(trimmed)
    } else if trimmed.hasPrefix("rd_send_") {
      self = .sender(trimmed)
    } else {
      return nil
    }
  }
}

// MARK: - Device

/// What the board is told about the phone.
///
/// The receiver needs the geometry to place this phone's viewport and to size
/// the ink; it does not need to know whose phone it is. That split is why
/// ``anonymous`` exists and why it is a first-class option rather than a
/// documented workaround: with `deviceId` omitted the SDK collects no device
/// identifier at all, which is the difference between a linked and an unlinked
/// data type in the host app's privacy report.
public struct RemoteDrawSenderDevice: Codable, Equatable, Sendable {
  /// `identifierForVendor`. Omitted entirely when the host chose ``anonymous``.
  public let deviceId: String?
  public let platform: String
  public let appVersion: String?
  public let displayName: String?
  public let modelIdentifier: String?
  public let aspectRatio: Double
  public let screen: RemoteDrawSenderDeviceScreen?

  public init(
    deviceId: String? = nil,
    platform: String = "ios",
    appVersion: String? = nil,
    displayName: String? = nil,
    modelIdentifier: String? = nil,
    aspectRatio: Double = 393.0 / 852.0,
    screen: RemoteDrawSenderDeviceScreen? = nil
  ) {
    self.deviceId = deviceId
    self.platform = platform
    self.appVersion = appVersion
    self.displayName = displayName
    self.modelIdentifier = modelIdentifier
    self.aspectRatio = aspectRatio
    self.screen = screen
  }

  /// Geometry only: no vendor identifier, no device name, no model.
  ///
  /// A board still places the viewport correctly; it just shows "a phone"
  /// instead of "Ada's iPhone".
  public static func anonymous(
    aspectRatio: Double,
    screen: RemoteDrawSenderDeviceScreen? = nil
  ) -> RemoteDrawSenderDevice {
    RemoteDrawSenderDevice(
      deviceId: nil,
      platform: "ios",
      appVersion: nil,
      displayName: nil,
      modelIdentifier: nil,
      aspectRatio: aspectRatio,
      screen: screen
    )
  }
}

/// The screen the strokes were drawn on, in points, plus the parts of it the
/// user cannot draw in.
public struct RemoteDrawSenderDeviceScreen: Codable, Equatable, Sendable {
  public let width: Double
  public let height: Double
  public let scale: Double
  public let pixelWidth: Double
  public let pixelHeight: Double
  public let safeAreaTop: Double
  public let safeAreaRight: Double
  public let safeAreaBottom: Double
  public let safeAreaLeft: Double
  /// `notch`, `dynamicIsland`, `none`, … — how the receiver draws the frame.
  public let cutout: String

  public init(
    width: Double,
    height: Double,
    scale: Double,
    pixelWidth: Double,
    pixelHeight: Double,
    safeAreaTop: Double,
    safeAreaRight: Double,
    safeAreaBottom: Double,
    safeAreaLeft: Double,
    cutout: String
  ) {
    self.width = width
    self.height = height
    self.scale = scale
    self.pixelWidth = pixelWidth
    self.pixelHeight = pixelHeight
    self.safeAreaTop = safeAreaTop
    self.safeAreaRight = safeAreaRight
    self.safeAreaBottom = safeAreaBottom
    self.safeAreaLeft = safeAreaLeft
    self.cutout = cutout
  }
}

// MARK: - Session

/// Where the phone's window sits on the board.
public struct RemoteDrawProjection: Codable, Equatable, Sendable {
  public let centerX: Double
  public let centerY: Double
  public let width: Double
  public let height: Double
  public let rotationDegrees: Double
  public let aspectRatio: Double
  public let coordinateAspectRatio: Double?
  public let connected: Bool?
  public let updatedAt: Double

  public init(
    centerX: Double,
    centerY: Double,
    width: Double,
    height: Double,
    rotationDegrees: Double = 0,
    aspectRatio: Double,
    coordinateAspectRatio: Double? = nil,
    connected: Bool? = nil,
    updatedAt: Double = Date().timeIntervalSince1970 * 1000
  ) {
    self.centerX = centerX
    self.centerY = centerY
    self.width = width
    self.height = height
    self.rotationDegrees = rotationDegrees
    self.aspectRatio = aspectRatio
    self.coordinateAspectRatio = coordinateAspectRatio
    self.connected = connected
    self.updatedAt = updatedAt
  }
}

/// What the session is drawn on.
///
/// `target.kind` **is** the surface — there is no separate field. Unknown names
/// keep their text rather than being folded into a lookalike.
///
/// Still deliberately no preset, and no `metadata`. A preset is a *shape the
/// product imposes on the customer's UI*, and the ~110-line
/// `RemoteDrawTargetMetadata` in the first-party app exists to turn one into
/// every string on the board — "Approval", "Review the provided item and submit
/// approval when ready", "Approve". Those are RemoteDraw's product copy for
/// RemoteDraw's own presets. An SDK host is not building an approval screen out
/// of our vocabulary; it is putting a drawing surface in *its* screen, and it
/// titles that screen itself through ``RemoteDrawStrings`` and the header
/// chrome slot. So the metadata tree stays first-party, and what crosses into
/// the SDK is only what the surface cannot draw without.
///
/// Two fields did cross in Stage 2, because they are geometry rather than copy:
///
/// - ``inputMapping`` decides whether the phone *is* the board or is a window
///   onto it, which changes the layout, the corner radius, and whether a pinch
///   means anything at all. A surface that guesses this wrong is not
///   mis-titled, it is unusable.
/// - ``coordinateSpace`` is the board's own units, which is what a stroke width
///   and a hit-test radius are measured in. Without it the surface falls back to
///   the web's 1000-unit default and every measurement is silently off.
public struct RemoteDrawTarget: Decodable, Equatable, Sendable {
  public let kind: String
  public let label: String?
  /// Whether this phone's screen is the whole board or a window onto it.
  public let inputMapping: RemoteDrawInputMapping?
  /// The board's own units. `nil` when the board declares none.
  public let coordinateSpace: RemoteDrawCoordinateSpace?

  private enum CodingKeys: String, CodingKey {
    case kind, label, inputMapping, coordinateSpace
  }

  public init(
    kind: String,
    label: String? = nil,
    inputMapping: RemoteDrawInputMapping? = nil,
    coordinateSpace: RemoteDrawCoordinateSpace? = nil
  ) {
    self.kind = kind
    self.label = label
    self.inputMapping = inputMapping
    self.coordinateSpace = coordinateSpace
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "custom"
    label = try container.decodeIfPresent(String.self, forKey: .label)
    // Forward-decoding, like everything else on this type: a mapping this build
    // has never heard of must leave the sender able to draw, not throw the
    // session away. `RemoteDrawInputMapping` keeps the unknown name.
    inputMapping = try? container.decodeIfPresent(
      RemoteDrawInputMapping.self, forKey: .inputMapping)
    coordinateSpace = try? container.decodeIfPresent(
      RemoteDrawCoordinateSpace.self, forKey: .coordinateSpace)
  }

  /// The ground this target asks the renderer for.
  public var ground: RemoteDrawGround { .forProtocolSurface(kind) }

  /// True when the phone's screen *is* the board.
  ///
  /// The single most load-bearing bit on this type. A `surface` board has no
  /// window to move and no projection to send, so the surface drops the pinch,
  /// the move-portal mode and the projection heartbeat, and draws the sheet
  /// inset with a corner radius instead of edge to edge.
  public var mapsInputToSurface: Bool { inputMapping == .surface }
}

/// Whether the phone is the board or a window onto it.
public enum RemoteDrawInputMapping: Equatable, Sendable, RawRepresentable, Decodable {
  /// The phone's screen *is* the board's surface, one to one.
  case surface
  /// The phone is a movable window onto a larger board.
  case viewport
  /// A mapping a newer board knows about and this build does not. Kept rather
  /// than folded into a lookalike: guessing between "you are the board" and
  /// "you are a window onto it" gets the whole coordinate system wrong.
  case other(String)

  public init(rawValue: String) {
    switch rawValue {
    case "surface": self = .surface
    case "viewport": self = .viewport
    default: self = .other(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .surface: return "surface"
    case .viewport: return "viewport"
    case .other(let raw): return raw
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }
}

/// The board's own units.
///
/// A stroke width, a hit-test radius and a selection outline are all distances,
/// and a distance means nothing until you say in what. Boards that declare none
/// are measured against the web's `DEFAULT_COORDINATE_SIZE` of 1000 on the
/// short axis, so the same number of units is the same number of pixels on
/// every client.
public struct RemoteDrawCoordinateSpace: Decodable, Equatable, Sendable {
  public let width: Double?
  public let height: Double?
  public let bounds: Bounds?

  public struct Bounds: Decodable, Equatable, Sendable {
    public let minX: Double?
    public let minY: Double?
    public let maxX: Double?
    public let maxY: Double?

    public init(minX: Double? = nil, minY: Double? = nil, maxX: Double? = nil, maxY: Double? = nil) {
      self.minX = minX
      self.minY = minY
      self.maxX = maxX
      self.maxY = maxY
    }
  }

  public init(width: Double? = nil, height: Double? = nil, bounds: Bounds? = nil) {
    self.width = width
    self.height = height
    self.bounds = bounds
  }

  /// Width over height, or `nil` when either is missing or degenerate.
  public var aspectRatio: Double? {
    guard let width, let height, width.isFinite, height.isFinite, width > 0, height > 0
    else { return nil }
    return width / height
  }
}

/// The board, as much of it as a sender needs to know.
///
/// **Every field but `id` decodes forward.** A response shape this build does
/// not recognise must not cost the sender its token, so anything unfamiliar is
/// dropped rather than thrown: see ``RemoteDrawJoinResponse``, which decodes
/// this with `try?` for exactly that reason.
public struct RemoteDrawSession: Decodable, Equatable, Sendable {
  public let id: String
  public let status: String
  public let target: RemoteDrawTarget?
  public let capabilities: [String]
  /// The board this session draws on, when the session belongs to one.
  public let boardId: String?
  /// The preset the session was created from, verbatim. Carried, never
  /// interpreted: preset *copy* stays first-party (see the note above), but a
  /// host that created the session with a preset is entitled to read back which
  /// one.
  public let markupPreset: String?
  /// Which sender surface the board expects — see
  /// ``RemoteDrawSenderIntegrationMode``.
  ///
  /// Decoded because ignoring it was a silent trap: a customer who created the
  /// session with `senderIntegrationMode: "streaming"` and pointed this SDK at
  /// it got no behaviour change at all, and no way to find out why. The surface
  /// now refuses the board out loud instead. See ``requestsStreaming``.
  public let senderIntegrationMode: RemoteDrawSenderIntegrationMode?
  /// The receiver's live screen share, if the board publishes one.
  ///
  /// **This SDK cannot consume it.** The field is decoded so the surface can
  /// say so rather than paint an empty pad — see ``requestsStreaming`` and
  /// ``RemoteDrawUnsupportedSurface``.
  public let visualContext: RemoteDrawVisualContext?
  /// Epoch milliseconds. Slides forward while input arrives — see the note on
  /// ``RemoteDrawSenderSession`` about the token *not* sliding with it.
  public let expiresAt: Double?
  public let phoneProjection: RemoteDrawProjection?
  /// Whether this board has already been submitted, and when.
  ///
  /// In the SDK because it answers a question the surface has to answer before
  /// it draws a button: *is Submit still a thing this person can do?* A board
  /// whose submission is already accepted must not offer it again, and a host
  /// that re-presents the surface after a submit needs the same answer without
  /// having tracked it itself. The first-party app reads exactly this and
  /// nothing more of the submission tree — the customer-facing labels around it
  /// (`submitLabel`) live in `RemoteDrawTargetMetadata`, which stayed
  /// first-party, because a host names its own button.
  public let submission: RemoteDrawSubmissionState?

  private enum CodingKeys: String, CodingKey {
    case id, status, target, capabilities, expiresAt, phoneProjection, submission
    case boardId, markupPreset, senderIntegrationMode, visualContext
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    status = try container.decodeIfPresent(String.self, forKey: .status) ?? "active"
    target = try? container.decodeIfPresent(RemoteDrawTarget.self, forKey: .target)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
    boardId = try? container.decodeIfPresent(String.self, forKey: .boardId)
    markupPreset = try? container.decodeIfPresent(String.self, forKey: .markupPreset)
    senderIntegrationMode = try? container.decodeIfPresent(
      RemoteDrawSenderIntegrationMode.self, forKey: .senderIntegrationMode)
    visualContext = try? container.decodeIfPresent(
      RemoteDrawVisualContext.self, forKey: .visualContext)
    expiresAt = try container.decodeIfPresent(Double.self, forKey: .expiresAt)
    phoneProjection = try? container.decodeIfPresent(
      RemoteDrawProjection.self, forKey: .phoneProjection)
    submission = try? container.decodeIfPresent(
      RemoteDrawSubmissionState.self, forKey: .submission)
  }

  public var isActive: Bool { status == "active" }

  /// Whether a submission is still open on this board.
  ///
  /// `true` when nothing has been submitted yet. Combine with
  /// ``RemoteDrawCapability/submit`` — the grant says whether this sender *may*
  /// submit, this says whether there is anything left to submit to.
  public var acceptsSubmission: Bool { submission?.isSubmitted != true }

  /// Whether this board expects its sender to show the receiver's live pixels.
  ///
  /// Either half is enough, because the two say the same thing from opposite
  /// ends: `senderIntegrationMode == .streaming` is the board asking for a
  /// streaming sender, and `visualContext.enabled` is the board *publishing*
  /// the stream a streaming sender would consume. A board that set only one is
  /// still a board this SDK cannot draw, and answering "no" to half of it is
  /// how the blank pad happened.
  public var requestsStreaming: Bool {
    senderIntegrationMode == .streaming || visualContext?.enabled == true
  }
}

/// Which sender surface a board expects.
///
/// Forward-decoding, like every other enum on the wire: a mode this build has
/// never heard of is kept rather than folded into a lookalike.
public enum RemoteDrawSenderIntegrationMode: Equatable, Sendable, RawRepresentable, Decodable {
  /// A native sender draws the board itself. What this SDK is.
  case native
  /// The sender is expected to show the receiver's screen, live, underneath the
  /// ink — WebRTC video, which this package deliberately has no dependency for.
  /// See ``RemoteDrawUnsupportedSurface``.
  case streaming
  case other(String)

  public init(rawValue: String) {
    switch rawValue {
    case "native": self = .native
    case "streaming": self = .streaming
    default: self = .other(rawValue)
    }
  }

  public var rawValue: String {
    switch self {
    case .native: return "native"
    case .streaming: return "streaming"
    case .other(let raw): return raw
    }
  }

  public init(from decoder: Decoder) throws {
    self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
  }
}

/// The receiver's live screen share, as the session describes it.
///
/// Decoded in full — including the resolved ``iceServers``, which the API
/// inlines onto the session precisely so a sender learns them without a second
/// call — even though **this SDK renders none of it**. Two reasons it is here
/// rather than omitted: a host writing its own consumer (a `WKWebView` on the
/// hosted `/join` page, or its own WebRTC stack) needs the values, and the
/// built-in surface needs to know the board wants something it cannot give
/// before it paints a pad with nothing on it.
public struct RemoteDrawVisualContext: Decodable, Equatable, Sendable {
  /// Whether the receiver publishes its pixels for this session.
  public let enabled: Bool
  public let maxFps: Int?
  public let maxLongEdge: Int?
  /// Regions the receiver blanks before publishing, in normalized board space.
  public let redact: [RemoteDrawNormalizedBounds]?
  /// STUN/TURN, already resolved by the API to the deployment's own unless the
  /// session named its own set.
  public let iceServers: [RemoteDrawIceServer]?

  private enum CodingKeys: String, CodingKey {
    case enabled, maxFps, maxLongEdge, redact, iceServers
  }

  public init(
    enabled: Bool = false,
    maxFps: Int? = nil,
    maxLongEdge: Int? = nil,
    redact: [RemoteDrawNormalizedBounds]? = nil,
    iceServers: [RemoteDrawIceServer]? = nil
  ) {
    self.enabled = enabled
    self.maxFps = maxFps
    self.maxLongEdge = maxLongEdge
    self.redact = redact
    self.iceServers = iceServers
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    enabled = ((try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
    maxFps = try? container.decodeIfPresent(Int.self, forKey: .maxFps)
    maxLongEdge = try? container.decodeIfPresent(Int.self, forKey: .maxLongEdge)
    redact = try? container.decodeIfPresent([RemoteDrawNormalizedBounds].self, forKey: .redact)
    iceServers = try? container.decodeIfPresent([RemoteDrawIceServer].self, forKey: .iceServers)
  }
}

/// A normalized rectangle on the board, `0…1` on both axes.
public struct RemoteDrawNormalizedBounds: Decodable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  public let width: Double
  public let height: Double

  public init(x: Double, y: Double, width: Double, height: Double) {
    self.x = x
    self.y = y
    self.width = width
    self.height = height
  }
}

/// One ICE server, in the shape `RTCIceServer` wants.
///
/// `urls` is normalized to an array on the way in, because the wire allows both
/// a single string and a list and a consumer should not have to care which
/// arrived.
public struct RemoteDrawIceServer: Decodable, Equatable, Sendable {
  public let urls: [String]
  public let username: String?
  public let credential: String?

  private enum CodingKeys: String, CodingKey {
    case urls, username, credential
  }

  public init(urls: [String], username: String? = nil, credential: String? = nil) {
    self.urls = urls
    self.username = username
    self.credential = credential
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let single = try? container.decode(String.self, forKey: .urls) {
      urls = [single]
    } else {
      urls = (try? container.decode([String].self, forKey: .urls)) ?? []
    }
    username = try? container.decodeIfPresent(String.self, forKey: .username)
    credential = try? container.decodeIfPresent(String.self, forKey: .credential)
  }
}

/// Where a board's submission got to.
public struct RemoteDrawSubmissionState: Decodable, Equatable, Sendable {
  public let id: String?
  public let status: String?
  /// Epoch milliseconds.
  public let submittedAt: Double?
  public let acceptedAt: Double?

  public var isSubmitted: Bool { status == "submitted" || submittedAt != nil }
}

/// What `/v1/join` hands back once a pairing code is spent.
///
/// The token is the only part a sender cannot work without, so it is the only
/// required field: a response from a newer server must still produce a usable
/// join.
public struct RemoteDrawJoinResponse: Decodable, Equatable, Sendable {
  public let senderToken: String
  public let senderId: String?
  public let capabilities: [String]?
  /// The highest sequence the server already holds for this token. A join mints
  /// a fresh token so this is usually absent or `-1`; a *resumed* token answers
  /// where the previous run stopped, which is what stops every draft after a
  /// relaunch bouncing as `stale_sequence`.
  public let lastSequence: Int?
  public let session: RemoteDrawSession?

  private enum CodingKeys: String, CodingKey {
    case senderToken, senderId, capabilities, lastSequence, session
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    senderToken = try container.decode(String.self, forKey: .senderToken)
    senderId = try container.decodeIfPresent(String.self, forKey: .senderId)
    capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities)
    lastSequence = try container.decodeIfPresent(Int.self, forKey: .lastSequence)
    session = try? container.decodeIfPresent(RemoteDrawSession.self, forKey: .session)
  }

  public init(
    senderToken: String,
    senderId: String? = nil,
    capabilities: [String]? = nil,
    lastSequence: Int? = nil,
    session: RemoteDrawSession? = nil
  ) {
    self.senderToken = senderToken
    self.senderId = senderId
    self.capabilities = capabilities
    self.lastSequence = lastSequence
    self.session = session
  }
}

/// `/v1/sender/session` — the same picture as a join, minus the token.
public struct RemoteDrawSessionResponse: Decodable, Equatable, Sendable {
  public let senderId: String?
  public let session: RemoteDrawSession
  public let capabilities: [String]?
  public let lastSequence: Int?
}

/// The answer to a live draft.
///
/// `accepted == false` is a routine outcome, not a failure, which is why this
/// is returned rather than thrown. The server rejects a draft whose sequence it
/// has already passed and hands back the counter to beat, so a sender that
/// resumed a token it did not mint — relaunch, deep link, background return —
/// resyncs from the rejection itself instead of re-reading the session while
/// every draft bounces.
///
/// Miss this and live ink silently vanishes while commits keep working, which
/// is the hardest class of bug for a customer to report.
public struct RemoteDrawDraftAck: Decodable, Equatable, Sendable {
  public let accepted: Bool
  public let reason: String?
  public let lastSequence: Int?

  /// The one rejection a sender can act on: continue from `lastSequence + 1`.
  public var isStaleSequence: Bool { !accepted && reason == "stale_sequence" }

  public init(accepted: Bool, reason: String? = nil, lastSequence: Int? = nil) {
    self.accepted = accepted
    self.reason = reason
    self.lastSequence = lastSequence
  }
}

/// A committed stroke, as the server stored it.
///
/// `points` come back in board space and may differ from what was posted: the
/// server runs shape assistance and endpoint snapping before it writes. A
/// sender whose ink should match the board redraws from these rather than
/// keeping its own samples.
public struct RemoteDrawCommitResult: Decodable, Equatable, Sendable {
  public let id: String?
  /// True when this `clientStrokeId` had already landed. Retrying a commit is
  /// therefore safe: the second attempt is answered, not duplicated.
  public let duplicate: Bool?
  public let type: String?
  public let style: RemoteDrawDrawingStyle?
  public let points: [RemoteDrawNormalizedPoint]?
  public let text: String?
  /// The board's offer to straighten what was just drawn.
  ///
  /// **Shape snapping is part of the drawing experience, not app chrome, so it
  /// is in the SDK.** The judgement is the one a person makes about the product
  /// rather than about the code: a customer who embeds "the same drawing
  /// surface the RemoteDraw app has" and finds that a hand-drawn rectangle
  /// stays wobbly has been given a different product, and they cannot add it
  /// back — the suggestion is computed server-side and arrives only here. The
  /// counter-argument, that a pill floating over the board is chrome a host may
  /// want to place itself, is real and is answered by making the offer a
  /// *published value* on the session as well as a built-in pill: a Tier 3 host
  /// reads ``RemoteDrawSenderSession/shapeSuggestion`` and draws its own.
  ///
  /// Nothing is applied automatically. The stroke stands as drawn until the
  /// person accepts, which is why this is an offer and not a correction.
  public let suggestion: RemoteDrawShapeSuggestion?

  public var isDuplicate: Bool { duplicate ?? false }
}

/// The board's read of what a freehand stroke was probably meant to be.
public struct RemoteDrawShapeSuggestion: Decodable, Equatable, Sendable {
  /// The recogniser's own name for the match.
  public let kind: String
  /// The protocol drawing type to replace with — `line`, `arrow`, `rectangle`,
  /// `ellipse`, `point`.
  public let type: String
  /// The straightened geometry, in the same space the commit was posted in.
  public let points: [RemoteDrawNormalizedPoint]
  /// `0...1`.
  public let confidence: Double

  public init(kind: String, type: String, points: [RemoteDrawNormalizedPoint], confidence: Double) {
    self.kind = kind
    self.type = type
    self.points = points
    self.confidence = confidence
  }

  /// The tool a replace should be posted as.
  ///
  /// Anything this build does not recognise degrades to `freehand` rather than
  /// riding an unknown type onto the wire: the offer is cosmetic, and a refused
  /// replace would cost the person the stroke they already made.
  public var replacementTool: RemoteDrawTool {
    switch type {
    case "line": return .line
    case "arrow": return .arrow
    case "rectangle": return .rectangle
    case "ellipse": return .ellipse
    case "point": return .point
    default: return .freehand
    }
  }
}

public struct RemoteDrawReplaceResult: Decodable, Equatable, Sendable {
  public let accepted: Bool
  public let reason: String?
  public let id: String?
  public let type: String?
  public let points: [RemoteDrawNormalizedPoint]?
  public let style: RemoteDrawDrawingStyle?
}

public struct RemoteDrawUndoResult: Decodable, Equatable, Sendable {
  public let removed: Bool
  public let drawingId: String?
}

public struct RemoteDrawClearResult: Decodable, Equatable, Sendable {
  public let removed: Int
}

/// What a submit is worth telling the host about.
public struct RemoteDrawReceipt: Decodable, Equatable, Sendable {
  public let id: String?
  public let status: String?
  public let accepted: Bool?
  public let duplicate: Bool?
  public let message: String?
  /// Epoch milliseconds.
  public let submittedAt: Double?
}

/// One element already on the board.
public struct RemoteDrawDrawing: Decodable, Equatable, Sendable, Identifiable {
  public let id: String
  public let type: String
  public let style: RemoteDrawDrawingStyle?
  public let points: [RemoteDrawNormalizedPoint]
  public let text: String?
  public let hidden: Bool?
  public let revision: Int?
}

public struct RemoteDrawDrawingsResponse: Decodable, Equatable, Sendable {
  public let session: RemoteDrawSession?
  public let items: [RemoteDrawDrawing]
}

extension Sequence where Element == RemoteDrawDrawing {
  /// The elements a sender should actually paint.
  ///
  /// `sender.listDrawings` serves every non-removed element, hidden ones
  /// included — hiding is a property, not a deletion, and a client that wants to
  /// unhide one still needs to receive it. But a hidden element is by definition
  /// not on the board, so painting it shows ink the receiver is not showing.
  ///
  /// `!= true` rather than `== false` on purpose: the field is absent on every
  /// element of an unedited board, and absent means visible.
  public var paintable: [RemoteDrawDrawing] { filter { $0.hidden != true } }
}

/// Anything a host wants attached to a submission.
public enum RemoteDrawJSONValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case bool(Bool)
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .string(let value): try container.encode(value)
    case .number(let value): try container.encode(value)
    case .bool(let value): try container.encode(value)
    case .null: try container.encodeNil()
    }
  }
}

extension RemoteDrawSenderDevice {
  /// This device where there is one to describe, and `nil` on a platform with
  /// no `UIKit` — which is only ever `swift test` on a Mac.
  ///
  /// A separate name from `current()` so the platform fork lives in exactly one
  /// place instead of at every call site.
  @MainActor
  static func describingThisDevice() -> RemoteDrawSenderDevice? {
    #if canImport(UIKit) && !os(watchOS)
      return .current()
    #else
      return nil
    #endif
  }
}

// MARK: - Editing elements already on the board

/// A transform an element carries.
///
/// Four numbers, never a matrix: similarity transforms are closed under
/// composition, so repeated drags cannot accumulate a shear no renderer
/// implements. `translateX` and `translateY` are plain board units, directly
/// comparable to a point's `x` and `y`.
///
/// `rotation` is part of the *format* only — the board refuses it with
/// `unsupported_transform`, because a `rectangle` and an `ellipse` paint from
/// the axis-aligned bounding box of their points and a rotated rectangle would
/// come back as a larger upright one. Scale has no such problem: the bounding
/// box of the scaled points *is* the correctly scaled bounding box.
public struct RemoteDrawTransform: Codable, Equatable, Sendable {
  public let translateX: Double
  public let translateY: Double
  public let scale: Double
  public let rotation: Double

  public init(translateX: Double, translateY: Double, scale: Double = 1, rotation: Double = 0) {
    self.translateX = translateX
    self.translateY = translateY
    self.scale = scale
    self.rotation = rotation
  }
}

/// The edit `/v1/sender/edit` accepts, as a narrowed slice of the wire's union.
///
/// The route also accepts `reorder` with an anchor element, and `setProperties`
/// also accepts `zIndex`, `locked`, `hidden` and `name`. Stating the subset in
/// the type means a host that grows a "send to back" control has to say so
/// rather than discovering it can already smuggle one through.
public enum RemoteDrawElementEdit: Encodable, Sendable {
  public struct Move: Equatable, Sendable {
    public let drawingId: String
    /// What the sender last saw. The board computes absolute state from it, so a
    /// stale revision is refused rather than applied twice.
    public let expectedRevision: Int
    /// `nil` **erases** — the element goes back where it was drawn. That is not
    /// the same as omitting the key, which means "leave it alone", so it is
    /// encoded as an explicit JSON `null`.
    public let transform: RemoteDrawTransform?

    public init(drawingId: String, expectedRevision: Int, transform: RemoteDrawTransform?) {
      self.drawingId = drawingId
      self.expectedRevision = expectedRevision
      self.transform = transform
    }
  }

  case setProperties([Move])
  /// No `expectedRevision` travels with a delete: "get rid of that" means the
  /// same thing however the element has moved since it was read.
  case delete([String])

  private enum CodingKeys: String, CodingKey { case kind, targets }
  private enum TargetKeys: String, CodingKey { case drawingId, expectedRevision, properties }
  private enum PropertyKeys: String, CodingKey { case transform }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .setProperties(let moves):
      try container.encode("setProperties", forKey: .kind)
      var array = container.nestedUnkeyedContainer(forKey: .targets)
      for move in moves {
        var row = array.nestedContainer(keyedBy: TargetKeys.self)
        try row.encode(move.drawingId, forKey: .drawingId)
        try row.encode(move.expectedRevision, forKey: .expectedRevision)
        var properties = row.nestedContainer(keyedBy: PropertyKeys.self, forKey: .properties)
        // `encodeIfPresent` would drop the key on nil, which the board reads as
        // "leave the transform alone" — the opposite of what an erase means.
        if let transform = move.transform {
          try properties.encode(transform, forKey: .transform)
        } else {
          try properties.encodeNil(forKey: .transform)
        }
      }
    case .delete(let drawingIds):
      try container.encode("delete", forKey: .kind)
      var array = container.nestedUnkeyedContainer(forKey: .targets)
      for drawingId in drawingIds {
        var row = array.nestedContainer(keyedBy: TargetKeys.self)
        try row.encode(drawingId, forKey: .drawingId)
      }
    }
  }
}

/// What one element looks like after an edit landed on — or bounced off — it.
public struct RemoteDrawEditedElement: Decodable, Equatable, Sendable {
  public let drawingId: String
  public let revision: Int
  public let transform: RemoteDrawTransform?
  public let removed: Bool?
}

/// The result of an edit.
///
/// **A refused-but-understood edit is a 200 carrying `accepted: false`.** Only a
/// malformed body or a dead token is a 4xx, so a caller must read this rather
/// than treat the absence of a throw as success. The rejection carries the
/// current revision of the element that blocked it, so a sender resyncs without
/// a second round trip — the same rule a `stale_sequence` draft follows.
public struct RemoteDrawEditResult: Decodable, Equatable, Sendable {
  public let accepted: Bool
  public let kind: String?
  /// Present on acceptance; the id an undo would reverse.
  public let editId: String?
  public let elements: [RemoteDrawEditedElement]
  /// `revision_mismatch` | `deleted` | `locked` | `unsupported_transform` |
  /// `not_found`, and whatever the board learns to say next — deliberately a
  /// string rather than an enum, so an unfamiliar reason arrives intact instead
  /// of failing the decode at the wire boundary.
  public let reason: String?
  public let drawingId: String?

  private enum CodingKeys: String, CodingKey {
    case accepted, kind, editId, elements, reason, drawingId
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accepted = try container.decodeIfPresent(Bool.self, forKey: .accepted) ?? false
    kind = try container.decodeIfPresent(String.self, forKey: .kind)
    editId = try container.decodeIfPresent(String.self, forKey: .editId)
    elements =
      (try? container.decodeIfPresent([RemoteDrawEditedElement].self, forKey: .elements)) ?? []
    reason = try container.decodeIfPresent(String.self, forKey: .reason)
    drawingId = try container.decodeIfPresent(String.self, forKey: .drawingId)
  }
}
