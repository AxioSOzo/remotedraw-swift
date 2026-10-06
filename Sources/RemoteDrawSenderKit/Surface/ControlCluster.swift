// Chrome. UIKit-only because it speaks to the haptics engine and the
// keyboard; `swift test` runs this package on macOS, so it is guarded
// rather than ported.
#if canImport(UIKit) && !os(watchOS)
import SwiftUI

/// Compact floating cluster of one-hand actions (undo and controls).
/// Sits in the bottom corner chosen by handedness and hides while a touch is
/// interacting with the board.
public struct RemoteDrawControlCluster: View {
  /// Entry and exit for select mode, when the session allows editing elements.
  ///
  /// It sits in the cluster rather than only in the controls sheet because
  /// switching modes is the one thing select mode asks of a thumb repeatedly,
  /// and a mode you have to open a sheet to leave is a mode people avoid
  /// entering.
  public struct SelectModeConfiguration {
    let isActive: Bool
    let onToggle: () -> Void

    public init(isActive: Bool, onToggle: @escaping () -> Void) {
      self.isActive = isActive
      self.onToggle = onToggle
    }
  }

  let side: RemoteDrawScreenSide
  let isHidden: Bool
  let showsUndo: Bool
  let isUndoDisabled: Bool
  let toolSystemImage: String
  let selectMode: SelectModeConfiguration?
  let textComposer: RemoteDrawTextComposerConfiguration?
  let onUndo: () -> Void
  let onOpenControls: () -> Void

  @Environment(\.remoteDrawAppearance) private var appearance
  @Environment(\.remoteDrawStrings) private var strings

  public init(
    side: RemoteDrawScreenSide,
    isHidden: Bool = false,
    showsUndo: Bool = true,
    isUndoDisabled: Bool = false,
    toolSystemImage: String,
    selectMode: SelectModeConfiguration? = nil,
    textComposer: RemoteDrawTextComposerConfiguration? = nil,
    onUndo: @escaping () -> Void,
    onOpenControls: @escaping () -> Void
  ) {
    self.side = side
    self.isHidden = isHidden
    self.showsUndo = showsUndo
    self.isUndoDisabled = isUndoDisabled
    self.toolSystemImage = toolSystemImage
    self.selectMode = selectMode
    self.textComposer = textComposer
    self.onUndo = onUndo
    self.onOpenControls = onOpenControls
  }

  public var body: some View {
    VStack(alignment: side == .right ? .trailing : .leading, spacing: 8) {
      if let textComposer {
        RemoteDrawTextComposer(configuration: textComposer)
      } else {
        HStack(spacing: 10) {
          if let selectMode {
            Button(action: selectMode.onToggle) {
              Image(systemName: selectMode.isActive ? "hand.point.up.left.fill" : "hand.point.up.left")
                .font(.system(size: 18, weight: .bold))
                .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(RemoteDrawFloatingCircleButtonStyle(isActive: selectMode.isActive))
            .accessibilityLabel(selectMode.isActive ? "Stop selecting" : "Select elements")
            .accessibilityAddTraits(selectMode.isActive ? [.isSelected] : [])
          }

          if showsUndo {
            Button(action: onUndo) {
              Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 18, weight: .bold))
            }
            .buttonStyle(RemoteDrawFloatingCircleButtonStyle())
            .disabled(isUndoDisabled)
            .accessibilityLabel(strings.undo)
          }

          Button(action: onOpenControls) {
            Image(systemName: toolSystemImage)
              .font(.system(size: 18, weight: .bold))
              .contentTransition(.symbolEffect(.replace))
          }
          .buttonStyle(RemoteDrawFloatingCircleButtonStyle())
          .accessibilityLabel(strings.controls)
        }
      }
    }
    .opacity(isHidden ? 0 : 1)
    .scaleEffect(
      isHidden ? 0.82 : 1,
      anchor: side == .right ? .bottomTrailing : .bottomLeading
    )
    .offset(y: isHidden ? 26 : 0)
    .animation(.spring(response: 0.42, dampingFraction: 0.82), value: isHidden)
    .allowsHitTesting(!isHidden)
  }
}

public struct RemoteDrawTextComposerConfiguration {
  let text: Binding<String>
  let focus: FocusState<Bool>.Binding
  let isCommitDisabled: Bool
  let onCommit: () -> Void

  public init(
    text: Binding<String>,
    focus: FocusState<Bool>.Binding,
    isCommitDisabled: Bool,
    onCommit: @escaping () -> Void
  ) {
    self.text = text
    self.focus = focus
    self.isCommitDisabled = isCommitDisabled
    self.onCommit = onCommit
  }
}

/// Internal rather than private so ``RemoteDrawControlBar`` can present the
/// same composer: one text field for both chromes, not two that drift.
struct RemoteDrawTextComposer: View {
  let configuration: RemoteDrawTextComposerConfiguration

  @Environment(\.remoteDrawAppearance) private var appearance

  var body: some View {
    HStack(spacing: 10) {
      Image(systemName: "mappin.and.ellipse")
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(appearance.ink.opacity(0.74))

      TextField("Text", text: configuration.text)
        .textFieldStyle(.plain)
        .focused(configuration.focus)
        .submitLabel(.done)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(appearance.ink)
        .autocorrectionDisabled(false)
        .onSubmit(configuration.onCommit)

      Button(action: configuration.onCommit) {
        Image(systemName: "checkmark")
          .font(.system(size: 20, weight: .bold))
      }
      .buttonStyle(.plain)
      .foregroundStyle(
        appearance.ink.opacity(configuration.isCommitDisabled ? 0.28 : 0.86)
      )
      .disabled(configuration.isCommitDisabled)
      .accessibilityLabel("Place text")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: 520)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .stroke(.black.opacity(0.08), lineWidth: 0.5)
    )
    .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
  }
}

public struct RemoteDrawFloatingCircleButtonStyle: ButtonStyle {
  /// Latches the button on, for a control that names a mode rather than an
  /// action. Nothing else in the cluster has a state to show, so this defaults
  /// off and leaves every existing call site unchanged.
  public var isActive: Bool

  @Environment(\.remoteDrawAppearance) private var appearance

  public init(isActive: Bool = false) {
    self.isActive = isActive
  }

  public func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .frame(width: 56, height: 56)
      .foregroundStyle(
        isActive
          ? Color.white.opacity(configuration.isPressed ? 0.7 : 1)
          : appearance.ink.opacity(configuration.isPressed ? 0.55 : 0.88)
      )
      .background(
        Circle().fill(
          isActive
            ? AnyShapeStyle(appearance.accent)
            : AnyShapeStyle(.regularMaterial)
        )
      )
      .overlay(Circle().strokeBorder(.white.opacity(0.4), lineWidth: 0.5))
      .overlay(Circle().strokeBorder(.black.opacity(0.06), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.16), radius: 16, y: 7)
      .scaleEffect(configuration.isPressed ? 0.92 : 1)
      .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
  }
}
#endif
