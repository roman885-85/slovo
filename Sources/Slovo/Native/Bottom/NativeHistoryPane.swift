import AppKit
import SlovoCore

/// Історія (11) — розділ 5.1.11 посібника.
///
/// «В историю заносятся адреса всех стихов, которые были первыми показаны в
/// окне слайда после их выбора. Щелчок мышью по адресу стиха в истории
/// производит выбор этого места в связке Книга-Глава-Стих. Пункты истории
/// можно удалять. Также можно очистить всю историю. Это делается через
/// контекстное меню.»
///
/// Меню — три пункти зі знімка: «Перейти», риска, «Видалити» і «Очистити
/// історію». Клавіша Del видаляє виділений рядок.
///
/// Рядків в автора не більше шістдесяти, але список усе одно віртуальний:
/// прокрутка довгого списку зобов'язана коштувати однаково за будь-якої довжини, інакше
/// першого ж разу, коли межа виросте, вікно знову почне думати.
@MainActor
final class NativeHistoryPane: NSView, NativeListSource {

    private let state: AppState
    private let desk = DeskModel.shared

    private let box = NativeBottomFramedBox(frame: .zero)
    let list = NativeList(mode: .list, metrics: NativeHistoryPane.metrics,
                          heights: .uniform(16), fontSize: 11)

    /// Готові рядки — «Быт.- В начале сотворил Бог небо и землю.»
    private var captions: [String] = []
    private var identifiers: [UUID] = []
    private var stamp = 0

    private var tokens: [Signals.Token] = []

    private static let metrics: NativeListMetrics = {
        var m = NativeListMetrics()
        m.padding = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
        m.textFontDelta = 0
        return m
    }()

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)

        addSubview(box)
        box.install(list)

        list.source = self
        list.onSelect = { [weak self] _, index, cause in
            // Клацання по рядку повертає до місця — так само, як «Перейти».
            guard let self, cause == .click, let record = self.record(at: index) else { return }
            self.desk.historySelection = record.id
            self.desk.activate(record, state: self.state)
        }
        list.onActivate = { [weak self] index in
            guard let self, let record = self.record(at: index) else { return }
            self.desk.activate(record, state: self.state)
        }

        tokens.append(Signals.shared.subscribe(.history) { [weak self] in self?.reloadHistory() })
        // Повзунок кегля (20) міняє всі списки вікна, а цей стояв на своєму:
        // власник — «в окошке истории не изменяется размер текста».
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self else { return }
            self.list.fontSize = CGFloat(self.state.listFontSize)
            self.list.reload()
        })
        // Підсвічений рядок історії має означати «оце зараз показують».
        // Пішли в інше місце — підсвітка бреше, і її треба зняти. Власник:
        // «выделение не пропадает, но на текст на проекторе это не влияет».
        tokens.append(Signals.shared.subscribe(.verseSelection) { [weak self] in self?.forgetIfMoved() })
        tokens.append(Signals.shared.subscribe(.slide) { [weak self] in self?.forgetIfMoved() })
        list.fontSize = CGFloat(state.listFontSize)
        reloadHistory()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        box.frame = bounds
    }

    // MARK: - Рядки списку

    var rowCount: Int { captions.count }

    func row(at index: Int) -> NativeRow {
        NativeRow(text: captions[index], singleLine: true)
    }

    func menu(at index: Int) -> NSMenu? {
        guard let record = record(at: index) else { return nil }
        let menu = NSMenu()
        menu.addItem(item(caption("N15", "Перейти")) { [weak self] in
            guard let self else { return }
            self.desk.activate(record, state: self.state)
        })
        menu.addItem(.separator())
        menu.addItem(item(caption("MIDelHisItem", "Удалить")) { [weak self] in
            self?.desk.removeHistory(record.id)
        })
        menu.addItem(item(caption("MIHistClear", "Очистить историю")) { [weak self] in
            self?.desk.clearHistory()
        })
        return menu
    }

    // MARK: - Оновлення

    func reloadHistory() {
        var hasher = Hasher()
        for record in desk.history.records { hasher.combine(record.id) }
        let fresh = hasher.finalize()
        if fresh != stamp {
            stamp = fresh
            captions = desk.history.records.map(\.caption)
            identifiers = desk.history.records.map(\.id)
            list.reload()
        }
        applySelection()
    }

    /// Показане місце більше не те, що в підсвіченому рядку, — знімаємо
    /// підсвітку. Рядок історії не «вибраний назавжди»: він показує, звідки
    /// зараз узятий вірш у залі.
    private func forgetIfMoved() {
        guard let chosen = desk.historySelection,
              let record = desk.history.records.first(where: { $0.id == chosen }) else { return }
        guard record.kind == .bible else { return }
        let sameBook = state.currentBook?.index == record.bookIndex
        let sameChapter = state.selectedChapterNumber == record.chapter
        let sameVerses = Set(state.selectedVerseNumbers) == Set(record.verses)
        guard !(sameBook && sameChapter && sameVerses) else { return }
        desk.historySelection = nil
        applySelection()
    }

    func applySelection() {
        guard let chosen = desk.historySelection,
              let row = identifiers.firstIndex(of: chosen) else {
            list.setSelection(IndexSet())
            return
        }
        list.setSelection(IndexSet(integer: row), active: row)
    }

    /// Клавіша Del у пункту «Видалити». Кличуть зі спільного сторожа клавіш
    /// нижнього ряду — списку клавіші не віддано навмисно.
    func deleteSelected() {
        guard let chosen = desk.historySelection else { return }
        desk.removeHistory(chosen)
    }

    func setFocused(_ focused: Bool) { box.isHighlighted = focused }

    // MARK: -

    private func record(at index: Int) -> HistoryRecord? {
        let records = desk.history.records
        guard index >= 0, index < records.count else { return nil }
        return records[index]
    }

    /// Підписи в автора йдуть з амперсандом підкреслення («&Перейти») —
    /// у меню macOS він читався б як знак.
    private func caption(_ key: String, _ fallback: String) -> String {
        state.text(key, default: fallback).replacingOccurrences(of: "&", with: "")
    }

    private func item(_ title: String, _ body: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
        let action = NativeBottomMenuAction(body)
        item.target = action
        item.representedObject = action
        return item
    }
}
