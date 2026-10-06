//
//  The shape-snap offer's geometry: where the ghost is, where its trace goes,
//  where the chip sits.
//
//  Pure, and deliberately in a file with no `canImport(UIKit)` guard, so every
//  number is checkable by `swift test` on a machine with no simulator. The
//  views in `Chrome.swift` and `Surface.swift` read this and draw it; they
//  decide nothing. The chip placement mirrors
//  `packages/react/src/shapeSnapPlacement.ts` rule for rule.
//
import CoreGraphics
import SwiftUI

public enum RemoteDrawShapeSnapGeometry {
  /// What the chip calls each shape the board can offer.
  public static func shapeName(for type: String) -> String {
    switch type {
    case "line": return "Line"
    case "arrow": return "Arrow"
    case "rectangle": return "Rectangle"
    case "ellipse": return "Ellipse"
    case "point": return "Dot"
    default: return "Shape"
    }
  }

  /// The ghost's box in surface points, grown by half the ink width so the
  /// chip clears the mark and not just its centreline. Empty when nothing of
  /// the shape is on this screen.
  public static func anchorRect(
    type: String,
    points: [RemoteDrawNormalizedPoint],
    in size: CGSize,
    inkWidth: CGFloat
  ) -> CGRect {
    guard let bounds = normalizedBounds(points) else { return .null }
    var rect = CGRect(
      x: bounds.minX * size.width, y: bounds.minY * size.height,
      width: bounds.width * size.width, height: bounds.height * size.height)
    let pad = type == "point" ? max(inkWidth, 14) : inkWidth / 2
    rect = rect.insetBy(dx: -pad, dy: -pad)
    return rect
  }

  /// The dashed trace around the ghost, in surface points.
  public static func outlinePath(
    type: String,
    points: [RemoteDrawNormalizedPoint],
    in size: CGSize
  ) -> Path {
    var path = Path()
    guard let first = points.first, let last = points.last else { return path }
    func scaled(_ point: RemoteDrawNormalizedPoint) -> CGPoint {
      CGPoint(x: point.x * size.width, y: point.y * size.height)
    }
    switch type {
    case "rectangle", "ellipse":
      guard let bounds = normalizedBounds(points) else { return path }
      let rect = CGRect(
        x: bounds.minX * size.width, y: bounds.minY * size.height,
        width: max(1, bounds.width * size.width), height: max(1, bounds.height * size.height))
      if type == "rectangle" { path.addRect(rect) } else { path.addEllipse(in: rect) }
    case "line", "arrow":
      path.move(to: scaled(first))
      path.addLine(to: scaled(last))
    case "point":
      let center = scaled(first)
      path.addEllipse(in: CGRect(x: center.x - 14, y: center.y - 14, width: 28, height: 28))
    default:
      path.move(to: scaled(first))
      for point in points.dropFirst() { path.addLine(to: scaled(point)) }
    }
    return path
  }

  /// Where the chip's top-left corner goes, in surface points.
  ///
  /// Prefers just below the ghost, centred on it; then just above; then nudged
  /// to the side of the reserved corner; then wherever it fits. Never outside
  /// the pad, and never over `avoid` — the floating control cluster — if any
  /// other placement is possible.
  public static func chipOrigin(
    pad: CGSize,
    anchor: CGRect,
    chip: CGSize,
    avoid: CGRect?,
    gap: CGFloat = 12,
    margin: CGFloat = 10
  ) -> CGPoint {
    let maxX = max(margin, pad.width - chip.width - margin)
    let maxY = max(margin, pad.height - chip.height - margin)
    func clampX(_ x: CGFloat) -> CGFloat { min(maxX, max(margin, x)) }
    func clampY(_ y: CGFloat) -> CGFloat { min(maxY, max(margin, y)) }
    func intersects(_ origin: CGPoint) -> Bool {
      guard let avoid else { return false }
      return CGRect(origin: origin, size: chip).intersects(avoid)
    }

    let centred = clampX(anchor.midX - chip.width / 2)
    let below = anchor.maxY + gap
    let above = anchor.minY - gap - chip.height
    let candidates: [(y: CGFloat, fits: Bool)] = [
      (below, below <= maxY),
      (above, above >= margin),
    ]

    for candidate in candidates where candidate.fits {
      let origin = CGPoint(x: centred, y: candidate.y)
      if !intersects(origin) { return origin }
    }
    if let avoid {
      for candidate in candidates where candidate.fits {
        // Slide to whichever side of the reserve has room, nearest first.
        let leftOf = avoid.minX - gap - chip.width
        let rightOf = avoid.maxX + gap
        if avoid.midX >= pad.width / 2 {
          if leftOf >= margin { return CGPoint(x: leftOf, y: candidate.y) }
        } else if rightOf <= maxX {
          return CGPoint(x: rightOf, y: candidate.y)
        }
      }
    }

    var origin = CGPoint(x: centred, y: clampY(below))
    if let avoid, intersects(origin) {
      origin.y = clampY(avoid.minY - gap - chip.height)
    }
    return origin
  }

  private static func normalizedBounds(_ points: [RemoteDrawNormalizedPoint]) -> CGRect? {
    guard let first = points.first else { return nil }
    var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
    for point in points.dropFirst() {
      minX = min(minX, point.x); maxX = max(maxX, point.x)
      minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    guard minX.isFinite, minY.isFinite, maxX.isFinite, maxY.isFinite else { return nil }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
  }
}
