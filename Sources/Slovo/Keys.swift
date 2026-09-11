import AppKit
import SlovoCore

/// Гарячі клавіші беремо з `hotkeys.ini` програми — розкладка має
/// збігатися зі звичною до клавіші, інакше на служінні рука схибить.
enum Keys {
    /// Клавиша пункта меню — строкой, как её ждёт `NSMenuItem`.
    ///
    /// Раньше здесь были величины SwiftUI (`KeyEquivalent`, `EventModifiers`).
    /// Меню давно собирается средствами AppKit, и держать ради него чужие
    /// типы значило тянуть SwiftUI в самый низ программы.
    static func function(_ number: Int) -> String {
        // NSF1FunctionKey = 0xF704, дальше подряд.
        String(Character(UnicodeScalar(0xF704 + number - 1)!))
    }

    static let showSlide       = function(5)    // F5
    static let hideSlide       = "\u{1B}"          // Esc
    static let search          = function(3)    // F3
    static let fastInput       = function(4)    // F4
    static let plan            = function(2)    // F2
    static let mainWindow      = function(6)    // F6
    static let screenshot      = function(11)   // F11
    static let blackScreen     = function(12)   // F12
    static let blankSlide      = function(5)    // Ctrl+F5
    static let backgroundOnSlide = function(9)  // Ctrl+F9
    static let fastInputBook   = function(7)    // F7
    static let fastInputChapter = function(8)   // F8
    static let fastInputVerse  = function(9)    // F9

    /// Сочетание функции для пункта меню — из окна «Параметры», а не зашитое.
    ///
    /// Семь пунктов меню («Показать слайд», «Скрыть слайд», «Пустой слайд»,
    /// «Затемнение», «Общий фон», «Снимок экрана», «Фокус на Стихи/Текст»)
    /// брали клавишу отсюда же, но константой: переназначенная на вкладке
    /// «Горячие клавиши» (6.1.6) не действовала ни на одну из них, и в меню
    /// по-прежнему стояла старая. Теперь спрашиваем раскладку.
    ///
    /// Запасное значение остаётся: пока `hotkeys.ini` не прочитан, меню всё
    /// равно должно работать привычными клавишами.
    @MainActor
    static func assigned(_ action: String,
                         fallback: String,
                         fallbackModifiers: NSEvent.ModifierFlags = []) -> (String, NSEvent.ModifierFlags) {
        guard let hotkey = EffectiveHotkeys.hotkey(action),
              let key = equivalent(for: hotkey.key) else {
            return (fallback, fallbackModifiers)
        }
        var modifiers: NSEvent.ModifierFlags = []
        if hotkey.control { modifiers.insert(.control) }
        if hotkey.alt { modifiers.insert(.option) }
        if hotkey.shift { modifiers.insert(.shift) }
        return (key, modifiers)
    }

    /// Имя клавиши в записи оригинала → клавиша меню. Список тот же, что у
    /// `HotkeyKeyNames`, только в другую сторону.
    private static func equivalent(for name: String) -> String? {
        if name.hasPrefix("F"), let number = Int(name.dropFirst()), (1...20).contains(number) {
            return function(number)
        }
        // Значения — те, что `NSMenuItem` ждёт в `keyEquivalent`: клавиши
        // без печатного знака записаны своими кодами из `NSText`/AppKit.
        switch name {
        case "Esc":       return "\u{1B}"
        case "Tab":       return "\t"
        case "Space":     return " "
        case "Enter":     return "\r"
        case "BackSpace": return "\u{8}"
        case "Del":       return String(UnicodeScalar(NSDeleteFunctionKey)!)
        case "Home":      return String(UnicodeScalar(NSHomeFunctionKey)!)
        case "End":       return String(UnicodeScalar(NSEndFunctionKey)!)
        case "PgUp":      return String(UnicodeScalar(NSPageUpFunctionKey)!)
        case "PgDn":      return String(UnicodeScalar(NSPageDownFunctionKey)!)
        case "Left":      return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "Right":     return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "Up":        return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "Down":      return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        default:
            // Буква или цифра. В меню macOS пишется строчной — заглавная
            // означала бы «с Shift», а Shift у нас приходит отдельно.
            guard name.count == 1 else { return nil }
            return name.lowercased()
        }
    }
}

/// Esc обязан гасить показ при любом положении дел — даже если меню не
/// получило событие или фокус ушёл в чужое окно. Это же и страховка от
/// ситуации, когда слайд занял единственный экран и управлять нечем.
@MainActor
final class EscapeGuard {
    private var monitor: Any?

    /// - Parameter action: возвращает `true`, если Esc был использован для
    ///   скрытия слайда. В остальных случаях событие идёт дальше — иначе Esc
    ///   перестанет закрывать диалоги и сбрасывать поля ввода.
    func install(_ action: @escaping () -> Bool) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 53 else { return event }   // 53 = Esc
            return action() ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
