import AppKit
import SlovoCore

/// Три клавиши вкладки «Горячие клавиши» (6.1.6), у которых не было ни пункта
/// меню, ни обработчика: «Выбрать Общий фон» (`OpenCommonBG`, в поставке
/// Ctrl+B), «Выбрать фон Слайда» (`OpenSlideBG`, Ctrl+Alt+B) и «Режим
/// редакт./просмотр» Песенника (`ReactionOnCtrlE`, Ctrl+E).
///
/// Назначить сочетание в окне «Параметры» было можно, нажать — нет: строки
/// стояли в списке и ничего не делали.
///
/// Свой перехватчик, а не пункты меню: у автора этих трёх функций в меню нет
/// вовсе, а пункт с сочетанием забирает клавишу у всего приложения — включая
/// поля ввода в окне настроек. Раскладку читаем на каждое нажатие, поэтому
/// переназначенная по «Ок» клавиша работает сразу.
@MainActor
final class NativeWindowHotkeys {

    static let shared = NativeWindowHotkeys()

    private var monitor: Any?
    private weak var state: AppState?

    private init() {}

    func install(state: AppState) {
        self.state = state
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    /// Стоит ли перехватчик — для самопроверки.
    var isInstalled: Bool { monitor != nil }

    private func handle(_ event: NSEvent) -> Bool {
        let layout = EffectiveHotkeys.layout
        // Пока идёт ввод в поле, клавиша принадлежит полю: Ctrl+E в названии
        // песни должен ставить курсор в конец строки, а не менять режим окна.
        if isTyping { return false }

        if let hotkey = layout["OpenCommonBG"], HotkeyKeyNames.matches(hotkey, event: event) {
            NativeBottom.row?.control.chooseCommonBackground()
            return true
        }
        if let hotkey = layout["OpenSlideBG"], HotkeyKeyNames.matches(hotkey, event: event) {
            guard let control = NativeBottom.row?.control else { return false }
            control.chooseSlideBackground(from: control)
            return true
        }
        if let hotkey = layout["ReactionOnCtrlE"], HotkeyKeyNames.matches(hotkey, event: event) {
            return toggleSongEditMode()
        }
        return false
    }

    /// Курсор в поле ввода: у окна есть первый ответчик — текстовое поле.
    private var isTyping: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is NSTextView { return true }
        return responder is NSTextField
    }

    /// (30.1) и (30.4): вход в режим правки и выход из него. Выход спрашивает
    /// про несохранённый Песенник — за это отвечает сама модель.
    private func toggleSongEditMode() -> Bool {
        guard state?.mode == .songs else { return false }
        let model = NativeSongsWorkspace.shared.model
        if model.isEditing {
            model.leaveEditMode()
        } else {
            model.enterEditMode()
        }
        NativeSongsWorkspace.shared.bridge.sync()
        return true
    }
}
