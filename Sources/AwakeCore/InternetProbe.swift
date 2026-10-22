import Foundation

public protocol InternetProbing: Sendable {
    func isOnline() async -> Bool
}

/// Online if either Apple's or Google's connectivity check answers as expected.
/// Captive portals and dead uplinks both fail, which is what we want.
public struct HTTPInternetProbe: InternetProbing {
    private let session: URLSession

    public init(timeout: TimeInterval = 4) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 1
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    public func isOnline() async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await check("https://captive.apple.com/hotspot-detect.html") { $0 == 200 && $1.contains("Success") } }
            group.addTask { await check("https://www.gstatic.com/generate_204") { status, _ in status == 204 } }
            for await ok in group where ok {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    private func check(_ url: String, _ isExpected: @Sendable (Int, String) -> Bool) async -> Bool {
        guard let url = URL(string: url),
              let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse else { return false }
        return isExpected(http.statusCode, String(decoding: data, as: UTF8.self))
    }
}
