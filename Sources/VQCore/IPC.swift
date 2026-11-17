import Foundation

/// Newline-delimited JSON over a Unix domain socket. The menu-bar app listens; hooks and the CLI connect.
public final class SocketConnection {
    public let fd: Int32
    private var buffer = Data()
    private let lock = NSLock()
    private var closed = false

    public init(fd: Int32) {
        self.fd = fd
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// Connects to a listening socket, or nil when nobody is there.
    public static func connect(path: String) -> SocketConnection? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        guard var address = makeAddress(path) else {
            Darwin.close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else {
            Darwin.close(fd)
            return nil
        }
        return SocketConnection(fd: fd)
    }

    /// Blocks until a full line arrives. Returns nil on EOF, error or timeout.
    public func readLine(timeout: TimeInterval? = nil) -> String? {
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<newline)
                buffer.removeSubrange(buffer.startIndex...newline)
                return String(data: line, encoding: .utf8)
            }
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, Int32(min(remaining * 1000, 60_000)))
                if ready == 0 { continue }
                if ready < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
            }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
            } else if count < 0, errno == EINTR {
                continue
            } else {
                return nil
            }
        }
    }

    @discardableResult
    public func writeLine(_ line: String) -> Bool {
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
    }

    static func makeAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
            raw[bytes.count] = 0
        }
        return address
    }
}

public final class SocketServer {
    public enum ServerError: Error {
        case alreadyRunning
        case bindFailed(Int32)
        case pathTooLong
    }

    private let path: String
    private var listenFD: Int32 = -1
    private let handler: (SocketConnection) -> Void

    /// `handler` runs on a dedicated thread per connection and owns the connection.
    public init(path: String, handler: @escaping (SocketConnection) -> Void) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        // A live listener means another instance already serves this socket.
        if let existing = SocketConnection.connect(path: path) {
            existing.close()
            throw ServerError.alreadyRunning
        }
        unlink(path)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.bindFailed(errno) }
        guard var address = SocketConnection.makeAddress(path) else {
            Darwin.close(fd)
            throw ServerError.pathTooLong
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw ServerError.bindFailed(code)
        }
        chmod(path, 0o600)
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "vq.accept"
        thread.start()
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            let connection = SocketConnection(fd: client)
            let worker = Thread { [handler] in handler(connection) }
            worker.name = "vq.connection"
            worker.start()
        }
    }

    public func stop() {
        guard listenFD >= 0 else { return }
        Darwin.close(listenFD)
        listenFD = -1
        unlink(path)
    }
}

public enum IPCClient {
    /// Sends one request and waits for the single-line reply.
    public static func send(_ request: IPCRequest, path: String = VQ.socketPath, timeout: TimeInterval? = nil) -> Data? {
        guard let connection = SocketConnection.connect(path: path) else { return nil }
        defer { connection.close() }
        guard connection.writeLine(VQ.encodeLine(request)), let line = connection.readLine(timeout: timeout) else { return nil }
        return line.data(using: .utf8)
    }

    public static func ask(_ request: AskRequest, path: String = VQ.socketPath, timeout: TimeInterval? = nil) -> AskResponse? {
        guard let data = send(IPCRequest(cmd: "ask", request: request), path: path, timeout: timeout) else { return nil }
        return try? JSONDecoder().decode(AskResponse.self, from: data)
    }

    public static func status(path: String = VQ.socketPath) -> StatusReport? {
        guard let data = send(IPCRequest(cmd: "status"), path: path, timeout: 3) else { return nil }
        return try? JSONDecoder().decode(StatusReport.self, from: data)
    }

    public static func isAppRunning(path: String = VQ.socketPath) -> Bool {
        guard let connection = SocketConnection.connect(path: path) else { return false }
        connection.close()
        return true
    }
}
