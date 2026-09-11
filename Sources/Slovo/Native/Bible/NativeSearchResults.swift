import AppKit
import SlovoCore

/// Віртуальний список рядків із різнокольоровими шматками.
///
/// Навіщо свій, а не `NativeList`. У `NativeRow` колір один на весь текст, і це
/// правильно для книг, розділів і віршів. А рядок результату пошуку на знімку
/// посібника пофарбовано всередині: «Иоан. 5:24 - Истинно, истинно говорю вам:
/// слушающий…», де знайдені слова червоні. Класти в спільний рядок списку
/// розмітку заради одного вікна — значить здорожчити всі інші списки; простіше
/// тримати тут маленький список на п'ять десятків рядків, який уміє рівно
/// одне: намалювати готовий `NSAttributedString`.
///
/// Віртуальність та сама: рядків живе стільки, скільки видно, а рядок будується
/// в ту мить, коли показався.
@MainActor
final class NativeAttributedList: NSView {

    var rowCount: () -> Int = { 0 }
    var attributed: (Int) -> NSAttributedString = { _ in NSAttributedString() }
    var isSelected: (Int) -> Bool = { _ in false }
    var onSelect: ((Int) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    var rowHeight: CGFloat = 20 {
        didSet { table.rowHeight = rowHeight }
    }

    private let scroll = NSScrollView()
    private let table: Table
    private let bridge = Bridge()

    override init(frame frameRect: NSRect) {
        table = Table()
        super.init(frame: frameRect)
        bridge.list = self
        table.owner = self

        let column = NSTableColumn(identifier: .init("line"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = rowHeight
        table.gridStyleMask = []
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.allowsMultipleSelection = false
        table.intercellSpacing = .zero
        table.backgroundColor = .textBackgroundColor
        table.dataSource = bridge
        table.delegate = bridge

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.backgroundColor = .textBackgroundColor
        scroll.autoresizingMask = [.width, .height]
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override func layout() {
        scroll.frame = bounds
        super.layout()
    }

    func reload() { table.reloadData() }

    /// Перемалювати лише видимі рядки: змінився вибір, а не склад.
    func refreshVisible() {
        let rows = table.rows(in: scroll.contentView.bounds)
        guard rows.length > 0 else { return }
        for row in rows.location..<(rows.location + rows.length) {
            guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? Cell
            else { continue }
            cell.line = attributed(row)
            cell.selected = isSelected(row)
            cell.needsDisplay = true
        }
    }

    fileprivate func clicked(_ event: NSEvent) {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, row < rowCount() else { return }
        if event.clickCount >= 2 { onActivate?(row) } else { onSelect?(row) }
    }

    fileprivate func contextMenu(for event: NSEvent) -> NSMenu? {
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard row >= 0, row < rowCount() else { return nil }
        return onContextMenu?(row)
    }

    // MARK: - Міст

    private final class Bridge: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        weak var list: NativeAttributedList?

        func numberOfRows(in tableView: NSTableView) -> Int { list?.rowCount() ?? 0 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard let list else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("line")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? Cell) ?? {
                let fresh = Cell()
                fresh.identifier = identifier
                return fresh
            }()
            cell.line = list.attributed(row)
            cell.selected = list.isSelected(row)
            return cell
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }
    }

    private final class Table: NSTableView {
        weak var owner: NativeAttributedList?
        override func mouseDown(with event: NSEvent) { owner?.clicked(event) }
        override func rightMouseDown(with event: NSEvent) {
            guard let menu = owner?.contextMenu(for: event) else { return }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }

    /// Рядок: одне малювання готового розміченого рядка, підвидів усередині немає.
    private final class Cell: NSView {
        var line = NSAttributedString()
        var selected = false
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            if selected {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                bounds.fill()
                // Вибраний рядок цілком білий: червоне на підсвічуванні не
                // читається, і в оригіналі виділений рядок теж одноколірний.
                let white = NSMutableAttributedString(attributedString: line)
                white.addAttribute(.foregroundColor, value: NSColor.white,
                                   range: NSRange(location: 0, length: white.length))
                draw(white)
                return
            }
            draw(line)
        }

        private func draw(_ string: NSAttributedString) {
            let height = string.size().height
            string.draw(with: NSRect(x: 8, y: (bounds.height - height) / 2,
                                     width: max(0, bounds.width - 16), height: height),
                        options: [.usesLineFragmentOrigin])
        }
    }
}

// MARK: - Вікно результатів пошуку (5)

/// Вікно результатів пошуку (5) — розділ 5.1.5.
///
/// Шапка «Знайдено: (7 збігів)», смуга побудови пошукового ходу і
/// хрестик; нижче — сам список. З'являється вікно лише за трьома приводами:
/// набрали рядок пошуку, натиснули Ctrl+F3 або кнопку (6.1) — за це відповідає
/// `DeskModel.isSearchResultsShown`, а не цей вид.
@MainActor
final class NativeSearchResultsPane: NSView {

    private let caption = NativeCaption()
    private let count = NativeCaption()
    private let progress = NSProgressIndicator()
    private let progressCaption = NativeCaption()
    private let close: NativeIconButton
    private let list = NativeAttributedList()
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []
    /// Рядки пошуку, приготовані до показу. Перезбираються лише коли
    /// приходить інший набір знайденого.
    private var lines: [NSAttributedString] = []

    init(state: AppState) {
        self.state = state
        close = NativeIconButton(symbol: "xmark",
                                 hint: state.hint("SBHideSearchResult",
                                                  default: "Скрыть окно результатов поиска")) {
            DeskModel.shared.isSearchResultsShown = false
            NativeBibleBridge.shared.sync()
        }
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor

        count.weight = .semibold
        count.color = .labelColor
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.isHidden = true
        progressCaption.text = state.text("Label3D12", default: "Идет построение поискового  индекса...")

        addSubview(caption)
        addSubview(count)
        addSubview(progress)
        addSubview(progressCaption)
        addSubview(close)
        addSubview(list)

        list.rowCount = { [weak self] in self?.lines.count ?? 0 }
        list.attributed = { [weak self] index in
            guard let self, self.lines.indices.contains(index) else { return NSAttributedString() }
            return self.lines[index]
        }
        list.isSelected = { [weak self] index in self?.isCurrent(index) ?? false }
        list.onSelect = { [weak self] index in self?.show(index, live: false) }
        list.onActivate = { [weak self] index in self?.show(index, live: true) }
        list.onContextMenu = { [weak self] index in self?.menu(index) }

        applyCaptions()
        rebuild()

        tokens.append(Signals.shared.subscribe(.searchResults) { [weak self] in
            self?.rebuild()
        })
        tokens.append(Signals.shared.subscribe([.verseSelection, .songSelection, .songPart]) { [weak self] _ in
            self?.list.refreshVisible()
        })
        // Змінили вкладку — набране слово шукається заново, уже за нею:
        // на Біблії вірші, на Піснях пісні.
        tokens.append(Signals.shared.subscribe(.mode) { [weak self] in
            guard let self, let state = self.state else { return }
            DeskModel.shared.rerunSearch(state: state)
            self.rebuild()
        })
        tokens.append(Signals.shared.subscribe([.language, .listFontSize]) { [weak self] _ in
            self?.applyCaptions()
            self?.rebuild()
        })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let header: CGFloat = 22
        var x: CGFloat = 8
        let captionWidth = caption.fittingWidth
        caption.frame = NSRect(x: x, y: 0, width: captionWidth, height: header)
        x += captionWidth + 6
        let countWidth = count.fittingWidth
        count.frame = NSRect(x: x, y: 0, width: countWidth, height: header)
        x += countWidth + 6
        progress.frame = NSRect(x: x, y: 7, width: 110, height: 8)
        if !progress.isHidden {
            x += 116
            progressCaption.frame = NSRect(x: x, y: 0,
                                           width: progressCaption.fittingWidth, height: header)
        } else {
            progressCaption.frame = .zero
        }
        close.frame = NSRect(x: bounds.width - 26, y: 3, width: 20, height: 16)
        list.frame = NSRect(x: 0, y: header + 1, width: bounds.width,
                            height: max(0, bounds.height - header - 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 22).fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 22, width: bounds.width, height: 1).fill()
    }

    private func applyCaptions() {
        guard let state else { return }
        caption.text = state.text("Label2", default: "Найдено:")
        close.toolTip = state.hint("SBHideSearchResult", default: "Скрыть окно результатов поиска")
        list.rowHeight = ceil(CGFloat(state.listFontSize)) + 7
    }

    // MARK: - Рядки

    /// На вкладці «Пісні» вікно показує знахідки по Пісеннику.
    private var showsSongs: Bool { state?.mode == .songs }

    /// «(7 збігів)» — з дужками, як на знімку посібника.
    private func countText() -> String {
        guard let state else { return "" }
        let desk = DeskModel.shared
        let count = desk.hitCount(mode: state.mode)
        guard count > 0 else {
            return desk.isSearching ? "…" : state.text("TextMessages9", default: "Ничего не найдено")
        }
        let word = state.text("TextMessages8", default: "совпадений")
        let number = desk.isTruncated ? "\(count)+" : "\(count)"
        return "(\(number) \(word))"
    }

    /// Скільки рядків стоїть у списку — самоперевірці.
    var lineCount: Int { lines.count }

    private func rebuild() {
        guard let state else { return }
        let desk = DeskModel.shared
        let font = NSFont.systemFont(ofSize: max(7, CGFloat(state.listFontSize)))
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let plain: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: style,
        ]
        let matched: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.systemRed, .paragraphStyle: style,
        ]
        func line(_ head: String, _ segments: [TextSearch.Hit.Segment]) -> NSAttributedString {
            let line = NSMutableAttributedString(string: head + " - ", attributes: plain)
            for segment in segments {
                line.append(NSAttributedString(string: segment.text,
                                               attributes: segment.isMatch ? matched : plain))
            }
            return line
        }

        lines = showsSongs
            ? desk.songHits.map { line($0.title, $0.segments) }
            : desk.hits.map { line($0.reference, $0.segments) }
        count.text = countText()
        if let value = desk.indexProgress {
            progress.isHidden = false
            progress.doubleValue = value
        } else {
            progress.isHidden = true
        }
        needsLayout = true
        needsDisplay = true
        list.reload()
    }

    private func isCurrent(_ index: Int) -> Bool {
        guard let state else { return false }
        if showsSongs {
            guard DeskModel.shared.songHits.indices.contains(index) else { return false }
            let hit = DeskModel.shared.songHits[index]
            let model = NativeSongsWorkspace.shared.model
            return model.songIndex == hit.songIndex
                && (hit.partIndex == nil || model.partIndex == hit.partIndex)
        }
        guard DeskModel.shared.hits.indices.contains(index) else { return false }
        let hit = DeskModel.shared.hits[index]
        return hit.bookIndex == state.currentBook?.index
            && hit.chapter == state.selectedChapterNumber
            && state.selectedVerseNumbers.contains(hit.verse)
    }

    /// Той самий договір, що й у списку віршів: одиночне клацання готує вірш у
    /// передпоказі, подвійне — виводить у зал.
    private func show(_ index: Int, live: Bool) {
        guard let state else { return }
        if showsSongs {
            guard DeskModel.shared.songHits.indices.contains(index) else { return }
            let hit = DeskModel.shared.songHits[index]
            NativeSongsWorkspace.shared.reveal(song: hit.songIndex, part: hit.partIndex, live: live)
            list.refreshVisible()
            return
        }
        guard DeskModel.shared.hits.indices.contains(index) else { return }
        DeskModel.shared.show(DeskModel.shared.hits[index], state: state, live: live)
        NativeBibleBridge.shared.sync()
        list.refreshVisible()
    }

    private func menu(_ index: Int) -> NSMenu? {
        guard let state else { return nil }
        if showsSongs {
            guard DeskModel.shared.songHits.indices.contains(index),
                  let song = NativeSongsWorkspace.shared.song(at: DeskModel.shared.songHits[index].songIndex)
            else { return nil }
            let hit = DeskModel.shared.songHits[index]
            let menu = NSMenu()
            add(menu, state.text("MIAddToPlan", default: "Добавить в План")) {
                let part = hit.partIndex.flatMap { song.parts.indices.contains($0) ? song.parts[$0] : nil }
                if let part, let item = DeskModel.shared.planItem(forSong: song, part: part, state: state) {
                    DeskModel.shared.addToPlan([item])
                } else {
                    DeskModel.shared.addToPlan(DeskModel.shared.planItems(forSong: song, state: state))
                }
            }
            add(menu, state.text("MICopyToClipboard",
                                 default: "Скопировать в буфер обмена (Ctrl + C)")) {
                let board = NSPasteboard.general
                board.clearContents()
                board.setString("\(hit.title)\n\(hit.text)", forType: .string)
            }
            return menu
        }
        guard DeskModel.shared.hits.indices.contains(index) else { return nil }
        let hit = DeskModel.shared.hits[index]
        let menu = NSMenu()
        add(menu, state.text("MIAddToPlan", default: "Добавить в План")) {
            DeskModel.shared.show(hit, state: state, live: false)
            DeskModel.shared.addCurrentToPlan(state: state)
        }
        add(menu, state.text("MICopyToClipboard",
                             default: "Скопировать в буфер обмена (Ctrl + C)")) {
            let board = NSPasteboard.general
            board.clearContents()
            board.setString("\(hit.reference) \(hit.text)", forType: .string)
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
