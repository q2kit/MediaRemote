import AppKit
import SwiftUI

/// A small About window (the standard panel's icon and name can't be enlarged).
@MainActor
enum AboutWindow {
    private static var window: NSWindow?

    static func show() {
        if window == nil {
            let controller = NSHostingController(rootView: AboutView())
            // Size the window to the content; without this it opens too narrow and truncates the name.
            controller.sizingOptions = [.preferredContentSize]
            let window = NSWindow(contentViewController: controller)
            window.setContentSize(controller.view.fittingSize)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // A menu bar app isn't active, so the window would open behind other apps.
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 128, height: 128)
            Text("Media Remote")
                .font(.system(size: 24, weight: .bold))
                .fixedSize()
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 56)
        .padding(.top, 12)
        .padding(.bottom, 32)
    }

    private static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }
}
