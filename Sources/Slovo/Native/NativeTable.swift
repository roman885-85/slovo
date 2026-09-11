import AppKit

/// Системная таблица для окон настроек и редакторов.
///
/// Владелец: «списки модулей выглядят инородно и коряво — текст кривой,
/// пункты для выделения мелкие». Самодельный `NativeList` хорош в главном
/// окне (там он быстрый и рисует по-своему), а в окне настроек нужен
/// обычный вид macOS: настоящие галочки, однострочный текст с многоточием,
/// колонка подписи, стандартное выделение. Здесь всё это делает NSTableView,
/// а снаружи — тот же договор, что у `NativeList`: `source`, `onSelect`,
/// `reload()`, `setSelection(...)`, — окна меняют только тип.
@MainActor
final class NativeTable: NSView, NSTableViewDataSource, NSTableViewDelegate, NativeListChecking {
    /// Источник подключают после создания — перечитываем сразу, иначе
    /// таблица так и стоит пустой: самопроверка это и поймала.
    weak var source: NativeListSource? {
        didSet { table.reloadData() }
    }
    var onSelect: ((IndexSet, Int, NativeList.Cause) -> Void)?
    var onActivate: ((Int) -> Void)?
    var onContextMenu: ((Int) -> NSMenu?)?
    /// Щелчок по галочке (или по значку в первой колонке).
    var onLeadClick: ((Int) -> Void)?

    private let scroll = NSScrollView()
    private let table: MenuTableView
    private let detailWidth: CGFloat
    private var suppressSelect = false

    private static let leadColumn = NSUserInterfaceItemIdentifier("lead")
    private static let textColumn = NSUserInterfaceItemIdentifier("text")
    private static let detailColumn = NSUserInterfaceItemIdentifier("detail")

    init(detailWidth: CGFloat = 0) {
        self.detailWidth = detailWidth
        table = MenuTableView()
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    private func build() {
        let lead = NSTableColumn(identifier: Self.leadColumn)
        lead.width = 28
        lead.minWidth = 28
        lead.maxWidth = 28
        table.addTableColumn(lead)
        let text = NSTableColumn(identifier: Self.textColumn)
        text.minWidth = 80
        table.addTableColumn(text)
        if detailWidth > 0 {
            let detail = NSTableColumn(identifier: Self.detailColumn)
            detail.width = detailWidth
            detail.minWidth = 60
            table.addTableColumn(detail)
        }
        table.headerView = nil
        table.rowHeight = 24
        table.style = .plain
        table.intercellSpacing = NSSize(width: 6, height: 2)
        table.selectionHighlightStyle = .regular
        table.usesAlternatingRowBackgroundColors = false
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        table.menuProvider = { [weak self] row in self?.onContextMenu?(row) }

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { table.reloadData() }
    }

    override func layout() {
        super.layout()
        // Колонка текста забирает всё, что осталось от значка и подписи.
        let width = table.bounds.width - 28 - (detailWidth > 0 ? detailWidth : 0) - 6 * 3
        table.tableColumns[1].width = max(80, width)
    }

    // MARK: - Договор NativeList

    func reload() { table.reloadData() }
    func reloadRow(_ index: Int) { reloadRows(IndexSet(integer: index)) }
    func reloadRows(_ indexes: IndexSet) {
        let all = IndexSet(integersIn: 0..<table.numberOfColumns)
        table.reloadData(forRowIndexes: indexes, columnIndexes: all)
    }

    func setSelection(_ new: IndexSet, active: Int? = nil, notify: Bool = false, cause: NativeList.Cause = .code) {
        suppressSelect = !notify
        table.selectRowIndexes(new, byExtendingSelection: false)
        suppressSelect = false
        if let active, active >= 0, active < table.numberOfRows { table.scrollRowToVisible(active) }
        if notify, let active { onSelect?(new, active, cause) }
    }

    func scrollTo(_ index: Int, place: NativeList.Place = .nearest) {
        guard index >= 0, index < table.numberOfRows else { return }
        table.scrollRowToVisible(index)
    }

    var visibleItems: Range<Int> {
        let range = table.rows(in: table.visibleRect)
        return range.location..<(range.location + range.length)
    }

    var rowsInTable: Int { table.numberOfRows }
    /// Сколько строк у источника — как `itemCount` у прежнего списка.
    var itemCount: Int { source?.rowCount ?? 0 }
    var hasSource: Bool { source != nil }
    var sourceRowCount: Int { source?.rowCount ?? 0 }
    var describedForCheck: String {
        "таблица: строк \(rowsInTable), источник \(source == nil ? "нет" : "есть (\(sourceRowCount))")"
    }

    // MARK: - NSTableViewDataSource / Delegate

    func numberOfRows(in tableView: NSTableView) -> Int { source?.rowCount ?? 0 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let source, row >= 0, row < source.rowCount, let column = tableColumn else { return nil }
        let data = source.row(at: row)
        switch column.identifier {
        case Self.leadColumn:
            return leadView(for: data, row: row)
        case Self.detailColumn:
            let cell = textCell(identifier: "detail", font: .systemFont(ofSize: 11), color: .secondaryLabelColor)
            cell.textField?.stringValue = data.detail
            cell.textField?.lineBreakMode = .byTruncatingMiddle
            return cell
        default:
            let cell = textCell(identifier: "text", font: .systemFont(ofSize: 13), color: data.textColor ?? .labelColor)
            cell.textField?.stringValue = data.text
            cell.textField?.lineBreakMode = .byTruncatingTail
            return cell
        }
    }

    private func textCell(identifier: String, font: NSFont, color: NSColor) -> NSTableCellView {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let cell = (table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = id
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()
        cell.textField?.font = font
        cell.textField?.textColor = color
        return cell
    }

    /// Первая колонка: галочка, цветной квадрат или значок — по тому, что
    /// источник положил в `lead`.
    private func leadView(for data: NativeRow, row: Int) -> NSView {
        let lead = data.lead
        if let checked = Self.checkboxState(lead) {
            let id = NSUserInterfaceItemIdentifier("check")
            let button = (table.makeView(withIdentifier: id, owner: nil) as? NSButton) ?? {
                let button = NSButton(checkboxWithTitle: "", target: self, action: #selector(checkboxClicked(_:)))
                button.identifier = id
                button.controlSize = .regular
                return button
            }()
            button.state = checked ? .on : .off
            button.tag = row
            button.isEnabled = onLeadClick != nil
            return button
        }
        if lead == "■", let colour = data.leadColor {
            let id = NSUserInterfaceItemIdentifier("swatch")
            let swatch = (table.makeView(withIdentifier: id, owner: nil) as? SwatchView) ?? {
                let view = SwatchView()
                view.identifier = id
                return view
            }()
            swatch.colour = colour
            return swatch
        }
        let id = NSUserInterfaceItemIdentifier("symbol")
        let cell = (table.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
            let view = NSTableCellView()
            view.identifier = id
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.imageScaling = .scaleProportionallyDown
            view.addSubview(image)
            view.imageView = image
            let field = NSTextField(labelWithString: "")
            field.translatesAutoresizingMaskIntoConstraints = false
            field.alignment = .center
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                image.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }()
        if let symbol = Self.systemSymbol(for: lead),
           let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            cell.imageView?.image = image
            cell.imageView?.contentTintColor = data.leadColor ?? .secondaryLabelColor
            cell.imageView?.isHidden = false
            cell.textField?.isHidden = true
        } else {
            cell.imageView?.isHidden = true
            cell.textField?.isHidden = false
            cell.textField?.stringValue = lead
            cell.textField?.textColor = data.leadColor ?? .secondaryLabelColor
            cell.textField?.font = .systemFont(ofSize: 12)
        }
        return cell
    }

    /// Какие значки источники кладут в `lead` вместо галочки.
    private static func checkboxState(_ lead: String) -> Bool? {
        switch lead {
        case "☑", "✓", "●": return true
        case "☐", "○": return false
        default: return nil
        }
    }

    /// Значки-символы из прежнего списка — системными картинками.
    private static func systemSymbol(for lead: String) -> String? {
        switch lead {
        case "🔒": return "lock.fill"
        case "✎": return "pencil"
        case "♪": return "music.note"
        case "▤": return "tablecells"
        case "▸": return "folder"
        case "↳": return "arrow.turn.down.right"
        case "•": return "folder"
        default: return nil
        }
    }

    @objc private func checkboxClicked(_ sender: NSButton) {
        let row = sender.tag
        // Галочку рисует источник по своим данным: щелчок сообщаем, а вид
        // вернём тем, что перечитаем строку.
        onLeadClick?(row)
        if row < table.numberOfRows { reloadRow(row) }
    }

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0 else { return }
        onActivate?(row)
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelect else { return }
        let selected = table.selectedRowIndexes
        onSelect?(selected, selected.first ?? -1, .click)
    }

    /// Таблица с контекстным меню по строке под курсором.
    private final class MenuTableView: NSTableView {
        var menuProvider: ((Int) -> NSMenu?)?
        override func menu(for event: NSEvent) -> NSMenu? {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            guard row >= 0 else { return super.menu(for: event) }
            if !selectedRowIndexes.contains(row) { selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
            return menuProvider?(row) ?? super.menu(for: event)
        }
    }

    /// Цветной квадрат палитры частей песни.
    private final class SwatchView: NSView {
        var colour: NSColor = .clear { didSet { needsDisplay = true } }
        override func draw(_ dirtyRect: NSRect) {
            let square = NSRect(x: (bounds.width - 14) / 2, y: (bounds.height - 14) / 2, width: 14, height: 14)
            let path = NSBezierPath(roundedRect: square, xRadius: 3, yRadius: 3)
            colour.setFill()
            path.fill()
            NSColor.separatorColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }
}

/// Что самопроверка спрашивает у любого списка окна настроек.
@MainActor
protocol NativeListChecking: AnyObject {
    var describedForCheck: String { get }
    var rowsInTable: Int { get }
    var hasSource: Bool { get }
    var sourceRowCount: Int { get }
}
