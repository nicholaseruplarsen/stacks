import AppKit
import ServiceManagement
import SwiftUI

enum Module: String, CaseIterable, Identifiable {
    case apps, apm, cpu, gpu, ram, disk, sensors, net, battery
    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "Apps"
        case .apm: "APM"
        case .cpu: "CPU"
        case .gpu: "GPU"
        case .ram: "RAM"
        case .disk: "Disk"
        case .sensors: "Sensors"
        case .net: "Network"
        case .battery: "Battery"
        }
    }

    var symbol: String {
        switch self {
        case .apps: "chart.bar.xaxis"
        case .apm: "keyboard"
        case .cpu: "cpu"
        case .gpu: "square.stack.3d.up"
        case .ram: "memorychip"
        case .disk: "internaldrive"
        case .sensors: "thermometer.medium"
        case .net: "network"
        case .battery: "battery.100percent"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let store = Store()
    private var sampler: Sampler?
    private var items: [Module: NSStatusItem] = [:]
    private var lastKey: [Module: String] = [:]
    private let popover = NSPopover()
    private var shown: Module?
    private let ui = UIState()
    private var pendingRebuild = false
    private var outsideMonitor: Any?
    private var lastClose: (module: Module, at: Date)?

    /// Clicks in other apps (and on other menubar items) close the panel unless it's pinned.
    /// Clicks on Stacks's own items go through `clicked`, which toggles.
    private func startOutsideClickMonitor() {
        guard outsideMonitor == nil else { return }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self, !ui.pinned else { return }
            // Clicks on Stacks's own items can arrive here too; `clicked` handles those.
            let p = NSEvent.mouseLocation
            let onOwnItem = items.values.contains { item in
                guard let b = item.button, let w = b.window else { return false }
                return w.convertToScreen(b.convert(b.bounds, to: nil)).contains(p)
            }
            if !onOwnItem { popover.performClose(nil) }
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Closing is handled here (see `clicked` and the outside-click monitor):
        // a transient popover closes on the status item's mouse-down, and the
        // click then reopened it, so it took several clicks to dismiss.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.delegate = self
        ui.onModulesChanged = { [weak self] in
            guard let self else { return }
            // The popover is anchored to a status item; rebuilding now would close it.
            if popover.isShown { pendingRebuild = true } else { rebuildItems() }
        }
        rebuildItems()

        ui.onIntervalChanged = { [weak self] in self?.sampler?.setInterval($0) }
        let sampler = Sampler(interval: ui.interval) { [weak self] s, snap in
            DispatchQueue.main.async { self?.receive(s, snap) }
        }
        sampler.start()
        self.sampler = sampler

        // Open at login by default, once; the settings toggle can turn it off.
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }

        // STACKS_OPEN=<module> opens the panel on that tab after 20 s, for screenshots.
        if let raw = ProcessInfo.processInfo.environment["STACKS_OPEN"], let m = Module(rawValue: raw) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                guard let self, let b = items[m == .apps ? .cpu : m]?.button else { return }
                clicked(b)
                if m == .apps { ui.tab = .apps }
            }
        }
    }

    func applicationWillTerminate(_ note: Notification) { store.save() }

    private func receive(_ s: Sample, _ snap: Snapshot) {
        store.append(s, snap)
        for (m, item) in items { render(m, item, s, snap) }
    }

    // MARK: status items

    /// Items are added right-to-left, so create them in reverse display order.
    private func rebuildItems() {
        for item in items.values { NSStatusBar.system.removeStatusItem(item) }
        items = [:]
        lastKey = [:]
        for m in ui.order.reversed() where ui.enabled.contains(m) {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.autosaveName = "stacks.\(m.rawValue)"
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.identifier = NSUserInterfaceItemIdentifier(m.rawValue)
            item.button?.imagePosition = .imageOnly
            items[m] = item
            if let s = store.samples.last { render(m, item, s, store.snap) } else { placeholder(m, item) }
        }
    }

    private func placeholder(_ m: Module, _ item: NSStatusItem) {
        let img = NSImage(systemSymbolName: m.symbol, accessibilityDescription: m.title)
        img?.isTemplate = true
        item.button?.image = img
    }

    private func render(_ m: Module, _ item: NSStatusItem, _ s: Sample, _ snap: Snapshot) {
        guard let w = Self.widget(m, s, snap) else {
            if lastKey[m] == nil { placeholder(m, item); lastKey[m] = "icon" }
            return
        }
        let key = w.key
        guard lastKey[m] != key else { return }
        lastKey[m] = key
        item.button?.image = w.image()
    }

    static func widget(_ m: Module, _ s: Sample, _ snap: Snapshot) -> MenuWidget? {
        func pct(_ v: Double) -> String { String(format: "%.0f%%", max(0, v) * 100) }
        switch m {
        case .apps: return nil
        // 300 APM is pro-gamer territory: yellow from 150, orange-red at 300.
        case .apm: return .mini(label: "APM", value: String(format: "%.0f", s.apm), color: heat(s.apm / 300), fits: "999")
        case .cpu: return .mini(label: "CPU", value: pct(s.cpuUser + s.cpuSystem), color: heat(s.cpuUser + s.cpuSystem))
        case .gpu: return .mini(label: "GPU", value: pct(s.gpuUtil), color: heat(s.gpuUtil))
        // Pressure, not used %: macOS keeps RAM nearly full by design, so pressure is what
        // says whether memory is actually short. Orange at warning, red at critical.
        case .ram: return .mini(label: "RAM", value: pct(s.pressure),
                                color: s.pressureLevel >= 4 ? .systemRed : s.pressureLevel >= 2 ? .systemOrange : heat(s.pressure))
        case .disk: return .speed(top: ("W", .systemRed, Fmt.byteRateShort(s.diskWrite)), bottom: ("R", .systemBlue, Fmt.byteRateShort(s.diskRead)))
        // 60° starts warming, 80° is orange, 100° orange-red.
        case .sensors: return .mini(label: "TEMP", value: String(format: "%.0f°", snap.cpuTempAvg), color: heat((snap.cpuTempAvg - 20) / 80))
        case .net: return .speed(top: ("↑", .systemRed, Fmt.bitRateShort(s.netOut)), bottom: ("↓", .systemBlue, Fmt.bitRateShort(s.netIn)))
        case .battery: return .battery(level: snap.battery.level, plugged: snap.battery.external)
        }
    }

    /// Load color for a 0…1 value: plain below half, then faint yellow → yellow-orange at
    /// 75% → orange-red at 100%.
    static func heat(_ v: Double) -> NSColor? {
        guard v >= 0.5 else { return nil }
        let stops: [(Double, (CGFloat, CGFloat, CGFloat))] = [(0.5, (1, 0.95, 0.7)), (0.75, (1, 0.72, 0.2)), (1, (1, 0.33, 0.15))]
        let x = min(v, 1)
        let i = x < 0.75 ? 0 : 1
        let (a, ca) = stops[i], (b, cb) = stops[i + 1]
        let f = CGFloat((x - a) / (b - a))
        return NSColor(srgbRed: ca.0 + (cb.0 - ca.0) * f, green: ca.1 + (cb.1 - ca.1) * f, blue: ca.2 + (cb.2 - ca.2) * f, alpha: 1)
    }

    // MARK: popover

    @objc private func clicked(_ sender: NSStatusBarButton) {
        guard let raw = sender.identifier?.rawValue, let m = Module(rawValue: raw) else { return }
        if popover.isShown {
            if shown == m { popover.performClose(nil); return }
            // Another item: move the open panel there instead of closing and reopening,
            // which briefly stacked two translucent panels.
            shown = m
            ui.tab = m == .cpu ? .apps : m
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            return
        }
        // This click may also have closed the panel a moment ago; don't bounce it back open.
        if let c = lastClose, c.module == m, Date().timeIntervalSince(c.at) < 0.3 { return }
        startOutsideClickMonitor()
        shown = m
        // The CPU item opens the per-app view; the CPU tab is one click away in the header.
        ui.tab = m == .cpu ? .apps : m
        let host = NSHostingController(rootView: RootView(store: store, ui: ui))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }


    /// Dropping the hosting controller tears down every SwiftUI view, so nothing
    /// renders while the panel is closed. Sampling continues regardless.
    func popoverDidClose(_ notification: Notification) {
        if let m = shown { lastClose = (m, Date()) }
        popover.contentViewController = nil
        shown = nil
        if let m = outsideMonitor { NSEvent.removeMonitor(m); outsideMonitor = nil }
        if pendingRebuild {
            pendingRebuild = false
            rebuildItems()
        }
    }
}

@Observable
final class UIState {
    var tab: Module = .apps
    var pinned = false
    var enabled: Set<Module> {
        didSet {
            UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "modules")
            onModulesChanged?()
        }
    }
    /// Tab and menubar order, rearranged by dragging tabs in the panel header.
    var order: [Module] {
        didSet {
            guard order != oldValue else { return }
            UserDefaults.standard.set(order.map(\.rawValue), forKey: "order")
            onModulesChanged?()
        }
    }
    @ObservationIgnored var onModulesChanged: (() -> Void)?
    /// Seconds between samples, set from the settings slider.
    var interval: Double {
        didSet {
            guard interval != oldValue else { return }
            UserDefaults.standard.set(interval, forKey: "interval")
            onIntervalChanged?(interval)
        }
    }
    @ObservationIgnored var onIntervalChanged: ((Double) -> Void)?

    init() {
        let i = UserDefaults.standard.double(forKey: "interval")
        interval = i > 0 ? i : 2
        let savedOrder = (UserDefaults.standard.stringArray(forKey: "order") ?? []).compactMap(Module.init(rawValue:))
        // Modules added in a later version slot in before CPU, as APM did.
        let added = Module.allCases.filter { !savedOrder.contains($0) && $0 != .apps }
        var o = savedOrder
        if !savedOrder.isEmpty, !added.isEmpty, let i = o.firstIndex(of: .cpu) { o.insert(contentsOf: added, at: i) }
        order = o + Module.allCases.filter { !o.contains($0) }
        let saved = UserDefaults.standard.stringArray(forKey: "modules")
        // The Apps icon is off by default: every item opens the panel, which has an Apps
        // tab, and on notched Macs the extra width pushes the leftmost item under the notch.
        enabled = Set((saved ?? Module.allCases.filter { $0 != .apps }.map(\.rawValue)).compactMap(Module.init(rawValue:)))
            .union(savedOrder.isEmpty ? [] : added)
        // didSet doesn't run in init; save now so a module turned off later stays off.
        if !savedOrder.isEmpty, !added.isEmpty {
            UserDefaults.standard.set(order.map(\.rawValue), forKey: "order")
            UserDefaults.standard.set(enabled.map(\.rawValue), forKey: "modules")
        }
    }
}

// MARK: - Menubar drawing (layout follows Stats' mini, speed, label and battery widgets)

enum MenuWidget {
    /// `fits` is the widest value that gets full-size digits; wider ones are squeezed.
    case mini(label: String, value: String, color: NSColor? = nil, fits: String = "99%")
    case value(String)
    case speed(top: (String, NSColor, String), bottom: (String, NSColor, String))
    case battery(level: Double, plugged: Bool)

    var key: String {
        switch self {
        case let .mini(l, v, c, _): "\(l)\(v)\(c?.description ?? "")"
        case let .value(v): v
        case let .speed(t, b): "\(t.2)|\(b.2)"
        case let .battery(l, p): "\(Int(l * 100))\(p)"
        }
    }

    private static let height = NSStatusBar.system.thickness
    private static let labelFont = NSFont.systemFont(ofSize: 7, weight: .regular)
    private static let valueFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    /// Breathing room on each side of a mini item, on top of macOS's own item spacing.
    private static let miniPadding: CGFloat = 3
    private static let condensedFont = NSFont.systemFont(ofSize: 13, weight: .regular, width: .condensed)
    private static let bigFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    private static let rowFont = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
    private static let letterFont = NSFont.systemFont(ofSize: 9, weight: .regular)

    private static func size(_ s: String, _ f: NSFont) -> NSSize { (s as NSString).size(withAttributes: [.font: f]) }

    private static func draw(_ s: String, _ f: NSFont, _ c: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: f, .foregroundColor: c])
    }

    func image() -> NSImage {
        let h = Self.height
        switch self {
        case let .mini(label, value, color, fits):
            // Sized for two digits ("99%"); a rare third digit is squeezed into the same
            // width so neighbouring items never shift.
            let w = ceil(max(Self.size(label, Self.labelFont).width, Self.size(fits, Self.valueFont).width))
            let pad = Self.miniPadding
            return NSImage(size: NSSize(width: w + pad * 2, height: h), flipped: true) { _ in
                let top = (h - 21) / 2
                Self.draw(label, Self.labelFont, .labelColor, at: NSPoint(x: pad, y: top))
                var font = Self.valueFont
                if Self.size(value, font).width > w { font = Self.condensedFont }
                let vw = Self.size(value, font).width
                let ctx = NSGraphicsContext.current!.cgContext
                ctx.saveGState()
                ctx.translateBy(x: pad, y: 0)
                if vw > w { ctx.scaleBy(x: w / vw, y: 1) }
                Self.draw(value, font, color ?? .labelColor, at: NSPoint(x: 0, y: top + 6))
                ctx.restoreGState()
                return true
            }

        case let .value(v):
            let w = ceil(Self.size(v, Self.bigFont).width) + 2
            return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
                Self.draw(v, Self.bigFont, .labelColor, at: NSPoint(x: 1, y: (h - Self.size(v, Self.bigFont).height) / 2))
                return true
            }

        case let .speed(top, bottom):
            let letterW: CGFloat = 9
            // Fixed slot so the item doesn't jitter, widened if a value ever exceeds it.
            let valueW = ceil([ "999 KB/s", top.2, bottom.2].map { Self.size($0, Self.rowFont).width }.max()!)
            let w = letterW + 3 + valueW
            return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
                let rowH: CGFloat = 10
                let y0 = (h - rowH * 2) / 2 - 0.5
                for (i, row) in [top, bottom].enumerated() {
                    let y = y0 + CGFloat(i) * rowH
                    Self.draw(row.0, Self.letterFont, row.1, at: NSPoint(x: 0, y: y))
                    let vw = Self.size(row.2, Self.rowFont).width
                    Self.draw(row.2, Self.rowFont, .labelColor, at: NSPoint(x: letterW + 3 + valueW - vw, y: y - 0.5))
                }
                return true
            }

        case let .battery(level, plugged):
            let w: CGFloat = 28
            return NSImage(size: NSSize(width: w, height: h), flipped: true) { _ in
                let body = NSRect(x: 1.5, y: (h - 12) / 2, width: 22, height: 12)
                let outline = NSBezierPath(roundedRect: body, xRadius: 3, yRadius: 3)
                outline.lineWidth = 1.2
                NSColor.labelColor.setStroke()
                outline.stroke()
                let cap = NSBezierPath(roundedRect: NSRect(x: body.maxX + 1.2, y: body.midY - 2.2, width: 1.6, height: 4.4), xRadius: 0.8, yRadius: 0.8)
                NSColor.labelColor.setFill()
                cap.fill()
                let inner = body.insetBy(dx: 2, dy: 2)
                let fill = NSRect(x: inner.minX, y: inner.minY, width: inner.width * max(0.04, min(1, level)), height: inner.height)
                (level < 0.15 && !plugged ? NSColor.systemRed : NSColor.labelColor).setFill()
                NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
                if plugged, let plug = NSImage(systemSymbolName: "powerplug.fill", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 7.5, weight: .bold)) {
                                        let r = NSRect(x: body.midX - plug.size.width / 2, y: body.midY - plug.size.height / 2, width: plug.size.width, height: plug.size.height)
                    // Punch the plug out of the fill so the bar shows through, as in Stats.
                    plug.draw(in: r, from: .zero, operation: .destinationOut, fraction: 1)
                }
                return true
            }
        }
    }
}

// MARK: - Formatting

enum Fmt {
    static func byteRate(_ b: Double) -> String {
        if b < 1e6 { return String(format: "%.0f KB/s", b / 1e3) }
        if b < 1e9 { return String(format: "%.1f MB/s", b / 1e6) }
        return String(format: "%.2f GB/s", b / 1e9)
    }

    /// Menubar rates: at most three significant digits, so they fit a fixed slot.
    static func byteRateShort(_ b: Double) -> String { short(b, ["KB/s", "MB/s", "GB/s"]) }
    static func bitRateShort(_ bytes: Double) -> String { short(bytes * 8, ["Kb/s", "Mb/s", "Gb/s"]) }

    private static func short(_ v: Double, _ units: [String]) -> String {
        var x = v / 1e3
        for (i, u) in units.enumerated() {
            if x < 999.5 || i == units.count - 1 {
                return x < 9.95 && i > 0 ? String(format: "%.1f %@", x, u) : String(format: "%.0f %@", x, u)
            }
            x /= 1e3
        }
        return ""
    }

    static func bitRate(_ bytes: Double) -> String {
        let b = bytes * 8
        if b < 1e6 { return String(format: "%.0f Kb/s", b / 1e3) }
        if b < 1e9 { return String(format: "%.1f Mb/s", b / 1e6) }
        return String(format: "%.2f Gb/s", b / 1e9)
    }

    static func bytes(_ b: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(b), countStyle: .decimal)
    }

    static func gib(_ b: Double) -> String {
        let g = b / 1_073_741_824
        return g >= 1 ? String(format: "%.2f GB", g) : String(format: "%.0f MB", b / 1_048_576)
    }

    static func watts(_ w: Double) -> String {
        w >= 10 ? String(format: "%.1f W", w) : w >= 1 ? String(format: "%.2f W", w) : String(format: "%.0f mW", w * 1000)
    }

    static func wattHours(_ j: Double) -> String {
        let wh = j / 3600
        return wh >= 1 ? String(format: "%.1f Wh", wh) : String(format: "%.0f mWh", wh * 1000)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 86400 ? [.day, .hour, .minute] : [.hour, .minute]
        f.unitsStyle = .full
        return f.string(from: seconds) ?? ""
    }

    static func flag(_ cc: String) -> String {
        guard cc.count == 2 else { return "" }
        return String(String.UnicodeScalarView(cc.uppercased().unicodeScalars.compactMap { UnicodeScalar(127397 + $0.value) }))
    }
}
