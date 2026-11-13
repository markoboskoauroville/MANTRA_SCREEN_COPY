import AppKit

let VERSION = 4

final class Tab {
    let phoneId: String
    var name: String
    let session: Session
    let view: VideoView
    init(phoneId: String, name: String) {
        self.phoneId = phoneId; self.name = name
        let pid = phoneId
        session = Session(phoneId: phoneId, routes: { Discovery.shared.routes(pid) })
        view = VideoView(session: session)
    }
    var title: String {
        let l = session.serial.isEmpty ? "…" : linkName2(session.serial)
        return "\(name) · \(l)"
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
    let panel = PhonesPanel()
    var panelShown = true
    var tabs: [Tab] = []
    var active = 0
    var allTabs = false
    let hl1 = hairline()
    var navButtons: [NSView] = []
    var soundRow: [NSView] = []
    var sliderRow: [NSView] = []
    let thisBtn: WordButton, allBtn: WordButton, muteBtn: WordButton, spkBtn: WordButton
    let slider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    let status = label("", size: 11)
    var timer: Timer?
    let pvNames: [(String, Int)] = [("MEDIA", 3), ("RING", 2), ("ALARM", 4), ("CALL", 0)]
    var pvStream = 3
    var pvAll = false
    var pvBtns: [WordButton] = []
    var pvRow: [NSView] = []
    var pvRow2: [NSView] = []
    let minusBtn = WordButton("−", target: nil, action: nil)
    let plusBtn = WordButton("+", target: nil, action: nil)
    let pvValue = label("— / —", size: 12, color: BRIGHT)
    let pvTitle = label("THE SLIDER SETS THE PHONE'S OWN VOLUME · WHAT YOU HEAR STAYS THE SAME", size: 10)
    let pvThis = WordButton("THIS PHONE", target: nil, action: nil)
    let pvAllBtn = WordButton("ALL PHONES", target: nil, action: nil)
    var startMuted = false
    var lastLog = Date()
    var immersive = false
    var closedIds = Set<String>()
    var lastMouse = Date()
    var cursorHidden = false
    let immBtn = WordButton("IMMERSIVE", target: nil, action: nil)

    override init() {
        thisBtn = WordButton("THIS TAB", target: nil, action: nil)
        allBtn = WordButton("ALL TABS", target: nil, action: nil)
        muteBtn = WordButton("SOUND ON", target: nil, action: nil)
        spkBtn = WordButton("PHONE SILENT", target: nil, action: nil)
        super.init()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        startMuted = CommandLine.arguments.contains("--muted")
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 960), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screen Copy (Mantra) v\(VERSION)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.06, alpha: 1)
        window.minSize = NSSize(width: 480, height: 680)
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.contentView = root
        root.owner = self
        root.wantsLayer = true
        root.addSubview(tabBar); root.addSubview(hl1)
        root.addSubview(panel)
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in self?.close(i) }
        tabBar.onAdd = { [weak self] _ in self?.togglePanel() }
        panel.onOpen = { [weak self] id in self?.openPhone(id) }
        panel.onRoute = { [weak self] id, a in self?.forceRoute(id, a) }
        panel.onTcpip = { [weak self] id in self?.enableTcpip(id) }
        panel.onScan = { Discovery.shared.scanNow() }
        panel.onAddr = { [weak self] in self?.addAddress() }
        panel.onPair = { [weak self] in self?.pairPhone() }

        let back = WordButton("BACK", target: self, action: #selector(navBack))
        let home = WordButton("HOME", target: self, action: #selector(navHome))
        let apps = WordButton("APPS", target: self, action: #selector(navApps))
        immBtn.target = self; immBtn.action = #selector(toggleImmersive)
        navButtons = pipes([back, home, apps, immBtn]) + [label("|", size: 12, color: DIM), spkBtn]
        thisBtn.target = self; thisBtn.action = #selector(modeThis)
        allBtn.target = self; allBtn.action = #selector(modeAll)
        muteBtn.target = self; muteBtn.action = #selector(toggleMute)
        spkBtn.target = self; spkBtn.action = #selector(toggleSpeaks)
        slider.target = self; slider.action = #selector(volumeChanged)
        slider.isContinuous = false
        slider.numberOfTickMarks = 0
        slider.setAccessibilityLabel("Phone volume")
        soundRow = pipes([thisBtn, allBtn]) + [muteBtn]
        sliderRow = [slider, pvValue]
        for (i, p) in pvNames.enumerated() {
            let b = WordButton(p.0, target: self, action: #selector(pvPick(_:))); b.tag = p.1; pvBtns.append(b)
            if i > 0 { pvRow.append(label("|", size: 12, color: DIM)) }
            pvRow.append(b)
        }
        minusBtn.target = self; minusBtn.action = #selector(pvStep(_:)); minusBtn.tag = -1; minusBtn.setAccessibilityLabel("Phone volume down")
        plusBtn.target = self; plusBtn.action = #selector(pvStep(_:)); plusBtn.tag = 1; plusBtn.setAccessibilityLabel("Phone volume up")
        pvThis.target = self; pvThis.action = #selector(pvScopeThis); pvAllBtn.target = self; pvAllBtn.action = #selector(pvScopeAll)
        pvRow2 = [minusBtn, plusBtn] + pipes([pvThis, pvAllBtn])
        for v in navButtons + soundRow + sliderRow + pvRow + pvRow2 + [pvTitle] { root.addSubview(v) }
        root.addSubview(status)
        paintMode()

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logLine("started v\(VERSION), window number \(window.windowNumber)")
        if !UserDefaults.standard.bool(forKey: "speaksResetV3") { UserDefaults.standard.set([String](), forKey: "speaks"); UserDefaults.standard.set(true, forKey: "speaksResetV3") }
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown]) { [weak self] e in
            guard let s = self else { return e }
            return s.monitor(e)
        }
        Discovery.shared.onChange = { [weak self] in self?.discoveryChanged() }
        Discovery.shared.start()
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
        let im = NSMenuItem(title: "Immersive", action: #selector(toggleImmersive), keyEquivalent: "f"); im.target = self; tm.addItem(im)
        tabItem.submenu = tm
        NSApp.mainMenu = main
    }
    @objc func menuTab(_ s: NSMenuItem) { select(s.tag) }

    // MARK: layout
    func layoutAll() {
        let w = root.bounds.width, h = root.bounds.height
        if immersive {
            for t in tabs { t.view.frame = root.bounds }
            for v in [tabBar, hl1, panel, status, pvTitle] as [NSView] { v.isHidden = true }
            for v in navButtons + soundRow + sliderRow + pvRow + pvRow2 { v.isHidden = true }
            return
        }
        tabBar.isHidden = false; hl1.isHidden = false; status.isHidden = false; pvTitle.isHidden = false; panel.isHidden = !panelShown
        for v in navButtons + soundRow + sliderRow + pvRow + pvRow2 { v.isHidden = false }
        let tabH: CGFloat = 36, bottom: CGFloat = 206
        tabBar.frame = NSRect(x: 0, y: h - tabH, width: w, height: tabH)
        hl1.frame = NSRect(x: 0, y: bottom, width: w, height: 1)
        let area = NSRect(x: 0, y: bottom + 1, width: w, height: max(0, h - tabH - bottom - 1))
        for t in tabs { t.view.frame = area }
        panel.frame = area
        center(navButtons, y: bottom - 28, spacing: 12)
        center(soundRow, y: bottom - 56, spacing: 12)
        center(sliderRow, y: bottom - 86, spacing: 12)
        pvTitle.frame = NSRect(x: 12, y: bottom - 110, width: w - 24, height: 16)
        center(pvRow, y: bottom - 134, spacing: 10)
        center(pvRow2, y: bottom - 160, spacing: 24)
        status.frame = NSRect(x: 12, y: 8, width: w - 24, height: 18)
    }
    func center(_ views: [NSView], y: CGFloat, spacing: CGFloat) {
        var sizes: [NSSize] = []
        for v in views {
            if v === slider { sizes.append(NSSize(width: min(260, root.bounds.width - 140), height: 18)) }
            else if v === muteBtn { sizes.append(NSSize(width: 74, height: 20)) }
            else if v === pvValue { sizes.append(NSSize(width: 70, height: 20)) }
            else if v === spkBtn { sizes.append(NSSize(width: 120, height: 20)) }
            else { sizes.append(NSSize(width: fitW(v), height: 20)) }
        }
        let total = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, views.count - 1))
        var x = (root.bounds.width - total) / 2
        for (i, v) in views.enumerated() {
            v.frame = NSRect(x: x, y: y + (24 - sizes[i].height) / 2, width: sizes[i].width, height: sizes[i].height)
            x += sizes[i].width + spacing
        }
    }

    // MARK: panel and discovery
    func togglePanel() { panelShown.toggle(); panel.isHidden = !panelShown; if panelShown { reloadPanel() } }
    func reloadPanel() {
        var m: [String: (open: Bool, active: String?, forced: String?)] = [:]
        for t in tabs { m[t.phoneId] = (true, t.session.serial.isEmpty ? nil : t.session.serial, t.session.forced) }
        panel.reload(phones: Discovery.shared.all(), tabs: m, searching: !Discovery.shared.firstDone)
    }
    func discoveryChanged() {
        for t in tabs { if let n = Discovery.shared.name(t.phoneId) { t.name = n } }
        // every phone that is found gets its tab and stream by itself, best route first
        for p in Discovery.shared.all() where !tabs.contains(where: { $0.phoneId == p.id }) && !closedIds.contains(p.id) {
            addTab(phoneId: p.id, name: p.name, select: tabs.isEmpty)
            panelShown = false; panel.isHidden = true
        }
        reloadPanel(); refreshTabs(); save()
    }

    // MARK: tabs
    @discardableResult
    func addTab(phoneId: String, name: String, select sel: Bool = true) -> Tab {
        if let t = tabs.first(where: { $0.phoneId == phoneId }) { return t }
        let t = Tab(phoneId: phoneId, name: name)
        t.session.audio.muted = startMuted
        t.view.onDouble = { [weak self] in self?.toggleImmersive() }
        t.session.phoneSpeaks = (UserDefaults.standard.stringArray(forKey: "speaks") ?? []).contains(phoneId)
        t.session.onChange = { [weak self] in self?.refreshStatus(); self?.refreshTabs() }
        tabs.append(t)
        root.addSubview(t.view, positioned: .below, relativeTo: panel)
        t.view.showNote("CONNECTING")
        layoutAll()
        t.session.start()
        save()
        if sel { select(tabs.count - 1) }
        return t
    }

    func openPhone(_ id: String) {
        closedIds.remove(id)
        if let i = tabs.firstIndex(where: { $0.phoneId == id }) { select(i) }
        else { addTab(phoneId: id, name: Discovery.shared.name(id) ?? id) }
        panelShown = false; panel.isHidden = true
    }

    func forceRoute(_ id: String, _ addr: String) {
        openPhone(id)
        guard let t = tabs.first(where: { $0.phoneId == id }) else { return }
        t.session.forced = (t.session.forced == addr) ? nil : addr
        t.session.reconnect()
        reloadPanel()
    }

    func select(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        active = i
        let t = tabs[i]
        root.addSubview(t.view, positioned: .below, relativeTo: panel)
        for o in tabs where o !== t { root.addSubview(o.view, positioned: .below, relativeTo: t.view) }
        t.session.sendResetVideo()
        applyAudio(); paintMode()
        refreshTabs(); refreshStatus()
        window.makeFirstResponder(t.view)
        refreshPhoneVol()
    }

    func close(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        let t = tabs.remove(at: i)
        closedIds.insert(t.phoneId)
        t.session.stop(); t.view.removeFromSuperview()
        active = min(active, max(0, tabs.count - 1))
        save(); refreshTabs()
        if !tabs.isEmpty { select(active) } else { panelShown = true; panel.isHidden = false }
        refreshStatus(); reloadPanel()
    }

    func refreshTabs() {
        tabBar.live = tabs.map { $0.session.status == "LIVE" }
        tabBar.titles = tabs.map { $0.title }
        tabBar.selected = active
    }

    func applyAudio() {
        for (i, t) in tabs.enumerated() {
            let on = allTabs || i == active
            if t.session.audio.enabled != on { t.session.audio.enabled = on; if !on { t.session.audio.silence() } }
        }
    }

    // MARK: persistence
    func save() {
        UserDefaults.standard.set(tabs.map { $0.phoneId }, forKey: "phones")
        UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: tabs.map { ($0.phoneId, $0.name) }), forKey: "names")
    }
    func restore() {
        let ids = UserDefaults.standard.stringArray(forKey: "phones") ?? []
        let names = UserDefaults.standard.dictionary(forKey: "names") as? [String: String] ?? [:]
        if !ids.isEmpty {
            for id in ids { addTab(phoneId: id, name: names[id] ?? id, select: false) }
            select(0)
            panelShown = false; panel.isHidden = true
        }
    }

    // MARK: adding by hand
    func addAddress() {
        let a = NSAlert()
        a.messageText = "Phone address"
        a.informativeText = "Only if the scan did not find it. Wi-Fi adb or Tailscale, like 10.146.4.95:5555"
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        f.placeholderString = "10.0.0.5:5555"
        a.accessoryView = f
        a.addButton(withTitle: "CONNECT"); a.addButton(withTitle: "CANCEL")
        if a.runModal() == .alertFirstButtonReturn {
            var s = f.stringValue.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { return }
            if !s.contains(":") { s += ":5555" }
            DispatchQueue.global().async { let r = adb(nil, ["connect", s], timeout: 10); logLine("adb connect \(s): \(r)"); Discovery.shared.scanNow() }
        }
    }

    func pairPhone() {
        let a = NSAlert()
        a.messageText = "Pair a new phone"
        a.informativeText = "On the phone: Developer options, Wireless debugging, Pair device with pairing code. Type the address and the six-digit code it shows."
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 56))
        let f1 = NSTextField(frame: NSRect(x: 0, y: 32, width: 260, height: 24)); f1.placeholderString = "address:port, like 10.0.0.5:37123"
        let f2 = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f2.placeholderString = "pairing code"
        box.addSubview(f1); box.addSubview(f2)
        a.accessoryView = box
        a.addButton(withTitle: "PAIR"); a.addButton(withTitle: "CANCEL")
        if a.runModal() == .alertFirstButtonReturn {
            let addr = f1.stringValue.trimmingCharacters(in: .whitespaces), code = f2.stringValue.trimmingCharacters(in: .whitespaces)
            if addr.isEmpty || code.isEmpty { return }
            DispatchQueue.global().async {
                let r = adb(nil, ["pair", addr, code], timeout: 20)
                logLine("adb pair: \(r)")
                Discovery.shared.scanNow()
                DispatchQueue.main.async { self.panel.heading.stringValue = r.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
            }
        }
    }

    /// A phone that is on USB only: make it reachable over Wi-Fi and Tailscale as well (adb tcpip 5555).
    func enableTcpip(_ id: String) {
        guard let usb = Discovery.shared.all().first(where: { $0.id == id })?.routes.first(where: { $0.link == "USB" })?.addr else { return }
        panel.heading.stringValue = "SWITCHING WI-FI ACCESS ON…"
        DispatchQueue.global().async {
            logLine("tcpip: \(adb(usb, ["tcpip", "5555"], timeout: 15))")
            var ip = ""
            for _ in 0..<8 where ip.isEmpty {
                sleep(2)
                let out = adb(usb, ["shell", "ip", "-f", "inet", "addr", "show", "wlan0"], timeout: 8)
                if let r = out.range(of: "inet ") { ip = String(out[r.upperBound...].prefix(while: { $0 != "/" && $0 != " " })) }
            }
            if !ip.isEmpty { logLine("tcpip connect \(ip): \(adb(nil, ["connect", "\(ip):5555"], timeout: 10))") }
            Discovery.shared.scanNow()
        }
    }

    // MARK: immersive
    @objc func toggleImmersive() { window.toggleFullScreen(nil) }
    func windowDidEnterFullScreen(_ n: Notification) { immersive = true; lastMouse = Date(); layoutAll(); if let t = tabs.indices.contains(active) ? tabs[active] : nil { window.makeFirstResponder(t.view) } }
    func windowDidExitFullScreen(_ n: Notification) { immersive = false; showCursor(); layoutAll() }
    func showCursor() { if cursorHidden { NSCursor.unhide(); cursorHidden = false } }
    func monitor(_ e: NSEvent) -> NSEvent? {
        if e.window !== window { return e }
        if e.type == .mouseMoved || e.type == .leftMouseDown { lastMouse = Date(); showCursor(); return e }
        guard immersive else { return e }
        let shift = e.modifierFlags.contains(.shift)
        let other = e.modifierFlags.intersection([.command, .control, .option]).isEmpty == false
        if other { return e }
        switch e.keyCode {
        case 48 where !tabs.isEmpty:
            select((active + (shift ? tabs.count - 1 : 1)) % tabs.count); return nil
        case 53: window.toggleFullScreen(nil); return nil
        case 3 where !shift: window.toggleFullScreen(nil); return nil
        default: return e
        }
    }

    // MARK: controls
    func cur() -> Session? { active < tabs.count ? tabs[active].session : nil }
    @objc func navBack() { cur()?.key(4) }
    @objc func navHome() { cur()?.key(3) }
    @objc func navApps() { cur()?.key(187) }
    @objc func toggleSpeaks() {
        guard let t = tabs.indices.contains(active) ? tabs[active] : nil else { return }
        t.session.phoneSpeaks.toggle()
        var l = UserDefaults.standard.stringArray(forKey: "speaks") ?? []
        l.removeAll { $0 == t.phoneId }
        if t.session.phoneSpeaks { l.append(t.phoneId) }
        UserDefaults.standard.set(l, forKey: "speaks")
        paintMode(); t.session.reconnect()
    }
    @objc func modeThis() { allTabs = false; paintMode(); applyAudio() }
    @objc func modeAll() { allTabs = true; paintMode(); applyAudio() }
    var muted: Bool { cur()?.audio.muted ?? false }
    func paintMode() {
        for b in pvBtns { b.normal = b.tag == pvStream ? ACCENT : DIM }
        pvThis.normal = pvAll ? DIM : ACCENT; pvAllBtn.normal = pvAll ? ACCENT : DIM
        thisBtn.normal = allTabs ? DIM : ACCENT; allBtn.normal = allTabs ? ACCENT : DIM
        muteBtn.normal = muted ? DIM : BRIGHT; muteBtn.word = muted ? "MUTED" : "SOUND ON"
        let sp = cur()?.phoneSpeaks ?? false
        spkBtn.word = sp ? "PHONE SPEAKS" : "PHONE SILENT"; spkBtn.normal = sp ? ACCENT : BRIGHT
    }
    @objc func toggleMute() { if let s = cur() { s.audio.muted.toggle() }; paintMode() }
    @objc func volumeChanged() { setFromSlider(slider.doubleValue) }

    // the phone's own volume (the Mac listens pre-fader, so this never changes what you hear)
    func parseVol(_ s: String) -> (Int, Int)? {
        guard let r = s.range(of: "volume is ") else { return nil }
        let rest = s[r.upperBound...]
        let v = Int(rest.prefix(while: { $0.isNumber })) ?? -1
        guard v >= 0, let r2 = rest.range(of: "..") else { return nil }
        let mx = Int(rest[r2.upperBound...].prefix(while: { $0.isNumber })) ?? -1
        return mx >= 0 ? (v, mx) : nil
    }
    func getVol(_ serial: String, _ stream: Int) -> (Int, Int)? {
        parseVol(adb(serial, ["shell", "cmd", "media_session", "volume", "--stream", "\(stream)", "--get"], timeout: 10))
    }
    /// Sets the phone's volume and reads it back. If `cmd media_session` does not take, the volume keys are pressed until it is there (media stream).
    func setPhoneVol(_ ser: String, _ st: Int, _ target: Int) -> (Int, Int)? {
        guard let (v0, mx) = getVol(ser, st) else { return nil }
        let nv = max(0, min(mx, target))
        if nv == v0 { return (v0, mx) }
        _ = adb(ser, ["shell", "cmd", "media_session", "volume", "--stream", "\(st)", "--set", "\(nv)"], timeout: 10)
        var back = getVol(ser, st)
        var how = "media_session"
        if back?.0 != nv && st == 3 {
            how = "keyevent"
            var cur = back?.0 ?? v0
            var guardN = 0
            while cur != nv && guardN < 40 {
                _ = adb(ser, ["shell", "input", "keyevent", cur < nv ? "24" : "25"], timeout: 6)
                guardN += 1
                cur = getVol(ser, st)?.0 ?? cur
            }
            back = getVol(ser, st)
        }
        logLine("phone volume \(ser) stream \(st): \(v0) -> \(nv) via \(how), read back \(back.map { "\($0.0)" } ?? "?")")
        return back
    }
    func targetSerials() -> [String] { pvAll ? tabs.map { $0.session.serial } : (tabs.indices.contains(active) ? [tabs[active].session.serial] : []) }
    func show(_ r: (Int, Int)?) {
        guard let r = r else { pvValue.stringValue = "— / —"; return }
        pvValue.stringValue = "\(r.0) / \(r.1)"
        slider.maxValue = Double(max(1, r.1)); slider.doubleValue = Double(r.0)
    }
    func refreshPhoneVol() {
        guard tabs.indices.contains(active), !tabs[active].session.serial.isEmpty else { return }
        let serial = tabs[active].session.serial, st = pvStream
        DispatchQueue.global().async { [weak self] in
            let r = self?.getVol(serial, st)
            DispatchQueue.main.async { self?.show(r) }
        }
    }
    func setFromSlider(_ value: Double) {
        let frac = slider.maxValue > 0 ? value / slider.maxValue : 0
        let st = pvStream, targets = targetSerials(), activeSerial = tabs.indices.contains(active) ? tabs[active].session.serial : ""
        let exact = Int(value.rounded())
        DispatchQueue.global().async { [weak self] in
            guard let self = self else { return }
            var shown: (Int, Int)?
            for ser in targets where !ser.isEmpty {
                var t = exact
                if ser != activeSerial, let (_, mx) = self.getVol(ser, st) { t = Int((frac * Double(mx)).rounded()) }
                let back = self.setPhoneVol(ser, st, t)
                if ser == activeSerial { shown = back }
            }
            DispatchQueue.main.async { self.show(shown) }
        }
    }
    @objc func pvPick(_ s: NSButton) { pvStream = s.tag; paintMode(); refreshPhoneVol() }
    @objc func pvScopeThis() { pvAll = false; paintMode() }
    @objc func pvScopeAll() { pvAll = true; paintMode() }
    @objc func pvStep(_ s: NSButton) { setFromSlider(slider.doubleValue + Double(s.tag)) }

    func tick() {
        refreshStatus()
        if immersive && !cursorHidden && Date().timeIntervalSince(lastMouse) > 2 { NSCursor.hide(); cursorHidden = true }
        refreshTabs()
        if Date().timeIntervalSince(lastLog) > 5 {
            lastLog = Date()
            for t in tabs { logLine("\(t.title): \(t.session.status) \(t.session.width)x\(t.session.height) frames \(t.session.framesTotal) fps \(t.session.fps) \(t.session.audioState) packets \(t.session.audio.packets) level \(Int(t.session.audio.levelDb)) dB") }
        }
    }

    func refreshStatus() {
        for t in tabs { t.view.showNote(t.session.status == "LIVE" ? nil : t.session.status) }
        guard let t = tabs.indices.contains(active) ? tabs[active] : nil else { status.stringValue = "NO PHONE OPEN"; return }
        let s = t.session
        let db = s.audio.levelDb <= -100 ? "silent" : "\(Int(s.audio.levelDb)) dB"
        status.stringValue = "\(s.width)×\(s.height) · \(s.fps) fps · \(s.audioState) \(db) · PRE-FADER"
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "screencopy" {
            if u.host == "tab", let n = Int(u.lastPathComponent) { panelShown = false; panel.isHidden = true; select(n - 1) }
            if u.host == "volume", let n = Int(u.lastPathComponent) { setFromSlider(Double(n)) }
            if u.host == "window" { logLine("window number \(window.windowNumber)") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { for t in tabs { t.session.stop() } }
}

