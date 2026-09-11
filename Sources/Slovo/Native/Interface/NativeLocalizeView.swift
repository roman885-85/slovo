import AppKit
import SlovoCore

/// Окно «Перевод интерфейса» — раздел 7.1, форма `LocalizeTranslateForm`,
/// на AppKit.
///
/// Номера в комментариях — номера элементов из руководства (страницы 40—41).
/// Раскладка повторяет оригинал сверху вниз: панель инструментов, выбор окна,
/// вкладки типов текстов, список элементов, две половины «оригинал / перевод».
@MainActor
final class NativeLocalizeView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {

    private let state: AppState
    private let model: LocalizeTranslateModel
    private let onClose: () -> Void
    private let form = "LocalizeTranslateForm"

    private let topBar = NSStackView()
    private let secondBar = NSStackView()
    private let tabs = NSSegmentedControl()
    private let counter = NSTextField(labelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let dirtyMark = NSTextField(labelWithString: "")

    private var languages: NSPopUpButton!
    private var forms: NSPopUpButton!
    private var onlyUntranslated: NSButton!
    private var saveButton: NSButton!

    // Нижняя половина: оригинал и перевод.
    private let objectLine = NSTextField(labelWithString: "")
    private let typeLine = NSTextField(labelWithString: "")
    private let originalCaption = NSTextField(labelWithString: "")
    private let originalHint = NSTextField(labelWithString: "")
    private let captionField = NSTextField(string: "")
    private let hintField = NSTextField(string: "")
    private let originalTitle = NSTextField(labelWithString: "")
    private let translationTitle = NSTextField(labelWithString: "")
    private var editorButtons: [NSButton] = []

    init(state: AppState, model: LocalizeTranslateModel, onClose: @escaping () -> Void) {
        self.state = state
        self.model = model
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 1060, height: 700))
        build()
        // Какой перевод стоит в главном окне — от этого зависит отказ (4).
        model.activeLanguageCode = state.language?.code ?? ""
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Подписи из файла перевода автора

    private func caption(_ key: String, _ fallback: String) -> String {
        state.text(key, form: form, default: fallback)
    }

    private func hint(_ key: String, _ fallback: String) -> String {
        state.language?.hint(key, form: form) ?? OurWords.t(fallback)
    }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for bar in [topBar, secondBar] {
            bar.orientation = .horizontal
            bar.spacing = 6
            bar.alignment = .centerY
            addSubview(bar)
        }

        // (1) Сохранить перевод.
        saveButton = NativeForm.button("⤓", hint: hint("TBSave", "Сохранить перевод интерфейса")) {
            [weak self] in
            guard let self else { return }
            if self.model.save() { InterfaceLanguageStore.announceChange(originals: self.model.originals) }
            self.reload()
        }
        topBar.addArrangedSubview(saveButton)
        // (2) Язык перевода для правки.
        topBar.addArrangedSubview(NativeForm.label(hint("CBLangList", "Язык перевода интерфейса") + ":"))
        languages = NSPopUpButton(frame: .zero, pullsDown: false)
        languages.target = self
        languages.action = #selector(languageChanged)
        topBar.addArrangedSubview(languages)
        // (3) (4) Добавить и удалить перевод.
        topBar.addArrangedSubview(NativeForm.button("+", hint: hint("TBAddLocal",
                                                    "Добавить новый перевод интерфейса")) {
            [weak self] in self?.addTranslation()
        })
        topBar.addArrangedSubview(NativeForm.button("−", hint: hint("TBDelLocal",
                                                    "Удалить выбранный перевод интерфейса")) {
            [weak self] in self?.deleteTranslation()
        })
        dirtyMark.font = .systemFont(ofSize: 11)
        dirtyMark.textColor = .systemOrange
        topBar.addArrangedSubview(dirtyMark)
        topBar.addArrangedSubview(NativeForm.button(OurWords.t("Закрыть")) { [weak self] in
            self?.onClose()
        })

        // (5) Окно (форма) программы.
        secondBar.addArrangedSubview(NativeForm.label(
            hint("CBFormsSelect", "Выбор окна (формы) программы для перевода") + ":"))
        forms = NSPopUpButton(frame: .zero, pullsDown: false)
        forms.target = self
        forms.action = #selector(formChanged)
        secondBar.addArrangedSubview(forms)
        // (6) (7) Очистить и скопировать всё для окна.
        secondBar.addArrangedSubview(NativeForm.button("⌫", hint: hint("TBClearAll",
                                                       "Очистить ВСЕ переводы для окна")) {
            [weak self] in self?.model.clearForm(); self?.reload()
        })
        secondBar.addArrangedSubview(NativeForm.button("⧉", hint: hint("TBCopyAll",
                                                       "Скопировать ВСЕ переводы для окна из оригинальных текстов")) {
            [weak self] in self?.model.copyFormFromOriginal(); self?.reload()
        })
        // (8) (9) Онлайн-перевод. Требует учётной записи на visiobible.org.ua
        // — чужой службы, ключей к которой у программы нет. Кнопки оставлены
        // на своих местах и выключены: так виден полный состав окна и честная
        // граница.
        for (mark, key, fallback) in [("🌐", "TBWebTranslateAll", "Онлайн перевод ВСЕХ текстов для окна"),
                                      ("■", "TBWebTranslateStop", "Остановить перевод ВСЕХ текстов"),
                                      ("🔑", "TWebTranslateSettings", "Авторизация для онлайн перевода")] {
            let button = NativeForm.button(mark, hint: hint(key, fallback)) {}
            button.isEnabled = false
            secondBar.addArrangedSubview(button)
        }
        // (10) Только непереведённые.
        onlyUntranslated = NativeForm.check(
            hint("TBOnlyNotTranslated", "Показывать только непереведенные (Вкл/Выкл)"),
            NativeForm.Tie(get: { [model] in model.onlyUntranslated },
                           set: { [weak self] value in
                               self?.model.onlyUntranslated = value
                               self?.reload()
                           }))
        secondBar.addArrangedSubview(onlyUntranslated)

        // (11) Вкладки типов текстов.
        tabs.segmentCount = LocalizeTranslateModel.TextTab.allCases.count
        for (index, tab) in LocalizeTranslateModel.TextTab.allCases.enumerated() {
            tabs.setLabel(title(for: tab), forSegment: index)
        }
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        addSubview(tabs)
        counter.font = .systemFont(ofSize: 11)
        counter.textColor = .secondaryLabelColor
        addSubview(counter)

        // (12) Список элементов.
        table.dataSource = self
        table.delegate = self
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 20
        table.allowsMultipleSelection = false
        table.menu = rowMenu()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        buildEditor()
        rebuildColumns()
        fillLanguages()
        fillForms()
    }

    /// (13)…(17) Оригинал и перевод.
    private func buildEditor() {
        for label in [objectLine, typeLine, originalTitle, translationTitle] {
            label.font = .systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            addSubview(label)
        }
        for label in [originalCaption, originalHint] {
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.isSelectable = true
            addSubview(label)
        }
        for field in [captionField, hintField] {
            field.font = .systemFont(ofSize: 12)
            field.delegate = self
            addSubview(field)
        }
        // (15) (16) (17) Очистить, скопировать, онлайн-перевод.
        editorButtons = [
            NativeForm.button("⌫", hint: hint("PngSBClearObjText", "Очистить перевод для объекта")) {
                [weak self] in self?.model.clearSelected(); self?.reload()
            },
            NativeForm.button("⧉", hint: hint("PngSBCopyObjText", "Скопировать из оригинальных текстов")) {
                [weak self] in self?.model.copySelectedFromOriginal(); self?.reload()
            },
            NativeForm.button("🌐", hint: hint("PngSBWebTranslate", "Онлайн перевод текста")) {},
            // Пара «искать предыдущий / следующий» — как у автора рядом с полем.
            NativeForm.button("↑", hint: hint("PngSpeedButton1", "Искать предыдущий объект")) {
                [weak self] in self?.model.step(.object, forward: false); self?.syncSelection()
            },
            NativeForm.button("↓", hint: hint("PngSpeedButton2", "Искать следующий объект")) {
                [weak self] in self?.model.step(.object, forward: true); self?.syncSelection()
            },
        ]
        editorButtons[2].isEnabled = false
        for button in editorButtons { addSubview(button) }
    }

    private func rowMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: caption("NCopyText", "Скопировать текст в буфер обмена"),
                              action: #selector(copyRow), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    /// У первой вкладки в файле автора своего ключа нет — там стоят только
    /// `TSTexts` и `TSErrors`, а первая подписана классом объектов.
    private func title(for tab: LocalizeTranslateModel.TextTab) -> String {
        switch tab {
        case .objects: return caption("TSObjects", "Объекты")
        case .texts:   return caption("TSTexts", "Тексты")
        case .errors:  return caption("TSErrors", "Ошибки")
        }
    }

    // MARK: - Колонки

    private func rebuildColumns() {
        for column in table.tableColumns { table.removeTableColumn(column) }
        let titles: [(String, CGFloat)]
        if model.tab == .objects {
            titles = [(caption("LVObjects->Column0", "Объект"), 170),
                      (caption("LVObjects->Column1", "Тип"), 130),
                      (caption("LVObjects->Column2", "Оригин. заголовок"), 200),
                      (caption("LVObjects->Column3", "Оригин. подсказка"), 200),
                      (caption("LVObjects->Column4", "Перевод заголовка"), 200),
                      (caption("LVObjects->Column5", "Перевод подсказки"), 200)]
        } else {
            // У каждой текстовой вкладки свой набор ключей: «Тексты» —
            // LVTexts->Column0…2, «Ошибки» — LVTextsError->Column0…2. Общий
            // ключ дал бы «Ошибкам» чужие заголовки.
            let list = model.tab == .errors ? "LVTextsError" : "LVTexts"
            titles = [(caption("\(list)->Column0", "№"), 130),
                      (caption("\(list)->Column1", "Текст на языке оригинала"), 380),
                      (caption("\(list)->Column2", "Текст перевода"), 380)]
        }
        for (index, item) in titles.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(index)"))
            column.title = item.0
            column.width = item.1
            table.addTableColumn(column)
        }
        table.reloadData()
    }

    private func fillLanguages() {
        languages.removeAllItems()
        for language in model.availableLanguages {
            languages.addItem(withTitle: language.displayName + "  (" + language.code + ")")
        }
        if let index = model.availableLanguages.firstIndex(where: { $0.code == model.languageCode }) {
            languages.selectItem(at: index)
        }
    }

    private func fillForms() {
        forms.removeAllItems()
        forms.addItems(withTitles: model.formNames)
        if let index = model.formNames.firstIndex(of: model.formName) { forms.selectItem(at: index) }
    }

    // MARK: - Действия панели

    @objc private func languageChanged() {
        let index = languages.indexOfSelectedItem
        guard model.availableLanguages.indices.contains(index) else { return }
        model.languageCode = model.availableLanguages[index].code
        reload()
    }

    @objc private func formChanged() {
        let index = forms.indexOfSelectedItem
        guard model.formNames.indices.contains(index) else { return }
        model.formName = model.formNames[index]
        reload()
    }

    @objc private func tabChanged() {
        let all = LocalizeTranslateModel.TextTab.allCases
        let index = max(0, min(tabs.selectedSegment, all.count - 1))
        model.tab = all[index]
        rebuildColumns()
        reload()
    }

    @objc private func copyRow() {
        guard let row = model.selectedRow else { return }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(row.caption.isEmpty ? row.originalCaption : row.caption, forType: .string)
    }

    // MARK: - Правка полей

    func controlTextDidChange(_ notification: Notification) {
        guard let key = model.selectedKey else { return }
        if notification.object as? NSTextField === captionField {
            model.setCaption(captionField.stringValue, key: key)
        } else if notification.object as? NSTextField === hintField {
            model.setHint(hintField.stringValue, key: key)
        }
        dirtyMark.stringValue = model.isDirty ? OurWords.t("не сохранено") : ""
        saveButton.isEnabled = model.isDirty
        table.reloadData()
    }

    // MARK: - Обновление

    private func reload() {
        table.reloadData()
        counter.stringValue = "\(model.rows.count)"
        dirtyMark.stringValue = model.isDirty ? OurWords.t("не сохранено") : ""
        saveButton.isEnabled = model.isDirty
        originalTitle.stringValue = caption("GroupBox1", "Тексты на языке оригинала:")
            + "  " + model.referenceName
        translationTitle.stringValue = caption("GroupBox2", "Тексты перевода:")
            + "  " + model.displayName
        syncSelection()
    }

    private func syncSelection() {
        if let key = model.selectedKey, let index = model.rows.firstIndex(where: { $0.key == key }) {
            if table.selectedRow != index {
                table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
                table.scrollRowToVisible(index)
            }
        }
        let row = model.selectedRow
        objectLine.stringValue = caption("Label1", "Объект:") + "  "
            + (row?.key ?? caption("LObjName", "Не выбран"))
        typeLine.stringValue = caption("Label2", "Тип объекта:") + "  "
            + (row?.type ?? caption("LObjType", "Не выбран"))
        originalCaption.stringValue = caption("Label3", "Заголовок:") + "  " + (row?.originalCaption ?? "")
        originalHint.stringValue = caption("Label4", "Подсказка:") + "  " + (row?.originalHint ?? "")
        captionField.stringValue = row?.caption ?? ""
        hintField.stringValue = row?.hint ?? ""
        // «Если поле не активно, значит, перевод для этого поля недоступен»
        // (14): в оригинале этого текста нет — переводить нечего. Уже
        // введённый перевод поле не запирает, иначе его нельзя было бы стереть.
        captionField.isEnabled = row.map { !$0.originalCaption.isEmpty || !$0.caption.isEmpty } ?? false
        hintField.isEnabled = model.tab == .objects
            && (row.map { !$0.originalHint.isEmpty || !$0.hint.isEmpty } ?? false)
        for button in editorButtons.prefix(2) { button.isEnabled = row != nil }
        needsLayout = true
    }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        topBar.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: 26)
        secondBar.frame = NSRect(x: gap, y: topBar.frame.maxY + 4, width: bounds.width - gap * 2, height: 26)
        tabs.frame = NSRect(x: gap, y: secondBar.frame.maxY + 6, width: 320, height: 24)
        counter.frame = NSRect(x: bounds.width - 80, y: tabs.frame.minY + 4, width: 60, height: 16)

        let editorHeight: CGFloat = 210
        scroll.frame = NSRect(x: gap, y: tabs.frame.maxY + 6, width: bounds.width - gap * 2,
                              height: max(0, bounds.height - tabs.frame.maxY - editorHeight - 18))

        var top = scroll.frame.maxY + 8
        objectLine.frame = NSRect(x: gap, y: top, width: bounds.width / 2 - gap, height: 18)
        typeLine.frame = NSRect(x: bounds.width / 2, y: top, width: bounds.width / 2 - gap, height: 18)
        for (index, button) in editorButtons.suffix(2).enumerated() {
            button.frame = NSRect(x: bounds.width - 70 + CGFloat(index) * 32, y: top - 2, width: 30, height: 22)
        }
        top += 24
        let half = (bounds.width - gap * 3) / 2
        originalTitle.frame = NSRect(x: gap, y: top, width: half, height: 16)
        translationTitle.frame = NSRect(x: gap * 2 + half, y: top, width: half, height: 16)
        top += 20
        originalCaption.frame = NSRect(x: gap, y: top, width: half, height: 20)
        captionField.frame = NSRect(x: gap * 2 + half, y: top, width: half, height: 22)
        top += 26
        originalHint.frame = NSRect(x: gap, y: top, width: half, height: 20)
        hintField.frame = NSRect(x: gap * 2 + half, y: top, width: half, height: 22)
        top += 28
        for (index, button) in editorButtons.prefix(3).enumerated() {
            button.frame = NSRect(x: gap * 2 + half + CGFloat(index) * 34, y: top, width: 30, height: 22)
        }
    }

    // MARK: - Таблица

    func numberOfRows(in tableView: NSTableView) -> Int { model.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard model.rows.indices.contains(row), let column = tableColumn else { return nil }
        let entry = model.rows[row]
        let index = table.tableColumns.firstIndex(of: column) ?? 0
        let text: String
        if model.tab == .objects {
            text = [entry.key, entry.type, entry.originalCaption, entry.originalHint,
                    entry.caption, entry.hint][min(index, 5)]
        } else {
            text = [entry.key, entry.originalCaption, entry.caption][min(index, 2)]
        }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.lineBreakMode = .byTruncatingTail
        // «Зелёная строка — перевод завершён, красная — нет» (12).
        label.textColor = entry.isDone
            ? NSColor(srgbRed: 0.05, green: 0.45, blue: 0.12, alpha: 1)
            : NSColor(srgbRed: 0.72, green: 0.12, blue: 0.12, alpha: 1)
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard model.rows.indices.contains(row) else { return }
        model.selectedKey = model.rows[row].key
        syncSelection()
    }

    // MARK: - (3) (4) Переводы

    private func addTranslation() {
        let alert = NSAlert()
        alert.messageText = caption("TextMessages5", "Создание нового перевода")
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 84))
        let name = NSTextField(frame: NSRect(x: 0, y: 56, width: 420, height: 22))
        name.placeholderString = caption("TextMessages6", "Введите язык перевода:")
        let code = NSTextField(frame: NSRect(x: 0, y: 28, width: 420, height: 22))
        code.placeholderString = caption("TextMessages7",
                                         "Введите короткое название перевода (напр. ru/en/de):")
        // Пустой перевод в оригинале начинают с копии текстов языка
        // оригинала — иначе окно открывается сплошь красным.
        let copy = NSButton(checkboxWithTitle: OurWords.t("Скопировать тексты языка оригинала"),
                            target: nil, action: nil)
        copy.frame = NSRect(x: 0, y: 0, width: 420, height: 20)
        copy.state = .on
        box.addSubview(name)
        box.addSubview(code)
        box.addSubview(copy)
        alert.accessoryView = box
        alert.addButton(withTitle: state.text("PBBOk", form: "SelectLangForm", default: "Ок"))
        alert.addButton(withTitle: state.text("PBBCancel", form: "SelectLangForm", default: "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let short = code.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let title = name.stringValue.trimmingCharacters(in: .whitespaces)
        guard !short.isEmpty, !title.isEmpty else { return }
        if InterfaceLanguageStore.isUserOwned(code: short) {
            let ask = NSAlert()
            ask.messageText = caption("TextMessages8", "Перевод")
            ask.informativeText = caption("TextMessages9", "Существует.\\nПереписать?")
                .replacingOccurrences(of: "\\n", with: "\n")
            ask.addButton(withTitle: OurWords.t("Да"))
            ask.addButton(withTitle: OurWords.t("Нет"))
            guard ask.runModal() == .alertFirstButtonReturn else { return }
        }
        model.addTranslation(name: title, code: short, copyOriginal: copy.state == .on)
        InterfaceLanguageStore.announceChange(originals: model.originals)
        fillLanguages()
        reload()
    }

    private func deleteTranslation() {
        // Отказ проверяем до вопроса: спрашивать «Удалить перевод?», чтобы
        // потом ответить «нельзя», — издевательство над оператором.
        model.activeLanguageCode = state.language?.code ?? ""
        if let refusal = model.deleteRefusal() { warn(refusal); return }

        let confirm = NSAlert()
        confirm.messageText = caption("TextMessages11", "Удаление переводов")
        confirm.informativeText = caption("TextMessages10", "Удалить перевод?")
        confirm.addButton(withTitle: OurWords.t("Да"))
        confirm.addButton(withTitle: OurWords.t("Нет"))
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        if let refusal = model.deleteTranslation() {
            warn(refusal)
        } else {
            InterfaceLanguageStore.announceChange(originals: model.originals)
            fillLanguages()
            reload()
        }
    }

    private func warn(_ refusal: LocalizeTranslateModel.DeleteRefusal) {
        let alert = NSAlert()
        alert.messageText = caption("TextMessages13", "Внимание")
        switch refusal {
        case .inUse:
            // Формулировка автора, ключ TextMessages12 формы
            // LocalizeTranslateForm. Перевод строки в файле записан «\n».
            alert.informativeText = caption("TextMessages12",
                "Нельзя удалить текущий перевод\\nСначала измените язык в главном окне программы")
                .replacingOccurrences(of: "\\n", with: "\n")
        case .notOurs:
            alert.informativeText = OurWords.t("Это перевод из комплекта программы — он только читается.") + "\n"
                + OurWords.t("Удалить можно лишь свой перевод, сохранённый в «Слове».")
        }
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
    }
}
