import AppKit

let VERSION = 1

final class Tab {
    let serial: String
    var title: String
    let session: Session
    let view: VideoView
    init(serial: String, title: String) {
        self.serial = serial; self.title = title
        session = Session(serial: serial)
        view = VideoView(session: session)
    }
}

final class Root: NSView {
    weak var owner: Controller?
    override func layout() { super.layout(); owner?.layoutAll() }
}

final class Controller: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    let root = Root()
    let tabBar = TabBar()
    var tabs: [Tab] = []
    var active = 0
    var allTabs = false
    var muted = false
    var volume: Float = 1
    let hl1 = hairline(), hl2 = hairline()
    var navButtons: [NSView] = []
    var soundRow: [NSView] = []
    let thisBtn: WordButton, allBtn: WordButton, muteBtn: WordButton
    let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let status = label("", size: 11)
    var timer: Timer?
    var lastLog = Date()

    override init() {
        thisBtn = WordButton("THIS TAB", target: nil, action: nil)
        allBtn = WordButton("ALL TABS", target: nil, action: nil)
        muteBtn = WordButton("SOUND ON", target: nil, action: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        muted = CommandLine.arguments.contains("--muted")
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screen Copy (Mantra) v\(VERSION)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.06, alpha: 1)
        window.minSize = NSSize(width: 360, height: 560)
        window.delegate = self
        window.contentView = root
        root.owner = self
        root.wantsLayer = true
        root.addSubview(tabBar); root.addSubview(hl1); root.addSubview(hl2)
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in self?.close(i) }
        tabBar.onAdd = { [weak self] v in self?.addMenu(v) }

        let back = WordButton("BACK", target: self, action: #selector(navBack))
        let home = WordButton("HOME", target: self, action: #selector(navHome))
        let apps = WordButton("APPS", target: self, action: #selector(navApps))
        navButtons = pipes([back, home, apps])
        thisBtn.target = self; thisBtn.action = #selector(modeThis)
        allBtn.target = self; allBtn.action = #selector(modeAll)
        muteBtn.target = self; muteBtn.action = #selector(toggleMute)
        slider.target = self; slider.action = #selector(volumeChanged)
        slider.setAccessibilityLabel("Volume of this tab")
        soundRow = pipes([thisBtn, allBtn]) + [muteBtn, slider]
        for v in navButtons + soundRow { root.addSubview(v) }
        root.addSubview(status)
        paintMode()

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logLine("started v\(VERSION), window number \(window.windowNumber)")
        restore()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.tick() }
    }

    func pipes(_ v: [NSView]) -> [NSView] {
        var r: [NSView] = []
        for (i, x) in v.enumerated() {
            if i > 0 { r.append(label("|", size: 12, color: DIM)) }
            r.append(x)
        }
        return r
    }

    func buildMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); main.addItem(app)
        let m = NSMenu()
        m.addItem(withTitle: "Quit Screen Copy (Mantra)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = m
        let tabItem = NSMenuItem(); main.addItem(tabItem)
        let tm = NSMenu(title: "Tabs")
        for i in 1...9 {
            let it = NSMenuItem(title: "Tab \(i)", action: #selector(menuTab(_:)), keyEquivalent: "\(i)")
            it.tag = i - 1; it.target = self; tm.addItem(it)
        }
        tabItem.submenu = tm
        NSApp.mainMenu = main
    }
    @objc func menuTab(_ s: NSMenuItem) { select(s.tag) }

    // MARK: layout
    func layoutAll() {
        let w = root.bounds.width, h = root.bounds.height
        let tabH: CGFloat = 36, bottom: CGFloat = 96
        tabBar.frame = NSRect(x: 0, y: h - tabH, width: w, height: tabH)
        hl1.frame = NSRect(x: 0, y: bottom, width: w, height: 1)
        let area = NSRect(x: 0, y: bottom + 1, width: w, height: max(0, h - tabH - bottom - 1))
        for t in tabs { t.view.frame = area }
        center(navButtons, y: bottom - 28, spacing: 12)
        center(soundRow, y: bottom - 56, spacing: 12)
        status.frame = NSRect(x: 12, y: 8, width: w - 24, height: 18)
        hl2.frame = .zero
    }
    func center(_ views: [NSView], y: CGFloat, spacing: CGFloat) {
        var sizes: [NSSize] = []
        for v in views {
            if v === slider { sizes.append(NSSize(width: 110, height: 18)) }
            else if v === muteBtn { sizes.append(NSSize(width: 74, height: 20)) }
            else { v.sizeToFit(); sizes.append(NSSize(width: ceil(v.frame.width) + 2, height: 20)) }
        }
        let total = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, views.count - 1))
        var x = (root.bounds.width - total) / 2
        for (i, v) in views.enumerated() {
            v.frame = NSRect(x: x, y: y + (24 - sizes[i].height) / 2, width: sizes[i].width, height: sizes[i].height)
            x += sizes[i].width + spacing
        }
    }

    // MARK: tabs
    func addTab(serial: String, title: String?) {
        if tabs.contains(where: { $0.serial == serial }) { return }
        let t = Tab(serial: serial, title: title ?? "\(linkName(serial)) \(serial)")
        t.session.audio.muted = muted
        t.session.audio.volume = volume
        t.session.onChange = { [weak self] in self?.refreshStatus() }
        tabs.append(t)
        root.addSubview(t.view)
        t.view.showNote("CONNECTING")
        t.session.start()
        if title == nil {
            DispatchQueue.global().async { [weak self] in
                let name = phoneName(serial) + " · " + linkName(serial)
                DispatchQueue.main.async { t.title = name; self?.save(); self?.refreshTabs() }
            }
        }
        refreshTabs(); save()
        select(tabs.count - 1)
    }

    func select(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        active = i
        let t = tabs[i]
        root.addSubview(t.view, positioned: .above, relativeTo: nil)
        t.session.sendResetVideo()
        applyAudio()
        refreshTabs(); refreshStatus()
        window.makeFirstResponder(t.view)
    }

    func close(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        let t = tabs.remove(at: i)
        t.session.stop(); t.view.removeFromSuperview()
        active = min(active, max(0, tabs.count - 1))
        save(); refreshTabs()
        if !tabs.isEmpty { select(active) }
        refreshStatus()
    }

    func refreshTabs() {
        tabBar.titles = tabs.map { $0.title }
        tabBar.selected = active
    }

    func applyAudio() {
        for (i, t) in tabs.enumerated() {
            let on = allTabs || i == active
            if t.session.audio.enabled != on { t.session.audio.enabled = on; if !on { t.session.audio.silence() } }
            t.session.audio.muted = muted
        }
    }

    // MARK: persistence
    func save() {
        UserDefaults.standard.set(tabs.map { $0.serial }, forKey: "serials")
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: tabs.map { ($0.serial, $0.title) }), forKey: "titles")
    }
    func restore() {
        let serials = UserDefaults.standard.stringArray(forKey: "serials") ?? []
        let titles = UserDefaults.standard.dictionary(forKey: "titles") as? [String: String] ?? [:]
        if !serials.isEmpty {
            for s in serials { addTab(serial: s, title: titles[s]) }
            select(0)
            return
        }
        DispatchQueue.global().async { [weak self] in
            // first start: one tab per physical phone, USB preferred
            var seen: [String: String] = [:]
            for e in adbDevices().sorted(by: { !$0.serial.contains(":") && $1.serial.contains(":") }) where e.state == "device" {
                let id = physicalId(e.serial)
                if seen[id] == nil { seen[id] = e.serial }
            }
            DispatchQueue.main.async { for s in seen.values.sorted() { self?.addTab(serial: s, title: nil) }; self?.select(0) }
        }
    }

    // MARK: adding
    func addMenu(_ from: NSView) {
        DispatchQueue.global().async { [weak self] in
            let list = adbDevices().filter { $0.state == "device" }
            DispatchQueue.main.async {
                guard let self = self else { return }
                let m = NSMenu()
                for e in list where !self.tabs.contains(where: { $0.serial == e.serial }) {
                    let it = NSMenuItem(title: "\(e.model.replacingOccurrences(of: "_", with: " ")) · \(linkName(e.serial)) · \(e.serial)", action: #selector(self.addFromMenu(_:)), keyEquivalent: "")
                    it.representedObject = e.serial; it.target = self; m.addItem(it)
                }
                if m.items.isEmpty { let it = NSMenuItem(title: "No other phone on adb", action: nil, keyEquivalent: ""); it.isEnabled = false; m.addItem(it) }
                m.addItem(.separator())
                let a = NSMenuItem(title: "Add an address (Wi-Fi or Tailscale)…", action: #selector(self.addAddress), keyEquivalent: "")
                a.target = self; m.addItem(a)
                m.popUp(positioning: nil, at: NSPoint(x: 0, y: from.bounds.height), in: from)
            }
        }
    }
    @objc func addFromMenu(_ s: NSMenuItem) { if let x = s.representedObject as? String { addTab(serial: x, title: nil) } }
    @objc func addAddress() {
        let a = NSAlert()
        a.messageText = "Phone address"
        a.informativeText = "Wi-Fi adb or Tailscale, like 10.146.4.95:5555 or 100.70.23.53:5555"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.placeholderString = "10.0.0.5:5555"
        a.accessoryView = f
        a.addButton(withTitle: "ADD"); a.addButton(withTitle: "CANCEL")
        if a.runModal() == .alertFirstButtonReturn {
            var s = f.stringValue.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return }
            if !s.contains(":") { s += ":5555" }
            addTab(serial: s, title: nil)
        }
    }

    // MARK: controls
    func cur() -> Session? { active < tabs.count ? tabs[active].session : nil }
    @objc func navBack() { cur()?.key(4) }
    @objc func navHome() { cur()?.key(3) }
    @objc func navApps() { cur()?.key(187) }
    @objc func modeThis() { allTabs = false; paintMode(); applyAudio() }
    @objc func modeAll() { allTabs = true; paintMode(); applyAudio() }
    func paintMode() { thisBtn.normal = allTabs ? DIM : ACCENT; allBtn.normal = allTabs ? ACCENT : DIM; muteBtn.normal = muted ? DIM : BRIGHT; muteBtn.word = muted ? "MUTED" : "SOUND ON" }
    @objc func toggleMute() { muted.toggle(); paintMode(); applyAudio() }
    @objc func volumeChanged() { volume = slider.floatValue; if active < tabs.count { tabs[active].session.audio.volume = volume } }

    func tick() { refreshStatus(); if Date().timeIntervalSince(lastLog) > 5 { lastLog = Date(); for t in tabs { logLine("\(t.title): \(t.session.status) \(t.session.width)x\(t.session.height) frames \(t.session.framesTotal) fps \(t.session.fps) \(t.session.audioState) packets \(t.session.audio.packets) level \(Int(t.session.audio.levelDb)) dB") } } }

    func refreshStatus() {
        for t in tabs { t.view.showNote(t.session.status == "LIVE" ? nil : t.session.status) }
        guard let t = tabs.indices.contains(active) ? tabs[active] : nil else { status.stringValue = "ADD A PHONE WITH +"; return }
        let s = t.session
        let db = s.audio.levelDb <= -100 ? "silent" : "\(Int(s.audio.levelDb)) dB"
        status.stringValue = "\(s.width)×\(s.height) · \(s.fps) fps · \(s.audioState) \(db)"
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "screencopy" {
            if u.host == "tab", let n = Int(u.lastPathComponent) { select(n - 1) }
            if u.host == "window" { logLine("window number \(window.windowNumber)") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { for t in tabs { t.session.stop() } }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.run()
