import Darwin
import Foundation

/// Bytes an interface has received and sent since it came up (64-bit counters, so they don't wrap in practice).
public struct InterfaceCounts: Equatable, Sendable {
    public var received: UInt64
    public var sent: UInt64

    public init(received: UInt64, sent: UInt64) {
        self.received = received
        self.sent = sent
    }
}

/// One read of the traffic counters, per interface.
public struct TrafficCounters: Equatable, Sendable {
    public var interfaces: [String: InterfaceCounts]

    public init(_ interfaces: [String: InterfaceCounts]) {
        self.interfaces = interfaces
    }

    /// The interfaces the meter counts: the physical ones macOS names `en…` (Wi-Fi, Ethernet, a USB or Bluetooth
    /// tethered phone) that have a routable address. Tunnels (`utun`, e.g. Tailscale or a VPN) are left out, since their
    /// traffic also crosses an `en` interface and would count twice; so are loopback, AirDrop (`awdl`, `llw`) and
    /// bridges. An `en` interface without an address of its own is a bridge member (Internet Sharing, Thunderbolt
    /// Bridge): what it carries is forwarded and already counted on the uplink, so it's left out too.
    public static func counts(interface name: String, addresses: [String]) -> Bool {
        name.hasPrefix("en") && addresses.contains(where: isRoutable)
    }

    /// Not link-local: IPv4 169.254/16 and IPv6 fe80::/10 exist on every link and say nothing about a real network.
    static func isRoutable(_ address: String) -> Bool {
        let lower = address.lowercased()
        if lower.contains(":") {
            return !(lower.hasPrefix("fe8") || lower.hasPrefix("fe9") || lower.hasPrefix("fea") || lower.hasPrefix("feb"))
                && lower != "::1"
        }
        return !lower.hasPrefix("169.254.") && !lower.hasPrefix("127.") && !lower.isEmpty
    }
}

/// Network traffic right now, in bits per second (what speed tests and ISPs quote).
public struct TrafficRate: Equatable, Sendable {
    public var down: Double
    public var up: Double

    public init(down: Double, up: Double) {
        self.down = down
        self.up = up
    }

    /// The rate between two reads `seconds` apart. Only interfaces present in both count, and one whose counters went
    /// backwards (it went down and came back up) is skipped, so a new or reset interface never shows as a burst. Nil
    /// when no time passed.
    public static func between(_ earlier: TrafficCounters, _ later: TrafficCounters,
                               seconds: TimeInterval) -> TrafficRate? {
        guard seconds > 0 else { return nil }
        var received: UInt64 = 0
        var sent: UInt64 = 0
        for (name, now) in later.interfaces {
            guard let before = earlier.interfaces[name],
                  now.received >= before.received, now.sent >= before.sent else { continue }
            received += now.received - before.received
            sent += now.sent - before.sent
        }
        return TrafficRate(down: Double(received) * 8 / seconds, up: Double(sent) * 8 / seconds)
    }

    /// "↓ 84 Mbps  ↑ 2.1 Mbps".
    public var text: String {
        "↓ \(Self.text(bitsPerSecond: down))  ↑ \(Self.text(bitsPerSecond: up))"
    }

    /// For VoiceOver.
    public var spokenText: String {
        "Download \(Self.text(bitsPerSecond: down)), upload \(Self.text(bitsPerSecond: up))"
    }

    /// At most three digits: "0 kbps", "640 kbps", "2.1 Mbps", "84 Mbps", "1.2 Gbps".
    public static func text(bitsPerSecond bps: Double) -> String {
        let kilo = max(0, bps) / 1_000
        if kilo.rounded() < 1_000 { return "\(Int(kilo.rounded())) kbps" }
        let mega = kilo / 1_000
        if (mega * 10).rounded() < 100 { return String(format: "%.1f Mbps", mega) }
        if mega.rounded() < 1_000 { return "\(Int(mega.rounded())) Mbps" }
        let giga = mega / 1_000
        if (giga * 10).rounded() < 100 { return String(format: "%.1f Gbps", giga) }
        return "\(Int(giga.rounded())) Gbps"
    }
}

/// Reads the live per-interface counters (`sysctl` `NET_RT_IFLIST2`, the source `netstat -ib` uses). No permission
/// needed; takes microseconds.
public enum TrafficReader {
    public static func read() -> TrafficCounters? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, u_int(mib.count), nil, &length, nil, 0) == 0, length > 0 else { return nil }
        // Room for an interface that appears between the two calls.
        length += 4_096
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, u_int(mib.count), &buffer, &length, nil, 0) == 0 else { return nil }

        let addresses = interfaceAddresses()
        var interfaces: [String: InterfaceCounts] = [:]
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2,
                   offset + MemoryLayout<if_msghdr2>.size <= length,
                   header.ifm_flags & IFF_UP != 0 {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil {
                        let interface = String(cString: name)
                        if TrafficCounters.counts(interface: interface, addresses: addresses[interface] ?? []) {
                            interfaces[interface] = InterfaceCounts(received: message.ifm_data.ifi_ibytes,
                                                                    sent: message.ifm_data.ifi_obytes)
                        }
                    }
                }
                offset += messageLength
            }
        }
        return TrafficCounters(interfaces)
    }

    /// Each interface's IPv4 and IPv6 addresses, as text (`getifaddrs`).
    static func interfaceAddresses() -> [String: [String]] {
        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let first else { return [:] }
        defer { freeifaddrs(first) }
        var result: [String: [String]] = [:]
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            result[String(cString: entry.pointee.ifa_name), default: []].append(String(cString: host))
        }
        return result
    }
}
