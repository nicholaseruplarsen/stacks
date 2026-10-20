import AppKit
import Darwin
import Foundation
import IOKit
import SystemConfiguration

func sysctlInt(_ name: String) -> Int {
    var v: Int64 = 0
    var size = MemoryLayout<Int64>.size
    guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return 0 }
    return size == 4 ? Int(Int32(truncatingIfNeeded: v)) : Int(v)
}

func registryProps(_ e: io_registry_entry_t) -> [String: Any] {
    var props: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(e, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let d = props?.takeRetainedValue() as? [String: Any] else { return [:] }
    return d
}

// MARK: - CPU

struct CPULoad {
    var user = 0.0, system = 0.0      // fractions of all cores
    var perCore: [Double] = []
    var eUsage = 0.0, pUsage = 0.0
}

final class CPUReader {
    let eCores = sysctlInt("hw.perflevel1.logicalcpu")
    let pCores = sysctlInt("hw.perflevel0.logicalcpu")
    private var prev: [Int32] = []

    func read() -> CPULoad? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        let cur = Array(UnsafeBufferPointer(start: info, count: Int(infoCount)))
        vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        defer { prev = cur }
        guard prev.count == cur.count else { return nil }

        var load = CPULoad()
        var tu = 0.0, ts = 0.0, tt = 0.0
        for c in 0..<Int(count) {
            let b = c * Int(CPU_STATE_MAX)
            func d(_ s: Int32) -> Double { Double(UInt32(bitPattern: cur[b + Int(s)] &- prev[b + Int(s)])) }
            let u = d(CPU_STATE_USER) + d(CPU_STATE_NICE), s = d(CPU_STATE_SYSTEM), i = d(CPU_STATE_IDLE)
            let t = u + s + i
            load.perCore.append(t > 0 ? (u + s) / t : 0)
            tu += u; ts += s; tt += t
        }
        if tt > 0 { load.user = tu / tt; load.system = ts / tt }
        let e = load.perCore.prefix(eCores), p = load.perCore.dropFirst(eCores)
        load.eUsage = e.isEmpty ? 0 : e.reduce(0, +) / Double(e.count)
        load.pUsage = p.isEmpty ? 0 : p.reduce(0, +) / Double(p.count)
        return load
    }
}

// MARK: - RAM

struct RAMInfo {
    var total = 0.0, used = 0.0, app = 0.0, wired = 0.0, compressed = 0.0, free = 0.0
    var swapUsed = 0.0
    var pressure = 1   // 1 normal, 2 warning, 4 critical
    var pressurePct = 0.0  // 0...1, 100 minus the kernel's "memory free" level
    var compressedOriginal = 0.0  // what the compressed pages would take uncompressed
}

enum RAMReader {
    static let total = Double(sysctlInt("hw.memsize"))

    static func read() -> RAMInfo {
        var s = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        _ = withUnsafeMutablePointer(to: &s) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        let page = Double(vm_kernel_page_size)
        var r = RAMInfo()
        r.total = total
        r.app = Double(Int64(s.internal_page_count) - Int64(s.purgeable_count)) * page
        r.wired = Double(s.wire_count) * page
        r.compressed = Double(s.compressor_page_count) * page
        r.used = r.app + r.wired + r.compressed
        r.free = max(0, total - r.used)

        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 { r.swapUsed = Double(swap.xsu_used) }
        r.pressure = max(1, sysctlInt("kern.memorystatus_vm_pressure_level"))
        r.pressurePct = Double(100 - min(100, max(0, sysctlInt("kern.memorystatus_level")))) / 100
        r.compressedOriginal = Double(s.total_uncompressed_pages_in_compressor) * page
        return r
    }
}

// MARK: - Disk

final class DiskReader {
    private var driver: io_registry_entry_t = 0

    init(bsdName: String = "disk0") {
        var e = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsdName))
        while e != 0 {
            if IOObjectConformsTo(e, "IOBlockStorageDriver") != 0 { driver = e; return }
            var parent: io_registry_entry_t = 0
            let kr = IORegistryEntryGetParentEntry(e, kIOServicePlane, &parent)
            IOObjectRelease(e)
            e = kr == KERN_SUCCESS ? parent : 0
        }
    }

    /// Cumulative bytes (read, written) since boot.
    func read() -> (UInt64, UInt64) {
        guard driver != 0,
              let st = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return (0, 0) }
        return ((st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0, (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0)
    }

    static func capacity() -> (total: Double, free: Double) {
        let v = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return (Double(v?.volumeTotalCapacity ?? 0), Double(v?.volumeAvailableCapacityForImportantUsage ?? 0))
    }
}

// MARK: - Network

struct NetInfo {
    var interface = ""          // BSD name
    var displayName = ""
    var mac = ""
    var localIP = ""
    var publicIP = ""
    var country = ""
    var up = false
    var latency: Double?        // ms
    var jitter: Double?
    var connectivity: [Ping] = []

    struct Ping {
        let t: Date
        let ms: Double?   // nil: no reply within 2s
    }
}

enum NetReader {
    /// The physical interface carrying traffic. When a VPN (Tailscale exit node,
    /// utun*) is primary, its traffic also crosses the physical link, so count
    /// that instead, as Stats does.
    static func primaryInterface() -> String? {
        let d = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        if let p = d?["PrimaryInterface"] as? String, p.hasPrefix("en") { return p }
        var found: String?
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0 else { return nil }
        var p = addrs
        while let a = p {
            let name = String(cString: a.pointee.ifa_name)
            let flags = Int32(a.pointee.ifa_flags)
            if found == nil, name.hasPrefix("en"), flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
               a.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_INET) { found = name }
            p = a.pointee.ifa_next
        }
        freeifaddrs(addrs)
        return found
    }

    /// Cumulative (in, out) bytes for one interface, from the 64-bit counters.
    static func counters(_ name: String) -> (UInt64, UInt64)? {
        let index = Int32(if_nametoindex(name))
        guard index > 0 else { return nil }
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return nil }
        return buf.withUnsafeBytes { raw -> (UInt64, UInt64)? in
            var off = 0
            while off + MemoryLayout<if_msghdr>.size <= len {
                let hdr = raw.load(fromByteOffset: off, as: if_msghdr.self)
                if Int32(hdr.ifm_type) == RTM_IFINFO2, Int32(hdr.ifm_index) == index {
                    let h2 = raw.loadUnaligned(fromByteOffset: off, as: if_msghdr2.self)
                    return (h2.ifm_data.ifi_ibytes, h2.ifm_data.ifi_obytes)
                }
                off += Int(hdr.ifm_msglen)
                if hdr.ifm_msglen == 0 { break }
            }
            return nil
        }
    }

    static func details(_ name: String) -> (display: String, mac: String, ip: String) {
        var display = name, mac = "", ip = ""
        if let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] {
            for i in all where SCNetworkInterfaceGetBSDName(i) as String? == name {
                display = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? name
                mac = (SCNetworkInterfaceGetHardwareAddressString(i) as String?) ?? ""
            }
        }
        var addrs: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&addrs) == 0 {
            var p = addrs
            while let a = p {
                if String(cString: a.pointee.ifa_name) == name, let sa = a.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        ip = String(cString: host)
                    }
                }
                p = a.pointee.ifa_next
            }
            freeifaddrs(addrs)
        }
        return (display, mac, ip)
    }

    /// Round-trip ms to 1.1.1.1, or nil when unreachable.
    static func ping() -> Double? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/ping")
        p.arguments = ["-c", "1", "-t", "2", "-q", "1.1.1.1"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        // "round-trip min/avg/max/stddev = 289.3/289.3/289.3/0.000 ms"
        guard let r = out.range(of: "= ") else { return nil }
        return Double(out[r.upperBound...].split(separator: "/").first ?? "")
    }

    /// Public IP and country code from Cloudflare's trace endpoint.
    static func publicIP(_ done: @escaping (String, String) -> Void) {
        var req = URLRequest(url: URL(string: "https://1.1.1.1/cdn-cgi/trace")!)
        req.timeoutInterval = 10
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data else { return }
            var ip = "", loc = ""
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                if line.hasPrefix("ip=") { ip = String(line.dropFirst(3)) }
                if line.hasPrefix("loc=") { loc = String(line.dropFirst(4)) }
            }
            done(ip, loc)
        }.resume()
    }
}

// MARK: - Battery

struct BatteryInfo {
    var present = false
    var level = 0.0             // 0...1
    var external = false        // adapter connected
    var charging = false
    var fullyCharged = false
    var timeToEmpty = -1        // minutes
    var timeToFull = -1
    var maxCapacity = 0         // mAh
    var designCapacity = 0
    var cycles = 0
    var voltage = 0.0           // V
    var current = 0.0           // A (negative when discharging)
    var temperature = 0.0       // °C
    var adapterWatts = 0
    var adapterVoltage = 0.0
    var adapterCurrent = 0.0
    var health: Double { designCapacity > 0 ? Double(maxCapacity) / Double(designCapacity) : 0 }
    var power: Double { voltage * current }
}

enum BatteryReader {
    static func read() -> BatteryInfo {
        var b = BatteryInfo()
        let svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard svc != 0 else { return b }
        defer { IOObjectRelease(svc) }
        let p = registryProps(svc)
        func int(_ k: String) -> Int { (p[k] as? NSNumber)?.intValue ?? 0 }
        b.present = (p["BatteryInstalled"] as? Bool) ?? true
        b.level = Double(int("CurrentCapacity")) / Double(max(1, int("MaxCapacity")))
        b.external = (p["ExternalConnected"] as? Bool) ?? false
        b.charging = (p["IsCharging"] as? Bool) ?? false
        b.fullyCharged = (p["FullyCharged"] as? Bool) ?? false
        b.timeToEmpty = int("AvgTimeToEmpty")
        b.timeToFull = int("AvgTimeToFull")
        b.maxCapacity = int("AppleRawMaxCapacity")
        b.designCapacity = int("DesignCapacity")
        b.cycles = int("CycleCount")
        b.voltage = Double(int("Voltage")) / 1000
        b.current = Double(Int16(truncatingIfNeeded: int("Amperage"))) / 1000
        b.temperature = Double(int("Temperature")) / 100
        if let a = p["AdapterDetails"] as? [String: Any] {
            b.adapterWatts = (a["Watts"] as? NSNumber)?.intValue ?? 0
            b.adapterVoltage = Double((a["AdapterVoltage"] as? NSNumber)?.intValue ?? 0) / 1000
            b.adapterCurrent = Double((a["Current"] as? NSNumber)?.intValue ?? 0) / 1000
        }
        return b
    }
}

// MARK: - Sensors (SMC keys and names as Stats uses them on M2)

struct SensorReading: Identifiable {
    let key: String, name: String, group: String, kind: String
    let value: Double
    var id: String { kind + key + name }
}

enum SensorReader {
    static let defs: [(key: String, name: String, group: String, kind: String)] = [
        ("TW0P", "Airport", "Systems", "Temperature"),
        ("TH0x", "NAND", "Systems", "Temperature"),
        ("TB1T", "Battery 1", "Systems", "Temperature"),
        ("TB2T", "Battery 2", "Systems", "Temperature"),
        ("Tp01", "CPU performance core 1", "CPU", "Temperature"),
        ("Tp05", "CPU performance core 2", "CPU", "Temperature"),
        ("Tp09", "CPU performance core 3", "CPU", "Temperature"),
        ("Tp0D", "CPU performance core 4", "CPU", "Temperature"),
        ("Tp0b", "CPU performance core 6", "CPU", "Temperature"),
        ("Tp0f", "CPU performance core 7", "CPU", "Temperature"),
        ("Tp0j", "CPU performance core 8", "CPU", "Temperature"),
        ("Tg0f", "GPU 1", "GPU", "Temperature"),
        ("VD0R", "DC In", "Sensors", "Voltage"),
        ("VP0R", "12V rail", "Sensors", "Voltage"),
        ("ID0R", "DC In", "Sensors", "Current"),
        ("PPBR", "Battery", "Sensors", "Power"),
        ("PDTR", "DC In", "Sensors", "Power"),
        ("PSTR", "System Total", "Sensors", "Power"),
    ]

    static func read() -> [SensorReading] {
        defs.compactMap { d in
            var v = 0.0
            guard smc_read(d.key, &v), v.isFinite else { return nil }
            return SensorReading(key: d.key, name: d.name, group: d.group, kind: d.kind, value: v)
        }
    }
}

// MARK: - Input activity

/// Keyboard and mouse activity. Event counts come from the window server's per-type
/// counters, which need no permission and never see which keys were pressed. Pointer
/// travel comes from a global mouse-moved monitor; mouse events don't need Accessibility.
final class InputReader {
    struct Counts {
        var keys: UInt32 = 0, clicks: UInt32 = 0, rightClicks: UInt32 = 0, scrolls: UInt32 = 0, modifiers: UInt32 = 0
    }

    static func counts() -> Counts {
        func n(_ t: CGEventType) -> UInt32 { CGEventSource.counterForEventType(.combinedSessionState, eventType: t) }
        return Counts(keys: n(.keyDown), clicks: n(.leftMouseDown), rightClicks: n(.rightMouseDown) + n(.otherMouseDown),
                      scrolls: n(.scrollWheel), modifiers: n(.flagsChanged))
    }

    /// Seconds since any keyboard or mouse input.
    static func idle() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Millimetres per screen point on the main display, for turning pointer travel into distance.
    static let mmPerPoint: Double = {
        guard let screen = NSScreen.main else { return 0.2 }
        let mm = CGDisplayScreenSize(CGMainDisplayID()).width
        return mm > 0 ? mm / screen.frame.width : 0.2
    }()

    private var travel = 0.0   // points, guarded by `lock`
    private let lock = NSLock()
    private var monitors: [Any] = []

    /// Call on the main thread.
    func start() {
        let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        let add: (NSEvent) -> Void = { [weak self] e in
            guard let self else { return }
            let d = hypot(e.deltaX, e.deltaY)
            lock.lock(); travel += d; lock.unlock()
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: add) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { add($0); return $0 }) { monitors.append(l) }
    }

    /// Pointer travel in millimetres since the last call.
    func takeTravel() -> Double {
        lock.lock(); defer { lock.unlock() }
        let t = travel
        travel = 0
        return t * Self.mmPerPoint
    }
}
