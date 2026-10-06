#if canImport(UIKit) && !os(watchOS)
import Foundation

/// The SDK surface's arc: the same wheel of sixteen instruments, widths,
/// colours and shapes as the first-party sender, filtered by what the session
/// granted. Ids follow the app's `DrawingPuckAction` scheme (`tip.<kind>`,
/// `size.<n>`, `color.<hex>`, `color.more`, `shape.<tool>`, `shape.more`).
enum RemoteDrawSurfacePuck {
  static let quickShapes: [RemoteDrawTool] = [.auto, .freehand, .line, .rectangle]

  static func menu(kind: DrawingStyleKind, color: String, thickness: Double,
    tool: RemoteDrawTool, tools: [RemoteDrawTool]) -> RemoteDrawPuckMenu {
    guard !tools.isEmpty else { return .empty }
    let canDraw = tools.contains { $0 != .point }

    let pens: [RemoteDrawPuckItem]
    if canDraw {
      pens = RemoteDrawPuckDefaults.pens.map {
        RemoteDrawPuckItem(id: "tip.\($0.rawValue)", title: $0.title, detail: $0.family.rawValue,
          content: .instrument($0), isCurrent: $0 == kind)
      }
    } else {
      // Pointing only: the wheel is the one tool the board allows.
      pens = [RemoteDrawPuckItem(id: "shape.point", title: RemoteDrawTool.point.title,
        content: .symbol(RemoteDrawTool.point.systemImage), isCurrent: true)]
    }

    let nearest = RemoteDrawPuckDefaults.nearestWidth(to: thickness)
    let widths = RemoteDrawPuckDefaults.widths.map {
      RemoteDrawPuckItem(id: "size.\(Int($0))", title: "\(Int($0)) pt",
        content: .width(points: $0, hex: color), isCurrent: $0 == nearest)
    }

    var colors = RemoteDrawPuckDefaults.colors.map { hex in
      RemoteDrawPuckItem(id: "color.\(hex)", title: colorTitle(hex), content: .swatch(hex: hex),
        isCurrent: hex.caseInsensitiveCompare(color) == .orderedSame)
    }
    colors.append(RemoteDrawPuckItem(id: "color.more", title: "All colors", content: .colorWell,
      isCurrent: !colors.contains { $0.isCurrent }, opensSheet: true))

    var shapes = quickShapes.filter { tools.contains($0) }.map {
      RemoteDrawPuckItem(id: "shape.\($0.rawValue)", title: $0.title,
        content: .symbol($0.systemImage), isCurrent: $0 == tool)
    }
    shapes.append(RemoteDrawPuckItem(id: "shape.more", title: "More", content: .symbol("ellipsis"),
      isCurrent: !shapes.contains { $0.isCurrent }, opensSheet: true))

    return RemoteDrawPuckMenu(
      pens: pens, widths: canDraw ? widths : [], colors: colors, shapes: shapes,
      inkHex: color, width: thickness, colorTitle: colorTitle(color), shapeTitle: tool.title)
  }

  static func colorTitle(_ hex: String) -> String {
    RemoteDrawColorPalette.swatches
      .first { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }?.title ?? "Custom"
  }
}

#endif
