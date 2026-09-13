import AppKit
import SlovoCore

/// Робоча область «Екран»: монітор або вікно чужої програми — в зал і в NDI.
///
/// Власник: «захват окна или выделенного участка монитора или весь монитор
/// или определённого окна и выводить его на проектор и ndi, с функцией
/// указки и масштабирования содержимого».
///
/// Зліва список того, що можна показати, справа — підказка і кнопки. Самої
/// картинки тут немає навмисно: її видно там же, де й усе інше, — на живому
/// екрані в нижньому ряду, і там же по ній ведуть указкою і вибирають точку
/// фокуса. Другий такий самий екран у робочій області був би тим самим
/// кадром удруге і забирав би такт у показу.
@MainActor
final class NativeScreenWorkspace: NSView {

    static let shared = NativeScreenWorkspace()

    /// Роздільник між списком і поясненням: ширина списку тягнеться й пам'ятається.
    private let grip = NativeWidthGrip()
    private static let listWidthKey = "screenListWidth"
    private let list = NativeList(mode: .list, metrics: NativeListMetrics.settings(detailWidth: 220),
                                  heights: .uniform(44), fontSize: 13)
    private let title = NSTextField(labelWithString: "")
    private let note = NSTextField(wrappingLabelWithString: "")
    private let reloadButton = NSButton(title: "", target: nil, action: nil)
    private let showButton = NSButton(title: "", target: nil, action: nil)
    private let hideButton = NSButton(title: "", target: nil, action: nil)
    private let rows = Rows()
    private weak var state: AppState?
    private var tokens: [Signals.Token] = []
    /// Що вибрано в списку. Номер, а не саме джерело: список перечитується.
    private var chosen = 0

    private init() {
        super.init(frame: .zero)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 8
        for button in [reloadButton, showButton, hideButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        reloadButton.action = #selector(reloadTapped)
        showButton.action = #selector(showTapped)
        hideButton.action = #selector(hideTapped)
        rows.owner = self
        list.source = rows
        list.onSelect = { [weak self] _, active, _ in self?.chosen = active }
        list.onActivate = { [weak self] row in
            self?.chosen = row
            self?.showTapped()
        }
        for view in [title, note, reloadButton, showButton, hideButton, list, grip] as [NSView] { addSubview(view) }
        grip.onDrag = { [weak self] delta in
            guard let self else { return }
            NativeWidths.set(Self.listWidthKey, self.list.frame.width + delta, min: 200, max: self.bounds.width * 0.7)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        grip.onReset = { [weak self] in NativeWidths.reset(Self.listWidthKey); self?.needsLayout = true }
        applyCaptions()
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in self?.applyCaptions() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    /// Поставити область у вікно. Кличе перемикач вкладок.
    func install(state: AppState) {
        self.state = state
        NativeMainWindowController.shared.install(self, in: .workspace)
        refresh()
        reloadTapped()
    }

    private func applyCaptions() {
        title.stringValue = OurWords.t("Что показать в зале")
        reloadButton.title = OurWords.t("Обновить список")
        showButton.title = OurWords.t("Показать")
        hideButton.title = OurWords.t("Скрыть")
        refresh()
    }

    // MARK: - Кнопки

    @objc private func reloadTapped() {
        guard let state else { return }
        let capture = state.screenCapture
        Task { @MainActor in
            await capture.reload()
            self.list.reload()
            self.refresh()
        }
    }

    @objc private func showTapped() {
        guard let state else { return }
        let capture = state.screenCapture
        guard capture.sources.indices.contains(chosen) else { return }
        state.showCapturedScreen(capture.sources[chosen])
        list.reload()
        refresh()
    }

    @objc private func hideTapped() {
        guard let state else { return }
        state.stopCapturedScreen()
        list.reload()
        refresh()
    }

    // MARK: - Стан

    func refresh() {
        let hint = OurWords.t("Выберите монитор или окно и нажмите «Показать». "
            + "Картинка пойдёт на проектор и в NDI. Указка и приближение работают "
            + "по живому экрану в нижнем ряду — там же выбирается участок, на "
            + "который надо смотреть.")
        guard let state else {
            showButton.isEnabled = false
            hideButton.isEnabled = false
            return
        }
        let capture = state.screenCapture
        showButton.isEnabled = !capture.sources.isEmpty
        hideButton.isEnabled = capture.isRunning
        note.stringValue = capture.state.isEmpty ? hint : capture.state + "\n\n" + hint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let padding: CGFloat = 12
        let gap: CGFloat = 10
        let listWidth = NativeWidths.value(Self.listWidthKey, auto: max(240, min(520, bounds.width * 0.45)),
                                           min: 200, max: bounds.width * 0.7)
        let buttonHeight: CGFloat = 26
        title.frame = NSRect(x: padding, y: bounds.maxY - padding - 18,
                             width: max(0, bounds.width - padding * 2), height: 18)
        let top = title.frame.minY - gap
        let contentHeight = max(0, top - padding - buttonHeight - gap)
        list.frame = NSRect(x: padding, y: padding + buttonHeight + gap,
                            width: listWidth, height: contentHeight)
        reloadButton.frame = NSRect(x: padding, y: padding, width: 170, height: buttonHeight)
        grip.frame = NSRect(x: list.frame.maxX, y: list.frame.minY, width: NativeWidths.grip, height: contentHeight)
        let rightX = grip.frame.maxX + gap
        let rightWidth = max(0, bounds.width - rightX - padding)
        note.frame = NSRect(x: rightX, y: padding + buttonHeight + gap,
                            width: rightWidth, height: contentHeight)
        showButton.frame = NSRect(x: rightX, y: padding, width: 130, height: buttonHeight)
        hideButton.frame = NSRect(x: rightX + 140, y: padding, width: 110, height: buttonHeight)
    }

    /// Самоперевірці: скільки джерел у списку і що вибрано.
    var rowCountForCheck: Int { rows.rowCount }
    func selectForCheck(_ index: Int) { chosen = index }
    func showForCheck() { showTapped() }
    func hideForCheck() { hideTapped() }

    /// Рядки списку джерел.
    private final class Rows: NativeListSource {
        weak var owner: NativeScreenWorkspace?
        var rowCount: Int {
            guard let state = owner?.state else { return 0 }
            return state.screenCapture.sources.count
        }
        func row(at index: Int) -> NativeRow {
            var row = NativeRow()
            guard let state = owner?.state,
                  state.screenCapture.sources.indices.contains(index) else { return row }
            let source = state.screenCapture.sources[index]
            row.text = source.title
            row.detail = source.subtitle
            row.singleLine = true
            row.bold = state.screenCapture.current == source
            return row
        }
    }
}
