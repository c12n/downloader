import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.connectionsKey) private var connections: Int = 4
    @AppStorage(AppSettings.maxSimultaneousKey) private var maxSimultaneous: Int = 3
    @AppStorage(AppSettings.keepAwakeKey) private var keepAwake: Bool = true
    @AppStorage(AppSettings.adBlockKey) private var adBlock: Bool = true
    @ObservedObject private var debrid = DebridStore.shared

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $connections, in: 1...16) {
                        LabeledContent("Connections per download", value: "\(connections)")
                    }
                    Stepper(value: $maxSimultaneous, in: 1...5) {
                        LabeledContent("Simultaneous downloads", value: "\(maxSimultaneous)")
                    }
                } header: {
                    Text("Performance")
                } footer: {
                    Text("More connections can speed up large files from servers that support range requests. Changes apply to downloads started after the change.")
                }
                Section {
                    Toggle("Block ads and pop-ups", isOn: $adBlock)
                } header: {
                    Text("Browser")
                } footer: {
                    Text("The built-in browser blocks known ad and tracker domains and never allows pop-up windows. Changes apply the next time the browser tab is opened.")
                }
                Section {
                    ForEach(DebridServiceID.priority) { service in
                        DebridServiceRow(service: service, store: debrid)
                    }
                } header: {
                    Text("Debrid services")
                } footer: {
                    Text("Add a key, then tap Test. Once a service is tested and verified, links from hosts it supports are fetched through it for faster speeds instead of downloading directly. If several verified services support a host, the order is TorBox, then Premiumize, then Real-Debrid. Keys are stored in the Keychain and never leave the device except to their own service.")
                }
                Section {
                    Toggle("Keep screen awake while downloading", isOn: $keepAwake)
                } header: {
                    Text("Screen")
                }
                Section {
                    LabeledContent("Version", value: versionString)
                    Text("Files are saved in the app's Downloads folder and are visible in the Files app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
        }
    }
}

/// One debrid service in Settings: key field, Save, Test, and the
/// verified state. The key is loaded from the Keychain when the row
/// appears and only written back when Save is tapped.
private struct DebridServiceRow: View {
    let service: DebridServiceID
    @ObservedObject var store: DebridStore
    @State private var keyText: String = ""
    @State private var savedNote: String? = nil

    private var isVerified: Bool { store.verified[service] == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(service.displayName).font(.headline)
                Spacer()
                statusBadge
            }
            SecureField("API key", text: $keyText)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onAppear { keyText = store.key(for: service) }
            HStack(spacing: 12) {
                Button("Save key") {
                    store.setKey(keyText, for: service)
                    savedNote = "Saved. Tap Test to verify it."
                }
                .buttonStyle(.borderless)
                Button {
                    Task { await store.verify(service) }
                } label: {
                    if store.testing == service {
                        ProgressView()
                    } else {
                        Text("Test")
                    }
                }
                .buttonStyle(.borderless)
                .disabled(store.testing != nil || keyText.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            if isVerified, let label = store.accountLabel[service], !label.isEmpty {
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            if let err = store.lastError[service] {
                Text(err).font(.caption).foregroundStyle(.red)
            } else if let savedNote, !isVerified {
                Text(savedNote).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if store.testing == service {
            Text("Testing").font(.caption).foregroundStyle(.secondary)
        } else if isVerified {
            Text("Verified").font(.caption).foregroundStyle(.green)
        } else if store.hasKey(service) {
            Text("Not verified").font(.caption).foregroundStyle(.orange)
        } else {
            Text("No key").font(.caption).foregroundStyle(.secondary)
        }
    }
}
