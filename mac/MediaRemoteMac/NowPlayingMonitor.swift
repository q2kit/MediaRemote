import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Tracks what's playing: state, title/artist, progress and artwork.
///
/// Since macOS 15.4 MediaRemote only returns Now Playing info to Apple-signed processes, so
/// the bundled `libMediaRemoteHelper.dylib` is loaded into `/usr/bin/perl` (Apple-signed, but
/// allows third-party libraries) and streams JSON lines back over stdout; commands go to its stdin. This relies on
/// private API and may stop working in a future macOS; `info` then simply stays nil.
final class NowPlayingMonitor {
    struct Info: Equatable {
        var isPlaying: Bool
        var title: String?
        var artist: String?
        var appName: String?
        var duration: Double?
        /// Elapsed time as of `timestamp`.
        var elapsed: Double?
        var rate: Double
        var timestamp: Date?

        /// Elapsed time extrapolated to `date`.
        func elapsed(at date: Date) -> Double? {
            guard var elapsed else { return nil }
            if isPlaying, let timestamp {
                elapsed += date.timeIntervalSince(timestamp) * rate
            }
            if let duration, duration > 0 {
                elapsed = min(elapsed, duration)
            }
            return max(elapsed, 0)
        }
    }

    /// An app with a Now Playing session, whether or not it's the one being controlled.
    struct Source: Equatable {
        var id: String
        /// The app it belongs to, when the session comes from a web app or a helper of another app.
        var parentID: String?
        var name: String
        var isPlaying: Bool
        var title: String?
    }

    /// nil when unknown (nothing playing, or the helper can't read Now Playing).
    private(set) var info: Info?
    /// Bundle identifier of the app playback commands go to.
    private(set) var nowPlayingID: String?
    /// Sorted by name, so the list doesn't reshuffle as apps take turns playing.
    private(set) var sources: [Source] = []
    /// The app picked with `selectSource(_:)`; nil while macOS decides. The helper drops the pick by
    /// itself once the Mac is used directly (see MediaRemoteHelper.m).
    private(set) var selectedSourceID: String?
    private(set) var canSelectSource = false
    /// JPEG, scaled down for sending to the phone.
    private(set) var artwork: Data?
    var onChange: (() -> Void)?
    var onArtworkChange: (() -> Void)?

    private var process: Process?
    private var commandPipe: Pipe?
    private var buffer = Data()
    private var stopped = false

    private static let maxArtworkPixels = 600

    // Installs the helper's entry point as a perl sub and calls it (it never returns).
    private static let perlLoader = """
    use DynaLoader;
    my $h = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
    my $s = DynaLoader::dl_find_symbol($h, "mrhelper_run") or die DynaLoader::dl_error();
    DynaLoader::dl_install_xsub("main::mrhelper_run", $s);
    mrhelper_run();
    """

    func start() {
        // Writing a seek to a helper that just died must not kill the app.
        signal(SIGPIPE, SIG_IGN)
        stopped = false
        launch()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stop()
        }
    }

    func stop() {
        stopped = true
        process?.terminate()
        process = nil
        commandPipe = nil
    }

    func seek(to seconds: Double) {
        sendToHelper(String(format: "seek %.3f", max(seconds, 0)))
    }

    /// Makes `id` the app that playback commands (and the Mac's media keys) go to, or with nil lets
    /// macOS decide again.
    func selectSource(_ id: String?) {
        guard canSelectSource, id != selectedSourceID else { return }
        selectedSourceID = id
        sendToHelper(id.map { "select \($0)" } ?? "select")
        onChange?()
    }

    private func sendToHelper(_ command: String) {
        guard let data = (command + "\n").data(using: .utf8) else { return }
        try? commandPipe?.fileHandleForWriting.write(contentsOf: data)
    }

    private func launch() {
        guard let frameworks = Bundle.main.privateFrameworksPath else { return }
        let helper = (frameworks as NSString).appendingPathComponent("libMediaRemoteHelper.dylib")
        guard FileManager.default.fileExists(atPath: helper) else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", Self.perlLoader, helper]
        let pipe = Pipe()
        let commandPipe = Pipe()
        process.standardInput = commandPipe
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            DispatchQueue.main.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            pipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async { [weak self] in
                if self?.commandPipe === commandPipe { self?.commandPipe = nil }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, !stopped else { return }
                launch()
            }
        }
        do {
            try process.run()
            self.process = process
            self.commandPipe = commandPipe
            // A new helper starts by clearing any override, so pick the source again.
            if let selectedSourceID { sendToHelper("select \(selectedSourceID)") }
        } catch {
            info = nil
        }
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let payload = try? JSONDecoder().decode(Payload.self, from: line) else { continue }
            update(payload)
        }
    }

    private struct Payload: Decodable {
        var available: Bool
        var playing: Bool?
        var title: String?
        var artist: String?
        var bundleID: String?
        var duration: Double?
        var elapsed: Double?
        var rate: Double?
        var timestamp: Double?
        var artworkChanged: Bool?
        var artwork: String?
        var clients: [Client]?
        var selected: String?
        var selectable: Bool?

        struct Client: Decodable {
            var id: String
            var parent: String?
            var name: String
            var playing: Bool
            var title: String?
        }
    }

    private func update(_ payload: Payload) {
        if payload.artworkChanged == true {
            let newArtwork = payload.artwork
                .flatMap { Data(base64Encoded: $0) }
                .flatMap(Self.scaledJPEG)
            if newArtwork != artwork {
                artwork = newArtwork
                onArtworkChange?()
            }
        }

        var newInfo: Info?
        if payload.available, let playing = payload.playing, payload.bundleID != nil || payload.title != nil {
            newInfo = Info(
                isPlaying: playing,
                title: payload.title.flatMap { $0.isEmpty ? nil : $0 },
                artist: payload.artist.flatMap { $0.isEmpty ? nil : $0 },
                appName: payload.bundleID.flatMap(Self.appName),
                duration: payload.duration.flatMap { $0 > 0 ? $0 : nil },
                elapsed: payload.elapsed,
                rate: playing ? (payload.rate ?? 1) : 0,
                timestamp: payload.timestamp.map(Date.init(timeIntervalSince1970:))
            )
        }
        let newSources = (payload.clients ?? [])
            .map { Source(id: $0.id, parentID: $0.parent, name: $0.name, isPlaying: $0.playing,
                          title: $0.title.flatMap { $0.isEmpty ? nil : $0 }) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let newNowPlayingID = payload.available ? payload.bundleID : nil

        guard newInfo != info || newSources != sources || newNowPlayingID != nowPlayingID
            || payload.selected != selectedSourceID || (payload.selectable == true) != canSelectSource
        else { return }
        info = newInfo
        sources = newSources
        nowPlayingID = newNowPlayingID
        selectedSourceID = payload.selected
        canSelectSource = payload.selectable == true
        onChange?()
    }

    private static func appName(bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    private static func scaledJPEG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxArtworkPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
