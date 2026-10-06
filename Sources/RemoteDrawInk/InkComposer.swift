import SwiftUI

/// Paints a *run* of strokes, batching the ones that share a per-pixel ceiling
/// into one accumulation buffer.
///
/// ``RemoteDrawStrokePainter`` draws one mark. This draws a passage, and the
/// difference is not cosmetic: the board's dab engine runs a shaded area up to
/// `capacity(h) = capacityFloor + capacityGain * h` and **stops**, while a
/// `Canvas` compositing every stroke source-over reaches `1 - (1 - a)ᴺ` and has
/// no fixed point at all. Shading with twenty passes of a pencil would go black
/// here and stay grey on the board.
///
/// So consecutive marks that belong to the same film are painted into one
/// isolated layer, clipped by the surface's tooth field at
/// `floor + gain * height`, and only then composited. That is the group ceiling,
/// and it is why the live stroke has to be drawn in the *same* run as the dry
/// ink it is shading over rather than on top of it.
///
/// Lifted verbatim from `DrawingBoardView.drawCapped` in the first-party app.
/// It lives in `RemoteDrawInk` rather than in the surface because it needs the
/// instrument film table and the rasterised tooth field, both of which are
/// internal here — publishing them to move forty lines would have been the
/// larger change to the public surface.
public enum RemoteDrawInkComposer {
  /// Draws `items` in order, grouping consecutive marks that share a ceiling.
  ///
  /// - Parameters:
  ///   - items: whatever the caller is painting, in paint order. Opaque to this
  ///     type — the caller says what film each one belongs to and how to paint
  ///     it, because on a map board a "stroke" is a record that still has to be
  ///     projected before it has any geometry at all.
  ///   - film: the ceiling `item` belongs to, or `nil` for a mark that needs no
  ///     wrapper. Use ``film(forType:pointCount:style:surface:)``.
  ///   - paint: paints one item into the context it is handed. **Must** use the
  ///     context passed in and not capture the outer one, or the mark escapes
  ///     the ceiling it was grouped under.
  public static func draw<Item>(
    _ items: [Item],
    in context: inout GraphicsContext,
    size: CGSize,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind,
    film: (Item) -> Film?,
    paint: (Item, inout GraphicsContext) -> Void
  ) {
    let extent = max(size.width, size.height)
    let sheet = CGRect(origin: .zero, size: CGSize(width: extent, height: extent))
    var index = 0
    while index < items.count {
      let current = film(items[index])
      var end = index + 1
      while end < items.count, film(items[end]) == current { end += 1 }
      let run = items[index..<end]
      // `floor + gain * h` as alpha: a flat floor, then the height field at the
      // opacity that leaves exactly `gain` of headroom. Every instrument holds
      // `floor + gain` below 1 in `DEPOSIT_BY_KIND`, so this never clips. Nil
      // when the film has no ceiling, and also when the sheet's field is not
      // built yet — an uncapped run is the mark this renderer drew before the
      // ceiling existed, where a dropped run would not be.
      var capped: (floor: Double, scale: Double, field: CGImage)?
      if let capacity = current?.inner.capacity, extent > 0,
        let field = RemoteDrawInk.capacityImage(for: surface, extent: extent, texture: capacity.texture)
      {
        let floor = min(1, max(0, capacity.floor))
        capped = (
          floor: floor,
          scale: floor >= 1 ? 0 : min(1, max(0, capacity.gain / (1 - floor))),
          field: field
        )
      }
      guard capped != nil || current?.inner.multiply == true else {
        for item in run { paint(item, &context) }
        index = end
        continue
      }
      var target = context
      if current?.inner.multiply == true { target.blendMode = .multiply }
      target.drawLayer { outer in
        if let capped {
          outer.clipToLayer { mask in
            if capped.floor > 0 {
              mask.fill(Path(sheet), with: .color(.black.opacity(capped.floor)))
            }
            mask.opacity = capped.scale
            mask.draw(Image(decorative: capped.field, scale: 1), in: sheet)
          }
        }
        outer.drawLayer { inner in
          for item in run { paint(item, &inner) }
        }
      }
      index = end
    }
  }

  /// The film a mark belongs to, or `nil` for anything that needs no wrapper.
  ///
  /// Text and the point tool are excluded even under a dry style: neither is
  /// masked by the tooth, so neither is approaching a capacity, and folding them
  /// into a group would only dim them.
  public static func film(
    forType type: String,
    pointCount: Int,
    style: RemoteDrawDrawingStyle?,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind
  ) -> Film? {
    guard type != "text", type != "point", pointCount > 1 else { return nil }
    guard let film = RemoteDrawInk.film(for: DrawingStyleKind(rawValue: style?.kind ?? ""), surface: surface)
    else { return nil }
    return Film(inner: film)
  }

  /// An opaque ceiling identity.
  ///
  /// Public so a caller can group by it; deliberately carrying no readable
  /// members, because everything inside is instrument tuning that changes with
  /// the ink pipeline and nobody outside can act on. Equality is the inner
  /// film's own, so a term added to `RemoteDrawInk.Film` is compared here by
  /// construction rather than by a comparison someone has to remember to extend.
  ///
  /// `@unchecked` only because the inner film is declared in the renderer,
  /// which stays free of module-boundary edits; it is two `Double`s and a
  /// `Bool`, nothing a thread could observe changing.
  public struct Film: Equatable, @unchecked Sendable {
    let inner: RemoteDrawInk.Film
  }

  /// Starts rasterising the tooth field an instrument will need, before a
  /// stroke asks for it. Cheap when the field already exists, and never blocks.
  public static func prepareTooth(
    for style: RemoteDrawDrawingStyle?,
    surface: RemoteDrawInkSurface.Kind,
    extent: CGFloat
  ) {
    guard
      RemoteDrawInk.profile(
        for: DrawingStyleKind(rawValue: style?.kind ?? ""), surface: surface
      ).tooth != nil
    else { return }
    RemoteDrawInk.prepareToothImage(for: surface, extent: extent)
  }
}
