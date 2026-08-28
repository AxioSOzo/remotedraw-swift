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
    case expired
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
    private let onOutcome: (RemoteDrawOutcome) -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var isConfirmingExit = false
    @State private var hasReportedOutcome = false

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
      self.onOutcome = onOutcome
    }

    public var body: some View {
      ZStack(alignment: .topLeading) {
        RemoteDrawSurface(
          session: session,
          appearance: appearance,
          strings: strings,
          onLeave: exit.showsInControls ? requestExit : nil
        )

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
        case .ended(.ended), .ended(.tokenLost):
          report(.expired)
        case .ended(.failed(let message)):
          report(.failed(.transport(message)))
        default:
          break
        }
      }
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
    ///     case .submitted(let receipt):  record(receipt)
    ///     case .left:                    dismissBanner()
    ///     case .expired:                 refreshSession()
    ///     case .failed(let error):       report(error)
    ///     }
    ///   }
    /// ```
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
    let onOutcome: (RemoteDrawOutcome) -> Void

    @State private var session: RemoteDrawSenderSession?
    @State private var failure: RemoteDrawError?

    func body(content: Content) -> some View {
      content.fullScreenCover(isPresented: $isPresented) {
        Group {
          if let session {
            RemoteDrawTakeover(
              session: session,
              appearance: appearance,
              strings: strings,
              exit: exit,
              onOutcome: { outcome in
                isPresented = false
                onOutcome(outcome)
              }
            )
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
          do {
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
