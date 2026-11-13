import Foundation
import AVFoundation
import CoreMedia
import VideoToolbox
import Darwin

/// One phone: pushes the scrcpy server (bundled, version 4.1), opens its three sockets over an adb forward
/// (video, audio, control), shows the video in an AVSampleBufferDisplayLayer (hardware H.264 decode),
/// plays the sound through AudioOut and sends touches/keys back. Runs in the background whether or not its tab is shown.
final class Session {
    let phoneId: String
    private(set) var serial = ""                 // the route (adb address) in use now
    var forced: String?                           // a route chosen by hand
    private let routes: () -> [String]
    let layer = AVSampleBufferDisplayLayer()
    let audio = AudioOut()
    var onChange: (() -> Void)?                // status or size changed (called on the main queue)
    private(set) var status = "CONNECTING"
    private(set) var width = 0
    private(set) var height = 0
    private(set) var deviceName = ""
    private(set) var audioState = "AUDIO OFF"
    private(set) var framesTotal = 0
    private(set) var lastFrameAt = Date.distantPast
    private(set) var fps = 0
    private var fpsCount = 0
    private var fpsStart = Date()
    private var running = false
    private var cfd: Int32 = -1
    private var vfd: Int32 = -1
    private var afd: Int32 = -1
    private var shell: Process?
    private var shellLog = ""
    private let ctlLock = NSLock()
    private var sps: [UInt8] = [], pps: [UInt8] = []
    private var fmt: CMVideoFormatDescription?
    private var touchDown = false
    var clipboardSeq: UInt64 = 1
    /// false (default): the phone stays silent, its sound goes only to the Mac (audio_source=playback, no audio_dup).
    var phoneSpeaks = false

    init(phoneId: String, routes: @escaping () -> [String]) {
        self.phoneId = phoneId
        self.routes = routes
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = NSColorBlack
    }

    func start() {
        running = true
        Thread.detachNewThread { [weak self] in self?.loop() }
    }

    /// Restart the stream (used when "also play on the phone" is switched).
    func reconnect() {
        for fd in [vfd, afd, cfd] where fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        if let sh = shell, sh.isRunning { sh.terminate() }
    }

    func stop() {
        running = false
        teardown()
        audio.close()
    }

    private func set(_ s: String) {
        status = s
        DispatchQueue.main.async { self.onChange?() }
    }

    // MARK: connect loop
    private func loop() {
        while running {
            let rs = forced.map { [$0] } ?? routes()
            if rs.isEmpty { set("SEARCHING"); for _ in 0..<10 where running { usleep(100_000) }; continue }
            var was = false
            for r in rs where running {
                serial = r
                set("CONNECTING")
                let ok = connectOnce()
                teardown()
                if ok { was = true; break }          // it had been live and dropped: begin again from the best route
            }
            if !running { break }
            set(was ? "RECONNECTING" : "NOT REACHABLE")
            for _ in 0..<15 where running { usleep(100_000) }
        }
    }

    private func teardown() {
        for fd in [vfd, afd, cfd] where fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR); close(fd) }
        vfd = -1; afd = -1; cfd = -1
        if let sh = shell, sh.isRunning { sh.terminate() }
        shell = nil
        audio.silence()
    }

    private func connectSocket(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { return -1 }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, 4)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if r != 0 { close(fd); return -1 }
        return fd
    }

    private func setTimeout(_ fd: Int32, _ sec: Int) {
        var tv = timeval(tv_sec: sec, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func readFully(_ fd: Int32, _ n: Int) -> [UInt8]? {
        if n == 0 { return [] }
        var buf = [UInt8](repeating: 0, count: n)
        var got = 0
        while got < n {
            let r = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, n - got) }
            if r <= 0 { return nil }
            got += r
        }
        return buf
    }

    /// Returns true when it had been connected (so a later retry is a RECONNECT), false when it never got there.
    private func connectOnce() -> Bool {
        if serial.contains(":") { _ = adb(nil, ["connect", serial], timeout: 8) }
        let state = adb(serial, ["get-state"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
        if state != "device" { logLine("\(serial): state '\(state)'"); return false }
        let remote = "/data/local/tmp/scrcpy-server-mantra.jar"
        let pushed = adb(serial, ["push", serverJarPath(), remote], timeout: 30)
        if !pushed.contains("pushed") && !pushed.contains("1 file") { logLine("\(serial): push: \(pushed)"); return false }
        let scid = UInt32.random(in: 1..<0x7fffffff)
        let scidHex = String(format: "%08x", scid)
        let fwd = adb(serial, ["forward", "tcp:0", "localabstract:scrcpy_\(scidHex)"], timeout: 10).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(fwd) else { logLine("\(serial): forward: \(fwd)"); return false }

        let sh = Process()
        sh.executableURL = URL(fileURLWithPath: ADB)
        let opts = "scid=\(scidHex) log_level=info tunnel_forward=true video=true audio=true control=true video_codec=h264 audio_codec=raw audio_source=playback\(phoneSpeaks ? " audio_dup=true" : "") max_size=1920 video_bit_rate=8000000 max_fps=60"
        sh.arguments = ["-s", serial, "shell", "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server 4.1 \(opts)"]
        let pipe = Pipe()
        sh.standardOutput = pipe; sh.standardError = pipe
        shellLog = ""
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            if let s = String(data: d, encoding: .utf8) { self?.shellLog += s; logLine("\(self?.serial ?? "?") server: \(s.trimmingCharacters(in: .whitespacesAndNewlines))") }
        }
        do { try sh.run() } catch { logLine("shell: \(error)"); return false }
        shell = sh

        // video socket first (it carries the dummy byte), then audio, then control
        var v: Int32 = -1
        for _ in 0..<80 where running {
            let fd = connectSocket(port)
            if fd >= 0 {
                setTimeout(fd, 2)
                if let b = readFully(fd, 1), b.count == 1 { v = fd; break }
                close(fd)
            }
            usleep(100_000)
        }
        if v < 0 { logLine("\(serial): no video socket. server log: \(shellLog)"); return false }
        vfd = v
        let a = connectSocket(port); afd = a
        let c = connectSocket(port); cfd = c
        if a < 0 || c < 0 { logLine("\(serial): audio/control socket failed"); return false }
        setTimeout(v, 10); setTimeout(a, 10)
        guard let meta = readFully(v, 64) else { logLine("\(serial): no device meta. \(shellLog)"); return false }
        deviceName = String(decoding: meta.prefix(while: { $0 != 0 }), as: UTF8.self)
        guard let cid = readFully(v, 4) else { logLine("\(serial): no codec id"); return false }
        logLine("\(serial): connected '\(deviceName)' video codec \(String(format: "%08x", be32(cid, 0)))")
        setTimeout(v, 0)
        set("LIVE")
        Thread.detachNewThread { [weak self] in self?.audioLoop(a) }
        Thread.detachNewThread { [weak self] in self?.controlReader(c) }
        videoLoop(v)
        return true
    }

    private func be32(_ b: [UInt8], _ o: Int) -> UInt32 {
        (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16) | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    // MARK: video
    private func videoLoop(_ fd: Int32) {
        while running {
            guard let h = readFully(fd, 12) else { return }
            if h[0] & 0x80 != 0 {                       // session packet: new size (start, rotation)
                width = Int(be32(h, 4)); height = Int(be32(h, 8))
                DispatchQueue.main.async { self.onChange?() }
                continue
            }
            let flags = h[0]
            let size = Int(be32(h, 8))
            guard size >= 0, size < 20_000_000, let payload = readFully(fd, size) else { return }
            let pts = (Int64(flags & 0x1f) << 56) | (Int64(h[1]) << 48) | (Int64(h[2]) << 40) | (Int64(h[3]) << 32) | (Int64(h[4]) << 24) | (Int64(h[5]) << 16) | (Int64(h[6]) << 8) | Int64(h[7])
            handleVideo(payload, pts: pts)
        }
    }

    private func splitNals(_ d: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(Int, Int)] = []       // (index of start code, length of start code)
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0 && d[i + 1] == 0 {
                if d[i + 2] == 1 { starts.append((i, 3)); i += 3; continue }
                if i + 4 <= d.count && d[i + 2] == 0 && d[i + 3] == 1 { starts.append((i, 4)); i += 4; continue }
            }
            i += 1
        }
        var r: [ArraySlice<UInt8>] = []
        for (k, s) in starts.enumerated() {
            let begin = s.0 + s.1
            let end = k + 1 < starts.count ? starts[k + 1].0 : d.count
            if end > begin { r.append(d[begin..<end]) }
        }
        return r
    }

    private func handleVideo(_ d: [UInt8], pts: Int64) {
        var vcl: [ArraySlice<UInt8>] = []
        var newParams = false
        for n in splitNals(d) {
            switch n.first! & 0x1f {
            case 7: let x = Array(n); if x != sps { sps = x; newParams = true }
            case 8: let x = Array(n); if x != pps { pps = x; newParams = true }
            case 9, 6: break
            default: vcl.append(n)
            }
        }
        if newParams && !sps.isEmpty && !pps.isEmpty { makeFormat() }
        guard !vcl.isEmpty, let f = fmt else { return }
        var avcc: [UInt8] = []
        for n in vcl {
            let l = UInt32(n.count)
            avcc += [UInt8(l >> 24), UInt8((l >> 16) & 255), UInt8((l >> 8) & 255), UInt8(l & 255)]
            avcc += n
        }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == kCMBlockBufferNoErr, let blk = block else { return }
        _ = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blk, offsetIntoDestination: 0, dataLength: avcc.count) }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000), decodeTimeStamp: .invalid)
        var sizeArr = avcc.count
        var sb: CMSampleBuffer?
        guard CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: blk, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: f, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &sizeArr, sampleBufferOut: &sb) == noErr, let sample = sb else { return }
        if let att = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(att) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(att, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(), Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush(); sendResetVideo() }
        layer.enqueue(sample)
        framesTotal += 1; fpsCount += 1
        lastFrameAt = Date()
        if Date().timeIntervalSince(fpsStart) >= 1 {
            fps = fpsCount; fpsCount = 0; fpsStart = Date()
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    private func makeFormat() {
        var out: CMVideoFormatDescription?
        let st: OSStatus = sps.withUnsafeBufferPointer { sp in pps.withUnsafeBufferPointer { pp in
            let ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
            let sizes = [sps.count, pps.count]
            return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: 2, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &out)
        } }
        if st == noErr { fmt = out } else { logLine("\(serial): format description failed \(st)") }
    }

    // MARK: audio
    private func audioLoop(_ fd: Int32) {
        guard let cid = readFully(fd, 4) else { audioState = "AUDIO OFF"; return }
        let id = be32(cid, 0)
        if id == 0 { audioState = "AUDIO OFF (phone refused)"; logLine("\(serial): audio disabled by server"); return }
        if id == 1 { audioState = "AUDIO ERROR"; logLine("\(serial): audio configuration error. \(shellLog)"); return }
        if id != 0x00726177 { audioState = "AUDIO CODEC?"; logLine("\(serial): unexpected audio codec \(String(format: "%08x", id))"); return }
        audioState = "AUDIO ON"
        setTimeout(fd, 0)
        while running {
            guard let h = readFully(fd, 12) else { audioState = "AUDIO OFF"; return }
            let size = Int(be32(h, 8))
            guard size >= 0, size < 4_000_000, let p = readFully(fd, size) else { audioState = "AUDIO OFF"; return }
            if h[0] & 0x40 != 0 { continue }          // config packet (none for raw)
            audio.feed(p)
        }
    }

    // MARK: control
    private func controlReader(_ fd: Int32) {
        while running {
            guard let t = readFully(fd, 1) else { return }
            switch t[0] {
            case 0: guard let l = readFully(fd, 4), readFully(fd, Int(be32(l, 0))) != nil else { return }   // clipboard from phone (not used)
            case 1: guard readFully(fd, 8) != nil else { return }
            case 2: guard let h = readFully(fd, 4), readFully(fd, Int(h[2]) << 8 | Int(h[3])) != nil else { return }
            default: return
            }
        }
    }

    private func send(_ bytes: [UInt8]) {
        ctlLock.lock(); defer { ctlLock.unlock() }
        let fd = cfd
        if fd < 0 { return }
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
    }

    private func put32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
    private func put16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 255)] }

    func sendResetVideo() { send([17]) }

    func key(_ keycode: UInt32, meta: UInt32 = 0) {
        send([0, 0] + put32(keycode) + put32(0) + put32(meta))      // down
        send([0, 1] + put32(keycode) + put32(0) + put32(meta))      // up
    }

    func text(_ s: String) {
        let u = Array(s.utf8)
        if u.isEmpty || u.count > 300 { return }
        send([1] + put32(UInt32(u.count)) + u)
    }

    func paste(_ s: String) {
        let u = Array(s.utf8)
        clipboardSeq += 1
        send([9] + [0, 0, 0, 0] + put32(UInt32(clipboardSeq)) + [1] + put32(UInt32(u.count)) + u)
    }

    /// action 0 down, 1 up, 2 move. x, y in video pixels.
    func touch(action: UInt8, x: Int, y: Int) {
        if width == 0 { return }
        let pressure: UInt16 = action == 1 ? 0 : 0xffff
        let btn: UInt32 = action == 1 ? 0 : 1
        let actionButton: UInt32 = action == 2 ? 0 : 1
        let msg: [UInt8] = [2, action] + [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff]
            + put32(UInt32(max(0, min(width - 1, x)))) + put32(UInt32(max(0, min(height - 1, y))))
            + put16(UInt16(width)) + put16(UInt16(height)) + put16(pressure) + put32(actionButton) + put32(btn)
        send(msg)
    }

    func scroll(x: Int, y: Int, h: Double, v: Double) {
        if width == 0 { return }
        func fix(_ d: Double) -> UInt16 { UInt16(bitPattern: Int16(max(-1, min(1, d / 16)) * 32767)) }
        send([3] + put32(UInt32(max(0, min(width - 1, x)))) + put32(UInt32(max(0, min(height - 1, y))))
             + put16(UInt16(width)) + put16(UInt16(height)) + put16(fix(h)) + put16(fix(v)) + put32(0))
    }
}

let NSColorBlack = CGColor(gray: 0, alpha: 1)
