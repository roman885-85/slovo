import AppKit
import SlovoCore

/// Окреме вікно «Редактор невідповідностей нумерації перекладів Біблії» (N40).
///
/// Не аркуш поверх головного, а самостійне `NSWindow`, як «Конструктор
/// слайда»: поки правлять нумерацію, у головному вікні далі гортають вірші й
/// дивляться, чи сходиться. Аркуш замкнув би головне вікно, і перевіряти
/// було б нічим.
///
/// Вікно одне на програму й переживає закриття (`isReleasedWhenClosed =
/// false`). Хрестик вважається скасуванням — так само, як у «Кольоровій легенді»:
/// правки, не підтверджені «Ок», в оригіналі теж пропадають.
@MainActor
enum NumberingEditorWindow {

    private static var controller: NSWindowController?
    private static var model: NumberingEditorModel?
    private static var closeObserver: NSObjectProtocol?
    /// «Ок» уже відпрацював: тоді закриття не має відкочувати записане.
    private static var isFinishing = false

    static func show(state: AppState) {
        if let window = controller?.window {
            // Відкрили знову — база на диску могла змінитися, зокрема
            // нашою ж кнопкою «Повернути все як в автора».
            model?.reopen()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = NumberingEditorModel(state: state)
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = state.text("N40", default: "Редактор несоответствий нумерации переводов Библии")
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("NumberingEditorWindow")
        window.minSize = NSSize(width: 1000, height: 660)

        window.contentView = NativeNumberingEditor(state: state, model: model) { saved in
            finish(saved: saved)
        }
        window.center()

        // Хрестик — те саме, що «Скасувати». Знімок повертається цілком, на
        // диск при цьому нічого не йшло: свою копію пише тільки «Ок».
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                guard !isFinishing else { isFinishing = false; return }
                self.model?.revert()
            }
        }

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Натиснули «Ок» або «Скасувати». Записує й відкочує вікно, а не вид:
    /// знімок належить вікну, і вирішувати його долю має воно ж.
    private static func finish(saved: Bool) {
        guard let model else { return }
        if saved {
            if let failure = model.save() {
                // Не записалося — вікно не закриваємо: інакше правки пропали б
                // мовчки, а людина вважала б їх збереженими.
                model.status = OurWords.t("не записалось: %s", failure)
                return
            }
            isFinishing = true
        } else {
            model.revert()
            isFinishing = true
        }
        controller?.window?.performClose(nil)
    }
}

extension Notification.Name {
    /// Правила нумерації змінилися: адресу в другому перекладі треба рахувати
    /// заново. Надсилається за «Ок» вікна N40 — підписникові лишається перезібрати слайд.
    static let slovoNumberingChanged = Notification.Name("slovo.numberingChanged")
}
