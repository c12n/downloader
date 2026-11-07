import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            DownloadsView()
                .tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
                .tag(0)
            BrowserView(selectedTab: $selectedTab)
                .tabItem { Label("Browser", systemImage: "globe") }
                .tag(1)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(2)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { manager.drainSharedLinks() }
        }
    }
}

enum QueueFilter: String, CaseIterable {
    case all = "All", active = "Active", done = "Done", failed = "Failed"
}

struct DownloadsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @AppStorage(AppSettings.wifiOnlyKey) private var wifiOnly: Bool = false
    @State private var showingAdd = false
    @State private var filter: QueueFilter = .all

    private var visibleItems: [DownloadItem] {
        switch filter {
        case .all: return manager.items
        case .active: return manager.items.filter { $0.status == .queued || $0.status == .downloading || $0.status == .paused }
        case .done: return manager.items.filter { $0.status == .completed }
        case .failed: return manager.items.filter { $0.status == .failed }
        }
    }

    private var waitingForWiFi: Bool {
        wifiOnly && !manager.wifiAvailable && manager.items.contains { $0.status == .queued }
    }

    var body: some View {
        NavigationStack {
            Group {
                if manager.items.isEmpty {
                    ContentUnavailableView("No downloads yet",
                                           systemImage: "arrow.down.circle",
                                           description: Text("Tap + to add a file URL, or grab one in the Browser tab."))
                } else {
                    VStack(spacing: 0) {
                        Picker("Filter", selection: $filter) {
                            ForEach(QueueFilter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                        if waitingForWiFi {
                            Label("Waiting for Wi-Fi to start new downloads", systemImage: "wifi.slash")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .padding(.bottom, 6)
                        }
                        if visibleItems.isEmpty {
                            ContentUnavailableView("Nothing here",
                                                   systemImage: "line.3.horizontal.decrease.circle",
                                                   description: Text("No \(filter.rawValue.lowercased()) downloads."))
                        } else {
                            List {
                                ForEach(visibleItems) { item in
                                    DownloadRow(item: item)
                                        .environmentObject(manager)
                                }
                                .onDelete { offsets in
                                    for i in offsets { manager.delete(visibleItems[i]) }
                                }
                            }
                            .listStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("Downloader")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showingAdd = true } label: { Image(systemName: "plus") }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Pause all") { manager.pauseAll() }
                        Button("Resume all") { manager.resumeAll() }
                        Button("Clear completed") { manager.clearCompleted() }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddDownloadView().environmentObject(manager)
            }
        }
    }
}

struct DownloadRow: View {
    @EnvironmentObject private var manager: DownloadManager
    let item: DownloadItem
    @State private var showingShare = false
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.filename).font(.headline).lineLimit(2)
                    Text(item.host.isEmpty ? item.urlString : item.host)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let phase = item.debridPhase {
                        Text(phase).font(.caption).foregroundStyle(.blue).lineLimit(1)
                    } else if let via = item.viaDebrid {
                        Text("via \(via)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                statusBadge
            }
            if item.status != .completed {
                ProgressView(value: item.fraction)
            }
            HStack(spacing: 8) {
                Text(sizeText).font(.caption).foregroundStyle(.secondary)
                if item.status == .downloading {
                    if !formatSpeed(item.speedBytesPerSec).isEmpty {
                        Text(formatSpeed(item.speedBytesPerSec)).font(.caption).foregroundStyle(.secondary)
                    }
                    if !formatETA(item.etaSeconds).isEmpty {
                        Text(formatETA(item.etaSeconds)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                controls
            }
            if item.status == .failed, let err = item.errorMessage {
                Text(err).font(.caption).foregroundStyle(.red).lineLimit(3)
            }
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $showingShare) {
            ShareSheet(activityItems: [manager.finalURL(for: item)])
        }
        .sheet(isPresented: $showingDetails) {
            DownloadDetailsView(item: item).environmentObject(manager)
        }
    }

    private var sizeText: String {
        if item.totalBytes > 0 {
            return "\(formatBytes(item.effectiveDownloaded)) of \(formatBytes(item.totalBytes)) · \(Int(item.fraction * 100))%"
        }
        return formatBytes(item.effectiveDownloaded)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch item.status {
        case .queued: Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .downloading: Text("Downloading").font(.caption).foregroundStyle(.blue)
        case .paused: Text("Paused").font(.caption).foregroundStyle(.orange)
        case .completed: Text("Done").font(.caption).foregroundStyle(.green)
        case .failed: Text("Failed").font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch item.status {
            case .downloading:
                Button { manager.pause(item) } label: { Image(systemName: "pause.circle") }
                    .buttonStyle(.borderless)
            case .paused, .queued:
                Button { manager.resume(item) } label: { Image(systemName: "play.circle") }
                    .buttonStyle(.borderless)
            case .failed:
                Button { manager.retry(item) } label: { Image(systemName: "arrow.clockwise.circle") }
                    .buttonStyle(.borderless)
            case .completed:
                if manager.fileExistsCompleted(item) {
                    Button { showingShare = true } label: { Image(systemName: "square.and.arrow.up") }
                        .buttonStyle(.borderless)
                }
            }
            Button { showingDetails = true } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
            Button(role: .destructive) { manager.delete(item) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
        }
        .font(.title3)
    }
}

/// Everything known about one download, with copyable links.
struct DownloadDetailsView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @State private var showingShare = false

    private var statusText: String {
        switch item.status {
        case .queued: return "Queued"
        case .downloading: return item.debridPhase ?? "Downloading"
        case .paused: return "Paused"
        case .completed: return "Completed"
        case .failed: return "Failed"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("File") {
                    LabeledContent("Name", value: item.filename)
                    LabeledContent("Status", value: statusText)
                    if item.totalBytes > 0 {
                        LabeledContent("Size", value: "\(formatBytes(item.effectiveDownloaded)) of \(formatBytes(item.totalBytes))")
                    } else if item.effectiveDownloaded > 0 {
                        LabeledContent("Downloaded", value: formatBytes(item.effectiveDownloaded))
                    }
                    if item.segments.count > 1 {
                        LabeledContent("Connections", value: "\(item.segments.count)")
                    }
                    LabeledContent("Added", value: item.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                if let via = item.viaDebrid {
                    Section("Debrid") {
                        LabeledContent("Service", value: via)
                    }
                }
                Section("Source") {
                    if let original = item.originalURLString, original != item.urlString {
                        linkRow("Original link", original)
                    }
                    linkRow(item.isMagnet == true ? "Magnet" : "Link", item.urlString)
                }
                if item.status == .failed, let err = item.errorMessage {
                    Section("Error") {
                        Text(err).font(.footnote).foregroundStyle(.red)
                    }
                }
                if item.status == .completed && manager.fileExistsCompleted(item) {
                    Section {
                        Button { showingShare = true } label: {
                            Label("Share file", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                Section {
                    Button("Delete download", role: .destructive) {
                        manager.delete(item)
                        dismiss()
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $showingShare) {
                ShareSheet(activityItems: [manager.finalURL(for: item)])
            }
        }
    }

    private func linkRow(_ label: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.footnote).lineLimit(3)
            }
            Spacer()
            Button { UIPasteboard.general.string = value } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
        }
    }
}

struct AddDownloadView: View {
    @EnvironmentObject private var manager: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var urlText: String = ""
    @State private var customFilename: String = ""
    @State private var message: String? = nil

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $urlText)
                        .frame(minHeight: 110)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("URL(s) - one per line")
                } footer: {
                    Text("Paste one link, or several links each on its own line. Magnet links work too; they are fetched through your verified debrid service.")
                }
                Section("Custom filename (single URL only)") {
                    TextField("Optional - e.g. movie.mp4", text: $customFilename)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                if let message {
                    Section { Text(message).font(.footnote).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Add download")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                // Convenience: if the clipboard already holds links,
                // pre-fill the field (only when it is empty).
                guard urlText.isEmpty,
                      let clip = UIPasteboard.general.string,
                      clip.contains("http") || clip.contains("magnet:?") else { return }
                urlText = clip
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }.disabled(urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func add() {
        // Use clipboard contents as a convenience when the field holds a
        // single pasted link - nothing special needed; the field already
        // accepts paste directly.
        let (added, invalid) = manager.addURLs(text: urlText, customFilename: customFilename)
        if added == 0 {
            message = "No valid http(s) URLs found."
        } else if invalid > 0 {
            message = "\(added) added, \(invalid) line(s) skipped as invalid."
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { dismiss() }
        } else {
            dismiss()
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
