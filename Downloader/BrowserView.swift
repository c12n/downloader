import SwiftUI
import WebKit

// MARK: - Download capture model

struct PendingCapture: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let sizeBytes: Int64 // -1 when unknown
}

/// File extensions the browser treats as downloads when a link to one
/// is tapped (pages and media the web view can show are left alone).
private let downloadExtensions: Set<String> = [
    "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "tgz",
    "dmg", "pkg", "iso", "img", "exe", "msi", "deb", "ipa", "apk",
    "mp3", "m4a", "flac", "wav", "ogg", "opus", "aac",
    "mp4", "mkv", "avi", "mov", "wmv", "webm", "m4v",
    "torrent", "epub", "mobi", "azw3", "cbz", "cbr",
]

func isDownloadLink(_ url: URL) -> Bool {
    downloadExtensions.contains(url.pathExtension.lowercased())
}

func captureFilename(for url: URL, disposition: String?) -> String {
    if let disposition {
        if let name = filenameFromDisposition(disposition), !name.isEmpty {
            return sanitizeFilename(name)
        }
    }
    let last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
    return sanitizeFilename(last.isEmpty ? "download" : last)
}

/// Small Content-Disposition filename parser (same rules as the
/// download manager's): filename*=UTF-8''..., filename="...", filename=...
func filenameFromDisposition(_ header: String) -> String? {
    if let range = header.range(of: "filename\\*\\s*=\\s*[^']*''([^;]+)", options: .regularExpression) {
        let raw = String(header[range])
        if let last = raw.split(separator: "''").last {
            return String(last).removingPercentEncoding ?? String(last)
        }
    }
    if let range = header.range(of: "filename\\s*=\\s*\"([^\"]+)\"", options: .regularExpression) {
        let m = String(header[range])
        if let first = m.firstIndex(of: "\""), let last = m.lastIndex(of: "\""), first != last {
            return String(m[m.index(after: first)..<last])
        }
    }
    if let range = header.range(of: "filename\\s*=\\s*([^;\\s]+)", options: .regularExpression) {
        let m = String(header[range])
        return String(m.split(separator: "=").last ?? "")
    }
    return nil
}

// MARK: - Browser model

@MainActor
final class BrowserModel: ObservableObject {
    @Published var addressText: String = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var progress: Double = 0
    @Published var pendingCapture: PendingCapture? = nil

    weak var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var rulesReady = false

    static let startURL = URL(string: "https://duckduckgo.com")!

    func attach(webView: WKWebView) {
        self.webView = webView
        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.progress = wv.estimatedProgress
                if wv.estimatedProgress >= 1 { self?.progress = 0 }
            }
        }
    }

    /// Compiles and attaches the bundled ad-block rule list, then
    /// loads the start page. With the blocker off, loads immediately.
    func prepareAndLoad() {
        guard let webView else { return }
        guard AppSettings.adBlockEnabled,
              let url = Bundle.main.url(forResource: "adblock-rules", withExtension: "json"),
              let json = try? String(contentsOf: url, encoding: .utf8) else {
            webView.load(URLRequest(url: Self.startURL))
            return
        }
        guard !rulesReady else {
            webView.load(URLRequest(url: Self.startURL))
            return
        }
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "downloader-adblock", encodedContentRuleList: json
        ) { [weak self] list, _ in
            Task { @MainActor in
                guard let self, let webView = self.webView else { return }
                if let list {
                    webView.configuration.userContentController.add(list)
                }
                self.rulesReady = true
                webView.load(URLRequest(url: Self.startURL))
            }
        }
    }

    func navigate(to text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let webView else { return }
        if let url = Self.urlFromAddressText(trimmed) {
            webView.load(URLRequest(url: url))
        }
    }

    static func urlFromAddressText(_ text: String) -> URL? {
        if let url = URL(string: text), url.scheme != nil { return url }
        let looksLikeHost = !text.contains(" ") && text.contains(".")
        if looksLikeHost, let url = URL(string: "https://" + text) { return url }
        let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? text
        return URL(string: "https://duckduckgo.com/?q=\(q)")
    }

    func proposeCapture(url: URL, filename: String, sizeBytes: Int64 = -1) {
        // One prompt at a time; a page firing several at once gets one.
        guard pendingCapture == nil else { return }
        pendingCapture = PendingCapture(url: url, filename: filename, sizeBytes: sizeBytes)
    }

    func syncNavState() {
        guard let webView else { return }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        if let u = webView.url { addressText = u.absoluteString }
    }
}

// MARK: - Web view wrapper

private struct WebViewRepresentable: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        model.attach(webView: webView)
        model.prepareAndLoad()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        init(model: BrowserModel) { self.model = model }

        // Pop-ups: never open a new window. A target=_blank link either
        // loads in this view or, if it points at a file, is captured.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                Task { @MainActor in
                    if isDownloadLink(url) {
                        self.model.proposeCapture(url: url, filename: captureFilename(for: url, disposition: nil))
                    } else if url.scheme == "http" || url.scheme == "https" {
                        webView.load(navigationAction.request)
                    }
                }
            }
            return nil
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            let scheme = url.scheme?.lowercased() ?? ""
            // Anything that is not a web page (app deep links, tel:,
            // intent:, ...) is dropped: ad pages love those.
            guard scheme == "http" || scheme == "https" || scheme == "about" else {
                decisionHandler(.cancel); return
            }
            // A tapped link to a file is a download, not a navigation.
            if navigationAction.navigationType == .linkActivated, isDownloadLink(url) {
                model.proposeCapture(url: url, filename: captureFilename(for: url, disposition: nil))
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            guard let url = navigationResponse.response.url else { decisionHandler(.allow); return }
            if let http = navigationResponse.response as? HTTPURLResponse {
                let disposition = http.value(forHTTPHeaderField: "Content-Disposition") ?? ""
                if disposition.lowercased().contains("attachment") {
                    model.proposeCapture(url: url,
                                          filename: captureFilename(for: url, disposition: disposition),
                                          sizeBytes: http.expectedContentLength)
                    decisionHandler(.cancel); return
                }
            }
            if !navigationResponse.canShowMIMEType {
                model.proposeCapture(url: url, filename: captureFilename(for: url, disposition: nil),
                                      sizeBytes: (navigationResponse.response as? HTTPURLResponse)?.expectedContentLength ?? -1)
                decisionHandler(.cancel); return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in self.model.syncNavState() }
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in self.model.syncNavState() }
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.model.syncNavState() }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in self.model.syncNavState() }
        }

        // JS dialogs are dismissed quietly (ad pages abuse them).
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            completionHandler()
        }
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            completionHandler(false)
        }
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                     defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (String?) -> Void) {
            completionHandler(nil)
        }
    }
}

// MARK: - Browser tab

struct BrowserView: View {
    @EnvironmentObject private var manager: DownloadManager
    @StateObject private var model = BrowserModel()
    @Binding var selectedTab: Int

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                if model.isLoading || model.progress > 0 {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                }
                WebViewRepresentable(model: model)
            }
            .navigationTitle("Browser")
            .navigationBarTitleDisplayMode(.inline)
            .alert(item: $model.pendingCapture) { capture in
                Alert(
                    title: Text("Download this file?"),
                    message: Text(captureMessage(capture)),
                    primaryButton: .default(Text("Download")) {
                        // Adds to the queue (debrid routing applies)
                        // and the scheduler starts it right away.
                        _ = manager.addURLs(text: capture.url.absoluteString,
                                            customFilename: capture.filename)
                        selectedTab = 0
                    },
                    secondaryButton: .cancel()
                )
            }
        }
    }

    private func captureMessage(_ capture: PendingCapture) -> String {
        var parts = [capture.filename]
        if capture.sizeBytes > 0 { parts.append(formatBytes(capture.sizeBytes)) }
        if let host = capture.url.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Button { model.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!model.canGoBack)
            Button { model.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!model.canGoForward)
            TextField("Search or enter an address", text: $model.addressText)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { model.navigate(to: model.addressText) }
            Button {
                if model.isLoading { model.webView?.stopLoading() } else { model.webView?.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}
