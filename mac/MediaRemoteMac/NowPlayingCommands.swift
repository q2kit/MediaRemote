import Foundation

/// Sends transport commands to the current "Now Playing" app through the private
/// MediaRemote.framework (what Control Center uses). Unlike `MediaKeys`, this needs no
/// Accessibility permission, but being private API it may stop working in a future macOS.
enum NowPlayingCommands {
    // Values of MRMediaRemoteCommand
    enum Command: UInt32 {
        case togglePlayPause = 2
        case nextTrack = 4
        case previousTrack = 5
    }

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private static let sendCommand: SendCommand? = {
        guard
            let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
            let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    static var isAvailable: Bool {
        sendCommand != nil
    }

    /// Returns false when the framework is unavailable or rejected the command.
    @discardableResult
    static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil) ?? false
    }
}
