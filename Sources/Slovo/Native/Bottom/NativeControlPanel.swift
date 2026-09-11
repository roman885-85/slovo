import AppKit
import SlovoCore

/// Мініатюра з підписом зверху і приписом знизу: шаблон слайда, фон слайда,
/// спільний фон. Усі три влаштовано однаково, відрізняються лише тим, що робить
/// клацання.
@MainActor
final class NativeBottomThumbnail: NSView {

    static let pictureSize = NSSize(width: 96, height: 54)
    static let fullHeight: CGFloat = 12 + pictureSize.height + 12

    private let title = NativeBottomCaption()
    private let picture = NSImageView(frame: .zero)
    private let note = NativeBottomCaption()
    private let frameBox = NSView(frame: .zero)

    /// Що робити по клацанню і що показати по правій кнопці.
    var onClick: (() -> Void)?
    var onMenu: (() -> NSMenu?)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        title.font = .systemFont(ofSize: 10)
        note.font = .systemFont(ofSize: 9)
        note.textColor = .tertiaryLabelColor
        note.lineBreakMode = .byTruncatingMiddle

        frameBox.wantsLayer = true
        frameBox.layer?.cornerRadius = 3
        frameBox.layer?.masksToBounds = true
        frameBox.layer?.borderWidth = 1

        picture.imageScaling = .scaleProportionallyUpOrDown
        picture.wantsLayer = true

        frameBox.addSubview(picture)
        addSubview(title)
        addSubview(frameBox)
        addSubview(note)
        applyColors()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        title.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 12)
        frameBox.frame = NSRect(x: 0, y: 12,
                                width: Self.pictureSize.width, height: Self.pictureSize.height)
        picture.frame = frameBox.bounds
        note.frame = NSRect(x: 0, y: 12 + Self.pictureSize.height,
                            width: Self.pictureSize.width, height: 12)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = onMenu?() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    /// Оновити вміст. Картинка читається через спільний кеш: без нього фон
    /// розкодовувався б заново на кожне оновлення панелі.
    func apply(title text: String, url: URL?, note caption: String,
               hint: String, dimmed: Bool) {
        title.stringValue = text
        note.stringValue = caption
        toolTip = hint
        picture.alphaValue = dimmed ? 0.4 : 1
        if let url, let image = ImageCache.thumbnail(at: url, height: 80) {
            picture.image = image
        } else {
            picture.image = NSImage(systemSymbolName: "photo", accessibilityDescription: text)
            picture.contentTintColor = .tertiaryLabelColor
        }
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            frameBox.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            frameBox.layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// Панель «Керування» (13) — правий нижній кут вікна.
///
/// Два ряди кнопок перегортання, «Показати» і «Сховати», а під ними три
/// мініатюри: шаблон слайда, фон слайда і спільний фон.
///
/// Панель постійна: кнопки заводяться один раз і живуть увесь час роботи.
/// На зміну вірша тут не відбувається нічого — жодного перерахунку.
@MainActor
final class NativeControlPanel: NSView {

    private let state: AppState

    private var stepButtons: [NativeBottomIconButton] = []
    /// Російські ключі підказок кнопок переходу — щоб при зміні мови
    /// перекласти їх заново, а не лишити такими, якими вони були при побудові.
    private var stepHintKeys: [String] = []
    private var showButton: NativeBottomLabelButton!
    private var hideButton: NativeBottomLabelButton!
    private let separator = NSView(frame: .zero)
    private let template = NativeBottomThumbnail(frame: .zero)
    private let slideBackground = NativeBottomThumbnail(frame: .zero)
    private let commonBackground = NativeBottomThumbnail(frame: .zero)

    private var tokens: [Signals.Token] = []

    init(state: AppState) {
        self.state = state
        super.init(frame: .zero)

        separator.wantsLayer = true
        buildButtons()
        addSubview(separator)
        addSubview(template)
        addSubview(slideBackground)
        addSubview(commonBackground)
        wireThumbnails()
        applyColors()

        tokens.append(Signals.shared.subscribe([.slide, .language]) { [weak self] _ in
            self?.refresh()
        })
        tokens.append(Signals.shared.subscribe(.live) { [weak self] in self?.refreshLive() })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let step: CGFloat = 26
        let gap: CGFloat = 3
        for (index, button) in stepButtons.enumerated() {
            let column = CGFloat(index % 3)
            let line = CGFloat(index / 3)
            button.frame = NSRect(x: column * (step + gap), y: line * (20 + gap),
                                  width: step, height: 20)
        }
        let navWidth = step * 3 + gap * 2
        showButton.frame = NSRect(x: navWidth + 8, y: 0, width: 108, height: 21)
        hideButton.frame = NSRect(x: navWidth + 8, y: 24, width: 108, height: 21)

        let barY: CGFloat = 48
        separator.frame = NSRect(x: 0, y: barY, width: bounds.width, height: 1)

        let thumbY = barY + 6
        let thumbWidth = NativeBottomThumbnail.pictureSize.width
        let thumbHeight = NativeBottomThumbnail.fullHeight
        for (index, thumbnail) in [template, slideBackground, commonBackground].enumerated() {
            thumbnail.frame = NSRect(x: CGFloat(index) * (thumbWidth + 8), y: thumbY,
                                     width: thumbWidth, height: thumbHeight)
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            separator.layer?.backgroundColor = NSColor.separatorColor.cgColor
        }
    }

    // MARK: - Кнопки

    private func buildButtons() {
        // Порядок як у колишньому вікні: зверху назад, знизу вперед, і в кінці
        // повернення до поточного вірша і знімок екрана.
        let plan: [(String, String, () -> Void)] = [
            ("chevron.left.2", "Предыдущая глава", { [weak self] in self?.state.stepChapter(by: -1) }),
            ("chevron.left", "Предыдущий стих", { [weak self] in self?.state.stepVerse(by: -1) }),
            ("arrow.counterclockwise", "К текущему стиху", { [weak self] in
                guard let self else { return }
                self.state.scrollToCurrentVerse += 1
            }),
            ("chevron.right.2", "Следующая глава", { [weak self] in self?.state.stepChapter(by: 1) }),
            ("chevron.right", "Следующий стих", { [weak self] in self?.state.stepVerse(by: 1) }),
            ("camera", "Сделать снимок экрана слайда", { [weak self] in self?.state.saveScreenshot() }),
        ]
        for (symbol, hint, action) in plan {
            let button = NativeBottomIconButton(symbol: symbol, hint: OurWords.t(hint), bordered: true, action: action)
            stepButtons.append(button)
            stepHintKeys.append(hint)
            addSubview(button)
        }

        // Кнопка зобов'язана робити рівно те саме, що пункт меню «Показати слайд»
        // і F5: підготовлений вірш іде в зал і пишеться в «Історію».
        showButton = NativeBottomLabelButton(symbol: "eye", title: "Показать", hint: "Показать слайд",
                                       prominent: true) { [weak self] in self?.state.showCurrent() }
        hideButton = NativeBottomLabelButton(symbol: "eye.slash", title: "Скрыть", hint: "Скрыть слайд",
                                       prominent: false) { [weak self] in self?.state.isLive = false }
        addSubview(showButton)
        addSubview(hideButton)
    }

    private func wireThumbnails() {
        template.onClick = { [weak self] in self?.chooseTemplate(from: self?.template) }
        // Кнопка називається «Фон Слайда» — вона й має вибирати фон.
        // Раніше вона відкривала список шаблонів: підпис обіцяв одне, а
        // робила інше, і вибраний «фон» пропадав при наступному запуску
        // разом зі зміною шаблону.
        slideBackground.onClick = { [weak self] in self?.chooseSlideBackground(from: self?.slideBackground) }
        commonBackground.onClick = { [weak self] in self?.chooseCommonBackground() }
        commonBackground.onMenu = { [weak self] in self?.commonBackgroundMenu() }
    }

    // MARK: - Оновлення

    private func refresh() {
        // Підказки кнопок переходу — мовою, що зараз обрана: сюди приходять
        // і за поводом `.language`.
        for (button, key) in zip(stepButtons, stepHintKeys) { button.setHint(OurWords.t(key)) }
        let current = state.currentTemplate
        // У свого шаблону з Конструктора немає готової картинки на диску:
        // авторські шаблони лежать теками з `thumbs/scene1.jpg`, а свій —
        // одним файлом. Без цієї гілки на місці обох мініатюр лишалися
        // порожні сірі квадрати, і виглядало це як поломка.
        let mine = state.slidePreset
        let backdrop = mine.flatMap { state.presetImageURL($0.background.imagePath) }
        template.apply(title: state.text("Label3D10", default: "Шаблон:"),
                       url: mine == nil
                           ? current?.thumbnailURL(state.slide.secondaryTexts.isEmpty ? .single : .dual)
                           : backdrop,
                       note: state.templateName.isEmpty ? OurWords.t("не выбран") : state.templateName,
                       hint: state.hint("PngSBSelSlideTemplate", default: "Шаблон Слайда"),
                       dimmed: false)
        // Мініатюра показує те, що й справді лежить під текстом: спершу
        // свій вибір, і лише якщо його немає — фон шаблону. Поки вона дивилася
        // тільки в шаблон, людина вибирала картинку, а квадратик лишався
        // колишнім — і виглядало це як «вибір не спрацював».
        let ownBackdrop = state.slideBackgroundPath.map { URL(fileURLWithPath: $0) }
        let slideURL = ownBackdrop ?? (mine == nil ? current?.backgroundURL : backdrop)
        slideBackground.apply(title: state.text("Label3D22", default: "Фон Слайда:"),
                              url: slideURL,
                              note: slideURL?.lastPathComponent
                                  ?? OurWords.t("из шаблона"),
                              hint: state.hint("PngSBSelSlideBg", default: "Фон Слайда"),
                              dimmed: false)
        commonBackground.apply(title: state.text("Label3D23", default: "Фон Общий:"),
                               url: state.commonBackgroundPath.map { URL(fileURLWithPath: $0) },
                               note: state.showsCommonBackground ? OurWords.t("включён") : OurWords.t("выключен"),
                               hint: state.hint("PngSBSelCommonBg", default: "Общий фон"),
                               dimmed: !state.showsCommonBackground)
        showButton.apply(title: state.text("SBShowOutScr", default: "Показать"),
                         hint: state.hint("SBShowOutScr", default: "Показать слайд"))
        hideButton.apply(title: state.text("SBHideOutScr", default: "Скрыть"),
                         hint: state.hint("SBHideOutScr", default: "Скрыть слайд"))
        refreshLive()
    }

    private func refreshLive() {
        hideButton.isEnabled = state.isLive
    }

    // MARK: - Вибір шаблону і фону

    /// Шаблони показуються меню з мініатюрами, а не окремим віконцем:
    /// меню піднімається миттєво і закривається клацанням, а вікно треба ще
    /// побудувати, показати і прибрати — і все це між двома віршами.
    private func chooseTemplate(from anchor: NSView?) {
        let templates = state.schemes?.templates ?? []
        // Свої шаблони перечитуємо при кожному відкритті списку: Конструктор
        // пише їх файлами, і щойно збережений зобов'язаний бути тут.
        state.reloadPresets()
        let mine = state.presets.presets
        guard !templates.isEmpty || !mine.isEmpty else { return }

        let menu = NSMenu()
        menu.addItem(withTitle: state.text("Label3D10", default: "Шаблон:"),
                     action: nil, keyEquivalent: "")
        menu.addItem(.separator())

        // Свої — першими: їх зібрали руками, і беруть їх частіше.
        if !mine.isEmpty {
            menu.addItem(withTitle: OurWords.t("Свои шаблоны"), action: nil, keyEquivalent: "")
            for preset in mine {
                let item = NSMenuItem(title: preset.name,
                                      action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
                let action = NativeBottomMenuAction { [weak self] in self?.state.applyPreset(preset) }
                item.target = action
                item.representedObject = action
                item.state = preset.id == state.slidePreset?.id ? .on : .off
                menu.addItem(item)
            }
            if state.slidePreset != nil {
                let back = NSMenuItem(title: OurWords.t("Вернуться к авторскому"),
                                      action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
                let action = NativeBottomMenuAction { [weak self] in self?.state.applyPreset(nil) }
                back.target = action
                back.representedObject = action
                menu.addItem(back)
            }
            menu.addItem(.separator())
        }

        for scheme in templates {
            let item = NSMenuItem(title: scheme.name,
                                  action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
            let name = scheme.name
            let action = NativeBottomMenuAction { [weak self] in
                self?.state.applyPreset(nil)
                self?.state.applyTemplate(named: name)
            }
            item.target = action
            item.representedObject = action
            item.state = (state.slidePreset == nil && scheme.name == state.templateName) ? .on : .off
            if let url = scheme.thumbnailURL(.single), let image = ImageCache.thumbnail(at: url, height: 28) {
                item.image = image
            }
            menu.addItem(item)
        }
        let view = anchor ?? self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    /// Вибір фону слайда: картинки з теки `BackGrounds`, свій файл і «немає».
    ///
    /// Відкрито назовні: те саме робить клавіша «Вибрати фон Слайда»
    /// (`OpenSlideBG`, у поставці Ctrl+Alt+B) — див. `NativeWindowHotkeys`.
    func chooseSlideBackground(from anchor: NSView?) {
        let menu = NSMenu()

        let none = NSMenuItem(title: OurWords.t("Убрать картинку"),
                              action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
        let noneAction = NativeBottomMenuAction { [weak self] in self?.state.setBackground(nil) }
        none.target = noneAction
        none.representedObject = noneAction
        none.state = state.slideBackgroundPath == nil ? .on : .off
        menu.addItem(none)
        menu.addItem(.separator())

        for url in state.backgroundImages {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent,
                                  action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
            let action = NativeBottomMenuAction { [weak self] in self?.state.setBackground(url) }
            item.target = action
            item.representedObject = action
            item.state = state.slideBackgroundPath == url.path ? .on : .off
            if let image = ImageCache.thumbnail(at: url, height: 28) { item.image = image }
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let pick = NSMenuItem(title: OurWords.t("Выбрать файл…"),
                              action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
        let pickAction = NativeBottomMenuAction { [weak self] in self?.state.chooseBackgroundFile() }
        pick.target = pickAction
        pick.representedObject = pickAction
        menu.addItem(pick)

        let view = anchor ?? self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
    }

    private func commonBackgroundMenu() -> NSMenu {
        let menu = NSMenu()
        let title = state.showsCommonBackground ? OurWords.t("Выключить общий фон") : OurWords.t("Включить общий фон")
        let toggle = NSMenuItem(title: title, action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
        let toggleAction = NativeBottomMenuAction { [weak self] in self?.state.toggleCommonBackground() }
        toggle.target = toggleAction
        toggle.representedObject = toggleAction
        menu.addItem(toggle)

        let clear = NSMenuItem(title: OurWords.t("Убрать картинку"),
                               action: #selector(NativeBottomMenuAction.fire), keyEquivalent: "")
        let clearAction = NativeBottomMenuAction { [weak self] in self?.state.setCommonBackground(nil) }
        clear.target = clearAction
        clear.representedObject = clearAction
        menu.addItem(clear)
        return menu
    }

    /// Вибір спільного фону. Відкрито назовні з тієї самої причини, що й вибір фону
    /// слайда: за ним стоїть клавіша «Вибрати Спільний фон» (`OpenCommonBG`).
    func chooseCommonBackground() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.prompt = OurWords.t("Выбрать")
        panel.message = OurWords.t("Общий фон для всех слайдов")
        panel.directoryURL = state.backgroundImages.first?.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        state.setCommonBackground(url.path)
    }
}
