import Combine
import Foundation
import Network

/// SoundControl's control socket messages. A copy of the types in SoundControl's ControlServer.swift;
/// fields only get added there, so unknown ones are simply ignored here.
struct ControlMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case hello, state, setVolume, setMuted, setDevice, setDeviceVolume, setDeviceMuted
    }

    var kind: Kind
    var version: Int?
    var app: String?
    var volume: Float?
    var muted: Bool?
    var device: String?
    var apps: [ControlApp]?
    var settings: [String: ControlSettings]?
    var devices: [ControlDevice]?
}

struct ControlApp: Codable, Equatable {
    var id: String
    var name: String
    var playing: Bool
    var device: ControlDevice?
}

struct ControlDevice: Codable, Equatable {
    var uid: String
    var name: String
    /// Only in `devices`; nil when the device has no volume control.
    var volume: Float?
    var muted: Bool?
}

struct ControlSettings: Codable, Equatable {
    var volume: Float
    var muted: Bool
    /// nil when the app follows the system output.
    var device: String?
}

/// Talks to SoundControl when it runs on this Mac, so the remote can change the volume of the app
/// it's controlling instead of the whole Mac. That matters once SoundControl sends apps to different
/// devices: turning the Mac's output down does nothing for an app playing on headphones.
///
/// Without SoundControl this just stays disconnected. It notices SoundControl starting by watching the
/// folder its socket lives in, so nothing is polled. It can be turned off in Settings › Extensions;
/// then it doesn't connect or watch anything, and the remote behaves as if SoundControl weren't there.
final class SoundControlLink: ObservableObject {
    static let socketURL = URL.applicationSupportDirectory
        .appendingPathComponent("SoundControl", isDirectory: true)
        .appendingPathComponent("control.sock")
    private static let enabledKey = "soundControlEnabled"

    /// On unless the user turned it off.
    @Published var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }
    @Published private(set) var isConnected = false
    /// Apps that have audio right now, with the device their sound ends up on.
    private(set) var apps: [ControlApp] = []
    /// Devices an app can be sent to, as SoundControl's own pickers show them.
    private(set) var devices: [ControlDevice] = []
    var onChange: (() -> Void)?

    /// Every app whose settings aren't the defaults.
    private var settings: [String: ControlSettings] = [:]
    private var line: LineConnection<ControlMessage>?
    private var folderWatch: DispatchSourceFileSystemObject?
    private var watchedFolder: URL?
    private var retryScheduled = false
    /// A few retries after SoundControl's folder changes, to get past the moment between the socket
    /// appearing and SoundControl accepting connections. A socket left behind by a SoundControl that
    /// has quit refuses forever, so this doesn't go on.
    private var retriesLeft = 3

    init() {
        UserDefaults.standard.register(defaults: [Self.enabledKey: true])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    private func start() {
        retriesLeft = 3
        watchFolder()
        connect()
    }

    private func stop() {
        folderWatch?.cancel()
        folderWatch = nil
        watchedFolder = nil
        // Forgotten first, so its cancellation isn't mistaken for SoundControl going away.
        let line = self.line
        self.line = nil
        line?.cancel()
        disconnected()
    }

    /// Volume, mute and device of an app, including apps that aren't playing right now. nil while disconnected.
    func settings(of app: String) -> ControlSettings? {
        isConnected ? settings[app] ?? ControlSettings(volume: 1, muted: false) : nil
    }

    /// Where an app's sound ends up: the device SoundControl reports for it while it plays, otherwise
    /// the one picked for it if connected, otherwise the Mac's output (`systemOutputUID`).
    func output(of app: String, systemOutputUID: String?) -> ControlDevice? {
        let uid = apps.first { $0.id == app }?.device?.uid
            ?? settings(of: app)?.device.flatMap { uid in devices.contains { $0.uid == uid } ? uid : nil }
            ?? systemOutputUID
        return devices.first { $0.uid == uid }
    }

    /// SoundControl unmutes an app that's turned up.
    func setVolume(_ volume: Float, of app: String) {
        let volume = min(max(volume, 0), 1)
        update(app) {
            $0.volume = volume
            if volume > 0 { $0.muted = false }
        }
        line?.send(ControlMessage(kind: .setVolume, app: app, volume: volume))
    }

    func setMuted(_ muted: Bool, of app: String) {
        update(app) { $0.muted = muted }
        line?.send(ControlMessage(kind: .setMuted, app: app, muted: muted))
    }

    /// nil sends the app back to the system output.
    func setDevice(_ uid: String?, of app: String) {
        update(app) { $0.device = uid }
        line?.send(ControlMessage(kind: .setDevice, app: app, device: uid))
    }

    /// A device's own volume, shared by every app playing on it. Raising it from 0 also unmutes.
    func setDeviceVolume(_ volume: Float, of uid: String) {
        let volume = min(max(volume, 0), 1)
        updateDevice(uid) {
            $0.volume = volume
            if volume > 0 { $0.muted = false }
        }
        line?.send(ControlMessage(kind: .setDeviceVolume, volume: volume, device: uid))
    }

    func setDeviceMuted(_ muted: Bool, of uid: String) {
        updateDevice(uid) { $0.muted = muted }
        line?.send(ControlMessage(kind: .setDeviceMuted, muted: muted, device: uid))
    }

    private func updateDevice(_ uid: String, _ change: (inout ControlDevice) -> Void) {
        guard let index = devices.firstIndex(where: { $0.uid == uid }) else { return }
        change(&devices[index])
    }

    /// Shows the change right away; SoundControl confirms it with its next state.
    private func update(_ app: String, _ change: (inout ControlSettings) -> Void) {
        guard var current = settings(of: app) else { return }
        change(&current)
        settings[app] = current
    }

    // MARK: - Connection

    private func connect() {
        guard isEnabled, line == nil, FileManager.default.fileExists(atPath: Self.socketURL.path) else { return }
        let line = LineConnection<ControlMessage>(NWConnection(to: .unix(path: Self.socketURL.path), using: .tcp))
        line.onStateChange = { [weak self, weak line] state in
            guard let self, let line, line === self.line else { return }
            switch state {
            case .ready:
                line.send(ControlMessage(kind: .hello, version: 1))
            case .waiting, .failed:
                // Refused: SoundControl isn't running (its socket stays behind), or is still starting up.
                line.cancel()
                scheduleRetry()
            case .cancelled:
                self.line = nil
                disconnected()
            default:
                break
            }
        }
        line.onMessage = { [weak self, weak line] message in
            guard let self, let line, line === self.line, message.kind == .state else { return }
            apps = message.apps ?? []
            settings = message.settings ?? [:]
            devices = message.devices ?? []
            isConnected = true
            retriesLeft = 3
            onChange?()
        }
        self.line = line
        line.start()
    }

    private func disconnected() {
        guard isConnected else { return }
        isConnected = false
        apps = []
        devices = []
        settings = [:]
        onChange?()
    }

    private func scheduleRetry() {
        guard !retryScheduled, retriesLeft > 0 else { return }
        retryScheduled = true
        retriesLeft -= 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            retryScheduled = false
            connect()
        }
    }

    /// Watches SoundControl's folder, or Application Support until that folder exists. SoundControl
    /// creates its socket there every time it starts.
    private func watchFolder() {
        let folder = Self.socketURL.deletingLastPathComponent()
        let target = FileManager.default.fileExists(atPath: folder.path) ? folder : folder.deletingLastPathComponent()
        guard target != watchedFolder else { return }

        folderWatch?.cancel()
        folderWatch = nil
        watchedFolder = nil
        let descriptor = open(target.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            watchFolder()
            retriesLeft = 3
            connect()
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        folderWatch = source
        watchedFolder = target
    }
}
