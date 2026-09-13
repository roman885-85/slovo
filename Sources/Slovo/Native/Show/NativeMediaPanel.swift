import AppKit
import AVFoundation
import UniformTypeIdentifiers
import SlovoCore

/// Панель медиаплеера (16) — на AppKit, без SwiftUI.
///
/// Состав кнопок и подписи взяты из файла перевода автора: «Открыть
/// медиа-файл» (16.1), «Открыть URL с медиа контентом» (16.2),
/// «Воспроизвести/пауза» (16.3), «Воспроизвести после открытия» (16.4),
/// «Отображать видео на экране проектора» (16.5), «Выбрать звуковую дорожку»
/// (16.6), остановка, перемотка, начало и конец, повтор, «Без звука» и
/// «Громкость». Файл можно перетащить в окно кадра мышью — как в оригинале.
///
/// Здесь же кончается SwiftUI в рабочей области: раскладку считает `layout()`,
/// а состояние приходит подпиской на сам плеер. Прежняя панель пересобиралась
/// целиком на каждый кадр позиции — тридцать раз в секунду во время фильма.
@MainActor
final class NativeMediaPanel: NSView {

    private let model: MediaPlayerModel
    private weak var state: AppState?

    private let videoBox = VideoBox()
    private let placeholder = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let status = NSTextField(labelWithString: "")
    private let elapsed = NSTextField(labelWithString: "0:00")
    private let total = NSTextField(labelWithString: "0:00")
    private let position = NSSlider()
    private let volume = NSSlider()
    private let volumeLabel = NSTextField(labelWithString: "")
    private let top = NSStackView()
    private let transport = NSStackView()

    private var openButton: NSButton!
    private var urlButton: NSButton!
    private var autoPlayButton: NSButton!
    private var toScreenButton: NSButton!
    private var tracksButton: NSPopUpButton!
    private var playButton: NSButton!
    private var repeatButton: NSButton!
    private var muteButton: NSButton!
    private var transportButtons: [NSButton] = []
    private var observers: [Any] = []
    private var tokens: [Signals.Token] = []

    init(model: MediaPlayerModel, state: AppState) {
        self.model = model
        self.state = state
        super.init(frame: .zero)
        // Підказки, назва без файлу, «Гучність:» і пункт «Аудіодоріжка» ставилися
        // при побудові — після зміни мови перекладаємо їх заново, інакше під
        // англійським інтерфейсом лишалися українські слова.
        tokens.append(Signals.shared.subscribe(.language) { [weak self] in
            guard let self else { return }
            self.applyHints()
            self.refresh()
            self.rebuildTracks()
        })
        build()
        observers.append(model.objectWillChange.sink { [weak self] in
            // Плеер шлёт повод перед сменой значения — читаем следующим
            // оборотом, иначе позиция отставала бы на кадр.
            DispatchQueue.main.async { self?.refresh() }
        })
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    // MARK: - Сборка

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 4

        top.orientation = .horizontal
        top.spacing = 3
        top.alignment = .centerY
        transport.orientation = .horizontal
        transport.spacing = 3
        transport.alignment = .centerY

        openButton = command("folder", #selector(openFile))
        urlButton = command("link", #selector(openURL))
        autoPlayButton = command("play.circle", #selector(toggleAutoPlay))
        toScreenButton = command("tv", #selector(toggleToScreen))

        tracksButton = NSPopUpButton(frame: .zero, pullsDown: true)
        tracksButton.bezelStyle = .rounded
        tracksButton.imagePosition = .imageOnly
        tracksButton.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)

        title.font = .systemFont(ofSize: 10)
        title.textColor = .secondaryLabelColor
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for item in [openButton!, urlButton!, autoPlayButton!, toScreenButton!] {
            top.addArrangedSubview(item)
        }
        top.addArrangedSubview(tracksButton)
        top.addArrangedSubview(title)

        placeholder.imageScaling = .scaleNone
        placeholder.contentTintColor = .tertiaryLabelColor
        videoBox.addSubview(placeholder)
        videoBox.onDrop = { [weak self] urls in
            guard let self else { return false }
            // Брошенное в окно кадра идёт в список, а не подменяет собой то,
            // что уже открыто: список — то, ради чего его и заводили.
            self.model.addToPlaylist(urls)
            if let first = urls.first, self.model.mediaURL == nil { self.model.open(first) }
            return true
        }
        model.attach(videoBox.videoLayer)

        elapsed.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        elapsed.textColor = .secondaryLabelColor
        total.font = elapsed.font
        total.textColor = .secondaryLabelColor
        total.alignment = .right

        position.target = self
        position.action = #selector(scrub(_:))
        position.minValue = 0
        position.maxValue = 1

        volume.target = self
        volume.action = #selector(changeVolume(_:))
        volume.minValue = 0
        volume.maxValue = 1
        volume.controlSize = .small
        // Ширина ползунка — своя, а не «всё, что осталось в ряду»: в широком
        // окне он вытягивался на полметра, и владелец назвал его слишком
        // длинным. Сотни пунктов на сто делений громкости достаточно.
        volume.translatesAutoresizingMaskIntoConstraints = false
        volume.widthAnchor.constraint(equalToConstant: 100).isActive = true
        volumeLabel.font = .systemFont(ofSize: 10)
        volumeLabel.textColor = .secondaryLabelColor

        let toBegin = command("backward.end.fill", #selector(toBegin))
        let back = command("gobackward.5", #selector(shuttleBack))
        playButton = command("play.fill", #selector(playPause))
        let stop = command("stop.fill", #selector(stopPlayback))
        let forward = command("goforward.5", #selector(shuttleForward))
        let toEnd = command("forward.end.fill", #selector(toEnd))
        transportButtons = [toBegin, back, playButton, stop, forward, toEnd]
        repeatButton = command("repeat", #selector(toggleRepeat))
        muteButton = command("speaker.wave.2.fill", #selector(toggleMute))

        for item in transportButtons { transport.addArrangedSubview(item) }
        transport.addArrangedSubview(repeatButton)
        transport.addArrangedSubview(muteButton)
        transport.addArrangedSubview(volumeLabel)
        transport.addArrangedSubview(volume)
        // Пустой вид в конце забирает остаток ряда — иначе ряд растянул бы
        // последний вид, то есть ползунок.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        transport.addArrangedSubview(spacer)

        status.font = .systemFont(ofSize: 10)
        status.lineBreakMode = .byTruncatingTail

        addSubview(top)
        addSubview(videoBox)
        addSubview(elapsed)
        addSubview(position)
        addSubview(total)
        addSubview(transport)
        addSubview(status)

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: OurWords.t("Закрыть медиафайл"),
                                action: #selector(closeFile), keyEquivalent: ""))
        menu.items.first?.target = self
        videoBox.menu = menu
        title.menu = menu
    }

    private func command(_ symbol: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                                ?? NSImage(), target: self, action: action)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        return button
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 6
        let row: CGFloat = 24
        let width = bounds.width - gap * 2

        top.frame = NSRect(x: gap, y: gap, width: width, height: row)

        // Кадр 16:9 — как в оригинале, и не выше того, что осталось.
        let rows = row * 2 + 18 + gap * 4
        let boxHeight = min(width * 9 / 16, max(60, bounds.height - top.frame.maxY - rows))
        videoBox.frame = NSRect(x: gap, y: top.frame.maxY + gap,
                                width: width, height: boxHeight)
        placeholder.frame = NSRect(x: videoBox.bounds.midX - 16, y: videoBox.bounds.midY - 16,
                                   width: 32, height: 32)

        let positionTop = videoBox.frame.maxY + gap
        elapsed.frame = NSRect(x: gap, y: positionTop + 3, width: 44, height: 16)
        total.frame = NSRect(x: bounds.width - gap - 44, y: positionTop + 3, width: 44, height: 16)
        position.frame = NSRect(x: elapsed.frame.maxX + 5, y: positionTop,
                                width: max(0, total.frame.minX - elapsed.frame.maxX - 10), height: 20)

        transport.frame = NSRect(x: gap, y: positionTop + row + gap, width: width, height: row)
        status.frame = NSRect(x: gap, y: transport.frame.maxY + 2, width: width, height: 14)
    }

    // MARK: - Состояние

    private func refresh() {
        let hasFile = model.mediaURL != nil
        placeholder.image = NSImage(systemSymbolName: hasFile ? "music.note" : "film",
                                    accessibilityDescription: nil)
        placeholder.isHidden = hasFile && model.hasVideo

        title.stringValue = model.title.isEmpty
            ? message("TextMessages61", "Файл не выбран") : model.title

        elapsed.stringValue = MediaPlayerModel.timeText(model.position)
        total.stringValue = MediaPlayerModel.timeText(model.duration)
        position.isEnabled = model.duration > 0
        position.maxValue = max(model.duration, 0.1)
        if !isScrubbing { position.doubleValue = model.position }
        volume.doubleValue = model.volume
        volumeLabel.stringValue = message("LMEdiaVolume", "Громкость:")

        playButton.image = NSImage(systemSymbolName: model.isPlaying ? "pause.fill" : "play.fill",
                                   accessibilityDescription: nil)
        for button in transportButtons { button.isEnabled = hasFile }
        mark(autoPlayButton, on: model.autoPlay)
        mark(toScreenButton, on: model.videoToScreen)
        mark(repeatButton, on: model.repeats)
        muteButton.image = NSImage(systemSymbolName: model.isMuted ? "speaker.slash.fill"
                                        : "speaker.wave.2.fill", accessibilityDescription: nil)
        mark(muteButton, on: model.isMuted)

        tracksButton.isEnabled = model.audioTracks.count > 1
        rebuildTracks()
        applyHints()

        if let failure = model.failure {
            status.stringValue = failureText(failure)
            status.textColor = .systemRed
        } else if let text = activityText(model.activity) {
            status.stringValue = text
            status.textColor = .secondaryLabelColor
        } else {
            status.stringValue = ""
        }
        needsLayout = true
    }

    /// Утопленная кнопка — так переключатели нарисованы у автора.
    private func mark(_ button: NSButton, on: Bool) {
        // Кнопка з двома положеннями: увімкнена малюється натиснутою, а не
        // лише підфарбовує значок — власник: «кнопка повтору спрацьовує, але
        // не міняє колір, незрозуміло, чи вона активна».
        button.setButtonType(.pushOnPushOff)
        button.state = on ? .on : .off
        button.bezelStyle = .rounded
        button.contentTintColor = on ? .controlAccentColor : nil
    }

    private func rebuildTracks() {
        let menu = NSMenu()
        // Первый пункт у выпадающей кнопки — её собственный значок.
        menu.addItem(NSMenuItem())
        if model.audioTracks.isEmpty {
            let item = NSMenuItem(title: message("TextMessages64", "Аудио дорожка"),
                                  action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        for track in model.audioTracks {
            let item = NSMenuItem(title: track.title, action: #selector(chooseTrack(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = track.id
            item.state = track.id == model.selectedAudioTrackID ? .on : .off
            menu.addItem(item)
        }
        tracksButton.menu = menu
    }

    private func applyHints() {
        openButton.toolTip = hint("PSBOpenVideo", "Открыть медиа-файл")
        urlButton.toolTip = hint("PSBOpenVideoUrl", "Открыть URL с медиа контентом")
        autoPlayButton.toolTip = hint("PngSBAutoPlay", "Воспроизвести после открытия (Вкл/Выкл)")
        toScreenButton.toolTip = hint("PngSBVideoToScreen", "Отображать видео на экране проектора (Вкл/Выкл)")
        tracksButton.toolTip = hint("PSBSelectAudioStreams", "Выбрать звуковую дорожку")
        let hints = ["PSBVideoToBegin": "В начало", "PSBVideoSmallShuttleLeft": "Перемотать назад",
                     "PSBVideoPlayPause": "Воспроизвести/пауза", "PSBVideoStop": "Остановить",
                     "PSBVideoSmallShuttleRight": "Перемотать вперед", "PSBVideoToEnd": "В конец"]
        let order = ["PSBVideoToBegin", "PSBVideoSmallShuttleLeft", "PSBVideoPlayPause",
                     "PSBVideoStop", "PSBVideoSmallShuttleRight", "PSBVideoToEnd"]
        for (button, key) in zip(transportButtons, order) {
            button.toolTip = hint(key, hints[key] ?? "")
        }
        repeatButton.toolTip = hint("PSBVideoRepeate", "Повтор")
        muteButton.toolTip = hint("PngSBAudioMute", "Без звука")
    }

    // MARK: - Действия

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Несколько разом: список для того и заведён.
        panel.allowsMultipleSelection = true
        panel.message = message("TextMessages58", "Открытие медиафайлов")
        panel.prompt = settings("BBOk", "Ок")

        let captions = MediaFileFilters.FilterGroup.allCases.map {
            message($0.captionKey, $0.fallbackCaption)
        }
        let chooser = MediaFilterChooser(panel: panel, filters: model.filters, captions: captions)
        panel.accessoryView = chooser
        panel.isAccessoryViewDisclosed = true
        chooser.apply(.media)

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let before = model.playlist.count
        model.addToPlaylist(panel.urls)
        // Открываем первый ДОБАВЛЕННЫЙ по порядку списка, а не первый
        // нащёлканный в окне: иначе очередь показа расходится со списком.
        if model.playlist.count > before { model.openFromPlaylist(at: before) }
    }

    @objc private func openURL() {
        let alert = NSAlert()
        alert.messageText = message("TextMessages52", "Открытие медиапотока")
        alert.informativeText = message("TextMessages53", "Введите URL медиапотока")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 420, height: 22))
        alert.accessoryView = field
        alert.addButton(withTitle: settings("BBOk", "Ок"))
        alert.addButton(withTitle: settings("BBCancel", "Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.openStream(text: field.stringValue)
    }

    @objc private func toggleAutoPlay() { model.autoPlay.toggle(); refresh() }
    @objc private func toggleToScreen() { model.videoToScreen.toggle(); refresh() }
    @objc private func toggleRepeat() { model.repeats.toggle(); refresh() }
    @objc private func toggleMute() { model.isMuted.toggle(); refresh() }
    @objc private func playPause() { model.playPause() }
    @objc private func stopPlayback() { model.stop() }
    @objc private func toBegin() { model.toBegin() }
    @objc private func toEnd() { model.toEnd() }
    @objc private func shuttleBack() { model.shuttle(-1) }
    @objc private func shuttleForward() { model.shuttle(1) }
    @objc private func closeFile() { model.close() }

    @objc private func chooseTrack(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        model.selectAudioTrack(id)
    }

    private var isScrubbing = false

    @objc private func scrub(_ sender: NSSlider) {
        // Тянут ползунок — держим перемотку, пока кнопку не отпустят: иначе
        // плеер дёргался бы к каждому промежуточному значению.
        let dragging = NSApp.currentEvent?.type == .leftMouseDragged
            || NSApp.currentEvent?.type == .leftMouseDown
        if dragging, !isScrubbing { isScrubbing = true; model.beginScrub() }
        model.scrub(to: sender.doubleValue)
        if !dragging, isScrubbing { isScrubbing = false; model.endScrub() }
    }

    @objc private func changeVolume(_ sender: NSSlider) { model.volume = sender.doubleValue }

    // MARK: - Подписи

    private func hint(_ key: String, _ fallback: String) -> String {
        state?.language?.hint(key, form: "MainForm") ?? OurWords.t(fallback)
    }

    private func message(_ key: String, _ fallback: String) -> String {
        state?.text(key, form: "MainForm", default: fallback) ?? fallback
    }

    private func settings(_ key: String, _ fallback: String) -> String {
        state?.text(key, form: "SettingsForm", default: fallback) ?? fallback
    }

    private func activityText(_ activity: MediaPlayerModel.Activity) -> String? {
        switch activity {
        case .idle:          return nil
        case .openingFile:   return message("TextMessages50", "Открываем медиафайл...")
        case .openingStream: return message("TextMessages59", "Открываем медиапоток...")
        case .closing(let stream):
            return stream ? message("TextMessages60", "Закрываем медиапоток...")
                          : message("TextMessages51", "Закрываем медиафайл...")
        }
    }

    private func failureText(_ failure: MediaPlayerModel.Failure) -> String {
        switch failure {
        case .cannotOpen: return message("ErrorMessages18", "Ошибка при открытии медиа-файла")
        case .badURL:     return message("ErrorMessages20", "Ошибка в URL")
        case .pageLink(let host):
            return OurWords.t("%s даёт по такой ссылке страницу, а не поток. "
                + "Нужен прямой адрес файла или трансляции (.m3u8).", host)
        case .unsupportedScheme(let scheme):
            return message("ErrorMessages20", "Ошибка в URL")
                + OurWords.t(": %s:// на macOS не воспроизводится", "\(scheme)")
        case .youTube(let code):
            let reason: String
            switch code {
            case 2:        reason = OurWords.t("в ссылке нет верного номера ролика")
            case 100:      reason = OurWords.t("ролик удалён или закрыт")
            case 101, 150: reason = OurWords.t("владелец ролика запретил показ вне сайта YouTube")
            case -1:       reason = OurWords.t("страница проигрывателя не загрузилась — нет сети?")
            default:       reason = OurWords.t("проигрыватель не запустился (код %s)", "\(code)")
            }
            return OurWords.t("YouTube не отдал ролик") + ": " + reason
        }
    }
}

/// Окно кадра плеера: чёрный прямоугольник со своим слоем и приёмом файлов.
@MainActor
private final class VideoBox: NSView {

    /// Слой кадра — свой у вида, а не добавленный в чужой: AppKit
    /// переставляет добавленные руками слои под слои подвидов.
    let videoLayer = CALayer()
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 3
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        videoLayer.contentsGravity = .resizeAspect
        layer?.addSublayer(videoLayer)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoLayer.frame = bounds
        CATransaction.commit()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                          options: [.urlReadingFileURLsOnly: true])
                        as? [URL]) ?? []
        guard !urls.isEmpty else { return false }
        return onDrop?(urls) ?? false
    }
}
