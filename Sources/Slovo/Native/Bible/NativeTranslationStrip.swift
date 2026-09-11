import AppKit
import SlovoCore

/// Смуга вкладок перекладів (7).
///
/// Усі вкладки малює один вид, а не півсотні кнопок: підписи короткі,
/// розкладка рахується арифметикою один раз на зміну складу, а натискання
/// перефарбовує дві вкладки з п'ятдесяти.
@MainActor
final class NativeTabStrip: NSView, NSViewToolTipOwner {

    /// Що намалювати у вкладці. Значення `TextModule` сюди не потрапляють.
    private struct Tab {
        var title: String
        var identifier: String
        var box: NSRect = .zero
        var isPrimary = false
        var isSecondary = false
    }

    private var tabs: [Tab] = []
    private weak var state: AppState?
    /// Ctrl+клацання призначає другий переклад — так в оригіналі вмикають показ
    /// двох перекладів одразу.
    var onPick: ((String, Bool) -> Void)?
    var onMenu: ((String) -> NSMenu?)?

    private static let font = NSFont.systemFont(ofSize: 11)
    private static let boldFont = NSFont.systemFont(ofSize: 11, weight: .bold)

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Ширина, яку просить уся смуга.
    private(set) var fittingWidth: CGFloat = 0

    /// Скільки вкладок намальовано — самоперевірці.
    var tabCount: Int { tabs.count }

    func reload() {
        guard let state else { return }
        let primary = state.primaryModuleID
        let secondary = Set(state.secondaryModuleIDs)
        tabs = state.orderedModules.map { module in
            Tab(title: state.tabTitle(for: module),
                identifier: module.identifier,
                isPrimary: module.identifier == primary,
                isSecondary: secondary.contains(module.identifier))
        }
        relayout()
        needsDisplay = true
        removeAllToolTips()
        for tab in tabs { _ = addToolTip(tab.box, owner: self, userData: nil) }
    }

    private func relayout() {
        var x: CGFloat = 6
        for position in tabs.indices {
            let font = tabs[position].isPrimary ? Self.boldFont : Self.font
            let width = ceil((tabs[position].title as NSString)
                .size(withAttributes: [.font: font]).width) + 14
            tabs[position].box = NSRect(x: x, y: 3, width: width, height: 20)
            x += width + 3
        }
        fittingWidth = x
        frame.size.width = max(fittingWidth, superview?.bounds.width ?? fittingWidth)
    }

    override func draw(_ dirtyRect: NSRect) {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        for tab in tabs where tab.box.intersects(dirtyRect) {
            let font = tab.isPrimary ? Self.boldFont : Self.font
            if tab.isPrimary {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: tab.box, xRadius: 4, yRadius: 4).fill()
            } else if tab.isSecondary {
                NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
                NSBezierPath(roundedRect: tab.box, xRadius: 4, yRadius: 4).fill()
            }
            let color: NSColor = tab.isPrimary ? .white : .labelColor
            let height = ceil(font.ascender - font.descender + font.leading)
            let box = NSRect(x: tab.box.minX, y: tab.box.minY + (tab.box.height - height) / 2,
                             width: tab.box.width, height: height)
            (tab.title as NSString).draw(with: box, options: [.usesLineFragmentOrigin],
                                         attributes: [.font: font, .foregroundColor: color,
                                                      .paragraphStyle: style])
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tab = tabs.first(where: { $0.box.contains(point) }) else { return }
        onPick?(tab.identifier, event.modifierFlags.contains(.control))
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let tab = tabs.first(where: { $0.box.contains(point) }),
              let menu = onMenu?(tab.identifier) else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
              point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let state, let tab = tabs.first(where: { $0.box.contains(point) }),
              let module = state.module(tab.identifier) else { return "" }
        return "\(module.displayName) — \(module.format.title)"
    }
}

// MARK: - Смуга цілком: вкладки, Пошук (8) і Швидкий вибір (9)

@MainActor
final class NativeTranslationStripView: NSView {

    private let scroll = NSScrollView()
    private let tabs: NativeTabStrip
    private let searchCaption = NativeCaption()
    let searchField = NativeQuickField()
    private let searchToggle: NativeIconButton
    private let addressCaption = NativeCaption()
    let addressField = NativeQuickField()
    private let errorCaption = NativeCaption()
    /// «Один переклад» / «Два переклади» — список усіх перекладів із галочками.
    /// У колишньому вікні він був на правому кінці смуги; без нього другий переклад
    /// вмикався лише правою кнопкою по вкладці, і знайти це було ніде.
    private let pairButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []
    private var rejectionTimer: Timer?

    init(state: AppState) {
        self.state = state
        tabs = NativeTabStrip(state: state)
        searchToggle = NativeIconButton(symbol: "list.bullet.rectangle",
                                        hint: state.hint("SBSearchToggle",
                                                         default: "Показать/скрыть результаты поиска")) {
            DeskModel.shared.toggleSearchResults()
            NativeBibleBridge.shared.sync()
        }
        super.init(frame: .zero)

        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = tabs
        addSubview(scroll)

        addSubview(searchCaption)
        addSubview(searchField)
        addSubview(searchToggle)
        addSubview(addressCaption)
        addSubview(addressField)
        addSubview(errorCaption)
        errorCaption.color = .systemRed

        pairButton.isBordered = false
        pairButton.font = .systemFont(ofSize: 11)
        pairButton.toolTip = OurWords.t("Второй перевод на слайде: он же выбирается правой кнопкой по вкладке")
        pairButton.target = self
        pairButton.action = #selector(pairPicked(_:))
        addSubview(pairButton)
        rebuildPairMenu()

        tabs.onPick = { [weak self] identifier, secondary in
            guard let state = self?.state else { return }
            if secondary {
                state.toggleSecondary(identifier)
            } else {
                state.primaryModuleID = identifier
            }
            NativeBibleBridge.shared.sync()
        }
        tabs.onMenu = { [weak self] identifier in self?.tabMenu(identifier) }

        searchField.onChange = { [weak self] text in
            guard let state = self?.state else { return }
            state.searchQuery = text
            DeskModel.shared.searchQueryChanged(text, state: state)
            NativeBibleBridge.shared.sync()
        }
        searchField.onSubmit = { [weak self] text in
            guard let state = self?.state else { return }
            DeskModel.shared.runSearch(text, state: state)
            NativeBibleBridge.shared.sync()
        }
        // Курсор став у поле — саме час будувати пошуковий хід, не
        // чекаючи першої літери: інакше вона одна коштувала б секунд очікування.
        searchField.onFocus = { [weak self] focused in
            guard focused, let state = self?.state else { return }
            DeskModel.shared.prepareSearch(state: state)
        }
        searchField.toolTip = state.hint("ESearch", default: "Поиск")

        addressField.onChange = { [weak self] text in self?.addressTyped(text) }
        addressField.onSubmit = { [weak self] text in self?.addressSubmitted(text) }
        addressField.toolTip = state.hint("EFastInput",
                                          default: "Быстрый выбор вводом в формате:\n[номер Книги] Книга Глава Стих [Стих_по] (имя книги можно сокращать)")
            .replacingOccurrences(of: "\\n", with: "\n")

        applyCaptions()
        applyColors()
        tabs.reload()
        applyToggle()

        tokens.append(Signals.shared.subscribe(.translations) { [weak self] in
            self?.tabs.reload()
            self?.rebuildPairMenu()
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            self?.applyCaptions()
            self?.tabs.reload()
            self?.rebuildPairMenu()
            self?.needsLayout = true
        })
        tokens.append(Signals.shared.subscribe(.layout) { [weak self] in
            self?.applyToggle()
        })
        NativeBibleBridge.shared.watchDesk { [weak self] in self?.syncFields() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Розкладка

    override func layout() {
        super.layout()
        let height = NativeQuickField.height
        let y = (bounds.height - height) / 2
        var right = bounds.width

        if !errorCaption.text.isEmpty {
            let width = errorCaption.fittingWidth
            errorCaption.frame = NSRect(x: right - width, y: 0, width: width, height: bounds.height)
            right -= width + 6
        } else {
            errorCaption.frame = .zero
        }

        addressField.frame = NSRect(x: right - 104, y: y, width: 104, height: height)
        right -= 104 + 4
        let addressWidth = addressCaption.fittingWidth
        addressCaption.frame = NSRect(x: right - addressWidth, y: 0,
                                      width: addressWidth, height: bounds.height)
        right -= addressWidth + 6

        searchToggle.frame = NSRect(x: right - 20, y: (bounds.height - 16) / 2, width: 20, height: 16)
        right -= 20 + 4
        searchField.frame = NSRect(x: right - 140, y: y, width: 140, height: height)
        right -= 140 + 4
        let searchWidth = searchCaption.fittingWidth
        searchCaption.frame = NSRect(x: right - searchWidth, y: 0,
                                     width: searchWidth, height: bounds.height)
        right -= searchWidth + 6

        if guest == nil {
            let pairWidth = pairButton.intrinsicContentSize.width + 6
            pairButton.frame = NSRect(x: right - pairWidth, y: y, width: pairWidth, height: height)
            right -= pairWidth + 8
        } else {
            pairButton.frame = .zero
        }

        let box = NSRect(x: 0, y: 0, width: max(0, right), height: bounds.height)
        if let guest {
            guest.frame = NSRect(x: 4, y: (bounds.height - NativeSongBookTabs.height) / 2,
                                 width: max(40, box.width - 8),
                                 height: NativeSongBookTabs.height)
        } else {
            scroll.frame = box
            tabs.frame.size.height = bounds.height
        }
    }

    // MARK: - Гість на місці перекладів

    /// Хто зайняв місце списку перекладів. У режимі пісень це закладки
    /// Пісенників (33): переклади Біблії на сторінці пісень ні до чого, а
    /// Пісенники потрібні рівно там, де Біблія тримає переклади.
    private weak var guest: NSView?

    /// Скільки вкладок перекладів стоїть на смузі — самоперевірці.
    var translationTabCount: Int { tabs.tabCount }

    /// Поставити чужі закладки замість перекладів — або прибрати їх.
    ///
    /// Вид приходить живий, той самий, що був у сторінки пісень: у нього вже
    /// налаштовано натискання і праву кнопку, і заводити другий такий самий означало б
    /// тримати два списки Пісенників із різними думками про те, що відкрито.
    func showGuestTabs(_ view: NSView?) {
        guard guest !== view else { return }
        guest?.removeFromSuperview()
        guest = view
        let ours = (view == nil)
        scroll.isHidden = !ours
        pairButton.isHidden = !ours
        if let view { addSubview(view) }
        needsLayout = true
        needsDisplay = true
    }

    // MARK: - Один або два переклади

    /// Список перекладів із галочками. Перший рядок — заголовок випадного
    /// списку, він же показує нинішній стан справ.
    private func rebuildPairMenu() {
        guard let state else { return }
        let menu = NSMenu()
        let title = state.secondaryModuleIDs.isEmpty ? OurWords.t("Один перевод") : OurWords.t("Два перевода")
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        for module in state.orderedModules {
            let item = NSMenuItem(title: module.displayName,
                                  action: #selector(pairPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = module.identifier
            item.state = state.secondaryModuleIDs.contains(module.identifier) ? .on : .off
            menu.addItem(item)
        }
        pairButton.menu = menu
        needsLayout = true
    }

    @objc private func pairPicked(_ sender: Any?) {
        guard let state,
              let item = (sender as? NSMenuItem) ?? pairButton.selectedItem,
              let identifier = item.representedObject as? String else { return }
        state.toggleSecondary(identifier)
        NativeBibleBridge.shared.sync()
        rebuildPairMenu()
    }

    private func applyCaptions() {
        guard let state else { return }
        searchCaption.text = state.text("Label3D11", default: "Поиск:")
        addressCaption.text = state.text("Label3D14", default: "Быстр. выбор:")
        // Підказки ставилися при побудові й після зміни мови лишалися старою
        // мовою — перекладаємо їх тут же, разом із підписами.
        pairButton.toolTip = OurWords.t("Второй перевод на слайде: он же выбирается правой кнопкой по вкладке")
        searchToggle.toolTip = state.hint("SBSearchToggle", default: "Показать/скрыть результаты поиска")
        searchField.toolTip = state.hint("ESearch", default: "Поиск")
        addressField.toolTip = state.hint("EFastInput",
                                          default: "Быстрый выбор вводом в формате:\n[номер Книги] Книга Глава Стих [Стих_по] (имя книги можно сокращать)")
            .replacingOccurrences(of: "\\n", with: "\n")
    }

    /// Колір активного поля, яким він був минулого разу. Звірка йде на кожну
    /// зміну стану — тобто на кожне натискання, — а налаштування міняється
    /// раз на рік; складати два кольори марно нема чого.
    private var appliedInputColor: SlideStyle.RGBA?

    private func applyColors() {
        guard let state else { return }
        let options = state.programOptions.activeInputFieldColor
        guard options != appliedInputColor else { return }
        appliedInputColor = options
        let fill = NSColor(rgba: options)
        // Колір тексту добираємо за яскравістю заливки: в автора підфарбування завжди
        // світле, а в нас тема буває темною, і системний білий на світло-
        // рожевому не прочитати.
        let luminance = 0.299 * options.red + 0.587 * options.green + 0.114 * options.blue
        let ink: NSColor = luminance > 0.55 ? .black : .white
        for field in [searchField, addressField] {
            field.activeFill = fill
            field.activeText = ink
        }
    }

    /// Поля і кнопка доганяють стан: клавіша, пункт меню або план могли
    /// поміняти і текст, і фокус, оминаючи вікно.
    private func syncFields() {
        guard let state else { return }
        applyColors()
        searchField.text = state.searchQuery
        addressField.text = state.quickInput
        applyToggle()
        if DeskModel.shared.addressFocusRequest != lastAddressFocus {
            lastAddressFocus = DeskModel.shared.addressFocusRequest
            addressField.focus()
        }
        if DeskModel.shared.searchFocusRequest != lastSearchFocus {
            lastSearchFocus = DeskModel.shared.searchFocusRequest
            searchField.focus()
        }
    }

    private var lastAddressFocus = 0
    private var lastSearchFocus = 0

    private func applyToggle() {
        searchToggle.isOn = DeskModel.shared.isSearchResultsShown
    }

    // MARK: - Швидкий вибір місця Писання (9)

    private var previousAddress = ""

    /// Набір по знаку. Промовчати тут важливіше, ніж відповісти: адреса, яку
    /// ще дописують, не знаходиться за визначенням.
    private func addressTyped(_ value: String) {
        guard let state else { return }
        let isDeletion = value.count < previousAddress.count
        previousAddress = value
        addressField.isRejected = false
        errorCaption.text = ""
        state.quickInput = value
        guard !value.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        // «Шукати по BackSpace у швидкому наборі» (6.1.2, елемент 14).
        if isDeletion, !state.programOptions.fastInputUseBackSpace { return }
        DeskModel.shared.applyAddress(value, state: state)
        NativeBibleBridge.shared.sync()
    }

    private func addressSubmitted(_ value: String) {
        guard let state else { return }
        state.quickInput = value
        if DeskModel.shared.applyAddress(value, state: state) {
            addressField.isRejected = false
            errorCaption.text = ""
            NativeBibleBridge.shared.sync()
            return
        }
        // Книгу не впізнали: ErrorMessages11 і червона рамка на пару секунд.
        addressField.isRejected = true
        errorCaption.text = state.text("ErrorMessages11", default: "Адрес не найден.")
            .replacingOccurrences(of: "\\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        needsLayout = true
        rejectionTimer?.invalidate()
        rejectionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { _ in
            MainActor.assumeIsolated {
                self.addressField.isRejected = false
                self.errorCaption.text = ""
                self.needsLayout = true
            }
        }
    }

    // MARK: - Меню правої кнопки по вкладці перекладу (5.1.7)

    /// Шість пунктів автора: `N_LongName`, `N_ShortName`, `NReloadModule`,
    /// `NOpenModuleFolder`, `NSelAsFirstTranslate` і `TextMessages62/63`.
    private func tabMenu(_ identifier: String) -> NSMenu? {
        guard let state, let module = state.module(identifier) else { return nil }
        let isSecond = state.secondaryModuleIDs.contains(identifier)
        let isPrimary = state.primaryModuleID == identifier
        func mark(_ on: Bool) -> String { on ? "✓ " : "" }

        let menu = NSMenu()
        add(menu, mark(state.tabNamesLong) + state.text("N_LongName", default: "Длинное название")) {
            state.setTabNames(long: true)
        }
        add(menu, mark(!state.tabNamesLong) + state.text("N_ShortName", default: "Короткое название")) {
            state.setTabNames(long: false)
        }
        menu.addItem(.separator())
        add(menu, state.text("NReloadModule", default: "Перезагрузить модуль")) {
            // Знятого кешу мало: список віршів тримає знімок тексту і
            // перечитує його лише за зміною складу. Перечитуємо книгу
            // тією самою дорогою, якою її читають завжди, і повертаємо вибір.
            let chapter = state.selectedChapterNumber
            let verses = state.selectedVerseNumbers
            module.releaseCache()
            state.selectedBookIndex = state.selectedBookIndex
            if state.chapters.contains(where: { $0.number == chapter }) {
                state.selectedChapterNumber = chapter
                state.selectedVerseNumbers = verses
            }
            state.refreshSlide()
            NativeBibleBridge.shared.sync()
            Signals.shared.send(.verses)
        }
        add(menu, state.text("NOpenModuleFolder", default: "Открыть папку с модулем")) {
            state.revealModule(identifier)
        }
        menu.addItem(.separator())
        add(menu, mark(isPrimary)
            + state.text("NSelAsFirstTranslate", default: "Выбрать основным переводом")) {
            state.primaryModuleID = identifier
        }
        add(menu, mark(isSecond)
            + state.text(isSecond ? "TextMessages63" : "TextMessages62",
                         default: isSecond ? "Отменить второй перевод" : "Выбрать вторым переводом")) {
            state.toggleSecondary(identifier)
        }
        if !state.secondaryModuleIDs.isEmpty {
            menu.addItem(.separator())
            add(menu, OurWords.t("Показывать один перевод")) { state.showSingleTranslation() }
        }
        return menu
    }

    private func add(_ menu: NSMenu, _ title: String, _ body: @escaping () -> Void) {
        let item = NSMenuItem(title: title, action: #selector(NativeMenuAction.fire(_:)),
                              keyEquivalent: "")
        let target = NativeMenuAction(body)
        item.target = target
        item.representedObject = target
        menu.addItem(item)
    }
}

/// Приймач пункту меню: меню живе від клацання до закриття, і ціль пункту
/// тримається самим пунктом.
@MainActor
final class NativeMenuAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }

    @objc func fire(_ sender: Any?) {
        body()
        NativeBibleBridge.shared.sync()
    }
}
