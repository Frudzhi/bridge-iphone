import SwiftUI
import WebKit

struct ContentView: View {
  var body: some View {
    TabView {
      ShtabScreen().tabItem { Label("Штаб", systemImage: "square.grid.2x2.fill") }
      NavigationStack {
        List {
          Section("Подключение к ноутбуку") {
            Label("Bluetooth → Wi-Fi → интернет", systemImage: "antenna.radiowaves.left.and.right")
            Text("Прямой Bluetooth ещё в разработке.").foregroundStyle(.secondary)
          }
          Section("Управление") {
            Text("Кликер и тачпад через интернет: открой «Штаб» → «Пульт».")
          }
        }.navigationTitle("Bridge")
      }.tabItem { Label("Bridge", systemImage: "laptopcomputer.and.iphone") }
    }
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
  @Published var loading = true
  @Published var failure: String?
  override init() {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    webView = WKWebView(frame: .zero, configuration: config)
    super.init()
    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.allowsBackForwardNavigationGestures = true
    reload()
  }
  func reload() {
    failure = nil
    loading = true
    if webView.url == nil { webView.load(URLRequest(url: ShtabDestination.home)) }
    else { webView.reload() }
  }
  func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
    loading = true
    failure = nil
  }
  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false }
  private func fail(_ error: Error) {
    guard (error as NSError).code != NSURLErrorCancelled else { return }
    loading = false
    failure = "Проверь подключение к интернету и попробуй снова."
  }
  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
  func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
  func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
    loading = false
    failure = "Штаб был выгружен из памяти. Нажми «Повторить», чтобы открыть его снова."
  }
  func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
               decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
    if response.isForMainFrame, let http = response.response as? HTTPURLResponse, http.statusCode >= 400 {
      loading = false
      failure = "Сервер Штаба недоступен (" + String(http.statusCode) + "). Попробуй снова немного позже."
      decisionHandler(.cancel)
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

private struct ShtabScreen: View {
  @StateObject private var browser = ShtabBrowser()
  var body: some View {
    NavigationStack {
      ZStack {
        ShtabWebView(browser: browser)
        if browser.loading { ProgressView().padding(16).background(.regularMaterial, in: Capsule()) }
        if let failure = browser.failure {
          ContentUnavailableView {
            Label("Не удалось открыть Штаб", systemImage: "wifi.exclamationmark")
          } description: { Text(failure) } actions: {
            Button("Повторить") { browser.reload() }.buttonStyle(.borderedProminent)
          }.background(Color(.systemBackground))
        }
      }
      .navigationTitle("Штаб")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button { browser.reload() } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityLabel("Обновить Штаб")
        }
      }
    }
  }
}
