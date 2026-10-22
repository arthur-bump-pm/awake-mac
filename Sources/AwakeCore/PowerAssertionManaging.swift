import IOKit
import IOKit.pwr_mgt

public protocol PowerAssertionManaging {
    func create(type: CFString, name: CFString, id: inout IOPMAssertionID) -> IOReturn
    func release(id: IOPMAssertionID)
}

public struct LivePowerAssertionManager: PowerAssertionManaging {
    public init() {}

    public func create(type: CFString, name: CFString, id: inout IOPMAssertionID) -> IOReturn {
        IOPMAssertionCreateWithName(type, IOPMAssertionLevel(kIOPMAssertionLevelOn), name, &id)
    }

    public func release(id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}
