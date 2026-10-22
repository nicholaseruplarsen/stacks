import AppKit
import SwiftUI

@main
enum Main {
    static func main() {
        // One instance only: a second copy (e.g. opened from Finder while the login
        // agent's copy runs) would duplicate every menubar item.
        let snapshot = ProcessInfo.processInfo.environment["STACKS_SNAPSHOT"] != nil
        if !snapshot, let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id).count > 1 {
            exit(0)
        }
        migrateDefaults()
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        // STACKS_SNAPSHOT=/dir renders every panel to PNGs after 30s and exits (checks the UI headlessly).
        if let dir = ProcessInfo.processInfo.environment["STACKS_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
                for m in Module.allCases {
                    let ui = UIState()
                    ui.tab = m
                    let r = ImageRenderer(content: RootView(store: delegate.store, ui: ui, snapshot: true)
                        .background(Color(white: 0.13)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(m.rawValue).png"))
                    }
                }
                let settings = ImageRenderer(content: SettingsView(store: delegate.store, ui: UIState())
                    .background(Color(white: 0.13)).environment(\.colorScheme, .dark))
                settings.scale = 2
                if let img = settings.nsImage, let tiff = img.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("settings.png"))
                }
                // What the CPU "Other" popover would list right now.
                let d = AppChartData(samples: delegate.store.samples, metric: .cpu, window: 120)
                if let last = d.others.last {
                    let entries = last.filter { $0.value > 0 }.sorted { $0.value > $1.value }
                        .map { LegendRow.Entry(name: $0.key, value: AppMetric.cpu.format($0.value), copy: "") }
                    let r = ImageRenderer(content: BreakdownList(entries: entries).background(Color(white: 0.13)).environment(\.colorScheme, .dark))
                    r.scale = 2
                    if let img = r.nsImage, let tiff = img.tiffRepresentation,
                       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                        try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("other.png"))
                    }
                }
                // Menubar strip, dark appearance, same order as the real items.
                if let s = delegate.store.samples.last {
                    let ws = Module.allCases.compactMap { AppDelegate.widget($0, s, delegate.store.snap)?.image() }
                    let gap: CGFloat = 12
                    let size = NSSize(width: ws.reduce(0) { $0 + $1.size.width + gap } + gap, height: NSStatusBar.system.thickness)
                    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                    rep.size = size
                    NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
                        NSGraphicsContext.saveGraphicsState()
                        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                        NSColor(white: 0.08, alpha: 1).setFill()
                        NSRect(origin: .zero, size: size).fill()
                        var x = gap
                        for w in ws { w.draw(at: NSPoint(x: x, y: 0), from: .zero, operation: .sourceOver, fraction: 1); x += w.size.width + gap }
                        NSGraphicsContext.restoreGraphicsState()
                    }
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("menubar.png"))
                }
                exit(0)
            }
        }
        app.run()
    }
}

/// Carries settings and running totals over from the app's earlier name, ProcGraph.
private func migrateDefaults() {
    let d = UserDefaults.standard
    guard let id = Bundle.main.bundleIdentifier, !d.bool(forKey: "migratedFromProcGraph") else { return }
    if d.persistentDomain(forName: id)?.isEmpty ?? true, let old = d.persistentDomain(forName: "local.procgraph") {
        d.setPersistentDomain(old, forName: id)
    }
    d.set(true, forKey: "migratedFromProcGraph")
}

// MARK: - Per-app chart data

enum AppMetric: String, CaseIterable, Identifiable {
    case cpu = "CPU", gpu = "GPU", mem = "Memory", disk = "Disk", net = "Network", compressed = "Compressed", energy = "Power"

    /// The charts on the Apps tab.
    static let apps: [AppMetric] = [.cpu, .gpu, .mem, .disk, .net]
    var id: String { rawValue }

    func values(_ s: Sample) -> [String: Double] {
        switch self {
        case .cpu: s.cpu
        case .gpu: s.gpu
        case .mem: s.mem.mapValues { $0 / 1_073_741_824 }
        case .disk: s.disk
        case .net: s.net
        case .compressed: s.compressed.mapValues { $0 / 1_073_741_824 }
        case .energy: s.appPower
        }
    }

    func format(_ v: Double) -> String {
        switch self {
        case .cpu: String(format: "%.0f%%", v * 100)
        case .gpu: String(format: "%.0f%%", v)
        case .mem: v >= 1 ? String(format: "%.2f GB", v) : String(format: "%.0f MB", v * 1024)
        case .disk: Fmt.byteRate(v)
        case .net: Fmt.bitRate(v)
        case .compressed: v >= 1 ? String(format: "%.2f GB", v) : String(format: "%.0f MB", v * 1024)
        case .energy: Fmt.watts(v)
        }
    }

    var unit: String {
        switch self {
        case .cpu: "cores"
        case .gpu: "% of GPU"
        case .mem: "GB"
        case .disk: "B/s"
        case .net: "B/s"
        case .compressed: "GB"
        case .energy: "W"
        }
    }

    var note: String? {
        switch self {
        case .disk: "Your own processes only; system daemons aren't visible without root."
        case .compressed: "Original size of each app's compressed pages. Refreshed every minute."
        case .energy: "CPU energy is measured per process; GPU power is split by GPU time. Display and memory aren't counted."
        default: nil
        }
    }
}

struct Point: Identifiable {
    let t: Date
    let name: String
    let v: Double
    var id: String { "\(t.timeIntervalSince1970)|\(name)" }
}

/// Buckets samples into at most `maxBuckets` averaged points over the window.
func bucketed(_ samples: [Sample], window: TimeInterval, maxBuckets: Int = 180) -> [ArraySlice<Sample>] {
    let cutoff = Date().addingTimeInterval(-window)
    let start = samples.firstIndex { $0.t >= cutoff } ?? samples.count
    let slice = samples[start...]
    guard !slice.isEmpty else { return [] }
    let size = max(1, Int((Double(slice.count) / Double(maxBuckets)).rounded(.up)))
    return stride(from: slice.startIndex, to: slice.endIndex, by: size).map { slice[$0..<min($0 + size, slice.endIndex)] }
}

struct AppChartData {
    var names: [String] = []
    var points: [Point] = []
    var times: [Date] = []
    var buckets: [[String: Double]] = []
    var temps: [Double] = []      // per bucket, when a temperature series was requested
    var others: [[String: Double]] = []  // per bucket, the apps folded into "Other"

    /// Name for the sampler's own remainder (apps outside its top 20) inside the Other breakdown.
    static let smaller = "Smaller processes"
    var peak = 0.0                // largest stacked total
    var peaks: [String: Double] = [:]  // per legend entry, highest bucket in the window

    init(samples: [Sample], metric: AppMetric, window: TimeInterval, top: Int = 5, temp: ((Sample) -> Double)? = nil) {
        let chunks = bucketed(samples, window: window)
        guard !chunks.isEmpty else { return }

        var totals: [String: Double] = [:]
        for c in chunks { for s in c { for (k, v) in metric.values(s) { totals[k, default: 0] += v } } }
        let shown = Array(totals.filter { $0.key != "Other" }.sorted { $0.value > $1.value }.map(\.key).prefix(top))
        let shownSet = Set(shown)
        names = shown + ["Other"]

        for chunk in chunks {
            var acc: [String: Double] = [:]
            var rest: [String: Double] = [:]
            for s in chunk {
                for (k, v) in metric.values(s) {
                    if shownSet.contains(k) { acc[k, default: 0] += v; continue }
                    acc["Other", default: 0] += v
                    rest[k == "Other" ? Self.smaller : k, default: 0] += v
                }
            }
            let n = Double(chunk.count)
            let avg = acc.mapValues { $0 / n }
            others.append(rest.mapValues { $0 / n })
            let t = chunk.last!.t
            times.append(t)
            buckets.append(avg)
            peak = max(peak, avg.values.reduce(0, +))
            for (k, v) in avg { peaks[k] = max(peaks[k] ?? 0, v) }
            if let temp { temps.append(chunk.reduce(0) { $0 + temp($1) } / n) }
            for name in names { points.append(Point(t: t, name: name, v: avg[name] ?? 0)) }
        }
    }
}

// MARK: - Colors

/// Categorical palette (dark-mode steps), assigned by a stable name hash with
/// probing so an app keeps its color across charts and launches.
enum Palette {
    static let slots: [Color] = [0x3987e5, 0xd95926, 0x199e70, 0xc98500, 0xd55181, 0x008300, 0x9085e9, 0xe66767].map(hex)
    static let other = Color.gray.opacity(0.55)

    // Stats' own module colors, so the panels read like Stats.
    static let red = hex(0xe66767)
    static let blue = hex(0x3987e5)
    static let cyan = hex(0x5ac8d8)
    static let purple = hex(0x7d74e8)
    static let orange = hex(0xf0a04b)

    static func hex(_ v: Int) -> Color {
        Color(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }

    static func assign(_ names: [String]) -> [String: Color] {
        var used = Set<Int>()
        var out: [String: Color] = ["Other": other]
        for name in names where name != "Other" {
            var idx = Int(fnv(name) % UInt64(slots.count))
            while used.contains(idx), used.count < slots.count { idx = (idx + 1) % slots.count }
            used.insert(idx)
            out[name] = slots[idx]
        }
        return out
    }

    private static func fnv(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }
}
