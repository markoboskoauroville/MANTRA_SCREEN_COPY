import Foundation
import AVFoundation

/// One shared engine plays every phone's sound through the Mac's current output. Each tab has its own player node
/// (own volume and mute). Phone audio arrives as raw 16-bit 48 kHz stereo (scrcpy audio_codec=raw), so nothing is decoded.
final class AudioHub {
    static let shared = AudioHub()
    let engine = AVAudioEngine()
    let queue = DispatchQueue(label: "audio.hub")
    var started = false
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!

    func attach(_ node: AVAudioNode) {
        queue.sync {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            if !started || !engine.isRunning {
                do { try engine.start(); started = true } catch { logLine("audio engine start failed: \(error)") }
            }
        }
    }
    func detach(_ node: AVAudioNode) {
        queue.sync { engine.detach(node) }
    }
}

func writeWav16(_ path: String, rate: Int, channels: Int, pcm: [Int16]) {
    var h = Data()
    func u32(_ v: Int) { var x = UInt32(v).littleEndian; h.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: Int) { var x = UInt16(v).littleEndian; h.append(Data(bytes: &x, count: 2)) }
    let bytes = pcm.count * 2
    h.append("RIFF".data(using: .ascii)!); u32(36 + bytes); h.append("WAVEfmt ".data(using: .ascii)!)
    u32(16); u16(1); u16(channels); u32(rate); u32(rate * channels * 2); u16(channels * 2); u16(16)
    h.append("data".data(using: .ascii)!); u32(bytes)
    h.append(pcm.withUnsafeBytes { Data($0) })
    try? h.write(to: URL(fileURLWithPath: path))
}

/// One phone's sound: a jitter buffer in front of the player (v24). Packets are queued; the player (a source node) starts when
/// `target` ms are queued, on an underrun it plays silence (no click) and primes again, and the target grows by 50 ms per
/// underrun up to 400 ms (back down by 25 ms after 30 s without one, never below 150 ms). More than target + 300 ms queued
/// (a burst after a stall) is trimmed to target + 100 ms so the sound stays live; never more than 2 s are held.
final class AudioOut {
    private let lock = NSLock()
    private let cap = 96000
    private var ringL = [Float](repeating: 0, count: 96000), ringR = [Float](repeating: 0, count: 96000)
    private var head = 0, count = 0
    private var primed = false
    private var fadeIn = 0
    private(set) var targetFrames = 7200            // 150 ms
    private var fixedTarget = 0                      // test hook: screencopy://jitter/<ms>, 0 = adaptive
    private var lastUnderrun = Date.distantPast, lastDecay = Date()
    private var lastArrival = Date.distantPast
    // measurements
    private var maxGapMs = 0.0, underruns = 0, totalUnderruns = 0, trims = 0
    private var depthSum = 0.0, depthN = 0, depthMin = Int.max
    // capture hook
    private var recIn: [Int16] = [], recOut: [Int16] = [], recUntil = Date.distantPast, recFrames = 0

    var enabled = true { didSet { if !enabled && oldValue { silence() } } }
    var muted = false
    var volume: Float = 1.0
    private(set) var levelDb: Double = -120
    private(set) var packets = 0
    private var attached = false
    private lazy var src = AVAudioSourceNode(format: AudioHub.shared.format) { [weak self] _, _, frames, abl in
        self?.render(Int(frames), abl); return noErr
    }

    func apply() {}       // gain is applied in render()

    func setFixedTarget(ms: Int) {
        lock.lock(); fixedTarget = ms; if ms > 0 { targetFrames = ms * 48 } else { targetFrames = 7200 }; lock.unlock()
        logLine("audio: jitter target \(ms > 0 ? "fixed \(ms) ms" : "adaptive from 150 ms")")
    }

    func startRecording(seconds: Int) {
        lock.lock(); recIn = []; recOut = []; recIn.reserveCapacity(seconds * 96000 + 96000); recOut.reserveCapacity(seconds * 96000 + 96000)
        recUntil = Date().addingTimeInterval(Double(seconds)); lock.unlock()
        logLine("audio: recording \(seconds) s of the phone audio (as received and as played)")
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(seconds) + 0.3) { [weak self] in self?.finishRecording() }
    }
    private func finishRecording() {
        lock.lock(); let a = recIn, b = recOut; recUntil = .distantPast; recIn = []; recOut = []; lock.unlock()
        let d = NSHomeDirectory() + "/Library/Logs/"
        writeWav16(d + "ScreenCopyPhoneAudio.wav", rate: 48000, channels: 2, pcm: a)
        writeWav16(d + "ScreenCopyPhoneAudioPlayed.wav", rate: 48000, channels: 2, pcm: b)
        logLine("audio: wrote ScreenCopyPhoneAudio.wav (received, \(a.count / 96000) s) and ScreenCopyPhoneAudioPlayed.wav (played, \(b.count / 96000) s)")
    }

    func feed(_ bytes: [UInt8]) {
        let frames = bytes.count / 4
        if frames == 0 { return }
        if !attached { AudioHub.shared.attach(src); attached = true }
        var l = [Float](repeating: 0, count: frames), r = [Float](repeating: 0, count: frames)
        var sum: Double = 0
        bytes.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let a = Float(Int16(littleEndian: s[2 * i])) / 32768
                let b = Float(Int16(littleEndian: s[2 * i + 1])) / 32768
                l[i] = a; r[i] = b
                sum += Double(a * a + b * b)
            }
        }
        let rms = (sum / Double(frames * 2)).squareRoot()
        let db = rms > 0.000001 ? 20 * log10(rms) : -120
        levelDb = max(db, levelDb - 3)           // quick rise, slow fall
        packets += 1
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        if lastArrival != .distantPast { maxGapMs = max(maxGapMs, now.timeIntervalSince(lastArrival) * 1000) }
        lastArrival = now
        if now < recUntil { bytes.withUnsafeBytes { raw in let s = raw.bindMemory(to: Int16.self); recIn.append(contentsOf: s.prefix(frames * 2)) } }
        if !enabled { return }
        // never more than cap; a burst after a stall is trimmed so the sound stays live
        let live = targetFrames + 14400
        if count + frames > live && primed {
            let keep = targetFrames + 4800
            let drop = max(0, count + frames - keep)
            let d = min(drop, count); head = (head + d) % cap; count -= d; trims += 1
        }
        if count + frames > cap { let d = count + frames - cap; head = (head + d) % cap; count -= d }
        var w = (head + count) % cap
        for i in 0..<frames { ringL[w] = l[i]; ringR[w] = r[i]; w += 1; if w == cap { w = 0 } }
        count += frames
        if !primed && count >= targetFrames { primed = true; fadeIn = 192 }
        if fixedTarget == 0, primed, now.timeIntervalSince(lastUnderrun) > 30, now.timeIntervalSince(lastDecay) > 30, targetFrames > 7200 {
            targetFrames -= 1200; lastDecay = now
        }
    }

    private func render(_ frames: Int, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        guard bufs.count >= 2, let pl = bufs[0].mData?.assumingMemoryBound(to: Float.self), let pr = bufs[1].mData?.assumingMemoryBound(to: Float.self) else { return }
        let gain: Float = muted ? 0 : volume
        lock.lock()
        var n = 0
        if primed {
            n = min(frames, count)
            var rd = head
            for i in 0..<n {
                var g = gain
                if fadeIn > 0 { g *= 1 - Float(fadeIn) / 192; fadeIn -= 1 }
                pl[i] = ringL[rd] * g; pr[i] = ringR[rd] * g
                rd += 1; if rd == cap { rd = 0 }
            }
            head = rd; count -= n
            if n < frames {
                primed = false; underruns += 1; totalUnderruns += 1; lastUnderrun = Date()
                if fixedTarget == 0 { targetFrames = min(19200, targetFrames + 2400) }
            }
            depthSum += Double(count + n) / 48; depthN += 1; depthMin = min(depthMin, count + n)
        }
        if n < frames { for i in n..<frames { pl[i] = 0; pr[i] = 0 } }
        if Date() < recUntil { for i in 0..<frames { recOut.append(Int16(max(-1, min(1, pl[i])) * 32767)); recOut.append(Int16(max(-1, min(1, pr[i])) * 32767)) } }
        lock.unlock()
    }

    /// One line for the 5 s log, then the interval counters start again.
    func statsLine() -> String {
        lock.lock(); defer { lock.unlock() }
        let avg = depthN > 0 ? Int(depthSum / Double(depthN)) : 0
        let mn = depthMin == Int.max ? 0 : depthMin / 48
        let s = "jitter: underruns \(underruns) (total \(totalUnderruns)) max gap \(Int(maxGapMs)) ms depth avg \(avg) min \(mn) ms target \(targetFrames / 48) ms trims \(trims)"
        maxGapMs = 0; underruns = 0; trims = 0; depthSum = 0; depthN = 0; depthMin = Int.max
        return s
    }

    func silence() {
        lock.lock(); primed = false; count = 0; head = 0; lock.unlock()
    }
    func close() { if attached { AudioHub.shared.detach(src); attached = false } }
}
