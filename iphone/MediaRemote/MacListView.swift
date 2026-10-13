import SwiftUI

struct MacListView: View {
    @StateObject private var browser = MacBrowser()
    @ObservedObject private var store = KnownMacStore.shared
    @AppStorage(SettingsKey.autoConnectLastMac) private var autoConnectLastMac = true
    @State private var path: [DiscoveredMac] = []
    @State private var showsSettings = false
    /// Auto-connect only once per launch, so going back to the list doesn't bounce you in again.
    @State private var autoConnectHandled = false

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let problem = browser.problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }

                if !store.macs.isEmpty {
                    Section("My devices") {
                        ForEach(store.macs) { known in
                            knownRow(known)
                        }
                    }
                }

                Section {
                    if nearbyMacs.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Searching…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(nearbyMacs) { mac in
                            NavigationLink(value: mac) {
                                Label(mac.name, systemImage: "laptopcomputer")
                            }
                        }
                    }
                } header: {
                    Text("Available devices")
                } footer: {
                    Text("Make sure your iPhone and Mac are on the same Wi‑Fi network and Media Remote is running on your Mac.")
                }
            }
            .navigationTitle("Media Remote")
            .navigationDestination(for: DiscoveredMac.self) { mac in
                RemoteView(mac: mac)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
        }
        .onAppear { browser.start() }
        .onChange(of: browser.macs) { _, _ in autoConnectIfNeeded() }
        .onChange(of: path) { _, path in
            if !path.isEmpty { autoConnectHandled = true }
        }
    }

    /// Discovered Macs that aren't paired yet.
    private var nearbyMacs: [DiscoveredMac] {
        browser.macs.filter { store.mac(named: $0.name) == nil }
    }

    private func discovered(_ known: KnownMac) -> DiscoveredMac? {
        browser.macs.first { $0.name == known.name }
    }

    @ViewBuilder
    private func knownRow(_ known: KnownMac) -> some View {
        Group {
            if let mac = discovered(known) {
                NavigationLink(value: mac) {
                    KnownMacRow(mac: known, isOnline: true)
                }
            } else {
                KnownMacRow(mac: known, isOnline: false)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                store.forget(known.name)
            } label: {
                Image(systemName: "trash")
            }
            .accessibilityLabel("Forget")
        }
        .contextMenu {
            Button("Forget this device", systemImage: "trash", role: .destructive) {
                store.forget(known.name)
            }
        }
    }

    private func autoConnectIfNeeded() {
        guard autoConnectLastMac, !autoConnectHandled, path.isEmpty,
              let last = store.lastConnected, last.pin != nil,
              let mac = discovered(last)
        else { return }
        autoConnectHandled = true
        path.append(mac)
    }
}

private struct KnownMacRow: View {
    let mac: KnownMac
    let isOnline: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "laptopcomputer")
                .font(.title3)
                .foregroundStyle(isOnline ? Color.accentColor : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                    .foregroundStyle(isOnline ? .primary : .secondary)
                HStack(spacing: 4) {
                    Circle()
                        .fill(isOnline ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                    Text(isOnline ? LocalizedStringKey("Online") : LocalizedStringKey("Offline"))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
