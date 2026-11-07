import Foundation
import UIKit
import Network
import UserNotifications

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    /// Whether the current network path includes Wi-Fi (or wired).
    /// Only enforced when the Wi-Fi-only setting is on.
    @Published private(set) var wifiAvailable = true

    let engine = BackgroundDownloadEngine()
    private var engineActive: Set<UUID> = []
    private var speedSamples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var speedTimer: Timer?
    private var progressSaveCounter = 0
    private let pathMonitor = NWPathMonitor()
    private var notificationAuthRequested = false

    // MARK: Paths

    private var downloadsDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var partsRoot: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = sup.appendingPathComponent("Parts", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private var stateFile: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: sup, withIntermediateDirectories: true)
        return sup.appendingPathComponent("state.json")
    }
    func partsDir(for id: UUID) -> URL { partsRoot.appendingPathComponent(id.uuidString, isDirectory: true) }
    func finalURL(for item: DownloadItem) -> URL { downloadsDir.appendingPathComponent(item.filename) }
    func fileExistsCompleted(_ item: DownloadItem) -> Bool {
        FileManager.default.fileExists(atPath: finalURL(for: item).path)
    }

    init() {
        loadState()
        // Wire the background engine. Downloads may have kept going
        // while the app was away; attach to whatever it still holds.
        engine.onProgress = { [weak self] id, segs, live in
            Task { @MainActor in self?.applyProgress(id: id, segments: segs, liveBytes: live) }
        }
        engine.onFinish = { [weak self] id, result, segs in
            Task { @MainActor in self?.applyFinish(id: id, result: result, segments: segs) }
        }
        BackgroundSessionRelay.shared.engine = engine
        if let pending = BackgroundSessionRelay.shared.pendingHandler {
            engine.backgroundCompletionHandler = pending
            BackgroundSessionRelay.shared.pendingHandler = nil
        }
        for item in items where item.status == .downloading {
            let preSegs = engine.segments(for: item.id)
            if let result = engine.attach(itemID: item.id, segments: item.segments, partsDir: partsDir(for: item.id)) {
                applyFinish(id: item.id, result: result, segments: preSegs ?? item.segments)
            } else {
                engineActive.insert(item.id)
                if let idx = items.firstIndex(where: { $0.id == item.id }), let segs = preSegs {
                    items[idx].segments = segs
                }
            }
        }
        // Anything still marked downloading that the engine knows
        // nothing about (and reports nothing for) settles as paused.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self else { return }
            self.engine.sweepOrphans(self.items.filter { $0.status == .downloading }.map(\.id))
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                guard let self else { return }
                let changed = self.wifiAvailable != wifi
                self.wifiAvailable = wifi
                if changed && wifi { self.schedule() }
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "path-monitor"))
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSpeeds() }
        }
        drainSharedLinks()
    }

    // MARK: Persistence

    private func saveState() {
        var snapshot = items
        for i in snapshot.indices { snapshot[i].speedBytesPerSec = 0; snapshot[i].etaSeconds = -1 }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: stateFile, options: .atomic)
        }
    }

    private func loadState() {
        guard let data = try? Data(contentsOf: stateFile),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }
        items = decoded.map { item in
            var item = item
            // Downloads run on a background session now: a .downloading
            // item may genuinely still be running, so it is NOT flipped
            // to paused here. init() attaches it to the engine, and the
            // orphan sweep settles any that are truly dead.
            item.speedBytesPerSec = 0
            item.etaSeconds = -1
            item.transientBytes = item.downloadedBytes
            item.debridPhase = nil
            return item
        }
    }

    // MARK: Adding

    /// Returns (added, invalidLineCount). Accepts http(s) links and
    /// magnet: URIs; exact duplicates of queued items are skipped.
    @discardableResult
    func addURLs(text: String, customFilename: String) -> (Int, Int) {
        var added = 0, invalid = 0
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines {
            if items.contains(where: { $0.urlString == line || $0.originalURLString == line }) {
                continue // already queued
            }
            if DebridLinks.isMagnet(line) {
                var item = DownloadItem(urlString: line, filename: uniqueFilename(DebridLinks.magnetName(line)))
                item.isMagnet = true
                item.originalURLString = line
                item.debridResolved = false
                if let service = DebridStore.shared.firstVerified() {
                    item.viaDebrid = service.displayName
                    item.debridService = service.rawValue
                }
                items.insert(item, at: 0)
                added += 1
                continue
            }
            guard let url = URL(string: line), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { invalid += 1; continue }
            var name = ""
            var isCustom = false
            if lines.count == 1 && !customFilename.trimmingCharacters(in: .whitespaces).isEmpty {
                name = sanitizeFilename(customFilename)
                isCustom = true
            } else {
                name = sanitizeFilename(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            }
            name = uniqueFilename(name)
            var item = DownloadItem(urlString: line, filename: name)
            item.customName = isCustom
            if url.pathExtension.lowercased() == "torrent",
               let service = DebridStore.shared.firstVerified() {
                // A .torrent file goes to a debrid service, which
                // fetches the torrent's contents as regular files.
                item.isTorrentFile = true
                item.viaDebrid = service.displayName
                item.debridService = service.rawValue
                item.originalURLString = line
                item.debridResolved = false
            } else if let host = url.host, let service = DebridStore.shared.service(forHost: host) {
                // Debrid routing: a link whose host is supported by a
                // service the user has tested and verified is fetched
                // through that service instead of directly.
                item.viaDebrid = service.displayName
                item.debridService = service.rawValue
                item.originalURLString = line
                item.debridResolved = false
            }
            items.insert(item, at: 0)
            added += 1
        }
        if added > 0 {
            requestNotificationAuthorizationOnce()
            saveState(); schedule()
        }
        return (added, invalid)
    }

    private func uniqueFilename(_ name: String) -> String {
        var candidate = name
        var n = 2
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        while items.contains(where: { $0.filename == candidate }) ||
              FileManager.default.fileExists(atPath: downloadsDir.appendingPathComponent(candidate).path) {
            candidate = ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"
            n += 1
        }
        return candidate
    }

    // MARK: Controls

    func pause(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        let wasActive = engineActive.contains(item.id)
        items[idx].status = .paused
        items[idx].debridPhase = nil
        if wasActive {
            // The engine cancels the segment tasks (keeping resume
            // data) and reports back; applyFinish settles the state.
            engine.pause(itemID: item.id)
        }
        saveState()
        updateIdleTimer()
    }

    /// Shared restart preparation: a debrid item re-resolves (direct
    /// links expire), and its stale part/resume files are dropped.
    private func resetForRestart(_ idx: Int) {
        if items[idx].debridService != nil, items[idx].debridResolved == true,
           let original = items[idx].originalURLString {
            items[idx].urlString = original
            items[idx].debridResolved = false
            items[idx].probed = false
            items[idx].segments = []
            items[idx].transientBytes = 0
            try? FileManager.default.removeItem(at: partsDir(for: items[idx].id))
        }
        items[idx].debridPhase = nil
    }

    func resume(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[idx].status == .completed { return }
        resetForRestart(idx)
        items[idx].status = .queued
        items[idx].errorMessage = nil
        saveState()
        schedule()
    }

    func retry(_ item: DownloadItem) {
        // A manual retry also earns a fresh automatic repair.
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].autoRetried = nil
        resume(item)
    }

    func delete(_ item: DownloadItem) {
        engine.cancel(itemID: item.id)
        engineActive.remove(item.id)
        try? FileManager.default.removeItem(at: partsDir(for: item.id))
        try? FileManager.default.removeItem(at: finalURL(for: item))
        items.removeAll { $0.id == item.id }
        saveState()
        schedule()
        updateIdleTimer()
    }

    func pauseAll() { for item in items where item.status == .downloading || item.status == .queued { pause(item) } }
    func resumeAll() {
        for i in items.indices where items[i].status == .paused || items[i].status == .failed {
            resetForRestart(i)
            items[i].status = .queued; items[i].errorMessage = nil
        }
        saveState(); schedule()
    }
    func clearCompleted() {
        // List entries only - the downloaded files stay in Documents/Downloads
        // (visible in the Files app) unless deleted per item.
        items.removeAll { $0.status == .completed }
        saveState()
    }

    // MARK: Scheduling

    private func schedule() {
        // Wi-Fi only: new downloads wait for a Wi-Fi path. Running
        // downloads are left alone if the path changes mid-flight.
        if AppSettings.wifiOnly && !wifiAvailable { updateIdleTimer(); return }
        let active = items.filter { $0.status == .downloading }.count
        guard active < AppSettings.maxSimultaneous else { return }
        for item in items where item.status == .queued {
            if items.filter({ $0.status == .downloading }).count >= AppSettings.maxSimultaneous { break }
            start(item)
        }
        updateIdleTimer()
    }

    private func start(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].status = .downloading
        let current = items[idx]
        if (current.isMagnet == true || current.isTorrentFile == true) && current.debridResolved != true {
            Task { await resolveTorrentAndStart(current) }
        } else if current.debridService != nil && current.debridResolved != true {
            Task { await resolveDebridAndStart(current) }
        } else if !current.probed {
            Task { await probeAndStart(current) }
        } else {
            startRunner(current)
        }
        updateIdleTimer()
    }

    /// Magnets and .torrent files: the debrid service fetches the
    /// torrent on its own servers (cached torrents are quick; fresh
    /// ones can take minutes, reported through debridPhase), then the
    /// resulting files download like any other debrid link. There is
    /// no direct-download fallback for a magnet, so a failure fails
    /// the item with the service's message.
    private func resolveTorrentAndStart(_ item: DownloadItem) async {
        guard let serviceID = DebridServiceID(rawValue: item.debridService ?? "") else {
            fail(item.id, "Magnets and torrents need a debrid service. Add a TorBox, Premiumize or Real-Debrid key in Settings and tap Test to verify it.")
            return
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].debridPhase = "\(serviceID.displayName): preparing torrent"
        saveState()
        do {
            let files: [DebridFile]
            let onPhase: (String) -> Void = { [weak self] text in
                Task { @MainActor in
                    guard let self, let i = self.items.firstIndex(where: { $0.id == item.id }),
                          self.items[i].status == .downloading else { return }
                    self.items[i].debridPhase = text
                }
            }
            if item.isMagnet == true {
                files = try await DebridStore.shared.resolveMagnet(item.urlString, service: serviceID, onPhase: onPhase)
            } else if let torrentURL = URL(string: item.originalURLString ?? item.urlString) {
                files = try await DebridStore.shared.resolveTorrentURL(torrentURL, service: serviceID, onPhase: onPhase)
            } else {
                throw DebridError.message("The torrent link is not valid.")
            }
            guard let idx = items.firstIndex(where: { $0.id == item.id }),
                  items[idx].status == .downloading else { return } // paused meanwhile
            items[idx].debridPhase = nil
            guard let first = files.first else { throw DebridError.message("The torrent contained no files.") }
            items[idx].urlString = first.directURL.absoluteString
            if let fn = first.filename, !fn.isEmpty {
                items[idx].filename = uniqueFilename(sanitizeFilename(fn))
            }
            items[idx].debridResolved = true
            for extra in files.dropFirst() {
                var extraItem = DownloadItem(
                    urlString: extra.directURL.absoluteString,
                    filename: uniqueFilename(sanitizeFilename(extra.filename ?? extra.directURL.lastPathComponent)))
                extraItem.viaDebrid = serviceID.displayName
                extraItem.debridService = serviceID.rawValue
                extraItem.originalURLString = item.originalURLString
                extraItem.debridResolved = true
                items.insert(extraItem, at: idx)
            }
            saveState()
            await probeAndStart(items[idx])
            schedule()
        } catch {
            guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
            items[idx].debridPhase = nil
            fail(item.id, (error as? DebridError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// Resolves a debrid-routed item's hoster link to direct link(s)
    /// through its service, then hands over to the normal probe/start.
    /// Any debrid failure falls back to downloading the hoster link
    /// directly, so the download is never worse off.
    private func resolveDebridAndStart(_ item: DownloadItem) async {
        guard let serviceID = DebridServiceID(rawValue: item.debridService ?? ""),
              let original = URL(string: item.originalURLString ?? item.urlString) else {
            await probeAndStart(item); return
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx].debridPhase = "Fetching via \(serviceID.displayName)"
        saveState()
        do {
            let files = try await DebridStore.shared.resolve(url: original, service: serviceID)
            guard let idx = items.firstIndex(where: { $0.id == item.id }),
                  items[idx].status == .downloading else { return } // paused meanwhile
            items[idx].debridPhase = nil
            guard let first = files.first else { throw DebridError.message("No files returned.") }
            items[idx].urlString = first.directURL.absoluteString
            if items[idx].customName != true, let fn = first.filename, !fn.isEmpty {
                items[idx].filename = uniqueFilename(sanitizeFilename(fn))
            }
            items[idx].debridResolved = true
            // Extra files in the same link become their own items,
            // already resolved.
            for extra in files.dropFirst() {
                var extraItem = DownloadItem(
                    urlString: extra.directURL.absoluteString,
                    filename: uniqueFilename(sanitizeFilename(extra.filename ?? extra.directURL.lastPathComponent)))
                extraItem.viaDebrid = serviceID.displayName
                extraItem.debridService = serviceID.rawValue
                extraItem.originalURLString = item.originalURLString
                extraItem.debridResolved = true
                items.insert(extraItem, at: idx)
            }
            saveState()
            await probeAndStart(items[idx])
            schedule()
        } catch {
            guard let idx = items.firstIndex(where: { $0.id == item.id }),
                  items[idx].status == .downloading else { return }
            items[idx].debridPhase = nil
            items[idx].viaDebrid = nil
            items[idx].debridService = nil
            items[idx].originalURLString = nil
            items[idx].debridResolved = nil
            saveState()
            await probeAndStart(items[idx])
        }
    }

    private func probeAndStart(_ item: DownloadItem) async {
        guard let url = URL(string: item.urlString) else { fail(item.id, "Invalid URL"); return }
        var total: Int64 = -1
        var ranges = false
        var dispositionName: String? = nil
        // HEAD first
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        if let (_, response) = try? await URLSession.shared.data(for: head),
           let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
            total = http.expectedContentLength
            if let ar = http.value(forHTTPHeaderField: "Accept-Ranges") { ranges = ar.lowercased().contains("bytes") }
            dispositionName = filenameFromDisposition(http.value(forHTTPHeaderField: "Content-Disposition"))
        }
        // Fall back to a 1-byte range GET to learn total + range support
        if total < 0 || !ranges {
            var get = URLRequest(url: url)
            get.setValue("bytes=0-0", forHTTPHeaderField: "Range")
            if let (_, response) = try? await URLSession.shared.data(for: get),
               let http = response as? HTTPURLResponse {
                if http.statusCode == 206 {
                    ranges = true
                    if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let slash = cr.lastIndex(of: "/") {
                        total = Int64(cr[cr.index(after: slash)...]) ?? total
                    }
                } else if (200...299).contains(http.statusCode), total < 0 {
                    total = http.expectedContentLength
                }
                if dispositionName == nil {
                    dispositionName = filenameFromDisposition(http.value(forHTTPHeaderField: "Content-Disposition"))
                }
            }
        }
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[idx].status != .downloading { return } // paused while probing
        items[idx].totalBytes = total
        items[idx].supportsRanges = ranges
        items[idx].probed = true
        // Adopt the server-provided filename if the current one is a bare
        // placeholder with no extension and the user gave no custom name.
        if let dn = dispositionName, !dn.isEmpty,
           !items[idx].filename.contains(".") {
            let old = items[idx]
            items[idx].filename = uniqueFilename(sanitizeFilename(dn))
            _ = old
        }
        items[idx].segments = makeSegments(total: total, ranges: ranges, existing: items[idx].segments)
        saveState()
        startRunner(items[idx])
    }

    private func filenameFromDisposition(_ header: String?) -> String? {
        guard let header else { return nil }
        // filename*=UTF-8''name or filename="name" or filename=name
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

    private func makeSegments(total: Int64, ranges: Bool, existing: [SegmentInfo]) -> [SegmentInfo] {
        if !existing.isEmpty, let first = existing.first, first.end == (total >= 0 ? existing.last!.end : -1), total >= 0, existing.last!.end == total - 1 {
            return existing // resume state matches this total
        }
        if !existing.isEmpty && total < 0 { return existing }
        let connections = AppSettings.connections
        if ranges, total >= 1_048_576, connections > 1 {
            let n = min(connections, max(1, Int(total / 262_144))) // at least ~256KB per segment
            let count = max(2, n)
            var segs: [SegmentInfo] = []
            let chunk = total / Int64(count)
            for i in 0..<count {
                let start = Int64(i) * chunk
                let end = (i == count - 1) ? total - 1 : start + chunk - 1
                segs.append(SegmentInfo(start: start, end: end))
            }
            return segs
        }
        return [SegmentInfo(start: 0, end: total >= 0 ? total - 1 : -1)]
    }

    private func startRunner(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }), !engineActive.contains(item.id),
              let url = URL(string: item.urlString) else { return }
        engineActive.insert(item.id)
        engine.start(itemID: item.id, url: url, segments: items[idx].segments, partsDir: partsDir(for: item.id))
    }

    private func applyProgress(id: UUID, segments: [SegmentInfo], liveBytes: Int64) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].segments = segments
        items[idx].transientBytes = liveBytes
        progressSaveCounter += 1
        if progressSaveCounter % 20 == 0 { saveState() }
    }

    private func applyFinish(id: UUID, result: RunnerResult, segments: [SegmentInfo]) {
        engineActive.remove(id)
        guard let idx = items.firstIndex(where: { $0.id == id }) else { schedule(); return }
        items[idx].segments = segments
        items[idx].transientBytes = segments.reduce(0) { $0 + $1.downloaded }
        switch result {
        case .paused:
            if items[idx].status == .downloading { items[idx].status = .paused }
            saveState()
        case .failed(let message):
            // Auto-repair: one automatic retry. For a debrid item the
            // restart re-resolves first, so an expired direct link
            // heals itself; anything else simply resumes.
            if items[idx].autoRetried != true {
                items[idx].autoRetried = true
                resetForRestart(idx)
                items[idx].status = .queued
                items[idx].errorMessage = nil
                saveState()
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    self?.schedule()
                }
                updateIdleTimer()
                return
            }
            items[idx].status = .failed
            items[idx].errorMessage = message
            saveState()
        case .rangeIgnored:
            if !items[idx].rangeFallbackTried && items[idx].totalBytes > 0 {
                // One automatic retry as a clean single-stream download.
                items[idx].rangeFallbackTried = true
                items[idx].segments = [SegmentInfo(start: 0, end: items[idx].totalBytes - 1)]
                items[idx].transientBytes = 0
                try? FileManager.default.removeItem(at: partsDir(for: id))
                items[idx].status = .downloading
                saveState()
                startRunner(items[idx])
                return
            }
            items[idx].status = .failed
            items[idx].errorMessage = "Server does not honour range requests for this file."
            saveState()
        case .finished:
            if assemble(item: items[idx]) {
                items[idx].status = .completed
                items[idx].errorMessage = nil
                items[idx].transientBytes = items[idx].totalBytes
                try? FileManager.default.removeItem(at: partsDir(for: id))
                notifyCompleted(items[idx])
            } else {
                items[idx].status = .failed
                items[idx].errorMessage = "Download finished but the file could not be assembled."
            }
            saveState()
        }
        updateIdleTimer()
        schedule()
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = .failed
        items[idx].errorMessage = message
        saveState()
        schedule()
    }

    // MARK: Notifications + shared links

    private func requestNotificationAuthorizationOnce() {
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = UserDefaults.standard.bool(forKey: "notifAuthRequested")
        guard !notificationAuthRequested else { return }
        notificationAuthRequested = true
        UserDefaults.standard.set(true, forKey: "notifAuthRequested")
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyCompleted(_ item: DownloadItem) {
        let content = UNMutableNotificationContent()
        content.title = "Download complete"
        content.body = item.filename
        content.sound = .default
        let request = UNNotificationRequest(identifier: "done-\(item.id.uuidString)",
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Links handed over by the share extension wait in the App Group
    /// container; drain them into the queue. Called at launch and
    /// whenever the app comes to the foreground.
    func drainSharedLinks() {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.c12n.downloadmanager") else { return }
        let file = container.appendingPathComponent("pending-links.json")
        guard let data = try? Data(contentsOf: file),
              let links = try? JSONDecoder().decode([String].self, from: data),
              !links.isEmpty else { return }
        try? FileManager.default.removeItem(at: file)
        addURLs(text: links.joined(separator: "\n"), customFilename: "")
    }

    /// Concatenate part files in segment order into Documents/Downloads.
    private func assemble(item: DownloadItem) -> Bool {
        let dir = partsDir(for: item.id)
        let dest = finalURL(for: item)
        try? FileManager.default.removeItem(at: dest)
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: dest) else { return false }
        defer { try? out.close() }
        do {
            for i in item.segments.indices {
                let part = dir.appendingPathComponent("part-\(i)")
                guard let input = try? FileHandle(forReadingFrom: part) else { return false }
                while true {
                    let chunk = try input.read(upToCount: 1_048_576) ?? Data()
                    if chunk.isEmpty { break }
                    try out.write(contentsOf: chunk)
                }
                try input.close()
            }
        } catch { return false }
        if item.totalBytes > 0 {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? -1
            if size != item.totalBytes { return false }
        }
        return true
    }

    // MARK: Speed / ETA / idle timer

    private func updateSpeeds() {
        let now = Date()
        for i in items.indices {
            let id = items[i].id
            let bytes = items[i].effectiveDownloaded
            if items[i].status == .downloading, let prev = speedSamples[id] {
                let dt = now.timeIntervalSince(prev.time)
                if dt > 0.4 {
                    let rate = Double(bytes - prev.bytes) / dt
                    items[i].speedBytesPerSec = items[i].speedBytesPerSec * 0.5 + rate * 0.5
                    speedSamples[id] = (bytes, now)
                    let remaining = items[i].totalBytes - bytes
                    items[i].etaSeconds = (remaining > 0 && items[i].speedBytesPerSec > 0)
                        ? Double(remaining) / items[i].speedBytesPerSec : -1
                }
            } else {
                speedSamples[id] = (bytes, now)
                if items[i].status != .downloading { items[i].speedBytesPerSec = 0; items[i].etaSeconds = -1 }
            }
        }
    }

    private func updateIdleTimer() {
        let anyActive = items.contains { $0.status == .downloading }
        UIApplication.shared.isIdleTimerDisabled = anyActive && AppSettings.keepAwake
    }
}
