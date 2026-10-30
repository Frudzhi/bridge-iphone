import XCTest
@testable import BridgePhone

final class BridgePhoneTests: XCTestCase {
  func testBluetoothHasPriority() {
    XCTAssertEqual(TransportPolicy.preferred(available: [.bluetooth, .wifi, .internet]), .bluetooth)
  }
  func testFallsBackToWifiThenInternet() {
    XCTAssertEqual(TransportPolicy.preferred(available: [.wifi, .internet]), .wifi)
    XCTAssertEqual(TransportPolicy.preferred(available: [.internet]), .internet)
  }
  func testReturnsToBluetoothWhenItReappears() {
    XCTAssertEqual(TransportPolicy.preferred(available: [.wifi]), .wifi)
    XCTAssertEqual(TransportPolicy.preferred(available: [.wifi, .bluetooth]), .bluetooth)
  }
  func testOfflineDoesNotPretendToBeConnected() {
    XCTAssertNil(TransportPolicy.preferred(available: []))
  }
}
