import AppKit
import SlovoCore

/// Отдельное окно «Конструктор слайда» (раздел 6.3).
///
/// В оригинале это самостоятельное окно, а не лист поверх главного: пока
/// шаблон правят, в главном окне продолжают листать стихи и смотреть, как
/// ложится настоящий текст. Лист (`sheet`) главное окно бы заблокировал,
/// поэтому берём обычное `NSWindow`.
///
/// Окно одно на всю программу и живёт между открытиями: закрыли крестиком,
/// открыли снова — незаписанный шаблон на месте. Отсюда и `isReleasedWhenClosed
/// = false`: иначе AppKit разрушил бы окно, а вместе с ним и правки.
@MainActor
enum SlideConstructorWindow {

    private static var controller: NSWindowController?

    /// Открыть окно, создав его при первом обращении.
    static func show(state: AppState) {
        if let window = controller?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)

        let title = state.language?.caption("SlideConstructorForm",
                                            form: "SlideConstructorForm",
                                            default: "Конструктор слайда") ?? "Конструктор слайда"
        window.title = title
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SlideConstructorWindow")
        window.minSize = NSSize(width: 1120, height: 700)

        // Кнопка «Закрыть» внизу формы прячет именно это окно. Крестик и ⌘W
        // идут через тот же requestClose: иначе они миновали вопрос о
        // сохранении и не снимали живой шаблон с зала.
        window.contentView = NativeSlideConstructor(state: state) { [weak window] in
            closeGuard.isClosingProgrammatically = true
            window?.performClose(nil)
            closeGuard.isClosingProgrammatically = false
        }
        window.delegate = closeGuard
        window.center()

        let controller = NSWindowController(window: window)
        self.controller = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Крестик окна Конструктора: спросить о сохранении, как кнопка «Закрыть».
@MainActor
private let closeGuard = ConstructorCloseGuard()

final class ConstructorCloseGuard: NSObject, NSWindowDelegate {
    var isClosingProgrammatically = false
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isClosingProgrammatically { return true }
        (sender.contentView as? NativeSlideConstructor)?.requestClose()
        return false
    }
}
