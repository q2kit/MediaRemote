import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let server = RemoteServer()
    private var statusMenu: StatusMenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusMenu = StatusMenuController(server: server)
    }
}
