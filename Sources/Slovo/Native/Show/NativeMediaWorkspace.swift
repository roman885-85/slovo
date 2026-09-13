import AppKit
import SlovoCore

/// Робоча область «Медіа»: ліворуч список файлів, праворуч сам плеєр.
///
/// Списку тут не було зовсім: плеєр тримав один файл, і кожен наступний
/// стирав попередній. На служінні файлів кілька — заставка, ролик до
/// проповіді, гімн, — і ходити по кожен у вікно вибору посеред служіння
/// не можна.
///
/// Влаштовано так само, як показ картинок: той самий `NativeList`, ті самі
/// кнопки «додати», «прибрати», «очистити». Різниця тільки в тому, що
/// праворуч стоїть панель плеєра, а не попередній перегляд сторінки.
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
    /// Роздільник між списком і плеєром: ширина списку тягнеться й пам'ятається.
    private let grip = NativeWidthGrip()
    private static let listWidthKey = "mediaListWidth"
    /// Фонограма — під списком файлів: своя, окрема від плеєра.
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
            // Одиночне клацання тільки виділяє: файл на служінні відкривають
            // навмисно, а не мимохідь зачепивши список.
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
        // Список плеєра міняється й повз нас: файл відкривають перетягуванням
        // у вікно й клавішею Ctrl+M.
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

    // MARK: - Складання

    private func build() {
        wantsLayer = true
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.alignment = .centerY
        addSubview(list)
        addSubview(toolbar)
        addSubview(grip)
        grip.onDrag = { [weak self] delta in
            guard let self else { return }
            NativeWidths.set(Self.listWidthKey, self.list.frame.width + delta, min: 150, max: self.bounds.width * 0.6)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        grip.onReset = { [weak self] in NativeWidths.reset(Self.listWidthKey); self?.needsLayout = true }

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
        let listWidth = NativeWidths.value(Self.listWidthKey, auto: max(180, min(320, bounds.width * 0.26)),
                                           min: 150, max: bounds.width * 0.6)
        let toolbarHeight: CGFloat = 28
        toolbar.frame = NSRect(x: gap, y: gap, width: listWidth, height: toolbarHeight)
        let top = toolbar.frame.maxY + gap
        let barHeight = backingBar == nil ? 0 : NativeBackingTrackBar.height + gap
        list.frame = NSRect(x: gap, y: top, width: listWidth,
                            height: max(0, bounds.height - top - gap - barHeight))
        backingBar?.frame = NSRect(x: gap, y: bounds.height - gap - NativeBackingTrackBar.height,
                                   width: listWidth, height: NativeBackingTrackBar.height)
        grip.frame = NSRect(x: list.frame.maxX, y: gap, width: NativeWidths.grip,
                            height: max(0, bounds.height - gap * 2))
        let hostX = grip.frame.maxX + gap
        host?.frame = NSRect(x: hostX, y: gap,
                             width: max(0, bounds.width - hostX - gap),
                             height: max(0, bounds.height - gap * 2))
    }

    // MARK: - Дії

    @objc private func addFiles() {
        guard let state else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = state.text("TextMessages58", form: "MediaPlayerForm",
                                   default: "Открытие медиафайлов")
        panel.prompt = state.text("BBOk", default: "Ок")

        // Той самий вибір наборів, що й у кнопки «Відкрити медіафайл» (16.1):
        // одна й та сама дія у двох місцях не має пропонувати різне.
        // Без нього діалог показував і картинки — вони потрапляли до списку
        // плеєра, доріжки відео в них немає, і на проєкторі виходило порожньо.
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
