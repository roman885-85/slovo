import AppKit
import SlovoCore

/// Вікно «Програми для Android»: встановлення за QR-кодом.
///
/// Власник: «добавить функцию установки программ для андроид по qr коду».
/// Навели камеру телефона чи планшета на код — браузер завантажує
/// установочний файл просто зі «Слова» й пропонує встановити. Код — адресою
/// цифрами: старі Android імен .local не розуміють. Файли віддає сторінка
/// пульта в браузері, тож вона має бути ввімкнена — вікно про це скаже.
@MainActor
enum NativeAndroidAppsWindow {

    private static var window: NSWindow?
    private static var content: NativeAndroidAppsView?

    static func show() {
        if let window {
            content?.refresh()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = OurWords.t("Программы для Android")
        panel.isReleasedWhenClosed = false
        let view = NativeAndroidAppsView()
        panel.contentView = view
        panel.center()
        window = panel
        content = view
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Зберегти установочний файл на цей комп'ютер — з вікна і з параметрів.
@MainActor
enum AndroidAppFile {
    static func save(_ app: RemoteControlServer.AndroidApp) {
        guard let source = RemoteControlServer.androidFile(app) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = app.file
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

@MainActor
final class NativeAndroidAppsView: NSView {

    private struct Card {
        let app: RemoteControlServer.AndroidApp
        let caption: NSTextField
        let code: NSImageView
    }

    private var cards: [Card] = []
    private let note = NSTextField(wrappingLabelWithString: "")
    private var timer: Timer?
    private var shownCodes: [String: String] = [:]

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 470))
        build()
        refresh()
        // Сторінку пульта могли щойно ввімкнути, мережа могла змінитися —
        // коди мають вести туди, де «Слово» зараз.
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    /// Посилання на завантаження — цифрами, на порту сторінки пульта.
    static func downloadLink(_ app: RemoteControlServer.AndroidApp) -> String? {
        guard RemoteControlServer.shared.webRunning, let base = RemoteWebAddress.numeric else { return nil }
        return base + "download/\(app.id).apk"
    }

    private func build() {
        let title = NSTextField(wrappingLabelWithString: OurWords.t("Установить на телефон или планшет по QR-коду"))
        title.font = .boldSystemFont(ofSize: 15)
        let steps = NSTextField(wrappingLabelWithString: OurWords.t(
            "Наведите камеру устройства на код нужной программы — файл загрузится; нажмите его и разрешите установку из браузера."))
        steps.font = .systemFont(ofSize: 13)

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 28
        for app in RemoteControlServer.androidApps {
            let caption = NSTextField(wrappingLabelWithString: "")
            caption.font = .systemFont(ofSize: 13)
            caption.alignment = .center
            let code = NSImageView()
            code.imageScaling = .scaleNone
            code.wantsLayer = true
            code.layer?.backgroundColor = NSColor.white.cgColor
            code.layer?.cornerRadius = 6
            code.translatesAutoresizingMaskIntoConstraints = false
            code.widthAnchor.constraint(equalToConstant: 200).isActive = true
            code.heightAnchor.constraint(equalToConstant: 200).isActive = true
            let save = NativeForm.button(OurWords.t("Сохранить…"),
                                         hint: OurWords.t("Сохранить установочный файл на этот компьютер")) {
                AndroidAppFile.save(app)
            }
            save.isEnabled = RemoteControlServer.androidFile(app) != nil
            let column = NSStackView(views: [caption, code, save])
            column.orientation = .vertical
            column.alignment = .centerX
            column.spacing = 8
            caption.widthAnchor.constraint(equalToConstant: 240).isActive = true
            row.addArrangedSubview(column)
            cards.append(Card(app: app, caption: caption, code: code))
        }

        note.font = .systemFont(ofSize: 12)
        let stack = NSStackView(views: [title, steps, row, note])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -16),
        ])
    }

    func refresh() {
        for card in cards {
            let app = card.app
            card.caption.stringValue = app.title + (app.version.isEmpty ? "" : " " + app.version)
                + "\n" + OurWords.t("Android %s и новее", app.minAndroid)
            let link = Self.downloadLink(app) ?? ""
            if shownCodes[app.id] != link {
                shownCodes[app.id] = link
                card.code.image = link.isEmpty ? nil : NativeBrowserRemoteView.qr(link, side: 200)
            }
        }
        if RemoteControlServer.shared.webRunning {
            note.stringValue = OurWords.t(
                "Телефон или планшет — в той же сети Wi-Fi. Предупреждение Android о неизвестном разработчике ожидаемо: «Всё равно установить».")
            note.textColor = .secondaryLabelColor
        } else {
            note.stringValue = OurWords.t("Коды работают, когда включён пульт в браузере (Параметры → Remote API).")
            note.textColor = .systemRed
        }
    }

    /// Для самоперевірки: що показано — код і посилання кожної програми.
    var shown: [(id: String, code: NSImage?, link: String?)] {
        cards.map { ($0.app.id, $0.code.image, Self.downloadLink($0.app)) }
    }
}
