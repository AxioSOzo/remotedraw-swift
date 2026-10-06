//
//  The persistent chrome, as one bar.
//
//  Three 56pt circles floating over the corner of a drawing were the loudest
//  thing on the screen and said the least: same weight for undo, for a mode and
//  for a whole settings sheet. This is the same three callbacks in one 48pt
//  porcelain bar — two square actions and a labelled segment — so the board
//  reads as paper with a tool bar on it rather than as three buttons with a
//  board behind them.
//
//  ``RemoteDrawControlCluster`` is untouched and still exported: hosts that
//  ship the circles keep them.
//
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  public struct RemoteDrawControlBar: View {
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
    let selectMode: SelectModeConfiguration?
    let textComposer: RemoteDrawTextComposerConfiguration?
    let onUndo: () -> Void
    let onOpenControls: () -> Void

    @Environment(\.remoteDrawAppearance) private var appearance
    @Environment(\.remoteDrawStrings) private var strings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    public init(
      side: RemoteDrawScreenSide,
      isHidden: Bool = false,
      showsUndo: Bool = true,
      isUndoDisabled: Bool = false,
      selectMode: SelectModeConfiguration? = nil,
      textComposer: RemoteDrawTextComposerConfiguration? = nil,
      onUndo: @escaping () -> Void,
      onOpenControls: @escaping () -> Void
    ) {
      self.side = side
      self.isHidden = isHidden
      self.showsUndo = showsUndo
      self.isUndoDisabled = isUndoDisabled
      self.selectMode = selectMode
      self.textComposer = textComposer
      self.onUndo = onUndo
      self.onOpenControls = onOpenControls
    }

    public var body: some View {
      Group {
        if let textComposer {
          RemoteDrawTextComposer(configuration: textComposer)
        } else {
          bar
        }
      }
      // Fade only. The bar is where it is; sliding and shrinking it made the
      // board feel like it was recoiling from the finger.
      .opacity(isHidden ? 0 : 1)
      .animation(.easeOut(duration: 0.16), value: isHidden)
      .allowsHitTesting(!isHidden)
    }

    private var bar: some View {
      HStack(spacing: 4) {
        if let selectMode {
          squareButton(
            systemImage: selectMode.isActive ? "hand.point.up.left.fill" : "hand.point.up.left",
            label: selectMode.isActive ? "Stop selecting" : "Select elements",
            isActive: selectMode.isActive,
            isDisabled: false,
            action: selectMode.onToggle
          )
          .accessibilityAddTraits(selectMode.isActive ? [.isSelected] : [])
          .accessibilityIdentifier("remotedraw.controls.select")
        }

        if showsUndo {
          squareButton(
            systemImage: "arrow.uturn.backward",
            label: strings.undo,
            isActive: false,
            isDisabled: isUndoDisabled,
            action: onUndo
          )
          .accessibilityIdentifier("remotedraw.controls.undo")
        }

        if selectMode != nil || showsUndo {
          Rectangle()
            .fill(RemoteDrawPorcelain.graphite.opacity(0.12))
            .frame(width: 0.5, height: 24)
            .padding(.horizontal, 2)
        }

        Button(action: onOpenControls) {
          HStack(spacing: 7) {
            Image(systemName: "slider.horizontal.3")
              .font(.system(size: 18, weight: .medium))
            Text(strings.controls)
              .font(.system(size: 15, weight: .medium))
              .lineLimit(1)
          }
          .foregroundStyle(RemoteDrawPorcelain.graphite.opacity(0.88))
          .padding(.horizontal, 12)
          .frame(height: 44)
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(strings.controls)
        .accessibilityIdentifier("remotedraw.controls.open")
      }
      .padding(.horizontal, 2)
      .frame(height: 48)
      .background {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        ZStack {
          if reduceTransparency {
            shape.fill(RemoteDrawPorcelain.opaque)
          } else {
            shape.fill(.regularMaterial)
            shape.fill(RemoteDrawPorcelain.tint.opacity(0.5))
          }
          shape.strokeBorder(
            RemoteDrawPorcelain.graphite.opacity(contrast == .increased ? 0.32 : 0.14),
            lineWidth: contrast == .increased ? 1 : 0.5)
        }
      }
      .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
      .accessibilityIdentifier("remotedraw.controls.bar")
    }

    private func squareButton(
      systemImage: String,
      label: String,
      isActive: Bool,
      isDisabled: Bool,
      action: @escaping () -> Void
    ) -> some View {
      Button(action: action) {
        Image(systemName: systemImage)
          .font(.system(size: 18, weight: .medium))
          .foregroundStyle(
            isActive
              ? appearance.accent
              : RemoteDrawPorcelain.graphite.opacity(isDisabled ? 0.3 : 0.88)
          )
          .frame(width: 44, height: 44)
          .background {
            if isActive {
              RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(appearance.accent.opacity(0.16))
            }
          }
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isDisabled)
      .accessibilityLabel(label)
    }
  }
#endif
