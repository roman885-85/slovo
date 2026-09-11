import AppKit
import SlovoCore

/// Сторінки 4.2.2–4.2.4 — опис того, що можна перенести.
///
/// Влаштовані однаково: галочка, «Коротка назва», «Повна назва» і дві
/// кнопки «позначити все» / «зняти все».
@MainActor
final class ImportListPage: NSView, ImportPageRefreshing,
                            NSTableViewDataSource, NSTableViewDelegate {

    private let state: AppState
    private let model: ImportWizardModel
    private let page: ImportWizardModel.Page

    private let selectAll = NSButton()
    private let deselectAll = NSButton()
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private let empty = NSTextField(labelWithString: "")
    private let counter = NSTextField(labelWithString: "")
    private var shownIDs: [String] = []

    init(state: AppState, model: ImportWizardModel, page: ImportWizardModel.Page) {
        self.state = state
        self.model = model
        self.page = page
        super.init(frame: .zero)

        build(selectAll, symbol: "checkmark.square", hint: selectAllHint) { [weak self] in
            guard let self else { return }
            self.model.setAll(on: self.page, to: true)
        }
        build(deselectAll, symbol: "square", hint: deselectAllHint) { [weak self] in
            guard let self else { return }
            self.model.setAll(on: self.page, to: false)
        }

        buildTable()

        empty.stringValue = emptyText
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        addSubview(empty)

        counter.font = .systemFont(ofSize: 10)
        counter.textColor = .secondaryLabelColor
        addSubview(counter)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build(_ button: NSButton, symbol: String, hint: String,
                       _ action: @escaping () -> Void) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: hint)
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageOnly
        button.toolTip = hint
        button.target = NativeForm.Trampoline.shared
        button.action = #selector(NativeForm.Trampoline.fire(_:))
        NativeForm.Trampoline.shared.bind(button, action)
        addSubview(button)
    }

    private func buildTable() {
        let mark = NSTableColumn(identifier: .init("mark"))
        mark.title = ""
        mark.width = 22
        mark.minWidth = 22
        mark.maxWidth = 22
        let title = NSTableColumn(identifier: .init("title"))
        title.title = state.imp("LVModules->Column0", "Короткое название")
        title.width = 300
        title.minWidth = 160
        let subtitle = NSTableColumn(identifier: .init("subtitle"))
        subtitle.title = state.imp("LVModules->Column1", "Полное название")
        subtitle.width = 360
        subtitle.minWidth = 140
        table.addTableColumn(mark)
        table.addTableColumn(title)
        table.addTableColumn(subtitle)
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = true
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)
    }

    // MARK: Перерисовка

    private var items: [ImportItem] { model.items(on: page) }

    func refreshPage() {
        let list = items
        empty.isHidden = !list.isEmpty
        scroll.isHidden = list.isEmpty

        let ids = list.map(\.id)
        if ids != shownIDs {
            shownIDs = ids
            table.reloadData()
        } else {
            // Галочки міняються найчастіше, і перетрушувати всю таблицю
            // заради однієї клітинки нема чого: рядки перемальовуються на місці.
            table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<list.count),
                             columnIndexes: IndexSet(integer: 0))
        }

        let chosen = list.filter(\.isSelected)
        let bytes = chosen.reduce(Int64(0)) { $0 + $1.byteSize }
        var line = OurWords.t("Отмечено %s из %s", "\(chosen.count)", "\(list.count)")
        if bytes > 0 {
            line += " · " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
        counter.stringValue = line
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        deselectAll.frame = NSRect(x: width - 28, y: 0, width: 28, height: 22)
        selectAll.frame = NSRect(x: width - 62, y: 0, width: 28, height: 22)
        let top: CGFloat = 28
        let bottom = bounds.height - 18
        let body = NSRect(x: 0, y: top, width: width, height: max(60, bottom - top - 6))
        scroll.frame = body
        empty.frame = NSRect(x: 0, y: body.midY - 9, width: width, height: 18)
        counter.frame = NSRect(x: 0, y: bottom, width: width, height: 14)
    }

    /// Скільки рядків показано насправді — для самоперевірки.
    var shownRows: Int { table.numberOfRows }

    // MARK: Таблица

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let list = items
        guard list.indices.contains(row), let column = tableColumn else { return nil }
        let item = list[row]
        switch column.identifier.rawValue {
        case "mark":
            let button = NSButton(checkboxWithTitle: "", target: self,
                                  action: #selector(toggleRow(_:)))
            button.state = item.isSelected ? .on : .off
            button.tag = row
            return button
        case "title":
            let field = NSTextField(labelWithString: "")
            field.attributedStringValue = titleLine(item)
            field.lineBreakMode = .byTruncatingTail
            return field
        default:
            let field = NSTextField(labelWithString: item.subtitle)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingMiddle
            field.toolTip = item.subtitle
            return field
        }
    }

    @objc private func toggleRow(_ sender: NSButton) {
        let list = items
        guard list.indices.contains(sender.tag) else { return }
        model.setSelected(list[sender.tag].id, on: page, to: sender.state == .on)
    }

    /// Название и пометки в одной строке. Пометки — не украшение: ровно они
    /// объясняют, почему галочка стоит (4.2.2: «Автоматически будут отмечены
    /// отсутствующие в текущей версии, или более новые модули»).
    private func titleLine(_ item: ImportItem) -> NSAttributedString {
        let line = NSMutableAttributedString()
        line.append(NSAttributedString(string: item.title, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor,
        ]))
        if let mark = conditionBadge(item) {
            line.append(NSAttributedString(string: " "))
            line.append(badge(mark, tint: .systemOrange))
        }
        return line
    }

    private func badge(_ text: String, tint: NSColor) -> NSAttributedString {
        NSAttributedString(string: " \(text) ", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: tint,
            .backgroundColor: tint.withAlphaComponent(0.16),
        ])
    }

    /// TextMessages4 «Нет» — в текущей версии этого нет, TextMessages2
    /// «Устар.» — то, что есть, старее источника.
    private func conditionBadge(_ item: ImportItem) -> String? {
        switch item.condition {
        case .missing:  return state.imp("TextMessages4", "Нет")
        case .outdated: return state.imp("TextMessages2", "Устар.")
        case .upToDate: return nil
        }
    }

    // MARK: Подписи кнопок

    private var emptyText: String {
        switch page {
        case .modules:   return OurWords.t("В источнике нет модулей")
        case .templates: return OurWords.t("В источнике нет шаблонов слайда")
        case .images:    return OurWords.t("В источнике нет фоновых изображений")
        default:         return ""
        }
    }

    private var selectAllHint: String {
        switch page {
        case .modules:   return state.impHint("PSBSelModules", "Выделить все модули")
        case .templates: return state.impHint("PSBSelTemplates", "Выделить все шаблоны слайда")
        case .images:    return state.impHint("PSBSelImages", "Выделить все изображения")
        default:         return ""
        }
    }

    private var deselectAllHint: String {
        switch page {
        case .modules:   return state.impHint("PSBUnSelModules", "Снять выделение со всех модулей")
        case .templates: return state.impHint("PSBUnSelTemplates",
                                              "Снять выделение со всех шаблонов слайда")
        case .images:    return state.impHint("PSBUnSelImages", "Снять выделение со всех изображений")
        default:         return ""
        }
    }
}

extension ImportListPage: NSMenuDelegate {

    /// N1 — «Открыть папку с модулем».
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let list = items
        let row = table.clickedRow
        guard list.indices.contains(row) else { return }
        let item = NSMenuItem(title: state.imp("N1", "Открыть папку с модулем"),
                              action: #selector(openFolder(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = list[row].sourceURL
        menu.addItem(item)
    }

    @objc private func openFolder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
