import AppKit
import CoreGraphics
import Network
import SlovoCore

/// Дозволи macOS, без яких частина «Слова» не працює.
///
/// Власник: «сейчас при попытке захвата окна, пишет, что нет разрешения.
/// Нужно добавить проверку всех разрешений, которые нужны программе, при
/// запуске и если чего-то не хватает, сообщить и предложить дать разрешение,
/// с открытием окна». Досі про брак дозволу людина дізнавалася посеред
/// служіння — з рядка у вкладці «Екран».
///
/// Мікрофон, камера, контакти, «Універсальний доступ» програмі не потрібні;
/// доступ до тек macOS просить сама в мить відкриття файлу, і наперед його
/// не перевірити, не показавши людині зайвого запиту.
enum SystemPermission: String, CaseIterable {
    /// Вкладка «Екран» і звук потоків та YouTube у NDI.
    case screenRecording
    /// Пульт, планшет, пульт у браузері, NDI (macOS 15 і новіші).
    case localNetwork
    /// Вхідні з'єднання — лише коли ввімкнено брандмауер.
    case firewall

    enum Status: Equatable {
        case granted
        case missing
        /// На цій системі чи з цими налаштуваннями дозвіл не потрібен.
        case notNeeded
        /// Не з'ясовано (перевірка не дала відповіді).
        case unknown
    }

    var symbol: String {
        switch self {
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .localNetwork: return "network"
        case .firewall: return "shield.lefthalf.filled"
        }
    }

    var title: String {
        switch self {
        case .screenRecording: return OurWords.t("Запись экрана и системного звука")
        case .localNetwork: return OurWords.t("Локальная сеть")
        case .firewall: return OurWords.t("Входящие соединения (брандмауэр)")
        }
    }

    var purpose: String {
        switch self {
        case .screenRecording:
            return OurWords.t("Вкладка «Экран» (монитор или окно другой программы в зале) и звук потоков и YouTube в NDI.")
        case .localNetwork:
            return OurWords.t("Пульт на телефоне, планшет, пульт в браузере и трансляция NDI.")
        case .firewall:
            return OurWords.t("Чтобы пульт и планшет могли подключиться к этому компьютеру.")
        }
    }

    /// Розділ «Системних параметрів», де цей дозвіл вмикають.
    var settingsURL: URL? {
        let major = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        switch self {
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        case .localNetwork:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        case .firewall:
            return URL(string: major >= 13
                       ? "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall"
                       : "x-apple.systempreferences:com.apple.preference.security?Firewall")
        }
    }
}

/// Перевірка дозволів. Частина відповідей приходить не одразу (мережа,
/// брандмауер), тому зібране віддається в `completion`.
@MainActor
final class SystemPermissions {

    static let shared = SystemPermissions()

    private(set) var statuses: [SystemPermission: SystemPermission.Status] = [:]
    private var browser: NWBrowser?

    /// Чого бракує зараз.
    var missing: [SystemPermission] {
        SystemPermission.allCases.filter { statuses[$0] == .missing }
    }

    func refresh(completion: @escaping () -> Void) {
        statuses[.screenRecording] = CGPreflightScreenCaptureAccess() ? .granted : .missing
        let group = DispatchGroup()

        // Локальна мережа: окремий дозвіл є лише з macOS 15. Спитати систему
        // напряму нема чим — пробуємо пошук Bonjour: коли дозволу нема, він
        // зупиняється з помилкою «заборонено політикою» (−65570).
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 15 {
            group.enter()
            probeLocalNetwork { [weak self] status in
                self?.statuses[.localNetwork] = status
                group.leave()
            }
        } else {
            statuses[.localNetwork] = .notNeeded
        }

        // Брандмауер: якщо вимкнено — дозвіл не потрібен.
        group.enter()
        let bundle = Bundle.main.bundleURL.path
        DispatchQueue.global(qos: .utility).async {
            let status = Self.firewallStatus(bundlePath: bundle)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.statuses[.firewall] = status
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) {
            MainActor.assumeIsolated { completion() }
        }
    }

    private func probeLocalNetwork(_ done: @escaping (SystemPermission.Status) -> Void) {
        browser?.cancel()
        let probe = NWBrowser(for: .bonjour(type: "_slovo._tcp", domain: nil), using: .tcp)
        browser = probe
        var answered = false
        func answer(_ status: SystemPermission.Status) {
            guard !answered else { return }
            answered = true
            probe.cancel()
            done(status)
        }
        probe.stateUpdateHandler = { state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    switch state {
                    case .ready:
                        answer(.granted)
                    case .waiting(let error), .failed(let error):
                        if case .dns(let code) = error, code == -65570 { answer(.missing) } else { answer(.unknown) }
                    default:
                        break
                    }
                }
            }
        }
        probe.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            MainActor.assumeIsolated { answer(.unknown) }
        }
    }

    /// Відповідь `socketfilterfw`: брандмауер, «блокувати всі вхідні» і сам
    /// дозвіл програми.
    nonisolated static func firewallStatus(bundlePath: String) -> SystemPermission.Status {
        func run(_ arguments: [String]) -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/libexec/ApplicationFirewall/socketfilterfw")
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            guard (try? process.run()) != nil else { return "" }
            process.waitUntilExit()
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        }
        let global = run(["--getglobalstate"])
        guard !global.isEmpty else { return .unknown }
        if global.contains("disabled") || global.contains("State = 0") { return .notNeeded }
        if run(["--getblockall"]).contains("enabled") { return .missing }
        let app = run(["--getappblocked", bundlePath])
        if app.contains("is blocked") { return .missing }
        if app.contains("is permitted") { return .granted }
        // Програми ще немає в списку брандмауера — macOS спитає сама при
        // першому з'єднанні.
        return .unknown
    }

    /// Попросити дозвіл: системний запит, де він є, і відповідний розділ
    /// «Системних параметрів».
    func request(_ permission: SystemPermission) {
        if permission == .screenRecording, !CGPreflightScreenCaptureAccess() {
            // Системний запит з'являється лише першого разу; далі вмикають
            // тільки в параметрах, тому відкриваємо їх завжди.
            _ = CGRequestScreenCaptureAccess()
        }
        if let url = permission.settingsURL { NSWorkspace.shared.open(url) }
    }
}

/// Вікно «Дозволи macOS»: що потрібно, що дозволено, кнопка до параметрів.
@MainActor
final class NativePermissionsWindow: NSObject, NSWindowDelegate {

    static let shared = NativePermissionsWindow()

    /// Чи перевіряти під час запуску. За умовчанням — так.
    static var checksOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "permissionsCheckOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "permissionsCheckOnLaunch") }
    }

    private var window: NSWindow?
    private var rows: [SystemPermission: (status: NSTextField, button: NSButton)] = [:]
    private let restartButton = NSButton()
    private let launchBox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private var becameActive: Any?
    /// Людина натиснула «Дозволити» для запису екрана: після ввімкнення
    /// потрібен перезапуск — показати кнопку.
    private var askedScreen = false

    /// При запуску: перевірити й показати вікно, лише якщо чогось бракує.
    static func checkOnLaunch() {
        guard checksOnLaunch else { return }
        SystemPermissions.shared.refresh {
            guard !SystemPermissions.shared.missing.isEmpty else { return }
            shared.show()
        }
    }

    /// З меню: показати завжди.
    static func open() {
        shared.show()
        SystemPermissions.shared.refresh { shared.update() }
    }

    /// Чи вікно зараз відкрите — самоперевірці.
    var isShown: Bool { window?.isVisible ?? false }
    /// Що написано в рядку дозволу — самоперевірці.
    func statusTextForCheck(_ permission: SystemPermission) -> String { rows[permission]?.status.stringValue ?? "" }
    func close() { window?.orderOut(nil) }
    /// Знімок вмісту вікна у `~/Library/Logs/<name>` — самоперевірці.
    func snapshotForCheck(to name: String) -> Bool {
        guard let view = window?.contentView else { return false }
        return Diagnostics.snapshot(view, to: name)
    }

    private func show() {
        if window == nil { build() }
        update()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func build() {
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.title = OurWords.t("Разрешения macOS")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)

        let intro = NSTextField(wrappingLabelWithString: OurWords.t("Чтобы все части «Слова» работали, macOS должна им это разрешить. Чего не хватает — отмечено красным: нажмите «Разрешить…», включите «Слово» в открывшемся окне «Системных настроек» и вернитесь сюда."))
        intro.font = .systemFont(ofSize: 12)
        intro.preferredMaxLayoutWidth = 560
        stack.addArrangedSubview(intro)

        for permission in SystemPermission.allCases {
            let icon = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular)) ?? NSImage())
            icon.contentTintColor = .controlAccentColor
            icon.widthAnchor.constraint(equalToConstant: 30).isActive = true
            let title = NSTextField(labelWithString: permission.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let purpose = NSTextField(wrappingLabelWithString: permission.purpose)
            purpose.font = .systemFont(ofSize: 11)
            purpose.textColor = .secondaryLabelColor
            purpose.preferredMaxLayoutWidth = 330
            let status = NSTextField(labelWithString: "")
            status.font = .systemFont(ofSize: 11, weight: .medium)
            let texts = NSStackView(views: [title, purpose, status])
            texts.orientation = .vertical
            texts.alignment = .leading
            texts.spacing = 2
            let button = NSButton(title: OurWords.t("Разрешить…"), target: self, action: #selector(grant(_:)))
            button.bezelStyle = .rounded
            button.identifier = NSUserInterfaceItemIdentifier(permission.rawValue)
            button.toolTip = OurWords.t("Открыть нужный раздел «Системных настроек»")
            let row = NSStackView(views: [icon, texts, NSView(), button])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.widthAnchor.constraint(equalToConstant: 560).isActive = true
            stack.addArrangedSubview(row)
            rows[permission] = (status, button)
        }

        launchBox.title = OurWords.t("Проверять разрешения при запуске")
        launchBox.target = self
        launchBox.action = #selector(launchToggled)
        launchBox.state = Self.checksOnLaunch ? .on : .off
        restartButton.title = OurWords.t("Перезапустить «Слово»")
        restartButton.bezelStyle = .rounded
        restartButton.target = self
        restartButton.action = #selector(restart)
        restartButton.toolTip = OurWords.t("Запись экрана начинает работать после перезапуска программы")
        let again = NSButton(title: OurWords.t("Проверить снова"), target: self, action: #selector(recheck))
        again.bezelStyle = .rounded
        let close = NSButton(title: OurWords.t("Закрыть"), target: self, action: #selector(closeTapped))
        close.bezelStyle = .rounded
        close.keyEquivalent = "\r"
        let footer = NSStackView(views: [launchBox, NSView(), restartButton, again, close])
        footer.orientation = .horizontal
        footer.spacing = 8
        footer.widthAnchor.constraint(equalToConstant: 560).isActive = true
        stack.addArrangedSubview(footer)

        panel.contentView = stack
        panel.setContentSize(stack.fittingSize)
        window = panel
        // Повернулися з «Системних параметрів» — перевірити заново.
        becameActive = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                              object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window?.isVisible == true else { return }
                SystemPermissions.shared.refresh { self.update() }
            }
        }
    }

    private func update() {
        for permission in SystemPermission.allCases {
            guard let row = rows[permission] else { continue }
            let status = SystemPermissions.shared.statuses[permission] ?? .unknown
            switch status {
            case .granted:
                row.status.stringValue = "✓ " + OurWords.t("Разрешено")
                row.status.textColor = .systemGreen
            case .missing:
                row.status.stringValue = "✕ " + OurWords.t("Нет разрешения")
                row.status.textColor = .systemRed
            case .notNeeded:
                row.status.stringValue = permission == .firewall
                    ? OurWords.t("Не нужно: брандмауэр выключен")
                    : OurWords.t("Не нужно на этой версии macOS")
                row.status.textColor = .secondaryLabelColor
            case .unknown:
                row.status.stringValue = permission == .firewall
                    ? OurWords.t("macOS спросит при первом подключении пульта")
                    : OurWords.t("Не удалось проверить — при необходимости откройте настройки")
                row.status.textColor = .secondaryLabelColor
            }
            row.button.isEnabled = status != .notNeeded
            row.button.title = status == .granted ? OurWords.t("Системные настройки…") : OurWords.t("Разрешить…")
        }
        let screenGranted = SystemPermissions.shared.statuses[.screenRecording] == .granted
        restartButton.isHidden = !(askedScreen && screenGranted)
    }

    @objc private func grant(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue, let permission = SystemPermission(rawValue: raw) else { return }
        if permission == .screenRecording { askedScreen = true }
        SystemPermissions.shared.request(permission)
    }

    @objc private func recheck() { SystemPermissions.shared.refresh { [weak self] in self?.update() } }
    @objc private func closeTapped() { window?.performClose(nil) }
    @objc private func launchToggled() { Self.checksOnLaunch = launchBox.state == .on }

    /// Перезапуск: новий запуск через мить, цей — закривається.
    @objc private func restart() {
        let path = Bundle.main.bundleURL.path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
