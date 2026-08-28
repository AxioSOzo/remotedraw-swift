import Foundation

/// The value types the ink renderer draws from.
///
/// They live in `RemoteDrawInk` rather than in `RemoteDrawSenderKit` because
/// this is the lower of the two targets: the renderer cannot depend on the
/// sender, and a point is the one thing both of them need. `RemoteDrawSenderKit`
/// re-exports this module, so a customer writes one `import` and sees these
/// under the same names.
///
/// The other reason they are here is the one `InkCompatibility.swift` gave in
/// `apps/ios/RemoteDrawKit`, and it still holds: `InkRenderer.swift` is a
/// **byte-identical copy** of `apps/ios/RemoteDraw/InkRenderer.swift`
/// (`diff -q` clean), 2,129 lines of geometry with documented parity to the
/// web's `inkGeometry.ts`. Editing it to fit a module boundary is the easiest
/// way to break that parity silently. So the file is copied verbatim and the
/// two names it reaches for are supplied here.

/// A point on the drawing surface, normalized to `0...1` with a top-left
/// origin, plus whatever the hardware reported about the touch that made it.
///
/// Deliberately **not** clamping in `init`, matching
/// `apps/ios/RemoteDraw/Models.swift`: board-space map points legitimately move
/// outside `0...1` as a sender pans, and clamping the shared model would
/// silently fold those onto the edge. Clamping happens where a point is
/// captured, and again inside ``PointCodec`` where the wire demands it.
public struct RemoteDrawNormalizedPoint: Codable, Equatable, Sendable {
  public let x: Double
  public let y: Double
  /// Milliseconds since **process start** — see ``RemoteDrawInkClock``. Never
  /// an epoch timestamp: the packed codec quantises this channel into an
  /// `Int32`.
  public let t: Double?
  /// `0...1`, from `touch.force / touch.maximumPossibleForce`.
  public let pressure: Double?
  /// Degrees, PointerEvents convention. See ``RemoteDrawPencilTilt``.
  public let tiltX: Double?
  public let tiltY: Double?

  public init(
    x: Double,
    y: Double,
    t: Double? = nil,
    pressure: Double? = nil,
    tiltX: Double? = nil,
    tiltY: Double? = nil
  ) {
    self.x = x
    self.y = y
    self.t = t
    self.pressure = pressure
    self.tiltX = tiltX
    self.tiltY = tiltY
  }
}

/// The name `InkRenderer.swift` uses. Internal, because the public spelling is
/// `RemoteDrawNormalizedPoint` and two public names for one type is a worse
/// surface than one.
typealias NormalizedPoint = RemoteDrawNormalizedPoint

/// The enclosed-area wash a stroke can request. Mirrors `DrawingFill` in
/// `packages/protocol`.
///
/// Absent is not the same as transparent: a stroke with no fill has an open
/// interior, a stroke with `opacity: 0` asked for an invisible one.
public struct RemoteDrawDrawingFill: Codable, Equatable, Sendable {
  public let color: String?
  public let opacity: Double?

  public init(color: String? = nil, opacity: Double? = nil) {
    self.color = color
    self.opacity = opacity
  }
}

/// How a stroke should look. Mirrors `DrawingStyle` in `packages/protocol` and
/// `apps/ios/RemoteDraw/Models.swift`.
///
/// `kind` is a `String` rather than ``DrawingStyleKind`` on purpose, and this
/// is the same forward-compatibility rule the rest of the wire follows: a board
/// that learns a new instrument must not fail to decode on a sender that has
/// not shipped yet. ``RemoteDrawStrokePainter`` resolves an unrecognised name
/// to the default instrument instead.
public struct RemoteDrawDrawingStyle: Codable, Equatable, Sendable {
  public let kind: String?
  public let color: String?
  public let width: Double?
  public let opacity: Double?
  public let fill: RemoteDrawDrawingFill?

  public init(
    kind: String? = nil,
    color: String? = nil,
    width: Double? = nil,
    opacity: Double? = nil,
    fill: RemoteDrawDrawingFill? = nil
  ) {
    self.kind = kind
    self.color = color
    self.width = width
    self.opacity = opacity
    self.fill = fill
  }

  public init(
    kind: DrawingStyleKind,
    color: String? = nil,
    width: Double? = nil,
    opacity: Double? = nil,
    fill: RemoteDrawDrawingFill? = nil
  ) {
    self.init(
      kind: kind.rawValue, color: color, width: width, opacity: opacity, fill: fill)
  }
}

/// An instrument. The renderer switches on it to pick a profile, and the
/// surface's picker groups and labels it.
///
/// **The only declaration.** Stage 1 left a second copy in
/// `apps/ios/RemoteDraw/Models.swift` carrying the presentation members, on the
/// grounds that they belonged to the surface and the surface was Stage 2. The
/// surface is here, so they are here, and the app's copy is gone: two enums over
/// the same sixteen instruments, pinned by nothing but review, is exactly the
/// parity hazard this package exists to retire. `Identifiable` and the
/// presentation members below are what let a picker be built from this type
/// without a lookup table beside it.
public enum DrawingStyleKind: String, CaseIterable, Codable, Sendable, Identifiable {
  // Wet, opaque, round-nib lines.
  case ink
  case whiteboardMarker
  case brushPen
  case fineliner
  case ballpoint
  // Dry media: grain rather than one solid pass.
  case pencil
  case chalk
  case charcoal
  case crayon
  case dryBrush
  // Broad-edge nibs: width follows stroke direction.
  case italicNib
  case chiselMarker
  // Stylus tilt drives the mark.
  case tiltPencil
  // Translucent and scattered.
  case highlighter
  case airbrush
  case neon

  public var id: String { rawValue }

  /// The groups a picker leads with, in the order the cases are declared.
  ///
  /// Four rather than sixteen flat entries because sixteen instruments in one
  /// row is a scroll, not a choice. `tiltPencil` is filed under dry media
  /// beside `pencil` — it is the same graphite, laid over — even though the
  /// renderer treats it as its own axis.
  public enum Family: String, CaseIterable, Identifiable, Sendable {
    case pens = "Pens"
    case dry = "Dry media"
    case broadEdge = "Broad edge"
    case translucent = "Translucent"

    public var id: String { rawValue }

    public var members: [DrawingStyleKind] {
      switch self {
      case .pens: return [.ink, .whiteboardMarker, .brushPen, .fineliner, .ballpoint]
      case .dry: return [.pencil, .tiltPencil, .chalk, .charcoal, .crayon, .dryBrush]
      case .broadEdge: return [.italicNib, .chiselMarker]
      case .translucent: return [.highlighter, .airbrush, .neon]
      }
    }
  }

  /// What a person calls this instrument.
  ///
  /// English, and deliberately not localised here: a host that ships in another
  /// language overrides every user-facing string through
  /// ``RemoteDrawStrings``, and a half-localised SDK that translates the tool
  /// names and nothing else reads worse than one that translates nothing.
  public var title: String {
    switch self {
    case .ink: return "Ink"
    case .whiteboardMarker: return "Marker"
    case .brushPen: return "Brush pen"
    case .fineliner: return "Fineliner"
    case .ballpoint: return "Ballpoint"
    case .pencil: return "Pencil"
    case .chalk: return "Chalk"
    case .charcoal: return "Charcoal"
    case .crayon: return "Crayon"
    case .dryBrush: return "Dry brush"
    case .italicNib: return "Italic nib"
    case .chiselMarker: return "Chisel marker"
    case .tiltPencil: return "Tilt pencil"
    case .highlighter: return "Highlighter"
    case .airbrush: return "Airbrush"
    case .neon: return "Neon"
    }
  }

  /// The same name where the chrome is one line tall — the control cluster and
  /// the radial menu. Falls through to ``title`` for everything that already
  /// fits.
  public var shortTitle: String {
    switch self {
    case .whiteboardMarker: return "Marker"
    case .highlighter: return "Highlight"
    case .chiselMarker: return "Chisel"
    case .tiltPencil: return "Tilt"
    default: return title
    }
  }

  /// An SF Symbol for the picker and the cluster.
  public var systemImage: String {
    switch self {
    case .ink: return "pencil.tip"
    case .whiteboardMarker: return "paintbrush.pointed"
    case .brushPen: return "paintbrush"
    case .fineliner: return "pencil.line"
    case .ballpoint: return "pencil"
    case .pencil: return "pencil.and.outline"
    case .chalk: return "scribble.variable"
    case .charcoal: return "scribble"
    case .crayon: return "pencil.tip.crop.circle"
    case .dryBrush: return "paintbrush.fill"
    case .italicNib: return "signature"
    case .chiselMarker: return "rectangle.slash"
    case .tiltPencil: return "pencil.and.ruler"
    case .highlighter: return "highlighter"
    case .airbrush: return "aqi.medium"
    case .neon: return "light.max"
    }
  }
}
