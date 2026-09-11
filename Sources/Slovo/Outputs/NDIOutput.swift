import Accelerate
import AppKit
import Combine
import CoreGraphics
import CoreVideo
import Foundation
import SlovoCore

/// Дневник трансляции: что программа отдала в сеть и когда.
///
/// Заведён после того, как «нажимаю Убрать, а картинка на микшере остаётся»
/// не сошлось ни с чтением кода, ни с замером кадра со стороны приёмника.
/// Мерить снаружи оказалось мало: приёмник показывает последнее, что до него
/// доехало, и по картинке не видно, отдала ли программа новый кадр или
/// промолчала. Теперь видно — прямо из неё самой.
///
/// Пишется в `~/Library/Logs/slovo-ndi.txt`, переписывается на каждый пуск.
enum NDITrace {

    static let path = NSString(string: "~/Library/Logs/slovo-ndi.txt").expandingTildeInPath
    private nonisolated(unsafe) static var started = false
    private static let lock = NSLock()

    static func say(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        if !started {
            started = true
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data("\(stamp)  \(line)\n".utf8))
        try? handle.close()
    }
}

/// Канал сетевой трансляции: превращает текущий слайд в поток кадров.
///
/// Устроен как настоящий источник видео, а не как «сохрани картинку по
/// кнопке»: у трансляции своя частота кадров, и микшер ждёт кадры даже тогда,
/// когда на экране ничего не меняется. Отсюда разделение труда — содержимое
/// приходит событиями (сменился стих), а темп задаёт таймер.
///
/// Отрисовка живёт на главном потоке (SwiftUI иначе не умеет), но случается
/// только при смене содержимого. Всё остальное — раскладка байтов, отправка,
/// счётчики — идёт на своей очереди, поэтому даже шестьдесят кадров в секунду
/// не подтормаживают набор ссылки в окне управления.
@MainActor
final class NDIOutput: ObservableObject {

    /// В каком режиме работает канал. «Нет NDI» — отдельное честное состояние,
    /// а не ошибка: кадры всё равно готовятся и уходят приёмнику внутри
    /// приложения (предпросмотр, запись), просто в сеть их никто не берёт.
    enum Mode: Equatable {
        case stopped
        case previewOnly(reason: String)
        case broadcasting(sourceName: String)

        var title: String {
            switch self {
            case .stopped:                 return "Остановлена"
            case .previewOnly:             return "Только предпросмотр"
            case let .broadcasting(name):  return OurWords.t("В эфире: %s", name)
            }
        }

        var isBroadcasting: Bool {
            if case .broadcasting = self { return true }
            return false
        }
    }

    // MARK: - Состояние для интерфейса

    @Published private(set) var isActive = false
    @Published private(set) var mode: Mode = .stopped
    @Published private(set) var frameRate: Int = 30
    @Published private(set) var sentFrameCount: Int = 0
    /// Кадры, пропущенные потому, что картинка не изменилась. Видеть это
    /// полезно: если счётчик стоит на месте, режим «только изменения» не
    /// работает и канал зря греет сеть в зале.
    @Published private(set) var skippedFrameCount: Int = 0
    @Published private(set) var connectionCount: Int = 0
    /// Пересчитано кадров фильма и выброшено без пересчёта — самопроверке:
    /// пересчётов не должно быть заметно больше, чем отправок.
    @Published private(set) var convertedFrameCount: Int = 0
    @Published private(set) var droppedFrameCount: Int = 0
    /// Порций звука ушло в сеть; строка состояния звука — для «Параметров».
    @Published private(set) var audioFrameCount: Int = 0
    /// Сколько порций звука пришло в насос и сколько не ушло из-за
    /// отсутствия отправителя — для самопроверки.
    @Published private(set) var audioInCount: Int = 0
    @Published private(set) var audioNoSenderCount: Int = 0
    /// Сколько отправок шли дольше кадра — видно в отчёте самопроверки.
    @Published private(set) var slowSendCount: Int = 0
    @Published private(set) var audioState: String = ""

    /// Захват звука программы — пока канал открыт, звук разрешён настройкой и
    /// что-то играет. С запуска захват не стартует: он спрашивает у системы
    /// разрешение, и спрашивать его при каждом старте программы незачем.
    private var audio: AnyObject?
    /// Брать ли звук из отвода плеера. Ставится на главном потоке, читается
    /// в звуковом: пока идёт системный захват, отвод молчит — иначе звук шёл
    /// бы дважды.
    nonisolated(unsafe) private var playerAudioEnabled = false

    /// Звук из отвода плеера — зовётся из звукового потока.
    nonisolated func submitPlayerAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        guard playerAudioEnabled else { return }
        pump.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: sampleRate)
    }
    var audioWanted = false {
        didSet { if audioWanted != oldValue { syncAudio(rules: currentRules) } }
    }
    /// Звук идёт не через наш плеер (YouTube, веб-страница) — взять его
    /// можно только системным захватом. Для файлов с диска захват не нужен:
    /// отвод плеера отдаёт звук без разрешений и без задержки.
    var audioNeedsSystemCapture = false {
        didSet { if audioNeedsSystemCapture != oldValue { syncAudio(rules: currentRules) } }
    }
    @Published private(set) var lastError: String?
    /// Последний отправленный кадр — им удобно показывать в настройках,
    /// что именно уходит в сеть.
    /// Последний отправленный кадр. Намеренно не `@Published`: при шестидесяти
    /// кадрах в секунду это шестьдесят перерисовок окна настроек в секунду,
    /// ради значения, которое там никто не разглядывает. Счётчики отдаются
    /// отдельно и с прореживанием.
    private(set) var lastFrame: RenderedFrame?

    /// Куда отдавать готовые кадры кроме самой сети. Через это замыкание канал
    /// подключают к предпросмотру, записи или проверке, не трогая его код.
    /// Вызывается на главном потоке и только для кадров, которые реально ушли.
    var onFrame: ((RenderedFrame) -> Void)?

    /// Имя источника, каким его увидит микшер.
    var sourceName: String = "Слово" {
        didSet {
            guard sourceName != oldValue, isActive else { return }
            let rules = currentRules
            stop()
            start(rules: rules)
        }
    }

    /// Разрешение кадра. Менять на ходу можно — таймер это переживёт.
    ///
    /// Просят размер слайда; отдаём его же или уменьшенный до высоты из
    /// настроек (`frameHeight`): по Wi-Fi полный 1080p не проходит.
    var frameSize: CGSize {
        get { requestedSize }
        set {
            requestedSize = newValue
            applyEffectiveSize()
        }
    }
    private var requestedSize = CGSize(width: 1920, height: 1080)

    private func applyEffectiveSize() {
        var size = requestedSize
        let height = currentRules.frameHeight
        if height > 0, size.height > CGFloat(height) {
            let width = (size.width * CGFloat(height) / max(1, size.height) / 2).rounded() * 2
            size = CGSize(width: width, height: CGFloat(height))
        }
        guard size != renderer.size else { return }
        renderer.size = size
        pump.reset()
        rerenderLastContent()
    }

    /// Что сейчас с NDI на этой машине — для окна настроек.
    var runtimeSummary: String { NDIRuntime.availability.summary }

    // MARK: - Внутренности

    private let renderer = SlideFrameRenderer()
    /// Свой шаблон из Конструктора — тот же, что на проекторе.
    private var preset: SlidePreset?
    private var texts = ConstructorSample()
    /// Фон, выбранный человеком: важнее фона шаблона.
    private var backgroundOverride: String?
    private var imageURL: (String?) -> URL? = { _ in nil }
    private let pump = FramePump()
    private var currentRules = OutputRules()
    private var lastSlide = Slide.blank
    /// Стиль, навязанный вызывающим поверх стиля канала, — им гасят экран
    /// (чёрный слайд) или показывают заставку. `nil` — у канала свой стиль.
    private var styleOverride: SlideStyle?
    private var lastPublish = Date.distantPast

    /// Когда счётчики в последний раз отдавались главному потоку.
    ///
    /// Насос кадров живёт на своей очереди, но об отправленном кадре и о
    /// счётчиках он рассказывал главному потоку КАЖДЫЙ раз. При шестидесяти
    /// кадрах в секунду это шестьдесят заходов в главную очередь в секунду —
    /// на пустом месте, при том что в окне от них меняется одна подпись.
    /// Самопроверка пакета на этом просто не доходила до конца: главный поток
    /// не успевал разгрестись между кадрами.
    ///
    /// Теперь наверх уходит не чаще двух раз в секунду. Счётчики — вещь
    /// справочная, чаще человеку не нужно; сам кадр при этом уходит в сеть
    /// как шёл, без задержки.
    private nonisolated(unsafe) static var lastReport = Date.distantPast
    private static let reportInterval: TimeInterval = 0.5

    init() {
        pump.onSent = { [weak self] frame in
            let now = Date()
            guard now.timeIntervalSince(Self.lastReport) >= Self.reportInterval else { return }
            Self.lastReport = now
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.frameWasSent(frame) }
            }
        }
        pump.onTick = { [weak self] stats in
            let now = Date()
            guard now.timeIntervalSince(Self.lastReport) >= Self.reportInterval else { return }
            Self.lastReport = now
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.publish(stats) }
            }
        }
    }

    deinit {
        // Источник NDI обязан быть закрыт, иначе он останется висеть в сети
        // до конца процесса. `FramePump` не изолирован, поэтому его можно
        // остановить прямо отсюда.
        pump.shutdown()
    }

    // MARK: - Управление

    /// Запускает канал по правилам вывода. Если NDI на машине нет — не падает
    /// и не отказывается работать, а переходит в предпросмотр.
    func start(rules: OutputRules) {
        currentRules = rules
        frameRate = Self.clampFrameRate(rules.frameRate)
        lastError = nil
        sentFrameCount = 0
        skippedFrameCount = 0
        connectionCount = 0
        convertedFrameCount = 0
        droppedFrameCount = 0
        audioFrameCount = 0
        isActive = true
        syncAudio(rules: rules)

        let availability = NDIRuntime.availability
        pump.start(sourceName: sourceName,
                   frameRate: frameRate,
                   onlyChanged: rules.sendsOnlyChanged,
                   useNetwork: availability.isReady) { [weak self] created in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.isActive else { return }
                    if created {
                        self.mode = .broadcasting(sourceName: self.sourceName)
                        self.lastError = nil
                    } else if availability.isReady {
                        self.mode = .previewOnly(reason: OurWords.t("NDI не дал создать источник"))
                        self.lastError = "Не удалось создать источник NDI «\(self.sourceName)»."
                    } else {
                        self.mode = .previewOnly(reason: availability.summary)
                        self.lastError = nil
                    }
                }
            }
        }
        rerenderLastContent()
    }

    func stop() {
        if #available(macOS 13.0, *), let capture = audio as? AppAudioCapture { capture.stop() }
        audio = nil
        audioState = ""
        guard isActive else { return }
        isActive = false
        mode = .stopped
        connectionCount = 0
        pump.stop()
        // «Видео по Wi-Fi» и источник «Слово Wi-Fi» кормятся тем же насосом:
        // без основного NDI он крутится без сети.
        syncAuxPump()
    }

    /// Сколько буферов звука отдал системный захват — для самопроверки.
    var capturedAudioCount: Int {
        if #available(macOS 13.0, *), let capture = audio as? AppAudioCapture { return capture.deliveredCount }
        return -1
    }
    /// Сколько порций захват отдал наружу и сколько буферов не разобрал.
    var capturedPassedCount: Int {
        if #available(macOS 13.0, *), let capture = audio as? AppAudioCapture { return capture.passedCount }
        return -1
    }
    var capturedFailedCount: Int {
        if #available(macOS 13.0, *), let capture = audio as? AppAudioCapture { return capture.failedCount }
        return -1
    }

    /// Канал «Видео по Wi-Fi» подключён к насосу.
    private(set) weak var webVideo: WebVideoOutput?
    private var webWanted = false

    func setWebVideo(_ output: WebVideoOutput?, enabled: Bool) {
        webVideo = output
        webWanted = enabled && output != nil
        pump.webSink = webWanted ? { [weak output] frame in output?.submit(frame: frame) } : nil
        syncAuxPump()
    }

    /// Кому-то нужны кадры: основному NDI, «Видео по Wi-Fi» или «Слово Wi-Fi».
    /// Раньше все входы были закрыты `guard isActive`, и без основного NDI
    /// насос крутился вхолостую.
    var feeds: Bool { isActive || webWanted || wifiWanted }

    /// Второй источник NDI «Слово Wi-Fi».
    let wifi = NDIWiFiSender()
    private var wifiWanted = false
    @Published private(set) var wifiState = ""
    @Published private(set) var wifiConnections = 0
    @Published private(set) var wifiSentCount = 0

    /// С чем сейчас запущен второй источник.
    ///
    /// Пересоздавать его на каждое применение параметров нельзя: старт
    /// программы, «Ок» в окне и живой предпросмотр «Параметров» зовут
    /// `applyProgramOptions` подряд, и «Слово Wi-Fi» на микшере каждый раз
    /// пропадал из списка и появлялся заново, а подключённый приёмник терял
    /// поток. Теперь источник трогаем только при смене имени, размера или
    /// частоты.
    private var wifiRunning: (name: String, height: Int, fps: Int)?

    func setWiFi(enabled: Bool, height: Int, fps: Int) {
        wifiWanted = enabled
        let wifi = wifi
        let name = sourceName + " Wi-Fi"
        if enabled {
            let same = wifiRunning.map { $0.name == name && $0.height == height && $0.fps == fps } ?? false
            if !same {
                wifiRunning = (name, height, fps)
                pump.performWiFi { wifi.start(name: name, height: height, fps: fps) }
            }
            pump.wifiSink = { frame in wifi.submit(frame: frame) }
            pump.wifiAudioSink = { planar, channels, samples, rate in
                wifi.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
            }
        } else {
            wifiRunning = nil
            pump.wifiSink = nil
            pump.wifiAudioSink = nil
            pump.performWiFi { wifi.stop() }
            wifiState = ""
            wifiConnections = 0
            wifiSentCount = 0
        }
        syncAuxPump()
    }

    /// NDI выключен, а веб-видео или источник для Wi-Fi нужны — насос
    /// работает без основного отправителя; не нужно ничего — стоит.
    private func syncAuxPump() {
        guard !isActive else { return }
        if webWanted || wifiWanted {
            pump.start(sourceName: sourceName, frameRate: frameRate, onlyChanged: false, useNetwork: false) { _ in }
            rerenderLastContent()
        } else {
            pump.stop()
        }
    }

    /// Правила поменялись на ходу: другая частота, другой фон, другой режим
    /// отправки. Ради этого пересоздавать источник не нужно — микшер иначе
    /// на секунду потеряет картинку.
    func apply(rules: OutputRules) {
        currentRules = rules

        if !rules.isEnabled {
            if isActive { stop() }
            return
        }
        if !isActive {
            start(rules: rules)
            return
        }

        let wanted = Self.clampFrameRate(rules.frameRate)
        if wanted != frameRate {
            frameRate = wanted
        }
        pump.configure(frameRate: wanted, onlyChanged: rules.sendsOnlyChanged)
        syncAudio(rules: rules)
        applyEffectiveSize()

        // Пересобирать кадр вручную не надо: прозрачность фона и состав текста
        // входят в его отпечаток, поэтому смена правил сама выглядит как смена
        // содержимого, а неизменившийся кадр так же сам себя и отсеет.
        rerenderLastContent()
    }

    /// Новое содержимое. Вызывать оттуда же, откуда обновляется проектор.
    ///
    /// `style` — не «стиль NDI», а стиль, которым вызывающий подменяет свой:
    /// так гасят экран или показывают заставку. Правила канала при этом
    /// остаются в силе: если NDI просили без подложки, её не будет и здесь.
    /// Передать `nil` — значит «рисуй своим стилем».
    func update(slide: Slide, style: SlideStyle? = nil,
                preset: SlidePreset? = nil,
                texts: ConstructorSample = ConstructorSample(),
                backgroundOverride: String? = nil,
                imageURL: ((String?) -> URL?)? = nil) {
        lastSlide = slide
        styleOverride = style
        self.preset = preset
        self.texts = texts
        self.backgroundOverride = backgroundOverride
        if let imageURL { self.imageURL = imageURL }
        guard feeds else { return }

        // Отрисовку откладываем на следующий проход цикла событий.
        //
        // `ImageRenderer` работает в главном потоке и стоит около восьми
        // миллисекунд на кадр. Если делать это прямо в обработчике нажатия,
        // они складываются с перерисовкой окна, и нажатие отзывается заметно
        // позже. Отложенный вызов отдаёт кадр после того, как экран уже
        // обновился, а несколько быстрых нажатий подряд схлопываются в одну
        // отрисовку — на проектор всё равно уходит только последнее.
        guard !isRenderScheduled else { return }
        isRenderScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isRenderScheduled = false
            guard self.isActive else { return }
            self.renderIfNeeded(slide: self.lastSlide)
        }
    }

    private var isRenderScheduled = false

    // MARK: - Видео в трансляцию

    /// Кадр видео вместо слайда.
    ///
    /// Настройка «Отображать Видео» (`NdiSendVideo`) стояла у автора единицей,
    /// признак читался, ложился в правила вывода — и не использовался ни одной
    /// строкой: галочка в окне обещала то, чего не было. Пока в зале идёт
    /// видео, микшеру нужно оно, а не текст — ровно так же, как на проекторе,
    /// где окно видео накрывает окно слайда.
    ///
    /// Кадр приходит из плеера уже в BGRA — том самом порядке байтов, какого
    /// ждёт и NDI. Перекладывать его в картинку и обратно незачем: остаётся
    /// вписать в холст трансляции и отдать очереди.
    func submitVideo(_ buffer: CVPixelBuffer) {
        guard feeds else { return }
        let size = renderer.size
        pump.submitVideo(buffer,
                         canvas: CGSize(width: max(1, size.width.rounded()),
                                        height: max(1, size.height.rounded())),
                         opaque: true)
    }

    /// Пересчёт кадра видео в кадр трансляции.
    ///
    /// Отдельной функцией, чтобы его можно было прогнать самопроверкой на
    /// собранном кадре — не открывая ни файла, ни сети. Ошибиться тут проще
    /// всего в шаге строки и в порядке байтов, а увидеть это на живом видео
    /// можно только глазами на микшере.
    nonisolated static func videoFrame(from buffer: CVPixelBuffer, canvas: CGSize,
                                       opaque: Bool, identity: Int) -> RenderedFrame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        let sourceStride = CVPixelBufferGetBytesPerRow(buffer)
        guard sourceWidth > 0, sourceHeight > 0 else { return nil }

        // Другой формат (не 32-битный BGRA, который мы просим у плеера) —
        // прежней дорогой через CoreGraphics: она медленнее, зато всеядна.
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let source = CGContext(data: base, width: sourceWidth, height: sourceHeight,
                                         bitsPerComponent: 8, bytesPerRow: sourceStride,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: info.rawValue)?.makeImage() else { return nil }
            return frame(from: source, canvas: canvas, opaque: opaque, identity: identity)
        }

        // Масштабируем vImage, а не CoreGraphics. Кадр 1920×1080 в холст
        // 1280×720 через CGContext стоил десятки миллисекунд, и фильм уходил
        // в сеть десятью кадрами в секунду: следующий кадр не пересчитывался,
        // пока прежний не ушёл, а пересчёт съедал больше такта. У vImage та же
        // работа — единицы миллисекунд, и поток догоняет частоту канала.
        let width = Int(canvas.width), height = Int(canvas.height)
        guard width > 1, height > 1 else { return nil }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        // Вписываем целиком: пропорции кадра важнее заполнения экрана,
        // растянутое лицо на стене видно всем.
        let scale = min(Double(width) / Double(sourceWidth), Double(height) / Double(sourceHeight))
        let drawWidth = max(2, min(width, Int((Double(sourceWidth) * scale).rounded())))
        let drawHeight = max(2, min(height, Int((Double(sourceHeight) * scale).rounded())))
        let x0 = (width - drawWidth) / 2
        let y0 = (height - drawHeight) / 2
        let done: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let target = raw.baseAddress else { return false }
            // Поля — непрозрачный чёрный (в памяти B, G, R, A): сквозь
            // прозрачные при растворении в слайд просвечивал бы текст.
            var whole = vImage_Buffer(data: target, height: vImagePixelCount(height),
                                      width: vImagePixelCount(width), rowBytes: bytesPerRow)
            let black: [UInt8] = [0, 0, 0, 255]
            vImageBufferFill_ARGB8888(&whole, black, vImage_Flags(kvImageNoFlags))
            var source = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                       height: vImagePixelCount(sourceHeight),
                                       width: vImagePixelCount(sourceWidth), rowBytes: sourceStride)
            var window = vImage_Buffer(data: target + y0 * bytesPerRow + x0 * 4,
                                       height: vImagePixelCount(drawHeight),
                                       width: vImagePixelCount(drawWidth), rowBytes: bytesPerRow)
            if drawWidth == sourceWidth, drawHeight == sourceHeight {
                // Размер совпал — простое копирование строк.
                for row in 0..<sourceHeight {
                    memcpy(target + (y0 + row) * bytesPerRow + x0 * 4, base + row * sourceStride, sourceWidth * 4)
                }
                return true
            }
            return vImageScale_ARGB8888(&source, &window, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        }
        guard done else { return nil }

        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        // Картинка — поверх тех же байтов, без копии: она нужна второму
        // источнику (уменьшить) и растворению в слайд.
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return RenderedFrame(pixels: pixels, width: width, height: height,
                             bytesPerRow: bytesPerRow, alpha: .premultiplied,
                             identity: identity, image: image, hasTransparency: !opaque)
    }

    /// То же для готовой картинки: фотография в зале и страница презентации
    /// идут на микшер той же дорогой, что и кадр фильма.
    nonisolated static func frame(from source: CGImage, canvas: CGSize,
                                  opaque: Bool, identity: Int) -> RenderedFrame? {
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
            let width = Int(canvas.width), height = Int(canvas.height)
            let bytesPerRow = width * 4
            var pixels = Data(count: bytesPerRow * height)
            let drawn: CGImage? = pixels.withUnsafeMutableBytes { raw -> CGImage? in
                guard let address = raw.baseAddress,
                      let context = CGContext(data: address, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: info.rawValue) else { return nil }
                if opaque {
                    context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
                    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                }
                // Вписываем целиком: пропорции кадра важнее заполнения экрана,
                // растянутое лицо на стене видно всем.
                let scale = min(canvas.width / Double(source.width), canvas.height / Double(source.height))
                let drawWidth = Double(source.width) * scale
                let drawHeight = Double(source.height) * scale
                context.draw(source, in: CGRect(x: (canvas.width - drawWidth) / 2,
                                                y: (canvas.height - drawHeight) / 2,
                                                width: drawWidth, height: drawHeight))
                return context.makeImage()
            }
            guard let image = drawn else { return nil }

            return RenderedFrame(pixels: pixels, width: width, height: height,
                                 bytesPerRow: bytesPerRow,
                                 alpha: .premultiplied,
                                 identity: identity,
                                 image: image, hasTransparency: !opaque)
    }

    /// Зменшити готовий кадр — для додаткового джерела «Слово Wi-Fi».
    ///
    /// Раніше вони зменшували кадр через `frame(from:canvas:)`, тобто
    /// перемальовуванням CoreGraphics прямо на черзі насоса. На слайді це
    /// нічого не коштує (кадр той самий, зменшене береться з запасу), а на
    /// фільмі відпечаток міняється щокадру — і кожен такт насоса ніс два
    /// зайві перемальовування 1280×720. Такт не встигав, і власник бачив це
    /// як «ndi по wifi тормозит»: страждав і сам Wi-Fi, і основне джерело.
    ///
    /// Тут та сама робота робиться vImage по вже готових байтах: одиниці
    /// мілісекунд замість десятків, без проміжної картинки.
    nonisolated static func downscaled(_ frame: RenderedFrame, height targetHeight: Int,
                                       identity: Int) -> RenderedFrame? {
        let height = max(2, min(targetHeight, frame.height) / 2 * 2)
        let width = max(2, Int((Double(frame.width) * Double(height) / Double(max(1, frame.height))).rounded()) / 2 * 2)
        guard frame.width > 0, frame.height > 0 else { return nil }
        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        let ok = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let target = raw.baseAddress else { return false }
            return frame.pixels.withUnsafeBytes { source -> Bool in
                guard let base = source.baseAddress else { return false }
                var input = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: base),
                                          height: vImagePixelCount(frame.height),
                                          width: vImagePixelCount(frame.width),
                                          rowBytes: frame.bytesPerRow)
                var output = vImage_Buffer(data: target, height: vImagePixelCount(height),
                                           width: vImagePixelCount(width), rowBytes: bytesPerRow)
                return vImageScale_ARGB8888(&input, &output, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard ok else { return nil }
        // Картинку робимо з тих самих байтів, без перемальовування: полю
        // `image` вона потрібна, а відправленню — ні.
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: info, provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return RenderedFrame(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
                             alpha: .premultiplied, identity: identity, image: image,
                             hasTransparency: frame.hasTransparency)
    }

    /// Картинка вместо слайда: фотография или страница презентации.
    func submitImage(_ image: CGImage?) {
        guard feeds else { return }
        guard let image else { resumeSlide(); return }
        let size = renderer.size
        pump.submitImage(image,
                         canvas: CGSize(width: max(1, size.width.rounded()),
                                        height: max(1, size.height.rounded())),
                         opaque: true)
    }

    /// Перехід між двома сторінками показу — у мережу, кадр за кадром.
    ///
    /// Та сама дорога, що й у переходу слайда: канал не вміє «змінити
    /// картинку плавно» одним рухом, він шле потік, і перехід у ньому треба
    /// намалювати. Розмір беремо з полотна каналу, щоб приймач не бачив
    /// стрибка розміру посеред переходу.
    func submitImageTransition(from: CGImage, to: CGImage,
                               kind: SlideStyle.Transition, seconds: Double) {
        guard feeds else { return }
        guard kind != .none, seconds > 0.01 else { submitImage(to); return }
        pump.beginTransition(from: from, to: to, identity: pump.nextImageIdentity(),
                             duration: seconds, transition: kind, alpha: .straight)
    }

    /// Видео кончилось или его убрали — вернуть на канал слайд.
    ///
    /// `fade` — за сколько секунд растворить кадр показа в слайде. На
    /// проекторе плавность уже была, а на микшере картинка сменялась рывком:
    /// в трансляции это заметно даже сильнее, чем в зале.
    func resumeSlide(fade: Double = 0) {
        submittedIdentity = nil
        guard feeds else { return }
        guard fade > 0.01, let from = pump.currentImage else { rerenderLastContent(); return }

        let composed = currentRules.compose(lastSlide)
        let effective = resolvedStyle(overriding: styleOverride)
        let opaque = currentRules.drawsBackground
        guard let snapshot = renderer.snapshot(slide: composed, style: effective,
                                               preset: preset, texts: texts,
                                               drawsBackground: opaque,
                                               backgroundOverride: backgroundOverride,
                                               imageURL: imageURL) else {
            rerenderLastContent()
            return
        }
        lastSnapshot = snapshot
        submittedIdentity = snapshot.identity
        pump.beginTransition(from: from, to: snapshot.image, identity: snapshot.identity,
                             duration: fade, transition: .fade, alpha: .straight)
        NDITrace.say("зал: кадр показу розчиняється в слайді за \(fade) с")
    }

    /// Погасить трансляцию немедленно.
    ///
    /// Отдельная короткая дорога в обход SwiftUI, шаблона и отпечатков
    /// содержимого. «Убрать со стены» — то самое действие, которое обязано
    /// срабатывать всегда, и чем меньше условий у него на пути, тем меньше
    /// мест, где оно может тихо не сработать: не нарисовался кадр, совпал
    /// отпечаток, не дошла отложенная отрисовка — любого из этого хватало,
    /// чтобы на микшере осталась прежняя картинка.
    ///
    /// Кадр здесь не рисуется, а обнуляется. В BGRA все нули — это разом и
    /// полностью прозрачно, и совершенно чёрно: пусто при любом обращении на
    /// приёмнике, хоть с альфой, хоть без.
    /// Что сейчас в канале — для самопроверки.
    var channelIdentity: Int? { pump.currentIdentity }

    /// Указка на кадре трансляции: `nil` — убрать.
    func setPointer(_ mark: SlidePointer.Mark?, look: SlidePointer.Look) {
        pump.setPointer(mark, look: look)
    }

    /// Кадр ли это видео. Отпечатки фильма лежат в своём диапазоне, и по ним
    /// видно, замер ли канал на последнем кадре показа.
    static func isVideoIdentity(_ identity: Int?) -> Bool { FramePump.isVideoIdentity(identity) }

    func blank(fade: Double = 0) {
        lastSlide = .blank
        submittedIdentity = nil
        guard feeds else {
            NDITrace.say("гашение: канал остановлен, гасить нечего")
            return
        }
        let width = max(1, Int(renderer.size.width.rounded()))
        let height = max(1, Int(renderer.size.height.rounded()))
        // Гасить можно и плавно — но только когда об этом просят: у кнопки
        // «Убрать» плавности быть не должно, она обязана срабатывать разом.
        if fade > 0.01, let from = pump.currentImage,
           let empty = FramePump.emptyImage(width: width, height: height) {
            pump.beginTransition(from: from, to: empty, identity: FramePump.blankIdentity,
                                 duration: fade, transition: .fade, alpha: .straight)
            NDITrace.say("гашение: кадр растворяется за \(fade) с")
            return
        }
        pump.submitBlank(width: width, height: height)
        NDITrace.say("гашение: пустой кадр \(width)×\(height) отдан очереди")
    }

    /// Разовый кадр текущего слайда — для «сохранить слайд картинкой» и для
    /// проверок. Работает и когда канал остановлен.
    func snapshotFrame(slide: Slide? = nil, style: SlideStyle? = nil) -> RenderedFrame? {
        let content = currentRules.compose(slide ?? lastSlide)
        return renderer.frame(slide: content,
                              style: resolvedStyle(overriding: style ?? styleOverride),
                              alpha: .straight)
    }

    // MARK: - Отрисовка

    /// Стиль, которым рисуется кадр: чужой поверх своего, но всегда через
    /// `effectiveStyle` — прозрачность фона решает канал, а не вызывающий.
    private func resolvedStyle(overriding override: SlideStyle?) -> SlideStyle {
        guard let override else { return currentRules.effectiveStyle }
        var rules = currentRules
        rules.style = override
        return rules.effectiveStyle
    }

    /// Отпечаток последнего отданного на отрисовку кадра.
    private var submittedIdentity: Int?
    /// Прошлый показанный кадр — с него начинается переход.
    private var lastSnapshot: SlideFrameRenderer.Snapshot?
    /// Таймер покадрового появления объектов.
    private var filmTimer: Timer?

    private func rerenderLastContent() {
        // Сменились шрифт, цвет или размер кадра — прежний отпечаток больше
        // ничего не говорит, картинку надо перерисовать даже для того же стиха.
        submittedIdentity = nil

        guard feeds else { return }
        renderIfNeeded(slide: lastSlide)
    }

    /// Рисует кадр и отдаёт его очереди. `ImageRenderer` держит главный поток
    /// ровно на время раскладки SwiftUI; всё остальное уносим в фон.
    private func renderIfNeeded(slide: Slide) {
        let composed = currentRules.compose(slide)
        let effective = resolvedStyle(overriding: styleOverride)

        // Подложку решает канал, а не шаблон: у NDI, как правило, стоит
        // «прозрачный фон» (`NdiTransparentBackGr`), и фон зала в сеть уходить
        // не должен. Благодаря этому шаблон Конструктора один на все выводы:
        // в зале он с картинкой, в трансляции — только надпись.
        let opaque = currentRules.drawsBackground
        var identity = SlideFrameRenderer.identity(slide: composed, style: effective,
                                                   size: renderer.size, preset: preset,
                                                   drawsBackground: opaque)
        if let backgroundOverride { identity = identity &+ backgroundOverride.hashValue }
        // Сверяемся со своим последним заданием, а не с уже упакованным
        // кадром очереди: между проверкой и отправкой упаковка идёт в фоне,
        // и кадр, отданный секунду назад, там ещё может не появиться —
        // тогда одна и та же картинка рисуется по второму разу.
        // Это поле живёт на главном акторе вместе с `renderIfNeeded`,
        // поэтому гонки здесь нет по построению.
        if submittedIdentity == identity {
            NDITrace.say("отрисовка: пропущена, отпечаток тот же (\(identity))")
            return
        }

        let hasEntrance = (preset?.objects.contains { $0.animation.isAnimated } ?? false) && !composed.isBlank
        // Кадр рисует очередь в фоне: на главном потоке он стоил столько же,
        // сколько кадр зала, и вместе они замораживали окно на каждое
        // движение ползунка. Отпечаток помечаем сразу — второй такой же заказ
        // не нужен; обогнанный следующим кадр отбрасывается по номеру.
        submittedIdentity = identity
        var order = SlideDrawing.Order(slide: composed, style: effective, preset: preset, texts: texts,
                                       drawsBackground: opaque, clock: hasEntrance ? 0 : nil,
                                       backgroundOverride: backgroundOverride,
                                       withSecondTranslation: !composed.secondaryTexts.isEmpty,
                                       imageURL: imageURL)
        order.resolveImages()
        renderGeneration &+= 1
        let wanted = renderGeneration
        let size = renderer.size
        SlideRenderQueue.shared.render(key: "ndi", generation: wanted, order: order,
                                       size: size, opaque: false) { [weak self] image, done in
            guard let self, done == self.renderGeneration else { return }
            guard let image else {
                self.lastError = "Не удалось нарисовать кадр \(Int(size.width))×\(Int(size.height))."
                NDITrace.say("отрисовка: НЕ УДАЛАСЬ")
                return
            }
            self.deliver(SlideFrameRenderer.Snapshot(image: image, identity: identity),
                         identity: identity, composed: composed, effective: effective, opaque: opaque)
        }
    }

    /// Номер последнего заказа кадра — устаревший ответ очереди не идёт в сеть.
    private var renderGeneration = 0

    /// Готовый кадр — в сеть: с появлением объектов по кадру, с переходом
    /// или разом.
    private func deliver(_ snapshot: SlideFrameRenderer.Snapshot, identity: Int,
                         composed: Slide, effective: SlideStyle, opaque: Bool) {
        NDITrace.say("отрисовка: кадр готов, пусто=\(composed.isBlank), отпечаток \(identity)")
        // Появление объектов рисуем по кадру: у каждого своя задержка и своя
        // длина пути, и одним растворением кадра в кадре этого не показать.
        if let preset, !composed.isBlank {
            let span = preset.objects
                .map { $0.animation }
                .filter { $0.isAnimated }
                .map { ($0.delay + $0.duration) / 1000 }
                .max() ?? 0
            if span > 0.01 {
                lastSnapshot = snapshot
                submittedIdentity = identity
                playObjectFilm(slide: composed, style: effective,
                               opaque: opaque, span: span)
                return
            }
        }

        // Переход рисуем сами: в сеть уходит поток кадров, и «как сменяется
        // слайд» здесь надо не объявить, а нарисовать — по кадру на такт.
        let effect = preset?.transition ?? currentRules.style.transition
        let seconds = preset?.transitionDuration ?? currentRules.style.transitionDuration
        if effect != .none, seconds > 0.01, let previous = lastSnapshot?.image, !composed.isBlank {
            pump.beginTransition(from: previous, to: snapshot.image,
                                 identity: identity, duration: seconds,
                                 transition: effect, alpha: .straight)
            lastSnapshot = snapshot
            submittedIdentity = identity
            return
        }
        lastSnapshot = snapshot
        // NDI в BGRA ждёт неумноженную альфу. При непрозрачном фоне разницы
        // нет, поэтому режим один на оба случая — так меньше веток.
        submittedIdentity = identity
        pump.submit(snapshot, alpha: .straight)
    }

    /// Показать появление объектов покадрово.
    ///
    /// Каждый кадр рисуется заново, с отметкой времени: SwiftUI в поток кадров
    /// свою анимацию не отдаёт, а объекты у автора выезжают вразнобой — у
    /// каждого своя задержка. Частоту нарочно держим скромной: кадр слайда
    /// стоит миллисекунды главного потока, и шестьдесят таких в секунду
    /// отняли бы у оператора отзывчивость ради того, чего он не разглядит.
    private func playObjectFilm(slide: Slide, style: SlideStyle, opaque: Bool, span: Double) {
        filmTimer?.invalidate()
        let rate = max(10, min(25, frameRate))
        let step = 1.0 / Double(rate)
        var clock = 0.0
        NDITrace.say("поява об'єктів: малюємо \(Int(span / step)) кадрів за \(span) с")
        filmTimer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { timer.invalidate(); return }
                clock += step
                let finished = clock >= span
                // Кадр появления — тоже через очередь: не поспевает — рисуется
                // последний заказанный, а не все подряд с опозданием.
                var order = SlideDrawing.Order(slide: slide, style: style, preset: self.preset,
                                               texts: self.texts, drawsBackground: opaque,
                                               clock: finished ? nil : clock,
                                               backgroundOverride: self.backgroundOverride,
                                               withSecondTranslation: !slide.secondaryTexts.isEmpty,
                                               imageURL: self.imageURL)
                order.resolveImages()
                let stamp = Int(clock * 1000)
                SlideRenderQueue.shared.render(key: "ndi-появление", generation: stamp, order: order,
                                               size: self.renderer.size, opaque: false) { [weak self] image, _ in
                    guard let self, self.isActive, let image else { return }
                    self.pump.submit(SlideFrameRenderer.Snapshot(image: image, identity: stamp), alpha: .straight)
                }
                if finished { timer.invalidate(); self.filmTimer = nil }
            }
        }
    }

    // MARK: - Обратная связь от очереди

    private func frameWasSent(_ frame: RenderedFrame) {
        guard isActive else { return }
        lastFrame = frame
        onFrame?(frame)
    }

    /// Скільки кадрів канал справді відправив — просто зараз, повз
    /// чотирираз-на-секунду оновлення для вікна.
    var sentFramesNow: Int { pump.statsNow.sent }

    /// Обновлять `@Published` шестьдесят раз в секунду — значит шестьдесят раз
    /// в секунду перерисовывать окно настроек. Точный счёт ведёт очередь,
    /// наружу отдаём четырежды в секунду.
    private func publish(_ stats: FramePump.Stats) {
        guard isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastPublish) >= 0.25 else { return }
        lastPublish = now
        sentFrameCount = stats.sent
        skippedFrameCount = stats.skipped
        connectionCount = stats.connections
        convertedFrameCount = stats.converted
        droppedFrameCount = stats.dropped
        audioFrameCount = stats.audioSent
        audioInCount = stats.audioIn
        audioNoSenderCount = stats.audioNoSender
        slowSendCount = stats.slow
        if wifiWanted {
            wifiSentCount = wifi.sent
            wifiConnections = wifi.connections
            wifiState = wifi.state
        }
    }

    /// Звук — включить или выключить по правилам вывода.
    ///
    /// Захватывается звук самой программы (см. `AppAudioCapture`): всё, что
    /// она играет, уходит в трансляцию вместе с картинкой. Разрешение на
    /// запись звука системы macOS спрашивает один раз.
    private func syncAudio(rules: OutputRules) {
        // Системный захват — только когда звук идёт мимо нашего плеера
        // (YouTube, веб). Раньше он включался и для файлов, и как только
        // сообщал «звук: идёт», отвод плеера замолкал — а сам захват отдавал
        // крохи: приёмник получал 10 порций за 3 с вместо ~130. Владелец
        // слышал это как «звука по NDI нет».
        let wanted = isActive && rules.sendsAudio && audioWanted && audioNeedsSystemCapture
        playerAudioEnabled = isActive && rules.sendsAudio && !wanted
        if wanted {
            guard audio == nil else { return }
            guard #available(macOS 13.0, *) else {
                audioState = OurWords.t("звук: нужна macOS 13 или новее")
                return
            }
            guard CGPreflightScreenCaptureAccess() else {
                audioState = OurWords.t("звук: с плеера (файлы с диска); для потоков и YouTube нужно разрешение «Запись экрана и звука системы»")
                return
            }
            let capture = AppAudioCapture()
            capture.onState = { [weak self] text in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.audioState = OurWords.t(text)
                    }
                }
            }
            capture.onSamples = { [weak self] planar, channels, samples, rate in
                self?.pump.submitAudio(planar: planar, channels: channels, samples: samples, sampleRate: rate)
            }
            audio = capture
            audioState = OurWords.t("звук: запускается…")
            capture.start()
        } else {
            if #available(macOS 13.0, *), let capture = audio as? AppAudioCapture { capture.stop() }
            audio = nil
            audioState = !rules.sendsAudio ? OurWords.t("звук: выключен настройкой")
                : (audioWanted && isActive ? OurWords.t("звук: с плеера")
                   : (audioState.hasPrefix(OurWords.t("звук: нет разрешения").prefix(12)) ? audioState : ""))
        }
    }

    /// Частоты берём из того же списка, что и оригинал: вне его микшеру
    /// придётся пересчитывать поток, а это лишняя задержка.
    static func clampFrameRate(_ value: Int) -> Int {
        let allowed = OutputConfiguration.ndiFrameRates.map { Int($0.rounded()) }
        guard let nearest = allowed.min(by: { abs($0 - value) < abs($1 - value) }) else { return 30 }
        return nearest
    }
}

// MARK: -

/// Насос кадров: таймер, отправитель и последний готовый кадр.
///
/// Отдельный класс вне главного актора — не украшение. Тик таймера не должен
/// ждать главный поток: если оператор в этот момент тянет мышью список стихов,
/// поток занят, и трансляция начала бы дёргаться. Поэтому всё, что нужно
/// таймеру, лежит здесь под обычным замком, а с интерфейсом класс говорит
/// только замыканиями.
private final class FramePump: @unchecked Sendable {

    struct Stats {
        var sent = 0
        var skipped = 0
        var connections = 0
        /// Сколько кадров фильма пересчитано в кадр трансляции.
        var converted = 0
        /// Сколько кадров фильма выброшено, потому что прежний ещё не ушёл.
        var dropped = 0
        /// Сколько порций звука ушло в сеть.
        var audioSent = 0
        /// Сколько порций звука пришло в насос (до отправки).
        var audioIn = 0
        /// Почему порция не ушла: отправителя нет.
        var audioNoSender = 0
        /// Сколько кадров фильма пропущено, потому что сеть не успевала.
        var slow = 0
    }

    /// Кадр ушёл в сеть (или был бы отправлен, если бы сеть была).
    var onSent: ((RenderedFrame) -> Void)?
    /// Приёмник кадров для «Видео по Wi-Fi»: получает текущий кадр на каждом
    /// такте, даже неизменный, — кодеру нужен ровный поток.
    var webSink: ((RenderedFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return webSinkStorage }
        set { lock.lock(); webSinkStorage = newValue; lock.unlock() }
    }
    private var webSinkStorage: ((RenderedFrame) -> Void)?
    /// Второй источник NDI «Слово Wi-Fi»: те же кадры, свой размер и частота.
    var wifiSink: ((RenderedFrame) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return wifiSinkStorage }
        set { lock.lock(); wifiSinkStorage = newValue; lock.unlock() }
    }
    private var wifiSinkStorage: ((RenderedFrame) -> Void)?

    /// Звук для второго источника — с очереди насоса.
    var wifiAudioSink: ((Data, Int, Int, Int) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return wifiAudioStorage }
        set { lock.lock(); wifiAudioStorage = newValue; lock.unlock() }
    }
    private var wifiAudioStorage: ((Data, Int, Int, Int) -> Void)?

    /// Выполнить на очереди насоса: там живут отправители.
    func perform(_ work: @escaping () -> Void) { queue.async(execute: work) }

    /// Свої черги для додаткових джерел: «Видео по Wi-Fi» (HLS) і
    /// «Слово Wi-Fi».
    ///
    /// Раніше вони працювали просто на такті насоса. Кожен із них зменшує
    /// кадр, а колишнє джерело HX (прибране 10.09.2026) ще й стискало його в
    /// H.264 — і `VTCompressionSessionEncodeFrame` на завантаженому кодері
    /// чекав. Поки він чекав, такт не йшов далі,
    /// ознака «кадр у роботі» не знімалася, і ВСІ кадри фільму для основного
    /// NDI летіли в кошик: перевірка показала «перераховано 0, викинуто 49».
    /// Власник бачив це як «ndi по wifi тормозит» — насправді гальмувало все.
    ///
    /// Тепер у кожного джерела своя черга і правило «зайнятий — пропускаємо
    /// кадр»: повільний додатковий вивід відстає сам, а основний канал іде
    /// своїм темпом.
    func performWiFi(_ work: @escaping () -> Void) { wifiQueue.async(execute: work) }

    private let wifiQueue = DispatchQueue(label: "ua.church.slovo.ndi.wifi", qos: .utility)
    private let webQueue = DispatchQueue(label: "ua.church.slovo.ndi.web", qos: .utility)
    private var wifiBusy = false
    private var webBusy = false

    /// Віддати кадр додатковому виводу, якщо він устиг упоратися з минулим.
    private func offer(_ frame: RenderedFrame, to sink: @escaping (RenderedFrame) -> Void,
                       on queue: DispatchQueue, busy: ReferenceWritableKeyPath<FramePump, Bool>) {
        lock.lock()
        if self[keyPath: busy] { lock.unlock(); return }
        self[keyPath: busy] = true
        lock.unlock()
        queue.async { [self] in
            sink(frame)
            lock.lock(); self[keyPath: busy] = false; lock.unlock()
        }
    }
    /// Счётчики после очередного тика.
    var onTick: ((Stats) -> Void)?

    private let queue = DispatchQueue(label: "ua.church.slovo.ndi", qos: .userInitiated)
    private let lock = NSLock()

    private var timer: DispatchSourceTimer?
    private var sender: NDISender?
    private var frame: RenderedFrame?
    private var sentIdentity: Int?
    private var frameRate = 30
    private var onlyChanged = true
    private var stats = Stats()
    private var connectionPoll = 0

    /// Справжній рахунок, а не той, що вже доїхав до вікна.
    ///
    /// Назовні лічильники віддаються чотири рази на секунду через головну
    /// чергу — для вікна цього досить. Але самоперевірка сама сидить у
    /// головній черзі й крутить укладений цикл, а в ньому блоки головної
    /// черги не виконуються зовсім. Тому перевірка бачила «кадрів +0» тоді,
    /// коли канал справді слав кадри — це збивало з пантелику й ховало б
    /// справжню поломку, якби вона колись сталася.
    var statsNow: Stats {
        lock.lock()
        let copy = stats
        lock.unlock()
        return copy
    }

    // MARK: Управление

    func start(sourceName: String,
               frameRate: Int,
               onlyChanged: Bool,
               useNetwork: Bool,
               completion: @escaping (Bool) -> Void) {
        lock.lock()
        self.frameRate = frameRate
        self.onlyChanged = onlyChanged
        stats = Stats()
        frame = nil
        sentIdentity = nil
        pendingVideo = false
        lock.unlock()

        queue.async { [self] in
            if sender != nil { NDITrace.say("джерело: попереднє «\(sourceName)» закрито перед новим запуском") }
            sender?.close()
            sender = useNetwork ? NDIRuntime.makeSender(name: sourceName) : nil
            // Жизнь источника — в дневник: когда микшер теряет «Слово» из
            // списка, первым делом надо знать, не закрыли ли мы его сами.
            NDITrace.say("источник: " + (useNetwork ? (sender == nil ? "НЕ создан «\(sourceName)»" : "создан «\(sourceName)»")
                                                  : "без мережі (лише передпоказ)")
                         + ", \(frameRate) к/с, лише зміни=\(onlyChanged)")
            completion(sender != nil)
            rescheduleTimer()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            if let sender { NDITrace.say("джерело: закрито «\(sender.name)» (зупинка каналу)") }
            sender?.close()
            sender = nil
        }
        lock.lock()
        frame = nil
        sentIdentity = nil
        pendingVideo = false
        lock.unlock()
    }

    /// Синхронная остановка для `deinit`: после возврата ни таймер, ни
    /// отправитель уже не существуют.
    func shutdown() {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            sender?.close()
            sender = nil
        }
    }

    func configure(frameRate newRate: Int, onlyChanged newOnlyChanged: Bool) {
        lock.lock()
        let rateChanged = newRate != frameRate
        frameRate = newRate
        onlyChanged = newOnlyChanged
        lock.unlock()
        guard rateChanged else { return }
        queue.async { [self] in
            guard timer != nil else { return }
            rescheduleTimer()
        }
    }

    /// Забыть последний кадр: следующий будет отправлен даже в режиме
    /// «только изменения».
    func reset() {
        lock.lock()
        frame = nil
        sentIdentity = nil
        pendingVideo = false
        lock.unlock()
    }

    // MARK: Кадры

    func holds(identity: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return frame?.identity == identity
    }

    /// Отпечаток пустого кадра. Постоянный: повторное гашение не должно
    /// считаться сменой содержимого.
    static let blankIdentity = Int.min + 7

    /// Нынешний кадр картинкой — с него начинается растворение при уходе
    /// показа. Без него канал переключался бы рывком.
    var currentImage: CGImage? {
        lock.lock(); defer { lock.unlock() }
        return frame?.image
    }

    /// Что сейчас стоит в очереди — это смотрит самопроверка. Отпечаток
    /// кадра видео лежит в своём диапазоне, и по нему видно, замер ли канал
    /// на последнем кадре фильма.
    var currentIdentity: Int? {
        lock.lock(); defer { lock.unlock() }
        return frame?.identity
    }

    /// Отпечатки кадров видео — по ним отличают фильм от слайда.
    static func isVideoIdentity(_ identity: Int?) -> Bool {
        guard let identity else { return false }
        return identity >= Int.min &+ 2000 && identity < Int.min &+ 1_000_000
    }

    /// Пустой кадр — все нули, без единого обращения к отрисовке.
    ///
    /// Ставится в очередь напрямую и мимо всего, что может промолчать:
    /// это дорога кнопки «Убрать», и промолчать ей нельзя.
    /// Совсем пустой кадр картинкой: все нули — это разом и прозрачно, и
    /// черно, то есть пусто при любом обращении на приёмнике.
    static func emptyImage(width: Int, height: Int) -> CGImage? {
        let bytesPerRow = width * 4
        let pixels = Data(count: bytesPerRow * height)
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: info, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    func submitBlank(width: Int, height: Int) {
        queue.async { [self] in
            let bytesPerRow = width * 4
            let pixels = Data(count: bytesPerRow * height)
            guard let provider = CGDataProvider(data: pixels as CFData) else { return }
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let image = CGImage(width: width, height: height, bitsPerComponent: 8,
                                      bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                                      provider: provider, decode: nil, shouldInterpolate: false,
                                      intent: .defaultIntent) else { return }
            let empty = RenderedFrame(pixels: pixels, width: width, height: height,
                                      bytesPerRow: bytesPerRow, alpha: .straight,
                                      identity: Self.blankIdentity, image: image,
                                      hasTransparency: true)
            lock.lock()
            fading = nil
            frame = empty
            lock.unlock()
        }
    }

    /// Кадр видео: вписать в холст трансляции и положить в очередь.
    ///
    /// Холст держим постоянным, а не подстраиваемся под размер файла: смена
    /// размера кадра посреди потока сбивает часть приёмников, и микшер на
    /// мгновение теряет картинку. Видео вписывается целиком, с полями —
    /// так же, как `contentsGravity = .resizeAspect` на проекторе.
    ///
    /// Отпечаток у каждого кадра свой: видео меняется всегда, и режим
    /// «слать только изменённое» не должен принять его за неподвижную
    /// картинку и выбросить.
    /// Пересчитанный кадр фильма ещё не ушёл в сеть.
    private var pendingVideo = false
    /// Сколько последних отправок шли дольше кадра. Только для отчёта:
    /// душить поток по этому счётчику нельзя — пробовал, и фильм на
    /// приёмнике превращался в пять кадров за четыре секунды.
    private var slowSends = 0
    /// Когда медленная отправка в последний раз попадала в дневник.
    private var lastSlowNote = Date.distantPast

    /// Очередь пересчёта кадров фильма — отдельная от очереди насоса.
    ///
    /// На очереди насоса ждут такт и порции звука. Пока кадр фильма
    /// пересчитывался перед ними, звук уходил рывками, а такт опаздывал —
    /// приёмник слышал обрывы и видел задержку.
    private let convertQueue = DispatchQueue(label: "ua.church.slovo.ndi.convert", qos: .userInitiated)

    func submitVideo(_ buffer: CVPixelBuffer, canvas: CGSize, opaque: Bool) {
        // Плеєр віддає кадри вдвічі частіше, ніж канал їх шле (60 проти 30), а
        // перерахунок кадру — найдорожча робота каналу. Тому беремо не кожен:
        // один перерахунок у польоті і не частіше за частоту каналу з невеликим
        // запасом. Половина роботи інакше йшла б марно.
        //
        // Раніше ознака «кадр у роботі» знімалася ЛИШЕ тактом насоса. Варто
        // було такту застрягти — наприклад, на кодері «Слово HX», який тоді
        // працював просто на такті, — і ознака лишалася назавжди: усі кадри
        // фільму летіли в кошик, а в залі й у трансляції стояв слайд.
        // Перевірка показувала «перераховано 0, викинуто 49». Тепер ознака
        // знімається там же, де ставиться, — після перерахунку.
        let now = CACurrentMediaTime()
        lock.lock()
        let gap = 1.0 / (Double(max(1, frameRate)) * 1.2)
        if pendingVideo || now - lastVideoAcceptedAt < gap {
            stats.dropped &+= 1
            lock.unlock()
            return
        }
        pendingVideo = true
        lastVideoAcceptedAt = now
        videoCounter &+= 1
        let identity = Int.min &+ 2000 &+ videoCounter
        lock.unlock()
        convertQueue.async { [self] in
            let packed = NDIOutput.videoFrame(from: buffer, canvas: canvas, opaque: opaque, identity: identity)
            lock.lock()
            pendingVideo = false
            guard let packed else { lock.unlock(); return }
            stats.converted &+= 1
            fading = nil
            frame = packed
            lock.unlock()
        }
    }

    /// Коли востаннє взяли кадр фільму на перерахунок.
    private var lastVideoAcceptedAt: CFTimeInterval = 0

    /// Порция звука — в сеть, с той же очереди, что и кадры.
    func submitAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) {
        queue.async { [self] in
            lock.lock(); stats.audioIn &+= 1; lock.unlock()
            // Звук додаткових джерел — теж на їхніх чергах: відправлення в
            // мережу не має тримати такт основного каналу.
            if let sink = wifiAudioSink {
                wifiQueue.async { sink(planar, channels, samples, sampleRate) }
            }
            guard let sender else {
                lock.lock(); stats.audioNoSender &+= 1; lock.unlock()
                return
            }
            guard sender.sendAudio(planar: planar, channels: channels,
                                   samples: samples, sampleRate: sampleRate) else { return }
            lock.lock(); stats.audioSent &+= 1; lock.unlock()
        }
    }

    func submitImage(_ image: CGImage, canvas: CGSize, opaque: Bool) {
        queue.async { [self] in
            lock.lock()
            videoCounter &+= 1
            let identity = Int.min &+ 2000 &+ videoCounter
            lock.unlock()
            guard let packed = NDIOutput.frame(from: image, canvas: canvas, opaque: opaque,
                                               identity: identity) else { return }
            lock.lock()
            fading = nil
            frame = packed
            lock.unlock()
        }
    }

    /// Відбиток для переходу між картинками — свій, щоб канал не сплутав
    /// його з кадром фільму і не вирішив, що картинка не змінилася.
    func nextImageIdentity() -> Int {
        lock.lock()
        videoCounter &+= 1
        let value = Int.min &+ 2000 &+ videoCounter
        lock.unlock()
        return value
    }

    /// Счётчик кадров видео — из него складывается отпечаток. Под `lock`:
    /// кадры фильма считает очередь пересчёта, картинки — очередь насоса.
    private var videoCounter = 0

    /// Идущий переход: из чего, во что и с какой поры.
    private struct Fading {
        let from: CGImage
        let to: CGImage
        let identity: Int
        let started: Date
        let duration: Double
        let transition: SlideStyle.Transition
        var easing: SlideStyle.Easing = .easeInOut
        let alpha: FrameAlpha
    }
    private var fading: Fading?
    /// Отпечаток промежуточного кадра. Свой на каждый такт: иначе режим
    /// «слать только изменённое» примет переход за неподвижную картинку.
    private var fadeCounter = 0
    private func nextFadeIdentity() -> Int {
        fadeCounter &+= 1
        return Int.min &+ 1000 &+ fadeCounter
    }

    /// Начать переход. Кадры для него складываются на этой же очереди, по
    /// одному на такт: держать их все в памяти незачем — при шестидесяти
    /// кадрах в секунду это сотни мегабайт ради трети секунды.
    func beginTransition(from: CGImage, to: CGImage, identity: Int,
                         duration: Double, transition: SlideStyle.Transition,
                         alpha: FrameAlpha) {
        queue.async { [self] in
            lock.lock()
            fading = Fading(from: from, to: to, identity: identity, started: Date(),
                            duration: duration, transition: transition, alpha: alpha)
            lock.unlock()
        }
    }

    /// Принимает снимок с главного потока и раскладывает его по байтам уже
    /// в фоне: миллисекунды на мегабайт — не та работа, ради которой стоит
    /// задерживать интерфейс.
    func submit(_ snapshot: SlideFrameRenderer.Snapshot, alpha: FrameAlpha) {
        queue.async { [self] in
            guard let packed = SlideFrameRenderer.pack(snapshot, alpha: alpha) else { return }
            lock.lock()
            // Слайд пришёл посреди растворения — растворение отменяется,
            // иначе оно каждый такт затирало бы новый кадр промежуточным.
            fading = nil
            frame = packed
            lock.unlock()
        }
    }

    // MARK: Таймер

    /// Вызывать только с `queue`.
    private func rescheduleTimer() {
        timer?.cancel()
        lock.lock()
        let rate = max(1, frameRate)
        lock.unlock()

        let interval = 1.0 / Double(rate)
        let source = DispatchSource.makeTimerSource(queue: queue)
        // Допуск в десятую долю кадра: системе разрешено чуть сдвинуть тик и
        // не будить процессор ради микросекунд — на глаз это незаметно.
        source.schedule(deadline: .now() + interval,
                        repeating: interval,
                        leeway: .milliseconds(max(1, Int(interval * 100))))
        source.setEventHandler { [weak self] in self?.tick() }
        timer = source
        source.resume()
    }

    /// Сколько тактов осталось до обязательного повтора неизменного кадра.
    private var repeatCountdown = 0

    /// Указка на кадре — ставится с главного потока, читается в такте.
    private var pointer: (mark: SlidePointer.Mark, look: SlidePointer.Look)?
    /// Последний кадр с подмешанной указкой: пока ни кадр, ни пятно не
    /// сдвинулись, второй раз его не рисуем.
    private var composedCache: (identity: Int, frame: RenderedFrame)?

    func setPointer(_ mark: SlidePointer.Mark?, look: SlidePointer.Look) {
        lock.lock()
        pointer = mark.map { ($0, look) }
        lock.unlock()
    }

    /// Кадр с указкой. Только с очереди насоса.
    ///
    /// Пятно рисуется в копию пикселей готового кадра, а не в слайд: слайд
    /// перерисовывать на каждое движение мыши было бы слишком дорого, а
    /// копия и круг стоят миллисекунды.
    private func compose(_ base: RenderedFrame, mark: SlidePointer.Mark, look: SlidePointer.Look,
                         identity: Int) -> RenderedFrame {
        if let cached = composedCache, cached.identity == identity { return cached.frame }
        var pixels = base.pixels
        let width = base.width, height = base.height, bytesPerRow = base.bytesPerRow
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue)
        pixels.withUnsafeMutableBytes { raw in
            guard let address = raw.baseAddress,
                  let context = CGContext(data: address, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: info.rawValue) else { return }
            SlidePointer.draw(mark, look: look, in: context, width: CGFloat(width), height: CGFloat(height), flipped: false)
            // Кадр с прозрачным фоном лежит с неумноженной альфой (так его
            // ждёт NDI), а CoreGraphics рисовал как в умноженную. Внутри
            // пятна возвращаем неумноженный вид — иначе пятно выходит тёмным.
            guard base.alpha == .straight else { return }
            let radius = Int((look.size * Double(height) / 2).rounded(.up)) + 3
            let cx = Int(mark.x * Double(width)), cy = Int(mark.y * Double(height))
            let bytes = address.assumingMemoryBound(to: UInt8.self)
            for y in max(0, cy - radius)..<min(height, cy + radius) {
                for x in max(0, cx - radius)..<min(width, cx + radius) {
                    let at = y * bytesPerRow + x * 4
                    let alpha = Int(bytes[at + 3])
                    guard alpha > 0, alpha < 255 else { continue }
                    bytes[at] = UInt8(min(255, Int(bytes[at]) * 255 / alpha))
                    bytes[at + 1] = UInt8(min(255, Int(bytes[at + 1]) * 255 / alpha))
                    bytes[at + 2] = UInt8(min(255, Int(bytes[at + 2]) * 255 / alpha))
                }
            }
        }
        var image = base.image
        if let provider = CGDataProvider(data: pixels as CFData),
           let drawn = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info,
                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) {
            image = drawn
        }
        let frame = RenderedFrame(pixels: pixels, width: width, height: height, bytesPerRow: bytesPerRow,
                                  alpha: base.alpha, identity: identity, image: image,
                                  hasTransparency: base.hasTransparency)
        composedCache = (identity, frame)
        return frame
    }

    private func tick() {
        // Переход впереди всего: пока он идёт, каждый такт отдаёт свой кадр.
        lock.lock()
        let ongoing = fading
        lock.unlock()
        if let ongoing {
            let passed = Date().timeIntervalSince(ongoing.started)
            let step = min(1, passed / max(0.01, ongoing.duration))
            let done = step >= 1
            if let composed = SlideFrameRenderer.blend(from: ongoing.from, to: ongoing.to,
                                                       progress: step,
                                                       transition: ongoing.transition,
                                                       easing: ongoing.easing,
                                                       identity: done ? ongoing.identity : nextFadeIdentity(),
                                                       alpha: ongoing.alpha) {
                lock.lock()
                frame = composed
                if done { fading = nil }
                sentIdentity = nil
                lock.unlock()
            } else {
                lock.lock(); fading = nil; lock.unlock()
            }
        }

        lock.lock()
        let wantsOnlyChanged = onlyChanged
        let rate = frameRate
        let pointer = self.pointer
        var sendsNow = false
        var changedNow = false
        // Указка — часть кадра трансляции: пятно сдвинулось — кадр другой,
        // и режим «только изменения» обязан его отправить.
        let effectiveIdentity: Int? = frame.map { base in
            pointer.map { base.identity &+ SlidePointer.hash($0.mark, look: $0.look) } ?? base.identity
        }
        if let effectiveIdentity {
            // «Слать только изменённое» экономит работу, но приёмник,
            // подключившийся между сменами слайдов, не получит вообще ничего
            // и покажет пустоту. Поэтому неизменный кадр всё равно
            // повторяем — раз в секунду этого достаточно, чтобы картинка
            // появилась сразу, и в сто раз дешевле полного потока.
            let changed = sentIdentity != effectiveIdentity
            changedNow = changed
            repeatCountdown = changed ? 0 : repeatCountdown - 1
            if changed || !wantsOnlyChanged || repeatCountdown <= 0 {
                sentIdentity = effectiveIdentity
                repeatCountdown = max(1, rate)
                sendsNow = true
            }

        }
        if sendsNow { stats.sent += 1 } else { stats.skipped += 1 }
        let baseFrame = frame
        let webSink = webSinkStorage
        let wifiSink = wifiSinkStorage
        lock.unlock()
        // Подмес указки — вне замка: рисование стоит миллисекунды, а замок
        // держат и звук, и кадры фильма.
        let shownFrame: RenderedFrame? = baseFrame.map { base in
            guard let pointer, let effectiveIdentity else { return base }
            return compose(base, mark: pointer.mark, look: pointer.look, identity: effectiveIdentity)
        }
        let outgoing = sendsNow ? shownFrame : nil
        if let shownFrame {
            // Додаткові виводи — кожен на своїй черзі і без черги кадрів:
            // поки не впорався з минулим, новий пропускаємо. Інакше повільний
            // кодер зупиняє такт, а з ним і основний канал.
            if let webSink { offer(shownFrame, to: webSink, on: webQueue, busy: \.webBusy) }
            if let wifiSink { offer(shownFrame, to: wifiSink, on: wifiQueue, busy: \.wifiBusy) }
        }

        if let outgoing {
            if changedNow {
                NDITrace.say("у мережу: кадр \(outgoing.identity)"
                             + (outgoing.identity == Self.blankIdentity ? " (пустой)" : "")
                             + ", приймачів \(stats.connections)"
                             + (sender == nil ? ", СЕТИ НЕТ" : ""))
            }
            let started = Date()
            sender?.send(outgoing, frameRate: rate, opaque: !outgoing.hasTransparency)
            let took = Date().timeIntervalSince(started)
            if took > 1.5 / Double(max(1, rate)) {
                lock.lock(); stats.slow &+= 1; slowSends &+= 1; lock.unlock()
                // Не чаще раза в секунду: по этим строкам на чужой машине
                // видно, что тормозит именно отправка, а не отрисовка.
                if started.timeIntervalSince(lastSlowNote) >= 1 {
                    lastSlowNote = started
                    NDITrace.say(String(format: "у мережу: відправлення кадру %d×%d тривало %.0f мс при такті %.0f мс, приймачів %d",
                                        outgoing.width, outgoing.height, took * 1000, 1000 / Double(max(1, rate)), stats.connections))
                }
            }
            onSent?(outgoing)
        }

        // Число подключений спрашиваем не каждый кадр: вызов идёт внутрь SDK.
        connectionPoll += 1
        if connectionPoll >= rate {
            connectionPoll = 0
            let count = sender?.connectionCount() ?? 0
            lock.lock(); stats.connections = count; lock.unlock()
        }

        lock.lock(); let snapshot = stats; lock.unlock()
        onTick?(snapshot)
    }
}
