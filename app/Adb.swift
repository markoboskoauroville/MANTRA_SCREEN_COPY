import Foundation

let ADB = NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb"

func logLine(_ s: String) {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"
    let line = "\(f.string(from: Date())) \(s)\n"
    let path = NSHomeDirectory() + "/Library/Logs/ScreenCopyMantra.log"
    if let h = FileHandle(forWritingAtPath: path) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close() }
    else { try? line.write(toFile: path, atomically: true, encoding: .utf8) }
}

/// Runs a program and returns (status, stdout+stderr). Killed after `timeout` seconds.
@discardableResult
func runCmd(_ path: String, _ args: [String], timeout: Double = 20) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

func adb(_ serial: String?, _ args: [String], timeout: Double = 20) -> String {
    var a: [String] = []
    if let s = serial { a += ["-s", s] }
    return runCmd(ADB, a + args, timeout: timeout).1
}

struct AdbEntry { var serial: String; var state: String; var model: String }

func adbDevices() -> [AdbEntry] {
    let out = adb(nil, ["devices", "-l"])
    var r: [AdbEntry] = []
    for line in out.split(separator: "\n").dropFirst() {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2, parts[0] != "*" else { continue }
        var model = ""
        for p in parts where p.hasPrefix("model:") { model = String(p.dropFirst(6)) }
        r.append(AdbEntry(serial: parts[0], state: parts[1], model: model))
    }
    return r
}

func linkName(_ serial: String) -> String {
    if !serial.contains(":") { return "USB" }
    let host = serial.split(separator: ":")[0]
    if host.hasPrefix("100.") { return "Tailscale" }
    return "Wi-Fi"
}

func phoneName(_ serial: String) -> String {
    let model = adb(serial, ["shell", "getprop", "ro.product.model"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
    let maker = adb(serial, ["shell", "getprop", "ro.product.manufacturer"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
    if model.isEmpty || model.contains("error") { return serial }
    if maker.isEmpty || maker.lowercased() == "google" || model.lowercased().hasPrefix(maker.lowercased()) { return model }
    return maker.prefix(1).uppercased() + maker.dropFirst() + " " + model
}

func physicalId(_ serial: String) -> String {
    adb(serial, ["shell", "getprop", "ro.serialno"], timeout: 8).trimmingCharacters(in: .whitespacesAndNewlines)
}

func serverJarPath() -> String {
    if let p = Bundle.main.path(forResource: "scrcpy-server", ofType: "jar") { return p }
    return "/opt/homebrew/Cellar/scrcpy/4.1_1/share/scrcpy/scrcpy-server"
}
