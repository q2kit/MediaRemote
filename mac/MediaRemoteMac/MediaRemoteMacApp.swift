import SwiftUI

@main
struct MediaRemoteMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Everything lives in the status item menu (see StatusMenuController); a scene is still required.
        Settings {
            EmptyView()
        }
    }
}
