import Foundation
import XCTest

@testable import RemoteDrawSenderKit

/// The generated golden vectors, read as data.
///
/// Emitted by `scripts/point-codec-fixtures.ts` from the canonical TypeScript
/// encoder and consumed here **without being retyped**. That is the entire
/// point: the three hand-copied vector sets this replaces are what let an
/// epoch-millisecond `t` through — a value that traps Swift's `Int32`
/// conversion and killed the app on the first point of the first stroke, while
/// every suite stayed green, because every pinned vector used a small `t`.
///
/// If a vector here disagrees with what this encoder produces, that is a real
/// divergence between two implementations of a wire format. Fix the encoder or
/// fix the generator; do not edit the fixture to match.
struct CodecFixture: Decodable {
  struct Vector: Decodable {
    let name: String
    /// What the case is defending, carried into the failure message.
    let why: String
    let packed: String
    let points: [FixturePoint]

    var normalizedPoints: [RemoteDrawNormalizedPoint] {
      points.map(\.point)
    }
  }

  /// A point exactly as JSON spells it: absent optional channels stay absent,
  /// because channel *presence* is what the flags byte encodes and a decoder
  /// that defaulted them would silently pass a vector that tests nothing.
  struct FixturePoint: Decodable {
    let x: Double
    let y: Double
    let t: Double?
    let pressure: Double?
    let tiltX: Double?
    let tiltY: Double?

    var point: RemoteDrawNormalizedPoint {
      RemoteDrawNormalizedPoint(
        x: x, y: y, t: t, pressure: pressure, tiltX: tiltX, tiltY: tiltY)
    }
  }

  /// A vector whose channels are spelled as strings.
  ///
  /// `JSON.stringify(NaN)` is `null`, so the generator writes every channel of
  /// the non-finite cases as text — `"0.4"`, `"NaN"`, `"-Infinity"` — and each
  /// language parses it with its own `Double`. Without this the one contract
  /// that most needs pinning as data would be the one contract that could only
  /// be written as prose.
  struct NonFiniteVector: Decodable {
    let name: String
    let why: String
    let packed: String
    let points: [LooseFixturePoint]

    var normalizedPoints: [RemoteDrawNormalizedPoint] {
      points.map(\.point)
    }
  }

  struct LooseFixturePoint: Decodable {
    let x: String
    let y: String
    let t: String?
    let pressure: String?
    let tiltX: String?
    let tiltY: String?

    /// `Double(_:)` goes through `strtod`, which reads `NaN`, `Infinity` and
    /// `-Infinity` as well as ordinary decimals. A channel that fails to parse
    /// is a corrupt fixture, not a value to guess at, so it becomes `.nan` and
    /// the assertions below report it.
    var point: RemoteDrawNormalizedPoint {
      RemoteDrawNormalizedPoint(
        x: Double(x) ?? .nan,
        y: Double(y) ?? .nan,
        t: t.map { Double($0) ?? .nan },
        pressure: pressure.map { Double($0) ?? .nan },
        tiltX: tiltX.map { Double($0) ?? .nan },
        tiltY: tiltY.map { Double($0) ?? .nan }
      )
    }
  }

  let codecVersion: Int
  let vectors: [Vector]
  /// Optional so a fixture generated before this section existed still decodes;
  /// the test that reads it fails loudly rather than silently passing on zero
  /// cases.
  let nonFiniteVectors: [NonFiniteVector]?

  static func load(file: StaticString = #filePath, line: UInt = #line) throws -> CodecFixture {
    guard let url = Bundle.module.url(forResource: "pointCodecVectors", withExtension: "json")
    else {
      XCTFail(
        "pointCodecVectors.json is missing. Run: bun run scripts/point-codec-fixtures.ts",
        file: file, line: line)
      throw CocoaError(.fileNoSuchFile)
    }
    return try JSONDecoder().decode(CodecFixture.self, from: Data(contentsOf: url))
  }

  func vector(named name: String) -> Vector? {
    vectors.first { $0.name == name }
  }
}
