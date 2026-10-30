import Foundation

enum BridgeTransport: String, CaseIterable {
  case bluetooth = "Bluetooth"
  case wifi = "Wi-Fi"
  case internet = "Интернет"
}

/// Adapters will supply real availability; this type never invents a connection.
enum TransportPolicy {
  static func preferred(available: Set<BridgeTransport>) -> BridgeTransport? {
    [BridgeTransport.bluetooth, .wifi, .internet].first { available.contains($0) }
  }
}
