import Darwin
import Foundation

/// A macOS sharing service that, when switched on, listens on known TCP ports.
public enum SharingService: String, CaseIterable, Codable, Sendable {
    case screenSharing, fileSharing, remoteLogin

    public var title: String {
        switch self {
        case .screenSharing: "Screen Sharing"
        case .fileSharing: "File Sharing"
        case .remoteLogin: "Remote Login"
        }
    }

    /// File Sharing answers on SMB (445) and, on older macOS, AFP (548).
    public var ports: [UInt16] {
        switch self {
        case .screenSharing: [5900]
        case .fileSharing: [445, 548]
        case .remoteLogin: [22]
        }
    }
}

public protocol PortConnecting: Sendable {
    /// Whether something on this Mac accepts a TCP connection on 127.0.0.1 at `port` within `timeout`.
    func canConnect(port: UInt16, timeout: TimeInterval) -> Bool
}

/// Finds sharing services that are on, without privileges: a quick TCP connect to each one's port on this Mac.
/// Only looks; it never turns anything off. Blocks for up to `timeout` per port, so call it off the main actor.
public struct SharingCheck: Sendable {
    private let connector: PortConnecting
    private let timeout: TimeInterval

    public init(connector: PortConnecting = LoopbackConnector(), timeout: TimeInterval = 0.3) {
        self.connector = connector
        self.timeout = timeout
    }

    /// The services that answered, in `SharingService.allCases` order.
    public func servicesOn() -> [SharingService] {
        SharingService.allCases.filter { service in
            service.ports.contains { connector.canConnect(port: $0, timeout: timeout) }
        }
    }
}

/// A non-blocking TCP connect to 127.0.0.1 with a timeout; the socket is closed straight away.
public struct LoopbackConnector: PortConnecting {
    public init() {}

    public func canConnect(port: UInt16, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        let result = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&poller, 1, Int32(max(timeout, 0) * 1000)) == 1 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
