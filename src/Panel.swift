import Cocoa
import IOKit

// ── Панель: прямое управление подсветкой встроенного XDR ─────────────────────
//
// Так же, как «Прямое масштабирование XDR» в BetterDisplay 5:
// яркость пишется в нитах в свойство IOMFBBrightnessLevel фреймбуфера
// (формат 16.16, 1600 нит = 1600 × 65536). Никаких слоёв поверх картинки —
// поэтому Cmd+Tab и Mission Control яркость не сбивают.
//
// На пресете «Apple XDR Display (P3-1600)» WindowServer сам держит подсветку
// на «SDR × текущий EDR headroom» и перетирает запись, поэтому на время работы
// экран переводится на пресет без HDR («Apple Display (P3-600 nits)»).
final class Panel {

    let display: CGDirectDisplayID
    private let framebuffer: io_service_t

    let minNits: Double     // ccMinNitsConfig, обычно 2
    let peakNits: Double    // BLNitsCap, 1600 на MacBook Pro
    let sdrNits: Double     // потолок SDR штатного пресета, 600

    private typealias FnGetIdx = @convention(c) (CGDirectDisplayID) -> Int32
    private typealias FnSetIdx = @convention(c) (CGDirectDisplayID, Int32) -> Int32
    private typealias FnCopy   = @convention(c) (CGDirectDisplayID, Int32) -> Unmanaged<CFDictionary>?
    private typealias FnSetALS = @convention(c) (CGDirectDisplayID, Bool) -> Int32
    private typealias FnGetALS = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Bool>) -> Int32
    private typealias FnGetB   = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias FnSetB   = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private let getIdx: FnGetIdx, setIdx: FnSetIdx, copyPreset: FnCopy
    private let setALS: FnSetALS?, getALS: FnGetALS?
    private let getB: FnGetB?, setB: FnSetB?

    init?() {
        guard let cd = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_NOW),
              let a = dlsym(cd, "CoreDisplay_Display_GetActivePresetIndex"),
              let b = dlsym(cd, "CoreDisplay_Display_SetActivePresetIndex"),
              let c = dlsym(cd, "CoreDisplay_Display_CopyPresetData")
        else { return nil }
        getIdx = unsafeBitCast(a, to: FnGetIdx.self)
        setIdx = unsafeBitCast(b, to: FnSetIdx.self)
        copyPreset = unsafeBitCast(c, to: FnCopy.self)

        let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW)
        setALS = dlsym(ds, "DisplayServicesEnableAmbientLightCompensation").map { unsafeBitCast($0, to: FnSetALS.self) }
        getALS = dlsym(ds, "DisplayServicesAmbientLightCompensationEnabled").map { unsafeBitCast($0, to: FnGetALS.self) }
        getB = dlsym(ds, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: FnGetB.self) }
        setB = dlsym(ds, "DisplayServicesSetBrightness").map { unsafeBitCast($0, to: FnSetB.self) }

        var n: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &n)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        CGGetActiveDisplayList(n, &ids, &n)
        guard let d = ids.first(where: { CGDisplayIsBuiltin($0) != 0 }),
              let fb = Self.builtinFramebuffer()
        else { return nil }
        display = d
        framebuffer = fb

        func nits(_ key: String) -> Double? {
            (IORegistryEntryCreateCFProperty(fb, key as CFString, nil, 0)?.takeRetainedValue() as? Int)
                .map { Double($0) / 65536 }
        }
        // BLNitsCap система опускает до потолка пресета (600 на P3-600), а
        // IOMFBIndicatorNitsCap всегда показывает настоящий пик панели.
        guard let peak = [nits("IOMFBIndicatorNitsCap"), nits("BLNitsCap")].compactMap({ $0 }).max(), peak > 0
        else { return nil }
        peakNits = peak
        let floor = IORegistryEntryCreateCFProperty(fb, "ccMinNitsConfig" as CFString, nil, 0)?
            .takeRetainedValue() as? Int
        minNits = Double(max(floor ?? 2, 1))

        var sdr = 600.0
        for i in 0..<Int32(32) {
            if let p = copyPreset(d, i)?.takeRetainedValue() as? [String: Any],
               let s = p["PresetMaxSDRLuminance"] as? Int, let h = p["PresetMaxHDRLuminance"] as? Int, h > s {
                sdr = Double(s); break
            }
        }
        sdrNits = sdr
    }

    /// Встроенный фреймбуфер — тот, у которого есть потолок подсветки BLNitsCap.
    private static func builtinFramebuffer() -> io_service_t? {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebufferShim"), &it) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 {
            if IORegistryEntryCreateCFProperty(s, "BLNitsCap" as CFString, nil, 0) != nil { return s }
            IOObjectRelease(s)
        }
        return nil
    }

    // ── Подсветка ─────────────────────────────────────────────────────────────

    var nits: Double { read("IOMFBBrightnessLevel") }

    @discardableResult
    func setNits(_ value: Double) -> Bool {
        let v = min(max(value, minNits), peakNits)
        return write("IOMFBBrightnessLevel", v)
    }

    /// Потолок подсветки. На пресете без HDR система ставит его равным SDR
    /// (600), и всё, что выше, драйвер обрезает. Поднимаем до пика панели.
    var capNits: Double { read("BLNitsCap") }

    @discardableResult
    func unlockCap() -> Bool { capNits >= peakNits - 0.5 || write("BLNitsCap", peakNits) }

    private func read(_ key: String) -> Double {
        guard let v = IORegistryEntryCreateCFProperty(framebuffer, key as CFString, nil, 0)?
            .takeRetainedValue() as? Int else { return 0 }
        return Double(v) / 65536
    }

    private func write(_ key: String, _ nits: Double) -> Bool {
        IORegistryEntrySetCFProperty(framebuffer, key as CFString, NSNumber(value: Int(nits * 65536))) == KERN_SUCCESS
    }

    // ── Пресеты ───────────────────────────────────────────────────────────────

    var activePreset: Int32 { getIdx(display) }

    func presetName(_ i: Int32) -> String {
        (copyPreset(display, i)?.takeRetainedValue() as? [String: Any])?["PresetName"] as? String ?? "слот \(i)"
    }

    /// Пресет без HDR с самым высоким потолком SDR — «Apple Display (P3-600 nits)».
    /// На нём WindowServer не трогает подсветку, и прямая запись держится.
    lazy var directPreset: Int32? = {
        var best: (Int32, Int)?
        for i in 0..<Int32(32) {
            guard let p = copyPreset(display, i)?.takeRetainedValue() as? [String: Any],
                  let s = p["PresetMaxSDRLuminance"] as? Int, let h = p["PresetMaxHDRLuminance"] as? Int,
                  h == s, s > (best?.1 ?? 0) else { continue }
            best = (i, s)
        }
        return best?.0
    }()

    @discardableResult
    func selectPreset(_ i: Int32) -> Bool {
        guard activePreset != i else { return true }
        return setIdx(display, i) != 0
    }

    // ── Автояркость ───────────────────────────────────────────────────────────

    var autoBrightness: Bool? {
        guard let getALS else { return nil }
        var on = false
        return getALS(display, &on) == 0 ? on : nil
    }

    func setAutoBrightness(_ on: Bool) { _ = setALS?(display, on) }

    // ── Штатная яркость macOS (0…1) ───────────────────────────────────────────
    // После смены пресета система секунды две плавно ведёт подсветку к этому
    // значению. Пока панель наша, держим его на 1 — тогда её «хвост» идёт к
    // 600 нит, а не проваливает экран в темноту.

    var systemBrightness: Float? {
        guard let getB else { return nil }
        var v: Float = 0
        return getB(display, &v) == 0 ? v : nil
    }

    func setSystemBrightness(_ v: Float) { _ = setB?(display, v) }
}
