import AppKit
import Combine
import SlovoCore
import UniformTypeIdentifiers

/// Окно «Параметры» (6.1) — на AppKit.
///
/// Девять вкладок в том же порядке, что у автора: Основные, Дополнительные,
/// Слайд, Модули, Пути, Горячие клавиши, Медиа, Remote API, Обновление.
/// Подписи берутся из файла перевода той же формы `SettingsForm`, поэтому
/// человек, знающий оригинал, находит нужное на том же месте.
///
/// Внизу только «Ок» и «Отмена» — как у автора; всё применяется по «Ок» и
/// только по нему, а «Отмена» возвращает снимок, снятый при открытии.
///
/// Вкладки переезжают на AppKit по одной. Пока какая-то не переехала, она
/// живёт здесь же в `NSHostingView` — окно от этого не ждёт, и человек
/// разницы не видит.
@MainActor
final class NativeSettingsWindow: NSObject, NSWindowDelegate {

    static let shared = NativeSettingsWindow()

    private var window: NSWindow?
    private weak var state: AppState?
    private var session: SettingsStore.EditSession?
    private let store = SettingsStore.shared
    /// Объекты вкладок — живут, пока живёт окно.
    ///
    /// Список берёт источник строк слабой ссылкой, а объекты вкладок
    /// никто не держал: они умирали сразу после сборки окна, и таблица
    /// спрашивала строки у никого. Так вкладки со списками — «Дополнительные»,
    /// «Модули», «Пути», «Remote API», «Горячие клавиши» — стояли с рамками и
    /// кнопками, но без единой строки; владелец это и увидел.
    private var tabObjects: [AnyObject] = []
    /// Смуга вкладок — щоб знати, яку саме скидають.
    private weak var tabsView: NSTabView?

    func show(state: AppState) {
        self.state = state
        store.reload(dataRoot: state.modulesFolder.deletingLastPathComponent())
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        // Снимок снимаем один раз на открытие окна: второй слой сделал бы
        // «Ок» бесполезным — он записал бы поверх собственного снимка.
        session = store.beginEditing()
        // Правки применяются на лету: владелец хочет видеть их на проекторе,
        // не нажимая «Ок». «Отмена» и крестик возвращают прежние значения —
        // и на экране тоже. На диск по-прежнему пишет только «Ок».
        liveWatcher = store.$settings
            .dropFirst()
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] settings in self?.applyLive(settings) }

        // Ширина — под девять вкладок с полными подписями и предпросмотр
        // справа: при 880 подписи вкладок сжимались до «Онов…», «Дода…»,
        // «Гаряч…» — владелец растягивал окно руками каждый раз. Размер
        // запоминается между открытиями, а меньше 1000 окно не сжать — там
        // подписи снова пропадают.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        let size = NSSize(width: min(1180, screen.width - 40), height: min(720, screen.height - 60))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = state.vb("SettingsForm", "Параметры")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 1000, height: 620)
        window.contentView = build(state: state)
        window.center()
        window.setFrameAutosaveName("SettingsWindow")
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    var isOpen: Bool { window?.isVisible ?? false }

    // MARK: - Сборка

    /// Не `private`: самопроверка обходит все вкладки в поисках русских слов
    /// в украинском интерфейсе, не открывая окна.
    func build(state: AppState) -> NSView {
        tabObjects.removeAll()
        func keep<Tab: AnyObject>(_ tab: Tab) -> Tab { tabObjects.append(tab); return tab }
        let root = Root()
        // Живой предпросмотр справа от вкладок: тот же вид, что и в нижней
        // панели, кормится тем же. Владелец просил править настройки «с
        // предпросмотром в реальном времени».
        let preview = NativeSlidePreview(frame: .zero)
        let previewTitle = NativeForm.label(OurWords.t("Предпросмотр"), secondary: true)
        root.preview = preview
        root.previewTitle = previewTitle
        root.addSubview(preview)
        root.addSubview(previewTitle)
        livePreview = preview
        previewWatcher = state.objectWillChange
            .debounce(for: .milliseconds(60), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshPreview() }
        root.onLayout = { [weak self] in self?.refreshPreview() }
        let tabs = NSTabView(frame: .zero)
        tabs.font = .systemFont(ofSize: 12)

        func page(_ caption: String, _ view: NSView) -> NSTabViewItem {
            let item = NSTabViewItem(identifier: caption)
            item.label = caption
            item.view = view
            return item
        }

        // Переехавшие на AppKit.
        tabs.addTabViewItem(page(state.vb("TSSlide", "Слайд"),
                                 keep(NativeSettingsSlideTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSMedia", "Медиа"),
                                 keep(NativeSettingsMediaTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSPath", "Пути"),
                                 keep(NativeSettingsPathsTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSUpdate", "Обновление"),
                                 keep(NativeSettingsUpdateTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSRemoteApi", "Remote API"),
                                 keep(NativeSettingsRemoteTab(state: state, store: store)).page))

        tabs.addTabViewItem(page(state.vb("TSBasic", "Основные"),
                                 keep(NativeSettingsBasicTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TabSheet1", "Дополнительные"),
                                 keep(NativeSettingsAdvancedTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSModules", "Модули"),
                                 keep(NativeSettingsModulesTab(state: state, store: store)).page))
        tabs.addTabViewItem(page(state.vb("TSHotKey", "Горячие клавиши"),
                                 keep(NativeSettingsHotkeysTab(state: state, store: store)).page))

        let ok = NativeForm.button(state.vb("BBOk", "Ок"),
                                   hint: state.vbHint("BBOk", "Применить настройки")) { [weak self] in
            self?.accept()
        }
        ok.keyEquivalent = "\r"
        let cancel = NativeForm.button(state.vb("BBCancel", "Отмена"),
                                       hint: state.vbHint("BBCancel", OurWords.t("Отменить изменения и закрыть"))) { [weak self] in
            self?.discard()
        }
        cancel.keyEquivalent = "\u{1B}"

        // Скидання й перенесення — ліворуч, окремо від «Ок» і «Відмінити»:
        // це дії над усіма налаштуваннями, а не над цим вікном.
        let reset = NativeForm.button(OurWords.t("↺ Сбросить…"),
                                      hint: OurWords.t("Вернуть значения к тем, с которыми программа запускается впервые")) {
            [weak self] in self?.askReset()
        }
        let save = NativeForm.button(OurWords.t("Сохранить в файл…"),
                                     hint: OurWords.t("Сложить все настройки в один файл — перенести на другой компьютер или отложить про запас")) {
            [weak self] in self?.exportSettings()
        }
        let load = NativeForm.button(OurWords.t("Взять из файла…"),
                                     hint: OurWords.t("Прочитать настройки из файла, сохранённого раньше")) {
            [weak self] in self?.importSettings()
        }

        tabsView = tabs
        root.tabs = tabs
        root.leftButtons = [reset, save, load]
        root.addSubview(reset)
        root.addSubview(save)
        root.addSubview(load)
        root.buttons = [cancel, ok]
        root.addSubview(tabs)
        root.addSubview(cancel)
        root.addSubview(ok)
        return root
    }

    /// Раскладка окна: вкладки во всю площадь, ряд кнопок снизу.
    private final class Root: NSView {

        /// Enter у полі записує набране, а не зачиняє «Параметри» по «Ок».
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if NativeForm.endsFieldEditing(on: event, in: window) { return true }
            return super.performKeyEquivalent(with: event)
        }

        var tabs: NSTabView?
        var buttons: [NSButton] = []
        var leftButtons: [NSButton] = []
        var preview: NSView?
        var previewTitle: NSView?
        var onLayout: (() -> Void)?

        override func layout() {
            super.layout()
            let footer: CGFloat = 44
            // Полоса предпросмотра справа: 16:9, ширина от окна, но не шире
            // 280 — остальное вкладкам, их подписи важнее размера картинки.
            let previewWidth: CGFloat = preview == nil ? 0 : min(280, max(200, bounds.width * 0.24))
            let previewHeight = (previewWidth / 16 * 9).rounded()
            tabs?.frame = NSRect(x: 10, y: footer, width: bounds.width - 20 - (previewWidth > 0 ? previewWidth + 10 : 0),
                                 height: max(0, bounds.height - footer - 10))
            if let preview {
                preview.frame = NSRect(x: bounds.width - 10 - previewWidth,
                                       y: bounds.height - 10 - previewHeight,
                                       width: previewWidth, height: previewHeight)
                previewTitle?.frame = NSRect(x: preview.frame.minX, y: preview.frame.minY - 18,
                                             width: previewWidth, height: 16)
            }
            onLayout?()
            var right = bounds.width - 12
            for button in buttons.reversed() {
                let width = max(90, button.intrinsicContentSize.width + 24)
                button.frame = NSRect(x: right - width, y: 10, width: width, height: 24)
                right -= width + 8
            }
            var left: CGFloat = 12
            for button in leftButtons {
                let width = button.intrinsicContentSize.width + 20
                // Вузьке вікно: далі за «Ок» не лізем, краще обрізати підпис.
                guard left + width < right - 8 else { button.frame = .zero; continue }
                button.frame = NSRect(x: left, y: 10, width: width, height: 24)
                left += width + 6
            }
        }
    }

    // MARK: - Кнопки

    private func accept() {
        liveWatcher = nil
        previewWatcher = nil
        store.save(session)
        session = nil
        state?.applyProgramOptions(store.settings.options)
        // Список переводов применяем прямо здесь, а не только через повод
        // `.slovoSettingsChanged`: замечание 12 — «включил перевод, а он на
        // полосе не появился». Повод шлёт `save`, но лишь когда закрылся
        // последний слой правки; переживший слой (незакрытая проверка,
        // повторное открытие) молча оставлял полосу прежней. Прямой вызов
        // от «Ок» не зависит ни от чего.
        if let state {
            state.applyModuleRoster(store.settings.modules)
            if state.rosterNeedsLibraryReload { state.reloadLibrary() }
        }
        close()
    }

    // MARK: - Скидання та перенесення налаштувань

    /// Яку вкладку зараз видно.
    private func currentArea() -> SettingsStore.Area {
        let order = SettingsStore.Area.allCases
        guard let tabsView, let item = tabsView.selectedTabViewItem else { return .slide }
        let index = tabsView.tabViewItems.firstIndex(of: item) ?? 0
        return order.indices.contains(index) ? order[index] : .slide
    }

    /// «Скинути…»: одну вкладку чи все.
    ///
    /// Власник просив і те, і те. Питаємо в одному вікні: людина вже стоїть
    /// на потрібній вкладці, і назва її тут-таки в кнопці.
    private func askReset() {
        let area = currentArea()
        let alert = NSAlert()
        alert.messageText = OurWords.t("Сброс настроек")
        alert.informativeText = OurWords.t("Значения вернутся к тем, с которыми программа запускается впервые. Файлы — модули, песенники, шаблоны слайдов, планы и записи — остаются на месте. Передумали — «Отмена» в окне «Параметры» вернёт всё как было.")
        alert.addButton(withTitle: OurWords.t("Только вкладку") + " «" + area.title + "»")
        alert.addButton(withTitle: OurWords.t("Все настройки"))
        alert.addButton(withTitle: state?.vb("BBCancel", "Отмена") ?? OurWords.t("Отмена"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  store.reset(area)
        case .alertSecondButtonReturn: store.resetAll()
        default: return
        }
        refreshAfterChange()
    }

    /// Скласти всі налаштування в один файл.
    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = OurWords.t("Настройки Слова") + ".json"
        panel.allowedContentTypes = [.json]
        panel.message = OurWords.t("Сложить все настройки в один файл")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.export(to: url)
        } catch {
            report(OurWords.t("Не удалось сохранить файл настроек"), error)
        }
    }

    /// Прочитати налаштування з файла.
    private func importSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.json]
        panel.message = OurWords.t("Выберите файл настроек")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importSettings(from: url)
        } catch {
            report(OurWords.t("Это не файл настроек «Слова» или он испорчен"), error)
            return
        }
        refreshAfterChange()
    }

    private func report(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: state?.vb("BBOk", "Ок") ?? "Ок")
        alert.runModal()
    }

    /// Значення змінилися не з поля, а цілим набором: поля перечитують себе,
    /// списки перезбираються, програма одразу показує нове.
    private func refreshAfterChange() {
        if let root = window?.contentView { NativeForm.refreshValues(in: root) }
        for tab in tabObjects { (tab as? NativeSettingsRows)?.reloadRows() }
        applyLive(store.settings)
        refreshPreview()
    }

    func discard() {
        liveWatcher = nil
        previewWatcher = nil
        store.cancel(session)
        session = nil
        // Живые правки уже дошли до экрана — вернуть и его.
        applyLive(store.settings)
        close()
    }

    private var liveWatcher: AnyCancellable?
    private var previewWatcher: AnyCancellable?
    private weak var livePreview: NativeSlidePreview?

    /// Перерисовать предпросмотр в окне — тем же, чем нижняя панель.
    func refreshPreview() {
        guard let state, let preview = livePreview else { return }
        preview.show(slide: state.previewSlide, style: state.previewStyle,
                     preset: state.preset(for: .preview), texts: state.previewTexts,
                     backgroundOverride: state.previewBackgroundOverride,
                     imageURL: { [weak state] name in state?.presetImageURL(name) })
    }
    /// Для самопроверки: сколько раз предпросмотр окна перерисован.
    var previewDrawCount: Int { livePreview?.drawCount ?? -1 }

    /// Применить текущие значения хранилища к программе, не записывая их.
    ///
    /// Разом з простими значеннями — і галочки модулів: доти живий шлях знав
    /// лише `options`, і зняти галочку з перекладу означало «нічого не
    /// сталося» аж до «Ок». Тепер і зняття, і «Відмінити» видно одразу.
    func applyLive(_ settings: SlovoSettings) {
        state?.applyProgramOptions(settings.options)
        state?.applyModuleRoster(settings.modules)
    }

    /// Закрыть окно — зовёт и самопроверка.
    func close() {
        window?.orderOut(nil)
        window = nil
        state?.isSettingsOpen = false
    }

    /// Закрыли крестиком — считаем отменой: иначе слой снимка остался бы
    /// навсегда, и следующее «Ок» уже ничего бы не записало.
    func windowWillClose(_ notification: Notification) {
        liveWatcher = nil
        store.cancelIfEditing(session)
        applyLive(store.settings)
        session = nil
        window = nil
        state?.isSettingsOpen = false
    }
}
