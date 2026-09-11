import AppKit
import SlovoCore

/// Отдельное окно редактора веб-слайдов.
///
/// Отдельное, а не лист поверх главного: править разметку и одновременно
/// поглядывать на список стихов — обычное дело, а лист закрывает всё окно.
@MainActor
enum WebSlideEditorWindow {

    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show(state: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Розмір беремо не «як хочеться», а «скільки є екрана». Власник:
        // «при открытии окна данных настроек, часть кнопок не видно из-за
        // некорректной работы масштабирования». 1240×760 на ноутбуці не
        // влазило, система стискала вікно — і полоси кнопок обрізалися.
        let free = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame.size
            ?? NSSize(width: 1240, height: 760)
        let size = NSSize(width: min(1240, max(760, free.width - 40)),
                          height: min(760, max(520, free.height - 40)))

        let editor = NativeWebSlideEditor(state: state)
        let created = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        created.contentView = editor
        // Закрыли окно — недописанные правки должны лечь на диск.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: created, queue: .main
        ) { _ in MainActor.assumeIsolated { editor.finish(); window = nil } }
        created.title = OurWords.t("Редактор веб-слайдов")
        created.setContentSize(size)
        // Менше цього вікно робити нема сенсу: список сторінок і панель
        // ручок перестають бути читабельними. Полоси кнопок від вузького
        // вікна більше не страждають — вони переносять ряди.
        created.contentMinSize = NSSize(width: 720, height: 460)
        created.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        created.isReleasedWhenClosed = false
        created.center()
        created.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        window = created
    }
}
