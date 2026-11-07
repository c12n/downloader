import Foundation
import UIKit

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var items: [DownloadItem] = []

    private var runners: [UUID: SegmentRunner] = [:]
    private var speedSamples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var speedTimer: Timer?
    private var progressSaveCounter = 0

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
        speedTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateSpeeds() }
        }
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
            if item.status == .downloading { item.status = .paused } // resume manually / via Resume All
            item.speedBytesPerSec = 0
            item.etaSeconds = -1
            return item
        }
    }

    // MARK: Adding

    /// Returns (added, invalidLineCount)
    @discardableResult
    func addURLs(text: String, customFilename: String) -> (Int, Int) {
        var added = 0, invalid = 0
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        for line in lines {
            guard let url = URL(string: line), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https", url.host != nil else { invalid += 1; continue }
            var name = ""
            if lines.count == 1 && !customFilename.trimmingCharacters(in: .whitespaces).isEmpty {
                name = sanitizeFilename(customFilename)
            } else {
                name = sanitizeFilename(url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent)
            }
            name = uniqueFilename(name)
            items.insert(DownloadItem(urlString: line, filename: name), at: 0)
            added += 1
        }
        if added > 0 { saveState(); schedule() }
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
        if let runner = runners[item.id] {
            items[idx].status = .paused
            runner.stop() // finish handler will persist segments
        } else if items[idx].status == .downloading || items[idx].status == .queued {
            items[idx].status = .paused
        }
        saveState()
        updateIdleTimer()
    }

    func resume(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        if items[idx].status == .completed { return }
        items[idx].status = .queued
        items[idx].errorMessage = nil
        saveState()
        schedule()
    }

    func retry(_ item: DownloadItem) { resume(item) }

    func delete(_ item: DownloadItem) {
        runners[item.id]?.stop()
        runners[item.id] = nil
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
        let active = runners.count
        guard active < AppSettings.maxSimultaneous else { return }
        for item in items where item.status == .queued {
            if runners.count >= AppSettings.maxSimultaneous { break }
            start(item)
        }
        updateIdleTimer()
    }

    private func start(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }), runners[item.id] == nil else { return }
        items[idx].status = .downloading
        let current = items[idx]
        if !current.probed {
            Task { await probeAndStart(current) }
        } else {
            startRunner(current)
        }
        updateIdleTimer()
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
        guard let idx = items.firstIndex(where: { $0.id == item.id }), runners[item.id] == nil,
              let url = URL(string: item.urlString) else { return }
        let id = item.id
        let runner = SegmentRunner(
            itemID: id, url: url, segments: items[idx].segments, partsDir: partsDir(for: id),
            onProgress: { [weak self] segs in
                Task { @MainActor in self?.applyProgress(id: id, segments: segs) }
            },
            onFinish: { [weak self] result, segs in
                Task { @MainActor in self?.applyFinish(id: id, result: result, segments: segs) }
            })
        runners[id] = runner
        runner.start()
    }

    private func applyProgress(id: UUID, segments: [SegmentInfo]) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].segments = segments
        progressSaveCounter += 1
        if progressSaveCounter % 20 == 0 { saveState() }
    }

    private func applyFinish(id: UUID, result: RunnerResult, segments: [SegmentInfo]) {
        runners[id] = nil
        guard let idx = items.firstIndex(where: { $0.id == id }) else { schedule(); return }
        items[idx].segments = segments
        switch result {
        case .paused:
            if items[idx].status == .downloading { items[idx].status = .paused }
            saveState()
        case .failed(let message):
            items[idx].status = .failed
            items[idx].errorMessage = message
            saveState()
        case .rangeIgnored:
            if !items[idx].rangeFallbackTried && items[idx].totalBytes > 0 {
                // One automatic retry as a clean single-stream download.
                items[idx].rangeFallbackTried = true
                items[idx].segments = [SegmentInfo(start: 0, end: items[idx].totalBytes - 1)]
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
                try? FileManager.default.removeItem(at: partsDir(for: id))
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
            let bytes = items[i].downloadedBytes
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
