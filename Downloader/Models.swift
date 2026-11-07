import Foundation

enum DownloadStatus: String, Codable {
    case queued, downloading, paused, completed, failed
}

/// One byte-range slice of a download. `end` is inclusive; -1 means "to EOF" (unknown total).
struct SegmentInfo: Codable, Equatable {
    var start: Int64
    var end: Int64
    var downloaded: Int64 = 0
    var length: Int64 { end >= 0 ? (end - start + 1) : -1 }
    var isDone: Bool { end >= 0 && downloaded >= length }
}

struct DownloadItem: Identifiable, Codable {
    var id: UUID = UUID()
    var urlString: String
    var filename: String
    var totalBytes: Int64 = -1
    var status: DownloadStatus = .queued
    var errorMessage: String? = nil
    var createdAt: Date = Date()
    var segments: [SegmentInfo] = []
    var probed: Bool = false
    var supportsRanges: Bool = false
    var rangeFallbackTried: Bool = false

    // Debrid routing (optional so state saved by 1.0.0 still decodes).
    // When set, urlString starts as the hoster link; once resolved it
    // is replaced by the direct link and debridResolved becomes true.
    var viaDebrid: String? = nil        // display name, e.g. "TorBox"
    var debridService: String? = nil    // DebridServiceID raw value
    var originalURLString: String? = nil
    var debridResolved: Bool? = nil
    var debridPhase: String? = nil      // e.g. "Fetching via TorBox"
    var customName: Bool? = nil         // filename came from the user

    // 1.3.0 additions (also optional, for the same decode reason).
    var isMagnet: Bool? = nil           // urlString is a magnet: URI
    var isTorrentFile: Bool? = nil      // source is a .torrent file URL
    var autoRetried: Bool? = nil        // the one automatic repair was used

    /// Bytes the background engine reports for in-flight segments.
    /// Segment counters only advance when a whole segment lands, so
    /// live progress is tracked separately and merged for display.
    var transientBytes: Int64 = 0

    var host: String { URL(string: originalURLString ?? urlString)?.host ?? URL(string: urlString)?.host ?? "" }

    // Transient (persisted but reset on load / not meaningful across launches)
    var speedBytesPerSec: Double = 0
    var etaSeconds: Double = -1

    var downloadedBytes: Int64 { segments.reduce(0) { $0 + $1.downloaded } }
    /// Segment bytes plus whatever the engine has in flight right now.
    var effectiveDownloaded: Int64 { max(downloadedBytes, transientBytes) }
    var fraction: Double {
        guard totalBytes > 0 else { return status == .completed ? 1 : 0 }
        return min(1, Double(effectiveDownloaded) / Double(totalBytes))
    }
}

enum AppSettings {
    static let connectionsKey = "connectionsPerDownload"
    static let maxSimultaneousKey = "maxSimultaneousDownloads"
    static let keepAwakeKey = "keepScreenAwake"

    static var connections: Int {
        let v = UserDefaults.standard.integer(forKey: connectionsKey)
        return v == 0 ? 4 : min(16, max(1, v))
    }
    static var maxSimultaneous: Int {
        let v = UserDefaults.standard.integer(forKey: maxSimultaneousKey)
        return v == 0 ? 3 : min(5, max(1, v))
    }
    static var keepAwake: Bool {
        if UserDefaults.standard.object(forKey: keepAwakeKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: keepAwakeKey)
    }

    static let adBlockKey = "browserAdBlock"
    static var adBlockEnabled: Bool {
        if UserDefaults.standard.object(forKey: adBlockKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: adBlockKey)
    }

    static let wifiOnlyKey = "wifiOnlyDownloads"
    static var wifiOnly: Bool { UserDefaults.standard.bool(forKey: wifiOnlyKey) }
}

func formatBytes(_ bytes: Int64) -> String {
    if bytes < 0 { return "—" }
    return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}

func formatSpeed(_ bps: Double) -> String {
    if bps <= 0 { return "" }
    return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
}

func formatETA(_ seconds: Double) -> String {
    if seconds < 0 || !seconds.isFinite { return "" }
    let s = Int(seconds.rounded())
    if s < 60 { return "\(s)s left" }
    if s < 3600 { return "\(s / 60)m \(s % 60)s left" }
    return "\(s / 3600)h \((s % 3600) / 60)m left"
}

func sanitizeFilename(_ name: String) -> String {
    var n = name.trimmingCharacters(in: .whitespacesAndNewlines)
    for bad in ["/", ":", "\\", "\0"] { n = n.replacingOccurrences(of: bad, with: "_") }
    if n.isEmpty || n == "." || n == ".." { n = "download" }
    return n
}
