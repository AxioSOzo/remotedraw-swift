// The full-screen takeover, built on the embeddable surface.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  /// How a session finished, from the host's point of view.
  ///
  /// A closed enum, so an agent that writes a non-exhaustive `switch` gets a
  /// compiler error rather than a silent path.
  public enum RemoteDrawOutcome: Sendable {
    /// The drawing was submitted. The receipt carries the server's own record.
    case submitted(RemoteDrawReceipt)
    /// The person left. Anything they drew is on the board; nothing was
    /// submitted.
    case left
    /// The board finished, or the session timed out, while the surface was up.
    ///
    /// Both are terminal and both call for the same recovery — a new session
    /// from your backend — which is why they are one case. What used to be
    /// folded in here and is **not** any more is ``credentialLost``: that one is
    /// recoverable, and reporting it as an expiry sent hosts to create a new
    /// session for a board that was still running.
    case expired
    /// The sender's credential stopped working while the board carried on.
    ///
    /// A sender token's expiry is pinned to the session's expiry **at join
    /// time** and never patched, while the session's own expiry slides forward
    /// while someone draws — so a long board outlives its credential. It is also
    /// what happens when the token is revoked: `/v1/join` revokes every other
    /// active sender on the session, so a second device scanning the QR knocks
    /// this one off.
    ///
    /// **The wire cannot tell those two apart.** `convex/lib/auth.ts` answers a
    /// malformed, an unknown and a *revoked* token with one
    /// `invalid_sender_token`, on purpose — the token is the whole credential —
    /// and only a genuine expiry of a still-wanted token gets its own
    /// `sender_token_expired`. The distinguishable half travels in the
    /// associated error; there is no honest `.revoked` to report.
    ///
    /// Recover by asking your backend for a fresh token
    /// (`POST /v1/sessions/direct-sender`) and presenting the surface again.
    /// Supply ``RemoteDrawConfiguration/tokenProvider`` and the SDK does it for
    /// you before this is ever reported.
    case credentialLost(RemoteDrawError?)
    /// The board asked for something this SDK has no renderer for.
    ///
    /// Reported **without dismissing the surface**, which stays up showing the
    /// reason: a cover that closes itself with no explanation is the white
    /// screen again, one step earlier. Read
    /// ``RemoteDrawUnsupportedSurface/hostedSenderURL`` to hand the person the
    /// hosted pad, which can do what this one cannot.
    case unsupportedSurface(RemoteDrawUnsupportedSurface)
    case failed(RemoteDrawError)
  }

  /// What happens when someone tries to leave.
  public struct RemoteDrawExit: Sendable {
    public enum Style: Sendable {
      /// Leave immediately.
      case immediate
      /// Ask first, but only when there is something to lose.
      ///
      /// "Something to lose" is a stroke that has not been submitted on a board
      /// that accepts submissions — not merely "has drawn". On a board with no
      /// submission there is nothing pending, and a confirmation there is a
      /// dialog that answers a question nobody asked.
      case confirmWhenUnsubmitted
    }

    public var style: Style
    /// Whether the exit is *also* reachable from the controls sheet.
    ///
    /// There is no case for hiding it from the screen. The close control in the
    /// corner is not configurable, and that is a deliberate refusal: a
    /// full-screen takeover a person cannot leave is an App Store guideline 4.2
    /// exposure for the *host*, and the host cannot audit our view hierarchy to
    /// discover they have one. The SDK will not ship a setting whose only effect
    /// is to get its customer rejected.
    public var showsInControls: Bool
    /// Whether a downward drag can dismiss the cover.
    ///
    /// Off by default: a downward flick is a stroke on a drawing surface.
    public var allowsInteractiveDismiss: Bool

    public init(
      style: Style = .confirmWhenUnsubmitted,
      showsInControls: Bool = true,
      allowsInteractiveDismiss: Bool = false
    ) {
      self.style = style
      self.showsInControls = showsInControls
      self.allowsInteractiveDismiss = allowsInteractiveDismiss
    }

    public static let `default` = RemoteDrawExit()
  }

  /// ``RemoteDrawSurface`` plus session chrome, scene-phase wiring and a way
  /// out.
  ///
  /// Present it in a `fullScreenCover`, or reach for the
  /// ``SwiftUI/View/remoteDrawSurface(isPresented:senderToken:appearance:strings:exit:onOutcome:)``
  /// modifier, which does that for you and joins the session on the way in.
  public struct RemoteDrawTakeover: View {
    @ObservedObject private var session: RemoteDrawSenderSession
    private let appearance: RemoteDrawAppearance
    private let strings: RemoteDrawStrings
    private let exit: RemoteDrawExit
    private let background: ((RemoteDrawGroundContext) -> AnyView)?
    private let onOutcome: (RemoteDrawOutcome) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingExit = false
    @State private var hasReportedOutcome = false
    @State private var hasReportedUnsupported = false

    public init(
      session: RemoteDrawSenderSession,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      exit: RemoteDrawExit = .default,
      onOutcome: @escaping (RemoteDrawOutcome) -> Void = { _ in }
    ) {
      self.session = session
      self.appearance = appearance
      self.strings = strings
      self.exit = exit
      self.background = nil
      self.onOutcome = onOutcome
    }

    /// The takeover with a ground of your own behind the ink. See
    /// ``RemoteDrawGroundContext``.
    public init<Background: View>(
      session: RemoteDrawSenderSession,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      exit: RemoteDrawExit = .default,
      onOutcome: @escaping (RemoteDrawOutcome) -> Void = { _ in },
      @ViewBuilder background: @escaping (RemoteDrawGroundContext) -> Background
    ) {
      self.session = session
      self.appearance = appearance
      self.strings = strings
      self.exit = exit
      self.background = { AnyView(background($0)) }
      self.onOutcome = onOutcome
    }

    public var body: some View {
      ZStack(alignment: .topLeading) {
        if let background {
          RemoteDrawSurface(
            session: session,
            appearance: appearance,
            strings: strings,
            onLeave: exit.showsInControls ? requestExit : nil,
            background: background
          )
        } else {
          RemoteDrawSurface(
            session: session,
            appearance: appearance,
            strings: strings,
            onLeave: exit.showsInControls ? requestExit : nil
          )
        }

        closeControl
      }
      .environment(\.remoteDrawAppearance, appearance)
      .environment(\.remoteDrawStrings, strings)
      .preferredColorScheme(.light)
      .confirmationDialog(
        strings.leaveConfirmationTitle,
        isPresented: $isConfirmingExit,
        titleVisibility: .visible
      ) {
        Button(strings.leaveConfirmationConfirm, role: .destructive) { leave() }
        Button(strings.leaveConfirmationCancel, role: .cancel) {}
      } message: {
        Text(strings.leaveConfirmationMessage)
      }
      .onChange(of: scenePhase) { _, phase in
        // Presence is a heartbeat, not a leave signal — but a backgrounded
        // phone that keeps pinging holds a session open against the customer's
        // quota for nothing.
        Task {
          phase == .active ? await session.markActive() : await session.markInactive()
        }
      }
      .onChange(of: session.phase) { _, phase in
        switch phase {
        case .submitted:
          report(.submitted(RemoteDrawReceipt.placeholder))
        case .ended(.ended):
          report(.expired)
        case .ended(.tokenLost):
          // Not an expiry. The board may still be running; the credential is
          // what stopped. `lastError` carries whichever of the two the wire was
          // able to distinguish — see ``RemoteDrawOutcome/credentialLost(_:)``.
          report(.credentialLost(session.lastError))
        case .ended(.failed(let message)):
          report(.failed(.transport(message)))
        default:
          break
        }
      }
      .onChange(of: unsupportedSurface) { _, unsupported in
        reportUnsupported(unsupported)
      }
      .onAppear { reportUnsupported(unsupportedSurface) }
    }

    /// The board asking for something this SDK cannot draw, if it is.
    ///
    /// Read from the session rather than from the surface so a host using the
    /// one-liner is told even though the surface is the thing showing it.
    private var unsupportedSurface: RemoteDrawUnsupportedSurface? {
      guard session.session?.requestsStreaming == true else { return nil }
      return .streaming(senderToken: session.senderToken)
    }

    /// Reported once, and **without latching the terminal outcome**: the person
    /// can still leave, and that leave is still a `.left`.
    private func reportUnsupported(_ unsupported: RemoteDrawUnsupportedSurface?) {
      guard let unsupported, !hasReportedUnsupported, !hasReportedOutcome else { return }
      hasReportedUnsupported = true
      onOutcome(.unsupportedSurface(unsupported))
    }

    /// Always present, never configurable. See ``RemoteDrawExit/showsInControls``.
    private var closeControl: some View {
      Button(action: requestExit) {
        Image(systemName: "chevron.down")
          .font(.system(size: 17, weight: .bold))
      }
      .buttonStyle(RemoteDrawFloatingCircleButtonStyle())
      .padding(.leading, 18)
      .padding(.top, 8)
      .accessibilityLabel(strings.leave)
    }

    private func requestExit() {
      switch exit.style {
      case .immediate:
        leave()
      case .confirmWhenUnsubmitted:
        if hasUnsubmittedWork {
          isConfirmingExit = true
        } else {
          leave()
        }
      }
    }

    private var hasUnsubmittedWork: Bool {
      guard session.capabilities.contains(.submit) else { return false }
      guard session.session?.acceptsSubmission != false else { return false }
      guard case .submitted = session.phase else { return !session.strokes.isEmpty }
      return false
    }

    private func leave() {
      session.leave()
      report(.left)
    }

    private func report(_ outcome: RemoteDrawOutcome) {
      guard !hasReportedOutcome else { return }
      hasReportedOutcome = true
      onOutcome(outcome)
    }
  }

  extension RemoteDrawReceipt {
    /// What a takeover reports when the session says it was submitted but the
    /// host did not make the call itself — a submit from the controls sheet, or
    /// from a header slot.
    ///
    /// It carries no ids because there are none to carry here: the receipt the
    /// server minted was returned to whoever called
    /// ``RemoteDrawSenderSession/submit(metadata:)``. A host that needs the
    /// server's record calls `submit` and reads the value.
    static let placeholder = RemoteDrawReceipt(
      id: nil, status: "submitted", accepted: true, duplicate: false, message: nil,
      submittedAt: nil)
  }

  // MARK: - The one-line integration

  extension View {
    /// Presents the RemoteDraw board full screen, joining the session on the way
    /// in and reporting how it finished.
    ///
    /// ```swift
    /// Button("Draw") { drawing = true }
    ///   .remoteDrawSurface(isPresented: $drawing, senderToken: token) { outcome in
    ///     switch outcome {
    ///     case .submitted(let receipt):     record(receipt)
    ///     case .left:                       dismissBanner()
    ///     case .expired:                    refreshSession()
    ///     case .credentialLost:             refreshToken()
    ///     case .unsupportedSurface(let it): open(it.hostedSenderURL)
    ///     case .failed(let error):          report(error)
    ///     }
    ///   }
    /// ```
    ///
    /// **There is nothing to configure first.** ``RemoteDraw/shared`` installs
    /// production defaults on first use, so this line is the whole integration.
    /// Call ``RemoteDraw/configure(_:)`` from your `App.init` only to change the
    /// base URL, the device description or the token provider.
    ///
    /// `senderToken` is an `rd_send_…` from your backend's
    /// `POST /v1/sessions/direct-sender`. A join token works too — it is
    /// recognised by prefix — but spending one **revokes every other active
    /// sender on that session**, so it is the QR path and not the host-initiated
    /// one.
    public func remoteDrawSurface(
      isPresented: Binding<Bool>,
      senderToken: String,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      exit: RemoteDrawExit = .default,
      onOutcome: @escaping (RemoteDrawOutcome) -> Void = { _ in }
    ) -> some View {
      modifier(
        RemoteDrawSurfaceModifier(
          isPresented: isPresented,
          senderToken: senderToken,
          appearance: appearance,
          strings: strings,
          exit: exit,
          background: nil,
          onOutcome: onOutcome
        ))
    }

    /// The same one-liner, with your own ground behind the ink.
    ///
    /// ```swift
    /// .remoteDrawSurface(isPresented: $drawing, senderToken: token) { ground in
    ///   MapboxView(bounds: ground.mapBounds)
    ///     .onCameraIdle { ground.reportViewport(currentBoardRectangle()) }
    /// } onOutcome: { outcome in
    ///   …
    /// }
    /// ```
    ///
    /// ## Precedence
    ///
    /// This builder wins over everything. Omit it and a `kind: "map"` board with
    /// `coordinateSpace.bounds` gets the built-in MapKit ground; omit it on any
    /// other board and the canvas paints its own paper, whiteboard or flat tone.
    /// The builder is never *merged* with the built-in ground — a host that
    /// supplies one owns the whole layer, which is the only way "keep my own
    /// cartography" can mean anything.
    ///
    /// A ground that moves must call ``RemoteDrawGroundContext/reportViewport``.
    /// A static one calls nothing and every stroke stays in surface space.
    public func remoteDrawSurface<Background: View>(
      isPresented: Binding<Bool>,
      senderToken: String,
      appearance: RemoteDrawAppearance = .default,
      strings: RemoteDrawStrings = .default,
      exit: RemoteDrawExit = .default,
      @ViewBuilder background: @escaping (RemoteDrawGroundContext) -> Background,
      onOutcome: @escaping (RemoteDrawOutcome) -> Void = { _ in }
    ) -> some View {
      modifier(
        RemoteDrawSurfaceModifier(
          isPresented: isPresented,
          senderToken: senderToken,
          appearance: appearance,
          strings: strings,
          exit: exit,
          background: { AnyView(background($0)) },
          onOutcome: onOutcome
        ))
    }
  }

  private struct RemoteDrawSurfaceModifier: ViewModifier {
    @Binding var isPresented: Bool
    let senderToken: String
    let appearance: RemoteDrawAppearance
    let strings: RemoteDrawStrings
    let exit: RemoteDrawExit
    let background: ((RemoteDrawGroundContext) -> AnyView)?
    let onOutcome: (RemoteDrawOutcome) -> Void

    @State private var session: RemoteDrawSenderSession?
    @State private var failure: RemoteDrawError?

    /// A takeover outcome closes the cover — except the one that is a message
    /// rather than an ending. See ``RemoteDrawOutcome/unsupportedSurface(_:)``.
    private func handle(_ outcome: RemoteDrawOutcome) {
      if case .unsupportedSurface = outcome {
        onOutcome(outcome)
        return
      }
      isPresented = false
      onOutcome(outcome)
    }

    func body(content: Content) -> some View {
      content.fullScreenCover(isPresented: $isPresented) {
        Group {
          if let session {
            if let background {
              RemoteDrawTakeover(
                session: session,
                appearance: appearance,
                strings: strings,
                exit: exit,
                onOutcome: handle,
                background: background
              )
            } else {
              RemoteDrawTakeover(
                session: session,
                appearance: appearance,
                strings: strings,
                exit: exit,
                onOutcome: handle
              )
            }
          } else {
            RemoteDrawConnectingView(
              failure: failure,
              onCancel: {
                isPresented = false
                onOutcome(failure.map(RemoteDrawOutcome.failed) ?? .left)
              }
            )
          }
        }
        .interactiveDismissDisabled(!exit.allowsInteractiveDismiss)
        .task {
          guard session == nil else { return }
          // Cleared on the way in: re-presenting after a failure used to show
          // the old error next to a spinner for the retry already in flight.
          failure = nil
          do {
            // `RemoteDraw.shared` configures itself against production if the
            // host never called `configure(_:)`. It used to trap here instead —
            // and a `preconditionFailure` is not an `Error`, so the `catch`
            // below could never turn it into an outcome. The customer got a
            // crash on their user's tap.
            session = try await RemoteDraw.shared.join(rawToken: senderToken)
          } catch {
            failure = (error as? RemoteDrawError) ?? .transport(error.localizedDescription)
          }
        }
      }
    }
  }

  /// One waiting screen, for every wait.
  ///
  /// Named stages, never a percentage, and **never a URL, a host or a token** —
  /// an earlier version of the first-party app's put the deployment hostname
  /// under the spinner, which told the person nothing and leaked where the app
  /// pointed. The cancel button appears only after ~6 s, so a normal connect
  /// never shows a give-up button.
  private struct RemoteDrawConnectingView: View {
    let failure: RemoteDrawError?
    let onCancel: () -> Void

    @Environment(\.remoteDrawAppearance) private var appearance
    @State private var showsCancel = false

    var body: some View {
      ZStack {
        appearance.ground?.flatColor.ignoresSafeArea() ?? Color.white.ignoresSafeArea()
        VStack(spacing: 18) {
          if let failure {
            Image(systemName: "exclamationmark.triangle")
              .font(.system(size: 32, weight: .semibold))
              .foregroundStyle(appearance.muted)
            Text(failure.errorDescription ?? "That board is not available.")
              .multilineTextAlignment(.center)
              .font(.system(size: 15, weight: .medium))
              .foregroundStyle(appearance.ink)
              .padding(.horizontal, 40)
          } else {
            ProgressView().controlSize(.large)
            Text("Opening the board")
              .font(.system(size: 15, weight: .semibold))
              .foregroundStyle(appearance.muted)
          }
          if showsCancel || failure != nil {
            Button("Cancel", action: onCancel)
              .buttonStyle(.bordered)
              .tint(appearance.accent)
          }
        }
      }
      .task {
        try? await Task.sleep(nanoseconds: 6_000_000_000)
        showsCancel = true
      }
    }
  }
#endif
