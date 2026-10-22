import Darwin
import Foundation
import IOKit

/// One history point. Per-app maps are trimmed to the top entries plus "Other".
struct Sample {
    let t: Date
    let cpu: [String: Double]   // cores (1.0 = one core fully busy)
    let gpu: [String: Double]   // percent of the whole GPU
    let mem: [String: Double]   // bytes
    let disk: [String: Double]  // bytes/s read+written (own-user processes only)
    let net: [String: Double]   // bytes/s in+out
    let compressed: [String: Double]  // bytes before compression, refreshed every minute
    let appPower: [String: Double]    // watts, estimated (see `attributePower`)

    let cpuUser: Double, cpuSystem: Double    // fractions of all cores
    let gpuUtil: Double                       // 0...1
    let ramApp: Double, ramWired: Double, ramCompressed: Double, ramTotal: Double
    let diskRead: Double, diskWrite: Double   // bytes/s
    let netIn: Double, netOut: Double         // bytes/s
    let cpuTemp: Double, gpuTemp: Double
    let power: Double                         // system total W
    let battery: Double                       // 0...1
    let pressure: Double                      // 0...1
    let pressureLevel: Int                    // 1 normal, 2 warning, 4 critical
    let keysPM: Double, clicksPM: Double      // input rates this tick, per minute
    let apm: Double                           // actions (keys + clicks) in the last 60 s
    let wpm: Double                           // keys in the last 10 s, as words per minute

    var ramUsed: Double { ramApp + ramWired + ramCompressed }
}

/// Latest-only readings shown in the detail panels.
struct Snapshot {
    var cpu = CPULoad()
    var loadAvg: [Double] = [0, 0, 0]
    var uptime: TimeInterval = 0
    var freqE = 0.0, freqP = 0.0, freqGPU = 0.0
    var powerCPU = 0.0, powerGPU = 0.0, powerANE = 0.0, powerDRAM = 0.0
    var gpuModel = "", gpuCores = 0
    var gpuUtil = 0.0, gpuRenderer = 0.0, gpuTiler = 0.0
    var ram = RAMInfo()
    var diskTotal = 0.0, diskFree = 0.0
    var diskReadSinceBoot: UInt64 = 0, diskWriteSinceBoot: UInt64 = 0
    var net = NetInfo()
    var battery = BatteryInfo()
    var sensors: [SensorReading] = []
    var cpuTempAvg = 0.0, cpuTempMax = 0.0, gpuTemp = 0.0
    // Increments since the previous tick, folded into persistent totals by the store.
    var netInDelta: UInt64 = 0, netOutDelta: UInt64 = 0
    var energyJ = 0.0
    var input = InputDelta()
}

/// Input since the previous tick.
struct InputDelta {
    var keys = 0, clicks = 0, rightClicks = 0, scrolls = 0, modifiers = 0
    var travelMM = 0.0
    var idle: TimeInterval = 0
    var actions: Int { keys + clicks + rightClicks }
}

/// Collects everything once per tick on a utility queue.
///
/// Own-user processes are read with libproc. Processes owned by other users
/// (WindowServer, kernel_task, root daemons) are invisible to libproc without
/// root, so those are read with one setuid `ps` call limited to their pids.
/// Per-process GPU time comes from the accelerator's per-client
/// `accumulatedGPUTime` counters; per-process network from `nettop`.
final class Sampler {
    static let keep = 20

    private let queue = DispatchQueue(label: "stacks.sampler", qos: .utility)
    private let slowQueue = DispatchQueue(label: "stacks.slow", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var slowTimer: DispatchSourceTimer?
    private var interval: TimeInterval
    private let onSample: (Sample, Snapshot) -> Void

    private var prevTime: UInt64 = 0
    private var prevCPU: [pid_t: UInt64] = [:]
    private var prevDisk: [pid_t: UInt64] = [:]
    private var prevNet: [pid_t: UInt64] = [:]
    private var prevGPU: [UInt64: UInt64] = [:]
    private var prevEnergy: [pid_t: UInt64] = [:]
    private var prevDeniedCPU: [pid_t: UInt64] = [:]
    private var groups: [pid_t: String] = [:]
    private let numer: UInt64
    private let denom: UInt64

    private let cpuReader = CPUReader()
    private let diskReader = DiskReader()
    private var prevDiskIO: (UInt64, UInt64)?
    private var prevNetIO: (String, UInt64, UInt64)?
    private var net = NetInfo()           // guarded by `queue`
    private var ticks = 0
    private var lastPublicIPFetch = Date.distantPast
    let input = InputReader()
    private var prevInput: InputReader.Counts?
    private var recentInput: [(t: Date, actions: Int, keys: Int)] = []   // last 60 s

    init(interval: TimeInterval, onSample: @escaping (Sample, Snapshot) -> Void) {
        self.interval = interval
        self.onSample = onSample
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        numer = UInt64(tb.numer)
        denom = UInt64(tb.denom)
        _ = smc_open()
        _ = ior_open()
    }

    /// Call on the main thread.
    func start() {
        input.start()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(Int(interval * 100)))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        let s = DispatchSource.makeTimerSource(queue: slowQueue)
        s.schedule(deadline: .now() + 1, repeating: 10, leeway: .seconds(2))
        s.setEventHandler { [weak self] in self?.slowTick() }
        s.resume()
        slowTimer = s
    }

    /// Changes the sampling period; takes effect from the next tick.
    func setInterval(_ i: TimeInterval) {
        queue.async { [self] in
            interval = i
            timer?.schedule(deadline: .now() + i, repeating: i, leeway: .milliseconds(Int(i * 100)))
        }
    }

    /// Folds this tick's keyboard and mouse counts into `snap` and returns
    /// (keys/min, clicks/min, rolling APM, burst WPM).
    private func readInput(_ snap: inout Snapshot, dt: Double) -> (Double, Double, Double, Double) {
        let c = InputReader.counts()
        defer { prevInput = c }
        snap.input.idle = InputReader.idle()
        snap.input.travelMM = input.takeTravel()
        guard let p = prevInput, dt > 0 else { return (0, 0, 0, 0) }
        // Counters are 32-bit and only grow; wrapping subtraction survives a rollover.
        func d(_ a: UInt32, _ b: UInt32) -> Int { Int(a &- b) }
        snap.input.keys = d(c.keys, p.keys)
        snap.input.clicks = d(c.clicks, p.clicks)
        snap.input.rightClicks = d(c.rightClicks, p.rightClicks)
        snap.input.scrolls = d(c.scrolls, p.scrolls)
        snap.input.modifiers = d(c.modifiers, p.modifiers) / 2   // one press = down + up

        let now = Date()
        recentInput.append((now, snap.input.actions, snap.input.keys))
        recentInput.removeAll { now.timeIntervalSince($0.t) > 60 }
        let apm = Double(recentInput.reduce(0) { $0 + $1.actions })
        let burst = recentInput.filter { now.timeIntervalSince($0.t) <= 10 }.reduce(0) { $0 + $1.keys }
        let wpm = Double(burst) * 6 / 5   // keys per 10 s → per minute, 5 keys to a word
        return (Double(snap.input.keys) / dt * 60, Double(snap.input.clicks + snap.input.rightClicks) / dt * 60, apm, wpm)
    }

    /// Latency and connectivity, every 10s off the main sampling queue.
    private func slowTick() {
        slowTicks += 1
        if slowTicks % 6 == 1 { readCompressed() }
        let ms = NetReader.ping()
        queue.async { [self] in
            if let ms, let last = net.latency { net.jitter = ((net.jitter ?? 0) * 3 + abs(ms - last)) / 4 }
            net.latency = ms ?? net.latency
            net.connectivity.append(NetInfo.Ping(t: Date(), ms: ms))
            if net.connectivity.count > 90 { net.connectivity.removeFirst(net.connectivity.count - 90) }
        }
    }

    private func tick() {
        let now = DispatchTime.now().uptimeNanoseconds
        let dtNs = prevTime == 0 ? 0 : Double(now - prevTime)
        let dt = dtNs / 1e9
        prevTime = now
        ticks += 1
        // Disk capacity and interface details refresh about every 30s, whatever the period.
        let slowEvery = max(1, Int(30 / interval))

        // Per-process CPU, memory, disk.
        var cpuNow: [pid_t: UInt64] = [:]
        var diskNow: [pid_t: UInt64] = [:]
        var energyNow: [pid_t: UInt64] = [:]
        var deniedCPUNow: [pid_t: UInt64] = [:]
        var mem: [String: Double] = [:]
        var denied: [pid_t] = [0]
        for pid in listPids() {
            if let s = ownStats(pid) {
                cpuNow[pid] = s.cpu
                diskNow[pid] = s.disk
                energyNow[pid] = s.energy
                mem[group(pid), default: 0] += Double(s.footprint)
            } else {
                denied.append(pid)
            }
        }
        for (pid, ns, rss) in psStats(denied) {
            cpuNow[pid] = ns
            deniedCPUNow[pid] = ns
            mem[group(pid), default: 0] += rss
        }
        let cpu = rates(cpuNow, &prevCPU, per: dtNs)
        let disk = rates(diskNow, &prevDisk, per: dt)
        let net = rates(nettop(), &prevNet, per: dt)
        let ownWatts = rates(energyNow, &prevEnergy, per: dt * 1e9)
        let deniedCPU = rates(deniedCPUNow, &prevDeniedCPU, per: dtNs)

        let g = gpuStats()
        var gpu: [String: Double] = [:]
        if dtNs > 0 { for (pid, ns) in g.perPid { gpu[group(pid), default: 0] += Double(ns) / dtNs * 100 } }

        groups = groups.filter { cpuNow[$0.key] != nil }

        // System-wide.
        var snap = Snapshot()
        if let c = cpuReader.read() { snap.cpu = c }
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        snap.loadAvg = la
        snap.uptime = Date().timeIntervalSince1970 - bootTime
        var io = ior_sample_t()
        if ior_sample(&io), io.seconds > 0 {
            snap.powerCPU = io.cpu_j / io.seconds
            snap.powerGPU = io.gpu_j / io.seconds
            snap.powerANE = io.ane_j / io.seconds
            snap.powerDRAM = io.dram_j / io.seconds
            snap.freqE = io.ecpu_mhz
            snap.freqP = io.pcpu_mhz
            snap.freqGPU = io.gpu_mhz
        }
        snap.gpuModel = g.model
        snap.gpuCores = g.cores
        snap.gpuUtil = g.device / 100
        snap.gpuRenderer = g.renderer / 100
        snap.gpuTiler = g.tiler / 100
        snap.ram = RAMReader.read()

        let dio = diskReader.read()
        var diskRead = 0.0, diskWrite = 0.0
        if let p = prevDiskIO, dt > 0, dio.0 >= p.0, dio.1 >= p.1 {
            diskRead = Double(dio.0 - p.0) / dt
            diskWrite = Double(dio.1 - p.1) / dt
        }
        prevDiskIO = dio
        snap.diskReadSinceBoot = dio.0
        snap.diskWriteSinceBoot = dio.1
        if ticks % slowEvery == 1 { (snap.diskTotal, snap.diskFree) = DiskReader.capacity() } else { (snap.diskTotal, snap.diskFree) = lastCapacity }
        lastCapacity = (snap.diskTotal, snap.diskFree)

        var netIn = 0.0, netOut = 0.0
        let iface = NetReader.primaryInterface() ?? ""
        if let c = NetReader.counters(iface) {
            if let p = prevNetIO, p.0 == iface, c.0 >= p.1, c.1 >= p.2, dt > 0 {
                snap.netInDelta = c.0 - p.1
                snap.netOutDelta = c.1 - p.2
                netIn = Double(snap.netInDelta) / dt
                netOut = Double(snap.netOutDelta) / dt
            }
            prevNetIO = (iface, c.0, c.1)
        }
        self.net.up = !iface.isEmpty
        if iface != self.net.interface || ticks % slowEvery == 1 {
            let d = NetReader.details(iface)
            let ipChanged = d.ip != self.net.localIP
            self.net.interface = iface
            self.net.displayName = d.display
            self.net.mac = d.mac
            self.net.localIP = d.ip
            if ipChanged || Date().timeIntervalSince(lastPublicIPFetch) > 600 {
                lastPublicIPFetch = Date()
                NetReader.publicIP { [weak self] ip, cc in
                    self?.queue.async { self?.net.publicIP = ip; self?.net.country = cc }
                }
            }
        }
        snap.net = self.net

        snap.battery = BatteryReader.read()
        snap.sensors = SensorReader.read()
        let cpuTemps = snap.sensors.filter { $0.group == "CPU" && $0.kind == "Temperature" }.map(\.value)
        snap.cpuTempAvg = cpuTemps.isEmpty ? 0 : cpuTemps.reduce(0, +) / Double(cpuTemps.count)
        snap.cpuTempMax = cpuTemps.max() ?? 0
        snap.gpuTemp = snap.sensors.first { $0.group == "GPU" && $0.kind == "Temperature" }?.value ?? 0
        let systemPower = snap.sensors.first { $0.key == "PSTR" }?.value ?? 0
        snap.energyJ = systemPower * dt

        let (keysPM, clicksPM, apm, wpm) = readInput(&snap, dt: dt)

        guard dt > 0 else { return }
        let appPower = attributePower(own: ownWatts, denied: deniedCPU, gpu: gpu, snap: snap)
        let sample = Sample(
            t: Date(), cpu: trim(cpu), gpu: trim(gpu), mem: trim(mem), disk: trim(disk), net: trim(net), compressed: compressed,
            appPower: trim(appPower),
            cpuUser: snap.cpu.user, cpuSystem: snap.cpu.system, gpuUtil: snap.gpuUtil,
            ramApp: snap.ram.app, ramWired: snap.ram.wired, ramCompressed: snap.ram.compressed, ramTotal: snap.ram.total,
            diskRead: diskRead, diskWrite: diskWrite, netIn: netIn, netOut: netOut,
            cpuTemp: snap.cpuTempAvg, gpuTemp: snap.gpuTemp, power: systemPower, battery: snap.battery.level,
            pressure: snap.ram.pressurePct, pressureLevel: snap.ram.pressure,
            keysPM: keysPM, clicksPM: clicksPM, apm: apm, wpm: wpm)
        onSample(sample, snap)
    }

    private var lastCapacity = (0.0, 0.0)
    private var slowTicks = 0
    private var compressed: [String: Double] = [:]   // guarded by `queue`

    /// Per-app compressed memory (original size) from setuid `top`, the only
    /// source that sees it without root. It costs ~0.5s of CPU per run whatever
    /// the filter, so this runs once a minute; compressed memory moves slowly.
    private func readCompressed() {
        let text = run("/usr/bin/top", ["-l", "1", "-o", "cmprs", "-n", "\(Self.keep)", "-stats", "pid,cmprs"])
        var byPid: [(pid_t, Double)] = []
        var started = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("PID") { started = true; continue }
            guard started else { continue }
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 2, let pid = pid_t(f[0]), let bytes = Self.topSize(String(f[1])) else { continue }
            byPid.append((pid, bytes))
        }
        let total = RAMReader.read().compressedOriginal
        queue.async { [self] in
            var out: [String: Double] = [:]
            for (pid, b) in byPid { out[group(pid), default: 0] += b }
            let rest = total - out.values.reduce(0, +)
            if rest > 0 { out["Other", default: 0] += rest }
            compressed = out
        }
    }

    /// "7858M", "512K", "1.2G", "0B" -> bytes.
    private static func topSize(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
        guard let unit = t.last else { return nil }
        let mult: Double = switch unit {
        case "B": 1
        case "K": 1024
        case "M": 1_048_576
        case "G": 1_073_741_824
        default: 0
        }
        guard mult > 0, let n = Double(t.dropLast()) else { return nil }
        return n * mult
    }

    /// Wall-clock boot time; `systemUptime` would leave out time spent asleep.
    private let bootTime: TimeInterval = {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        sysctlbyname("kern.boottime", &tv, &size, nil, 0)
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1e6
    }()

    /// Turns per-pid cumulative counters into per-app rates.
    private func rates(_ now: [pid_t: UInt64], _ prev: inout [pid_t: UInt64], per divisor: Double) -> [String: Double] {
        var out: [String: Double] = [:]
        if divisor > 0 {
            for (pid, v) in now {
                if let p = prev[pid], v > p { out[group(pid), default: 0] += Double(v - p) / divisor }
            }
        }
        prev = now
        return out
    }

    /// Per-app power in watts. CPU energy is measured per process by the kernel for
    /// processes we can read; CPU power the package used beyond that is split among
    /// the other users' processes (WindowServer, daemons) by CPU time. GPU power is
    /// split by each app's share of GPU time. Display, memory and the rest of the
    /// system aren't attributed to any app.
    private func attributePower(own: [String: Double], denied: [String: Double], gpu: [String: Double], snap: Snapshot) -> [String: Double] {
        var out = own
        let residual = max(0, snap.powerCPU - own.values.reduce(0, +))
        let deniedTotal = denied.values.reduce(0, +)
        if deniedTotal > 0 { for (g, c) in denied { out[g, default: 0] += residual * c / deniedTotal } }
        let gpuTotal = gpu.values.reduce(0, +)
        if gpuTotal > 0 { for (g, v) in gpu { out[g, default: 0] += snap.powerGPU * v / gpuTotal } }
        return out
    }

    private func trim(_ d: [String: Double]) -> [String: Double] {
        let sorted = d.filter { $0.value > 0 }.sorted { $0.value > $1.value }
        var out: [String: Double] = [:]
        for (k, v) in sorted.prefix(Self.keep) { out[k] = v }
        let rest = sorted.dropFirst(Self.keep).reduce(0) { $0 + $1.value }
        if rest > 0 { out["Other", default: 0] += rest }
        return out
    }

    // MARK: processes

    private func listPids() -> [pid_t] {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(got, 0))).filter { $0 > 0 }
    }

    private func ownStats(_ pid: pid_t) -> (cpu: UInt64, footprint: UInt64, disk: UInt64, energy: UInt64)? {
        var ri = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
            }
        }
        guard r == 0 else { return nil }
        let ticks = ri.ri_user_time + ri.ri_system_time
        return (ticks * numer / denom, ri.ri_phys_footprint, ri.ri_diskio_bytesread + ri.ri_diskio_byteswritten, ri.ri_energy_nj)
    }

    private func run(_ path: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// (pid, cumulative CPU ns, RSS bytes) for processes libproc can't read.
    private func psStats(_ pids: [pid_t]) -> [(pid_t, UInt64, Double)] {
        var out: [(pid_t, UInt64, Double)] = []
        let text = run("/bin/ps", ["-o", "pid=,time=,rss=", "-p", pids.map(String.init).joined(separator: ",")])
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let rss = Double(f[2]) else { continue }
            // cputime is "[[dd-]hh:]mm:ss.cc"; minutes may exceed 59.
            var secs = 0.0
            let dayParts = f[1].split(separator: "-")
            if dayParts.count == 2, let d = Double(dayParts[0]) { secs += d * 86400 }
            secs += dayParts.last!.split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
            out.append((pid, UInt64(secs * 1e9), rss * 1024))
        }
        return out
    }

    /// Cumulative bytes in+out per pid. Lines look like "Mail.874,11250,8013,".
    private func nettop() -> [pid_t: UInt64] {
        var out: [pid_t: UInt64] = [:]
        let text = run("/usr/bin/nettop", ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"])
        for line in text.split(separator: "\n").dropFirst() {
            let f = line.split(separator: ",", omittingEmptySubsequences: false)
            guard f.count >= 3, let dot = f[0].lastIndex(of: "."),
                  let pid = pid_t(f[0][f[0].index(after: dot)...]),
                  let i = UInt64(f[1]), let o = UInt64(f[2]) else { continue }
            out[pid, default: 0] += i + o
        }
        return out
    }

    /// Display name: outermost .app bundle when there is one, so helpers roll up
    /// into their app; otherwise the process name.
    private func group(_ pid: pid_t) -> String {
        if let g = groups[pid] { return g }
        var name = ""
        if pid == 0 {
            name = "kernel_task"
        } else {
            var buf = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
                let path = String(cString: buf)
                if let r = path.range(of: ".app/") {
                    name = path[..<r.lowerBound].split(separator: "/").last.map(String.init) ?? ""
                }
            }
            if name.isEmpty {
                var nb = [CChar](repeating: 0, count: 256)
                if proc_name(pid, &nb, UInt32(nb.count)) > 0 { name = String(cString: nb) }
            }
            if name.isEmpty { name = sysctlComm(pid) }
            if name.isEmpty { name = "pid \(pid)" }
        }
        groups[pid] = name
        return name
    }

    private func sysctlComm(_ pid: pid_t) -> String {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return "" }
        return withUnsafeBytes(of: info.kp_proc.p_comm) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    // MARK: GPU

    private struct GPUStats {
        var perPid: [pid_t: UInt64] = [:]   // GPU ns since last call
        var device = 0.0, renderer = 0.0, tiler = 0.0
        var model = "", cores = 0
    }

    private func gpuStats() -> GPUStats {
        var g = GPUStats()
        var seen: [UInt64: UInt64] = [:]

        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else {
            return g
        }
        defer { IOObjectRelease(it) }

        while true {
            let acc = IOIteratorNext(it)
            if acc == 0 { break }
            defer { IOObjectRelease(acc) }

            if let ps = prop(acc, "PerformanceStatistics") as? [String: Any] {
                g.device = max(g.device, (ps["Device Utilization %"] as? NSNumber)?.doubleValue ?? 0)
                g.renderer = max(g.renderer, (ps["Renderer Utilization %"] as? NSNumber)?.doubleValue ?? 0)
                g.tiler = max(g.tiler, (ps["Tiler Utilization %"] as? NSNumber)?.doubleValue ?? 0)
            }
            if g.model.isEmpty {
                g.model = prop(acc, "model") as? String ?? ""
                g.cores = (prop(acc, "gpu-core-count") as? NSNumber)?.intValue ?? 0
            }

            var ci: io_iterator_t = 0
            guard IORegistryEntryGetChildIterator(acc, kIOServicePlane, &ci) == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(ci) }
            while true {
                let c = IOIteratorNext(ci)
                if c == 0 { break }
                defer { IOObjectRelease(c) }
                guard let creator = prop(c, "IOUserClientCreator") as? String,
                      let usage = prop(c, "AppUsage") as? [[String: Any]],
                      let pid = parsePid(creator) else { continue }
                let total = usage.reduce(UInt64(0)) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0) }
                var id: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(c, &id)
                seen[id] = total
                if let p = prevGPU[id], total > p { g.perPid[pid, default: 0] += total - p }
            }
        }
        prevGPU = seen
        return g
    }

    private func prop(_ e: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(e, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// "pid 406, WindowServer" -> 406
    private func parsePid(_ s: String) -> pid_t? {
        guard s.hasPrefix("pid "), let comma = s.firstIndex(of: ",") else { return nil }
        return pid_t(s[s.index(s.startIndex, offsetBy: 4)..<comma])
    }
}
