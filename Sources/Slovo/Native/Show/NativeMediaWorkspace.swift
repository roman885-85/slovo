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
    /// Підпис списку плеєра: поруч тепер є ще й список фонограм, і без
    /// назви не видно, котрий із них для заставок і роликів.
    private let listCaption = NSTextField(labelWithString: "")
    /// Роздільник між списком і плеєром: ширина списку тягнеться й пам'ятається.
    let grip = NativeWidthGrip()
    private static let listWidthKey = "mediaListWidth"
    /// Межа між списком медіа й фонограмами: за неї тягнуть висоту панелі
    /// фонограм, а з нею — висоту їхнього списку. Власник: «размер высоты
    /// плейлиста должен регулироваться и весь блок по ширине тоже».
    let heightGrip = NativeBottomHeightGrip()
    private static let backingHeightKey = "backingPanelHeight"
    /// Найвужчий лівий стовпець: у фонограм п'ять кнопок і тон в один ряд.
    static let minimumListWidth: CGFloat = 240
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
        addSubview(heightGrip)
        grip.onDrag = { [weak self] delta in
            guard let self else { return }
            NativeWidths.set(Self.listWidthKey, self.list.frame.width + delta,
                             min: Self.minimumListWidth, max: self.bounds.width * 0.6)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        heightGrip.onDrag = { [weak self] delta in
            guard let self, let bar = self.backingBar else { return }
            // Униз — панель фонограм нижча, угору — вища.
            NativeWidths.set(Self.backingHeightKey, bar.frame.height - delta,
                             min: NativeBackingTrackBar.minimumHeight, max: self.backingMaxHeight)
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
        heightGrip.onReset = { [weak self] in
            NativeWidths.reset(Self.backingHeightKey)
            self?.needsLayout = true
        }
        grip.onReset = { [weak self] in NativeWidths.reset(Self.listWidthKey); self?.needsLayout = true }

        func button(_ symbol: String, _ action: Selector) -> NSButton {
            let item = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                    ?? NSImage(), target: self, action: action)
            item.bezelStyle = .rounded
            item.imagePosition = .imageOnly
            return item
        }
        listCaption.font = .systemFont(ofSize: 11, weight: .semibold)
        listCaption.textColor = .secondaryLabelColor
        listCaption.lineBreakMode = .byTruncatingTail
        listCaption.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for item in [button("plus", #selector(addFiles)),
                     button("minus", #selector(removeSelected)),
                     button("xmark", #selector(clearAll))] {
            toolbar.addArrangedSubview(item)
        }
        toolbar.addArrangedSubview(listCaption)
    }

    private func applyCaptions() {
        listCaption.stringValue = OurWords.t("Медиафайлы: заставки, видео")
        heightGrip.toolTip = OurWords.t("Потяните вверх или вниз — высота панели фонограмм; двойной щелчок — как было")
        grip.toolTip = OurWords.t("Потяните — ширина списков и фонограмм; двойной щелчок — как было")
        let items = toolbar.arrangedSubviews
        items.first?.toolTip = state?.text("PSBOpenVideo", default: OurWords.t("Открыть медиа-файл"))
        if items.count > 1 { items[1].toolTip = OurWords.t("Убрать из списка") }
        if items.count > 2 { items[2].toolTip = OurWords.t("Очистить список") }
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 8
        let listWidth = NativeWidths.value(Self.listWidthKey, auto: max(Self.minimumListWidth, min(340, bounds.width * 0.26)),
                                           min: Self.minimumListWidth, max: bounds.width * 0.6)
        let toolbarHeight: CGFloat = 28
        toolbar.frame = NSRect(x: gap, y: gap, width: listWidth, height: toolbarHeight)
        let top = toolbar.frame.maxY + gap
        // Фонограмі — половина стовпця, але не менше, ніж треба її хвилі й
        // кнопкам, і так, щоб списку плеєра лишилося хоч трохи рядків.
        let column = max(0, bounds.height - top - gap)
        let automatic = min(max(NativeBackingTrackBar.minimumHeight, column * 0.55), backingMaxHeight)
        let backingHeight = backingBar == nil ? 0
            : min(backingMaxHeight, NativeWidths.value(Self.backingHeightKey, auto: automatic,
                                                        min: NativeBackingTrackBar.minimumHeight, max: backingMaxHeight))
        let barHeight = backingBar == nil ? 0 : backingHeight + gap
        list.frame = NSRect(x: gap, y: top, width: listWidth,
                            height: max(0, column - barHeight))
        backingBar?.frame = NSRect(x: gap, y: bounds.height - gap - backingHeight,
                                   width: listWidth, height: backingHeight)
        heightGrip.isHidden = backingBar == nil
        heightGrip.frame = NSRect(x: gap, y: list.frame.maxY, width: listWidth, height: gap)
        grip.frame = NSRect(x: list.frame.maxX, y: gap, width: NativeWidths.grip,
                            height: max(0, bounds.height - gap * 2))
        let hostX = grip.frame.maxX + gap
        host?.frame = NSRect(x: hostX, y: gap,
                             width: max(0, bounds.width - hostX - gap),
                             height: max(0, bounds.height - gap * 2))
    }

    /// Вища за це панель фонограм не стає: списку медіа лишається хоч
    /// кілька рядків.
    private var backingMaxHeight: CGFloat {
        let column = max(0, bounds.height - (8 + 28 + 8) - 8)
        return max(NativeBackingTrackBar.minimumHeight, column - 90)
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
