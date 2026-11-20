import Foundation
import Darwin
import NeSpatNative
import NeSpatPrivilegeCore

final class LocalFixedPowerInvoker: Sendable {
    init() throws {
        guard nespat_setter_ready() else { throw PrivilegeError.blocked }
    }
    static func inspectIdle() -> Bool { nespat_setter_idle() }
    func canFinalizePending() -> Bool { Self.inspectIdle() }
    func setDisabled(_ disabled: Bool) throws {
        switch nespat_set_power(disabled) {
        case 0: return
        case 1: throw PrivilegeError.blocked
        case 2: throw PrivilegeError.busy
        case 3: throw PrivilegeError.denied
        case 4: throw PrivilegeError.interference
        case 5: throw PrivilegeError.journal
        default: throw PrivilegeError.unconfirmed
        }
    }
}
