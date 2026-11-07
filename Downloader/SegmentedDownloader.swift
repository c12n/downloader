import Foundation

enum RunnerResult {
    case finished
    case paused
    case failed(String)
    case rangeIgnored
}

/// The download engine: one background URLSession for the whole app.
/// Every segment of a download is one download task carrying a Range
/// request; the system keeps those tasks alive while the app is in
/// the background or even terminated, and replays their events when
/// the app comes back.
///
/// Bookkeeping is kept twice: in memory for live runs, and in a JSON
/// manifest on disk (segments + per-task records) so a relaunch can
/// pick up exactly where things stand. Part files live in
/// Application Support/Parts/<item-id>/part-<segment>, the same
/// layout the manager assembles from.
///
/// Segment counters only advance when a whole segment lands (a
/// download task delivers its bytes as one file). In-flight progress
/// is reported separately as live bytes for display.
final class BackgroundDownloadEngine: NSObject, URLSessionDownloadDelegate {
    var onProgress: ((UUID, [SegmentInfo], Int64) -> Void)?
    var onFinish: ((UUID, RunnerResult, [SegmentInfo]) -> Void)?
    var backgroundCompletionHandler: (() -> Void)?

    static let sessionIdentifier = "com.c12n.downloadmanager.downloads"

    private struct TaskRecord: Codable {
        var segment: Int
        var base: Int64      // segment.downloaded when this task was created
        var expected: Int64  // bytes this task should deliver; -1 = unknown
    }

    private struct ItemManifest: Codable {
        var segments: [SegmentInfo]
        var tasks: [String: TaskRecord] = [:]   // taskIdentifier -> record
        var pendingResult: String? = nil        // terminal result awaiting pickup
        var stopping: Bool = false
    }

    private struct ItemRun {
        var partsDir: URL
        var liveWritten: [Int: Int64] = [:]     // taskIdentifier -> bytes so far
        var lastProgressReport = Date.distantPast
    }

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "background-download-engine"
        return q
    }()

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 60 * 24 * 7
        return URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
    }()

    private var manifest: [String: ItemManifest] = [:]
    private var runs: [UUID: ItemRun] = [:]
    /// Items that produced any engine event since launch; the manager
    /// uses it to tell still-running downloads from orphaned ones.
    private(set) var touchedItems: Set<UUID> = []

    override init() {
        super.init()
        loadManifest()
        _ = session // create the session early so events reconnect
    }

    // MARK: Paths (deterministic, mirrors the manager's layout)

    private var supportDir: URL {
        let sup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: sup, withIntermediateDirectories: true)
        return sup
    }
    private var manifestFile: URL { supportDir.appendingPathComponent("engine-manifest.json") }
    func partsDir(for id: UUID) -> URL {
        let dir = supportDir.appendingPathComponent("Parts", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func partURL(_ partsDir: URL, _ index: Int) -> URL { partsDir.appendingPathComponent("part-\(index)") }
    private func resumeURL(_ partsDir: URL, _ index: Int) -> URL { partsDir.appendingPathComponent("resume-\(index)") }

    // MARK: Manifest persistence

    private func loadManifest() {
        guard let data = try? Data(contentsOf: manifestFile),
              let decoded = try? JSONDecoder().decode([String: ItemManifest].self, from: data) else { return }
        manifest = decoded
    }

    private func saveManifest() {
        if let data = try? JSONEncoder().encode(manifest) {
            try? data.write(to: manifestFile, options: .atomic)
        }
    }

    // MARK: Starting

    func start(itemID: UUID, url: URL, segments: [SegmentInfo], partsDir: URL) {
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            self.touchedItems.insert(itemID)
            try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
            self.manifest[itemID.uuidString] = ItemManifest(segments: segments)
            self.runs[itemID] = ItemRun(partsDir: partsDir)
            let pending = segments.enumerated().filter { !$0.element.isDone }
            if pending.isEmpty {
                self.finishRun(itemID, .finished)
                return
            }
            for (i, seg) in pending {
                self.createTask(itemID: itemID, url: url, index: i, segment: seg, partsDir: partsDir)
            }
            self.saveManifest()
        }
    }

    private func createTask(itemID: UUID, url: URL, index: Int, segment seg: SegmentInfo, partsDir: URL) {
        let key = itemID.uuidString
        var task: URLSessionDownloadTask
        let resumeFile = resumeURL(partsDir, index)
        if let data = try? Data(contentsOf: resumeFile), !data.isEmpty {
            task = session.downloadTask(withResumeData: data)
        } else {
            var req = URLRequest(url: url)
            let from = seg.start + seg.downloaded
            if seg.end >= 0 {
                req.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")
            } else if seg.downloaded > 0 {
                req.setValue("bytes=\(from)-", forHTTPHeaderField: "Range")
            }
            task = session.downloadTask(with: req)
        }
        task.taskDescription = "\(key)|\(index)"
        let expected: Int64 = seg.end >= 0 ? (seg.end - (seg.start + seg.downloaded) + 1) : -1
        manifest[key]?.tasks[String(task.taskIdentifier)] =
            TaskRecord(segment: index, base: seg.downloaded, expected: expected)
        task.resume()
    }

    // MARK: Pause / cancel

    /// Pause: cancel each task while keeping its resume data, so the
    /// segment continues from the same byte later. Reports .paused
    /// once every task has landed.
    func pause(itemID: UUID) {
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            let key = itemID.uuidString
            guard var entry = self.manifest[key] else { return }
            entry.stopping = true
            self.manifest[key] = entry
            self.saveManifest()
            let taskIDs = Set(entry.tasks.keys)
            if taskIDs.isEmpty {
                self.finishRun(itemID, .paused)
                return
            }
            let partsDir = self.runs[itemID]?.partsDir ?? self.partsDir(for: itemID)
            self.session.getAllTasks { tasks in
                for task in tasks where taskIDs.contains(String(task.taskIdentifier)) {
                    guard let dt = task as? URLSessionDownloadTask else { continue }
                    let segIdx = self.manifest[key]?.tasks[String(task.taskIdentifier)]?.segment
                    dt.cancel(byProducingResumeData: { data in
                        if let data, let segIdx {
                            try? data.write(to: self.resumeURL(partsDir, segIdx), options: .atomic)
                        }
                    })
                }
            }
        }
    }

    /// Delete: cancel everything and drop all bookkeeping silently.
    func cancel(itemID: UUID) {
        delegateQueue.addOperation { [weak self] in
            guard let self else { return }
            let key = itemID.uuidString
            let taskIDs = Set(self.manifest[key]?.tasks.keys ?? [])
            self.manifest.removeValue(forKey: key)
            self.runs.removeValue(forKey: itemID)
            self.saveManifest()
            if !taskIDs.isEmpty {
                self.session.getAllTasks { tasks in
                    for task in tasks where taskIDs.contains(String(task.taskIdentifier)) {
                        task.cancel()
                    }
                }
            }
        }
    }

    // MARK: Relaunch attach

    /// Runs work on the delegate queue (where all manifest access
    /// belongs) and returns its result, for callers on other threads.
    private func onQueue<T>(_ work: () -> T) -> T {
        if OperationQueue.current === delegateQueue { return work() }
        var out: T!
        let sem = DispatchSemaphore(value: 0)
        delegateQueue.addOperation { out = work(); sem.signal() }
        sem.wait()
        return out
    }

    /// Re-attaches a persisted download after relaunch. Returns a
    /// terminal result if the download finished (or failed) while the
    /// app was away; otherwise live tasks keep running and report
    /// through the normal callbacks. Returns nil when the engine has
    /// nothing for this item (orphaned state; the manager pauses it).
    func attach(itemID: UUID, segments: [SegmentInfo], partsDir: URL) -> RunnerResult? {
        onQueue { attachOnQueue(itemID: itemID, segments: segments, partsDir: partsDir) }
    }

    private func attachOnQueue(itemID: UUID, segments: [SegmentInfo], partsDir: URL) -> RunnerResult? {
        let key = itemID.uuidString
        guard let entry = manifest[key] else { return nil }
        touchedItems.insert(itemID)
        if let pending = entry.pendingResult {
            manifest.removeValue(forKey: key)
            runs.removeValue(forKey: itemID)
            saveManifest()
            switch pending {
            case "finished": return .finished
            case "rangeIgnored": return .rangeIgnored
            case let s where s.hasPrefix("failed:"): return .failed(String(s.dropFirst("failed:".count)))
            default: return .paused
            }
        }
        // Live run: rebuild from the manifest (its segments are the
        // freshest) and wait for task events.
        runs[itemID] = ItemRun(partsDir: partsDir)
        return nil
    }

    /// The freshest segment state the engine has for an item.
    func segments(for itemID: UUID) -> [SegmentInfo]? {
        onQueue { manifest[itemID.uuidString]?.segments }
    }

    func hasLiveWork(for itemID: UUID) -> Bool {
        onQueue {
            guard let entry = manifest[itemID.uuidString] else { return false }
            return !entry.tasks.isEmpty || entry.pendingResult != nil
        }
    }

    /// After relaunch, an item can claim manifest tasks that no
    /// longer exist (for example after a force-quit) and never
    /// produce events. For each candidate that stayed untouched and
    /// has no live task, drop the stale records and report it paused
    /// with the freshest segments, so the manager can settle it.
    func sweepOrphans(_ candidates: [UUID]) {
        guard !candidates.isEmpty else { return }
        // getAllTasks completions run on the delegate queue, where
        // touchedItems and the manifest live.
        session.getAllTasks { [weak self] tasks in
            guard let self else { return }
            let untouched = candidates.filter { !self.touchedItems.contains($0) }
            let liveIDs = Set(tasks.map { String($0.taskIdentifier) })
            for itemID in untouched {
                let key = itemID.uuidString
                guard let entry = self.manifest[key], entry.pendingResult == nil else { continue }
                let anyLive = entry.tasks.keys.contains { liveIDs.contains($0) }
                if !anyLive {
                    self.finishRun(itemID, .paused)
                }
            }
        }
    }

    // MARK: Run completion

    private func finishRun(_ itemID: UUID, _ result: RunnerResult) {
        let key = itemID.uuidString
        let segments = manifest[key]?.segments ?? []
        let hadRun = runs[itemID] != nil
        manifest.removeValue(forKey: key)
        runs.removeValue(forKey: itemID)
        saveManifest()
        if hadRun {
            onFinish?(itemID, result, segments)
        } else {
            // Nobody is listening (app was away): stash the result in
            // a fresh manifest entry for attach() to pick up.
            var entry = ItemManifest(segments: segments)
            switch result {
            case .finished: entry.pendingResult = "finished"
            case .rangeIgnored: entry.pendingResult = "rangeIgnored"
            case .failed(let m): entry.pendingResult = "failed:\(m)"
            case .paused: entry.pendingResult = "paused"
            }
            manifest[key] = entry
            saveManifest()
        }
    }

    private func failRun(_ itemID: UUID, _ result: RunnerResult) {
        // Cancel any sibling tasks, then finish with the result.
        let key = itemID.uuidString
        let taskIDs = Set(manifest[key]?.tasks.keys ?? [])
        manifest[key]?.tasks = [:]
        saveManifest()
        if !taskIDs.isEmpty {
            session.getAllTasks { tasks in
                for task in tasks where taskIDs.contains(String(task.taskIdentifier)) {
                    task.cancel()
                }
            }
        }
        finishRun(itemID, result)
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard let (itemID, record) = record(for: downloadTask) else { return }
        touchedItems.insert(itemID)
        runs[itemID]?.liveWritten[downloadTask.taskIdentifier] = totalBytesWritten
        guard var run = runs[itemID] else { return }
        let now = Date()
        guard now.timeIntervalSince(run.lastProgressReport) > 0.25 else { return }
        run.lastProgressReport = now
        runs[itemID] = run
        reportProgress(itemID)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // The temp file is deleted when this method returns: move or
        // append it into the segment's part file synchronously.
        guard let (itemID, record) = record(for: downloadTask) else { return }
        touchedItems.insert(itemID)
        let key = itemID.uuidString
        guard var entry = manifest[key] else { return }
        let partsDir = runs[itemID]?.partsDir ?? partsDir(for: itemID)

        let http = downloadTask.response as? HTTPURLResponse
        let status = http?.statusCode ?? 200
        guard (200...299).contains(status) else {
            failRun(itemID, .failed("HTTP \(status)"))
            return
        }
        let seg = entry.segments[record.segment]
        // A 200 where a range was owed means the server ignored the
        // Range header and sent the whole file into this slot.
        let rangeOwed = record.base > 0 || seg.start > 0 || entry.segments.count > 1
        if status == 200 && rangeOwed {
            failRun(itemID, .rangeIgnored)
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? NSNumber)?.int64Value ?? -1
        if record.expected >= 0 && size >= 0 && size != record.expected {
            if size > record.expected {
                failRun(itemID, .rangeIgnored)
            } else {
                failRun(itemID, .failed("Server sent an incomplete segment."))
            }
            return
        }
        let part = partURL(partsDir, record.segment)
        do {
            if record.base > 0 && FileManager.default.fileExists(atPath: part.path) {
                // Append this task's bytes to the segment's part file.
                let incoming = try Data(contentsOf: location)
                let handle = try FileHandle(forWritingTo: part)
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: incoming)
                try handle.close()
            } else {
                try? FileManager.default.removeItem(at: part)
                try FileManager.default.moveItem(at: location, to: part)
            }
        } catch {
            failRun(itemID, .failed("Write failed: \(error.localizedDescription)"))
            return
        }
        entry.segments[record.segment].downloaded = record.base + max(size, 0)
        entry.tasks.removeValue(forKey: String(downloadTask.taskIdentifier))
        manifest[key] = entry
        try? FileManager.default.removeItem(at: resumeURL(partsDir, record.segment))
        runs[itemID]?.liveWritten.removeValue(forKey: downloadTask.taskIdentifier)
        saveManifest()
        reportProgress(itemID)
        if entry.tasks.isEmpty {
            if entry.stopping {
                finishRun(itemID, .paused)
            } else if entry.segments.allSatisfy({ $0.isDone || $0.end < 0 }) {
                finishRun(itemID, .finished)
            } else {
                // Some segments never got tasks (should not happen):
                // treat as paused so the user can resume.
                finishRun(itemID, .paused)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let (itemID, record) = record(for: task) else { return }
        touchedItems.insert(itemID)
        let key = itemID.uuidString
        guard var entry = manifest[key] else { return }
        // Success was already accounted in didFinishDownloadingTo.
        if error == nil { return }
        let ns = error as NSError
        // Keep any resume data the system offers so a later resume
        // continues this segment instead of restarting it.
        if let data = ns.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            let partsDir = runs[itemID]?.partsDir ?? partsDir(for: itemID)
            try? data.write(to: resumeURL(partsDir, record.segment), options: .atomic)
        }
        entry.tasks.removeValue(forKey: String(task.taskIdentifier))
        manifest[key] = entry
        runs[itemID]?.liveWritten.removeValue(forKey: task.taskIdentifier)
        saveManifest()
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
            if entry.tasks.isEmpty {
                finishRun(itemID, .paused)
            }
            return
        }
        if entry.stopping {
            if entry.tasks.isEmpty { finishRun(itemID, .paused) }
            return
        }
        failRun(itemID, .failed(error?.localizedDescription ?? "Download failed."))
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }

    // MARK: Helpers

    private func record(for task: URLSessionTask) -> (UUID, TaskRecord)? {
        guard let desc = task.taskDescription,
              let sep = desc.firstIndex(of: "|"),
              let itemID = UUID(uuidString: String(desc[..<sep])),
              let rec = manifest[itemID.uuidString]?.tasks[String(task.taskIdentifier)] else { return nil }
        return (itemID, rec)
    }

    private func reportProgress(_ itemID: UUID) {
        guard let entry = manifest[itemID.uuidString] else { return }
        var live: Int64 = 0
        for (i, seg) in entry.segments.enumerated() {
            // In-flight contribution: base + written for active tasks.
            var best = seg.downloaded
            if let run = runs[itemID] {
                for (taskID, written) in run.liveWritten {
                    if let rec = entry.tasks[String(taskID)], rec.segment == i {
                        best = max(best, rec.base + written)
                    }
                }
            }
            live += best
        }
        onProgress?(itemID, entry.segments, live)
    }
}
