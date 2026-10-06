import XCTest
@testable import RemoteDrawInk

final class MaterialCapacityParityTests: XCTestCase {
  func testMatchesTypeScriptMaterialCapacityVectors() {
    // Direct samples from client/dabEngine.ts materialCapacityHeight. Pin the
    // actual spatial fields, including negative coordinates and tile wrapping.
    let vectors: [(Double, Double, [Double])] = [
      (0.5, 0.5, [0.5698123292940616, 0.6376298896191831, 0.6351216457761386, 0.39820681206116504]),
      (73.25, 119.75, [0.5392938917082443, 0.5134663065812367, 0.2607070494316468, 0.5562256404396889]),
      (-2.5, 514.25, [0.6063407182511368, 0.6007621905968286, 0.4189145494713389, 0.5450649124627429]),
    ]
    for (x, y, values) in vectors {
      for texture in 1...4 {
        XCTAssertEqual(RemoteDrawPaperGround.materialCapacityHeight(x, y, grain: 11, texture: texture), values[texture - 1], accuracy: 1e-10)
        XCTAssertEqual(RemoteDrawPaperGround.materialCapacityHeight(x + 512, y - 512, grain: 11, texture: texture), values[texture - 1], accuracy: 1e-10)
      }
    }
  }

  func testCapacityIdentitySeparatesDryFamiliesWithoutChangingGround() {
    XCTAssertEqual(RemoteDrawInk.capacity(for: .pencil)?.texture, 1)
    XCTAssertEqual(RemoteDrawInk.capacity(for: .tiltPencil)?.texture, 1)
    XCTAssertEqual(RemoteDrawInk.capacity(for: .chalk)?.texture, 2)
    XCTAssertEqual(RemoteDrawInk.capacity(for: .charcoal)?.texture, 3)
    XCTAssertEqual(RemoteDrawInk.capacity(for: .crayon)?.texture, 4)
    XCTAssertEqual(RemoteDrawInk.capacity(for: .dryBrush)?.texture, 0)
    XCTAssertEqual(RemoteDrawPaperGround.materialCapacityHeight(42, 81, grain: 11), RemoteDrawPaperGround.height(42, 81, grain: 11))
    XCTAssertEqual(RemoteDrawPaperGround.materialCapacityHeight(42, 81, grain: nil, texture: 3), 1)
    XCTAssertEqual(RemoteDrawPaperGround.materialCapacityHeight(.infinity, 81, grain: 11, texture: 3), 0.5)
  }
}
