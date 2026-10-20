import Foundation
import Network

/// Listens on the local network (advertised via Bonjour), authenticates iPhones with a PIN
/// and turns their commands into media key presses / volume changes.
final class RemoteServer: ObservableObject {
    struct Client: Identifiable {
        let id: ObjectIdentifier
        let name: String
    }

    @Published private(set) var pin: String
    @Published private(set) var isListening = false
    @Published private(set) var listenerError: String?
    @Published private(set) var clients: [Client] = []
    /// Accessibility is only needed for the media-key fallbacks: transport commands when
    /// MediaRemote is unavailable, and volume when the output has no software volume (HDMI etc.).
    @Published private(set) var needsAccessibility = RemoteServer.computeNeedsAccessibility()

    /// The computer name; `-serviceName "…"` at launch overrides it (for demos and screenshots).
    let serviceName = UserDefaults.standard.string(forKey: "serviceName") ?? Host.current().localizedName ?? "Mac"

    private final class Session {
        let line: LineConnection<RemoteMessage>
        var deviceName: String?
        var isAuthenticated = false
        init(_ line: LineConnection<RemoteMessage>) { self.line = line }
    }

    private let nowPlaying = NowPlayingMonitor()
    let soundControl = SoundControlLink()
    private var listener: NWListener?
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var pollTimer: Timer?
    /// What was last broadcast. Includes the full Now Playing info so seeks count as changes
    /// even though `elapsed` itself is only computed when sending.
    private var lastBroadcast: BroadcastKey?

    private struct BroadcastKey: Equatable {
        var state: RemoteMessage
        var nowPlaying: NowPlayingMonitor.Info?
    }

    private static let pinKey = "pairingPIN"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.pinKey) {
            pin = saved
        } else {
            pin = Self.makePIN()
            UserDefaults.standard.set(pin, forKey: Self.pinKey)
        }
        startListener()
        nowPlaying.onChange = { [weak self] in
            self?.broadcastStateIfChanged()
        }
        nowPlaying.onArtworkChange = { [weak self] in
            self?.broadcastArtwork()
        }
        soundControl.onChange = { [weak self] in
            self?.broadcastStateIfChanged()
        }
        nowPlaying.start()
        if needsAccessibility {
            MediaKeys.requestAccess()
        }
        // Pick up volume changes made on the Mac itself and Accessibility being granted.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            broadcastStateIfChanged()
            let needsAccessibility = Self.computeNeedsAccessibility()
            if self.needsAccessibility != needsAccessibility {
                self.needsAccessibility = needsAccessibility
            }
        }
    }

    // MARK: - Pairing

    /// Generates a new PIN and drops every connected device, forcing them to pair again.
    func regeneratePIN() {
        pin = Self.makePIN()
        UserDefaults.standard.set(pin, forKey: Self.pinKey)
        for session in sessions.values {
            session.line.cancel()
        }
    }

    private static func makePIN() -> String {
        String(format: "%06d", Int.random(in: 0...999_999))
    }

    // MARK: - Listener

    private func startListener() {
        do {
            let parameters = NWParameters.tcp
            parameters.includePeerToPeer = true
            let listener = try NWListener(using: parameters)
            listener.service = NWListener.Service(name: serviceName, type: RemoteService.type)
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self] state in
                self?.listenerStateChanged(state)
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            listenerError = error.localizedDescription
            scheduleRestart()
        }
    }

    private func listenerStateChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            isListening = true
            listenerError = nil
        case .failed(let error):
            isListening = false
            listenerError = error.localizedDescription
            listener?.cancel()
            listener = nil
            scheduleRestart()
        case .waiting(let error):
            isListening = false
            listenerError = error.localizedDescription
        case .cancelled:
            isListening = false
        default:
            break
        }
    }

    private func scheduleRestart() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, listener == nil else { return }
            startListener()
        }
    }

    // MARK: - Sessions

    private func accept(_ connection: NWConnection) {
        let session = Session(LineConnection(connection))
        let id = ObjectIdentifier(session)
        sessions[id] = session

        session.line.onStateChange = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.remove(id)
            default:
                break
            }
        }
        session.line.onMessage = { [weak self, weak session] message in
            guard let self, let session else { return }
            handle(message, from: session)
        }
        session.line.start()

        // Drop connections that never authenticate.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak session] in
            guard let session, !session.isAuthenticated else { return }
            session.line.cancel()
        }
    }

    private func remove(_ id: ObjectIdentifier) {
        guard sessions.removeValue(forKey: id) != nil else { return }
        refreshClients()
        // Picking a source changes how the whole Mac's media keys behave; only keep that up while
        // someone is holding the remote.
        if clients.isEmpty {
            nowPlaying.selectSource(nil)
        }
    }

    private func refreshClients() {
        clients = sessions
            .filter { $0.value.isAuthenticated }
            .map { Client(id: $0.key, name: $0.value.deviceName ?? "iPhone") }
            .sorted { $0.name < $1.name }
    }

    private func handle(_ message: RemoteMessage, from session: Session) {
        switch message.kind {
        case .hello:
            authenticate(session, pin: message.pin, deviceName: message.deviceName)
        case .command:
            guard session.isAuthenticated, let command = message.command else { return }
            perform(command, value: message.value, muted: message.muted, outputID: message.outputID,
                    sourceID: message.sourceID)
        default:
            break
        }
    }

    private func authenticate(_ session: Session, pin candidate: String?, deviceName: String?) {
        guard !session.isAuthenticated else { return }
        guard candidate == pin else {
            // Slow down guessing, then hang up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                session.line.send(.denied("Wrong PIN"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    session.line.cancel()
                }
            }
            return
        }
        session.isAuthenticated = true
        session.deviceName = deviceName
        session.line.send(.welcome)
        session.line.send(stamped(currentState()))
        session.line.send(.artwork(nowPlaying.artwork))
        refreshClients()
    }

    // MARK: - Commands

    private func perform(_ command: RemoteCommand, value: Double?, muted: Bool?, outputID: String?, sourceID: String?) {
        switch command {
        case .playPause:
            transport(.togglePlayPause, fallbackKey: .play)
        case .next:
            transport(.nextTrack, fallbackKey: .next)
        case .previous:
            transport(.previousTrack, fallbackKey: .previous)
        case .volumeUp:
            if let app = volumeApp, let settings = soundControl.settings(of: app) {
                soundControl.setVolume(settings.volume + SystemVolume.step, of: app)
                break
            }
            if let volume = SystemVolume.volume, SystemVolume.setVolume(volume + SystemVolume.step) {
                break
            }
            MediaKeys.press(.soundUp)
        case .volumeDown:
            if let app = volumeApp, let settings = soundControl.settings(of: app) {
                soundControl.setVolume(settings.volume - SystemVolume.step, of: app)
                break
            }
            if let volume = SystemVolume.volume, SystemVolume.setVolume(volume - SystemVolume.step) {
                break
            }
            MediaKeys.press(.soundDown)
        case .toggleMute:
            if let app = volumeApp, let settings = soundControl.settings(of: app) {
                soundControl.setMuted(!settings.muted, of: app)
                break
            }
            if let muted = SystemVolume.isMuted, SystemVolume.setMuted(!muted) {
                break
            }
            MediaKeys.press(.mute)
        case .setVolume:
            guard let value else { return }
            if let app = volumeApp {
                soundControl.setVolume(Float(value), of: app)
            } else {
                SystemVolume.setVolume(Float(value))
            }
        case .seek:
            guard let value else { return }
            nowPlaying.seek(to: value)
        case .selectOutput:
            if let app = volumeApp {
                soundControl.setDevice(outputID, of: app)
            } else if let outputID {
                AudioOutputs.select(id: outputID)
            }
        case .selectSource:
            nowPlaying.selectSource(sourceID)
        case .setOutputVolume:
            guard let value else { return }
            if let app = volumeApp, let device = appOutput(of: app) {
                soundControl.setDeviceVolume(Float(value), of: device.uid)
            } else {
                SystemVolume.setVolume(Float(value))
            }
        case .setOutputMuted:
            guard let muted else { return }
            if let app = volumeApp, let device = appOutput(of: app) {
                soundControl.setDeviceMuted(muted, of: device.uid)
            } else {
                SystemVolume.setMuted(muted)
            }
        }
        broadcastStateIfChanged()
    }

    /// The app whose own volume the remote changes, as SoundControl knows it: the one playback
    /// commands go to. nil without SoundControl, and then the remote changes the Mac's volume.
    private var volumeApp: String? {
        guard soundControl.isConnected, let id = nowPlaying.nowPlayingID else { return nil }
        // A web app plays through the browser it belongs to, and SoundControl only sees the browser.
        return nowPlaying.sources.first { $0.id == id }?.parentID ?? id
    }

    private func appOutput(of app: String) -> ControlDevice? {
        soundControl.output(of: app, systemOutputUID: AudioOutputs.currentID())
    }

    /// MediaRemote needs no permission; media keys (which need Accessibility) are the fallback.
    private func transport(_ command: NowPlayingCommands.Command, fallbackKey key: MediaKeys.Key) {
        if !NowPlayingCommands.send(command) {
            MediaKeys.press(key)
        }
    }

    private static func computeNeedsAccessibility() -> Bool {
        !MediaKeys.isTrusted && (!NowPlayingCommands.isAvailable || SystemVolume.volume == nil)
    }

    /// State without `elapsed`, so it only differs from the last broadcast when something really changed.
    private func currentState() -> RemoteMessage {
        let info = nowPlaying.info
        var state = RemoteMessage(kind: .state)
        let systemOutputs = AudioOutputs.all()
        let systemOutputID = AudioOutputs.currentID()
        if let app = volumeApp, let settings = soundControl.settings(of: app) {
            state.volume = Double(settings.volume)
            state.muted = settings.muted
            state.appVolume = true
            let output = soundControl.output(of: app, systemOutputUID: systemOutputID)
            state.appOutputName = output?.name
            state.outputVolume = output?.volume.map(Double.init)
            state.outputMuted = output?.muted
            state.outputs = soundControl.devices.map { device in
                AudioOutput(id: device.uid, name: device.name,
                            kind: systemOutputs.first { $0.id == device.uid }?.kind ?? .other)
            }
            state.outputID = settings.device
        } else {
            state.volume = SystemVolume.volume.map(Double.init)
            state.muted = SystemVolume.isMuted
            state.outputs = systemOutputs
            state.outputID = systemOutputID
        }
        if nowPlaying.canSelectSource {
            state.sources = nowPlaying.sources.map {
                MediaSource(id: $0.id, name: $0.name, playing: $0.isPlaying, title: $0.title)
            }
            state.sourceID = nowPlaying.selectedSourceID
        }
        state.nowPlayingID = nowPlaying.nowPlayingID
        state.playing = info?.isPlaying
        state.title = info?.title
        state.artist = info?.artist
        state.appName = info?.appName
        state.duration = info?.duration
        state.rate = info?.rate
        return state
    }

    /// Fills in the playback position as of now, right before sending.
    private func stamped(_ state: RemoteMessage) -> RemoteMessage {
        var state = state
        state.elapsed = nowPlaying.info?.elapsed(at: Date())
        return state
    }

    private func broadcastArtwork() {
        let message = RemoteMessage.artwork(nowPlaying.artwork)
        for session in sessions.values where session.isAuthenticated {
            session.line.send(message)
        }
    }

    private func broadcastStateIfChanged() {
        let state = currentState()
        let key = BroadcastKey(state: state, nowPlaying: nowPlaying.info)
        guard key != lastBroadcast else { return }
        lastBroadcast = key
        let message = stamped(state)
        for session in sessions.values where session.isAuthenticated {
            session.line.send(message)
        }
    }
}
