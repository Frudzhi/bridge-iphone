import SwiftUI
import WebKit

struct ContentView: View {
  @Environment(\.scenePhase) private var scenePhase
  @StateObject private var browser = ShtabBrowser()
  var body: some View {
    ZStack {
      Color(.systemBackground).ignoresSafeArea()
      ShtabWebView(browser: browser).ignoresSafeArea(.container, edges: .bottom)
      if let failure = browser.failure {
        ContentUnavailableView {
          Label("Штаб не открылся", systemImage: "exclamationmark.circle")
        } description: { Text(failure) } actions: {
          Button("Повторить") { browser.reload() }.buttonStyle(.borderedProminent)
        }.background(Color(.systemBackground))
      }
    }.preferredColorScheme(browser.preferredScheme)
      .sheet(isPresented: $browser.bluetoothSetup) { BluetoothSetup(control: browser.bluetooth) }
      .onAppear { browser.bluetooth.setActive(true) }
      .onChange(of: scenePhase) { _, value in browser.bluetooth.setActive(value != .background) }
  }
}

enum ShtabDestination {
  static let home = URL(string: "https://shtab.bagavievalexe.workers.dev")!
  static func isInternal(_ url: URL) -> Bool {
    if url.scheme == "blob" {
      guard let origin = URL(string: String(url.absoluteString.dropFirst(5))) else { return false }
      return isInternal(origin)
    }
    return url.scheme == "https" && url.host == home.host &&
      (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
  }
}

@MainActor
final class ShtabBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
  let webView: WKWebView
  @Published var failure: String?
  @Published var preferredScheme: ColorScheme?
  @Published var bluetoothSetup = false
  let bluetooth = BluetoothControl()
  private let refreshControl = UIRefreshControl()
  private var bundledNavigation: WKNavigation?

  func receiveTheme(_ message: WKScriptMessage) {
    guard message.frameInfo.isMainFrame,
          let url = message.frameInfo.request.url, ShtabDestination.isInternal(url),
          let theme = message.body as? String, ["auto", "light", "dark"].contains(theme) else { return }
    preferredScheme = theme == "dark" ? .dark : theme == "light" ? .light : nil
    webView.overrideUserInterfaceStyle = theme == "dark" ? .dark : theme == "light" ? .light : .unspecified
    UserDefaults.standard.set(theme, forKey: "shtabAppearance")
  }

  // All controls remain in Shtab. The only script message accepted by iOS is
  // a three-value appearance preference; scripts cannot issue native input.
  private static let integrationScript = """
    (() => {
      const syncTheme = () => {
        const theme = document.documentElement.dataset.theme || 'auto';
        if (['auto','light','dark'].includes(theme)) window.webkit.messageHandlers.shtabAppearance.postMessage(theme);
      };
      const integrate = () => {
        document.querySelector('#nav [data-pc="bridge"]')?.remove();
      };
      let viewport = document.querySelector('meta[name="viewport"]');
      if (!viewport) { viewport = document.createElement('meta'); viewport.name = 'viewport'; document.head.append(viewport); }
      viewport.content = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover';
      const style = document.createElement('style');
      style.textContent = 'html { touch-action: manipulation; } input, textarea, select { font-size:16px!important; }';
      document.head.append(style);
      new MutationObserver(syncTheme).observe(document.documentElement, {attributes:true, attributeFilter:['data-theme']});
      new MutationObserver(integrate).observe(document.body, {childList:true, subtree:true});
      syncTheme(); integrate();
    })();
    """

  @objc private func pulledToRefresh() {
    // Do not interrupt the remote-control panel or an unfinished edit form.
    webView.evaluateJavaScript("""
      if (!document.querySelector('#sheet:not([hidden])')) {
        if (window.__shtabSync) window.__shtabSync();
        else if (typeof refresh === 'function') refresh();
      }
      void 0;
      """) { [weak self] _, _ in
      self?.refreshControl.endRefreshing()
    }
  }

  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.userContentController.addUserScript(WKUserScript(source: Self.integrationScript,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    config.userContentController.addUserScript(WKUserScript(source: BridgeWebIntegration.script,
      injectionTime: .atDocumentEnd, forMainFrameOnly: true))
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    let saved = UserDefaults.standard.string(forKey: "shtabAppearance")
    preferredScheme = saved == "dark" ? .dark : saved == "light" ? .light : nil
    config.userContentController.add(ShtabThemeHandler(owner: self), name: "shtabAppearance")
    config.userContentController.addScriptMessageHandler(BridgeInputHandler(owner:self), contentWorld:.page, name:"bridgeControl")
    bluetooth.changed = { [weak self] in self?.publishBluetoothState() }
    refreshControl.addTarget(self, action: #selector(pulledToRefresh), for: .valueChanged)
    webView.scrollView.refreshControl = refreshControl
    webView.scrollView.alwaysBounceVertical = true
    webView.scrollView.pinchGestureRecognizer?.isEnabled = false
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    reload()
  }
  func reload() {
    failure = nil
    guard let resource = Bundle.main.url(forResource: "ShtabOffline", withExtension: "html"),
          let html = try? String(contentsOf: resource, encoding: .utf8) else {
      showLoadFailure()
      return
    }
    // The page renders its cache first and synchronizes in place on the live origin.
    bundledNavigation = webView.loadSimulatedRequest(URLRequest(url: ShtabDestination.home), responseHTML: html)
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    failure = nil
    refreshControl.endRefreshing()
    publishBluetoothState()
  }

  private func publishBluetoothState() {
    guard let data = try? JSONSerialization.data(withJSONObject:["ready":bluetooth.ready,"name":bluetooth.name,"status":bluetooth.status]),
          let json = String(data:data, encoding:.utf8) else { return }
    webView.evaluateJavaScript("window.__setBridgeNativeState?.(" + json + ")", completionHandler:nil)
  }
  func handleControl(_ message: WKScriptMessage, reply:@escaping (Any?,String?) -> Void) {
    guard message.frameInfo.isMainFrame, let url = message.frameInfo.request.url,
          ShtabDestination.isInternal(url), let body = message.body as? [String:Any], let op = body["op"] as? String else {
      reply(nil,"Недопустимый запрос"); return
    }
    if op == "setup" {
      bluetooth.configure(key:body["key"] as? String)
      bluetoothSetup = true
      reply(["ok":true],nil)
    } else if op == "input", let events = body["events"] as? [[String:Any]] {
      bluetooth.send(events:events, reply:reply)
    } else { reply(nil,"Недопустимая команда") }
  }
  private func showLoadFailure() {
    refreshControl.endRefreshing()
    failure = "Не удалось открыть Штаб. Попробуй ещё раз."
  }

  private func fail(_ navigation: WKNavigation?, _ error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    if navigation === bundledNavigation { showLoadFailure() }
    else { reload() }
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    fail(navigation, error)
  }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
    fail(navigation, error)
  }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    reload()
  }

  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
      decisionHandler(.cancel)
      reload()
    } else { decisionHandler(.allow) }
  }
  func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
               decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
    guard let url = action.request.url else { decisionHandler(.cancel); return }
    if ShtabDestination.isInternal(url) {
      if action.targetFrame == nil {
        webView.load(action.request)
        decisionHandler(.cancel)
      } else { decisionHandler(.allow) }
      return
    }
    if action.navigationType == .linkActivated,
       ["https", "http", "mailto", "tel", "tg"].contains(url.scheme ?? "") {
      UIApplication.shared.open(url)
    }
    decisionHandler(.cancel)
  }
}

private struct ShtabWebView: UIViewRepresentable {
  let browser: ShtabBrowser
  func makeUIView(context: Context) -> WKWebView { browser.webView }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
}

@MainActor
private final class ShtabThemeHandler: NSObject, WKScriptMessageHandler {
  weak var owner: ShtabBrowser?
  init(owner: ShtabBrowser) { self.owner = owner; super.init() }
  func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
    owner?.receiveTheme(message)
  }
}

@MainActor
private final class BridgeInputHandler: NSObject, WKScriptMessageHandlerWithReply {
  weak var owner: ShtabBrowser?
  init(owner:ShtabBrowser) { self.owner = owner; super.init() }
  func userContentController(_ userContentController:WKUserContentController, didReceive message:WKScriptMessage,
                             replyHandler:@escaping (Any?,String?) -> Void) {
    guard let owner = owner else { replyHandler(nil,"Приложение закрыто"); return }
    owner.handleControl(message, reply:replyHandler)
  }
}
