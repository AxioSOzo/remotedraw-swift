import SwiftUI

/// Tier 1 — theming. Values only, and every one of them has a default that
/// works.
///
/// The line this type draws is the one §5.4 sets: **anything that changes
/// what goes on the wire is not here.** Cadence, budgets, the codec and the
/// sequence counter are `public let` on ``RemoteDrawSenderSession`` for
/// inspection and are not settable, because a customer who can raise the draft
/// rate can get their own tenant rate-limited. What *is* here is everything a
/// design-system team actually objects to — colour, ground, corner, type
/// scale, handedness, which tools to offer, and every user-facing string.
public struct RemoteDrawAppearance: Sendable {
  /// The accent behind selection rings, active controls and the summon menu.
  public var accent: Color
  /// The ink colour a stroke falls back to when its style names none.
  public var ink: Color
  /// Secondary chrome — labels, hairlines, disabled states.
  public var muted: Color
  /// The highlighter's own fallback, which is not the ink colour: a
  /// highlighter that inherits black is a marker.
  public var highlighter: Color
  /// What the marks are made on. `nil` follows the board's own `target.kind`,
  /// which is what the first-party app does and what a host almost always
  /// wants — a whiteboard board should not draw on paper because the SDK's
  /// default said so.
  public var ground: RemoteDrawGround?
  /// The corner the sheet is drawn with when the phone is a window onto a
  /// larger board. A board the phone *is* has no corner: it runs edge to edge.
  public var cornerRadius: CGFloat
  /// Dynamic Type ceiling. Clamped by default so chrome cannot swallow the
  /// paper — the same clamp the first-party app applies.
  public var maximumDynamicTypeSize: DynamicTypeSize
  /// Which side the one-handed control cluster lives on.
  public var handedness: RemoteDrawHandedness
  /// Whether the surface says whose it is.
  public var branding: Branding

  public enum Branding: Sendable {
    case hidden
    case footnote
  }

  public init(
    accent: Color = RemoteDrawAppearance.defaultAccent,
    ink: Color = RemoteDrawAppearance.defaultInk,
    muted: Color = RemoteDrawAppearance.defaultMuted,
    highlighter: Color = RemoteDrawAppearance.defaultHighlighter,
    ground: RemoteDrawGround? = nil,
    cornerRadius: CGFloat = 18,
    maximumDynamicTypeSize: DynamicTypeSize = .xxxLarge,
    handedness: RemoteDrawHandedness = .automatic,
    branding: Branding = .hidden
  ) {
    self.accent = accent
    self.ink = ink
    self.muted = muted
    self.highlighter = highlighter
    self.ground = ground
    self.cornerRadius = cornerRadius
    self.maximumDynamicTypeSize = maximumDynamicTypeSize
    self.handedness = handedness
    self.branding = branding
  }

  public static let `default` = RemoteDrawAppearance()

  // The first-party app's palette, which is where these numbers come from —
  // `RemoteDrawTheme` in `apps/ios/RemoteDraw/RootView.swift`. They are the
  // defaults rather than the only option: a host that overrides `accent`
  // alone still gets a coherent board.
  public static let defaultInk = Color(red: 0.09, green: 0.09, blue: 0.08)
  public static let defaultMuted = Color(red: 0.38, green: 0.38, blue: 0.34)
  public static let defaultAccent = Color(red: 0.20, green: 0.36, blue: 0.40)
  public static let defaultHighlighter = Color(red: 0.95, green: 0.79, blue: 0.41)

  /// The painter defaults these colours imply.
  var painterDefaults: RemoteDrawStrokePainter.Defaults {
    RemoteDrawStrokePainter.Defaults(
      color: ink, lineWidth: 4, highlighterColor: highlighter)
  }
}

/// Which side of the screen the one-handed controls live on.
public enum RemoteDrawHandedness: String, CaseIterable, Identifiable, Sendable {
  case automatic = "auto"
  case right
  case left

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .automatic: return "Auto"
    case .right: return "Right"
    case .left: return "Left"
    }
  }

  /// Where the cluster goes.
  ///
  /// `automatic` resolves to the right until there is real inference to do it
  /// with. Left as a named case rather than folded into `.right` because the
  /// stored preference has to be able to say "nobody has chosen" — otherwise
  /// shipping inference later would silently override people who had.
  public var resolvedSide: RemoteDrawScreenSide {
    self == .left ? .left : .right
  }
}

public enum RemoteDrawScreenSide: String, Sendable {
  case left
  case right
}

/// Every user-facing string the surface can say.
///
/// One struct rather than a `Bundle` lookup so a host with no localisation
/// story can change one label without adopting one, and so an agent writing
/// the integration can see the whole vocabulary in autocomplete.
public struct RemoteDrawStrings: Sendable {
  public var leave: String
  public var leaveConfirmationTitle: String
  /// Names what is lost. "Are you sure?" names nothing.
  public var leaveConfirmationMessage: String
  public var leaveConfirmationConfirm: String
  public var leaveConfirmationCancel: String
  public var undo: String
  public var clear: String
  public var submit: String
  public var submitted: String
  public var controls: String
  public var snapToShape: String
  public var drawingAreaLabel: String
  public var drawingAreaHint: String

  public init(
    leave: String = "Leave",
    leaveConfirmationTitle: String = "Leave this board?",
    leaveConfirmationMessage: String = "Your last strokes haven't been sent.",
    leaveConfirmationConfirm: String = "Leave",
    leaveConfirmationCancel: String = "Keep drawing",
    undo: String = "Undo",
    clear: String = "Clear",
    submit: String = "Submit",
    submitted: String = "Submitted",
    controls: String = "Controls",
    snapToShape: String = "Snap to shape",
    drawingAreaLabel: String = "Drawing area",
    drawingAreaHint: String = "Double-tap and hold, then drag, to draw."
  ) {
    self.leave = leave
    self.leaveConfirmationTitle = leaveConfirmationTitle
    self.leaveConfirmationMessage = leaveConfirmationMessage
    self.leaveConfirmationConfirm = leaveConfirmationConfirm
    self.leaveConfirmationCancel = leaveConfirmationCancel
    self.undo = undo
    self.clear = clear
    self.submit = submit
    self.submitted = submitted
    self.controls = controls
    self.snapToShape = snapToShape
    self.drawingAreaLabel = drawingAreaLabel
    self.drawingAreaHint = drawingAreaHint
  }

  public static let `default` = RemoteDrawStrings()
}

/// The muted editorial palette the swatch strip offers, shared with the web
/// senders. The first entry is the default ink.
public enum RemoteDrawColorPalette {
  public static let defaultColor = "#151512"

  /// Turns a palette hex into a `Color`.
  ///
  /// In one place because the swatches appear in two — the board's colour
  /// strip and the host's own settings — and two copies would be two chances
  /// to drift.
  public static func color(
    _ hex: String, fallback: Color = RemoteDrawAppearance.defaultInk
  ) -> Color {
    let raw = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
    guard raw.count == 6, let number = Int(raw, radix: 16) else { return fallback }
    return Color(
      red: Double((number >> 16) & 0xff) / 255.0,
      green: Double((number >> 8) & 0xff) / 255.0,
      blue: Double(number & 0xff) / 255.0
    )
  }

  public static let swatches: [(hex: String, title: String)] = [
    ("#151512", "Ink"),
    ("#6f675f", "Warm gray"),
    ("#1f7a8c", "Teal"),
    ("#2f6b4f", "Forest"),
    ("#b45309", "Amber"),
    ("#9f1239", "Crimson"),
    ("#1e40af", "Blue"),
  ]

  /// Whether a stored swatch is well-formed enough to ride the wire.
  ///
  /// Anything else falls back to the board's own default ink, so a corrupted
  /// preference cannot put junk in a stroke's style.
  public static func wireColor(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard trimmed.count == 7, trimmed.hasPrefix("#"),
      Int(trimmed.dropFirst(), radix: 16) != nil
    else { return nil }
    // The default swatch rides the receiver's own default ink, so it is
    // omitted from the wire — native and web senders both transmit no colour
    // by default, and sending one would override a board that themed itself.
    if trimmed.caseInsensitiveCompare(defaultColor) == .orderedSame { return nil }
    return trimmed
  }
}

// MARK: - Environment

private struct RemoteDrawAppearanceKey: EnvironmentKey {
  static let defaultValue = RemoteDrawAppearance.default
}

private struct RemoteDrawStringsKey: EnvironmentKey {
  static let defaultValue = RemoteDrawStrings.default
}

extension EnvironmentValues {
  /// The theme in force for the surface below.
  ///
  /// Through the environment rather than threaded as an argument because the
  /// chrome is a dozen small views and an appearance parameter on each of them
  /// is a dozen call sites to keep in step. Scoped to the SDK's own subtree, so
  /// it never touches the host's.
  public var remoteDrawAppearance: RemoteDrawAppearance {
    get { self[RemoteDrawAppearanceKey.self] }
    set { self[RemoteDrawAppearanceKey.self] = newValue }
  }

  public var remoteDrawStrings: RemoteDrawStrings {
    get { self[RemoteDrawStringsKey.self] }
    set { self[RemoteDrawStringsKey.self] = newValue }
  }
}
