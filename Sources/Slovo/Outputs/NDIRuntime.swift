import Foundation
import SlovoCore

/// Подключение к библиотеке NDI, если она есть на машине.
///
/// NDI SDK нельзя ни положить в репозиторий, ни требовать при установке:
/// это отдельная лицензия и отдельный установщик, а служение должно идти и
/// без него. Поэтому библиотека ищется в местах, куда её кладут официальные
/// установщики, открывается через `dlopen`, а нужные функции берутся
/// `dlsym`-ом по документированным именам. Ничего не нашлось — канал молча
/// переходит в режим «локальный предпросмотр кадров» и честно об этом
/// сообщает; падать тут не из-за чего.
///
/// Своего заголовка у нас нет, поэтому две структуры SDK
/// (`NDIlib_send_create_t` и `NDIlib_video_frame_v2_t`) складываются байтами
/// по документированной раскладке — см. `NDISender.FrameLayout`. Раскладку
/// своих структур Swift не гарантирует, а смещения в сыром буфере —
/// гарантирует; на чужом ABI это единственный честный способ.
enum NDIRuntime {

    /// Что удалось найти. Состояние честное: «не установлено» — это не ошибка
    /// и не повод прятать канал из настроек.
    enum Availability {
        case notInstalled(searched: [String])
        /// Библиотека есть, но пользоваться ей нельзя — не тот процессор,
        /// не те символы, слишком старая версия.
        case unusable(path: String, reason: String)
        case ready(path: String, version: String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// Строка для окна настроек — на языке пользователя, без англицизмов.
        var summary: String {
            switch self {
            case .notInstalled:
                return OurWords.t("NDI не установлен. Кадры готовятся, но в сеть не уходят.")
            case let .unusable(path, reason):
                return OurWords.t("NDI найден (%s), но не работает: %s.", path, reason)
            case let .ready(_, version):
                return OurWords.t("NDI готов: %s.", version)
            }
        }

        /// Где искали — нужно, когда пользователь уверен, что NDI у него есть.
        var searchedPaths: [String] {
            if case let .notInstalled(searched) = self { return searched }
            return []
        }
    }

    // MARK: - Поиск и загрузка

    private static let lock = NSLock()
    private static var cachedAPI: NDIAPI??
    private static var cachedAvailability: Availability?

    /// Состояние NDI. Поиск делается один раз за запуск: `dlopen` недёшев, а
    /// установщик NDI посреди служения никто не запускает.
    static var availability: Availability {
        lock.lock()
        defer { lock.unlock() }
        if let cachedAvailability { return cachedAvailability }
        let (api, state) = load()
        cachedAPI = api
        cachedAvailability = state
        return state
    }

    /// Перечитать состояние — после того как пользователь поставил NDI Tools
    /// и не хочет перезапускать программу.
    static func rescan() {
        lock.lock()
        cachedAPI = nil
        cachedAvailability = nil
        lock.unlock()
        _ = availability
    }

    private static var api: NDIAPI? {
        _ = availability
        lock.lock()
        defer { lock.unlock() }
        return cachedAPI ?? nil
    }

    /// Места, куда NDI кладут официальные установщики для macOS, плюс
    /// переменные окружения, которыми SDK сам ищет свою библиотеку.
    static var searchPaths: [String] {
        var paths: [String] = []
        // Явно указанная библиотека — первой. Так самопроверка гоняет всю
        // трансляцию на этой машине с той же libndi 4.x, что поедет на Big
        // Sur, а не с системной 6.x: иначе совместимость старого выпуска с
        // нашими вызовами оставалась бы верой, а не измерением.
        if let forced = ProcessInfo.processInfo.environment["SLOVO_NDI_LIBRARY"], !forced.isEmpty {
            paths.append(forced)
        }
        // Своя копия внутри пакета — первой: на чужой машине NDI Tools может
        // не быть вовсе, а программа должна работать одним пакетом. Кладёт её
        // туда deploy.sh.
        if let frameworks = Bundle.main.privateFrameworksURL {
            for name in libraryNames { paths.append(frameworks.appendingPathComponent(name).path) }
        }
        let environment = ProcessInfo.processInfo.environment
        // Так называет их сам загрузчик NDI (NDIlib_Load): каталог, где лежит
        // библиотека нужного поколения.
        for key in ["NDI_RUNTIME_DIR_V6", "NDI_RUNTIME_DIR_V5", "NDI_RUNTIME_DIR_V4"] {
            guard let directory = environment[key], !directory.isEmpty else { continue }
            for name in libraryNames {
                paths.append((directory as NSString).appendingPathComponent(name))
            }
        }

        let directories = [
            "/usr/local/lib",
            "/opt/homebrew/lib",
            "/Library/NDI/lib/macOS",
            "/Library/NDI SDK for Apple/lib/macOS",
            "/Library/NDI Advanced SDK for Apple/lib/macOS",
            "/Library/Application Support/NewTek/NDI/lib/macOS",
            NSHomeDirectory() + "/Library/Application Support/NewTek/NDI/lib/macOS",
        ]
        for directory in directories {
            for name in libraryNames {
                paths.append((directory as NSString).appendingPathComponent(name))
            }
        }
        paths.append(contentsOf: bundledLibraries())
        return paths
    }

    /// Библиотека внутри приложений NDI Tools.
    ///
    /// Отдельный SDK ставят единицы, а NDI Tools стоят почти у всех, кто
    /// вообще пользуется NDI, — и `libndi.dylib` едет вместе с ними внутри
    /// бандла. Обходим `/Applications` и заглядываем в каждое приложение
    /// с NDI в имени: на этой машине библиотека нашлась в «NDI Scan
    /// Converter» и в «NDI Router».
    private static func bundledLibraries() -> [String] {
        let applications = "/Applications"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: applications)) ?? []
        var found: [String] = []

        for app in names where app.lowercased().contains("ndi") && app.hasSuffix(".app") {
            let frameworks = [
                "\(applications)/\(app)/Contents/Frameworks",
                "\(applications)/\(app)/Contents/Frameworks/NTFramework.framework/Versions/A/Frameworks",
            ]
            for directory in frameworks {
                for name in libraryNames {
                    let path = (directory as NSString).appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: path) { found.append(path) }
                }
            }
        }
        return found
    }

    private static let libraryNames = [
        "libndi.dylib", "libndi.6.dylib", "libndi.5.dylib", "libndi.4.dylib",
    ]

    /// Ключ UserDefaults с выбором транспорта («auto» | «tcp»).
    static let transportKey = "SlovoNDITransport"

    /// Папка со своим `ndi-config.v1.json`: SDK читает её из переменной
    /// NDI_CONFIG_DIR (проверено опытом — имя машины из файла попало в имя
    /// источника). Так транспорт меняется только у нас, а не у всех
    /// программ NDI на машине.
    static var configFolder: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
        return base.appendingPathComponent("Slovo/ndi", isDirectory: true)
    }

    /// Готовит конфиг под выбранный транспорт и указывает на него SDK.
    /// Звать до загрузки библиотеки: после запуска NDI конфиг не перечитывает.
    static func prepareConfig() {
        let transport = UserDefaults.standard.string(forKey: transportKey) ?? "auto"
        let folder = configFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("ndi-config.v1.json")
        if transport == "tcp" {
            let json = """
            { "ndi": { "tcp":  { "send": { "enable": true },  "recv": { "enable": true } },
                       "rudp": { "send": { "enable": false }, "recv": { "enable": false } },
                       "unicast": { "send": { "enable": false }, "recv": { "enable": false } },
                       "multicast": { "send": { "enable": false }, "recv": { "enable": false } } } }
            """
            try? json.write(to: file, atomically: true, encoding: .utf8)
        } else {
            // Пустая папка — SDK берёт свои умолчания.
            try? FileManager.default.removeItem(at: file)
        }
        setenv("NDI_CONFIG_DIR", folder.path, 1)
    }

    /// Кого отвергли при последнем поиске и почему — для отчёта самопроверки:
    /// на чужой машине это единственный способ увидеть, какая библиотека
    /// взялась и почему не взялись остальные.
    nonisolated(unsafe) static var refusedCandidates: [(path: String, reason: String)] = []

    /// Слова dyld — человеческим языком. Самый частый отказ на старой
    /// системе: библиотека собрана для более новой macOS.
    static func explain(dyld message: String) -> String {
        let short = message.components(separatedBy: "\n").first ?? message
        if short.contains("newer than running OS") || short.contains("built for macOS") {
            let built = short.range(of: "built for macOS ").map {
                String(short[$0.upperBound...].prefix(while: { $0.isNumber || $0 == "." }))
            } ?? "?"
            return OurWords.t("библиотека NDI собрана для macOS %s, а эта система старше — положите libndi 5.x в папку программы как libndi-bigsur.dylib и соберите заново", "\(built)")
        }
        if short.contains("incompatible architecture") || short.contains("no suitable image") {
            return OurWords.t("библиотека NDI собрана только для Intel, а программа идёт на Apple Silicon — в свойствах программы (⌘I) включите «Открывать через Rosetta» и запустите снова")
        }
        return OurWords.t("dyld не загрузил библиотеку: %s", "\(short.suffix(160))")
    }

    private static func load() -> (NDIAPI?, Availability) {
        prepareConfig()
        let candidates = searchPaths
        var found: (handle: UnsafeMutableRawPointer, path: String)?

        // Файл есть, а dyld его не взял — это не «NDI не установлен», и
        // причину надо сохранить: на Big Sur наша libndi 6.x отвергается
        // словами «built for macOS 13.0 which is newer than running OS», и
        // без этих слов владелец видел лишь «библиотека не найдена».
        var refused: [(path: String, reason: String)] = []
        let running = ProcessInfo.processInfo.operatingSystemVersion
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            // Заголовок библиотеки читаем сами: полагаться на то, что старый
            // dyld отвергнет слишком новую библиотеку, нельзя — он может её и
            // загрузить, а работать она не будет. Наша 6.x собрана для
            // macOS 13; на Big Sur она пропускается, и очередь доходит до 4.x.
            if let required = MachOHeader.minimumOS(of: path),
               !MachOHeader.runningSystem(satisfies: required) {
                refused.append((path, OurWords.t("собрана для macOS %s, а здесь macOS %s — пропущена", "\(MachOHeader.text(required))", "\(running.majorVersion).\(running.minorVersion)")))
                continue
            }
            // RTLD_LOCAL: символы NDI не должны просачиваться в общее
            // пространство имён процесса. RTLD_NOW: пусть лучше не откроется
            // сейчас, чем упадёт на первом кадре.
            if let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                found = (handle, path)
                break
            }
            refused.append((path, explain(dyld: dlerror().map { String(cString: $0) } ?? OurWords.t("dlopen без объяснения"))))
        }
        refusedCandidates = refused
        // Последняя попытка — вдруг библиотека уже видна по путям загрузчика.
        if found == nil, let handle = dlopen("libndi.dylib", RTLD_NOW | RTLD_LOCAL) {
            found = (handle, "libndi.dylib")
        }
        guard let found else {
            if let first = refused.first {
                return (nil, .unusable(path: first.path, reason: first.reason))
            }
            return (nil, .notInstalled(searched: candidates))
        }

        guard let api = NDIAPI(handle: found.handle) else {
            dlclose(found.handle)
            return (nil, .unusable(path: found.path,
                                   reason: OurWords.t("в библиотеке нет функций отправки видео")))
        }
        if let supported = api.isSupportedCPU, !supported() {
            return (nil, .unusable(path: found.path, reason: OurWords.t("процессор не поддерживается")))
        }
        guard api.initialize() else {
            return (nil, .unusable(path: found.path, reason: OurWords.t("не удалось запустить NDI")))
        }
        return (api, .ready(path: found.path, version: api.versionString))
    }

    // MARK: - Отправитель

    /// Создаёт источник NDI с заданным именем. `nil` — значит трансляции нет;
    /// причину смотреть в `availability`.
    /// Что дошло до своего приёмника за отведённое время.
    struct ProbeResult {
        var found = false
        var video = 0
        var audio = 0
        var audioSamples = 0
        var audioRate = 0
        var audioChannels = 0
        var firstVideoAfter: TimeInterval?
        var videoWidth = 0
        var videoHeight = 0
        /// Чим приймач отримав кадр. Головне питання для HX: якщо тут
        /// лишився «H264», бібліотека стиснутий потік НЕ розібрала — кадр
        /// прилетів, а картинки в ньому немає. Приймач просив BGRX, і саме
        /// BGRX має прийти.
        var videoFourCC: UInt32 = 0
        /// Наскільки різні пікселі в отриманому кадрі: різниця найбільшого і
        /// найменшого байта з проби. Нуль — суцільна пляма, тобто картинки
        /// однаково немає, навіть якщо формат правильний.
        var videoSpread = 0
        /// Метки времени первого кадра и первой порции звука — по ним
        /// настоящий клиент выстраивает поток; нули означают беду.
        var videoTimecode: Int64 = 0
        var videoTimestamp: Int64 = 0
        var audioTimecode: Int64 = 0
        var audioTimestamp: Int64 = 0
        /// Пиковый уровень первой порции звука — виден эталон +20 дБ.
        var audioPeak: Float = 0
        var note = ""
    }

    /// Свой приёмник NDI на этой же машине: подключается к источнику, в имени
    /// которого есть `name`, и считает кадры и звук `seconds` секунд.
    ///
    /// Зачем: владелец по сети не видит ни смены слайдов, ни звука, а
    /// проверить звук локальным монитором не может. Приёмник в самой
    /// самопроверке отвечает на главный вопрос — отдаёт ли отправитель то,
    /// что должен, — без чужого клиента и без сети.
    ///
    /// Работает синхронно и долго — звать только с фонового потока.
    /// - Parameter audioOnly: просить у источника только звук. Кадр 1920×1080
    ///   без сжатия — восемь мегабайт, и приёмник, который берёт всё,
    ///   захлёбывается ими и теряет звук; так же ведёт себя и чужой клиент
    ///   на слабом канале.
    /// - Parameter lowestBandwidth: просить уменьшенный поток (как режим
    ///   «Low bandwidth» в клиентах NDI) — его делает наш же SDK, и по Wi-Fi
    ///   это главный способ не захлебнуться.
    nonisolated static func probe(sourceContaining name: String, seconds: Double,
                                  audioOnly: Bool = false, lowestBandwidth: Bool = false,
                                  after marker: (() -> Void)? = nil) -> ProbeResult {
        var result = ProbeResult()
        guard let api, let findCreate = api.findCreate, let findWait = api.findWait,
              let findSources = api.findSources, let findDestroy = api.findDestroy,
              let recvCreate = api.recvCreate, let recvConnect = api.recvConnect,
              let recvCapture = api.recvCapture, let recvDestroy = api.recvDestroy else {
            result.note = OurWords.t("в библиотеке нет функций приёмника")
            return result
        }
        // NDIlib_find_create_t: show_local_sources (bool), p_groups, p_extra_ips.
        let findSettings = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { findSettings.deallocate() }
        _ = findSettings.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
        findSettings.storeBytes(of: UInt8(1), toByteOffset: 0, as: UInt8.self)   // свои источники — да
        guard let finder = findCreate(UnsafeRawPointer(findSettings)) else {
            result.note = OurWords.t("не создался искатель источников")
            return result
        }
        defer { findDestroy(finder) }

        // Источник ищем до трёх секунд: свой должен найтись сразу.
        var source: UnsafeRawPointer?
        var sourceBytes = [UInt8](repeating: 0, count: 16)
        let searchDeadline = Date().addingTimeInterval(3)
        while source == nil, Date() < searchDeadline {
            _ = findWait(finder, 500)
            var count: UInt32 = 0
            guard let list = findSources(finder, &count) else { continue }
            // Точное имя «… (name)» важнее подстроки: рядом с «Слово» стоит
            // «Слово Wi-Fi», и подстрока ловила не тот источник.
            var fallback: UnsafeRawPointer?
            for index in 0..<Int(count) {
                let entry = list.advanced(by: index * 16)
                guard let namePointer = entry.load(as: UnsafePointer<CChar>?.self) else { continue }
                let sourceName = String(cString: namePointer)
                if sourceName.hasSuffix("(\(name))") {
                    source = entry
                    break
                }
                if fallback == nil, sourceName.contains(name) { fallback = entry }
            }
            if source == nil { source = fallback }
            if let source { sourceBytes = Array(UnsafeRawBufferPointer(start: source, count: 16)) }
        }
        guard source != nil else {
            result.note = OurWords.t("источник с «%s» в имени не найден", "\(name)")
            return result
        }
        result.found = true

        // NDIlib_recv_create_v3_t: источник (16), цвет (int, 16), полоса
        // (int, 20), поля (bool, 24), имя приёмника (ptr, 32) — 40 байт.
        let settings = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
        defer { settings.deallocate() }
        _ = settings.initializeMemory(as: UInt8.self, repeating: 0, count: 40)
        sourceBytes.withUnsafeBytes { raw in settings.copyMemory(from: raw.baseAddress!, byteCount: 16) }
        settings.storeBytes(of: Int32(0), toByteOffset: 16, as: Int32.self)     // BGRX/BGRA
        // 10 — только звук, 0 — уменьшенный поток, 100 — всё.
        settings.storeBytes(of: Int32(audioOnly ? 10 : (lowestBandwidth ? 0 : 100)), toByteOffset: 20, as: Int32.self)
        settings.storeBytes(of: UInt8(1), toByteOffset: 24, as: UInt8.self)
        let receiverName = strdup("Slovo-selftest")
        defer { free(receiverName) }
        settings.storeBytes(of: receiverName.map { UnsafeRawPointer($0) }, toByteOffset: 32, as: UnsafeRawPointer?.self)
        guard let receiver = recvCreate(UnsafeRawPointer(settings)) else {
            result.note = OurWords.t("не создался приёмник")
            return result
        }
        defer { recvDestroy(receiver) }
        sourceBytes.withUnsafeBytes { raw in recvConnect(receiver, raw.baseAddress) }

        let video = UnsafeMutableRawPointer.allocate(byteCount: 72, alignment: 8)
        let audio = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        let meta = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
        defer { video.deallocate(); audio.deallocate(); meta.deallocate() }
        _ = video.initializeMemory(as: UInt8.self, repeating: 0, count: 72)
        _ = audio.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
        _ = meta.initializeMemory(as: UInt8.self, repeating: 0, count: 24)

        var markerAt: Date?
        let started = Date()
        let deadline = started.addingTimeInterval(seconds)
        while Date() < deadline {
            // Половина времени прошла — можно сменить слайд и засечь, когда
            // приёмник получит следующий кадр.
            if let marker, markerAt == nil, Date().timeIntervalSince(started) > seconds / 2 {
                markerAt = Date()
                marker()
            }
            let kind = recvCapture(receiver, video, audio, meta, 100)
            switch kind {
            case 1:
                result.video += 1
                result.videoWidth = Int(video.load(fromByteOffset: 0, as: Int32.self))
                result.videoHeight = Int(video.load(fromByteOffset: 4, as: Int32.self))
                if result.video == 1 {
                    result.videoTimecode = video.load(fromByteOffset: 32, as: Int64.self)
                    result.videoTimestamp = video.load(fromByteOffset: 64, as: Int64.self)
                }
                // Формат і самі пікселі. Рахунок «кадрів прийшло» нічого не
                // каже про те, чи є в них картинка: стиснутий кадр, який
                // бібліотека не розібрала, теж має і розмір, і лічильник.
                let fourCC = UInt32(bitPattern: video.load(fromByteOffset: 8, as: Int32.self))
                if result.videoFourCC == 0 { result.videoFourCC = fourCC }
                if result.videoSpread == 0,
                   let pixels = video.load(fromByteOffset: 40, as: UnsafeRawPointer?.self) {
                    let stride = Int(video.load(fromByteOffset: 48, as: Int32.self))
                    let width = result.videoWidth, height = result.videoHeight
                    if stride > 0, width > 1, height > 1 {
                        var lowest = 255, highest = 0
                        // Проба по діагоналі: тридцять точок вистачає, щоб
                        // відрізнити картинку від суцільної плями.
                        for step in 0..<30 {
                            let x = min(width - 1, width * step / 30)
                            let y = min(height - 1, height * step / 30)
                            let at = y * stride + x * 4
                            guard at + 3 < stride * height else { continue }
                            for channel in 0..<3 {
                                let value = Int(pixels.load(fromByteOffset: at + channel, as: UInt8.self))
                                lowest = min(lowest, value)
                                highest = max(highest, value)
                            }
                        }
                        result.videoSpread = max(0, highest - lowest)
                    }
                }
                if let markerAt, result.firstVideoAfter == nil {
                    result.firstVideoAfter = Date().timeIntervalSince(markerAt)
                }
                api.recvFreeVideo?(receiver, video)
            case 2:
                result.audio += 1
                result.audioRate = Int(audio.load(fromByteOffset: 0, as: Int32.self))
                result.audioChannels = Int(audio.load(fromByteOffset: 4, as: Int32.self))
                result.audioSamples += Int(audio.load(fromByteOffset: 8, as: Int32.self))
                if result.audio == 1 {
                    result.audioTimecode = audio.load(fromByteOffset: 16, as: Int64.self)
                    result.audioTimestamp = audio.load(fromByteOffset: 56, as: Int64.self)
                }
                // v3: FourCC на 24, данные на 32, шаг канала на 40 — плоский float.
                if result.audio <= 5, let data = audio.load(fromByteOffset: 32, as: UnsafeRawPointer?.self) {
                    let channels = Int(audio.load(fromByteOffset: 4, as: Int32.self))
                    let samples = Int(audio.load(fromByteOffset: 8, as: Int32.self))
                    let stride = Int(audio.load(fromByteOffset: 40, as: Int32.self))
                    for channel in 0..<max(0, channels) {
                        let plane = data.advanced(by: channel * stride).bindMemory(to: Float.self, capacity: max(0, samples))
                        for i in 0..<max(0, samples) { result.audioPeak = max(result.audioPeak, abs(plane[i])) }
                    }
                }
                api.recvFreeAudio?(receiver, audio)
            case 3:
                api.recvFreeMetadata?(receiver, meta)
            default:
                break
            }
        }
        return result
    }

    static func makeSender(name: String, groups: String? = nil) -> NDISender? {
        guard let api else { return nil }
        return NDISender(api: api, name: name, groups: groups)
    }
}

/// Функции NDI, найденные в библиотеке.
///
/// Берём плоские символы, а не таблицу из `NDIlib_v5_load`: раскладку той
/// таблицы пришлось бы угадывать, а имена функций документированы и стабильны
/// уже несколько поколений SDK. `NDIlib_v5_load` всё же ищем — по нему видно
/// поколение библиотеки, если она не умеет назвать свою версию сама.
final class NDIAPI {
    typealias Initialize = @convention(c) () -> Bool
    typealias IsSupportedCPU = @convention(c) () -> Bool
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    typealias SendCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias SendVideo = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    typealias SendAudio = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    typealias SendDestroy = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias SendConnections = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias SendMetadata = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    // Приёмник — только для самопроверки: на этой же машине подключиться к
    // своему источнику и посчитать, сколько кадров и звука доходит.
    typealias FindCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias FindWait = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Bool
    typealias FindSources = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutablePointer<UInt32>?) -> UnsafeRawPointer?
    typealias RecvCreate = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    typealias RecvConnect = @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void
    typealias RecvCapture = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UInt32) -> Int32
    typealias RecvFree = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Void
    typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void

    let initialize: Initialize
    let sendCreate: SendCreate
    let sendVideo: SendVideo
    /// `NDIlib_send_send_video_async_v2`: возвращается сразу, кадр сжимается
    /// и уходит в фоне; буфер надо держать до следующего вызова.
    let sendVideoAsync: SendVideo?
    /// `NDIlib_send_send_audio_v2` — всегда плоский float, ровно наш формат.
    ///
    /// Не v3 нарочно. Опыт на этой машине (отправитель и приёмник в одном
    /// процессе): через `send_send_audio_v3` до приёмника не дошло ни одной
    /// порции звука за четыре секунды, через `v2` — все 88 из 88, 48 кГц, два
    /// канала. Владелец это и видел как «звука по NDI нет».
    let sendAudio: SendAudio?
    let sendDestroy: SendDestroy
    let isSupportedCPU: IsSupportedCPU?
    let connections: SendConnections?
    let addConnectionMetadata: SendMetadata?
    let findCreate: FindCreate?
    let findWait: FindWait?
    let findSources: FindSources?
    let findDestroy: Destroy?
    let recvCreate: RecvCreate?
    let recvConnect: RecvConnect?
    let recvCapture: RecvCapture?
    let recvFreeVideo: RecvFree?
    let recvFreeAudio: RecvFree?
    let recvFreeMetadata: RecvFree?
    let recvDestroy: Destroy?
    private let version: Version?
    private let hasV5Loader: Bool

    init?(handle: UnsafeMutableRawPointer) {
        func symbol<T>(_ name: String, as type: T.Type) -> T? {
            guard let pointer = dlsym(handle, name) else { return nil }
            return unsafeBitCast(pointer, to: type)
        }
        guard let initialize = symbol("NDIlib_initialize", as: Initialize.self),
              let sendCreate = symbol("NDIlib_send_create", as: SendCreate.self),
              let sendVideo = symbol("NDIlib_send_send_video_v2", as: SendVideo.self),
              case let sendVideoAsync = symbol("NDIlib_send_send_video_async_v2", as: SendVideo.self),
              let sendDestroy = symbol("NDIlib_send_destroy", as: SendDestroy.self)
        else { return nil }

        self.initialize = initialize
        self.sendCreate = sendCreate
        self.sendVideo = sendVideo
        self.sendVideoAsync = sendVideoAsync
        // Только v2: описатель собран под её раскладку, а v3 с ним — тихий мусор.
        self.sendAudio = symbol("NDIlib_send_send_audio_v2", as: SendAudio.self)
        self.sendDestroy = sendDestroy
        self.isSupportedCPU = symbol("NDIlib_is_supported_CPU", as: IsSupportedCPU.self)
        self.connections = symbol("NDIlib_send_get_no_connections", as: SendConnections.self)
        self.addConnectionMetadata = symbol("NDIlib_send_add_connection_metadata", as: SendMetadata.self)
        self.findCreate = symbol("NDIlib_find_create_v2", as: FindCreate.self)
        self.findWait = symbol("NDIlib_find_wait_for_sources", as: FindWait.self)
        self.findSources = symbol("NDIlib_find_get_current_sources", as: FindSources.self)
        self.findDestroy = symbol("NDIlib_find_destroy", as: Destroy.self)
        self.recvCreate = symbol("NDIlib_recv_create_v3", as: RecvCreate.self)
        self.recvConnect = symbol("NDIlib_recv_connect", as: RecvConnect.self)
        self.recvCapture = symbol("NDIlib_recv_capture_v3", as: RecvCapture.self)
        self.recvFreeVideo = symbol("NDIlib_recv_free_video_v2", as: RecvFree.self)
        self.recvFreeAudio = symbol("NDIlib_recv_free_audio_v3", as: RecvFree.self)
        self.recvFreeMetadata = symbol("NDIlib_recv_free_metadata", as: RecvFree.self)
        self.recvDestroy = symbol("NDIlib_recv_destroy", as: Destroy.self)
        self.version = symbol("NDIlib_version", as: Version.self)
        self.hasV5Loader = dlsym(handle, "NDIlib_v5_load") != nil
    }

    var versionString: String {
        if let version, let raw = version() { return String(cString: raw) }
        return hasV5Loader ? OurWords.t("версия 5 или новее") : OurWords.t("версия неизвестна")
    }

    // `NDIlib_destroy` намеренно не вызываем: выгрузка NDI посреди работы
    // процесса официально не поддерживается и роняет фоновые потоки SDK.
    // Освободить всё при выходе система умеет и сама.
}

/// Живой источник NDI. Все обращения — с одной очереди: SDK не обещает
/// потокобезопасности для одного и того же отправителя.
final class NDISender {

    /// Официальная раскладка `NDIlib_video_frame_v2_t` на 64-битной машине.
    /// Держим смещения руками, потому что Swift не обещает раскладку своих
    /// структур, а угадывать её на чужом ABI — верный способ получить
    /// «зелёный снег» в эфире вместо стиха.
    private enum FrameLayout {
        static let size = 72
        static let xres = 0            // int32
        static let yres = 4            // int32
        static let fourCC = 8          // int32
        static let frameRateN = 12     // int32
        static let frameRateD = 16     // int32
        static let aspectRatio = 20    // float
        static let formatType = 24     // int32 (+4 байта выравнивания)
        static let timecode = 32       // int64
        static let data = 40           // указатель
        static let lineStride = 48     // int32 (+4 байта выравнивания)
        static let metadata = 56       // указатель
        static let timestamp = 64      // int64
    }

    /// Раскладка `NDIlib_audio_frame_v2_t` (56 байт) — проверена опытом:
    /// с ней звук доходит до приёмника, с раскладкой v3 — нет.
    private enum AudioLayout {
        static let size = 56
        static let sampleRate = 0       // int32
        static let channels = 4         // int32
        static let samples = 8          // int32 (+4 байта выравнивания)
        static let timecode = 16        // int64
        static let data = 24            // float*
        static let channelStride = 32   // int32 (+4 байта выравнивания)
        static let metadata = 40        // указатель
        static let timestamp = 48       // int64
    }

    /// Отправляет звук: `planar` — каналы подряд, в каждом `samples` float32.
    /// Вызывается только с очереди канала. Вызов синхронный, как и у видео:
    /// буфер достаточно удержать на время вызова.
    /// Уровень звука в дБ относительно «как есть». По документации SDK
    /// ±1,0 в NDI — это +4 dBu, а обычный звук 0 dBFS принято отдавать с
    /// эталоном +20 дБ (так делают утилиты SDK при переводе из 16 бит).
    /// Без этого приёмники слышат нас на 20 дБ тише — «звука нет».
    nonisolated(unsafe) static var audioGainDb: Double = 20

    func sendAudio(planar: Data, channels: Int, samples: Int, sampleRate: Int) -> Bool {
        guard !isClosed, let sendAudio = api.sendAudio, channels > 0, samples > 0 else { return false }
        let gain = Float(pow(10, Self.audioGainDb / 20))
        if abs(gain - 1) > 0.001, !planar.isEmpty {
            var scaled = planar
            scaled.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: Float.self)
                for i in 0..<p.count { p[i] *= gain }
            }
            let saved = Self.audioGainDb
            Self.audioGainDb = 0
            defer { Self.audioGainDb = saved }
            return self.sendAudio(planar: scaled, channels: channels, samples: samples, sampleRate: sampleRate)
        }
        // NDI ждёт 48 кГц и обычно стерео; файл отдаёт своё (44,1 кГц моно).
        // Приводим сами: чужому клиенту не придётся ни пересчитывать, ни
        // отбрасывать непривычный формат.
        if sampleRate != 48_000 || channels != 2 {
            let converted = Self.toStereo48k(planar: planar, channels: channels, samples: samples, sampleRate: sampleRate)
            return self.sendAudio(planar: converted.data, channels: 2, samples: converted.samples, sampleRate: 48_000)
        }
        // Крупные порции (отвод отдаёт по 80–130 мс) — режем до 1024
        // отсчётов: клиент строит поток по меткам, и мелкие ровные порции
        // ему проще, чем редкие пачки.
        if samples > 1024 {
            var offset = 0
            var ok = true
            planar.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: Float.self)
                while offset < samples {
                    let count = min(1024, samples - offset)
                    var chunk = [Float](repeating: 0, count: count * channels)
                    for channel in 0..<channels {
                        for i in 0..<count { chunk[channel * count + i] = source[channel * samples + offset + i] }
                    }
                    let data = chunk.withUnsafeBytes { Data($0) }
                    if !self.sendAudio(planar: data, channels: channels, samples: count, sampleRate: sampleRate) { ok = false }
                    offset += count
                }
            }
            return ok
        }
        let descriptor = UnsafeMutableRawPointer.allocate(byteCount: AudioLayout.size, alignment: 8)
        defer { descriptor.deallocate() }
        _ = descriptor.initializeMemory(as: UInt8.self, repeating: 0, count: AudioLayout.size)
        descriptor.storeBytes(of: Int32(sampleRate), toByteOffset: AudioLayout.sampleRate, as: Int32.self)
        descriptor.storeBytes(of: Int32(channels), toByteOffset: AudioLayout.channels, as: Int32.self)
        descriptor.storeBytes(of: Int32(samples), toByteOffset: AudioLayout.samples, as: Int32.self)
        descriptor.storeBytes(of: Self.synthesizeTimecode, toByteOffset: AudioLayout.timecode, as: Int64.self)
        descriptor.storeBytes(of: Int32(samples * 4), toByteOffset: AudioLayout.channelStride, as: Int32.self)
        descriptor.storeBytes(of: UnsafeRawPointer?.none, toByteOffset: AudioLayout.metadata, as: UnsafeRawPointer?.self)
        descriptor.storeBytes(of: Self.synthesizeTimecode, toByteOffset: AudioLayout.timestamp, as: Int64.self)
        planar.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            descriptor.storeBytes(of: UnsafeMutableRawPointer(mutating: base),
                                  toByteOffset: AudioLayout.data, as: UnsafeMutableRawPointer?.self)
            sendAudio(instance, UnsafeRawPointer(descriptor))
        }
        return true
    }

    /// `NDIlib_FourCC_type_BGRA` и `..._BGRX`: четыре символа, младшим байтом
    /// вперёд. BGRX — тот же кадр, но приёмник знает, что альфы нет, и не
    /// тратит на неё полосу.
    private static let fourCCBGRA: Int32 = 0x4152_4742
    private static let fourCCBGRX: Int32 = 0x5852_4742
    /// `NDIlib_frame_format_type_progressive`.
    private static let progressive: Int32 = 1
    /// `NDIlib_send_timecode_synthesize` — «поставь метку времени сам».
    private static let synthesizeTimecode: Int64 = Int64.max

    private let api: NDIAPI
    private let instance: UnsafeMutableRawPointer
    /// Описатель кадра переиспользуем: он маленький, но выделять его
    /// шестьдесят раз в секунду незачем.
    private let descriptor: UnsafeMutableRawPointer
    private var isClosed = false

    let name: String

    init?(api: NDIAPI, name: String, groups: String?) {
        // `NDIlib_send_create_t`: два указателя на строки и два флага.
        let settingsSize = 24
        let settings = UnsafeMutableRawPointer.allocate(byteCount: settingsSize, alignment: 8)
        defer { settings.deallocate() }
        _ = settings.initializeMemory(as: UInt8.self, repeating: 0, count: settingsSize)

        // Строки должны пережить вызов create — держим их в локальных буферах.
        let nameBuffer = strdup(name)
        let groupsBuffer = groups.map { strdup($0) } ?? nil
        defer {
            free(nameBuffer)
            if let groupsBuffer { free(groupsBuffer) }
        }

        settings.storeBytes(of: nameBuffer.map { UnsafeRawPointer($0) }, toByteOffset: 0, as: UnsafeRawPointer?.self)
        settings.storeBytes(of: groupsBuffer.map { UnsafeRawPointer($0) }, toByteOffset: 8, as: UnsafeRawPointer?.self)
        // clock_video/clock_audio = false: темп задаёт наш таймер (FramePump),
        // а не SDK. Включать оба значило бы два пейсера сразу — лишняя
        // задержка. Документация советует clock_video для источника БЕЗ
        // своего такта; у нас такт есть.
        settings.storeBytes(of: UInt8(0), toByteOffset: 16, as: UInt8.self)
        settings.storeBytes(of: UInt8(0), toByteOffset: 17, as: UInt8.self)

        guard let instance = api.sendCreate(UnsafeRawPointer(settings)) else { return nil }
        // Метаданные подключения — имя продукта, как рекомендует SDK: их
        // получает каждый новый приёмник.
        if let add = api.addConnectionMetadata {
            let xml = "<ndi_product long_name=\"Слово\" short_name=\"Slovo\" manufacturer=\"Slovo\" version=\"1.0\" model_name=\"Slovo\" session_name=\"\(name)\" serial=\"\" />"
            xml.withCString { text in
                let frame = UnsafeMutableRawPointer.allocate(byteCount: 24, alignment: 8)
                defer { frame.deallocate() }
                _ = frame.initializeMemory(as: UInt8.self, repeating: 0, count: 24)
                frame.storeBytes(of: Int32(strlen(text) + 1), toByteOffset: 0, as: Int32.self)
                frame.storeBytes(of: Self.synthesizeTimecode, toByteOffset: 8, as: Int64.self)
                frame.storeBytes(of: UnsafeRawPointer(text), toByteOffset: 16, as: UnsafeRawPointer?.self)
                add(instance, UnsafeRawPointer(frame))
            }
        }
        self.api = api
        self.instance = instance
        self.name = name
        self.descriptor = UnsafeMutableRawPointer.allocate(byteCount: FrameLayout.size, alignment: 8)
        _ = self.descriptor.initializeMemory(as: UInt8.self, repeating: 0, count: FrameLayout.size)
    }

    deinit {
        descriptor.deallocate()
        if !isClosed { api.sendDestroy(instance) }
    }

    /// Сколько приёмников сейчас смотрит наш источник. Ноль — не ошибка:
    /// микшер мог ещё не подключиться.
    func connectionCount() -> Int {
        guard !isClosed, let connections = api.connections else { return 0 }
        return Int(connections(instance, 0))
    }

    /// Отправляет кадр. Вызывается только с очереди канала.
    ///
    /// `NDIlib_send_send_video_v2` синхронна: она возвращает управление, когда
    /// кадр уже забран, поэтому буфер достаточно удержать на время вызова —
    /// что `withUnsafeBytes` и делает.
    /// Кадр, отданный асинхронно: SDK ещё читает его память, отпускать нельзя
    /// до следующего вызова.
    private var inFlight: RenderedFrame?
    nonisolated(unsafe) static var prefersAsync = false

    func send(_ frame: RenderedFrame, frameRate: Int, opaque: Bool) {
        guard !isClosed else { return }

        descriptor.storeBytes(of: Int32(frame.width), toByteOffset: FrameLayout.xres, as: Int32.self)
        descriptor.storeBytes(of: Int32(frame.height), toByteOffset: FrameLayout.yres, as: Int32.self)
        descriptor.storeBytes(of: opaque ? Self.fourCCBGRX : Self.fourCCBGRA,
                              toByteOffset: FrameLayout.fourCC, as: Int32.self)
        // Частоту передаём дробью: 30000/1000 читается приёмником точнее,
        // чем 30/1, и оставляет место для 29.97 и 59.94, если они понадобятся.
        descriptor.storeBytes(of: Int32(max(1, frameRate) * 1000), toByteOffset: FrameLayout.frameRateN, as: Int32.self)
        descriptor.storeBytes(of: Int32(1000), toByteOffset: FrameLayout.frameRateD, as: Int32.self)
        descriptor.storeBytes(of: Float(frame.width) / Float(max(1, frame.height)),
                              toByteOffset: FrameLayout.aspectRatio, as: Float.self)
        descriptor.storeBytes(of: Self.progressive, toByteOffset: FrameLayout.formatType, as: Int32.self)
        descriptor.storeBytes(of: Self.synthesizeTimecode, toByteOffset: FrameLayout.timecode, as: Int64.self)
        descriptor.storeBytes(of: Int32(frame.bytesPerRow), toByteOffset: FrameLayout.lineStride, as: Int32.self)
        descriptor.storeBytes(of: UnsafeRawPointer?.none, toByteOffset: FrameLayout.metadata, as: UnsafeRawPointer?.self)
        // Метка времени — не ноль. Приёмник выстраивает звук и кадры по
        // меткам; нулевая читается как «эпоха», и настоящий клиент выбросит
        // кадр как устаревший (наш же приёмник в проверке просто считал
        // кадры и этого не видел). Int64.max — «пусть проставит SDK».
        descriptor.storeBytes(of: Self.synthesizeTimecode, toByteOffset: FrameLayout.timestamp, as: Int64.self)

        // Асинхронная отправка — только по просьбе: по документации один
        // медленный приёмник (телефон по Wi-Fi) держит следующий
        // асинхронный вызов, и мёрзнут все. Синхронная копирует кадр и
        // возвращается, а медленному приёмнику SDK кадры сам пропускает.
        if Self.prefersAsync, let sendAsync = api.sendVideoAsync {
            // Асинхронно: сжатие и отправка идут в фоне SDK, а насос сразу
            // берёт следующий кадр. Память кадра держим до следующего вызова —
            // `inFlight` отпускает прежний кадр только после того, как SDK
            // получил новый.
            frame.pixels.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                descriptor.storeBytes(of: UnsafeMutableRawPointer(mutating: base),
                                      toByteOffset: FrameLayout.data, as: UnsafeMutableRawPointer?.self)
                sendAsync(instance, UnsafeRawPointer(descriptor))
            }
            inFlight = frame
            return
        }
        frame.pixels.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            descriptor.storeBytes(of: UnsafeMutableRawPointer(mutating: base),
                                  toByteOffset: FrameLayout.data, as: UnsafeMutableRawPointer?.self)
            api.sendVideo(instance, UnsafeRawPointer(descriptor))
            // Указатель на чужую память в описателе не оставляем: следующий
            // кадр может прийти позже, а `deinit` не должен наткнуться на него.
            descriptor.storeBytes(of: UnsafeMutableRawPointer?.none,
                                  toByteOffset: FrameLayout.data, as: UnsafeMutableRawPointer?.self)
        }
    }

    /// Плоский float любой частоты и числа каналов → 48 кГц стерео, тоже
    /// плоский (левый канал целиком, потом правый). Линейная интерполяция:
    /// для речи и пения в зале её хватает.
    static func toStereo48k(planar: Data, channels: Int, samples: Int, sampleRate: Int) -> (data: Data, samples: Int) {
        let ratio = 48_000.0 / Double(max(1, sampleRate))
        let outSamples = max(1, Int((Double(samples) * ratio).rounded()))
        var out = [Float](repeating: 0, count: outSamples * 2)
        planar.withUnsafeBytes { raw in
            let source = raw.bindMemory(to: Float.self)
            guard source.count >= channels * samples else { return }
            for channel in 0..<2 {
                let from = min(channels - 1, channel)
                for i in 0..<outSamples {
                    let position = Double(i) / ratio
                    let index = min(samples - 1, Int(position))
                    let next = min(samples - 1, index + 1)
                    let fraction = Float(position - Double(index))
                    let a = source[from * samples + index]
                    let b = source[from * samples + next]
                    out[channel * outSamples + i] = a + (b - a) * fraction
                }
            }
        }
        return (out.withUnsafeBytes { Data($0) }, outSamples)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        // Асинхронной отправке нужен пустой вызов: он ждёт, пока SDK дочитает
        // последний кадр, — иначе память уйдёт у него из-под ног.
        if let sendAsync = api.sendVideoAsync, inFlight != nil {
            sendAsync(instance, nil)
            inFlight = nil
        }
        api.sendDestroy(instance)
    }
}
