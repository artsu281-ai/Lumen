import Cocoa

// ── Индикатор при нажатии клавиш ─────────────────────────────────────────────
// Плашка в правом верхнем углу, как системная в macOS 26: значок, шкала с
// меткой границы SDR, ниты. Выше метки шкала светится — это зона XDR.
final class HUD {

    private let window: NSPanel
    private let icon = NSImageView()
    private let bar = Bar()
    private let label = NSTextField(labelWithString: "")
    private var hide: DispatchWorkItem?

    init() {
        window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 52),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let fx = NSVisualEffectView(frame: window.contentRect(forFrameRect: window.frame))
        fx.material = .hudWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 26
        fx.layer?.cornerCurve = .continuous
        window.contentView = fx

        icon.symbolConfiguration = .init(pointSize: 17, weight: .semibold)
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.alignment = .right

        for v in [icon, bar, label] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; fx.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            bar.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            bar.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
            bar.heightAnchor.constraint(equalToConstant: 8),
            label.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -18),
            label.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 66),
        ])
    }

    func show(_ b: Brightness) {
        bar.value = b.position
        bar.sdrMark = b.position(for: b.panel.sdrNits)
        bar.needsDisplay = true
        icon.image = NSImage(systemSymbolName: b.isBoosted ? "sun.max.fill" : "sun.max", accessibilityDescription: nil)
        icon.contentTintColor = b.isBoosted ? .systemYellow : .labelColor
        label.stringValue = "\(Int(b.targetNits.rounded())) нит"

        if let screen = NSScreen.screens.first(where: { $0.displayID == b.panel.display }) ?? NSScreen.main {
            let f = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: f.maxX - window.frame.width - 12, y: f.maxY - window.frame.height - 10))
        }
        window.alphaValue = 1
        window.orderFrontRegardless()

        hide?.cancel()
        let w = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.35; self?.window.animator().alphaValue = 0 },
                                                 completionHandler: { self?.window.orderOut(nil) })
        }
        hide = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: w)
    }

    private final class Bar: NSView {
        var value = 0.0, sdrMark = 0.6

        override func draw(_ dirty: NSRect) {
            let r = bounds, rad = r.height / 2
            NSColor.labelColor.withAlphaComponent(0.15).setFill()
            NSBezierPath(roundedRect: r, xRadius: rad, yRadius: rad).fill()

            let fill = NSRect(x: 0, y: 0, width: max(r.height, r.width * value), height: r.height)
            let sdrW = r.width * sdrMark
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: fill, xRadius: rad, yRadius: rad).addClip()
            NSColor.labelColor.setFill()
            NSRect(x: 0, y: 0, width: min(sdrW, fill.width), height: r.height).fill()
            if fill.width > sdrW {
                NSGradient(starting: .systemOrange, ending: .systemYellow)?
                    .draw(in: NSRect(x: sdrW, y: 0, width: fill.width - sdrW, height: r.height), angle: 0)
            }
            NSGraphicsContext.restoreGraphicsState()

            // метка «100 %» — граница штатной яркости
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: sdrW - 0.75, y: -2, width: 1.5, height: r.height + 4).fill()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
