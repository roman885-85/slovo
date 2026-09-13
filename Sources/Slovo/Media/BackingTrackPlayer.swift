import AVFoundation
import Foundation

/// Независимый проигрыватель фонограммы (минусовки).
///
/// Замечание 15: «аудио останавливается при переходе на слайды; нужен
/// независимый аудиоплеер для минусовок». Основной плеер один: открыли в
/// нём ролик — прежний звук закрыт. А минусовка на служении живёт своей
/// жизнью: играет под пение, пока оператор листает куплеты, показывает
/// картинки или запускает ролик. Поэтому у неё свой двигатель, никак не
/// связанный ни с плеером, ни с показом: его не трогают ни «Показать», ни
/// смена вкладки, ни открытие фильма.
///
/// Внутри — AVAudioEngine с одним узлом: он даёт и точную позицию, и отвод
/// звука в трансляцию (тем же путём, что отвод основного плеера).
@MainActor
final class BackingTrackPlayer: ObservableObject {

    @Published private(set) var url: URL?
    @Published private(set) var title = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var error: String?
    /// Повторять с начала, когда дошли до конца — минусовку под долгое
    /// пение часто пускают по кругу.
    @Published var loops = false
    @Published var volume: Float = 0.8 {
        didSet { node.volume = MediaPlayerModel.gain(Double(volume)) }
    }

    /// Звук — в трансляцию: зовётся из звукового потока двигателя.
    nonisolated(unsafe) var networkAudioSink: ((Data, Int, Int, Int) -> Void)?
    /// Пока играет основной плеер, его звук уже идёт в сеть; два потока
    /// разом превратились бы в кашу. Ставит `AppState`.
    nonisolated(unsafe) var mainPlayerIsPlaying = false
    /// Двигатель отдаёт буферы и на паузе (тишину) — в сеть их не шлём.
    nonisolated(unsafe) private var feeding = false

    /// Что-то изменилось (файл, ход, конец) — интерфейсу и `AppState`.
    var onChange: (() -> Void)?

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var sampleRate: Double = 44_100
    /// С какого отсчёта пошёл текущий отрезок: позиция считается от него.
    private var segmentStart: AVAudioFramePosition = 0
    private var ticker: Timer?
    private var tapInstalled = false
    /// Номер расписания: завершение старого отрезка (после перемотки или
    /// стопа) не должно принять себя за конец файла.
    private var scheduleGeneration = 0

    init() {
        engine.attach(node)
        node.volume = MediaPlayerModel.gain(Double(volume))
    }

    // MARK: - Файл

    func open(_ target: URL) {
        stopEngine()
        do {
            let opened = try AVAudioFile(forReading: target)
            file = opened
            sampleRate = opened.processingFormat.sampleRate
            duration = Double(opened.length) / max(1, sampleRate)
            url = target
            title = target.deletingPathExtension().lastPathComponent
            error = nil
            position = 0
            engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: opened.processingFormat)
        } catch {
            file = nil
            url = nil
            title = ""
            duration = 0
            self.error = error.localizedDescription
        }
        remember()
        notify()
    }

    /// Чи запам'ятовує цей програвач відкриту фонограму між запусками.
    /// Вмикає тільки той, з яким працює людина: самоперевірка відкриває свої
    /// пробні файли, і пам'ять від них має лишатися чистою.
    var remembers = false

    private static let memoryKey = "backingTrackFile"

    private func remember() {
        guard remembers, !SessionMemory.isSuspended else { return }
        if let url { UserDefaults.standard.set(url.path, forKey: Self.memoryKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.memoryKey) }
    }

    /// Відкрити фонограму, що стояла минулого разу, — але не грати її.
    ///
    /// Власник: «после закрытия программы все добавленные презентации,
    /// минусовки, картинки и т.д. не сохраняются». Файла може вже й не бути
    /// — тоді просто нічого не відкриваємо.
    func restore() {
        guard remembers, url == nil,
              let path = UserDefaults.standard.string(forKey: Self.memoryKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    func close() {
        stopEngine()
        file = nil
        url = nil
        title = ""
        duration = 0
        position = 0
        error = nil
        remember()
        notify()
    }

    // MARK: - Управление

    func play() {
        guard let file else { return }
        // Дошли до конца и жмут «играть» — с начала, иначе кнопка выглядит
        // сломанной.
        if position >= duration - 0.05 { position = 0 }
        guard ensureEngine() else { return }
        schedule(from: AVAudioFramePosition(position * sampleRate), file: file)
        node.play()
        isPlaying = true
        feeding = true
        startTicker()
        notify()
    }

    func pause() {
        guard isPlaying else { return }
        position = currentPosition()
        node.pause()
        isPlaying = false
        feeding = false
        stopTicker()
        notify()
    }

    func toggle() { isPlaying ? pause() : play() }

    /// «Стоп»: пауза и в начало.
    func stop() {
        node.stop()
        isPlaying = false
        feeding = false
        stopTicker()
        position = 0
        scheduleGeneration &+= 1
        notify()
    }

    func seek(to seconds: Double) {
        guard let file else { return }
        let target = max(0, min(duration, seconds))
        let wasPlaying = isPlaying
        node.stop()
        scheduleGeneration &+= 1
        position = target
        if wasPlaying {
            schedule(from: AVAudioFramePosition(target * sampleRate), file: file)
            node.play()
        }
        notify()
    }

    // MARK: - Внутренности

    private func ensureEngine() -> Bool {
        installTapIfNeeded()
        guard !engine.isRunning else { return true }
        do {
            try engine.start()
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func stopEngine() {
        node.stop()
        scheduleGeneration &+= 1
        isPlaying = false
        feeding = false
        stopTicker()
        if engine.isRunning { engine.stop() }
    }

    private func schedule(from frame: AVAudioFramePosition, file: AVAudioFile) {
        let start = max(0, min(file.length, frame))
        let count = AVAudioFrameCount(max(0, file.length - start))
        segmentStart = start
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        guard count > 0 else { finished(generation) ; return }
        node.scheduleSegment(file, startingFrame: start, frameCount: count, at: nil,
                             completionCallbackType: .dataPlayedBack) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finished(generation) }
            }
        }
    }

    /// Отрезок доигран до конца файла.
    private func finished(_ generation: Int) {
        guard generation == scheduleGeneration, isPlaying else { return }
        if loops, let file {
            position = 0
            schedule(from: 0, file: file)
            node.play()
            notify()
            return
        }
        node.stop()
        isPlaying = false
        feeding = false
        stopTicker()
        position = duration
        notify()
    }

    private func currentPosition() -> Double {
        guard isPlaying, let nodeTime = node.lastRenderTime,
              let played = node.playerTime(forNodeTime: nodeTime) else { return position }
        return min(duration, (Double(segmentStart) + Double(played.sampleTime)) / max(1, sampleRate))
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                self.position = self.currentPosition()
                self.onChange?()
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    private func notify() { onChange?() }

    /// Отвод звука в трансляцию: плоский float32, каналы подряд — тот же
    /// формат, что у отвода основного плеера.
    private func installTapIfNeeded() {
        guard !tapInstalled else { return }
        tapInstalled = true
        let mixer = engine.mainMixerNode
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.feeding, !self.mainPlayerIsPlaying,
                  let sink = self.networkAudioSink,
                  let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            guard frames > 0, count > 0 else { return }
            var planar = Data(count: frames * count * MemoryLayout<Float>.size)
            planar.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Float.self)
                for channel in 0..<count {
                    let source = channels[channel]
                    for i in 0..<frames { out[channel * frames + i] = source[i] }
                }
            }
            sink(planar, count, frames, Int(buffer.format.sampleRate))
        }
    }
}
