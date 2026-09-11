import AppKit
import SlovoCore

/// Отдельное окно «Цветовая легенда частей песен» (6.4) — на AppKit.
///
/// В оригинале это соседний с «Параметрами» пункт меню «Настройка»
/// (`NSongColorSet`), а не кнопка внутри окна параметров: у формы свои «Ок» и
/// «Отменить», и открывать её можно, не открывая настройки.
///
/// Окно одно на программу и живёт между открытиями. Закрытие крестиком
/// считается отменой: иначе в хранилище настроек навсегда остался бы лишний
/// слой снимков, и следующая «Отмена» откатила бы не то.
@MainActor
enum NativeSongColorsetWindow {

    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?
    /// Слой снимка настроек, снятый этим окном.
    private static var session: SettingsStore.EditSession?

    static func show(state: AppState) {
        let store = SettingsStore.shared
        if let window {
            if session == nil { session = store.beginEditing() }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        store.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        session = store.beginEditing()

        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 672, height: 502),
                             styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
        panel.title = state.vb("SongColorsetForm", form: "SongColorsetForm",
                               "Цветовая легенда частей песен")
        panel.isReleasedWhenClosed = false
        panel.setFrameAutosaveName("SongColorsetWindow")
        // Вид только сообщает, какую кнопку нажали: снимок настроек
        // принадлежит окну, оно же его и разрешает. Иначе «Ок» здесь снимал
        // бы слой соседних «Параметров».
        panel.contentView = NativeSongColorsetView(state: state, store: store) { saved in
            finish(saved: saved)
        }
        panel.center()

        // Крестик — то же, что «Отменить»: правки, не подтверждённые «Ок»,
        // в оригинале тоже пропадают.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: panel, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                SettingsStore.shared.cancelIfEditing(session)
                session = nil
            }
        }
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func finish(saved: Bool) {
        let store = SettingsStore.shared
        if saved { store.save(session) } else { store.cancel(session) }
        session = nil
        window?.orderOut(nil)
    }

    static func close() {
        window?.performClose(nil)
    }
}
