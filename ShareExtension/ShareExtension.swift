//
//  ShareExtension.swift
//  Downloader Share Extension
//
//  "Downloader" in the iOS share sheet: takes shared web URLs or
//  text containing links (magnets included) and queues them in the
//  main app through the shared App Group container. The app drains
//  the queue when it next comes to the foreground, or right away if
//  the user picks "Add and open Downloader".
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

private let appGroupID = "group.com.c12n.downloadmanager"
private let pendingFileName = "pending-links.json"

final class DownloaderShareController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        extractLinks { [weak self] links in
            guard let self else { return }
            let root = ShareRootView(
                links: links,
                onAdd: { [weak self] openApp in
                    guard let self else { return }
                    Self.save(links)
                    if openApp { self.openMainApp() }
                    self.extensionContext?.completeRequest(returningItems: nil)
                },
                onCancel: { [weak self] in
                    let error = NSError(domain: "com.c12n.downloadmanager.share", code: 0, userInfo: nil)
                    self?.extensionContext?.cancelRequest(withError: error)
                })
            let host = UIHostingController(rootView: root)
            addChild(host)
            host.view.frame = view.bounds
            host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            view.addSubview(host.view)
            host.didMove(toParent: self)
        }
    }

    /// Collect every http(s) or magnet link from what was shared:
    /// URL attachments directly, links inside shared text otherwise.
    private func extractLinks(completion: @escaping ([String]) -> Void) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { completion([]); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var found: [String] = []
        func collect(_ candidates: [String]) {
            lock.lock()
            for c in candidates where !found.contains(c) { found.append(c) }
            lock.unlock()
        }
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { value, _ in
                    if let url = value as? URL {
                        collect([url.absoluteString])
                    } else if let text = value as? String {
                        collect(Self.links(in: text))
                    }
                    group.leave()
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { value, _ in
                    if let text = value as? String { collect(Self.links(in: text)) }
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { completion(found) }
    }

    static func links(in text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter {
            $0.hasPrefix("http://") || $0.hasPrefix("https://") || $0.hasPrefix("magnet:?")
        }
    }

    static func save(_ links: [String]) {
        guard !links.isEmpty,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupID) else { return }
        let file = container.appendingPathComponent(pendingFileName)
        var existing: [String] = []
        if let data = try? Data(contentsOf: file),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            existing = decoded
        }
        let merged = existing + links.filter { !existing.contains($0) }
        if let data = try? JSONEncoder().encode(merged) {
            try? data.write(to: file, options: .atomic)
        }
    }

    /// Opens the main app through the responder chain (share
    /// extensions have no direct open-URL API). If it does not work,
    /// the links are still saved and start on the next manual open.
    private func openMainApp() {
        guard let url = URL(string: "downloader://queue") else { return }
        let selector = NSSelectorFromString("openURL:")
        var responder: UIResponder? = self
        while let r = responder {
            if r.responds(to: selector) {
                r.perform(selector, with: url)
                return
            }
            responder = r.next
        }
    }
}

// MARK: - UI

private struct ShareRootView: View {
    let links: [String]
    var onAdd: (Bool) -> Void
    var onCancel: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Link\(links.count == 1 ? "" : "s")") {
                    if links.isEmpty {
                        Text("No download link found in what you shared.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(links, id: \.self) { link in
                            Text(link).font(.footnote).lineLimit(3)
                        }
                    }
                }
                if !links.isEmpty {
                    Section {
                        Button {
                            onAdd(false)
                        } label: {
                            HStack { Spacer(); Text("Add to Downloader").font(.headline); Spacer() }
                        }
                        Button {
                            onAdd(true)
                        } label: {
                            HStack { Spacer(); Text("Add and open Downloader"); Spacer() }
                        }
                    } footer: {
                        Text("Plain Add queues the links; they start downloading the next time Downloader is opened.")
                    }
                }
                Section {
                    Button(links.isEmpty ? "Done" : "Cancel", role: .cancel) { onCancel() }
                }
            }
            .navigationTitle("Downloader")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
