import AppKit
import SwiftUI

/// SwiftUI content shown as a row of the status menu. Clicks handled inside a custom row don't
/// close the menu, and the row follows its content's height while the menu is open.
final class MenuRowHostingView<Content: View>: NSHostingView<Content> {
    init(rootView: Content, minimumWidth: CGFloat) {
        super.init(rootView: rootView)
        autoresizingMask = [.width]
        let size = fittingSize
        setFrameSize(NSSize(width: max(size.width, minimumWidth), height: size.height))
    }

    @available(*, unavailable)
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        let height = fittingSize.height
        if abs(frame.height - height) > 0.5 {
            setFrameSize(NSSize(width: frame.width, height: height))
        }
    }
}

/// App icon, name and whether the Mac is visible on the network.
struct MenuHeaderRow: View {
    @EnvironmentObject private var server: RemoteServer

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: AppIcon.image)
                .resizable()
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text("Media Remote")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 5) {
                    Circle()
                        .fill(server.isListening ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                    Group {
                        if server.isListening {
                            Text("Visible as “\(server.serviceName)”")
                        } else {
                            Text(server.listenerError ?? String(localized: "Starting…"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

/// The pairing PIN in large digits, with a button to generate a new one.
struct MenuPINRow: View {
    @EnvironmentObject private var server: RemoteServer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("PIN")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .center, spacing: 12) {
                Text(verbatim: server.pin.map(String.init).joined(separator: " "))
                    .font(.system(size: 26, weight: .semibold, design: .monospaced))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: server.pin)
                Spacer(minLength: 0)
                RegenerateButton {
                    server.regeneratePIN()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// Round icon button; the arrow spins once per click.
private struct RegenerateButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @State private var turns = 0.0

    var body: some View {
        Image(systemName: "arrow.clockwise")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isHovered ? Color.primary : Color.secondary)
            .rotationEffect(.degrees(turns * 360))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(isHovered ? 0.14 : 0.06)))
            .contentShape(Circle())
            .onHover { hovered in
                withAnimation(.easeOut(duration: 0.12)) { isHovered = hovered }
            }
            .onTapGesture {
                withAnimation(.spring(response: 0.55, dampingFraction: 0.75)) { turns += 1 }
                action()
            }
            .help(Text("Generate new PIN"))
            .accessibilityElement()
            .accessibilityLabel(Text("Generate new PIN"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { action() }
    }
}

struct MenuDevicesRow: View {
    @EnvironmentObject private var server: RemoteServer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Connected devices")
                .font(.caption)
                .foregroundStyle(.secondary)
            if server.clients.isEmpty {
                Text("None")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(server.clients) { client in
                    Label(client.name, systemImage: "iphone")
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

/// A menu item with a check on the trailing side (space reserved even when off), like many
/// menu bar apps. Toggling keeps the menu open.
struct MenuToggleRow: View {
    let title: LocalizedStringKey
    let isOn: Bool
    let toggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        // Spacing 0 + a 12pt spacer: the row's natural width is text + 12 + check, which is what
        // the submenu sizes to.
        HStack(spacing: 0) {
            Text(title)
            Spacer(minLength: 12)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 14))
                .symbolRenderingMode(.hierarchical)
                .opacity(isOn ? 1 : 0)
        }
        .font(.system(size: NSFont.systemFontSize))
        .foregroundStyle(isHovered ? Color.white : Color.primary)
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: toggle)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? Text("On") : Text("Off"))
    }
}

/// "Open at login", following `LaunchAtLogin` live.
struct OpenAtLoginRow: View {
    @ObservedObject var launchAtLogin = LaunchAtLogin.shared

    var body: some View {
        MenuToggleRow(title: "Open at login", isOn: launchAtLogin.isEnabled) {
            launchAtLogin.setEnabled(!launchAtLogin.isEnabled)
        }
    }
}

enum AppIcon {
    /// `NSApp.applicationIconImage` comes back as the generic icon for this menu bar app,
    /// so read the icon from the bundle like Finder does.
    static var image: NSImage {
        NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
}
