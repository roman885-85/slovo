import AppKit
import SlovoCore

/// Окреме вікно «Конструктор слайда» (розділ 6.3).
///
/// В оригіналі це самостійне вікно, а не аркуш поверх головного: поки
/// шаблон правлять, у головному вікні далі гортають вірші й дивляться, як
/// лягає справжній текст. Аркуш (`sheet`) заблокував би головне вікно,
/// тому беремо звичайне `NSWindow`.
///
/// Вікно одне на всю програму й живе між відкриттями: закрили хрестиком,
/// відкрили знову — незаписаний шаблон на місці. Звідси й `isReleasedWhenClosed
/// = false`: інакше AppKit зруйнував би вікно, а разом із ним і правки.
@MainActor
enum SlideConstructorWindow {

    private static var controller: NSWindowController?

    /// Відкрити вікно, створивши його при першому зверненні.
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

        // Кнопка «Закрити» внизу форми ховає саме це вікно. Хрестик і ⌘W
        // ідуть через той самий requestClose: інакше вони минали питання про
        // збереження й не знімали живий шаблон із залу.
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

/// Хрестик вікна Конструктора: спитати про збереження, як кнопка «Закрити».
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
