import Foundation
import Darwin

/// The way to a phone on Wi-Fi when the adb server cannot reach it.
///
/// macOS Local Network privacy (Sequoia) blocks LAN connections of a process that has no permission, with "No route to host".
/// The shared adb server is started by whichever app runs adb first (14.11.2026: one started at login, orphaned, pid 680), so
/// it inherits that app's permission, not ours: `adb connect 192.168.1.101:5555` failed while this app's own port scan reached
/// the Pixel. This app has the permission, so it opens a relay on 127.0.0.1 and lets adb connect to that: loopback is never
/// blocked, and the shared adb server keeps running for everyone else (Connection Keeper's phone lines need it).
final class Relay {
    static let shared = Relay()
    private let lock = NSLock()
    private var byTarget: [String: Int] = [:]        // "192.168.1.101:5555" -> local port
    private var byPort: [Int: String] = [:]

    /// The real address behind a serial like "127.0.0.1:53211", or nil when it is not one of ours.
    func target(of serial: String) -> String? {
        guard serial.hasPrefix("127.0.0.1:"), let p = Int(serial.split(separator: ":").last ?? "") else { return nil }
        lock.lock(); defer { lock.unlock() }
        return byPort[p]
    }

    /// Returns the local serial ("127.0.0.1:<port>") that leads to `target`, opening the relay the first time.
    func open(_ target: String) -> String? {
        lock.lock()
        if let p = byTarget[target] { lock.unlock(); return "127.0.0.1:\(p)" }
        lock.unlock()
        let parts = target.split(separator: ":")
        guard parts.count == 2, let tport = Int(parts[1]) else { return nil }
        let host = String(parts[0])

        let ls = socket(AF_INET, SOCK_STREAM, 0)
        if ls < 0 { return nil }
        var one: Int32 = 1
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(ls, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if b != 0 || listen(ls, 8) != 0 { close(ls); return nil }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(ls, $0, &len) } }
        let port = Int(UInt16(bigEndian: got.sin_port))

        lock.lock(); byTarget[target] = port; byPort[port] = target; lock.unlock()
        logLine("relay: 127.0.0.1:\(port) -> \(target) (the adb server has no Local Network permission)")
        Thread.detachNewThread {
            while true {
                let c = accept(ls, nil, nil)
                if c < 0 { usleep(200_000); continue }
                Thread.detachNewThread { Relay.bridge(c, host, tport) }
            }
        }
        return "127.0.0.1:\(port)"
    }

    private static func bridge(_ c: Int32, _ host: String, _ port: Int) {
        let r = socket(AF_INET, SOCK_STREAM, 0)
        if r < 0 { close(c); return }
        var one: Int32 = 1
        for fd in [c, r] { setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4); setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) }
        var tv = timeval(tv_sec: 4, tv_usec: 0)
        setsockopt(r, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))      // connect gives up after 4 s
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let k = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(r, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if k != 0 { close(c); close(r); return }
        var tv0 = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(r, SOL_SOCKET, SO_SNDTIMEO, &tv0, socklen_t(MemoryLayout<timeval>.size))
        let done = DispatchGroup()
        for (a, z) in [(c, r), (r, c)] {
            done.enter()
            Thread.detachNewThread {
                var buf = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = buf.withUnsafeMutableBytes { read(a, $0.baseAddress!, 65536) }
                    if n <= 0 { break }
                    var off = 0
                    while off < n {
                        let w = buf.withUnsafeBytes { write(z, $0.baseAddress! + off, n - off) }
                        if w <= 0 { break }
                        off += w
                    }
                    if off < n { break }
                }
                Darwin.shutdown(z, SHUT_WR)
                done.leave()
            }
        }
        done.wait()
        close(c); close(r)
    }
}
