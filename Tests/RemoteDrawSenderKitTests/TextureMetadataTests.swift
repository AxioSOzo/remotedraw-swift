import XCTest
@testable import RemoteDrawSenderKit

final class TextureMetadataTests: XCTestCase {
  func testPhysicalStyleSurvivesDecodeEncodeWithoutLosingBillingAndRenderingMetadata() throws {
    let json = ##"{"kind":"ink","color":"#236DAD","width":16,"textureMode":"experimental-3d","textureMaterial":"oil","textureSurface":"glass"}"##
    let style = try JSONDecoder().decode(RemoteDrawDrawingStyle.self, from: Data(json.utf8))
    XCTAssertEqual(style.textureMode, "experimental-3d")
    XCTAssertEqual(style.textureMaterial, "oil")
    XCTAssertEqual(style.textureSurface, "glass")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? NSDictionary
    let original = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? NSDictionary
    XCTAssertEqual(encoded, original)
  }

  func testLegacyStyleDoesNotInventPhysicalMaterialOrChargeMetadata() throws {
    let style = RemoteDrawDrawingStyle(kind: .pencil, width: 6)
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as! [String: Any]
    XCTAssertNil(encoded["textureMode"])
    XCTAssertNil(encoded["textureMaterial"])
    XCTAssertNil(encoded["textureSurface"])
  }

  func testUnknownFutureMaterialRemainsRoundTrippable() throws {
    let style = RemoteDrawDrawingStyle(kind: .ink, textureMode: "future-mode", textureMaterial: "future-material", textureSurface: "future-surface")
    XCTAssertEqual(try JSONDecoder().decode(RemoteDrawDrawingStyle.self, from: JSONEncoder().encode(style)), style)
  }
}
