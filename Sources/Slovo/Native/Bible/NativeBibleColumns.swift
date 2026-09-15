import AppKit
import SlovoCore

// MARK: - Клас (1)

/// Колонка «Клас:» — Уся Біблія, Стар.Заповіт, Нов.Заповіт, Неканон.
///
/// Фон панелі `textBackgroundColor`, відступ 4 з усіх боків, шрифт 12 —
/// він тут свій і від повзунка списків не залежить, як і в оригіналі.
@MainActor
final class NativeBookClassColumn: NSView {

    private let rows = NativeBookClassRows()
    private(set) var list = NativeList(mode: .list, metrics: NativeBookClassColumn.metrics,
                                  heights: .uniform(20), fontSize: 12)
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []

    private static let metrics: NativeListMetrics = {
        var m = NativeListMetrics()
        m.padding = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        m.textFontDelta = 0
        m.background = .textBackgroundColor
        return m
    }()

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        addSubview(list)

        rows.reload(state: state)
        list.source = rows
        list.onSelect = { [weak self] _, index, cause in
            guard cause != .code, let self, let state = self.state else { return }
            let picked = self.rows.classes[index]
            guard state.bookClass != picked else { return }
            state.bookClass = picked
            NativeBibleBridge.shared.sync()
        }
        applySelection()

        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self, let state = self.state else { return }
            self.rows.reload(state: state)
            self.list.reload()
            self.applySelection()
        })
        tokens.append(Signals.shared.subscribe(.bookClass) { [weak self] in
            self?.applySelection()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        list.frame = bounds.insetBy(dx: 4, dy: 4)
    }

    private func applySelection() {
        guard let state, let position = rows.classes.firstIndex(of: state.bookClass) else { return }
        list.setSelection(IndexSet(integer: position), active: position)
    }
}

// MARK: - Книга (2)

/// Колонка «Книга:» — кнопки вигляду (22), список книг у чотирьох виглядах і поле
/// швидкого вибору (6) під ним.
@MainActor
final class NativeBookColumn: NSView {

    private let buttons = NativeIconButtonRow()
    /// Кнопки вигляду книг — у порядку `ListStyleButtons.bookButtons`.
    private var bookButtons: [NativeIconButton] = []
    private let separator = NativeHairline()
    private let rows = NativeBookRows()
    private let list: NativeList

    /// Список — самоперевірці: вона міряє, чи вміщається рядок у свою висоту.
    var bookList: NativeList { list }
    let quick = NativeQuickField()
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []
    /// Вигляд, під який список налаштовано зараз. Міняється рідко, а перебудова
    /// метрик і висот коштує цілого перечитування — звіряємо, щоб не робити її даремно.
    private var appliedMode: InterfaceSettings.BookViewMode?

    init(state: AppState) {
        self.state = state
        list = NativeList(mode: .list, metrics: .books, heights: .uniform(22),
                          fontSize: CGFloat(state.listFontSize))
        super.init(frame: .zero)
        addSubview(buttons)
        addSubview(separator)
        addSubview(list)
        addSubview(quick)

        bookButtons = ListStyleButtons.bookButtons.map { item in
            NativeIconButton(symbol: item.symbol,
                             hint: state.hint(item.key, default: item.fallback)) { [weak self] in
                InterfaceSettings.shared.setBooksFlow(item.flow, in: state.listScope)
                self?.applyButtons()
                NativeBibleBridge.shared.sync()
            }
        }
        buttons.install(bookButtons)

        rows.reload(state: state)
        list.source = rows
        list.onSelect = { [weak self] _, index, cause in
            guard cause != .code, let self, let state = self.state else { return }
            guard self.rows.bookIndexes.indices.contains(index) else { return }
            let book = self.rows.bookIndexes[index]
            guard state.selectedBookIndex != book else { return }
            state.selectedBookIndex = book
            NativeBibleBridge.shared.sync()
        }

        quick.placeholder = OurWords.t("Название книги…")
        quick.toolTip = state.hint("EBookFastInput",
                                   default: "Быстрый выбор Книги вводом её названия (можно сокращать)")
        quick.onChange = { [weak self] text in
            guard let state = self?.state else { return }
            DeskModel.shared.bookQuery = text
            DeskModel.shared.applyBookQuery(text, state: state)
            NativeBibleBridge.shared.sync()
        }
        quick.onSubmit = quick.onChange
        quick.onFocus = { focused in
            if focused {
                DeskModel.shared.quickFocus = .book
            } else if DeskModel.shared.quickFocus == .book {
                DeskModel.shared.quickFocus = nil
            }
        }

        applyMode()
        applyButtons()
        applySelection()

        tokens.append(Signals.shared.subscribe([.books, .bookClass]) { [weak self] _ in
            guard let self, let state = self.state else { return }
            self.rows.reload(state: state)
            self.list.reload()
            self.scrolledTo = nil
            self.applySelection()
        })
        tokens.append(Signals.shared.subscribe(.bookSelection) { [weak self] in
            self?.applySelection()
        })
        tokens.append(Signals.shared.subscribe(.listKind) { [weak self] in
            self?.applyMode()
            self?.applyButtons()
        })
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self, let state = self.state else { return }
            self.list.fontSize = CGFloat(state.listFontSize)
            self.applyMode(force: true)
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self, let state = self.state else { return }
            self.rows.reload(state: state)
            self.applyMode(force: true)
            // Підказки ставилися при побудові — перекладаємо їх заново.
            for (button, item) in zip(self.bookButtons, ListStyleButtons.bookButtons) {
                button.toolTip = state.hint(item.key, default: item.fallback)
            }
            self.quick.toolTip = state.hint("EBookFastInput",
                                            default: "Быстрый выбор Книги вводом её названия (можно сокращать)")
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

    // MARK: - Вигляд списку (22)

    private func applyMode(force: Bool = false) {
        guard let state else { return }
        let mode = InterfaceSettings.shared.bookView(state.listScope)
        guard force || mode != appliedMode else { return }
        appliedMode = mode
        rows.mode = mode
        let font = CGFloat(state.listFontSize)

        switch mode {
        case .icons:
            var metrics = NativeListMetrics()
            metrics.leadFontDelta = -1
            metrics.detailFontDelta = max(8 - font, -4)
            metrics.background = .textBackgroundColor
            list.metrics = metrics
            list.mode = .tiles(minItemWidth: 74, itemHeight: tileHeight(tall: true), gap: 3)
            list.heights = .uniform(tileHeight(tall: true))
            list.headerTitles = nil
        case .smallIcons:
            var metrics = NativeListMetrics()
            metrics.leadFontDelta = -1
            metrics.background = .textBackgroundColor
            list.metrics = metrics
            list.mode = .tiles(minItemWidth: 52, itemHeight: tileHeight(tall: false), gap: 3)
            list.heights = .uniform(tileHeight(tall: false))
            list.headerTitles = nil
        case .list:
            var metrics = NativeListMetrics.books
            metrics.leadFontDelta = -1
            list.metrics = metrics
            list.mode = .list
            list.heights = .uniform(rowHeight())
            list.headerTitles = nil
        case .table:
            var metrics = NativeListMetrics.books
            metrics.leadWidth = 58
            metrics.leadFontDelta = -1
            metrics.detailWidth = 44
            list.metrics = metrics
            list.mode = .list
            list.heights = .uniform(rowHeight())
            // Заголовки колонок — з файла перекладу автора, ті самі слова, що
            // й у таблиці модулів вікна параметрів.
            list.headerTitles = [
                state.text("LVBiblesPath->Column1", form: "SettingsForm", default: "Сокращ."),
                state.text("LVBiblesPath->Column0", form: "SettingsForm", default: "Название"),
                OurWords.t("Глав"),
            ]
        }
        list.reload()
        applySelection()
    }

    /// Висота клітинки: скорочення, під ним повна назва, поля по 7 (або 6).
    private func tileHeight(tall: Bool) -> CGFloat {
        let font = CGFloat(state?.listFontSize ?? 13)
        let title = ceil(NSFont.systemFont(ofSize: max(7, font - 1), weight: .semibold).pointSize) + 4
        guard tall else { return title + 12 }
        let caption = ceil(max(8, font - 4)) + 4
        return title + caption + 1 + 14
    }

    private func rowHeight() -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(7, CGFloat(state?.listFontSize ?? 13)))
        return ceil(font.ascender - font.descender + font.leading) + 6
    }

    private func applyButtons() {
        guard let state else { return }
        let flowing = InterfaceSettings.shared.booksAreFlowing(in: state.listScope)
        for (position, item) in ListStyleButtons.bookButtons.enumerated()
        where buttons.buttons.indices.contains(position) {
            buttons.buttons[position].isOn = (item.flow == flowing)
        }
    }

    /// Рядок, до якого список уже підведено: зміна перекладу шле і «склад»,
    /// і «вибір», і прокручувати двічі до одного місця нема чого.
    private var scrolledTo: Int?

    private func applySelection() {
        guard let state, let position = rows.position(ofBook: state.selectedBookIndex) else {
            list.setSelection(IndexSet())
            scrolledTo = nil
            return
        }
        list.setSelection(IndexSet(integer: position), active: position)
        guard position != scrolledTo else { return }
        scrolledTo = position
        list.scrollTo(position, place: .center)
    }
}

// MARK: - Розділ (3)

/// Колонка «Розділ:» — номери по центру і поле швидкого вибору під ними.
@MainActor
final class NativeChapterColumn: NSView {

    private let rows = NativeChapterRows()
    private let list: NativeList

    /// Список — самоперевірці: вона міряє, чи вміщається рядок у свою висоту.
    var chapterList: NativeList { list }
    let quick = NativeQuickField()
    private let spinner = NSProgressIndicator()
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []

    init(state: AppState) {
        self.state = state
        list = NativeList(mode: .list, metrics: .chapters, heights: .uniform(20),
                          fontSize: CGFloat(state.listFontSize))
        super.init(frame: .zero)
        addSubview(list)
        addSubview(quick)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        addSubview(spinner)

        rows.reload(state: state)
        list.source = rows
        list.onSelect = { [weak self] _, index, cause in
            guard cause != .code, let self, let state = self.state else { return }
            guard self.rows.numbers.indices.contains(index) else { return }
            let number = self.rows.numbers[index]
            guard state.selectedChapterNumber != number else { return }
            state.selectedChapterNumber = number
            NativeBibleBridge.shared.sync()
        }

        quick.placeholder = OurWords.t("№ главы")
        quick.toolTip = state.hint("EChaptFastInput", default: "Быстрый выбор Главы вводом её номера")
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self, let state = self.state else { return }
            self.quick.toolTip = state.hint("EChaptFastInput", default: "Быстрый выбор Главы вводом её номера")
        })
        quick.onChange = { [weak self] text in
            guard let state = self?.state else { return }
            DeskModel.shared.chapterQuery = text
            DeskModel.shared.applyChapterQuery(text, state: state)
            NativeBibleBridge.shared.sync()
        }
        quick.onSubmit = quick.onChange
        quick.onFocus = { focused in
            if focused {
                DeskModel.shared.quickFocus = .chapter
            } else if DeskModel.shared.quickFocus == .chapter {
                DeskModel.shared.quickFocus = nil
            }
        }

        applyHeights()
        applySelection()
        applySpinner()

        tokens.append(Signals.shared.subscribe(.chapters) { [weak self] in
            guard let self, let state = self.state else { return }
            self.rows.reload(state: state)
            self.list.reload()
            self.scrolledTo = nil
            self.applySelection()
            self.applySpinner()
        })
        tokens.append(Signals.shared.subscribe(.chapterSelection) { [weak self] in
            self?.applySelection()
        })
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self, let state = self.state else { return }
            self.list.fontSize = CGFloat(state.listFontSize)
            self.applyHeights()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let quickHeight = NativeQuickField.height
        let listHeight = max(0, bounds.height - quickHeight - 2)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: listHeight)
        quick.frame = NSRect(x: 0, y: listHeight + 2, width: bounds.width, height: quickHeight)
        spinner.frame = NSRect(x: (bounds.width - 16) / 2, y: 8, width: 16, height: 16)
    }

    private func applyHeights() {
        let font = NSFont.systemFont(ofSize: max(7, CGFloat(state?.listFontSize ?? 13)))
        list.heights = .uniform(ceil(font.ascender - font.descender + font.leading) + 6)
    }

    private func applySpinner() {
        guard let state else { return }
        if state.isLoadingChapters {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    /// Рядок, до якого список уже підведено.
    private var scrolledTo: Int?

    private func applySelection() {
        guard let state, let position = rows.position(ofChapter: state.selectedChapterNumber) else {
            list.setSelection(IndexSet())
            scrolledTo = nil
            return
        }
        list.setSelection(IndexSet(integer: position), active: position)
        guard position != scrolledTo else { return }
        scrolledTo = position
        list.scrollTo(position, place: .center)
    }
}

/// Волосяна риска між панеллю кнопок і списком.
@MainActor
final class NativeHairline: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.separatorColor.setFill()
        bounds.fill()
    }
}
