import WebKit
import XCTest
@testable import BridgePhone

final class ShtabOfflineTests: XCTestCase {
  @MainActor
  func testBundledPageReadsCachedDataOnTheLiveOrigin() async throws {
    let resource = try XCTUnwrap(Bundle.main.url(forResource: "ShtabOffline", withExtension: "html"))
    let html = try String(contentsOf: resource, encoding: .utf8)
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .nonPersistent()
    config.userContentController.addUserScript(WKUserScript(source: """
      window.fetch = () => Promise.reject(new TypeError("Offline test"));
      localStorage.setItem("shtab_key", "offline-test-fixture");
      localStorage.setItem("shtab_data", JSON.stringify({tasks: []}));
      localStorage.setItem("shtab_view", "home");
      """, injectionTime: .atDocumentStart, forMainFrameOnly: true))

    let view = WKWebView(frame: .zero, configuration: config)
    let loaded = expectation(description: "Bundled page loaded")
    let observer = PageLoadObserver(loaded)
    view.navigationDelegate = observer
    view.loadSimulatedRequest(URLRequest(url: ShtabDestination.home), responseHTML: html)
    await fulfillment(of: [loaded], timeout: 15)
    XCTAssertNil(observer.error)

    let result = try await view.callAsyncJavaScript("""
      await Promise.all([plannerReady, proposalReady, taskQueueReady, hubSync]);
      return {
        origin: location.origin,
        signedIn: S.key === "offline-test-fixture",
        cached: Array.isArray(S.data?.tasks),
        offline: S.offline,
        rendered: !document.querySelector("#nav").hidden
      };
      """, arguments: [:], in: nil, contentWorld: .page)
    let state = try XCTUnwrap(result as? [String: Any])
    XCTAssertEqual(state["origin"] as? String, ShtabDestination.home.absoluteString)
    for key in ["signedIn", "cached", "offline", "rendered"] {
      XCTAssertEqual(state[key] as? Bool, true, key)
    }
  }
}

@MainActor
private final class PageLoadObserver: NSObject, WKNavigationDelegate {
  private let loaded: XCTestExpectation
  private(set) var error: Error?

  init(_ loaded: XCTestExpectation) {
    self.loaded = loaded
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    loaded.fulfill()
  }

  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    self.error = error
    loaded.fulfill()
  }
}
