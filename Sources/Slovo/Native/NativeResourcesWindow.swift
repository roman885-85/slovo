import AppKit
import SlovoCore

/// Вікно «Ресурси з GitHub»: що завантажити й що оновити.
///
/// Власник: «при запуске предложить выполнить импорт или скачать из гитхаба
/// ресурсы (с выбором ресурсов)… плюс выбор откуда качать: наш ресурс или
/// переводы с гитхаба BibleQuote». Список з галочками, згрупований за родом;
/// у рядку — назва, розмір і стан: «є» (стоїть), «оновлення» (у каталозі
/// новіша версія) або порожньо. Кнопки: позначити всі нові, всі оновлення,
/// завантажити позначене. Хід — смужкою внизу; після — бібліотека
/// перечитується.
@MainActor
enum NativeResourcesWindow {

    fileprivate static var window: NSWindow?
    fileprivate static var content: NativeResourcesView?

    /// Відкрити; `updatesOnly` — одразу позначити те, що має оновлення.
    static func show(state: AppState, updatesOnly: Bool = false) {
        if let window, let content {
            content.wantsUpdatesOnly = updatesOnly
            content.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        panel.title = OurWords.t("Ресурсы с GitHub")
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 620, height: 420)
        let view = NativeResourcesView(state: state)
        view.wantsUpdatesOnly = updatesOnly
        panel.contentView = view
        panel.center()
        window = panel
        content = view
        view.reload()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension NativeResourcesWindow {
    /// Самоперевірці: скільки рядків у списку, знімок вікна, закрити.
    static var rowsForCheck: Int { content?.rowCount ?? 0 }
    static func snapshotForCheck(to name: String) -> Bool {
        guard let view = content else { return false }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        return Diagnostics.snapshot(view, to: name)
    }
    static func closeForCheck() { window?.close() }
}

@MainActor
final class NativeResourcesView: NSView, NativeListSource {

    private let state: AppState
    /// Що шукаємо: переклади, пісенники чи фони й шаблони. Власник: «не делай
    /// путаницу. переводы выбираются отдельно, песенники отдельно».
    private let kindControl = NSSegmentedControl()
    private let source = NSPopUpButton(frame: .zero, pullsDown: false)
    /// Джерела, що стоять у списку зараз (залежать від вибраного роду).
    private var shownSources: [ResourceHub.Source] = []
    /// Джерело, з якого прочитано `catalog`.
    private var loadedSource: ResourceHub.Source?
    /// Пошук у списку: назва, скорочення, мова. У MyBible — тисячі перекладів.
    private let search = NSSearchField()
    private let list = NativeTable(detailWidth: 150)
    private let status = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let takeButton: NSButton
    private let newButton: NSButton
    private let updatesButton: NSButton
    private let noneButton: NSButton
    private var hub: ResourceHub
    private var catalog: ResourceCatalog?
    private var ledger = ResourceLedger.load()
    private var chosen: Set<String> = []
    private var busy = false
    var wantsUpdatesOnly = false

    /// Рядок таблиці: заголовок роду або сам ресурс.
    private enum Line {
        case header(String)
        case item(ResourceItem)
    }
    private var lines: [Line] = []

    private var chosenSource: ResourceHub.Source {
        shownSources.indices.contains(source.indexOfSelectedItem) ? shownSources[source.indexOfSelectedItem] : .slovo
    }

    /// Роди ресурсів вибраної вкладки.
    private var chosenKinds: Set<ResourceItem.Kind> {
        switch kindControl.selectedSegment {
        case 1: return [.songbook]
        case 2: return [.backgrounds, .templates, .fonts, .web]
        default: return [.bible]
        }
    }

    /// Джерела вкладки з підписами — лише ті, що дають цей рід.
    private func fillSources() {
        let all: [(ResourceHub.Source, String)] = [
            (.slovo, OurWords.t("Ресурсы «Слова» (GitHub)")),
            (.bibleQuote, OurWords.t("Модули «Цитата из Библии» на GitHub")),
            (.myBible, OurWords.t("Реестр MyBible (переводы на многих языках)")),
            (.eBible, OurWords.t("eBible.org — свободные переводы на 1000+ языках (ставятся модулем MyBible)")),
            (.softProjector, OurWords.t("Песенники SoftProjector (softprojector.org)")),
        ]
        let kinds = chosenKinds
        let fitting = all.filter { !$0.0.kinds.isDisjoint(with: kinds) }
        shownSources = fitting.map(\.0)
        source.removeAllItems()
        source.addItems(withTitles: fitting.map(\.1))
        source.selectItem(at: 0)
    }

    init(state: AppState) {
        self.state = state
        hub = ResourceHub(layout: ResourceLayout(modulesFolder: state.modulesFolder))
        takeButton = NSButton(title: OurWords.t("Загрузить отмеченное"), target: nil, action: nil)
        newButton = NSButton(title: OurWords.t("Отметить все новые"), target: nil, action: nil)
        updatesButton = NSButton(title: OurWords.t("Отметить обновления"), target: nil, action: nil)
        noneButton = NSButton(title: OurWords.t("Снять отметки"), target: nil, action: nil)
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build() {
        kindControl.segmentCount = 3
        for (index, title) in [OurWords.t("Переводы Библии"), OurWords.t("Песенники"), OurWords.t("Фоны и шаблоны")].enumerated() {
            kindControl.setLabel(title, forSegment: index)
            kindControl.setWidth(0, forSegment: index)
        }
        kindControl.trackingMode = .selectOne
        kindControl.selectedSegment = 0
        kindControl.target = self
        kindControl.action = #selector(kindChosen)
        kindControl.toolTip = OurWords.t("Что загружать: переводы, песенники или фоны и шаблоны — у каждого свои источники")
        addSubview(kindControl)
        fillSources()
        source.target = self
        source.action = #selector(sourceChosen)
        source.toolTip = OurWords.t("Откуда загружать")
        newButton.toolTip = OurWords.t("Отметить всё, чего ещё нет на этом компьютере")
        updatesButton.toolTip = OurWords.t("Отметить установленное, у чего вышла новая версия")
        noneButton.toolTip = OurWords.t("Снять все отметки")
        takeButton.toolTip = OurWords.t("Загрузить и установить отмеченное")
        addSubview(source)
        search.placeholderString = OurWords.t("Поиск: название, сокращение или язык (uk, ru, en…)")
        search.target = self
        search.action = #selector(searchChanged)
        search.sendsSearchStringImmediately = true
        addSubview(search)

        list.source = self
        list.onLeadClick = { [weak self] index in self?.toggle(at: index) }
        list.onActivate = { [weak self] index in self?.toggle(at: index) }
        addSubview(list)

        for (button, action) in [(takeButton, #selector(take)), (newButton, #selector(markNew)),
                                 (updatesButton, #selector(markUpdates)), (noneButton, #selector(markNone))] {
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            addSubview(button)
        }
        takeButton.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        addSubview(status)
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.isHidden = true
        addSubview(bar)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 12
        let searchWidth = min(300, bounds.width * 0.38)
        kindControl.sizeToFit()
        kindControl.frame = NSRect(x: gap, y: gap, width: min(bounds.width - gap * 2, max(kindControl.frame.width, 420)), height: 26)
        let row = kindControl.frame.maxY + 8
        source.frame = NSRect(x: gap, y: row, width: bounds.width - gap * 3 - searchWidth, height: 26)
        search.frame = NSRect(x: source.frame.maxX + gap, y: row + 1, width: searchWidth, height: 24)
        let buttonsY = bounds.height - gap - 28
        var x = gap
        for button in [newButton, updatesButton, noneButton] {
            button.sizeToFit()
            button.frame = NSRect(x: x, y: buttonsY, width: button.frame.width + 12, height: 28)
            x = button.frame.maxX + 8
        }
        takeButton.sizeToFit()
        takeButton.frame = NSRect(x: bounds.width - gap - takeButton.frame.width - 16, y: buttonsY,
                                  width: takeButton.frame.width + 16, height: 28)
        bar.frame = NSRect(x: gap, y: buttonsY - 10, width: bounds.width - gap * 2, height: 6)
        status.frame = NSRect(x: gap, y: buttonsY - 30, width: bounds.width - gap * 2, height: 16)
        list.frame = NSRect(x: gap, y: source.frame.maxY + gap,
                            width: bounds.width - gap * 2, height: max(0, status.frame.minY - gap - source.frame.maxY - gap))
    }

    // MARK: - Каталог

    func reload() {
        hub = ResourceHub(layout: ResourceLayout(modulesFolder: state.modulesFolder))
        ledger = ResourceLedger.load()
        catalog = nil
        lines = []
        chosen = []
        list.reload()
        status.stringValue = OurWords.t("Читаю каталог…")
        let picked = chosenSource
        loadedSource = nil
        hub.fetchCatalog(picked) { [weak self] result in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.chosenSource == picked else { return }
                    switch result {
                    case .failure(let error):
                        self.status.stringValue = OurWords.t("Каталог не прочитался: %s", "\(error)")
                    case .success(let catalog):
                        self.catalog = catalog
                        self.loadedSource = picked
                        // «Перевірити оновлення ресурсів»: відкриваємо ту вкладку,
                        // де оновлення справді є (часто це пісенники).
                        if self.wantsUpdatesOnly, picked == .slovo {
                            let outdated = catalog.items.filter { self.standing(of: $0) == .outdated }
                            let tabs: [Set<ResourceItem.Kind>] = [[.bible], [.songbook], [.backgrounds, .templates, .fonts, .web]]
                            if !outdated.contains(where: { self.chosenKinds.contains($0.kind) }),
                               let tab = tabs.firstIndex(where: { kinds in outdated.contains { kinds.contains($0.kind) } }) {
                                self.kindControl.selectedSegment = tab
                            }
                        }
                        self.rebuildLines()
                        if self.wantsUpdatesOnly { self.markUpdates() } else { self.summarize() }
                    }
                }
            }
        }
    }

    @objc private func sourceChosen() { reload() }

    @objc private func kindChosen() {
        fillSources()
        search.stringValue = ""
        chosen = []
        // Свій каталог уже прочитано — для іншої вкладки перечитувати нема чого.
        if loadedSource == .slovo, chosenSource == .slovo, catalog != nil {
            rebuildLines()
            summarize()
        } else {
            reload()
        }
    }

    @objc private func searchChanged() { rebuildLines() }

    private func rebuildLines() {
        guard let catalog else { lines = []; list.reload(); return }
        let order: [ResourceItem.Kind] = [.bible, .songbook, .backgrounds, .templates, .fonts, .web]
        let titles: [ResourceItem.Kind: String] = [
            .bible: OurWords.t("Переводы Библии"), .songbook: OurWords.t("Песенники"),
            .backgrounds: OurWords.t("Фоны"), .templates: OurWords.t("Шаблоны слайдов"),
            .fonts: OurWords.t("Шрифты"), .web: OurWords.t("Страницы веб-слайдов"),
        ]
        let query = search.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        let kindsShown = chosenKinds
        // Код мови («uk», «ru», «en») — лише ця мова: інакше «uk» знаходило й
        // «Luke», «UKJV» — сотню чужих перекладів.
        let isLanguage = !query.isEmpty && catalog.items.contains { $0.language?.lowercased() == query }
        let visible = catalog.items.filter { item in
            guard kindsShown.contains(item.kind) else { return false }
            if query.isEmpty { return true }
            if isLanguage { return item.language?.lowercased() == query }
            return item.title.lowercased().contains(query) || item.subtitle.lowercased().contains(query)
        }
        var built: [Line] = []
        if kindsShown.isSubset(of: [.bible, .songbook]), visible.contains(where: { $0.language != nil }) {
            // Список із мовами (MyBible) — за мовами: спершу мова інтерфейсу,
            // далі українська, російська, англійська, решта за абеткою.
            let preferred = [OurWords.language, "uk", "ru", "en"]
            let groups = Dictionary(grouping: visible) { $0.language ?? "—" }
            let keys = groups.keys.sorted { a, b in
                let ia = preferred.firstIndex(of: a) ?? Int.max, ib = preferred.firstIndex(of: b) ?? Int.max
                return ia != ib ? ia < ib : a < b
            }
            for key in keys {
                let items = (groups[key] ?? []).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                built.append(.header("\(OurWords.t("Язык")) \(key)  ·  \(items.count)"))
                built.append(contentsOf: items.map(Line.item))
            }
        } else {
            for kind in order {
                let items = visible.filter { $0.kind == kind }
                    .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
                guard !items.isEmpty else { continue }
                built.append(.header("\(titles[kind] ?? kind.rawValue)  ·  \(items.count)"))
                built.append(contentsOf: items.map(Line.item))
            }
        }
        lines = built
        list.reload()
    }

    /// Стан ресурсу: стоїть, є оновлення чи нема.
    private enum Standing { case absent, installed, outdated }

    private func standing(of item: ResourceItem) -> Standing {
        let present = hub.layout.isPresent(item)
        guard present else { return .absent }
        if let known = ledger.installed[item.id], !item.version.isEmpty, known != item.version { return .outdated }
        return .installed
    }

    private func summarize() {
        guard let catalog else { return }
        let kinds = chosenKinds
        let items = catalog.items.filter { kinds.contains($0.kind) }
        let absent = items.filter { standing(of: $0) == .absent }.count
        let outdated = items.filter { standing(of: $0) == .outdated }.count
        let size = catalog.items.filter { chosen.contains($0.id) }.reduce(Int64(0)) { $0 + $1.size }
        status.stringValue = OurWords.t("Ресурсов %s; ещё не установлено %s, обновлений %s; отмечено %s (%s)",
                                        "\(items.count)", "\(absent)", "\(outdated)", "\(chosen.count)", Self.megabytes(size))
    }

    private static func megabytes(_ bytes: Int64) -> String {
        bytes <= 0 ? "—" : String(format: "%.1f МБ", Double(bytes) / 1_048_576)
    }

    // MARK: - Позначки

    private func toggle(at index: Int) {
        guard lines.indices.contains(index), case .item(let item) = lines[index] else { return }
        if chosen.contains(item.id) { chosen.remove(item.id) } else { chosen.insert(item.id) }
        list.reload()
        summarize()
    }

    /// Те, що видно в списку після пошуку: позначки діють на нього, а не на
    /// весь каталог — у MyBible тисячі перекладів, і «Позначити всі нові»
    /// без пошуку поставило б їх усі.
    private var visibleItems: [ResourceItem] {
        lines.compactMap { if case .item(let item) = $0 { return item } else { return nil } }
    }

    @objc private func markNew() {
        chosen = Set(visibleItems.filter { standing(of: $0) == .absent }.map(\.id))
        list.reload(); summarize()
    }

    @objc private func markUpdates() {
        chosen = Set(visibleItems.filter { standing(of: $0) == .outdated }.map(\.id))
        list.reload(); summarize()
    }

    @objc private func markNone() {
        chosen = []
        list.reload(); summarize()
    }

    /// Самоперевірці й стартовому вікну: позначити за ідентифікаторами.
    func choose(ids: [String]) {
        chosen = Set(ids)
        list.reload(); summarize()
    }

    // MARK: - Завантаження

    @objc private func take() {
        guard !busy, let catalog else { return }
        let items = catalog.items.filter { chosen.contains($0.id) }
        guard !items.isEmpty else { status.stringValue = OurWords.t("Ничего не отмечено"); return }
        busy = true
        takeButton.isEnabled = false
        source.isEnabled = false
        kindControl.isEnabled = false
        bar.isHidden = false
        bar.doubleValue = 0
        install(items)
    }

    func install(_ items: [ResourceItem], completion: (@MainActor (ResourceHub.Outcome) -> Void)? = nil) {
        hub.install(items, progress: { [weak self] progress in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let step = 1.0 / Double(max(progress.total, 1))
                    self.bar.doubleValue = Double(progress.index) * step + (progress.fraction ?? 0) * step
                    self.status.stringValue = OurWords.t("Загружаю %s из %s: %s", "\(progress.index + 1)", "\(progress.total)", progress.item.title)
                }
            }
        }, completion: { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.busy = false
                    self.takeButton.isEnabled = true
                    self.source.isEnabled = true
                    self.kindControl.isEnabled = true
                    self.bar.isHidden = true
                    self.ledger = ResourceLedger.load()
                    self.chosen = []
                    self.list.reload()
                    var text = OurWords.t("Установлено: %s", "\(outcome.installed.count)")
                    if !outcome.failures.isEmpty {
                        text += "; " + OurWords.t("не удалось: %s", outcome.failures.map { "\($0.0.title) — \($0.1)" }.joined(separator: "; "))
                    }
                    self.status.stringValue = text
                    NativeTrace.say("ресурси: " + text)
                    if !outcome.installed.isEmpty { self.state.reloadLibrary() }
                    completion?(outcome)
                }
            }
        })
    }

    // MARK: - NativeListSource

    var rowCount: Int { lines.count }

    func row(at index: Int) -> NativeRow {
        var row = NativeRow()
        guard lines.indices.contains(index) else { return row }
        switch lines[index] {
        case .header(let title):
            row.text = title.uppercased()
            row.textColor = .secondaryLabelColor
        case .item(let item):
            row.lead = chosen.contains(item.id) ? "☑" : "☐"
            row.text = item.title + (item.subtitle.isEmpty ? "" : "  (" + item.subtitle + ")")
            let mark: String
            switch standing(of: item) {
            case .absent:    mark = ""
            case .installed: mark = OurWords.t("есть")
            case .outdated:  mark = OurWords.t("обновление")
            }
            row.detail = [Self.megabytes(item.size), mark].filter { $0 != "—" && !$0.isEmpty }.joined(separator: " · ")
        }
        return row
    }
}
