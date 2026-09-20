import AVFoundation
import SlovoCore
import Foundation
import UniformTypeIdentifiers

/// Хвиля трека для панелі: найменше й найбільше значення відліків на кожен
/// із `mins.count` рівних відрізків файлу — як смуга в Audacity.
struct BackingWaveform: Sendable {
    let url: URL
    let mins: [Float]
    let maxs: [Float]

    /// Найгучніший відлік файлу — самоперевірці й масштабу малювання.
    var peak: Float { max(maxs.max() ?? 0, -(mins.min() ?? 0)) }

    /// Прочитати файл цілком і зібрати хвилю. Довго (секунда на пісню),
    /// тому лише поза головним потоком.
    static func build(from url: URL, buckets: Int = 2048) -> BackingWaveform? {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0, buckets > 0 else { return nil }
        let format = file.processingFormat
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { return nil }
        var mins = [Float](repeating: 0, count: buckets)
        var maxs = [Float](repeating: 0, count: buckets)
        let perBucket = max(1, Int64((Double(file.length) / Double(buckets)).rounded(.up)))
        let channels = Int(format.channelCount)
        var frame: Int64 = 0
        while frame < file.length {
            do { try file.read(into: buffer, frameCount: chunk) } catch { break }
            let count = Int(buffer.frameLength)
            guard count > 0, let data = buffer.floatChannelData else { break }
            var i = 0
            while i < count {
                let bucket = Int(min(Int64(buckets - 1), (frame + Int64(i)) / perBucket))
                // До кінця поточного відрізка — без ділення на кожен відлік.
                let bucketEnd = Int(min(Int64(count), (Int64(bucket) + 1) * perBucket - frame))
                var low = mins[bucket], high = maxs[bucket]
                for channel in 0..<channels {
                    let samples = data[channel]
                    for j in i..<max(i + 1, bucketEnd) {
                        let value = samples[j]
                        if value < low { low = value }
                        if value > high { high = value }
                    }
                }
                mins[bucket] = low
                maxs[bucket] = high
                i = max(i + 1, bucketEnd)
            }
            frame += Int64(count)
        }
        return BackingWaveform(url: url, mins: mins, maxs: maxs)
    }
}

/// Пікові рівні з виходу фонограми для індикатора. Пише звуковий потік,
/// забирає головний — тому під замком.
final class BackingLevels: @unchecked Sendable {
    private let lock = NSLock()
    private var left: Float = 0
    private var right: Float = 0
    private var fresh = false

    /// Найгучніше, що бачив відвід за весь час, — тільки для самоперевірки:
    /// воно НЕ обнуляється при читанні, і за ним видно, чи рівень губиться
    /// по дорозі до смуги, чи його не було й у звуці.
    private var loudest: Float = 0
    var loudestForCheck: Float {
        lock.lock(); defer { lock.unlock() }
        return loudest
    }
    func resetLoudestForCheck() {
        lock.lock(); loudest = 0; lock.unlock()
    }

    func push(left newLeft: Float, right newRight: Float) {
        lock.lock()
        left = max(left, newLeft)
        right = max(right, newRight)
        loudest = max(loudest, max(newLeft, newRight))
        fresh = true
        lock.unlock()
    }

    /// Найбільші піки з минулого разу; лічильник обнуляється. `nil` — нових
    /// порцій звуку не прийшло: порція йде раз на ~23 мс, а індикатор
    /// малюється частіше, і нуль між порціями смикав смугу вниз-угору.
    func take() -> (left: Float, right: Float)? {
        lock.lock()
        defer { left = 0; right = 0; fresh = false; lock.unlock() }
        return fresh ? (left, right) : nil
    }
}

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
    /// Доіграла — одразу наступна фонограма зі списку. Власник: «добавить
    /// кнопку проигрывания следующего трека после окончания». «По колу»
    /// старше: якщо ввімкнено обидві, повторюється та сама.
    @Published var playsNext = false {
        didSet {
            guard remembers, !(store === UserDefaults.standard && SessionMemory.isSuspended) else { return }
            store.set(playsNext, forKey: Self.playsNextKey)
        }
    }
    private static let playsNextKey = "backingPlaysNext"

    /// Тон фонограми в тонах: крок 0,5 (півтону), від −3 до +3. Власник:
    /// «добавить кнопки увеличения и уменьшения тона (шаг тона 0.5)». Темп
    /// при цьому не міняється. Запам'ятовується для кожного файлу окремо:
    /// пісню, яку опустили на тон, наступного разу співають так само.
    @Published private(set) var pitchTones: Double = 0
    static let pitchStep = 0.5
    static let pitchLimit = 3.0
    private let pitchUnit = AVAudioUnitTimePitch()
    private static let pitchKey = "backingPitch"

    /// Тон, що справді стоїть у звуковому ланцюжку, у центах — самоперевірці.
    var appliedPitchCents: Float { pitchUnit.pitch }

    func shiftPitch(by tones: Double) { setPitch(pitchTones + tones) }

    func setPitch(_ tones: Double) {
        let stepped = (tones / Self.pitchStep).rounded() * Self.pitchStep
        pitchTones = min(Self.pitchLimit, max(-Self.pitchLimit, stepped))
        pitchUnit.pitch = Float(pitchTones * 200)
        if let url, remembers, !(store === UserDefaults.standard && SessionMemory.isSuspended) {
            var saved = store.dictionary(forKey: Self.pitchKey) as? [String: Double] ?? [:]
            if pitchTones == 0 { saved[url.path] = nil } else { saved[url.path] = pitchTones }
            store.set(saved, forKey: Self.pitchKey)
        }
        notify()
    }
    @Published var volume: Float = 0.8 {
        didSet { node.volume = MediaPlayerModel.gain(Double(volume)) }
    }

    /// Хвиля відкритого файлу; `nil`, поки будується або файла немає.
    @Published private(set) var waveform: BackingWaveform?
    /// Піки виходу для індикатора рівня.
    let levels = BackingLevels()
    private var waveformCache: [URL: BackingWaveform] = [:]

    /// Точна позиція просто зараз — для курсора на хвилі. `position`
    /// оновлюється чотири рази на секунду, і курсор за ним ішов би ривками.
    var livePosition: Double { currentPosition() }

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
        engine.attach(pitchUnit)
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
            engine.disconnectNodeOutput(pitchUnit)
            // Програвач → зміна тону → мікшер: відвід у трансляцію й пік-метр
            // стоять на мікшері й чують уже змінений тон.
            engine.connect(node, to: pitchUnit, format: opened.processingFormat)
            engine.connect(pitchUnit, to: engine.mainMixerNode, format: opened.processingFormat)
            let saved = remembers ? (store.dictionary(forKey: Self.pitchKey) as? [String: Double])?[target.path] : nil
            pitchTones = saved ?? 0
            pitchUnit.pitch = Float(pitchTones * 200)
            loadWaveform(for: target)
            // Відкрита фонограма завжди стоїть у своєму списку: відкрили
            // кнопкою чи перетягуванням — вона там, і її видно виділеною.
            if let known = playlist.firstIndex(of: target) {
                playlistIndex = known
            } else {
                playlist.append(target)
                playlistIndex = playlist.count - 1
            }
        } catch {
            // Спершу — засобами самої macOS: буває, що `AVAudioFile` не бере
            // файл, який AVFoundation читає чудово (власник: «иногда
            // программа не воспроизводит файл минуса, несмотря на известный
            // формат mp3» — такі MP3 з довгими тегами чи хибним розширенням
            // трапляються). Розкодовуємо в тимчасовий .caf і граємо його.
            if let ready = Self.decoded(target), ready != target {
                open(ready)
                title = target.deletingPathExtension().lastPathComponent
                notify()
                return
            }
            // Далі — чужі формати (.ogg, .opus, .wma…): їх бере ffmpeg.
            if let ready = Self.converted(target), ready != target {
                open(ready)
                // Назву лишаємо від вихідного файла: у кеші вона службова.
                title = target.deletingPathExtension().lastPathComponent
                notify()
                return
            }
            file = nil
            url = nil
            title = ""
            duration = 0
            self.error = Self.explain(error, for: target)
        }
        remember()
        notify()
    }


    // MARK: - Чужі формати

    /// Тека, куди кладемо перетворені фонограми.
    private static var conversionFolder: URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-фонограми")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }


    /// Ім'я готового файла в кеші: воно має бути ОДНАКОВИМ між запусками.
    ///
    /// Грабля: `hashValue` у Swift щоразу інший (сіль на процес), тож ім'я
    /// виходило нове, і та сама мінусовка перетворювалася знову й знову, а
    /// в тимчасовій теці росли двійники. Рахуємо свій, сталий відбиток —
    /// шлях плюс час правки: змінили файл — зміниться й ім'я.
    private static func cacheName(_ source: URL, _ extension_: String) -> String {
        let stamp = (try? source.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        var mark: UInt64 = 0xcbf2_9ce4_8422_2325          // FNV-1a
        for byte in Array(source.path.utf8) + Array(String(Int(stamp)).utf8) {
            mark = (mark ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return source.deletingPathExtension().lastPathComponent
            + "-" + String(format: "%016llx", mark) + extension_
    }

    /// Розкодувати файл засобами AVFoundation у тимчасовий .caf.
    ///
    /// `AVAudioFile` користується вужчим шляхом, ніж `AVAsset`: буває, що
    /// звичайний MP3 він відкрити не може (довгі теги, обкладинка, хибне
    /// розширення), а читач ресурсу читає його без питань. Тому перш ніж
    /// кликати ffmpeg, пробуємо власний інструмент системи.
    static func decoded(_ source: URL) -> URL? {
        let asset = AVURLAsset(url: source)
        guard let track = asset.tracks(withMediaType: .audio).first else { return nil }
        let ready = conversionFolder.appendingPathComponent(cacheName(source, ".caf"))
        if FileManager.default.fileExists(atPath: ready.path) { return ready }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 2,
        ]
        guard let reader = try? AVAssetReader(asset: asset) else { return nil }
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        guard reader.canAdd(output) else { return nil }
        reader.add(output)
        guard reader.startReading() else { return nil }

        var file: AVAudioFile?
        while reader.status == .reading {
            guard let sample = output.copyNextSampleBuffer(),
                  let block = CMSampleBufferGetDataBuffer(sample) else { break }
            let count = CMBlockBufferGetDataLength(block)
            var bytes = [UInt8](repeating: 0, count: count)
            guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: &bytes) == noErr,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100,
                                             channels: 2, interleaved: true) else { break }
            let frames = AVAudioFrameCount(count / 8)   // два канали по чотири байти
            guard frames > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { continue }
            buffer.frameLength = frames
            bytes.withUnsafeBytes { raw in
                if let base = buffer.floatChannelData?[0] {
                    base.withMemoryRebound(to: UInt8.self, capacity: count) { target in
                        raw.copyBytes(to: UnsafeMutableRawBufferPointer(start: target, count: count))
                    }
                }
            }
            if file == nil {
                file = try? AVAudioFile(forWriting: ready, settings: format.settings,
                                        commonFormat: .pcmFormatFloat32, interleaved: true)
            }
            try? file?.write(from: buffer)
        }
        guard reader.status == .completed || reader.status == .reading, file != nil else {
            try? FileManager.default.removeItem(at: ready)
            return nil
        }
        file = nil
        guard let size = (try? ready.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 4096 else {
            try? FileManager.default.removeItem(at: ready)
            return nil
        }
        NativeTrace.say("фонограма: «\(source.lastPathComponent)» розкодовано засобами системи")
        return ready
    }

    /// Перетворити файл у .m4a, якщо є чим. `nil` — не вийшло.
    ///
    /// Перетворення робить ffmpeg: він читає і .ogg, і .opus, і .wma, і .ape.
    /// Готове лежить у тимчасовій теці й береться повторно, поки воно свіже —
    /// на служінні ту саму минусовку відкривають не раз.
    static func converted(_ source: URL) -> URL? {
        guard let ffmpeg = YouTubeResolver.ffmpeg else { return nil }
        let ready = conversionFolder.appendingPathComponent(cacheName(source, ".m4a"))
        if FileManager.default.fileExists(atPath: ready.path) { return ready }

        let task = Process()
        task.executableURL = ffmpeg
        task.arguments = ["-nostdin", "-y", "-i", source.path,
                          "-vn", "-c:a", "aac", "-b:a", "256k", ready.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            NativeTrace.say("фонограма: ffmpeg не запустився — \(error.localizedDescription)")
            return nil
        }
        guard task.terminationStatus == 0,
              let size = (try? ready.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 1024 else {
            try? FileManager.default.removeItem(at: ready)
            NativeTrace.say("фонограма: ffmpeg не перетворив «\(source.lastPathComponent)»")
            return nil
        }
        NativeTrace.say("фонограма: «\(source.lastPathComponent)» перетворено в \(ready.lastPathComponent)")
        return ready
    }

    /// Чому не відкрилося — словами, з якими можна щось зробити.
    static func explain(_ error: Error, for source: URL) -> String {
        let kind = source.pathExtension.uppercased()
        if YouTubeResolver.ffmpeg == nil {
            return OurWords.t("Формат %s macOS сама не грає, а ffmpeg не знайдено — покладіть ffmpeg поруч із програмою або збережіть фонограму в MP3",
                              kind.isEmpty ? "?" : kind)
        }
        return OurWords.t("Не вдалося відкрити %s: %s", "\(kind.isEmpty ? "?" : kind)", error.localizedDescription)
    }

    // MARK: - Свій список

    /// Список фонограм — окремий від списку плеєра.
    ///
    /// Власник: «для блока фонограмм нет своего плейлиста, а при перетягивании
    /// на плеер фонограмм музыки, она добавляется в общий плейлист медиа.
    /// Сделать разделение медиаплейлиста (заставки, видео и др) и плейлиста
    /// для фонограмм». Досі фонограма тримала один файл, а все, що кидали
    /// мишею, ішло в список плеєра — поруч із заставками й роликами.
    @Published private(set) var playlist: [URL] = [] { didSet { rememberPlaylist() } }
    /// Котрий пункт списку зараз відкрито.
    @Published private(set) var playlistIndex: Int?

    /// Розширення звукових файлів, які бере фонограма. Відео сюди не йде,
    /// навіть якщо в ньому є звук: ролик — справа плеєра.
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "m4b",
                                               // Власник: «некоторые минусовки не воспроизводятся, возможно есть
                                               // неподдерживаемые форматы, добавить». Ці macOS сама не грає —
                                               // їх перетворює ffmpeg (див. `converted`), а без ffmpeg програма
                                               // каже про це словами, а не мовчить.
                                               "ogg", "oga", "opus", "wma", "ape", "wv", "mpc", "amr", "ra", "tta", "dsf", "m4r"]

    /// Чи звуковий це файл для фонограми.
    static func isAudio(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if audioExtensions.contains(ext) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) && !type.conforms(to: .movie)
    }

    /// Додати файли до списку фонограм. Незвукові пропускаються; якщо
    /// нічого ще не відкрито — відкривається перший доданий (але не грає:
    /// минусовку запускають тоді, коли почали співати). Повертає, скільки
    /// файлів узято.
    @discardableResult
    func addToPlaylist(_ urls: [URL]) -> Int {
        let wanted = urls.filter(Self.isAudio)
        guard let first = wanted.first else { return 0 }
        for item in wanted where !playlist.contains(item) {
            playlist.append(item)
        }
        if url == nil, let index = playlist.firstIndex(of: first) { openFromPlaylist(at: index) }
        notify()
        return wanted.count
    }

    func openFromPlaylist(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        open(playlist[index])
    }

    func removeFromPlaylist(at index: Int) {
        guard playlist.indices.contains(index) else { return }
        let removed = playlist.remove(at: index)
        if removed == url {
            playlistIndex = nil
            close()
        } else if let current = playlistIndex, current > index {
            playlistIndex = current - 1
        }
        notify()
    }

    /// Очистити список. Те, що зараз грає, не зупиняється — як і в плеєрі:
    /// список чистять між частинами служіння, а не посеред пісні.
    func clearPlaylist() {
        playlist = url.map { [$0] } ?? []
        playlistIndex = url == nil ? nil : 0
        notify()
    }

    /// Повернути список як був — самоперевірці після своїх пробних файлів.
    func putBackPlaylist(_ urls: [URL]) {
        playlist = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        playlistIndex = url.flatMap { playlist.firstIndex(of: $0) }
        notify()
    }

    /// Куди писати пам'ять. Самоперевірка підставляє свій набір, щоб
    /// перевірити запис і читання, не чіпаючи налаштувань людини.
    var store: UserDefaults = .standard

    private static let playlistKey = "backingPlaylist"

    private func rememberPlaylist() {
        guard remembers, !(store === UserDefaults.standard && SessionMemory.isSuspended) else { return }
        store.set(playlist.map(\.path), forKey: Self.playlistKey)
    }

    /// Чи запам'ятовує цей програвач відкриту фонограму між запусками.
    /// Вмикає тільки той, з яким працює людина: самоперевірка відкриває свої
    /// пробні файли, і пам'ять від них має лишатися чистою.
    var remembers = false

    private static let memoryKey = "backingTrackFile"

    private func remember() {
        guard remembers, !(store === UserDefaults.standard && SessionMemory.isSuspended) else { return }
        if let url { store.set(url.path, forKey: Self.memoryKey) }
        else { store.removeObject(forKey: Self.memoryKey) }
    }

    /// Відкрити фонограму, що стояла минулого разу, — але не грати її.
    ///
    /// Власник: «после закрытия программы все добавленные презентации,
    /// минусовки, картинки и т.д. не сохраняются». Файла може вже й не бути
    /// — тоді просто нічого не відкриваємо.
    func restore() {
        guard remembers, url == nil else { return }
        if store.object(forKey: Self.playsNextKey) != nil { playsNext = store.bool(forKey: Self.playsNextKey) }
        // Спершу список: інакше відкрита фонограма стала б у ньому першою,
        // а решта — після неї, не в тому порядку, як їх складали.
        let saved = (store.stringArray(forKey: Self.playlistKey) ?? [])
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
        if playlist.isEmpty, !saved.isEmpty { playlist = saved }
        guard let path = store.string(forKey: Self.memoryKey),
              FileManager.default.fileExists(atPath: path) else { return }
        open(URL(fileURLWithPath: path))
    }

    func close() {
        stopEngine()
        file = nil
        url = nil
        waveform = nil
        playlistIndex = nil
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

    /// Хвиля — з кешу або фоном. Відповідь, що запізнилася (людина вже
    /// відкрила інший файл), відкидається.
    private func loadWaveform(for target: URL) {
        if let cached = waveformCache[target] { waveform = cached; return }
        waveform = nil
        Task.detached(priority: .utility) { [weak self] in
            let built = BackingWaveform.build(from: target)
            await MainActor.run {
                guard let self, let built else { return }
                if self.waveformCache.count > 30 { self.waveformCache.removeAll() }
                self.waveformCache[target] = built
                if self.url == target { self.waveform = built; self.notify() }
            }
        }
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
        if playsNext, let current = playlistIndex, playlist.indices.contains(current + 1) {
            openFromPlaylist(at: current + 1)
            if self.file != nil { play() }
            return
        }
        node.stop()
        isPlaying = false
        feeding = false
        stopTicker()
        position = duration
        notify()
    }

    /// Чи крутиться двигун звуку — самоперевірці: коли macOS міняє пристрій
    /// виводу, двигун зупиняється, і індикатор мовчить не з власної вини.
    var engineRunningForCheck: Bool { engine.isRunning }

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
        let levels = self.levels
        mixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.feeding, let channels = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let count = Int(buffer.format.channelCount)
            guard frames > 0, count > 0 else { return }
            // Піки для індикатора — завжди, поки фонограма грає: він
            // показує її рівень, а не те, що пішло в трансляцію.
            var peaks: [Float] = [0, 0]
            for channel in 0..<min(count, 2) {
                let source = channels[channel]
                var top: Float = 0
                for i in 0..<frames { top = max(top, abs(source[i])) }
                peaks[channel] = top
            }
            levels.push(left: peaks[0], right: count > 1 ? peaks[1] : peaks[0])
            guard !self.mainPlayerIsPlaying, let sink = self.networkAudioSink else { return }
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
