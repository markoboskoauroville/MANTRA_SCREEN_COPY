import AppKit

let VERSION = 24
let APP_NAME = "Screen Copy (Mantra)"

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
    var panelShown = false
    var tabs: [Tab] = []
    var active = 0
    let hl1 = hairline()
    var sliderRow: [NSView] = []
    let slider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let pvValue = label("— / —", size: 12, color: BRIGHT)
    let status = label("", size: 11)
    var rotBtn: RoundIconButton!
    var timer: Timer?
    var lastLog = Date()
    var immersive = false
    var closedIds = Set<String>()
    var lastMouse = Date()
    var cursorHidden = false
    var lastUserVol = Date.distantPast
    var volBusy = false
    var lastVolPoll = Date.distantPast
    let permBtn = NSButton(title: "", target: nil, action: nil)
    var lastPermCheck = Date.distantPast

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 960), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Screen Copy (Mantra) v\(VERSION)"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(white: 0.06, alpha: 1)
        window.minSize = NSSize(width: 420, height: 320)
        window.delegate = self
        window.collectionBehavior = [.fullScreenPrimary]
        window.acceptsMouseMovedEvents = true
        window.contentView = root
        root.owner = self
        root.wantsLayer = true
        root.addSubview(tabBar); root.addSubview(hl1)
        root.addSubview(panel); panel.isHidden = true
        tabBar.onSelect = { [weak self] i in self?.select(i) }
        tabBar.onClose = { [weak self] i in self?.close(i) }
                panel.onOpen = { [weak self] id in self?.openPhone(id) }
        panel.onRoute = { [weak self] id, a in self?.forceRoute(id, a) }
        panel.onTcpip = { [weak self] id in self?.enableTcpip(id) }
        panel.onScan = { Discovery.shared.scanNow() }
        panel.onAddr = { [weak self] in self?.addAddress() }
        panel.onPair = { [weak self] in self?.pairPhone() }

        slider.target = self; slider.action = #selector(volumeChanged)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Phone volume")
        rotBtn = RoundIconButton(target: self, action: #selector(toggleRotation))
        sliderRow = [slider, pvValue, rotBtn]
        for v in sliderRow { root.addSubview(v) }
        root.addSubview(status)
        permBtn.isBordered = false
        permBtn.attributedTitle = NSAttributedString(string: "PERMISSIONS", attributes: [.foregroundColor: NSColor(red: 0.91, green: 0.64, blue: 0.24, alpha: 1), .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)])
        permBtn.target = self; permBtn.action = #selector(permClicked)
        permBtn.setAccessibilityLabel("PERMISSIONS")
        permBtn.isHidden = true
        root.addSubview(permBtn)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        logLine("started v\(VERSION), window number \(window.windowNumber)")
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .mouseMoved, .leftMouseDown]) { [weak self] e in
            guard let s = self else { return e }
            return s.monitor(e)
        }
        Discovery.shared.onChange = { [weak self] in self?.discoveryChanged() }
        Discovery.shared.start()
        restore()
        MicLink.shared.start()
        Updater.checkAtStart()
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
        let ph = NSMenuItem(); main.addItem(ph)
        let pm = NSMenu(title: "Phones")
        for (t, s) in [("Scan now", #selector(menuScan)), ("Add an address…", #selector(menuAddr)), ("Pair a phone…", #selector(menuPair)), ("Switch on Wi-Fi access for the phone on USB", #selector(menuTcpip))] {
            let it = NSMenuItem(title: t, action: s, keyEquivalent: ""); it.target = self; pm.addItem(it)
        }
        ph.submenu = pm
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
    @objc func menuScan() { Discovery.shared.scanNow() }
    @objc func menuAddr() { addAddress() }
    @objc func menuPair() { pairPhone() }
    @objc func menuTcpip() { if tabs.indices.contains(active) { enableTcpip(tabs[active].phoneId) } }

    // MARK: layout
    func layoutAll() {
        let w = root.bounds.width, h = root.bounds.height
        if immersive {
            for t in tabs { t.view.frame = root.bounds }
            for v in [tabBar, hl1, panel, status] as [NSView] { v.isHidden = true }
            for v in sliderRow { v.isHidden = true }
            return
        }
        tabBar.isHidden = false; hl1.isHidden = false; status.isHidden = false; panel.isHidden = true
        for v in sliderRow { v.isHidden = false }
        let tabH: CGFloat = 36, bottom: CGFloat = 56
        tabBar.frame = NSRect(x: 0, y: h - tabH, width: w, height: tabH)
        hl1.frame = NSRect(x: 0, y: bottom, width: w, height: 1)
        let area = NSRect(x: 0, y: bottom + 1, width: w, height: max(0, h - tabH - bottom - 1))
        for t in tabs { t.view.frame = area }
        panel.frame = area
        center(sliderRow, y: bottom - 40, spacing: 12)
        status.frame = NSRect(x: 12, y: h / 2 - 9, width: w - 24, height: 18)
        permBtn.frame = NSRect(x: w - 112, y: h - 28, width: 104, height: 20)
    }
    func center(_ views: [NSView], y: CGFloat, spacing: CGFloat) {
        var sizes: [NSSize] = []
        for v in views {
            if v === slider { sizes.append(NSSize(width: max(70, min(180, root.bounds.width - 330)), height: 18)) }
            else if v === pvValue { sizes.append(NSSize(width: 70, height: 20)) }
            else if v === rotBtn { sizes.append(NSSize(width: 48, height: 40)) }
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
                t.view.onDouble = { [weak self] in self?.toggleImmersive() }
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
        applyAudio()
        lastUserVol = .distantPast; lastVolPoll = .distantPast; pollVolume()
        refreshTabs(); refreshStatus()
        window.makeFirstResponder(t.view)
    }

    func close(_ i: Int) {
        guard i >= 0, i < tabs.count else { return }
        let t = tabs.remove(at: i)
        closedIds.insert(t.phoneId)
        let sess = t.session
        DispatchQueue.global().async { sess.restorePhone(); sess.stop() }
        t.view.removeFromSuperview()
        active = min(active, max(0, tabs.count - 1))
        save(); refreshTabs()
        if !tabs.isEmpty { select(active) }
        refreshStatus(); reloadPanel()
    }

    func refreshTabs() {
        tabBar.live = tabs.map { $0.session.status == "LIVE" }
        tabBar.titles = tabs.map { $0.title }
        tabBar.selected = active
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
    func applyAudio() {
        for t in tabs where !t.session.audio.enabled { t.session.audio.enabled = true }   // every phone's sound, pre-fader, to the Mac's default output
    }

    // The slider is the phone's own media volume, two ways: moving it sets the phone, a change on the phone moves it.
    // (The Mac listens pre-fader, so this never changes what you hear.)
    // Rotation: the phone is asked to turn (`cmd window user-rotation lock`, auto-rotate stays off). If the app in front
    // keeps the phone upright (the home screen does), the PICTURE is turned by the capture instead, so the view is landscape anyway.
    // v20 (14.11.2026): a press is one request that is seen through. While it is on its way the button is dimmed and further
    // presses wait (before, a second press 2-3 s later undid the first one: "it rotates and comes back"). The phone is asked
    // (auto-rotate off, ignore-orientation-request, fixed-to-user-rotation, user-rotation lock), read back every 0.4 s for 5 s
    // and asked again once if it did not turn; then for 20 s a guard puts it back if the phone or an app resets it.
    var wantLandscape: [String: Bool] = [:]
    var rotPending: [String: Date] = [:]          // phone id -> when the request was sent (dimmed button, presses ignored)
    @objc func toggleRotation() {
        guard let s = cur(), s.width > 0, tabs.indices.contains(active) else { return }
        let id = tabs[active].phoneId
        if rotPending[id] != nil { logLine("rotation \(id): press ignored, the last one is still on its way"); return }
        rotate(s.width > s.height ? 0 : 1)        // one press turns the phone from what it really shows now
    }
    func realRotation(_ ser: String) -> Int? {
        let out = adb(ser, ["shell", "dumpsys window displays | grep -m1 mCurrentRotation"], timeout: 8)
        guard let r = out.range(of: "ROTATION_") else { return nil }
        guard let deg = Int(out[r.upperBound...].prefix(while: { $0.isNumber })) else { return nil }
        return deg >= 90 ? deg / 90 : deg          // ROTATION_90 is 1
    }
    static func askRotation(_ ser: String, _ n: Int) {
        _ = adb(ser, ["shell", "settings put system accelerometer_rotation 0; cmd window set-ignore-orientation-request -d 0 \(n == 1 ? "true" : "false"); cmd window fixed-to-user-rotation -d 0 \(n == 1 ? "enabled" : "default"); settings put system user_rotation \(n); cmd window user-rotation -d 0 lock \(n)"], timeout: 10)
    }
    func rotate(_ n: Int) {
        guard tabs.indices.contains(active), !tabs[active].session.serial.isEmpty else { return }
        let t = tabs[active]
        let id = t.phoneId
        wantLandscape[id] = (n == 1)
        rotPending[id] = Date()
        rotBtn.landscape = (n == 1); rotBtn.alphaValue = 0.45
        let ser = t.session.serial
        DispatchQueue.global().async { [weak self] in
            let t0 = Date()
            Controller.askRotation(ser, n)
            var real = self?.realRotation(ser)
            var asked = 1
            while real != n && Date().timeIntervalSince(t0) < 5 {
                usleep(400_000)
                real = self?.realRotation(ser)
                if real != n && asked == 1 && Date().timeIntervalSince(t0) > 2.5 { Controller.askRotation(ser, n); asked = 2 }
            }
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            logLine("rotation \(ser): asked \(n) (\(asked)x), real rotation \(real.map { String($0) } ?? "?") after \(ms) ms")
            // the press stays "on its way" until the picture on the Mac has turned too (paintRotation), at most 6 s
            // the guard: for 20 s the phone is kept where it was asked to be
            var fixes = 0
            while Date().timeIntervalSince(t0) < 25 && fixes < 4 {
                usleep(1_500_000)
                guard let me = self, me.wantLandscape[id] == (n == 1) else { return }     // a newer press took over
                if let r = me.realRotation(ser), r != n {
                    fixes += 1
                    logLine("rotation \(ser): the phone went back to \(r), asked \(n) again (guard \(fixes))")
                    Controller.askRotation(ser, n)
                }
            }
        }
    }
    /// The window turns with the phone: its shape follows the picture, around the same centre.
    var lastLand: Bool?
    func reshapeWindow(_ land: Bool) {
        if lastLand == nil { lastLand = land; return }
        if lastLand == land { return }
        lastLand = land
        if immersive || window.styleMask.contains(.fullScreen) { return }
        let f = window.frame
        let vis = window.screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1600, height: 1000)
        let w = min(f.height, vis.width), h = min(f.width, vis.height)
        var nf = NSRect(x: f.midX - w / 2, y: f.midY - h / 2, width: w, height: h)
        nf.origin.x = max(vis.minX, min(nf.origin.x, vis.maxX - w)); nf.origin.y = max(vis.minY, min(nf.origin.y, vis.maxY - h))
        window.setFrame(nf, display: true, animate: true)
    }
    func paintRotation() {
        guard let s = cur(), s.width > 0 else { return }
        let land = s.width > s.height
        // the button shows the request until the picture follows; only then (at least 1.5 s, at most 6 s) the next press counts
        if tabs.indices.contains(active), let t0 = rotPending[tabs[active].phoneId] {
            let id = tabs[active].phoneId
            let age = Date().timeIntervalSince(t0)
            if (age >= 1.5 && land == (wantLandscape[id] ?? land)) || age > 6 { rotPending[id] = nil; rotBtn.alphaValue = 1 } else { return }
        }
        if rotBtn.landscape != land { rotBtn.landscape = land }
        reshapeWindow(land)
    }

    @objc func volumeChanged() {
        lastUserVol = Date()
        pvValue.stringValue = "\(Int(slider.doubleValue.rounded())) / \(Int(slider.maxValue))"
        if NSApp.currentEvent?.type == .leftMouseUp || NSApp.currentEvent?.type == .keyDown || NSApp.currentEvent == nil { setPhoneVolume(Int(slider.doubleValue.rounded())) }
    }
    func parseVol(_ s: String) -> (Int, Int)? {
        guard let r = s.range(of: "volume is ") else { return nil }
        let rest = s[r.upperBound...]
        let v = Int(rest.prefix(while: { $0.isNumber })) ?? -1
        guard v >= 0, let r2 = rest.range(of: "..") else { return nil }
        let mx = Int(rest[r2.upperBound...].prefix(while: { $0.isNumber })) ?? -1
        return mx >= 0 ? (v, mx) : nil
    }
    func getVol(_ serial: String) -> (Int, Int)? {
        parseVol(adb(serial, ["shell", "cmd", "media_session", "volume", "--stream", "3", "--get"], timeout: 8))
    }
    /// Sets the phone's media volume and reads it back; if `cmd media_session` does not take, the volume keys are pressed until it does.
    func setPhoneVol(_ ser: String, _ target: Int) -> (Int, Int)? {
        guard let (v0, mx) = getVol(ser) else { return nil }
        let nv = max(0, min(mx, target))
        if nv == v0 { return (v0, mx) }
        _ = adb(ser, ["shell", "cmd", "media_session", "volume", "--stream", "3", "--set", "\(nv)"], timeout: 10)
        var back = getVol(ser)
        for _ in 0..<6 where back?.0 != nv { usleep(300_000); back = getVol(ser) }      // the phone takes a moment to apply it
        var how = "media_session"
        if back?.0 != nv {
            how = "keyevent"
            var cur = back?.0 ?? v0
            var n = 0
            while cur != nv && n < 40 {
                _ = adb(ser, ["shell", "input", "keyevent", cur < nv ? "24" : "25"], timeout: 6)
                n += 1
                usleep(250_000)
                cur = getVol(ser)?.0 ?? cur
            }
            back = getVol(ser)
        }
        logLine("phone volume \(ser): \(v0) -> \(nv) via \(how), read back \(back.map { "\($0.0)" } ?? "?")")
        return back
    }
    func setPhoneVolume(_ value: Int) {
        guard tabs.indices.contains(active), !tabs[active].session.serial.isEmpty else { return }
        let ser = tabs[active].session.serial
        volBusy = true
        DispatchQueue.global().async { [weak self] in
            let r = self?.setPhoneVol(ser, value)
            DispatchQueue.main.async { self?.volBusy = false; self?.lastUserVol = Date(); self?.show(r) }
        }
    }
    func show(_ r: (Int, Int)?) {
        guard let r = r else { pvValue.stringValue = "— / —"; return }
        pvValue.stringValue = "\(r.0) / \(r.1)"
        slider.maxValue = Double(max(1, r.1)); slider.doubleValue = Double(r.0)
    }
    /// About once a second: read the active phone's volume, so the slider follows its own buttons.
    func pollVolume() {
        if volBusy || Date().timeIntervalSince(lastUserVol) < 1.5 || Date().timeIntervalSince(lastVolPoll) < 1 { return }
        guard tabs.indices.contains(active), !tabs[active].session.serial.isEmpty else { return }
        lastVolPoll = Date(); volBusy = true
        let ser = tabs[active].session.serial
        DispatchQueue.global().async { [weak self] in
            let r = self?.getVol(ser)
            DispatchQueue.main.async { self?.volBusy = false; if let r = r, self?.tabs.indices.contains(self?.active ?? 0) == true, self?.tabs[self!.active].session.serial == ser { self?.show(r) } }
        }
    }

    @objc func permClicked() { MicPermission.clicked(); lastPermCheck = .distantPast }
    func tick() {
        if Date().timeIntervalSince(lastPermCheck) > 2 {
            lastPermCheck = Date()
            permBtn.isHidden = MicLink.allowed() || immersive
            permBtn.frame = NSRect(x: root.bounds.width - 112, y: root.bounds.height - 28, width: 104, height: 20)
        }
        refreshStatus()
        pollVolume()
        paintRotation()
        if immersive && !cursorHidden && Date().timeIntervalSince(lastMouse) > 2 { NSCursor.hide(); cursorHidden = true }
        refreshTabs()
        if Date().timeIntervalSince(lastLog) > 5 {
            lastLog = Date()
            for t in tabs { logLine("\(t.title): \(t.session.status) \(t.session.width)x\(t.session.height) frames \(t.session.framesTotal) fps \(t.session.fps) \(t.session.audioState) packets \(t.session.audio.packets) level \(Int(t.session.audio.levelDb)) dB \(t.session.audio.statsLine())") }
        }
    }

    func refreshStatus() {
        for t in tabs { t.view.showNote(t.session.status == "LIVE" ? nil : t.session.status) }
        guard let t = tabs.indices.contains(active) ? tabs[active] : nil else { status.stringValue = Discovery.shared.firstDone ? "NO PHONE FOUND · PLUG ONE IN OR TURN ON ITS WI-FI DEBUGGING" : "LOOKING FOR PHONES…"; return }
        let s = t.session
        let db = s.audio.levelDb <= -100 ? "silent" : "\(Int(s.audio.levelDb)) dB"
        _ = db; status.stringValue = ""
    }

    func application(_ app: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "screencopy" {
            if u.host == "tab", let n = Int(u.lastPathComponent) { panelShown = false; panel.isHidden = true; select(n - 1) }
            if u.host == "volume", let n = Int(u.lastPathComponent) { setPhoneVolume(n) }
            if u.host == "audiorec", let n = Int(u.lastPathComponent), tabs.indices.contains(active) { tabs[active].session.audio.startRecording(seconds: max(1, min(120, n))) }
            if u.host == "jitter", let n = Int(u.lastPathComponent) { for t in tabs { t.session.audio.setFixedTarget(ms: n) } }
            if u.host == "rotate" { toggleRotation() }          // test hook: the same as a press on the button
            if u.host == "window" { logLine("window number \(window.windowNumber)") }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ a: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) {
        let g = DispatchGroup()
        for t in tabs { g.enter(); DispatchQueue.global().async { t.session.restorePhone(); g.leave() } }
        _ = g.wait(timeout: .now() + 7)
        for t in tabs { t.session.stop() }
        MicLink.shared.removeAllReverse()
    }
}

