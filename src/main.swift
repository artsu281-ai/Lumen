import Cocoa
import ServiceManagement

// ── Строка меню ──────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var item: NSStatusItem!
    private var brightness: Brightness?
    private var panel: MenuPanel?
    private let keys = MediaKeys()
    private let hud = HUD()
    private let defaults = UserDefaults.standard
    private var signals: [DispatchSourceSignal] = []
    private var shownSymbol = ""

    static let betterDisplayID = "pro.betterdisplay.BetterDisplay"

    /// То, что меню показывает помимо яркости. Спрашивать это у системы
    /// дорого (XPC к launchd, список процессов, TCC), поэтому не на каждое
    /// движение ползунка, а при открытии меню и по событиям.
    private struct Environment { var login = false, betterDisplay = false, needsAccess = false }
    private var env = Environment()

    func applicationDidFinishLaunching(_ n: Notification) {
        let me = Bundle.main.bundleIdentifier ?? "local.artsu.Lumen"
        if NSRunningApplication.runningApplications(withBundleIdentifier: me).contains(where: { $0 != .current }) {
            NSApp.terminate(nil); return   // вторая копия перетягивала бы подсветку у первой
        }
        guard Panel.hasPanelHardware else {
            let a = NSAlert()
            a.messageText = "Нужен встроенный дисплей XDR"
            a.informativeText = "Lumen управляет подсветкой Liquid Retina XDR напрямую. Подходящий дисплей не найден."
            NSApp.activate(ignoringOtherApps: true)
            a.runModal(); NSApp.terminate(nil); return
        }

        defaults.register(defaults: ["enabled": true, "keys": true])
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: Brightness.changed, object: nil)
        nc.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.didWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(screensSlept), name: NSWorkspace.willSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionOn), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(sessionOff), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        ws.addObserver(self, selector: #selector(appLaunched), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appTerminated), name: NSWorkspace.didTerminateApplicationNotification, object: nil)

        // kill / Ctrl+C / выход из системы — всё равно вернуть пресет
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signals.append(s)
        }

        keys.onStep = { [weak self] up, fine in
            guard let self, let b = self.brightness, b.engaged else { return }
            b.step(up: up, fine: fine)
            self.hud.show(b)
        }
        // системный запрос доступа — только при первом запуске; дальше о нём
        // напоминает плашка в меню
        if defaults.bool(forKey: "keys") {
            keys.start(prompt: !defaults.bool(forKey: "askedAccess"))
            defaults.set(true, forKey: "askedAccess")
        }

        if !setUp() { showWaiting() }
    }

    /// Берёт встроенный экран. При закрытой крышке его может не быть —
    /// тогда ждём, пока он появится, а не закрываемся.
    @discardableResult
    private func setUp() -> Bool {
        guard brightness == nil, let display = Panel(), display.directPreset != nil else { return brightness != nil }
        let b = Brightness(panel: display)
        b.onYield = { [weak self] in self?.defaults.set(false, forKey: "enabled"); self?.refresh() }
        brightness = b
        item.menu = buildMenu(b)
        item.menu?.delegate = self
        refreshEnvironment()

        let willEngage = defaults.bool(forKey: "enabled") && !env.betterDisplay
        // прошлый запуск упал, не вернув систему. Если сейчас снова берём
        // панель — сохранённое исходное состояние и есть исходное, пресет
        // туда-обратно не дёргаем
        if !willEngage { Brightness.restoreSystem(display) }
        if willEngage { b.engage() }
        refresh()
        return true
    }

    private func showWaiting() {
        let menu = NSMenu()
        let info = NSMenuItem(title: "Встроенный экран выключен — Lumen включится, когда откроете крышку", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(info)
        menu.addItem(.separator())
        menu.addItem(quitItem())
        item.menu = menu
        setSymbol("sun.min")
        item.button?.toolTip = "Lumen ждёт встроенный экран"
    }

    func applicationWillTerminate(_ n: Notification) { brightness?.release() }

    // ── Меню ──────────────────────────────────────────────────────────────────

    private func buildMenu(_ b: Brightness) -> NSMenu {
        let p = b.panel
        let view = MenuPanel(levels: [("moon.stars.fill", 20), ("sun.horizon.fill", 120),
                                      ("sun.max", p.sdrNits), ("sun.max.fill", 1000), ("sparkles", p.peakNits)])
        view.sdrNits = p.sdrNits
        view.onPosition = { [weak self] in self?.brightness?.set(position: $0) }
        view.onNits = { [weak self] in self?.brightness?.set(nits: $0, animated: true) }
        view.onEnabled = { [weak self] in self?.setEnabled($0) }
        view.onKeys = { [weak self] in self?.setKeys($0) }
        view.onLogin = { [weak self] in self?.setLogin($0) }
        view.onFixBetterDisplay = { [weak self] in self?.quitBetterDisplay() }
        view.onFixAccess = { [weak self] in self?.openAccess() }
        panel = view

        let menu = NSMenu()
        let holder = NSMenuItem()
        holder.view = view
        menu.addItem(holder)
        menu.addItem(.separator())
        menu.addItem(quitItem())
        return menu
    }

    private func quitItem() -> NSMenuItem {
        let quit = NSMenuItem(title: "Выйти и вернуть яркость macOS", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        return quit
    }

    func menuWillOpen(_ menu: NSMenu) { refreshEnvironment() }

    private func refreshEnvironment() {
        env.login = SMAppService.mainApp.status == .enabled
        env.betterDisplay = betterDisplayRunning
        env.needsAccess = defaults.bool(forKey: "keys") && !MediaKeys.isTrusted
        refresh()
    }

    @objc private func refresh() {
        guard let b = brightness, let panel else { return }
        keys.intercepting = b.engaged && !b.paused
        // выключен — показываем, что сейчас на панели на самом деле
        let shown = b.engaged ? b.targetNits : b.panel.nits
        panel.update(.init(nits: shown, position: b.position(for: shown),
                           sdrMark: b.position(for: b.panel.sdrNits), percent: b.percent,
                           boosted: b.isBoosted, engaged: b.engaged,
                           limitedTo: b.engaged && b.isLimited ? b.effectiveNits : nil,
                           keys: defaults.bool(forKey: "keys"), login: env.login,
                           betterDisplay: env.betterDisplay, needsAccess: env.needsAccess))

        setSymbol(!b.engaged ? "sun.min" : b.isBoosted ? "sun.max.fill" : "sun.max")
        item.button?.toolTip = b.engaged ? "Lumen: \(Int(b.targetNits.rounded())) нит" : "Lumen выключен"
    }

    private func setSymbol(_ name: String) {
        guard name != shownSymbol else { return }
        shownSymbol = name
        item.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Lumen")
    }

    private var betterDisplayRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.betterDisplayID).isEmpty
    }

    // ── События системы ───────────────────────────────────────────────────────

    @objc private func screensChanged() {
        if brightness == nil { setUp(); return }   // крышку открыли
        brightness?.screensChanged()
    }

    @objc private func screensSlept() { brightness?.pause(); refresh() }

    @objc private func screensWoke() {
        brightness?.resume()
        brightness?.reassertSoon()
        refresh()
    }

    /// Быстрая смена пользователя: на чужой сессии панель не наша.
    @objc private func sessionOff() { brightness?.release() }

    @objc private func sessionOn() {
        guard let b = brightness else { return }
        if defaults.bool(forKey: "enabled") && !betterDisplayRunning { b.engage() } else { b.reassertSoon() }
    }

    private func isBetterDisplay(_ n: Notification) -> Bool {
        (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.betterDisplayID
    }

    /// BetterDisplay в прямом режиме тоже пишет IOMFBBrightnessLevel — вдвоём
    /// они перетягивают подсветку. Пришёл он — уступаем, не трогая «включено».
    @objc private func appLaunched(_ n: Notification) {
        guard isBetterDisplay(n) else { return }
        brightness?.release()
        refreshEnvironment()
    }

    /// Ушёл BetterDisplay — он сам вернул свой пресет, теперь берём панель.
    @objc private func appTerminated(_ n: Notification) {
        guard isBetterDisplay(n) else { return }
        refreshEnvironment()
        guard let b = brightness, defaults.bool(forKey: "enabled"), !b.engaged, !betterDisplayRunning else { return }
        b.engage()
    }

    // ── Действия ──────────────────────────────────────────────────────────────

    private func setEnabled(_ on: Bool) {
        guard let b = brightness else { return }
        defaults.set(on, forKey: "enabled")
        if !on { b.release() }
        else if betterDisplayRunning { quitBetterDisplay() }   // панель возьмём, когда он закроется
        else { b.engage() }
        refresh()
    }

    private func setKeys(_ on: Bool) {
        defaults.set(on, forKey: "keys")
        on ? keys.start(prompt: true) : keys.stop()
        refreshEnvironment()
    }

    private func setLogin(_ on: Bool) {
        let s = SMAppService.mainApp
        do {
            try on ? s.register() : s.unregister()
            if s.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            item.menu?.cancelTracking()
            let a = NSAlert()
            a.messageText = on ? "Не получилось добавить Lumen в автозапуск" : "Не получилось убрать Lumen из автозапуска"
            a.informativeText = error.localizedDescription
                + (Bundle.main.bundlePath.hasPrefix("/Applications/") ? "" : "\n\nLumen запущен не из папки «Программы» — автозапуск работает только оттуда.")
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        refreshEnvironment()
    }

    private func openAccess() {
        item.menu?.cancelTracking()
        keys.start(prompt: false)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Панель берётся по факту выхода BetterDisplay (appTerminated), а не
    /// через фиксированную паузу: при выходе он сам возвращает свой пресет.
    private func quitBetterDisplay() {
        defaults.set(true, forKey: "enabled")
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.betterDisplayID).forEach { $0.terminate() }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

// `Lumen --restore` — вернуть исходный пресет, автояркость и системную
// яркость, если Lumen закрыли принудительно и запускать его больше не хотят.
if CommandLine.arguments.contains("--restore") {
    if let p = Panel() { Brightness.restoreSystem(p) }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
