import Darwin
import Foundation

public enum ControlSocketError: LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case badResponse

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "Socket path is too long: \(path)"
        case .system(let call, let code): "\(call) failed: \(String(cString: strerror(code)))"
        case .badResponse: "Awake sent an unreadable reply."
        }
    }
}

/// Listens on a Unix socket (mode 0600, same-user peers only) and answers one request per connection.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlResponse

    private let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "Awake.control")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?

    public init(path: String = ControlPaths.socket, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    public func start() throws {
        let directory = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        unlink(path)
        listener = try SocketIO.makeSocket()
        try SocketIO.withAddress(path) { address, length in
            guard bind(listener, address, length) == 0 else { throw ControlSocketError.system("bind", errno) }
        }
        chmod(path, 0o600)
        guard listen(listener, 16) == 0 else { throw ControlSocketError.system("listen", errno) }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(fileDescriptor: listener, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAll() }
        source.resume()
        self.source = source
    }

    public func stop() {
        source?.cancel()
        source = nil
        if listener >= 0 {
            close(listener)
            listener = -1
        }
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            // Accepted sockets inherit O_NONBLOCK on macOS; requests are read with a timeout instead.
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            SocketIO.configure(client, timeout: 5)
            let handler = self.handler
            DispatchQueue.global().async {
                guard let line = SocketIO.readLine(client),
                      let request = try? JSONDecoder().decode(ControlRequest.self, from: line) else {
                    SocketIO.send(ControlResponse(ok: false, error: "Unreadable request."), to: client)
                    close(client)
                    return
                }
                Task {
                    SocketIO.send(await handler(request), to: client)
                    close(client)
                }
            }
        }
    }
}

public enum ControlClient {
    /// Sends one request to the running app. Throws if nothing is listening.
    public static func send(_ request: ControlRequest, path: String = ControlPaths.socket,
                            timeout: TimeInterval = 180) throws -> ControlResponse {
        let fd = try SocketIO.makeSocket()
        defer { close(fd) }
        SocketIO.configure(fd, timeout: timeout)
        try SocketIO.withAddress(path) { address, length in
            guard connect(fd, address, length) == 0 else { throw ControlSocketError.system("connect", errno) }
        }
        var payload = try JSONEncoder().encode(request)
        payload.append(0x0A)
        guard SocketIO.writeAll(payload, to: fd) else { throw ControlSocketError.system("write", errno) }
        guard let line = SocketIO.readLine(fd),
              let response = try? JSONDecoder().decode(ControlResponse.self, from: line) else {
            throw ControlSocketError.badResponse
        }
        return response
    }
}

enum SocketIO {
    static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocketError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func configure(_ fd: Int32, timeout: TimeInterval) {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void) throws {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { throw ControlSocketError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// Reads up to the first newline (or EOF). Caps at 1 MB.
    static func readLine(_ fd: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = read(fd, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer[0..<count])
            if let newline = data.firstIndex(of: 0x0A) {
                return data.prefix(upTo: newline)
            }
        }
        return data.isEmpty ? nil : data
    }

    static func writeAll(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    static func send(_ response: ControlResponse, to fd: Int32) {
        guard var data = try? JSONEncoder().encode(response) else { return }
        data.append(0x0A)
        _ = writeAll(data, to: fd)
    }
}
