import Foundation

/// A lossless JSON snapshot for host-specific models, not another read API.
///
/// SenderKit owns admission, revisions, ordering and credential generations.
/// A host may decode additional metadata from an *accepted* session or drawings
/// snapshot without starting its own maintenance loop. Unknown objects, arrays
/// and nulls survive; the SDK does not interpret product copy or selection state.
/// These payloads may contain private board data. Do not log or persist them as
/// diagnostics. They contain a snapshot, never a reusable admission grant.
public struct RemoteDrawSnapshotPayload: Decodable, Equatable, Sendable {
  private let value: JSON

  public init(from decoder: Decoder) throws {
    value = try JSON(from: decoder)
  }

  public func decode<T: Decodable>(_ type: T.Type) throws -> T {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
  }

  private init(value: JSON) {
    self.value = value
  }

  /// The plain dialect of a drawings answer: every item's `packedPoints`
  /// becomes a `points` array and the top-level `encoding` marker goes. A
  /// payload without packed items comes back unchanged.
  func expandingPackedDrawings() -> RemoteDrawSnapshotPayload {
    guard case .object(var root) = value, case .array(let items)? = root["items"] else {
      return self
    }
    var changed = root.removeValue(forKey: "encoding") != nil
    let expanded = items.map { item -> JSON in
      guard case .object(var fields) = item,
        case .string(let packed)? = fields.removeValue(forKey: "packedPoints")
      else { return item }
      changed = true
      fields["points"] = .array(PointCodec.unpackForDisplay(packed).map(JSON.point))
      return .object(fields)
    }
    guard changed else { return self }
    root["items"] = .array(expanded)
    return RemoteDrawSnapshotPayload(value: .object(root))
  }

  /// A drawings answer's `items`, one payload per element in served order.
  var drawingItems: [RemoteDrawSnapshotPayload]? {
    guard case .object(let root) = value, case .array(let items)? = root["items"] else {
      return nil
    }
    return items.map(RemoteDrawSnapshotPayload.init(value:))
  }

  /// A drawings answer as a whole list: `items` replaced by `items`, and the
  /// incremental-sync fields (`removedIds`, `cursor`, `reset`, `activeCount`)
  /// dropped, so a host sees the shape a whole-list read has always had.
  func wholeDrawingsList(_ items: [RemoteDrawSnapshotPayload]) -> RemoteDrawSnapshotPayload {
    guard case .object(var root) = value else { return self }
    for key in ["removedIds", "cursor", "reset", "activeCount"] { root.removeValue(forKey: key) }
    root["items"] = .array(items.map(\.value))
    return RemoteDrawSnapshotPayload(value: .object(root))
  }

  private indirect enum JSON: Codable, Equatable, Sendable {
    case object([String: JSON]), array([JSON]), string(String)
    case integer(Int64), unsigned(UInt64), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if c.decodeNil() { self = .null }
      else if let v = try? c.decode(Bool.self) { self = .bool(v) }
      else if let v = try? c.decode(Int64.self) { self = .integer(v) }
      else if let v = try? c.decode(UInt64.self) { self = .unsigned(v) }
      else if let v = try? c.decode(Double.self) { self = .number(v) }
      else if let v = try? c.decode(String.self) { self = .string(v) }
      else if let v = try? c.decode([JSON].self) { self = .array(v) }
      else { self = .object(try c.decode([String: JSON].self)) }
    }

    static func point(_ point: RemoteDrawNormalizedPoint) -> JSON {
      var fields: [String: JSON] = ["x": .number(point.x), "y": .number(point.y)]
      if let t = point.t { fields["t"] = .number(t) }
      if let pressure = point.pressure { fields["pressure"] = .number(pressure) }
      if let tiltX = point.tiltX { fields["tiltX"] = .number(tiltX) }
      if let tiltY = point.tiltY { fields["tiltY"] = .number(tiltY) }
      return .object(fields)
    }

    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      switch self {
      case .object(let v): try c.encode(v)
      case .array(let v): try c.encode(v)
      case .string(let v): try c.encode(v)
      case .integer(let v): try c.encode(v)
      case .unsigned(let v): try c.encode(v)
      case .number(let v): try c.encode(v)
      case .bool(let v): try c.encode(v)
      case .null: try c.encodeNil()
      }
    }
  }
}
