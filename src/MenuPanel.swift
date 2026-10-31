import Cocoa

// ── Панель в меню строки меню ────────────────────────────────────────────────
// Крупные ниты, толстая шкала как в Пункте управления (белая до штатных 600,
// жёлтая зона XDR за разрывом), ряд уровней, тумблеры, плашки-предупреждения.
final class MenuPanel: NSView {

    static let width: CGFloat = 300

    var onPosition: ((Double) -> Void)?
    var onNits: ((Double) -> Void)?
    var onEnabled: ((Bool) -> Void)?
    var onKeys: ((Bool) -> Void)?
    var onLogin: ((Bool) -> Void)?
    var onFixBetterDisplay: (() -> Void)?
    var onFixAccess: (() -> Void)?

    private let value = NSTextField(labelWithString: "")
    private let unit = NSTextField(labelWithString: "нит")
    private let badge = NSTextField(labelWithString: "")
    private let gauge = Gauge()
    private let chips = NSStackView()
    private var chipViews: [Chip] = []
    private let bdBanner = Banner(text: "BetterDisplay перехватывает подсветку у Lumen.",
                                  button: "Закрыть BetterDisplay")
    private let accessBanner = Banner(text: "Без Универсального доступа клавиши F1/F2 меняют яркость в обход Lumen.",
                                      button: "Открыть настройки")
    private let enabledRow = ToggleRow("Lumen управляет яркостью")
    private let keysRow = ToggleRow("Клавиши яркости через Lumen")
    private let loginRow = ToggleRow("Открывать при входе в систему")
    private let stack = NSStackView()

    init(levels: [(symbol: String, nits: Double)]) {
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 300))

        value.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold).rounded
        unit.font = .systemFont(ofSize: 15, weight: .medium).rounded
        unit.textColor = .secondaryLabelColor
        badge.font = .systemFont(ofSize: 13, weight: .semibold).rounded
        badge.alignment = .right

        let readout = NSStackView(views: [value, unit, NSView(), badge])
        readout.alignment = .firstBaseline
        readout.spacing = 4

        gauge.onChange = { [weak self] in self?.onPosition?($0) }

        chips.distribution = .equalSpacing
        for level in levels {
            let c = Chip(symbol: level.symbol, nits: level.nits)
            c.onTap = { [weak self] in self?.onNits?(level.nits) }
            chipViews.append(c)
            chips.addArrangedSubview(c)
        }

        bdBanner.onTap = { [weak self] in self?.onFixBetterDisplay?() }
        accessBanner.onTap = { [weak self] in self?.onFixAccess?() }
        enabledRow.onChange = { [weak self] in self?.onEnabled?($0) }
        keysRow.onChange = { [weak self] in self?.onKeys?($0) }
        loginRow.onChange = { [weak self] in self?.onLogin?($0) }

        let toggles = NSStackView(views: [enabledRow, keysRow, loginRow])
        toggles.orientation = .vertical
        toggles.spacing = 2

        for v in [readout, gauge, chips, bdBanner, accessBanner, Divider(), toggles] as [NSView] {
            stack.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28).isActive = true
        }
        stack.orientation = .vertical
        stack.spacing = 12
        stack.setCustomSpacing(10, after: readout)
        stack.setCustomSpacing(16, after: gauge)
        stack.setCustomSpacing(16, after: chips)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 8, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: Self.width),
            gauge.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    struct State {
        var nits: Double, position: Double, sdrMark: Double, percent: Int
        var boosted: Bool, engaged: Bool, keys: Bool, login: Bool
        var betterDisplay: Bool, needsAccess: Bool
    }

    func update(_ s: State) {
        value.stringValue = "\(Int(s.nits.rounded()))"
        badge.stringValue = !s.engaged ? "яркостью управляет macOS" : s.boosted ? "XDR  \(s.percent) %" : "\(s.percent) %"
        badge.textColor = s.engaged && s.boosted ? .systemYellow : .secondaryLabelColor
        badge.font = .systemFont(ofSize: s.engaged ? 13 : 11, weight: s.engaged ? .semibold : .regular).rounded
        value.textColor = s.engaged ? .labelColor : .tertiaryLabelColor

        gauge.position = s.position
        gauge.sdrMark = s.sdrMark
        gauge.isEnabled = s.engaged
        if !gauge.isTracking { gauge.needsDisplay = true }

        for c in chipViews {
            c.isOn = s.engaged && abs(c.nits - s.nits) < 1
            c.isXDR = c.nits > sdrNits + 0.5
            c.isEnabled = s.engaged
        }
        let relayout = bdBanner.isHidden == s.betterDisplay || accessBanner.isHidden == s.needsAccess
        bdBanner.isHidden = !s.betterDisplay
        accessBanner.isHidden = !s.needsAccess
        enabledRow.isOn = s.engaged
        keysRow.isOn = s.keys
        loginRow.isOn = s.login
        // пересчёт вёрстки дорогой — только когда плашки появились или ушли,
        // а не на каждое движение ползунка
        if relayout || frame.height < 100 { setFrameSize(fittingSize) }
    }

    /// Штатный потолок: всё выше — зона XDR.
    var sdrNits = 600.0
}

// ── Шкала ─────────────────────────────────────────────────────────────────────
private final class Gauge: NSView {

    var position = 0.0, sdrMark = 0.6
    var isEnabled = true { didSet { needsDisplay = true } }
    var onChange: ((Double) -> Void)?
    private(set) var isTracking = false

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirty: NSRect) {
        let r = bounds, rad = r.height / 2
        let alpha: CGFloat = isEnabled ? 1 : 0.4
        let seam = r.width * sdrMark

        // дорожка из двух частей: штатная и XDR, между ними разрыв
        let gap: CGFloat = 3
        let sdrTrack = NSRect(x: 0, y: 0, width: seam - gap / 2, height: r.height)
        let xdrTrack = NSRect(x: seam + gap / 2, y: 0, width: r.width - seam - gap / 2, height: r.height)
        let sdrPath = roundedLeft(sdrTrack, rad), xdrPath = roundedRight(xdrTrack, rad)

        NSColor.labelColor.withAlphaComponent(0.13 * alpha).setFill()
        sdrPath.fill()
        xdrPath.fill()

        let fillW = max(r.height, r.width * position)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: fillW, height: r.height)).addClip()
        NSColor.labelColor.withAlphaComponent(0.92 * alpha).setFill()
        sdrPath.fill()
        NSGraphicsContext.saveGraphicsState()
        xdrPath.addClip()
        NSGradient(starting: NSColor.systemOrange.withAlphaComponent(alpha),
                   ending: NSColor.systemYellow.withAlphaComponent(alpha))?.draw(in: xdrTrack, angle: 0)
        NSGraphicsContext.restoreGraphicsState()
        NSGraphicsContext.restoreGraphicsState()

        // солнце внутри дорожки, как в Пункте управления
        let boosted = position > sdrMark + 0.001
        let name = position < 0.08 ? "sun.min.fill" : boosted ? "sun.max.fill" : "sun.max"
        let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .bold)
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
            let tint = NSColor.black.withAlphaComponent(0.7 * alpha)
            let s = img.size
            let rect = NSRect(x: 9, y: (r.height - s.height) / 2, width: s.width, height: s.height)
            tinted(img, tint).draw(in: rect)
        }
    }

    private func roundedLeft(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.maxX, y: r.minY))
        p.line(to: NSPoint(x: r.minX + rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.minX + rad, y: r.midY), radius: rad, startAngle: 270, endAngle: 90, clockwise: true)
        p.line(to: NSPoint(x: r.maxX, y: r.maxY))
        p.close()
        return p
    }

    private func roundedRight(_ r: NSRect, _ rad: CGFloat) -> NSBezierPath {
        let p = NSBezierPath()
        p.move(to: NSPoint(x: r.minX, y: r.minY))
        p.line(to: NSPoint(x: r.maxX - rad, y: r.minY))
        p.appendArc(withCenter: NSPoint(x: r.maxX - rad, y: r.midY), radius: rad, startAngle: 270, endAngle: 90)
        p.line(to: NSPoint(x: r.minX, y: r.maxY))
        p.close()
        return p
    }

    private func tinted(_ img: NSImage, _ color: NSColor) -> NSImage {
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        out.unlockFocus()
        return out
    }

    // В меню обычные mouseDragged не приходят — ведём перетаскивание сами.
    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isTracking = true
        defer { isTracking = false }
        var e: NSEvent? = event
        while let ev = e {
            let x = convert(ev.locationInWindow, from: nil).x
            position = min(max(Double(x / bounds.width), 0), 1)
            needsDisplay = true
            onChange?(position)
            if ev.type == .leftMouseUp { break }
            e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp])
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard isEnabled else { return }
        position = min(max(position + Double(event.scrollingDeltaY) / 400, 0), 1)
        needsDisplay = true
        onChange?(position)
    }
}

// ── Кнопка уровня ─────────────────────────────────────────────────────────────
private final class Chip: NSView {

    let nits: Double
    var isOn = false { didSet { needsDisplay = true; label.textColor = isOn ? .labelColor : .secondaryLabelColor } }
    var isXDR = false { didSet { needsDisplay = true } }
    var isEnabled = true { didSet { alphaValue = isEnabled ? 1 : 0.4 } }
    var onTap: (() -> Void)?

    private let symbol: String
    private let label = NSTextField(labelWithString: "")
    private var pressed = false { didSet { needsDisplay = true } }
    private let d: CGFloat = 38

    init(symbol: String, nits: Double) {
        self.symbol = symbol
        self.nits = nits
        super.init(frame: .zero)
        label.stringValue = "\(Int(nits))"
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 48),
            heightAnchor.constraint(equalToConstant: d + 18),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = "\(Int(nits)) нит"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirty: NSRect) {
        let circle = NSRect(x: (bounds.width - d) / 2, y: bounds.height - d, width: d, height: d)
        let path = NSBezierPath(ovalIn: circle)
        let fill: NSColor = isOn ? (isXDR ? .systemYellow : .labelColor)
                                 : .labelColor.withAlphaComponent(pressed ? 0.22 : 0.12)
        fill.setFill()
        path.fill()

        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        else { return }
        let tint: NSColor = isOn ? .black.withAlphaComponent(0.8) : (isXDR ? .systemYellow : .labelColor)
        let out = NSImage(size: img.size)
        out.lockFocus()
        img.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        tint.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.draw(in: NSRect(x: circle.midX - img.size.width / 2, y: circle.midY - img.size.height / 2,
                            width: img.size.width, height: img.size.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true
        if trackClick(self, event) { onTap?() }
        pressed = false
    }
}

// ── Тумблер ───────────────────────────────────────────────────────────────────
// Свой, а не NSSwitch: меню никогда не бывает активным окном, и системный
// переключатель там всегда серый — «вкл» не отличить от «выкл».
private final class ToggleRow: NSView {

    var onChange: ((Bool) -> Void)?
    var isOn = false { didSet { knob.isOn = isOn } }
    private let knob = Switch()

    init(_ title: String) {
        super.init(frame: .zero)
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        for v in [label, knob] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.trailingAnchor.constraint(equalTo: trailingAnchor),
            knob.centerYAnchor.constraint(equalTo: centerYAnchor),
            knob.widthAnchor.constraint(equalToConstant: 34),
            knob.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    // щёлкнуть можно по всей строке, не только по переключателю
    override func mouseDown(with event: NSEvent) {
        guard trackClick(self, event) else { return }
        isOn.toggle()
        onChange?(isOn)
    }

    private final class Switch: NSView {
        var isOn = false { didSet { needsDisplay = true } }
        override func draw(_ dirty: NSRect) {
            let r = bounds, rad = r.height / 2
            (isOn ? NSColor.controlAccentColor : NSColor.labelColor.withAlphaComponent(0.18)).setFill()
            NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()
            let d = r.height - 4
            let knob = NSRect(x: isOn ? r.maxX - d - 2 : 2, y: 2, width: d, height: d)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = .black.withAlphaComponent(0.3); sh.shadowBlurRadius = 2; sh.shadowOffset = .init(width: 0, height: -1)
            sh.set()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: knob).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // клики уходят строке
    }
}

// ── Плашка-предупреждение ─────────────────────────────────────────────────────
private final class Banner: NSView {

    var onTap: (() -> Void)?

    init(text: String, button: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor

        let icon = NSImageView(image: NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: nil)!)
        icon.contentTintColor = .systemYellow
        icon.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        // 300 − поля меню 28 − отступы плашки 20 − значок 16 − зазор 8
        label.preferredMaxLayoutWidth = MenuPanel.width - 72
        let b = NSButton(title: button, target: self, action: #selector(tap))
        b.bezelStyle = .push
        b.controlSize = .small

        for v in [icon, label, b] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            b.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -4),
            b.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            b.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tap() { onTap?() }
}

/// В меню mouseUp до вида доходит не всегда — ждём отпускания сами.
/// true, если кнопку отпустили внутри вида.
private func trackClick(_ view: NSView, _ down: NSEvent) -> Bool {
    guard let window = view.window else { return false }
    while let e = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) {
        if e.type == .leftMouseUp { return view.bounds.contains(view.convert(e.locationInWindow, from: nil)) }
    }
    return false
}

private final class Divider: NSBox {
    init() { super.init(frame: .zero); boxType = .separator }
    required init?(coder: NSCoder) { fatalError() }
}

private extension NSFont {
    var rounded: NSFont {
        guard let d = fontDescriptor.withDesign(.rounded) else { return self }
        return NSFont(descriptor: d, size: pointSize) ?? self
    }
}
