import CoreWLAN
import Foundation

public struct WiFiState: Equatable, Sendable {
    public var isPoweredOn: Bool
    /// Needs Location access; nil without it or when not connected.
    public var ssid: String?

    public init(isPoweredOn: Bool, ssid: String?) {
        self.isPoweredOn = isPoweredOn
        self.ssid = ssid
    }
}

public enum WiFiError: LocalizedError {
    case noInterface
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case .noInterface: "This Mac has no Wi-Fi."
        case .notFound(let ssid): "\(ssid) isn't nearby."
        }
    }
}

/// Wi-Fi calls block (scans take a few seconds), so call them off the main thread.
public protocol WiFiControlling: Sendable {
    func state() -> WiFiState
    func nearbyNetworkNames() -> [String]
    func join(ssid: String, password: String?) throws
    func disconnect()
}

public final class CoreWLANWiFi: WiFiControlling, @unchecked Sendable {
    public init() {}

    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    public func state() -> WiFiState {
        WiFiState(isPoweredOn: interface?.powerOn() ?? false, ssid: interface?.ssid())
    }

    public func nearbyNetworkNames() -> [String] {
        guard let networks = try? interface?.scanForNetworks(withName: nil) else { return [] }
        return Set(networks.compactMap(\.ssid)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func join(ssid: String, password: String?) throws {
        guard let interface else { throw WiFiError.noInterface }
        let matches = try interface.scanForNetworks(withName: ssid)
        guard let strongest = matches.max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiError.notFound(ssid) }
        try interface.associate(to: strongest, password: password)
    }

    public func disconnect() {
        interface?.disassociate()
    }
}
