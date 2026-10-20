import Foundation
import Network

/// Wraps an `NWConnection` and exchanges newline-delimited JSON messages (`RemoteMessage` with the
/// iPhone, SoundControl's messages on the Mac). All callbacks are delivered on the main queue.
final class LineConnection<Message: Codable> {
    let connection: NWConnection
    var onMessage: ((Message) -> Void)?
    var onStateChange: ((NWConnection.State) -> Void)?

    private var buffer = Data()
    /// Large enough for a base64-encoded artwork JPEG.
    private static var maxFrameSize: Int { 2 * 1024 * 1024 }

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            self?.onStateChange?(state)
        }
        connection.start(queue: .main)
        receive()
    }

    func send(_ message: Message) {
        guard var data = try? JSONEncoder().encode(message) else { return }
        data.append(0x0A)
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxFrameSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                buffer.append(data)
                drainBuffer()
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            receive()
        }
    }

    private func drainBuffer() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if let message = try? JSONDecoder().decode(Message.self, from: line) {
                onMessage?(message)
            }
        }
        if buffer.count > Self.maxFrameSize {
            connection.cancel()
        }
    }
}
