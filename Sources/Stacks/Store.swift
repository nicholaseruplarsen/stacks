import Foundation
import Observation

@Observable
final class Store {
    var samples: [Sample] = []
    var snap = Snapshot()

    // Running totals, persisted across launches.
    var netTotalIn: Double
    var netTotalOut: Double
    var energyWh: Double
    var powerAvg = 0.0
    var day: InputDay
    var inputAllTime: InputTotals

    @ObservationIgnored private var powerN = 0.0
    @ObservationIgnored private var unsaved = 0
    @ObservationIgnored private let defaults = UserDefaults.standard

    /// History kept, in seconds; sample count follows the sampling period.
    static let history: TimeInterval = 3600

    init() {
        netTotalIn = defaults.double(forKey: "netTotalIn")
        netTotalOut = defaults.double(forKey: "netTotalOut")
        energyWh = defaults.double(forKey: "energyWh")
        day = (defaults.data(forKey: "inputDay")).flatMap { try? JSONDecoder().decode(InputDay.self, from: $0) } ?? InputDay()
        inputAllTime = (defaults.data(forKey: "inputAllTime")).flatMap { try? JSONDecoder().decode(InputTotals.self, from: $0) } ?? InputTotals()
        if !defaults.bool(forKey: "importedStats") {
            importFromStats()
            defaults.set(true, forKey: "importedStats")
        }
    }

    func append(_ s: Sample, _ snap: Snapshot) {
        samples.append(s)
        let cutoff = s.t.addingTimeInterval(-Self.history)
        if let first = samples.first, first.t < cutoff {
            samples.removeFirst(samples.firstIndex { $0.t >= cutoff } ?? samples.count)
        }
        self.snap = snap
        netTotalIn += Double(snap.netInDelta)
        netTotalOut += Double(snap.netOutDelta)
        energyWh += snap.energyJ / 3600
        if s.power > 0 {
            powerN += 1
            powerAvg += (s.power - powerAvg) / powerN
        }
        foldInput(s, snap.input)
        unsaved += 1
        if unsaved >= 15 { save() }
    }

    func save() {
        unsaved = 0
        defaults.set(netTotalIn, forKey: "netTotalIn")
        defaults.set(netTotalOut, forKey: "netTotalOut")
        defaults.set(energyWh, forKey: "energyWh")
        defaults.set(try? JSONEncoder().encode(day), forKey: "inputDay")
        defaults.set(try? JSONEncoder().encode(inputAllTime), forKey: "inputAllTime")
    }

    private func foldInput(_ s: Sample, _ d: InputDelta) {
        let today = InputDay.key(s.t)
        if day.date != today {
            let y = day
            day = InputDay(date: today)
            if y.date == InputDay.key(s.t.addingTimeInterval(-86400)) { day.yesterdayActions = y.actions; day.yesterdayAvgAPM = y.avgAPM }
        }
        day.keys += d.keys
        day.clicks += d.clicks
        day.rightClicks += d.rightClicks
        day.scrolls += d.scrolls
        day.modifiers += d.modifiers
        day.travelMM += d.travelMM
        day.hourly[Calendar.current.component(.hour, from: s.t)] += Double(d.actions)
        day.peakAPM = max(day.peakAPM, s.apm)
        day.peakWPM = max(day.peakWPM, s.wpm)
        inputAllTime.actions += d.actions
        inputAllTime.keys += d.keys
        inputAllTime.travelMM += d.travelMM
        if inputAllTime.since == nil { inputAllTime.since = s.t }

        // Flow: unbroken activity, where a pause under a minute doesn't break it.
        let dt = samples.count > 1 ? s.t.timeIntervalSince(samples[samples.count - 2].t) : 0
        if d.idle < InputDay.flowGap {
            day.activeSeconds += min(dt, InputDay.flowGap)
            if day.streakStart == nil { day.streakStart = s.t }
            day.longestStreak = max(day.longestStreak, day.currentStreak(at: s.t))
        } else {
            day.streakStart = nil
        }
    }

    /// Replaces the running totals with the latest values Stats saved.
    @discardableResult
    func importFromStats() -> Bool {
        guard let s = StatsImport.read() else { return false }
        if let i = s.netIn { netTotalIn = i }
        if let o = s.netOut { netTotalOut = o }
        if let e = s.energyWh { energyWh = e }
        save()
        return true
    }
}

/// Reads the last values Stats wrote into its LevelDB cache. The values are
/// stored as plain JSON after the reader's key, uncompressed in the log and in
/// the small tables, so a byte scan is enough; no LevelDB library needed.
enum StatsImport {
    static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Stats/lldb")

    static func read() -> (netIn: Double?, netOut: Double?, energyWh: Double?)? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        let sorted = files
            .filter { ["ldb", "log"].contains($0.pathExtension) }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a < b
            }
        var netIn: Double?, netOut: Double?, energy: Double?
        for f in sorted {
            guard let data = try? Data(contentsOf: f) else { continue }
            for obj in jsonValues(after: "Network@UsageReader", in: data) {
                if let total = (obj as? [String: Any])?["total"] as? [String: Any] {
                    if let d = (total["download"] as? NSNumber)?.doubleValue { netIn = max(netIn ?? 0, d) }
                    if let u = (total["upload"] as? NSNumber)?.doubleValue { netOut = max(netOut ?? 0, u) }
                }
            }
            for obj in jsonValues(after: "Sensors@SensorsReader", in: data) {
                for s in ((obj as? [String: Any])?["sensors"] as? [[String: Any]]) ?? [] {
                    if let p = s["payload"] as? [String: Any], p["name"] as? String == "Total System Consumption",
                       let v = (p["value"] as? NSNumber)?.doubleValue { energy = v }
                }
            }
        }
        if netIn == nil && energy == nil { return nil }
        return (netIn, netOut, energy)
    }

    /// Every JSON object/array that starts within a few bytes after `key`.
    private static func jsonValues(after key: String, in data: Data) -> [Any] {
        let bytes = [UInt8](data)
        let k = [UInt8](key.utf8)
        var out: [Any] = []
        var i = 0
        while i + k.count < bytes.count {
            guard bytes[i] == k[0], Array(bytes[i..<i + k.count]) == k else { i += 1; continue }
            var s = i + k.count
            let limit = min(bytes.count, s + 12)
            while s < limit, bytes[s] != UInt8(ascii: "{"), bytes[s] != UInt8(ascii: "[") { s += 1 }
            if s < limit, let end = matchingEnd(bytes, s),
               let obj = try? JSONSerialization.jsonObject(with: Data(bytes[s...end])) {
                out.append(obj)
                i = end
            }
            i += 1
        }
        return out
    }

    private static func matchingEnd(_ b: [UInt8], _ start: Int) -> Int? {
        var depth = 0, inString = false, escape = false
        for j in start..<b.count {
            let c = b[j]
            if inString {
                if escape { escape = false } else if c == UInt8(ascii: "\\") { escape = true } else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "{"), UInt8(ascii: "["): depth += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                if depth == 0 { return j }
            default: break
            }
        }
        return nil
    }
}

/// Today's keyboard and mouse activity, persisted and reset at midnight.
struct InputDay: Codable {
    static let flowGap: TimeInterval = 60

    var date = InputDay.key(Date())
    var keys = 0, clicks = 0, rightClicks = 0, scrolls = 0, modifiers = 0
    var travelMM = 0.0
    var hourly = [Double](repeating: 0, count: 24)
    var peakAPM = 0.0, peakWPM = 0.0
    var activeSeconds = 0.0
    var streakStart: Date?
    var longestStreak = 0.0
    var yesterdayActions: Int?
    var yesterdayAvgAPM: Double?

    var actions: Int { keys + clicks + rightClicks }
    /// Average APM over the minutes you were actually active.
    var avgAPM: Double { activeSeconds > 60 ? Double(actions) / (activeSeconds / 60) : 0 }
    func currentStreak(at t: Date) -> TimeInterval { streakStart.map { t.timeIntervalSince($0) } ?? 0 }

    static func key(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// StarCraft-style league for an average APM.
    static func league(_ apm: Double) -> (name: String, next: Double?) {
        let tiers: [(String, Double)] = [("Bronze", 0), ("Silver", 40), ("Gold", 60), ("Platinum", 80),
                                         ("Diamond", 120), ("Master", 160), ("Grandmaster", 220)]
        let i = tiers.lastIndex { apm >= $0.1 } ?? 0
        return (tiers[i].0, i + 1 < tiers.count ? tiers[i + 1].1 : nil)
    }
}

struct InputTotals: Codable {
    var actions = 0, keys = 0
    var travelMM = 0.0
    var since: Date?
}
