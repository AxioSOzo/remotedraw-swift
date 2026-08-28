//
//  Moved here from `apps/ios/RemoteDrawTests/RemoteDrawClientConfigurationTests.swift`
//  by Stage 2.
//
//  It is the renderer's surface table this pins — grounds, tooth, grain,
//  absorbency, the instrument palette each surface leads with — against
//  `packages/client/src/surfaces.ts`. Every symbol it touches is internal to
//  `RemoteDrawInk`, which the app can no longer reach now that it imports the
//  module rather than compiling its source.
//
import XCTest

@testable import RemoteDrawInk

/// TypeScript <-> Swift parity for the surface table.
///
/// `packages/client/src/surfaces.ts` and `RemoteDrawInkSurface` in
/// `InkRenderer.swift` are a hand mirror: two files, one specification, and no
/// compiler standing between them. That is exactly how the tooth drifted. The
/// web moved the paper from the instrument to the surface — six per-instrument
/// grains and three tooth specs collapsed onto one sheet — and iOS went on
/// binding `fineTooth` to a pencil and `coarseTooth` to charcoal with nothing
/// failing anywhere. The packed point codec has pinned parity vectors and has
/// never drifted; the ink geometry had none, and did.
///
/// These are the same vectors `packages/client/tests/surfaces.test.ts` asserts
/// under "the Swift mirror pins the same vectors". Change one side alone and one
/// of the two suites fails.
final class SurfaceParityTests: XCTestCase {
  /// The instruments that declare `ridesTooth`. Mirrors `DRY_KINDS` in
  /// surfaces.test.ts.
  private let dryKinds: [DrawingStyleKind] = [
    .pencil, .chalk, .charcoal, .crayon, .dryBrush, .tiltPencil,
  ]

  // MARK: - The surface owns the paper

  func testGroundGrainAndToothPerSurface() {
    let expected:
      [(
        kind: RemoteDrawInkSurface.Kind,
        ground: RemoteDrawInkSurface.Ground,
        grain: Double?,
        tooth: RemoteDrawInk.Tooth?,
        absorbency: Double,
        depositRate: Double?
      )] = [
        (.whiteboard, RemoteDrawInkSurface.Ground.whiteboard, nil, nil, 0, 0.85),
        (
          .paper, RemoteDrawInkSurface.Ground.paper, 11,
          // `depth` was 1 until the painter was given a real per-pixel ceiling.
          // A full-depth mask rejects the deepest valleys outright, which was
          // load-bearing only because nothing else kept a worked passage off
          // black; the board's own `bite` term asks for about half that. See
          // `RemoteDrawInkSurface.paperTooth`.
          RemoteDrawInk.Tooth(scale: 0.55, radius: 0.275, depth: 0.51), 0.55, nil
        ),
        (.map, RemoteDrawInkSurface.Ground.none, nil, nil, 0, 0.85),
        (.custom, RemoteDrawInkSurface.Ground.none, nil, nil, 0, 0.85),
      ]
    XCTAssertEqual(
      expected.count, RemoteDrawInkSurface.Kind.allCases.count,
      "A new render surface needs a pinned vector here and in surfaces.test.ts."
    )
    for row in expected {
      let spec = RemoteDrawInkSurface.spec(row.kind)
      XCTAssertEqual(spec.ground, row.ground, "\(row.kind) ground")
      XCTAssertEqual(spec.grain, row.grain, "\(row.kind) grain")
      XCTAssertEqual(spec.tooth, row.tooth, "\(row.kind) tooth")
      XCTAssertEqual(spec.absorbency, row.absorbency, "\(row.kind) absorbency")
      XCTAssertEqual(spec.depositScale?.rate, row.depositRate, "\(row.kind) deposit rate")
      // The sheet and its mask travel together: a surface with a grain has a
      // tooth, and one without has neither.
      XCTAssertEqual(
        spec.grain == nil, spec.tooth == nil,
        "\(row.kind) has a grain without a tooth, or the reverse"
      )
      XCTAssertEqual(RemoteDrawInkSurface.grain(row.kind), row.grain)
      XCTAssertEqual(RemoteDrawInkSurface.tooth(row.kind), row.tooth)
      XCTAssertEqual(RemoteDrawInkSurface.absorbency(row.kind), row.absorbency)
      // A sheet that drinks is a sheet with fibres: absorbency and the tooth are
      // two readings of the same paper, so one without the other is a surface
      // half-described. Stated as an implication rather than an equality because
      // a tooth-bearing sheet that genuinely repels — coated art board — is a
      // thing, and this is the direction that has never made sense.
      if row.absorbency > 0 {
        XCTAssertNotNil(spec.tooth, "\(row.kind) drinks but has no fibres")
      }
    }
  }

  /// The wet half of the surface's paper, mirroring the block of the same name in
  /// `surfaces.test.ts`.
  ///
  /// The *shape* is the thing pinned here, not the numbers: a wet mark's boundary
  /// must be decided by one fact about the sheet and one about the medium, and by
  /// nothing an instrument believes about what it is drawn on.
  func testOnlyAnAbsorbentSurfaceGivesAnEdgeTreatment() {
    let wet: [DrawingStyleKind] = [
      .ink, .whiteboardMarker, .brushPen, .fineliner, .ballpoint,
      .italicNib, .chiselMarker, .highlighter, .airbrush, .neon,
    ]
    for surface in [RemoteDrawInkSurface.Kind.whiteboard, .map, .custom] {
      for kind in wet + dryKinds {
        XCTAssertNil(
          RemoteDrawInk.edge(for: kind, surface: surface), "\(kind) on \(surface)")
        XCTAssertNil(
          RemoteDrawInk.profile(for: kind, surface: surface).edge, "\(kind) on \(surface)")
      }
    }
    // Dry media never feather, and it is derived from `ridesTooth` rather than
    // declared, so graphite cannot acquire a wet edge by being forgotten.
    for kind in dryKinds {
      XCTAssertNil(RemoteDrawInk.edge(for: kind, surface: .paper), "\(kind)")
      XCTAssertNil(RemoteDrawInk.profile(for: kind, surface: .paper).edge, "\(kind)")
    }
    // Three wet instruments opt out or down, each for a reason about the medium:
    // an oil paste, an atomised spray, a synthetic glow.
    XCTAssertNil(RemoteDrawInk.edge(for: .airbrush, surface: .paper))
    XCTAssertNil(RemoteDrawInk.edge(for: .neon, surface: .paper))
    guard let ink = RemoteDrawInk.edge(for: .ink, surface: .paper),
      let ballpoint = RemoteDrawInk.edge(for: .ballpoint, surface: .paper)
    else { return XCTFail("ink and ballpoint feather on paper") }
    XCTAssertLessThan(ballpoint.feather, ink.feather)
    // 1 page unit of wicking at full absorbency; cartridge is 0.55 of that.
    XCTAssertEqual(ink.feather, 0.55, accuracy: 1e-12)
    XCTAssertEqual(ink.bleed, 0.55, accuracy: 1e-12)
    XCTAssertEqual(ballpoint.feather, 0.55 * 0.25, accuracy: 1e-12)
  }

  /// Dry-out is geometry, and only at the lift.
  ///
  /// The halo leaves the mark's own silhouette alone by construction — which is
  /// what makes it tone-safe — so it can never make a lift *fail*. That job is the
  /// taper's, and only the exit's: a landing is the nib arriving loaded, which
  /// absorbency has nothing to say about.
  func testAnAbsorbentSheetDriesTheLiftOutAndLeavesTheLandingAlone() {
    guard let dry = RemoteDrawInk.profile(for: .ink, surface: .whiteboard).taper,
      let wet = RemoteDrawInk.profile(for: .ink, surface: .paper).taper,
      let dryExit = dry.exit, let wetExit = wet.exit
    else { return XCTFail("ink tapers at both ends on both surfaces") }
    XCTAssertEqual(wet.tipFactor, dry.tipFactor)
    XCTAssertEqual(wet.arcFraction, dry.arcFraction)
    XCTAssertEqual(wet.maxWidths, dry.maxWidths)
    XCTAssertLessThan(wetExit.tipFactor, dryExit.tipFactor)
    XCTAssertGreaterThan(wetExit.maxWidths, dryExit.maxWidths)
    XCTAssertEqual(
      wetExit.tipFactor, dryExit.tipFactor * (1 - 0.7 * 0.55), accuracy: 1e-12)
    XCTAssertEqual(
      wetExit.maxWidths, dryExit.maxWidths * (1 + 0.8 * 0.55), accuracy: 1e-12)
    // An instrument with no taper gets no exit invented for it: the surface bends
    // what an instrument has, it does not add organs.
    for kind in [DrawingStyleKind.fineliner, .highlighter, .italicNib, .chiselMarker] {
      XCTAssertNil(RemoteDrawInk.profile(for: kind, surface: .paper).taper, "\(kind)")
      XCTAssertNotNil(RemoteDrawInk.profile(for: kind, surface: .paper).edge, "\(kind)")
    }
  }

  func testEveryDryInstrumentBitesIntoTheSameTooth() {
    let teeth = Set(
      dryKinds.map { kind -> String in
        let tooth = RemoteDrawInk.profile(for: kind, surface: .paper).tooth
        XCTAssertNotNil(tooth, "\(kind) rides the tooth and paper has one")
        guard let tooth else { return "missing-\(kind.rawValue)" }
        return "\(tooth.scale)-\(tooth.radius)-\(tooth.depth)"
      }
    )
    // Three distinct specs here — fine / paper / coarse, bound per instrument —
    // is precisely the state this replaced, and precisely what iOS still had
    // after the web had already unified.
    XCTAssertEqual(teeth.count, 1, "one board, one sheet of paper: \(teeth)")
    XCTAssertEqual(RemoteDrawInk.profile(for: .pencil, surface: .paper).tooth,
                   RemoteDrawInkSurface.paperTooth)
  }

  func testAWhiteboardHasNoToothHoweverDryTheInstrument() {
    // Dry media are not forbidden on a whiteboard; they simply draw an even
    // line, which is what a pencil on a glossy surface does.
    for kind in dryKinds {
      XCTAssertTrue(RemoteDrawInk.profile(for: kind).ridesTooth, "\(kind) should ride the tooth")
      XCTAssertNil(
        RemoteDrawInk.profile(for: kind, surface: .whiteboard).tooth,
        "\(kind) on a whiteboard must get no mask rather than a borrowed one"
      )
      XCTAssertNil(RemoteDrawInk.profile(for: kind, surface: .map).tooth)
      XCTAssertNil(RemoteDrawInk.profile(for: kind, surface: .custom).tooth)
    }
  }

  func testAnInstrumentThatDoesNotRideTheToothNeverGetsOne() {
    let wet: [DrawingStyleKind] = [
      .ink, .whiteboardMarker, .brushPen, .fineliner, .ballpoint,
      .italicNib, .chiselMarker, .highlighter, .airbrush, .neon,
    ]
    XCTAssertEqual(
      wet.count + dryKinds.count, DrawingStyleKind.allCases.count,
      "Every instrument must be classified as riding the tooth or not."
    )
    for kind in wet {
      XCTAssertFalse(RemoteDrawInk.profile(for: kind).ridesTooth, "\(kind)")
      for surface in RemoteDrawInkSurface.Kind.allCases {
        XCTAssertNil(RemoteDrawInk.profile(for: kind, surface: surface).tooth, "\(kind) on \(surface)")
      }
    }
  }

  func testTheDefaultSurfaceIsPaper() {
    // Paper, because that is what every dry mark in the product has always been
    // drawn against: this refactor unified the sheet, it did not swap it. The
    // default is what callers that only want a width or an opacity get.
    XCTAssertEqual(RemoteDrawInkSurface.defaultKind, .paper)
    XCTAssertEqual(RemoteDrawInkSurface.grain(), 11)
    XCTAssertEqual(RemoteDrawInk.profile(for: .pencil).tooth, RemoteDrawInkSurface.paperTooth)
  }

  // MARK: - One sheet of paper, on every renderer

  /// The Swift height field is the web's, not a lookalike.
  ///
  /// `RemoteDrawPaperGround.height` is a transcription of `paperHeight`
  /// (`packages/client/src/dabEngine.ts`) over `InkRenderer.noise`, which is
  /// already the web's `inkNoise` byte for byte — so the two are not merely
  /// similar fields, they are the same field, and a page coordinate has to
  /// yield the same tooth on both. These vectors were produced by running the
  /// TypeScript at grain 11 and are written out here the way `pointCodec`'s
  /// parity vectors are: the same literals on both sides, because a shared
  /// fixture would need the checked-in xcodeproj to change.
  ///
  /// `surfaceSwiftParity.test.ts` pins the schedule constants themselves from
  /// the other direction, so a change to the octave plan fails in TypeScript
  /// as well as here.
  func testThePaperHeightFieldMatchesTheWeb() {
    let expected: [(x: Double, y: Double, height: Double)] = [
      (0.5, 0.5, 0.002578208580),
      (7.5, 3.5, 0.357827609695),
      (123.5, 88.5, 0.617352704975),
      (512.25, 511.75, 0.237767180917),
      (1000.5, 777.5, 0.495530159975),
    ]
    for row in expected {
      XCTAssertEqual(
        RemoteDrawPaperGround.height(row.x, row.y, grain: 11), row.height,
        accuracy: 1e-9, "paperHeight(\(row.x), \(row.y), 11)")
    }
    // A surface with no tooth reads as a flat ridge, not as noise: full
    // capacity, full bite, an even mark.
    XCTAssertEqual(RemoteDrawPaperGround.height(11, 23, grain: nil), 1)
    XCTAssertEqual(RemoteDrawPaperGround.height(400.5, 91.25, grain: 0), 1)
  }

  /// The schedule and the tone, pinned against `paperGround.ts`.
  func testThePaperGroundMatchesTheSharedSheet() {
    XCTAssertEqual(RemoteDrawPaperGround.octaves, 4)
    XCTAssertEqual(RemoteDrawPaperGround.falloff, 0.6, accuracy: 1e-12)
    XCTAssertEqual(RemoteDrawPaperGround.octaveGain, 0.75, accuracy: 1e-12)
    // #f7f4ed, the board's base tone — not `RemoteDrawTheme.paper`, which is UI
    // chrome and was a third sheet of paper for one product.
    XCTAssertEqual(RemoteDrawPaperGround.base.red, 247)
    XCTAssertEqual(RemoteDrawPaperGround.base.green, 244)
    XCTAssertEqual(RemoteDrawPaperGround.base.blue, 237)
    // Faint on purpose, and never zero: a paper surface with no visible tooth
    // at all is the flat SDK ground this replaced.
    XCTAssertGreaterThan(RemoteDrawPaperGround.relief, 0)
    XCTAssertLessThanOrEqual(RemoteDrawPaperGround.relief, 4)
    // The finest octave stays clear of a pixel — the grain floor, restated in
    // the only terms it is actually about.
    let finest = RemoteDrawInkSurface.paperGrain * pow(RemoteDrawPaperGround.falloff, 3)
    XCTAssertGreaterThan(finest, 1.9)
  }

  // MARK: - Protocol surfaces map onto render surfaces

  func testEverySurfaceTheProtocolCarriesIsHandledExplicitly() {
    // Written out rather than derived, so a new protocol surface fails here
    // instead of quietly falling through to the default and rendering paper
    // under something that is not paper. Same table as surfaces.test.ts.
    let expected: [String: RemoteDrawInkSurface.Kind] = [
      "whiteboard": .whiteboard,
      "plain": .whiteboard,
      "paper": .paper,
      "map": .map,
      "canvas": .custom,
      "svg": .custom,
      "ai": .custom,
      "tldraw": .custom,
      "field": .custom,
      "image": .custom,
      "pdf": .custom,
      "screen": .custom,
      "custom": .custom,
    ]
    for (name, kind) in expected {
      XCTAssertEqual(RemoteDrawInkSurface.kind(forProtocolName: name), kind, "\(name) by name")
    }
    // The other half of this pin — that the app's own `RemoteDrawSurfaceKind`
    // canonicalises to the same axis — lives in the app's `SurfaceKindTests`,
    // because that enum is the app's and this bundle cannot see it. Splitting
    // it was the price of the renderer's table being internal; losing it was
    // not, so the app asserts the two agree for every protocol name.
  }

  func testSurfacesThatHostSomeoneElsesGroundGetNoPaperTooth() {
    for name in ["image", "pdf", "screen", "tldraw", "svg", "canvas", "field", "ai", "custom"] {
      let spec = RemoteDrawInkSurface.spec(RemoteDrawInkSurface.kind(forProtocolName: name))
      XCTAssertEqual(spec.ground, RemoteDrawInkSurface.Ground.none, "\(name) ground")
      XCTAssertNil(spec.grain, "\(name) grain")
      XCTAssertNil(spec.tooth, "\(name) tooth")
    }
  }

  func testAnUnknownSurfaceStillDrawsOnTheDefaultSheet() {
    XCTAssertEqual(RemoteDrawInkSurface.kind(forProtocolName: nil), .paper)
    XCTAssertEqual(RemoteDrawInkSurface.kind(forProtocolName: "moon-rock"), .paper)
    // An unknown kind survives canonicalisation with its text intact in the
    // app's enum; it still has to render something, and paper is the default
    // sheet. The app's `SurfaceKindTests` holds that half.
  }

  // MARK: - Tool policy

  func testEachSurfaceLeadsWithItsOwnDefaultAndForbidsNothing() {
    let defaults: [RemoteDrawInkSurface.Kind: DrawingStyleKind] = [
      .whiteboard: .whiteboardMarker,
      .paper: .pencil,
      .map: .ink,
      .custom: .ink,
    ]
    for kind in RemoteDrawInkSurface.Kind.allCases {
      let tools = RemoteDrawInkSurface.spec(kind).tools
      // Deliberate and load-bearing: strong defaults, and bans only on evidence
      // that a combination renders badly.
      XCTAssertEqual(tools.forbidden, [], "\(kind) forbids instruments")
      XCTAssertEqual(tools.order.first, tools.default, "\(kind) leads with its default")
      XCTAssertEqual(tools.default, defaults[kind], "\(kind) default instrument")
      XCTAssertEqual(Set(tools.order).count, tools.order.count, "\(kind) order repeats itself")
    }
  }

  func testNoInstrumentGoesMissingFromAPalette() {
    for kind in RemoteDrawInkSurface.Kind.allCases {
      let order = RemoteDrawInkSurface.toolOrder(kind)
      XCTAssertEqual(Set(order).count, order.count, "\(kind) palette repeats itself")
      XCTAssertEqual(
        Set(order), Set(DrawingStyleKind.allCases),
        "\(kind) palette drops or invents an instrument"
      )
      XCTAssertEqual(order.first, RemoteDrawInkSurface.spec(kind).tools.default)
    }
  }
}
