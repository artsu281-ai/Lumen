import Cocoa

// ── Клавиши яркости ──────────────────────────────────────────────────────────
//
// F1/F2 приходят как NX_SYSDEFINED (подтип 8, коды 3/2). Их нужно перехватить
// и съесть: иначе macOS выставит свою яркость поверх нашей. Активный перехват
// требует Универсального доступа.
final class MediaKeys {

    private var tap: CFMachPort?
    private var retry: Timer?
    var onStep: ((_ up: Bool, _ fine: Bool) -> Void)?

    var isActive: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }
    static var isTrusted: Bool { AXIsProcessTrusted() }

    func start(prompt: Bool) {
        guard tap == nil else { return }
        if prompt {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
        if install() { return }
        // разрешение могут выдать позже — проверяем раз в пару секунд
        retry?.invalidate()
        retry = Timer.common(withTimeInterval: 2, repeats: true) { [weak self] t in
            if self?.install() ?? true { t.invalidate() }
        }
    }

    func stop() {
        retry?.invalidate(); retry = nil
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        self.tap = nil
    }

    private func install() -> Bool {
        let mask = CGEventMask(1 << 14)   // NX_SYSDEFINED
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: callback, userInfo: me)
        else { return false }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        NotificationCenter.default.post(name: Brightness.changed, object: nil)
        return true
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type.rawValue == 14, let e = NSEvent(cgEvent: event), e.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(event)
        }
        let code = (e.data1 & 0xFFFF0000) >> 16
        guard code == 2 || code == 3 else { return Unmanaged.passUnretained(event) }
        let isDown = ((e.data1 & 0xFF00) >> 8) == 0xA
        if isDown {
            let fine = e.modifierFlags.contains([.shift, .option])
            DispatchQueue.main.async { self.onStep?(code == 2, fine) }
        }
        return nil   // и нажатие, и отпускание — съедаем
    }
}

private func callback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                      _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let info else { return Unmanaged.passUnretained(event) }
    return Unmanaged<MediaKeys>.fromOpaque(info).takeUnretainedValue().handle(type, event)
}
