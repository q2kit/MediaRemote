import AppKit
import ApplicationServices

/// Simulates the hardware media keys (F7/F8/F9, volume keys), so whatever app currently
/// owns "Now Playing" (Music, Spotify, Safari/YouTube, ...) reacts as if the user pressed them.
/// Posting these events requires the Accessibility permission.
enum MediaKeys {
    // Values from IOKit/hidsystem/ev_keymap.h
    enum Key: Int {
        case soundUp = 0
        case soundDown = 1
        case mute = 7
        case play = 16
        case next = 17
        case previous = 18
    }

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that sends the user to Privacy & Security > Accessibility.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func press(_ key: Key) {
        post(key, down: true)
        post(key, down: false)
    }

    private static func post(_ key: Key, down: Bool) {
        let state = down ? 0xA : 0xB
        let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8, // NX_SUBTYPE_AUX_CONTROL_BUTTONS
            data1: (key.rawValue << 16) | (state << 8),
            data2: -1
        )
        event?.cgEvent?.post(tap: .cghidEventTap)
    }
}
