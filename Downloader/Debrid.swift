import Foundation
import Security

// MARK: - Keychain

/// Minimal Keychain wrapper for the debrid API keys. Keys never touch
/// UserDefaults or the state file.
enum Keychain {
    private static let service = "com.c12n.downloadmanager.debrid"

    static func set(_ value: String, for account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var attrs = query
        attrs[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(attrs as CFDictionary, nil)
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Services

enum DebridServiceID: String, CaseIterable, Identifiable {
    case torbox, premiumize, realdebrid
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .torbox: return "TorBox"
        case .premiumize: return "Premiumize"
        case .realdebrid: return "Real-Debrid"
        }
    }
    /// Routing priority when several verified services support a host.
    static let priority: [DebridServiceID] = [.torbox, .premiumize, .realdebrid]
}

struct DebridFile {
    let directURL: URL
    let filename: String?
}

enum DebridError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let m): return m }
    }
}

// MARK: - Store

/// Holds the keys (Keychain), the verified state, and each service's
/// supported-hoster list (fetched live from the service, cached for a
/// day). Only services whose key has been TESTED AND VERIFIED in
/// Settings ever route a download.
@MainActor
final class DebridStore: ObservableObject {
    static let shared = DebridStore()

    @Published private(set) var verified: [DebridServiceID: Bool] = [:]
    @Published private(set) var accountLabel: [DebridServiceID: String] = [:]
    @Published var testing: DebridServiceID? = nil
    @Published var lastError: [DebridServiceID: String] = [:]

    private var hostsCache: [DebridServiceID: Set<String>] = [:]

    private init() {
        for id in DebridServiceID.allCases {
            verified[id] = UserDefaults.standard.bool(forKey: "debrid.verified.\(id.rawValue)")
            accountLabel[id] = UserDefaults.standard.string(forKey: "debrid.account.\(id.rawValue)") ?? ""
            if let data = UserDefaults.standard.data(forKey: "debrid.hosts.\(id.rawValue)"),
               let list = try? JSONDecoder().decode([String].self, from: data) {
                hostsCache[id] = Set(list)
            }
        }
        // Keep the hoster lists fresh in the background for verified
        // services (the lists are what decide routing).
        Task { await self.refreshStaleLists() }
    }

    // MARK: Keys

    func key(for id: DebridServiceID) -> String {
        Keychain.get("key.\(id.rawValue)") ?? ""
    }

    func setKey(_ key: String, for id: DebridServiceID) {
        Keychain.set(key.trimmingCharacters(in: .whitespacesAndNewlines), for: "key.\(id.rawValue)")
        // A changed key is unverified until it is tested again.
        setVerified(false, for: id)
        accountLabel[id] = ""
        UserDefaults.standard.removeObject(forKey: "debrid.account.\(id.rawValue)")
    }

    func hasKey(_ id: DebridServiceID) -> Bool { !key(for: id).isEmpty }

    private func setVerified(_ value: Bool, for id: DebridServiceID) {
        verified[id] = value
        UserDefaults.standard.set(value, forKey: "debrid.verified.\(id.rawValue)")
    }

    // MARK: Host matching

    /// The verified service that should fetch this host, if any.
    func service(forHost host: String) -> DebridServiceID? {
        let host = host.lowercased()
        guard !host.isEmpty else { return nil }
        for id in DebridServiceID.priority where verified[id] == true {
            guard let domains = hostsCache[id], !domains.isEmpty else { continue }
            if domains.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
                return id
            }
        }
        return nil
    }

    private func saveHosts(_ domains: Set<String>, for id: DebridServiceID) {
        hostsCache[id] = domains
        if let data = try? JSONEncoder().encode(Array(domains)) {
            UserDefaults.standard.set(data, forKey: "debrid.hosts.\(id.rawValue)")
        }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "debrid.hostsAt.\(id.rawValue)")
    }

    private func refreshStaleLists() async {
        for id in DebridServiceID.allCases where verified[id] == true {
            let at = UserDefaults.standard.double(forKey: "debrid.hostsAt.\(id.rawValue)")
            if hostsCache[id]?.isEmpty ?? true || Date().timeIntervalSince1970 - at > 86_400 {
                if let domains = try? await fetchHosts(id) { saveHosts(domains, for: id) }
            }
        }
    }

    // MARK: Verify (the Settings "Test" button)

    /// Tests the saved key against the service. On success the service
    /// is marked verified, its account label stored, and its hoster
    /// list fetched so routing can start immediately.
    @discardableResult
    func verify(_ id: DebridServiceID) async -> Bool {
        let key = key(for: id)
        guard !key.isEmpty else {
            lastError[id] = "Enter an API key first."
            return false
        }
        testing = id
        lastError[id] = nil
        defer { testing = nil }
        do {
            let label = try await checkAccount(id, key: key)
            setVerified(true, for: id)
            accountLabel[id] = label
            UserDefaults.standard.set(label, forKey: "debrid.account.\(id.rawValue)")
            if let domains = try? await fetchHosts(id) { saveHosts(domains, for: id) }
            return true
        } catch {
            setVerified(false, for: id)
            lastError[id] = (error as? DebridError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    private func checkAccount(_ id: DebridServiceID, key: String) async throws -> String {
        switch id {
        case .torbox:
            let (data, _) = try await request("https://api.torbox.app/v1/api/user/me", key: key)
            let json = try JSON(data)
            guard json["success"] as? Bool == true, let d = json["data"] as? [String: Any] else {
                throw DebridError.message("TorBox rejected the key.")
            }
            return (d["email"] as? String) ?? "TorBox account"
        case .premiumize:
            let (data, _) = try await request("https://www.premiumize.me/api/account/info", key: key)
            let json = try JSON(data)
            guard json["status"] as? String == "success" else {
                throw DebridError.message((json["message"] as? String) ?? "Premiumize rejected the key.")
            }
            if let cid = json["customer_id"] { return "Customer \(cid)" }
            return "Premiumize account"
        case .realdebrid:
            let (data, resp) = try await request("https://api.real-debrid.com/rest/1.0/user", key: key)
            guard resp.statusCode == 200 else {
                throw DebridError.message("Real-Debrid rejected the token (HTTP \(resp.statusCode)).")
            }
            let json = try JSON(data)
            let name = (json["username"] as? String) ?? "Real-Debrid account"
            let type = (json["type"] as? String) ?? ""
            return type == "premium" ? "\(name) · Premium" : "\(name) · free account (hoster links need Premium)"
        }
    }

    // MARK: Hoster lists (live, per service)

    private func fetchHosts(_ id: DebridServiceID) async throws -> Set<String> {
        let key = key(for: id)
        switch id {
        case .torbox:
            // Public endpoint, no key needed.
            let (data, _) = try await request("https://api.torbox.app/v1/api/webdl/hosters", key: nil)
            let json = try JSON(data)
            var out = Set<String>()
            for hoster in (json["data"] as? [[String: Any]]) ?? [] {
                for d in (hoster["domains"] as? [String]) ?? [] {
                    out.insert(d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                }
            }
            return out
        case .premiumize:
            let (data, _) = try await request("https://www.premiumize.me/api/services/list", key: key)
            let json = try JSON(data)
            var out = Set<String>()
            let hosterlist = json["hosterlist"] ?? json["hosters"]
            if let dict = hosterlist as? [String: Any] {
                for (k, v) in dict {
                    out.insert(k.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    if let vd = v as? [String: Any] {
                        for d in (vd["domains"] as? [String]) ?? [] {
                            out.insert(d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                        }
                    }
                }
            } else if let list = hosterlist as? [Any] {
                for h in list {
                    if let s = h as? String {
                        out.insert(s.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    } else if let hd = h as? [String: Any] {
                        for d in (hd["domains"] as? [String]) ?? [] {
                            out.insert(d.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                        }
                    }
                }
            }
            return out
        case .realdebrid:
            let (data, resp) = try await request("https://api.real-debrid.com/rest/1.0/hosts/status", key: key)
            if resp.statusCode == 200, let json = try? JSON(data) {
                var out = Set<String>()
                for (domain, v) in json {
                    if let vd = v as? [String: Any], (vd["status"] as? String) == "supported" {
                        out.insert(domain.lowercased())
                    }
                }
                if !out.isEmpty { return out }
            }
            // Fallback: the major hosters, so routing still works if
            // the live list cannot be read.
            return ["rapidgator.net", "nitroflare.com", "turbobit.net", "uploadgig.com",
                    "1fichier.com", "uploaded.net", "uploadboy.com", "hitfile.net",
                    "filer.net", "alfafile.net", "wdupload.com", "mexashare.com",
                    "keep2share.cc", "filefactory.com", "ddownload.com", "icerbox.com",
                    "fikper.com", "rapidrar.com", "nitro.download", "turbobit.cc"]
        }
    }

    // MARK: Resolve a hoster link to direct download(s)

    /// Turns a supported hoster link into direct download URL(s) on the
    /// service's own servers. Throws DebridError on failure; callers
    /// fall back to a plain direct download.
    func resolve(url: URL, service id: DebridServiceID) async throws -> [DebridFile] {
        let key = key(for: id)
        guard !key.isEmpty else { throw DebridError.message("No \(id.displayName) API key saved.") }
        switch id {
        case .torbox: return try await resolveTorBox(url: url, key: key)
        case .premiumize: return try await resolvePremiumize(url: url, key: key)
        case .realdebrid: return try await resolveRealDebrid(url: url, key: key)
        }
    }

    private func resolveTorBox(url: URL, key: String) async throws -> [DebridFile] {
        var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/webdl/createwebdownload")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["link": url.absoluteString])
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSON(data)
        if json["success"] as? Bool == false {
            throw DebridError.message("TorBox rejected the link: \((json["detail"] as? String) ?? (json["error"] as? String) ?? "unknown error")")
        }
        let d = (json["data"] as? [String: Any]) ?? [:]
        guard let webID = d["webdownload_id"] ?? d["id"] ?? d["web_download_id"] else {
            throw DebridError.message("TorBox did not return a download id.")
        }
        // Poll until the web download completes (up to ~8 minutes).
        let deadline = Date().addingTimeInterval(8 * 60)
        var files: [[String: Any]] = []
        while Date() < deadline {
            let (pdata, _) = try await request(
                "https://api.torbox.app/v1/api/webdl/mylist?id=\(webID)", key: key)
            let pjson = try JSON(pdata)
            var item: [String: Any] = [:]
            if let dict = pjson["data"] as? [String: Any] { item = dict }
            if let list = pjson["data"] as? [[String: Any]] { item = list.first ?? [:] }
            let state = ((item["download_state"] as? String) ?? (item["state"] as? String) ?? "").lowercased()
            if state.contains("error") || state.contains("fail") {
                throw DebridError.message("TorBox download failed (\(state)).")
            }
            files = (item["files"] as? [[String: Any]]) ?? []
            let done = ["completed", "downloaded", "finished", "cached"].contains(state)
                || (item["download_finished"] as? Bool) == true
                || ((item["progress"] as? Double) ?? 0) >= 1
            if !files.isEmpty && done { break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard !files.isEmpty else { throw DebridError.message("TorBox did not finish the download in time.") }
        var out: [DebridFile] = []
        for f in files {
            guard let fid = f["id"] else { continue }
            let (rdata, _) = try await request(
                "https://api.torbox.app/v1/api/webdl/requestdl?token=\(key)&web_id=\(webID)&file_id=\(fid)", key: nil)
            let rjson = try JSON(rdata)
            if let link = rjson["data"] as? String, let direct = URL(string: link) {
                let name = (f["name"] as? String) ?? (f["filename"] as? String) ?? (f["file_name"] as? String)
                out.append(DebridFile(directURL: direct, filename: name))
            }
        }
        guard !out.isEmpty else { throw DebridError.message("TorBox returned no download links.") }
        return out
    }

    private func pmDirectdl(src: String, key: String) async throws -> [[String: Any]] {
        let payload = try await pmPost("/transfer/directdl", ["src": src], key: key)
        return (payload["content"] as? [[String: Any]]) ?? []
    }

    /// Creates a Premiumize transfer for src (a hoster link, a magnet,
    /// or a .torrent URL) and waits for it to finish.
    private func pmCreateAndWait(src: String, key: String,
                                 onPhase: ((String) -> Void)? = nil) async throws {
        let created = try await pmPost("/transfer/create", ["src": src], key: key)
        guard created["status"] as? String == "success", let tid = created["id"] else {
            throw DebridError.message("Premiumize could not take the link: \((created["message"] as? String) ?? "not supported")")
        }
        let deadline = Date().addingTimeInterval(20 * 60)
        while Date() < deadline {
            let listing = try await pmPost("/transfer/list", [:], key: key)
            for t in (listing["transfers"] as? [[String: Any]]) ?? [] {
                if String(describing: t["id"] ?? "") == String(describing: tid) {
                    let status = ((t["status"] as? String) ?? "").lowercased()
                    if status == "finished" { return }
                    if status == "error" {
                        throw DebridError.message("Premiumize transfer failed: \((t["message"] as? String) ?? "error")")
                    }
                    if let progress = t["progress"] as? Double {
                        onPhase?("Premiumize: fetching, \(Int(progress * 100))%")
                    } else if !status.isEmpty {
                        onPhase?("Premiumize: \(status)")
                    }
                    break
                }
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw DebridError.message("Premiumize did not finish in time.")
    }

    private func pmFiles(from content: [[String: Any]]) -> [DebridFile] {
        content.compactMap { entry in
            guard let link = (entry["link"] as? String) ?? (entry["stream_link"] as? String),
                  let direct = URL(string: link) else { return nil }
            let path = (entry["path"] as? String) ?? (entry["name"] as? String) ?? ""
            let name = path.split(separator: "/").last.map(String.init)
            return DebridFile(directURL: direct, filename: name)
        }
    }

    private func resolvePremiumize(url: URL, key: String) async throws -> [DebridFile] {
        var content = try await pmDirectdl(src: url.absoluteString, key: key)
        if content.isEmpty {
            try await pmCreateAndWait(src: url.absoluteString, key: key)
            content = try await pmDirectdl(src: url.absoluteString, key: key)
        }
        let out = pmFiles(from: content)
        guard !out.isEmpty else { throw DebridError.message("Premiumize returned no files for that link.") }
        return out
    }

    private func pmPost(_ path: String, _ form: [String: String], key: String) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://www.premiumize.me/api\(path)")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = form.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSON(data)
    }

    private func resolveRealDebrid(url: URL, key: String) async throws -> [DebridFile] {
        var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/unrestrict/link")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let encoded = url.absoluteString.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url.absoluteString
        req.httpBody = "link=\(encoded)".data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: req)
        let json = try JSON(data)
        if let err = json["error"] as? String {
            let code = json["error_code"] as? Int
            throw DebridError.message("Real-Debrid could not unrestrict the link (\(err)\(code.map { ", \($0)" } ?? "")).")
        }
        guard let link = json["download"] as? String, let direct = URL(string: link) else {
            throw DebridError.message("Real-Debrid returned no download link.")
        }
        return [DebridFile(directURL: direct, filename: json["filename"] as? String)]
    }

    // MARK: Magnets and torrent files

    /// The first service (in routing priority order) whose key has
    /// been tested and verified; torrent sources route through it.
    func firstVerified() -> DebridServiceID? {
        DebridServiceID.priority.first { verified[$0] == true }
    }

    /// Hands a magnet link to a service, waits for its servers to
    /// fetch the torrent, and returns direct links for every file.
    func resolveMagnet(_ magnet: String, service id: DebridServiceID,
                       onPhase: @escaping (String) -> Void) async throws -> [DebridFile] {
        let key = key(for: id)
        guard !key.isEmpty else { throw DebridError.message("No \(id.displayName) API key saved.") }
        switch id {
        case .torbox: return try await torboxTorrent(magnet: magnet, torrentData: nil, key: key, onPhase: onPhase)
        case .premiumize:
            try await pmCreateAndWait(src: magnet, key: key, onPhase: onPhase)
            let files = pmFiles(from: try await pmDirectdl(src: magnet, key: key))
            guard !files.isEmpty else { throw DebridError.message("Premiumize returned no files for that magnet.") }
            return files
        case .realdebrid: return try await realDebridTorrent(magnet: magnet, torrentData: nil, key: key, onPhase: onPhase)
        }
    }

    /// Same for a .torrent file URL: Premiumize fetches the file
    /// itself; TorBox and Real-Debrid need the bytes uploaded.
    func resolveTorrentURL(_ url: URL, service id: DebridServiceID,
                           onPhase: @escaping (String) -> Void) async throws -> [DebridFile] {
        let key = key(for: id)
        guard !key.isEmpty else { throw DebridError.message("No \(id.displayName) API key saved.") }
        switch id {
        case .premiumize:
            try await pmCreateAndWait(src: url.absoluteString, key: key, onPhase: onPhase)
            let files = pmFiles(from: try await pmDirectdl(src: url.absoluteString, key: key))
            guard !files.isEmpty else { throw DebridError.message("Premiumize returned no files for that torrent.") }
            return files
        case .torbox, .realdebrid:
            onPhase("\(id.displayName): reading the .torrent file")
            let (data, _) = try await URLSession.shared.data(from: url)
            guard data.count > 0, data.count < 5_000_000 else {
                throw DebridError.message("That .torrent file could not be read.")
            }
            if id == .torbox {
                return try await torboxTorrent(magnet: nil, torrentData: data, key: key, onPhase: onPhase)
            }
            return try await realDebridTorrent(magnet: nil, torrentData: data, key: key, onPhase: onPhase)
        }
    }

    private func torboxTorrent(magnet: String?, torrentData: Data?, key: String,
                               onPhase: @escaping (String) -> Void) async throws -> [DebridFile] {
        var torrentID: Any?
        if let magnet {
            var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/torrents/createtorrent")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["magnet": magnet])
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSON(data)
            if json["success"] as? Bool == false {
                throw DebridError.message("TorBox rejected the magnet: \((json["detail"] as? String) ?? (json["error"] as? String) ?? "unknown error")")
            }
            torrentID = (json["data"] as? [String: Any])?["torrent_id"] ?? (json["data"] as? [String: Any])?["id"]
        } else if let torrentData {
            torrentID = try await torboxUploadTorrentFile(torrentData, key: key)
        }
        guard let tid = torrentID else { throw DebridError.message("TorBox did not return a torrent id.") }

        let deadline = Date().addingTimeInterval(20 * 60)
        var files: [[String: Any]] = []
        while Date() < deadline {
            let (pdata, _) = try await request("https://api.torbox.app/v1/api/torrents/mylist?id=\(tid)", key: key)
            let pjson = try JSON(pdata)
            var item: [String: Any] = [:]
            if let dict = pjson["data"] as? [String: Any] { item = dict }
            if let list = pjson["data"] as? [[String: Any]] { item = list.first ?? [:] }
            let state = ((item["download_state"] as? String) ?? (item["state"] as? String) ?? "").lowercased()
            if state.contains("error") || state.contains("fail") || state.contains("expired") {
                throw DebridError.message("TorBox torrent failed (\(state)).")
            }
            files = (item["files"] as? [[String: Any]]) ?? []
            let progress = (item["progress"] as? Double) ?? 0
            onPhase(progress > 0 ? "TorBox: fetching torrent, \(Int(progress * 100))%" : "TorBox: fetching torrent")
            let done = (item["download_finished"] as? Bool) == true
                || ["completed", "downloaded", "finished", "cached", "uploading", "seeding"].contains(state)
            if !files.isEmpty && done { break }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard !files.isEmpty else { throw DebridError.message("TorBox did not finish the torrent in time.") }
        var out: [DebridFile] = []
        for f in files {
            guard let fid = f["id"] else { continue }
            let (rdata, _) = try await request(
                "https://api.torbox.app/v1/api/torrents/requestdl?token=\(key)&torrent_id=\(tid)&file_id=\(fid)", key: nil)
            let rjson = try JSON(rdata)
            if let link = rjson["data"] as? String, let direct = URL(string: link) {
                let name = (f["name"] as? String) ?? (f["filename"] as? String) ?? (f["file_name"] as? String)
                out.append(DebridFile(directURL: direct, filename: name))
            }
        }
        guard !out.isEmpty else { throw DebridError.message("TorBox returned no download links for that torrent.") }
        return out
    }

    private func torboxUploadTorrentFile(_ data: Data, key: String) async throws -> Any {
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: "https://api.torbox.app/v1/api/torrents/createtorrent")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"file.torrent\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-bittorrent\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body
        let (respData, _) = try await URLSession.shared.data(for: req)
        let json = try JSON(respData)
        if json["success"] as? Bool == false {
            throw DebridError.message("TorBox rejected the .torrent file: \((json["detail"] as? String) ?? (json["error"] as? String) ?? "unknown error")")
        }
        let d = (json["data"] as? [String: Any]) ?? [:]
        guard let tid = d["torrent_id"] ?? d["id"] else {
            throw DebridError.message("TorBox did not return a torrent id.")
        }
        return tid
    }

    private func realDebridTorrent(magnet: String?, torrentData: Data?, key: String,
                                   onPhase: @escaping (String) -> Void) async throws -> [DebridFile] {
        var torrentID: String?
        if let magnet {
            var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/addMagnet")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let encoded = magnet.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? magnet
            req.httpBody = "magnet=\(encoded)".data(using: .utf8)
            let (data, _) = try await URLSession.shared.data(for: req)
            let json = try JSON(data)
            if let err = json["error"] as? String { throw DebridError.message("Real-Debrid rejected the magnet (\(err)).") }
            torrentID = json["id"] as? String
        } else if let torrentData {
            var req = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/addTorrent")!)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue("application/x-bittorrent", forHTTPHeaderField: "Content-Type")
            req.httpBody = torrentData
            let (data, resp) = try await URLSession.shared.data(for: req)
            if let json = try? JSON(data), let err = json["error"] as? String {
                throw DebridError.message("Real-Debrid rejected the .torrent file (\(err)).")
            }
            guard (200...299).contains((resp as? HTTPURLResponse)?.statusCode ?? 0) else {
                throw DebridError.message("Real-Debrid rejected the .torrent file.")
            }
            // addTorrent's body can be empty on success; the new
            // torrent is then the first one in the user's list.
            if let json = try? JSON(data), let tid = json["id"] as? String {
                torrentID = tid
            } else {
                let (ldata, _) = try await request("https://api.real-debrid.com/rest/1.0/torrents?limit=1", key: key)
                if let list = (try? JSONSerialization.jsonObject(with: ldata)) as? [[String: Any]] {
                    torrentID = list.first?["id"] as? String
                }
            }
        }
        guard let tid = torrentID else { throw DebridError.message("Real-Debrid did not return a torrent id.") }

        // Select every file, then poll until the torrent is downloaded.
        var sel = URLRequest(url: URL(string: "https://api.real-debrid.com/rest/1.0/torrents/selectFiles/\(tid)")!)
        sel.httpMethod = "POST"
        sel.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        sel.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        sel.httpBody = "files=all".data(using: .utf8)
        _ = try? await URLSession.shared.data(for: sel)

        let deadline = Date().addingTimeInterval(20 * 60)
        var links: [String] = []
        while Date() < deadline {
            let (idata, _) = try await request("https://api.real-debrid.com/rest/1.0/torrents/info/\(tid)", key: key)
            let info = try JSON(idata)
            let status = ((info["status"] as? String) ?? "").lowercased()
            if ["error", "virus", "dead"].contains(status) {
                throw DebridError.message("Real-Debrid torrent failed (\(status)).")
            }
            if let progress = info["progress"] as? Double, status != "downloaded" {
                onPhase("Real-Debrid: fetching torrent, \(Int(progress))%")
            }
            if status == "downloaded" {
                links = (info["links"] as? [String]) ?? []
                break
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        guard !links.isEmpty else { throw DebridError.message("Real-Debrid did not finish the torrent in time.") }
        var out: [DebridFile] = []
        for link in links {
            guard let url = URL(string: link) else { continue }
            out += try await resolveRealDebrid(url: url, key: key)
        }
        return out
    }

    // MARK: HTTP helpers

    private func request(_ urlString: String, key: String?) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: urlString)!)
        if let key { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.timeoutInterval = 30
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DebridError.message("No response from the service.") }
        return (data, http)
    }

    private func JSON(_ data: Data) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data),
              let dict = obj as? [String: Any] else {
            throw DebridError.message("The service returned an unexpected response.")
        }
        return dict
    }
}

// MARK: - Link classification

enum DebridLinks {
    static func isMagnet(_ s: String) -> Bool {
        s.lowercased().hasPrefix("magnet:?") && s.lowercased().contains("xt=urn:btih:")
    }

    /// Display name for a magnet: its dn= parameter when present.
    static func magnetName(_ magnet: String) -> String {
        guard let comps = URLComponents(string: magnet) else { return "Magnet download" }
        if let dn = comps.queryItems?.first(where: { $0.name == "dn" })?.value,
           !dn.trimmingCharacters(in: .whitespaces).isEmpty {
            return sanitizeFilename(dn)
        }
        return "Magnet download"
    }
}
