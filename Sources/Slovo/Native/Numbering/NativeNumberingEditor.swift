import AppKit
import SlovoCore

/// Окно «Редактор несоответствий нумерации переводов Библии» (N40) — на AppKit.
///
/// Своей формы у этого окна в файле перевода автора нет: он не локализовал её
/// ни на один язык, потому что правит базу у себя. Значит, чужих подписей мы
/// взять не можем ниоткуда, кроме соседних форм («Модули», «Название»,
/// «Сокращ.», «Книга:», «Глава:», «Стих:», «Ок», «Отменить»), а остальное
/// пишем своими словами.
///
/// Три вкладки: «Модули» — какому переводу какой стандарт нумерации,
/// «Правила» — сами правила пересчёта, «Проверка» — живая сверка стиха в двух
/// переводах. Правки идут в свою копию базы, файл программы только читается.
@MainActor
final class NativeNumberingEditor: NSView, NSTableViewDataSource, NSTableViewDelegate {

    private let state: AppState
    private let model: NumberingEditorModel
    /// Какую кнопку нажали: `true` — «Ок», `false` — «Отменить». Записывает и
    /// откатывает окно, а не вид.
    private let onFinish: (Bool) -> Void

    private let toolbar = NSStackView()
    private let tabs = NSSegmentedControl()
    private let counter = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let bottomNote = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private var pages: [NSView] = []
    private var timer: Timer?

    // Вкладка «Модули»
    private let modulesBar = NSStackView()
    private let assigned = NSTextField(labelWithString: "")
    // Вкладка «Правила»
    private let rulesBar = NSStackView()
    private let pairNote = NSTextField(labelWithString: "")
    private var pairFrom: NSPopUpButton!
    private var pairTo: NSPopUpButton!
    // Вкладка «Проверка»
    private let checkBar = NSStackView()
    private let addressField = NSTextField(string: "")
    private var bookPopup: NSPopUpButton!
    private var chapterField: NSTextField!
    private var verseField: NSTextField!
    private var primaryPopup: NSPopUpButton!
    private var secondaryPopup: NSPopUpButton!
    private let leftColumn = VerseColumn()
    private let rightColumn = VerseColumn()
    private let explanation = NSTextField(labelWithString: "")
    private let reportLine = NSTextField(labelWithString: "")
    private var buttons: [NSButton] = []

    init(state: AppState, model: NumberingEditorModel, onFinish: @escaping (Bool) -> Void) {
        self.state = state
        self.model = model
        self.onFinish = onFinish
        super.init(frame: NSRect(x: 0, y: 0, width: 1100, height: 700))
        build()
        refresh()
        // Часть работы модель делает в стороне: определение стандартов, сверка
        // книги, чтение глав. Своих поводов она не шлёт, поэтому раз в
        // полсекунды переспрашиваем — окно открыто минуты, это ничего не стоит.
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.window != nil else { self?.timer?.invalidate(); return }
                self.refresh()
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Подписи

    private func main(_ key: String, _ fallback: String) -> String {
        state.text(key, form: "MainForm", default: fallback).replacingOccurrences(of: "&", with: "")
    }

    private func settings(_ key: String, _ fallback: String) -> String {
        state.vb(key, fallback).replacingOccurrences(of: "&", with: "")
    }

    private func song(_ key: String, _ fallback: String) -> String {
        state.vb(key, form: "SongColorsetForm", fallback).replacingOccurrences(of: "&", with: "")
    }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for bar in [toolbar, modulesBar, rulesBar, checkBar] {
            bar.orientation = .horizontal
            bar.spacing = 6
            bar.alignment = .centerY
            addSubview(bar)
        }
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingMiddle

        toolbar.addArrangedSubview(NativeForm.button("⤓", hint: OurWords.t("Сохранить сейчас")) { [weak self] in
            guard let self else { return }
            if let failure = self.model.save() {
                self.model.status = OurWords.t("не записалось: %s", failure)
            }
            self.refresh()
        })
        toolbar.addArrangedSubview(NativeForm.button("↺", hint: OurWords.t("Вернуть всё как у автора")) {
            [weak self] in self?.askReset()
        })
        toolbar.addArrangedSubview(NativeForm.button("📁", hint: OurWords.t("Показать свою копию в Finder")) {
            [weak self] in self?.model.revealOwnCopy()
        })
        toolbar.addArrangedSubview(status)

        // Вкладки.
        tabs.segmentCount = NumberingEditorModel.Tab.allCases.count
        for (index, tab) in NumberingEditorModel.Tab.allCases.enumerated() {
            tabs.setLabel(title(of: tab), forSegment: index)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        addSubview(tabs)
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        addSubview(counter)

        buildModulesBar()
        buildRulesBar()
        buildCheckBar()

        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        for column in [leftColumn, rightColumn] { addSubview(column) }
        for label in [explanation, reportLine, bottomNote] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            addSubview(label)
        }
        bottomNote.stringValue = OurWords.t("Правки пишутся в %s, файл программы только читается",
                                            model.userFilePath)

        buttons = [
            NativeForm.button(song("BBCancel", "Отменить"),
                              hint: state.vbHint("BBCancel", form: "SongColorsetForm", "Не сохранять")) {
                [weak self] in self?.onFinish(false)
            },
            NativeForm.button(song("BBOk", "Ок"),
                              hint: state.vbHint("BBOk", form: "SongColorsetForm", "Сохранить")) {
                [weak self] in self?.onFinish(true)
            },
        ]
        buttons[1].keyEquivalent = "\r"
        buttons[0].keyEquivalent = "\u{1B}"
        for button in buttons { addSubview(button) }
        rebuildColumns()
    }

    private func title(of tab: NumberingEditorModel.Tab) -> String {
        switch tab {
        case .modules: return settings("TSModules", "Модули")
        case .rules:   return OurWords.t("Правила")
        case .check:   return OurWords.t("Проверка")
        }
    }

    private func buildModulesBar() {
        modulesBar.addArrangedSubview(NativeForm.button("✨", hint: OurWords.t("Определить стандарт для всех модулей")) {
            [weak self] in self?.model.detectAll()
        })
        modulesBar.addArrangedSubview(NativeForm.button("✧", hint: OurWords.t("Определить для выбранного")) {
            [weak self] in self?.model.detectSelected()
        })
        modulesBar.addArrangedSubview(NativeForm.button("↺", hint: OurWords.t("Вернуть авторское назначение")) {
            [weak self] in
            guard let self, let id = self.model.selectedModule else { return }
            self.model.restoreAuthorStandard(forModule: id)
            self.refresh()
        })
        modulesBar.addArrangedSubview(NativeForm.check(OurWords.t("Показывать только неназначенные"),
            NativeForm.Tie(get: { [model] in model.onlyUnassigned },
                           set: { [weak self] value in
                               self?.model.onlyUnassigned = value
                               self?.refresh()
                           })))
        assigned.font = .systemFont(ofSize: 11)
        assigned.textColor = .secondaryLabelColor
        modulesBar.addArrangedSubview(assigned)
    }

    private func buildRulesBar() {
        rulesBar.addArrangedSubview(NativeForm.label(OurWords.t("Из:")))
        pairFrom = standardPopup { [weak self] code in
            self?.model.pairFrom = code
            self?.refresh()
        }
        rulesBar.addArrangedSubview(pairFrom)
        rulesBar.addArrangedSubview(NativeForm.label(OurWords.t("В:")))
        pairTo = standardPopup { [weak self] code in
            self?.model.pairTo = code
            self?.refresh()
        }
        rulesBar.addArrangedSubview(pairTo)
        rulesBar.addArrangedSubview(NativeForm.button("⇄", hint: OurWords.t("Поменять местами")) { [weak self] in
            guard let self else { return }
            let from = self.model.pairFrom
            self.model.pairFrom = self.model.pairTo
            self.model.pairTo = from
            self.refresh()
        })
        rulesBar.addArrangedSubview(NativeForm.button("+", hint: state.vbHint("PngSBAdd", form: "SongColorsetForm",
                                                                             "Добавить правило")) {
            [weak self] in
            guard let self else { return }
            self.editRule(self.model.newDraft())
        })
        rulesBar.addArrangedSubview(NativeForm.button("✎", hint: state.vbHint("PngSBEdit", form: "SongColorsetForm",
                                                                             "Изменить правило")) {
            [weak self] in
            guard let self, let rule = self.model.rule(self.model.selectedRule) else { return }
            self.editRule(self.model.draft(from: rule))
        })
        rulesBar.addArrangedSubview(NativeForm.button("−", hint: state.vbHint("PngSBRem", form: "SongColorsetForm",
                                                                             "Удалить правило")) {
            [weak self] in
            guard let self, let id = self.model.selectedRule else { return }
            self.model.removeRule(id)
            self.refresh()
        })
        rulesBar.addArrangedSubview(NativeForm.button("⧉", hint: OurWords.t("Создать зеркальное правило в обратной паре")) {
            [weak self] in
            guard let self, let rule = self.model.rule(self.model.selectedRule) else { return }
            self.editRule(self.model.mirrorDraft(of: rule))
        })
        rulesBar.addArrangedSubview(NativeForm.button("↺", hint: OurWords.t("Вернуть авторскую строку")) {
            [weak self] in
            guard let self, let id = self.model.selectedRule else { return }
            self.model.restoreAuthorRule(id)
            self.refresh()
        })
        rulesBar.addArrangedSubview(NativeForm.check(OurWords.t("Только свои строки"),
            NativeForm.Tie(get: { [model] in model.onlyMine },
                           set: { [weak self] value in
                               self?.model.onlyMine = value
                               self?.refresh()
                           })))
        pairNote.font = .systemFont(ofSize: 11)
        pairNote.textColor = .secondaryLabelColor
        rulesBar.addArrangedSubview(pairNote)
    }

    private func buildCheckBar() {
        primaryPopup = modulePopup { [weak self] id in
            self?.model.checkPrimary = id
            self?.refresh()
        }
        secondaryPopup = modulePopup { [weak self] id in
            self?.model.checkSecondary = id
            self?.refresh()
        }
        checkBar.addArrangedSubview(NativeForm.label(main("Label3D4", "Модуль:")))
        checkBar.addArrangedSubview(primaryPopup)
        checkBar.addArrangedSubview(secondaryPopup)
        checkBar.addArrangedSubview(NativeForm.button("⇄", hint: OurWords.t("Поменять переводы местами")) {
            [weak self] in
            guard let self else { return }
            let first = self.model.checkPrimary
            self.model.checkPrimary = self.model.checkSecondary
            self.model.checkSecondary = first
            self.refresh()
        })

        addressField.font = .systemFont(ofSize: 12)
        addressField.target = self
        addressField.action = #selector(addressEntered)
        addressField.toolTip = state.language?.hint("EFastInput", form: "MainForm")
            ?? OurWords.t("Быстрый выбор вводом в формате: [номер Книги] Книга Глава Стих [Стих_по]")
        checkBar.addArrangedSubview(addressField)

        checkBar.addArrangedSubview(NativeForm.label(main("Label8", "Книга:")))
        bookPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        bookPopup.target = self
        bookPopup.action = #selector(bookChanged)
        checkBar.addArrangedSubview(bookPopup)

        checkBar.addArrangedSubview(NativeForm.label(main("Label1", "Глава:")))
        chapterField = NativeForm.number(NativeForm.Tie(get: { [model] in model.checkChapter },
                                                        set: { [weak self] value in
                                                            self?.model.checkChapter = value
                                                            self?.model.refreshAddressInput()
                                                            self?.refresh()
                                                        }), range: 1...200, width: 54)
        checkBar.addArrangedSubview(chapterField)
        checkBar.addArrangedSubview(NativeForm.label(main("Label3", "Стих:")))
        verseField = NativeForm.number(NativeForm.Tie(get: { [model] in model.checkVerse },
                                                      set: { [weak self] value in
                                                          self?.model.checkVerse = value
                                                          self?.model.refreshAddressInput()
                                                          self?.refresh()
                                                      }), range: 1...200, width: 54)
        checkBar.addArrangedSubview(verseField)
        checkBar.addArrangedSubview(NativeForm.button(OurWords.t("Сверить книгу целиком")) { [weak self] in
            self?.model.verifyBook()
        })
    }

    private func standardPopup(_ apply: @escaping (String) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: model.standardCodes.map(NumberingEditorModel.standardTitle))
        NativeForm.Trampoline.shared.bind(popup) { [weak popup] in
            guard let popup else { return }
            let codes = NumberingEditorModel.self
            _ = codes
            apply(popup.indexOfSelectedItem >= 0 ? popupCode(popup) : "")
        }
        popup.target = NativeForm.Trampoline.shared
        popup.action = #selector(NativeForm.Trampoline.fire(_:))
        return popup

        func popupCode(_ popup: NSPopUpButton) -> String {
            let index = popup.indexOfSelectedItem
            return model.standardCodes.indices.contains(index) ? model.standardCodes[index] : ""
        }
    }

    private func modulePopup(_ apply: @escaping (String) -> Void) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: model.modules.map(\.name))
        NativeForm.Trampoline.shared.bind(popup) { [weak self, weak popup] in
            guard let self, let popup else { return }
            let index = popup.indexOfSelectedItem
            guard self.model.modules.indices.contains(index) else { return }
            apply(self.model.modules[index].id)
        }
        popup.target = NativeForm.Trampoline.shared
        popup.action = #selector(NativeForm.Trampoline.fire(_:))
        return popup
    }

    // MARK: - Действия

    @objc private func tabChanged() {
        let all = NumberingEditorModel.Tab.allCases
        model.tab = all[max(0, min(tabs.selectedSegment, all.count - 1))]
        rebuildColumns()
        refresh()
    }

    @objc private func addressEntered() {
        model.addressInput = addressField.stringValue
        model.applyAddressInput()
        refresh()
    }

    @objc private func bookChanged() {
        let index = bookPopup.indexOfSelectedItem
        guard model.books.indices.contains(index) else { return }
        model.checkBook = model.books[index].number
        model.refreshAddressInput()
        refresh()
    }

    private func askReset() {
        guard model.hasOwnCopy else { return }
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages24", "Внимание")
        alert.informativeText = OurWords.t("Все ваши правки нумерации будут удалены. Продолжить?")
        alert.addButton(withTitle: state.yesCaption)
        alert.addButton(withTitle: state.noCaption)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.dropOwnCopy()
        refresh()
    }

    /// Правка одного правила отдельным окном. Правим копию: пока окно
    /// открыто, в таблице должна оставаться прежняя строка, а «Отменить»
    /// обязано её сохранить.
    private func editRule(_ draft: NumberingEditorModel.RuleDraft) {
        let sheet = NativeNumberingRuleSheet(state: state, model: model, draft: draft)
        sheet.run()
        refresh()
    }

    // MARK: - Обновление

    private func refresh() {
        status.stringValue = model.status
            + (model.isDirty ? "  " + OurWords.t("не сохранено") : "")
            + "  " + OurWords.t("своих строк: %s", "\(model.ownRowCount)")
        assigned.stringValue = OurWords.t("назначено %s из %s",
                                          "\(model.assignedCount)", "\(model.moduleRows.count)")
        pairNote.stringValue = model.pairNote
        counter.stringValue = counterText

        if let index = model.standardCodes.firstIndex(of: model.pairFrom) { pairFrom.selectItem(at: index) }
        if let index = model.standardCodes.firstIndex(of: model.pairTo) { pairTo.selectItem(at: index) }
        if bookPopup.numberOfItems != model.books.count {
            bookPopup.removeAllItems()
            bookPopup.addItems(withTitles: model.books.map(\.name))
        }
        if let index = model.books.firstIndex(where: { $0.number == model.checkBook }) {
            bookPopup.selectItem(at: index)
        }
        if let index = model.modules.firstIndex(where: { $0.id == model.checkPrimary }) {
            primaryPopup.selectItem(at: index)
        }
        if let index = model.modules.firstIndex(where: { $0.id == model.checkSecondary }) {
            secondaryPopup.selectItem(at: index)
        }
        if addressField.stringValue != model.addressInput, window?.firstResponder !== addressField.currentEditor() {
            addressField.stringValue = model.addressInput
        }
        chapterField.stringValue = "\(model.checkChapter)"
        verseField.stringValue = "\(model.checkVerse)"

        modulesBar.isHidden = model.tab != .modules
        rulesBar.isHidden = model.tab != .rules
        checkBar.isHidden = model.tab != .check
        scroll.isHidden = model.tab == .check
        leftColumn.isHidden = model.tab != .check
        rightColumn.isHidden = model.tab != .check
        explanation.isHidden = model.tab != .check
        reportLine.isHidden = model.tab != .check

        if model.tab == .check { refreshCheck() }
        table.reloadData()
        needsLayout = true
    }

    private var counterText: String {
        switch model.tab {
        case .modules: return "\(model.visibleModuleRows.count)"
        case .rules:   return "\(model.ruleRows.count)"
        case .check:   return model.reportSummary
        }
    }

    /// Живая сверка: слева стих в своей нумерации, справа — куда он попадает.
    private func refreshCheck() {
        let from = model.standardCode(ofModule: model.checkPrimary)
        let to = model.standardCode(ofModule: model.checkSecondary)
        let answer = from.isEmpty || to.isEmpty
            ? (spans: [VerseSpan](), reason: OurWords.t("стандарт не назначен одному из переводов"),
               rule: nil as NumberingRule?)
            : model.translate(book: model.checkBook, chapter: model.checkChapter,
                              verses: [model.checkVerse], from: from, to: to)

        fill(leftColumn, moduleID: model.checkPrimary, chapter: model.checkChapter,
             verses: [model.checkVerse], isTarget: false)
        let chapter = answer.spans.first?.chapter ?? model.checkChapter
        let verses = answer.spans.first?.verses ?? [model.checkVerse]
        fill(rightColumn, moduleID: model.checkSecondary, chapter: chapter,
             verses: verses, isTarget: true)

        let head = answer.spans.isEmpty ? ""
            : "\(model.bookName(model.checkBook)) \(model.checkChapter):\(model.checkVerse) → "
                + answer.spans.map { ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses) }
                    .joined(separator: ", ") + ", "
        explanation.stringValue = head + answer.reason
        reportLine.stringValue = model.reportSummary
            + (model.report.isEmpty ? "" : "  " + OurWords.t("промахи: %s", "\(model.report.count)"))
    }

    private func fill(_ column: VerseColumn, moduleID: String, chapter: Int,
                      verses: [Int], isTarget: Bool) {
        let name = model.modules.first { $0.id == moduleID }?.name ?? moduleID
        let chapters = model.chapters(ofModule: moduleID, canonical: model.checkBook) ?? []
        let ready = chapters.first { $0.number == chapter }
        // Соседние два стиха сверху и снизу — не украшение: когда правило
        // ошиблось на единицу, правильный текст видно строкой выше или ниже.
        let low = (verses.min() ?? 1) - 2
        let high = (verses.max() ?? 1) + 2
        column.name = name
        column.address = "\(model.bookName(model.checkBook)) "
            + ReferenceFormat.position(chapter: chapter, verses: verses)
        column.isTarget = isTarget
        column.highlighted = Set(verses)
        column.verses = (ready?.verses ?? []).filter { $0.number >= low && $0.number <= high }
        column.isLoading = chapters.isEmpty
        column.needsDisplay = true
    }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        let gap: CGFloat = 10
        toolbar.frame = NSRect(x: gap, y: 8, width: bounds.width - gap * 2, height: 26)
        tabs.frame = NSRect(x: gap, y: toolbar.frame.maxY + 6, width: 320, height: 24)
        counter.frame = NSRect(x: bounds.width - 220, y: tabs.frame.minY + 4, width: 200, height: 16)

        let barTop = tabs.frame.maxY + 8
        for bar in [modulesBar, rulesBar, checkBar] {
            bar.frame = NSRect(x: gap, y: barTop, width: bounds.width - gap * 2, height: 26)
        }
        let contentTop = barTop + 34
        let bottom: CGFloat = 44

        if model.tab == .check {
            let half = (bounds.width - gap * 3) / 2
            let height = max(0, bounds.height - contentTop - bottom - 46)
            leftColumn.frame = NSRect(x: gap, y: contentTop, width: half, height: height)
            rightColumn.frame = NSRect(x: gap * 2 + half, y: contentTop, width: half, height: height)
            explanation.frame = NSRect(x: gap, y: contentTop + height + 4,
                                       width: bounds.width - gap * 2, height: 16)
            reportLine.frame = NSRect(x: gap, y: contentTop + height + 22,
                                      width: bounds.width - gap * 2, height: 16)
        } else {
            scroll.frame = NSRect(x: gap, y: contentTop, width: bounds.width - gap * 2,
                                  height: max(0, bounds.height - contentTop - bottom))
        }

        bottomNote.frame = NSRect(x: gap, y: bounds.height - 34, width: bounds.width - 240, height: 16)
        var right = bounds.width - gap
        for button in buttons.reversed() {
            let width = max(90, button.intrinsicContentSize.width + 24)
            button.frame = NSRect(x: right - width, y: bounds.height - 38, width: width, height: 24)
            right -= width + 8
        }
    }

    // MARK: - Таблицы

    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        let titles: [(String, CGFloat)]
        switch model.tab {
        case .modules:
            titles = [(settings("LVBiblesPath->Column0", "Название"), 230),
                      (settings("LVBiblesPath->Column1", "Сокращ."), 110),
                      (OurWords.t("Стандарт"), 220),
                      (OurWords.t("Откуда"), 110),
                      (OurWords.t("Сходится"), 190)]
        case .rules:
            titles = [(OurWords.t("Тип"), 170), (OurWords.t("Книга"), 160),
                      (OurWords.t("Откуда"), 150), (OurWords.t("Куда"), 150),
                      (OurWords.t("Источник"), 120)]
        case .check:
            titles = []
        }
        for (index, item) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = item.0
            column.width = item.1
            table.addTableColumn(column)
        }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        switch model.tab {
        case .modules: return model.visibleModuleRows.count
        case .rules:   return model.ruleRows.count
        case .check:   return 0
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn else { return nil }
        let index = table.tableColumns.firstIndex(of: column) ?? 0
        switch model.tab {
        case .modules:
            guard model.visibleModuleRows.indices.contains(row) else { return nil }
            return moduleCell(model.visibleModuleRows[row], column: index)
        case .rules:
            guard model.ruleRows.indices.contains(row) else { return nil }
            return ruleCell(model.ruleRows[row], column: index)
        case .check:
            return nil
        }
    }

    private func moduleCell(_ entry: NumberingEditorModel.ModuleRow, column: Int) -> NSView {
        switch column {
        case 2:
            // Стандарт назначают прямо в строке — так же, как в оригинале.
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItem(withTitle: OurWords.t("не назначен"))
            popup.addItems(withTitles: model.standardCodes.map(NumberingEditorModel.standardTitle))
            let codes = [""] + model.standardCodes
            popup.selectItem(at: codes.firstIndex(of: entry.standard) ?? 0)
            popup.font = .systemFont(ofSize: 11)
            NativeForm.Trampoline.shared.bind(popup) { [weak self, weak popup] in
                guard let self, let popup else { return }
                let value = codes.indices.contains(popup.indexOfSelectedItem)
                    ? codes[popup.indexOfSelectedItem] : ""
                self.model.setStandard(value, forModule: entry.id)
                self.refresh()
            }
            popup.target = NativeForm.Trampoline.shared
            popup.action = #selector(NativeForm.Trampoline.fire(_:))
            return popup
        case 4:
            let label = NSTextField(labelWithString: matchText(entry.match))
            label.font = .systemFont(ofSize: 11)
            label.textColor = matchColor(entry.match)
            return label
        default:
            let text = [entry.name, entry.short, "", entry.origin.title][min(column, 3)]
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11)
            // Оранжевым — те, у кого стандарта нет: их адрес не
            // пересчитывается вовсе, и это видно должно быть сразу.
            label.textColor = column == 3 && entry.standard.isEmpty ? .systemOrange : .labelColor
            return label
        }
    }

    private func matchText(_ match: NumberingEditorModel.MatchState) -> String {
        switch match {
        case .unknown: return "—"
        case .working: return OurWords.t("считаю…")
        case .impossible(let why): return OurWords.t("не проверить: %s", why)
        case let .score(hits, total, missed):
            return missed.isEmpty ? OurWords.t("%s из %s", "\(hits)", "\(total)")
                                  : OurWords.t("%s из %s — %s", "\(hits)", "\(total)", missed)
        }
    }

    private func matchColor(_ match: NumberingEditorModel.MatchState) -> NSColor {
        guard case let .score(hits, total, _) = match else { return .secondaryLabelColor }
        if hits == total { return .labelColor }
        return hits == 0 ? .systemRed : .systemOrange
    }

    private func ruleCell(_ entry: NumberingEditorModel.RuleRow, column: Int) -> NSView {
        let text = [entry.kindTitle + " (" + entry.letter + ")", entry.bookTitle,
                    entry.source, entry.target, entry.origin.title][min(column, 4)]
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        // Удалённую авторскую строку показываем зачёркнутой — она осталась в
        // базе, но больше не работает.
        if entry.origin == .removed {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .foregroundColor: NSColor.secondaryLabelColor,
                .font: NSFont.systemFont(ofSize: 11),
            ])
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        switch model.tab {
        case .modules:
            guard model.visibleModuleRows.indices.contains(row) else { return }
            model.selectedModule = model.visibleModuleRows[row].id
        case .rules:
            guard model.ruleRows.indices.contains(row) else { return }
            model.selectedRule = model.ruleRows[row].id
        case .check:
            break
        }
    }

    /// Колонка стихов: имя перевода, адрес и сами стихи с подсветкой.
    final class VerseColumn: NSView {
        var name = ""
        var address = ""
        var isTarget = false
        var verses: [Verse] = []
        var highlighted: Set<Int> = []
        var isLoading = false

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.textBackgroundColor.setFill()
            bounds.fill()
            var top: CGFloat = 6
            draw(name, at: &top, size: 12, weight: .medium, colour: .labelColor)
            draw(address, at: &top, size: isTarget ? 14 : 12,
                 weight: isTarget ? .bold : .regular, colour: .labelColor)
            if isLoading {
                draw(OurWords.t("читаю книгу…"), at: &top, size: 11, weight: .regular,
                     colour: .secondaryLabelColor)
            }
            top += 4
            for verse in verses {
                let chosen = highlighted.contains(verse.number)
                if chosen {
                    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                    NSRect(x: 2, y: top - 2, width: bounds.width - 4, height: 18).fill()
                }
                let number = NSAttributedString(string: "\(verse.number)", attributes: [
                    .font: NSFont.systemFont(ofSize: 10),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ])
                number.draw(at: NSPoint(x: 6, y: top))
                let text = NSAttributedString(string: verse.text, attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: chosen ? NSColor.labelColor : NSColor.secondaryLabelColor,
                ])
                let box = NSRect(x: 34, y: top, width: bounds.width - 40, height: bounds.height - top)
                text.draw(with: box, options: [.usesLineFragmentOrigin])
                top += max(18, text.boundingRect(with: NSSize(width: box.width, height: .greatestFiniteMagnitude),
                                                 options: [.usesLineFragmentOrigin]).height + 4)
                if top > bounds.height { break }
            }
        }

        private func draw(_ text: String, at top: inout CGFloat, size: CGFloat,
                          weight: NSFont.Weight, colour: NSColor) {
            let line = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: colour,
            ])
            line.draw(at: NSPoint(x: 6, y: top))
            top += size + 6
        }
    }
}
