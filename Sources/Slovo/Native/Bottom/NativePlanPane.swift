import AppKit
import Combine
import SlovoCore

/// План служіння (10) — розділ 5.1.10 посібника.
///
/// «Пункты плана можно удалять и перемещать. Делается это при помощи кнопок,
/// расположенных над планом.» Звідси й розкладка: смуга з шести кнопок
/// зверху, список під нею. Кнопки ті самі і в тому самому порядку, що на знімку
/// посібника: Новий, Відкрити, Зберегти, Видалити рядок, Вгору, Вниз.
///
/// Список — віртуальний `NativeList`: рядки беруться за номером, значення
/// `PlanItem` у нього не потрапляють зовсім. План рідко буває довшим за півсотні
/// пунктів, але правило одне на всі списки вікна, і робити тут виняток
/// означало б завести другий порядок роботи — той самий, через який
/// колишнє вікно й переписується.
@MainActor
final class NativePlanPane: NSView, NativeListSource {

    private let state: AppState
    private let desk = DeskModel.shared

    private let box = NativeBottomFramedBox(frame: .zero)
    private let bar = NSView(frame: .zero)
    private let separator = NSView(frame: .zero)
    let list = NativeList(mode: .list, metrics: NativePlanPane.metrics,
                          heights: .uniform(18), fontSize: 12)
    /// Перетягування пункту мишею. Відкрито назовні заради заміру і самоперевірки.
    private(set) var reorder: NativeListReorder!

    private var buttons: [NativeBottomIconButton] = []
    private var clearButton: NativeBottomIconButton!
    private var saveButton: NativeBottomIconButton!
    private var deleteButton: NativeBottomIconButton!
    private var upButton: NativeBottomIconButton!
    private var downButton: NativeBottomIconButton!

    /// Готові рядки списку. Перезбираються лише при зміні складу плану —
    /// на виділення і на показ вони не озиваються зовсім.
    private var captions: [String] = []
    private var currentRow: Int?
    /// Відбиток складу плану: за ним видно, чи міняти рядки взагалі.
    private var planStamp = 0

    /// Під час проповіді: чий це план і як повернути план служіння.
    private let sermonLabel = NSTextField(labelWithString: "")
    private let sermonButton = NSButton(title: "", target: nil, action: nil)

    private var tokens: [Signals.Token] = []
    private var bells: [AnyCancellable] = []

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
        bar.wantsLayer = true
        separator.wantsLayer = true
        box.addSubview(bar)
        box.addSubview(separator)
        box.addSubview(list)
        applyColors()

        buildButtons()
        list.source = self
        list.allowsMultipleSelection = true
        list.onSelect = { [weak self] selection, _, cause in
            guard let self, cause != .code else { return }
            self.desk.planSelection = Set(selection.compactMap { self.desk.plan[$0]?.id })
            self.updateButtons()
        }
        // Одинарне клацання лише виділяє пункт; відкривають його подвійне
        // клацання або Enter — так вирішив власник (14.09.2026): «по нажатию
        // выделяется пункт плана, а по двойному щелчку мыши (или Enter)
        // активируется». Доти (0.66–0.67) відкривало й одинарне.
        list.onActivate = { [weak self] index in
            guard let self, let item = self.desk.plan[index] else { return }
            self.desk.activate(item, state: self.state)
        }
        list.activatesOnReturn = true
        reorder = NativeListReorder(list: list)
        reorder.onMove = { [weak self] from, to in
            self?.desk.movePlan(fromOffsets: IndexSet(integer: from), toOffset: to)
        }

        sermonLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        sermonLabel.textColor = .controlAccentColor
        sermonLabel.lineBreakMode = .byTruncatingTail
        sermonButton.bezelStyle = .recessed
        sermonButton.controlSize = .small
        sermonButton.font = .systemFont(ofSize: 11)
        sermonButton.target = self
        sermonButton.action = #selector(endSermon)
        bar.addSubview(sermonLabel)
        bar.addSubview(sermonButton)

        tokens.append(Signals.shared.subscribe(.plan) { [weak self] in
            self?.reloadPlan()
            self?.updateSermonStrip()
        })
        // Той самий повзунок кегля, що й для решти списків вікна: План стояв
        // на своєму разом з Історією.
        tokens.append(Signals.shared.subscribe(.listFontSize) { [weak self] in
            guard let self else { return }
            self.list.fontSize = CGFloat(self.state.listFontSize)
            self.list.reload()
        })
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })
        // «Дзвінок» F2 у приводів свого виду немає і бути не повинно: це не
        // зміна стану, а разове прохання забрати клавіатуру собі.
        bells.append(desk.$planFocusRequest.dropFirst().sink { [weak self] _ in
            guard let self else { return }
            self.window?.makeFirstResponder(NativeListProbe.table(in: self.list) ?? self.list)
        })

        applyCaptions()
        reloadPlan()
        updateSermonStrip()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    /// Смужка проповіді видна лише тоді, коли план служіння відкладено.
    private func updateSermonStrip() {
        let title = desk.plan.title.trimmingCharacters(in: .whitespaces)
        sermonLabel.stringValue = title.isEmpty
            ? OurWords.t("План проповеди")
            : OurWords.t("План проповеди: %s", title)
        sermonButton.title = OurWords.t("Вернуть план служения")
        sermonLabel.isHidden = !desk.isSermon
        sermonButton.isHidden = !desk.isSermon
        needsLayout = true
    }

    @objc private func endSermon() {
        desk.endSermon()
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        box.frame = bounds
        // Під час проповіді — другий ряд: панель Плана вузька, і поруч зі
        // значками кнопка повернення не вміщається.
        let strip: CGFloat = sermonButton.isHidden ? 0 : 24
        let barHeight: CGFloat = 24 + strip
        bar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: barHeight)
        separator.frame = NSRect(x: 0, y: barHeight, width: bounds.width, height: 1)
        list.frame = NSRect(x: 0, y: barHeight + 1,
                            width: bounds.width, height: max(0, bounds.height - barHeight - 1))
        // `bar` рахує знизу вгору: значки — у верхньому ряду, смужка — під ними.
        var x: CGFloat = 4
        for button in buttons {
            button.frame = NSRect(x: x, y: strip + 3, width: 20, height: 18)
            x += 22
        }
        if !sermonButton.isHidden {
            sermonButton.sizeToFit()
            let width = min(sermonButton.frame.width, max(0, bounds.width - 8))
            sermonButton.frame = NSRect(x: bounds.width - width - 4, y: 2, width: width, height: 20)
            sermonLabel.frame = NSRect(x: 6, y: 4, width: max(0, bounds.width - width - 16), height: 16)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Рядки списку

    var rowCount: Int { captions.count }

    func row(at index: Int) -> NativeRow {
        // Поданий на екран пункт відрізняється лише накресленням: зайвих
        // позначок у списку в автора немає.
        NativeRow(text: captions[index], singleLine: true, bold: index == currentRow)
    }

    func menu(at index: Int) -> NSMenu? {
        // Рівно три пункти зі знімка посібника: «Перейти», риска,
        // «Видалити» і «Очистити план».
        let menu = NSMenu()
        menu.addItem(item(caption("MenuItem1", "Перейти")) { [weak self] in
            guard let self, let plan = self.desk.plan[index] else { return }
            self.desk.activate(plan, state: self.state)
        })
        menu.addItem(.separator())
        menu.addItem(item(caption("MenuItem3", "Удалить")) { [weak self] in
            self?.desk.deletePlan(atOffsets: IndexSet(integer: index))
        })
        menu.addItem(item(caption("MenuItem4", "Очистить план")) { [weak self] in
            self?.askAndClear()
        })
        return menu
    }

    // MARK: - Оновлення

    /// Привід `.plan` приходить і на зміну складу, і на зміну виділення, і на
    /// подачу пункту в зал. Розбираємо, що саме змінилося, і робимо рівно
    /// це: перечитувати сорок рядків на кожне клацання нема чого.
    func reloadPlan() {
        var hasher = Hasher()
        for item in desk.plan.items { hasher.combine(item.id) }
        let stamp = hasher.finalize()

        if stamp != planStamp {
            planStamp = stamp
            captions = desk.plan.items.map { item in
                guard let subtitle = item.subtitle, !subtitle.isEmpty else { return item.title }
                return "\(item.title) - \(subtitle)"
            }
            currentRow = desk.plan.currentIndex
            list.reload()
        } else if currentRow != desk.plan.currentIndex {
            // Змінився лише поданий пункт: жирним стає інший
            // рядок, і перемалювати треба рівно два.
            let was = currentRow
            currentRow = desk.plan.currentIndex
            if let was { list.reloadRow(was) }
            if let now = currentRow { list.reloadRow(now) }
        }
        applySelection()
        updateButtons()
    }

    /// Виділення змінилося, склад той самий: список не перечитується.
    func applySelection() {
        let rows = IndexSet(desk.selectedPlanPositions)
        list.setSelection(rows, active: rows.first)
    }

    private func updateButtons() {
        let empty = desk.plan.isEmpty
        clearButton.isEnabled = !empty
        saveButton.isEnabled = !empty
        let positions = working
        deleteButton.isEnabled = !positions.isEmpty
        // «Вище» і «нижче» рухають один пункт: що означає «підняти» три
        // виділені врозбивку, в автора не сказано, і вигадувати не можна.
        if positions.count == 1 {
            upButton.isEnabled = positions[0] > 0
            downButton.isEnabled = positions[0] < desk.plan.count - 1
        } else {
            upButton.isEnabled = false
            downButton.isEnabled = false
        }
    }

    /// Кнопки «мінус», «вище» і «нижче» працюють за виділенням, а якщо його
    /// немає — за поданим пунктом: інакше після завантаження плану рухати нічого,
    /// поки не клацнеш мишею.
    private var working: [Int] {
        let positions = desk.selectedPlanPositions
        if !positions.isEmpty { return positions }
        return [desk.plan.currentIndex].compactMap { $0 }
    }

    // MARK: - Клавіша Del

    /// Клавішу Del і стрілки списку ніхто не віддає: стрілки в програмі
    /// гортають вірш, а Del живе в контекстному меню. Кличуть це зі спільного
    /// сторожа клавіш нижнього ряду.
    func deleteSelected() {
        let positions = working
        guard !positions.isEmpty else { return }
        desk.deletePlan(atOffsets: IndexSet(positions))
    }

    // MARK: - Кнопки

    private func buildButtons() {
        clearButton = NativeBottomIconButton(symbol: "doc", hint: "") { [weak self] in self?.askAndClear() }
        let open = NativeBottomIconButton(symbol: "folder", hint: "") { [weak self] in
            self?.desk.openPlan()
        }
        saveButton = NativeBottomIconButton(symbol: "square.and.arrow.down", hint: "") { [weak self] in
            self?.desk.savePlan()
        }
        deleteButton = NativeBottomIconButton(symbol: "nosign", hint: "") { [weak self] in
            self?.deleteSelected()
        }
        upButton = NativeBottomIconButton(symbol: "arrow.up", hint: "") { [weak self] in self?.step(-1) }
        downButton = NativeBottomIconButton(symbol: "arrow.down", hint: "") { [weak self] in self?.step(1) }

        buttons = [clearButton, open, saveButton, deleteButton, upButton, downButton]
        for button in buttons { bar.addSubview(button) }
    }

    private func step(_ delta: Int) {
        desk.movePlanSelection(by: delta)
    }

    private func askAndClear() {
        guard !desk.plan.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = state.text("TextMessages27", default: "Очистка плана")
        alert.informativeText = state.text("TextMessages28",
                                           default: "Все пункты плана будут удалены. Уверены?")
        // В оригіналі це питання з «Так» і «Ні»; підписувати згоду
        // назвою дії не можна — такої кнопки в автора немає.
        alert.addButton(withTitle: caption("TextMessages6", "Да"))
        alert.addButton(withTitle: caption("TextMessages7", "Нет"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        desk.clearPlan()
    }

    // MARK: - Підписи

    /// Підписи кнопок плану в автора лежать у підказках: сам підпис там —
    /// службове ім'я («TBPlanDel»), бо на кнопці лише значок.
    private func applyCaptions() {
        let hints = ["TBPlanNew": "Очистить план", "TBPlanOpen": "Загрузить план",
                     "TBPlanSave": "Сохранить план", "TBPlanDel": "Удалить строку",
                     "TBPlanUp": "Переместить выше", "TBPlanDown": "Переместить ниже"]
        let order = ["TBPlanNew", "TBPlanOpen", "TBPlanSave", "TBPlanDel", "TBPlanUp", "TBPlanDown"]
        for (button, key) in zip(buttons, order) {
            button.setHint(state.hint(key, default: hints[key] ?? ""))
        }
    }

    /// Підписи пунктів меню і кнопок питання в автора йдуть з амперсандом
    /// підкреслення («&Удалить») — у macOS він читався б як знак.
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

    /// Рамка списку стає кольоровою, поки клавіатура в нього: за нею видно,
    /// що стрілки зараз гортають план, а не вірші.
    func setFocused(_ focused: Bool) {
        box.isHighlighted = focused
        desk.isPlanFocused = focused
    }
}

/// Дія пункту меню. `NSMenuItem` тримає ціль слабко, тому її треба десь
/// зберігати — зберігаємо в самому пункті, у `representedObject`.
@MainActor
final class NativeBottomMenuAction: NSObject {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    @objc func fire() { body() }
}
