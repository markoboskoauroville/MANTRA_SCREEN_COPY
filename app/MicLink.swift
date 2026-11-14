import AppKit
import AVFoundation

/// Mac microphone to the phone (v22, Marko 14.11.2026, for TTT). Contract:
/// TCP 127.0.0.1:8879; client line "TTT-MIC 1 <rate>\n"; answer "OK <rate> 1 s16le\n", then raw PCM mono s16le in ~20 ms chunks.
/// Bad line: "ERR <reason>\n". No microphone permission: "ERR mic-permission\n".
/// The microphone (default input device, never changed) is open only while a client is connected.
/// v27: every phone gets its OWN listener (127.0.0.1:<port>, `adb reverse tcp:8879 tcp:<port>`), so the Mac knows which phone
/// asks, and `gate` decides: "" = yes, else the line "NO <reason>\n" and close (TTT then records with the phone mic).
/// The shared 8879 listener (a reverse left from v22-v26) always answers "NO unknown-phone".
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
    private var inFormat: AVAudioFormat?
    private var monoBuf: AVAudioPCMBuffer?
    private var stopWork: DispatchWorkItem?
    private var reversed = Set<String>()
    private var listenFd: Int32 = -1
    private var statsTimer: DispatchSourceTimer?
    private let q = DispatchQueue(label: "miclink.engine")
    var gate: ((String) -> String)?
    private var phonePorts: [String: UInt16] = [:]

    static func allowed() -> Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    // MARK: listener
    func start() {
        guard let fd = listenOn(MicLink.port, phone: nil) else { return }
        listenFd = fd
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.logStats() }
        t.resume(); statsTimer = t
    }

    /// A listener on 127.0.0.1:<port> (0 = any free port) whose clients are taken as `phone` (nil = unknown). Returns the fd.
    private func listenOn(_ port: UInt16, phone: String?) -> Int32? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { logLine("miclink: socket failed"); return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let b = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if b != 0 || listen(fd, 8) != 0 { logLine("miclink: cannot listen on 127.0.0.1:\(port) (errno \(errno))"); close(fd); return nil }
        var got = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let real = UInt16(bigEndian: got.sin_port)
        if let p = phone { lock.lock(); phonePorts[p] = real; lock.unlock() }
        let whom = phone != nil ? "for phone " + phone! : "(shared, refuses)"
        logLine("miclink: listening on 127.0.0.1:\(real) \(whom)")
        Thread.detachNewThread { [weak self] in
            while let s = self {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; break }
                Thread.detachNewThread { s.handle(c, phone: phone) }
            }
        }
        return fd
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

    private func handle(_ fd: Int32, phone: String?) {
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
        // v27: only the phone he drives from the Mac right now gets the Mac microphone
        let verdict = phone == nil ? "NO unknown-phone" : (gate?(phone!) ?? "NO no-gate")
        if !verdict.isEmpty {
            logLine("miclink: \(phone ?? "unknown phone") refused: \(verdict)")
            reply(fd, verdict + "\n"); close(fd); return
        }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        reply(fd, "OK \(r) 1 s16le\n")
        let c = add(fd: fd, rate: Double(r))
        logLine("miclink: client #\(c.id) (\(phone ?? "?")) connected, \(r) Hz, allowed: driven from the Mac (clients now \(count()))")
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
        if inN > 0 { logLine("miclink: mic input rms \(Int(10 * log10(max(1e-12, inSq / Double(inN))))) dBFS, peak \(peak)"); inSq = 0; inN = 0; peak = 0 }
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
        lock.lock(); resamplers = [:]; lock.unlock()
        monoBuf = nil; wavData = Data(); wavDone = false
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
        lock.lock(); resamplers = [:]; lock.unlock()
        logLine("miclink: microphone closed (no client)")
    }

    /// Streaming box-filter resampler (Float mono at the input rate to Float at `rate`), done by hand.
    final class Resampler {
        let ratio: Double; var pending: [Float] = []; var pos = 0.0
        init(inRate: Double, outRate: Double) { ratio = inRate / outRate }
        func process(_ x: UnsafePointer<Float>, _ n: Int) -> [Float] {
            pending.append(contentsOf: UnsafeBufferPointer(start: x, count: n))
            var out: [Float] = []
            while pos + ratio <= Double(pending.count) {
                let a = pos, b = pos + ratio
                var i = Int(a.rounded(.down)); var acc = 0.0
                while Double(i) < b {
                    let lo = max(a, Double(i)), hi = min(b, Double(i + 1))
                    acc += Double(pending[i]) * (hi - lo); i += 1
                }
                out.append(Float(acc / ratio)); pos = b
            }
            let drop = Int(pos.rounded(.down))
            if drop > 0 { pending.removeFirst(drop); pos -= Double(drop) }
            return out
        }
    }
    private var resamplers: [Double: Resampler] = [:]
    private var inSq = 0.0, inN = 0, peak: Float = 0
    private var wavData = Data(); private var wavDone = false
    private func ensureConverter(_ rate: Double) {
        guard let f = inFormat else { return }
        lock.lock(); defer { lock.unlock() }
        if resamplers[rate] == nil { resamplers[rate] = Resampler(inRate: f.sampleRate, outRate: rate) }
    }
    private func writeWav(rate: Int, pcm: Data) {
        var h = Data()
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
        h.append("RIFF".data(using: .ascii)!); u32(36 + pcm.count); h.append("WAVEfmt ".data(using: .ascii)!)
        u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        h.append("data".data(using: .ascii)!); u32(pcm.count)
        try? (h + pcm).write(to: URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/ScreenCopyMicLink.wav"))
        logLine("miclink: first 2 s of the sent audio written to ~/Library/Logs/ScreenCopyMicLink.wav")
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
        for i in 0..<frames { let v = dst[i]; inSq += Double(v * v); if abs(v) > peak { peak = abs(v) } }; inN += frames
        lock.lock(); let cs = clients; let rss = resamplers; lock.unlock()
        var pcm: [Double: Data] = [:]
        for r in Set(cs.map { $0.rate }) {
            guard let rs = rss[r] else { continue }
            let fl = rs.process(UnsafePointer(dst), frames)
            if fl.isEmpty { continue }
            var i16 = [Int16](repeating: 0, count: fl.count)
            for k in 0..<fl.count { i16[k] = Int16(max(-1, min(1, fl[k])) * 32767) }
            pcm[r] = i16.withUnsafeBytes { Data($0) }       // little-endian on this Mac
        }
        for c in cs {
            guard let d = pcm[c.rate] else { continue }
            let ok = d.withUnsafeBytes { sendAll(c.fd, $0.baseAddress!, d.count) }
            if ok {
                c.bytes += d.count; c.intervalBytes += d.count
                if !wavDone { wavData.append(d); if wavData.count >= Int(c.rate) * 4 { wavDone = true; writeWav(rate: Int(c.rate), pcm: wavData) } }
            }
            else { Darwin.shutdown(c.fd, SHUT_RDWR) }      // the client's thread sees the close and removes it
        }
    }

    // MARK: adb reverse
    func applyReverse(_ serial: String, phone: String) {
        lock.lock(); var port = phonePorts[phone]; lock.unlock()
        if port == nil { _ = listenOn(0, phone: phone); lock.lock(); port = phonePorts[phone]; lock.unlock() }
        guard let p = port else { logLine("miclink: no listener for \(phone), no reverse on \(serial)"); return }
        let out = adb(serial, ["reverse", "tcp:\(MicLink.port)", "tcp:\(p)"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); reversed.insert(serial); lock.unlock()
        logLine("miclink: reverse applied on \(serial) (8879 -> Mac \(p), phone \(phone)) (\(out.isEmpty ? "ok" : out))")
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
