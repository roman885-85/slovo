import AppKit
import SlovoCore

/// Колонка «Вірш:» — кнопки вигляду (21), список віршів і поле швидкого вибору.
///
/// Виділення тут веде `AppState`, а не список: відрізок із Shift і додавання
/// врозбивку з Ctrl рахуються в `selectVerse(_:mode:)`, там же живе опорний
/// вірш, і звідти ж виділення потрапляє на слайд. Список після кожного клацання
/// перечитує готову відповідь стану — двох правд про виділення у вікні немає.
@MainActor
final class NativeVerseColumn: NSView {

    private let buttons = NativeIconButtonRow()
    /// Кнопки вигляду — у тому ж порядку, що `VerseViewMode.allCases`: при
    /// зміні мови їхні підказки перекладаються заново.
    private var viewButtons: [NativeIconButton] = []
    private let separator = NativeHairline()
    private let rows = NativeVerseRows()
    private let list: NativeList
    let quick = NativeQuickField()
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []
    private var appliedSingleLine: Bool?

    /// Сам список — його читає замір, щоб відділити роботу списку від роботи
    /// стану.
    var verseList: NativeList { list }

    init(state: AppState) {
        self.state = state
        list = NativeList(mode: .list, metrics: .verses, heights: .measured(estimate: 30),
                          fontSize: CGFloat(state.listFontSize))
        super.init(frame: .zero)
        addSubview(buttons)
        addSubview(separator)
        addSubview(list)
        addSubview(quick)

        viewButtons = InterfaceSettings.VerseViewMode.allCases.map { mode in
            NativeIconButton(symbol: mode.symbol,
                             hint: state.hint(state.listScope.hintKeyPrefix + mode.hintKey,
                                              default: mode.hintFallback)) { [weak self] in
                InterfaceSettings.shared.setVerseView(mode, in: state.listScope)
                self?.applyButtons()
                NativeBibleBridge.shared.sync()
            }
        }
        buttons.install(viewButtons)

        rows.reload(state: state)
        list.allowsMultipleSelection = true
        list.source = rows

        // Одиночне клацання готує вірш у передпоказі, подвійне виводить його
        // в зал — так працює оригінал.
        list.onSelect = { [weak self] selection, index, cause in
            self?.chose(index, selection: selection, cause: cause, live: false)
        }
        list.onActivate = { [weak self] index in
            self?.chose(index, selection: IndexSet(integer: index), cause: .doubleClick, live: true)
        }

        quick.toolTip = state.hint("EVersFastInput",
                                   default: "Быстрый выбор Стиха вводом его номера или части текста")
        quick.onChange = { [weak self] text in
            guard let state = self?.state else { return }
            DeskModel.shared.verseQuery = text
            DeskModel.shared.applyVerseQuery(text, state: state)
            NativeBibleBridge.shared.sync()
        }
        quick.onSubmit = quick.onChange
        quick.onFocus = { focused in
            if focused {
                DeskModel.shared.quickFocus = .verse
            } else if DeskModel.shared.quickFocus == .verse {
                DeskModel.shared.quickFocus = nil
            }
        }

        applyKind(force: true)
        applySelection(scroll: true)

        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self, let state = self.state else { return }
            for (button, mode) in zip(self.viewButtons, InterfaceSettings.VerseViewMode.allCases) {
                button.toolTip = state.hint(state.listScope.hintKeyPrefix + mode.hintKey,
                                            default: mode.hintFallback)
            }
            self.quick.toolTip = state.hint("EVersFastInput", default: "Быстрый выбор Стиха вводом его номера или части текста")
        })
        tokens.append(Signals.shared.subscribe(.verses) { [weak self] in
            guard let self, let state = self.state else { return }
            self.rows.reload(state: state)
            self.list.reload()
            // Зміна розділу при тому самому номері вірша вибір не міняє, а список
            // лишається там, куди його відвели колесом. Прокручуємо примусово.
            self.scrolledTo = nil
            self.applySelection(scroll: true)
        })
        tokens.append(Signals.shared.subscribe(.verseSelection) { [weak self] in
            guard let self else { return }
            self.applySelection(scroll: !self.pickedHere)
        })
        tokens.append(Signals.shared.subscribe(.listKind) { [weak self] in
            self?.applyKind()
            self?.applyButtons()
        })
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self, let state = self.state else { return }
            self.list.fontSize = CGFloat(state.listFontSize)
            self.applyKind(force: true)
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let top = NativeIconButtonRow.height
        buttons.frame = NSRect(x: 0, y: 0, width: bounds.width, height: top)
        separator.frame = NSRect(x: 0, y: top, width: bounds.width, height: 1)
        let quickHeight = NativeQuickField.height
        let listTop = top + 1
        let listHeight = max(0, bounds.height - listTop - quickHeight - 2)
        list.frame = NSRect(x: 0, y: listTop, width: bounds.width, height: listHeight)
        quick.frame = NSRect(x: 0, y: listTop + listHeight + 2,
                             width: bounds.width, height: quickHeight)
    }

    // MARK: - Вибір вірша

    /// Поки йде розбір свого ж клацання — не прокручувати список.
    ///
    /// Вірш, по якому клацнули, і так на виду, а прокрутка «до вибраного»
    /// відвела б його на середину прямо під курсором: наступне клацання потрапило б
    /// уже в інший вірш. Усі інші шляхи — стрілки, F6, швидкий вибір, план,
    /// пошук — прокручують, як і було.
    private var pickedHere = false

    /// Shift — відрізок підряд, Ctrl (або ⌘) — окремий вірш. Модифікатори
    /// читаємо в події так само, як це робило вікно SwiftUI: список про них не
    /// повідомляє, а рішення приймає все одно `AppState`.
    private func chose(_ index: Int, selection: IndexSet, cause: NativeList.Cause, live: Bool) {
        guard let state, rows.numbers.indices.contains(index) else { return }
        pickedHere = true
        defer { pickedHere = false }

        // ⌘A: список віддав увесь розділ разом — стан уміє це саме.
        if cause == .keyboard, selection.count == rows.rowCount, rows.rowCount > 1 {
            state.selectAllVerses()
            NativeBibleBridge.shared.sync()
            applySelection(scroll: false)
            return
        }
        // Протяжка мишею: відрізок від рядка натискання до рядка під курсором.
        // Опорним віршем лишається рядок натискання — тоді Shift після
        // протяжки продовжить відрізок з того самого кінця.
        if cause == .drag {
            guard let first = selection.first, let last = selection.last,
                  rows.numbers.indices.contains(first), rows.numbers.indices.contains(last) else { return }
            let origin = index == last ? first : last
            state.selectVerse(rows.numbers[origin], mode: .replace)
            if origin != index { state.selectVerse(rows.numbers[index], mode: .extend) }
            NativeBibleBridge.shared.sync()
            applySelection(scroll: false)
            return
        }

        let flags = NSEvent.modifierFlags
        let mode: AppState.VerseSelection
        if flags.contains(.shift) {
            mode = .extend
        } else if flags.contains(.control) || flags.contains(.command) {
            mode = .toggle
        } else {
            mode = .replace
        }
        state.chooseVerse(rows.numbers[index], mode: mode, live: live)
        NativeBibleBridge.shared.sync()
        // Стан — єдина правда про виділення: те, що список устиг
        // нарахувати сам, тут і перекривається.
        applySelection(scroll: false)
    }

    /// Рядок, до якого список уже підведено. Зміна розділу шле і «склад»,
    /// і «виділення» — без цієї пам'яті список прокручувався б до одного й
    /// того самого місця двічі, а прокрутка при висотах за текстом не безкоштовна.
    private var scrolledTo: Int?

    private func applySelection(scroll: Bool) {
        guard let state else { return }
        var indexes = IndexSet()
        for number in state.selectedVerseNumbers {
            if let position = rows.position(ofVerse: number) { indexes.insert(position) }
        }
        let first = indexes.first
        list.setSelection(indexes, active: first)
        guard scroll, let first, first != scrolledTo else { return }
        scrolledTo = first
        list.scrollTo(first, place: .center)
    }

    // MARK: - Вигляд списку (21) і риска кожні десять віршів

    private func applyKind(force: Bool = false) {
        guard let state else { return }
        let singleLine = InterfaceSettings.shared.verseView(state.listScope) == .singleLine
        let separatorOn = state.programOptions.separatorTenVerses
        let changed = force || singleLine != appliedSingleLine || separatorOn != rows.separator
        guard changed else { return }
        appliedSingleLine = singleLine
        rows.singleLine = singleLine
        rows.separator = separatorOn

        let font = NSFont.systemFont(ofSize: max(7, CGFloat(state.listFontSize) + 1))
        let line = ceil(font.ascender - font.descender + font.leading)
        // «Одна лінія» — усі рядки однієї висоти, і це найшвидший шлях:
        // таблиця про висоти не питає зовсім. Багаторядкові рахуються за
        // текстом, але лише ті, що показалися.
        list.heights = singleLine ? .uniform(line + 10) : .measured(estimate: line + 10)
        list.reload()
        applySelection(scroll: false)
    }

    private func applyButtons() {
        guard let state else { return }
        let current = InterfaceSettings.shared.verseView(state.listScope)
        for (position, mode) in InterfaceSettings.VerseViewMode.allCases.enumerated()
        where buttons.buttons.indices.contains(position) {
            buttons.buttons[position].isOn = (mode == current)
        }
    }
}
