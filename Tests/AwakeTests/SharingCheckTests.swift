import Darwin
import XCTest
@testable import AwakeCore

private final class FakeConnector: PortConnecting, @unchecked Sendable {
    let open: Set<UInt16>
    private let lock = NSLock()
    private var _tried: [(UInt16, TimeInterval)] = []

    init(open: Set<UInt16>) { self.open = open }

    var tried: [(UInt16, TimeInterval)] { lock.lock(); defer { lock.unlock() }; return _tried }

    func canConnect(port: UInt16, timeout: TimeInterval) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _tried.append((port, timeout))
        return open.contains(port)
    }
}

final class SharingCheckTests: XCTestCase {
    func testReportsServicesInPanelOrder() {
        let services = SharingCheck(connector: FakeConnector(open: [22, 5900])).servicesOn()
        XCTAssertEqual(services, [.screenSharing, .remoteLogin])
        XCTAssertEqual(services.map(\.title).joined(separator: ", "), "Screen Sharing, Remote Login")
    }

    func testFileSharingOnEitherPortCountsOnce() {
        XCTAssertEqual(SharingCheck(connector: FakeConnector(open: [548])).servicesOn(), [.fileSharing])
        XCTAssertEqual(SharingCheck(connector: FakeConnector(open: [445, 548])).servicesOn(), [.fileSharing])
    }

    func testNothingListening() {
        XCTAssertEqual(SharingCheck(connector: FakeConnector(open: [])).servicesOn(), [])
    }

    func testTriesOnlyTheKnownPortsWithTheTimeout() {
        let connector = FakeConnector(open: [])
        _ = SharingCheck(connector: connector, timeout: 0.2).servicesOn()
        XCTAssertEqual(Set(connector.tried.map(\.0)), [22, 445, 548, 5900])
        XCTAssertTrue(connector.tried.allSatisfy { $0.1 == 0.2 })
    }

    func testLoopbackConnectorSeesAListenerAndItsAbsence() throws {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(0x7f00_0001).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                Darwin.bind(listener, pointer, length) == 0 && Darwin.listen(listener, 1) == 0
                    && Darwin.getsockname(listener, pointer, &length) == 0
            }
        }
        XCTAssertTrue(bound)
        let port = UInt16(bigEndian: address.sin_port)

        XCTAssertTrue(LoopbackConnector().canConnect(port: port, timeout: 1))
        Darwin.close(listener)
        XCTAssertFalse(LoopbackConnector().canConnect(port: port, timeout: 1))
    }
}
