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
    private var watchdog: Timer?

    // Следящий двигатель: каждый кадр экрана ведёт подсветку к цели
    // критически демпфированной пружиной по логарифму нит — мягкий разгон,
    // мягкая остановка, без перелёта. Новые нажатия только двигают цель, а
    // набранная скорость сохраняется — нет ни «едет-стоп-едет», ни рывка.
    private lazy var clock = FrameClock(screen: panel.display) { [weak self] dt in self?.follow(dt) }
    private var shownNits = 0.0
    private var velocity = 0.0           // лог-нит в секунду
    private var smoothTime = 0.12
    private var animating: Bool { clock.isRunning }

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
        // клавиши и уровни — мягко, ползунок — почти вплотную за пальцем
        smoothTime = animated ? 0.12 : 0.05
        if !animating { shownNits = max(panel.nits, panel.minNits); velocity = 0 }
        clock.start()
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
        pinSystem()   // пресет подгружает свою сохранённую яркость — перебиваем её
        engaged = true
        reassertSoon()

        watchdog?.invalidate()
        watchdog = Timer.common(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.guardLevel() }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Отдаёт подсветку системе: исходный пресет, исходная автояркость.
    func release() {
        clock.stop()
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
        pinSystem()
        holdUntil = Date().addingTimeInterval(3)
        guard holdTimer == nil else { return }
        holdTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, self.engaged, Date() < self.holdUntil else {
                t.invalidate(); self?.holdTimer = nil; return
            }
            if !self.animating, abs(self.panel.nits - self.targetNits) > 0.5 { self.apply() }
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
        guard engaged else { return }
        pinSystem()
        guard !animating else { return }
        if let direct = panel.directPreset, panel.activePreset != direct {
            reassertSoon(); return
        }
        if abs(panel.nits - targetNits) > 0.5 || targetNits > panel.capNits + 0.5 { apply() }
    }

    /// Штатная яркость macOS — это то, что WindowServer считает белым SDR.
    /// Ниже 1 он видит запас под HDR и при любом видео притемняет весь
    /// интерфейс, хотя подсветку держим мы, — экран «мигает» вместе с роликом.
    /// На 1 белый SDR равен потолку пресета, запаса нет, затемнять нечем.
    private func pinSystem() {
        if let v = panel.systemBrightness, v < 0.999 { panel.setSystemBrightness(1) }
        if panel.autoBrightness == true { panel.setAutoBrightness(false) }
    }

    private func follow(_ dt: Double) {
        guard engaged else { clock.stop(); return }
        let goal = log(targetNits), now = log(max(shownNits, panel.minNits))
        let next = smoothDamp(now, goal, dt)
        if abs(next - goal) < 0.002 && abs(velocity) < 0.05 {   // < 0,2 % — глазу не видно, встаём
            shownNits = targetNits
            velocity = 0
            apply()
            clock.stop()
        } else {
            shownNits = exp(next)
            if shownNits > panel.capNits { panel.unlockCap() }
            panel.setNits(shownNits)
        }
    }
}

extension Brightness {
    /// Пружина SmoothDamp (Game Programming Gems 4, 1.10): плавно догоняет
    /// цель за ~smoothTime, скорость не больше maxSpeed — даже с 2 до 1600
    /// нит переход растягивается, а не прыгает.
    fileprivate func smoothDamp(_ current: Double, _ target: Double, _ dt: Double) -> Double {
        let maxSpeed = 3.5                       // лог-нит/с: не быстрее ×33 за секунду
        let omega = 2 / smoothTime, x = omega * dt
        let k = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        let limit = maxSpeed * smoothTime
        let change = min(max(current - target, -limit), limit)
        let temp = (velocity + omega * change) * dt
        velocity = (velocity - omega * temp) * k
        var out = (current - change) + (change + temp) * k
        if (target - current > 0) == (out > target) { out = target; velocity = 0 }   // без перелёта
        // жёсткий потолок: не больше ~3 % яркости за кадр на 120 Гц —
        // мельче порога, на котором глаз видит ступеньку на ровном фоне
        let step = min(maxSpeed * dt, 0.025)     // и за пропущенный кадр не больше
        if abs(out - current) > step {
            out = current + (out > current ? step : -step)
            velocity = min(max(velocity, -maxSpeed), maxSpeed)
        }
        return out
    }
}

/// Такт по кадрам встроенного экрана (120 Гц на ProMotion), идёт и при
/// открытом меню. Сам останавливается, когда двигатель дошёл до цели.
final class FrameClock: NSObject {

    private let screenID: CGDirectDisplayID
    private let tick: (Double) -> Void
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    var isRunning: Bool { link != nil }

    init(screen: CGDirectDisplayID, tick: @escaping (Double) -> Void) {
        screenID = screen
        self.tick = tick
    }

    func start() {
        guard link == nil else { return }
        let screen = NSScreen.screens.first { $0.displayID == screenID } ?? NSScreen.main
        guard let l = screen?.displayLink(target: self, selector: #selector(frame(_:))) else { return }
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        last = 0
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ l: CADisplayLink) {
        let dt = last == 0 ? 1.0 / 120 : min(l.timestamp - last, 1.0 / 30)
        last = l.timestamp
        tick(dt)
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
