import Foundation
import Network
import UIKit

/// One connection to a Mac: authenticates with the PIN, sends commands, receives volume state.
final class RemoteClient: ObservableObject {
    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case needsPIN(message: String?)
        case disconnected(message: String)
    }

    @Published private(set) var status: Status = .idle
    /// nil when the Mac's output device has no software volume (e.g. HDMI).
    @Published private(set) var volume: Double?
    @Published private(set) var muted = false
    /// nil when the Mac can't tell what's playing.
    @Published private(set) var isPlaying: Bool?
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var appName: String?
    @Published private(set) var duration: Double?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var outputs: [AudioOutput] = []
    @Published private(set) var outputID: String?
    /// Apps on the Mac that can be picked; nil when the Mac doesn't offer a choice.
    @Published private(set) var sources: [MediaSource]?
    /// The picked app, nil while following whatever the Mac plays.
    @Published private(set) var sourceID: String?
    /// The app the controls act on right now.
    @Published private(set) var nowPlayingID: String?
    /// True when the volume is that app's own (SoundControl on the Mac), not the Mac's.
    @Published private(set) var appVolume = false
    @Published private(set) var appOutputName: String?
    /// With `appVolume`: the volume of the device that app plays on, shared with every app there.
    @Published private(set) var outputVolume: Double?
    @Published private(set) var outputMuted = false
    /// Position reported by the Mac, the moment we received it, and how fast it advances.
    @Published private var elapsedAnchor: (elapsed: Double, date: Date, rate: Double)?
    /// After a seek, states sent before the Mac applied it would snap the position back.
    private var seekPendingUntil: Date?

    let mac: DiscoveredMac
    private var line: LineConnection<RemoteMessage>?
    private var pendingPIN: String?

    init(mac: DiscoveredMac) {
        self.mac = mac
    }

    private var savedPIN: String? {
        KnownMacStore.shared.mac(named: mac.name)?.pin
    }

    /// Connects with the saved PIN, or asks for one.
    func connect() {
        if let savedPIN {
            connect(pin: savedPIN)
        } else {
            status = .needsPIN(message: nil)
        }
    }

    func connect(pin: String) {
        disconnect()
        pendingPIN = pin
        status = .connecting

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let line = LineConnection<RemoteMessage>(NWConnection(to: mac.endpoint, using: parameters))
        line.onStateChange = { [weak self, weak line] state in
            guard let self, let line, line === self.line else { return }
            connectionStateChanged(state, line: line)
        }
        line.onMessage = { [weak self, weak line] message in
            guard let self, let line, line === self.line else { return }
            handle(message)
        }
        self.line = line
        line.start()
    }

    func disconnect() {
        let line = self.line
        self.line = nil
        line?.cancel()
    }

    /// Reconnects after the app comes back from background (iOS drops the socket).
    func reconnectIfNeeded() {
        switch status {
        case .disconnected, .idle:
            connect()
        default:
            break
        }
    }

    func send(_ command: RemoteCommand, value: Double? = nil) {
        guard status == .connected else { return }
        line?.send(.command(command, value: value))
        // Shown right away; the Mac confirms with its next state. Turning up also unmutes there.
        if command == .setVolume, let value {
            volume = value
            if value > 0 { muted = false }
        } else if command == .toggleMute {
            muted.toggle()
        }
    }

    func seek(to seconds: Double) {
        guard status == .connected else { return }
        line?.send(.command(.seek, value: seconds))
        // Show the new position right away; the Mac confirms with the next state.
        elapsedAnchor = (seconds, Date(), elapsedAnchor?.rate ?? 0)
        seekPendingUntil = Date().addingTimeInterval(2.5)
    }

    private func updateElapsed(_ elapsed: Double?, rate: Double) {
        if let until = seekPendingUntil, Date() < until, let elapsed, let expected = self.elapsed(at: Date()),
           abs(elapsed - expected) > 2 {
            return // stale position from before the seek
        }
        seekPendingUntil = nil
        elapsedAnchor = elapsed.map { ($0, Date(), rate) }
    }

    /// With `appVolume`, nil sends the app back to the Mac's own output.
    func selectOutput(_ id: String?) {
        guard status == .connected, id != outputID else { return }
        line?.send(.command(.selectOutput, outputID: id))
        outputID = id
    }

    func setOutputVolume(_ value: Double) {
        guard status == .connected else { return }
        line?.send(.command(.setOutputVolume, value: value))
        outputVolume = value
        if value > 0 { outputMuted = false }
    }

    func setOutputMuted(_ muted: Bool) {
        guard status == .connected else { return }
        line?.send(.command(.setOutputMuted, muted: muted))
        outputMuted = muted
    }

    /// The app the controls act on: the picked one, or whatever the Mac follows before anything is picked.
    var currentSourceID: String? {
        sourceID ?? nowPlayingID
    }

    /// Picks the next (`step` 1) or previous (-1) app, in the order the Mac lists them. False when
    /// there's none that way.
    @discardableResult
    func selectAdjacentSource(_ step: Int) -> Bool {
        guard let id = adjacentSourceID(step) else { return false }
        selectSource(id)
        return true
    }

    func canSelectAdjacentSource(_ step: Int) -> Bool {
        adjacentSourceID(step) != nil
    }

    private func adjacentSourceID(_ step: Int) -> String? {
        guard let sources, !sources.isEmpty else { return nil }
        let index = sources.firstIndex { $0.id == currentSourceID } ?? (step > 0 ? -1 : sources.count)
        return sources.indices.contains(index + step) ? sources[index + step].id : nil
    }

    func selectSource(_ id: String?) {
        guard status == .connected, id != sourceID else { return }
        line?.send(.command(.selectSource, sourceID: id))
        sourceID = id
    }

    /// Playback position extrapolated to `date`.
    func elapsed(at date: Date) -> Double? {
        guard let anchor = elapsedAnchor else { return nil }
        var elapsed = anchor.elapsed + date.timeIntervalSince(anchor.date) * anchor.rate
        if let duration { elapsed = min(elapsed, duration) }
        return max(elapsed, 0)
    }

    private func connectionStateChanged(_ state: NWConnection.State, line: LineConnection<RemoteMessage>) {
        switch state {
        case .ready:
            line.send(.hello(pin: pendingPIN ?? "", deviceName: DeviceName.current))
        case .waiting(let error):
            status = .disconnected(message: error.localizedDescription)
            disconnect()
        case .failed(let error):
            status = .disconnected(message: error.localizedDescription)
            self.line = nil
        case .cancelled:
            if status == .connected || status == .connecting {
                status = .disconnected(message: String(localized: "Lost connection to \(mac.name)."))
            }
            self.line = nil
        default:
            break
        }
    }

    private func handle(_ message: RemoteMessage) {
        switch message.kind {
        case .welcome:
            if let pendingPIN {
                KnownMacStore.shared.recordConnection(name: mac.name, pin: pendingPIN)
            }
            status = .connected
        case .denied:
            KnownMacStore.shared.clearPIN(for: mac.name)
            status = .needsPIN(message: String(localized: "Wrong PIN"))
            disconnect()
        case .state:
            volume = message.volume
            muted = message.muted ?? false
            isPlaying = message.playing
            title = message.title
            artist = message.artist
            appName = message.appName
            duration = message.duration
            updateElapsed(message.elapsed, rate: message.rate ?? 0)
            outputs = message.outputs ?? []
            outputID = message.outputID
            sources = message.sources
            sourceID = message.sourceID
            nowPlayingID = message.nowPlayingID
            appVolume = message.appVolume ?? false
            appOutputName = message.appOutputName
            outputVolume = message.outputVolume
            outputMuted = message.outputMuted ?? false
        case .artwork:
            artwork = message.artwork.flatMap(UIImage.init(data:))
        default:
            break
        }
    }
}
