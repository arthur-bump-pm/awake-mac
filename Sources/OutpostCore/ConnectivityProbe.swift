import Foundation

public enum Connectivity: Equatable, Sendable {
    case online
    /// A sign-in page is intercepting traffic; the URL is where it sent us, if it said.
    case captivePortal(URL?)
    case offline
}

public protocol ConnectivityProbing: Sendable {
    func check() async -> Connectivity
}

/// Tells a working connection from a sign-in page (cafe Wi-Fi) from no connection at all.
/// Needs an ATS exception for captive.apple.com: the check must be plain HTTP so a portal can intercept it.
public struct CaptiveAwareProbe: ConnectivityProbing {
    private let session: URLSession

    public init(timeout: TimeInterval = 4, session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout + 1
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            config.waitsForConnectivity = false
            self.session = URLSession(configuration: config)
        }
    }

    public func check() async -> Connectivity {
        if let url = URL(string: "http://captive.apple.com/hotspot-detect.html"),
           let (data, response) = await fetch(url) {
            let status = response.statusCode
            if (300..<400).contains(status) {
                let location = response.value(forHTTPHeaderField: "Location")
                // Only web pages: a hostile network must not be able to open other URL schemes.
                let portal = location.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
                return .captivePortal(["http", "https"].contains(portal?.scheme?.lowercased()) ? portal : nil)
            }
            let body = String(decoding: data, as: UTF8.self)
            if status == 200, body.contains("Success") { return .online }
            return .captivePortal(nil)
        }
        // Some networks block plain HTTP outright.
        if let url = URL(string: "https://www.gstatic.com/generate_204"),
           let (_, response) = await fetch(url), response.statusCode == 204 {
            return .online
        }
        return .offline
    }

    private func fetch(_ url: URL) async -> (Data, HTTPURLResponse)? {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await session.data(for: request, delegate: NoRedirects()),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http)
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
