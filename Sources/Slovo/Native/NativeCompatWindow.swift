import AppKit
import SlovoCore

/// Вікно «Перевірка сумісності»: що на ЦІЙ системі працює, а що ні.
///
/// Власник: «программа должна полностью работать на 11 версии макос». Із
/// цього Mac не видно, що саме не так на Big Sur, а просити людину лазити в
/// термінал — недобре. Тепер перевірка — пункт меню «Довідка»: вона проганяє
/// ту саму секцію `сумісність`, що й самоперевірка, показує результат і
/// кладе його в буфер обміну однією кнопкою.
@MainActor
final class NativeCompatWindow: NSWindowController {

    private static var shared: NativeCompatWindow?

    static func show(state: AppState) {
        if let shared {
            shared.window?.makeKeyAndOrderFront(nil)
            shared.run(state: state)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = OurWords.t("Проверка совместимости")
        window.center()
        let controller = NativeCompatWindow(window: window)
        controller.build()
        shared = controller
        window.makeKeyAndOrderFront(nil)
        controller.run(state: state)
    }

    private let text = NSTextView()
    private let status = NSTextField(labelWithString: "")

    private func build() {
        guard let window else { return }
        let root = NSView(frame: window.contentLayoutRect)
        root.autoresizingMask = [.width, .height]

        let scroll = NSScrollView(frame: NSRect(x: 12, y: 52, width: root.bounds.width - 24,
                                                height: root.bounds.height - 74))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        text.isEditable = false
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = text
        root.addSubview(scroll)

        status.frame = NSRect(x: 12, y: root.bounds.height - 34, width: root.bounds.width - 24, height: 18)
        status.autoresizingMask = [.width, .minYMargin]
        status.stringValue = OurWords.t("Проверяю…")
        root.addSubview(status)

        let copy = NSButton(title: OurWords.t("Скопировать"), target: self, action: #selector(copyAll))
        copy.frame = NSRect(x: 12, y: 12, width: 140, height: 28)
        copy.autoresizingMask = [.maxXMargin, .maxYMargin]
        root.addSubview(copy)

        let close = NSButton(title: OurWords.t("Закрыть"), target: self, action: #selector(closeWindow))
        close.frame = NSRect(x: root.bounds.width - 152, y: 12, width: 140, height: 28)
        close.autoresizingMask = [.minXMargin, .maxYMargin]
        close.keyEquivalent = "\u{1b}"
        root.addSubview(close)

        window.contentView = root
    }

    private func run(state: AppState) {
        status.stringValue = OurWords.t("Проверяю…")
        text.string = ""
        // Наступним кроком циклу: вікно має встигнути показатися.
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            let checks = Diagnostics.compatSection(state: state)
            let system = ProcessInfo.processInfo.operatingSystemVersion
            var lines = ["macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
                         OurWords.t("Версия %s", AppUpdater.currentVersion), ""]
            var bad = 0
            for check in checks {
                if check.status == .failed { bad += 1 }
                let mark: String
                switch check.status {
                case .ok: mark = "ок     "
                case .warning: mark = "увага  "
                case .failed: mark = "ПОМИЛКА"
                case .skipped: mark = "пропущено"
                }
                lines.append("\(mark)  \(check.name): \(check.detail)")
            }
            self.text.string = lines.joined(separator: "\n")
            self.status.stringValue = bad == 0
                ? OurWords.t("Всё работает на этой системе")
                : OurWords.t("Не работает: %s", "\(bad)")
        }
    }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.string, forType: .string)
        status.stringValue = OurWords.t("Скопировано — пришлите это разработчику")
    }

    @objc private func closeWindow() {
        window?.close()
        Self.shared = nil
    }
}
