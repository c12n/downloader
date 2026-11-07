import Foundation

enum RunnerResult {
    case finished
    case paused
    case failed(String)
    case rangeIgnored
}

/// Runs the segment data tasks for one download item.
/// All delegate callbacks land on a single serial queue, so file writes and
/// segment counters need no extra locking. Pause/cancel are also funnelled
/// onto that queue before handles are closed.
final class SegmentRunner: NSObject, URLSessionDataDelegate {
    let itemID: UUID
    private let url: URL
    private(set) var segments: [SegmentInfo]
    private let partsDir: URL
    private let onProgress: ([SegmentInfo]) -> Void
    private let onFinish: (RunnerResult, [SegmentInfo]) -> Void

    private let delegateQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        q.name = "segment-runner"
        return q
    }()
    private var session: URLSession?
    private var tasks: [Int: URLSessionDataTask] = [:]
    private var handles: [Int: FileHandle] = [:]
    private var completedTasks = 0
    private var totalTasks = 0
    private var stopping = false
    private var reported = false
    private var lastProgressReport = Date.distantPast

    init(itemID: UUID, url: URL, segments: [SegmentInfo], partsDir: URL,
         onProgress: @escaping ([SegmentInfo]) -> Void,
         onFinish: @escaping (RunnerResult, [SegmentInfo]) -> Void) {
        self.itemID = itemID
        self.url = url
        self.segments = segments
        self.partsDir = partsDir
        self.onProgress = onProgress
        self.onFinish = onFinish
        super.init()
    }

    func partURL(_ index: Int) -> URL { partsDir.appendingPathComponent("part-\(index)") }

    func start() {
        try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60 * 24
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        var pending: [(Int, SegmentInfo)] = []
        for (i, seg) in segments.enumerated() where !seg.isDone {
            pending.append((i, seg))
        }
        if pending.isEmpty {
            report(.finished)
            return
        }
        totalTasks = pending.count
        for (i, seg) in pending {
            var req = URLRequest(url: url)
            let from = seg.start + seg.downloaded
            if seg.end >= 0 {
                req.setValue("bytes=\(from)-\(seg.end)", forHTTPHeaderField: "Range")
            } else if seg.downloaded > 0 {
                req.setValue("bytes=\(from)-", forHTTPHeaderField: "Range")
            }
            let task = session.dataTask(with: req)
            task.taskDescription = "\(i)"
            tasks[i] = task
        }
        for t in tasks.values { t.resume() }
    }

    /// Pause: funnel onto the delegate queue so no data callback is mid-write,
    /// then close handles and cancel. Segment offsets already reflect every
    /// byte written, so resume continues exactly from here.
    func stop() {
        delegateQueue.addOperation { [weak self] in
            guard let self, !self.reported else { return }
            self.stopping = true
            for t in self.tasks.values { t.cancel() }
            for h in self.handles.values { try? h.close() }
            self.handles.removeAll()
            self.report(.paused)
        }
    }

    private func report(_ result: RunnerResult) {
        guard !reported else { return }
        reported = true
        session?.invalidateAndCancel()
        let segs = segments
        onFinish(result, segs)
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let idx = Int(dataTask.taskDescription ?? ""),
              idx < segments.count,
              let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        let seg = segments[idx]
        let wantsRange = seg.end >= 0 || seg.downloaded > 0
        if wantsRange && http.statusCode == 200 && seg.downloaded > 0 || (segments.count > 1 && http.statusCode == 200) {
            // Server ignored the Range header and is sending the whole file
            // into one segment slot - that would corrupt the assembly.
            completionHandler(.cancel)
            report(.rangeIgnored)
            return
        }
        if wantsRange && http.statusCode == 200 && seg.downloaded == 0 && seg.end >= 0 && segments.count == 1 {
            // Single-segment resume where the server sent the whole file from
            // byte 0 even though we asked from an offset happens only when
            // downloaded == 0 here, so it is safe to accept.
        }
        guard (200...299).contains(http.statusCode) else {
            completionHandler(.cancel)
            report(.failed("HTTP \(http.statusCode)"))
            return
        }
        // Open (or create) the part file and position at its end. Part files
        // hold only this segment's bytes, appended in order.
        let url = partURL(idx)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if seg.downloaded == 0 {
            // Fresh segment: truncate any stale part file.
            try? FileManager.default.removeItem(at: url)
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handles[idx] = handle
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let idx = Int(dataTask.taskDescription ?? ""), idx < segments.count,
              let handle = handles[idx] else { return }
        do {
            try handle.write(contentsOf: data)
            segments[idx].downloaded += Int64(data.count)
        } catch {
            dataTask.cancel()
            report(.failed("Write failed: \(error.localizedDescription)"))
            return
        }
        let now = Date()
        if now.timeIntervalSince(lastProgressReport) > 0.2 {
            lastProgressReport = now
            onProgress(segments)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let idx = Int(task.taskDescription ?? "") else { return }
        if let h = handles[idx] { try? h.close(); handles[idx] = nil }
        if stopping || reported { return }
        if let error = error {
            let ns = error as NSError
            if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled {
                report(.paused)
            } else {
                report(.failed(error.localizedDescription))
            }
            return
        }
        onProgress(segments)
        completedTasks += 1
        if completedTasks >= totalTasks {
            report(.finished)
        }
    }
}
