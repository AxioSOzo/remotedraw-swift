// The controls sheet, as sections rather than as a sheet.
//
// A whole sheet would have been the smaller API and the wrong one. The
// first-party board's sheet carries three rows that are not the SDK's — sender
// mode, move portal, select elements — and §5.4 allows the surface exactly two
// chrome slots, so an `extraSections` builder would be a third one in disguise.
// Shipping the *sections* instead means the app assembles its own sheet from
// the same instrument picker the SDK's uses, which is where every parity risk
// actually lives: sixteen instruments, a thickness scale, seven swatches and a
// fill toggle, all of which have to agree with the renderer.
//
// `RemoteDrawControlsSheet` below is the assembled default, for a host that
// wants the sheet and not the pieces.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  /// Which instrument, how thick, what colour, and whether shapes fill.
  ///
  /// Place inside a `Form`. Every binding writes through to
  /// ``RemoteDrawPreferences``' keys when the caller has them backed by
  /// `@AppStorage`, which is what makes the choice outlive the session.
  public struct RemoteDrawInstrumentSection: View {
    @Binding var styleKindRaw: String
    @Binding var thickness: Double
    @Binding var colorRaw: String
    @Binding var isFillEnabled: Bool

    @Environment(\.remoteDrawAppearance) private var appearance

    public init(
      styleKindRaw: Binding<String>,
      thickness: Binding<Double>,
      colorRaw: Binding<String>,
      isFillEnabled: Binding<Bool>
    ) {
      self._styleKindRaw = styleKindRaw
      self._thickness = thickness
      self._colorRaw = colorRaw
      self._isFillEnabled = isFillEnabled
    }

    public var body: some View {
      Section {
        // Sixteen instruments is too many for a flat menu; grouping by family
        // keeps the list scannable and puts related nibs together.
        Picker("Style", selection: styleBinding) {
          ForEach(DrawingStyleKind.Family.allCases) { family in
            Section(family.rawValue) {
              ForEach(family.members) { styleKind in
                Label(styleKind.title, systemImage: styleKind.systemImage)
                  .tag(styleKind.rawValue)
              }
            }
          }
        }
        .pickerStyle(.menu)

        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Label("Thickness", systemImage: "lineweight")
            Spacer()
            Text("\(Int(sliderThickness.rounded())) pt")
              .font(.system(size: 13, weight: .bold))
              .foregroundStyle(appearance.accent)
          }
          Slider(value: thicknessBinding, in: 1...24, step: 1)
        }

        VStack(alignment: .leading, spacing: 10) {
          Label("Color", systemImage: "paintpalette")
          HStack(spacing: 10) {
            ForEach(RemoteDrawColorPalette.swatches, id: \.hex) { swatch in
              swatchButton(swatch.hex, title: swatch.title)
            }
            Spacer(minLength: 0)
          }
        }
        .padding(.vertical, 2)

        Toggle(isOn: $isFillEnabled) {
          Label("Fill enclosed shapes", systemImage: "drop.halffull")
        }
      } header: {
        Text("Default Drawing Style")
      } footer: {
        Text(
          "Fill washes the inside of rectangles, ellipses, and closed freehand loops with the stroke color."
        )
      }
    }

    private var styleBinding: Binding<String> {
      Binding(
        get: {
          DrawingStyleKind(rawValue: styleKindRaw)?.rawValue
            ?? RemoteDrawPreferences.defaultStyleKind.rawValue
        },
        set: { styleKindRaw = $0 }
      )
    }

    /// The slider stops at 24 while the wire accepts 48. That is not an
    /// oversight: 24 is the widest mark that still reads as a mark on a phone,
    /// and the wider range exists so a board can hand a sender a heavier
    /// default than a person would ever choose.
    private var thicknessBinding: Binding<Double> {
      Binding(
        get: { sliderThickness },
        set: { thickness = min(24, max(1, $0)) }
      )
    }

    private var sliderThickness: Double {
      min(24, max(1, thickness.isFinite ? thickness : RemoteDrawPreferences.defaultThickness))
    }

    @ViewBuilder
    private func swatchButton(_ hex: String, title: String) -> some View {
      let isSelected = colorRaw.lowercased() == hex.lowercased()
      Button {
        colorRaw = hex
      } label: {
        Circle()
          .fill(RemoteDrawColorPalette.color(hex, fallback: appearance.ink))
          .frame(width: 26, height: 26)
          .overlay(Circle().strokeBorder(Color.black.opacity(0.14), lineWidth: 1))
          .padding(3)
          .overlay(
            Circle().strokeBorder(
              isSelected
                ? RemoteDrawColorPalette.color(hex, fallback: appearance.ink) : .clear,
              lineWidth: 2)
          )
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(title))
      .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
  }

  /// Which tool a drag makes.
  ///
  /// `tools` is what the *board* granted, not what the SDK offers: a host can
  /// narrow it to offer less than the session allows, and can never widen it.
  public struct RemoteDrawToolSection: View {
    @Binding var selection: RemoteDrawTool
    let tools: [RemoteDrawTool]

    public init(selection: Binding<RemoteDrawTool>, tools: [RemoteDrawTool]) {
      self._selection = selection
      self.tools = tools
    }

    public var body: some View {
      Section {
        Picker(selection: $selection) {
          ForEach(tools, id: \.self) { tool in
            Label(tool.title, systemImage: tool.systemImage).tag(tool)
          }
        } label: {
          Label("Tool", systemImage: "paintbrush.pointed")
        }
        .pickerStyle(.menu)
        .disabled(tools.isEmpty)
      } header: {
        Text("Draw with")
      }
    }
  }

  /// Which side the floating controls sit on.
  public struct RemoteDrawHandednessSection: View {
    @Binding var handednessRaw: String

    public init(handednessRaw: Binding<String>) {
      self._handednessRaw = handednessRaw
    }

    public var body: some View {
      Section {
        Picker("Controls side", selection: $handednessRaw) {
          ForEach(RemoteDrawHandedness.allCases) { handedness in
            Text(handedness.title).tag(handedness.rawValue)
          }
        }
        .pickerStyle(.segmented)
      } header: {
        Text("Handedness")
      } footer: {
        Text("Places the floating controls and thumb puck within reach of your thumb.")
      }
    }
  }

  /// Undo, clear, and the way out.
  ///
  /// **The exit is here and it is always here.** A takeover with no visible way
  /// back is an App Store 4.2 exposure, and "the host will provide one" is not
  /// a guarantee the SDK can make on the host's behalf — see
  /// ``RemoteDrawTakeover``.
  public struct RemoteDrawSessionSection: View {
    let canUndo: Bool
    let canClear: Bool
    let isBusy: Bool
    let onUndo: () -> Void
    let onClear: () -> Void
    let onLeave: (() -> Void)?

    @Environment(\.remoteDrawStrings) private var strings

    public init(
      canUndo: Bool,
      canClear: Bool,
      isBusy: Bool = false,
      onUndo: @escaping () -> Void,
      onClear: @escaping () -> Void,
      onLeave: (() -> Void)? = nil
    ) {
      self.canUndo = canUndo
      self.canClear = canClear
      self.isBusy = isBusy
      self.onUndo = onUndo
      self.onClear = onClear
      self.onLeave = onLeave
    }

    public var body: some View {
      if canUndo || canClear {
        Section {
          if canUndo {
            Button(action: onUndo) {
              Label(strings.undo, systemImage: "arrow.uturn.backward")
            }
            .disabled(isBusy)
          }
          if canClear {
            Button(role: .destructive, action: onClear) {
              Label("Clear board", systemImage: "eraser")
            }
            .disabled(isBusy)
          }
        }
      }
      if let onLeave {
        Section {
          Button(role: .destructive, action: onLeave) {
            Label(strings.leave, systemImage: "rectangle.portrait.and.arrow.right")
          }
        }
      }
    }
  }

  /// The assembled sheet, for a host that wants it whole.
  public struct RemoteDrawControlsSheet: View {
    @ObservedObject var session: RemoteDrawSenderSession
    @Binding var selectedTool: RemoteDrawTool
    @Binding var styleKindRaw: String
    @Binding var thickness: Double
    @Binding var colorRaw: String
    @Binding var isFillEnabled: Bool
    @Binding var handednessRaw: String
    let onLeave: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.remoteDrawStrings) private var strings

    public init(
      session: RemoteDrawSenderSession,
      selectedTool: Binding<RemoteDrawTool>,
      styleKindRaw: Binding<String>,
      thickness: Binding<Double>,
      colorRaw: Binding<String>,
      isFillEnabled: Binding<Bool>,
      handednessRaw: Binding<String>,
      onLeave: (() -> Void)? = nil
    ) {
      self.session = session
      self._selectedTool = selectedTool
      self._styleKindRaw = styleKindRaw
      self._thickness = thickness
      self._colorRaw = colorRaw
      self._isFillEnabled = isFillEnabled
      self._handednessRaw = handednessRaw
      self.onLeave = onLeave
    }

    public var body: some View {
      NavigationStack {
        Form {
          RemoteDrawToolSection(
            selection: $selectedTool, tools: session.capabilities.grantedTools)
          RemoteDrawInstrumentSection(
            styleKindRaw: $styleKindRaw,
            thickness: $thickness,
            colorRaw: $colorRaw,
            isFillEnabled: $isFillEnabled
          )
          RemoteDrawSessionSection(
            canUndo: session.capabilities.contains(.undo),
            canClear: session.capabilities.contains(.clear),
            onUndo: { Task { try? await session.undo() } },
            onClear: { Task { try? await session.clear() } },
            onLeave: onLeave.map { leave in
              {
                dismiss()
                leave()
              }
            }
          )
          RemoteDrawHandednessSection(handednessRaw: $handednessRaw)
        }
        .navigationTitle(strings.controls)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .confirmationAction) {
            Button("Done") { dismiss() }
          }
        }
      }
    }
  }

  extension Set where Element == RemoteDrawCapability {
    /// The tools this grant allows, in menu order.
    ///
    /// `draw` is the freehand family; `point` is its own capability because a
    /// board can want a tap and nothing else. A grant that allows neither leaves
    /// an empty picker rather than an unusable one that lies about what it can
    /// do.
    public var grantedTools: [RemoteDrawTool] {
      var tools: [RemoteDrawTool] = []
      if contains(.draw) {
        tools.append(contentsOf: [
          .auto, .freehand, .line, .arrow, .rectangle, .ellipse, .text,
        ])
      }
      if contains(.draw) || contains(.other("point")) {
        tools.append(.point)
      }
      return tools
    }
  }

  extension RemoteDrawTool {
    public var title: String {
      switch self {
      case .auto: return "Auto"
      case .freehand: return "Freehand"
      case .line: return "Line"
      case .arrow: return "Arrow"
      case .rectangle: return "Rectangle"
      case .ellipse: return "Ellipse"
      case .point: return "Point"
      case .text: return "Text"
      }
    }

    public var systemImage: String {
      switch self {
      case .auto: return "wand.and.stars"
      case .freehand: return "scribble"
      case .line: return "line.diagonal"
      case .arrow: return "arrow.up.right"
      case .rectangle: return "rectangle"
      case .ellipse: return "circle"
      case .point: return "smallcircle.filled.circle"
      case .text: return "textformat"
      }
    }
  }
#endif
