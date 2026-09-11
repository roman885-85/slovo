import AppKit
import Combine
import SlovoCore

// MARK: - Имена клавиш в записи оригинала

/// Перевод кода клавиши macOS в то имя, каким её записывает `hotkeys.ini`:
/// 46 → «M», 98 → «F7», 53 → «Esc».
///
/// Отдельная таблица, а не разбор `charactersIgnoringModifiers`: с зажатым
/// Control система отдаёт управляющий символ (Ctrl+M — это `\r`), а на
/// русской раскладке та же клавиша даёт «ь». Код клавиши — это железо, он
/// один и тот же при любой раскладке, и именно так сочетание понимает
/// оригинал: у него в записи стоит физическая клавиша.
enum HotkeyKeyNames {

    /// Буквы и цифры верхнего ряда — раскладка ANSI, коды из `Carbon/Events.h`.
    private static let characters: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
        11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        31: "O", 32: "U", 34: "I", 35: "P", 37: "L", 38: "J", 40: "K",
        45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5",
        25: "9", 26: "7", 28: "8", 29: "0",
    ]

    /// F1…F20.
    private static let functions: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7,
        100: 8, 101: 9, 109: 10, 103: 11, 111: 12,
        105: 13, 107: 14, 113: 15, 106: 16, 64: 17,
        79: 18, 80: 19, 90: 20,
    ]

    /// Клавиши с собственным именем — написание то же, что у
    /// `Hotkey.canonicalKey`, иначе сравнение не сойдётся.
    private static let named: [UInt16: String] = [
        53: "Esc", 48: "Tab", 49: "Space", 36: "Enter", 76: "Enter",
        51: "BackSpace", 114: "Ins", 117: "Del",
        115: "Home", 119: "End", 116: "PgUp", 121: "PgDn",
        123: "Left", 124: "Right", 125: "Down", 126: "Up",
    ]

    /// Все имена, которые таблица умеет узнать. По ним самопроверка говорит,
    /// доживёт ли назначенное в окне сочетание до нажатия.
    static var allNames: Set<String> {
        var names = Set(named.values)
        names.formUnion(characters.values)
        for number in functions.values { names.insert("F\(number)") }
        return names
    }

    static func name(for code: UInt16) -> String? {
        if let number = functions[code] { return "F\(number)" }
        if let name = named[code] { return name }
        return characters[code]
    }

    /// Совпало ли событие с сочетанием из `hotkeys.ini`.
    ///
    /// Command не участвует ни в одном сочетании оригинала, поэтому любое
    /// нажатие с ⌘ отдаём системе: иначе программа съедала бы ⌘M «свернуть».
    static func matches(_ hotkey: Hotkey, event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad, .capsLock])

        guard !modifiers.contains(.command),
              hotkey.control == modifiers.contains(.control),
              hotkey.shift == modifiers.contains(.shift),
              hotkey.alt == modifiers.contains(.option) else { return false }
        return name(for: event.keyCode) == hotkey.key
    }
}

// MARK: - Клавиши медиа-плеера

/// Ctrl+M «Открыть Медиаплеер» и Ctrl+P «Медиаплеер Воспр./Пауза».
///
/// Обе функции у автора заведены в `hotkeys.ini` (`ShowMediaPlayer`,
/// `MediaPlayerPlayPause`) и показаны на вкладке «Горячие клавиши» (6.1.6),
/// но обработчика у них не было. Свой перехватчик, а не пункт меню: пункт с
/// сочетанием забирает клавишу у всего приложения, а нам нужно отдавать её
/// дальше, когда сочетание не наше, — так же сделаны стрелки и Esc.
///
/// Сюда же вынесено гашение видео в зале: `AppState.isLive` — единственный
/// признак «слайд скрыт», доступный снаружи, и подписка на него закрывает
/// кнопку «Скрыть» (13.2) без правок общего файла. Затемнение (13.3) и
/// «пустой слайд» ставят свои признаки сами — см. описание подключения.
@MainActor
final class MediaHotkeys {

    static let shared = MediaHotkeys()

    private var monitor: Any?
    private var observers: [AnyCancellable] = []
    private weak var installedFor: AppState?

    /// Раскладка — общая на программу: её же по «Ок» обновляет окно
    /// «Параметры», поэтому переназначенная там клавиша работает сразу.
    /// Запасные значения для `ShowMediaPlayer` и `MediaPlayerPlayPause`
    /// `EffectiveHotkeys` подставляет сам.
    private var keys: [String: Hotkey] { EffectiveHotkeys.layout }

    private static let showPlayer = "ShowMediaPlayer"
    private static let playPause = "MediaPlayerPlayPause"

    var isInstalled: Bool { monitor != nil }

    /// Записанное сочетание — для диагностики и подсказок.
    func hotkeyText(_ action: String) -> String? { keys[action]?.text }

    var showPlayerHotkeyText: String? { hotkeyText(Self.showPlayer) }
    var playPauseHotkeyText: String? { hotkeyText(Self.playPause) }

    /// Ставится один раз за запуск. Зовётся и из `.onAppear` панели плеера —
    /// тогда клавиши начинают работать хотя бы после первого её открытия,
    /// даже если вызова при старте программы никто не сделал.
    func install(state: AppState) {
        guard installedFor !== state || monitor == nil else { return }
        installedFor = state
        addMonitor(state: state)
        observeSlideVisibility(state: state)
    }

    private func addMonitor(state: AppState) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak state] event in
            guard let self, let state else { return event }
            return MainActor.assumeIsolated { self.handle(event, state: state) ? nil : event }
        }
    }

    private func handle(_ event: NSEvent, state: AppState) -> Bool {
        if let hotkey = keys[Self.showPlayer], HotkeyKeyNames.matches(hotkey, event: event) {
            state.isMediaOpen.toggle()
            return true
        }
        if let hotkey = keys[Self.playPause], HotkeyKeyNames.matches(hotkey, event: event) {
            state.media.playPause()
            return true
        }
        return false
    }

    /// «Скрыть слайд» (13.2) убирает из зала и видео: у оригинала кадр живёт
    /// внутри окна слайда и исчезает вместе с ним.
    private func observeSlideVisibility(state: AppState) {
        observers.removeAll()
        apply(isLive: state.isLive, to: state)
        state.$isLive
            .removeDuplicates()
            .sink { [weak state] live in
                guard let state else { return }
                MainActor.assumeIsolated { MediaHotkeys.shared.apply(isLive: live, to: state) }
            }
            .store(in: &observers)
    }

    private func apply(isLive: Bool, to state: AppState) {
        if isLive {
            state.media.screenSuppression.remove(.hiddenSlide)
        } else {
            state.media.screenSuppression.insert(.hiddenSlide)
        }
    }
}
