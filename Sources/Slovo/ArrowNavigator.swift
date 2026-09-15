import AppKit

/// Перелистывание стрелками без модификаторов — как в оригинале.
///
/// Через меню это не сделать: пункт с горячей клавишей «стрелка вправо» без
/// ⌘ перехватывает её у всего приложения, и списки книг, глав и стихов
/// перестают прокручиваться с клавиатуры. Поэтому ловим событие сами и
/// пропускаем его дальше, когда оно адресовано не нам.
///
/// Раскладка повторяет подсказку `CBLinkSlides` оригинала:
///   связано:    ← →  перелистывают стих,  ↑ ↓  главу;
///   не связано: ↑ ↓  перелистывают стих,  ← →  главу.
@MainActor
final class ArrowNavigator {

    private var monitor: Any?

    /// Стоит ли перехватчик — это проверяет диагностика.
    var isInstalled: Bool { monitor != nil }

    struct Actions {
        /// `live` — уходит ли смена в зал или меняется только предпросмотр.
        let stepVerse: (Int, Bool) -> Void
        /// Shift со стрелкой раздвигает выделение на соседний стих.
        let extendSelection: (Int, Bool) -> Void
        /// Ctrl+A — вся глава на один слайд.
        let selectAll: () -> Void
        let isLinked: () -> Bool
        /// Галочка «Активна» панелі «Керування». Знято — стрілки лише
        /// гортають передпоказ, а в зал слайд іде через «Показати» чи Enter.
        let isActive: () -> Bool
        /// Enter — «показать текущий стих в зале», как в оригинале.
        let show: () -> Void
        /// Кнопка «затемнить» на пульте докладчика — то же, что F12.
        let blackout: () -> Void
    }

    func install(_ actions: Actions) {
        guard monitor == nil else { return }

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                Self.handle(event, actions: actions) ? nil : event
            }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: -

    /// Раскладка по руководству оригинала (раздел «Стих»):
    ///
    /// «Связать навигацию» выключено — ↑ ↓ листают только предпросмотр,
    /// ← → листают и предпросмотр, и слайд в зале. Включено — наоборот.
    /// Удержание Ctrl временно меняет их местами.
    ///
    /// Обе пары листают именно стихи: главой управляют другие кнопки.
    /// Не `private`: этим же разбором пользуется самопроверка — подделать
    /// событие клавиши можно, а нажать её на пульте в проверке нечем.
    static func handle(_ event: NSEvent, actions: Actions) -> Bool {
        // Стрелки на macOS всегда приходят с флагами «функциональная клавиша»
        // и «цифровой блок» — это часть их кода, а не нажатые модификаторы.
        // Пока они учитывались, условие «модификаторов нет» не выполнялось
        // никогда: событие уходило дальше, и SwiftUI листал им не стихи, а
        // фокус по кнопкам книг.
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])
        let control = modifiers == .control
        let shift = modifiers == .shift
        guard modifiers.isEmpty || control || shift else { return false }
        guard !isEditingText else { return false }

        // Ctrl+A — выбрать всю главу.
        if control, event.charactersIgnoringModifiers?.lowercased() == "a" {
            actions.selectAll()
            return true
        }

        // Ctrl равносилен временному переключению «Связать навигацию».
        let linked = actions.isLinked() != control

        // Enter выводит подготовленный стих на проектор — то же, что F5.
        if event.keyCode == 36 || event.keyCode == 76 {
            actions.show()
            return true
        }

        // Пульт докладчика. Все известные пульты — Logitech, Kensington,
        // Baseus и китайские без имени — притворяются клавиатурой и шлют
        // ровно это: PageDown «дальше», PageUp «назад», точку или «b»
        // на кнопку затемнения. Отдельного протокола у них нет, и ловить
        // их надо здесь же, вместе со стрелками.
        //
        // Листают они ВСЕГДА в зал: пульт держит тот, кто говорит, и
        // «показать потом» ему нажать нечем.
        switch event.keyCode {
        case 121, 119:                       // PageDown, End
            actions.stepVerse(1, true)
            return true
        case 116, 115:                       // PageUp, Home
            actions.stepVerse(-1, true)
            return true
        case 47, 11:                         // точка и «b» — «затемнить»
            guard modifiers.isEmpty else { return false }
            actions.blackout()
            return true
        default:
            break
        }

        let vertical: Bool
        switch event.keyCode {
        case 126: vertical = true            // ↑
        case 125: vertical = true            // ↓
        case 123: vertical = false           // ←
        case 124: vertical = false           // →
        default:  return false
        }
        let forward = event.keyCode == 125 || event.keyCode == 124
        // «Активна» знято — жодна пара стрілок у зал не виводить (власник:
        // «стрелками переключается позиция, на предпросмотре видно, но на
        // проектор не идет»). Пульт доповідача вище це не зачіпає: у того,
        // хто говорить, «Показати» під рукою немає.
        let live = actions.isActive() && (linked ? vertical : !vertical)

        if shift {
            actions.extendSelection(forward ? 1 : -1, live)
        } else {
            actions.stepVerse(forward ? 1 : -1, live)
        }
        return true
    }

    /// Пока курсор стоит в поле ввода, стрелки принадлежат ему: иначе
    /// невозможно будет исправить опечатку в строке поиска.
    ///
    /// Проверяем именно активный редактор текста, а не «любой текстовый вид».
    /// Прошлая проверка отдавала стрелки всему, что похоже на текст, — а в
    /// SwiftUI выделяемый текст стиха тоже сделан текстовым видом. Стоило
    /// щёлкнуть по стиху, и перелистывание переставало работать: событие
    /// уходило списку, и тот просто прокручивался.
    private static var isEditingText: Bool {
        guard let window = NSApp.keyWindow else { return false }
        let responder = window.firstResponder

        if let editor = window.fieldEditor(false, for: nil), responder === editor { return true }
        if let text = responder as? NSTextView { return text.isEditable }
        return false
    }
}
