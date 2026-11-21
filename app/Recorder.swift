import Foundation
import Darwin

enum RecorderState: String, Equatable {
    case idle
    case recording
    case paused
    case stopped
}

struct RecorderSnapshot {
    let state: RecorderState
    let phone: String
    let name: String
    let file: URL?
    let elapsed: Double
    let levelRMS: Double
}

final class Recorder {
    static let sampleRate = 48000
    static let channels = 2
    static let bytesPerSecond = sampleRate * channels * MemoryLayout<Int16>.size

    private let queue = DispatchQueue(label: "screen.copy.recorder")
    private let lock = NSLock()
    private var stateValue = RecorderState.idle
    private var phoneValue = ""
    private var nameValue = ""
    private var fileValue: URL?
    private var dataBytes: UInt64 = 0
    private var levelValue: Double = 0
    private var handle: FileHandle?
    private var energy: [(samples: Int, sum: Double)] = []
    private var lastPatch = Date.distantPast

    static var recordingsRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music", isDirectory: true)
            .appendingPathComponent("Screen Copy Recordings", isDirectory: true)
    }

    func snapshot() -> RecorderSnapshot {
        lock.lock()
        let result = RecorderSnapshot(
            state: stateValue,
            phone: phoneValue,
            name: nameValue,
            file: fileValue,
            elapsed: Double(dataBytes) / Double(Self.bytesPerSecond),
            levelRMS: levelValue
        )
        lock.unlock()
        return result
    }

    @discardableResult
    func start(phone: String, name: String) -> URL? {
        queue.sync {
            stopInternal()
            do {
                let base = Self.safeName(name, fallback: "Recording")
                let safePhone = Self.safeName(phone, fallback: "Phone")
                let directory = Self.recordingsRoot.appendingPathComponent(safePhone, isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard let (url, newHandle) = Self.createWav(in: directory, base: base) else { return nil }
                lock.lock()
                handle = newHandle
                phoneValue = safePhone
                nameValue = url.deletingPathExtension().lastPathComponent
                fileValue = url
                dataBytes = 0
                energy = []
                levelValue = 0
                stateValue = .recording
                lastPatch = Date()
                lock.unlock()
                logLine("recorder: started \(safePhone)/\(nameValue).wav")
                return url
            } catch {
                logLine("recorder: start failed: \(error)")
                return nil
            }
        }
    }

    func write(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else { return }
        queue.async { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let recording = self.stateValue == .recording
            let h = self.handle
            self.lock.unlock()
            guard recording, let h = h else { return }
            do {
                try h.write(contentsOf: Data(bytes))
                self.lock.lock()
                self.dataBytes += UInt64(bytes.count)
                self.addLevelSamples(bytes)
                let patchDue = Date().timeIntervalSince(self.lastPatch) >= 2
                self.lock.unlock()
                if patchDue { self.patchHeader() }
            } catch {
                logLine("recorder: write failed: \(error)")
                self.stopInternal()
            }
        }
    }

    @discardableResult
    func pause() -> Bool {
        queue.sync {
            lock.lock()
            guard stateValue == .recording else { lock.unlock(); return false }
            stateValue = .paused
            lock.unlock()
            patchHeader()
            logLine("recorder: paused \(fileValue?.lastPathComponent ?? nameValue)")
            return true
        }
    }

    @discardableResult
    func resume() -> Bool {
        queue.sync {
            lock.lock()
            guard stateValue == .paused else { lock.unlock(); return false }
            stateValue = .recording
            lastPatch = Date()
            lock.unlock()
            logLine("recorder: resumed \(fileValue?.lastPathComponent ?? nameValue)")
            return true
        }
    }

    @discardableResult
    func stop() -> Bool {
        queue.sync { stopInternal() }
    }

    @discardableResult
    func renameFinished(from sourceName: String?, to newName: String) -> URL? {
        queue.sync {
            lock.lock()
            guard stateValue == .stopped else { lock.unlock(); return nil }
            let safePhone = phoneValue
            let current = fileValue
            lock.unlock()
            guard let source = sourceURL(from: sourceName, current: current, phone: safePhone) else {
                logLine("recorder: rename source is invalid")
                return nil
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                logLine("recorder: rename source does not exist: \(source.path)")
                return nil
            }
            do {
                let base = Self.safeName(newName, fallback: "Recording")
                let destination = Self.availableURL(in: source.deletingLastPathComponent(), base: base)
                try FileManager.default.moveItem(at: source, to: destination)
                lock.lock()
                if fileValue?.standardizedFileURL == source.standardizedFileURL {
                    fileValue = destination
                    nameValue = destination.deletingPathExtension().lastPathComponent
                }
                lock.unlock()
                logLine("recorder: renamed \(source.lastPathComponent) to \(destination.lastPathComponent)")
                return destination
            } catch {
                logLine("recorder: rename failed: \(error)")
                return nil
            }
        }
    }

    private func stopInternal() -> Bool {
        lock.lock()
        let active = stateValue == .recording || stateValue == .paused
        lock.unlock()
        guard active else { return false }
        patchHeader()
        lock.lock()
        let h = handle
        handle = nil
        stateValue = .stopped
        lock.unlock()
        do { try h?.close() } catch { logLine("recorder: close failed: \(error)") }
        logLine("recorder: stopped \(fileValue?.lastPathComponent ?? nameValue)")
        return true
    }

    private func patchHeader() {
        lock.lock()
        let h = handle
        let bytes = min(dataBytes, UInt64(UInt32.max - 36))
        lock.unlock()
        guard let h = h else { return }
        do {
            try h.seek(toOffset: 4)
            try h.write(contentsOf: Self.u32(UInt32(36 + bytes)))
            try h.seek(toOffset: 40)
            try h.write(contentsOf: Self.u32(UInt32(bytes)))
            try h.seekToEnd()
            lock.lock()
            lastPatch = Date()
            lock.unlock()
        } catch {
            logLine("recorder: WAV header patch failed: \(error)")
        }
    }

    private func addLevelSamples(_ bytes: [UInt8]) {
        let completeBytes = bytes.count - bytes.count % 2
        let sampleCount = completeBytes / 2
        guard sampleCount > 0 else { return }
        let first = max(0, sampleCount - 96000)
        var sum: Double = 0
        bytes.withUnsafeBytes { raw in
            let values = raw.prefix(completeBytes).bindMemory(to: Int16.self)
            for i in first..<sampleCount {
                let value = Double(Int16(littleEndian: values[i])) / 32768
                sum += value * value
            }
        }
        energy.append((sampleCount - first, sum))
        var totalSamples = energy.reduce(0) { $0 + $1.samples }
        var excess = totalSamples - 96000
        while excess > 0, !energy.isEmpty {
            if energy[0].samples <= excess {
                excess -= energy[0].samples
                energy.removeFirst()
            } else {
                let fraction = Double(energy[0].samples - excess) / Double(energy[0].samples)
                energy[0] = (energy[0].samples - excess, energy[0].sum * fraction)
                excess = 0
            }
        }
        totalSamples = energy.reduce(0) { $0 + $1.samples }
        let totalSum = energy.reduce(0) { $0 + $1.sum }
        levelValue = totalSamples > 0 ? sqrt(totalSum / Double(totalSamples)) : 0
    }

    private func sourceURL(from name: String?, current: URL?, phone: String) -> URL? {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return current }
        let url: URL
        if name.hasPrefix("/") {
            url = URL(fileURLWithPath: name)
            let root = Self.recordingsRoot.standardizedFileURL.path + "/"
            guard url.standardizedFileURL.path.hasPrefix(root) else { return nil }
        } else {
            let stem = Self.safeName(name, fallback: "Recording")
            url = Self.recordingsRoot
                .appendingPathComponent(phone, isDirectory: true)
                .appendingPathComponent(stem.hasSuffix(".wav") ? stem : stem + ".wav")
        }
        return url.pathExtension.isEmpty ? url.appendingPathExtension("wav") : url
    }

    static func nextName(after name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Recording 2" }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        if let last = parts.last, let n = Int(last), parts.count > 1 {
            return parts.dropLast().joined(separator: " ") + " \(n + 1)"
        }
        return "\(trimmed) 2"
    }

    static func defaultName(phone: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(phone) \(formatter.string(from: Date()))"
    }

    private static func safeName(_ value: String, fallback: String) -> String {
        var result = value.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        result = result.components(separatedBy: .controlCharacters).joined()
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.lowercased().hasSuffix(".wav") { result = String(result.dropLast(4)) }
        if result.isEmpty { result = fallback }
        return String(result.prefix(180))
    }

    private static func availableURL(in directory: URL, base: String) -> URL {
        var number = 1
        while true {
            let stem = number == 1 ? base : "\(base) \(number)"
            let url = directory.appendingPathComponent(stem).appendingPathExtension("wav")
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            number += 1
        }
    }

    private static func createWav(in directory: URL, base: String) -> (URL, FileHandle)? {
        var number = 1
        while true {
            let stem = number == 1 ? base : "\(base) \(number)"
            let url = directory.appendingPathComponent(stem).appendingPathExtension("wav")
            let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600)) }
            if fd >= 0 {
                let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                do {
                    try h.write(contentsOf: wavHeader())
                    return (url, h)
                } catch {
                    logLine("recorder: could not initialize \(url.path): \(error)")
                    try? h.close()
                    try? FileManager.default.removeItem(at: url)
                    return nil
                }
            }
            if errno != EEXIST {
                logLine("recorder: could not create \(url.path): \(String(cString: strerror(errno)))")
                return nil
            }
            number += 1
        }
    }

    private static func wavHeader() -> Data {
        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(u32(36))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(u32(16))
        data.append(u16(1))
        data.append(u16(UInt16(channels)))
        data.append(u32(UInt32(sampleRate)))
        data.append(u32(UInt32(bytesPerSecond)))
        data.append(u16(UInt16(channels * 2)))
        data.append(u16(16))
        data.append("data".data(using: .ascii)!)
        data.append(u32(0))
        return data
    }

    private static func u16(_ value: UInt16) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt16>.size)
    }

    private static func u32(_ value: UInt32) -> Data {
        var little = value.littleEndian
        return Data(bytes: &little, count: MemoryLayout<UInt32>.size)
    }
}
