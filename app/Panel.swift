import AppKit

/// One card per physical phone: its name, its routes as badges (USB / Wi-Fi / Tailscale with measured ms).
final class PhoneCard: NSView {
    let phone: Phone
    var open = false
    var activeAddr: String?
    var forced: String?
    var onOpen: ((String) -> Void)?
    var onRoute: ((String, String) -> Void)?
    var onTcpip: ((String) -> Void)?
    private let title: NSTextField
    private var badges: [WordButton] = []
    private var sep: [NSTextField] = []
    private var tcpip: WordButton?
    private var hover = false

    init(phone: Phone, open: Bool, activeAddr: String?, forced: String?) {
        self.phone = phone; self.open = open; self.activeAddr = activeAddr; self.forced = forced
        title = label((open ? "● " : "") + phone.name, size: 15, color: BRIGHT)
        title.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor
        addSubview(title)
        let rs = phone.routes.sorted { (linkRank($0.link), $0.rtt) < (linkRank($1.link), $1.rtt) }
        for (i, r) in rs.enumerated() {
            if i > 0 { let p = label("|", size: 12, color: DIM); sep.append(p); addSubview(p) }
            let mark = (r.addr == activeAddr) ? "● " : ""
            let b = WordButton("\(mark)\(r.link.uppercased()) \(r.rtt) ms", target: self, action: #selector(routeTapped(_:)))
            b.identifier = NSUserInterfaceItemIdentifier(r.addr)
            b.normal = (r.addr == forced) ? ACCENT : BRIGHT
            b.setAccessibilityLabel("Use route \(r.link) \(r.addr)")
            badges.append(b); addSubview(b)
        }
        let hasUSB = phone.routes.contains { $0.link == "USB" }
        let hasNet = phone.routes.contains { $0.link != "USB" }
        if hasUSB && !hasNet {
            let t = WordButton("ENABLE WI-FI AND TAILSCALE ACCESS", target: self, action: #selector(tcpipTapped))
            t.normal = DIM
            tcpip = t; addSubview(t)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func routeTapped(_ s: NSButton) { if let a = s.identifier?.rawValue { onRoute?(phone.id, a) } }
    @objc func tcpipTapped() { onTcpip?(phone.id) }
    override func mouseDown(with event: NSEvent) { onOpen?(phone.id) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { layer?.borderColor = ACCENT.cgColor }
    override func mouseExited(with event: NSEvent) { layer?.borderColor = NSColor(white: 1, alpha: 0.18).cgColor }
    override func layout() {
        super.layout()
        let w = bounds.width
        title.frame = NSRect(x: 8, y: bounds.height - 30, width: w - 16, height: 20)
        // badges row, centred
        var items: [NSView] = []
        for (i, b) in badges.enumerated() { if i > 0 { items.append(sep[i - 1]) }; items.append(b) }
        var sizes = items.map { v -> CGFloat in v.sizeToFit(); return ceil(v.frame.width) + 2 }
        let total = sizes.reduce(0, +) + 10 * CGFloat(max(0, items.count - 1))
        var x = (w - total) / 2
        for (i, v) in items.enumerated() { v.frame = NSRect(x: x, y: bounds.height - 58, width: sizes[i], height: 20); x += sizes[i] + 10 }
        sizes.removeAll()
        if let t = tcpip { t.sizeToFit(); let tw = ceil(t.frame.width) + 2; t.frame = NSRect(x: (w - tw) / 2, y: 6, width: tw, height: 20) }
    }
}

/// The phones found, one card each, over the picture area. Footer in the same place always: SCAN NOW | ADD AN ADDRESS | PAIR A PHONE.
final class PhonesPanel: NSView {
    var cards: [PhoneCard] = []
    let heading = label("", size: 12, color: DIM)
    var footer: [NSView] = []
    var onOpen: ((String) -> Void)?
    var onRoute: ((String, String) -> Void)?
    var onTcpip: ((String) -> Void)?
    var onScan: (() -> Void)?
    var onAddr: (() -> Void)?
    var onPair: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.06, alpha: 0.97).cgColor
        addSubview(heading)
        let scan = WordButton("SCAN NOW", target: self, action: #selector(scanT))
        let addr = WordButton("ADD AN ADDRESS", target: self, action: #selector(addrT))
        let pair = WordButton("PAIR A PHONE", target: self, action: #selector(pairT))
        var f: [NSView] = []
        for (i, b) in [scan, addr, pair].enumerated() { if i > 0 { f.append(label("|", size: 12, color: DIM)) }; f.append(b) }
        footer = f
        for v in f { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func scanT() { onScan?() }
    @objc func addrT() { onAddr?() }
    @objc func pairT() { onPair?() }

    func reload(phones: [Phone], tabs: [String: (open: Bool, active: String?, forced: String?)], searching: Bool) {
        for c in cards { c.removeFromSuperview() }
        cards = phones.map { p in
            let t = tabs[p.id]
            let c = PhoneCard(phone: p, open: t?.open ?? false, activeAddr: t?.active, forced: t?.forced)
            c.onOpen = { [weak self] in self?.onOpen?($0) }
            c.onRoute = { [weak self] a, b in self?.onRoute?(a, b) }
            c.onTcpip = { [weak self] in self?.onTcpip?($0) }
            addSubview(c); return c
        }
        heading.stringValue = phones.isEmpty ? (searching ? "LOOKING FOR PHONES ON USB, WI-FI AND TAILSCALE…" : "NO PHONE FOUND. PLUG ONE IN, OR PAIR IT.") : "\(phones.count) PHONE\(phones.count == 1 ? "" : "S") FOUND · CLICK A CARD TO OPEN IT"
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        heading.frame = NSRect(x: 12, y: bounds.height - 36, width: w - 24, height: 18)
        let cw = min(440, w - 40), ch: CGFloat = 92
        var y = bounds.height - 56 - ch
        for c in cards { c.frame = NSRect(x: (w - cw) / 2, y: y, width: cw, height: ch); y -= ch + 12 }
        var sizes = footer.map { v -> CGFloat in v.sizeToFit(); return ceil(v.frame.width) + 2 }
        let total = sizes.reduce(0, +) + 12 * CGFloat(max(0, footer.count - 1))
        var x = (w - total) / 2
        for (i, v) in footer.enumerated() { v.frame = NSRect(x: x, y: 14, width: sizes[i], height: 20); x += sizes[i] + 12 }
        sizes.removeAll()
    }
}
