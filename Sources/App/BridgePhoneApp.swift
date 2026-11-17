import SwiftUI

/// App entry point. Rename this struct to match your app if you like — the
/// `@main` attribute is what matters, not the name.
@main
struct BridgePhoneApp: App {
  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
        // Pure model tests do not need a live WebKit/Bluetooth application host.
        Color.clear
      } else {
        ContentView()
      }
    }
  }
}
