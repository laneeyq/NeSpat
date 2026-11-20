import AppKit
import SwiftUI
import Testing
import NeSpatNative
@testable import NeSpat

@Suite @MainActor struct PanelLayoutTests {
    // Offscreen SwiftUI only, injected dependencies, no real NeSpat app/timers/power adapters.
    @Test func renderPanelVariantsWithoutSystemOperations() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = root.appendingPathComponent(".build/layout-v7.3")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for variant in ["normal", "long-error", "custom", "restore", "large-text"] {
            let f = Fixture(); f.sample.temperatureC = 36; f.sample.cpuPercent = 13
            f.sample.memUsedBytes = 69; f.sample.memTotalBytes = 100; f.sample.batteryPercent = 87
            f.sample.charging = true
            if variant == "restore" { f.state = .disabled }
            let model = f.model()
            if variant == "custom" { model.applyCustomMinutes("165") }
            if variant == "long-error" {
                var deps = f.dependencies
                deps.load = { throw NSError(domain: "mock", code: 1, userInfo: [NSLocalizedDescriptionKey: String(repeating: "Не удалось подтвердить состояние сна. Запись сохранена для безопасного восстановления. ", count: 5)]) }
                let long = AppModel(testTimer: false, dependencies: deps, startTimer: false)
                try render(long, name: variant, output: output)
            } else { try render(model, name: variant, output: output) }
            #expect(f.calls.isEmpty && f.displayCalls == 0)
        }
    }
    @Test func productionPanelKeepsOriginalMenuWidthAndMetricScales() throws {
        let readings = PanelReadings(poll: false)
        readings.sample.temperatureC = 32.1
        readings.sample.cpuPercent = 13
        readings.sample.memUsedBytes = 8_000_000_000
        readings.sample.memTotalBytes = 16_000_000_000
        readings.sample.batteryPercent = 80
        readings.sample.externalPowerConnected = true
        readings.helper = true; readings.watchdog = true; readings.permitted = true
        readings.power = .enabled
        let mode = AutomaticModeModel(requested: false, start: false, save: { _ in })
        let view = ExclusivePanel(mode: mode, readings: readings)
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        #expect(size.width == 300 && size.height > 220)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func findPresets(in view: NSView) -> NSSegmentedControl? {
            if let control = view as? NSSegmentedControl, control.segmentCount == 4 { return control }
            return view.subviews.lazy.compactMap { findPresets(in: $0) }.first
        }
        let presets = try #require(findPresets(in: host))
        let frame = presets.convert(presets.bounds, to: host)
        #expect(abs(frame.minX - 14) <= 2)
        #expect(abs(frame.maxX - (host.bounds.width - 14)) <= 2)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".build/production-panel.png")
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    @Test func expandedBatteryGridFitsPanelAndRefreshesMissingValues() throws {
        let readings = NeSpatBatteryDetails(cycles: 123, design: 5000, full: 4750, remaining: 2375)
        let raw = try #require(nespat_battery_grid_create(readings))
        let grid = Unmanaged<NSGridView>.fromOpaque(raw).takeRetainedValue()
        func values() -> [String?] {
            (0..<grid.numberOfRows).map {
                (grid.cell(atColumnIndex: 1, rowIndex: $0).contentView as? NSTextField)?.stringValue
            }
        }
        #expect(grid.numberOfColumns == 2 && grid.numberOfRows == 5)
        #expect(values() == ["123", "2375 мА·ч", "4750 мА·ч", "5000 мА·ч", "95%"])
        #expect(grid.fittingSize.width > 0 && grid.fittingSize.width <= 272)
        nespat_battery_grid_update(raw, .init(cycles: -1, design: -1, full: -1, remaining: -1))
        #expect(values() == Array(repeating: "—", count: 5))
    }

    @Test func panelWindowShrinksAfterTransientRowDisappears() async throws {
        let readings = PanelReadings(poll: false)
        readings.helper = true; readings.watchdog = true; readings.permitted = true
        readings.power = .enabled
        let mode = AutomaticModeModel(requested: false, start: false, save: { _ in })
        let content = NSHostingController(rootView: ExclusivePanel(mode: mode, readings: readings))
        content.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.contentViewController = content
        let anchor = NSButton(title: "NeSpat", target: nil, action: nil)
        let window = NSWindow(contentRect: NSRect(x: 40, y: 120, width: 140, height: 30),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = anchor
        window.orderBack(nil)
        popover.animates = false
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        defer { popover.close(); window.orderOut(nil) }
        func settle() async throws {
            for _ in 0..<6 {
                content.view.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(15))
            }
        }
        try await settle()
        let normal = popover.contentSize
        #expect(normal.width == 300 && normal.height > 0)
        readings.power = .disabled
        try await settle()
        #expect(popover.contentSize.height > normal.height)
        readings.power = .enabled
        try await settle()
        #expect(abs(popover.contentSize.height - normal.height) <= 1)

    }

    private func render(_ model: AppModel, name: String, output: URL) throws {
        let panel = PanelView(model: model).environment(\.dynamicTypeSize, name == "large-text" ? .accessibility3 : .medium)
        var heights: [Int] = []
        for height in [CGFloat(0), 800] {
            let renderer = ImageRenderer(content: panel.background(Color.white))
            renderer.proposedSize = ProposedViewSize(width: 300, height: height == 0 ? nil : height)
            renderer.scale = 1
            let image = try #require(renderer.cgImage)
            #expect(image.width == 300 && image.height > 0)
            heights.append(image.height)
            let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("\(name)-\(Int(height)).png"))
            print("PANEL_LAYOUT \(name) proposal=\(Int(height)) image=\(image.width)x\(image.height)")
        }
        #expect(heights[0] == heights[1], "Panel must keep its content height under a taller proposal")
        // ImageRenderer does not render NSView-backed controls fully; native harness is separate.
    }
}
