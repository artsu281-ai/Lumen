import Cocoa
import ServiceManagement

// ── Строка меню ──────────────────────────────────────────────────────────────
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var item: NSStatusItem!
    private var brightness: Brightness!
    private var panel: MenuPanel!
    private let keys = MediaKeys()
    private let hud = HUD()
    private let defaults = UserDefaults.standard
    private var signals: [DispatchSourceSignal] = []

    static let betterDisplayID = "pro.betterdisplay.BetterDisplay"

    func applicationDidFinishLaunching(_ n: Notification) {
        guard let display = Panel(), display.directPreset != nil else {
            let a = NSAlert()
            a.messageText = "Нужен встроенный дисплей XDR"
            a.informativeText = "Lumen управляет подсветкой Liquid Retina XDR напрямую. Подходящий дисплей не найден."
            a.runModal(); NSApp.terminate(nil); return
        }
        Brightness.restoreSystem(display)   // если прошлый запуск упал, не оставив систему как была
        brightness = Brightness(panel: display)

        defaults.register(defaults: ["enabled": true, "keys": true])

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        item.menu?.delegate = self

        keys.onStep = { [weak self] up, fine in
            guard let self, self.brightness.engaged else { return }
            self.brightness.step(up: up, fine: fine)
            self.hud.show(self.brightness)
        }
        if defaults.bool(forKey: "keys") { keys.start(prompt: true) }
        if defaults.bool(forKey: "enabled") && !betterDisplayRunning { brightness.engage() }

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: Brightness.changed, object: nil)
        nc.addObserver(self, selector: #selector(reassert), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                     NSWorkspace.sessionDidBecomeActiveNotification] {
            ws.addObserver(self, selector: #selector(reassert), name: name, object: nil)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            ws.addObserver(self, selector: #selector(refresh), name: name, object: nil)
        }

        // kill / Ctrl+C / выход из системы — всё равно вернуть пресет
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { NSApp.terminate(nil) }
            s.resume()
            signals.append(s)
        }
        refresh()
    }

    func applicationWillTerminate(_ n: Notification) { brightness?.release() }

    // ── Меню ──────────────────────────────────────────────────────────────────

    private func buildMenu() -> NSMenu {
        let p = brightness.panel
        panel = MenuPanel(levels: [("moon.stars.fill", 20), ("sun.horizon.fill", 120),
                                   ("sun.max", p.sdrNits), ("sun.max.fill", 1000), ("sparkles", p.peakNits)])
        panel.sdrNits = p.sdrNits
        panel.onPosition = { [weak self] in self?.brightness.set(position: $0) }
        panel.onNits = { [weak self] in self?.brightness.set(nits: $0, animated: true) }
        panel.onEnabled = { [weak self] in self?.setEnabled($0) }
        panel.onKeys = { [weak self] in self?.setKeys($0) }
        panel.onLogin = { [weak self] in self?.setLogin($0) }
        panel.onFixBetterDisplay = { [weak self] in self?.quitBetterDisplay() }
        panel.onFixAccess = { [weak self] in self?.openAccess() }

        let menu = NSMenu()
        let holder = NSMenuItem()
        holder.view = panel
        menu.addItem(holder)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти и вернуть яркость macOS", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    @objc private func refresh() {
        guard let brightness, let panel else { return }
        let b = brightness
        // выключен — показываем, что сейчас на панели на самом деле
        let shown = b.engaged ? b.targetNits : b.panel.nits
        panel.update(.init(nits: shown, position: b.position(for: shown),
                           sdrMark: b.position(for: b.panel.sdrNits), percent: b.percent,
                           boosted: b.isBoosted, engaged: b.engaged,
                           keys: defaults.bool(forKey: "keys"),
                           login: SMAppService.mainApp.status == .enabled,
                           betterDisplay: betterDisplayRunning,
                           needsAccess: defaults.bool(forKey: "keys") && !MediaKeys.isTrusted))

        let symbol = !b.engaged ? "sun.min" : b.isBoosted ? "sun.max.fill" : "sun.max"
        item.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Lumen")
        item.button?.toolTip = b.engaged ? "Lumen: \(Int(b.targetNits.rounded())) нит" : "Lumen выключен"
    }

    private var betterDisplayRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.betterDisplayID).isEmpty
    }

    // ── Действия ──────────────────────────────────────────────────────────────

    @objc private func reassert() { brightness?.reassertSoon() }

    private func setEnabled(_ on: Bool) {
        if on {
            if betterDisplayRunning { quitBetterDisplay() }
            brightness.engage()
        } else {
            brightness.release()
        }
        defaults.set(brightness.engaged, forKey: "enabled")
        refresh()
    }

    private func setKeys(_ on: Bool) {
        defaults.set(on, forKey: "keys")
        on ? keys.start(prompt: true) : keys.stop()
        refresh()
    }

    private func setLogin(_ on: Bool) {
        let s = SMAppService.mainApp
        try? (on ? s.register() : s.unregister())
        refresh()
    }

    private func openAccess() {
        item.menu?.cancelTracking()
        keys.start(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// BetterDisplay в прямом режиме тоже пишет IOMFBBrightnessLevel — вдвоём
    /// они перетягивают подсветку. При выходе он сам возвращает свой пресет,
    /// поэтому после него панель берётся заново.
    private func quitBetterDisplay() {
        NSRunningApplication.runningApplications(withBundleIdentifier: Self.betterDisplayID).forEach { $0.terminate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.defaults.bool(forKey: "enabled") else { return }
            self.brightness.engage()
            self.brightness.reassertSoon()
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
