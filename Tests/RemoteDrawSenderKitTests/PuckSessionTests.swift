//
//  The arc's rules.
//
//  Geometry is `PuckGeometryTests`. This is the other half: what a finger
//  moving over a solved arc does to the state and — the part that can cost
//  someone a stroke — exactly which lifts commit and which cancel. Every rule
//  in the spec's "Rules" section has a test here by name.
//
import XCTest

@testable import RemoteDrawSenderKit

final class PuckSessionTests: XCTestCase {
  private let phone = CGSize(width: 402, height: 874)
  private let insets = RemoteDrawPuckSolver.Insets(top: 62, bottom: 34)
  private let m = RemoteDrawPuckMetrics.standard
  private let thumb = CGPoint(x: 201, y: 680)

  // MARK: - Fixtures

  private func menu(current: DrawingStyleKind = .whiteboardMarker, ink: String = "#1e40af")
    -> RemoteDrawPuckMenu
  {
    let pens = RemoteDrawPuckDefaults.pens.map {
      RemoteDrawPuckItem(
        id: "tip.\($0.rawValue)", title: $0.title, content: .instrument($0), isCurrent: $0 == current)
    }
    let widths = RemoteDrawPuckDefaults.widths.map {
      RemoteDrawPuckItem(
        id: "size.\(Int($0))", title: "\(Int($0)) pt", content: .width(points: $0, hex: ink),
        isCurrent: $0 == 6)
    }
    var colors = RemoteDrawPuckDefaults.colors.map {
      RemoteDrawPuckItem(id: "color.\($0)", title: $0, content: .swatch(hex: $0), isCurrent: $0 == ink)
    }
    colors.append(
      RemoteDrawPuckItem(id: "color.more", title: "All colors", content: .colorWell, opensSheet: true))
    let shapes = [
      RemoteDrawPuckItem(id: "shape.auto", title: "Smart", content: .symbol("wand.and.stars"), isCurrent: true),
      RemoteDrawPuckItem(id: "shape.freehand", title: "Freehand", content: .symbol("scribble")),
      RemoteDrawPuckItem(id: "shape.line", title: "Line", content: .symbol("line.diagonal")),
      RemoteDrawPuckItem(id: "shape.rectangle", title: "Box", content: .symbol("rectangle")),
      RemoteDrawPuckItem(id: "shape.more", title: "More", content: .symbol("ellipsis"), opensSheet: true),
    ]
    return RemoteDrawPuckMenu(
      pens: pens, widths: widths, colors: colors, shapes: shapes, inkHex: ink, width: 6,
      colorTitle: "Blue", shapeTitle: "Smart")
  }

  private func index(_ kind: DrawingStyleKind) -> Int {
    RemoteDrawPuckDefaults.pens.firstIndex(of: kind)!
  }

  private func session(
    thumb: CGPoint? = nil, current: DrawingStyleKind = .whiteboardMarker, ink: String = "#1e40af",
    menu custom: RemoteDrawPuckMenu? = nil
  ) -> RemoteDrawPuckSession {
    let layout = RemoteDrawPuckSolver.solve(thumb: thumb ?? self.thumb, in: phone, insets: insets)!
    return RemoteDrawPuckSession(
      menu: custom ?? menu(current: current, ink: ink), layout: layout, at: 0)
  }

  /// A point at slot offset `off`, `radius` from the arc's centre.
  private func at(_ s: RemoteDrawPuckSession, _ off: Double, radius: CGFloat? = nil) -> CGPoint {
    s.layout.point(radius: radius ?? s.layout.distance(of: s.layout.thumb), offset: off)
  }

  /// Moves far enough to count as deliberate, then back to where it started.
  private func travel(_ s: inout RemoteDrawPuckSession, time: TimeInterval = 0.01) {
    let back = s.location
    s.update(location: CGPoint(x: back.x, y: back.y + 30), at: time)
    s.update(location: back, at: time + 0.01)
  }

  // MARK: - Opening

  func testItOpensCentredOnTheCurrentPenDirectlyAboveTheThumb() {
    let s = session(current: .chalk)
    XCTAssertEqual(s.offset(ofPen: index(.chalk)), 0, accuracy: 1e-9)
    XCTAssertEqual(s.hover, .pen(index(.chalk)))
    XCTAssertEqual(s.opacity(ofPen: index(.chalk)), 1)
    XCTAssertNil(s.tier)
    XCTAssertFalse(s.hasTravelled)
  }

  func testAClampedCentreStillOpensOnTheCurrentPenAboveTheThumb() {
    // Pushed right of the thumb: the thumb is left of the apex, off 0.
    let s = session(thumb: CGPoint(x: 160, y: 680), current: .ink)
    XCTAssertNotEqual(s.layout.center.x, 160)
    let thumbOffset = s.layout.offset(of: CGPoint(x: 160, y: 680))
    XCTAssertEqual(s.offset(ofPen: index(.ink)), thumbOffset, accuracy: 1e-9)
    XCTAssertEqual(s.hover, .pen(index(.ink)))
  }

  func testAThumbUnderTheWellPutsTheCurrentPenAtTheNearestCalmSlot() {
    let s = session(thumb: CGPoint(x: 330, y: 680), current: .pencil)
    let thumbOffset = s.layout.offset(of: CGPoint(x: 330, y: 680))
    XCTAssertGreaterThan(thumbOffset, 2.85, "fixture: the thumb is under the fixed slots")
    XCTAssertEqual(s.offset(ofPen: index(.pencil)), 1.5, accuracy: 1e-9)
    XCTAssertEqual(s.opacity(ofPen: index(.pencil)), 1)
  }

  // MARK: - Hover by angle

  func testHoverIsTheNearestVisiblePenWithinThreeQuarterSlot() {
    var s = session(current: .whiteboardMarker)
    let marker = index(.whiteboardMarker)
    s.update(location: at(s, 1.0), at: 0.1)
    XCTAssertEqual(s.hover, .pen(marker + 1), "one slot right is Brush pen")
    s.update(location: at(s, -1.0), at: 0.2)
    XCTAssertEqual(s.hover, .pen(marker - 1))
  }

  func testTheMiddleOfAFamilyBreathHoversNothing() {
    // Ink at 0; across the seam's breath, Neon at −1.5. The breath's middle is
    // 0.75 from both: not within reach of either.
    var s = session(current: .ink)
    let r = s.layout.distance(of: s.layout.thumb)
    XCTAssertEqual(s.offset(ofPen: index(.neon)), -1.5, accuracy: 1e-9)
    XCTAssertNil(s.target(atOffset: -0.75, radius: r))
    XCTAssertEqual(s.target(atOffset: -0.76, radius: r), .pen(index(.neon)))
    XCTAssertEqual(s.target(atOffset: -0.74, radius: r), .pen(index(.ink)))
    // Arriving from Neon, the hysteresis holds it a little past the middle…
    s.update(location: at(s, -1.5), at: 0.1)
    XCTAssertEqual(s.hover, .pen(index(.neon)))
    s.update(location: at(s, -0.7), at: 0.2)
    XCTAssertEqual(s.hover, .pen(index(.neon)))
    // …and no further.
    s.update(location: at(s, -0.5), at: 0.3)
    XCTAssertEqual(s.hover, .pen(index(.ink)))
  }

  func testPastEitherDividerIsThatEndsSlot() {
    let s = session()
    let r = s.layout.distance(of: s.layout.thumb)
    XCTAssertEqual(s.target(atOffset: 2.86, radius: r), .well)
    XCTAssertEqual(s.target(atOffset: 3.95, radius: r), .well)
    XCTAssertNil(s.target(atOffset: 3.96, radius: r), "past the band")
    XCTAssertEqual(s.target(atOffset: -2.86, radius: r), .shapes)
    XCTAssertEqual(s.target(atOffset: -3.95, radius: r), .shapes)
    XCTAssertNil(s.target(atOffset: -3.96, radius: r), "past the band")
  }

  func testOnlyVisiblePensCanBeHovered() {
    let s = session(current: .whiteboardMarker)
    let r = s.layout.distance(of: s.layout.thumb)
    // At −2.9 the nearest pen is outside the fade (|off| ≥ 2.6): nothing.
    let hidden = s.menu.pens.indices.filter { abs(s.offset(ofPen: $0)) >= 2.6 }
    XCTAssertFalse(hidden.isEmpty)
    for off in stride(from: -2.94, through: 2.84, by: 0.1) {
      if case .pen(let i) = s.target(atOffset: off, radius: r) {
        XCTAssertLessThan(abs(s.offset(ofPen: i)), 2.6, "hovered an invisible pen at \(off)")
      }
    }
  }

  func testHoverHasHysteresisSoABoundaryDoesNotStrobe() {
    var s = session(current: .whiteboardMarker)
    let marker = index(.whiteboardMarker)
    s.update(location: at(s, 0.55), at: 0.1)
    XCTAssertEqual(s.hover, .pen(marker), "0.55 is past the midpoint but inside the 0.15 hysteresis")
    s.update(location: at(s, 0.66), at: 0.2)
    XCTAssertEqual(s.hover, .pen(marker + 1))
    s.update(location: at(s, 0.45), at: 0.3)
    XCTAssertEqual(s.hover, .pen(marker + 1), "and back: held from the other side")
    s.update(location: at(s, 0.34), at: 0.4)
    XCTAssertEqual(s.hover, .pen(marker))
  }

  func testEachDividerHasHysteresisToo() {
    for (slot, side) in [(RemoteDrawPuckTarget.shapes, -1.0), (.well, 1.0)] {
      var s = session()
      s.update(location: at(s, side * 3.5), at: 0.1)
      XCTAssertEqual(s.hover, slot)
      // Just back over the divider: held.
      s.update(location: at(s, side * 2.78), at: 0.2)
      XCTAssertEqual(s.hover, slot, "\(slot) is held inside the hysteresis")
      s.update(location: at(s, side * 2.5), at: 0.3)
      XCTAssertNotEqual(s.hover, slot, "\(slot) lets go past it")
    }
  }

  func testCrossingAFamilyIsReported() {
    var s = session(current: .ballpoint)
    // Ballpoint at 0, Pencil (Dry media) at 1.5.
    XCTAssertEqual(s.offset(ofPen: index(.pencil)), 1.5, accuracy: 1e-9)
    let change = s.update(location: at(s, 1.5), at: 0.1)
    XCTAssertTrue(change.contains(.hover))
    XCTAssertTrue(change.contains(.family))
    let within = s.update(location: at(s, 2.5), at: 0.2)
    XCTAssertTrue(within.contains(.hover))
    XCTAssertFalse(within.contains(.family), "Pencil → Tilt pencil is the same family")
  }

  func testLiftsAreHoveredNeighboursAndResting() {
    var s = session(current: .whiteboardMarker)
    let marker = index(.whiteboardMarker)
    XCTAssertEqual(s.lift(ofPen: marker), 18)
    XCTAssertEqual(s.lift(ofPen: marker - 1), 5)
    XCTAssertEqual(s.lift(ofPen: marker + 1), 5)
    XCTAssertEqual(s.lift(ofPen: marker + 2), 0)
    // Across a breath is not a neighbour.
    s = session(current: .ballpoint)
    XCTAssertEqual(s.lift(ofPen: index(.pencil)), 0)
    // Nothing hovered: the current pen rests raised.
    s.update(location: at(s, 0, radius: m.radius - 210), at: 0.1)
    XCTAssertNil(s.hover)
    XCTAssertEqual(s.lift(ofPen: index(.ballpoint)), 10)
  }

  // MARK: - Commit and cancel

  func testReleaseInPlaceCancelsEvenWithAPenHovered() {
    var s = session()
    XCTAssertNotNil(s.hover)
    XCTAssertEqual(s.release(at: thumb, at: 0.5), .cancelled)
  }

  func testTravelUnder24PointsNeverCommits() {
    var s = session()
    s.update(location: CGPoint(x: thumb.x + 23, y: thumb.y), at: 0.1)
    XCTAssertFalse(s.hasTravelled)
    XCTAssertEqual(s.release(at: CGPoint(x: thumb.x + 23, y: thumb.y), at: 0.2), .cancelled)
  }

  func testTravelAtAnyTimeCountsEvenIfTheFingerComesBack() {
    var s = session(current: .chalk)
    travel(&s)
    XCTAssertTrue(s.hasTravelled)
    guard case .commit(let commit) = s.release(at: thumb, at: 0.5) else {
      return XCTFail("a deliberate gesture that ends on a pen commits it")
    }
    XCTAssertEqual(commit.items.map(\.id), ["tip.chalk"])
    XCTAssertEqual(commit.label, "Chalk")
  }

  func testReleaseOnAPenCommitsThatPen() {
    var s = session(current: .whiteboardMarker)
    s.update(location: at(s, 1), at: 0.1)
    guard case .commit(let commit) = s.release(at: at(s, 1), at: 0.2) else { return XCTFail() }
    XCTAssertEqual(commit.selection, RemoteDrawPuckSelection(source: .pen(index(.brushPen))))
    XCTAssertEqual(commit.items.map(\.id), ["tip.brushPen"])
  }

  func testReleaseOffTheBandCancels() {
    var s = session()
    s.update(location: at(s, -4.1), at: 0.1)
    XCTAssertNil(s.hover)
    XCTAssertEqual(s.release(at: at(s, -4.1), at: 0.2), .cancelled)
  }

  func testDraggedFarBelowTheThumbCancels() {
    var s = session()
    let low = at(s, 0, radius: m.radius - 201)
    s.update(location: low, at: 0.1)
    XCTAssertNil(s.hover, "|touch − o| < R − 200 hovers nothing")
    XCTAssertEqual(s.release(at: low, at: 0.2), .cancelled)
    var near = session()
    let justInside = at(near, 0, radius: m.radius - 199)
    near.update(location: justInside, at: 0.1)
    XCTAssertNotNil(near.hover)
  }

  func testReleaseOnTheTraysWellOpensThePaletteAndShapesTheCollection() {
    var s = session()
    s.update(location: at(s, 3.5), at: 0.1)
    guard case .commit(let well) = s.release(at: at(s, 3.5), at: 0.2) else { return XCTFail() }
    XCTAssertEqual(well.items.map(\.id), ["color.more"])
    XCTAssertNil(well.label, "a sheet opener gets no chip")

    var t = session()
    t.update(location: at(t, m.shapesOffset), at: 0.1)
    guard case .commit(let shapes) = t.release(at: at(t, m.shapesOffset), at: 0.2) else { return XCTFail() }
    XCTAssertEqual(shapes.items.map(\.id), ["shape.more"])
  }

  func testAReleasedSessionIgnoresEverything() {
    var s = session()
    travel(&s)
    _ = s.release(at: at(s, 1), at: 0.3)
    XCTAssertTrue(s.isReleased)
    XCTAssertEqual(s.update(location: at(s, 3.5), at: 0.4), [])
    XCTAssertEqual(s.advance(by: 0.016, at: 1), [])
  }

  // MARK: - The second tier

  func testSlidingUpOpensTheSourcesTierWithHysteresis() {
    var s = session(current: .chalk)
    s.update(location: at(s, 0, radius: m.radius - 73), at: 0.1)
    XCTAssertNil(s.tier, "R − 73 is not past R − 72")
    let change = s.update(location: at(s, 0, radius: m.radius - 71), at: 0.2)
    XCTAssertTrue(change.contains(.tierOpened))
    XCTAssertEqual(s.tier?.source, .pen(index(.chalk)))
    XCTAssertEqual(s.tier?.kind, .widths)
    XCTAssertEqual(s.tier?.count, 5)
    s.update(location: at(s, 0, radius: m.radius - 91), at: 0.3)
    XCTAssertNotNil(s.tier, "closes only inside R − 92")
    let closed = s.update(location: at(s, 0, radius: m.radius - 93), at: 0.4)
    XCTAssertTrue(closed.contains(.tierClosed))
    XCTAssertNil(s.tier)
  }

  func testWhileATierIsOpenTheTrayStaysOnItsSource() {
    var s = session(current: .chalk)
    s.update(location: at(s, 0, radius: m.radius - 30), at: 0.1)
    XCTAssertNotNil(s.tier)
    s.update(location: at(s, 1.4, radius: m.radius - 30), at: 0.2)
    XCTAssertEqual(s.hover, .pen(index(.chalk)))
    XCTAssertEqual(s.tier?.source, .pen(index(.chalk)))
  }

  func testReleaseWithATierOpenCommitsThePenAndItsWidth() {
    var s = session(current: .whiteboardMarker)
    s.update(location: at(s, 1), at: 0.1)  // Brush pen
    s.update(location: at(s, 1, radius: m.radius - 30), at: 0.2)
    let tier = s.tier!
    let target = s.layout.point(radius: m.radius - 30, angle: tier.angle(ofItem: 3))
    let change = s.update(location: target, at: 0.3)
    XCTAssertTrue(change.contains(.tierHover))
    XCTAssertEqual(s.tierHover, 3)
    XCTAssertEqual(s.previewWidth, 10)
    guard case .commit(let commit) = s.release(at: target, at: 0.4) else { return XCTFail() }
    XCTAssertEqual(commit.items.map(\.id), ["tip.brushPen", "size.10"], "pen first, then its width")
    XCTAssertEqual(commit.label, "Brush pen · 10 pt")
  }

  func testReleaseWithATierOpenAndNothingHoveredCancels() {
    var s = session(current: .chalk)
    s.update(location: at(s, 0, radius: m.radius - 30), at: 0.1)
    let tier = s.tier!
    let past = s.layout.point(radius: m.radius - 30, angle: tier.angle(ofItem: 4) + 0.135 * 1.2)
    s.update(location: past, at: 0.2)
    XCTAssertNotNil(s.tier)
    XCTAssertNil(s.tierHover)
    XCTAssertEqual(s.release(at: past, at: 0.3), .cancelled)
  }

  func testTierHoverHasHysteresis() {
    var s = session(current: .chalk)
    s.update(location: at(s, 0, radius: m.radius - 30), at: 0.1)
    let tier = s.tier!
    func point(_ k: Double) -> CGPoint {
      s.layout.point(
        radius: m.radius - 30,
        angle: tier.angle + s.layout.sign * (k - 2) * m.tierStep)
    }
    s.update(location: point(1), at: 0.2)
    XCTAssertEqual(s.tierHover, 1)
    s.update(location: point(1.6), at: 0.3)
    XCTAssertEqual(s.tierHover, 1)
    s.update(location: point(1.7), at: 0.4)
    XCTAssertEqual(s.tierHover, 2)
  }

  func testHoveringASwatchReDipsEveryTipAndLeavingRestores() {
    var s = session(ink: "#1e40af")
    s.update(location: at(s, 3.5), at: 0.1)
    s.update(location: at(s, 3.5, radius: m.radius - 30), at: 0.2)
    XCTAssertEqual(s.tier?.kind, .colors)
    XCTAssertEqual(s.tier?.count, 7, "six swatches and the palette well")
    let tier = s.tier!
    s.update(location: s.layout.point(radius: m.radius - 30, angle: tier.angle(ofItem: 2)), at: 0.3)
    XCTAssertEqual(s.previewHex, "#1f7a8c")
    XCTAssertEqual(s.tipHex, "#1f7a8c")
    s.update(location: s.layout.point(radius: m.radius - 30, angle: tier.angle(ofItem: 6)), at: 0.4)
    XCTAssertNil(s.previewHex, "the palette well is not a colour")
    XCTAssertEqual(s.tipHex, "#1e40af")
    s.update(location: at(s, 3.5, radius: m.radius - 100), at: 0.5)
    XCTAssertNil(s.tier)
    XCTAssertEqual(s.tipHex, "#1e40af")
  }

  func testAColourCommitIsJustTheColour() {
    var s = session()
    s.update(location: at(s, 3.5), at: 0.1)
    s.update(location: at(s, 3.5, radius: m.radius - 30), at: 0.2)
    let target = s.layout.point(radius: m.radius - 30, angle: s.tier!.angle(ofItem: 3))
    s.update(location: target, at: 0.3)
    guard case .commit(let commit) = s.release(at: target, at: 0.4) else { return XCTFail() }
    XCTAssertEqual(commit.items.map(\.id), ["color.#2f6b4f"])
  }

  func testTheShapesTierCommitsAShape() {
    var s = session()
    s.update(location: at(s, m.shapesOffset), at: 0.1)
    s.update(location: at(s, m.shapesOffset, radius: m.radius - 30), at: 0.2)
    XCTAssertEqual(s.tier?.kind, .shapes)
    let target = s.layout.point(radius: m.radius - 30, angle: s.tier!.angle(ofItem: 2))
    s.update(location: target, at: 0.3)
    guard case .commit(let commit) = s.release(at: target, at: 0.4) else { return XCTFail() }
    XCTAssertEqual(commit.items.map(\.id), ["shape.line"])
    XCTAssertEqual(commit.label, "Line")
  }

  func testTheTierIsClampedOnScreen() {
    // Thumb hard left: Ink hovered at the window's left end.
    var s = session(thumb: CGPoint(x: 20, y: 680), current: .ink)
    s.update(location: at(s, s.offset(ofPen: index(.ink)), radius: m.radius - 30), at: 0.1)
    let tier = s.tier!
    for k in 0..<tier.count {
      XCTAssertGreaterThanOrEqual(tier.point(ofItem: k).x, 28 - 1e-6)
      XCTAssertLessThanOrEqual(tier.point(ofItem: k).x, phone.width - 28 + 1e-6)
    }
  }

  // MARK: - Edge scroll

  func testTheEdgeTurnsTheWheelAfterADwell() {
    var s = session(current: .whiteboardMarker)
    travel(&s)
    let start = s.wheel
    s.update(location: at(s, 2.35), at: 1.0)
    XCTAssertEqual(s.advance(by: 0.016, at: 1.1), [], "0.1 s is not a dwell")
    XCTAssertEqual(s.wheel, start)
    let change = s.advance(by: 0.02, at: 1.23)
    XCTAssertTrue(change.contains(.scrolled))
    XCTAssertTrue(s.isScrolling)
    // 3.4 slot/s · min(1, (2.35 − 1.95)/0.4 + 0.4) = 3.4 · 1 → 0.068 in 20 ms.
    XCTAssertEqual(s.wheel - start, 3.4 * 0.02, accuracy: 1e-6)
  }

  func testEdgeSpeedRampsWithDepthIntoTheZone() {
    var s = session(current: .whiteboardMarker)
    travel(&s)
    s.update(location: at(s, -2.0), at: 1.0)
    let start = s.wheel
    s.advance(by: 0.02, at: 1.3)
    // Left edge turns the other way, at 3.4 · (0.05/0.4 + 0.4) = 1.785 slot/s.
    let offset = s.layout.offset(of: s.location)
    let expected = -3.4 * min(1, (abs(offset) - 1.95) / 0.4 + 0.4) * 0.02
    XCTAssertEqual(s.wheel - start, expected, accuracy: 1e-9)
    XCTAssertLessThan(s.wheel - start, 0)
  }

  func testPensPassingUnderAStillFingerEachTick() {
    var s = session(current: .whiteboardMarker)
    travel(&s)
    s.update(location: at(s, 2.2), at: 1.0)
    var passes = 0
    var time = 1.0
    for _ in 0..<120 {
      time += 1.0 / 60
      if s.advance(by: 1.0 / 60, at: time).contains(.hover) { passes += 1 }
    }
    // ~1.78 s of scrolling at 3.4 · 1.0 ≈ 6 slots ≈ 5–6 pens passing.
    XCTAssertGreaterThanOrEqual(passes, 4)
    XCTAssertLessThanOrEqual(passes, 8)
  }

  func testLeavingTheEdgeSnapsTheHoveredPenUnderTheFinger() {
    var s = session(current: .whiteboardMarker)
    travel(&s)
    s.update(location: at(s, 2.2), at: 1.0)
    var time = 1.0
    for _ in 0..<40 {
      time += 1.0 / 60
      s.advance(by: 1.0 / 60, at: time)
    }
    XCTAssertTrue(s.isScrolling)
    let change = s.update(location: at(s, 1.7), at: time + 0.01)
    XCTAssertTrue(change.contains(.snapped))
    XCTAssertFalse(s.isScrolling)
    guard case .pen(let hovered) = s.hover else { return XCTFail("a pen stays hovered") }
    XCTAssertEqual(s.offset(ofPen: hovered), 1.7, accuracy: 1e-9)
  }

  func testNoEdgeScrollWhileATierIsOpen() {
    var s = session(current: .whiteboardMarker)
    travel(&s)
    s.update(location: at(s, 2.2), at: 1.0)
    s.update(location: at(s, 2.2, radius: m.radius - 30), at: 1.05)
    XCTAssertNotNil(s.tier)
    XCTAssertEqual(s.advance(by: 0.016, at: 2.0), [])
  }

  func testAThumbThatLandsInTheEdgeZoneDoesNotTurnTheWheelByHoldingStill() {
    // The thumb itself lands in the zone: without travel, no dwell.
    let thumb = CGPoint(x: 275, y: 680)
    var s = session(thumb: thumb)
    let landed = s.layout.offset(of: thumb)
    XCTAssertTrue(landed > 1.95 && landed < 2.75, "fixture: the thumb is in the edge zone (\(landed))")
    XCTAssertEqual(s.advance(by: 0.016, at: 1.0), [])
    XCTAssertEqual(s.advance(by: 0.016, at: 2.0), [])
    XCTAssertFalse(s.isScrolling)
  }

  // MARK: - The mirror

  func testTheMirroredArcIsDrivenTheSameWay() {
    let top = CGPoint(x: 160, y: 150)
    var s = session(thumb: top, current: .chalk)
    XCTAssertEqual(s.layout.orientation, .below)
    XCTAssertEqual(s.hover, .pen(index(.chalk)))
    // "Up" into the tier is *down* the screen here: further from o.
    let down = CGPoint(x: top.x, y: top.y + 110 + 10)
    let change = s.update(location: down, at: 0.1)
    XCTAssertTrue(change.contains(.tierOpened))
    let target = s.layout.point(radius: m.radius, angle: s.tier!.angle(ofItem: 1))
    s.update(location: target, at: 0.2)
    guard case .commit(let commit) = s.release(at: target, at: 0.3) else { return XCTFail() }
    XCTAssertEqual(commit.items.map(\.id), ["tip.chalk", "size.4"])
  }

  // MARK: - Capabilities and menus

  func testAPointOnlyWheelHasNoWidthsAndDoesNotScroll() {
    let point = RemoteDrawPuckMenu(
      pens: [RemoteDrawPuckItem(id: "shape.point", title: "Point", content: .symbol("smallcircle.filled.circle"), isCurrent: true)],
      widths: [], colors: menu().colors,
      shapes: [RemoteDrawPuckItem(id: "shape.more", title: "More", content: .symbol("ellipsis"), opensSheet: true)],
      inkHex: "#151512", width: 6)
    var s = session(menu: point)
    XCTAssertFalse(s.wheelModel.wraps)
    XCTAssertEqual(s.hover, .pen(0))
    XCTAssertNil(point.tierKind(for: .pen(0)), "Point has no widths")
    s.update(location: at(s, 0, radius: m.radius - 30), at: 0.1)
    XCTAssertNil(s.tier)
    travel(&s)
    s.update(location: at(s, 2.2), at: 1.0)
    XCTAssertEqual(s.advance(by: 0.016, at: 2.0), [])
    s.update(location: at(s, 0.2), at: 2.1)
    guard case .commit(let commit) = s.release(at: at(s, 0.2), at: 2.2) else { return XCTFail() }
    XCTAssertEqual(commit.items.map(\.id), ["shape.point"])
  }

  func testTheMenuIsFrozenIntoTheSession() {
    let frozen = menu(current: .chalk)
    var s = session(menu: frozen)
    XCTAssertEqual(s.menu, frozen)
    travel(&s)
    guard case .commit(let commit) = s.release(at: s.layout.thumb, at: 0.5) else { return XCTFail() }
    XCTAssertEqual(commit.items.first, frozen.pens[index(.chalk)])
  }

  func testAnEmptyMenuIsNotPresentable() {
    XCTAssertFalse(RemoteDrawPuckMenu.empty.isPresentable)
    XCTAssertTrue(menu().isPresentable)
  }

  func testCancelEndsTheGesture() {
    var s = session()
    s.cancel()
    XCTAssertTrue(s.isReleased)
    XCTAssertEqual(s.update(location: at(s, 1), at: 0.1), [])
  }
}
