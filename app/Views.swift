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
/// v29: the hairline meter of the TTT keyboard (MaRecordMeter.kt): 3 dp rounded track at 18 % tint, fill green / orange
/// (> -12 dB) / red (> -3 dB), floor -54 dB, peak hold 2 px falling 0.6 dB per 60 ms. Phone sound is stereo, so (manifest
/// vu-meter-mono-stereo) two thin bars with a small gap, no line, no labels.
final class MeterView: NSView {
    var db: (Double, Double) = (-120, -120) { didSet { needsDisplay = true } }
    var dim = false { didSet { needsDisplay = true } }
    private var peak: (Double, Double) = (-54, -54)
    private var lastPeak = Date()
    private static let floorDb = -54.0
    private func norm(_ d: Double) -> CGFloat { CGFloat(max(0, min(1, (d - Self.floorDb) / -Self.floorDb))) }
    private func colour(_ d: Double) -> NSColor {
        d > -3 ? NSColor(red: 0.608, green: 0.231, blue: 0.2, alpha: 1) : d > -12 ? NSColor(red: 0.941, green: 0.533, blue: 0.243, alpha: 1) : NSColor(red: 0.337, green: 0.827, blue: 0.392, alpha: 1)
    }
    func step() {
        let now = Date(); let k = max(1, now.timeIntervalSince(lastPeak) / 0.06) * 0.6; lastPeak = now
        peak.0 = db.0 > peak.0 ? db.0 : max(Self.floorDb, peak.0 - k)
        peak.1 = db.1 > peak.1 ? db.1 : max(Self.floorDb, peak.1 - k)
        needsDisplay = true
    }
    override var isFlipped: Bool { false }
    override func draw(_ r: NSRect) {
        let a: CGFloat = dim ? 0.45 : 1
        let bh = (bounds.height - 1) / 2, w = bounds.width
        let rows: [(CGFloat, Double, Double)] = [(bh + 1, db.0, peak.0), (0, db.1, peak.1)]
        for (y, d, p) in rows {
            let tr = NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: w, height: bh), xRadius: bh / 2, yRadius: bh / 2)
            NSColor(white: 1, alpha: 0.18 * a).setFill(); tr.fill()
            let f = w * norm(d)
            if f > 0 { colour(d).withAlphaComponent(a).setFill(); NSBezierPath(roundedRect: NSRect(x: 0, y: y, width: max(f, bh), height: bh), xRadius: bh / 2, yRadius: bh / 2).fill() }
            let px = min(w - 2, w * norm(p))
            colour(p).withAlphaComponent(0.9 * a).setFill(); NSBezierPath(roundedRect: NSRect(x: px, y: y, width: 2, height: bh), xRadius: 1, yRadius: 1).fill()
        }
    }
}

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
    private(set) var meters: [MeterView] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        plus = WordButton("+", target: self, action: #selector(addTapped))
        plus.setAccessibilityLabel("Add a phone")
        addSubview(line); addSubview(under); addSubview(plus); plus.isHidden = true
        under.wantsLayer = true; under.layer?.backgroundColor = ACCENT.cgColor
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func addTapped() { onAdd?(plus) }
    @objc func tabTapped(_ s: NSButton) { onSelect?(s.tag) }
    @objc func closeTapped(_ s: NSButton) { onClose?(s.tag) }

    private func rebuild() {
        for v in items { v.removeFromSuperview() }
        items = []
        for m in meters { m.removeFromSuperview() }
        meters = []
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
            let m = MeterView(); m.setAccessibilityElement(false); addSubview(m); meters.append(m)
            items += [b, x]
        }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let n = titles.count
        let tabW: CGFloat = n == 0 ? 0 : min(190, (bounds.width - 104) / CGFloat(n))
        let total = tabW * CGFloat(n) + 28
        var x = (bounds.width - total) / 2
        let h = bounds.height
        for i in 0..<n {
            let b = items[2 * i] as! WordButton, c = items[2 * i + 1] as! WordButton
            let cw: CGFloat = 20
            b.frame = NSRect(x: x, y: 10, width: tabW - cw, height: h - 14)
            if i < meters.count { meters[i].frame = NSRect(x: x + 8, y: 4, width: max(10, tabW - cw - 16), height: 5) }
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

/// The rotation switch, drawn like the one in the MPA app: a thin grey rounded rectangle, tall in portrait and wide in landscape,
/// nothing else (MPA_ACADEMY_ANDROID Views.kt OrientView: 16x26 / 26x16 dp, stroke 2 dp, corner 3 dp, grey 8B8F94, amber 20 % when pressed).
final class RoundIconButton: NSButton {
    private var area: NSTrackingArea?
    private var hover = false
    var landscape = false { didSet { needsDisplay = true } }
    init(target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; title = ""
        setButtonType(.momentaryChange)
        setAccessibilityLabel("Rotate the phone")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let k: CGFloat = 1.5                                   // one MPA dp is 1.5 points here
        if hover || isHighlighted {
            NSColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.2).setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 6 * k, yRadius: 6 * k).fill()
        }
        let w = (landscape ? 26 : 16) * k, h = (landscape ? 16 : 26) * k
        let r = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
        let p = NSBezierPath(roundedRect: r, xRadius: 3 * k, yRadius: 3 * k)
        p.lineWidth = 2 * k
        NSColor(red: 0.545, green: 0.561, blue: 0.580, alpha: 1).setStroke()
        p.stroke()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let a = area { removeTrackingArea(a) }
        area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area!)
    }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }
}
