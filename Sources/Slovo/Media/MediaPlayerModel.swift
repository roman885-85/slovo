import AVFoundation
import AppKit
import CoreAudio
import CoreVideo
import IOSurface
import SlovoCore

// MARK: - Форматы файлов

/// Расширения, которые открывает оригинал: ключи `VideoFilesFilter` и
/// `AudioFilesFilter` из его `settings.json`.
///
/// Список читаем из файла, а не зашиваем в код: автор правит его от версии к
/// версии, и диалог «Открытие медиафайлов» должен показывать ровно то же, что
/// показывает VisioBible на этом же компьютере. Встроенная копия нужна только
/// для сборки, рядом с которой оригинала нет.
struct MediaFileFilters {
    let video: [String]
    let audio: [String]
    /// Откуда прочитаны списки. `nil` — встроенная копия.
    ///
    /// Отдельное поле, а не сравнение с `builtIn`: у поставки V2.5 списки
    /// совпадают со встроенной копией слово в слово, и по составу расширений
    /// «нашли файл» от «не нашли» не отличить.
    var sourceURL: URL?

    init(video: [String], audio: [String], sourceURL: URL? = nil) {
        self.video = video
        self.audio = audio
        self.sourceURL = sourceURL
    }

    var all: [String] { video + audio }

    /// Копия списков из поставки V2.5 — запасной вариант, если `settings.json`
    /// рядом не нашёлся.
    static let builtIn = MediaFileFilters(
        video: parse("""
            *.3g2;*.3gp;*.3gp2;*.3gpp;*.amv;*.asf;*.avi;*.bik;*.divx;*.drc;*.dv;*.dvr-ms;*.evo;\
            *.f4v;*.flv;*.gvi;*.gxf;*.m1v;*.m2t;*.m2v;*.m2ts;*.m4v;*.mkv;*.mov;*.mp2v;*.mp4;\
            *.mp4v;*.mpa;*.mpe;*.mpeg;*.mpeg1;*.mpeg2;*.mpeg4;*.mpg;*.mpv2;*.mts;*.mtv;*.mxf;\
            *.nsv;*.nuv;*.ogg;*.ogm;*.ogx;*.ogv;*.rec;*.rm;*.rmvb;*.rpl;*.thp;*.tod;*.tp;*.ts;\
            *.tts;*.vob;*.vro;*.webm;*.wmv;*.wtv;*.xesc;
            """),
        audio: parse("""
            *.3ga;*.669;*.a52;*.aac;*.ac3;*.adt;*.adts;*.aif;*.aifc;*.aiff;*.au;*.amr;*.aob;\
            *.ape;*.caf;*.cda;*.dts;*.flac;*.it;*.m4a;*.m4p;*.mid;*.mka;*.mlp;*.mod;*.mp1;\
            *.mp2;*.mp3;*.mpc;*.mpga;*.oga;*.oma;*.opus;*.qcp;*.ra;*.rmi;*.snd;*.s3m;*.spx;\
            *.tta;*.voc;*.vqf;*.w64;*.wav;*.wma;*.wv;*.xa;*.xm;
            """))

    /// - Parameters:
    ///   - dataRoot: корень данных программы — `settings.json` лежит рядом с
    ///     `Modules`.
    ///   - configFolder: папка, где нашёлся `VisioBible.ini`. Смотрим её
    ///     первой: у установки под CrossOver рабочие файлы лежат в
    ///     `ProgramData`, а не в папке самой программы, и свежий список
    ///     расширений — там.
    static func load(dataRoot: URL?, configFolder: URL? = nil) -> MediaFileFilters {
        for folder in [configFolder, dataRoot].compactMap({ $0 }) {
            if let loaded = read(folder.appendingPathComponent("settings.json")) { return loaded }
        }
        return .builtIn
    }

    private static func read(_ url: URL) -> MediaFileFilters? {
        guard var data = try? Data(contentsOf: url) else { return nil }

        // Файл записан Delphi в UTF-8 с BOM, а JSONSerialization спотыкается
        // о первые три байта.
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let settings = json["settings"] as? [String: Any] else { return nil }

        let video = parse(settings["VideoFilesFilter"] as? String ?? "")
        let audio = parse(settings["AudioFilesFilter"] as? String ?? "")
        guard !video.isEmpty || !audio.isEmpty else { return nil }
        return MediaFileFilters(video: video.isEmpty ? builtIn.video : video,
                                audio: audio.isEmpty ? builtIn.audio : audio,
                                sourceURL: url)
    }

    /// `*.mp4;*.mkv;` → `["mp4", "mkv"]`.
    static func parse(_ raw: String) -> [String] {
        raw.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .map { $0.hasPrefix("*.") ? String($0.dropFirst(2)) : $0 }
            .filter { !$0.isEmpty }
    }

    func accepts(_ url: URL) -> Bool {
        all.contains(url.pathExtension.lowercased())
    }

    /// Наборы фильтров диалога «Открытие медиафайлов» (16.1).
    ///
    /// У автора их ровно четыре, и подписи заведены под них отдельными
    /// ключами: TextMessages54 «Медиафайлы», TextMessages55 «Видеофайлы»,
    /// TextMessages56 «Аудиофайлы», TextMessages57 «Все файлы». Порядок тот
    /// же, что в оригинале: первым стоит общий набор, он же выбран заранее.
    enum FilterGroup: Int, CaseIterable, Identifiable {
        case media, video, audio, any

        var id: Int { rawValue }

        /// Ключ подписи в форме `MainForm`.
        var captionKey: String {
            switch self {
            case .media: return "TextMessages54"
            case .video: return "TextMessages55"
            case .audio: return "TextMessages56"
            case .any:   return "TextMessages57"
            }
        }

        var fallbackCaption: String {
            switch self {
            case .media: return OurWords.t("Медиафайлы")
            case .video: return OurWords.t("Видеофайлы")
            case .audio: return OurWords.t("Аудиофайлы")
            case .any:   return OurWords.t("Все файлы")
            }
        }
    }

    /// Расширения набора. Для «Все файлы» — пустой список: диалог не должен
    /// ограничивать выбор ничем.
    func extensions(in group: FilterGroup) -> [String] {
        switch group {
        case .media: return all
        case .video: return video
        case .audio: return audio
        case .any:   return []
        }
    }
}

// MARK: - Настройки плеера из VisioBible.ini

/// Секция `[mediaplayer]` файла настроек оригинала.
struct MediaPlayerSettings {
    var repeats = false
    /// `VideoDefVolume` там в процентах, 0…100.
    var volume: Double = 1
    var isMuted = false
    var videoToScreen = true
    var videoToPreview = true
    var autoPlay = true
    /// `MediaDefaultAudioDevice` — устройство вывода звука; 0 — системное,
    /// как и на вкладке «Медиа» окна настроек.
    var audioDevice = 0

    init() {}

    init(config: IniSettings?) {
        guard let config else { return }
        let section = "mediaplayer"
        repeats = config.bool("VideoRepeate", in: section) ?? repeats
        if let percent = config.int("VideoDefVolume", in: section) {
            volume = min(1, max(0, Double(percent) / 100))
        }
        isMuted = config.bool("AudioMute", in: section) ?? isMuted
        videoToScreen = config.bool("VideoToScreen", in: section) ?? videoToScreen
        videoToPreview = config.bool("VideoToPreview", in: section) ?? videoToPreview
        autoPlay = config.bool("VideoAutoPlay", in: section) ?? autoPlay
        audioDevice = config.int("MediaDefaultAudioDevice", in: section) ?? audioDevice
    }
}

// MARK: - Устройства вывода звука

/// Звуковой выход: `uid` нужен проигрывателю, `objectID` — тот же номер
/// устройства, каким его записывает `MediaDefaultAudioDevice` и каким его
/// показывает вкладка «Медиа» окна настроек.
struct MediaAudioDevice: Identifiable, Hashable {
    let objectID: Int
    let uid: String
    let name: String
    var id: String { uid }
}

/// Перечисление звуковых выходов средствами CoreAudio.
///
/// Готового списка у AVFoundation нет: `AVPlayer` умеет только принять
/// `audioOutputDeviceUniqueID`, а сам перечень устройств приходится брать у
/// звуковой подсистемы.
enum MediaAudioDevices {

    static func outputs() -> [MediaAudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }

        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap(device(id:))
    }

    private static func device(id: AudioObjectID) -> MediaAudioDevice? {
        guard hasOutput(id),
              let name = string(id, kAudioObjectPropertyName),
              let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        return MediaAudioDevice(objectID: Int(id), uid: uid, name: name)
    }

    /// Микрофоны и агрегаты без выходных каналов в список не попадают.
    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}

// MARK: - Плеер

/// Медиа-плеер (16) главного окна: воспроизведение видео и звука с диска и
/// потока по ссылке, кадр в предпросмотр и на проектор, выбор звуковой
/// дорожки, громкость, повтор и автозапуск.
///
/// Оригинал играет через ffmpeg, здесь AVFoundation: это единственный способ
/// получить на macOS аппаратное декодирование, выбор устройства вывода звука и
/// показ кадра без внешних библиотек, которых в проекте быть не должно.
@MainActor
final class MediaPlayerModel: ObservableObject {

    /// Звуковая дорожка файла — список кнопки (16.6).
    struct AudioTrack: Identifiable, Hashable {
        let id: String
        let title: String
    }

    /// Что сейчас делает плеер. Текст сообщения подставляет вид, из файла
    /// перевода оригинала (TextMessages50/51/59/60), — модель про подписи
    /// ничего не знает.
    enum Activity: Equatable {
        case idle
        case openingFile
        case openingStream
        /// Признак потока несём в самом состоянии, а не читаем у модели:
        /// к моменту, когда сообщение рисуется, `isStream` уже сброшен
        /// закрытием, и вид не смог бы выбрать между TextMessages51
        /// «Закрываем медиафайл…» и TextMessages60 «Закрываем медиапоток…».
        case closing(stream: Bool)
    }

    /// Ошибки оригинала: ErrorMessages18 и ErrorMessages20.
    enum Failure: Equatable {
        case cannotOpen
        case badURL
        /// Схема ссылки, которой на macOS нет проигрывателя: `rtp`, `rtsp`,
        /// `udp`, `mms`, `rtmp`. Отдельный случай нужен затем, что раньше
        /// такая ссылка уходила в AVFoundation и оканчивалась ErrorMessages18
        /// «Ошибка при открытии медиа-файла» — для оператора это выглядит
        /// поломкой, а не «формат не поддержан».
        case unsupportedScheme(String)
        /// Ссылка на СТРАНИЦУ видеосайта: YouTube и подобные отдают по такому
        /// адресу разметку, а не поток, и AVFoundation отвечает общей «Ошибка
        /// при открытии медиа-файла». Человеку по ней не понять, что дело не
        /// в программе и не в сети, а в самой ссылке.
        case pageLink(String)
        /// Встроенный проигрыватель YouTube отказал; число — его код ошибки
        /// (2 неверный номер, 5 не запустился, 100 ролика нет, 101/150
        /// владелец запретил показ вне сайта, −1 не загрузился сам API).
        case youTube(Int)
    }

    /// Сайты, которые по ссылке на страницу поток не отдают.
    ///
    /// YouTube тут больше нет: его ролики идут встроенным проигрывателем
    /// (`YouTubeLink`, `YouTubeEmbedPlayer`).
    ///
    /// Список короткий и явный: гадать «похоже на страницу или нет» по виду
    /// адреса нельзя — у настоящих потоков расширения часто нет вовсе.
    static let pageOnlyHosts: Set<String> = [
        "vimeo.com", "www.vimeo.com", "rutube.ru", "www.rutube.ru",
        "facebook.com", "www.facebook.com", "fb.watch", "ok.ru", "www.ok.ru",
    ]

    /// Что именно гасит картинку в зале.
    ///
    /// Затемнение (13.3) в руководстве — это «чёрный экран» без оговорок, а
    /// «Скрыть» (13.2) убирает слайд целиком. У оригинала видео живёт внутри
    /// окна слайда, поэтому гаснет вместе с ним; у нас окно отдельное, и его
    /// приходится гасить явно — иначе поверх чёрного экрана в зале остаётся
    /// кадр видео.
    struct ScreenSuppression: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// F12, «Показать/скрыть затемнение экрана» (13.3).
        static let blackout = ScreenSuppression(rawValue: 1 << 0)
        /// Esc, «Скрыть слайд» (13.2) — окно слайда не показано.
        static let hiddenSlide = ScreenSuppression(rawValue: 1 << 1)
        /// Ctrl+F5, «Показать пустой слайд».
        static let blankSlide = ScreenSuppression(rawValue: 1 << 2)
        /// «Остановить» в панели медиа: фильм отмотан к началу и с экрана
        /// снят — иначе он считался «на экране», как пауза, и стих выходил
        /// поверх замёрзшего кадра (владелец: «выводится последний кадр
        /// видео вместо слайда текста»).
        static let stopped = ScreenSuppression(rawValue: 1 << 4)
        /// В зал ушёл текст: стих Библии, куплет песни, страница набора.
        /// Экран в зале один, и два источника разом на нём не живут. Снимаем
        /// кадр этим признаком, а не галочкой «Видео на экран»: галочку
        /// ставит человек, и молча переключать её нельзя.
        static let slideTookOver = ScreenSuppression(rawValue: 1 << 3)
    }

    // MARK: Состояние для интерфейса

    @Published private(set) var mediaURL: URL?
    @Published private(set) var title = ""
    @Published private(set) var isStream = false
    /// Есть ли отвод звука с дорожки: у потоков (HLS, YouTube через yt-dlp)
    /// дорожек ресурса нет, и звук в сеть можно взять только системным
    /// захватом.
    @Published private(set) var hasAudioTap = false
    @Published private(set) var isPlaying = false {
        didSet { if isPlaying != oldValue { onPlaybackChanged?() } }
    }
    /// Пошло или встало — трансляции это нужно для звука: захватывать его
    /// стоит лишь пока что-то играет, а не с запуска программы.
    var onPlaybackChanged: (() -> Void)?
    @Published private(set) var hasVideo = false
    @Published private(set) var duration: Double = 0
    @Published private(set) var position: Double = 0
    @Published private(set) var audioTracks: [AudioTrack] = []
    @Published private(set) var selectedAudioTrackID: String?
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var failure: Failure?
    @Published private(set) var audioDevices: [MediaAudioDevice] = []

    // MARK: Настройки — [mediaplayer] оригинала

    /// «Повтор» (PSBVideoRepeate).
    @Published var repeats = false
    /// «Воспроизвести после открытия (Вкл/Выкл)» (PngSBAutoPlay).
    @Published var autoPlay = true
    /// «Отображать видео в окне предпросмотра» (CBShowVideoOnPreview).
    @Published var videoToPreview = true
    /// «Отображать видео на экране проектора (Вкл/Выкл)» (PngSBVideoToScreen).
    @Published var videoToScreen = true {
        didSet {
            // Галочку поставили — человек просит кадр в зал: снимаем уступку
            // тексту и просим зал. Прежде кнопка «Видео на экран» работала
            // лишь со второго нажатия — и выглядела сломанной.
            if videoToScreen, !oldValue {
                screenSuppression.subtract([.slideTookOver, .stopped])
                syncScreenWindow()
                onWantsHall?()
                return
            }
            syncScreenWindow()
        }
    }
    /// «Без звука» (PngSBAudioMute).
    @Published var isMuted = false {
        didSet {
            player.isMuted = isMuted
            youTube?.setMuted(isMuted)
            networkGain = isMuted ? 0 : Float(min(1, max(0, volume)))
        }
    }
    /// «Громкость:» (LMEdiaVolume), 0…1.
    @Published var volume: Double = 1 {
        didSet {
            player.volume = Float(min(1, max(0, volume)))
            youTube?.setVolume(volume)
            networkGain = isMuted ? 0 : Float(min(1, max(0, volume)))
        }
    }
    /// Громкость плеера для звука, что идёт в сеть через отвод.
    ///
    /// Отвод снимает отсчёты ДО регулятора громкости `AVPlayer`: ползунок и
    /// «Без звука» меняли то, что слышно в зале, а в NDI по-прежнему шёл
    /// звук в полную силу, да ещё с эталонными +20 дБ сверху — владелец:
    /// «слишком громкий звук и не регулируется громкостью плеера». Множитель
    /// читает звуковой поток, пишет главный; гонка на одном числе безобидна.
    nonisolated(unsafe) private(set) var networkGain: Float = 1
    /// Выбранный звуковой выход — вкладка «Медиа» настроек.
    @Published var audioDeviceUID: String? { didSet { player.audioOutputDeviceUniqueID = audioDeviceUID } }

    /// Затемнение, «Скрыть слайд» и «пустой слайд» гасят и видео.
    /// Пустой набор — обычная работа, поведение как было.
    @Published var screenSuppression: ScreenSuppression = [] {
        didSet {
            guard oldValue != screenSuppression else { return }
            syncScreenWindow()
        }
    }

    /// Видно ли сейчас видео в зале — то же условие, по которому живёт окно.
    /// Нужно диагностике: «включено (16.5), а на проекторе пусто» иначе
    /// объяснить нечем.
    var isVideoOnScreen: Bool {
        Self.showsVideoOnScreen(videoToScreen: videoToScreen,
                                hasVideo: hasVideo,
                                // Показанная картинка — тоже «есть что
                                // показывать»: у неё нет файла в плеере, но на
                                // экране она стоит наравне с фильмом.
                                hasMedia: hasMedia,
                                suppression: screenSuppression)
    }

    /// Іде захоплення екрана: кадри приходять ззовні, а не з файла.
    ///
    /// Для всієї решти програми це такий самий кадр, як у фільму: зал, NDI,
    /// живий екран і указка про різницю не знають.
    private(set) var isCapturing = false

    /// Почати показ захопленого екрана. Відкритий файл при цьому
    /// закривається: екран у залі один, і двох джерел на ньому не буває.
    func beginCapture(title: String) {
        if mediaURL != nil { close() }
        still = nil
        shownStill = nil
        isCapturing = true
        hasVideo = true
        self.title = title
        screenSuppression.subtract([.slideTookOver, .stopped])
        syncScreenWindow()
    }

    /// Кадр захоплення — тією самою дорогою, що й кадр фільму.
    func showCapturedFrame(_ buffer: CVPixelBuffer) {
        guard isCapturing else { return }
        deliverFrame(buffer)
    }

    /// Зупинити сам потік захоплення. Ставить `AppState`: модель плеєра про
    /// ScreenCaptureKit нічого не знає і знати не має.
    var stopCaptureStream: (() -> Void)?

    /// Захоплення поступається місцем тому, що показали замість нього.
    ///
    /// Власник: «если открыть захват экрана, выполнить вывод захвата, потом
    /// закрыть, то презентации и изображения вместо показа своих слайдов
    /// выдают захват экрана». Причина: «закрити» для людини — це піти зі
    /// вкладки, а потік захоплення від цього не зупинявся. Він сипав кадри
    /// шістдесят разів на секунду в ті самі шари й у ту саму мережу — і
    /// затирав щойно показану сторінку через мить після того, як її туди
    /// поклали.
    ///
    /// Правило те саме, що й для фільму з картинкою: екран у залі один, і
    /// двох джерел на ньому не буває. Захоплення знімає з себе показ саме, а
    /// не чекає, поки людина здогадається натиснути «Сховати».
    private func yieldCapture() {
        guard isCapturing else { return }
        endCapture()
        stopCaptureStream?()
    }

    /// Зупинити показ захопленого екрана.
    func endCapture() {
        guard isCapturing else { return }
        isCapturing = false
        hasVideo = still != nil || (mediaURL != nil && fileHasVideo)
        title = ""
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sinks.values { layer.contents = nil }
        CATransaction.commit()
        syncScreenWindow()
    }

    /// Есть ли вообще что показывать: открытый файл или показанная картинка.
    ///
    /// Отдельно от `isVideoOnScreen`: та отвечает «стоит ли кадр на экране
    /// СЕЙЧАС» и гаснет вместе с залом, а эта — «есть ли кадр, который займёт
    /// экран, как только зал включат». Различие стоило замечания 4: после
    /// «Скрыть» кадр со стены снят, но картинка никуда не делась, и показ
    /// стиха обязан отодвинуть именно её.
    var hasMedia: Bool { mediaURL != nil || still != nil || isCapturing }

    /// Само правило вынесено отдельно, чтобы его можно было проверить
    /// самопроверкой на всех сочетаниях, не открывая настоящий файл.
    static func showsVideoOnScreen(videoToScreen: Bool,
                                   hasVideo: Bool,
                                   hasMedia: Bool,
                                   suppression: ScreenSuppression) -> Bool {
        videoToScreen && hasVideo && hasMedia && suppression.isEmpty
    }

    /// Шаг кнопок «Перемотать назад/вперёд» (PSBVideoSmallShuttleLeft/Right).
    let shuttleStep: Double = 5

    private(set) var filters = MediaFileFilters.builtIn

    // MARK: Внутреннее

    private let player = AVPlayer()
    private var item: AVPlayerItem?
    private var videoOutput: AVPlayerItemVideoOutput?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var frameTimer: Timer?
    private var isScrubbing = false
    /// Встроенный проигрыватель YouTube — вместо `AVPlayer`, пока открыт ролик.
    private var youTube: YouTubeEmbedPlayer?
    /// Звуковой отвод открытого файла — звук фильма для трансляции.
    private var audioTap: PlayerAudioTap?
    /// Куда отдавать звук файла. Зовётся из звукового потока — ставит
    /// `AppState`, замыкание ничего из интерфейса не трогает.
    nonisolated(unsafe) var networkAudioSink: ((Data, Int, Int, Int) -> Void)?
    /// Номер последнего запроса к yt-dlp: пока он думал, могли открыть
    /// другое — поздний ответ не должен подменить открытое.
    private var resolveToken = 0
    private var youTubeJob: YouTubeResolver.Job?
    /// Чем yt-dlp ответил в последний раз, если отказал. Ролик при этом всё
    /// равно идёт — встроенным проигрывателем; строка видна в «Параметрах».
    @Published private(set) var youTubeToolProblem: String?

    /// Слои, в которые уходит кадр: предпросмотр в панели плеера, предпросмотр
    /// слайда и окно на проекторе. Один `AVPlayerLayer` показать сразу в
    /// нескольких местах нельзя — Core Animation оставляет картинку только в
    /// последнем, — поэтому кадры раздаём сами.
    private var sinks: [ObjectIdentifier: CALayer] = [:]
    /// Пока кадр висит на экране, его буфер нельзя вернуть в пул: иначе
    /// декодер запишет в ту же память следующий кадр и картинка порвётся.
    private var retainedBuffers: [CVPixelBuffer] = []


    /// - Parameter autoConfigure: читать ли настройки с диска сразу. Выключают
    ///   это только пробные экземпляры самопроверки: им нужны правила разбора
    ///   ссылок, а не чужие настройки, и лишний поход на диск ни к чему.
    init(autoConfigure: Bool = true) {
        player.actionAtItemEnd = .pause
        player.volume = Float(volume)
        observeRate()
        reloadAudioDevices()
        if autoConfigure { reloadSettingsFromDisk() }
    }

    // MARK: - Настройка

    /// Прочитаны ли уже настройки. Нужен затем, что чтение идёт в фоне: пока
    /// оно шло, оператор мог подвинуть громкость или выключить (16.5), и
    /// поздний ответ не должен затирать сделанное руками.
    private var isConfigured = false

    /// Подхватить настройки оригинала: списки расширений и секцию `[mediaplayer]`.
    func configure(dataRoot: URL?, config: IniSettings?) {
        isConfigured = true
        filters = MediaFileFilters.load(dataRoot: dataRoot)
        apply(MediaPlayerSettings(config: config))
    }

    /// Прочитать настройки с диска самому.
    ///
    /// Раньше `configure(dataRoot:config:)` не звали ниоткуда, и плеер жил на
    /// зашитых значениях: диалог «Открытие медиафайлов» показывал встроенную
    /// копию списков расширений вместо авторской из `settings.json`, а
    /// громкость, повтор, автозапуск и «Отображать видео на экране проектора»
    /// стояли не те, что записаны в `[mediaplayer]` файла настроек оператора.
    /// Ждать вызова снаружи нельзя — плеер должен работать сам по себе.
    ///
    /// Читаем в фоне: разбор `VisioBible.ini` и `settings.json` в главном
    /// потоке при запуске — это подвисание окна, а из-за плеера окно подвисать
    /// не должно.
    ///
    /// - Parameter force: перечитать, даже если настройки уже применены, —
    ///   так мастер импорта вводит перенесённый ini в дело без перезапуска
    ///   (4.2.6).
    func reloadSettingsFromDisk(force: Bool = false) {
        guard force || !isConfigured else { return }
        // Рабочая папка данных: та же, что выбирает `AppState` при запуске.
        let dataRoot = (Defaults.modulesFolder ?? AppState.guessModulesFolder())
            .deletingLastPathComponent()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Той самий файл умовчань програми, що й у всіх інших читачів.
            let url = IniSettings.locateConfig()
            let filters = MediaFileFilters.load(dataRoot: dataRoot,
                                                configFolder: url?.deletingLastPathComponent())
            let config = url.flatMap { try? IniSettings(fileAt: $0) }
            let settings = MediaPlayerSettings(config: config)
            let source = config == nil ? nil : url?.path

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, force || !self.isConfigured else { return }
                    self.isConfigured = true
                    self.settingsPath = source
                    self.filters = filters
                    self.apply(settings)
                }
            }
        }
    }

    /// Звідки взято налаштування `[mediaplayer]` — видно в самоперевірці.
    private(set) var settingsPath: String?
    /// Списки розширень прочитано з `settings.json` у теці даних, а не з
    /// вбудованої копії.
    var filtersAreFromDisk: Bool { filters.sourceURL != nil }

    func apply(_ settings: MediaPlayerSettings) {
        repeats = settings.repeats
        autoPlay = settings.autoPlay
        videoToPreview = settings.videoToPreview
        videoToScreen = settings.videoToScreen
        volume = settings.volume
        isMuted = settings.isMuted

        reloadAudioDevices()
        selectAudioDevice(objectID: settings.audioDevice)
    }

    /// Выбор звукового выхода по номеру устройства — так его хранит и
    /// оригинал (`MediaDefaultAudioDevice`), и вкладка «Медиа» настроек.
    /// Ноль означает «системный выход»: номера у устройств от запуска к
    /// запуску меняются, и жёстко привязываться к ним нельзя.
    func selectAudioDevice(objectID: Int) {
        guard objectID != 0 else { audioDeviceUID = nil; return }
        audioDeviceUID = audioDevices.first { $0.objectID == objectID }?.uid
    }

    /// Номер выбранного устройства для записи обратно в настройки.
    var audioDeviceObjectID: Int {
        get { audioDevices.first { $0.uid == audioDeviceUID }?.objectID ?? 0 }
        set { selectAudioDevice(objectID: newValue) }
    }

    func reloadAudioDevices() {
        audioDevices = MediaAudioDevices.outputs()
        if let uid = audioDeviceUID, !audioDevices.contains(where: { $0.uid == uid }) {
            audioDeviceUID = nil     // устройство отключили — вернуться к системному
        }
    }

    /// Значения, которые оригинал держит в `[mediaplayer]`.
    var currentSettings: MediaPlayerSettings {
        var settings = MediaPlayerSettings()
        settings.repeats = repeats
        settings.autoPlay = autoPlay
        settings.videoToPreview = videoToPreview
        settings.videoToScreen = videoToScreen
        settings.volume = volume
        settings.isMuted = isMuted
        settings.audioDevice = audioDeviceObjectID
        return settings
    }

    // MARK: - Открытие

    /// «Открыть медиа-файл» (16.1) и перетаскивание файла в окно плеера.
    func open(_ url: URL) {
        guard url.isFileURL else { openStream(url); return }
        load(url, stream: false)
    }

    /// «Открыть URL с медиа контентом» (16.2).
    func openStream(_ url: URL) {
        // Ролик YouTube: есть yt-dlp — берём прямой поток и играем как
        // обычный; нет — встроенный проигрыватель. AVFoundation по такой
        // ссылке получает разметку страницы и отвечает общей ошибкой.
        if let id = YouTubeLink.videoID(from: url) {
            if let tool = YouTubeResolver.locate().tool {
                resolveYouTube(url, id: id, with: tool)
            } else {
                openYouTube(id: id, url: url)
            }
            return
        }
        load(url, stream: true)
    }

    /// Схемы, которые действительно проигрывает AVFoundation. Всё остальное
    /// (`rtp`, `rtsp`, `udp`, `mms`, `rtmp`) на macOS без сторонних библиотек
    /// не открыть, а их в проекте быть не должно.
    static let playableSchemes: Set<String> = ["file", "http", "https"]

    /// Разбор строки из окна «Введите URL медиапотока».
    @discardableResult
    func openStream(text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), url.host != nil else {
            failure = .badURL
            return false
        }
        // Проверяем схему до открытия: иначе ссылка уходит в AVFoundation и
        // возвращается общей «Ошибка при открытии медиа-файла», по которой
        // не понять, что дело в самом виде потока.
        guard Self.playableSchemes.contains(scheme) else {
            failure = .unsupportedScheme(scheme)
            return false
        }
        if let host = url.host?.lowercased(), Self.pageOnlyHosts.contains(host) {
            failure = .pageLink(host)
            return false
        }
        // Ссылка на YouTube без ролика — главная, канал, список: показывать
        // нечего, и сказать об этом надо теми же словами, что о странице.
        if YouTubeLink.isYouTube(url), YouTubeLink.videoID(from: url) == nil {
            failure = .pageLink(url.host?.lowercased() ?? "youtube.com")
            return false
        }
        openStream(url)
        return true
    }

    /// Перетаскивание: берём первый файл подходящего расширения.
    @discardableResult
    func openDropped(_ urls: [URL]) -> Bool {
        guard let url = urls.first(where: { filters.accepts($0) }) ?? urls.first else { return false }
        open(url)
        return true
    }

    private func load(_ url: URL, stream: Bool) {
        screenSuppression.remove(.stopped)
        hasAudioTap = false
        // Відкрили файл — захоплення екрана більше не показане: інакше його
        // кадри затирали б фільм так само, як затирали сторінки показу.
        yieldCapture()
        close()
        // Открыли фильм — показанная до него картинка больше не показана.
        // Пока она оставалась, новый приёмник кадра получал именно её:
        // в плеере шёл фильм, а на проекторе стояло прежнее изображение.
        still = nil
        // Открытое любым путём — из окна выбора, перетаскиванием, по ссылке —
        // становится в список: иначе он врал бы о том, что открыто.
        if !stream {
            if let known = playlist.firstIndex(of: url) {
                playlistIndex = known
            } else {
                playlist.append(url)
                playlistIndex = playlist.count - 1
            }
        }

        // «Открываем…» отменяет отложенный сброс «Закрываем…»: при смене
        // файла у нас закрытие мгновенное, и держать полсекунды сообщение о
        // нём значило бы задержать открытие. Поэтому «Закрываем медиафайл…»
        // видно там, где закрытие — самостоятельное действие оператора
        // (команда «Закрыть медиафайл»), а при смене файла сразу пишется
        // «Открываем…».
        setActivity(stream ? .openingStream : .openingFile)
        failure = nil
        mediaURL = url
        isStream = stream
        title = stream ? url.absoluteString : url.lastPathComponent

        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let item = AVPlayerItem(asset: asset)

        // Выход кадров подключаем сразу: пока он не привязан к элементу,
        // достать картинку неоткуда, а включать его позже — значит потерять
        // первые кадры.
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            // Пустой словарь — «дай буфер с IOSurface, свойства по умолчанию»:
            // без него кадр придёт в обычной памяти и его нельзя будет отдать
            // слою напрямую.
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        item.add(output)

        self.item = item
        self.videoOutput = output
        player.replaceCurrentItem(with: item)
        player.isMuted = isMuted
        player.volume = Float(volume)
        player.audioOutputDeviceUniqueID = audioDeviceUID

        observe(item)
        inspect(asset, for: item)
    }

    /// «Закрываем медиафайл…» (TextMessages51) и «Закрываем медиапоток…»
    /// (TextMessages60) — снять всё, что держит текущий файл.
    ///
    /// Сообщение держим на экране заметное время. Раньше `activity` в том же
    /// синхронном вызове возвращалось в `.idle`, и SwiftUI промежуточное
    /// состояние не рисовал никогда: обе записи попадали в один оборот цикла
    /// событий и сливались в одну перерисовку.
    func close() {
        let wasOpen = mediaURL != nil
        let wasStream = isStream

        stopFrameTimer()
        removeObservers()
        youTube?.shutDown()
        youTube = nil
        // Открыли другое или закрыли — склейка прежнего никому не нужна.
        resolveToken &+= 1
        youTubeJob?.cancel()
        youTubeJob = nil

        player.pause()
        item?.audioMix = nil
        player.replaceCurrentItem(with: nil)
        item = nil
        audioTap = nil
        hasAudioTap = false
        videoOutput = nil
        retainedBuffers.removeAll()
        clearSinks()

        mediaURL = nil
        if still == nil { title = "" }
        isStream = false
        isPlaying = false
        fileHasVideo = false
        hasVideo = still != nil
        duration = 0
        position = 0
        audioTracks = []
        selectedAudioTrackID = nil
        syncScreenWindow()

        guard wasOpen else { setActivity(.idle); return }
        setActivity(.closing(stream: wasStream), thenIdleAfter: Self.closingMessageDuration)
    }

    /// Сколько держится сообщение о закрытии. Полсекунды — столько же, сколько
    /// оно висит в оригинале при смене файла: успеть прочитать, но не мешать.
    static let closingMessageDuration: Double = 0.6

    /// Номер последней записи в `activity`. Отложенный сброс сравнивает его со
    /// своим: пока он ждёт, оператор мог открыть другой файл, и вернуть
    /// `.idle` поверх «Открываем медиафайл…» нельзя.
    private var activityToken = 0

    private func setActivity(_ value: Activity, thenIdleAfter delay: Double? = nil) {
        activityToken &+= 1
        activity = value
        guard let delay else { return }
        let token = activityToken
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.activityToken == token else { return }
                self.activity = .idle
            }
        }
    }

    // MARK: - Управление воспроизведением

    /// «Воспроизвести/пауза» (16.3, PSBVideoPlayPause) — она же Ctrl+P.
    func playPause() {
        guard item != nil || youTube != nil else { return }
        isPlaying ? pause() : play()
    }

    func play() {
        guard item != nil || youTube != nil else { return }
        // Дошли до конца и жмут «играть» — начинаем сначала, иначе кнопка
        // выглядит сломанной.
        if duration > 0, position >= duration - 0.25 { seek(to: 0) }
        if let youTube { youTube.play() } else { player.play() }
        // Состояние проигрывателя приходит наблюдателем, то есть следующим
        // оборотом цикла событий. Для кнопки это заметная задержка, поэтому
        // значок переключаем сразу.
        isPlaying = true
        startFrameTimer()
        // Пошёл фильм — значит его показывают. Уступку тексту снимаем здесь,
        // а не ждём кнопки «Показать»: оператор уже нажал «играть».
        screenSuppression.subtract([.slideTookOver, .stopped])
        onWantsHall?()
    }

    func pause() {
        youTube?.pause()
        player.pause()
        isPlaying = false
    }

    /// «Остановить» (PSBVideoStop): пауза и возврат в начало.
    func stop() {
        pause()
        seek(to: 0)
        screenSuppression.insert(.stopped)
    }

    /// «В начало» (PSBVideoToBegin).
    func toBegin() { seek(to: 0) }

    /// «В конец» (PSBVideoToEnd).
    func toEnd() {
        guard duration > 0 else { return }
        seek(to: max(0, duration - 0.1))
    }

    /// «Перемотать назад/вперёд» (PSBVideoSmallShuttleLeft/Right).
    func shuttle(_ direction: Int) {
        seek(to: position + Double(direction) * shuttleStep)
    }

    func seek(to seconds: Double) {
        guard item != nil || youTube != nil else { return }
        let clamped = duration > 0 ? min(max(0, seconds), duration) : max(0, seconds)
        position = clamped
        if let youTube { youTube.seek(to: clamped); return }
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                // На паузе кадры никто не забирает, и после перемотки в окне
                // осталась бы картинка со старого места.
                self?.pullFrame(force: true)
            }
        }
    }

    /// Ползунок позиции: пока его тянут, наблюдатель времени не должен
    /// дёргать бегунок обратно.
    func beginScrub() { isScrubbing = true }

    func scrub(to seconds: Double) {
        position = seconds
    }

    func endScrub() {
        isScrubbing = false
        seek(to: position)
    }

    // MARK: - Звуковые дорожки

    /// «Выбрать звуковую дорожку» (16.6, PSBSelectAudioStreams).
    func selectAudioTrack(_ id: String) {
        selectedAudioTrackID = id
        applyAudioTrack()
    }

    private func applyAudioTrack() {
        guard let item, let id = selectedAudioTrackID else { return }

        // Порядок важен: у контейнеров с настоящими «дорожками» (mov, mp4)
        // работает выбор через группу, а у остальных остаётся только включать
        // и выключать сами дорожки элемента.
        if let group = audibleGroup,
           let option = group.options.first(where: { Self.identifier(of: $0) == id }) {
            item.select(option, in: group)
            return
        }
        for track in item.tracks where track.assetTrack?.mediaType == .audio {
            guard let assetTrack = track.assetTrack else { continue }
            track.isEnabled = String(assetTrack.trackID) == id
        }
    }

    private var audibleGroup: AVMediaSelectionGroup?

    private static func identifier(of option: AVMediaSelectionOption) -> String {
        // У варианта нет собственного номера, зато есть устойчивая пара
        // «язык + название», по которой его и выбирают в списке.
        let language = option.extendedLanguageTag ?? option.locale?.identifier ?? "—"
        return "\(language)#\(option.displayName)"
    }

    // MARK: - Разбор файла

    /// Что нужно знать о файле до показа: дорожки, группа языков, длина.
    struct AssetFacts {
        var video: [AVAssetTrack] = []
        var audio: [AVAssetTrack] = []
        var group: AVMediaSelectionGroup?
        var duration: CMTime = .indefinite
    }

    /// Две дороги к одному и тому же. На macOS 12 и новее — асинхронные
    /// загрузчики `loadTracks`/`load(.duration)`; в Big Sur их нет, там
    /// `loadValuesAsynchronously` и прежние свойства ресурса. Обе ветки
    /// возвращают одно и то же, и самопроверка гоняет старую ветку на новой
    /// системе через `Compat.pretendsBigSur`.
    static func assetFacts(of asset: AVURLAsset,
                           pretendingBigSur: Bool = Compat.pretendsBigSur) async -> AssetFacts {
        if #available(macOS 12, *), !pretendingBigSur {
            var facts = AssetFacts()
            facts.video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            facts.audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            facts.group = try? await asset.loadMediaSelectionGroup(for: .audible)
            facts.duration = (try? await asset.load(.duration)) ?? .indefinite
            return facts
        }
        return await withCheckedContinuation { continuation in
            let keys = ["tracks", "duration", "availableMediaCharacteristicsWithMediaSelectionOptions"]
            asset.loadValuesAsynchronously(forKeys: keys) {
                var facts = AssetFacts()
                // Свойство, которое не загрузилось, отдаёт пустоту, а не
                // роняет: файл без звука или поток без дорожек — обычное дело.
                if asset.statusOfValue(forKey: "tracks", error: nil) == .loaded {
                    facts.video = asset.tracks(withMediaType: .video)
                    facts.audio = asset.tracks(withMediaType: .audio)
                }
                if asset.statusOfValue(forKey: "availableMediaCharacteristicsWithMediaSelectionOptions",
                                       error: nil) == .loaded {
                    facts.group = asset.mediaSelectionGroup(forMediaCharacteristic: .audible)
                }
                if asset.statusOfValue(forKey: "duration", error: nil) == .loaded {
                    facts.duration = asset.duration
                }
                continuation.resume(returning: facts)
            }
        }
    }

    private func inspect(_ asset: AVURLAsset, for item: AVPlayerItem) {
        Task { [weak self] in
            guard let self else { return }

            let facts = await Self.assetFacts(of: asset)
            let videoTracks = facts.video
            let audio = facts.audio
            let group = facts.group
            // Отвод звука — у файлов с дорожками; поток без дорожек обходится
            // без него (см. `PlayerAudioTap`).
            if let track = audio.first, let tap = PlayerAudioTap(track: track) {
                // Между отводом и сетью — громкость плеера: ползунок и «Без
                // звука» обязаны действовать и на трансляцию.
                let model = self
                tap.onSamples = { planar, channels, samples, rate in
                    guard let sink = model.networkAudioSink else { return }
                    let gain = model.networkGain
                    if abs(gain - 1) < 0.001 { sink(planar, channels, samples, rate); return }
                    var scaled = planar
                    scaled.withUnsafeMutableBytes { raw in
                        let floats = raw.bindMemory(to: Float.self)
                        for index in 0..<floats.count { floats[index] *= gain }
                    }
                    sink(scaled, channels, samples, rate)
                }
                item.audioMix = tap.mix
                self.audioTap = tap
                self.hasAudioTap = true
            }
            let length = facts.duration

            guard self.item === item else { return }     // за это время открыли другое

            // У потока (HLS, .m3u8) дорожек у самого ресурса нет вовсе, и
            // пустой список тут не значит «видео нет». Для потока решает
            // размер картинки у элемента — см. `observe`. Пока эта строка
            // ставила `false` всем подряд, поток открывался, звук шёл, а на
            // проектор не выводилось ничего: правило вывода требует `hasVideo`.
            if !videoTracks.isEmpty {
                self.hasVideo = true
                self.fileHasVideo = true
            } else if !self.isStream {
                // Картинка, показанная поверх звукового файла, остаётся
                // «есть что показывать»: файл без видео её не отменяет.
                self.fileHasVideo = false
                self.hasVideo = self.still != nil
            }
            self.audibleGroup = group

            if let group, !group.options.isEmpty {
                self.audioTracks = group.options.map {
                    AudioTrack(id: Self.identifier(of: $0), title: $0.displayName)
                }
                let current = item.currentMediaSelection.selectedMediaOption(in: group)
                self.selectedAudioTrackID = current.map(Self.identifier(of:)) ?? self.audioTracks.first?.id
            } else {
                self.audioTracks = audio.enumerated().map { index, track in
                    AudioTrack(id: String(track.trackID), title: "\(index + 1)")
                }
                self.selectedAudioTrackID = self.audioTracks.first?.id
            }

            if length.isNumeric { self.duration = length.seconds }
            self.setActivity(.idle)
            self.syncScreenWindow()

            // «Воспроизвести после открытия» — как в оригинале: если кнопка
            // (16.4) выключена, ждём нажатия «Воспроизвести».
            if self.autoPlay {
                self.play()
            } else {
                self.showFirstFrame()
            }
        }
    }

    // MARK: - Наблюдение за проигрывателем

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.item === item else { return }
                    switch item.status {
                    case .failed:
                        self.failure = .cannotOpen
                        self.setActivity(.idle)
                    case .readyToPlay:
                        if item.duration.isNumeric { self.duration = item.duration.seconds }
                        self.failure = nil
                    default:
                        break
                    }
                }
            }
        }

        // Картинка потока объявляется здесь: у элемента появляется размер,
        // когда он готов показывать. Для файла это тоже верно, но там уже
        // сработали дорожки ресурса, и второй раз ничего не меняется.
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.item === item,
                          item.presentationSize != .zero, !self.fileHasVideo else { return }
                    self.hasVideo = true
                    self.fileHasVideo = true
                    self.syncScreenWindow()
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnd() }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(value: 1, timescale: 10), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, !self.isScrubbing else { return }
                self.position = time.seconds.isFinite ? time.seconds : 0
                if self.duration == 0, let current = self.item, current.duration.isNumeric {
                    self.duration = current.duration.seconds
                }
            }
        }
    }

    private func observeRate() {
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isPlaying = player.timeControlStatus != .paused
                    self.isPlaying ? self.startFrameTimer() : self.stopFrameTimer()
                }
            }
        }
    }

    private func handleEnd() {
        guard repeats else {
            isPlaying = false
            return
        }
        // «Повтор» (PSBVideoRepeate): без остановки, чтобы фоновая заставка
        // крутилась всё собрание.
        seek(to: 0)
        if let youTube { youTube.play() } else { player.play() }
    }

    private func removeObservers() {
        statusObservation?.invalidate()
        statusObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        audibleGroup = nil
    }

    // MARK: - Раздача кадров

    /// Неподвижная картинка вместо кадра видео.
    ///
    /// Ею живут показ изображений и страницы презентации. Отдельного окна на
    /// проекторе, отдельного слоя в предпросмотре и отдельной дороги в
    /// трансляцию для них не заводим: картинка идёт теми же выводами, что и
    /// фильм, — там всё это уже есть и уже проверено.
    private(set) var still: CGImage? {
        didSet {
            // Показане завжди йде за самою картинкою. Коли її знімають —
            // відкрили фільм, закрили файл, — знімаємо і вирізаний шматок:
            // інакше шар нового приймача діставав колишню картинку замість
            // кадру фільму.
            if still == nil { shownStill = nil }
        }
    }

    /// Те, що реально лягає в шари і йде в мережу: картинка, вирізана точкою
    /// фокуса. Сама `still` лишається цілою — наближення це лупа над нею, а
    /// не правка вмісту, і зняти його треба одним рухом.
    private(set) var shownStill: CGImage?

    /// Як вирізати шматок під наближення. Ставить `AppState` — модель плеєра
    /// про точку фокуса нічого не знає і знати не має.
    var focusCrop: ((CGImage) -> CGImage)?

    /// Есть ли у открытого файла видеодорожка. `hasVideo` этого не скажет:
    /// его поднимает и показанная картинка. А решать, закрывать ли файл при
    /// показе картинки и что класть в слой, надо по самому файлу: звуковой
    /// файл экрана не занимает, и картинка ему не мешает.
    private(set) var fileHasVideo = false

    /// Показать картинку на всех выводах плеера.
    ///
    /// `nil` — убрать показанное. Фильм при этом закрывается: экран в зале
    /// один, и держать на нём два источника разом нельзя. Звуковой файл —
    /// нет: он экрана не занимает, а фонограмма под картинки и страницы
    /// презентации — обычное дело на служении. Прежде картинка глушила и
    /// музыку: владелец — «звук останавливается, если переключиться на
    /// слайды».
    func showStill(_ image: CGImage?, title: String = "") {
        if image != nil { yieldCapture() }
        if image != nil, mediaURL != nil, fileHasVideo { close() }
        // Показали картинку — значит она и в зале: уступку тексту снимаем.
        if image != nil { screenSuppression.subtract([.slideTookOver, .stopped]) }
        still = image
        // Подпись картинки — пока играет звуковой файл, его имя важнее: оно
        // и стоит в панели плеера.
        if mediaURL == nil { self.title = image == nil ? "" : title }
        hasVideo = image != nil || (mediaURL != nil && fileHasVideo)
        deliverStill()
    }

    /// Перемалювати показане, коли змінилося наближення. Саму картинку не
    /// чіпаємо: міняється лише те, який її шматок іде в зал.
    func refreshStill() {
        guard still != nil else { return }
        deliverStill(animated: false)
    }

    /// Роздати картинку виводам — уже вирізану точкою фокуса.
    ///
    /// `animated` — чи грати перехід. Наближення точкою фокуса перемальовує
    /// ту саму сторінку десятки разів поспіль, і перехід там був би не
    /// красою, а кашею: лупа має їхати за рукою, а не розчинятися.
    private func deliverStill(animated: Bool = true) {
        let previous = shownStill
        let shown = still.map { focusCrop?($0) ?? $0 }
        shownStill = shown
        let effect = stillTransition
        // Перехід має сенс, коли є з чого і є в що: поява з порожнечі й
        // зникнення в порожнечу — це справа затемнення виводу, а не наша.
        if animated, let previous, let shown, effect.kind != .none, effect.seconds > 0.01 {
            for layer in sinks.values {
                SlideTransitionAnimator.play(on: layer, from: previous, to: shown,
                                             kind: effect.kind, duration: effect.seconds,
                                             easing: effect.easing)
            }
            onNetworkStillTransition?(previous, shown, effect.kind, effect.seconds)
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in sinks.values { SlideTransitionAnimator.settle(layer, contents: shown) }
            CATransaction.commit()
            if shown == nil, !sinks.isEmpty { NativeTrace.say("зал: плеєр віддав виводам порожню картинку") }
            onNetworkStill?(shown)
        }
        syncScreenWindow()
    }

    /// Картинка для сетевой трансляции — та же, что на экране.
    var onNetworkStill: ((CGImage?) -> Void)?

    /// Перехід між двома картинками для трансляції: канал малює його сам,
    /// по кадру на такт, — як робить для слайда.
    var onNetworkStillTransition: ((CGImage, CGImage, SlideStyle.Transition, Double) -> Void)?

    /// Як міняються сторінки показу і зображення.
    ///
    /// Власник: «Пункт презентация — добавить эффекты затуханий, наплывов и
    /// другие 20 с настройками». Тут — вибране в налаштуваннях; саме
    /// малювання роблять ті самі двадцять переходів, що й у слайда.
    var stillTransition: (kind: SlideStyle.Transition, seconds: Double, easing: SlideStyle.Easing)
        = (.none, 0.35, .easeInOut)

    /// Список открытых файлов.
    ///
    /// На служении их несколько: заставка, ролик к проповеди, гимн. Прежде
    /// плеер держал ровно один файл, и каждый следующий стирал предыдущий —
    /// значит перед каждым включением надо было снова идти в окно выбора.
    /// Список копится, а «Очистить» убирает всё разом.
    @Published private(set) var playlist: [URL] = [] { didSet { rememberPlaylist() } }
    /// Какой из списка открыт сейчас.
    @Published private(set) var playlistIndex: Int?

    /// Чи запам'ятовує цей плеєр свій список між запусками.
    ///
    /// Вмикає тільки той плеєр, з яким працює людина. Самоперевірка заводить
    /// свої плеєри й відкриває в них пробні файли; якби вони теж писали в
    /// пам'ять, кожен прогін підмінював би список, зібраний до служіння.
    var remembersPlaylist = false

    private static let playlistKey = "mediaPlaylist"

    private func rememberPlaylist() {
        guard remembersPlaylist, !SessionMemory.isSuspended else { return }
        UserDefaults.standard.set(playlist.map(\.path), forKey: Self.playlistKey)
    }

    /// Повернути список, зібраний минулого разу.
    ///
    /// Власник: «после закрытия программы все добавленные презентации,
    /// минусовки, картинки и т.д. не сохраняются». Файли, яких уже немає,
    /// просто пропускаємо — скарга про зниклу флешку на запуску докучлива.
    /// Нічого не відкриваємо: список стоїть, а що вмикати — вирішує людина.
    func restorePlaylist() {
        guard remembersPlaylist, playlist.isEmpty else { return }
        let saved = UserDefaults.standard.stringArray(forKey: Self.playlistKey) ?? []
        let alive = saved.map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !alive.isEmpty else { return }
        playlist = alive
    }

    /// Поставити список як був — нічого не відкриваючи.
    ///
    /// Для самоперевірки, що позичала плеєр. Раніше вона повертала список
    /// через `addToPlaylist`, а той відкриває перший доданий файл, якщо
    /// нічого не відкрито, — ще й з автозапуском, який перевірка вмикала.
    /// 2026-09-10 так посеред прогону заграв ролик власника, і наступна
    /// перевірка впиралася в його кадр замість вірша.
    func putBackPlaylist(_ urls: [URL]) {
        playlist = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        playlistIndex = nil
    }

    /// Добавить файлы в список. Открывается первый добавленный — если до
    /// этого не играло ничего.
    func addToPlaylist(_ urls: [URL]) {
        // Порядок — по именам, как в списке файлов: в окне выбора человек
        // щёлкает вразнобой, а показывать собирается по порядку.
        let wanted = urls.filter { (filters.accepts($0) || $0.isFileURL) && !Self.belongsToShow($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var added: [URL] = []
        for url in wanted where !playlist.contains(url) {
            playlist.append(url)
            added.append(url)
        }
        guard let first = added.first else { return }
        if mediaURL == nil { openFromPlaylist(at: playlist.firstIndex(of: first) ?? 0) }
    }

    /// Картинки и презентации в список плеера не берём.
    ///
    /// У них свои режимы — «Изображения» и «Презентации», — и там их
    /// показывают страницами. Попав сюда, картинка открывалась как фильм:
    /// дорожки видео у неё нет, на проекторе пусто, и со стороны это ровно
    /// то, о чём говорил владелец, — «видео не отображается на проекторе».
    /// Расширения те же, что у `ShowModel`.
    static func belongsToShow(_ url: URL) -> Bool {
        let known = ["jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp",
                     "pptx", "ppsx", "potx", "pptm", "ppsm", "pdf"]
        return known.contains(url.pathExtension.lowercased())
    }

    /// Открыть файл из списка.
    func openFromPlaylist(at position: Int) {
        guard playlist.indices.contains(position) else { return }
        playlistIndex = position
        open(playlist[position])
    }

    func removeFromPlaylist(at position: Int) {
        guard playlist.indices.contains(position) else { return }
        let removed = playlist.remove(at: position)
        if removed == mediaURL { close(); playlistIndex = nil }
        else if let current = playlistIndex, current > position { playlistIndex = current - 1 }
    }

    func clearPlaylist() {
        playlist.removeAll()
        playlistIndex = nil
        close()
    }

    /// «Показать это в зале»: файл открыт или пошёл. Решение о зале
    /// принимает состояние — плеер о выводах не знает и знать не должен.
    var onWantsHall: (() -> Void)?

    /// Кадр видео для сетевой трансляции.
    ///
    /// Ставит `AppState`, когда у NDI включено «Отображать Видео»
    /// (`NdiSendVideo`). Кадр отдаётся в том же виде, в каком его забрали у
    /// плеера, — BGRA, без единого лишнего преобразования: перекладывать его
    /// в картинку и обратно значит платить миллисекунды шестьдесят раз в
    /// секунду.
    var onNetworkFrame: ((CVPixelBuffer) -> Void)?

    /// Нужны ли кадры сети. Без этого признака кадры тянулись бы только пока
    /// открыт предпросмотр или окно проектора: оператор вправе гнать видео на
    /// микшер и не показывать его в зале.
    var sendsToNetwork = false {
        didSet {
            guard oldValue != sendsToNetwork else { return }
            if sendsToNetwork {
                isPlaying ? startFrameTimer() : pullFrame(force: true)
            } else if sinks.isEmpty {
                stopFrameTimer()
            }
        }
    }

    /// Слой-приёмник кадра. Регистрируют предпросмотр плеера, предпросмотр
    /// слайда и окно на проекторе.
    func attach(_ layer: CALayer) {
        layer.contentsGravity = .resizeAspect
        layer.backgroundColor = NSColor.black.cgColor
        sinks[ObjectIdentifier(layer)] = layer

        // Что лежало в слое до этого — не наше дело показывать.
        //
        // Слой проектора отвязывается, когда в зал уходит текст, и всё это
        // время держит последний показанный кадр. Владелец описал последствие
        // так: «то отображается последнее изображение вместо видео». Так и
        // было: картинку показали, потом стих (слой отвязан, картинка в нём
        // осталась), потом открыли фильм — и слой вернулся в зал с прежней
        // картинкой, пока не подоспел первый кадр фильма. Чистим его в тот
        // же миг, когда подключаем: источник сменился.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = (mediaURL == nil || !fileHasVideo) ? shownStill : nil
        CATransaction.commit()

        // Картинка кладётся сразу, но только если фильма нет: открытый файл
        // старше — он и есть то, что показывают. Звуковой файл кадров не
        // даёт, и картинка при нём остаётся.
        if still != nil, mediaURL == nil || !fileHasVideo { return }

        // Кадр берём сразу и насильно, а не ждём часового: между подключением
        // и первым готовым кадром слой стоял бы пустым, и в зале это чёрный
        // прямоугольник вместо фильма.
        pullFrame(force: true)
        if isPlaying { startFrameTimer() }
    }

    func detach(_ layer: CALayer) {
        sinks.removeValue(forKey: ObjectIdentifier(layer))
        // Кадр в слое не стираем: он уходит из зала плавно, и стирать его
        // сейчас значит оборвать затухание рывком. Чистит тот, кто подключит
        // слой заново.
        if sinks.isEmpty, !sendsToNetwork { stopFrameTimer() }
    }

    private func startFrameTimer() {
        // У YouTube кадры — снимки вида, и просят их только когда есть кому
        // отдать: слоям предпросмотра и зала или трансляции.
        if let youTube {
            if !sinks.isEmpty || sendsToNetwork { youTube.startSnapshots() }
            return
        }
        guard frameTimer == nil, videoOutput != nil else { return }
        // 60 Гц — та же частота обновления анимации, что стоит в настройках
        // оригинала; чаще проектору не нужно.
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pullFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        frameTimer = timer
    }

    private func stopFrameTimer() {
        youTube?.stopSnapshots()
        frameTimer?.invalidate()
        frameTimer = nil
    }

    /// - Parameter force: забрать кадр, даже если новый ещё не готов, —
    ///   нужно после перемотки на паузе и при показе первого кадра.
    private func pullFrame(force: Bool = false) {
        // У YouTube ни выхода буферов, ни времени элемента — один снимок вида.
        if let youTube { youTube.snapshot(); return }
        guard let videoOutput, !sinks.isEmpty || sendsToNetwork else { return }

        let time = force ? player.currentTime()
                         : videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        guard force || videoOutput.hasNewPixelBuffer(forItemTime: time),
              let buffer = videoOutput.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil)
        else { return }
        deliver(buffer)
    }

    /// Кадр — во все слои и в сеть. Одна дорога и для фильма, и для снимка
    /// YouTube: они не должны расходиться ни в чём.
    private func deliver(_ buffer: CVPixelBuffer) { deliverFrame(buffer) }

    /// Кадр — во все слои и в сеть. Не `private`: тією самою дорогою йде і
    /// захоплений екран.
    private func deliverFrame(_ buffer: CVPixelBuffer) {
        guard let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() else { return }
        retainedBuffers.append(buffer)
        if retainedBuffers.count > 3 { retainedBuffers.removeFirst() }

        // Сеть получает тот же кадр, что и экран, — до раскладки по слоям:
        // отдать его надо раньше, чем Core Animation займётся показом.
        if sendsToNetwork { onNetworkFrame?(buffer) }

        // Без явного отключения действий Core Animation растворяет каждый
        // новый кадр в предыдущем — видео превращается в кашу.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sinks.values { layer.contents = surface }
        CATransaction.commit()
    }

    /// Первый кадр, когда автозапуск выключен: чёрный прямоугольник не
    /// показывает, открылся файл или нет.
    private func showFirstFrame() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            MainActor.assumeIsolated { self?.pullFrame(force: true) }
        }
    }

    private func clearSinks() {
        if !sinks.isEmpty { NativeTrace.say("зал: плеєр очистив виводи") }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sinks.values { SlideTransitionAnimator.settle(layer, contents: nil) }
        CATransaction.commit()
    }

    // MARK: - YouTube

    /// Открыт ли ролик YouTube (а не файл или поток).
    var isYouTube: Bool { youTube != nil }

    /// Вид встроенного проигрывателя — его окно слайда ставит в зал: кадр
    /// YouTube буфером не достать, а снимки для зала слишком редки.
    var hostedView: NSView? { youTube?.webView }

    /// Через yt-dlp: спросить прямой поток и открыть его обычным плеером.
    private func resolveYouTube(_ url: URL, id: String, with tool: YouTubeResolver.Tool) {
        close()
        setActivity(.openingStream)
        failure = nil
        mediaURL = url
        isStream = true
        title = "YouTube · \(id)"
        resolveToken &+= 1
        let token = resolveToken
        youTubeJob?.cancel()
        let job = YouTubeResolver.obtain(url, with: tool) { [weak self] result in
            MainActor.assumeIsolated {
                guard let self, token == self.resolveToken else { return }
                switch result {
                case .success(let found):
                    self.youTubeToolProblem = nil
                    // Работа живёт дальше: ffmpeg склеивает поток всё время
                    // показа. `load` закрывает прежнее, но эту работу — нет.
                    let keep = self.youTubeJob
                    self.youTubeJob = nil
                    self.load(found.url, stream: true)
                    self.youTubeJob = keep
                    self.title = "YouTube · " + (found.title.isEmpty ? id : found.title)
                    // Длительность плеер у растущего плейлиста узнаёт лишь в
                    // конце, а ползунку она нужна сразу.
                    if found.isRemuxed, found.duration > 0 { self.duration = found.duration }
                case .failure(let problem):
                    // Не вышло — ролик всё равно идёт, встроенным проигрывателем.
                    self.youTubeJob = nil
                    self.youTubeToolProblem = problem.description
                    self.openYouTube(id: id, url: url)
                }
            }
        }
        youTubeJob = job
    }

    /// Склеивается ли сейчас поток YouTube на лету — самопроверке.
    var isRemuxingYouTube: Bool { youTubeJob?.isRemuxing ?? false }

    private func openYouTube(id: String, url: URL) {
        close()
        still = nil
        setActivity(.openingStream)
        failure = nil
        mediaURL = url
        isStream = true
        title = "YouTube · \(id)"

        let engine = YouTubeEmbedPlayer(videoID: id, autoplay: autoPlay)
        youTube = engine
        engine.onReady = { [weak self] in
            guard let self, self.youTube === engine else { return }
            engine.setVolume(self.volume)
            engine.setMuted(self.isMuted)
            // У ролика YouTube картинка есть всегда — это не звуковой поток.
            self.hasVideo = true
            self.setActivity(.idle)
            self.syncScreenWindow()
            // «Воспроизвести после открытия» — как для файла. Сам YouTube с
            // `autoplay` тоже стартует, но у нас пуск снимает уступку тексту
            // и просит зал — этого его страница сделать не может.
            if self.autoPlay { self.play() } else { engine.snapshot() }
        }
        engine.onState = { [weak self] state in
            guard let self, self.youTube === engine else { return }
            switch state {
            case .playing:
                self.isPlaying = true
                self.startFrameTimer()
            case .paused, .cued, .unstarted:
                self.isPlaying = false
            case .ended:
                self.handleEnd()
            case .buffering:
                break
            }
        }
        engine.onError = { [weak self] code in
            guard let self, self.youTube === engine else { return }
            self.failure = .youTube(code)
            self.setActivity(.idle)
        }
        engine.onTime = { [weak self] current, total in
            guard let self, self.youTube === engine, !self.isScrubbing else { return }
            self.position = current
            if total > 0 { self.duration = total }
        }
        engine.onFrame = { [weak self] buffer in self?.deliver(buffer) }
        syncScreenWindow()
        fetchYouTubeTitle(id: id)
    }

    /// Название ролика — по открытому oEmbed YouTube, без ключей и входа.
    /// Не пришло — остаётся номер; это подпись, а не условие показа.
    private func fetchYouTubeTitle(id: String) {
        guard let watch = YouTubeLink.watchURL(id: id),
              var parts = URLComponents(string: "https://www.youtube.com/oembed") else { return }
        parts.queryItems = [URLQueryItem(name: "url", value: watch.absoluteString),
                            URLQueryItem(name: "format", value: "json")]
        guard let url = parts.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["title"] as? String, !name.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.youTube?.videoID == id else { return }
                    self.title = "YouTube · " + name
                }
            }
        }.resume()
    }

    // MARK: - Видео на проекторе

    /// Кадр в зале показывать или убрать. Ставит `AppState`: плеер про окно
    /// слайда знать не должен, а окно — про плеер.
    var onScreenChanged: (() -> Void)?

    private func syncScreenWindow() {
        // Затемнение, «Скрыть слайд» и «пустой слайд» гасят кадр так же, как
        // и слайд: в зале должен остаться чёрный экран, а не картинка.
        //
        // Своего окна у плеера больше нет. Слайд и видео приходят в зал одним
        // экраном — так это и просил владелец, и так меньше мест, где они
        // могут разойтись: прежнее окно поверх слайда спорило за порядок с
        // окном управления и на одном мониторе накрывало собой всё.
        onScreenChanged?()
    }

    // MARK: - Вспомогательное

    /// Время в подписи плеера: «1:23» и «1:02:03».
    static func timeText(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let s = total % 60, m = (total / 60) % 60, h = total / 3600
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

