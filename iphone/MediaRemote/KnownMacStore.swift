import Foundation

/// A Mac this iPhone has paired with.
struct KnownMac: Codable, Identifiable, Hashable {
    /// Bonjour service name (the Mac's computer name).
    var name: String
    /// nil after the Mac rejected it, so the next connection asks again.
    var pin: String?
    var lastConnected: Date
    var id: String { name }
}

/// Remembers paired Macs and their PINs (in UserDefaults), most recently used first.
final class KnownMacStore: ObservableObject {
    static let shared = KnownMacStore()

    @Published private(set) var macs: [KnownMac] = []

    private let defaults = UserDefaults.standard
    private static let storageKey = "knownMacs"
    private static let legacyPINPrefix = "pin."

    private init() {
        if let data = defaults.data(forKey: Self.storageKey),
           let saved = try? JSONDecoder().decode([KnownMac].self, from: data) {
            macs = saved
        }
        migrateLegacyPINs()
    }

    var lastConnected: KnownMac? {
        macs.first
    }

    func mac(named name: String) -> KnownMac? {
        macs.first { $0.name == name }
    }

    func recordConnection(name: String, pin: String) {
        macs.removeAll { $0.name == name }
        macs.insert(KnownMac(name: name, pin: pin, lastConnected: Date()), at: 0)
        save()
    }

    func clearPIN(for name: String) {
        guard let index = macs.firstIndex(where: { $0.name == name }) else { return }
        macs[index].pin = nil
        save()
    }

    func forget(_ name: String) {
        macs.removeAll { $0.name == name }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }

    /// Earlier versions stored only a PIN per Mac under "pin.<name>".
    private func migrateLegacyPINs() {
        let legacy = defaults.dictionaryRepresentation().filter { $0.key.hasPrefix(Self.legacyPINPrefix) }
        guard !legacy.isEmpty else { return }
        for (key, value) in legacy {
            let name = String(key.dropFirst(Self.legacyPINPrefix.count))
            if let pin = value as? String, mac(named: name) == nil {
                macs.append(KnownMac(name: name, pin: pin, lastConnected: Date()))
            }
            defaults.removeObject(forKey: key)
        }
        save()
    }
}
