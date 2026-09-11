import AppKit
import CoreImage
import SlovoCore

/// Вікно «Пульт у браузері»: як відкрити «Слово» з планшета, телефона чи
/// іншого комп'ютера.
///
/// Власник: «пульт в браузере не открывается. Нужно, чтобы в основной
/// программе были подсказки по запуску с браузера». Тут усе, що треба
/// людині біля планшета: коротка адреса за ім'ям (slovo.local), QR-код для
/// камери, запасна адреса цифрами, три кроки і живий стан — чи працює
/// сторінка і на якому порту, чи оголошено ім'я, чи потрібен пароль.
@MainActor
enum NativeBrowserRemoteWindow {

    private static var window: NSWindow?
    private static var content: NativeBrowserRemoteView?

    static func show(state: AppState) {
        if let window {
            content?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = OurWords.t("Пульт в браузере")
        panel.isReleasedWhenClosed = false
        let view = NativeBrowserRemoteView()
        panel.contentView = view
        panel.center()
        window = panel
        content = view
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@MainActor
final class NativeBrowserRemoteView: NSView {

    private let nameLink = NSTextField(labelWithString: "")
    private let numberLink = NSTextField(labelWithString: "")
    private let statusLine = NSTextField(wrappingLabelWithString: "")
    private let code = NSImageView()
    private var timer: Timer?
    private var shownCode = ""

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 680, height: 480))
        build()
        refresh()
        // Ім'я оголошується за секунду-дві після запуску, а мережа може
        // змінитися будь-коли — вікно показує живий стан, а не знімок.
        RemoteName.shared.onChange = { [weak self] in self?.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    private func build() {
        func text(_ value: String, size: CGFloat = 13, bold: Bool = false, secondary: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: value)
            label.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            if secondary { label.textColor = .secondaryLabelColor }
            return label
        }

        nameLink.font = .systemFont(ofSize: 26, weight: .semibold)
        nameLink.textColor = .controlAccentColor
        nameLink.isSelectable = true
        numberLink.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        numberLink.isSelectable = true
        statusLine.font = .systemFont(ofSize: 12)

        let copy = NativeForm.button(OurWords.t("Скопировать"),
                                     hint: OurWords.t("Положить адрес в буфер обмена")) { [weak self] in
            self?.copyLink()
        }
        let open = NativeForm.button(OurWords.t("Открыть здесь"),
                                     hint: OurWords.t("Открыть страницу в браузере этого компьютера")) { [weak self] in
            self?.openLink()
        }
        let buttons = NSStackView(views: [copy, open])
        buttons.spacing = 8

        let left = NSStackView(views: [
            text(OurWords.t("«Слово» из браузера планшета, телефона или другого компьютера"), size: 15, bold: true),
            text(OurWords.t("1. Устройство — в той же сети Wi-Fi, что и этот компьютер.")),
            text(OurWords.t("2. В браузере наберите:")),
            nameLink,
            buttons,
            text(OurWords.t("3. Или наведите камеру планшета или телефона на код справа.")),
            text(OurWords.t("Если по имени не открывается (бывает на старых Android) — адрес цифрами:"), secondary: true),
            numberLink,
            text(OurWords.t("Пароль — если задан в Параметры → Remote API; страница спросит его сама."), secondary: true),
            text(OurWords.t("Программы для Android — кнопка «Android» на странице или установка по QR-коду:"), secondary: true),
            NativeForm.button(OurWords.t("Установить по QR-коду…"),
                              hint: OurWords.t("Показать QR-коды: камера телефона или планшета загрузит и установит программу")) {
                NativeAndroidAppsWindow.show()
            },
            statusLine,
        ])
        left.orientation = .vertical
        left.alignment = .leading
        left.spacing = 8
        left.setCustomSpacing(2, after: nameLink)
        left.translatesAutoresizingMaskIntoConstraints = false

        code.imageScaling = .scaleNone
        code.translatesAutoresizingMaskIntoConstraints = false
        code.wantsLayer = true
        code.layer?.backgroundColor = NSColor.white.cgColor
        code.layer?.cornerRadius = 6

        addSubview(left)
        addSubview(code)
        NSLayoutConstraint.activate([
            left.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            left.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            left.trailingAnchor.constraint(equalTo: code.leadingAnchor, constant: -20),
            left.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
            code.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            code.topAnchor.constraint(equalTo: topAnchor, constant: 24),
            code.widthAnchor.constraint(equalToConstant: 220),
            code.heightAnchor.constraint(equalToConstant: 220),
        ])
    }

    /// Головне посилання: за ім'ям, якщо його вже оголошено, інакше цифрами.
    private var mainLink: String? { RemoteWebAddress.named ?? RemoteWebAddress.numeric }

    func refresh() {
        let server = RemoteControlServer.shared
        let named = RemoteWebAddress.named
        let numeric = RemoteWebAddress.numeric
        nameLink.stringValue = named ?? numeric ?? "—"
        numberLink.stringValue = numeric ?? "—"

        // QR — цифрами: камера на будь-якому пристрої відкриє його без
        // оголошених імен (старі Android їх не розуміють).
        let codeText = numeric ?? ""
        if codeText != shownCode {
            shownCode = codeText
            code.image = codeText.isEmpty ? nil : Self.qr(codeText, side: 220)
        }

        var lines: [String] = []
        if numeric == nil {
            lines.append(OurWords.t("Сети не видно — подключите компьютер к Wi-Fi или кабелю."))
        }
        if !server.webRunning {
            lines.append(server.webError
                ?? OurWords.t("Пульт в браузере выключен — страница не откроется. Включите его в Параметры → Remote API."))
        } else {
            var parts = [OurWords.t("работает на порту %s", "\(server.webPort)")]
            if let name = RemoteName.shared.name {
                parts.append(OurWords.t("имя %s объявлено в сети", name))
            } else {
                parts.append(OurWords.t("имя пока не объявлено — пользуйтесь адресом цифрами"))
            }
            if server.plainReady {
                parts.append(OurWords.t("адрес без номера порта"))
            } else if server.webNoPort {
                parts.append(server.plainError ?? OurWords.t("порт 80 занят — адрес с номером порта"))
            }
            if server.webHasPassword { parts.append(OurWords.t("вход с паролем")) }
            if server.webViewOnly { parts.append(OurWords.t("только просмотр")) }
            lines.append(parts.joined(separator: " · "))
        }
        statusLine.stringValue = lines.joined(separator: "\n")
        statusLine.textColor = server.webRunning && numeric != nil ? .secondaryLabelColor : .systemRed
    }

    /// Для самоперевірки: що зараз показано у вікні.
    var shown: (name: String, number: String, status: String, code: NSImage?) {
        (nameLink.stringValue, numberLink.stringValue, statusLine.stringValue, code.image)
    }

    private func copyLink() {
        guard let link = mainLink else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    private func openLink() {
        guard let link = mainLink, let url = URL(string: link) else { return }
        NSWorkspace.shared.open(url)
    }

    /// QR-код без згладжування: модулі мають лишатися різкими квадратами,
    /// інакше камера на відстані його не прочитає.
    static func qr(_ text: String, side: CGFloat) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }
        let scale = max(1, floor((side - 16) / output.extent.width))
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: scaled.extent.width, height: scaled.extent.height))
    }
}
