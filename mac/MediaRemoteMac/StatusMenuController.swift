import AppKit
import Combine
import SwiftUI

/// The menu bar icon and its native menu. Rebuilt every time it opens, so it always shows
/// the current state.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let server: RemoteServer
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var cancellables: Set<AnyCancellable> = []
    // Custom rows are created once and reused, so they keep updating while the menu is open.
    private lazy var headerItem = hostedItem(MenuHeaderRow())
    private lazy var pinItem = hostedItem(MenuPINRow())
    private lazy var openAtLoginItem = hostedItem(OpenAtLoginRow(), minimumWidth: 0)
    // An item can only be in one menu at a time, so the submenu is reused too.
    private let settingsSubmenu = NSMenu()
    private lazy var settingsItem: NSMenuItem = {
        let item = NSMenuItem(title: String(localized: "Settings"), action: nil, keyEquivalent: "")
        item.submenu = settingsSubmenu
        return item
    }()
    private lazy var devicesItem = hostedItem(MenuDevicesRow())

    init(server: RemoteServer) {
        self.server = server
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        // @Published fires before the value changes, so read it on the next run loop turn.
        server.$clients
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateIcon() }
            .store(in: &cancellables)
        updateIcon()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        LaunchAtLogin.shared.refresh()
        rebuild()
    }

    private func updateIcon() {
        let symbol = server.clients.isEmpty ? "appletvremote.gen1" : "appletvremote.gen1.fill"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Media Remote")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    private func rebuild() {
        menu.removeAllItems()

        menu.addItem(headerItem)
        menu.addItem(.separator())
        menu.addItem(pinItem)
        menu.addItem(.separator())
        menu.addItem(devicesItem)

        if server.needsAccessibility {
            menu.addItem(.separator())
            let accessibility = item(String(localized: "Allow Accessibility access…"), action: #selector(openAccessibilitySettings))
            accessibility.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(accessibility)
        }

        menu.addItem(.separator())
        updateSettingsMenu()
        menu.addItem(settingsItem)
        menu.addItem(item(String(localized: "About Media Remote"), action: #selector(showAbout)))

        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Media Remote"), action: #selector(quit), key: "q"))
    }

    private func updateSettingsMenu() {
        let submenu = settingsSubmenu
        submenu.removeAllItems()
        submenu.autoenablesItems = false
        let launchAtLogin = LaunchAtLogin.shared
        submenu.addItem(openAtLoginItem)
        if launchAtLogin.needsApproval {
            submenu.addItem(item(String(localized: "Allow in Login Items…"), action: #selector(openLoginItemsSettings)))
        }
        if let error = launchAtLogin.error {
            submenu.addItem(disabledItem(error))
        }
    }

    // MARK: - Actions

    @objc private func openAccessibilitySettings() {
        MediaKeys.openAccessibilitySettings()
    }

    @objc private func openLoginItemsSettings() {
        LaunchAtLogin.shared.openLoginItemsSettings()
    }

    @objc private func showAbout() {
        AboutWindow.show()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func item(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func hostedItem<Content: View>(_ content: Content, minimumWidth: CGFloat = 260) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuRowHostingView(rootView: content.environmentObject(server), minimumWidth: minimumWidth)
        return item
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}
