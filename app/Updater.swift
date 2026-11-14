// Updater.swift: the app updates itself from its own GitHub releases (Marko, 14.11.2026: "When the application starts,
// it checks for it, downloads it, and asks you, 'Do you want to update?' Then I say 'yes,' and it downloads and runs the
// update."). One file, the same in every Mac app: only the three constants in Updater.Config change.
//
// At start (a few seconds after launch, in the background): `gh release view` on the app's repository (private repos
// work, gh is signed in on the Mac). A Latest tag vN with N > VERSION: the release's app.zip is downloaded quietly to
// ~/Library/Caches/<bundle id>/update, unpacked and checked, then the question is asked. Yes: a small script waits for
// this app to quit, swaps the new .app in at the same path (the old one kept until the new one is signed "Mantra Apps",
// so Accessibility and the other permissions stay), and opens it. Later: nothing changes, the question comes again at the
// next start. No gh, no network, no newer release: silent.
import AppKit

enum Updater {
    struct Config {
        static let repo = "markoboskoauroville/MANTRA_SCREEN_COPY"
        static let asset = "app.zip"
        static let sign = "Mantra Apps"
    }

    static var busy = false
    static let gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) }
    static var cache: URL {
        let id = Bundle.main.bundleIdentifier ?? APP_NAME
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/\(id)/update")
    }

    /// Called once from applicationDidFinishLaunching. `manual` (from the settings panel) also says "up to date".
    static func checkAtStart(delay: Double = 4, manual: Bool = false) {
        guard !busy else { return }
        busy = true
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            let found = findAndDownload()
            DispatchQueue.main.async {
                busy = false
                if let (v, app, notes) = found { ask(version: v, newApp: app, notes: notes) }
                else if manual { tell("\(APP_NAME) v\(VERSION) is the newest version.") }
            }
        }
    }

    /// The Latest release; downloaded and unpacked when it is newer. Returns (version, path of the new .app, notes).
    static func findAndDownload() -> (Int, URL, String)? {
        guard let gh else { log("no gh on this Mac"); return nil }
        guard let out = run(gh, ["release", "view", "--repo", Config.repo, "--json", "tagName,name,body"]),
              let j = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any],
              let tag = j["tagName"] as? String,
              let v = Int(tag.filter(\.isNumber)) else { log("no release info"); return nil }
        guard v > VERSION else { log("v\(VERSION) is the newest (Latest is \(tag))"); return nil }
        let fm = FileManager.default
        let dir = cache.appendingPathComponent(tag)
        let zip = dir.appendingPathComponent(Config.asset)
        let unpacked = dir.appendingPathComponent("app")
        let appName = (Bundle.main.bundlePath as NSString).lastPathComponent
        let newApp = unpacked.appendingPathComponent(appName)
        if !fm.fileExists(atPath: newApp.path) {       // never download the same version twice (SIM data)
            try? fm.removeItem(at: cache)
            try? fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
            guard run(gh, ["release", "download", tag, "--repo", Config.repo, "--pattern", Config.asset,
                           "-D", dir.path, "--clobber"]) != nil,
                  run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) != nil,
                  fm.fileExists(atPath: newApp.path) else { log("download of \(tag) failed"); try? fm.removeItem(at: dir); return nil }
        }
        let notes = ((j["body"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        log("v\(v) downloaded, asking")
        return (v, newApp, notes)
    }

    static func ask(version v: Int, newApp: URL, notes: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "\(APP_NAME) v\(v) is ready"
        a.informativeText = "You have v\(VERSION). Do you want to update?" + (notes.isEmpty ? "" : "\n\nWhat is new: \(notes.prefix(400))")
        a.addButton(withTitle: "Update")
        a.addButton(withTitle: "Later")
        if let icon = NSImage(contentsOf: newApp.appendingPathComponent("Contents/Resources/AppIcon.icns")) { a.icon = icon }
        guard a.runModal() == .alertFirstButtonReturn else { log("v\(v): later"); return }
        install(newApp)
    }

    /// The swap runs in a detached shell after this app quits; the old copy comes back if anything fails.
    static func install(_ newApp: URL) {
        let target = Bundle.main.bundlePath
        let script = cache.appendingPathComponent("install.sh")
        let sh = """
        #!/bin/sh
        T="$1"; N="$2"; P="$3"; S="$4"
        while kill -0 "$P" 2>/dev/null; do sleep 0.2; done
        xattr -dr com.apple.quarantine "$N" 2>/dev/null
        codesign --force -s "$S" "$N" || { open "$T"; exit 1; }
        rm -rf "$T.old"; mv "$T" "$T.old" || { open "$T"; exit 1; }
        if ditto "$N" "$T"; then rm -rf "$T.old"; else rm -rf "$T"; mv "$T.old" "$T"; fi
        open "$T"
        """
        do { try sh.write(to: script, atomically: true, encoding: .utf8) } catch { tell("Update failed: \(error)"); return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path, target, newApp.path, String(getpid()), Config.sign]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { tell("Update failed: \(error)"); return }
        log("installing \(newApp.path) over \(target)")
        NSApp.terminate(nil)
    }

    static func tell(_ s: String) {
        let a = NSAlert(); a.messageText = APP_NAME; a.informativeText = s; a.runModal()
    }

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> String? {
        let p = Process(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
        p.standardOutput = out; p.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"; env["GH_PROMPT_DISABLED"] = "1"
        p.environment = env
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : nil
    }

    static func log(_ s: String) { NSLog("[Updater] %@", s) }
}
