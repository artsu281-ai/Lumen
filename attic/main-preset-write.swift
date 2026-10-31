import Cocoa

// ── Движок: правит пресет дисплея вместо наложения слоя поверх картинки ──────
final class XDREngine {

    static let customSlot: Int32 = 11        // свободный записываемый слот
    static let factorySlot: Int32 = 0        // Apple XDR Display (P3-1600 nits)

    typealias FnGetIdx  = @convention(c) (CGDirectDisplayID) -> Int32
    typealias FnSetIdx  = @convention(c) (CGDirectDisplayID, Int32) -> Int32
    typealias FnCopy    = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
    typealias FnSetData = @convention(c) (CGDirectDisplayID, Int32, CFDictionary) -> Int32
    typealias FnFloat   = @convention(c) (CGDirectDisplayID) -> Float

    private let getIdx: FnGetIdx, setIdx: FnSetIdx
    private let copyData: FnCopy, setData: FnSetData
    private let headroom: FnFloat

    let display: CGDirectDisplayID
    let basePreset: [String: Any]
    let sdrFloor: Int      // 600 — штатный потолок SDR
    let hdrPeak: Int       // 1600 — пик панели

    init?() {
        guard let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW),
              let a = dlsym(cd, "CoreDisplay_Display_GetActivePresetIndex"),
              let b = dlsym(cd, "CoreDisplay_Display_SetActivePresetIndex"),
              let c = dlsym(cd, "CoreDisplay_Display_CopyPresetData"),
              let e = dlsym(cd, "CoreDisplay_Display_SetPresetData"),
              let f = dlsym(cd, "CoreDisplay_Display_GetCurrentHeadroom")
        else { return nil }
        getIdx   = unsafeBitCast(a, to: FnGetIdx.self)
        setIdx   = unsafeBitCast(b, to: FnSetIdx.self)
        copyData = unsafeBitCast(c, to: FnCopy.self)
        setData  = unsafeBitCast(e, to: FnSetData.self)
        headroom = unsafeBitCast(f, to: FnFloat.self)

        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        guard let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }) else { return nil }
        display = d

        guard let base = copyData(d, Self.factorySlot)?.takeRetainedValue() as? [String: Any],
              let sdr = base["PresetMaxSDRLuminance"] as? Int,
              let hdr = base["PresetMaxHDRLuminance"] as? Int, hdr > sdr
        else { return nil }
        basePreset = base; sdrFloor = sdr; hdrPeak = hdr
    }

    var currentHeadroom: Float { headroom(display) }
    var isBoosted: Bool { getIdx(display) == Self.customSlot }

    /// Кладёт в свободный слот копию заводского XDR-пресета с поднятым потолком SDR.
    @discardableResult
    func apply(nits: Int) -> Bool {
        var p = basePreset
        p["PresetMaxSDRLuminance"]              = nits
        p["PresetHostMaxSliderBrightness"]      = nits
        p["PresetHostAlwaysRequestMaxHeadroom"] = 1
        p["PresetName"]                         = "Lumen \(nits) nits"
        p["PresetUniqueID"]                     = nil     // свой слот — свой идентификатор
        guard setData(display, Self.customSlot, p as CFDictionary) != 0 else { return false }
        return setIdx(display, Self.customSlot) != 0
    }

    /// Возврат на заводской XDR-пресет.
    func restore() { _ = setIdx(display, Self.factorySlot) }
}

// ── Строка меню: одна иконка, один слайдер ──────────────────────────────────
final class Controller: NSObject, NSApplicationDelegate {

    private var item: NSStatusItem!
    private let engine = XDREngine()
    private var slider: NSSlider!
    private var readout: NSTextField!

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let engine else {
            let a = NSAlert(); a.messageText = "Дисплей не поддерживает XDR-пресеты"
            a.runModal(); NSApp.terminate(nil); return
        }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Lumen")

        let menu = NSMenu()

        readout = NSTextField(labelWithString: "\(engine.sdrFloor) нит")
        readout.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        readout.alignment = .center

        slider = NSSlider(value: Double(engine.sdrFloor),
                          minValue: Double(engine.sdrFloor),
                          maxValue: Double(engine.hdrPeak),
                          target: self, action: #selector(changed))
        slider.isContinuous = true

        let box = NSStackView(views: [readout, slider])
        box.orientation = .vertical
        box.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 8, right: 14)
        box.spacing = 6
        box.frame = NSRect(x: 0, y: 0, width: 240, height: 60)
        slider.widthAnchor.constraint(equalToConstant: 210).isActive = true

        let holder = NSMenuItem(); holder.view = box
        menu.addItem(holder)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Сбросить на 100 %", action: #selector(reset), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Выход", action: #selector(quit), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        item.menu = menu
    }

    @objc private func changed() {
        let nits = Int(slider.doubleValue.rounded())
        readout.stringValue = "\(nits) нит   ·   headroom \(String(format: "%.2f", engine?.currentHeadroom ?? 0))"
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(commit), object: nil)
        perform(#selector(commit), with: nil, afterDelay: 0.15)   // не дёргать пресет на каждый пиксель
    }

    @objc private func commit() {
        guard let engine else { return }
        let nits = Int(slider.doubleValue.rounded())
        if nits <= engine.sdrFloor { engine.restore() } else { engine.apply(nits: nits) }
    }

    @objc private func reset() {
        guard let engine else { return }
        slider.doubleValue = Double(engine.sdrFloor)
        readout.stringValue = "\(engine.sdrFloor) нит"
        engine.restore()
    }

    @objc private func quit() { engine?.restore(); NSApp.terminate(nil) }

    func applicationWillTerminate(_ n: Notification) { engine?.restore() }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
