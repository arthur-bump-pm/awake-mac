import XCTest
@testable import AwakeCore

final class StubURLProtocol: URLProtocol {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = ""
        var fails = false
    }

    nonisolated(unsafe) static var replies: [String: Reply] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = Self.replies[url.host ?? ""], !reply.fails else {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ConnectivityProbeTests: XCTestCase {
    private func probe(_ replies: [String: StubURLProtocol.Reply]) -> CaptiveAwareProbe {
        StubURLProtocol.replies = replies
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return CaptiveAwareProbe(session: URLSession(configuration: config))
    }

    func testSuccessBodyIsOnline() async {
        let result = await probe(["captive.apple.com": .init(body: "<HTML><BODY>Success</BODY></HTML>")]).check()
        XCTAssertEqual(result, .online)
    }

    func testRedirectIsAPortalWithItsLocation() async {
        let result = await probe(["captive.apple.com": .init(status: 302, headers: ["Location": "https://login.example.com/sign-in"])]).check()
        XCTAssertEqual(result, .captivePortal(URL(string: "https://login.example.com/sign-in")))
    }

    func testOtherBodyIsAPortal() async {
        let result = await probe(["captive.apple.com": .init(body: "<html>Please log in</html>")]).check()
        XCTAssertEqual(result, .captivePortal(nil))
    }

    func testBlockedHTTPFallsBackToHTTPS204() async {
        let result = await probe(["captive.apple.com": .init(fails: true),
                                  "www.gstatic.com": .init(status: 204)]).check()
        XCTAssertEqual(result, .online)
    }

    func testBothFailingIsOffline() async {
        let result = await probe(["captive.apple.com": .init(fails: true),
                                  "www.gstatic.com": .init(fails: true)]).check()
        XCTAssertEqual(result, .offline)
    }
}
