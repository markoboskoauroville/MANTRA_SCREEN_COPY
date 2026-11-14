import AppKit
import AVFoundation

/// Mac microphone to the phone (v22, Marko 14.11.2026, for TTT). Contract:
/// TCP 127.0.0.1:8879; client line "TTT-MIC 1 <rate>\n"; answer "OK <rate> 1 s16le\n", then raw PCM mono s16le in ~20 ms chunks.
/// Bad line: "ERR <reason>\n". No microphone permission: "ERR mic-permission\n".
/// The microphone (default input device, never changed) is open only while a client is connected.
final class MicLink {
    static let shared = MicLink()
    static let port: UInt16 = 8879

    final class Client {
        let fd: Int32; let rate: Double; let id: Int
        var bytes: Int = 0
        var intervalBytes: Int = 0
        init(fd: Int32, rate: Double, id: Int) { self.fd = fd; self.rate = rate; self.id = id }
    }

    private let lock = NSLock()
    private var clients: [Client] = []
    private var nextId = 1
    private var engine: AVAudioEngine?
    private var converters: [Double: AVAudioConverter] = [:]
    private var inFormat: AVAudioFormat?
    private var monoBuf: AVAudioPCMBuffer?
    private var stopWork: DispatchWorkItem?
    private var reversed = Set<String>()
    private var listenFd: Int32 = -1
    private var statsTimer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "miclink.engine")

    static func allowed() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    // MARK: listener
    func start() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { logLine("miclink: socket failed"); return }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = MicLink.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if b != 0 || listen(fd, 8) != 0 { logLine("miclink: cannot listen on 127.0.0.1:\(MicLink.port) (errno \(errno))"); close(fd); return }
        listenFd = fd
        logLine("miclink: listening on 127.0.0.1:\(MicLink.port)")
        Thread.detachNewThread { [weak self] in
            while let s = self {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; break }
                Thread.detachNewThread { s.handle(c) }
            }
        }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.logStats() }
        t.resume(); statsTimer = t
    }

    private func readLine(_ fd: Int32) -> String? {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var out = [UInt8](); var b: UInt8 = 0
        while out.count < 100 {
            let n = recv(fd, &b, 1, 0)
            if n <= 0 { return nil }
            if b == 10 { return String(decoding: out, as: UTF8.self) }
            out.append(b)
        }
        return nil
    }

    private func sendAll(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Bool {
        var off = 0
        while off < n {
            let r = send(fd, p + off, n - off, 0)
            if r <= 0 { return false }
            off += r
        }
        return true
    }
    private func reply(_ fd: Int32, _ s: String) { let d = Array(s.utf8); _ = d.withUnsafeBytes { sendAll(fd, $0.baseAddress!, d.count) } }

    private func handle(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        guard let line = readLine(fd) else { logLine("miclink: client without a handshake line"); close(fd); return }
        let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard parts.count == 3, parts[0] == "TTT-MIC", parts[1] == "1", let r = Int(parts[2]), r >= 8000, r <= 96000 else {
            logLine("miclink: bad handshake '\(line)'")
            reply(fd, "ERR bad-handshake\n"); close(fd); return
        }
        guard MicLink.allowed() else {
            logLine("miclink: client refused, microphone permission missing")
            reply(fd, "ERR mic-permission\n"); close(fd); return
        }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        reply(fd, "OK \(r) 1 s16le\n")
        let c = add(fd: fd, rate: Double(r))
        logLine("miclink: client #\(c.id) connected, \(r) Hz (clients now \(count()))")
        // wait for the client to go: it sends nothing more, recv returns 0 on close
        var tv0 = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv0, socklen_t(MemoryLayout<timeval>.size))
        var b: UInt8 = 0
        while true { let n = recv(fd, &b, 1, 0); if n == 0 || (n < 0 && errno != EINTR) { break } }
        remove(c)
        logLine("miclink: client #\(c.id) disconnected after \(c.bytes) bytes (clients now \(count()))")
    }

    private func count() -> Int { lock.lock(); defer { lock.unlock() }; return clients.count }

    private func add(fd: Int32, rate: Double) -> Client {
        lock.lock()
        let c = Client(fd: fd, rate: rate, id: nextId); nextId += 1
        clients.append(c)
        stopWork?.cancel(); stopWork = nil
        let first = clients.count == 1
        lock.unlock()
        if first || engine == nil { q.async { self.startEngine() } }
        else { q.async { self.ensureConverter(rate) } }
        return c
    }

    private func remove(_ c: Client) {
        lock.lock()
        clients.removeAll { $0 === c }
        let empty = clients.isEmpty
        if empty {
            let w = DispatchWorkItem { [weak self] in self?.stopEngineIfIdle() }
            stopWork = w
            q.asyncAfter(deadline: .now() + 0.5, execute: w)
        }
        lock.unlock()
        close(c.fd)
    }

    private func logStats() {
        lock.lock(); let cs = clients; lock.unlock()
        for c in cs { logLine("miclink: client #\(c.id) \(Int(c.rate)) Hz, \(c.intervalBytes) bytes in 5 s, \(c.bytes) total"); c.intervalBytes = 0 }
    }

    // MARK: engine
    private func startEngine() {
        lock.lock(); let n = clients.count; lock.unlock()
        if n == 0 || engine != nil { return }
        let e = AVAudioEngine()
        let input = e.inputNode
        let f = input.outputFormat(forBus: 0)
        guard f.sampleRate > 0, f.channelCount > 0 else { logLine("miclink: default input has no format"); return }
        inFormat = f
        converters = [:]
        monoBuf = nil
        lock.lock(); let rates = Set(clients.map { $0.rate }); lock.unlock()
        for r in rates { ensureConverter(r) }
        input.installTap(onBus: 0, bufferSize: 1024, format: f) { [weak self] buf, _ in self?.onBuffer(buf) }
        do { try e.start(); engine = e; logLine("miclink: microphone open (default input, \(Int(f.sampleRate)) Hz, \(f.channelCount) ch)") }
        catch { logLine("miclink: engine start failed \(error)"); input.removeTap(onBus: 0) }
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .AVAudioEngineConfigurationChange, object: e)
    }

    @objc private func configChanged() {
        q.async {
            guard let e = self.engine else { return }
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: e)
            e.inputNode.removeTap(onBus: 0); e.stop(); self.engine = nil
            logLine("miclink: input device changed, reopening")
            self.startEngine()
        }
    }

    private func stopEngineIfIdle() {
        lock.lock(); let n = clients.count; lock.unlock()
        guard n == 0, let e = engine else { return }
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: e)
        e.inputNode.removeTap(onBus: 0); e.stop(); engine = nil
        lock.lock(); converters = [:]; lock.unlock()
        logLine("miclink: microphone closed (no client)")
    }

    private func ensureConverter(_ rate: Double) {
        guard let f = inFormat else { return }
        lock.lock(); defer { lock.unlock() }
        if converters[rate] != nil { return }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate, channels: 1, interleaved: false),
              let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
              let cv = AVAudioConverter(from: mono, to: out) else { logLine("miclink: no converter for \(Int(rate)) Hz"); return }
        converters[rate] = cv
    }

    private func onBuffer(_ buf: AVAudioPCMBuffer) {
        guard let f = inFormat, let src = buf.floatChannelData else { return }
        let frames = Int(buf.frameLength)
        if frames == 0 { return }
        if monoBuf == nil || Int(monoBuf!.frameCapacity) < frames {
            guard let mf = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.sampleRate, channels: 1, interleaved: false) else { return }
            monoBuf = AVAudioPCMBuffer(pcmFormat: mf, frameCapacity: AVAudioFrameCount(max(frames, 4096)))
        }
        guard let mb = monoBuf, let dst = mb.floatChannelData?[0] else { return }
        let ch = Int(buf.format.channelCount)
        if ch == 1 { dst.update(from: src[0], count: frames) }
        else {
            for i in 0..<frames { var s: Float = 0; for c in 0..<ch { s += src[c][i] }; dst[i] = s / Float(ch) }
        }
        mb.frameLength = AVAudioFrameCount(frames)
        lock.lock(); let cs = clients; let cvs = converters; lock.unlock()
        var done = Set<Double>()
        for c in cs {
            if !done.contains(c.rate) { done.insert(c.rate) }
        }
        var pcm: [Double: Data] = [:]
        for r in done {
            guard let cv = cvs[r], let outF = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: r, channels: 1, interleaved: true) else { continue }
            let cap = AVAudioFrameCount(Double(frames) * r / f.sampleRate + 64)
            guard let ob = AVAudioPCMBuffer(pcmFormat: outF, frameCapacity: cap) else { continue }
            var fed = false
            var err: NSError?
            cv.convert(to: ob, error: &err) { _, st in
                if fed { st.pointee = .noDataNow; return nil }
                fed = true; st.pointee = .haveData; return mb
            }
            if err != nil || ob.frameLength == 0 { continue }
            pcm[r] = Data(bytes: ob.int16ChannelData![0], count: Int(ob.frameLength) * 2)
        }
        for c in cs {
            guard let d = pcm[c.rate] else { continue }
            let ok = d.withUnsafeBytes { sendAll(c.fd, $0.baseAddress!, d.count) }
            if ok { c.bytes += d.count; c.intervalBytes += d.count }
            else { Darwin.shutdown(c.fd, SHUT_RDWR) }      // the client's thread sees the close and removes it
        }
    }

    // MARK: adb reverse
    func applyReverse(_ serial: String) {
        let out = adb(serial, ["reverse", "tcp:\(MicLink.port)", "tcp:\(MicLink.port)"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); reversed.insert(serial); lock.unlock()
        logLine("miclink: reverse applied on \(serial) (\(out.isEmpty ? "ok" : out))")
    }
    func removeAllReverse() {
        lock.lock(); let all = reversed; reversed = []; lock.unlock()
        let g = DispatchGroup()
        for s in all {
            g.enter()
            DispatchQueue.global().async {
                _ = adb(s, ["reverse", "--remove", "tcp:\(MicLink.port)"], timeout: 5)
                logLine("miclink: reverse removed on \(s)"); g.leave()
            }
        }
        _ = g.wait(timeout: .now() + 6)
    }
}

/// PERMISSIONS (amber, top right) while the microphone is not allowed. A click checks again, asks once, opens the Microphone page.
enum MicPermission {
    static func clicked() {
        let st = AVCaptureDevice.authorizationStatus(for: .audio)
        if st == .authorized { return }
        if st == .notDetermined { AVCaptureDevice.requestAccess(for: .audio) { _ in } }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }
}
