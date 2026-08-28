import SwiftUI

/// Announces each tooth field as it finishes rasterising.
///
/// `RemoteDrawInk.toothImage` returns nil until its field is built, so a view
/// that drew a dry-media stroke early painted it unmasked. Observing this makes
/// that view redraw once the field exists, and the mark picks up its tooth.
@MainActor
final class ToothFieldCache: ObservableObject {
  static let shared = ToothFieldCache()

  @Published private(set) var revision = 0

  private init() {}

  fileprivate func fieldDidLand() {
    revision &+= 1
  }
}

/// Per-instrument constants, mirroring `freehandStyleProfile` on the web
/// (packages/client/src/inkGeometry.ts). Every native surface that resolves a
/// `DrawingStyle` reads them from here so the board, the web sender bridge,
/// and the receiver agree on what each instrument looks like.
enum RemoteDrawInk {
  /// Dry-media grain. Fractions are relative to the local stroke width.
  struct Grain {
    let streaks: Int
    let spread: Double
    let wander: Double
    let wanderRate: Int
    let streakWidth: ClosedRange<Double>
    let alpha: ClosedRange<Double>
    let bodyWidth: Double
    let bodyAlpha: Double
    /// Dry skips; nil for media that deposit continuously, like graphite.
    let dashOn: ClosedRange<Double>?
    let dashOff: ClosedRange<Double>?
  }

  /// Broad-edge nib: width follows stroke direction against a fixed angle.
  struct Nib {
    let angleDegrees: Double
    let thin: Double
  }

  /// Tilt shading: laid over, the lead presents its flank. Stored as explicit
  /// upright/flat endpoints rather than ranges — alpha runs *downwards* as the
  /// stylus flattens, and a ClosedRange traps on a descending pair.
  struct Tilt {
    let widthUpright: Double
    let widthFlat: Double
    let alphaUpright: Double
    let alphaFlat: Double
  }

  struct Scatter {
    let density: Int
    let radius: Double
    let dotWidth: Double
  }

  /// Paper tooth, held in board coordinates rather than stroke coordinates.
  /// Mirrors `FreehandToothSpec` in packages/client/src/inkGeometry.ts.
  ///
  /// Dry media deposit on the paper's high points and skip its valleys. Because
  /// the valleys belong to the *paper*, strokes crossing the same patch miss the
  /// same valleys and bare paper survives the overlap. The deepest valleys must
  /// reject completely or dense hatching fills them in and goes solid.
  ///
  /// The spec itself belongs to the **surface**, not to the instrument: see
  /// `RemoteDrawInkSurface` below.
  ///
  /// Only `depth` reaches the native mask, which is rasterised from the paper's
  /// own height field (`rasterizeToothImage`). `scale` and `radius` size the
  /// cell lattice the web sender's SVG mask is cut from and are carried here
  /// unread, for parity — see `toothOctaves`.
  /// What an absorbent sheet does to a wet mark's *boundary*. Mirrors
  /// `FreehandEdgeSpec` in packages/client/src/inkGeometry.ts.
  ///
  /// The wet-media study's conclusion, and narrower than it sounds: what reads as
  /// ink on cartridge rather than ink on glass is the **edge**, not the body. A
  /// page-registered stencil through the body was measured and rejected — it
  /// reads as a dry felt pen running out, because a tooth mask is *subtractive*,
  /// removing ink where the sheet is low, whereas wet ink thins on the ridges and
  /// pools in the valleys. Wrong sign. So the tooth is not reached for here; the
  /// sheet's field appears only in the halo *outside* the mark, where "less ink"
  /// is what a fibre that did not wick actually looks like.
  ///
  /// The body is untouched by construction — see `StrokePainter.drawFreehandMark`,
  /// where the halo is built by clipping the blur to the *inverse* of the mark —
  /// so no absorbency setting can move a wet block's tone.
  struct Edge: Equatable {
    /// How far the ink wicks past the nib, as a Gaussian radius in page units.
    /// Page units rather than a fraction of the width, deliberately: how far a
    /// solvent creeps along a fibre is a property of paper and ink, not of how
    /// wide the nib was. So a thin mark feathers proportionally more, which is
    /// the mechanism rather than a defect.
    let feather: Double
    /// How deeply the sheet's own field modulates the halo, 0...1. The same field
    /// the tooth rides, so the ragged edge and the tooth are two readings of one
    /// sheet. Applied as `1 - bleed * (1 - h)`.
    let bleed: Double
  }

  struct Tooth: Equatable {
    let scale: Double
    let radius: Double
    let depth: Double
  }

  struct ToothCell {
    let x: Double
    let y: Double
    let r: Double
    let a: Double
  }

  struct ToothOctave {
    let period: Double
    let rotate: Double
    let cells: [ToothCell]
  }

  /// Octaves whose periods share no common factor, each rotated off-axis.
  /// Incommensurate periods alone still read as woven cloth because every
  /// octave otherwise sits on the same row-and-column grid.
  private static let toothOctaveSpecs:
    [(period: Double, count: Int, rotate: Double, scale: Double, weight: Double)] = [
      (53, 17, 0, 1, 1),
      (89, 23, 23, 1.3, 0.66),
      (149, 27, 47, 1.75, 0.42),
    ]

  private static let toothDropout = 0.86

  // The tooth specs that used to live here — one fine, one coarse, one
  // middling, bound per instrument — are gone. Paper is one surface, so
  // instruments differ only in whether they ride it: the single spec now lives
  // on the surface (`RemoteDrawInkSurface.paperTooth`) and reaches a profile
  // through `profile(for:surface:)`. Mirrors the same note in
  // packages/client/src/inkGeometry.ts.

  /// Deterministic through `InkRenderer.noise`, so the field matches the web
  /// renderer cell for cell.
  ///
  /// **Nothing reads this any more, on either platform, and nothing pins it.**
  ///
  /// It was the cell lattice the web sender's SVG `<mask>` was cut from
  /// (`freehandToothOctaves` -> `inkPaths.tsx`), carried here unread so the two
  /// could not drift apart. Both halves of that are now gone: the native mask
  /// moved to `RemoteDrawPaperGround.height` on 2026-08-15 and the web's mask
  /// followed on 2026-08-16, for the same reason — at the shipped `scale` this
  /// lattice's finest pitch is `53/17 * 0.55` = 1.7 page units, so wherever a
  /// page unit is about a device pixel it renders as per-pixel static rather
  /// than paper tooth. See `rasterizeToothImage`.
  ///
  /// This comment used to claim `InkToothParityTests` pinned it. **There is no
  /// such test and there never has been** — the name appears only in these two
  /// comments. That is worse than no comment: it is the sentence a future
  /// reader would trust precisely when deciding whether it is safe to change
  /// these numbers. No test is being added, because pinning dead constants on
  /// both sides only makes them harder to delete. Delete this, the web's
  /// `freehandToothOctaves`, and the three `tools/texture-study` scripts that
  /// still cut masks from it, together.
  static func toothOctaves(for tooth: Tooth) -> [ToothOctave] {
    toothOctaveSpecs.enumerated().map { index, octave in
      let seed = index * 31 + 1
      let pitch = (octave.period / Double(octave.count)) * tooth.scale
      var cells: [ToothCell] = []
      for row in 0..<octave.count {
        for col in 0..<octave.count {
          if InkRenderer.noise(col * 23 + 7, row * 29 + seed) > toothDropout { continue }
          let n1 = InkRenderer.noise(col * 3 + seed, row * 7 + 2)
          let n2 = InkRenderer.noise(col * 11 + 5, row * 13 + seed)
          let n3 = InkRenderer.noise(col * 17 + seed * 9, row * 19 + 4)
          cells.append(ToothCell(
            x: (Double(col) + n1 * 1.35 - 0.17) * pitch,
            y: (Double(row) + n2 * 1.35 - 0.17) * pitch,
            r: pitch * tooth.radius * octave.scale * (0.28 + n3 * 0.95),
            a: tooth.depth * octave.weight * (0.62 + n1 * 0.38)))
        }
      }
      return ToothOctave(period: octave.period * tooth.scale, rotate: octave.rotate, cells: cells)
    }
  }

  /// Everything that separates one instrument from another. Mirrors
  /// `freehandStyleProfile` in packages/client/src/inkGeometry.ts.
  struct Profile {
    var band: ClosedRange<Double>?
    var taper: InkRenderer.TaperProfile?
    var widthScale: CGFloat = 1
    var fallbackWidthScale: CGFloat = 1
    var opacity: Double = 1
    var flatNib = false
    var grain: Grain?
    /// Whether this instrument sits *in* the surface's tooth rather than on top
    /// of it. A property of the medium — graphite and charcoal do, a marker does
    /// not. Mirrors `ridesTooth` on the web's `FreehandStyleProfile`.
    var ridesTooth = false
    /// The surface's tooth, bound onto the profile by `profile(for:surface:)`.
    /// Present only when the instrument rides the tooth *and* the surface has
    /// one; a whiteboard leaves it nil however dry the instrument is.
    var tooth: Tooth?
    /// How much solvent this medium carries, 0...1 — the instrument's half of the
    /// absorbency question, against `RemoteDrawInkSurface.absorbency`.
    ///
    /// Exactly the split `ridesTooth` established: the sheet says how thirsty it
    /// is, the medium says how much liquid it offers, neither holds an opinion
    /// about the other. A dry medium is 0 by derivation rather than declaration
    /// (`wetness(of:)`), so the dry six carry no new number.
    ///
    /// 1 unless stated. Three instruments state otherwise, each for a reason
    /// about the medium rather than about the board. Mirrors `wetness` on the
    /// web's `FreehandStyleProfile`.
    var wetness: Double = 1
    /// What an absorbent sheet does to this mark's boundary, bound on by
    /// `profile(for:surface:)`. The wet mirror of `tooth`: present only when the
    /// medium carries solvent *and* the surface takes it in, and absent on a
    /// whiteboard however wet the instrument is.
    var edge: Edge?
    /// How much of the paper's ceiling **one pass** of this instrument takes,
    /// as a multiplier on the stroke's colour alpha.
    ///
    /// The board renders dry media through a dab engine whose per-pixel law is
    /// `capacity(h) * (1 - transmittance)`. One pass takes `1 - transmittance`
    /// of that ceiling: measured through the shipped `freehandDabStream` and
    /// `depositTake` over a stroke's core, 0.73 to 0.85 for the dry six. One
    /// pass of the native painter takes `streakCoverage` — the union of
    /// `grain.streaks + 1` overlapping passes — which is 0.984 to 0.9999,
    /// because nine to thirteen streaks at alpha 0.34 to 0.92 stacked on one
    /// pixel are opaque whatever the medium claims to be. So every dry
    /// instrument reached its ceiling in a single stroke, and the phone drew a
    /// shaded passage 30 to 80 grey levels darker than the board did
    /// (`tools/texture-study/senders.py`, sheet 13).
    ///
    /// The factor wanted is the one `s` solving
    ///
    ///     1 - ∏(1 - s·aᵢ)  =  the board's mean one-pass (1 - transmittance)
    ///
    /// over that instrument's own `aᵢ` — its grain streak alphas times its
    /// default opacity, which is the alpha the compositor actually receives.
    /// `tools/texture-study/_iostone.ts` computes both sides from the shipped
    /// TypeScript and prints the table; run it whenever `DEPOSIT_BY_KIND`, the
    /// grain specs or the default opacities move.
    ///
    /// **What ships is that equation solved against the painter's *measured*
    /// coverage rather than its modelled one, and the two differ by up to
    /// 2x.** The closed form assumes every streak covers every core pixel.
    /// None of them do: the streaks are seated right across the nib at `spread`
    /// of the local width while being only 0.14 to 0.48 of it wide, and four of
    /// the six are dashed, so a core pixel sees three or four of the stack
    /// rather than all ten. `s` is therefore solved against the rendered hatch
    /// — a secant on the block's mean grey against the board's own render of
    /// the same strokes, three steps, every instrument landing within 0.5 of
    /// 255 grey levels. Closed form -> shipped, and the ratio between them is
    /// how much of the streak stack really reaches a core pixel:
    ///
    ///     pencil      0.404 -> 0.619   (1.53x)
    ///     tiltPencil  0.408 -> 0.491   (1.20x)
    ///     chalk       0.241 -> 0.513   (2.13x)
    ///     charcoal    0.201 -> 0.367   (1.82x)
    ///     crayon      0.357 -> 0.462   (1.29x)
    ///     dryBrush    0.310 -> 0.658   (2.12x)
    ///
    /// Crayon and the tilted pencil are closest because they stack fat or dense
    /// streaks over a narrow spread and really are nearly opaque at the core;
    /// dry brush is farthest because it is the one instrument that is mostly
    /// *skip* — a 0.72-width body at alpha 0.6 under dashes that are off for up
    /// to 0.8 of a nominal width. The model missed each of them in the
    /// direction its own grain spec predicts, which is what makes the residual
    /// a measurement rather than a fudge.
    ///
    /// This is a *tone* factor and never was a ceiling. Until 2026-08-16 the
    /// painter had no ceiling at all — N passes reached
    /// `1 - (1 - coverage·mask)ᴺ`, so a passage worked over enough times went to
    /// solid black (grey 23.7 at 32 passes against the board's 122.3) where the
    /// board settles on `capacity(h)`. `Profile.capacity` and
    /// `StrokePainter.withCapacity` are that ceiling now.
    ///
    /// **The six factors above were re-derived when it landed, by the same
    /// secant on the rendered block.** They had to grow, because two things that
    /// cost tone arrived together: the group ceiling itself (mean ~0.5 on this
    /// paper) and `RemoteDrawInkSurface.paperTooth.depth` coming down from 1 to
    /// 0.51, full depth having been that missing ceiling in disguise. Two steps,
    /// all six inside 0.2 of 255 grey levels, and pencil and dryBrush now sit
    /// just above 1 — which is fine and is pinned as such: what must not happen
    /// is `opacity * toneScale` reaching 1, where SwiftUI's alpha clamp bites and
    /// the factor silently stops responding. `inkSwiftParity.test.ts` holds that
    /// margin.
    ///
    /// 1 for every instrument that is not a dry medium on a toothed surface,
    /// where there is no ceiling to approach and nothing to be measured against.
    var toneScale: Double = 1
    /// The per-pixel ceiling a *group* of this instrument's strokes converges
    /// on, bound by `profile(for:surface:)` alongside the tooth. Nil wherever
    /// the tooth is nil: no paper to fill, nothing to be capped by.
    var capacity: Capacity?
    var nib: Nib?
    var tilt: Tilt?
    var glow: (width: CGFloat, opacity: Double)?
    var scatter: Scatter?
    var multiply = false
    var flatten = false
  }

  /// `capacity(h) = floor + gain * h` — how much pigment a spot of this paper
  /// can hold for this instrument, and the one thing that makes a shaded
  /// passage *stop*.
  ///
  /// Transcribed from `DEPOSIT_BY_KIND` in `packages/client/src/dabEngine.ts`,
  /// which is where they were fitted and where they belong; `capacityFloor` and
  /// `capacityGain` verbatim, nothing else from that table is read here.
  /// `RemoteDrawKitParityTests` pins the six pairs against the TypeScript.
  ///
  /// The board has always had these. The painter has not, and the gap is the
  /// whole defect: the board runs a passage to `capacity(h)` and holds there
  /// from about the sixteenth dab on, while every stroke this painter drew
  /// composited source-over into the page, so N passes reached `1 - (1 - a)ᴺ`
  /// and a worked block went to solid black — grey 23.7 at 32 passes against the
  /// board's 127.3, and a tooth-transfer slope 1.4 to 1.6x the board's on the
  /// soft media, which is the same defect seen as texture. See
  /// `StrokePainter.withCapacity` for where it is applied and why the *group*
  /// rather than the stroke is the unit.
  struct Capacity: Equatable {
    let floor: Double
    let gain: Double
  }

  /// Everything a *run* of marks composites as one film: its ceiling, and how
  /// the finished film sits on the page.
  ///
  /// Mirrors `FreehandFilmSpec` in `packages/client/src/dabEngine.ts`, and
  /// arrived for the same reason: the ceiling was the whole story while every
  /// film was a dry medium's, and it stopped being the whole story at the
  /// highlighter.
  ///
  /// **Source-over is already bounded, which is why eleven of the twelve wet
  /// instruments never needed a capacity.** `1 - ∏(1 - aᵢ)` climbs to 1, and
  /// alpha 1 of an ink colour *is* that ink colour, so an airbrush or a
  /// ballpoint worked over enough times converges on its own pigment and stops.
  /// Dry media needed a ceiling because the board's is `capacity(h) < 1` — paper
  /// valleys that never fill — and wet ink has no valleys.
  ///
  /// **`multiply` is the exception and it was doubly wrong here.** Applied per
  /// stroke it compounds: on the web, N highlighter passes reached `rgb(116, 10,
  /// 1)` at 32 — a yellow marker gone to black. On *this* renderer it did not
  /// compound, and that was worse rather than better: measured through `inkshot`,
  /// `drawLayer { layer.blendMode = .multiply }` never touched the page at all.
  /// A layer's `blendMode` governs what is drawn *into* that layer, whose
  /// backdrop is empty, and the finished layer then composites into its parent
  /// under the *parent's* blend mode — so the shipped highlighter was plain
  /// source-over, and a highlighter drawn over ink hid the ink instead of
  /// tinting it. Rendered against a red channel that a multiply must pull down
  /// and source-over cannot: 247 at every pass count, unchanged.
  ///
  /// Both fixes are the same move — the blend belongs to the run — and the
  /// ceiling needs no constant, because a film of dye cannot be more than fully
  /// dyed. `RemoteDrawStrokePainter.withFilm` sets it on the context that
  /// composites the run's layer, which is the placement `hlnative.swift`
  /// measured as the only one that reaches the page.
  struct Film: Equatable {
    let capacity: Capacity?
    let multiply: Bool
  }

  /// The film a mark belongs to, or nil where the run needs no wrapper at all —
  /// no ceiling and no blend, which is every opaque wet instrument.
  static func film(
    for kind: DrawingStyleKind?,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind
  ) -> Film? {
    let profile = profile(for: kind, surface: surface)
    guard profile.capacity != nil || profile.multiply else { return nil }
    return Film(capacity: profile.capacity, multiply: profile.multiply)
  }

  /// The instrument's ceiling, or nil for anything that is not a dry medium.
  /// Bound onto the profile only when the surface supplies a tooth.
  static func capacity(for kind: DrawingStyleKind?) -> Capacity? {
    switch kind {
    case .pencil: return Capacity(floor: 0.208, gain: 0.621)
    case .tiltPencil: return Capacity(floor: 0.136, gain: 0.612)
    case .chalk: return Capacity(floor: 0.315, gain: 0.519)
    case .charcoal: return Capacity(floor: 0.391, gain: 0.442)
    case .crayon: return Capacity(floor: 0.344, gain: 0.468)
    case .dryBrush: return Capacity(floor: 0.247, gain: 0.544)
    default: return nil
    }
  }

  static let chalkGrain = Grain(
    streaks: 13, spread: 0.94, wander: 0.13, wanderRate: 2,
    streakWidth: 0.14...0.3, alpha: 0.44...0.86,
    bodyWidth: 0.96, bodyAlpha: 0.88,
    dashOn: 0.9...3.4, dashOff: 0.05...0.22
  )
  static let pencilGrain = Grain(
    streaks: 9, spread: 0.8, wander: 0.07, wanderRate: 3,
    streakWidth: 0.16...0.32, alpha: 0.42...0.8,
    bodyWidth: 0.94, bodyAlpha: 0.92,
    dashOn: nil, dashOff: nil
  )
  static let charcoalGrain = Grain(
    streaks: 11, spread: 1, wander: 0.2, wanderRate: 2,
    streakWidth: 0.18...0.36, alpha: 0.5...0.9,
    bodyWidth: 0.96, bodyAlpha: 0.9,
    dashOn: 1.2...4.2, dashOff: 0.05...0.24
  )
  static let crayonGrain = Grain(
    streaks: 7, spread: 0.78, wander: 0.16, wanderRate: 4,
    streakWidth: 0.26...0.48, alpha: 0.5...0.84,
    bodyWidth: 0.98, bodyAlpha: 0.9,
    dashOn: 2.2...6.4, dashOff: 0.08...0.26
  )
  static let dryBrushGrain = Grain(
    streaks: 9, spread: 0.92, wander: 0.1, wanderRate: 2,
    streakWidth: 0.16...0.34, alpha: 0.5...0.9,
    bodyWidth: 0.72, bodyAlpha: 0.6,
    dashOn: 2.8...8, dashOff: 0.22...0.8
  )
  static let tiltPencilGrain = Grain(
    streaks: 11, spread: 0.86, wander: 0.08, wanderRate: 3,
    streakWidth: 0.14...0.28, alpha: 0.34...0.68,
    bodyWidth: 0.9, bodyAlpha: 0.82,
    dashOn: nil, dashOff: nil
  )

  /// The tooth field rasterised once per (surface, extent) and reused.
  ///
  /// Evaluating a height field per pixel per stroke per frame will not hold a
  /// drawing frame rate. The field is fixed to the board rather than to the
  /// stroke, so one image covers every mark on that board — and unlike the web
  /// renderer's tiled patterns there is no repeat at all, because the image
  /// spans the whole surface.
  ///
  /// Keyed on the **surface**, not on a `Tooth`: the sheet a mark bites is the
  /// board's, and its period (`Spec.grain`) and its depth (`Spec.tooth`) both
  /// come from the same row of `RemoteDrawInkSurface.spec`. A `Tooth` alone cannot
  /// say what paper it is.
  ///
  /// It still never rasterises on the calling thread. It used to run inline on
  /// the first textured stroke of a process, inside the `Canvas` draw closure,
  /// which froze the whole board: the queued touches all arrived at once when
  /// it finished, so the stroke that paid for it collapsed to a single dot and
  /// everything drawn during the freeze appeared in one go. Building happens on
  /// a background queue, the mask is simply skipped until the field lands, and
  /// `ToothFieldCache.shared` publishes its arrival so the board redraws with
  /// it. The build is much cheaper than the cell lattice it replaced — one
  /// height sample per pixel instead of millions of overscanned `fillEllipse`
  /// calls, ~0.1s against ~0.4s at a 360-point extent — but "cheaper" is not
  /// "free", and at a phone's extent it is still hundreds of milliseconds.
  private static let toothLock = NSLock()
  private static var toothImages: [String: CGImage] = [:]
  /// Keys whose rasterisation is in flight — or has permanently failed, which
  /// is the same thing as far as "do not start another one" is concerned.
  private static var toothBuildsStarted: Set<String> = []
  private static let toothQueue = DispatchQueue(
    label: "com.remotedraw.ios.tooth-field", qos: .userInitiated)

  private static func toothKey(_ surface: RemoteDrawInkSurface.Kind, _ extent: CGFloat) -> String {
    "\(surface.rawValue)-\(Int(extent.rounded()))"
  }

  /// The cached field, or nil while one is still being rasterised. Never
  /// rasterises on the calling thread — callers paint unmasked until it lands.
  /// Nil forever on a surface with no tooth.
  static func toothImage(for surface: RemoteDrawInkSurface.Kind, extent: CGFloat) -> CGImage? {
    guard RemoteDrawInkSurface.tooth(surface) != nil else { return nil }
    let key = toothKey(surface, extent)
    toothLock.lock()
    let cached = toothImages[key]
    let alreadyStarted = cached != nil || !toothBuildsStarted.insert(key).inserted
    toothLock.unlock()
    if let cached { return cached }
    guard !alreadyStarted else { return nil }
    toothQueue.async { buildToothImage(for: surface, extent: extent, key: key) }
    return nil
  }

  /// Starts the rasterisation ahead of the first stroke that needs it, so the
  /// board is never the thing waiting on it.
  static func prepareToothImage(for surface: RemoteDrawInkSurface.Kind, extent: CGFloat) {
    _ = toothImage(for: surface, extent: extent)
  }

  private static func buildToothImage(
    for surface: RemoteDrawInkSurface.Kind, extent: CGFloat, key: String
  ) {
    RDTrace.mark(
      RDLog.render,
      "tooth field build started key=\(key) extent=\(Int(extent.rounded()))")
    let (image, milliseconds) = RDTrace.measure {
      rasterizeToothImage(for: surface, extent: extent)
    }
    if let image {
      toothLock.lock()
      toothImages[key] = image
      toothLock.unlock()
    }
    // A failed build keeps its key in `toothBuildsStarted`: the failure is a
    // context allocation, which retrying every frame would not fix.
    RDTrace.mark(
      RDLog.render,
      String(
        format: "tooth field build %@ key=%@ in %.0fms",
        image == nil ? "FAILED" : "ready", key, milliseconds))
    guard image != nil else { return }
    Task { @MainActor in ToothFieldCache.shared.fieldDidLand() }
  }

  /// The mask is **the paper's own height field**, carried in the image's
  /// **alpha** channel.
  ///
  /// Two bugs lived here, and the phone showed both at once: pencil strokes
  /// that read as marker — solid dark cores, clean edges, no tooth whatever —
  /// on a board whose ground was already correct warm cartridge paper.
  ///
  /// 1. *The mask did nothing at all.* The field was an opaque `DeviceGray`
  ///    bitmap, white passing and black rejecting, which is a fine mask for
  ///    `CGContext.clip(to:mask:)` and a complete no-op for the only thing that
  ///    consumes it: both call sites paint through
  ///    `GraphicsContext.clipToLayer`, which clips by the **alpha** of what the
  ///    mask closure draws, and `CGImageAlphaInfo.none` is alpha 1 everywhere.
  ///    Every valley passed at full strength, so the mask cost a transparency
  ///    layer per stroke and changed not one pixel — on iOS or on macOS, since
  ///    the day it was written.
  /// 2. *It was the wrong sheet.* Fixing (1) alone produced tooth, but per-pixel
  ///    salt-and-pepper static rather than paper: `toothOctaves`' finest lattice
  ///    pitch is `53/17 * 0.55` = 1.7 page units, and at one page unit per pixel
  ///    a 1.7-pixel feature aliases. It is the same failure the grain floor of
  ///    11 exists to prevent on the ground.
  ///
  /// So the mask now samples `RemoteDrawPaperGround.height` — the transcription
  /// of the web's `paperHeight` that already paints the ground, at the same
  /// grain, at pixel centres, one page unit to one pixel. The sheet a mark bites
  /// is now literally the sheet under it, and the board's dab engine samples
  /// that same field: one paper, three renderers.
  ///
  /// **The image is the raw height field, and `Tooth.depth` is applied by the
  /// caller rather than baked in here.** It used to carry
  /// `1 - depth * (1 - height)` directly, which was fine while the mask was the
  /// field's only consumer. It is not any more: `capacity(h) = floor + gain * h`
  /// masks a whole *group* of strokes (`StrokePainter.withCapacity`), and there
  /// is no way to recover `h` from a pre-flattened field without an affine whose
  /// floor goes negative — at the shipped charcoal constants it wants -0.034.
  /// So the raster is the sheet itself and each consumer composites its own
  /// ramp over it, which is exactly what the web's `<mask>` pair does with the
  /// same tile. One raster, two ramps, and no second field to keep in register.
  ///
  /// `Tooth.scale` and `Tooth.radius` describe the web's dead cell lattice and
  /// are not read here.
  private static func rasterizeToothImage(
    for surface: RemoteDrawInkSurface.Kind, extent: CGFloat
  ) -> CGImage? {
    let spec = RemoteDrawInkSurface.spec(surface)
    guard let grain = spec.grain, spec.tooth != nil else { return nil }
    let side = Int(max(1, extent.rounded()))
    // Context-owned storage rather than a Swift array: `makeImage` is free to
    // share a bitmap context's buffer copy-on-write, and a buffer that dies
    // with the local array is not one to hand it.
    guard let context = CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side,
      space: CGColorSpaceCreateDeviceGray(),
      bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue),
      let base = context.data
    else { return nil }
    let rowBytes = context.bytesPerRow
    let pixels = base.bindMemory(to: UInt8.self, capacity: rowBytes * side)
    for y in 0..<side {
      for x in 0..<side {
        // Pixel centres, so the mask samples the field where the ground tile
        // does — a mark's valleys and the sheet's are the same valleys.
        let height = RemoteDrawPaperGround.height(
          Double(x) + 0.5, Double(y) + 0.5, grain: grain)
        // Opaque is a ridge, transparent is a valley floor. How much of that
        // range a given consumer actually uses is the consumer's ramp: the
        // stroke mask spans `Tooth.depth` of it, the group's ceiling spans
        // `capacityGain` of it over a floor of `capacityFloor`.
        pixels[y * rowBytes + x] = UInt8(min(255, max(0, (height * 255).rounded())))
      }
    }
    return context.makeImage()
  }

  /// Scatter marks are capped per stroke; a 500-point stroke at full density
  /// would otherwise emit thousands of dots per frame.
  static let maxScatterMarks = 1400

  /// The nib a scatter spec's `density` is stated at, in resolved surface units.
  ///
  /// 9.6 — the airbrush at the nominal 6-unit nib through its `widthScale` of 1.6
  /// — so the shipped instrument at the shipped weight lays exactly the dust it
  /// always did and only the ends of the width slider move. Transcribed from
  /// `SCATTER_REFERENCE_WIDTH` in `packages/client/src/inkGeometry.ts`, pinned by
  /// `inkSwiftParity.test.ts`.
  static let scatterReferenceWidth: CGFloat = 9.6

  /// An instrument as it behaves *on a surface*.
  ///
  /// `instrumentProfile` below is the instrument half. This is where the surface
  /// gets its say, which today is one thing: the paper tooth. An instrument
  /// declares `ridesTooth` — a fact about graphite and charcoal and chalk — and
  /// the surface supplies the sheet, so a pencil and a stick of charcoal on the
  /// same board finally bite into the same paper. On a surface with no tooth (a
  /// whiteboard, a map) they get no mask at all rather than a borrowed one.
  ///
  /// Mirrors `freehandStyleProfile` in packages/client/src/inkGeometry.ts, down
  /// to the default: callers that only want a width or an opacity need not know
  /// what the board is made of.
  static func profile(
    for kind: DrawingStyleKind?,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind
  ) -> Profile {
    var profile = instrumentProfile(for: kind)
    if profile.ridesTooth {
      guard let tooth = RemoteDrawInkSurface.tooth(surface) else { return profile }
      profile.tooth = tooth
      // The ceiling rides with the tooth, for the same reason the tone gain does:
      // a dry medium on a surface with no paper has no capacity to approach.
      profile.capacity = capacity(for: kind)
      return profile
    }
    // The wet half of the same question, and the same shape: the medium declares
    // how much solvent it carries, the surface how much of it the sheet takes in,
    // and only the product is a render decision. A marker on a whiteboard
    // multiplies out to nil and paints exactly what it always did — glossy and
    // even, which is correct and stays.
    guard let edge = edge(wetness: wetness(of: profile), surface: surface) else {
      return profile
    }
    profile.edge = edge
    // An absorbent sheet pulls ink out of the nib faster than the hand lifts it,
    // so the exit runs dry. Done in the taper rather than in the halo on purpose:
    // the halo leaves the mark's own silhouette untouched by construction, which
    // is what makes it tone-safe, and that same property means it can never make
    // a lift *fail*. Dry-out is geometry.
    if let taper = profile.taper {
      profile.taper = InkRenderer.dryOutExit(taper, edge: edge)
    }
    return profile
  }

  /// How much solvent a medium carries, 0...1.
  ///
  /// Derived for dry media rather than declared: `ridesTooth` already says "this
  /// is a stick of something", and a second flag saying "and therefore not wet"
  /// would be two spellings of one fact, free to disagree. Mirrors
  /// `instrumentWetness`.
  static func wetness(of profile: Profile) -> Double {
    profile.ridesTooth ? 0 : min(1, max(0, profile.wetness))
  }

  /// How far ink wicks past the nib on a fully absorbent sheet, as a Gaussian
  /// radius in page units.
  ///
  /// Chosen on the render rather than derived, because this renderer has no
  /// consistent physical scale to derive it from — the sheet's grain of 11 page
  /// units is already cartridge tooth at an unstated magnification, so a
  /// millimetre figure for the feather could not agree with it. Swept and looked
  /// at on sheet 17: 0.33 is indistinguishable from crisp at 1:1, 1.10 reads as
  /// soft focus and flattens the italic nib's hatch block, 0.55 is an edge.
  /// `inkGeometry.ts` carries the working. Mirrors `EDGE_FEATHER`.
  static let edgeFeather: Double = 1

  /// How deeply the sheet's field modulates the halo on a fully absorbent sheet.
  /// 1 — the surface's `absorbency` is the whole of it, and there is nothing for
  /// a second taste constant to trade against, because a halo outside the mark
  /// cannot change the mark's tone. Mirrors `EDGE_BLEED`.
  static let edgeBleed: Double = 1

  /// The edge treatment for a given wetness on a given surface, or nil. Mirrors
  /// `freehandEdgeFor`.
  static func edge(wetness: Double, surface: RemoteDrawInkSurface.Kind) -> Edge? {
    let wet = wetness * RemoteDrawInkSurface.absorbency(surface)
    guard wet > 0 else { return nil }
    return Edge(feather: edgeFeather * wet, bleed: edgeBleed * wet)
  }

  /// What an absorbent surface does to this instrument's boundary, or nil.
  /// Mirrors `freehandEdge`.
  static func edge(
    for kind: DrawingStyleKind?,
    surface: RemoteDrawInkSurface.Kind = RemoteDrawInkSurface.defaultKind
  ) -> Edge? {
    edge(wetness: wetness(of: instrumentProfile(for: kind)), surface: surface)
  }

  private static func instrumentProfile(for kind: DrawingStyleKind?) -> Profile {
    switch kind {
    case .ink:
      return Profile(
        band: 0.58...1.14, taper: InkRenderer.inkTaper, widthScale: 0.78)
    case .brushPen:
      return Profile(
        band: 0.34...1.44, taper: InkRenderer.brushTaper, widthScale: 1.18)
    case .fineliner:
      return Profile(band: nil, taper: nil, widthScale: 0.62)
    case .ballpoint:
      // An oil-based paste, not a solvent ink: a biro on blotting paper still
      // draws a hard line, which is most of why it is the pen that survives
      // being used on anything. Not zero — the ball does leave a faintly furred
      // edge on a rough sheet.
      return Profile(
        band: 0.84...1.06, taper: InkRenderer.bluntTaper, widthScale: 0.66,
        opacity: 0.9, wetness: 0.25)
    case .pencil:
      return Profile(
        band: 0.72...1.12, taper: InkRenderer.bluntTaper, widthScale: 0.92,
        opacity: 0.64, grain: pencilGrain, ridesTooth: true,
        toneScale: 1.0353)
    case .chalk:
      return Profile(
        band: nil, taper: nil, fallbackWidthScale: 1.12, opacity: 0.6,
        flatNib: true, grain: chalkGrain, ridesTooth: true,
        toneScale: 0.7269)
    case .charcoal:
      return Profile(
        band: nil, taper: nil, widthScale: 1.26, fallbackWidthScale: 1.12,
        opacity: 0.7, flatNib: true, grain: charcoalGrain, ridesTooth: true,
        toneScale: 0.4956)
    case .crayon:
      return Profile(
        band: nil, taper: nil, widthScale: 1.12, fallbackWidthScale: 1.12,
        opacity: 0.62, flatNib: true, grain: crayonGrain, ridesTooth: true,
        toneScale: 0.6386)
    case .dryBrush:
      return Profile(
        band: 0.4...1.3, taper: InkRenderer.brushTaper, widthScale: 1.1,
        opacity: 0.62, flatNib: true, grain: dryBrushGrain, ridesTooth: true,
        toneScale: 1.0942)
    case .italicNib:
      return Profile(
        band: nil, taper: nil, nib: Nib(angleDegrees: 42, thin: 0.12))
    case .chiselMarker:
      return Profile(
        band: nil, taper: nil, widthScale: 1.3, flatNib: true,
        nib: Nib(angleDegrees: 35, thin: 0.34))
    case .tiltPencil:
      return Profile(
        band: nil, taper: nil, widthScale: 0.82, opacity: 0.52,
        grain: tiltPencilGrain, ridesTooth: true,
        toneScale: 0.8260,
        tilt: Tilt(widthUpright: 0.55, widthFlat: 2.2, alphaUpright: 1, alphaFlat: 0.72))
    case .highlighter:
      return Profile(
        band: nil, taper: nil, fallbackWidthScale: 2.2, opacity: 0.46,
        flatNib: true, multiply: true, flatten: true)
    case .airbrush:
      // Atomised before it lands, so there is no continuous wet boundary for a
      // fibre to draw ink along; the spray's own scatter radius is the soft edge.
      return Profile(
        band: nil, taper: nil, widthScale: 1.6, opacity: 0.5, wetness: 0,
        scatter: Scatter(density: 9, radius: 1.4, dotWidth: 0.125))
    case .neon:
      // Not a liquid arriving at a boundary: a synthetic glow whose whole look
      // is a wide soft halo already, and feathering a halo is feathering nothing.
      return Profile(
        band: InkRenderer.markerFactorRange, taper: InkRenderer.markerTaper,
        widthScale: 0.8, wetness: 0, glow: (width: 3.4, opacity: 0.16))
    case .whiteboardMarker, .none:
      return Profile(
        band: InkRenderer.markerFactorRange, taper: InkRenderer.markerTaper)
    }
  }
}

/// What the marks are made *on*.
///
/// A line-by-line mirror of `packages/client/src/surfaces.ts`; the two are meant
/// to be read side by side.
///
/// The paper used to belong to the instrument. `RemoteDrawInk` held three tooth
/// specs — fine, middling, coarse — and bound one per instrument, so a pencil
/// and a stick of charcoal on one board drew against two different sheets of
/// paper, which is not a thing that happens. The split is: the surface owns the
/// paper — its grain, its tooth, its ground — and an instrument owns only
/// whether it rides that paper (`RemoteDrawInk.Profile.ridesTooth`).
///
/// **Where this deliberately differs from the TypeScript.** iOS has no dab
/// engine: there is no deposit law here, so `depositScale` has nothing to act
/// on. It is carried anyway, unread, so the numbers cannot drift ahead of a
/// future port unnoticed — `SurfaceParityTests` pins it against the same values
/// `surfaces.test.ts` pins. `grain` *is* read, twice over:
/// `RemoteDrawPaperGround` below is a Swift transcription of `paperHeight`, so
/// the sheet the phone paints is the sheet the board paints, and
/// `RemoteDrawInk.rasterizeToothImage` masks the *mark* with that same field at
/// that same grain. What is still not here is the deposit law — a mark is
/// clipped by the paper rather than deposited into it, which is the renderer
/// divergence Phase 3 item 3 of the roadmap keeps, deliberately, on the most
/// performance-constrained device we ship to.
///
/// **`Kind` is public and the rest is not**, on purpose. `RemoteDrawKit` ships
/// this file, and `RemoteDrawStrokePainter.draw` has to be able to *say* which
/// surface a stroke is being drawn on — without that, every SDK stroke got the
/// graphite tooth whatever the board was made of. Naming a surface is the
/// caller's business; the table behind it is not.
public enum RemoteDrawInkSurface {
  /// What paints the surface behind the marks. Mirrors `GroundId`.
  enum Ground: String {
    case whiteboard
    case paper
    case none
  }

  /// The renderer's own axis: which ground, which tooth, which instruments.
  ///
  /// Deliberately **not** `RemoteDrawSurfaceKind` (Models.swift) and
  /// deliberately not named the same. That enum is the protocol's — `svg`,
  /// `image`, `pdf`, `screen`, `tldraw` — and describes how a board is
  /// *sourced*; several of its members are the same sheet as far as the ink is
  /// concerned. This axis is lossy on purpose.
  /// `RemoteDrawSurfaceKind.drawingSurface` maps one onto the other, so protocol
  /// names stay out of the render path. Mirrors `DrawingSurfaceKind`.
  public enum Kind: String, CaseIterable {
    case whiteboard
    case paper
    case map
    case custom
  }

  /// How a surface bends an instrument's deposit constants. Multipliers.
  /// Nothing on iOS reads these yet — see the note on the enum.
  struct DepositScale: Equatable {
    var rate: Double?
    var capacityFloor: Double?
  }

  /// The instrument palette a surface leads with.
  ///
  /// `order` names only the instruments this surface puts first; everything else
  /// follows in `DrawingStyleKind.allCases` order (see `toolOrder`), so adding
  /// an instrument to the protocol never silently hides it.
  ///
  /// `forbidden` is empty on every surface, on purpose: strong defaults rather
  /// than prohibitions. A pencil sketch on a whiteboard is a plausible thing to
  /// want, and banning it buys nothing but support burden. The field exists so
  /// that a combination which genuinely renders badly can be removed on
  /// evidence, not on taste.
  struct Tools {
    var order: [DrawingStyleKind]
    var `default`: DrawingStyleKind
    var forbidden: [DrawingStyleKind] = []
  }

  struct Spec {
    var ground: Ground
    /// Paper period in page units — the coarseness of the tooth every instrument
    /// on this surface rides. `nil` is a surface with no tooth at all. The web
    /// holds a hard floor at 11 (below it the finest octave drops under a pixel
    /// and the render turns to digital static); nothing here samples it yet.
    var grain: Double?
    /// The mask for the same sheet; `nil` wherever `grain` is nil.
    var tooth: RemoteDrawInk.Tooth?
    /// How thirsty the sheet is: how much of a wet mark's solvent the substrate
    /// takes in. `0` absorbs nothing.
    ///
    /// The third paper property, here for the reason the other two are: paper
    /// absorbs, a whiteboard cannot, and a map tile or an SDK host's screenshot
    /// is not a substrate we are entitled to an opinion about. On the instrument
    /// it would be sixteen beliefs about what they are drawn on, which is the
    /// state the tooth was in before it moved onto the sheet.
    ///
    /// The scale runs glass `0` to blotting paper `1`; the wet-edge constants in
    /// `RemoteDrawInk` are calibrated at `1`. Mirrors `DrawingSurface.absorbency`
    /// and is required, not optional, so a new surface has to answer.
    var absorbency: Double
    var depositScale: DepositScale?
    var tools: Tools
  }

  /// Tooth octave weights for the mask. One sheet, so one spec — the fine and
  /// coarse variants that used to be bound per instrument are gone. Mirrors
  /// `PAPER_TOOTH`, including `depth`, which read 1 until 2026-08-16.
  ///
  /// **1 was the ceiling wearing the tooth's clothes.** A full-depth mask means
  /// the deepest valleys reject outright, and that was load-bearing only because
  /// nothing else kept a worked passage off black. With `Profile.capacity` in
  /// place the mask can go back to describing what it is — how far the nib
  /// reaches down the valley wall — and the board says that in `depositStep`'s
  /// `bite` term, which over `paperHeight`'s own decile means at the middle of
  /// the reach band asks for 0.647 / 0.574 / 0.451 / 0.419 / 0.380 / 0.597
  /// across the dry six. 0.51 is their mean. `surfaces.ts` carries the working.
  static let paperTooth = RemoteDrawInk.Tooth(scale: 0.55, radius: 0.275, depth: 0.51)

  /// Cartridge paper, the sheet every dry instrument now works.
  ///
  /// One sheet rather than the per-instrument 13-20 it replaces: those were not
  /// six measurements of six papers but one paper fitted six times, each
  /// against that instrument's own dab spacing. See `surfaces.ts` for the
  /// measurement and for why the descriptor cannot choose this number.
  ///
  /// 11 rather than the 16 it was until 2026-08-15, and the two are not
  /// comparable as they stand: the octave schedule under them moved in the same
  /// change (see `RemoteDrawPaperGround`). 16 bought headroom over the floor
  /// when the finest octave sat at `grain * 0.176`; at `grain * 0.216` it takes
  /// 11 to land the finest octave in the same place.
  static let paperGrain: Double = 11

  /// How much of a wet mark's solvent cartridge paper takes in.
  ///
  /// A judgement, and stated as one. The scale's ends are physical — glass at 0,
  /// blotting paper at 1 — and cartridge sits below the middle: it is sized,
  /// which is the whole point of cartridge over newsprint, so a fountain pen on
  /// it feathers visibly but does not bloom. `surfaces.ts` carries the sweep.
  static let paperAbsorbency: Double = 0.55

  /// The surfaces a board can be drawn on. Mirrors `SURFACES`.
  static func spec(_ kind: Kind) -> Spec {
    switch kind {
    // A marker on a board is glossy and even: no tooth, and dry media are not
    // forbidden here — a pencil on a whiteboard just draws an even line, which
    // is what a pencil on a glossy surface does.
    case .whiteboard:
      return Spec(
        ground: .whiteboard,
        grain: nil,
        tooth: nil,
        // A melamine board takes in nothing: the solvent flashes off and the
        // pigment sits on the gloss, so a marker keeps its crisp even edge.
        absorbency: 0,
        // With no tooth every pixel takes pigment at full bite, so an instrument
        // fitted against paper lays down noticeably more here.
        depositScale: DepositScale(rate: 0.85),
        tools: Tools(
          order: [.whiteboardMarker, .ink, .highlighter, .fineliner, .neon],
          default: .whiteboardMarker))
    case .paper:
      return Spec(
        ground: .paper,
        grain: paperGrain,
        tooth: paperTooth,
        absorbency: paperAbsorbency,
        depositScale: nil,
        tools: Tools(
          order: [
            .pencil, .ballpoint, .charcoal, .crayon, .chalk, .tiltPencil, .dryBrush, .ink,
          ],
          default: .pencil))
    // The map is the ground, and it is not paper — annotating a satellite tile
    // through a graphite tooth reads as a dirty screen. Marks sit on the glass.
    case .map:
      return Spec(
        ground: .none,
        grain: nil,
        tooth: nil,
        // Marks sit on the glass, and glass does not drink.
        absorbency: 0,
        depositScale: DepositScale(rate: 0.85),
        tools: Tools(
          order: [.ink, .whiteboardMarker, .highlighter, .fineliner],
          default: .ink))
    // The SDK story: the developer renders their own ground — a card, an app
    // screenshot, a photo — so we cannot claim to know what the marks are biting
    // into, and inventing a paper tooth over someone's screenshot is worse than
    // having none.
    case .custom:
      return Spec(
        ground: .none,
        grain: nil,
        tooth: nil,
        // The developer's ground, so not ours to characterise.
        absorbency: 0,
        depositScale: DepositScale(rate: 0.85),
        tools: Tools(
          order: [.ink, .whiteboardMarker, .highlighter, .pencil],
          default: .ink))
    }
  }

  /// The surface a board renders on when nothing has said otherwise.
  ///
  /// Paper, because that is what every dry mark in the product has always been
  /// drawn against — this refactor unifies the sheet, it does not swap it.
  /// Mirrors `DEFAULT_SURFACE_KIND`.
  public static let defaultKind: Kind = .paper

  /// The paper period this surface's instruments ride; nil for no tooth.
  static func grain(_ kind: Kind = defaultKind) -> Double? {
    spec(kind).grain
  }

  /// The mask spec for this surface's paper; nil for no tooth.
  static func tooth(_ kind: Kind = defaultKind) -> RemoteDrawInk.Tooth? {
    spec(kind).tooth
  }

  /// How much of a wet mark's solvent this surface takes in; `0` for a substrate
  /// that absorbs nothing. Mirrors `surfaceAbsorbency`.
  ///
  /// The surface's half of the wet-edge question; the instrument's half is
  /// `RemoteDrawInk.Profile.wetness`, and `RemoteDrawInk.profile(for:surface:)`
  /// multiplies the two — the same shape as `ridesTooth` against `tooth`.
  static func absorbency(_ kind: Kind = defaultKind) -> Double {
    spec(kind).absorbency
  }

  /// The full instrument palette for a surface: its own order first, then every
  /// remaining instrument in protocol order, minus anything it forbids. Mirrors
  /// `surfaceToolOrder`.
  static func toolOrder(_ kind: Kind = defaultKind) -> [DrawingStyleKind] {
    let tools = spec(kind).tools
    let forbidden = Set(tools.forbidden)
    let led = tools.order.filter { !forbidden.contains($0) }
    let seen = Set(led)
    return led + DrawingStyleKind.allCases.filter {
      !seen.contains($0) && !forbidden.contains($0)
    }
  }

  /// A protocol surface name off the wire -> the renderer's own axis.
  ///
  /// Takes a raw string rather than `RemoteDrawSurfaceKind` for the same reason
  /// `drawingSurfaceKindFor` is typed against `string`: these names arrive from
  /// outside, and one we have never heard of resolves to the default rather than
  /// failing, because a board with an unfamiliar surface still has to draw. The
  /// app's mapping from the already-canonicalised enum is
  /// `RemoteDrawSurfaceKind.drawingSurface` in Models.swift, which is written
  /// out case by case so a new protocol surface cannot fall through here
  /// unnoticed.
  public static func kind(forProtocolName name: String?) -> Kind {
    switch name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    // `plain` is the protocol's deprecated name for a whiteboard.
    case "whiteboard", "plain":
      return .whiteboard
    case "paper":
      return .paper
    case "map":
      return .map
    // Every remaining protocol surface hands the ground to someone else: an
    // image, a PDF page, a screen capture, a tldraw canvas, an SDK host.
    case "canvas", "svg", "ai", "tldraw", "field", "image", "pdf", "screen", "custom":
      return .custom
    default:
      return defaultKind
    }
  }
}

/// The paper sheet itself — the tone an empty paper board is, before a mark.
///
/// A transcription of two web files that have to be read alongside it:
/// `paperHeight` in `packages/client/src/dabEngine.ts` (the height field) and
/// `packages/react/src/paperGround.ts` (the tone it is painted as). The hash
/// underneath is `InkRenderer.noise`, which is already byte-identical to the
/// web's `inkNoise`, so this is not a lookalike field: a given page coordinate
/// yields the same tooth here as it does in the board's shader.
///
/// **Why this exists at all.** Until 2026-08-15 the native pad painted a flat
/// `rgb(255,252,245)`, the SDK painted a flat `#f2ecdf`, and only the web board
/// had a sheet — three papers for one product, and the phone previewing none of
/// what the room could see. `DrawingBoardView.drawPaper` said so in a comment
/// and deferred, correctly, until the height field stopped moving. It has
/// stopped.
///
/// Deliberately *not* the deposit engine — a mark is clipped by the paper here
/// rather than deposited into it, which is the renderer divergence the roadmap
/// keeps. `height` is the shared part, and it is shared twice: this ground, and
/// the tooth mask the marks on it are cut by (`rasterizeToothImage`). Until
/// 2026-08-16 that mask was a separate cell lattice at a period the sheet never
/// had, which is why the phone's marks read as static and then, once the mask
/// stopped biting at all, as marker.
enum RemoteDrawPaperGround {
  /// Cartridge paper's base tone. Mirrors `PAPER_GROUND.base`.
  static let base: (red: Double, green: Double, blue: Double) = (247, 244, 237)

  /// How far a ridge and a valley pull apart, in 0-255. Mirrors
  /// `PAPER_GROUND.relief` — read the note there; it is a taste number that has
  /// come down twice, and an empty sheet should read as paper at a glance and
  /// show its tooth only to someone looking for it.
  static let relief: Double = 2

  /// The flat tone, for the frame before the raster lands and for anywhere a
  /// bitmap cannot go.
  static var color: Color {
    Color(red: base.red / 255, green: base.green / 255, blue: base.blue / 255)
  }

  /// The tooth's octave schedule. Mirrors the constants in `paperHeight`: four
  /// octaves, each 0.60 the period and 0.75 the amplitude of the one before, so
  /// the coarsest carries 37% of the field rather than the 54% that made a
  /// shaded passage read as a blob field.
  static let octaves = 4
  static let falloff = 0.6
  static let octaveGain = 0.75

  /// The paper's tooth at a page coordinate, 0 in a valley and 1 on a ridge.
  static func height(_ pageX: Double, _ pageY: Double, grain: Double?) -> Double {
    guard let grain, grain > 0 else { return 1 }
    let period = max(1, grain)
    var total = 0.0
    var weight = 0.0
    var scale = period
    var amplitude = 1.0
    for octave in 0..<octaves {
      // Rotated off-axis by an irrational-ish angle per octave so the octaves
      // never share a row-and-column grid and the field cannot read as woven.
      let angle = Double(octave) * 0.9553
      let c = cos(angle)
      let s = sin(angle)
      total += amplitude * valueNoise(
        (pageX * c - pageY * s) / scale, (pageX * s + pageY * c) / scale)
      weight += amplitude
      scale *= falloff
      amplitude *= octaveGain
    }
    let h = total / weight
    // Paper tooth is not Gaussian: broad flat ridges, narrow deep pits.
    return min(1, max(0, h * h * (3 - 2 * h)))
  }

  private static func valueNoise(_ x: Double, _ y: Double) -> Double {
    let xi = Int(floor(x))
    let yi = Int(floor(y))
    let xf = x - Double(xi)
    let yf = y - Double(yi)
    let u = xf * xf * (3 - 2 * xf)
    let v = yf * yf * (3 - 2 * yf)
    let n00 = InkRenderer.noise(xi, yi)
    let n10 = InkRenderer.noise(xi + 1, yi)
    let n01 = InkRenderer.noise(xi, yi + 1)
    let n11 = InkRenderer.noise(xi + 1, yi + 1)
    return n00 * (1 - u) * (1 - v) + n10 * u * (1 - v)
      + n01 * (1 - u) * v + n11 * u * v
  }

  /// The tile edge, in page units, which is also its edge in pixels.
  ///
  /// Tiled rather than rasterised at the surface's own size, which is what the
  /// tooth mask next door does: a phone surface is 2500 points on its long edge
  /// and evaluating four octaves of noise over 6 million pixels to paint a
  /// texture nobody is meant to notice is not a trade worth making. The field
  /// is not periodic, so a repeat is a seam in principle — at this size and at
  /// a relief of 2 it is not one on a screen.
  static let tileEdge = 512

  private static let lock = NSLock()
  private static var tiles: [String: CGImage] = [:]
  /// Keys whose rasterisation is in flight, or has permanently failed — the
  /// same thing as far as "do not start another one" is concerned.
  private static var buildsStarted: Set<String> = []
  private static let queue = DispatchQueue(
    label: "com.remotedraw.ios.paper-ground", qos: .userInitiated)

  /// The cached sheet, or nil while one is still being rasterised. Never
  /// rasterises on the calling thread: callers paint the flat tone until it
  /// lands, and `ToothFieldCache.shared` publishes the arrival so they redraw.
  static func tile(grain: Double?) -> CGImage? {
    guard let grain, grain > 0 else { return nil }
    let key = "\(grain)-\(relief)-\(tileEdge)"
    lock.lock()
    let cached = tiles[key]
    let alreadyStarted = cached != nil || !buildsStarted.insert(key).inserted
    lock.unlock()
    if let cached { return cached }
    guard !alreadyStarted else { return nil }
    queue.async { build(grain: grain, key: key) }
    return nil
  }

  /// Starts the rasterisation ahead of the first board that needs it.
  static func prepareTile(grain: Double?) {
    _ = tile(grain: grain)
  }

  private static func build(grain: Double, key: String) {
    let (image, milliseconds) = RDTrace.measure { rasterize(grain: grain) }
    if let image {
      lock.lock()
      tiles[key] = image
      lock.unlock()
    }
    RDTrace.mark(
      RDLog.render,
      String(
        format: "paper ground build %@ key=%@ in %.0fms",
        image == nil ? "FAILED" : "ready", key, milliseconds))
    guard image != nil else { return }
    Task { @MainActor in ToothFieldCache.shared.fieldDidLand() }
  }

  private static func rasterize(grain: Double) -> CGImage? {
    let side = tileEdge
    var bytes = [UInt8](repeating: 255, count: side * side * 4)
    for y in 0..<side {
      for x in 0..<side {
        // Pixel centres, so the tile samples the field where the web does.
        let tooth = height(Double(x) + 0.5, Double(y) + 0.5, grain: grain)
        // Ridges catch the light and valleys hold shadow, so the relief runs
        // both ways off the mid tone rather than only darkening.
        let lift = (tooth - 0.5) * 2 * relief
        let offset = (y * side + x) * 4
        bytes[offset] = channel(base.red + lift)
        bytes[offset + 1] = channel(base.green + lift)
        bytes[offset + 2] = channel(base.blue + lift)
      }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
    return CGImage(
      width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
      provider: provider, decode: nil, shouldInterpolate: false,
      intent: .defaultIntent)
  }

  private static func channel(_ value: Double) -> UInt8 {
    UInt8(min(255, max(0, value.rounded())))
  }
}

/// Stroke-rendering geometry for the native board, mirroring the web ink
/// spec (packages/client): curvature-aware sampling, Catmull-Rom smoothing,
/// and pressure/velocity width dynamics. Keep the constants in sync with
/// `shouldAppendStrokeSample` / `smoothPathFromPoints` on the web so a stroke
/// drawn on either sender renders identically everywhere.
enum InkRenderer {
  // Sampling thresholds in normalized surface units (0..1). Straight motion
  // is decimated aggressively; direction changes keep near samples so corners
  // and tight curves survive.
  //
  // One normalized unit is the surface width — ~250mm on a 12.9" iPad — so the
  // curve threshold is the finest detail the sampler can resolve: 0.3mm.
  private static let flatSampleDistance = 0.003
  private static let curveSampleDistance = 0.0012
  private static let curveTurnCos = cos(10.0 * Double.pi / 180)

  /// A pressure change large enough to keep a sample on its own.
  ///
  /// The geometric tests alone lost up to a third of the pressure range at
  /// stroke entry and exit: the nib ramps from nothing to full bite in ~40ms
  /// while barely moving, so every sample carrying that ramp failed both the
  /// distance and the turn test. Sits above sensor noise, and runs only after
  /// the minimum-distance rejection, so a resting hand cannot trip it.
  private static let pressureSampleDelta = 0.02

  // Width dynamics for the "ink" style. Pressure maps directly to width;
  // without pressure, speed stands in (faster finger -> thinner line).
  private static let pressureFactorRange = 0.4...1.4
  private static let velocityFactorRange = 0.6...1.15
  private static let velocityReference = 0.0068 // normalized units per ms
  private static let velocityEmaAlpha = 0.3
  private static let minimumHalfWidth: CGFloat = 0.5
  private static let capSegments = 8

  /// The default marker's band.
  ///
  /// Was 0.86...1.10 — 24.5% peak to peak, about 1.5px on a 6px nib over a
  /// whole stroke, which is the definition of "too subtle to see". The
  /// counter-argument is real and worth stating: **a felt marker gets lighter
  /// at speed, not narrower.** The nib is a rigid wedge; it does not flex.
  ///
  /// What *does* change width is the ink bead. A dry-erase nib at a crawl
  /// floods a wet footprint wider than the felt itself; dragged fast it lays
  /// down only the felt's own contact patch and the bead never forms. That is a
  /// bounded effect — a bead, not a brush — so the band is bounded with it:
  /// 0.72...1.12 is 44% peak to peak, half of what the brush pen does and a
  /// third of a calligraphic nib. Mirrors MARKER_FACTOR_RANGE on the web.
  static let markerFactorRange = 0.72...1.12
  /// Ink's band. Wider than the marker's so the line breathes, but centred
  /// just under 1 rather than swelling past it: a pen modulates, it does not
  /// bloat. Mirrors INK_FACTOR_RANGE on the web.
  static let inkFactorRange = 0.58...1.14

  /// One end of a ribbon: how far it thins, and over what distance. Mirrors
  /// the web's `FreehandTaperEnd`.
  struct TaperEnd {
    /// Ribbon tips start at this fraction of the local width.
    let tipFactor: Double
    /// Each taper covers this fraction of the stroke arc length, capped below.
    let arcFraction: Double
    /// Taper length cap, in multiples of the stroke width.
    ///
    /// How far a nib takes to seat is a property of the nib, not of the board,
    /// so this is the cap that keeps an instrument the same shape at every
    /// width. `maxSurfaceUnits` did not: it is absolute, so the marker's
    /// landing ran 3.7 nib widths at width 3 and 0.6 at width 24 — a needle at
    /// one end of the slider and a blunt stub at the other.
    let maxWidths: Double
    /// The absolute cap, in SURFACE_SIZE-relative units (1000 = full extent).
    /// Used only when the caller supplies no stroke width; `taperMultipliers`
    /// prefers `maxWidths` whenever it can.
    let maxSurfaceUnits: Double
  }

  /// How a ribbon's ends thin out. Mirrors the web's `FreehandTaperProfile`:
  /// tips ease `tipFactor` -> 1 over min(`arcFraction` of the arc length, the
  /// cap), and the two ends are separate because a nib does not land the way it
  /// leaves. A marker is placed and floods immediately, then is dragged off the
  /// board while still moving; a loaded brush lands wide and leaves as a hair.
  /// The profile was symmetric before, which made every instrument land exactly
  /// as tentatively as it lifted — and made the marker, the default instrument
  /// on the default surface, begin every stroke with a needle.
  struct TaperProfile {
    let tipFactor: Double
    let arcFraction: Double
    let maxWidths: Double
    let maxSurfaceUnits: Double
    /// How the mark leaves, when that differs from how it lands.
    var exit: TaperEnd?
  }

  /// How far the exit taper's tip thins, and how far its run-out stretches, on a
  /// fully absorbent sheet.
  ///
  /// Only the *exit*. A landing is the nib arriving loaded, which absorbency has
  /// nothing to say about; a lift is the nib leaving while the sheet is still
  /// drinking, which is the whole of what dry-out is. Mirrors `EXIT_DRYOUT` and
  /// `EXIT_STRETCH`.
  static let exitDryOut: Double = 0.7
  static let exitStretch: Double = 0.8

  /// The exit this taper leaves on an absorbent sheet. Mirrors `dryOutExit`.
  static func dryOutExit(
    _ taper: TaperProfile, edge: RemoteDrawInk.Edge
  ) -> TaperProfile {
    // Recovered from the spec rather than passed alongside it, so the two can
    // never be handed different absorbencies for one mark.
    let wet = min(1, max(0, edge.feather / RemoteDrawInk.edgeFeather))
    let exit =
      taper.exit
      ?? TaperEnd(
        tipFactor: taper.tipFactor, arcFraction: taper.arcFraction,
        maxWidths: taper.maxWidths, maxSurfaceUnits: taper.maxSurfaceUnits)
    var dried = taper
    dried.exit = TaperEnd(
      tipFactor: exit.tipFactor * (1 - exitDryOut * wet),
      arcFraction: exit.arcFraction * (1 + exitStretch * wet),
      maxWidths: exit.maxWidths * (1 + exitStretch * wet),
      maxSurfaceUnits: exit.maxSurfaceUnits * (1 + exitStretch * wet))
    return dried
  }

  /// The marker: lands hard, drags off.
  ///
  /// A dry-erase nib is a rigid felt wedge. It is placed on the board and
  /// floods at once — there is no flex to ramp up through — so the landing is
  /// barely a taper at all. The lift is the long end: the nib is pulled away
  /// while the hand is still moving, so the ink thins over a couple of nib
  /// widths.
  static let markerTaper = TaperProfile(
    tipFactor: 0.74,
    arcFraction: 0.06,
    maxWidths: 0.8,
    maxSurfaceUnits: 5,
    exit: TaperEnd(
      tipFactor: 0.44,
      arcFraction: 0.16,
      maxWidths: 2.6,
      maxSurfaceUnits: 12
    )
  )
  /// A pen leaves the paper in a hurry: a shorter lift than a marker's, to a
  /// finer point, because the tip that is running dry is a small one.
  static let inkTaper = TaperProfile(
    tipFactor: 0.58,
    arcFraction: 0.04,
    maxWidths: 1.1,
    maxSurfaceUnits: 4,
    exit: TaperEnd(
      tipFactor: 0.4,
      arcFraction: 0.07,
      maxWidths: 1.8,
      maxSurfaceUnits: 6
    )
  )
  /// A loaded brush lands wide and leaves as a hair — which is what this
  /// comment always said, and what the symmetric profile never did.
  static let brushTaper = TaperProfile(
    tipFactor: 0.34,
    arcFraction: 0.08,
    maxWidths: 2.2,
    maxSurfaceUnits: 12,
    exit: TaperEnd(
      tipFactor: 0.1,
      arcFraction: 0.22,
      maxWidths: 6.5,
      maxSurfaceUnits: 26
    )
  )
  /// Barely lifts at all — a ballpoint stops where it stops. Symmetric on
  /// purpose: it has no `exit`, so both ends use the same numbers.
  static let bluntTaper = TaperProfile(
    tipFactor: 0.62,
    arcFraction: 0.04,
    maxWidths: 1.5,
    maxSurfaceUnits: 3
  )

  /// Preview prediction: at most this many predicted samples are appended.
  /// Matches `MAX_PREDICTED_POINTS` in `packages/client/src/inkGeometry.ts`.
  static let maxPredictedPoints = 2

  /// Preview-only stroke assembly, shared with the web senders.
  ///
  /// A port of `previewPointsWithPrediction` in
  /// `packages/client/src/inkGeometry.ts`, cap and clamp included: at most
  /// `maxPredictedPoints` samples are appended, and each predicted step is
  /// limited to twice the last real segment so a wild prediction can never
  /// overshoot the finger. Both halves matter — the cap bounds how far ahead
  /// the ink can be wrong, the clamp bounds how badly.
  ///
  /// **Predicted points must NEVER be transmitted or committed.** Callers keep
  /// the source array for drafts and commits and hand the returned array to the
  /// renderer only; the same invariant `packages/client/src/pointerInput.ts`
  /// states for the web senders.
  static func previewPointsWithPrediction(
    _ points: [NormalizedPoint],
    predicted: [NormalizedPoint]
  ) -> [NormalizedPoint] {
    guard points.count >= 2, !predicted.isEmpty else { return points }
    let last = points[points.count - 1]
    let previous = points[points.count - 2]
    let lastSegment = hypot(last.x - previous.x, last.y - previous.y)
    guard lastSegment > 0 else { return points }
    var result = points
    var anchor = last
    for candidate in predicted.prefix(maxPredictedPoints) {
      guard candidate.x.isFinite, candidate.y.isFinite else { break }
      let dx = candidate.x - anchor.x
      let dy = candidate.y - anchor.y
      let distance = hypot(dx, dy)
      guard distance > 0 else { break }
      let limit = lastSegment * 2
      let scale = distance > limit ? limit / distance : 1
      let next = NormalizedPoint(
        x: anchor.x + dx * scale,
        y: anchor.y + dy * scale,
        t: candidate.t,
        pressure: candidate.pressure,
        tiltX: candidate.tiltX,
        tiltY: candidate.tiltY
      )
      result.append(next)
      anchor = next
    }
    return result
  }

  static func shouldAppendSample(_ points: [NormalizedPoint], candidate: NormalizedPoint) -> Bool {
    guard let last = points.last else { return true }
    let dx = candidate.x - last.x
    let dy = candidate.y - last.y
    let distance = hypot(dx, dy)
    if distance < curveSampleDistance { return false }
    if distance >= flatSampleDistance { return true }
    if let candidatePressure = candidate.pressure, let lastPressure = last.pressure,
       abs(candidatePressure - lastPressure) >= pressureSampleDelta {
      return true
    }
    guard points.count >= 2 else { return true }
    let previous = points[points.count - 2]
    let px = last.x - previous.x
    let py = last.y - previous.y
    let previousLength = hypot(px, py)
    guard previousLength > 0 else { return true }
    let cosine = (px * dx + py * dy) / (previousLength * distance)
    return cosine < curveTurnCos
  }

  // MARK: - Snapped shapes as ink
  //
  // Shape assist rewrites a recognised stroke to line / arrow / rectangle /
  // ellipse, and this board used to draw those as a bare stroked polyline —
  // no grain, no tooth, no taper, no ribbon. A straightened pencil line came
  // back as a generic marker line.
  //
  // These mirror `shapeInkStrokes` in packages/client/src/inkGeometry.ts:
  // they turn a shape back into the polyline a hand would have travelled to
  // draw it, at ink sampling density, so it goes through the same freehand
  // mark assembler and picks up its instrument for free.

  /// Ink sample spacing along a shape outline, in normalized surface units.
  private static let shapeSampleSpacing = 1.0 / 90
  /// Ceiling on samples per shape, so a huge ellipse cannot stall a frame.
  private static let shapeMaxSamples = 400
  /// An ellipse never reads as a circle below this many samples.
  private static let ellipseMinSamples = 48
  /// Arrow barb length as a multiple of stroke width...
  private static let arrowHeadWidthFactor = 6.0
  /// ...capped at this fraction of the shaft, so short arrows stay readable.
  private static let arrowHeadShaftFraction = 0.4
  /// Half-angle between shaft and barb.
  private static let arrowHeadSpread = Double.pi / 7

  /// True for the drawing types that are shapes, and so need an ink outline.
  static func isInkShapeType(_ type: String) -> Bool {
    type == "line" || type == "arrow" || type == "rectangle" || type == "ellipse"
  }

  private static func interpolated(
    _ a: NormalizedPoint,
    _ b: NormalizedPoint,
    _ u: Double,
    at position: CGPoint
  ) -> NormalizedPoint {
    // Dynamics ride along only when both ends carry them; a half-known ramp
    // would be invented data, and the width factors read it as real.
    func lerp(_ from: Double?, _ to: Double?) -> Double? {
      guard let from, let to else { return nil }
      return from + (to - from) * u
    }
    return NormalizedPoint(
      x: Double(position.x),
      y: Double(position.y),
      t: lerp(a.t, b.t),
      pressure: lerp(a.pressure, b.pressure),
      tiltX: lerp(a.tiltX, b.tiltX),
      tiltY: lerp(a.tiltY, b.tiltY)
    )
  }

  /// Walks a corner polyline at ink density. Corners are always emitted as
  /// samples, so a snapped rectangle keeps square corners instead of the
  /// rounding a uniform arc-length resample would introduce.
  private static func resampleOutline(
    corners: [CGPoint],
    spacing: Double,
    from: NormalizedPoint,
    to: NormalizedPoint
  ) -> [NormalizedPoint] {
    guard corners.count >= 2 else { return [] }
    var lengths: [Double] = []
    var total = 0.0
    for index in 1..<corners.count {
      let length = Double(hypot(
        corners[index].x - corners[index - 1].x,
        corners[index].y - corners[index - 1].y
      ))
      lengths.append(length)
      total += length
    }
    guard total > 0 else { return [] }
    // One pass to size the walk, so the sample budget is spent evenly rather
    // than exhausted on the first edge.
    let step = max(spacing, total / Double(shapeMaxSamples))
    var out: [NormalizedPoint] = [interpolated(from, to, 0, at: corners[0])]
    var travelled = 0.0
    for index in 1..<corners.count {
      let start = corners[index - 1]
      let end = corners[index]
      let length = lengths[index - 1]
      guard length > 0 else { continue }
      let steps = max(1, Int((length / step).rounded(.up)))
      for sample in 1...steps {
        let u = Double(sample) / Double(steps)
        let position = CGPoint(
          x: start.x + (end.x - start.x) * CGFloat(u),
          y: start.y + (end.y - start.y) * CGFloat(u)
        )
        out.append(
          interpolated(from, to, (travelled + length * u) / total, at: position)
        )
      }
      travelled += length
    }
    return out
  }

  /// The stroke (or strokes) a hand would have travelled to draw this shape,
  /// in normalized surface units at ink sampling density. An `arrow` yields
  /// two — the shaft, then the head as a single barb-tip-barb pass. Returns
  /// nil for anything that is not a shape, or whose geometry is too
  /// degenerate to walk, so callers fall back to their own rendering.
  ///
  /// Rectangles and ellipses come off the bounding box rather than the
  /// literal point trail: senders store a snapped shape as a two-point
  /// diagonal, and only the server expands it into a loop.
  static func shapeInkStrokes(
    type: String,
    points: [NormalizedPoint],
    strokeWidth: Double
  ) -> [[NormalizedPoint]]? {
    guard isInkShapeType(type) else { return nil }
    let points = points.filter { $0.x.isFinite && $0.y.isFinite }
    guard let first = points.first, let last = points.last, points.count >= 2 else {
      return nil
    }
    let spacing = shapeSampleSpacing

    if type == "line" || type == "arrow" {
      let length = hypot(last.x - first.x, last.y - first.y)
      guard length > 0 else { return nil }
      let shaft = resampleOutline(
        corners: [CGPoint(x: first.x, y: first.y), CGPoint(x: last.x, y: last.y)],
        spacing: spacing,
        from: first,
        to: last
      )
      guard shaft.count >= 2 else { return nil }
      if type == "line" { return [shaft] }
      let width = strokeWidth.isFinite && strokeWidth > 0 ? strokeWidth : 0.006
      let headLength = min(width * arrowHeadWidthFactor, length * arrowHeadShaftFraction)
      guard headLength > 0 else { return [shaft] }
      let angle = atan2(last.y - first.y, last.x - first.x)
      func barb(_ spread: Double) -> CGPoint {
        CGPoint(
          x: last.x - cos(angle + spread) * headLength,
          y: last.y - sin(angle + spread) * headLength
        )
      }
      // The head is drawn at the stroke's end, so it carries the end's
      // dynamics throughout rather than ramping across itself.
      let head = resampleOutline(
        corners: [barb(-arrowHeadSpread), CGPoint(x: last.x, y: last.y), barb(arrowHeadSpread)],
        spacing: spacing,
        from: last,
        to: last
      )
      return head.count >= 2 ? [shaft, head] : [shaft]
    }

    let minX = points.map(\.x).min() ?? 0
    let maxX = points.map(\.x).max() ?? 0
    let minY = points.map(\.y).min() ?? 0
    let maxY = points.map(\.y).max() ?? 0
    let width = maxX - minX
    let height = maxY - minY
    guard width > 0 || height > 0 else { return nil }

    if type == "rectangle" {
      let outline = resampleOutline(
        corners: [
          CGPoint(x: minX, y: minY),
          CGPoint(x: maxX, y: minY),
          CGPoint(x: maxX, y: maxY),
          CGPoint(x: minX, y: maxY),
          CGPoint(x: minX, y: minY),
        ],
        spacing: spacing,
        from: first,
        to: last
      )
      return outline.count >= 2 ? [outline] : nil
    }

    let radiusX = width / 2
    let radiusY = height / 2
    let centerX = minX + radiusX
    let centerY = minY + radiusY
    // Ramanujan's approximation: exact enough to pick a sample count, and far
    // cheaper than an elliptic integral.
    let circumference = Double.pi * (
      3 * (radiusX + radiusY)
        - ((3 * radiusX + radiusY) * (radiusX + 3 * radiusY)).squareRoot()
    )
    let samples = max(
      ellipseMinSamples,
      min(shapeMaxSamples, Int((circumference / spacing).rounded()))
    )
    // Angle 0 first, counter-clockwise, matching the point trail shape assist
    // itself builds — so a snapped ellipse seams where its preview does.
    let outline = (0...samples).map { index -> NormalizedPoint in
      let angle = (Double(index) / Double(samples)) * Double.pi * 2
      return interpolated(
        first,
        last,
        Double(index) / Double(samples),
        at: CGPoint(x: centerX + cos(angle) * radiusX, y: centerY + sin(angle) * radiusY)
      )
    }
    return [outline]
  }

  /// Catmull-Rom converted to cubic Béziers: the curve passes through every
  /// input sample, so smoothing never drags the ink away from the finger.
  static func smoothPath(through points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 1 else { return path }
    guard points.count > 2 else {
      path.addLine(to: points[1])
      return path
    }
    addSmoothCurves(&path, through: points)
    return path
  }

  /// Per-point width multipliers for ribbon styles. Pressure wins when the
  /// digitizer reported it; otherwise velocity from point timestamps; flat 1
  /// when neither exists. Factors are neighbor-averaged so a single noisy
  /// sample never produces a bulge. Pass `range` (e.g. `markerFactorRange`)
  /// to override the per-mode clamps with a narrower dynamics band.
  static func widthFactors(for points: [NormalizedPoint], range: ClosedRange<Double>? = nil) -> [Double] {
    guard !points.isEmpty else { return [] }
    let pressureRange = range ?? pressureFactorRange
    let velocityRange = range ?? velocityFactorRange
    var factors = [Double](repeating: 1, count: points.count)
    let hasPressure = points.contains { ($0.pressure ?? 0) > 0 }
    if hasPressure {
      var lastPressure = 0.5
      for (index, point) in points.enumerated() {
        if let pressure = point.pressure, pressure > 0 {
          lastPressure = pressure
        }
        factors[index] = clamped(0.55 + 0.9 * lastPressure, to: pressureRange)
      }
    } else {
      var ema: Double?
      for index in 1..<points.count {
        let previous = points[index - 1]
        let current = points[index]
        guard let previousT = previous.t, let currentT = current.t else { continue }
        let dt = max(1, currentT - previousT)
        let velocity = hypot(current.x - previous.x, current.y - previous.y) / dt
        let smoothedVelocity = ema.map { velocityEmaAlpha * velocity + (1 - velocityEmaAlpha) * $0 } ?? velocity
        ema = smoothedVelocity
        factors[index] = clamped(1.2 - smoothedVelocity / velocityReference, to: velocityRange)
      }
      if points.count > 1 {
        factors[0] = factors[1]
      }
    }
    guard factors.count > 2 else { return factors }
    var smoothed = factors
    for index in 1..<(factors.count - 1) {
      smoothed[index] = (factors[index - 1] + factors[index] + factors[index + 1]) / 3
    }
    return smoothed
  }

  /// Per-point taper multipliers so ribbon strokes land and lift like a real
  /// nib: each end ramps its `tipFactor` -> 1 over its own length, with a
  /// smoothstep curve, and a point takes whichever end is thinning it more.
  /// Mirrors the web's `freehandTaperMultipliers`.
  ///
  /// `strokeWidth` is in the same units as the points. Supply it and each end's
  /// cap is read in nib widths (`maxWidths`), which is the length a taper
  /// actually has; omit it and the absolute `maxSurfaceUnits` cap applies
  /// against `surfaceExtent`, which is what every caller did before
  /// nib-relative lengths existed.
  static func taperMultipliers(
    for points: [CGPoint],
    surfaceExtent: CGFloat,
    profile: TaperProfile = markerTaper,
    strokeWidth: CGFloat? = nil
  ) -> [Double] {
    guard points.count > 1 else { return [Double](repeating: 1, count: points.count) }
    var arc = [Double](repeating: 0, count: points.count)
    for index in 1..<points.count {
      arc[index] = arc[index - 1] + Double(hypot(
        points[index].x - points[index - 1].x,
        points[index].y - points[index - 1].y
      ))
    }
    guard let total = arc.last, total > 0 else {
      return [Double](repeating: 1, count: points.count)
    }
    var nib: Double?
    if let strokeWidth, strokeWidth.isFinite, strokeWidth > 0 {
      nib = Double(strokeWidth)
    }
    func lengthOf(_ tipFactor: Double, _ arcFraction: Double, _ maxWidths: Double, _ maxSurfaceUnits: Double) -> Double {
      let cap = nib.map { $0 * maxWidths } ?? Double(surfaceExtent) * maxSurfaceUnits / 1000
      return min(total * arcFraction, cap)
    }
    let exit = profile.exit
      ?? TaperEnd(
        tipFactor: profile.tipFactor,
        arcFraction: profile.arcFraction,
        maxWidths: profile.maxWidths,
        maxSurfaceUnits: profile.maxSurfaceUnits
      )
    let entryLength = lengthOf(
      profile.tipFactor, profile.arcFraction, profile.maxWidths, profile.maxSurfaceUnits)
    let exitLength = lengthOf(
      exit.tipFactor, exit.arcFraction, exit.maxWidths, exit.maxSurfaceUnits)
    if entryLength <= 0 && exitLength <= 0 {
      return [Double](repeating: 1, count: points.count)
    }
    func ramp(_ distance: Double, _ length: Double, _ tipFactor: Double) -> Double {
      guard length > 0 else { return 1 }
      let t = min(1, max(0, distance / length))
      return tipFactor + (1 - tipFactor) * (t * t * (3 - 2 * t))
    }
    return arc.map { s in
      min(
        ramp(s, entryLength, profile.tipFactor),
        ramp(total - s, exitLength, exit.tipFactor)
      )
    }
  }

  /// Variable-width ribbon: the smoothed centerline offset along its normals
  /// by per-point half-widths, closed with round end caps, meant to be filled.
  /// Returns nil for degenerate input so callers can fall back to a stroked
  /// path.
  static func ribbonPath(centerline points: [CGPoint], halfWidths: [CGFloat]) -> Path? {
    guard points.count >= 3, points.count == halfWidths.count else { return nil }
    guard let normals = centerlineNormals(points) else { return nil }

    var left = [CGPoint]()
    var right = [CGPoint]()
    left.reserveCapacity(points.count)
    right.reserveCapacity(points.count)
    for index in 0..<points.count {
      let halfWidth = max(minimumHalfWidth, halfWidths[index])
      let normal = normals[index]
      let point = points[index]
      left.append(CGPoint(x: point.x + normal.dx * halfWidth, y: point.y + normal.dy * halfWidth))
      right.append(CGPoint(x: point.x - normal.dx * halfWidth, y: point.y - normal.dy * halfWidth))
    }
    guard left.allSatisfy(isFinite), right.allSatisfy(isFinite) else { return nil }

    let last = points.count - 1
    var path = Path()
    path.move(to: left[0])
    addSmoothCurves(&path, through: left)
    addCap(
      &path,
      center: points[last],
      radius: max(minimumHalfWidth, halfWidths[last]),
      startAngle: atan2(left[last].y - points[last].y, left[last].x - points[last].x)
    )
    addSmoothCurves(&path, through: Array(right.reversed()))
    addCap(
      &path,
      center: points[0],
      radius: max(minimumHalfWidth, halfWidths[0]),
      startAngle: atan2(right[0].y - points[0].y, right[0].x - points[0].x)
    )
    path.closeSubpath()
    return path
  }

  // MARK: - Width axes

  /// Stroke direction at each sample, from its neighbours.
  private static func headings(_ points: [CGPoint]) -> [Double] {
    points.indices.map { index in
      let ahead = points[min(index + 1, points.count - 1)]
      let behind = points[max(index - 1, 0)]
      return atan2(Double(ahead.y - behind.y), Double(ahead.x - behind.x))
    }
  }

  /// Per-point width factors for a broad-edge nib: full width across the nib,
  /// `thin` along it. Needs no input signal — only the direction the stroke is
  /// already travelling. Mirrors the web's freehandNibFactors.
  static func nibFactors(for points: [CGPoint], nib: RemoteDrawInk.Nib) -> [Double] {
    let angle = nib.angleDegrees * .pi / 180
    let thin = min(1, max(0.02, nib.thin))
    return headings(points).map { heading in
      let across = abs(sin(heading - angle))
      return thin + (1 - thin) * across
    }
  }

  /// How far the stylus is laid over, 0 (upright) to 1 (flat).
  static func tiltAmount(_ point: NormalizedPoint) -> Double {
    guard let x = point.tiltX, let y = point.tiltY,
          x.isFinite, y.isFinite else { return 0 }
    return min(1, max(0, hypot(x, y) / 90))
  }

  /// Per-point width factors from stylus tilt: laid over, the lead presents
  /// its flank and shades broad. Mirrors the web's freehandTiltFactors.
  static func tiltFactors(for points: [NormalizedPoint], tilt: RemoteDrawInk.Tilt) -> [Double] {
    let raw = points.map { point -> Double in
      let t = min(1, max(0, tiltAmount(point)))
      let ramp = t * t * (3 - 2 * t)
      return tilt.widthUpright + (tilt.widthFlat - tilt.widthUpright) * ramp
    }
    guard raw.count > 2 else { return raw }
    var smoothed = raw
    for index in 1..<(raw.count - 1) {
      smoothed[index] = (raw[index - 1] + raw[index] + raw[index + 1]) / 3
    }
    return smoothed
  }

  static func meanTiltAmount(_ points: [NormalizedPoint]) -> Double {
    guard !points.isEmpty else { return 0 }
    return points.reduce(0.0) { $0 + tiltAmount($1) } / Double(points.count)
  }

  // MARK: - Dry-media grain

  /// One painted pass of a textured stroke.
  struct GrainStreak {
    let path: Path
    let width: CGFloat
    let alpha: Double
    /// Dash pattern in points; empty for continuous media and the body pass.
    let dash: [CGFloat]
  }

  /// Deterministic 0..1 noise from two integers. Grain has to be identical on
  /// every renderer, so the native board hashes the same (streak, sample)
  /// pairs as the web. Bit-for-bit the same 32-bit mixing as `inkNoise` in
  /// packages/client/src/inkGeometry.ts.
  static func noise(_ a: Int, _ b: Int) -> Double {
    var h = (UInt32(truncatingIfNeeded: a) &* 0x27d4_eb2d)
      ^ (UInt32(truncatingIfNeeded: b) &* 0x1656_67b1)
    h = (h ^ (h >> 15)) &* 0x85eb_ca6b
    h = (h ^ (h >> 13)) &* 0xc2b2_ae35
    h = h ^ (h >> 16)
    return Double(h) / 4294967296.0
  }

  private static func mix(_ range: ClosedRange<Double>, _ t: Double) -> Double {
    range.lowerBound + (range.upperBound - range.lowerBound) * t
  }

  /// Dry-media grain: thin streaks offset across the stroke width, each
  /// wandering slightly and (for media that skip) broken by dashes, over a
  /// faint full-width body that keeps them reading as one line. Overlapping
  /// semi-transparent streaks give the density variation and ragged edges a
  /// solid path cannot.
  ///
  /// `widths` is per-point so grain tracks a ribbon that is itself varying —
  /// what a dry brush or a tilted pencil needs. Returns nil for degenerate
  /// input so callers fall back to a plain stroked path.
  static func grainStreaks(
    centerline points: [CGPoint],
    widths: [CGFloat],
    grain: RemoteDrawInk.Grain
  ) -> [GrainStreak]? {
    guard points.count >= 2, !widths.isEmpty else { return nil }
    guard let normals = centerlineNormals(points) else { return nil }
    let nominal = widths.reduce(0, +) / CGFloat(widths.count)
    guard nominal > 0 else { return nil }
    let widthAt: (Int) -> CGFloat = { index in
      widths[min(max(0, index), widths.count - 1)]
    }

    var streaks: [GrainStreak] = [
      GrainStreak(
        path: smoothPath(through: points),
        width: nominal * CGFloat(grain.bodyWidth),
        alpha: grain.bodyAlpha,
        dash: []
      )
    ]

    for streak in 0..<grain.streaks {
      let seat = grain.streaks == 1
        ? 0.5
        : Double(streak) / Double(grain.streaks - 1)
      let streakWidth = nominal * CGFloat(mix(grain.streakWidth, noise(streak, 1)))
      let alpha = mix(grain.alpha, noise(streak, 2))
      var dash: [CGFloat] = []
      if let on = grain.dashOn, let off = grain.dashOff {
        // Two on/off pairs rather than one: an aperiodic dash keeps the skips
        // from lining up into visible stripes along the stroke.
        dash = [
          nominal * CGFloat(mix(on, noise(streak, 3))),
          nominal * CGFloat(mix(off, noise(streak, 4))),
          nominal * CGFloat(mix(on, noise(streak, 5))),
          nominal * CGFloat(mix(off, noise(streak, 6))),
        ]
      }
      let shifted = points.enumerated().map { index, point -> CGPoint in
        let normal = normals[index]
        let local = widthAt(index)
        let offset = CGFloat((seat - 0.5) * grain.spread) * local
        // Low-frequency wander: one noise sample every few points, so a streak
        // meanders across the nib instead of buzzing sample to sample.
        let step = 16 + index / max(1, grain.wanderRate)
        let wander = CGFloat((noise(streak, step) - 0.5) * grain.wander) * local
        let distance = offset + wander
        return CGPoint(x: point.x + normal.dx * distance, y: point.y + normal.dy * distance)
      }
      streaks.append(
        GrainStreak(
          path: smoothPath(through: shifted),
          width: streakWidth,
          alpha: alpha,
          dash: dash
        )
      )
    }
    return streaks
  }

  /// Scattered deposit for an airbrush: marks sprayed around the path, denser
  /// where the hand pressed harder. Emitted as one path of dots so a spray
  /// costs a single fill rather than hundreds of draw calls. Total marks are
  /// capped for the same reason.
  static func scatterPath(
    centerline points: [CGPoint],
    pressures: [Double],
    width: CGFloat,
    scatter: RemoteDrawInk.Scatter
  ) -> (path: Path, dotWidth: CGFloat)? {
    guard !points.isEmpty, width > 0 else { return nil }
    // **Marks per sample, normalised for the nib, or the spray changes shape as
    // the width slider moves.** Each sample's dust is width-invariant on its own
    // — dot area and disc area both go with `width²` — but sample spacing comes
    // off the wire and does not scale with the nib, so a wide nozzle stacks
    // proportionally more discs over any one point and areal deposit ran linear
    // in width: 0.125 / 0.301 / 0.584 ink per nib width at nibs 6 / 12 / 24, a
    // 4.7x spread against the other nine wet instruments' 2.3%. Mirrors
    // `freehandScatterLayer`; see its note for the whole argument.
    let areal = Double(RemoteDrawInk.scatterReferenceWidth / width)
    let wanted = Double(scatter.density) * areal
    let perPoint = max(
      1, min(wanted, Double(RemoteDrawInk.maxScatterMarks / max(1, points.count))))
    // The mark budget is a flat total, so a long stroke gets fewer marks per
    // sample than a short one — measured, a spray lost 78% of its coverage
    // between a 60-unit dab (12.7% areal) and a board-width sweep (2.8%), which
    // is the airbrush fading out as you keep drawing. Growing each mark by the
    // same factor the budget shrank them conserves the deposit.
    let thinned = (wanted / perPoint).squareRoot()
    var path = Path()
    var seed = 0
    let radius = max(width * CGFloat(scatter.dotWidth) * CGFloat(thinned), 0.2) / 2
    for (index, point) in points.enumerated() {
      let pressure = min(1, max(0.05, pressures.indices.contains(index) ? pressures[index] : 0.6))
      let count = max(1, Int((perPoint * (0.4 + pressure)).rounded()))
      for _ in 0..<count {
        seed += 1
        let angle = noise(seed, 1) * .pi * 2
        // Density falls off from the axis. A sqrt here spreads marks evenly
        // over the disc, which lands a flat pad of dust with a hard rim — the
        // one thing a spray never is. The 0.75 exponent puts density at r^-0.5,
        // so the mark has a solid core that fades out, and its edge is where
        // the marks run out rather than where the disc stops.
        let distance = CGFloat(pow(noise(seed, 2), 0.75) * scatter.radius) * width * 0.5
        let x = point.x + CGFloat(cos(angle)) * distance
        let y = point.y + CGFloat(sin(angle)) * distance
        path.addEllipse(in: CGRect(
          x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
      }
    }
    return (path, radius * 2)
  }

  /// Unit normals along a centerline, with degenerate entries backfilled.
  private static func centerlineNormals(_ points: [CGPoint]) -> [CGVector]? {
    var normals = [CGVector]()
    normals.reserveCapacity(points.count)
    var lastNormal = CGVector.zero
    for index in 0..<points.count {
      let ahead = points[min(index + 1, points.count - 1)]
      let behind = points[max(index - 1, 0)]
      let dx = ahead.x - behind.x
      let dy = ahead.y - behind.y
      let length = hypot(dx, dy)
      if length > 0.0001 {
        lastNormal = CGVector(dx: -dy / length, dy: dx / length)
      }
      normals.append(lastNormal)
    }
    guard let firstValid = normals.first(where: { $0 != .zero }) else { return nil }
    for index in 0..<normals.count where normals[index] == .zero {
      normals[index] = firstValid
    }
    return normals
  }

  /// How much of the textbook Catmull-Rom handle survives the turn at `point`.
  ///
  /// Plain Catmull-Rom builds the tangent at p1 from the chord p0→p2. That
  /// chord is tangent to the intended curve only while the polyline turns
  /// gently; at a corner it points *outside* the corner and drags the cubic
  /// with it — a calibration square overshot by 12.5% of its own side. The
  /// cosine of the turn is 1 on a straight run and 0 at a right angle, so this
  /// is inert on the evenly, densely sampled polylines real ink produces.
  ///
  /// Mirrors `catmullRomTurnFactor` in packages/client/src/inkGeometry.ts,
  /// pinned by packages/geometry/tests/smoothing.test.ts.
  private static func catmullRomTurnFactor(_ previous: CGPoint?, _ point: CGPoint, _ next: CGPoint?) -> CGFloat {
    guard let previous, let next else { return 1 }
    let inX = point.x - previous.x
    let inY = point.y - previous.y
    let outX = next.x - point.x
    let outY = next.y - point.y
    let inLength = hypot(inX, inY)
    let outLength = hypot(outX, outY)
    guard inLength > 0, outLength > 0 else { return 1 }
    return max(0, (inX * outX + inY * outY) / (inLength * outLength))
  }

  /// Catmull-Rom segments with two guards on the `(p2 - p0) / 6` handles: the
  /// turn attenuation above, and a cap at a third of the segment's own length.
  /// Uniform Catmull-Rom's handle is |p2 - p0| / 6, which for even spacing is
  /// at most |p2 - p1| / 3 — so the cap only ever fires when spacing is uneven,
  /// exactly the short-segment-beside-a-long-one case where uniform
  /// Catmull-Rom throws a control point clean past the far end.
  private static func addSmoothCurves(_ path: inout Path, through points: [CGPoint]) {
    guard points.count > 1 else { return }
    for index in 0..<(points.count - 1) {
      let p0 = index > 0 ? points[index - 1] : points[index]
      let p1 = points[index]
      let p2 = points[index + 1]
      let p3 = index + 2 < points.count ? points[index + 2] : p2
      let startFactor = catmullRomTurnFactor(index > 0 ? points[index - 1] : nil, p1, p2)
      let endFactor = catmullRomTurnFactor(p1, p2, index + 2 < points.count ? points[index + 2] : nil)
      let limit = hypot(p2.x - p1.x, p2.y - p1.y) / 3
      func handle(_ x: CGFloat, _ y: CGFloat, _ factor: CGFloat) -> CGPoint {
        var hx = x / 6 * factor
        var hy = y / 6 * factor
        let length = hypot(hx, hy)
        if length > limit {
          let scale = limit / length
          hx *= scale
          hy *= scale
        }
        return CGPoint(x: hx, y: hy)
      }
      let start = handle(p2.x - p0.x, p2.y - p0.y, startFactor)
      let end = handle(p3.x - p1.x, p3.y - p1.y, endFactor)
      let control1 = CGPoint(x: p1.x + start.x, y: p1.y + start.y)
      let control2 = CGPoint(x: p2.x - end.x, y: p2.y - end.y)
      path.addCurve(to: p2, control1: control1, control2: control2)
    }
  }

  /// Half-circle cap sampled as short chords, sweeping -pi from `startAngle`
  /// so it bulges away from the ribbon body. Chord error at radius 34pt with
  /// 8 segments is under a point, invisible at stroke widths.
  private static func addCap(_ path: inout Path, center: CGPoint, radius: CGFloat, startAngle: CGFloat) {
    for step in 1...capSegments {
      let angle = startAngle - .pi * CGFloat(step) / CGFloat(capSegments)
      path.addLine(to: CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius))
    }
  }

  private static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(range.upperBound, max(range.lowerBound, value))
  }

  private static func isFinite(_ point: CGPoint) -> Bool {
    point.x.isFinite && point.y.isFinite
  }
}
