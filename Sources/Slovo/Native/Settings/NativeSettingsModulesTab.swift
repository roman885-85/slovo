import AppKit
import SlovoCore

/// 6.1.4 «Модули» на AppKit.
///
/// Список всех модулей Библии и песенников, которыми пользуется программа.
/// Галочка — включённость, порядок строк — порядок вкладок переводов в
/// главном окне. И то, и другое в оригинале хранится в секции `[BiblePath]`:
/// `0="Modules\rst+\"|1`.
///
/// Галочку ставят двойным щелчком по строке: колонки с флажком у нашего
/// списка нет, а признак этот меняют чаще всего.
@MainActor
final class NativeSettingsModulesTab: NSObject, NativeListSource {

    private let state: AppState
    private let store: SettingsStore
    private let list = NativeTable(detailWidth: 220)
    private let status = NativeForm.label("")
    private var selected: Int?

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
        super.init()
        list.source = self
        list.onSelect = { [weak self] _, active, _ in self?.selected = active }
        list.onActivate = { [weak self] index in self?.toggle(at: index) }
        list.onLeadClick = { [weak self] index in self?.toggle(at: index) }
    }

    var page: NSView { NativeForm.Page([modules, loading]) }

    // MARK: Список и кнопки

    private var modules: NativeForm.Group {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 260))
        list.frame = box.bounds
        list.autoresizingMask = [.width, .height]
        box.addSubview(list)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 260).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.spacing = 4
        // (26)…(30) — тот же порядок, что у автора.
        buttons.addArrangedSubview(NativeForm.button("+", hint: state.vbHint("SBAddBiblePath",
                                                     "Добавить путь... (Ins)")) { [weak self] in self?.addModule() })
        buttons.addArrangedSubview(NativeForm.button("−", hint: state.vbHint("SBDelBiblePath",
                                                     "Удалить путь... (Del)")) { [weak self] in self?.remove() })
        buttons.addArrangedSubview(NativeForm.button("↑", hint: state.vbHint("SBUpBiblePath",
                                                     "Переместить выше")) { [weak self] in self?.move(by: -1) })
        buttons.addArrangedSubview(NativeForm.button("↓", hint: state.vbHint("SBDownBiblePath",
                                                     "Переместить ниже")) { [weak self] in self?.move(by: 1) })
        buttons.addArrangedSubview(NativeForm.button("🔍", hint: state.vbHint("SBSearchTexts",
                                                     "Найти совместимые тексты")) { [weak self] in self?.search() })
        buttons.addArrangedSubview(NativeForm.button("⤓", hint: state.vbHint("SBImportModules",
                                                     "Импорт модулей...")) { [weak self] in self?.importModule() })

        return NativeForm.Group(state.vb("Label1", "Текстовые модули:"), [
            NativeForm.Row("", [
                NativeForm.button(state.vbHint("SBCheckAll", "Пометить все"), hint: nil) { [weak self] in
                    self?.store.setAllModules(enabled: true); self?.list.reload()
                },
                NativeForm.button(state.vbHint("SBUnCheckAll", "Снять пометку со всех"), hint: nil) { [weak self] in
                    self?.store.setAllModules(enabled: false); self?.list.reload()
                },
                status,
            ]),
            NativeForm.Row("", stretch: true, [box, buttons]),
        ])
    }

    private var loading: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBLoadAllBooks", "Загружать Тексты в память"),
                                 NativeForm.Tie(get: { [store] in store.settings.options.loadAllBooks },
                                                set: { [store] in store.settings.options.loadAllBooks = $0 })),
                NativeForm.check(state.vb("CBLazyLoad", "Отложенная загрузка модулей"),
                                 NativeForm.Tie(get: { [store] in store.settings.options.lazyLoadModules },
                                                set: { [store] in store.settings.options.lazyLoadModules = $0 })),
            ]),
        ])
    }

    // MARK: - Действия

    private func toggle(at index: Int) {
        let list = rows
        guard list.indices.contains(index) else { return }
        store.setModule(list[index].id, enabled: !list[index].isEnabled)
        self.list.reload()
    }

    private func remove() {
        guard let index = selected, rows.indices.contains(index) else { return }
        store.removeModule(rows[index].id)
        selected = nil
        list.reload()
    }

    private func move(by delta: Int) {
        guard let index = selected, rows.indices.contains(index) else { return }
        _ = store.moveModule(rows[index].id, by: delta)
        let next = min(max(0, index + delta), max(0, rows.count - 1))
        selected = next
        list.reload()
        list.setSelection(IndexSet(integer: next), active: next)
    }

    /// (26) Добавление модуля в список.
    ///
    /// Молча положить в список любую папку нельзя: строка «Индекс: Нет»
    /// никогда не откроется. У автора на этот случай заготовлено
    /// TextMessages6, его и показываем.
    private func addModule() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = state.vb("BBOk", "Ок")
        panel.message = state.vb("TextMessages5", "Выберите каталог текстов Библии")
        guard panel.runModal() == .OK else { return }
        add(panel.urls, title: state.vb("TextMessages24", "Внимание"))
    }

    /// (30) Импорт модулей MyBible и MySword. Файл базы подключаем там, где
    /// он лежит: копировать чужие модули в чужую же папку с данными — это
    /// уже не настройка, и делать это без спроса нельзя.
    private func importModule() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = state.vb("BBOk", "Ок")
        panel.message = state.vb("NImportFromMyBible", "Импортировать из MyBible модуля")
            + " / " + state.vb("NImportFromMySword", "Импортировать из MySword модуля")
        guard panel.runModal() == .OK else { return }
        add(panel.urls, title: state.vb("TextMessages27", "Импорт модуля"))
    }

    /// Добавляет всё, что подходит, а про первую неудачу говорит словами
    /// автора. Одно сообщение, а не по одному на файл: очередь из пяти окон
    /// подряд посреди служения хуже, чем одно.
    private func add(_ urls: [URL], title: String) {
        var problem: (SettingsStore.ModuleProblem, URL)?
        for url in urls {
            // Повтор пути — не ошибка: строка в списке уже есть.
            guard let reason = store.addModule(at: url), reason != .alreadyListed else { continue }
            if problem == nil { problem = (reason, url) }
        }
        list.reload()
        guard let (reason, url) = problem else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message(for: reason, url: url)
        alert.addButton(withTitle: state.vb("BBOk", "Ок"))
        alert.runModal()
    }

    private func message(for problem: SettingsStore.ModuleProblem, url: URL) -> String {
        switch problem {
        case .notBibleQuote:
            return state.vb("TextMessages6",
                            "В выбранном каталоге не найдены тексты формата \"Цитаты из Библии\"\n"
                            + "(не найден файл \"BibleQuote.ini\")\nВоспользуйтесь \"Поиском текстов\".")
        case .mySword:
            // TextMessages38 «Не поддерживается»: сам перевод MySword
            // программа открывает, а это его спутник — комментарий, словарь
            // или заметки. Стихов в нём нет.
            return "\(url.lastPathComponent)\n" + state.vb("TextMessages38", "Не поддерживается")
        case .unknownFormat, .alreadyListed:
            return "\(url.lastPathComponent)\n" + state.vb("TextMessages28", "Не удается открыть модуль")
        }
    }

    /// (29) Автоматический поиск совместимых модулей на компьютере.
    private func search() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = state.vb("TextMessages11", "Поиск")
        panel.message = state.vb("TextMessages10", "Произвести поиск текстов формата \"Цитата из Библии\"?")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.searchTexts(in: url)
        status.stringValue = state.vb("Label13", "Папка:") + " " + url.path

        // Ждём окончания обхода и только потом спрашиваем, что делать с
        // находками, — иначе вопрос выскочит на пустом списке.
        Task { [weak self] in
            guard let self else { return }
            while self.store.isSearching {
                self.status.stringValue = self.state.vb("Label14", "Просмотрено папок:")
                    + " \(self.store.scannedFolders)  "
                    + self.state.vb("Label15", "Найдено текстов:") + " \(self.store.foundTexts.count)"
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            self.status.stringValue = self.state.vb("Label15", "Найдено текстов:")
                + " \(self.store.foundTexts.count)"
            guard !self.store.foundTexts.isEmpty else { return }
            // TextMessages13: «Да» — заменить список, «Нет» — добавить к нему.
            let alert = NSAlert()
            alert.messageText = self.state.vb("TextMessages11", "Поиск")
            alert.informativeText = "\(self.state.vb("TextMessages12", "Найдено")) "
                + "\(self.store.foundTexts.count)\n"
                + self.state.vb("TextMessages13", "текстов формата \"Цитата из Библии\".\nЗаменить список?")
            alert.addButton(withTitle: self.state.yesCaption)
            alert.addButton(withTitle: self.state.noCaption)
            alert.addButton(withTitle: self.state.vb("BBCancel", "Отмена"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:  self.store.applyFoundTexts(replacing: true)
            case .alertSecondButtonReturn: self.store.applyFoundTexts(replacing: false)
            default: break
            }
            self.list.reload()
        }
    }

    // MARK: - Строки

    /// Название и сокращение подставляем из уже открытой библиотеки: в
    /// `[BiblePath]` лежит только путь, а человек ищет строку по названию
    /// перевода. Чего в библиотеке нет — показываем именем папки и «Индекс:
    /// Нет»: это и есть признак, что модуль не открылся.
    private var rows: [SettingsModuleRow] {
        store.settings.modules.map { entry in
            let key = entry.libraryIdentifier.lowercased()
            if let module = state.allModules.first(where: { $0.identifier.lowercased() == key }) {
                return SettingsModuleRow(id: entry.id, name: entry.name,
                                         title: module.info.name.isEmpty ? entry.name : module.info.name,
                                         shortName: module.info.shortName,
                                         hasIndex: true, isEnabled: entry.isEnabled,
                                         isSongBook: false, isDatabase: module.format != .bibleQuote,
                                         path: entry.path)
            }
            // Здесь именно весь каталог: выключенная строка обязана остаться
            // с названием и сокращением, иначе снятая галочка превращала бы
            // сборник в безымянный «Индекс: Нет».
            if let book = state.allSongBooks.first(where: { $0.url.lastPathComponent.lowercased() == key }) {
                return SettingsModuleRow(id: entry.id, name: entry.name,
                                         title: book.displayName, shortName: book.shortName,
                                         hasIndex: true, isEnabled: entry.isEnabled,
                                         isSongBook: true, isDatabase: false, path: entry.path)
            }
            return SettingsModuleRow(id: entry.id, name: entry.name, title: entry.name, shortName: "",
                                     hasIndex: false, isEnabled: entry.isEnabled,
                                     isSongBook: entry.isSongBook, isDatabase: false, path: entry.path)
        }
    }

    var rowCount: Int { rows.count }

    func row(at index: Int) -> NativeRow {
        let entry = rows[index]
        var row = NativeRow()
        // Флажок, как у автора: один щелчок по нему включает и выключает.
        row.lead = entry.isEnabled ? "☑" : "☐"
        // Значок формата — как разные картинки у автора: папка «Цитаты из
        // Библии», база (MyBible или MySword) или песенник.
        // Значок вида — в первой колонке его место занимает галочка, а
        // песенник и база и так видны по папке в правой колонке.
        row.text = entry.title
            + (entry.shortName.isEmpty ? "" : "  (" + entry.shortName + ")")
            + (entry.hasIndex ? "" : "  · " + state.vb("TextMessages8", "Нет"))
        row.detail = entry.path
        return row
    }
}
