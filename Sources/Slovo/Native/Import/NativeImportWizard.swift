import AppKit
import Combine
import SlovoCore

/// Майстер імпорту (4.2) — вікно цілком, на AppKit.
///
/// Сторінок шість, і кожна живе своїм видом; майстер тримає їх усі й
/// показує потрібну. Перепитувати модель на кожен рух не треба: вона б'є в
/// один спільний `objectWillChange`, і за ним сторінка перемальовується раз
/// за оберт циклу подій.
@MainActor
final class NativeImportWizard: NSView {

    private let state: AppState
    private let model: ImportWizardModel
    private let onClose: () -> Void
    private var observers: [AnyCancellable] = []

    private let titleLabel = NSTextField(labelWithString: "")
    private let stepLabel = NSTextField(labelWithString: "")
    private let topRule = NSBox()
    private let bottomRule = NSBox()
    private let content = NSView()
    private let scanning = NSView()
    private let scanningSpinner = NSProgressIndicator()

    private let closeButton = NSButton()
    private let backButton = NSButton()
    private let nextButton = NSButton()
    private let runBar = NSProgressIndicator()
    private let runStatus = NSTextField(labelWithString: "")

    private var pages: [ImportWizardModel.Page: NSView] = [:]
    private var shown: NSView?
    /// Сводку об ошибке показываем один раз на одну беду: иначе окно с
    /// отказом всплывало бы на каждую перерисовку.
    private var reportedProblem: String?
    /// Итог переноса применяется один раз — библиотека перечитывается не на
    /// каждый кадр.
    private var appliedOutcome = false

    init(state: AppState, model: ImportWizardModel, onClose: @escaping () -> Void) {
        self.state = state
        self.model = model
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 940, height: 660))

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        stepLabel.font = .systemFont(ofSize: 11)
        stepLabel.textColor = .secondaryLabelColor
        addSubview(titleLabel)
        addSubview(stepLabel)

        topRule.boxType = .separator
        bottomRule.boxType = .separator
        addSubview(topRule)
        addSubview(bottomRule)
        addSubview(content)

        build(closeButton, title: state.imp("PBBClose", "Закрыть"),
              hint: state.impHint("PBBClose", "Закрыть мастер")) { [weak self] in self?.onClose() }
        build(backButton, title: state.imp("PBBPrev", "Назад"),
              hint: state.impHint("PBBPrev", "Предыдущая страница")) { [weak self] in
            self?.model.goBack()
        }
        build(nextButton, title: state.imp("PBBNext", "Дальше"),
              hint: state.impHint("PBBNext", "Следующая страница")) { [weak self] in
            self?.advance()
        }
        // Ввод — «Дальше»: страницы мастера листаются с клавиатуры.
        nextButton.keyEquivalent = "\r"

        runBar.style = .bar
        runBar.isIndeterminate = false
        runBar.minValue = 0
        runBar.maxValue = 1
        runBar.isHidden = true
        addSubview(runBar)
        runStatus.font = .systemFont(ofSize: 10)
        runStatus.textColor = .secondaryLabelColor
        runStatus.lineBreakMode = .byTruncatingMiddle
        addSubview(runStatus)

        buildScanningOverlay()

        pages[.intro] = ImportIntroPage(state: state, model: model)
        pages[.versions] = ImportVersionsPage(state: state, model: model)
        for page in [ImportWizardModel.Page.modules, .templates, .images] {
            pages[page] = ImportListPage(state: state, model: model, page: page)
        }
        pages[.summary] = ImportSummaryPage(state: state, model: model,
                                            onImport: { [weak self] in self?.confirmAndRun() })

        observers.append(model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        model.adopt(destination: ImportWizardWindow.destination(for: state))
    }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        let width = bounds.width
        titleLabel.frame = NSRect(x: 14, y: 10, width: max(0, width - 28), height: 18)
        stepLabel.frame = NSRect(x: 14, y: 30, width: max(0, width - 28), height: 14)
        topRule.frame = NSRect(x: 0, y: 50, width: width, height: 1)

        let footerTop = bounds.height - 46
        bottomRule.frame = NSRect(x: 0, y: footerTop, width: width, height: 1)
        content.frame = NSRect(x: 14, y: 60, width: max(0, width - 28),
                               height: max(0, footerTop - 74))
        shown?.frame = content.bounds

        let overlay = NSSize(width: 190, height: 74)
        scanning.frame = NSRect(x: content.frame.midX - overlay.width / 2,
                                y: content.frame.midY - overlay.height / 2,
                                width: overlay.width, height: overlay.height)

        let buttonY = footerTop + 10
        closeButton.frame = NSRect(x: 12, y: buttonY, width: 110, height: 24)
        let nextWidth = max(110, nextButton.intrinsicContentSize.width + 24)
        nextButton.frame = NSRect(x: width - 12 - nextWidth, y: buttonY, width: nextWidth, height: 24)
        backButton.frame = NSRect(x: nextButton.frame.minX - 8 - 100, y: buttonY, width: 100, height: 24)
        runBar.frame = NSRect(x: 132, y: buttonY + 6, width: 160, height: 12)
        runStatus.frame = NSRect(x: 300, y: buttonY + 4, width: max(0, backButton.frame.minX - 310),
                                 height: 16)
    }

    // MARK: - Перерисовка

    /// Внутренний, а не приватный: самопроверка перебирает страницы сама и
    /// снимает каждую в картинку — иначе «мастер собран» осталось бы словами.
    func refresh() {
        titleLabel.stringValue = pageTitle
        stepLabel.stringValue = pageStep

        if let page = pages[model.page], page !== shown {
            shown?.removeFromSuperview()
            content.addSubview(page)
            page.frame = content.bounds
            shown = page
        }
        (shown as? ImportPageRefreshing)?.refreshPage()

        backButton.isEnabled = model.canGoBack
        if model.page == .summary {
            nextButton.title = state.imp("PBBImport", "Импортировать")
            nextButton.toolTip = OurWords.t("Перенести отмеченное в библиотеку программы")
            nextButton.isEnabled = !model.isRunning && model.plannedCount > 0
        } else {
            nextButton.title = state.imp("PBBNext", "Дальше")
            nextButton.toolTip = state.impHint("PBBNext", "Следующая страница")
            nextButton.isEnabled = model.canGoNext
        }

        runBar.isHidden = !model.isRunning
        runBar.doubleValue = model.runProgress
        runStatus.stringValue = model.isRunning ? model.runStatus : ""

        scanning.isHidden = !model.isScanning
        if model.isScanning { scanningSpinner.startAnimation(nil) } else { scanningSpinner.stopAnimation(nil) }

        applyOutcomeIfNeeded()
        showProblemIfNeeded()
        needsLayout = true
    }

    /// Вид страницы — для самопроверки.
    func view(of page: ImportWizardModel.Page) -> NSView? { pages[page] }

    private var pageTitle: String {
        switch model.page {
        case .intro:     return OurWords.t("Импорт модулей, шаблонов и фонов")
        case .versions:  return state.imp("Label3", "Предыдущие версии программы:")
        case .modules:   return state.imp("Label4",
                                          "Выберите какие модули Библии/Песенников будут импортированы:")
        case .templates: return state.imp("Label6", "Выберите какие шаблоны слайда будут импортированы:")
        case .images:    return OurWords.t("Выберите, какие фоновые изображения будут перенесены:")
        case .summary:   return OurWords.t("Будет перенесено:")
        }
    }

    /// Номер подраздела руководства — чтобы окно можно было сверять с ним
    /// страница за страницей.
    private var pageStep: String {
        switch model.page {
        case .intro:     return "4.2"
        case .versions:  return "4.2.1"
        case .modules:   return "4.2.2"
        case .templates: return "4.2.3"
        case .images:    return "4.2.4"
        case .summary:   return "4.2.6"
        }
    }

    // MARK: - Действия

    private func advance() {
        if model.page == .summary { confirmAndRun() } else { model.goNext() }
    }

    /// Підтвердження перед перенесенням.
    private func confirmAndRun() {
        guard !model.isRunning, model.plannedCount > 0 else { return }
        let alert = NSAlert()
        alert.messageText = OurWords.t("Импорт в библиотеку программы")
        alert.informativeText = OurWords.t("Перенести отмеченные модули, шаблоны и фоны в библиотеку программы?")
        alert.addButton(withTitle: state.imp("PBBImport", "Импортировать"))
        alert.addButton(withTitle: state.vb("BBCancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        appliedOutcome = false
        model.run()
    }

    private func showProblemIfNeeded() {
        guard let problem = model.problem else { reportedProblem = nil; return }
        guard reportedProblem != problem else { return }
        reportedProblem = problem
        let alert = NSAlert()
        alert.messageText = state.imp("ErrorMessages3", "Ошибка")
        alert.informativeText = problem
        alert.addButton(withTitle: state.imp("PBBClose", "Закрыть"))
        alert.runModal()
        model.problem = nil
    }

    /// Після перенесення програма не перезапускається: перенесені модулі й
    /// пісенники підключаються до списку перекладів поіменно, тека з фонами
    /// — до списку тек із фонами, і бібліотека перечитується. Робиться це
    /// один раз на один підсумок.
    private func applyOutcomeIfNeeded() {
        guard let outcome = model.outcome, outcome.total > 0, !appliedOutcome else { return }
        appliedOutcome = true
        state.adoptImported(modules: outcome.importedModules,
                            backgroundsFolder: outcome.images.isEmpty ? nil : model.destination.backgroundsFolder)
    }

    // MARK: - Мелочи

    private func build(_ button: NSButton, title: String, hint: String,
                       _ action: @escaping () -> Void) {
        button.title = title
        button.bezelStyle = .rounded
        button.toolTip = hint.isEmpty ? nil : hint
        button.target = NativeForm.Trampoline.shared
        button.action = #selector(NativeForm.Trampoline.fire(_:))
        NativeForm.Trampoline.shared.bind(button, action)
        addSubview(button)
    }

    private func buildScanningOverlay() {
        scanning.wantsLayer = true
        scanning.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        scanning.layer?.borderColor = NSColor.separatorColor.cgColor
        scanning.layer?.borderWidth = 1
        scanning.layer?.cornerRadius = 8
        scanningSpinner.style = .spinning
        scanningSpinner.controlSize = .small
        scanningSpinner.frame = NSRect(x: 87, y: 42, width: 16, height: 16)
        scanning.addSubview(scanningSpinner)
        let caption = NSTextField(labelWithString: OurWords.t("Просмотр источника…"))
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = .secondaryLabelColor
        caption.alignment = .center
        caption.frame = NSRect(x: 8, y: 16, width: 174, height: 16)
        scanning.addSubview(caption)
        scanning.isHidden = true
        addSubview(scanning)
    }
}

/// Страница, которой есть что обновить при перерисовке мастера.
@MainActor
protocol ImportPageRefreshing: AnyObject {
    func refreshPage()
}
