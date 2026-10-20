import AppKit
import Charts
import SwiftUI
import ServiceManagement

// MARK: - Root

struct RootView: View {
    let store: Store
    @Bindable var ui: UIState
    var snapshot = false
    @AppStorage("window") private var window: Double = 600
    @State private var dragging: Module?
    @State private var showSettings = false
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 8)
            Divider().opacity(0.4)
            content.padding(12)
        }
        .frame(width: ui.tab == .apps ? 480 : 360)
        .fixedSize(horizontal: false, vertical: true)
        // Darken the translucent backing while keeping it see-through. 37% over our
        // always-active backing measures about 0.098 brightness, the shade chosen.
        .background(colorScheme == .dark ? Color.black.opacity(0.37) : .clear)
        // Our own backing, always drawn in the active style: macOS's popover backing
        // turns lighter whenever it doesn't let this app activate.
        .background(ActiveMaterial())
    }

    private var header: some View {
        HStack(spacing: 2) {
            ForEach(ui.order) { m in
                Button { ui.tab = m } label: {
                    Image(systemName: m.symbol)
                        .font(.system(size: 13))
                        // Nine tabs plus pin and gear must fit the 360 pt panel, or the
                        // header overflows and the whole panel is clipped on both sides.
                        .frame(width: 28, height: 24)
                        .background(ui.tab == m ? Color.accentColor.opacity(0.85) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(ui.tab == m ? .white : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(m.title) — drag to reorder")
                .opacity(dragging == m ? 0.4 : 1)
                .onDrag {
                    dragging = m
                    return NSItemProvider(object: m.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: TabDrop(target: m, ui: ui, dragging: $dragging))
            }
            Spacer(minLength: 4)
            Button { ui.pinned.toggle() } label: {
                Image(systemName: ui.pinned ? "pin.fill" : "pin")
                    .rotationEffect(.degrees(ui.pinned ? 0 : 45))
                    .foregroundStyle(ui.pinned ? Color.accentColor : .secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .animation(.spring(duration: 0.25, bounce: 0.3), value: ui.pinned)
            }
            .buttonStyle(.plain)
            .help(ui.pinned ? "Pinned: stays open when you click elsewhere" : "Pin open")
            Button { showSettings.toggle() } label: {
                Image(systemName: "gearshape").foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings")
            .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                SettingsView(store: store, ui: ui)
            }
        }
    }

    @ViewBuilder private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ui.tab.title).font(.title3.weight(.semibold))
                Spacer()
                WindowPicker(window: $window)
            }
            if store.samples.count < 2 {
                Text("Collecting…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 160)
            } else {
                switch ui.tab {
                case .apps: AppsPanel(store: store, window: window)
                case .apm: APMPanel(store: store, window: window)
                case .cpu: CPUPanel(store: store, window: window)
                case .gpu: GPUPanel(store: store, window: window)
                case .ram: RAMPanel(store: store, window: window)
                case .disk: DiskPanel(store: store, window: window)
                case .sensors: SensorsPanel(store: store, window: window)
                case .net: NetPanel(store: store, window: window)
                case .battery: BatteryPanel(store: store, window: window)
                }
            }
        }
    }
}

/// Reorders tabs live while dragging; the order also drives the menubar.
private struct TabDrop: DropDelegate {
    let target: Module
    let ui: UIState
    @Binding var dragging: Module?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = ui.order.firstIndex(of: d), let to = ui.order.firstIndex(of: target) else { return }
        withAnimation(.snappy(duration: 0.2)) {
            ui.order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Clicking a chart copies its values at the hovered moment, with a brief "Copied" badge.
struct CopyOnClick: ViewModifier {
    let text: () -> String
    @State private var copied = false

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                let t = text()
                guard !t.isEmpty else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
                withAnimation(.spring(duration: 0.25, bounce: 0.3)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    withAnimation(.easeOut(duration: 0.3)) { copied = false }
                }
            }
            .overlay {
                if copied {
                    Label("Copied this moment", systemImage: "checkmark")
                        .font(.caption.weight(.semibold)).foregroundStyle(.green)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
    }
}

/// One square per 10-second ping; hovering a square shows its time and result.
struct ConnectivityRow: View {
    let pings: [NetInfo.Ping]
    @State private var hovered: Int?

    var body: some View {
        let pad = max(0, 45 - pings.count)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 2) {
                ForEach(0..<45, id: \.self) { i in
                    let p = i >= pad ? pings[i - pad] : nil
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(p == nil ? Color.primary.opacity(0.08) : p!.ms != nil ? Color.green : Color.red)
                        .frame(height: hovered == i ? 11 : 8)
                        .frame(height: 11)
                        .contentShape(Rectangle())
                        .onHover { h in
                            withAnimation(.easeOut(duration: 0.1)) { hovered = h ? i : (hovered == i ? nil : hovered) }
                        }
                }
            }
            Text(caption(pad)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func caption(_ pad: Int) -> String {
        if let i = hovered {
            guard i >= pad else { return "No check yet" }
            let p = pings[i - pad]
            let t = p.t.formatted(date: .omitted, time: .standard)
            return p.ms.map { "\(t) · reply in \(String(format: "%.0f", $0)) ms" } ?? "\(t) · no reply from 1.1.1.1 within 2 s"
        }
        let failed = pings.filter { $0.ms == nil }.count
        return "Ping to 1.1.1.1 every 10 s · \(failed) of \(pings.count) failed · hover a square for details"
    }
}

struct WindowPicker: View {
    @Binding var window: Double
    private let options: [(String, Double)] = [("2m", 120), ("10m", 600), ("30m", 1800), ("1h", 3600)]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.1) { label, v in
                Button { window = v } label: {
                    Text(label).font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(window == v ? Color.primary.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(window == v ? .primary : .secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A frosted backing that looks the same whether or not the app is active.
struct ActiveMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - Building blocks

struct SectionTitle: View {
    let title: String
    init(_ t: String) { title = t }

    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(.quaternary).frame(height: 1)
            Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(.quaternary).frame(height: 1)
        }
        .padding(.top, 2)
    }
}

/// Two columns of rows, so detail lists stay short.
struct Pairs<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible())], alignment: .leading, spacing: 5) { content }
    }
}

struct BadgeRow: View {
    let label: String
    let ok: Bool
    var on = "UP", off = "DOWN"

    var body: some View {
        HStack { Text(label).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1); Spacer(minLength: 4); Badge(ok: ok, on: on, off: off) }
    }
}

struct Row: View {
    let label: String
    let value: String
    var dot: Color?
    var valueColor: Color?

    var body: some View {
        HStack(spacing: 8) {
            if let dot { RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 9, height: 9) }
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).monospacedDigit().foregroundStyle(valueColor ?? .primary).lineLimit(1)
        }
        .font(.system(size: 12))
    }
}

struct Badge: View {
    let ok: Bool
    var on = "UP", off = "DOWN"

    var body: some View {
        Text(ok ? on : off).font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 1)
            .background((ok ? Color.green : Color.red).opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }
}

struct BigStats: View {
    let items: [(value: String, label: String, color: Color?)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(items.indices, id: \.self) { i in
                VStack(spacing: 2) {
                    Text(items[i].value).font(.system(size: 21, weight: .regular)).monospacedDigit()
                    HStack(spacing: 5) {
                        if let c = items[i].color { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 9, height: 9) }
                        Text(items[i].label).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

struct Bar: View {
    let fraction: Double
    var color: Color = .green

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: g.size.width * max(0, min(1, fraction)))
            }
        }
        .frame(height: 10)
    }
}

// MARK: - Time series chart (system metrics)

struct Series {
    let name: String
    let color: Color
    let value: (Sample) -> Double
}

struct TimeChart: View {
    let series: [Series]
    let samples: [Sample]
    let window: TimeInterval
    var stacked = true
    /// Plot the second series below zero (download up, upload down), as Stats does.
    var mirror = false
    var height: CGFloat = 80
    var yDomain: ClosedRange<Double>?
    let format: (Double) -> String
    @State private var hover: Date?

    var body: some View {
        let chunks = bucketed(samples, window: window)
        let times = chunks.map { $0.last!.t }
        let values: [[Double]] = chunks.map { c in series.map { s in c.reduce(0) { $0 + s.value($1) } / Double(c.count) } }
        let points: [Point] = zip(times, values).flatMap { t, vs in
            series.indices.map { i in Point(t: t, name: series[i].name, v: mirror && i == 1 ? -vs[i] : vs[i]) }
        }
        let idx = selected(times)

        VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(points) { p in
                    if stacked || mirror {
                        AreaMark(x: .value("Time", p.t), y: .value("Value", p.v), stacking: mirror ? .unstacked : .standard)
                            .foregroundStyle(by: .value("Series", p.name))
                            .interpolationMethod(.monotone)
                    } else {
                        LineMark(x: .value("Time", p.t), y: .value("Value", p.v))
                            .foregroundStyle(by: .value("Series", p.name))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                if hover != nil, let i = idx {
                    RuleMark(x: .value("Time", times[i])).foregroundStyle(.primary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
            .chartLegend(.hidden)
            .chartXSelection(value: $hover)
            .modifier(CopyOnClick { timeChartText(times, values, idx) })
            .chartXAxis { timeAxis(window) }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let d = v.as(Double.self) { Text(format(abs(d))) } }
                }
            }
            .modifier(YDomain(domain: yDomain))
            .frame(height: height)
            .overlay(alignment: .topTrailing) {
                if hover != nil, let i = idx {
                    Text(times[i], format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 14) {
                ForEach(series.indices, id: \.self) { i in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(series[i].color).frame(width: 9, height: 9)
                        Text(series[i].name).foregroundStyle(.secondary)
                        Text(idx.map { format(values[$0][i]) } ?? "–").monospacedDigit()
                    }
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }

    /// "System 22% · User 24% at 16:32:18", one series per line.
    private func timeChartText(_ times: [Date], _ values: [[Double]], _ idx: Int?) -> String {
        guard let i = idx else { return "" }
        let t = times[i].formatted(date: .omitted, time: .standard)
        return (["At \(t)"] + series.indices.map { "\(series[$0].name): \(format(values[i][$0]))" }).joined(separator: "\n")
    }

    private func selected(_ times: [Date]) -> Int? {
        guard !times.isEmpty else { return nil }
        guard let h = hover else { return times.count - 1 }
        return times.indices.min { abs(times[$0].timeIntervalSince(h)) < abs(times[$1].timeIntervalSince(h)) }
    }
}

private struct YDomain: ViewModifier {
    let domain: ClosedRange<Double>?
    func body(content: Content) -> some View {
        if let domain { content.chartYScale(domain: domain) } else { content }
    }
}

func timeAxis(_ window: TimeInterval) -> some AxisContent {
    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
        AxisGridLine().foregroundStyle(.quaternary)
        // Wall-clock time on this Mac; seconds only matter in the short window.
        AxisValueLabel(format: window <= 300 ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
    }
}

// MARK: - Per-app stacked chart

struct AppChart: View {
    let metric: AppMetric
    let store: Store
    let window: TimeInterval
    var title: String?
    var height: CGFloat = 80
    /// Overlays this temperature as a line on its own fixed °C scale (right axis).
    var temp: ((Sample) -> Double)?
    /// Fixed top of the value axis (e.g. installed RAM) instead of fitting the data.
    var fixedTop: Double?
    var legendColumns = 2
    var legendCount = 5
    @State private var hover: Date?

    /// The temperature scale spans the full chart height, independent of the stack.
    private static let tempRange = 20.0...100.0

    var body: some View {
        let data = AppChartData(samples: store.samples, metric: metric, window: window, top: legendCount, temp: temp)
        let colors = Palette.assign(data.names)
        let idx = selectedIndex(data)
        let values = idx.map { data.buckets[$0] } ?? [:]
        let total = values.values.reduce(0, +)
        let top = fixedTop ?? niceCeil(data.peak)
        let roundAxis = temp != nil || fixedTop != nil
        let lo = Self.tempRange.lowerBound, span = Self.tempRange.upperBound - lo
        let toY = { (c: Double) in (min(max(c, lo), Self.tempRange.upperBound) - lo) / span * top }

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title ?? metric.rawValue).font(.headline)
                Text(metric.format(total)).font(.headline.monospacedDigit()).foregroundStyle(.secondary)
                if temp != nil, let i = idx, i < data.temps.count {
                    HStack(spacing: 4) {
                        Capsule().fill(.primary).frame(width: 10, height: 2)
                        Text(String(format: "%.0f°C", data.temps[i])).monospacedDigit()
                    }
                    .font(.headline).foregroundStyle(.secondary)
                }
                Spacer()
                if hover != nil, let i = idx {
                    Text(data.times[i], format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }

            Chart {
                ForEach(data.points) { p in
                    AreaMark(x: .value("Time", p.t), y: .value(metric.unit, p.v), stacking: .standard)
                        .foregroundStyle(by: .value("App", p.name))
                        .interpolationMethod(.monotone)
                }
                if temp != nil {
                    ForEach(Array(zip(data.times, data.temps)), id: \.0) { t, c in
                        LineMark(x: .value("Time", t), y: .value(metric.unit, toY(c)), series: .value("Series", "Temperature"))
                            .foregroundStyle(Color.primary)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }
                }
                if hover != nil, let i = idx {
                    RuleMark(x: .value("Time", data.times[i])).foregroundStyle(.primary.opacity(0.5)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartForegroundStyleScale(domain: data.names, range: data.names.map { colors[$0]! })
            .chartLegend(.hidden)
            .chartXSelection(value: $hover)
            .modifier(CopyOnClick { appChartText(data, values, idx) })
            .chartXAxis { timeAxis(window) }
            .chartYAxis {
                if roundAxis {
                    AxisMarks(position: .leading, values: [0, top / 2, top]) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel { if let d = v.as(Double.self) { Text(d.formatted(.number.precision(.fractionLength(0...1)))) } }
                    }
                    if temp != nil {
                        AxisMarks(position: .trailing, values: [0, top / 2, top]) { v in
                            AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: "%.0f°", lo + d / top * span)) } }
                        }
                    }
                } else {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(metric == .disk ? Fmt.byteRate(d) : metric == .net ? Fmt.bitRate(d) : d.formatted())
                            }
                        }
                    }
                }
            }
            .modifier(YDomain(domain: roundAxis ? 0...top : nil))
            .frame(height: height)

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: legendColumns),
                      alignment: .leading, spacing: 2) {
                ForEach(data.names, id: \.self) { name in
                    let v = values[name] ?? 0, pk = data.peaks[name] ?? 0
                    // Idle now but busy earlier in the window: say so instead of a bare zero.
                    let idle = name != "Other" && v < pk * 0.05 || name != "Other" && pk == 0
                    let showPeak = idle && metric.format(pk) != metric.format(0)
                    LegendRow(name: name, color: colors[name]!,
                              value: showPeak ? "peak \(metric.format(pk))" : metric.format(v),
                              dimmed: idle,
                              breakdown: name == "Other" ? otherBreakdown(data, idx) : nil) {
                        let at = idx.map { data.times[$0] } ?? Date()
                        let time = at.formatted(date: .omitted, time: .standard)
                        return "\(name): \(metric.format(values[name] ?? 0)) \(metric.rawValue.lowercased()) at \(time)"
                    }
                }
            }
            if let note = metric.note {
                Text(note).font(.caption2).foregroundStyle(.tertiary)
            }
        }
    }

    /// Everything the chart shows at the selected time: total, temperature, every app, and the apps inside Other.
    private func appChartText(_ data: AppChartData, _ values: [String: Double], _ idx: Int?) -> String {
        guard let i = idx else { return "" }
        let t = data.times[i].formatted(date: .omitted, time: .standard)
        var head = "\(title ?? metric.rawValue) at \(t): \(metric.format(values.values.reduce(0, +))) total"
        if temp != nil, i < data.temps.count { head += String(format: ", %.0f°C", data.temps[i]) }
        var out = [head]
        for (k, v) in values.filter({ $0.key != "Other" }).sorted(by: { $0.value > $1.value }) {
            out.append("\(k): \(metric.format(v))")
        }
        if let o = values["Other"] {
            out.append("Other: \(metric.format(o))")
            for e in otherBreakdown(data, idx) { out.append("  \(e.name): \(e.value)") }
        }
        return out.joined(separator: "\n")
    }

    /// The apps inside "Other" at the selected time, largest first, in the chart's own units.
    private func otherBreakdown(_ data: AppChartData, _ idx: Int?) -> [LegendRow.Entry] {
        guard let i = idx, i < data.others.count else { return [] }
        let at = data.times[i].formatted(date: .omitted, time: .standard)
        return data.others[i]
            .filter { $0.value > 0 }
            .sorted { $0.key == AppChartData.smaller ? false : $1.key == AppChartData.smaller ? true : $0.value > $1.value }
            .map { k, v in
                LegendRow.Entry(name: k, value: metric.format(v),
                                copy: "\(k): \(metric.format(v)) \(metric.rawValue.lowercased()) at \(at)")
            }
    }

    /// Smallest 1/2/4/6/8 × 10ⁿ at or above `v`, so the top and its half are round numbers.
    private func niceCeil(_ v: Double) -> Double {
        guard v > 0 else { return 1 }
        let p = pow(10, floor(log10(v)))
        return [1, 2, 4, 6, 8, 10].map { $0 * p }.first { $0 >= v } ?? 10 * p
    }

    private func selectedIndex(_ data: AppChartData) -> Int? {
        guard !data.times.isEmpty else { return nil }
        guard let h = hover else { return data.times.count - 1 }
        return data.times.indices.min { abs(data.times[$0].timeIntervalSince(h)) < abs(data.times[$1].timeIntervalSince(h)) }
    }
}

/// A legend entry that copies "name: value metric at time" when clicked, with a
/// brief highlight and a "Copied" confirmation in place of the value.
struct LegendRow: View {
    struct Entry: Identifiable {
        let name: String, value: String, copy: String
        var id: String { name }
    }

    let name: String
    let color: Color
    let value: String
    var dimmed = false
    /// When set (the "Other" row), hovering shows these apps in a popover.
    var breakdown: [Entry]?
    let copyText: () -> String
    @State private var hovering = false
    @State private var copied = false
    @State private var showBreakdown = false
    @State private var overPopover = false

    var body: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 9, height: 9)
            Text(name).lineLimit(1).truncationMode(.tail).opacity(dimmed ? 0.45 : 1)
            if breakdown != nil {
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 4)
            Text(value).monospacedDigit().foregroundStyle(dimmed ? .tertiary : .secondary).opacity(copied ? 0 : 1)
                .layoutPriority(1)
                .overlay(alignment: .trailing) {
                    // Overlay so the hidden confirmation takes no layout width.
                    Label("Copied", systemImage: "checkmark").foregroundStyle(.green)
                        .fixedSize()
                        .opacity(copied ? 1 : 0).offset(y: copied ? 0 : 4)
                }
        }
        .font(.caption)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(copied ? color.opacity(0.35) : hovering ? Color.primary.opacity(0.08) : .clear))
        .scaleEffect(copied ? 0.97 : 1)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .onHover { h in
            hovering = h
            guard breakdown != nil else { return }
            if h { showBreakdown = true } else { closeSoon() }
        }
        .help(breakdown == nil ? "\(name) — click to copy" : "")
        .onTapGesture { copy(copyText()) }
        .popover(isPresented: $showBreakdown, arrowEdge: .trailing) {
            BreakdownList(entries: breakdown ?? [])
                .onHover { h in overPopover = h; if !h { closeSoon() } }
        }
    }

    /// Lets the pointer travel from the row into the popover without it closing.
    private func closeSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if !hovering && !overPopover { showBreakdown = false }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation(.spring(duration: 0.25, bounce: 0.3)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeOut(duration: 0.3)) { copied = false }
        }
    }
}

/// The apps folded into "Other", each clickable to copy like a legend row.
struct BreakdownList: View {
    let entries: [LegendRow.Entry]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Inside Other").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.bottom, 2)
            if entries.isEmpty {
                Text("Nothing at this moment").font(.caption).foregroundStyle(.tertiary)
            }
            ForEach(entries) { e in
                LegendRow(name: e.name, color: .gray.opacity(0.55), value: e.value) { e.copy }
            }
        }
        .padding(10)
        .frame(width: 260)
    }
}

// MARK: - Panels

private func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
private func temp(_ v: Double) -> String { v > 0 ? String(format: "%.0f°C", v) : "–" }
private func watts(_ v: Double) -> String { String(format: "%.2f W", v) }

struct AppsPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(AppMetric.apps) { m in
                AppChart(metric: m, store: store, window: window, height: 56,
                         temp: m == .cpu ? { $0.cpuTemp } : m == .gpu ? { $0.gpuTemp } : nil,
                         fixedTop: m == .mem ? RAMReader.total / 1_073_741_824 : nil, legendColumns: 3,
                         legendCount: m == .cpu || m == .mem ? 8 : 5)
            }
        }
    }
}

struct CPUPanel: View {
    let store: Store
    let window: TimeInterval
    private let eCores = sysctlInt("hw.perflevel1.logicalcpu")

    var body: some View {
        let s = store.snap
        let freqAll = s.freqE > 0 && s.freqP > 0 ? (s.freqE + s.freqP) / 2 : max(s.freqE, s.freqP)
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (pct(s.cpu.user + s.cpu.system), "Usage", nil),
                (temp(s.cpuTempAvg), "Temperature", nil),
                (String(format: "%.2f GHz", freqAll / 1000), "Frequency", nil),
            ])
            TimeChart(series: [
                Series(name: "System", color: Palette.red) { $0.cpuSystem },
                Series(name: "User", color: Palette.blue) { $0.cpuUser },
            ], samples: store.samples, window: window, yDomain: 0...1, format: pct)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(s.cpu.perCore.indices, id: \.self) { i in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 3).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 3).fill(i < eCores ? Palette.cyan : Palette.purple)
                            .frame(height: 32 * s.cpu.perCore[i])
                    }
                    .frame(height: 32)
                }
            }
            SectionTitle("Details")
            Pairs {
                Row(label: "System", value: pct(s.cpu.system), dot: Palette.red)
                Row(label: "User", value: pct(s.cpu.user), dot: Palette.blue)
                Row(label: "E-cores", value: pct(s.cpu.eUsage), dot: Palette.cyan)
                Row(label: "P-cores", value: pct(s.cpu.pUsage), dot: Palette.purple)
                Row(label: "E freq", value: String(format: "%.0f MHz", s.freqE))
                Row(label: "P freq", value: String(format: "%.0f MHz", s.freqP))
                Row(label: "Idle", value: pct(max(0, 1 - s.cpu.user - s.cpu.system)))
                Row(label: "Power", value: watts(s.powerCPU))
            }
            Row(label: "Load average", value: s.loadAvg.map { String(format: "%.2f", $0) }.joined(separator: "  "))
            Row(label: "Uptime", value: Fmt.duration(s.uptime))
            SectionTitle("By app")
            AppChart(metric: .cpu, store: store, window: window, title: "CPU", height: 64)
        }
    }
}

struct GPUPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let s = store.snap
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (pct(s.gpuUtil), "Utilization", nil),
                (temp(s.gpuTemp), "Temperature", nil),
                (String(format: "%.0f MHz", s.freqGPU), "Frequency", nil),
            ])
            TimeChart(series: [Series(name: "Utilization", color: Palette.blue) { $0.gpuUtil }],
                      samples: store.samples, window: window, yDomain: 0...1, format: pct)
            SectionTitle("Details")
            Pairs {
                Row(label: "Model", value: s.gpuModel)
                Row(label: "Cores", value: "\(s.gpuCores)")
                Row(label: "Renderer", value: pct(s.gpuRenderer))
                Row(label: "Tiler", value: pct(s.gpuTiler))
                Row(label: "Power", value: watts(s.powerGPU))
                Row(label: "ANE power", value: watts(s.powerANE))
            }
            SectionTitle("By app")
            AppChart(metric: .gpu, store: store, window: window, title: "GPU", height: 64)
        }
    }
}

struct RAMPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let r = store.snap.ram
        let pressure = r.pressure >= 4 ? "Critical" : r.pressure >= 2 ? "Warning" : "Normal"
        let pressureColor: Color = r.pressure >= 4 ? Palette.red : r.pressure >= 2 ? Palette.orange : .green
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (pct(r.total > 0 ? r.used / r.total : 0), "Used", nil),
                (Fmt.gib(r.used), "of \(Fmt.gib(r.total))", nil),
                (pressure, "Pressure", pressureColor),
            ])
            TimeChart(series: [
                Series(name: "App", color: Palette.blue) { $0.ramApp },
                Series(name: "Wired", color: Palette.orange) { $0.ramWired },
                Series(name: "Compressed", color: Palette.red) { $0.ramCompressed },
            ], samples: store.samples, window: window, yDomain: 0...r.total, format: Fmt.gib)
            SectionTitle("Pressure")
            TimeChart(series: [Series(name: "Pressure", color: pressureColor) { $0.pressure }],
                      samples: store.samples, window: window, height: 44, yDomain: 0...1, format: pct)
            SectionTitle("Details")
            Pairs {
                Row(label: "App", value: Fmt.gib(r.app), dot: Palette.blue)
                Row(label: "Wired", value: Fmt.gib(r.wired), dot: Palette.orange)
                Row(label: "Compressed", value: Fmt.gib(r.compressed), dot: Palette.red)
                Row(label: "Free", value: Fmt.gib(r.free), dot: .gray)
                Row(label: "Swap", value: r.swapUsed > 0 ? Fmt.gib(r.swapUsed) : "Zero KB")
                Row(label: "Power", value: watts(store.snap.powerDRAM))
            }
            SectionTitle("By app")
            AppChart(metric: .mem, store: store, window: window, title: "Memory", height: 64,
                     fixedTop: RAMReader.total / 1_073_741_824)
            AppChart(metric: .compressed, store: store, window: window, title: "Compressed",
                     height: 64, legendCount: 5)
        }
    }
}

struct DiskPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let s = store.snap
        let last = store.samples.last
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (Fmt.byteRate(last?.diskRead ?? 0), "Read", Palette.blue),
                (Fmt.byteRate(last?.diskWrite ?? 0), "Write", Palette.red),
            ])
            TimeChart(series: [
                Series(name: "Read", color: Palette.blue) { $0.diskRead },
                Series(name: "Write", color: Palette.red) { $0.diskWrite },
            ], samples: store.samples, window: window, mirror: true, format: Fmt.byteRate)
            SectionTitle("Macintosh HD")
            Bar(fraction: s.diskTotal > 0 ? 1 - s.diskFree / s.diskTotal : 0, color: Palette.blue)
            Pairs {
                Row(label: "Used", value: Fmt.bytes(s.diskTotal - s.diskFree))
                Row(label: "Free", value: Fmt.bytes(s.diskFree))
                Row(label: "Read (boot)", value: Fmt.bytes(Double(s.diskReadSinceBoot)))
                Row(label: "Written (boot)", value: Fmt.bytes(Double(s.diskWriteSinceBoot)))
            }
            SectionTitle("By app")
            AppChart(metric: .disk, store: store, window: window, title: "Disk", height: 64)
        }
    }
}

struct NetPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let n = store.snap.net
        let last = store.samples.last
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (Fmt.bitRate(last?.netIn ?? 0), "Download", Palette.blue),
                (Fmt.bitRate(last?.netOut ?? 0), "Upload", Palette.red),
            ])
            TimeChart(series: [
                Series(name: "Download", color: Palette.blue) { $0.netIn },
                Series(name: "Upload", color: Palette.red) { $0.netOut },
            ], samples: store.samples, window: window, mirror: true, format: Fmt.bitRate)
            ConnectivityRow(pings: Array(n.connectivity.suffix(45)))
            SectionTitle("Details")
            Pairs {
                Row(label: "Total ↓", value: Fmt.bytes(store.netTotalIn), dot: Palette.blue)
                Row(label: "Total ↑", value: Fmt.bytes(store.netTotalOut), dot: Palette.red)
                BadgeRow(label: "Status", ok: n.up)
                BadgeRow(label: "Internet", ok: n.connectivity.last?.ms != nil)
                Row(label: "Latency", value: n.latency.map { String(format: "%.0f ms", $0) } ?? "–")
                Row(label: "Jitter", value: n.jitter.map { String(format: "%.1f ms", $0) } ?? "–")
                Row(label: n.displayName.isEmpty ? "Interface" : n.displayName, value: n.interface)
                Row(label: "Local", value: n.localIP)
            }
            Row(label: "Public IP", value: n.publicIP.isEmpty ? "–" : "\(n.publicIP) \(Fmt.flag(n.country))")
            Row(label: "Physical address", value: n.mac)
            SectionTitle("By app")
            AppChart(metric: .net, store: store, window: window, title: "Network", height: 64)
        }
    }
}

struct BatteryPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let b = store.snap.battery
        let dcIn = store.snap.sensors.first { $0.key == "PDTR" }?.value ?? 0
        let state = b.charging ? "Charging" : b.external ? "Plugged in" : "On battery"
        let time = b.external
            ? (b.fullyCharged || !b.charging ? "Fully charged" : minutes(b.timeToFull))
            : minutes(b.timeToEmpty)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(Int((b.level * 100).rounded()))%").font(.system(size: 30)).monospacedDigit()
                Label(state, systemImage: b.external ? "powerplug.fill" : "battery.75percent")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(b.external ? .green : .secondary)
                Spacer()
                Text(time).font(.callout).foregroundStyle(.secondary)
            }
            TimeChart(series: [Series(name: "Level", color: .green) { $0.battery }],
                      samples: store.samples, window: window, height: 44, yDomain: 0...1, format: pct)
            TimeChart(series: [Series(name: "System power", color: Palette.orange) { $0.power }],
                      samples: store.samples, window: window, height: 44, format: { String(format: "%.0f W", $0) })
            SectionTitle("Battery")
            HStack {
                Text("Max \(b.maxCapacity) mAh")
                Spacer()
                Text("Design \(b.designCapacity) mAh")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            Bar(fraction: b.health)
            Pairs {
                Row(label: "Health", value: pct(b.health))
                Row(label: "Cycles", value: "\(b.cycles)")
                Row(label: "Power", value: watts(abs(b.power)))
                Row(label: "Current", value: String(format: "%.0f mA", b.current * 1000))
                Row(label: "Voltage", value: String(format: "%.2f V", b.voltage))
                Row(label: "Temp", value: String(format: "%.0f°C", b.temperature))
            }
            SectionTitle("Power adapter")
            Pairs {
                BadgeRow(label: "Charging", ok: b.charging, on: "Yes", off: "No")
                Row(label: "Power", value: String(format: "%.1f / %d W", dcIn, b.adapterWatts))
                Row(label: "Current", value: String(format: "%.0f mA", b.adapterCurrent * 1000))
                Row(label: "Voltage", value: String(format: "%.2f V", b.adapterVoltage))
            }
        }
    }

    private func minutes(_ m: Int) -> String {
        m <= 0 || m >= 65535 ? "Calculating…" : Fmt.duration(TimeInterval(m * 60))
    }
}

struct SensorsPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let s = store.snap
        let temps = s.sensors.filter { $0.kind == "Temperature" }
        let ordered = temps.filter { $0.group == "Systems" } + temps.filter { $0.group == "CPU" } + temps.filter { $0.group == "GPU" }
        VStack(alignment: .leading, spacing: 8) {
            TimeChart(series: [
                Series(name: "Average CPU", color: Palette.red) { $0.cpuTemp },
                Series(name: "GPU", color: Palette.blue) { $0.gpuTemp },
            ], samples: store.samples, window: window, stacked: false, height: 64, format: { String(format: "%.0f°", $0) })
            SectionTitle("Temperature")
            Pairs {
                ForEach(ordered) { Row(label: short($0.name), value: String(format: "%.1f°C", $0.value)) }
                Row(label: "Average CPU", value: String(format: "%.1f°C", s.cpuTempAvg))
                Row(label: "Hottest CPU", value: String(format: "%.1f°C", s.cpuTempMax))
            }
            SectionTitle("Voltage · Current")
            Pairs {
                ForEach(s.sensors.filter { $0.kind == "Voltage" }) { Row(label: $0.name, value: String(format: "%.2f V", $0.value)) }
                ForEach(s.sensors.filter { $0.kind == "Current" }) { Row(label: $0.name, value: String(format: "%.2f A", $0.value)) }
            }
            SectionTitle("Power")
            TimeChart(series: [Series(name: "System total", color: Palette.orange) { $0.power }],
                      samples: store.samples, window: window, height: 44, format: { String(format: "%.0f W", $0) })
            Pairs {
                ForEach(s.sensors.filter { $0.kind == "Power" }) { Row(label: $0.name, value: watts($0.value)) }
                Row(label: "Average total", value: watts(store.powerAvg))
                Row(label: "CPU", value: watts(s.powerCPU))
                Row(label: "GPU", value: watts(s.powerGPU))
                Row(label: "ANE", value: watts(s.powerANE))
                Row(label: "RAM", value: watts(s.powerDRAM))
            }
            Row(label: "Total system consumption", value: String(format: "%.2f Wh", store.energyWh))
        }
    }

    private func short(_ name: String) -> String {
        name.replacingOccurrences(of: "CPU performance core ", with: "P-core ")
    }
}

// MARK: - Settings

struct SettingsView: View {
    let store: Store
    @Bindable var ui: UIState
    @State private var loginItem = SMAppService.mainApp.status == .enabled

    static let intervals: [Double] = [0.5, 1, 2, 3, 5, 10]
    /// Measured cost of one tick: about 20 ms in Stacks plus 25 ms in nettop and 5 ms in ps.
    static let cpuPerTick = 0.05
    /// Rough in-memory size of one sample (per-app dictionaries for six metrics).
    static let bytesPerSample = 7_000.0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Menubar items").font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(ui.order) { m in
                    Toggle(m.title, isOn: Binding(
                        get: { ui.enabled.contains(m) },
                        set: { on in if on { ui.enabled.insert(m) } else { ui.enabled.remove(m) } }))
                }
            }
            .toggleStyle(.checkbox)

            Divider()
            HStack {
                Text("Sampling").font(.headline)
                Spacer()
                Text("every \(Self.label(ui.interval))").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { Double(Self.intervals.firstIndex(of: ui.interval) ?? 2) },
                set: { ui.interval = Self.intervals[Int($0.rounded())] }),
                   in: 0...Double(Self.intervals.count - 1), step: 1) {
                EmptyView()
            } minimumValueLabel: {
                Text("Fast").font(.caption).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("Light").font(.caption).foregroundStyle(.secondary)
            }
            estimate

            Toggle("Open at login", isOn: Binding(
                get: { loginItem },
                set: { on in
                    try? on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister()
                    loginItem = SMAppService.mainApp.status == .enabled
                }))
                .toggleStyle(.checkbox)

            Divider()
            HStack {
                Button("Re-import totals from Stats") { store.importFromStats() }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private var estimate: some View {
        let cpu = Self.cpuPerTick / ui.interval * 100
        let mb = Store.history / ui.interval * Self.bytesPerSample / 1_048_576
        let heavy = ui.interval < 1
        return VStack(alignment: .leading, spacing: 2) {
            Text("≈ \(String(format: cpu < 10 ? "%.1f" : "%.0f", cpu))% of one core · ≈ \(String(format: "%.0f", mb)) MB for 1 h of history")
                .foregroundStyle(heavy ? Palette.orange : .secondary)
            if heavy {
                Text("Sub-second sampling costs noticeably more CPU and battery.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .monospacedDigit()
        .animation(.easeOut(duration: 0.15), value: ui.interval)
    }

    static func label(_ i: Double) -> String { i < 1 ? "\(Int(i * 1000)) ms" : "\(Int(i)) s" }
}

// MARK: - APM

struct APMPanel: View {
    let store: Store
    let window: TimeInterval

    var body: some View {
        let d = store.day
        let now = store.samples.last
        let apm = now?.apm ?? 0
        let league = InputDay.league(d.avgAPM)
        let idle = store.snap.input.idle
        let keyShare = d.actions > 0 ? Double(d.keys) / Double(d.actions) : 0
        VStack(alignment: .leading, spacing: 8) {
            BigStats(items: [
                (String(format: "%.0f", apm), "APM now", nil),
                (String(format: "%.0f", d.avgAPM), "Avg today", nil),
                (String(format: "%.0f", d.peakAPM), "Peak today", nil),
            ])
            HStack(spacing: 6) {
                Image(systemName: "trophy.fill").foregroundStyle(Self.leagueColor(league.name))
                Text("\(league.name) league").font(.callout.weight(.semibold))
                Spacer()
                if let next = league.next {
                    Text("\(Int((next - d.avgAPM).rounded(.up))) avg APM to \(InputDay.league(next).name)")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Top league").font(.caption).foregroundStyle(.secondary)
                }
            }
            TimeChart(series: [
                Series(name: "Keys", color: Palette.blue) { $0.keysPM },
                Series(name: "Clicks", color: Palette.orange) { $0.clicksPM },
            ], samples: store.samples, window: window, format: { String(format: "%.0f/min", $0) })

            SectionTitle("Today by hour")
            HourBars(hourly: d.hourly, current: Calendar.current.component(.hour, from: Date()))

            SectionTitle("Today")
            Pairs {
                Row(label: "Keystrokes", value: d.keys.formatted(), dot: Palette.blue)
                Row(label: "Clicks", value: "\(d.clicks.formatted()) · \(d.rightClicks.formatted()) R", dot: Palette.orange)
                Row(label: "Modifier presses", value: d.modifiers.formatted())
                Row(label: "Scroll events", value: d.scrolls.formatted())
                Row(label: "Pointer travel", value: Self.distance(d.travelMM))
                Row(label: "Typing burst", value: String(format: "%.0f WPM", d.peakWPM))
                Row(label: "Active time", value: Self.short(d.activeSeconds))
                Row(label: "Longest flow", value: Self.short(d.longestStreak))
                Row(label: "Current flow", value: Self.short(d.currentStreak(at: Date())))
                Row(label: "Idle for", value: idle < 5 ? "Active" : Self.short(idle))
            }
            if d.actions > 0 { HStack(spacing: 6) {
                Text("Keyboard \(Int((keyShare * 100).rounded()))%").foregroundStyle(.secondary)
                GeometryReader { g in
                    HStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: 3).fill(Palette.blue).frame(width: max(0, (g.size.width - 2) * keyShare))
                        RoundedRectangle(cornerRadius: 3).fill(Palette.orange)
                    }
                }
                .frame(height: 10)
                Text("\(Int(((1 - keyShare) * 100).rounded()))% Mouse").foregroundStyle(.secondary)
            }
            .font(.system(size: 12)) }
            if let y = d.yesterdayActions {
                Row(label: "Actions vs yesterday", value: "\(d.actions.formatted()) / \(y.formatted())")
            }

            SectionTitle("All time")
            Pairs {
                Row(label: "Actions", value: store.inputAllTime.actions.formatted())
                Row(label: "Pointer travel", value: Self.distance(store.inputAllTime.travelMM))
            }
            if let since = store.inputAllTime.since {
                Text("Counting since \(since.formatted(date: .abbreviated, time: .omitted)). Only how many keys, never which.")
                    .font(.caption).foregroundStyle(.tertiary)
            }
        }
    }

    static func distance(_ mm: Double) -> String {
        mm >= 1_000_000 ? String(format: "%.2f km", mm / 1_000_000)
            : mm >= 1000 ? String(format: "%.1f m", mm / 1000) : String(format: "%.0f cm", mm / 10)
    }

    static func short(_ s: TimeInterval) -> String {
        let m = Int(s / 60)
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : m > 0 ? "\(m)m" : "\(Int(s))s"
    }

    static func leagueColor(_ name: String) -> Color {
        switch name {
        case "Bronze": Palette.hex(0xb0703c)
        case "Silver": Palette.hex(0xb8c0c8)
        case "Gold": Palette.hex(0xe8b923)
        case "Platinum": Palette.hex(0x7fd4d0)
        case "Diamond": Palette.hex(0x5aa7ff)
        case "Master": Palette.hex(0xb57cff)
        default: Palette.hex(0xff7a45)
        }
    }
}

/// 24 bars of actions per hour, with the current hour highlighted.
struct HourBars: View {
    let hourly: [Double]
    let current: Int

    var body: some View {
        let peak = max(1, hourly.max() ?? 1)
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { h in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.quaternary)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(h == current ? Palette.orange : Palette.blue)
                            .frame(height: hourly[h] > 0 ? max(2, 36 * hourly[h] / peak) : 0)
                    }
                    .frame(height: 36)
                    .help("\(h):00 · \(Int(hourly[h]).formatted()) actions")
                }
            }
            HStack {
                ForEach([0, 6, 12, 18], id: \.self) { h in
                    Text(String(format: "%02d", h)).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }
}
