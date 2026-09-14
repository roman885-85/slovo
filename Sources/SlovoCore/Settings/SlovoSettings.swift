import Foundation

/// Усе, що налаштовується у вікні «Параметри» (розділ 6.1 посібника).
///
/// Поля названо за ключами ini, щоб при звірці з оригіналом не
/// доводилося тримати в голові ще один словник імен. Значення за умовчанням
/// — ті самі, що підставляє VisioBible при першому запуску.
public struct ProgramOptions: Codable, Sendable, Hashable {

    // MARK: Основні (6.1.1)

    /// (1) «Реакція на кнопки» — по натисканню або по відпусканню.
    public enum ButtonAction: Int, Codable, CaseIterable, Sendable, Identifiable {
        case onPress = 0, onRelease = 1
        public var id: Int { rawValue }
    }

    /// (2) «При показі слайда на передній план»: головне вікно (два монітори)
    /// або вікно слайда (один монітор).
    public enum Foreground: Int, Codable, CaseIterable, Sendable, Identifiable {
        case mainWindow = 0, slideWindow = 1
        public var id: Int { rawValue }
    }

    /// «Режим мінікартинок»: системний провідник або вбудований переглядач.
    public enum ThumbsMode: Int, Codable, CaseIterable, Sendable, Identifiable {
        case system = 0, builtIn = 1
        public var id: Int { rawValue }
    }

    public var buttonAction: ButtonAction = .onPress
    public var foreground: Foreground = .mainWindow
    public var percentFillingPage: Int = 30
    public var animationFrequency: Int = 30
    /// Номер монітора в нумерації оригіналу: 1 — основний, 0 — ручне налаштування.
    public var monitorIndex: Int = 1
    public var defaultWidth: Int = 1024
    public var defaultHeight: Int = 768
    public var customLeft: Int = 0
    public var customTop: Int = 0
    public var customWidth: Int = 800
    public var customHeight: Int = 600
    public var loadAllBooks: Bool = true
    public var lazyLoadModules: Bool = true
    public var thumbsMode: ThumbsMode = .system

    // MARK: Додаткові (6.1.2)

    /// (10) і (11) — у мілісекундах, як в оригіналі.
    public var crossfadeTime: Int = 0
    /// Перехід слайда (ім'я з SlideStyle.Transition) і його крива — вибір
    /// із двадцяти шаблонів на вкладці «Додаткові».
    public var slideTransition: String?
    public var slideTransitionEasing: String?
    /// Перехід між сторінками показу і зображеннями — окремий від слайда.
    ///
    /// Власник: «Пункт презентация — добавить эффекты затуханий, наплывов и
    /// другие 20 с настройками». Окремий саме тому, що це різні служби:
    /// вірш змінюють щохвилини і швидкий перехід там доречний, а сторінки
    /// показу гортають рідко, і повільне розчинення виглядає краще. Тримати
    /// їх на одному числі означало б, що людина не може мати обидва.
    /// Кілька віршів на слайді — кожен з нового рядка і зі своїм номером.
    ///
    /// Власник: «было бы лучше при выводе нескольких стихов каждый с новой
    /// строки, и номер рядом с ним писать». Доти вірші зліплювалися в один
    /// абзац через пробіл, і на слайді не було видно, де кінчається один і
    /// починається другий.
    public var versesOnOwnLines: Bool?
    public var showTransition: String?
    public var showTransitionEasing: String?
    /// У мілісекундах, як і `crossfadeTime`.
    public var showTransitionTime: Int?
    public var hideSlideTime: Int = 0
    /// (12) «Дублювання слайда на монітори» — список описів моніторів із
    /// ключа `DoubleMonitors`.
    public var doubleMonitors: [String] = []
    /// (13) «Маркер останньої частини пісні».
    public var songsEndMarker: String = ""
    /// (14) «Шукати по BackSpace у "Швидк. виборі"».
    public var fastInputUseBackSpace: Bool = true
    /// (15) «Розділ. лінією по 10 віршів».
    public var separatorTenVerses: Bool = true
    /// (16) «Колір активного поля вводу».
    public var activeInputFieldColor: SlideStyle.RGBA = SlideStyle.RGBA(1, 1, 0.94)
    /// (17) «Показувати номери віршів» — окремо для двох перекладів.
    public var showVerseNumbers: Bool = false
    public var showSecondaryVerseNumbers: Bool = false
    public var useRCPointer: Bool = false

    // MARK: Слайд (6.1.3)

    /// (18) і (19): «Довгий» — повна назва книги, «Короткий» — скорочення.
    /// Порядок значень той самий, що в автора: TextMessages39 «Длинный»,
    /// TextMessages40 «Короткий».
    public enum AddressStyle: Int, Codable, CaseIterable, Sendable, Identifiable {
        case long = 0, short = 1
        public var id: Int { rawValue }
    }

    public var refAllMain: AddressStyle = .long
    public var refAllSec: AddressStyle = .short
    public var refMain: AddressStyle = .long
    public var refSec: AddressStyle = .long
    public var refsSeparated: Bool = false
    /// (20) «Режим відображення номера пісні в назві пісні».
    public var songNumberPP: Bool = false
    public var songNumberInCollection: Bool = true
    public var songNumberInBrackets: Bool = false
    public var songDotAfterNumber: Bool = true

    // MARK: Медіа (6.1.7)

    /// Ідентифікатор звукового пристрою; 0 — «за умовчанням», як в оригіналі.
    public var audioDeviceID: Int = 0
    public var showVideoOnPreview: Bool = true
    public var ndiEnabled: Bool = false
    public var ndiSendVideo: Bool = false
    /// Звук програми в трансляцію. Необов'язкове поле навмисно: старий
    /// `settings.json` без нього має читатися, а не скидати все до
    /// заводських. Порожньо — значить «так».
    public var ndiSendAudio: Bool?
    /// Висота кадру NDI: 0 або порожньо — як у слайда, 720, 540.
    public var ndiFrameHeight: Int?
    /// Транспорт NDI: nil/«auto» — як вирішує сам NDI (RUDP), «tcp» — лише
    /// TCP. По Wi-Fi RUDP на втратах пакетів накопичує чергу — власник бачив
    /// це як зависання і пропажу звуку; TCP там тримається рівніше.
    public var ndiTransport: String?
    /// «Відео по Wi-Fi»: потік H.264/AAC (HLS) із кадром залу на нашому
    /// HTTP-сервері, `/wifi/`. Висота кадру і потік у кбіт/с.
    public var webVideoEnabled: Bool?
    public var webVideoHeight: Int?
    public var webVideoKbps: Int?
    /// Друге джерело NDI «Слово Wi-Fi»: зменшений кадр і своя частота.
    public var ndiWiFiEnabled: Bool?
    public var ndiWiFiHeight: Int?
    public var ndiWiFiFrameRate: Int?
    /// Рівень звуку NDI в дБ: 20 — еталон SDK (за умовчанням), 0 — як є.
    public var ndiAudioGainDb: Int?
    public var ndiTransparentBackground: Bool = false
    /// Індекс у списку частот `OutputConfiguration.ndiFrameRates`, а не сама
    /// частота: у `NdiFpsId` оригінал зберігає саме індекс.
    public var ndiFrameRateIndex: Int = 13

    // MARK: Remote API (6.1.8)

    public var webEnabled: Bool = false
    public var webPort: Int = 82
    public var webNetInterface: String = ""
    public var webSocketEnabled: Bool = false
    public var webSocketPort: Int = 8100
    public var tcpEnabled: Bool = false
    public var tcpPort: Int = 8101
    public var udpEnabled: Bool = false
    public var udpPort: Int = 8100

    // MARK: Пульт на телефоні (свій канал, в автора його немає)

    /// Необов'язкові: старий `settings.json` без цих ключів зобов'язаний
    /// читатися, інакше налаштування мовчки скинуться до ini.
    public var remoteEnabled: Bool?
    public var remotePort: Int?
    public var remotePin: String?

    // MARK: Пульт у браузері (свій порт, свій пароль)

    /// Власник: «взять нестандартный порт, т.к. на другой машине он может
    /// быть занят» і «включение и отключение, вход с паролем или без, выбор
    /// порта и другие нужные настройки». Необов'язкові — з тієї ж причини,
    /// що й пульт телефона.
    public var remoteWebEnabled: Bool?
    public var remoteWebPort: Int?
    public var remoteWebPassword: String?
    /// Ім'я в мережі без «.local»: slovo → slovo.local.
    public var remoteWebName: String?
    /// Лише перегляд: сторінка показує зал, але не керує.
    public var remoteWebViewOnly: Bool?
    /// Відкривати й без номера порту (порт 80, якщо вільний).
    public var remoteWebNoPort: Bool?

    // MARK: Указка (своя; в автора її немає)

    /// Колір «#RRGGBB», діаметр — частка висоти кадру, яскравість — непрозорість,
    /// і куди виводити. Необов'язкові з тієї ж причини, що й пульт.
    public var pointerColour: String?
    public var pointerSize: Double?
    public var pointerOpacity: Double?
    public var pointerProjector: Bool?
    public var pointerNDI: Bool?

    // MARK: Оновлення

    /// «Інтервал перевірки оновлень» у днях: 0 — ніколи, 7, 30, 365.
    public var updateInterval: Int = 7

    public init() {}

    /// Розбір ini. Усе, чого у файлі немає, лишається зі значенням
    /// за умовчанням — наполовину прочитаний конфіг гірший за порожній.
    public init(config: IniSettings) {
        self.init()

        // Основні
        // `showversbypressdown` в оригіналі означає «реагувати по натисканню».
        buttonAction = (config.bool("showversbypressdown", in: "settings") ?? false) ? .onPress : .onRelease
        foreground = (config.bool("SetMainformForeground", in: "settings") ?? true) ? .mainWindow : .slideWindow
        percentFillingPage = config.int("percentfillingpage", in: "OutScreen") ?? percentFillingPage
        animationFrequency = config.int("AnimTimerFreq", in: "OutScreen") ?? animationFrequency
        monitorIndex = config.int("monitor", in: "OutScreen") ?? monitorIndex
        defaultWidth = config.int("width", in: "OutScreen") ?? defaultWidth
        defaultHeight = config.int("height", in: "OutScreen") ?? defaultHeight
        customLeft = config.int("CustomLeft", in: "OutScreen") ?? customLeft
        customTop = config.int("CustomTop", in: "OutScreen") ?? customTop
        customWidth = config.int("CustomWidth", in: "OutScreen") ?? customWidth
        customHeight = config.int("CustomHeight", in: "OutScreen") ?? customHeight
        loadAllBooks = config.bool("LoadAllBooks", in: "settings") ?? loadAllBooks
        lazyLoadModules = config.bool("LazyLoadModule", in: "settings") ?? lazyLoadModules
        thumbsMode = ThumbsMode(rawValue: config.int("ThumbsMode", in: "settings") ?? 0) ?? .system

        // Додаткові
        crossfadeTime = config.int("CrossfadeTime", in: "OutScreen") ?? crossfadeTime
        slideTransition = config.string("SlideTransition", in: "OutScreen") ?? slideTransition
        slideTransitionEasing = config.string("SlideTransitionEasing", in: "OutScreen") ?? slideTransitionEasing
        hideSlideTime = config.int("HideSlideTime", in: "OutScreen") ?? hideSlideTime
        doubleMonitors = (config.string("DoubleMonitors", in: "OutScreen") ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        songsEndMarker = config.string("SongsEndChunkPostText", in: "settings") ?? songsEndMarker
        fastInputUseBackSpace = config.bool("FastInputUseBackSpace", in: "settings") ?? fastInputUseBackSpace
        separatorTenVerses = config.bool("SeparatorTenLine", in: "Bible") ?? separatorTenVerses
        activeInputFieldColor = config.color("ActiveInputFieldColor", in: "settings") ?? activeInputFieldColor
        showVerseNumbers = config.bool("ShowVersNum", in: "OutScreen") ?? showVerseNumbers
        showSecondaryVerseNumbers = config.bool("ShowExtraQuoteVersNum", in: "OutScreen") ?? showSecondaryVerseNumbers
        useRCPointer = config.bool("UseRCPointer", in: "settings") ?? useRCPointer

        // Слайд
        refAllMain = AddressStyle(rawValue: config.int("RefAllMainType", in: "settings") ?? 0) ?? .long
        refAllSec = AddressStyle(rawValue: config.int("RefAllSecType", in: "settings") ?? 1) ?? .short
        refMain = AddressStyle(rawValue: config.int("RefMainType", in: "settings") ?? 0) ?? .long
        refSec = AddressStyle(rawValue: config.int("RefSecType", in: "settings") ?? 0) ?? .long
        refsSeparated = config.bool("RefsSeparated", in: "settings") ?? refsSeparated
        songNumberPP = config.bool("SongNameWithNumPP", in: "settings") ?? songNumberPP
        songNumberInCollection = config.bool("SongNameWithNumInCollection", in: "settings") ?? songNumberInCollection
        songNumberInBrackets = config.bool("SongNameWithNumInCollectionInBrackets", in: "settings") ?? songNumberInBrackets
        songDotAfterNumber = config.bool("SongNameDotAfterNum", in: "settings") ?? songDotAfterNumber

        // Медіа
        audioDeviceID = config.int("MediaDefaultAudioDevice", in: "mediaplayer") ?? audioDeviceID
        showVideoOnPreview = config.bool("VideoToPreview", in: "mediaplayer") ?? showVideoOnPreview
        ndiEnabled = config.bool("NdiSendSlide", in: "OutScreen") ?? ndiEnabled
        ndiSendVideo = config.bool("NdiSendVideo", in: "OutScreen") ?? ndiSendVideo
        ndiSendAudio = config.bool("NdiSendAudio", in: "OutScreen") ?? ndiSendAudio
        ndiFrameHeight = config.int("NdiFrameHeight", in: "OutScreen") ?? ndiFrameHeight
        ndiTransport = config.string("NdiTransport", in: "OutScreen") ?? ndiTransport
        webVideoEnabled = config.bool("WebVideo", in: "OutScreen") ?? webVideoEnabled
        webVideoHeight = config.int("WebVideoHeight", in: "OutScreen") ?? webVideoHeight
        webVideoKbps = config.int("WebVideoKbps", in: "OutScreen") ?? webVideoKbps
        ndiWiFiEnabled = config.bool("NdiWiFi", in: "OutScreen") ?? ndiWiFiEnabled
        ndiWiFiHeight = config.int("NdiWiFiHeight", in: "OutScreen") ?? ndiWiFiHeight
        ndiWiFiFrameRate = config.int("NdiWiFiFps", in: "OutScreen") ?? ndiWiFiFrameRate
        ndiAudioGainDb = config.int("NdiAudioGainDb", in: "OutScreen") ?? ndiAudioGainDb
        ndiTransparentBackground = config.bool("NdiTransparentBackGr", in: "OutScreen") ?? ndiTransparentBackground
        ndiFrameRateIndex = config.int("NdiFpsId", in: "OutScreen") ?? ndiFrameRateIndex

        // Remote API
        webEnabled = config.bool("WEBEnabled", in: "RemoteApi") ?? webEnabled
        webPort = config.int("WEBPort", in: "RemoteApi") ?? webPort
        webNetInterface = config.string("RemoteApiWEBNetInterface", in: "RemoteApi") ?? webNetInterface
        webSocketEnabled = config.bool("WSEnabled", in: "RemoteApi") ?? webSocketEnabled
        webSocketPort = config.int("WSPort", in: "RemoteApi") ?? webSocketPort
        tcpEnabled = config.bool("TCPEnabled", in: "RemoteApi") ?? tcpEnabled
        tcpPort = config.int("TCPPort", in: "RemoteApi") ?? tcpPort
        udpEnabled = config.bool("UDPEnabled", in: "RemoteApi") ?? udpEnabled
        udpPort = config.int("UDPPort", in: "RemoteApi") ?? udpPort

        // Оновлення
        updateInterval = config.int("CheckUpdatesInterval", in: "Update") ?? updateInterval
    }

    /// Частота кадрів NDI за індексом — списком володіє `OutputConfiguration`.
    public var ndiFrameRate: Int {
        let rates = OutputConfiguration.ndiFrameRates
        return rates.indices.contains(ndiFrameRateIndex)
            ? Int(rates[ndiFrameRateIndex].rounded()) : 30
    }
}

/// Рядок списку модулів на вкладці «Модулі» (6.1.4).
///
/// У `[BiblePath]` у кожного рядка два значення: шлях і ознака ввімкненості
/// (`0="Modules\rst+\"|1`). Порядок рядків — це порядок вкладок перекладів у
/// головному вікні, тому тут він і зберігається, а не виводиться з імені.
public struct ModuleRosterEntry: Codable, Sendable, Hashable, Identifiable {
    /// Шлях у записі оригіналу, разом зі зворотними скісними.
    public var path: String
    /// Ім'я теки або файлу — ним модуль упізнається в бібліотеці.
    public var name: String
    public var isEnabled: Bool

    public var id: String { path }

    public init(path: String, name: String, isEnabled: Bool) {
        self.path = path
        self.name = name
        self.isEnabled = isEnabled
    }

    /// Модуль це чи Пісенник: у пісенників розширення `.songbook` (своє)
    /// або `.vbm` (VisioBible).
    public var isSongBook: Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".vbm") || lower.hasSuffix(".songbook")
    }

    /// Де модуль лежить на диску. Запис — у дусі оригіналу: відносний
    /// шлях зі зворотними скісними від теки даних (`Modules\rst+\`) або повний
    /// шлях POSIX, якщо модуль додали з іншого місця.
    public func resolvedURL(dataRoot: URL) -> URL {
        var tail = path.replacingOccurrences(of: "\\", with: "/")
        while tail.hasSuffix("/") { tail.removeLast() }
        if tail.hasPrefix("/") { return URL(fileURLWithPath: tail) }
        return dataRoot.appendingPathComponent(tail)
    }

    /// Ім'я, яким модуль називає себе в бібліотеці: у теки «Цитата з
    /// Біблії» — ім'я теки, у бази MyBible — ім'я файлу без `.SQLite3`, у
    /// MySword — без `.bbl.mybible`. За ним рядок списку налаштувань і
    /// знаходить відкритий модуль.
    public var libraryIdentifier: String {
        let lower = name.lowercased()
        if lower.hasSuffix(".bbl.mybible") { return String(name.dropLast(".bbl.mybible".count)) }
        if lower.hasSuffix(".sqlite3") { return String(name.dropLast(".sqlite3".count)) }
        if lower.hasSuffix(".sqlite") { return String(name.dropLast(".sqlite".count)) }
        return name
    }

    /// Розбір рядка `"Modules\rst+\"|1`.
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = parts.first.map(String.init) ?? rawValue
        let enabled = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) != "0" : true
        let cleaned = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !cleaned.isEmpty else { return nil }
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "\\"))
        guard let name = trimmed.split(separator: "\\").last.map(String.init) else { return nil }
        self.init(path: cleaned, name: name, isEnabled: enabled)
    }

    public var rawValue: String { "\"\(path)\"|\(isEnabled ? 1 : 0)" }
}

/// Рядок списку шляхів до фонових малюнків (6.1.5).
/// У `[PicturePath]` формат той самий, але хвіст після `|` означає не
/// ввімкненість, а «сканувати вкладені теки».
public struct PicturePathEntry: Codable, Sendable, Hashable, Identifiable {
    public var path: String
    public var scansSubfolders: Bool

    public var id: String { path }

    public init(path: String, scansSubfolders: Bool) {
        self.path = path
        self.scansSubfolders = scansSubfolders
    }

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let rawPath = (parts.first.map(String.init) ?? rawValue)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        guard !rawPath.isEmpty else { return nil }
        self.init(path: rawPath, scansSubfolders: parts.count > 1 && parts[1].trimmingCharacters(in: .whitespaces) != "0")
    }

    public var rawValue: String { "\"\(path)\"|\(scansSubfolders ? 1 : 0)" }
}

/// Рядок списку «Web слайди» на вкладці Remote API.
/// Оригінал тримає його не в ini, а у `visiobible.json`.
public struct WebSlideEntry: Codable, Sendable, Hashable, Identifiable {
    public var name: String
    public var fileName: String
    public var details: String

    public var id: String { fileName + "|" + name }

    public init(name: String, fileName: String, details: String) {
        self.name = name
        self.fileName = fileName
        self.details = details
    }

    private enum CodingKeys: String, CodingKey {
        case name = "Name", fileName = "FileName", details = "Description"
    }
}

/// Тип частини пісні для «Колірної легенди» (6.4): колір і його альтернативні
/// назви різними мовами.
public struct SongChunkSetting: Codable, Sendable, Hashable, Identifiable {
    public var key: String
    /// `TColor` Delphi — так само, як це лежить у `[SongChunksColors]`.
    public var tColor: Int
    public var names: [String]

    public var id: String { key }

    public init(key: String, tColor: Int, names: [String]) {
        self.key = key
        self.tColor = tColor
        self.names = names
    }

    public var color: SlideStyle.RGBA { SongChunkPalette.color(tColor: tColor) }

    /// Рядок секції `[SongChunksColors]`: колір, далі назви через кому.
    public var rawValue: String { ([String(tColor)] + names).joined(separator: ",") }
}

/// Повний знімок налаштувань: параметри, списки модулів і шляхів, розкладки клавіш
/// і колірна легенда частин пісень.
public struct SlovoSettings: Codable, Sendable {

    public var options: ProgramOptions
    public var modules: [ModuleRosterEntry]
    public var picturePaths: [PicturePathEntry]
    public var screenshotFolder: String
    public var hotkeySets: HotkeySets
    public var hotkeySetName: String
    public var webSlides: [WebSlideEntry]
    public var songChunks: [SongChunkSetting]

    public init(options: ProgramOptions = ProgramOptions(),
                modules: [ModuleRosterEntry] = [],
                picturePaths: [PicturePathEntry] = [],
                screenshotFolder: String = "ScreenShots\\",
                hotkeySets: HotkeySets = .factoryDefault,
                hotkeySetName: String = "",
                webSlides: [WebSlideEntry] = [],
                songChunks: [SongChunkSetting] = []) {
        self.options = options
        self.modules = modules
        self.picturePaths = picturePaths
        self.screenshotFolder = screenshotFolder
        self.hotkeySets = hotkeySets
        self.hotkeySetName = hotkeySetName.isEmpty ? (hotkeySets.preferredSetName ?? "") : hotkeySetName
        self.webSlides = webSlides
        self.songChunks = songChunks
    }

    /// Збирання з файла умовчань — це вихідний стан вікна при першому
    /// запуску, до того як користувач щось змінив у нас.
    public init(config: IniSettings?, hotkeySets: HotkeySets, dataRoot: URL?) {
        let options = config.map { ProgramOptions(config: $0) } ?? ProgramOptions()

        var modules: [ModuleRosterEntry] = []
        if let section = config?.sections["BiblePath"] {
            modules = section
                .compactMap { key, value -> (Int, ModuleRosterEntry)? in
                    guard let index = Int(key), let entry = ModuleRosterEntry(rawValue: value) else { return nil }
                    return (index, entry)
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        var pictures: [PicturePathEntry] = []
        if let section = config?.sections["PicturePath"] {
            pictures = section
                .compactMap { key, value -> (Int, PicturePathEntry)? in
                    guard let index = Int(key), let entry = PicturePathEntry(rawValue: value) else { return nil }
                    return (index, entry)
                }
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        let chunks = SlovoSettings.readChunks(config)
        let slides = SlovoSettings.readWebSlides(dataRoot: dataRoot)

        self.init(options: options,
                  modules: modules,
                  picturePaths: pictures,
                  screenshotFolder: config?.string("screenshotfolder", in: "settings") ?? "ScreenShots\\",
                  hotkeySets: hotkeySets,
                  hotkeySetName: hotkeySets.preferredSetName ?? "",
                  webSlides: slides,
                  songChunks: chunks)
    }

    // MARK: -

    /// Кольори й назви частин пісень: той самий розбір, що в `SongChunkPalette`,
    /// але зі збереженням вихідного `TColor` — його треба вміти записати назад.
    private static func readChunks(_ config: IniSettings?) -> [SongChunkSetting] {
        let known = ["Verse", "Chorus", "Pre-Chorus", "Bridge", "Tag", "Intro", "End"]
        guard let section = config?.sections["SongChunksColors"], !section.isEmpty else {
            return SongChunkPalette.factoryDefault.chunks.map {
                SongChunkSetting(key: $0.key, tColor: tColor(of: $0.color), names: $0.names)
            }
        }
        var order = known
        for key in section.keys.sorted() where !known.contains(where: { $0.lowercased() == key }) {
            order.append(key)
        }
        var result: [SongChunkSetting] = []
        for key in order {
            guard let raw = section[key.lowercased()] else { continue }
            let fields = raw.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = fields.first, let value = Int(first) else { continue }
            result.append(SongChunkSetting(key: key, tColor: value, names: fields.dropFirst().filter { !$0.isEmpty }))
        }
        return result
    }

    /// Сторінки з комплекту — коли свого списку немає нізвідки: ті самі дві,
    /// що в автора, і наша сторінка шаблону.
    public static var builtInWebSlides: [WebSlideEntry] {
        [WebSlideEntry(name: "stage", fileName: "VBWebSlideStage.html", details: "Stage slide"),
         WebSlideEntry(name: "trans", fileName: "VBWebSlideCF1.html", details: "Translation slide"),
         WebSlideEntry(name: "slovo", fileName: "slovo-slide.html", details: OurWords.t("Слайд по шаблону программы")),
         WebSlideEntry(name: "slovo-overlay", fileName: "slovo-slide-overlay.html",
                       details: OurWords.t("Слайд поверх видео: без фона, только текст"))]
    }

    public static func readWebSlides(dataRoot: URL?) -> [WebSlideEntry] {
        guard let dataRoot else { return [] }
        let url = dataRoot.appendingPathComponent("visiobible.json")
        // Файл записано з міткою порядку байтів (BOM) — Windows так робить.
        // Розбирач JSON її не прощає, і список веб-сторінок у власника
        // виходив порожнім, хоча у файлі дві сторінки.
        guard var data = try? Data(contentsOf: url) else { return [] }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { data.removeFirst(3) }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let api = root["RemoteAPI"] as? [String: Any],
              let slides = api["WebSlides"] as? [String: Any] else { return [] }

        // Наборів сторінок може бути кілька; оригінал тримає робочий під
        // ім'ям «Default», а ми беремо його ж, інакше — перший-ліпший.
        let list = (slides["Default"] as? [[String: Any]]) ?? (slides.values.first as? [[String: Any]]) ?? []
        return list.compactMap { item in
            guard let file = item["FileName"] as? String else { return nil }
            return WebSlideEntry(name: item["Name"] as? String ?? file,
                                 fileName: file,
                                 details: item["Description"] as? String ?? "")
        }
    }

    /// Зворотне перетворення кольору в `TColor` — Delphi зберігає `0x00BBGGRR`.
    public static func tColor(of color: SlideStyle.RGBA) -> Int {
        let red = Int((color.red * 255).rounded())
        let green = Int((color.green * 255).rounded())
        let blue = Int((color.blue * 255).rounded())
        return (blue << 16) | (green << 8) | red
    }

    /// Палітра для списку частин пісні — з поточного стану налаштувань.
    public var songPalette: SongChunkPalette {
        SongChunkPalette(chunks: songChunks.map {
            SongChunkPalette.Chunk(key: $0.key, color: $0.color, names: $0.names)
        })
    }

    /// Розкладка клавіш вибраного набору.
    public var hotkeys: [String: Hotkey] { hotkeySets.hotkeys(inSet: hotkeySetName) }

    /// Імена ввімкнених модулів у тому порядку, в якому вони стоять у списку.
    public var enabledModuleNames: [String] {
        modules.filter(\.isEnabled).map(\.name)
    }
}
