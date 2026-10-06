// The porcelain recipe the tip library and the control bar share, and the
// renderer specimen the library and the controls sheet draw tips with.
//
// These used to live beside the radial puck. The Pencil Pro arc that replaced
// it is Liquid Glass (`PuckView.swift`); these stay for the persistent
// controls, which rest on the sheet rather than floating over the drawing.
#if canImport(UIKit) && !os(watchOS)
  import SwiftUI
  import UIKit

  /// The warm neutrals the persistent controls are made of.
  ///
  /// Named rather than inlined because the library sheet and the control bar
  /// have to be the same porcelain, and "one component family" is the acceptance
  /// gate they are judged against.
  public enum RemoteDrawPorcelain {
    /// Laid over `.regularMaterial` — enough to warm it, not enough to flatten
    /// the blur.
    public static let tint = Color(red: 0.992, green: 0.984, blue: 0.965)
    /// The Reduce Transparency substitute. Opaque, same hue.
    public static let opaque = Color(red: 0.973, green: 0.965, blue: 0.945)
    public static let graphite = Color(red: 0.09, green: 0.09, blue: 0.08)

    /// One restrained shadow, everywhere. Depth comes from the edges.
    public static let shadow = Color.black.opacity(0.08)
  }

  private struct RemoteDrawPorcelainSurface: ViewModifier {
    var cornerRadius: CGFloat
    var isRaised = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
      let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      return
        content
        .background {
          if reduceTransparency {
            shape.fill(RemoteDrawPorcelain.opaque)
          } else {
            shape.fill(.regularMaterial)
            shape.fill(RemoteDrawPorcelain.tint.opacity(0.55))
          }
        }
        .overlay {
          shape.strokeBorder(
            RemoteDrawPorcelain.graphite.opacity(contrast == .increased ? 0.34 : 0.14),
            lineWidth: contrast == .increased ? 1 : 0.5)
        }
        .shadow(
          color: isRaised ? RemoteDrawPorcelain.shadow : .clear,
          radius: isRaised ? 8 : 0,
          y: isRaised ? 3 : 0)
    }
  }

  extension View {
    /// The one porcelain recipe: warm material, a fine graphite keyline, one
    /// shadow — and an opaque fill when transparency is reduced.
    func remoteDrawPorcelain(cornerRadius: CGFloat, isRaised: Bool = true) -> some View {
      modifier(RemoteDrawPorcelainSurface(cornerRadius: cornerRadius, isRaised: isRaised))
    }
  }

  /// A real mark, made by the real renderer.
  ///
  /// The library's cells and the Tool sector's cards both use it, so a tip looks
  /// in the picker exactly like it draws — which is the only way a picker of
  /// sixteen instruments is a choice rather than a list of nouns.
  struct RemoteDrawPuckSpecimen: View {
    let kind: DrawingStyleKind
    let hex: String
    let width: Double
    let ink: Color
    var span: Span = .library

    /// The specimen space the mark is drawn in before it is fitted.
    enum Span {
      /// A long, gentle stroke for the library's generous cells.
      case library
      /// A short stroke for a 56pt dial card: at the library's span every tip
      /// shrinks to the same hairline there, and four instruments that look
      /// alike are not a choice.
      case compact

      var size: CGSize {
        switch self {
        case .library: return CGSize(width: 120, height: 40)
        case .compact: return CGSize(width: 64, height: 28)
        }
      }
    }

    var body: some View {
      Canvas { context, size in
        var canvas = context
        // Draw the same short material stroke in a consistent specimen space,
        // then fit it. A full 6pt brush inside a 31pt icon box turns every tip
        // into a solid wedge; scaling the entire rendered mark preserves its
        // pressure/material character and its relative remembered width.
        let specimenSize = span.size
        let factor = min(size.width / specimenSize.width, size.height / specimenSize.height)
        canvas.translateBy(
          x: (size.width - specimenSize.width * factor) / 2,
          y: (size.height - specimenSize.height * factor) / 2)
        canvas.scaleBy(x: factor, y: factor)
        RemoteDrawStrokePainter.draw(
          RemoteDrawStrokePainter.Stroke(
            points: Self.points,
            type: "freehand",
            style: RemoteDrawDrawingStyle(
              kind: kind.rawValue, color: hex, width: width)
          ),
          in: &canvas,
          size: specimenSize,
          defaults: RemoteDrawStrokePainter.Defaults(
            color: ink, lineWidth: CGFloat(width), highlighterColor: ink)
        )
      }
      .allowsHitTesting(false)
    }

    /// A shallow S with a pressure ramp: enough curvature for a broad-edge nib
    /// to turn, enough length for a dry medium to skip.
    static let points: [RemoteDrawNormalizedPoint] = (0...24).map { step in
      let t = Double(step) / 24
      return RemoteDrawNormalizedPoint(
        x: 0.08 + 0.84 * t,
        y: 0.5 + 0.18 * sin(t * .pi * 2),
        t: Double(step) * 12,
        pressure: 0.35 + 0.5 * sin(t * .pi)
      )
    }
  }
#endif
