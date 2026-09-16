import AppKit
import UniformTypeIdentifiers
import SlovoCore

// Сторінки майстра імпорту: 4.2 вступна, 4.2.1 вибір версії,
// 4.2.2–4.2.5 списки, 4.2.6 завершення. Порядок, підписи й ключі перекладу —
// авторські; своїми словами написано тільки те, чого в автора немає.

// MARK: - 4.2 Вступна

@MainActor
final class ImportIntroPage: NSView, ImportPageRefreshing {

    private let state: AppState
    private let model: ImportWizardModel
    private let stack = ImportStack()
    private let destination = importPathLabel("")

    init(state: AppState, model: ImportWizardModel) {
        self.state = state
        self.model = model
        super.init(frame: .zero)

        let intro = ImportText(
            OurWords.t("Этот мастер переносит модули Библии и песенники, шаблоны слайда и фоновые изображения в библиотеку программы."),
            size: 13)
        // Чесна межа: в оригіналі джерело — лише попередня версія, тут —
        // будь-яка тека з даними й архів; налаштувань не переносимо.
        // Власник: «добавить в описание все форматы импорта, которые
        // поддерживаются, и сделать подсказки в программе» — перелік тут
        // повний і збігається з описом на GitHub.
        let ours = ImportText(OurWords.t("Источником может быть папка с данными VisioBible или любая папка, архив .zip либо файл: "
            + "модули «Цитата из Библии» (папка с bibleqt.ini или архив .zip, в том числе несколько архивов в одной папке); "
            + "модули MyBible (.SQLite3, .sqlite — вместе со словарями и комментариями рядом); модули MySword (.bbl.mybible); "
            + "песенники VisioBible (.vbm) и «Слова» (.songbook); шаблоны слайда (папка Templates, .sch); "
            + "фоновые изображения (.jpg, .png, .bmp, .gif, .tif, .heic, .webp). "
            + "Настройки чужой программы не переносятся — у «Слова» свои. Каждый модуль перед переносом открывается, "
            + "и в библиотеку не попадает то, что программа не прочитает."), size: 11, secondary: true)

        let reveal = NativeForm.button(OurWords.t("Показать в Finder"),
                                       hint: DataHome.hint(OurWords.t("Открыть в Finder папку, куда программа кладёт данные"))) { [weak self] in
            guard let self else { return }
            try? self.model.destination.prepare()
            NSWorkspace.shared.activateFileViewerSelecting([self.model.destination.dataRoot])
        }
        let box = ImportBox(OurWords.t("Куда будет перенесено"),
                            [destination, ImportRight([reveal])])

        let tail = ImportText(OurWords.t("%s — к выбору источника.", state.imp("PBBNext", "Дальше")),
                              size: 11, secondary: true)

        stack.spacing = 14
        stack.set([intro, ours, box, tail])
        addSubview(stack)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func refreshPage() {
        destination.stringValue = model.destination.dataRoot.path
        destination.toolTip = destination.stringValue
        needsLayout = true
    }

    override func layout() {
        super.layout()
        stack.frame = NSRect(x: 0, y: 0, width: bounds.width,
                             height: stack.height(forWidth: bounds.width))
    }
}

/// Ряд кнопок, притиснутих праворуч.
@MainActor
final class ImportRight: NSView {
    private let views: [NSView]
    init(_ views: [NSView]) {
        self.views = views
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    override func layout() {
        super.layout()
        var right = bounds.width
        for view in views.reversed() {
            let width = max(60, view.intrinsicContentSize.width + 16)
            view.frame = NSRect(x: right - width, y: 0, width: width, height: 22)
            right -= width + 8
        }
    }
}

// MARK: - 4.2.1 Вибір версії

@MainActor
final class ImportVersionsPage: NSView, ImportPageRefreshing,
                                NSTableViewDataSource, NSTableViewDelegate {

    private let state: AppState
    private let model: ImportWizardModel

    private let hint = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let pathTitle = NSTextField(labelWithString: "")
    private let pathValue = importPathLabel("—")
    private let chooseButton: NSButton
    private let searchButton: NSButton
    private let stopButton: NSButton
    private let spinner = NSProgressIndicator()
    private let searchStatus = NSTextField(labelWithString: "")
    /// Кого показували минулого разу: список приходить із фонового обходу
    /// дисків десятками, і перетрушувати таблицю на кожне перемальовування —
    /// означає губити виділення під руками в людини.
    private var shownIDs: [String] = []

    init(state: AppState, model: ImportWizardModel) {
        self.state = state
        self.model = model
        chooseButton = NativeForm.button(
            state.imp("PBBSelectFolderPortableVers", "Выбрать папку с предыдущей версией"),
            hint: state.impHint("PBBSelectFolderPortableVers",
                                "Выбрать вручную папку с предыдущей версией программы")) { }
        searchButton = NativeForm.button(
            state.imp("PBBFindPortableVers", "Найти другие версии автоматически"),
            hint: state.impHint("PBBFindPortableVers",
                                "Найти другие версии программы автоматически на всех дисках")) { }
        stopButton = NativeForm.button(
            state.imp("PBBStopSearch", "Остановить"),
            hint: state.impHint("PBBStopSearch", "Остановить поиск других версий программы")) { }
        super.init(frame: .zero)

        NativeForm.Trampoline.shared.bind(chooseButton) { [weak self] in self?.choose() }
        NativeForm.Trampoline.shared.bind(searchButton) { [weak self] in self?.model.searchAllDisks() }
        NativeForm.Trampoline.shared.bind(stopButton) { [weak self] in self?.model.stopSearch() }

        hint.stringValue = state.imp("Label9", "Выберите из списка предыдущую версию для импорта.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        addSubview(hint)

        buildTable()

        empty.stringValue = state.imp("LOldAppNotFound", "Другие версии программы не найдены")
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        addSubview(empty)

        // Label1 — «Путь к папке с настройками предыдущей версии программы:»
        pathTitle.stringValue = state.imp("Label1",
                                          "Путь к папке с настройками предыдущей версии программы:")
        pathTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        pathTitle.lineBreakMode = .byTruncatingTail
        addSubview(pathTitle)
        addSubview(pathValue)

        addSubview(chooseButton)
        addSubview(searchButton)
        addSubview(stopButton)

        spinner.style = .spinning
        spinner.controlSize = .small
        addSubview(spinner)
        searchStatus.font = .systemFont(ofSize: 10)
        searchStatus.textColor = .secondaryLabelColor
        searchStatus.lineBreakMode = .byTruncatingMiddle
        addSubview(searchStatus)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func buildTable() {
        let version = NSTableColumn(identifier: .init("version"))
        version.title = state.imp("LVVersions->Column0", "Версия")
        version.width = 240
        version.minWidth = 140
        let path = NSTableColumn(identifier: .init("path"))
        path.title = state.imp("LVVersions->Column1", "Путь")
        path.width = 420
        path.minWidth = 160
        table.addTableColumn(version)
        table.addTableColumn(path)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)
    }

    // MARK: Перемальовування

    func refreshPage() {
        let ids = model.sources.map(\.id)
        if ids != shownIDs {
            shownIDs = ids
            table.reloadData()
        }
        let selected = model.sources.firstIndex { $0.id == model.selectedSourceID }
        if let selected, table.selectedRow != selected {
            table.selectRowIndexes(IndexSet(integer: selected), byExtendingSelection: false)
        }
        let hasSources = !model.sources.isEmpty
        scroll.isHidden = !hasSources
        empty.isHidden = hasSources
        pathValue.stringValue = model.selectedSource?.path ?? "—"
        pathValue.toolTip = pathValue.stringValue

        searchButton.isHidden = model.isSearching
        stopButton.isHidden = !model.isSearching
        spinner.isHidden = !model.isSearching
        if model.isSearching { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        searchStatus.stringValue = model.isSearching ? model.searchStatus : ""
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        hint.frame = NSRect(x: 0, y: 0, width: width, height: 16)
        let bottom = bounds.height
        let searchRow = bottom - 18
        searchStatus.frame = NSRect(x: 22, y: searchRow, width: max(0, width - 22), height: 14)
        spinner.frame = NSRect(x: 0, y: searchRow, width: 14, height: 14)

        let buttonsRow = searchRow - 30
        let chooseWidth = min(width * 0.55, chooseButton.intrinsicContentSize.width + 24)
        chooseButton.frame = NSRect(x: 0, y: buttonsRow, width: chooseWidth, height: 24)
        let searchWidth = min(width - chooseWidth - 8, searchButton.intrinsicContentSize.width + 24)
        searchButton.frame = NSRect(x: chooseWidth + 8, y: buttonsRow, width: searchWidth, height: 24)
        stopButton.frame = NSRect(x: chooseWidth + 8, y: buttonsRow,
                                  width: max(90, stopButton.intrinsicContentSize.width + 24), height: 24)

        let pathRow = buttonsRow - 44
        pathTitle.frame = NSRect(x: 0, y: pathRow, width: width, height: 15)
        pathValue.frame = NSRect(x: 0, y: pathRow + 18, width: width, height: 15)

        let tableTop: CGFloat = 22
        let tableHeight = max(60, pathRow - 8 - tableTop)
        scroll.frame = NSRect(x: 0, y: tableTop, width: width, height: tableHeight)
        empty.frame = NSRect(x: 0, y: tableTop + tableHeight / 2 - 9, width: width, height: 18)
    }

    /// Скільки рядків показано насправді — для самоперевірки.
    var shownRows: Int { table.numberOfRows }

    // MARK: Таблиця

    func numberOfRows(in tableView: NSTableView) -> Int { model.sources.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard model.sources.indices.contains(row), let column = tableColumn else { return nil }
        let source = model.sources[row]
        let field = NSTextField(labelWithString: "")
        field.lineBreakMode = .byTruncatingMiddle
        if column.identifier.rawValue == "version" {
            field.stringValue = "\(mark(for: source.kind)) \(source.version)"
            field.font = .systemFont(ofSize: 12)
        } else {
            field.stringValue = source.path
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.toolTip = source.path
        }
        return field
    }

    /// Звідки взялося джерело. Значків в оригіналі немає — пишемо словом, щоб
    /// у списку було видно, що перед тобою: установлена копія, тека чи
    /// архів.
    private func mark(for kind: ImportSource.Kind) -> String {
        switch kind {
        case .installed: return "▣"
        case .folder:    return "▤"
        case .archive:   return "🗜"
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard model.sources.indices.contains(row) else { return }
        model.selectedSourceID = model.sources[row].id
    }

    /// OpenDialogSelHandly — «Выбрать папку с предыдущей версией». Крім теки
    /// приймаємо архів і окремий файл модуля: майстер за завданням працює не
    /// тільки з минулою версією програми.
    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = state.imp("OpenDialogSelHandly", "Выбрать папку с предыдущей версией") + " — "
            + OurWords.t("папка с данными, архив .zip или файл .SQLite3, .mybible, .vbm, .songbook")
        panel.prompt = state.imp("PBBNext", "Дальше")

        var types: [UTType] = [.zip, .folder]
        for suffix in ["vbm", "songbook", "sqlite3", "sqlite"] {
            if let type = UTType(filenameExtension: suffix) { types.append(type) }
        }
        panel.allowedContentTypes = types

        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addChosen(url, language: state.language)
    }
}

extension ImportVersionsPage: NSMenuDelegate {

    /// N2 — «Открыть папку с программой».
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard model.sources.indices.contains(row) else { return }
        let url = model.sources[row].url
        let item = NSMenuItem(title: state.imp("N2", "Открыть папку с программой"),
                              action: #selector(openFolder(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = url
        menu.addItem(item)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
