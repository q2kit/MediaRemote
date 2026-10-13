import UIKit

/// The name this iPhone shows up as on the Mac.
///
/// Since iOS 16 `UIDevice.current.name` is just "iPhone" (the real name needs an entitlement
/// Apple grants case by case), so the user can set a name in Settings; otherwise the model is used.
enum DeviceName {
    static let settingsKey = "deviceName"

    static var current: String {
        let custom = UserDefaults.standard.string(forKey: settingsKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !custom.isEmpty { return custom }
        let systemName = UIDevice.current.name
        return systemName != UIDevice.current.model ? systemName : modelName
    }

    /// e.g. "iPhone 15 Pro"; falls back to "iPhone" for identifiers not listed here.
    static var modelName: String {
        models[modelIdentifier] ?? UIDevice.current.model
    }

    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static let models: [String: String] = [
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12",
        "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
        "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
        "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
        "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus",
        "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max", "iPhone17,5": "iPhone 16e",
    ]
}
