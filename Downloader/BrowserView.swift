import SwiftUI
import WebKit

// MARK: - Download capture model

struct PendingCapture: Identifiable {
    let id = UUID()
    let url: URL
    let filename: String
    let sizeBytes: Int64 // -1 when unknown
}

struct PendingMagnet: Identifiable {
    let id = UUID()
    let magnet: String
    let name: String
}

/// One downloadable link found on the current page.
struct FoundLink: Identifiable {
    let id = UUID()
    let urlString: String
    let title: String
    var isMagnet: Bool { DebridLinks.isMagnet(urlString) }
}

struct BrowserBookmark: Codable, Identifiable {
    var id = UUID()
    var title: String
    var urlString: String
}

/// Wrapper so a scan result can drive a .sheet(item:).
struct GrabResult: Identifiable {
    let id = UUID()
    let links: [FoundLink]
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
    @Published var pendingMagnet: PendingMagnet? = nil
    @Published var bookmarks: [BrowserBookmark] = []

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

    func proposeMagnet(_ magnet: String) {
        guard pendingMagnet == nil, pendingCapture == nil else { return }
        pendingMagnet = PendingMagnet(magnet: magnet, name: DebridLinks.magnetName(magnet))
    }

    // MARK: Grab all links

    /// Scans the page for links to downloadable files (and magnets)
    /// and returns them in page order, de-duplicated.
    func scanLinks(completion: @escaping ([FoundLink]) -> Void) {
        guard let webView else { completion([]); return }
        let js = """
        Array.from(document.querySelectorAll('a[href]')).map(a => ({
            href: a.href,
            text: (a.textContent || '').trim().slice(0, 120)
        }))
        """
        webView.evaluateJavaScript(js) { result, _ in
            var found: [FoundLink] = []
            var seen = Set<String>()
            for entry in (result as? [[String: Any]]) ?? [] {
                guard let href = entry["href"] as? String, !href.isEmpty,
                      !seen.contains(href) else { continue }
                let isMagnet = DebridLinks.isMagnet(href)
                if !isMagnet {
                    guard let url = URL(string: href), isDownloadLink(url) else { continue }
                }
                seen.insert(href)
                let text = (entry["text"] as? String) ?? ""
                found.append(FoundLink(urlString: href,
                                       title: text.isEmpty ? href : text))
            }
            Task { @MainActor in completion(found) }
        }
    }

    // MARK: Bookmarks

    private static let bookmarksKey = "browser.bookmarks"

    func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: Self.bookmarksKey),
           let decoded = try? JSONDecoder().decode([BrowserBookmark].self, from: data) {
            bookmarks = decoded
        }
    }

    func addCurrentPageBookmark() {
        guard let webView, let url = webView.url else { return }
        let title = (webView.title?.isEmpty == false) ? webView.title! : (url.host ?? url.absoluteString)
        bookmarks.append(BrowserBookmark(title: title, urlString: url.absoluteString))
        saveBookmarks()
    }

    func removeBookmarks(at offsets: IndexSet) {
        bookmarks.remove(atOffsets: offsets)
        saveBookmarks()
    }

    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.bookmarksKey)
        }
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
                    if url.scheme?.lowercased() == "magnet" {
                        self.model.proposeMagnet(url.absoluteString)
                    } else if isDownloadLink(url) {
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
            // A tapped magnet goes to the debrid flow, not navigation.
            if scheme == "magnet" {
                model.proposeMagnet(url.absoluteString)
                decisionHandler(.cancel); return
            }
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
    @State private var grabResult: GrabResult? = nil
    @State private var showingBookmarks = false

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
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            model.scanLinks { grabResult = GrabResult(links: $0) }
                        } label: { Label("Grab all links on this page", systemImage: "tray.and.arrow.down") }
                        Button {
                            model.addCurrentPageBookmark()
                        } label: { Label("Bookmark this page", systemImage: "bookmark") }
                        Button {
                            showingBookmarks = true
                        } label: { Label("Bookmarks", systemImage: "book") }
                        Button {
                            model.webView?.load(URLRequest(url: BrowserModel.startURL))
                        } label: { Label("Home", systemImage: "house") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
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
            .sheet(item: $grabResult) { result in
                GrabLinksSheet(links: result.links) { chosen in
                    _ = manager.addURLs(text: chosen.joined(separator: "\n"), customFilename: "")
                    grabResult = nil
                    if !chosen.isEmpty { selectedTab = 0 }
                } onCancel: { grabResult = nil }
            }
            .sheet(isPresented: $showingBookmarks) {
                BookmarksSheet(model: model)
            }
            .onAppear { model.loadBookmarks() }
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
        .alert(item: $model.pendingMagnet) { pending in
            Alert(
                title: Text("Add this magnet?"),
                message: Text(magnetMessage(pending)),
                primaryButton: .default(Text("Add")) {
                    _ = manager.addURLs(text: pending.magnet, customFilename: "")
                    selectedTab = 0
                },
                secondaryButton: .cancel()
            )
        }
    }

    private func magnetMessage(_ pending: PendingMagnet) -> String {
        if let service = DebridStore.shared.firstVerified() {
            return "\(pending.name)\nIt will be fetched through \(service.displayName)."
        }
        return "\(pending.name)\nAdd and verify a debrid key in Settings first; the magnet will wait in your queue."
    }
}

// MARK: - Grab-all-links sheet

private struct GrabLinksSheet: View {
    let links: [FoundLink]
    var onAdd: ([String]) -> Void
    var onCancel: () -> Void
    @State private var selected: Set<String>

    init(links: [FoundLink], onAdd: @escaping ([String]) -> Void, onCancel: @escaping () -> Void) {
        self.links = links
        self.onAdd = onAdd
        self.onCancel = onCancel
        _selected = State(initialValue: Set(links.map(\.urlString)))
    }

    var body: some View {
        NavigationStack {
            Group {
                if links.isEmpty {
                    ContentUnavailableView("No download links found",
                                           systemImage: "tray.and.arrow.down",
                                           description: Text("This page has no links to files the app recognises."))
                } else {
                    List {
                        ForEach(links) { link in
                            Button {
                                if selected.contains(link.urlString) {
                                    selected.remove(link.urlString)
                                } else {
                                    selected.insert(link.urlString)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: selected.contains(link.urlString) ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected.contains(link.urlString) ? Color.accentColor : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(link.isMagnet ? link.title : (URL(string: link.urlString)?.lastPathComponent ?? link.title))
                                            .font(.subheadline).lineLimit(2)
                                        Text(link.isMagnet ? "Magnet link" : (URL(string: link.urlString)?.host ?? link.urlString))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Links on this page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { onCancel() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Select all") { selected = Set(links.map(\.urlString)) }
                        Button("Select none") { selected = [] }
                    } label: { Image(systemName: "checklist") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") { onAdd(links.filter { selected.contains($0.urlString) }.map(\.urlString)) }
                        .disabled(selected.isEmpty)
                }
            }
        }
    }
}

// MARK: - Bookmarks sheet

private struct BookmarksSheet: View {
    @ObservedObject var model: BrowserModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.bookmarks.isEmpty {
                    ContentUnavailableView("No bookmarks yet",
                                           systemImage: "book",
                                           description: Text("Use Bookmark this page in the browser menu."))
                } else {
                    List {
                        ForEach(model.bookmarks) { mark in
                            Button {
                                if let url = URL(string: mark.urlString) {
                                    model.webView?.load(URLRequest(url: url))
                                }
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mark.title).font(.subheadline).lineLimit(1)
                                    Text(mark.urlString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { model.removeBookmarks(at: $0) }
                    }
                }
            }
            .navigationTitle("Bookmarks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
