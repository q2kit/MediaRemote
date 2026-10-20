import Foundation

/// Bonjour service type advertised by the Mac and browsed by the iPhone.
/// Must match NSBonjourServices in both Info.plist files.
enum RemoteService {
    static let type = "_mediaremote._tcp"
}

enum RemoteCommand: String, Codable, CaseIterable {
    case playPause
    case next
    case previous
    case volumeUp
    case volumeDown
    case toggleMute
    /// Uses `RemoteMessage.value` (0...1).
    case setVolume
    /// Uses `RemoteMessage.value` (seconds).
    case seek
    /// Uses `RemoteMessage.outputID`.
    case selectOutput
    /// Uses `RemoteMessage.sourceID`; nil goes back to following whatever the Mac plays.
    case selectSource
    /// The volume of the device the sound ends up on (`outputVolume`). Uses `RemoteMessage.value` (0...1).
    case setOutputVolume
    /// Uses `RemoteMessage.muted`.
    case setOutputMuted
}

/// An app on the Mac that shows up in Now Playing. Picking one makes it the app that the
/// playback controls (and the Mac's own media keys) act on.
struct MediaSource: Codable, Hashable, Identifiable {
    /// Bundle identifier.
    var id: String
    var name: String
    var playing: Bool
    var title: String?
}

/// An audio output device of the Mac.
struct AudioOutput: Codable, Hashable, Identifiable {
    enum Kind: String, Codable {
        case builtIn, bluetooth, airPlay, usb, display, other
    }

    /// CoreAudio device UID (stable across launches).
    var id: String
    var name: String
    var kind: Kind
}

/// Every frame on the wire is one JSON-encoded `RemoteMessage` followed by `\n`.
///
/// Flow: client sends `hello(pin)`; server answers `welcome` + `state`, or `denied` and closes.
/// After that the client sends `command`s and the server pushes `state` whenever volume or Now Playing changes,
/// and `artwork` whenever the cover art changes.
struct RemoteMessage: Codable, Equatable {
    enum Kind: String, Codable {
        case hello, welcome, denied, command, state, artwork
    }

    var kind: Kind
    var pin: String? = nil
    var deviceName: String? = nil
    var command: RemoteCommand? = nil
    var value: Double? = nil
    /// nil when the current output device has no software volume control.
    var volume: Double? = nil
    var muted: Bool? = nil
    /// Now Playing info; all nil when the Mac can't tell (nothing playing / API unavailable).
    var playing: Bool? = nil
    var title: String? = nil
    var artist: String? = nil
    var appName: String? = nil
    /// Seconds. `elapsed` is the position when the message was sent; it advances at `rate`.
    var duration: Double? = nil
    var elapsed: Double? = nil
    var rate: Double? = nil
    /// Available outputs and the current one (in `state`), or the one to switch to (in `selectOutput`).
    /// With `appVolume` these are the outputs of the app being controlled, and a nil `outputID` means
    /// it follows the Mac's output; `selectOutput` without an ID goes back to that.
    var outputs: [AudioOutput]? = nil
    var outputID: String? = nil
    /// Apps that can be picked as the source, in `state`. nil when the Mac can't offer a choice.
    var sources: [MediaSource]? = nil
    /// The picked source (in `state`, nil while following the Mac), or the one to pick (in `selectSource`).
    var sourceID: String? = nil
    /// The app the playback controls act on right now.
    var nowPlayingID: String? = nil
    /// True when `volume`, `muted` and the output belong to the app being controlled rather than to
    /// the whole Mac. That needs SoundControl running on the Mac.
    var appVolume: Bool? = nil
    /// Where that app's sound ends up, when known.
    var appOutputName: String? = nil
    /// With `appVolume`: the volume of the device that app's sound ends up on (`appOutputName`), shared
    /// with every other app playing there. nil when that device has no volume control.
    var outputVolume: Double? = nil
    var outputMuted: Bool? = nil
    /// JPEG cover art; nil in an `artwork` message means "no artwork".
    var artwork: Data? = nil
    var reason: String? = nil

    static func hello(pin: String, deviceName: String) -> RemoteMessage {
        RemoteMessage(kind: .hello, pin: pin, deviceName: deviceName)
    }

    static func command(_ command: RemoteCommand, value: Double? = nil, muted: Bool? = nil,
                        outputID: String? = nil, sourceID: String? = nil) -> RemoteMessage {
        RemoteMessage(kind: .command, command: command, value: value, muted: muted, outputID: outputID,
                      sourceID: sourceID)
    }

    static func artwork(_ data: Data?) -> RemoteMessage {
        RemoteMessage(kind: .artwork, artwork: data)
    }

    static func denied(_ reason: String) -> RemoteMessage {
        RemoteMessage(kind: .denied, reason: reason)
    }

    static let welcome = RemoteMessage(kind: .welcome)
}
