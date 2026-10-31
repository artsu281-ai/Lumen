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
    /// Экран спит или ушла сессия — панель наша, но писать в неё нельзя.
    private(set) var paused = false
    private(set) var targetNits: Double
    private var watchdog: Timer?

    /// Пользователь сам сменил пресет в Системных настройках — Lumen уступает.
    var onYield: (() -> Void)?

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
        targetNits = saved > 0 ? min(max(saved, panel.minNits), panel.peakNits) : panel.sdrNits
        NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if self.engaged && !self.paused { self.smoothTime = 0.4; self.startSpring() }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
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

    // ── Нагрев ────────────────────────────────────────────────────────────────
    // 1600 нит — пик панели; на весь экран и надолго Apple обещает 1000.
    // Когда macOS сообщает о сильном нагреве, держим не выше 1000, при
    // критическом — не выше SDR. Выбор пользователя при этом не теряется:
    // остынет — яркость вернётся.

    var thermalLimit: Double? {
        switch ProcessInfo.processInfo.thermalState {
        case .serious: return min(1000, panel.peakNits)
        case .critical: return panel.sdrNits
        default: return nil
        }
    }

    /// То, что на самом деле идёт на панель.
    var effectiveNits: Double { min(targetNits, thermalLimit ?? .infinity) }
    var isLimited: Bool { effectiveNits < targetNits - 0.5 }

    // ── Шаги и цель ───────────────────────────────────────────────────────────

    func step(up: Bool, fine: Bool) {
        let s = fine ? 1.0 / 64 : 1.0 / 16
        // привязка к сетке шагов, как у штатных клавиш: всегда к следующей
        // отметке в сторону нажатия, поэтому вверх и вниз шаг одинаковый
        let pos = position, g = pos / s
        var next = (up ? floor(g + 1e-6) + 1 : ceil(g - 1e-6) - 1) * s
        // 100 % между отметками сетки — шаг через неё на ней и останавливается
        let mark = position(for: panel.sdrNits)
        if up, pos < mark - 1e-6, next > mark + 1e-6 { next = mark }
        if !up, pos > mark + 1e-6, next < mark - 1e-6 { next = mark }
        set(nits: nits(at: next), animated: true)
    }

    func set(position: Double, animated: Bool = false) { set(nits: nits(at: position), animated: animated) }

    func set(nits: Double, animated: Bool = false) {
        targetNits = min(max(nits, panel.minNits), panel.peakNits)
        NotificationCenter.default.post(name: Self.changed, object: self)
        guard engaged, !paused else { save(); return }
        // клавиши и уровни — мягко, ползунок — почти вплотную за пальцем
        smoothTime = animated ? 0.12 : 0.05
        startSpring()   // на диск — когда двигатель встанет, а не на каждое движение
    }

    private func save() { defaults.set(targetNits, forKey: "nits") }

    private func startSpring() {
        if !animating { shownNits = panel.nits; velocity = 0 }
        clock.start()
    }

    // ── Захват панели ─────────────────────────────────────────────────────────

    /// Переводит экран на пресет без HDR и берёт подсветку на себя.
    /// Исходный пресет и автояркость запоминаются на диске — их вернёт даже
    /// следующий запуск, если приложение упало.
    func engage() {
        guard !engaged, let direct = panel.directPreset else { return }
        let current = panel.activePreset
        if defaults.object(forKey: "originalPreset") == nil {
            // экран уже на нашем пресете (его оставил BetterDisplay или прошлый
            // запуск) — исходным считаем штатный HDR-пресет, а системная
            // яркость на нём уже не исходная, её не запоминаем
            defaults.set(Int(current == direct ? panel.hdrPreset : current), forKey: "originalPreset")
            if let a = panel.autoBrightness { defaults.set(a, forKey: "originalAutoBrightness") }
            if current != direct, let b = panel.systemBrightness { defaults.set(b, forKey: "originalSystemBrightness") }
        }
        let from = panel.nits
        holdUntil = Date().addingTimeInterval(3)
        panel.setAutoBrightness(false)
        panel.selectPreset(direct)
        // смена пресета ставит подсветку на его потолок (600) — не сразу, а
        // спустя десятки мс, и раньше, чем придёт первый кадр такта. Ловим эту
        // запись и тут же перебиваем, иначе на экране мелькнёт провал.
        let deadline = CACurrentMediaTime() + 0.25
        while CACurrentMediaTime() < deadline {
            if abs(panel.nits - from) > 0.5 {
                if from > panel.capNits { panel.unlockCap() }
                panel.setNits(from)
            }
            usleep(1_000)
        }
        pinSystem()   // пресет подгружает свою сохранённую яркость — перебиваем её
        engaged = true
        paused = false

        // от того, что было на экране, к цели — пружиной, без скачка
        shownNits = from; velocity = 0; smoothTime = 0.25
        clock.start()
        startHold()

        watchdog?.invalidate()
        watchdog = Timer.common(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.guardLevel() }
        watchdog?.tolerance = 0.1
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Отдаёт подсветку системе: исходный пресет, исходная автояркость.
    /// keepPreset — пресет уже выбрал пользователь, его не перебиваем.
    func release(keepPreset: Bool = false) {
        guard engaged else { return }
        clock.stop()
        watchdog?.invalidate(); watchdog = nil
        holdTimer?.invalidate(); holdTimer = nil
        engaged = false
        paused = false
        save()
        // После смены пресета macOS начинает с уровня своей яркости и уже от
        // него плавно идёт дальше. Подводим подсветку к этому уровню сами —
        // иначе с 1600 экран падает до 600 одним кадром, а со 100 вспыхивает.
        if panel.isAwake { glide(to: Self.systemStart(panel)) }
        Self.restoreSystem(panel, preset: !keepPreset)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// С какого уровня macOS начнёт после возврата: белый SDR при исходной
    /// системной яркости. По логу WindowServer он идёт как sdr × яркость^2,2
    /// (0,5 → 140 нит, 0,62 → 200, 1 → 600).
    private static func systemStart(_ panel: Panel) -> Double {
        let d = UserDefaults.standard
        let ds = d.object(forKey: "originalSystemBrightness") != nil ? Double(d.float(forKey: "originalSystemBrightness")) : 1
        return min(max(panel.sdrNits * pow(min(max(ds, 0), 1), 2.2), panel.minNits), panel.sdrNits)
    }

    /// Короткий синхронный спуск: при выходе из приложения ждать кадров
    /// уже некому, поэтому без таймера, 0,35 с по логарифму нит.
    private func glide(to goal: Double, duration: Double = 0.35) {
        let from = log(max(panel.nits, panel.minNits)), to = log(goal)
        guard abs(to - from) > 0.01 else { return }
        let t0 = CACurrentMediaTime()
        while true {
            let t = min((CACurrentMediaTime() - t0) / duration, 1)
            let e = t * t * (3 - 2 * t)
            panel.setNits(exp(from + (to - from) * e))
            if t >= 1 { break }
            usleep(8_000)
        }
    }

    static func restoreSystem(_ panel: Panel, preset: Bool = true) {
        let d = UserDefaults.standard
        guard d.object(forKey: "originalPreset") != nil else { return }
        // сначала системная яркость, потом пресет: с неё macOS и начнёт
        if d.object(forKey: "originalSystemBrightness") != nil {
            panel.setSystemBrightness(d.float(forKey: "originalSystemBrightness"))
        }
        if preset { panel.selectPreset(Int32(d.integer(forKey: "originalPreset"))) }
        if d.bool(forKey: "originalAutoBrightness") { panel.setAutoBrightness(true) }
        for k in ["originalPreset", "originalAutoBrightness", "originalSystemBrightness"] { d.removeObject(forKey: k) }
    }

    /// Экран уснул, крышка закрыта, сессию сменили — перестаём писать.
    func pause() {
        guard engaged, !paused else { return }
        paused = true
        clock.stop()
        holdTimer?.invalidate(); holdTimer = nil
    }

    func resume() {
        guard engaged, paused else { return }
        paused = false
        reassertSoon()
    }

    /// Конфигурация экранов поменялась — такт кадров привязан к экрану,
    /// пересоздаём его, а потом держим значение, как после пробуждения.
    func screensChanged() {
        if animating { clock.stop(); clock.start() }
        reassertSoon()
    }

    /// После смены пресета, сна или переподключения система пару секунд сама
    /// ведёт подсветку к своей яркости. Эти секунды держим значение каждый кадр.
    func reassertSoon() {
        guard engaged, !paused, panel.isAwake else { return }
        holdUntil = Date().addingTimeInterval(3)
        if let direct = panel.directPreset { panel.selectPreset(direct) }
        pinSystem()
        startHold()
    }

    private var holdTimer: Timer?
    private var holdUntil = Date()

    private func startHold() {
        guard holdTimer == nil else { return }
        var tick = 0
        holdTimer = Timer.common(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
            guard let self, self.engaged, !self.paused, Date() < self.holdUntil else {
                t.invalidate(); self?.holdTimer = nil; return
            }
            tick += 1
            // пресет может подгрузить свою системную яркость не сразу
            if tick % 6 == 0 { self.pinSystem() }
            if !self.animating, abs(self.panel.nits - self.effectiveNits) > 0.5 { self.apply() }
        }
    }

    private func apply() {
        let goal = effectiveNits
        if goal > panel.capNits { panel.unlockCap() }
        panel.setNits(goal)
    }

    /// Сторож: если подсветку кто-то перезаписал (штатные клавиши, Пункт
    /// управления, сон), возвращаем своё значение.
    private func guardLevel() {
        guard engaged, !paused, panel.isAwake else { return }
        if clock.isStale { clock.stop() }   // такт кадров умер — без этого сторож молчал бы вечно
        pinSystem()
        guard !animating else { return }
        if let direct = panel.directPreset, panel.activePreset != direct {
            // пресет сменили в Системных настройках руками — это выбор
            // пользователя, а не сбой: не спорим, отдаём панель
            if Date() >= holdUntil,
               NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
                release(keepPreset: true); onYield?(); return
            }
            reassertSoon(); return
        }
        if abs(panel.nits - effectiveNits) > 0.5 || effectiveNits > panel.capNits + 0.5 { apply() }
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
        guard engaged, !paused else { clock.stop(); return }
        let target = effectiveNits
        let goal = log(target), now = log(max(shownNits, panel.minNits))
        let next = smoothDamp(now, goal, dt)
        if abs(next - goal) < 0.002 && abs(velocity) < 0.05 {   // < 0,2 % — глазу не видно, встаём
            shownNits = target
            velocity = 0
            apply()
            clock.stop()
            save()
        } else {
            shownNits = exp(next)
            // потолок важен только выше SDR — там и читаем его
            if shownNits > panel.sdrNits, shownNits > panel.capNits { panel.unlockCap() }
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
        // жёсткий потолок скорости: на 120 Гц это ~3 % яркости за кадр —
        // мельче порога, на котором глаз видит ступеньку на ровном фоне.
        // Считается от времени кадра, поэтому и на 60 Гц переход той же
        // длины, а за пропущенный кадр прыжок не больше, чем за 1/50 с.
        let step = maxSpeed * min(dt, 1.0 / 50)
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
    private var lastFrame: CFTimeInterval = 0
    var isRunning: Bool { link != nil }
    /// Запущен, но кадров нет: экран пропал или уснул посреди перехода.
    var isStale: Bool { link != nil && CACurrentMediaTime() - lastFrame > 0.5 }

    init(screen: CGDirectDisplayID, tick: @escaping (Double) -> Void) {
        screenID = screen
        self.tick = tick
    }

    func start() {
        if isStale { stop() }
        guard link == nil else { return }
        let screen = NSScreen.screens.first { $0.displayID == screenID } ?? NSScreen.main
        guard let l = screen?.displayLink(target: self, selector: #selector(frame(_:))) else { return }
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        last = 0
        lastFrame = CACurrentMediaTime()
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func frame(_ l: CADisplayLink) {
        let dt = last == 0 ? 1.0 / 120 : min(l.timestamp - last, 1.0 / 30)
        last = l.timestamp
        lastFrame = CACurrentMediaTime()
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
