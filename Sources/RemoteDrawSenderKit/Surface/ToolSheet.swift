// The controls sheet, in layers.
//
// Ordered by how often a hand reaches for each thing:
//
//   0. The bar.        Undo · Clear · More as navigation-bar items, with the
//                      sheet's own grabber above them. Actions, not settings,
//                      so they live where iOS puts actions.
//   1. The preview.    The next mark: the shape, drawn with the tool, at its
//                      width, in its colour — by the real renderer.
//   2. The tool.       One carousel of specimens. Chalk, pencil, brush pen: the
//                      thing you hold. Every tool has a fixed default width and
//                      colour and *returns* to it when re-selected. No memory,
//                      on purpose: remembered tweaks drift every tool toward
//                      the same fat black line.
//   3. Size · Colour · Fill. One row of three chips. Visible, so the options
//                      are findable; equal and quiet, so they read as one line
//                      of adjustments. Size and Colour open popovers.
//   4. The shape.      A segmented control — Smart, Line, Arrow, Rectangle,
//                      Ellipse, Text, Dot — plus a "+" for things that are
//                      placed rather than drawn.
//   5. Everything else behind More.
//
// Naming: the instrument is the **tool** (what you hold); what it makes is the
// **shape** (what appears). Documents and photos are not shapes, so they live
// under "+".
//
// Three sheets are assembled from these pieces — the SDK's own
// ``RemoteDrawControlsSheet``, the first-party board's, and the web sender's
// native chrome — which is why the pieces are public and the scaffold is
// generic over what the host puts in the More menu.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI

  // MARK: - Tool defaults

  extension DrawingStyleKind {
    /// The mark a tool makes before anyone touches Size or Colour.
    ///
    /// **The same table as the web's `toolStylePresets`**
    /// (`packages/client/src/toolPresets.ts`), so a person who picks Chalk on
    /// the phone and a person who picks it in the browser get the same chalk.
    /// The web applies this on every `setDrawingStyle`, and so does the sheet.
    public var defaultThickness: Double {
      switch self {
      case .ink: return 3
      case .whiteboardMarker: return 8
      case .brushPen: return 6
      case .fineliner: return 1.5
      case .ballpoint: return 1.8
      case .pencil: return 2
      case .chalk: return 9
      case .charcoal: return 10
      case .crayon: return 8
      case .dryBrush: return 10
      case .italicNib: return 5
      case .chiselMarker: return 10
      case .tiltPencil: return 8
      case .highlighter: return 16
      case .airbrush: return 24
      case .neon: return 6
      }
    }

    public var defaultColorHex: String {
      switch self {
      case .ink: return "#20252a"
      case .whiteboardMarker: return "#235b96"
      case .brushPen: return "#23282b"
      case .fineliner: return "#20252a"
      case .ballpoint: return "#254786"
      case .pencil: return "#55565a"
      case .chalk: return "#d8caa0"
      case .charcoal: return "#292929"
      case .crayon: return "#c67536"
      case .dryBrush: return "#8d4938"
      case .italicNib: return "#29262c"
      case .chiselMarker: return "#347475"
      case .tiltPencil: return "#606064"
      case .highlighter: return "#e5cd32"
      case .airbrush: return "#527ba0"
      case .neon: return "#e33baf"
      }
    }
  }

  extension DrawingStyleKind {
    /// The group the picker files this tool under.
    public var family: Family {
      Family.allCases.first { $0.members.contains(self) } ?? .pens
    }
  }

  extension RemoteDrawTool {
    /// Shapes that can hold a fill. Smart and freehand are included because a
    /// closed loop becomes one.
    public var canFill: Bool {
      switch self {
      case .auto, .freehand, .rectangle, .ellipse: return true
      case .line, .arrow, .point, .text: return false
      }
    }
  }

  /// The widths the Size chip offers. Eight stops, widening geometrically,
  /// because the difference between 1 and 2 pt is a different pen and the
  /// difference between 20 and 21 is nothing.
  public enum RemoteDrawSizeScale {
    public static let stops: [Double] = [1, 2, 4, 6, 8, 12, 16, 24]

    /// The dot a stop is drawn as. True diameter would make 1 pt invisible
    /// and 24 pt fill the chip, so the scale is compressed — still monotonic,
    /// still a ruler.
    static func dotDiameter(_ width: Double) -> CGFloat {
      min(20, 3 + CGFloat(width) * 0.72)
    }

    static func label(_ width: Double) -> String {
      let rounded = (width * 10).rounded() / 10
      if rounded == rounded.rounded() { return "\(Int(rounded)) pt" }
      return String(format: "%.1f pt", rounded)
    }
  }

  // MARK: - Mark preview

  /// The next mark: the shape, made with the tool, by the real renderer.
  ///
  /// Not a picture of a line restyled — `RemoteDrawStrokePainter` draws it, so
  /// a chalk is grainy, a fineliner is a hairline and a rectangle drawn with a
  /// brush pen has a brush pen's corners. Switching the shape visibly changes
  /// what the sheet promises.
  public struct RemoteDrawMarkPreview: View {
    let kind: DrawingStyleKind
    let colorHex: String
    let width: Double
    let tool: RemoteDrawTool
    let isFillEnabled: Bool

    @Environment(\.remoteDrawAppearance) private var appearance

    public init(
      kind: DrawingStyleKind,
      colorHex: String,
      width: Double,
      tool: RemoteDrawTool = .freehand,
      isFillEnabled: Bool = false
    ) {
      self.kind = kind
      self.colorHex = colorHex
      self.width = width
      self.tool = tool
      self.isFillEnabled = isFillEnabled
    }

    public var body: some View {
      Canvas { context, size in
        var canvas = context
        RemoteDrawStrokePainter.draw(
          stroke,
          in: &canvas,
          size: size,
          defaults: RemoteDrawStrokePainter.Defaults(
            color: appearance.ink, lineWidth: CGFloat(width),
            highlighterColor: appearance.highlighter)
        )
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
    }

    private var stroke: RemoteDrawStrokePainter.Stroke {
      let style = RemoteDrawDrawingStyle(
        kind: kind.rawValue, color: colorHex, width: width,
        fill: isFillEnabled && tool.canFill ? RemoteDrawDrawingFill() : nil)
      func point(_ x: Double, _ y: Double, t: Double = 0) -> RemoteDrawNormalizedPoint {
        RemoteDrawNormalizedPoint(x: x, y: y, t: t, pressure: 0.6)
      }
      switch tool {
      case .text:
        return .init(points: [point(0.36, 0.5)], type: "text", text: "Aa", style: style)
      case .point:
        return .init(points: [point(0.5, 0.5)], type: "point", style: style)
      case .line, .arrow:
        return .init(
          points: [point(0.08, 0.7), point(0.92, 0.3, t: 400)], type: tool.rawValue, style: style)
      case .rectangle, .ellipse:
        return .init(
          points: [point(0.31, 0.16), point(0.69, 0.84, t: 400)], type: tool.rawValue, style: style)
      case .auto, .freehand:
        return .init(points: RemoteDrawPuckSpecimen.points, type: "freehand", style: style)
      }
    }
  }

  // MARK: - Tool carousel

  /// Sixteen tools as a snapping row of specimens, each drawn in its own
  /// default colour at its own default width — a tray of pens, not a row of
  /// symbols. Selection is whatever sits in the centre.
  ///
  /// Everything mechanical is the platform's: `.viewAligned` snapping over a
  /// `.scrollTargetLayout()`, `.scrollPosition(id:)` for selection,
  /// `.sensoryFeedback` for the ticks. Hand-rolled reels were the tell in the
  /// designs this replaced.
  public struct RemoteDrawToolCarousel: View {
    @Binding var selection: DrawingStyleKind
    let kinds: [DrawingStyleKind]

    @Environment(\.remoteDrawAppearance) private var appearance
    @State private var rowWidth: CGFloat = 390
    @State private var centred: String?

    /// Four and a bit: the half-cells at both edges are what tell a thumb the
    /// row scrolls.
    private let visibleCells: CGFloat = 4.6
    private let cellHeight: CGFloat = 68

    public init(selection: Binding<DrawingStyleKind>, kinds: [DrawingStyleKind] = DrawingStyleKind.allCases) {
      self._selection = selection
      self.kinds = kinds
    }

    private var cellWidth: CGFloat { rowWidth / visibleCells }

    public var body: some View {
      VStack(spacing: 6) {
        RemoteDrawSheetSectionHeader(title: "Tool", detail: selection.family.rawValue)

        ZStack {
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color(.tertiarySystemFill))
            .frame(width: cellWidth - 6, height: cellHeight)

          ScrollView(.horizontal) {
            // Not lazy: sixteen cells are cheap, and an initial scroll
            // position aimed at a cell a lazy stack has not laid out yet
            // lands one off.
            HStack(spacing: 0) {
              ForEach(kinds) { kind in
                cell(kind)
              }
            }
            .scrollTargetLayout()
          }
          .scrollIndicators(.hidden)
          .scrollTargetBehavior(.viewAligned)
          .scrollPosition(id: $centred, anchor: .center)
          .contentMargins(.horizontal, max(0, (rowWidth - cellWidth) / 2), for: .scrollContent)
          .mask(edgeFade)
          .frame(height: cellHeight)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
      }
      .onAppear { centred = selection.rawValue }
      .onChange(of: selection) { _, kind in
        if centred != kind.rawValue {
          withAnimation(.snappy) { centred = kind.rawValue }
        }
      }
      .onChange(of: centred) { _, id in
        if let id, let kind = DrawingStyleKind(rawValue: id), kind != selection {
          selection = kind
        }
      }
      .sensoryFeedback(.selection, trigger: centred)
      .sensoryFeedback(.impact(weight: .heavy, intensity: 0.7), trigger: selection.family)
      .accessibilityElement(children: .contain)
      .accessibilityLabel("Tool")
      .accessibilityValue(Text(selection.title))
    }

    private func cell(_ kind: DrawingStyleKind) -> some View {
      let isSelected = selection == kind
      return Button {
        selection = kind
      } label: {
        VStack(spacing: 5) {
          RemoteDrawPuckSpecimen(
            kind: kind, hex: kind.defaultColorHex, width: kind.defaultThickness,
            ink: appearance.ink
          )
          .frame(width: cellWidth - 18, height: 30)

          Text(kind.shortTitle)
            .font(.caption2.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? appearance.accent : Color.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(width: cellWidth - 8)
        }
        .frame(width: cellWidth, height: cellHeight)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(Text(kind.title))
      .accessibilityAddTraits(isSelected ? [.isSelected] : [])
      .accessibilityIdentifier("remotedraw.controls.tool.\(kind.rawValue)")
      // Falloff by distance from the centre, continuously, so the row reads
      // as a carousel with a middle rather than four equal tiles.
      .visualEffect { content, proxy in
        let container = proxy.bounds(of: .scrollView(axis: .horizontal))?.width ?? 390
        let frame = proxy.frame(in: .scrollView(axis: .horizontal))
        let distance = min(1, abs(frame.midX - container / 2) / max(1, container / 2))
        return
          content
          .opacity(1 - 0.55 * distance * distance)
          .scaleEffect(1 - 0.1 * distance)
      }
    }

    /// The row dissolves at both ends: the half-cells that peek there are what
    /// say "this scrolls", and dissolving them is what keeps a cut label from
    /// reading as a bug.
    private var edgeFade: some View {
      LinearGradient(
        stops: [
          .init(color: .clear, location: 0),
          .init(color: .black, location: 0.07),
          .init(color: .black, location: 0.93),
          .init(color: .clear, location: 1),
        ],
        startPoint: .leading, endPoint: .trailing)
    }
  }

  // MARK: - Size · Colour · Fill

  /// Three equal chips. Size and Colour open popovers anchored to the chip;
  /// Fill is a toggle that greys out when the shape cannot hold one.
  public struct RemoteDrawAdjustRow: View {
    @Binding var thickness: Double
    @Binding var colorRaw: String
    @Binding var isFillEnabled: Bool
    let canFill: Bool

    @Environment(\.remoteDrawAppearance) private var appearance
    @State private var showsSize = false
    @State private var showsColour = false

    public init(
      thickness: Binding<Double>,
      colorRaw: Binding<String>,
      isFillEnabled: Binding<Bool>,
      canFill: Bool = true
    ) {
      self._thickness = thickness
      self._colorRaw = colorRaw
      self._isFillEnabled = isFillEnabled
      self.canFill = canFill
    }

    public var body: some View {
      HStack(spacing: 8) {
        Button {
          showsSize.toggle()
        } label: {
          HStack(spacing: 7) {
            Circle()
              .fill(Color(uiColor: .label))
              .frame(
                width: RemoteDrawSizeScale.dotDiameter(thickness),
                height: RemoteDrawSizeScale.dotDiameter(thickness))
              .frame(width: 20, height: 20)
            Text(RemoteDrawSizeScale.label(thickness)).monospacedDigit()
          }
          .frame(maxWidth: .infinity)
        }
        .modifier(RemoteDrawChipStyle())
        .accessibilityLabel("Size, \(RemoteDrawSizeScale.label(thickness))")
        .accessibilityIdentifier("remotedraw.controls.size")
        .popover(isPresented: $showsSize, arrowEdge: .bottom) {
          sizePopover.presentationCompactAdaptation(.popover)
        }

        Button {
          showsColour.toggle()
        } label: {
          HStack(spacing: 7) {
            Circle()
              .fill(RemoteDrawColorPalette.color(colorRaw, fallback: appearance.ink))
              .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
              .frame(width: 18, height: 18)
              .frame(width: 20, height: 20)
            Text(colourName)
          }
          .frame(maxWidth: .infinity)
        }
        .modifier(RemoteDrawChipStyle())
        .accessibilityLabel("Colour, \(colourName)")
        .accessibilityIdentifier("remotedraw.controls.colour")
        .popover(isPresented: $showsColour, arrowEdge: .bottom) {
          colourPopover.presentationCompactAdaptation(.popover)
        }

        Toggle(isOn: $isFillEnabled) {
          Label("Fill", systemImage: isFillEnabled ? "drop.fill" : "drop")
            .frame(maxWidth: .infinity)
        }
        .toggleStyle(.button)
        .modifier(RemoteDrawChipStyle(prominent: isFillEnabled))
        .disabled(!canFill)
        .accessibilityIdentifier("remotedraw.controls.fill")
      }
      .font(.subheadline)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
      .sensoryFeedback(.selection, trigger: thickness)
      .sensoryFeedback(.selection, trigger: colorRaw)
      .sensoryFeedback(.selection, trigger: isFillEnabled)
    }

    private var sizePopover: some View {
      HStack(spacing: 2) {
        ForEach(RemoteDrawSizeScale.stops, id: \.self) { stop in
          let isSelected = abs(thickness - stop) < 0.01
          Button {
            thickness = stop
          } label: {
            Circle()
              .fill(isSelected ? appearance.accent : Color(uiColor: .label))
              .frame(
                width: RemoteDrawSizeScale.dotDiameter(stop),
                height: RemoteDrawSizeScale.dotDiameter(stop))
              .frame(width: 36, height: 36)
              .background(Circle().fill(isSelected ? appearance.accent.opacity(0.14) : .clear))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(RemoteDrawSizeScale.label(stop))
          .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
      }
      .padding(10)
    }

    private var colourPopover: some View {
      HStack(spacing: 2) {
        ForEach(RemoteDrawColorPalette.swatches, id: \.hex) { swatch in
          let isSelected = colorRaw.caseInsensitiveCompare(swatch.hex) == .orderedSame
          Button {
            colorRaw = swatch.hex
          } label: {
            Circle()
              .fill(RemoteDrawColorPalette.color(swatch.hex, fallback: appearance.ink))
              .frame(width: 26, height: 26)
              .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
              .frame(width: 36, height: 36)
              .background(
                Circle().strokeBorder(appearance.accent, lineWidth: isSelected ? 2 : 0))
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text(swatch.title))
          .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        // The system colour well, for anything the palette does not have.
        ColorPicker("Custom colour", selection: customColour, supportsOpacity: false)
          .labelsHidden()
          .frame(width: 36, height: 36)
      }
      .padding(10)
    }

    private var customColour: Binding<Color> {
      Binding(
        get: { RemoteDrawColorPalette.color(colorRaw, fallback: appearance.ink) },
        set: { colour in
          if let hex = RemoteDrawColorPalette.hex(of: colour) { colorRaw = hex }
        })
    }

    private var colourName: String {
      RemoteDrawColorPalette.swatches.first {
        $0.hex.caseInsensitiveCompare(colorRaw) == .orderedSame
      }?.title ?? "Colour"
    }
  }

  extension RemoteDrawColorPalette {
    /// sRGB hex of a `Color`, for the colour well's way back into the model.
    static func hex(of colour: Color) -> String? {
      guard
        let space = CGColorSpace(name: CGColorSpace.sRGB),
        let components = UIColor(colour).cgColor.converted(
          to: space, intent: .defaultIntent, options: nil)?.components,
        components.count >= 3
      else { return nil }
      let r = Int((components[0] * 255).rounded())
      let g = Int((components[1] * 255).rounded())
      let b = Int((components[2] * 255).rounded())
      return String(format: "#%02x%02x%02x", r, g, b)
    }
  }

  // MARK: - Shape picker

  /// The shapes as one segmented control, with an optional "+" beside it for
  /// what is placed rather than drawn. Freehand is what Smart does when nothing
  /// is recognised, so it is not a separate segment when Smart is offered.
  public struct RemoteDrawShapePicker<Insert: View>: View {
    @Binding var selection: RemoteDrawTool
    let tools: [RemoteDrawTool]
    let insert: Insert

    public init(
      selection: Binding<RemoteDrawTool>,
      tools: [RemoteDrawTool],
      @ViewBuilder insert: () -> Insert
    ) {
      self._selection = selection
      self.tools = tools
      self.insert = insert()
    }

    private var segments: [RemoteDrawTool] {
      tools.contains(.auto) ? tools.filter { $0 != .freehand } : tools
    }

    /// Freehand shows as Smart when Smart stands in for it.
    private var pickerSelection: Binding<RemoteDrawTool> {
      Binding(
        get: { selection == .freehand && !segments.contains(.freehand) ? .auto : selection },
        set: { selection = $0 })
    }

    public var body: some View {
      VStack(spacing: 8) {
        RemoteDrawSheetSectionHeader(title: "Shape", detail: selection.title)

        HStack(spacing: 8) {
          Picker("Shape", selection: pickerSelection) {
            ForEach(segments, id: \.self) { tool in
              Image(systemName: tool.systemImage)
                .accessibilityLabel(Text(tool.title))
                .tag(tool)
            }
          }
          .pickerStyle(.segmented)
          .disabled(segments.isEmpty)
          .accessibilityIdentifier("remotedraw.controls.shape")

          insert
        }
      }
      .sensoryFeedback(.selection, trigger: selection)
    }
  }

  /// The "+" beside the shape control.
  public struct RemoteDrawInsertButton<Items: View>: View {
    let items: Items

    public init(@ViewBuilder items: () -> Items) {
      self.items = items()
    }

    public var body: some View {
      Menu {
        items
      } label: {
        Image(systemName: "plus")
          .font(.body.weight(.medium))
          .frame(width: 22, height: 18)
      }
      .modifier(RemoteDrawChipStyle())
      .controlSize(.small)
      .accessibilityLabel("Insert")
      .accessibilityIdentifier("remotedraw.controls.insert")
    }
  }

  // MARK: - Scaffold

  /// The whole sheet, assembled: bar, preview, tool, adjustments, shape.
  ///
  /// Generic over what the host puts in the More menu and on the Settings
  /// page, because that is the only part of the sheet that differs between
  /// the SDK, the first-party board and the web sender's chrome.
  public struct RemoteDrawToolSheet<More: View, Insert: View, Settings: View, Footer: View>: View {
    @Binding var kind: DrawingStyleKind
    @Binding var thickness: Double
    @Binding var colorRaw: String
    @Binding var isFillEnabled: Bool
    @Binding var selectedTool: RemoteDrawTool
    @Binding var showsSettings: Bool
    let tools: [RemoteDrawTool]
    let canUndo: Bool
    let canClear: Bool
    let isBusy: Bool
    let onUndo: () -> Void
    let onClear: () -> Void
    let onLeave: (() -> Void)?
    /// What selecting a tool does. `nil` applies the tool's defaults; a host
    /// with its own stroke state passes something that does that *and* drops
    /// the stroke in flight.
    let onSelectKind: ((DrawingStyleKind) -> Void)?
    let more: More
    let insert: Insert
    let settings: Settings
    let footer: Footer

    @Environment(\.remoteDrawStrings) private var strings
    @State private var confirmsClear = false
    @State private var detent: PresentationDetent = .height(430)
    @State private var measuredHeight: CGFloat = 430

    public init(
      kind: Binding<DrawingStyleKind>,
      thickness: Binding<Double>,
      colorRaw: Binding<String>,
      isFillEnabled: Binding<Bool>,
      selectedTool: Binding<RemoteDrawTool>,
      tools: [RemoteDrawTool],
      showsSettings: Binding<Bool>,
      canUndo: Bool,
      canClear: Bool,
      isBusy: Bool = false,
      onUndo: @escaping () -> Void,
      onClear: @escaping () -> Void,
      onLeave: (() -> Void)? = nil,
      onSelectKind: ((DrawingStyleKind) -> Void)? = nil,
      @ViewBuilder more: () -> More,
      @ViewBuilder insert: () -> Insert,
      @ViewBuilder settings: () -> Settings,
      @ViewBuilder footer: () -> Footer
    ) {
      self._kind = kind
      self._thickness = thickness
      self._colorRaw = colorRaw
      self._isFillEnabled = isFillEnabled
      self._selectedTool = selectedTool
      self._showsSettings = showsSettings
      self.tools = tools
      self.canUndo = canUndo
      self.canClear = canClear
      self.isBusy = isBusy
      self.onUndo = onUndo
      self.onClear = onClear
      self.onLeave = onLeave
      self.onSelectKind = onSelectKind
      self.more = more()
      self.insert = insert()
      self.settings = settings()
      self.footer = footer()
    }

    public var body: some View {
      NavigationStack {
        VStack(spacing: 0) {
          RemoteDrawMarkPreview(
            kind: kind, colorHex: colorRaw, width: thickness,
            tool: selectedTool, isFillEnabled: isFillEnabled
          )
          .frame(height: 76)
          .frame(maxWidth: .infinity)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color(red: 1.0, green: 0.99, blue: 0.96)))
          .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .strokeBorder(Color(.separator).opacity(0.7), lineWidth: 0.5))
          .padding(.horizontal, 16)
          .padding(.top, 4)
          .padding(.bottom, 18)
          .accessibilityIdentifier("remotedraw.controls.preview")

          RemoteDrawToolCarousel(selection: $kind)
            .padding(.bottom, 14)

          RemoteDrawAdjustRow(
            thickness: $thickness, colorRaw: $colorRaw, isFillEnabled: $isFillEnabled,
            canFill: selectedTool.canFill
          )
          .padding(.horizontal, 16)
          .padding(.bottom, 22)

          RemoteDrawShapePicker(selection: $selectedTool, tools: tools) { insert }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)

          footer
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
          proxy.size.height + proxy.safeAreaInsets.top
        } action: { height in
          measuredHeight = height
          if detent != .large { detent = .height(height) }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxHeight: .infinity, alignment: .top)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { bar }
        .navigationDestination(isPresented: $showsSettings) { settings }
        .confirmationDialog(
          "Clear this board?", isPresented: $confirmsClear, titleVisibility: .visible
        ) {
          Button("Clear board", role: .destructive, action: onClear)
          Button("Keep drawing", role: .cancel) {}
        } message: {
          Text("Everything on the board goes, for everyone looking at it.")
        }
      }
      .presentationDetents([.height(measuredHeight), .large], selection: $detent)
      .presentationDragIndicator(.visible)
      .presentationBackgroundInteraction(.enabled(upThrough: .height(measuredHeight)))
      .onChange(of: kind) { _, kind in
        if let onSelectKind {
          onSelectKind(kind)
        } else {
          thickness = kind.defaultThickness
          colorRaw = kind.defaultColorHex
        }
      }
      .onChange(of: showsSettings) { _, open in
        withAnimation { detent = open ? .large : .height(measuredHeight) }
      }
      .accessibilityIdentifier("remotedraw.controls")
    }

    @ToolbarContentBuilder
    private var bar: some ToolbarContent {
      ToolbarItem(placement: .topBarLeading) {
        if canUndo {
          Button(strings.undo, systemImage: "arrow.uturn.backward", action: onUndo)
            .disabled(isBusy)
            .accessibilityIdentifier("remotedraw.controls.undo")
        }
      }
      ToolbarItemGroup(placement: .topBarTrailing) {
        if canClear {
          // Clear always asks. Nothing on this board wipes work in one gesture.
          Button(strings.clear, systemImage: "trash") { confirmsClear = true }
            .disabled(isBusy)
            .accessibilityIdentifier("remotedraw.controls.clear")
        }
        Menu {
          more
          if let onLeave {
            Divider()
            Button(role: .destructive, action: onLeave) {
              Label(strings.leave, systemImage: "rectangle.portrait.and.arrow.right")
            }
            .accessibilityIdentifier("remotedraw.controls.leave")
          }
        } label: {
          Label("More", systemImage: "ellipsis.circle")
        }
        .accessibilityIdentifier("remotedraw.controls.more")
      }
    }
  }

  // MARK: - Shared parts

  struct RemoteDrawSheetSectionHeader: View {
    let title: String
    let detail: String

    var body: some View {
      HStack {
        Text(title).font(.footnote.weight(.semibold))
        Spacer()
        Text(detail).font(.footnote)
      }
      .foregroundStyle(.secondary)
      .padding(.horizontal, 16)
    }
  }

  /// The bar's material, on the chips: Liquid Glass where it exists, a bordered
  /// capsule before that.
  struct RemoteDrawChipStyle: ViewModifier {
    var prominent = false

    @Environment(\.remoteDrawAppearance) private var appearance

    func body(content: Content) -> some View {
      if #available(iOS 26, *) {
        if prominent {
          content.buttonStyle(.glassProminent).buttonBorderShape(.capsule)
        } else {
          content.buttonStyle(.glass).buttonBorderShape(.capsule)
        }
      } else {
        content
          .buttonStyle(.bordered)
          .buttonBorderShape(.capsule)
          .tint(prominent ? appearance.accent : Color.primary)
      }
    }
  }
#endif
