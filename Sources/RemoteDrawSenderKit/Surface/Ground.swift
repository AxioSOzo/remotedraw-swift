// What sits behind the ink, and what to say when the board wants something this
// SDK cannot draw.
//
// The two value types are deliberately outside the UIKit guard: `swift test`
// runs this package on macOS and compiles nothing inside one, so a contract
// declared in there is a contract no test can check. Only the *view* needs
// UIKit.
import CoreGraphics
import Foundation

/// What a host's own ground needs to know, and the one thing it has to say
/// back.
///
/// Handed to the `background:` builder on ``RemoteDrawSurface``,
/// ``RemoteDrawTakeover`` and
/// ``SwiftUI/View/remoteDrawSurface(isPresented:senderToken:appearance:strings:exit:background:onOutcome:)``.
///
/// ``reportViewport`` is the whole contract. A ground that **moves** — a map
/// camera, a scrolling plan, a zoomable photo — must say which board rectangle
/// it is currently showing, and the surface re-installs its stroke space from
/// that. Without it the ink stays pinned to the screen while the ground slides
/// underneath, which is the exact failure `@remotedraw/geometry`'s map module
/// opens by warning about.
///
/// A **static** ground reports nothing and the surface keeps
/// ``RemoteDrawBoardViewport/full`` — the identity mapping, which is right for
/// any ground that does not move.
public struct RemoteDrawGroundContext {
  /// The board, as the sender knows it.
  public let session: RemoteDrawSession?
  /// The board's geographic fence, when it declared one. `nil` on any board
  /// that is not a map, and on a map board created without
  /// `coordinateSpace.bounds`.
  public let mapBounds: RemoteDrawMapBounds?
  /// The receiver's current window onto the board, when it has one.
  public let phoneProjection: RemoteDrawProjection?
  /// The size the ground is being drawn at, in points.
  public let size: CGSize
  /// Tell the surface which board rectangle this ground is showing.
  public let reportViewport: @MainActor (RemoteDrawBoardViewport) -> Void

  public init(
    session: RemoteDrawSession?,
    mapBounds: RemoteDrawMapBounds?,
    phoneProjection: RemoteDrawProjection?,
    size: CGSize,
    reportViewport: @escaping @MainActor (RemoteDrawBoardViewport) -> Void
  ) {
    self.session = session
    self.mapBounds = mapBounds
    self.phoneProjection = phoneProjection
    self.size = size
    self.reportViewport = reportViewport
  }
}

/// A board this SDK cannot draw, with the reason and what to do instead.
///
/// The alternative to what shipped before, which was **nothing**: a session
/// that asked for a streaming sender got a pad with no ground, no video and no
/// message — a white screen with the customer's ink on it and no way to find
/// out why. See `docs/plans/2026-08-30-audit-connection-and-streaming.md` §2.6.
public struct RemoteDrawUnsupportedSurface: Equatable, Sendable, Identifiable {
  public enum Reason: Equatable, Sendable {
    /// The session asked for a streaming sender — `senderIntegrationMode:
    /// "streaming"`, or a legacy response with no mode and live view enabled — and
    /// this package has no WebRTC, no video and no `WKWebView`. That is a
    /// deliberate dependency choice (`Package.swift`: zero external
    /// dependencies), not an oversight, so it is reported rather than
    /// half-implemented.
    case streamingRequested
  }

  public let reason: Reason
  /// One sentence for a person.
  public let message: String
  /// One sentence for whoever has to fix it. Written as an action, because the
  /// reader is often an agent that will follow it verbatim.
  public let recoverySuggestion: String
  /// The hosted pad that **can** consume this board's stream, already carrying
  /// this sender's credential.
  ///
  /// Present a `WKWebView`/`SFSafariViewController` on it and streaming works
  /// today — that page is the only implemented consumer. The token travels in
  /// the fragment so it never reaches a server log, and `native=1` is
  /// deliberately absent: without it the page keeps its own controls instead
  /// of waiting for a native chrome host that a customer app does not have.
  public let hostedSenderURL: URL?

  public var id: String { "\(reason)-\(hostedSenderURL?.absoluteString ?? "")" }

  public init(
    reason: Reason,
    message: String,
    recoverySuggestion: String,
    hostedSenderURL: URL?
  ) {
    self.reason = reason
    self.message = message
    self.recoverySuggestion = recoverySuggestion
    self.hostedSenderURL = hostedSenderURL
  }

  /// Where the hosted pad lives. Not configurable: it is RemoteDraw's own
  /// surface, the same one every QR code points at.
  static let hostedSenderOrigin = "https://app.remotedraw.com/join"

  /// RFC 3986's unreserved set, which every character of an `rd_send_…` already
  /// belongs to — so the escape is a guard rather than a transformation.
  /// `.alphanumerics` alone is wrong here: it escapes the token's own
  /// underscores into `%5F`, and the page compares the string it is given.
  private static func escaped(_ token: String) -> String {
    let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
    return token.addingPercentEncoding(withAllowedCharacters: unreserved) ?? token
  }

  static func streaming(senderToken: String) -> RemoteDrawUnsupportedSurface {
    RemoteDrawUnsupportedSurface(
      reason: .streamingRequested,
      message: "This board streams the receiver's screen, which this app cannot show.",
      recoverySuggestion:
        "Open the hostedSenderURL in a WKWebView to get the stream today, or create the session with senderIntegrationMode: \"native\" and visualContext omitted so the board draws its own surface on the phone.",
      hostedSenderURL: URL(
        string: "\(hostedSenderOrigin)#senderToken=\(escaped(senderToken))")
    )
  }
}

#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  /// The panel a board this SDK cannot draw shows instead of an empty pad.
  ///
  /// Deliberately not a `.alert`: an alert is dismissed and then the person is
  /// looking at the white screen again. This *is* the screen, and it stays.
  struct RemoteDrawUnsupportedSurfaceView: View {
    let unsupported: RemoteDrawUnsupportedSurface
    let onLeave: (() -> Void)?

    @Environment(\.remoteDrawAppearance) private var appearance
    @Environment(\.remoteDrawStrings) private var strings

    var body: some View {
      ZStack {
        Color.white.ignoresSafeArea()
        VStack(spacing: 16) {
          Image(systemName: "rectangle.on.rectangle.slash")
            .font(.system(size: 34, weight: .semibold))
            .foregroundStyle(appearance.muted)
          Text(unsupported.message)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(appearance.ink)
            .multilineTextAlignment(.center)
          Text(unsupported.recoverySuggestion)
            .font(.system(size: 13))
            .foregroundStyle(appearance.muted)
            .multilineTextAlignment(.center)
          if let onLeave {
            Button(strings.leave, action: onLeave)
              .buttonStyle(.bordered)
              .tint(appearance.accent)
          }
        }
        .padding(.horizontal, 32)
      }
    }
  }
#endif
