import AppKit

let ACCENT = NSColor(red: 1.0, green: 0.62, blue: 0.12, alpha: 1)
let DIM = NSColor(white: 0.55, alpha: 1)
let BRIGHT = NSColor(white: 0.95, alpha: 1)

/// A word as a button: text only, brighter with an underline under the pointer, no bezel.
final class WordButton: NSButton {
    var normal = BRIGHT { didSet { paint(false) } }
    private var area: NSTrackingArea?
    var word: String { didSet { paint(false) } }
    init(_ word: String, target: AnyObject?, action: Selector?) {
        self.word = word
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false
        setButtonType(.momentaryChange)
        setAccessibilityLabel(word)
        paint(false)
    }
    required init?(coder: NSCoder) { fatalError() }
    func paint(_ hover: Bool) {
        var a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: hover ? ACCENT : normal, .kern: 0.8]
        if hover { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        attributedTitle = NSAttributedString(string: word, attributes: a)
        setAccessibilityLabel(word)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { paint(true); NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { paint(false); NSCursor.arrow.set() }
    override var intrinsicContentSize: NSSize { attributedTitle.size() }
}

func hairline() -> NSView {
    let v = NSView(); v.wantsLayer = true; v.layer?.backgroundColor = NSColor(white: 1, alpha: 0.16).cgColor; return v
}

func label(_ s: String, size: CGFloat = 11, color: NSColor = DIM) -> NSTextField {
    let t = NSTextField(labelWithString: s)
    t.font = NSFont.systemFont(ofSize: size, weight: .medium)
    t.textColor = color
    t.alignment = .center
    t.lineBreakMode = .byTruncatingMiddle
    return t
}

/// The phone's picture. Touches, scroll, keys and paste go back to the phone.
final class VideoView: NSView {
    let session: Session
    let note = label("", size: 14, color: BRIGHT)
    private var touching = false
    init(session: Session) {
        self.session = session
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(session.layer)
        addSubview(note)
        note.isHidden = true
        setAccessibilityLabel("Phone screen \(session.serial)")
    }
    required init?(coder: NSCoder) { fatalError() }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        session.layer.frame = bounds
        CATransaction.commit()
        note.sizeToFit()
        note.frame = NSRect(x: 8, y: bounds.midY - note.frame.height / 2, width: bounds.width - 16, height: note.frame.height)
    }
    func showNote(_ s: String?) {
        note.isHidden = (s == nil)
        if let s = s { note.stringValue = s; needsLayout = true }
    }
    var videoRect: NSRect {
        let w = CGFloat(session.width), h = CGFloat(session.height)
        if w == 0 || h == 0 { return .zero }
        let sc = min(bounds.width / w, bounds.height / h)
        return NSRect(x: bounds.midX - w * sc / 2, y: bounds.midY - h * sc / 2, width: w * sc, height: h * sc)
    }
    private func phonePoint(_ e: NSEvent, clamp: Bool) -> (Int, Int)? {
        let p = convert(e.locationInWindow, from: nil)
        let r = videoRect
        if r.width == 0 { return nil }
        if !clamp && !r.contains(p) { return nil }
        let x = (p.x - r.minX) / r.width * CGFloat(session.width)
        let y = (r.maxY - p.y) / r.height * CGFloat(session.height)
        return (Int(x), Int(y))
    }
    var onDouble: (() -> Void)?
    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        if e.clickCount == 2 { onDouble?(); return }
        guard let (x, y) = phonePoint(e, clamp: false) else { return }
        touching = true; session.touch(action: 0, x: x, y: y)
    }
    override func mouseDragged(with e: NSEvent) {
        guard touching, let (x, y) = phonePoint(e, clamp: true) else { return }
        session.touch(action: 2, x: x, y: y)
    }
    override func mouseUp(with e: NSEvent) {
        guard touching, let (x, y) = phonePoint(e, clamp: true) else { return }
        touching = false; session.touch(action: 1, x: x, y: y)
    }
    override func rightMouseDown(with e: NSEvent) { session.key(4) }       // back
    override func otherMouseDown(with e: NSEvent) { session.key(3) }       // home
    override func scrollWheel(with e: NSEvent) {
        guard let (x, y) = phonePoint(e, clamp: false) else { return }
        session.scroll(x: x, y: y, h: Double(e.scrollingDeltaX) / 4, v: Double(e.scrollingDeltaY) / 4)
    }
    override func keyDown(with e: NSEvent) {
        let f = e.modifierFlags
        if f.contains(.command) {
            if e.charactersIgnoringModifiers == "v", let s = NSPasteboard.general.string(forType: .string) { session.paste(s) }
            return
        }
        let map: [UInt16: UInt32] = [36: 66, 51: 67, 117: 112, 48: 61, 53: 4, 123: 21, 124: 22, 125: 20, 126: 19]
        if let k = map[e.keyCode] { session.key(k); return }
        if !f.contains(.control), let s = e.characters, !s.isEmpty, s.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }) { session.text(s) }
    }
}

/// The tab strip: one tab per phone (title, close), then +. Always centred.
final class TabBar: NSView {
    var live: [Bool] = [] { didSet { if live != oldValue { rebuild() } } }
    var titles: [String] = [] { didSet { if titles != oldValue { rebuild() } } }
    var selected = 0 { didSet { if selected != oldValue { rebuild() } } }
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?
    var onAdd: ((NSView) -> Void)?
    private var items: [NSView] = []
    private var plus: WordButton!
    private var line = hairline()
    private var under = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus = WordButton("+", target: self, action: #selector(addTapped))
        plus.setAccessibilityLabel("Add a phone")
        addSubview(line); addSubview(under); addSubview(plus)
        under.wantsLayer = true; under.layer?.backgroundColor = ACCENT.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func addTapped() { onAdd?(plus) }
    @objc func tabTapped(_ s: NSButton) { onSelect?(s.tag) }
    @objc func closeTapped(_ s: NSButton) { onClose?(s.tag) }

    private func rebuild() {
        for v in items { v.removeFromSuperview() }
        items = []
        for (i, t) in titles.enumerated() {
            let b = WordButton(t, target: self, action: #selector(tabTapped(_:)))
            b.tag = i
            let isLive = i < live.count ? live[i] : true
            b.normal = !isLive ? NSColor(white: 0.32, alpha: 1) : ((i == selected) ? BRIGHT : DIM)
            b.setAccessibilityLabel("Tab \(t)")
            let x = WordButton("✕", target: self, action: #selector(closeTapped(_:)))
            x.tag = i; x.normal = DIM
            x.setAccessibilityLabel("Close tab \(t)")
            addSubview(b); addSubview(x)
            items += [b, x]
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let n = titles.count
        let tabW: CGFloat = n == 0 ? 0 : min(190, (bounds.width - 60) / CGFloat(n))
        let total = tabW * CGFloat(n) + 28
        var x = (bounds.width - total) / 2
        let h = bounds.height
        for i in 0..<n {
            let b = items[2 * i] as! WordButton, c = items[2 * i + 1] as! WordButton
            let cw: CGFloat = 20
            b.frame = NSRect(x: x, y: 4, width: tabW - cw, height: h - 8)
            b.alignment = .center
            b.lineBreakMode = .byTruncatingTail
            c.frame = NSRect(x: x + tabW - cw, y: 4, width: cw, height: h - 8)
            if i == selected { under.frame = NSRect(x: x + 6, y: 0, width: tabW - 12, height: 2) }
            x += tabW
        }
        under.isHidden = n == 0
        plus.frame = NSRect(x: x, y: 4, width: 28, height: h - 8)
        line.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
    }
}

/// Natural width of a button or label.
func fitW(_ v: NSView) -> CGFloat {
    if let c = v as? NSControl { c.sizeToFit() }
    return ceil(v.frame.width) + 2
}
