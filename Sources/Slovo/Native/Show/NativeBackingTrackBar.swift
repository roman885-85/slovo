import AppKit
import Combine
import SlovoCore
import UniformTypeIdentifiers

/// Панель фонограммы под списком файлов вкладки «Медиа».
///
/// Своя, отдельная от плеера: свой список, хвиля треку, пік-метр,
/// «играть», «пауза», «стоп», «по кругу» и громкость. Ни одна кнопка показа
/// её не трогает — это и есть «независимый аудиоплеер для минусовок» из
/// замечания 15.
///
/// Список у неё тоже свой (власник: «для блока фонограмм нет своего
/// плейлиста, а при перетягивании на плеер фонограмм музыки, она добавляется
/// в общий плейлист медиа»). Звук, брошенный на панель, ложится сюда; в
/// список плеера — заставки, ролики и прочее — он больше не попадает.
/// Картка треку: відлік згори донизу, як і в самій панелі.
private final class BackingDeck: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class NativeBackingTrackBar: NSView, NativeListSource {

    /// Высота панели без списка: заголовок, картка треку, кнопки, гучність.
    static let chromeHeight: CGFloat = 266
    /// Меньше этого списку не остаётся места даже на две строки.
    static let minimumHeight: CGFloat = chromeHeight + 50

    private let player: BackingTrackPlayer
    private let icon = NSImageView()
    private let caption = NSTextField(labelWithString: "")
    private let count = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private let removeButton = NSButton()
    private let clearButton = NSButton()
    let list = NativeList(mode: .list,
                          metrics: NativeListMetrics(leadWidth: 26, detailWidth: 0),
                          heights: .uniform(22), fontSize: 12)
    /// Темна картка з тим, що грає: назва, час, хвиля, рівень. Темна — як
    /// передпоказ і живий екран: там, де в програмі «зал», завжди темно.
    private let deck = BackingDeck()
    private let name = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "0:00 / 0:00")
    let waveformView = NativeWaveformView()
    let meter = NativeLevelMeter()
    let playButton = NSButton()
    let pauseButton = NSButton()
    let stopButton = NSButton()
    private let loopButton = NSButton()
    let nextButton = NSButton()
    /// Тон: нижче на 0,5, що зараз (клацання — назад до 0), вище на 0,5.
    let toneDown = NSButton()
    let toneLabel = NSButton()
    let toneUp = NSButton()
    private let quiet = NSImageView()
    private let loud = NSImageView()
    private let volume = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var watcher: AnyCancellable?
    private var selected: Int?
    /// Над панелью держат звуковые файлы — рамка подсвечена.
    private var dropHighlighted = false { didSet { applyColours() } }
    private var shownList: [URL] = []
    private var shownIndex: Int?
    /// Курсор хвилі й пік-метр живуть частіше, ніж публікує програвач.
    private var animation: Timer?

    init(player: BackingTrackPlayer) {
        self.player = player
        super.init(frame: .zero)
        build()
        watcher = player.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        registerForDraggedTypes([.fileURL])
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 6
        deck.wantsLayer = true
        deck.layer?.cornerRadius = 6
        deck.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        applyColours()

        icon.image = NSImage(systemSymbolName: "music.note.list", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = .controlAccentColor
        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        count.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        count.textColor = .tertiaryLabelColor
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = .white
        time.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        time.textColor = NSColor(white: 1, alpha: 0.7)
        time.alignment = .right

        func tool(_ button: NSButton, _ symbol: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .regular))
            button.imagePosition = .imageOnly
            button.isBordered = false
            button.bezelStyle = .texturedRounded
            button.contentTintColor = .secondaryLabelColor
            button.target = self
            button.action = action
        }
        tool(addButton, "plus", #selector(addFiles))
        tool(removeButton, "minus", #selector(removeSelected))
        tool(clearButton, "trash", #selector(clearAll))

        func transport(_ button: NSButton, _ symbol: String, _ action: Selector, toggle: Bool = false) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.setButtonType(toggle ? .pushOnPushOff : .momentaryPushIn)
            button.target = self
            button.action = action
        }
        transport(playButton, "play.fill", #selector(play))
        // «Грати» — кольором, як «Показати»: її натискають наосліп.
        playButton.bezelColor = .controlAccentColor
        playButton.contentTintColor = .white
        transport(pauseButton, "pause.fill", #selector(pause))
        transport(stopButton, "stop.fill", #selector(stopPlay))
        transport(loopButton, "repeat", #selector(toggleLoop), toggle: true)
        transport(nextButton, "text.line.first.and.arrowtriangle.forward", #selector(toggleNext), toggle: true)
        if nextButton.image == nil {
            nextButton.image = NSImage(systemSymbolName: "forward.end.fill", accessibilityDescription: nil)
        }

        for (button, title, action) in [(toneDown, "♭ −0,5", #selector(lowerTone)),
                                         (toneUp, "♯ +0,5", #selector(raiseTone))] {
            button.title = title
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            button.target = self
            button.action = action
        }
        toneLabel.isBordered = false
        toneLabel.bezelStyle = .texturedRounded
        toneLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        toneLabel.target = self
        toneLabel.action = #selector(resetTone)

        list.source = self
        list.onSelect = { [weak self] _, active, _ in self?.selected = active }
        // Двойной щелчок или Enter — открыть и сразу играть: так пускают
        // минусовку, когда уже начали петь.
        list.onActivate = { [weak self] index in
            guard let self else { return }
            self.player.openFromPlaylist(at: index)
            self.player.play()
            self.refresh()
        }

        waveformView.onSeek = { [weak self] fraction in
            guard let self, self.player.duration > 0 else { return }
            self.player.seek(to: fraction * self.player.duration)
            if !self.player.isPlaying { self.player.play() }
            self.refresh()
        }

        volume.target = self
        volume.action = #selector(volumeMoved(_:))
        volume.isContinuous = true
        volume.controlSize = .small
        quiet.image = NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil)
        loud.image = NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil)
        for speaker in [quiet, loud] { speaker.contentTintColor = .tertiaryLabelColor }

        for view in [name, time, waveformView, meter] as [NSView] { deck.addSubview(view) }
        for view in [icon, caption, count, addButton, removeButton, clearButton, list, deck,
                     playButton, pauseButton, stopButton, loopButton, nextButton,
                     toneDown, toneLabel, toneUp, quiet, volume, loud] as [NSView] {
            addSubview(view)
        }
        applyCaptions()
    }

    func applyCaptions() {
        caption.stringValue = OurWords.t("Фонограммы")
        addButton.toolTip = OurWords.t("Добавить фонограммы в список…")
        removeButton.toolTip = OurWords.t("Убрать фонограмму из списка")
        clearButton.toolTip = OurWords.t("Очистить список фонограмм")
        list.toolTip = OurWords.t("Свой список фонограмм: перетащите сюда музыку. Двойной щелчок — играть")
        waveformView.toolTip = OurWords.t("Весь трек: щелчок или перетаскивание — играть с этого места")
        meter.toolTip = OurWords.t("Уровень фонограммы: левый и правый каналы, красное — перегрузка")
        playButton.toolTip = OurWords.t("Играть")
        pauseButton.toolTip = OurWords.t("Пауза")
        stopButton.toolTip = OurWords.t("Стоп")
        loopButton.toolTip = OurWords.t("Повторять по кругу")
        nextButton.toolTip = OurWords.t("После окончания играть следующую фонограмму из списка")
        volume.toolTip = OurWords.t("Громкость фонограммы")
        toneDown.toolTip = OurWords.t("Понизить тон на 0,5 (полтона); темп не меняется")
        toneUp.toolTip = OurWords.t("Повысить тон на 0,5 (полтона); темп не меняется")
        toneLabel.toolTip = OurWords.t("Тон фонограммы; щелчок — вернуть исходный. Запоминается для каждого файла")
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColours()
    }

    private func applyColours() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = (dropHighlighted ? NSColor.controlAccentColor : NSColor.separatorColor).cgColor
            layer?.borderWidth = dropHighlighted ? 2 : 1
        }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let width = bounds.width
        let inner = max(20, width - pad * 2)

        // Заголовок: значок, «Фонограми», скільки їх, і кнопки списку праворуч.
        icon.frame = NSRect(x: pad, y: 6, width: 16, height: 16)
        var right = width - pad
        for button in [clearButton, removeButton, addButton] {
            right -= 22
            button.frame = NSRect(x: right, y: 4, width: 22, height: 20)
        }
        let captionWidth = min(ceil(caption.fittingSize.width), max(20, right - pad - 22 - 36))
        caption.frame = NSRect(x: pad + 20, y: 7, width: captionWidth, height: 16)
        count.frame = NSRect(x: caption.frame.maxX + 4, y: 8, width: max(0, right - caption.frame.maxX - 8), height: 14)

        // Знизу вгору: гучність, тон, кнопки, картка треку — решта списку.
        let rowVolume = bounds.height - 26
        let rowTone = rowVolume - 30
        let rowButtons = rowTone - 32
        let deckHeight: CGFloat = 116
        let deckY = rowButtons - 8 - deckHeight
        list.frame = NSRect(x: pad, y: 28, width: inner, height: max(0, deckY - 6 - 28))

        deck.frame = NSRect(x: pad, y: deckY, width: inner, height: deckHeight)
        let deckInner = max(20, inner - 16)
        let timeWidth: CGFloat = 86
        name.frame = NSRect(x: 8, y: 7, width: max(20, deckInner - timeWidth - 4), height: 16)
        time.frame = NSRect(x: 8 + deckInner - timeWidth, y: 8, width: timeWidth, height: 14)
        waveformView.frame = NSRect(x: 8, y: 30, width: deckInner, height: 62)
        meter.frame = NSRect(x: 8, y: 98, width: deckInner, height: 10)

        var x = pad
        let buttons = [playButton, pauseButton, stopButton, loopButton, nextButton]
        let buttonWidth = min(40, max(28, (inner - CGFloat(buttons.count - 1) * 4) / CGFloat(buttons.count)))
        for button in buttons {
            button.frame = NSRect(x: x, y: rowButtons, width: buttonWidth, height: 26)
            x += buttonWidth + 4
        }

        let toneButton: CGFloat = 62
        toneDown.frame = NSRect(x: pad, y: rowTone, width: toneButton, height: 22)
        toneUp.frame = NSRect(x: width - pad - toneButton, y: rowTone, width: toneButton, height: 22)
        toneLabel.frame = NSRect(x: toneDown.frame.maxX + 4, y: rowTone, width: max(20, toneUp.frame.minX - toneDown.frame.maxX - 8), height: 22)

        quiet.frame = NSRect(x: pad, y: rowVolume + 3, width: 14, height: 14)
        loud.frame = NSRect(x: width - pad - 18, y: rowVolume + 3, width: 18, height: 14)
        volume.frame = NSRect(x: pad + 20, y: rowVolume, width: max(40, inner - 20 - 24), height: 20)
    }

    private func refresh() {
        let hasFile = player.url != nil
        name.stringValue = hasFile ? player.title : OurWords.t("Фонограмма не выбрана")
        name.textColor = hasFile ? .white : NSColor(white: 1, alpha: 0.45)
        playButton.isEnabled = (hasFile || !player.playlist.isEmpty) && !player.isPlaying
        pauseButton.isEnabled = player.isPlaying
        stopButton.isEnabled = hasFile
        loopButton.state = player.loops ? .on : .off
        nextButton.state = player.playsNext ? .on : .off
        loopButton.contentTintColor = player.loops ? .controlAccentColor : nil
        nextButton.contentTintColor = player.playsNext ? .controlAccentColor : nil
        if abs(Double(volume.floatValue) - Double(player.volume)) > 0.001 { volume.doubleValue = Double(player.volume) }
        if let error = player.error, !error.isEmpty {
            name.stringValue = OurWords.t("Не удалось открыть фонограмму: %s", error)
            name.textColor = .systemRed
        }
        removeButton.isEnabled = !player.playlist.isEmpty
        clearButton.isEnabled = !player.playlist.isEmpty
        count.stringValue = player.playlist.isEmpty ? "" : "· \(player.playlist.count)"
        toneLabel.title = OurWords.t("Тон: %s", Self.toneText(player.pitchTones))
        toneLabel.contentTintColor = player.pitchTones == 0 ? .secondaryLabelColor : .controlAccentColor
        toneDown.isEnabled = player.pitchTones > -BackingTrackPlayer.pitchLimit
        toneUp.isEnabled = player.pitchTones < BackingTrackPlayer.pitchLimit

        if waveformView.waveform?.url != player.waveform?.url { waveformView.waveform = player.waveform }
        waveformView.isLoading = hasFile && player.waveform == nil && player.error == nil
        waveformView.duration = player.duration
        showPosition(player.isPlaying ? player.livePosition : player.position)

        // Список перечитываем только когда он и правда изменился: позиция
        // бежит четыре раза в секунду, и перерисовывать строки на каждый
        // тик незачем.
        if player.playlist != shownList || player.playlistIndex != shownIndex {
            shownList = player.playlist
            shownIndex = player.playlistIndex
            list.reload()
            let active = player.playlistIndex
            list.setSelection(active.map { IndexSet(integer: $0) } ?? IndexSet(), active: active)
            if let selected, selected >= shownList.count { self.selected = nil }
        }
        if player.isPlaying { startAnimation() }
        needsLayout = true
    }

    private func showPosition(_ seconds: Double) {
        waveformView.progress = player.duration > 0 ? min(1, max(0, seconds / player.duration)) : 0
        time.stringValue = MediaPlayerModel.timeText(seconds) + " / " + MediaPlayerModel.timeText(player.duration)
    }

    /// 30 кадрів на секунду, поки грає або поки рівень ще не впав.
    private func startAnimation() {
        guard animation == nil else { return }
        animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let peaks = player.levels.take()
        meter.update(left: player.isPlaying ? peaks.left : 0, right: player.isPlaying ? peaks.right : 0)
        if player.isPlaying { showPosition(player.livePosition) }
        if !player.isPlaying, meter.isQuiet {
            animation?.invalidate()
            animation = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { animation?.invalidate(); animation = nil } else { refresh() }
    }

    // MARK: - Список

    var rowCount: Int { player.playlist.count }

    func row(at index: Int) -> NativeRow {
        var row = NativeRow()
        row.lead = "\(index + 1)"
        row.text = player.playlist[index].deletingPathExtension().lastPathComponent
        return row
    }

    // MARK: - Перетаскивание

    private static func urls(from sender: NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                               options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.urls(from: sender).contains(where: BackingTrackPlayer.isAudio) {
            dropHighlighted = true
            return .copy
        }
        // Не звук (ролик, картинка, презентация) — как при броске в любое
        // другое место окна: решает общий разбор.
        dropHighlighted = false
        return NativeWindowDrop.shared.operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropHighlighted = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropHighlighted = false
        if accept(urls: Self.urls(from: sender)) { return true }
        return NativeWindowDrop.shared.accept(sender)
    }

    /// Принять брошенные файлы. Отдельным входом — для самопроверки:
    /// подделать `NSDraggingInfo` в ней нечем.
    @discardableResult
    func accept(urls: [URL]) -> Bool {
        player.addToPlaylist(urls) > 0
    }

    // MARK: - Действия

    @objc private func addFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = OurWords.t("Добавить фонограммы в список…")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        player.addToPlaylist(panel.urls)
    }

    @objc private func removeSelected() {
        guard let index = selected ?? player.playlistIndex else { return }
        player.removeFromPlaylist(at: index)
        selected = nil
    }

    @objc private func clearAll() {
        player.clearPlaylist()
        selected = nil
    }

    @objc private func play() {
        // Нічого не відкрито, але список є — грати виділене чи перше.
        if player.url == nil, !player.playlist.isEmpty {
            player.openFromPlaylist(at: selected ?? 0)
        }
        player.play()
        // Кнопки — одразу, а не з наступним оновленням програвача: інакше
        // «Пауза» лишалася б недоступною ще мить після «Грати».
        refresh()
    }

    @objc private func pause() { player.pause(); refresh() }
    @objc private func stopPlay() { player.stop(); refresh() }
    @objc private func toggleLoop() { player.loops.toggle(); refresh() }
    @objc private func toggleNext() { player.playsNext.toggle(); refresh() }
    @objc private func lowerTone() { player.shiftPitch(by: -BackingTrackPlayer.pitchStep); refresh() }
    @objc private func raiseTone() { player.shiftPitch(by: BackingTrackPlayer.pitchStep); refresh() }
    @objc private func resetTone() { player.setPitch(0); refresh() }

    /// «0», «+0,5», «−1» — з комою там, де пишуть комою.
    static func toneText(_ tones: Double) -> String {
        guard tones != 0 else { return "0" }
        var text = String(format: "%.1f", abs(tones))
        if text.hasSuffix(".0") { text.removeLast(2) }
        if OurWords.language != "en" { text = text.replacingOccurrences(of: ".", with: ",") }
        return (tones > 0 ? "+" : "−") + text
    }

    @objc private func volumeMoved(_ slider: NSSlider) {
        player.volume = Float(slider.doubleValue)
    }
}
