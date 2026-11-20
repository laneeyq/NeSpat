import NeSpatNative

public enum SystemSessionObservation {
    public static func activeUID() -> UInt32? {
        let uid = nespat_active_uid()
        return uid == 0 ? nil : uid
    }
    public static func lidClosed() -> Bool? {
        switch nespat_lid_closed() {
        case 0: false
        case 1: true
        default: nil
        }
    }
}
