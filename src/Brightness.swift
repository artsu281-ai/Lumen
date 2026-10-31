import Cocoa

// ── Яркость: одна шкала от сверхзатемнения до пика панели ───────────────────
//
// Положение 0…1 → ниты по степенной кривой, чтобы шаги клавиш ощущались
// равными на глаз. 100 % — штатный потолок SDR (600 нит), всё выше — XDR.
final class Brightness {

    static let changed = Notification.Name("LumenBrightnessChanged")

    let panel: Panel
    private let defaults = UserDefaults.standard
    private let gamma = 2.2

    private(set) var engaged = false
    private(set) var targetNits: Double
    private var rampTimer: Timer?
    private var watchdog: Timer?

    init(panel: Panel) {
        self.panel = panel
        let saved = defaults.double(forKey: "nits")
        targetNits = saved > 0 ? saved : panel.sdrNits
    }

    // ── Шкала ─────────────────────────────────────────────────────────────────

    var position: Double { position(for: targetNits) }

    func position(for nits: Double) -> Double {
        let span = panel.peakNits - panel.minNits
        return pow(max(nits - panel.minNits, 0) / span, 1 / gamma)
    }

    func nits(at position: Double) -> Double {
        let p = min(max(position, 0), 1)
        return panel.minNits + (panel.peakNits - panel.minNits) * pow(p, gamma)
    }

    var percent: Int { Int((targetNits / panel.sdrNits * 100).rounded()) }
    var isBoosted: Bool { targetNits > panel.sdrNits + 0.5 }

    func step(up: Bool, fine: Bool) {
        let s = fine ? 1.0 / 64 : 1.0 / 16
        // привязка к сетке шагов, как у штатных клавиш
        let grid = (position / s).rounded()
        set(nits: nits(at: (grid + (up ? 1 : -1)) * s), animated: true)
    }

    func set(position: Double, animated: Bool = false) { set(nits: nits(at: position), animated: animated) }

    func set(nits: Double, animated: Bool = false) {
        targetNits = min(max(nits, panel.minNits), panel.peakNits)
        defaults.set(targetNits, forKey: "nits")
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard engaged else { return }
        animated ? ramp(to: targetNits) : apply()
    }

    // ── Захват панели ─────────────────────────────────────────────────────────

    /// Переводит экран на пресет без HDR и берёт подсветку на себя.
    /// Исходный пресет и автояркость запоминаются на диске — их вернёт даже
    /// следующий запуск, если приложение упало.
    func engage() {
        guard !engaged, let direct = panel.directPreset else { return }
        if defaults.object(forKey: "originalPreset") == nil {
            let current = panel.activePreset
            defaults.set(Int(current == direct ? 0 : current), forKey: "originalPreset")
            defaults.set(panel.autoBrightness ?? false, forKey: "originalAutoBrightness")
            defaults.set(panel.systemBrightness ?? 1, forKey: "originalSystemBrightness")
        }
        panel.setAutoBrightness(false)
        panel.setSystemBrightness(1)
        panel.selectPreset(direct)
        engaged = true
        reassertSoon()

        watchdog?.invalidate()
        watchdog = Timer.common(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.guardLevel() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Отдаёт подсветку системе: исходный пресет, исходная автояркость.
    func release() {
        rampTimer?.invalidate(); rampTimer = nil
        watchdog?.invalidate(); watchdog = nil
        holdTimer?.invalidate(); holdTimer = nil
        engaged = false
        Self.restoreSystem(panel)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    static func restoreSystem(_ panel: Panel) {
        let d = UserDefaults.standard
        guard d.object(forKey: "originalPreset") != nil else { return }
        panel.selectPreset(Int32(d.integer(forKey: "originalPreset")))
        if d.object(forKey: "originalSystemBrightness") != nil {
            panel.setSystemBrightness(d.float(forKey: "originalSystemBrightness"))
        }
        if d.bool(forKey: "originalAutoBrightness") { panel.setAutoBrightness(true) }
        for k in ["originalPreset", "originalAutoBrightness", "originalSystemBrightness"] { d.removeObject(forKey: k) }
    }

    /// После смены пресета, сна или переподключения система пару секунд сама
    /// ведёт подсветку к своей яркости. Эти секунды держим значение каждый кадр.
    func reassertSoon() {
        guard engaged else { return }
        if let direct = panel.directPreset { panel.selectPreset(direct) }
        holdUntil = Date().addingTimeInterval(3)
        guard holdTimer == nil else { return }
        holdTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, self.engaged, Date() < self.holdUntil else {
                t.invalidate(); self?.holdTimer = nil; return
            }
            if self.rampTimer == nil, abs(self.panel.nits - self.targetNits) > 0.5 { self.apply() }
        }
    }

    private var holdTimer: Timer?
    private var holdUntil = Date()

    private func apply() {
        if targetNits > panel.capNits { panel.unlockCap() }
        panel.setNits(targetNits)
    }

    /// Сторож: если подсветку кто-то перезаписал (штатные клавиши, Пункт
    /// управления, сон), возвращаем своё значение.
    private func guardLevel() {
        guard engaged, rampTimer == nil else { return }
        if let direct = panel.directPreset, panel.activePreset != direct {
            reassertSoon(); return
        }
        if abs(panel.nits - targetNits) > 0.5 || targetNits > panel.capNits + 0.5 { apply() }
    }

    /// Плавный переход за ~180 мс по логарифму нит — так он ровный на глаз.
    private func ramp(to goal: Double) {
        rampTimer?.invalidate()
        let start = max(panel.nits, panel.minNits)
        let frames = 11
        var i = 0
        rampTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let k = Double(i) / Double(frames)
            self.panel.setNits(exp(log(start) + (log(goal) - log(start)) * k))
            if i >= frames { t.invalidate(); self.rampTimer = nil; self.apply() }
        }
    }
}

extension Timer {
    /// Таймер в общем режиме цикла: идёт и пока открыто меню, и при
    /// перетаскивании. Обычный scheduledTimer в эти моменты стоит.
    static func common(withTimeInterval i: TimeInterval, repeats: Bool,
                       block: @escaping (Timer) -> Void) -> Timer {
        let t = Timer(timeInterval: i, repeats: repeats, block: block)
        RunLoop.main.add(t, forMode: .common)
        return t
    }
}
