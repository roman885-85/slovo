import AppKit
import SlovoCore

/// Рабочая область показа: слева список, справа то, что уйдёт в зал.
///
/// Одна на два режима — «Зображення» и «Презентація»: у них общая работа
/// «открыть, выбрать, показать, листать», и разводить её в два кода значило
/// бы дважды чинить каждую ошибку.
///
/// Показ идёт теми же выводами, что и видео: окно слайда, предпросмотр и
/// трансляция. Ни своего окна, ни своей дороги в сеть здесь нет — они уже
/// написаны и уже проверены.
@MainActor
final class NativeShowWorkspace: NSView, NativeListSource {

    static let pictures = NativeShowWorkspace(kind: .pictures)
    static let presentation = NativeShowWorkspace(kind: .presentation)

    /// Не `private`: этой же машиной пользуется самопроверка — ей нужно
    /// открыть папку без окна выбора файлов.
    let model: ShowModel
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []

    /// Колонка файлов — только у презентаций: имя и число страниц.
    private let files = NativeList(mode: .list,
                                   metrics: NativeListMetrics(leadWidth: 0, detailWidth: 36),
                                   heights: .uniform(26))
    /// Колонка страниц: у презентаций — страницы выбранного файла, у
    /// картинок — все картинки.
    private let list = NativeList(mode: .list,
                                  metrics: NativeListMetrics(leadWidth: 34, detailWidth: 0),
                                  heights: .uniform(26))
    private let preview = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let toolbar = NSStackView()
    /// Роздільники: за файлами (презентації) чи списком (зображення) і за
    /// сторінками. Ширини тягнуться мишею й пам'ятаються; подвійне
    /// клацання повертає автоматичну.
    private let firstGrip = NativeWidthGrip()
    private let secondGrip = NativeWidthGrip()
    private var firstKey: String { model.kind == .presentation ? "presentationFilesWidth" : "picturesListWidth" }
    private let secondKey = "presentationPagesWidth"
    private var showButton: NSButton!
    private var hideButton: NSButton!

    private init(kind: ShowModel.Kind) {
        model = ShowModel(kind: kind)
        super.init(frame: .zero)
        // Список, зібраний до служіння, має пережити закриття програми.
        // Власник: «после закрытия программы все добавленные презентации,
        // минусовки, картинки и т.д. не сохраняются».
        model.remembers = true
        model.restore()
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Подключение

    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        list.source = self
        // Строка колонки страниц — это страница выбранной колоды, а не
        // сквозной номер: пересчёт в одном месте.
        list.onSelect = { [weak self] _, active, _ in
            guard let self else { return }
            self.model.select(self.model.currentRange.lowerBound + active)
            self.refresh()
        }
        // Двойной щелчок — в зал: так же, как двойной щелчок по стиху.
        list.onActivate = { [weak self] position in
            guard let self else { return }
            self.model.select(self.model.currentRange.lowerBound + position)
            self.show()
        }
        files.source = deckSource
        files.onSelect = { [weak self] _, active, _ in self?.chooseDeck(active) }
        files.onActivate = { [weak self] position in
            self?.chooseDeck(position)
            self?.show()
        }
        // Рядок стану («Зображення не вибрані», «3 з 12») збирає refresh —
        // після зміни мови його теж треба перекласти.
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            self?.applyCaptions()
            self?.refresh()
        })
        applyCaptions()
        refresh()
    }

    /// Открыть присланное со стороны — из перетаскивания в окно.
    func open(_ urls: [URL]) {
        model.open(urls)
        reloadLists()
        refresh()
    }

    /// Списки после смены состава: обе колонки заново и выделение по месту.
    ///
    /// Колонку страниц перечитываем здесь безусловно. Раньше её перечитывал
    /// только `syncLists` — и только при смене колоды; когда убирали
    /// последнюю презентацию, колода «не менялась» (не было и нет), и в
    /// списке страниц оставались строки удалённого файла.
    private func reloadLists() {
        files.reload()
        shownDeck = model.kind == .pictures ? 0 : (model.currentDeck ?? (model.decks.isEmpty ? nil : 0))
        list.reload()
        syncLists()
    }

    /// Выделение обеих колонок — по текущей странице модели. Колонка страниц
    /// перезагружается только когда сменилась колода: иначе каждое нажатие
    /// стрелки пересобирало бы список. У картинок колонка одна на весь
    /// список, и сменой колоды её не тревожим вовсе.
    private func syncLists() {
        let deck = model.currentDeck ?? (model.decks.isEmpty ? nil : 0)
        let shownKey = model.kind == .pictures ? 0 : deck
        if shownKey != shownDeck {
            shownDeck = shownKey
            list.reload()
        }
        files.setSelection(deck.map { IndexSet(integer: $0) } ?? IndexSet(), active: deck)
        let local = model.index.map { $0 - model.currentRange.lowerBound }
        let valid = local.flatMap { (0..<model.currentRange.count).contains($0) ? $0 : nil }
        list.setSelection(valid.map { IndexSet(integer: $0) } ?? IndexSet(), active: valid)
        if let valid { list.scrollTo(valid) }
    }

    /// Какая колода стоит во второй колонке сейчас.
    private var shownDeck: Int?

    /// Выбрать файл в первой колонке: вторая показывает его страницы.
    /// Не `private` — этим же путём идёт самопроверка.
    func chooseDeck(_ position: Int) {
        model.selectDeck(position)
        syncLists()
        refresh()
    }

    /// Выбрать страницу по сквозному номеру — то же, что щелчок по строке.
    /// Этим путём идут самопроверка и пульт: у них нет мыши.
    func selectPage(_ position: Int) {
        model.select(position)
        syncLists()
        refresh()
    }

    /// Показать выбранную страницу в зале — кнопка «Показать» без кнопки.
    func showCurrentPage() { show() }

    /// Выбрать файл показа со стороны — с телефона.
    func selectDeck(_ position: Int) {
        model.selectDeck(position)
        reloadLists()
        refresh()
    }

    /// Убрать показанное из зала — кнопка «Скрыть» без кнопки.
    func hideCurrentPage() { hide() }

    /// Самоперевірці: прибрати пробну сторінку так само, як це робить «−».
    /// Разом із нею пам'ять списку переписується без проби — список людини
    /// лишається таким, яким був.
    func removePageForCheck(at position: Int) {
        model.remove(at: position)
        reloadLists()
        refresh()
    }

    /// Убрать выбранное: у презентаций — файл целиком, у картинок — картинку.
    func removeCurrentEntry() {
        if let deck = files.isHidden ? nil : (model.currentDeck ?? (model.decks.isEmpty ? nil : 0)) {
            model.removeDeck(at: deck)
        } else if let position = model.index {
            model.remove(at: position)
        } else {
            return
        }
        if model.isEmpty { hide() }
        reloadLists()
        refresh()
        // Пока страница была в зале, снятие её из списка меняет и зал.
        if state?.media.still != nil, model.currentImage != nil { show() }
    }

    /// Строки колонок — для самопроверки.
    var fileRows: Int { files.itemCount }
    var pageRows: Int { list.itemCount }

    /// Встать в окно, когда выбрали этот режим.
    func install() {
        NativeMainWindowController.shared.install(self, in: .workspace)
        refresh()
    }

    /// Стрелки и Enter в режимах показа работают со страницами, а не со
    /// стихами. Разбор нажатия остаётся один на всю программу: две разные
    /// ловушки клавиш неминуемо разошлись бы в мелочах.
    static func handleStep(mode: AppState.WorkMode, delta: Int) -> Bool {
        guard let workspace = workspace(for: mode) else { return false }
        workspace.step(by: delta)
        return true
    }

    static func handleShow(mode: AppState.WorkMode) -> Bool {
        guard let workspace = workspace(for: mode), workspace.model.currentImage != nil else { return false }
        workspace.show()
        return true
    }

    /// Картинка, которую вкладка показа отдаст в зал, — для предпросмотра.
    static func currentImage(for mode: AppState.WorkMode) -> CGImage? {
        workspace(for: mode)?.model.currentImage
    }

    private static func workspace(for mode: AppState.WorkMode) -> NativeShowWorkspace? {
        switch mode {
        case .pictures: return pictures
        case .presentation: return presentation
        default: return nil
        }
    }

    /// Стрелки листают показ — так же, как стихи в Библии.
    @discardableResult
    func step(by delta: Int) -> Bool {
        guard model.step(by: delta) else { return false }
        syncLists()
        refresh()
        // Пока показ идёт в зале, листание меняет и то, что видят люди.
        if state?.media.still != nil { show() }
        return true
    }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true

        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.wantsLayer = true
        preview.layer?.backgroundColor = NSColor.black.cgColor
        preview.layer?.cornerRadius = 6

        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingMiddle

        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .centerY

        addSubview(files)
        addSubview(list)
        addSubview(preview)
        addSubview(caption)
        addSubview(toolbar)
        addSubview(firstGrip)
        addSubview(secondGrip)
        firstGrip.onDrag = { [weak self] delta in
            guard let self else { return }
            let column = self.model.kind == .presentation ? self.files : self.list
            NativeWidths.set(self.firstKey, column.frame.width + delta, min: 120, max: self.bounds.width * 0.5)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        firstGrip.onReset = { [weak self] in
            guard let self else { return }
            NativeWidths.reset(self.firstKey)
            self.needsLayout = true
        }
        secondGrip.onDrag = { [weak self] delta in
            guard let self else { return }
            NativeWidths.set(self.secondKey, self.list.frame.width + delta, min: 120, max: self.bounds.width * 0.5)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        secondGrip.onReset = { [weak self] in
            guard let self else { return }
            NativeWidths.reset(self.secondKey)
            self.needsLayout = true
        }
        buildToolbar()
    }

    private func buildToolbar() {
        func button(_ symbol: String, _ action: Selector) -> NSButton {
            let item = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                    ?? NSImage(), target: self, action: action)
            item.bezelStyle = .rounded
            item.imagePosition = .imageOnly
            return item
        }
        let open = button("plus", #selector(openFiles))
        let drop = button("minus", #selector(removeCurrent))
        let close = button("xmark", #selector(closeShow))
        let back = button("chevron.left", #selector(stepBack))
        let forward = button("chevron.right", #selector(stepForward))

        showButton = NSButton(title: "", target: self, action: #selector(show))
        showButton.bezelStyle = .rounded
        hideButton = NSButton(title: "", target: self, action: #selector(hide))
        hideButton.bezelStyle = .rounded

        drop.toolTip = model.kind == .pictures
            ? OurWords.t("Убрать картинку из списка")
            : OurWords.t("Убрать презентацию из списка")
        close.toolTip = OurWords.t("Очистить список")
        for item in [open, drop, close, back, forward, showButton!, hideButton!] {
            toolbar.addArrangedSubview(item)
        }

        // Слайд-шоу. Власник: «мы частенько выводим несколько фоток, может
        // добавить функцию слайд-шоу?». Сторінки гортаються самі, з обраним
        // кроком, по колу; будь-яке ручне гортання його не збиває — просто
        // відлік починається від щойно показаної сторінки.
        showTimeButton = NSButton(title: "", target: self, action: #selector(toggleSlideshow))
        showTimeButton.bezelStyle = .rounded
        secondsField = NativeForm.number(NativeForm.Tie(
            get: { UserDefaults.standard.object(forKey: "showSlideshowSeconds") as? Int ?? 6 },
            set: { [weak self] value in
                UserDefaults.standard.set(value, forKey: "showSlideshowSeconds")
                if self?.slideshow != nil { self?.startSlideshow() }
            }), range: 1...600, width: 54)
        secondsLabel = NativeForm.label(OurWords.t("с"), secondary: true)
        for item in [showTimeButton!, secondsField!, secondsLabel!] as [NSView] {
            toolbar.addArrangedSubview(item)
        }
        applySlideshowCaption()
    }

    // MARK: - Слайд-шоу

    private var showTimeButton: NSButton!
    private var secondsField: NSView!
    private var secondsLabel: NSView!
    private var slideshow: Timer?

    private var slideshowSeconds: Double {
        Double(UserDefaults.standard.object(forKey: "showSlideshowSeconds") as? Int ?? 6)
    }

    private func applySlideshowCaption() {
        showTimeButton.title = slideshow == nil
            ? OurWords.t("Слайд-шоу")
            : OurWords.t("Остановить")
        showTimeButton.toolTip = OurWords.t("Показывать страницы одну за другой, по кругу")
    }

    @objc private func toggleSlideshow() {
        if slideshow == nil { startSlideshow() } else { stopSlideshow() }
    }

    private func startSlideshow() {
        stopSlideshow(keepingCaption: true)
        guard !model.isEmpty else { applySlideshowCaption(); return }
        // Перша сторінка йде в зал одразу: чекати шість секунд, поки
        // почнеться те, що щойно ввімкнули, — незрозуміло.
        if model.index == nil { model.select(0) }
        show()
        slideshow = Timer.scheduledTimer(withTimeInterval: slideshowSeconds, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
        applySlideshowCaption()
    }

    private func stopSlideshow(keepingCaption: Bool = false) {
        slideshow?.invalidate()
        slideshow = nil
        if !keepingCaption { applySlideshowCaption() }
    }

    /// Наступна сторінка, а після останньої — знову перша.
    private func advance() {
        guard !model.isEmpty else { stopSlideshow(); return }
        let last = model.count - 1
        if let current = model.index, current >= last { model.select(0) } else { _ = model.step(by: 1) }
        show()
        refresh()
    }

    private func applyCaptions() {
        showButton.title = state?.text("SBShowOutScr", default: OurWords.t("Показать"))
            ?? OurWords.t("Показать")
        hideButton.title = state?.text("SBHideOutScr", default: OurWords.t("Скрыть"))
            ?? OurWords.t("Скрыть")
        let items = toolbar.arrangedSubviews
        items.first?.toolTip = model.kind == .pictures
            ? OurWords.t("Добавить картинки или папку с ними")
            : OurWords.t("Добавить презентацию или PDF")
        if items.count > 1 {
            items[1].toolTip = model.kind == .pictures
                ? OurWords.t("Убрать картинку из списка")
                : OurWords.t("Убрать презентацию из списка")
        }
        if items.count > 2 { items[2].toolTip = OurWords.t("Очистить список") }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let listWidth = max(180, min(320, bounds.width * 0.28))
        let toolbarHeight: CGFloat = 28

        toolbar.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: toolbarHeight)
        let top = toolbar.frame.maxY + gap
        let height = max(0, bounds.height - top - gap)

        // У презентаций две колонки: файлы и страницы выбранного файла.
        // У картинок файл и есть страница — колонка одна.
        let twoColumns = model.kind == .presentation
        files.isHidden = !twoColumns
        secondGrip.isHidden = !twoColumns
        let grip = NativeWidths.grip
        var right: CGFloat
        if twoColumns {
            let auto = max(150, min(260, bounds.width * 0.2))
            let filesWidth = NativeWidths.value(firstKey, auto: auto, min: 120, max: bounds.width * 0.5)
            let pagesWidth = NativeWidths.value(secondKey, auto: auto, min: 120, max: bounds.width * 0.5)
            files.frame = NSRect(x: gap, y: top, width: filesWidth, height: height)
            firstGrip.frame = NSRect(x: files.frame.maxX, y: top, width: grip, height: height)
            list.frame = NSRect(x: firstGrip.frame.maxX, y: top, width: pagesWidth, height: height)
            secondGrip.frame = NSRect(x: list.frame.maxX, y: top, width: grip, height: height)
            right = secondGrip.frame.maxX + gap
        } else {
            let width = NativeWidths.value(firstKey, auto: listWidth, min: 120, max: bounds.width * 0.5)
            list.frame = NSRect(x: gap, y: top, width: width, height: height)
            firstGrip.frame = NSRect(x: list.frame.maxX, y: top, width: grip, height: height)
            right = firstGrip.frame.maxX + gap
        }
        let captionHeight: CGFloat = 16
        preview.frame = NSRect(x: right, y: top,
                               width: max(0, bounds.width - right - gap),
                               height: max(0, height - captionHeight - 4))
        caption.frame = NSRect(x: right, y: preview.frame.maxY + 4,
                               width: max(0, bounds.width - right - gap), height: captionHeight)
    }

    // MARK: - Действия

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = model.kind == .pictures
        panel.allowsMultipleSelection = model.kind == .pictures
        panel.allowedFileTypes = model.kind.extensions
        panel.prompt = state?.text("BBOk", default: "Ок") ?? "Ок"
        panel.message = model.kind == .pictures
            ? OurWords.t("Выберите картинки или папку с ними")
            : OurWords.t("Выберите презентацию или PDF")
        // Презентаций и PDF тоже можно взять сразу несколько: список копится.
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        model.open(panel.urls)
        reloadLists()
        refresh()
    }

    @objc private func removeCurrent() { removeCurrentEntry() }

    @objc private func closeShow() {
        model.close()
        hide()
        reloadLists()
        refresh()
    }

    @objc private func stepBack() { step(by: -1) }
    @objc private func stepForward() { step(by: 1) }

    @objc private func show() {
        guard let state, let image = model.currentImage else { return }
        state.media.showStill(image, title: model.currentTitle)
        // Показ в зале включаем так же, как для стиха: одной кнопкой.
        if !state.isLive { state.isLive = true }
        refresh()
    }

    @objc private func hide() {
        state?.media.showStill(nil)
        refresh()
    }

    private func refresh() {
        // Телефон следит за страницами показа: любое изменение здесь — повод
        // сверить состояние и разбудить ждущих. Без этого перелистывание
        // мышью на компьютере на телефоне не отражалось.
        RemoteControlServer.shared.scheduleCheck()
        let image = model.currentImage
        preview.image = image.map { NSImage(cgImage: $0, size: .zero) }
        let ownMode: AppState.WorkMode = model.kind == .pictures ? .pictures : .presentation
        if let state, state.mode == ownMode { state.previewStill = image }
        let shown = state?.media.still != nil
        var line = model.problem ?? ""
        if line.isEmpty {
            if model.isEmpty {
                line = model.kind == .pictures
                    ? OurWords.t("Картинки не выбраны")
                    : OurWords.t("Презентация не открыта")
            } else {
                // У презентаций счёт — внутри файла: «Слайд 3 из 12», а не по
                // всем открытым презентациям разом.
                let range = model.currentRange
                let local = (model.index ?? range.lowerBound) - range.lowerBound + 1
                line = model.currentTitle + " — "
                    + OurWords.t("%s из %s", "\(local)", "\(range.count)")
                    + (shown ? " · " + OurWords.t("в зале") : "")
            }
        }
        caption.stringValue = line
        caption.textColor = model.problem == nil ? .secondaryLabelColor : .systemOrange
        showButton.isEnabled = image != nil
        hideButton.isEnabled = shown
        needsLayout = true
    }

    // MARK: - Списки

    /// Колонка страниц: у презентаций — страницы выбранного файла.
    var rowCount: Int { model.currentRange.count }

    func row(at index: Int) -> NativeRow {
        var row = NativeRow()
        row.lead = "\(index + 1)"
        let position = model.currentRange.lowerBound + index
        guard model.pages.indices.contains(position) else { return row }
        row.text = model.decks.isEmpty ? model.pages[position].title : model.pages[position].short
        return row
    }

    /// Колонка файлов — своим источником: один класс не может быть двумя
    /// источниками списка сразу.
    private final class DeckSource: NativeListSource {
        weak var owner: NativeShowWorkspace?
        var rowCount: Int { owner?.model.decks.count ?? 0 }
        func row(at index: Int) -> NativeRow {
            var row = NativeRow()
            guard let decks = owner?.model.decks, decks.indices.contains(index) else { return row }
            row.text = decks[index].name
            row.detail = "\(decks[index].range.count)"
            row.singleLine = true
            return row
        }
        func menu(at index: Int) -> NSMenu? { nil }
    }
    private lazy var deckSource: DeckSource = {
        let source = DeckSource()
        source.owner = self
        return source
    }()
}
