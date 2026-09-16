import AppKit
import SlovoCore

/// 4.2.6 «Завершення»: до натискання — що буде перенесено, після — що
/// перенеслося і що з ним сталося.
@MainActor
final class ImportSummaryPage: NSView, ImportPageRefreshing {

    private let state: AppState
    private let model: ImportWizardModel
    private let onImport: () -> Void
    private let scroll = ImportScroll()
    /// Що показували минулого разу. Зведення перебудовується цілком, і без
    /// цієї позначки воно збиралося б заново на кожну перемальовку вікна —
    /// разом із прокруткою, що поїхала б на початок під руками в людини.
    private var shownSignature = ""

    init(state: AppState, model: ImportWizardModel, onImport: @escaping () -> Void) {
        self.state = state
        self.model = model
        self.onImport = onImport
        super.init(frame: .zero)
        scroll.body.spacing = 12
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = bounds
    }

    func refreshPage() {
        let signature = currentSignature
        guard signature != shownSignature else { return }
        shownSignature = signature
        scroll.body.set(model.outcome.map(result) ?? plan())
        scroll.refreshHeight()
    }

    private var currentSignature: String {
        if let outcome = model.outcome {
            return "підсумок:\(outcome.total):\(outcome.failures.count)"
        }
        return "план:\(model.plannedCount):\(model.selectedSource?.id ?? "")"
    }

    // MARK: До натискання «Імпортувати»

    private func plan() -> [NSView] {
        var rows: [NSView] = [
            group(title: state.imp("TextMessages3", "Модули"), names: chosen(model.modules)),
            group(title: state.imp("TextMessages8", "Шаблоны слайда"), names: chosen(model.templates)),
            group(title: state.imp("TextMessages5", "Фоновые изображения"), names: chosen(model.images)),
            ImportBox(OurWords.t("Откуда и куда"), [
                ImportPair(OurWords.t("Источник"), model.selectedSource?.path ?? "—"),
                ImportPair(OurWords.t("Библиотека программы"), model.destination.dataRoot.path),
            ]),
        ]
        if model.plannedCount == 0 {
            rows.append(ImportText(OurWords.t("Ничего не отмечено — переносить нечего."),
                                   size: 11, colour: .systemOrange))
        }
        return rows
    }

    private func chosen(_ items: [ImportItem]) -> [String] {
        items.filter(\.isSelected).map(\.title)
    }

    // MARK: Після перенесення

    private func result(_ outcome: ImportOutcome) -> [NSView] {
        var rows: [NSView] = [
            ImportText(outcome.failures.isEmpty
                       ? OurWords.t("Перенесено объектов: %s", "\(outcome.total)")
                       : OurWords.t("Перенесено объектов: %s, с ошибками: %s",
                                    "\(outcome.total)", "\(outcome.failures.count)"),
                       size: 13, weight: .semibold),
            group(title: state.imp("TextMessages3", "Модули"), names: outcome.modules),
            group(title: state.imp("TextMessages8", "Шаблоны слайда"), names: outcome.templates),
            group(title: state.imp("TextMessages5", "Фоновые изображения"), names: outcome.images),
        ]

        // Перенесене підключається без перезапуску й без перемикання
        // бібліотеки: модулі — поіменно до списку перекладів, тека з фонами
        // — до списку тек із фонами. Людина має це побачити написаним, інакше
        // шукатиме перенесене у вікні вибору теки модулів.
        if outcome.total > 0 {
            rows.append(ImportText(OurWords.t("Перенесённые модули и песенники добавлены в список переводов, папка с фонами — в список папок с фонами («Параметры»)."),
                                   size: 11, secondary: true))
        }

        if !outcome.failures.isEmpty {
            let lines = outcome.failures.map {
                ImportText("\($0.title): \($0.reason)", size: 11, colour: .systemOrange) as NSView
            }
            rows.append(ImportBox(state.imp("ErrorMessages3", "Ошибка") + " — \(outcome.failures.count)",
                                  lines))
        }

        let reveal = NativeForm.button(OurWords.t("Показать в Finder"),
                                       hint: DataHome.hint(OurWords.t("Открыть в Finder папку, куда программа кладёт данные"))) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([self.model.destination.dataRoot])
        }
        let reread = NativeForm.button(OurWords.t("Перечитать библиотеку")) { [weak self] in
            guard let self else { return }
            self.state.reloadLibrary()
        }
        rows.append(ImportLeft([reveal, reread]))
        return rows
    }

    /// Понад два десятки імен перетворюють сторінку на простирадло; решта
    /// згортається в лічильник.
    private func group(title: String, names: [String]) -> NSView {
        let body: NSView
        if names.isEmpty {
            body = ImportText("—", size: 11, secondary: true)
        } else {
            let text = names.prefix(24).joined(separator: ", ")
                + (names.count > 24 ? " " + OurWords.t("и ещё %s", "\(names.count - 24)") : "")
            body = ImportText(text, size: 11, secondary: true)
        }
        return ImportBox("\(title) — \(names.count)", [body])
    }
}

/// Ряд кнопок зліва направо.
@MainActor
final class ImportLeft: NSView {
    private let views: [NSView]
    init(_ views: [NSView]) {
        self.views = views
        super.init(frame: .zero)
        for view in views { addSubview(view) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }
    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 24) }
    override func layout() {
        super.layout()
        var left: CGFloat = 0
        for view in views {
            let width = max(80, view.intrinsicContentSize.width + 16)
            view.frame = NSRect(x: left, y: 0, width: width, height: 22)
            left += width + 8
        }
    }
}
