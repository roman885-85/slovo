import AppKit
import Combine
import SlovoCore

/// «Конструктор слайда» (раздел 6.3) — на AppKit.
///
/// Раскладка формы `SlideConstructorForm`: сверху выбор шаблона с кнопками
/// сохранения, кнопка «Тест анимации» с ползунком задержки и переключатель
/// «Отобразить для:». Ниже слева список объектов, фон и переход, по центру
/// предпросмотр с перетаскиванием рамок, справа «Параметры» и «Анимация».
/// Внизу «Закрыть».
///
/// Любой уход с текущего шаблона сперва спрашивает про несохранённые правки —
/// у автора это то же сообщение TextMessages11.
@MainActor
final class NativeSlideConstructor: NSView, NativeListSource {

    private let state: AppState
    private let model = SlideConstructorModel()

    /// Самопроверке: модель и перечитывание значений панелей — тем же путём,
    /// каким идут живые правки (`refresh()` при том же отпечатке).
    var modelForCheck: SlideConstructorModel { model }
    func refreshValuesForCheck() { panels.refreshValues() }
    private let onClose: () -> Void
    private var saveButton: NSButton!
    private var backgroundCaption: NSTextField!
    private var transitionCaption: NSTextField!
    private let text: ConstructorText
    private var observers: [AnyCancellable] = []

    private let topBar = NSStackView()
    private let objects = NativeTable(detailWidth: 0)
    private let leftBar = NSStackView()
    private let canvas: NativeConstructorCanvas
    private let panels: NativeConstructorPanels
    private let bottomNote = NSTextField(labelWithString: "")
    private let delayLabel = NSTextField(labelWithString: "")
    private var templateButton: NSPopUpButton!
    private var backgroundButton: NSPopUpButton!
    private var transitionButton: NSPopUpButton!
    private var sceneTabs: NSSegmentedControl!
    private var closeButton: NSButton!

    init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
        text = ConstructorText(language: state.language)
        canvas = NativeConstructorCanvas(model: model)
        panels = NativeConstructorPanels(model: model, text: text)
        super.init(frame: NSRect(x: 0, y: 0, width: 1240, height: 760))
        build()
        model.attach(schemes: state.schemes, baseStyle: state.style)
        observers.append(model.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    /// Enter у полі закінчує правку поля, а не закриває Конструктор.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if NativeForm.endsFieldEditing(on: event, in: window) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Подпись задержки прогона: «1200 мс».
    private var delayText: String { "\(Int(model.testDelay)) \(text("Label10", "мс"))" }

    /// Сколько объектов стоит в списке — для самопроверки.
    var listedObjects: Int { objects.itemCount }

    /// Закрытие идёт тем же путём, что смена шаблона: сперва вопрос про
    /// правки. Ответ «Сохранить» пишет и применяет.
    func requestClose() {
        guard model.asksToSave(before: .close) else { finishLive(); onClose(); return }
        switch askAboutChanges() {
        case .save: model.save(); applyToOutputs(); finishLive(); onClose()
        case .discard: finishLive(); onClose()
        case .cancel: break
        }
    }

    /// Живой показ окончен: зал снова рисует сохранённый шаблон.
    private func finishLive() {
        liveWatcher = nil
        state.previewPreset(nil)
    }
    private var liveWatcher: AnyCancellable?

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        for bar in [topBar, leftBar] {
            bar.orientation = .horizontal
            bar.spacing = 6
            bar.alignment = .centerY
            addSubview(bar)
        }

        for button in TemplateButton.beforeList {
            topBar.addArrangedSubview(NativeForm.button(
                OurWords.t(button.mark), hint: text.hint(button.rawValue, button.fallbackHint)) { [weak self] in
                self?.run(button)
            })
        }
        topBar.addArrangedSubview(NativeForm.label(text("Label14", "Шаблон:"), secondary: false))
        templateButton = NSPopUpButton(frame: .zero, pullsDown: false)
        templateButton.target = self
        templateButton.action = #selector(templateChosen)
        // В тесном ряду ужимается список шаблонов, а не кнопки и не
        // переключатель сцен: его подпись обрежется многоточием и останется
        // понятной, а кнопка без подписи — нет.
        templateButton.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        templateButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        // Но не до одних стрелок: имя шаблона должно оставаться читаемым.
        templateButton.translatesAutoresizingMaskIntoConstraints = false
        templateButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        topBar.addArrangedSubview(templateButton)
        for button in TemplateButton.afterList {
            topBar.addArrangedSubview(NativeForm.button(
                OurWords.t(button.mark), hint: text.hint(button.rawValue, button.fallbackHint)) { [weak self] in
                self?.run(button)
            })
        }
        topBar.addArrangedSubview(NativeForm.button(text("BBAnimation", "Тест анимации")) { [weak self] in
            self?.model.runAnimationTest()
        })
        // «Задержка» (Label13) — сколько миллисекунд держать кадр в прогоне
        // анимации. Ползунок авторский, и число рядом — его же: без числа
        // задержку не выставить повторяемо.
        topBar.addArrangedSubview(NativeForm.label(text("Label13", "Задержка:"), secondary: false))
        topBar.addArrangedSubview(NativeForm.slider(
            NativeForm.Tie(get: { [model] in model.testDelay },
                           set: { [weak self] value in
                               self?.model.testDelay = value
                               self?.delayLabel.stringValue = self?.delayText ?? ""
                           }),
            range: 0...3000, format: { _ in "" }, width: 110))
        delayLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        delayLabel.textColor = .labelColor
        topBar.addArrangedSubview(delayLabel)

        topBar.addArrangedSubview(NativeForm.label(text("RGVariantShow", "Отобразить для:"),
                                                   secondary: false))
        sceneTabs = NSSegmentedControl(labels: [text("RGVariantShow->Item0", "Сцена 1 (одного перевода)"),
                                                text("RGVariantShow->Item1", "Сцена 2 (двух переводов)")],
                                       trackingMode: .selectOne, target: self,
                                       action: #selector(sceneChanged))
        sceneTabs.selectedSegment = 0
        sceneTabs.setContentCompressionResistancePriority(.required, for: .horizontal)
        topBar.addArrangedSubview(sceneTabs)
        for view in topBar.arrangedSubviews where view !== templateButton {
            view.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        objects.source = self
        objects.onSelect = { [weak self] _, active, _ in
            guard let self, self.model.preset.objects.indices.contains(active) else { return }
            self.model.selection = self.model.preset.objects[active].id
            self.panels.rebuild()
            self.canvas.needsDisplay = true
        }
        addSubview(objects)

        for button in ObjectListButton.allCases {
            leftBar.addArrangedSubview(NativeForm.button(
                button.mark, hint: text.hint(button.rawValue, button.fallbackHint)) { [weak self] in
                self?.run(button)
            })
        }

        // «Имя файла фона» (6.3.5) и «Как сменяется слайд».
        backgroundButton = NSPopUpButton(frame: .zero, pullsDown: false)
        backgroundButton.target = self
        backgroundButton.action = #selector(backgroundChosen)
        addSubview(backgroundButton)
        backgroundCaption = NativeForm.label(OurWords.t("Фон:"), secondary: true)
        addSubview(backgroundCaption)
        transitionCaption = NativeForm.label(OurWords.t("Переход:"), secondary: true)
        addSubview(transitionCaption)
        transitionButton = NSPopUpButton(frame: .zero, pullsDown: false)
        transitionButton.addItems(withTitles: SlideStyle.Transition.allCases.map { OurWords.t($0.title) })
        transitionButton.target = self
        transitionButton.action = #selector(transitionChosen)
        addSubview(transitionButton)

        canvas.missingFileLabel = text("TextMessages4", "Не найден файл:")
        addSubview(canvas)

        panels.onChange = { [weak self] in
            self?.canvas.needsDisplay = true
            self?.objects.reload()
        }
        // Правка уходит на проектор сразу: владелец хочет видеть изменения
        // в зале на лету, а не после «Сохранить». Закрытие без сохранения
        // возвращает зал к сохранённому шаблону.
        liveWatcher = model.$preset
            .debounce(for: .milliseconds(80), scheduler: DispatchQueue.main)
            .sink { [weak self] preset in self?.state.previewPreset(preset) }
        addSubview(panels)

        bottomNote.font = .systemFont(ofSize: 10)
        bottomNote.textColor = .secondaryLabelColor
        bottomNote.lineBreakMode = .byTruncatingMiddle
        addSubview(bottomNote)

        saveButton = NativeForm.button(OurWords.t("Сохранить"),
                                       hint: text.hint("SBSaveSheme", "Сохранить шаблон")) { [weak self] in
            guard let self else { return }
            self.model.save()
            self.applyToOutputs()
        }
        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command]
        addSubview(saveButton)
        closeButton = NativeForm.button(text("BBOk", "Закрыть"),
                                        hint: text.hint("BBOk", "Закрыть редактирование анимации")) {
            [weak self] in self?.requestClose()
        }
        closeButton.keyEquivalent = "\r"
        addSubview(closeButton)
    }

    /// Новый объект: вид выбирают списком — у автора это тот же набор.
    private func addObject() {
        let kinds = SlideObjectKind.allCases
        let alert = NSAlert()
        alert.messageText = text.hint("SBAddObj", "Добавить объект")
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 24), pullsDown: false)
        popup.addItems(withTitles: kinds.map(\.title))
        alert.accessoryView = popup
        alert.addButton(withTitle: OurWords.t("Ок"))
        alert.addButton(withTitle: OurWords.t("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn,
              kinds.indices.contains(popup.indexOfSelectedItem) else { return }
        model.add(kinds[popup.indexOfSelectedItem])
        refresh()
    }

    // MARK: - Действия

    /// Кнопка шаблона из верхней строки.
    private func run(_ button: TemplateButton) {
        switch button {
        case .new:    newTemplate()
        case .save:   model.save(); applyToOutputs()
        case .saveAs: saveAs()
        case .delete: deleteTemplate()
        }
    }

    /// Кнопка списка объектов.
    private func run(_ button: ObjectListButton) {
        switch button {
        case .add:    addObject()
        case .delete: model.deleteSelected()
        case .copy:   model.duplicateSelected()
        case .up:     model.moveSelectedInList(by: -1)
        case .down:   model.moveSelectedInList(by: 1)
        }
        refresh()
    }

    @objc private func sceneChanged() {
        model.scene = sceneTabs.selectedSegment == 1 ? .dual : .single
        canvas.needsDisplay = true
        panels.rebuild()
    }

    @objc private func templateChosen() {
        let index = templateButton.indexOfSelectedItem
        let presets = model.library.presets
        // Сперва свои шаблоны, следом авторские `.sch` — они берутся только
        // за основу: сохраняются правки уже своим файлом.
        let schemes = model.schemes?.templates ?? []
        guard index >= 0 else { return }
        // Вибрали в списку той самий шаблон, що й відкритий, — міняти нічого,
        // і питати про збереження нема про що. Власник: «після деяких змін
        // вискакує вікно про збереження», а натиснувши «Зберегти», він
        // опинявся поза правкою.
        if index < presets.count, presets[index].id == model.preset.id { return }
        let departure: SlideConstructorModel.Departure = index < presets.count ? .switchPreset : .importScheme
        if model.asksToSave(before: departure) {
            switch askAboutChanges() {
            case .save: model.save(); applyToOutputs()
            case .discard: break
            case .cancel: refresh(); return
            }
        }
        if index < presets.count {
            model.load(presets[index])
        } else {
            let position = index - presets.count
            guard schemes.indices.contains(position) else { return }
            model.importScheme(schemes[position])
        }
        refresh()
    }

    @objc private func backgroundChosen() {
        let files = backgroundFiles
        let index = backgroundButton.indexOfSelectedItem
        if index == 0 {
            model.preset.background.imagePath = nil
        } else if index == files.count + 1 {
            // Последний пункт — «Выбрать файл…»: у автора рядом со списком
            // стоит кнопка «Импортировать файл фона».
            if let url = model.chooseImageFile(message: text("Label38", "Имя файла фона:")) {
                model.preset.background.imagePath = url.path
            }
        } else if files.indices.contains(index - 1) {
            model.preset.background.imagePath = files[index - 1].path
        }
        canvas.needsDisplay = true
        refresh()
    }

    @objc private func transitionChosen() {
        let all = SlideStyle.Transition.allCases
        let index = transitionButton.indexOfSelectedItem
        guard all.indices.contains(index) else { return }
        model.preset.transition = all[index]
    }

    private func newTemplate() {
        // Создание нового шаблона заменяет текущий целиком, поэтому идёт тем
        // же путём, что смена шаблона: сперва «Шаблон изменен. Сохранить?».
        if model.asksToSave(before: .newTemplate) {
            switch askAboutChanges() {
            case .save: model.save(); applyToOutputs()
            case .discard: break
            case .cancel: return
            }
        }
        guard let name = askName(title: text("TextMessages12", "Создание шаблона"), value: "") else { return }
        model.makeNew(named: name)
        refresh()
    }

    private func saveAs() {
        guard let name = askName(title: text("TextMessages0", "Сохранение шаблона"),
                                 value: model.preset.name) else { return }
        // Совпадение имён — не ошибка, но переписать шаблон молча нельзя.
        if model.nameIsTaken(name) {
            let alert = NSAlert()
            alert.messageText = text("TextMessages0", "Сохранение шаблона")
            alert.informativeText = OurWords.t("Шаблон с таким именем уже есть. Переписать?")
            alert.addButton(withTitle: OurWords.t("Да"))
            alert.addButton(withTitle: OurWords.t("Нет"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.saveAs(name)
        applyToOutputs()
        refresh()
    }

    private func deleteTemplate() {
        // Заголовок окна — TextMessages14, вопрос — TextMessages13.
        let alert = NSAlert()
        alert.messageText = text("TextMessages14", "Удаление шаблона слайда")
        alert.informativeText = text("TextMessages13", "Действительно удалить шаблон слайда:")
            + " " + model.preset.name
        alert.addButton(withTitle: OurWords.t("Да"))
        alert.addButton(withTitle: OurWords.t("Нет"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.deleteCurrent()
        refresh()
    }

    private enum Answer { case save, discard, cancel }

    private func askAboutChanges() -> Answer {
        let alert = NSAlert()
        alert.messageText = text("TextMessages11", "Шаблон изменен. Сохранить?")
        alert.addButton(withTitle: OurWords.t("Сохранить"))
        alert.addButton(withTitle: OurWords.t("Не сохранять"))
        alert.addButton(withTitle: OurWords.t("Отмена"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .save
        case .alertSecondButtonReturn: return .discard
        default:                       return .cancel
        }
    }

    private func askName(title: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text("TextMessages1", "Введите имя нового шаблона")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.stringValue = value
        alert.accessoryView = field
        alert.addButton(withTitle: OurWords.t("Ок"))
        alert.addButton(withTitle: OurWords.t("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// Сохранённый шаблон сразу уходит в зал.
    ///
    /// Иначе выходило так: правки видны на холсте и больше нигде — ни на
    /// проекторе, ни в предпросмотре. Сохранил — значит применил: за этим в
    /// Конструктор и приходят.
    private func applyToOutputs() {
        state.reloadPresets()
        state.applyPreset(model.preset)
    }

    // MARK: - Обновление

    private var backgroundFiles: [URL] {
        model.backgroundFolders.flatMap { model.images(in: $0) }
    }

    /// Отпечаток того, что требует пересборки окна: сам шаблон, состав его
    /// объектов, выбранный объект и сцена. Правка значения — цвета, ширины,
    /// прозрачности — сюда не входит: она меняет числа в полях, а не поля.
    private var structure = 0

    private func refresh() {
        var hasher = Hasher()
        hasher.combine(model.preset.id)
        hasher.combine(model.preset.objects.map(\.id))
        hasher.combine(model.selectedObject?.id)
        hasher.combine(model.selectedObject?.kind)
        hasher.combine(model.scene)
        hasher.combine(model.library.presets.map(\.id))
        hasher.combine(model.preset.background.imagePath)
        hasher.combine(model.preset.transition)
        hasher.combine(model.selectedObject?.imagePath)
        hasher.combine(model.selectedObject?.maskPath)
        let fingerprint = hasher.finalize()

        // Дешёвая часть — на каждое изменение.
        delayLabel.stringValue = delayText
        canvas.sample = sample
        canvas.needsDisplay = true
        let folder = PresetLibrary.defaultFolder.path
        bottomNote.stringValue = model.isDirty
            ? OurWords.t("Есть несохранённые правки. Шаблоны лежат в %s", folder)
            : OurWords.t("Шаблоны лежат в %s", folder)

        // Поменялось лишь значение: поля стоят, обновляем числа в них.
        // Раньше на каждое движение ползунка заново заполнялись списки
        // шаблонов и фонов (с обходом папок на диске), собиралась панель из
        // сорока полей и перечитывался список объектов — по 400 мс на шаг,
        // и владелец видел «фризы».
        guard fingerprint != structure else {
            panels.refreshValues()
            objects.reload()
            return
        }
        structure = fingerprint

        // Список шаблонов: свои, затем авторские.
        // Имена встроенных шаблонов — на языке интерфейса; свои имена
        // владельца словарь не знает и оставит как есть.
        let presets = model.library.presets.map { OurWords.t($0.name) }
        let schemes = (model.schemes?.templates ?? []).map { OurWords.t("Из папки Templates: ") + $0.name }
        templateButton.removeAllItems()
        templateButton.addItems(withTitles: presets + schemes)
        if let index = model.library.presets.firstIndex(where: { $0.id == model.preset.id }) {
            templateButton.selectItem(at: index)
        }

        let files = backgroundFiles
        backgroundButton.removeAllItems()
        backgroundButton.addItem(withTitle: text("TextMessages10", "Нет"))
        backgroundButton.addItems(withTitles: files.map(\.lastPathComponent))
        backgroundButton.addItem(withTitle: OurWords.t("Выбрать файл…"))
        if let path = model.preset.background.imagePath,
           let index = files.firstIndex(where: { $0.path == path }) {
            backgroundButton.selectItem(at: index + 1)
        }

        if let index = SlideStyle.Transition.allCases.firstIndex(of: model.preset.transition) {
            transitionButton.selectItem(at: index)
        }

        panels.rebuild()
        objects.reload()
        needsLayout = true
    }

    /// Подставляем то, что сейчас выбрано в программе: длинный стих сразу
    /// показывает, влезает ли он в рамку, а короткий — нет.
    private var sample: ConstructorSample {
        var sample = ConstructorSample()
        let slide = state.slide
        sample.mainText = slide.mainText.isEmpty
            ? "Для моєї ноги Твоє слово світильник, то світло для стежки моєї." : slide.mainText
        sample.secondaryText = slide.secondaryTexts.first
            ?? "Thy word is a lamp unto my feet, and a light unto my path."
        sample.reference = slide.reference.isEmpty ? "Пс. 118:105" : slide.reference
        sample.primaryReference = sample.reference
        sample.secondaryReference = sample.reference
        if let primary = state.primaryModule {
            sample.moduleNameFirst = primary.info.name
            sample.moduleShortNameFirst = primary.info.shortName
        }
        if let second = state.secondaryModuleIDs.first.flatMap({ state.module($0) }) {
            sample.moduleNameSecond = second.info.name
            sample.moduleShortNameSecond = second.info.shortName
        }
        sample.songTitle = state.selectedSong?.title ?? "Название песни"
        return sample
    }

    // MARK: - Раскладка

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        topBar.frame = NSRect(x: gap, y: gap, width: bounds.width - gap * 2, height: 28)
        let top = topBar.frame.maxY + gap
        let bottom = bounds.height - 44

        let leftWidth: CGFloat = 300
        leftBar.frame = NSRect(x: gap, y: top, width: leftWidth, height: 26)
        objects.frame = NSRect(x: gap, y: leftBar.frame.maxY + 4, width: leftWidth,
                               height: max(0, bottom - leftBar.frame.maxY - 72))
        // Подписи у выпадающих списков: без них «Ні» и «Розчинення» внизу
        // ни о чём не говорят.
        let captionWidth: CGFloat = 78
        backgroundCaption.frame = NSRect(x: gap, y: objects.frame.maxY + 6, width: captionWidth, height: 24)
        backgroundButton.frame = NSRect(x: gap + captionWidth, y: objects.frame.maxY + 6, width: leftWidth - captionWidth, height: 24)
        transitionCaption.frame = NSRect(x: gap, y: backgroundButton.frame.maxY + 6, width: captionWidth, height: 24)
        transitionButton.frame = NSRect(x: gap + captionWidth, y: backgroundButton.frame.maxY + 6,
                                        width: leftWidth - captionWidth, height: 24)

        let rightWidth: CGFloat = 330
        panels.frame = NSRect(x: bounds.width - rightWidth - gap, y: top,
                              width: rightWidth, height: max(0, bottom - top))
        let centreLeft = leftWidth + gap * 2
        canvas.frame = NSRect(x: centreLeft, y: top,
                              width: max(0, panels.frame.minX - centreLeft - gap),
                              height: max(0, bottom - top))

        bottomNote.frame = NSRect(x: gap, y: bounds.height - 34, width: bounds.width - 160, height: 16)
        closeButton.frame = NSRect(x: bounds.width - gap - 110, y: bounds.height - 38, width: 110, height: 24)
        saveButton.frame = NSRect(x: closeButton.frame.minX - 8 - 120, y: bounds.height - 38, width: 120, height: 24)
    }

    // MARK: - Список объектов

    var rowCount: Int { model.preset.objects.count }

    func row(at index: Int) -> NativeRow {
        let object = model.preset.objects[index]
        let values = object.values(in: model.scene)
        var row = NativeRow()
        row.lead = values.isVisible ? "●" : "○"
        row.text = object.name.isEmpty ? object.kind.title : object.name
        row.textColor = values.isVisible ? .labelColor : .secondaryLabelColor
        return row
    }
}
