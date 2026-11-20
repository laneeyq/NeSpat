import SwiftUI
import NeSpatNative

@MainActor struct BatteryDetailsPanel: NSViewRepresentable {
    let details: NeSpatBatteryDetails

    func makeNSView(context: Context) -> NSGridView {
        guard let address = nespat_battery_grid_create(details) else {
            preconditionFailure("Battery grid requires the main thread")
        }
        return Unmanaged<NSGridView>.fromOpaque(address).takeRetainedValue()
    }

    func updateNSView(_ view: NSGridView, context: Context) {
        nespat_battery_grid_update(Unmanaged.passUnretained(view).toOpaque(), details)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSGridView, context: Context) -> CGSize? {
        nsView.fittingSize
    }
}
