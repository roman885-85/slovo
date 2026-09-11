import AppKit
import Combine
import SlovoCore

/// Мастерская веб-слайдов — на AppKit: слева страницы, посередине ручки
/// оформления или разметка, справа живой результат.
///
/// В оригинале такого нет — там страницы пишут в стороннем редакторе, а в
/// настройках только перечисляют готовые файлы. Оператору без опыта это не
/// осилить: он не видит, что получится, пока не запустит показ, и не знает,
/// какую строку в чужом файле трогать.
///
/// Ползунки и правки руками живут мирно: и те и другие меняют один и тот же
/// текст страницы. Ползунок трогает только своё значение в блоке настроек.
@MainActor
final class NativeWebSlideEditor: NSView, NativeListSource, NSTextViewDelegate {

    private let state: AppState
    private let model = WebSlideEditorModel()
    private var observers: [AnyCancellable] = []

    /// Верхня і нижня полоси — з переносом рядів. Власник: «часть кнопок не
    /// видно… приходится вручную растягивать окно». `NSStackView` у вузькому
    /// вікні тихо обрізає хвіст, і «Убрать картинку» просто не існувало для
    /// того, хто не знав, що вона там є.
    private let toolbar = NativeFlowBar()
    private let pages = NativeTable(detailWidth: 0)
    private let middleBar = NSStackView()
    private let tabs = NSSegmentedControl()
    private let pageTitle = NSTextField(labelWithString: "")
    private let knobs = NativeWebSlideKnobs()
    private let markup = NSTextView()
    private let markupScroll = NSScrollView()
    private let stage: NativeWebSlideStage
    private let sampleBar = NativeFlowBar()
    private let status = NSTextField(labelWithString: "")
    private var samplePopup: NSPopUpButton!
    private var saveButton: NSButton!
    private var browserButton: NSButton!

    /// Что показано посередине: ручки или разметка.
    private var showsMarkup = false
    /// Яким був список сторінок минулого разу.
    private var listed = ""

    init(state: AppState) {
        self.state = state
        stage = NativeWebSlideStage(model: model)
        super.init(frame: NSRect(x: 0, y: 0, width: 1240, height: 720))
        build()
        model.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        model.broadcast = { [weak state] values in state?.web.publishStyle(values) }
        observers.append(model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Правки не должны пропасть при закрытии окна.
    func finish() { model.flushSave() }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        middleBar.orientation = .horizontal
        middleBar.spacing = 8
        middleBar.alignment = .centerY
        for bar in [toolbar, sampleBar, middleBar] as [NSView] { addSubview(bar) }

        var top: [NSView] = []
        top.append(NativeForm.button(OurWords.t("Новая из заготовки")) { [weak self] in
            self?.createPage()
        })
        top.append(NativeForm.button(OurWords.t("Взять за основу"),
            hint: OurWords.t("Сделать свою копию открытой страницы и править её")) { [weak self] in
            _ = self?.model.duplicateCurrent()
        })
        // Владелец: «в веб-слайдах нет кнопки сохранить» — она была, но
        // гасла на авторской странице и без правок. Теперь всегда доступна:
        // авторскую страницу сама копирует в свои и сохраняет копию.
        saveButton = NativeForm.button(OurWords.t("Сохранить")) { [weak self] in
            guard let self, let page = self.model.current else { return }
            if !page.isEditable {
                guard self.model.duplicateCurrent() else { return }
                self.pages.reload()
            }
            _ = self.model.save()
            self.refresh()
        }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        top.append(saveButton)
        browserButton = NativeForm.button(OurWords.t("Открыть в браузере")) { [weak self] in
            guard let self else { return }
            self.model.openInBrowser(port: self.state.outputs.web.httpPort)
        }
        top.append(browserButton)
        toolbar.setButtons(top)

        pages.source = self
        pages.onSelect = { [weak self] _, active, _ in
            guard let self else { return }
            let list = self.allPages
            guard list.indices.contains(active) else { return }
            self.model.open(list[active])
        }
        pages.onContextMenu = { [weak self] index in
            guard let self else { return nil }
            let list = self.allPages
            guard list.indices.contains(index), list[index].isEditable else { return nil }
            let menu = NSMenu()
            let item = NSMenuItem(title: OurWords.t("Удалить"), action: #selector(self.deletePage(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = list[index].id
            menu.addItem(item)
            return menu
        }
        addSubview(pages)

        pageTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        // Имя страницы с адресом длинное, а места в ряду мало: ужимается оно
        // (с многоточием посередине), а переключатель «Ползунки | Разметка»
        // стоит целиком — иначе от него оставалась одна «Разметка».
        pageTitle.lineBreakMode = .byTruncatingMiddle
        pageTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        middleBar.addArrangedSubview(pageTitle)
        tabs.segmentCount = 2
        tabs.setLabel(OurWords.t("Ползунки"), forSegment: 0)
        tabs.setLabel(OurWords.t("Разметка"), forSegment: 1)
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        tabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        middleBar.addArrangedSubview(tabs)

        knobs.model = model
        addSubview(knobs)

        markup.delegate = self
        markup.isRichText = false
        markup.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        markup.allowsUndo = true
        markup.isVerticallyResizable = true
        markup.autoresizingMask = [.width]
        markup.textContainer?.widthTracksTextView = true
        markupScroll.documentView = markup
        markupScroll.hasVerticalScroller = true
        markupScroll.borderType = .bezelBorder
        markupScroll.isHidden = true
        addSubview(markupScroll)

        addSubview(stage)

        // Чем наполнить слайд.
        samplePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        samplePopup.addItems(withTitles: WebSlideSample.all.map(\.title))
        samplePopup.target = self
        samplePopup.action = #selector(sampleChanged)
        var bottom: [NSView] = [samplePopup]
        bottom.append(NativeForm.button(OurWords.t("Со слайда"),
            hint: OurWords.t("Взять текст, который программа показывает прямо сейчас")) { [weak self] in
            guard let self else { return }
            let slide = self.state.slide
            self.model.takeSample(text: slide.mainText,
                                  second: slide.secondaryTexts.first ?? "",
                                  reference: slide.reference)
        })
        bottom.append(NativeForm.check(OurWords.t("Пустой экран в зале"),
            NativeForm.Tie(get: { [model] in model.isBlankScreen },
                           set: { [weak self] value in self?.model.isBlankScreen = value }),
            hint: OurWords.t("Так страница выглядит, когда показ выключен")))
        bottom.append(NativeForm.button(OurWords.t("Показать заново")) { [weak self] in
            self?.model.replay()
        })
        // Своя картинка под страницу: видно, как титры лягут на кадр из зала.
        bottom.append(NativeForm.button(OurWords.t("Своя картинка…"),
            hint: OurWords.t("Подложить свой файл под предпросмотр — как будет выглядеть поверх кадра")) { [weak self] in
            self?.chooseBackdrop()
        })
        bottom.append(NativeForm.button(OurWords.t("Убрать картинку")) { [weak self] in
            self?.stage.setBackdrop(nil)
        })
        sampleBar.setButtons(bottom)

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle
        addSubview(status)
    }

    // MARK: - Действия

    @objc private func tabChanged() {
        showsMarkup = tabs.selectedSegment == 1
        knobs.isHidden = showsMarkup
        markupScroll.isHidden = !showsMarkup
        // Текст розмітки наливаємо тільки тоді, коли його показують.
        if showsMarkup, markup.string != model.source { markup.string = model.source }
        needsLayout = true
    }

    /// Выбрать свой файл, который ляжет под страницу в предпросмотре.
    private func chooseBackdrop() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = OurWords.t("Выбрать…")
        panel.message = OurWords.t("Картинка ляжет под страницу — только в предпросмотре")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        stage.setBackdrop(url)
    }

    @objc private func sampleChanged() {
        let index = samplePopup.indexOfSelectedItem
        guard WebSlideSample.all.indices.contains(index) else { return }
        model.sample = WebSlideSample.all[index]
    }

    @objc private func deletePage(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let page = allPages.first(where: { $0.id == id }) else { return }
        model.delete(page)
        pages.reload()
    }

    /// Новая страница из заготовки: имя и заготовка — одним окном.
    private func createPage() {
        let alert = NSAlert()
        alert.messageText = OurWords.t("Новая из заготовки")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 56))
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 380, height: 22))
        name.placeholderString = OurWords.t("Имя файла страницы")
        let templates = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 380, height: 24), pullsDown: false)
        templates.addItems(withTitles: WebSlideTemplates.all.map { OurWords.t($0.title) })
        box.addSubview(name)
        box.addSubview(templates)
        alert.accessoryView = box
        alert.addButton(withTitle: state.vb("BBOk", "Ок"))
        alert.addButton(withTitle: state.vb("BBCancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty,
              WebSlideTemplates.all.indices.contains(templates.indexOfSelectedItem) else { return }
        model.create(from: WebSlideTemplates.all[templates.indexOfSelectedItem], name: title)
        pages.reload()
    }

    func textDidChange(_ notification: Notification) {
        guard model.current?.isEditable == true else { return }
        model.source = markup.string
    }

    // MARK: - Обновление

    private var allPages: [WebSlideEditorModel.Page] { model.myPages + model.authorPages }

    private func refresh() {
        // Рядом с именем — адрес, по которому страницу встраивают в OBS или
        // открывают в браузере (владелец: «не указаны адреса для встраивания»).
        let address: String
        if let page = model.current {
            let host = state.web.status.addresses.first ?? "127.0.0.1"
            address = "  —  " + WebPageAddress.url(host: host, port: state.outputs.web.httpPort,
                                                   fileName: page.url.lastPathComponent)
        } else {
            address = ""
        }
        pageTitle.stringValue = (model.current?.name ?? OurWords.t("Страница не выбрана")) + address
            + (model.isModified ? "  • " + OurWords.t("не сохранено") : "")
        pageTitle.isSelectable = true
        saveButton.isEnabled = model.current != nil
        browserButton.isEnabled = state.web.isRunning
        browserButton.toolTip = state.web.isRunning
            ? OurWords.t("Показать через работающий веб-сервер")
            : OurWords.t("Сначала включите веб-слайды в настройках вывода")
        markup.isEditable = model.current?.isEditable == true
        // Один крок повзунка переписує всю сторінку. Наливати цей текст у
        // схований редактор розмітки сорок разів на секунду — робота на
        // порожньому місці, від якої панель і починала спізнюватися за
        // рукою. Показують розмітку — наливаємо; ні — чекає свого часу.
        if showsMarkup, markup.string != model.source, window?.firstResponder !== markup {
            markup.string = model.source
        }
        if let index = WebSlideSample.all.firstIndex(where: { $0.id == model.sample.id }) {
            samplePopup.selectItem(at: index)
        }
        status.stringValue = model.current?.isEditable == false
            ? OurWords.t("только чтение — чужие файлы редактор не трогает")
            : OurWords.t("Правки руками и ползунки живут мирно: и те и другие меняют этот самый текст.")
        knobs.refresh()
        stage.refresh()
        // Список сторінок перебираємо лише тоді, коли він і справді змінився:
        // від руху повзунка сторінок не додається і не зникає.
        let listing = allPages.map { $0.id + ($0.isEditable ? "✎" : "🔒") }.joined(separator: "\u{1}")
            + "\u{2}" + (model.current?.id ?? "")
        if listing != listed {
            listed = listing
            pages.reload()
        }
        // Страница из комплекта: тянуть ручку можно, но записывать некуда —
        // предлагаем завести свою копию.
        if model.offersCopy { offerCopy() }
        needsLayout = true
    }

    private func offerCopy() {
        model.offersCopy = false
        let alert = NSAlert()
        alert.messageText = OurWords.t("Это страница из комплекта программы")
        alert.informativeText = OurWords.t("Чужие файлы редактор не трогает. Сделаем копию в ваших страницах — "
            + "и настраивайте её сколько угодно.")
        alert.addButton(withTitle: OurWords.t("Сделать свою копию"))
        alert.addButton(withTitle: OurWords.t("Отмена"))
        if alert.runModal() == .alertFirstButtonReturn { _ = model.duplicateCurrent() }
    }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        // Полоси міряємо самі: у вузькому вікні вони йдуть у два ряди, і
        // висоту під них треба віддати справжню, а не завжди 26.
        let toolbarHeight = toolbar.height(for: bounds.width - gap * 2)
        toolbar.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: toolbarHeight)
        let top = toolbar.frame.maxY + gap
        let bottom = bounds.height - 30

        let listWidth: CGFloat = 210
        pages.frame = NSRect(x: gap, y: top, width: listWidth, height: max(0, bottom - top))

        let middleLeft = listWidth + gap * 2
        // Панель ручок не має з'їдати предпросмотр: у вузькому вікні вона
        // бере свою частку, але не більше трьох п'ятих того, що лишилося.
        let free = bounds.width - middleLeft - gap
        let middleWidth = min(max(240, free * 0.42), max(240, free * 0.6))
        middleBar.frame = NSRect(x: middleLeft, y: top, width: middleWidth, height: 26)
        let middleTop = middleBar.frame.maxY + 4
        knobs.frame = NSRect(x: middleLeft, y: middleTop, width: middleWidth,
                             height: max(0, bottom - middleTop))
        markupScroll.frame = knobs.frame

        let stageLeft = middleLeft + middleWidth + gap
        let stageWidth = max(0, bounds.width - stageLeft - gap)
        let sampleHeight = sampleBar.height(for: stageWidth)
        sampleBar.frame = NSRect(x: stageLeft, y: max(top, bottom - sampleHeight - 4),
                                 width: stageWidth, height: sampleHeight)
        stage.frame = NSRect(x: stageLeft, y: top, width: stageWidth,
                             height: max(0, sampleBar.frame.minY - top - 6))
        status.frame = NSRect(x: gap, y: bounds.height - 24, width: bounds.width - gap * 2, height: 16)
    }

    // MARK: - Самоперевірці

    /// Полоси кнопок і панель ручок — щоб перевірка побачила, чи все влізло.
    var barsForCheck: [NativeFlowBar] { [toolbar, sampleBar] }
    var knobsForCheck: NativeWebSlideKnobs { knobs }
    var modelForCheck: WebSlideEditorModel { model }

    // MARK: - Список страниц

    var rowCount: Int { allPages.count }

    func row(at index: Int) -> NativeRow {
        let page = allPages[index]
        var row = NativeRow()
        row.lead = page.isEditable ? "✎" : "🔒"
        row.text = page.title
        row.textColor = page.isEditable ? .labelColor : .secondaryLabelColor
        return row
    }
}
