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
    /// macOS has this network saved (so it can join it with its own copy of the password).
    func isSaved(_ ssid: String) -> Bool
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

    /// Without a password (going back to a network macOS knows), an open network that copies the name of one macOS
    /// knows as secured is never joined: that's how an evil twin would look.
    public func join(ssid: String, password: String?) throws {
        guard let interface else { throw WiFiError.noInterface }
        var matches = Array(try interface.scanForNetworks(withName: ssid))
        if password == nil, knownAsSecured(ssid, on: interface) {
            matches.removeAll { $0.supportsSecurity(.none) }
        }
        guard let strongest = matches.max(by: { $0.rssiValue < $1.rssiValue }) else { throw WiFiError.notFound(ssid) }
        try interface.associate(to: strongest, password: password)
    }

    /// macOS has this network saved with a password (unknown or open counts as no).
    private func knownAsSecured(_ ssid: String, on interface: CWInterface) -> Bool {
        savedProfiles(on: interface).contains { $0.ssid == ssid && $0.security != .none && $0.security != .unknown }
    }

    public func isSaved(_ ssid: String) -> Bool {
        guard let interface else { return false }
        return savedProfiles(on: interface).contains { $0.ssid == ssid }
    }

    private func savedProfiles(on interface: CWInterface) -> [CWNetworkProfile] {
        interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
    }

    public func disconnect() {
        interface?.disassociate()
    }
}
