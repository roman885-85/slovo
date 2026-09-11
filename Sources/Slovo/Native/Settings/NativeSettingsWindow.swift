import AppKit
import Combine
import SlovoCore

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
                              styleMask: [.titled, .closable, .resizable],
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
                                       hint: state.vbHint("BBCancel", "Отменить изменения и закрыть")) { [weak self] in
            self?.discard()
        }
        cancel.keyEquivalent = "\u{1B}"

        root.tabs = tabs
        root.buttons = [cancel, ok]
        root.addSubview(tabs)
        root.addSubview(cancel)
        root.addSubview(ok)
        return root
    }

    /// Раскладка окна: вкладки во всю площадь, ряд кнопок снизу.
    private final class Root: NSView {
        var tabs: NSTabView?
        var buttons: [NSButton] = []
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
    func applyLive(_ settings: SlovoSettings) {
        state?.applyProgramOptions(settings.options)
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
