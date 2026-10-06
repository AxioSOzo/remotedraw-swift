//
//  The Pencil Pro arc's geometry: every number in the spec's table, the
//  wheel, the centre clamp, mirroring and the second tier's placement.
//
//  Spec: docs/design/2026-09-24-pencil-pro-arc-puck.md. The web sender shares
//  these numbers, so a change here is a change to both.
//
import XCTest

@testable import RemoteDrawSenderKit

final class PuckGeometryTests: XCTestCase {
  private let phone = CGSize(width: 402, height: 874)
  private let insets = RemoteDrawPuckSolver.Insets(top: 62, bottom: 34)
  private let m = RemoteDrawPuckMetrics.standard

  private func layout(_ thumb: CGPoint, size: CGSize? = nil) -> RemoteDrawPuckLayout {
    guard let solved = RemoteDrawPuckSolver.solve(thumb: thumb, in: size ?? phone, insets: insets)
    else {
      XCTFail("a phone must always solve")
      fatalError()
    }
    return solved
  }

  // MARK: - The table

  func testMetricsAreTheSpecsTable() {
    XCTAssertEqual(m.radius, 330)
    XCTAssertEqual(m.step, 0.142)
    XCTAssertEqual(m.apexAboveThumb, 110)
    XCTAssertEqual(m.penWindow, 2.5)
    XCTAssertEqual(m.penFadeEdge, 2.6)
    XCTAssertEqual(m.penFadeWidth, 0.5)
    XCTAssertEqual([m.dividerOffset, m.wellOffset, m.shapesOffset], [2.85, 3.5, -3.5])
    XCTAssertEqual([m.bandStart, m.bandEnd, m.capless], [-3.95, 3.95, 2.95])
    XCTAssertEqual(m.bandInnerRadius, 330 - 58)
    XCTAssertEqual(m.bandOuterRadius, 330 + 50)
    XCTAssertEqual(m.bandCorner, 30)
    XCTAssertEqual(m.edgeMargin, 22)
    XCTAssertEqual(m.penRadiusInset, 24)
    XCTAssertEqual([m.liftHovered, m.liftNeighbour, m.liftCurrent], [18, 5, 10])
    XCTAssertEqual(m.familyBreath, 0.5)
    XCTAssertEqual(m.wheelTail, 1.5)
    XCTAssertEqual(m.tierRadius, 330 + 88)
    XCTAssertEqual(m.tierStep, 0.135)
    XCTAssertEqual(m.tierHalfBand, 30)
    XCTAssertEqual(m.tierNudge, 0.02)
    XCTAssertEqual(m.tierEdgeMargin, 28)
    XCTAssertEqual([m.tooltipPenOutset, m.tooltipSlotOutset, m.tooltipTierOutset], [94, 70, 50])
    XCTAssertEqual(m.tooltipEdgeInset, 110)
    XCTAssertEqual([m.tierOpenInset, m.tierCloseInset], [72, 92])
    XCTAssertEqual([m.edgeZoneStart, m.edgeZoneEnd], [1.95, 2.75])
    XCTAssertEqual(m.edgeDwell, 0.22)
    XCTAssertEqual(m.edgeSpeed, 3.4)
    XCTAssertEqual([m.edgeRamp, m.edgeFloor], [0.4, 0.4])
    XCTAssertEqual([m.hoverReach, m.hoverHysteresis], [0.75, 0.15])
    XCTAssertEqual([m.trackSpan, m.summonSpin], [2.4, 0.9])
    XCTAssertEqual([m.ledgeInset, m.trackInset], [44, 51])
    XCTAssertEqual(m.commitTravel, 24)
    XCTAssertEqual(m.cancelInset, 200)
    XCTAssertEqual(m.roomAbove, 270)
    XCTAssertEqual(m.topClearance, 8)
    XCTAssertEqual(m.chipAbove, 64)
  }

  // MARK: - Slots and the centre

  func testSlotAngleIsMinusHalfPiPlusOffsetTimesStep() {
    let solved = layout(CGPoint(x: 160, y: 680))
    for off in [-3.95, -3.5, -2.85, -1, 0, 0.5, 2.85, 3.5, 3.95] {
      XCTAssertEqual(solved.angle(ofOffset: off), -.pi / 2 + off * 0.142, accuracy: 1e-12)
      XCTAssertEqual(solved.offset(ofAngle: solved.angle(ofOffset: off)), off, accuracy: 1e-9)
    }
  }

  func testTheApexSits110PointsAboveTheThumb() {
    let thumb = CGPoint(x: 201, y: 680)
    let solved = layout(thumb)
    XCTAssertEqual(solved.orientation, .above)
    XCTAssertEqual(solved.thumb, thumb, "the anchor never moves")
    XCTAssertEqual(solved.center.x, thumb.x, "room on both sides: the centre follows the thumb")
    XCTAssertEqual(solved.center.y, thumb.y + 330 - 110)
    let apex = solved.point(radius: 330, offset: 0)
    XCTAssertEqual(apex.x, thumb.x, accuracy: 1e-9)
    XCTAssertEqual(apex.y, thumb.y - 110, accuracy: 1e-9)
    XCTAssertEqual(solved.offset(of: thumb), 0, accuracy: 1e-9)
  }

  func testTheCentreIsClampedSoTheBandClearsBothEdges() {
    for x in [CGFloat(4), 40, 120, 300, 398] {
      let thumb = CGPoint(x: x, y: 680)
      let solved = layout(thumb)
      XCTAssertEqual(solved.thumb, thumb, "the thumb is never moved, only the centre")
      let left = solved.point(radius: m.radius, offset: m.bandStart).x
      let right = solved.point(radius: m.radius, offset: m.bandEnd).x
      XCTAssertGreaterThanOrEqual(left, 22 - 1e-9, "left end at \(x)")
      XCTAssertLessThanOrEqual(right, phone.width - 22 + 1e-9, "right end at \(x)")
    }
    // Measured from the clamped centre, not the thumb.
    let pushed = layout(CGPoint(x: 20, y: 680))
    XCTAssertGreaterThan(pushed.center.x, 20)
    XCTAssertEqual(pushed.point(radius: m.radius, offset: m.bandStart).x, 22, accuracy: 1e-9)
    let pulled = layout(CGPoint(x: 390, y: 680))
    XCTAssertEqual(pulled.point(radius: m.radius, offset: m.bandEnd).x, phone.width - 22, accuracy: 1e-9)
  }

  func testTooNarrowForBothLimitsTheRightHandSlotsWin() {
    let narrow = CGSize(width: 360, height: 780)
    let solved = layout(CGPoint(x: 180, y: 600), size: narrow)
    XCTAssertEqual(
      solved.point(radius: m.radius, offset: m.bandEnd).x, narrow.width - 22, accuracy: 1e-9,
      "the colour well may not be cut off")
  }

  // MARK: - Room and the mirror

  func testThereIsRoomAboveUnlessTheThumbIsNearTheTop() {
    XCTAssertEqual(layout(CGPoint(x: 160, y: 62 + 270)).orientation, .above)
    XCTAssertEqual(layout(CGPoint(x: 160, y: 62 + 269)).orientation, .below)
    XCTAssertEqual(layout(CGPoint(x: 160, y: 120)).orientation, .below)
  }

  func testTheMirrorOpensBelowWithTheSameLeftToRightOrder() {
    let thumb = CGPoint(x: 160, y: 150)
    let solved = layout(thumb)
    XCTAssertEqual(solved.orientation, .below)
    XCTAssertEqual(solved.center.y, thumb.y - (330 - 110), "centre above the thumb")
    let apex = solved.point(radius: 330, offset: 0)
    XCTAssertEqual(apex.y, thumb.y + 110, accuracy: 1e-9, "tray below the thumb")
    XCTAssertEqual(solved.angle(ofOffset: 0), .pi / 2, accuracy: 1e-12)
    // Shapes on the left, pens between, the well on the right, either way up.
    XCTAssertLessThan(
      solved.point(radius: 330, offset: m.shapesOffset).x, solved.point(radius: 330, offset: -2).x)
    XCTAssertLessThan(
      solved.point(radius: 330, offset: 2).x, solved.point(radius: 330, offset: m.wellOffset).x)
    for off in [-3.5, -2.0, 0, 1.3, 3.5] {
      XCTAssertEqual(solved.offset(ofAngle: solved.angle(ofOffset: off)), off, accuracy: 1e-9)
    }
    // Everything the tray draws is below the thumb.
    XCTAssertGreaterThan(solved.point(radius: m.bandInnerRadius, offset: m.bandStart).y, thumb.y)
  }

  /// The mirror reflects places, not things: a pen hanging tip down reads as
  /// a broken tray (owner, on device, 2026-09-28).
  func testEveryPenStandsTipUpEitherWayUp() {
    for thumb in [CGPoint(x: 200, y: 600), CGPoint(x: 200, y: 150)] {
      let solved = layout(thumb)
      for off in stride(from: -2.5, through: 2.5, by: 0.5) {
        let angle = solved.angle(ofOffset: off)
        let rotation = solved.penRotation(at: angle)
        // The instrument is drawn tip at the top: (0, −1) rotated.
        let tip = CGVector(dx: sin(rotation), dy: -cos(rotation))
        XCTAssertLessThan(tip.dy, -0.9, "\(solved.orientation) pen at \(off) points up")
        // Normal to the band, leaning toward the thumb's side of the arc.
        let up = solved.up(at: angle)
        XCTAssertEqual(tip.dx, up.dx, accuracy: 1e-9)
        XCTAssertEqual(tip.dy, up.dy, accuracy: 1e-9)
        // Lifting is up the screen; sinking is down it.
        let rest = solved.point(radius: solved.penRadius(lift: 0), angle: angle)
        XCTAssertLessThan(solved.point(radius: solved.penRadius(lift: 18), angle: angle).y, rest.y)
        XCTAssertGreaterThan(
          solved.point(radius: solved.penRadius(lift: 0, sink: 70), angle: angle).y, rest.y)
      }
    }
  }

  func testAMirroredPenSitsInTheBandAsItDoesAbove() {
    let above = layout(CGPoint(x: 200, y: 600))
    let below = layout(CGPoint(x: 200, y: 150))
    XCTAssertEqual(above.penRadius(lift: 0), 330 - 24)
    XCTAssertEqual(below.penRadius(lift: 0), 330 + 16)
    // The instrument is 120pt tall: its tip is 60pt tipward of its centre, and
    // clears the band's tipward edge by the same amount either way up.
    for lift in [0, m.liftCurrent, m.liftHovered] {
      let tipAbove = above.penRadius(lift: lift) + 60
      let tipBelow = below.penRadius(lift: lift) - 60
      XCTAssertEqual(m.bandOuterRadius - tipAbove, tipBelow - m.bandInnerRadius, accuracy: 1e-9)
    }
    XCTAssertGreaterThan(below.penRadius(lift: 0) - 60, m.bandInnerRadius, "a resting tip is whole")
  }

  func testAMirroredBandStaysUnderTheStatusBar() {
    // Thumb in the status bar: the band's ends would curl up past it.
    let thumb = CGPoint(x: 200, y: 30)
    let solved = layout(thumb)
    XCTAssertEqual(solved.orientation, .below)
    XCTAssertEqual(solved.thumb, thumb, "the anchor never moves")
    for off in [m.bandStart, 0, m.bandEnd] {
      XCTAssertGreaterThanOrEqual(
        solved.point(radius: m.bandInnerRadius, offset: off).y, insets.top + m.topClearance - 1e-9)
    }
    // Lower down there is nothing to clear: the centre is where the spec puts it.
    XCTAssertEqual(layout(CGPoint(x: 200, y: 150)).center.y, 150 - 220)
  }

  // MARK: - The fixed slots bookend the wheel

  func testShapesAndTheWellBookendTheWheelSymmetrically() {
    let solved = layout(CGPoint(x: 201, y: 680))
    XCTAssertEqual(m.bandStart, -m.bandEnd)
    XCTAssertEqual(m.shapesOffset, -m.wellOffset)
    let shapes = solved.point(radius: m.radius, offset: m.shapesOffset)
    let well = solved.point(radius: m.radius, offset: m.wellOffset)
    XCTAssertEqual(shapes.y, well.y, accuracy: 1e-9, "the same height: neither is an afterthought")
    XCTAssertEqual(solved.center.x - shapes.x, well.x - solved.center.x, accuracy: 1e-9)
  }

  func testAMissingSlotTrimsItsEndOfTheBand() {
    XCTAssertEqual(m.fitted(hasWell: true, hasShapes: true), m)
    let noShapes = m.fitted(hasWell: true, hasShapes: false)
    XCTAssertEqual([noShapes.bandStart, noShapes.bandEnd], [-2.95, 3.95])
    let neither = m.fitted(hasWell: false, hasShapes: false)
    XCTAssertEqual([neither.bandStart, neither.bandEnd], [-2.95, 2.95])
  }

  // MARK: - The scroll track

  private var sixteen: RemoteDrawPuckWheel {
    RemoteDrawPuckWheel(groups: (0..<16).map { "family\($0 / 4)" })
  }

  func testTheTrackIsTheWholeWheelOneSegmentPerFamily() {
    let wheel = sixteen
    XCTAssertEqual(wheel.length, 18)
    XCTAssertEqual(wheel.trackOrigin, -0.75, "half the seam's breath before the first pen")
    XCTAssertEqual(wheel.familySpans, [-0.5...3.5, 4...8, 8.5...12.5, 13...17])
    XCTAssertEqual(wheel.trackOffset(of: wheel.trackOrigin, span: 2.4), -2.4)
    XCTAssertEqual(wheel.trackOffset(of: wheel.trackOrigin + wheel.length, span: 2.4), 2.4)
  }

  func testTheBrightPartIsWhatIsInViewAcrossTheSeamToo() {
    let wheel = sixteen
    // Centred mid-family: that family, clipped by the window at the breaths.
    XCTAssertEqual(wheel.visibleSpans(wheel: 6, window: 2.5), [4...8])
    XCTAssertEqual(wheel.visibleSpans(wheel: 7, window: 2.5), [4.5...8, 8.5...9.5])
    // Centred on the first pen: the window wraps into the last family.
    XCTAssertEqual(wheel.visibleSpans(wheel: 0, window: 2.5), [-0.5...2.5, 15.5...17])
    // Turned a whole turn: the same.
    XCTAssertEqual(wheel.visibleSpans(wheel: 18, window: 2.5), wheel.visibleSpans(wheel: 0, window: 2.5))
  }

  func testNoRoomEitherWayTakesTheRoomierSide() {
    let short = CGSize(width: 402, height: 420)
    XCTAssertEqual(
      RemoteDrawPuckSolver.orientation(for: CGPoint(x: 100, y: 250), in: short), .above)
    XCTAssertEqual(
      RemoteDrawPuckSolver.orientation(for: CGPoint(x: 100, y: 150), in: short), .below)
  }

  func testDegenerateSurfacesDoNotSolve() {
    XCTAssertNil(RemoteDrawPuckSolver.solve(thumb: .zero, in: .zero))
    XCTAssertNil(RemoteDrawPuckSolver.solve(thumb: CGPoint(x: CGFloat.nan, y: 0), in: phone))
  }

  // MARK: - The wheel

  private var fullWheel: RemoteDrawPuckWheel {
    RemoteDrawPuckWheel(
      groups: RemoteDrawPuckDefaults.pens.map { kind in
        DrawingStyleKind.Family.allCases.first { $0.members.contains(kind) }?.rawValue
      })
  }

  func testTheWheelIsTheSixteenInstrumentsInFamilyOrder() {
    XCTAssertEqual(RemoteDrawPuckDefaults.pens.count, 16)
    XCTAssertEqual(
      RemoteDrawPuckDefaults.pens, DrawingStyleKind.Family.allCases.flatMap(\.members))
    XCTAssertEqual(Set(RemoteDrawPuckDefaults.pens).count, 16)
  }

  func testFamilyBreathsAreHalfASlot() {
    let wheel = fullWheel
    // pos(i) = i + 0.5 · familyIndex(i).
    for (index, kind) in RemoteDrawPuckDefaults.pens.enumerated() {
      let family = DrawingStyleKind.Family.allCases.firstIndex { $0.members.contains(kind) }!
      XCTAssertEqual(wheel.positions[index], Double(index) + 0.5 * Double(family))
    }
    XCTAssertEqual(wheel.length, wheel.positions[15] + 1.5)
    XCTAssertEqual(wheel.length, 18)
    XCTAssertTrue(wheel.wraps)
    // Four families, four breaths: three inside, one at the seam.
    XCTAssertEqual(wheel.breathOffsets(wheel: 0).count, 4)
    XCTAssertTrue(wheel.breathOffsets(wheel: 0).contains(4.75), "between Ballpoint (4) and Pencil (5.5)")
  }

  func testTheWheelWrapsSoEveryTipIsReachableBothWays() {
    let wheel = fullWheel
    // Turned to the first pen, the last pen (neon) sits just left of it,
    // across the seam's breath.
    XCTAssertEqual(wheel.offset(ofPen: 0, wheel: 0), 0)
    XCTAssertEqual(wheel.offset(ofPen: 15, wheel: 0), -1.5, accuracy: 1e-9)
    // Any wheel value: every offset lands in one turn around zero.
    for w in stride(from: -40.0, through: 40, by: 0.37) {
      for index in 0..<16 {
        let off = wheel.offset(ofPen: index, wheel: w)
        XCTAssertGreaterThanOrEqual(off, -9 - 1e-9)
        XCTAssertLessThan(off, 9 + 1e-9)
      }
    }
    // A full turn is the identity.
    XCTAssertEqual(
      wheel.offset(ofPen: 7, wheel: 3.3), wheel.offset(ofPen: 7, wheel: 3.3 + 18), accuracy: 1e-9)
  }

  func testAShortWheelDoesNotWrap() {
    let single = RemoteDrawPuckWheel(groups: [nil])
    XCTAssertFalse(single.wraps, "one pen must not show three times")
    XCTAssertEqual(single.offset(ofPen: 0, wheel: 20), -20)
    XCTAssertTrue(single.breathOffsets(wheel: 0).isEmpty)
  }

  // MARK: - The second tier

  func testTheTierCentresOnItsSourceWhenThereIsRoom() {
    let solved = layout(CGPoint(x: 200, y: 680))
    let source = solved.angle(ofOffset: 0)
    let tier = RemoteDrawPuckTier(
      source: .pen(3), kind: .widths, count: 5, sourceAngle: source, layout: solved)
    XCTAssertEqual(tier.angle, source, accuracy: 1e-12)
    XCTAssertEqual(tier.radius, 330 + 88)
    XCTAssertEqual(tier.angle(ofItem: 2), source, accuracy: 1e-12)
    XCTAssertEqual(tier.angle(ofItem: 3) - tier.angle(ofItem: 2), 0.135, accuracy: 1e-12)
    XCTAssertLessThan(tier.point(ofItem: 0).x, tier.point(ofItem: 4).x, "left to right")
    for k in 0..<5 {
      XCTAssertEqual(tier.item(atAngle: tier.angle(ofItem: k)), k)
    }
    XCTAssertNil(tier.item(atAngle: tier.angle(ofItem: 0) - 0.135))
    XCTAssertNil(tier.item(atAngle: tier.angle(ofItem: 4) + 0.135))
  }

  func testTheTierIsNudgedUntilEveryItemClearsTheEdges() {
    let solved = layout(CGPoint(x: 160, y: 680))
    for off in [-3.5, -2.5, -1.5, 3.5] {
      let source = solved.angle(ofOffset: off)
      for count in [5, 7] {
        let tier = RemoteDrawPuckTier(
          source: .well, kind: .colors, count: count, sourceAngle: source, layout: solved)
        let xs = (0..<count).map { tier.point(ofItem: $0).x }
        XCTAssertGreaterThanOrEqual(xs.min()!, 28 - 1e-6, "source \(off), \(count) items")
        XCTAssertLessThanOrEqual(xs.max()!, phone.width - 28 + 1e-6, "source \(off), \(count) items")
        // Nudged in 0.02 rad steps, never further than needed.
        let steps = (tier.angle - source) / 0.02
        XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6)
        if abs(steps) > 0.5 {
          let back = RemoteDrawPuckTier.placedAngle(
            around: source, count: count, layout: solved)
          XCTAssertEqual(back, tier.angle)
        }
      }
    }
  }

  func testTheMirroredTierIsNudgedTheRightWay() {
    let solved = layout(CGPoint(x: 160, y: 150))
    XCTAssertEqual(solved.orientation, .below)
    let tier = RemoteDrawPuckTier(
      source: .shapes, kind: .shapes, count: 5, sourceAngle: solved.angle(ofOffset: m.shapesOffset),
      layout: solved)
    let points = (0..<5).map { tier.point(ofItem: $0) }
    XCTAssertGreaterThanOrEqual(points.map(\.x).min()!, 28 - 1e-6)
    XCTAssertLessThanOrEqual(points.map(\.x).max()!, phone.width - 28 + 1e-6)
    XCTAssertTrue(points.allSatisfy { $0.y > 150 }, "the mirrored tier is below the thumb")
    XCTAssertLessThan(points[0].x, points[4].x, "left to right in the mirror too")
  }

  func testATierTooWideForTheScreenCentresRatherThanOverflowingOneSide() {
    let narrow = CGSize(width: 300, height: 700)
    let solved = layout(CGPoint(x: 150, y: 560), size: narrow)
    let tier = RemoteDrawPuckTier(
      source: .well, kind: .colors, count: 7, sourceAngle: solved.angle(ofOffset: 3.5),
      layout: solved)
    let xs = (0..<7).map { tier.point(ofItem: $0).x }
    let leftOverflow = max(0, 28 - xs.min()!)
    let rightOverflow = max(0, xs.max()! - (narrow.width - 28))
    XCTAssertGreaterThan(leftOverflow + rightOverflow, 0, "fixture must not fit")
    XCTAssertEqual(leftOverflow, rightOverflow, accuracy: 10, "split, not dumped on one side")
  }

  func testTooltipsAreClampedAwayFromTheEdges() {
    let solved = layout(CGPoint(x: 201, y: 680))
    let left = solved.tooltipPoint(radius: 330 + 94, angle: solved.angle(ofOffset: -2.5))
    XCTAssertEqual(left.x, 110)
    let right = solved.tooltipPoint(radius: 330 + 70, angle: solved.angle(ofOffset: m.wellOffset))
    XCTAssertEqual(right.x, phone.width - 110)
    let shapes = solved.tooltipPoint(radius: 330 + 70, angle: solved.angle(ofOffset: m.shapesOffset))
    XCTAssertEqual(shapes.x, 110)
    let middle = solved.tooltipPoint(radius: 330 + 94, angle: solved.angle(ofOffset: 0))
    XCTAssertEqual(middle.x, 201, accuracy: 1e-9)
    XCTAssertEqual(middle.y, 680 - 110 - 94, accuracy: 1e-9)
  }
}
