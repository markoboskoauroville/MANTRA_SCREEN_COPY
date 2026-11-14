import Foundation
import Darwin

struct Route { var addr: String; var link: String; var rtt: Int }

final class Phone {
    let id: String
    var name: String
    var routes: [Route]
    init(id: String, name: String, routes: [Route]) { self.id = id; self.name = name; self.routes = routes }
}

func isTailscale(_ host: String) -> Bool {
    let p = host.split(separator: ".").compactMap { Int($0) }
    return p.count == 4 && p[0] == 100 && p[1] >= 64 && p[1] <= 127
}

func linkName2(_ serial: String) -> String {
    if let t = Relay.shared.target(of: serial) { return linkName2(t) }        // a relay on 127.0.0.1 counts as the route behind it
    if serial.contains("_adb-tls") { return "Wi-Fi" }
    if !serial.contains(":") { return "USB" }
    return isTailscale(String(serial.split(separator: ":")[0])) ? "Tailscale" : "Wi-Fi"
}
func linkRank(_ l: String) -> Int { l == "USB" ? 0 : (l == "Wi-Fi" ? 1 : 2) }

/// Port test with a timeout (non-blocking connect + poll).
func tcpOpen(_ host: String, _ port: Int, timeoutMs: Int32) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    if fd < 0 { return false }
    defer { close(fd) }
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = UInt16(port).bigEndian
    addr.sin_addr.s_addr = inet_addr(host)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r == 0 { return true }
    if errno != EINPROGRESS { return false }
    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
    if poll(&p, 1, timeoutMs) <= 0 { return false }
    var err: Int32 = 0; var len = socklen_t(4)
    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
    return err == 0
}

/// Local IPv4 addresses on private networks (not Tailscale): returns (ip, first three octets).
func localNets() -> [(String, String)] {
    var r: [(String, String)] = []
    var ifa: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifa) == 0, let first = ifa else { return r }
    defer { freeifaddrs(ifa) }
    var p: UnsafeMutablePointer<ifaddrs>? = first
    while let c = p {
        let name = String(cString: c.pointee.ifa_name)
        if let sa = c.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), name.hasPrefix("en") || name.hasPrefix("bridge") {
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                var a = sin.pointee.sin_addr
                inet_ntop(AF_INET, &a, &buf, socklen_t(INET_ADDRSTRLEN))
            }
            let ip = String(cString: buf)
            let o = ip.split(separator: ".").map(String.init)
            if o.count == 4, o[0] == "10" || (o[0] == "192" && o[1] == "168") || (o[0] == "172" && (16...31).contains(Int(o[1]) ?? 0)) {
                r.append((ip, "\(o[0]).\(o[1]).\(o[2])."))
            }
        }
        p = c.pointee.ifa_next
    }
    return r
}

/// Finds every phone by itself and merges all routes of one phone into one card.
final class Discovery {
    static let shared = Discovery()
    private let lock = NSLock()
    private var phones: [String: Phone] = [:]
    private var info: [String: (id: String, name: String)] = [:]
    var onChange: (() -> Void)?
    var firstDone = false
    private var scanRequested = true
    private var running = false

    func start() {
        if running { return }
        running = true
        Thread.detachNewThread { [weak self] in
            var n = 0
            while let s = self {
                s.cycle(scan: s.scanRequested || n % 4 == 0)
                s.scanRequested = false
                s.firstDone = true
                n += 1
                for _ in 0..<60 where !s.scanRequested { usleep(100_000) }
            }
        }
    }
    static func sane(_ s: String) -> Bool {
        let l = s.lowercased()
        return !s.isEmpty && s.count < 60 && !l.contains("error") && !l.contains("offline") && !l.contains("not found") && !l.contains("unauthorized") && !l.contains("closed")
    }
    func scanNow() { scanRequested = true }

    func all() -> [Phone] {
        lock.lock(); defer { lock.unlock() }
        return phones.values.sorted { $0.name < $1.name }
    }
    func routes(_ id: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return (phones[id]?.routes ?? []).sorted { (linkRank($0.link), $0.rtt) < (linkRank($1.link), $1.rtt) }.map { $0.addr }
    }
    func name(_ id: String) -> String? { lock.lock(); defer { lock.unlock() }; return phones[id]?.name }

    private func cycle(scan: Bool) {
        if scan { findNetworkPhones() }
        let list = adbDevices().filter { $0.state == "device" && !$0.serial.hasPrefix("emulator-") }
        var groups: [String: Phone] = [:]
        for e in list {
            // a failed read ("error: device offline") must never be remembered as the phone's identity
            if let c = info[e.serial], !Discovery.sane(c.id) || !Discovery.sane(c.name) { info[e.serial] = nil }
            if info[e.serial] == nil {
                let id = physicalId(e.serial).split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
                let nm = phoneName(e.serial)
                if !Discovery.sane(id) || !Discovery.sane(nm) { logLine("discovery: \(e.serial) not readable yet (\(id) / \(nm))"); continue }
                info[e.serial] = (id, nm)
            }
            let inf = info[e.serial]!
            let t0 = Date()
            _ = adb(e.serial, ["shell", "true"], timeout: 5)
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            let route = Route(addr: e.serial, link: linkName2(e.serial), rtt: ms)
            if let g = groups[inf.id] { g.routes.append(route) } else { groups[inf.id] = Phone(id: inf.id, name: inf.name, routes: [route]) }
        }
        lock.lock(); phones = groups; lock.unlock()
        DispatchQueue.main.async { self.onChange?() }
    }

    private func findNetworkPhones() {
        let devs = adbDevices()
        // an address already reached, directly or through our relay, is not connected again
        let known = Set(devs.filter { $0.state == "device" }.map { Relay.shared.target(of: $0.serial) ?? $0.serial })
        var candidates: Set<String> = []
        // 1. wireless debugging announced by mDNS
        for line in adb(nil, ["mdns", "services"], timeout: 6).split(separator: "\n") where line.contains("_adb-tls-connect") {
            if let last = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last, last.contains(":") { candidates.insert(String(last)) }
        }
        // 2. port 5555 on every local subnet
        var open: [String] = []
        let lockO = NSLock()
        for (own, prefix) in localNets() {
            DispatchQueue.concurrentPerform(iterations: 254) { i in
                let h = "\(prefix)\(i + 1)"
                if h != own && tcpOpen(h, 5555, timeoutMs: 400) { lockO.lock(); open.append(h); lockO.unlock() }
            }
        }
        for h in open { candidates.insert("\(h):5555") }
        // 3. Tailscale peers that are Android
        let ts = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        if FileManager.default.fileExists(atPath: ts) {
            let out = runCmd(ts, ["status", "--json"], timeout: 6).1
            if let d = out.data(using: .utf8), let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let peers = j["Peer"] as? [String: Any] {
                for (_, v) in peers {
                    guard let p = v as? [String: Any], (p["OS"] as? String)?.lowercased() == "android", let ips = p["TailscaleIPs"] as? [String] else { continue }
                    for ip in ips where !ip.contains(":") && tcpOpen(ip, 5555, timeoutMs: 1200) { candidates.insert("\(ip):5555") }
                }
            }
        }
        for c in candidates where !known.contains(c) {
            let r = adb(nil, ["connect", c], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
            logLine("discovery: adb connect \(c): \(r)")
            if r.contains("connected to") && !r.contains("failed") { continue }
            // the adb server cannot reach the LAN (no Local Network permission) but this app can: go through a local relay
            let hp = c.split(separator: ":")
            if hp.count == 2, let port = Int(hp[1]), tcpOpen(String(hp[0]), port, timeoutMs: 1500), let local = Relay.shared.open(c) {
                if let d = devs.first(where: { $0.serial == local }), d.state != "device" { _ = adb(nil, ["disconnect", local], timeout: 5) }
                let r2 = adb(nil, ["connect", local], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
                logLine("discovery: through the relay \(local) -> \(c): \(r2)")
            }
        }
    }
}
