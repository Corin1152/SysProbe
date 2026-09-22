import Foundation

/// Reads battery and power-adapter state through IOKit.
///
/// IOKit is a private framework on iOS, so every symbol is resolved with `dlsym`
/// at runtime instead of being linked. Fine for a sideloaded build; this is the
/// reason MiniWatts can never pass App Store review.
///
/// What actually survives the iOS sandbox (verified on iOS 26):
/// - `IOPMPowerSource` registry: only `BatteryInstalled` and `ExternalConnected`.
/// - powerd `IOPSCopyPowerSourcesInfo`: percent, charging flags, low power mode.
/// - powerd `IOPSCopyExternalPowerAdapterDetails`: the full USB-PD handshake.
/// - `IOPSCopyChargeStatus`: refused (kIOReturnNotPrivileged), kept for the record.
nonisolated final class IOKitBattery {
    private typealias ServiceMatchingFn =
        @convention(c) (UnsafePointer<CChar>) -> Unmanaged<CFDictionary>?
    private typealias GetMatchingServiceFn =
        @convention(c) (mach_port_t, CFDictionary?) -> UInt32
    private typealias CreatePropertiesFn =
        @convention(c) (UInt32, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?, CFAllocator?, UInt32) -> kern_return_t
    private typealias ObjectReleaseFn = @convention(c) (UInt32) -> kern_return_t
    private typealias CopyPowerSourcesInfoFn = @convention(c) () -> Unmanaged<CFTypeRef>?
    private typealias CopyPowerSourcesListFn = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias GetPowerSourceDescriptionFn =
        @convention(c) (CFTypeRef, CFTypeRef) -> Unmanaged<CFDictionary>?
    private typealias CopyAdapterDetailsFn = @convention(c) () -> Unmanaged<CFDictionary>?
    private typealias CopyChargeStatusFn =
        @convention(c) (UnsafeMutablePointer<Unmanaged<CFTypeRef>?>) -> Int32

    private let serviceMatching: ServiceMatchingFn
    private let getMatchingService: GetMatchingServiceFn
    private let createProperties: CreatePropertiesFn
    private let objectRelease: ObjectReleaseFn
    private let copyPowerSourcesInfo: CopyPowerSourcesInfoFn?
    private let copyPowerSourcesList: CopyPowerSourcesListFn?
    private let powerSourceDescription: GetPowerSourceDescriptionFn?
    private let copyAdapterDetails: CopyAdapterDetailsFn?
    private let copyChargeStatus: CopyChargeStatusFn?

    /// Last IOReturn from `IOPSCopyChargeStatus`; 0xe00002c1 means the sandbox refused.
    private(set) var chargeStatusError: Int32 = 0

    init?() {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            dlsym(handle, name).map { unsafeBitCast($0, to: type) }
        }
        guard let matching = sym("IOServiceMatching", ServiceMatchingFn.self),
              let getService = sym("IOServiceGetMatchingService", GetMatchingServiceFn.self),
              let properties = sym("IORegistryEntryCreateCFProperties", CreatePropertiesFn.self),
              let release = sym("IOObjectRelease", ObjectReleaseFn.self)
        else { return nil }
        serviceMatching = matching
        getMatchingService = getService
        createProperties = properties
        objectRelease = release
        copyPowerSourcesInfo = sym("IOPSCopyPowerSourcesInfo", CopyPowerSourcesInfoFn.self)
        copyPowerSourcesList = sym("IOPSCopyPowerSourcesList", CopyPowerSourcesListFn.self)
        powerSourceDescription = sym("IOPSGetPowerSourceDescription", GetPowerSourceDescriptionFn.self)
        copyAdapterDetails = sym("IOPSCopyExternalPowerAdapterDetails", CopyAdapterDetailsFn.self)
        copyChargeStatus = sym("IOPSCopyChargeStatus", CopyChargeStatusFn.self)
    }

    /// Full property dictionary of the first `IOPMPowerSource` service.
    /// Complete on macOS and the simulator, filtered to two keys on a real iPhone.
    func readRegistryProperties(className: String = "IOPMPowerSource") -> [String: Any]? {
        guard let matching = serviceMatching(className) else { return nil }
        // IOServiceGetMatchingService consumes the +1 reference returned by
        // IOServiceMatching, so hand it over unretained rather than letting ARC
        // release it a second time.
        let service = getMatchingService(0 /* kIOMainPortDefault */, matching.takeUnretainedValue())
        guard service != 0 else { return nil }
        defer { _ = objectRelease(service) }

        var properties: Unmanaged<CFDictionary>?
        guard createProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() else { return nil }
        return dictionary as? [String: Any]
    }

    /// One dictionary per power source from powerd.
    func readPowerSources() -> [[String: Any]] {
        guard let copyPowerSourcesInfo, let copyPowerSourcesList, let powerSourceDescription,
              let blob = copyPowerSourcesInfo()?.takeRetainedValue(),
              let list = copyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return [] }
        return list.compactMap { powerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    /// The connected adapter's description, including the advertised USB-PD profile menu.
    func readAdapterDetails() -> [String: Any]? {
        copyAdapterDetails?()?.takeRetainedValue() as? [String: Any]
    }

    /// powerd's charge status, e.g. `chargeStatus = "Charging On Hold"`.
    /// Privileged on iOS; kept because it works on macOS and in the simulator.
    func readChargeStatus() -> [String: Any]? {
        guard let copyChargeStatus else { return nil }
        var out: Unmanaged<CFTypeRef>?
        let result = copyChargeStatus(&out)
        chargeStatusError = result
        guard result == 0, let value = out?.takeRetainedValue() else { return nil }
        return value as? [String: Any]
    }
}
