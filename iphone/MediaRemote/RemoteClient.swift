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
    /// Position reported by the Mac, the moment we received it, and how fast it advances.
    @Published private var elapsedAnchor: (elapsed: Double, date: Date, rate: Double)?
    /// After a seek, states sent before the Mac applied it would snap the position back.
    private var seekPendingUntil: Date?

    let mac: DiscoveredMac
    private var line: LineConnection?
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
        let line = LineConnection(NWConnection(to: mac.endpoint, using: parameters))
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
        if command == .setVolume, let value {
            volume = value
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

    func selectOutput(_ id: String) {
        guard status == .connected, id != outputID else { return }
        line?.send(.command(.selectOutput, outputID: id))
        outputID = id
    }

    /// Playback position extrapolated to `date`.
    func elapsed(at date: Date) -> Double? {
        guard let anchor = elapsedAnchor else { return nil }
        var elapsed = anchor.elapsed + date.timeIntervalSince(anchor.date) * anchor.rate
        if let duration { elapsed = min(elapsed, duration) }
        return max(elapsed, 0)
    }

    private func connectionStateChanged(_ state: NWConnection.State, line: LineConnection) {
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
        case .artwork:
            artwork = message.artwork.flatMap(UIImage.init(data:))
        default:
            break
        }
    }
}
