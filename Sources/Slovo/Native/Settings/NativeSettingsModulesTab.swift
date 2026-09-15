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
final class NativeSettingsModulesTab: NSObject, NativeListSource, NativeSettingsRows {


    private let state: AppState
    private let store: SettingsStore
    private let list = NativeTable(detailWidth: 220)
    private let status = NativeForm.label("")
    private var selected: Int?
    /// Два окремі списки — переклади Біблії та пісенники; перемикач над
    /// списком. Власник: «в настройках модули переводов и песенников должны
    /// быть разделены, чтобы не путаться в них».
    private let kinds = NSSegmentedControl(labels: ["", ""], trackingMode: .selectOne, target: nil, action: nil)
    private(set) var showsSongBooks = false

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
        super.init()
        list.source = self
        list.onSelect = { [weak self] _, active, _ in self?.selected = active }
        list.onActivate = { [weak self] index in self?.toggle(at: index) }
        list.onLeadClick = { [weak self] index in self?.toggle(at: index) }
        kinds.target = self
        kinds.action = #selector(kindChosen)
        kinds.toolTip = OurWords.t("Какой список показать: переводы Библии или песенники")
        kinds.selectedSegment = 0
        kinds.segmentStyle = .texturedRounded
        // Підписи — одразу: доти вони ставилися лише після першого
        // перечитування списку, і перемикач стояв порожнім клаптиком.
        refreshKinds()
    }

    @objc private func kindChosen() {
        showsSongBooks = kinds.selectedSegment == 1
        selected = nil
        refreshList()
    }

    /// Самоперевірці: відкрити список перекладів або пісенників.
    func showForCheck(songBooks: Bool) {
        kinds.selectedSegment = songBooks ? 1 : 0
        kindChosen()
    }

    /// Самоперевірці: якого роду кожен рядок відкритого списку.
    var rowKindsForCheck: [Bool] {
        lines.compactMap { if case .module(let entry) = $0 { return entry.isSongBook } else { return nil } }
    }

    /// Підписи перемикача з лічильниками: «Переклади Біблії · 57».
    private func refreshKinds() {
        let all = rows
        let bibles = all.filter { !$0.isSongBook }
        let songs = all.filter { $0.isSongBook }
        kinds.setLabel(OurWords.t("Переводы Библии") + " · \(bibles.count)", forSegment: 0)
        kinds.setLabel(OurWords.t("Песенники") + " · \(songs.count)", forSegment: 1)
        kinds.setWidth(0, forSegment: 0)
        kinds.setWidth(0, forSegment: 1)
        kinds.sizeToFit()
        kinds.invalidateIntrinsicContentSize()
        let shown = showsSongBooks ? songs : bibles
        status.stringValue = "\(OurWords.t("включено")) \(shown.filter(\.isEnabled).count) \(OurWords.t("из")) \(shown.count)"
    }

    var page: NSView { NativeForm.Page([modules, loading]) }

    // MARK: Список и кнопки

    private var modules: NativeForm.Group {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        list.frame = box.bounds
        list.autoresizingMask = [.width, .height]
        box.addSubview(list)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 420).isActive = true

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

        return NativeForm.Group(state.vb("Label1", OurWords.t("Текстовые модули:")), [
            NativeForm.Row("", [kinds]),
            NativeForm.Row("", [
                NativeForm.button(state.vbHint("SBCheckAll", OurWords.t("Пометить все")),
                                  hint: OurWords.t("Включить все модули открытого списка")) { [weak self] in
                    self?.setShownSection(enabled: true)
                },
                NativeForm.button(state.vbHint("SBUnCheckAll", OurWords.t("Снять пометку со всех")),
                                  hint: OurWords.t("Выключить все модули открытого списка")) { [weak self] in
                    self?.setShownSection(enabled: false)
                },
                status,
            ]),
            NativeForm.Row("", stretch: true, [box, buttons]),
            NativeForm.Row("", stretch: true, [
                NativeForm.label(OurWords.t("Галочка слева включает модуль: перевод встаёт на полосу переводов, песенник — в список песенников."),
                                 secondary: true),
            ]),
            NativeForm.Row("", stretch: true, [
                NativeForm.label(OurWords.t("Видно сразу, «Ок» только запоминает. «Пометить все» и «Снять пометку» действуют на открытый список — переводы или песенники."),
                                 secondary: true),
            ]),
        ])
    }

    private var loading: NativeForm.Group {
        NativeForm.Group("", [
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBLoadAllBooks", OurWords.t("Загружать Тексты в память")),
                                 NativeForm.Tie(get: { [store] in store.settings.options.loadAllBooks },
                                                set: { [store] in store.settings.options.loadAllBooks = $0 }),
                                 hint: OurWords.t("Держать тексты модулей в памяти целиком: переходы быстрее, памяти нужно больше")),
                NativeForm.check(state.vb("CBLazyLoad", OurWords.t("Отложенная загрузка модулей")),
                                 NativeForm.Tie(get: { [store] in store.settings.options.lazyLoadModules },
                                                set: { [store] in store.settings.options.lazyLoadModules = $0 }),
                                 hint: OurWords.t("Читать модуль только тогда, когда его открыли: быстрее запуск")),
            ]),
        ])
    }

    // MARK: - Действия

    /// Галочка діє одразу, а не по «Ок».
    ///
    /// Власник: «при відключенні або включенні модуля в програмі нічого не
    /// відбувається». Відбувалося — але тільки після «Ок», а стоячи у
    /// «Параметрах», побачити це було нічим. Тепер смуга перекладів і список
    /// пісенників міняються під вікном тієї ж миті; «Відмінити» поверне їх.
    private func toggle(at index: Int) {
        if case .header(_, let songBooks)? = line(at: index) {
            toggleSection(songBooks: songBooks)
            return
        }
        guard case .module(let entry)? = line(at: index) else { return }
        store.setModule(entry.id, enabled: !entry.isEnabled)
        refreshList()
        state.applyModuleRoster(store.settings.modules)
    }

    /// «Позначити все» / «Зняти позначку» — лише для відкритого списку.
    private func setShownSection(enabled: Bool) {
        for item in rows where item.isSongBook == showsSongBooks { store.setModule(item.id, enabled: enabled) }
        refreshList()
        state.applyModuleRoster(store.settings.modules)
    }

    /// Увімкнути або вимкнути весь розділ — клацанням по його заголовку.
    private func toggleSection(songBooks: Bool) {
        let items = rows.filter { $0.isSongBook == songBooks }
        guard !items.isEmpty else { return }
        // Хоч один вимкнений — умикаємо всі; усі ввімкнені — вимикаємо.
        let enable = items.contains { !$0.isEnabled }
        for item in items { store.setModule(item.id, enabled: enable) }
        refreshList()
        state.applyModuleRoster(store.settings.modules)
    }

    private func remove() {
        guard case .module(let entry)? = line(at: selected) else { return }
        store.removeModule(entry.id)
        selected = nil
        refreshList()
        state.applyModuleRoster(store.settings.modules)
    }

    /// «↑» і «↓» переставляють рядок у своєму розділі: порядок перекладів —
    /// це порядок вкладок на смузі, і заголовок розділу перестрибувати нікуди.
    private func move(by delta: Int) {
        guard let index = selected, case .module(let entry)? = line(at: index),
              case .module(let neighbour)? = line(at: index + delta),
              neighbour.isSongBook == entry.isSongBook else { return }
        store.swapModules(entry.id, neighbour.id)
        let next = index + delta
        selected = next
        refreshList()
        list.setSelection(IndexSet(integer: next), active: next)
        state.applyModuleRoster(store.settings.modules)
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
            + " (.SQLite3, .sqlite, .bbl.mybible)"
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
        refreshList()
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
            self.refreshList()
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
            // Пісенник — за ім'ям файла або за основою: у розписі «pv3055.vbm»,
            // а збірник уже «pv3055.songbook».
            let stem = (key as NSString).deletingPathExtension
            if let book = state.allSongBooks.first(where: {
                $0.url.lastPathComponent.lowercased() == key || $0.id.lowercased() == stem
            }) {
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

    /// Рядок списку: заголовок розділу або сам модуль.
    ///
    /// Власник: «у налаштуваннях модулів немає поділу на пісенники й біблії».
    /// В автора поділу немає — усі рядки впереміш, — але шукати пісенник серед
    /// шістдесяти перекладів у такому списку неможливо.
    private enum Line {
        case header(title: String, songBooks: Bool)
        case module(SettingsModuleRow)
    }

    /// Зібрані рядки тримаємо до наступного перечитування: інакше кожен
    /// рядок таблиці заново перебирав увесь розпис і всю бібліотеку — на
    /// сімдесяти модулях це вже помітно.
    private var lineCache: [Line]?

    private var lines: [Line] {
        if let lineCache { return lineCache }
        let built = buildLines()
        lineCache = built
        return built
    }

    /// Перебудувати список і перемалювати таблицю.
    private func refreshList() {
        lineCache = nil
        refreshKinds()
        list.reload()
    }

    /// Перечитати свій список — після скидання або ввезення налаштувань.
    func reloadRows() { refreshList() }

    private func buildLines() -> [Line] {
        // Лише відкритий список: переклади або пісенники, без заголовків —
        // рід видно з перемикача над списком.
        rows.filter { $0.isSongBook == showsSongBooks }.map(Line.module)
    }

    private func heading(_ title: String, _ items: [SettingsModuleRow]) -> String {
        let on = items.filter(\.isEnabled).count
        return "\(title.uppercased())  ·  \(OurWords.t("включено")) \(on) \(OurWords.t("из")) \(items.count)"
    }

    private func line(at index: Int?) -> Line? {
        guard let index, lines.indices.contains(index) else { return nil }
        return lines[index]
    }

    var rowCount: Int { lines.count }

    func row(at index: Int) -> NativeRow {
        var row = NativeRow()
        guard let line = line(at: index) else { return row }
        guard case .module(let entry) = line else {
            if case .header(let title, _) = line {
                row.text = title
                row.textColor = .secondaryLabelColor
            }
            return row
        }
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
