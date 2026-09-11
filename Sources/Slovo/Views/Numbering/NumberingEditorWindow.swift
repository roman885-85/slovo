import AppKit
import SlovoCore

/// Отдельное окно «Редактор несоответствий нумерации переводов Библии» (N40).
///
/// Не лист поверх главного, а самостоятельное `NSWindow`, как «Конструктор
/// слайда»: пока правят нумерацию, в главном окне продолжают листать стихи и
/// смотреть, сходится ли. Лист главное окно бы запер, и проверять было бы
/// нечем.
///
/// Окно одно на программу и переживает закрытие (`isReleasedWhenClosed =
/// false`). Крестик считается отменой — так же, как в «Цветовой легенде»:
/// правки, не подтверждённые «Ок», в оригинале тоже пропадают.
@MainActor
enum NumberingEditorWindow {

    private static var controller: NSWindowController?
    private static var model: NumberingEditorModel?
    private static var closeObserver: NSObjectProtocol?
    /// «Ок» уже отработал: тогда закрытие не должно откатывать записанное.
    private static var isFinishing = false

    static func show(state: AppState) {
        if let window = controller?.window {
            // Открыли заново — база на диске могла измениться, в том числе
            // нашей же кнопкой «Вернуть всё как у автора».
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

        // Крестик — то же, что «Отменить». Снимок возвращается целиком, на
        // диск при этом ничего не уходило: свою копию пишет только «Ок».
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

    /// Нажали «Ок» или «Отменить». Записывает и откатывает окно, а не вид:
    /// снимок принадлежит окну, и решать его судьбу должно оно же.
    private static func finish(saved: Bool) {
        guard let model else { return }
        if saved {
            if let failure = model.save() {
                // Не записалось — окно не закрываем: иначе правки пропали бы
                // молча, а человек считал бы их сохранёнными.
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
    /// Правила нумерации изменились: адрес во втором переводе надо считать
    /// заново. Шлётся по «Ок» окна N40 — подписчику остаётся пересобрать слайд.
    static let slovoNumberingChanged = Notification.Name("slovo.numberingChanged")
}
