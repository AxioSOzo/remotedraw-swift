import Foundation

/// Compact encoding for normalized point streams.
///
/// Mirrors `packages/protocol/src/pointCodec.ts` byte for byte — the two are a
/// wire format, so any change here belongs in the TypeScript twin and in the
/// generated fixture that diffs their output
/// (`scripts/point-codec-fixtures.ts`).
///
/// Columnar delta + zigzag varint over quantised channels, base64url. Points in
/// a stroke are dense and monotonic in time, so successive deltas are tiny and
/// nearly all fit in one varint byte; grouping by channel keeps like magnitudes
/// together and shortens the varints further. A 500-point stroke costs ~10.7
/// bytes per point instead of ~141 as JSON.
///
/// Deliberately lossy to a fixed bound: positions land on a 1/65535 grid (0.015
/// surface units, well under a display pixel), pressure on 1/255, tilt on ~0.7
/// degrees, timestamps on 1 ms. ``RemoteDrawPointCodecTolerance`` states those
/// bounds and the round-trip tests hold the codec to them.
///
/// **Why the decoder is here at all**, when
/// `apps/ios/RemoteDrawKit/.../ReceiverModels.swift` says `packedPoints`
/// "deliberately has no Swift decoder": that is a defensible call on the
/// *receiver* side, where a board reads points the server already unpacked. It
/// is not one on the sender side. Half a codec can only be tested against
/// itself; a round trip is what proves a quantiser, and the pinned vectors
/// alone did not catch the epoch-`t` trap that killed the app on the first
/// point of the first stroke.
public enum PointCodec {
  /// Wire format version, carried in the first byte so a v2 can coexist.
  ///
  /// If this ever goes to 2 the server must accept 1 forever: an installed SDK
  /// cannot be recalled.
  public static let version: UInt8 = 1

  private static let flagT: UInt8 = 1
  private static let flagPressure: UInt8 = 2
  private static let flagTiltX: UInt8 = 4
  private static let flagTiltY: UInt8 = 8

  private static let xyScale = 65535.0
  private static let pressureScale = 255.0
  private static let tiltScale = 255.0
  private static let tiltRange = 180.0
  /// Ceiling for the time channel: it quantises into an `Int32`, and Swift traps
  /// on conversion rather than wrapping. Every other channel was already clamped;
  /// this one was only floored at zero, so a caller passing an epoch timestamp
  /// (~1.8e12) killed the app on the first point it packed. TypeScript did not
  /// crash on the same input — JS numbers are doubles — which is exactly the kind
  /// of divergence the shared vectors exist to catch, and did not, because every
  /// pinned vector used a small `t`.
  private static let tMax = 2_147_483_647.0

  private static let base64url = Array(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

  private struct Writer {
    var bytes: [UInt8] = []

    mutating func byte(_ value: UInt8) {
      bytes.append(value)
    }

    /// LEB128: 7 bits per byte, high bit continues.
    mutating func varint(_ value: UInt32) {
      var rest = value
      while rest >= 0x80 {
        bytes.append(UInt8((rest & 0x7f) | 0x80))
        rest >>= 7
      }
      bytes.append(UInt8(rest))
    }

    /// Zigzag maps signed to unsigned without spending a bit on small negatives.
    mutating func zigzag(_ value: Int32) {
      varint(UInt32(bitPattern: (value << 1) ^ (value >> 31)))
    }
  }

  private struct Reader {
    private let bytes: [UInt8]
    private var offset = 0

    init(_ bytes: [UInt8]) {
      self.bytes = bytes
    }

    var isDone: Bool { offset >= bytes.count }

    mutating func byte() throws -> UInt8 {
      guard offset < bytes.count else {
        throw RemoteDrawPointCodecError.truncated
      }
      defer { offset += 1 }
      return bytes[offset]
    }

    mutating func varint() throws -> UInt32 {
      var result: UInt64 = 0
      var shift: UInt64 = 0
      while true {
        let next = try byte()
        result += UInt64(next & 0x7f) << shift
        if next & 0x80 == 0 { break }
        shift += 7
        // 5 bytes covers the full 32-bit range; more means corrupt input.
        if shift > 28 { throw RemoteDrawPointCodecError.malformedVarint }
      }
      guard result <= UInt64(UInt32.max) else {
        throw RemoteDrawPointCodecError.malformedVarint
      }
      return UInt32(truncatingIfNeeded: result)
    }

    mutating func zigzag() throws -> Int32 {
      let raw = try varint()
      return Int32(bitPattern: (raw >> 1)) ^ -Int32(bitPattern: raw & 1)
    }
  }

  private static func clamp(_ value: Double, _ minimum: Double, _ maximum: Double) -> Double {
    value < minimum ? minimum : (value > maximum ? maximum : value)
  }

  /// Every quantised value is non-negative by construction, so Swift's
  /// round-half-away-from-zero and JavaScript's `Math.round` (which rounds .5
  /// toward positive infinity) cannot disagree. Deltas are differences of
  /// already-rounded integers, so nothing negative is ever rounded.
  ///
  /// The `isFinite` guard is not decoration. `Int32(Double.nan.rounded())`
  /// **traps** — the process dies, exactly the way the epoch-`t` conversion used
  /// to — and `clamp` cannot catch a NaN because every comparison against it is
  /// false. A host app handing the SDK a point from a zero-sized layout pass or
  /// a divide-by-zero projection is not exotic; the first-party app is safe only
  /// because `DrawingBoardView.clamp01` happens to eat NaN on the way in, which
  /// is not a guarantee an SDK can make about somebody else's capture code.
  ///
  /// **This is now the shared contract, in all three implementations.** A
  /// non-finite channel is written as the wire's zero *for that channel of that
  /// point* and nothing else changes — not the point's other channels, not any
  /// later sample. TypeScript and Kotlin used to write NaN as a zero delta and
  /// leave their running `previous` non-finite, which silently flattened the
  /// rest of that channel onto the position before it; both were fixed to match
  /// this side, which was already correct. The rule is pinned as data rather
  /// than prose: `nonFiniteVectors` in the generated fixture is consumed by
  /// every language.
  private static func quantize(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    return Int32(value.rounded())
  }

  private static func channelFlags(_ points: [RemoteDrawNormalizedPoint]) -> UInt8 {
    var flags: UInt8 = 0
    for point in points {
      if point.t != nil { flags |= flagT }
      if point.pressure != nil { flags |= flagPressure }
      if point.tiltX != nil { flags |= flagTiltX }
      if point.tiltY != nil { flags |= flagTiltY }
    }
    return flags
  }

  private static func writeDeltas(
    _ writer: inout Writer,
    _ points: [RemoteDrawNormalizedPoint],
    _ quantizePoint: (RemoteDrawNormalizedPoint) -> Int32
  ) {
    var previous: Int32 = 0
    for point in points {
      let value = quantizePoint(point)
      writer.zigzag(value &- previous)
      previous = value
    }
  }

  private static func readDeltas(_ reader: inout Reader, _ count: Int) throws -> [Int32] {
    var values: [Int32] = []
    values.reserveCapacity(count)
    var previous: Int32 = 0
    for _ in 0..<count {
      previous = previous &+ (try reader.zigzag())
      values.append(previous)
    }
    return values
  }

  private static func toBase64Url(_ bytes: [UInt8]) -> String {
    var out = ""
    out.reserveCapacity((bytes.count + 2) / 3 * 4)
    var index = 0
    while index < bytes.count {
      let a = bytes[index]
      let b: UInt8? = index + 1 < bytes.count ? bytes[index + 1] : nil
      let c: UInt8? = index + 2 < bytes.count ? bytes[index + 2] : nil
      out.append(base64url[Int(a >> 2)])
      out.append(base64url[Int(((a & 3) << 4) | ((b ?? 0) >> 4))])
      if b == nil { break }
      out.append(base64url[Int(((b! & 15) << 2) | ((c ?? 0) >> 6))])
      if c == nil { break }
      out.append(base64url[Int(c! & 63)])
      index += 3
    }
    return out
  }

  private static let base64urlIndex: [Character: UInt8] = {
    var table: [Character: UInt8] = [:]
    for (index, character) in base64url.enumerated() {
      table[character] = UInt8(index)
    }
    return table
  }()

  private static func fromBase64Url(_ text: String) throws -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(text.count * 3 / 4 + 1)
    var accumulator: UInt32 = 0
    var bits = 0
    for character in text {
      guard let value = base64urlIndex[character] else {
        throw RemoteDrawPointCodecError.invalidCharacter(character)
      }
      accumulator = (accumulator << 6) | UInt32(value)
      bits += 6
      if bits >= 8 {
        bits -= 8
        bytes.append(UInt8((accumulator >> UInt32(bits)) & 0xff))
      }
    }
    return bytes
  }

  /// Packs a point stream into a URL-safe string.
  public static func pack(_ points: [RemoteDrawNormalizedPoint]) -> String {
    var writer = Writer()
    let flags = channelFlags(points)
    writer.byte(version)
    writer.byte(flags)
    writer.varint(UInt32(truncatingIfNeeded: points.count))

    writeDeltas(&writer, points) { quantize(clamp($0.x, 0, 1) * xyScale) }
    writeDeltas(&writer, points) { quantize(clamp($0.y, 0, 1) * xyScale) }
    if flags & flagT != 0 {
      writeDeltas(&writer, points) { quantize(clamp($0.t ?? 0, 0, tMax)) }
    }
    if flags & flagPressure != 0 {
      writeDeltas(&writer, points) {
        quantize(clamp($0.pressure ?? 0, 0, 1) * pressureScale)
      }
    }
    if flags & flagTiltX != 0 {
      writeDeltas(&writer, points) {
        quantize((clamp($0.tiltX ?? 0, -90, 90) + 90) / tiltRange * tiltScale)
      }
    }
    if flags & flagTiltY != 0 {
      writeDeltas(&writer, points) {
        quantize((clamp($0.tiltY ?? 0, -90, 90) + 90) / tiltRange * tiltScale)
      }
    }
    return toBase64Url(writer.bytes)
  }

  /// Unpacks a point stream.
  ///
  /// Throws on anything malformed rather than returning a partial stroke — a
  /// half-decoded stroke would render as a real one.
  ///
  /// - Parameter maxPoints: refuses a stream that declares more points than
  ///   this. A packed header is two bytes and a count, so a hostile or corrupt
  ///   string can ask for an allocation far larger than any stroke.
  public static func unpack(
    _ packed: String,
    maxPoints: Int? = nil
  ) throws -> [RemoteDrawNormalizedPoint] {
    var reader = Reader(try fromBase64Url(packed))
    let streamVersion = try reader.byte()
    guard streamVersion == version else {
      throw RemoteDrawPointCodecError.unsupportedVersion(streamVersion)
    }
    let flags = try reader.byte()
    let count = Int(try reader.varint())
    if let maxPoints, count > maxPoints {
      throw RemoteDrawPointCodecError.tooManyPoints(declared: count, limit: maxPoints)
    }

    let xs = try readDeltas(&reader, count)
    let ys = try readDeltas(&reader, count)
    let ts = flags & flagT != 0 ? try readDeltas(&reader, count) : nil
    let pressures = flags & flagPressure != 0 ? try readDeltas(&reader, count) : nil
    let tiltXs = flags & flagTiltX != 0 ? try readDeltas(&reader, count) : nil
    let tiltYs = flags & flagTiltY != 0 ? try readDeltas(&reader, count) : nil
    guard reader.isDone else {
      throw RemoteDrawPointCodecError.trailingBytes
    }

    var points: [RemoteDrawNormalizedPoint] = []
    points.reserveCapacity(count)
    for index in 0..<count {
      points.append(
        RemoteDrawNormalizedPoint(
          x: clamp(Double(xs[index]) / xyScale, 0, 1),
          y: clamp(Double(ys[index]) / xyScale, 0, 1),
          t: ts.map { max(0, Double($0[index])) },
          pressure: pressures.map { clamp(Double($0[index]) / pressureScale, 0, 1) },
          tiltX: tiltXs.map { clamp(Double($0[index]) / tiltScale * tiltRange - 90, -90, 90) },
          tiltY: tiltYs.map { clamp(Double($0[index]) / tiltScale * tiltRange - 90, -90, 90) }
        ))
    }
    return points
  }
}

/// Worst-case error each channel takes on, in that channel's own units.
/// Mirrors `POINT_CODEC_TOLERANCE`.
public enum RemoteDrawPointCodecTolerance {
  /// Normalized `0...1`; 1/65535 is ~0.015 surface units.
  public static let xy = 1.0 / 65535.0
  public static let pressure = 1.0 / 255.0
  /// Degrees.
  public static let tilt = 180.0 / 255.0
  /// Milliseconds.
  public static let t = 1.0
}

public enum RemoteDrawPointCodecError: Error, Equatable, CustomStringConvertible {
  case truncated
  case malformedVarint
  case trailingBytes
  case invalidCharacter(Character)
  case unsupportedVersion(UInt8)
  case tooManyPoints(declared: Int, limit: Int)

  public var description: String {
    switch self {
    case .truncated:
      return "Truncated packed point stream."
    case .malformedVarint:
      return "Malformed varint in packed point stream."
    case .trailingBytes:
      return "Trailing bytes in packed point stream."
    case .invalidCharacter(let character):
      return "Invalid character '\(character)' in packed point stream."
    case .unsupportedVersion(let version):
      return "Unsupported packed point version \(version)."
    case .tooManyPoints(let declared, let limit):
      return "Packed stream declares \(declared) points, over the \(limit) limit."
    }
  }
}
