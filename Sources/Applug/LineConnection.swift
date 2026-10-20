import Foundation
import Network

/// A TCP connection carrying one JSON message per line. Everything happens on the main queue.
@MainActor
final class LineConnection {
    let connection: NWConnection
    var onReady: (() -> Void)?
    var onMessage: ((Message) -> Void)?
    /// Called once, when the connection ends for any reason.
    var onClose: (() -> Void)?
    /// The longest line accepted. Providers keep it small until `hello`.
    var maxLine = Limits.maxLine

    private var buffer = Data()
    private var queued = 0
    private var queuedBytes = 0
    private var closed = false
    /// Closing after sending an error: the socket closes itself shortly, so leave it be.
    private var closingGracefully = false

    /// Connections lingering in a graceful close right now, and the most allowed at once. A graceful
    /// close holds its socket for up to half a second so the other side can read the error; beyond this
    /// many, close hard instead, so a flood of doomed connections (a web page POSTing junk, say) can't
    /// tie up the process's file descriptors outside the connection limits.
    private static var draining = 0
    private static let maxDraining = 32

    init(_ connection: NWConnection) {
        self.connection = connection
    }

    deinit {
        // Released without closing (its owner went away): don't leave the socket open.
        if !closingGracefully { connection.cancel() }
    }

    static func loopback(port: UInt16) -> LineConnection {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!)
        return LineConnection(NWConnection(to: endpoint, using: .tcp))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch state {
                case .ready:
                    self.onReady?()
                    self.receive()
                case .failed, .cancelled:
                    self.close()
                case .waiting:
                    // Loopback "waiting" means nothing is listening; don't hang around.
                    self.close()
                default:
                    break
                }
            }
        }
        connection.start(queue: .main)
    }

    func send(_ message: Message) {
        guard !closed else { return }
        let data = message.encoded()
        // A peer that stopped reading: give up rather than pile up messages for it.
        guard queued < Limits.maxQueued, queuedBytes + data.count <= Limits.maxQueuedBytes else {
            close()
            return
        }
        queued += 1
        queuedBytes += data.count
        let size = data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                self?.queued -= 1
                self?.queuedBytes -= size
            }
        })
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
        finish()
    }

    /// Sends an `error` saying why, then closes. Nothing after this is read or handled.
    func close(sayingError message: String) {
        guard !closed else { return }
        let connection = self.connection
        // Too many already lingering: send the error best-effort and reset now, rather than holding
        // another file descriptor open for half a second.
        guard Self.draining < Self.maxDraining else {
            connection.send(content: Message.error(message).encoded(), completion: .idempotent)
            close()
            return
        }
        // Send it as the last thing on the connection, keep reading (and ignoring) whatever is still
        // arriving, and close a moment later. Closing a socket with unread data resets it, which can
        // throw away the error before the other side reads it.
        Self.draining += 1
        connection.send(content: Message.error(message).encoded(), contentContext: .finalMessage, isComplete: true, completion: .idempotent)
        Self.drain(connection)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            connection.cancel()
            MainActor.assumeIsolated { Self.draining -= 1 }
        }
        closingGracefully = true
        finish()
    }

    private nonisolated static func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, isComplete, error in
            if isComplete || error != nil { connection.cancel() } else { drain(connection) }
        }
    }

    private func finish() {
        closed = true
        buffer = Data()
        connection.stateUpdateHandler = nil
        let onClose = self.onClose
        self.onClose = nil
        onMessage = nil
        onReady = nil
        onClose?()
    }

    var isClosed: Bool { closed }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.consume(data) }
                if isComplete || error != nil {
                    self.close()
                } else if !self.closed {
                    self.receive()
                }
            }
        }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        // Walk the lines with a cursor and drop what's been read once at the end, so a chunk
        // of many short lines doesn't shift the buffer for every one.
        var start = buffer.startIndex
        while !closed, let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            start = buffer.index(after: newline)
            guard line.count <= maxLine else { return tooLong() }
            guard line.contains(where: { $0 != 0x20 && $0 != 0x0D && $0 != 0x09 }) else { continue }
            // A line that isn't a message closes the connection. Besides catching bugs early, this keeps
            // out web pages: all they can send to 127.0.0.1 is HTTP, whose first line isn't JSON.
            do {
                onMessage?(try Message.decode(Data(line)))
            } catch {
                return close(sayingError: (error as? Message.DecodeError)?.description ?? "Unreadable line")
            }
        }
        guard !closed else { return }
        buffer.removeSubrange(buffer.startIndex..<start)
        if buffer.count > maxLine { tooLong() }
    }

    private func tooLong() {
        close(sayingError: maxLine < Limits.maxLine ? "Send hello first" : "A line longer than 1 MB")
    }
}
