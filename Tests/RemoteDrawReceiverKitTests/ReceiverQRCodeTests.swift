import XCTest
import CoreImage
@testable import RemoteDrawReceiverKit

final class ReceiverQRCodeTests: XCTestCase {
  func testQRDecodesToExactPairingURL() throws {
    let url = try XCTUnwrap(URL(string: "https://remotedraw.com/join?token=rd_join_development_fixture"))
    let bitmap = try XCTUnwrap(RemoteDrawReceiverQRCode.image(for: url))
    let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: CIContext(), options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
    let codes = detector.features(in: CIImage(cgImage: bitmap)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    XCTAssertEqual(codes, [url.absoluteString])
  }
}
