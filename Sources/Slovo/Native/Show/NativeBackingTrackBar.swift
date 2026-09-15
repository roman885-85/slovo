import AppKit
import Combine
import SlovoCore
import UniformTypeIdentifiers

/// Панель фонограммы под списком файлов вкладки «Медиа».
///
/// Своя, отдельная от плеера: файл, «играть/пауза», «стоп», «по кругу»,
/// положение и громкость. Ни одна кнопка показа её не трогает — это и есть
/// «независимый аудиоплеер для минусовок» из замечания 15.
@MainActor
final class NativeBackingTrackBar: NSView {

    static let height: CGFloat = 96

    private let player: BackingTrackPlayer
    private let caption = NSTextField(labelWithString: "")
    private let name = NSTextField(labelWithString: "")
    private let openButton = NSButton()
    private let playButton = NSButton()
    private let stopButton = NSButton()
    private let loopButton = NSButton()
    private let position = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let time = NSTextField(labelWithString: "0:00 / 0:00")
    private let speaker = NSImageView()
    private let volume = NSSlider(value: 0.8, minValue: 0, maxValue: 1, target: nil, action: nil)
    private var watcher: AnyCancellable?
    private var dragging = false

    init(player: BackingTrackPlayer) {
        self.player = player
        super.init(frame: .zero)
        build()
        watcher = player.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.refresh() }
        }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        caption.font = .systemFont(ofSize: 11, weight: .semibold)
        caption.textColor = .secondaryLabelColor
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingMiddle
        name.textColor = .labelColor
        time.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        time.textColor = .secondaryLabelColor
        time.alignment = .right

        func symbol(_ button: NSButton, _ symbol: String, _ action: Selector) {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.bezelStyle = .rounded
            button.target = self
            button.action = action
            button.setButtonType(.momentaryPushIn)
        }
        symbol(openButton, "folder", #selector(openFile))
        symbol(playButton, "play.fill", #selector(togglePlay))
        symbol(stopButton, "stop.fill", #selector(stopPlay))
        symbol(loopButton, "repeat", #selector(toggleLoop))
        loopButton.setButtonType(.pushOnPushOff)

        position.target = self
        position.action = #selector(positionMoved(_:))
        position.isContinuous = true
        volume.target = self
        volume.action = #selector(volumeMoved(_:))
        volume.isContinuous = true
        speaker.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        speaker.contentTintColor = .secondaryLabelColor

        for view in [caption, name, openButton, playButton, stopButton, loopButton, position, time, speaker, volume] {
            addSubview(view)
        }
        applyCaptions()
    }

    func applyCaptions() {
        caption.stringValue = OurWords.t("Фонограмма") + ":"
        openButton.toolTip = OurWords.t("Открыть фонограмму…")
        stopButton.toolTip = OurWords.t("Стоп")
        loopButton.toolTip = OurWords.t("Повторять по кругу")
        volume.toolTip = OurWords.t("Громкость фонограммы")
        position.toolTip = OurWords.t("Место воспроизведения: потяните, чтобы перемотать")
        refresh()
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let width = bounds.width
        caption.frame = NSRect(x: pad, y: 6, width: 90, height: 16)
        name.frame = NSRect(x: pad + 92, y: 6, width: max(20, width - pad * 2 - 92), height: 16)
        let row2: CGFloat = 28
        var x = pad
        for button in [openButton, playButton, stopButton, loopButton] {
            button.frame = NSRect(x: x, y: row2, width: 30, height: 24)
            x += 34
        }
        time.frame = NSRect(x: width - pad - 78, y: row2 + 4, width: 78, height: 14)
        position.frame = NSRect(x: x, y: row2 + 2, width: max(20, width - pad - 82 - x), height: 20)
        let row3: CGFloat = 60
        speaker.frame = NSRect(x: pad, y: row3 + 2, width: 18, height: 18)
        volume.frame = NSRect(x: pad + 24, y: row3, width: 100, height: 22)
    }

    private func refresh() {
        let hasFile = player.url != nil
        name.stringValue = hasFile ? player.title : OurWords.t("Фонограмма не выбрана")
        name.textColor = hasFile ? .labelColor : .tertiaryLabelColor
        playButton.image = NSImage(systemSymbolName: player.isPlaying ? "pause.fill" : "play.fill",
                                   accessibilityDescription: nil)
        playButton.toolTip = OurWords.t(player.isPlaying ? "Пауза" : "Играть")
        playButton.isEnabled = hasFile
        stopButton.isEnabled = hasFile
        loopButton.state = player.loops ? .on : .off
        position.isEnabled = hasFile && player.duration > 0
        if !dragging {
            position.doubleValue = player.duration > 0 ? player.position / player.duration : 0
        }
        time.stringValue = MediaPlayerModel.timeText(player.position) + " / " + MediaPlayerModel.timeText(player.duration)
        if abs(Double(volume.floatValue) - Double(player.volume)) > 0.001 { volume.doubleValue = Double(player.volume) }
        if let error = player.error, !error.isEmpty {
            name.stringValue = OurWords.t("Не удалось открыть фонограмму: %s", error)
            name.textColor = .systemRed
        }
    }

    // MARK: - Действия

    @objc private func openFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.message = OurWords.t("Открыть фонограмму…")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        player.open(url)
        player.play()
    }

    @objc private func togglePlay() { player.toggle() }
    @objc private func stopPlay() { player.stop() }
    @objc private func toggleLoop() { player.loops.toggle(); refresh() }

    @objc private func positionMoved(_ slider: NSSlider) {
        // Пока тянут — только подпись; перематываем, когда отпустили: иначе
        // каждый шаг мыши перезапускал бы отрезок и звук заикался.
        let dragged = NSApp.currentEvent?.type == .leftMouseDragged
        dragging = dragged
        let target = slider.doubleValue * player.duration
        time.stringValue = MediaPlayerModel.timeText(target) + " / " + MediaPlayerModel.timeText(player.duration)
        if !dragged { player.seek(to: target) }
    }

    @objc private func volumeMoved(_ slider: NSSlider) {
        player.volume = Float(slider.doubleValue)
    }
}
