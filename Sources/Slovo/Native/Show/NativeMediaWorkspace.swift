import AppKit
import SlovoCore

/// Рабочая область «Медиа»: слева список файлов, справа сам плеер.
///
/// Списка тут не было вовсе: плеер держал один файл, и каждый следующий
/// стирал предыдущий. На служении файлов несколько — заставка, ролик к
/// проповеди, гимн, — и ходить за каждым в окно выбора посреди служения
/// нельзя.
///
/// Устроено так же, как показ картинок: тот же `NativeList`, те же кнопки
/// «добавить», «убрать», «очистить». Разница только в том, что справа стоит
/// панель плеера, а не предпросмотр страницы.
@MainActor
final class NativeMediaWorkspace: NSView, NativeListSource {

    static let shared = NativeMediaWorkspace()

    private weak var state: AppState?
    private var host: NSView?
    private var tokens: [Signals.Token] = []
    private var observers: [Any] = []

    private let list = NativeList(mode: .list,
                                  metrics: NativeListMetrics(leadWidth: 30, detailWidth: 0),
                                  heights: .uniform(26))
    private let toolbar = NSStackView()
    /// Фонограмма — под списком файлов: своя, отдельная от плеера.
    private var backingBar: NativeBackingTrackBar?

    private init() {
        super.init(frame: .zero)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    func attach(state: AppState) {
        guard self.state == nil else { return }
        self.state = state
        list.source = self
        list.onSelect = { [weak self] _, active, _ in
            guard let self else { return }
            // Одиночный щелчок только выделяет: файл на служении открывают
            // намеренно, а не мимоходом задев список.
            self.selected = active
        }
        list.onActivate = { [weak self] position in
            self?.state?.media.openFromPlaylist(at: position)
        }
        let bar = NativeBackingTrackBar(player: state.backing)
        addSubview(bar)
        backingBar = bar
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            self?.applyCaptions()
            self?.backingBar?.applyCaptions()
        })
        // Список плеера меняется и мимо нас: файл открывают перетаскиванием
        // в окно и клавишей Ctrl+M.
        observers.append(state.media.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        })
        applyCaptions()
        reload()
    }

    private var selected: Int?

    func install() {
        guard let state else { return }
        if host == nil {
            let view = NativeMediaPanel(model: state.media, state: state)
            addSubview(view)
            host = view
        }
        NativeMainWindowController.shared.install(self, in: .workspace)
        reload()
    }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .centerY
        addSubview(list)
        addSubview(toolbar)

        func button(_ symbol: String, _ action: Selector) -> NSButton {
            let item = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                    ?? NSImage(), target: self, action: action)
            item.bezelStyle = .rounded
            item.imagePosition = .imageOnly
            return item
        }
        for item in [button("plus", #selector(addFiles)),
                     button("minus", #selector(removeSelected)),
                     button("xmark", #selector(clearAll))] {
            toolbar.addArrangedSubview(item)
        }
    }

    private func applyCaptions() {
        let items = toolbar.arrangedSubviews
        items.first?.toolTip = state?.text("PSBOpenVideo", default: OurWords.t("Открыть медиа-файл"))
        if items.count > 1 { items[1].toolTip = OurWords.t("Убрать из списка") }
        if items.count > 2 { items[2].toolTip = OurWords.t("Очистить список") }
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let listWidth = max(180, min(320, bounds.width * 0.26))
        let toolbarHeight: CGFloat = 28
        toolbar.frame = NSRect(x: gap, y: gap, width: listWidth, height: toolbarHeight)
        let top = toolbar.frame.maxY + gap
        let barHeight = backingBar == nil ? 0 : NativeBackingTrackBar.height + gap
        list.frame = NSRect(x: gap, y: top, width: listWidth,
                            height: max(0, bounds.height - top - gap - barHeight))
        backingBar?.frame = NSRect(x: gap, y: bounds.height - gap - NativeBackingTrackBar.height,
                                   width: listWidth, height: NativeBackingTrackBar.height)
        host?.frame = NSRect(x: listWidth + gap * 2, y: gap,
                             width: max(0, bounds.width - listWidth - gap * 3),
                             height: max(0, bounds.height - gap * 2))
    }

    // MARK: - Действия

    @objc private func addFiles() {
        guard let state else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = state.text("TextMessages58", form: "MediaPlayerForm",
                                   default: "Открытие медиафайлов")
        panel.prompt = state.text("BBOk", default: "Ок")

        // Тот же выбор наборов, что и у кнопки «Открыть медиафайл» (16.1):
        // одно и то же действие в двух местах не должно предлагать разное.
        // Без него диалог показывал и картинки — они попадали в список
        // плеера, дорожки видео у них нет, и на проекторе выходило пусто.
        let captions = MediaFileFilters.FilterGroup.allCases.map {
            state.text($0.captionKey, form: "MediaPlayerForm", default: $0.fallbackCaption)
        }
        let chooser = MediaFilterChooser(panel: panel, filters: state.media.filters,
                                         captions: captions)
        panel.accessoryView = chooser
        panel.isAccessoryViewDisclosed = true
        chooser.apply(.media)

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        state.media.addToPlaylist(panel.urls)
        reload()
    }

    @objc private func removeSelected() {
        guard let state, let position = selected ?? state.media.playlistIndex else { return }
        state.media.removeFromPlaylist(at: position)
        selected = nil
        reload()
    }

    @objc private func clearAll() {
        state?.media.clearPlaylist()
        selected = nil
        reload()
    }

    private func reload() {
        list.reload()
        let active = state?.media.playlistIndex
        list.setSelection(active.map { IndexSet(integer: $0) } ?? IndexSet(), active: active)
        needsLayout = true
    }

    // MARK: - Список

    var rowCount: Int { state?.media.playlist.count ?? 0 }

    func row(at index: Int) -> NativeRow {
        var row = NativeRow()
        row.lead = "\(index + 1)"
        row.text = state?.media.playlist[index].lastPathComponent ?? ""
        return row
    }
}
