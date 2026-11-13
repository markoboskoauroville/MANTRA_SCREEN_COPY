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

    func attach(_ node: AVAudioPlayerNode) {
        queue.sync {
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            if !started || !engine.isRunning {
                do { try engine.start(); started = true } catch { logLine("audio engine start failed: \(error)") }
            }
        }
    }
    func detach(_ node: AVAudioPlayerNode) {
        queue.sync { node.stop(); engine.detach(node) }
    }
}

final class AudioOut {
    let node = AVAudioPlayerNode()
    private let lock = NSLock()
    private var pending = 0
    var enabled = true          // false: the tab is not the one being listened to
    var muted = false { didSet { apply() } }
    var volume: Float = 1.0 { didSet { apply() } }
    private(set) var levelDb: Double = -120
    private(set) var packets = 0
    private var attached = false

    func apply() { node.volume = muted ? 0 : volume }

    func feed(_ bytes: [UInt8]) {
        let frames = bytes.count / 4
        if frames == 0 { return }
        if !attached { AudioHub.shared.attach(node); attached = true; apply() }
        guard let buf = AVAudioPCMBuffer(pcmFormat: AudioHub.shared.format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
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
        if !enabled { return }
        lock.lock()
        if pending > 12000 { lock.unlock(); return }      // more than 250 ms queued: drop, stay live
        pending += frames
        let now = pending
        lock.unlock()
        node.scheduleBuffer(buf, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            guard let self = self else { return }
            self.lock.lock(); self.pending = max(0, self.pending - frames); self.lock.unlock()
        }
        if !node.isPlaying && now >= 2400 { node.play() }     // 50 ms cushion before starting
    }

    func silence() {
        if attached { node.stop() }
        lock.lock(); pending = 0; lock.unlock()
    }
    func close() { if attached { AudioHub.shared.detach(node); attached = false } }
}
