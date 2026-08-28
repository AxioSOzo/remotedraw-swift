import XCTest

@testable import RemoteDrawSenderKit

/// The packed point format is a wire contract. These tests hold the Swift
/// encoder to the byte strings the canonical TypeScript encoder produces for
/// the same input, and hold the decoder to the tolerances the format documents.
final class PointCodecTests: XCTestCase {
  // MARK: - Generated parity

  func testEveryGeneratedVectorEncodesByteForByte() throws {
    let fixture = try CodecFixture.load()
    XCTAssertEqual(fixture.codecVersion, Int(PointCodec.version))
    XCTAssertFalse(fixture.vectors.isEmpty, "The fixture is empty; regenerate it.")

    for vector in fixture.vectors {
      XCTAssertEqual(
        PointCodec.pack(vector.normalizedPoints),
        vector.packed,
        """
        Vector "\(vector.name)" disagrees with the TypeScript encoder.
        \(vector.why)
        This is a wire-format divergence, not a fixture to be adjusted.
        """
      )
    }
  }

  func testEveryGeneratedVectorRoundTrips() throws {
    for vector in try CodecFixture.load().vectors {
      let decoded = try PointCodec.unpack(vector.packed)
      XCTAssertEqual(decoded.count, vector.points.count, vector.name)
      for (index, original) in vector.normalizedPoints.enumerated() {
        let back = decoded[index]
        // Clamped inputs decode to the clamp, not to the input.
        XCTAssertEqual(
          back.x, min(1, max(0, original.x)),
          accuracy: RemoteDrawPointCodecTolerance.xy, "\(vector.name)[\(index)].x")
        XCTAssertEqual(
          back.y, min(1, max(0, original.y)),
          accuracy: RemoteDrawPointCodecTolerance.xy, "\(vector.name)[\(index)].y")
        if let pressure = original.pressure {
          XCTAssertEqual(
            back.pressure ?? -1, min(1, max(0, pressure)),
            accuracy: RemoteDrawPointCodecTolerance.pressure,
            "\(vector.name)[\(index)].pressure")
        }
        if let tiltX = original.tiltX {
          XCTAssertEqual(
            back.tiltX ?? .nan, min(90, max(-90, tiltX)),
            accuracy: RemoteDrawPointCodecTolerance.tilt, "\(vector.name)[\(index)].tiltX")
        }
        if let t = original.t {
          XCTAssertEqual(
            back.t ?? -1, min(2_147_483_647, max(0, t)),
            accuracy: RemoteDrawPointCodecTolerance.t, "\(vector.name)[\(index)].t")
        }
      }
    }
  }

  func testReEncodingADecodedVectorIsAFixedPoint() throws {
    // Quantisation has to be idempotent, or a stroke drifts a little further
    // every time it passes through a store-and-forward hop.
    for vector in try CodecFixture.load().vectors {
      let decoded = try PointCodec.unpack(vector.packed)
      XCTAssertEqual(PointCodec.pack(decoded), vector.packed, vector.name)
    }
  }

  /// Channel *presence* is what the flags byte encodes, and it is the part a
  /// round trip cannot check on its own: a decoder that defaulted absent
  /// channels to zero would pass every tolerance assertion above.
  func testAbsentChannelsStayAbsentThroughARoundTrip() throws {
    let fixture = try CodecFixture.load()
    let xyOnly = try XCTUnwrap(fixture.vector(named: "xyOnly"))
    let decodedXY = try PointCodec.unpack(xyOnly.packed)
    XCTAssertNil(decodedXY.first?.t)
    XCTAssertNil(decodedXY.first?.pressure)
    XCTAssertNil(decodedXY.first?.tiltX)

    // One tilt axis without the other. The channel order is X, Y, T, PRESSURE,
    // TILT_X, TILT_Y, so an encoder that assumed the two tilts travel together
    // would write this stream one channel out of place and it would still parse.
    let tiltYOnly = try XCTUnwrap(fixture.vector(named: "tiltYOnly"))
    let decodedTilt = try PointCodec.unpack(tiltYOnly.packed)
    XCTAssertNil(decodedTilt.first?.tiltX)
    XCTAssertNotNil(decodedTilt.first?.tiltY)
  }

  func testSparseChannelsNormalizeToAllPresent() throws {
    // A stroke where some points carry pressure and others do not is normalised
    // to "all present" with the missing ones defaulting to 0: a per-point
    // presence bitmap costs more than it saves at these densities. Two
    // implementations drift on exactly this kind of rule.
    let vector = try XCTUnwrap(try CodecFixture.load().vector(named: "sparsePressure"))
    let decoded = try PointCodec.unpack(vector.packed)
    XCTAssertEqual(decoded.count, 3)
    XCTAssertEqual(decoded[0].pressure ?? -1, 0.5, accuracy: RemoteDrawPointCodecTolerance.pressure)
    XCTAssertEqual(decoded[1].pressure, 0)
    XCTAssertEqual(decoded[2].pressure ?? -1, 0.9, accuracy: RemoteDrawPointCodecTolerance.pressure)
  }

  // MARK: - The bug that already shipped

  func testEpochScaleTimestampClampsInsteadOfTrapping() throws {
    // An epoch-millisecond timestamp is ~1.8e12; the time channel quantises to
    // Int32, whose ceiling is 2.1e9. This used to trap and the app died on the
    // first point of the first stroke. TypeScript never crashed on the same
    // input — JS numbers are doubles — so the hand-copied vectors missed it
    // entirely: every one of them used a small `t`.
    let vector = try XCTUnwrap(try CodecFixture.load().vector(named: "epochTimestamp"))
    let decoded = try PointCodec.unpack(vector.packed)
    XCTAssertEqual(decoded.first?.t, 2_147_483_647)
    XCTAssertEqual(PointCodec.pack(vector.normalizedPoints), vector.packed)
  }

  /// Non-finite channels, pinned as data in every language.
  ///
  /// `Int32(Double.nan.rounded())` **traps** in Swift — the process dies,
  /// exactly the way the epoch-`t` conversion used to — so this side has always
  /// coerced a non-finite channel to the wire's zero for that channel *of that
  /// point*, leaving the point's other channels and every later sample alone.
  /// That is now the shared contract: TypeScript and Kotlin used to leave their
  /// running `previous` non-finite, which flattened the rest of the channel onto
  /// the sample before it, and both were fixed to match this behaviour rather
  /// than the reverse.
  ///
  /// Read from `nonFiniteVectors` rather than written here, which is the whole
  /// argument of the generated fixture: a hand-written NaN case can only test
  /// this implementation against itself, and the three implementations
  /// disagreeing about NaN is precisely what a hand-written case failed to
  /// catch.
  func testNonFiniteChannelsFollowTheGeneratedContract() throws {
    let vectors = try XCTUnwrap(
      CodecFixture.load().nonFiniteVectors,
      "The fixture has no nonFiniteVectors. Run: bun run scripts/point-codec-fixtures.ts")
    XCTAssertFalse(vectors.isEmpty, "The non-finite section is empty; regenerate the fixture.")

    for vector in vectors {
      let points = vector.normalizedPoints

      // Encoding must complete rather than trap, and land on the same bytes the
      // other two implementations produce.
      XCTAssertEqual(
        PointCodec.pack(points),
        vector.packed,
        """
        Vector "\(vector.name)" disagrees with the generated encoder.
        \(vector.why)
        """
      )

      let decoded = try PointCodec.unpack(vector.packed)
      XCTAssertEqual(decoded.count, points.count, vector.name)

      for (index, original) in points.enumerated() {
        let back = decoded[index]
        // NaN reads back as the channel's floor — 0 for position, time and
        // pressure, -90 for tilt, whose range is centred. An *infinity* is a
        // different case and lands on whichever end of the range it points at,
        // because the clamp runs before the quantiser and `value > maximum` is
        // true for `+inf` while every comparison against NaN is false.
        //
        // In both cases every *other* channel of the same point, and every
        // later sample, is untouched — which is the part that used to be wrong
        // in the other two implementations.
        assertChannel(
          back.x, original.x, clampedTo: 0...1,
          accuracy: RemoteDrawPointCodecTolerance.xy, "\(vector.name)[\(index)].x")
        assertChannel(
          back.y, original.y, clampedTo: 0...1,
          accuracy: RemoteDrawPointCodecTolerance.xy, "\(vector.name)[\(index)].y")
        if let t = original.t {
          assertChannel(
            back.t, t, clampedTo: 0...2_147_483_647,
            accuracy: RemoteDrawPointCodecTolerance.t, "\(vector.name)[\(index)].t")
        }
        if let pressure = original.pressure {
          assertChannel(
            back.pressure, pressure, clampedTo: 0...1,
            accuracy: RemoteDrawPointCodecTolerance.pressure,
            "\(vector.name)[\(index)].pressure")
        }
        if let tiltX = original.tiltX {
          assertChannel(
            back.tiltX, tiltX, clampedTo: -90...90,
            accuracy: RemoteDrawPointCodecTolerance.tilt, "\(vector.name)[\(index)].tiltX")
        }
        if let tiltY = original.tiltY {
          assertChannel(
            back.tiltY, tiltY, clampedTo: -90...90,
            accuracy: RemoteDrawPointCodecTolerance.tilt, "\(vector.name)[\(index)].tiltY")
        }
      }
    }
  }

  /// What a channel must decode to, given what went in.
  ///
  /// `range.lowerBound` *is* the channel's floor for every channel the format
  /// has — 0 for position, time and pressure; -90 for tilt — so NaN needs no
  /// separate constant, only a separate branch from the clamp that handles the
  /// infinities.
  private func assertChannel(
    _ decoded: Double?,
    _ original: Double,
    clampedTo range: ClosedRange<Double>,
    accuracy: Double,
    _ label: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let expected =
      original.isNaN
      ? range.lowerBound
      : min(range.upperBound, max(range.lowerBound, original))
    XCTAssertEqual(decoded ?? .nan, expected, accuracy: accuracy, label, file: file, line: line)
  }

  // MARK: - Decoder robustness

  func testRejectsMalformedInputRatherThanReturningAPartialStroke() throws {
    // A half-decoded stroke would render as a real one.
    XCTAssertThrowsError(try PointCodec.unpack("!!!not base64!!!"))
    XCTAssertThrowsError(try PointCodec.unpack(""))

    let valid = PointCodec.pack(
      (0..<50).map { RemoteDrawNormalizedPoint(x: Double($0) / 50, y: 0.5, t: Double($0)) })
    XCTAssertThrowsError(try PointCodec.unpack(String(valid.dropLast(8))))
    XCTAssertThrowsError(try PointCodec.unpack(valid + "AAAAAAAA")) { error in
      XCTAssertEqual(error as? RemoteDrawPointCodecError, .trailingBytes)
    }
  }

  func testRejectsAnUnsupportedVersion() {
    // "B" is index 1 in the alphabet, and the first base64 character carries the
    // top six bits of the version byte: 000001|xx becomes 0b101 = 5.
    let bogus = "B" + PointCodec.pack([RemoteDrawNormalizedPoint(x: 0.5, y: 0.5)]).dropFirst()
    XCTAssertThrowsError(try PointCodec.unpack(bogus)) { error in
      XCTAssertEqual(error as? RemoteDrawPointCodecError, .unsupportedVersion(5))
    }
  }

  func testRefusesAStreamThatDeclaresMorePointsThanTheCallerAllows() throws {
    // The header is three bytes, so a corrupt or hostile string can ask for an
    // allocation far larger than any stroke.
    let packed = PointCodec.pack(
      (0..<400).map { RemoteDrawNormalizedPoint(x: Double($0) / 400, y: 0.5) })
    XCTAssertThrowsError(try PointCodec.unpack(packed, maxPoints: 100))
    XCTAssertEqual(try PointCodec.unpack(packed, maxPoints: 1200).count, 400)
  }

  // MARK: - Size

  func testIsMeaningfullySmallerThanTheJSONItReplaces() throws {
    let points = (0..<500).map { index -> RemoteDrawNormalizedPoint in
      let i = Double(index)
      return RemoteDrawNormalizedPoint(
        x: 0.5 + 0.3 * sin(i / 9), y: 0.5 + 0.3 * cos(i / 7), t: i * 8,
        pressure: 0.5 + 0.4 * sin(i / 5), tiltX: 20 * sin(i / 11), tiltY: 10 * cos(i / 13))
    }
    let packed = PointCodec.pack(points)
    let json = try JSONEncoder().encode(points)
    // Measured ~13x. Assert a floor so a regression that quietly disables delta
    // coding shows up here rather than as a rate-limited tenant.
    XCTAssertLessThan(packed.count * 5, json.count)
  }
}
