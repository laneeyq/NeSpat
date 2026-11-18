import Foundation
import SystemConfiguration
import IOKit

public enum SystemSessionObservation {
    public static func activeUID() -> UInt32? {
        var uid: uid_t = 0, gid: gid_t = 0
        guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil, uid != 0, uid != UInt32.max else { return nil }
        return uid
    }
    public static func lidClosed() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return nil }; defer { IOObjectRelease(service) }
        guard let v = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
              CFGetTypeID(v) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue((v as! CFBoolean))
    }
}
