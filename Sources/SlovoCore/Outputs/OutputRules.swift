import Foundation

/// Куди йде слайд. Кожен вивід — самостійний канал зі своїми
/// правилами, а не копія сусіднього.
///
/// Це не прикраса архітектури, а вимога задачі: на проектор іде
/// картинка з фоном, у NDI — той самий напис, але часто на прозорому фоні і з
/// іншою частотою кадрів, у веб — узагалі HTML зі своїм шаблоном, а на екран
/// служителя — наступний вірш і нотатки, яких у залі ніхто не бачить.
public enum OutputKind: String, Sendable, CaseIterable, Identifiable, Codable {
    case screen     // проектор або другий монітор
    case preview    // передпоказ у вікні керування
    case ndi        // мережева трансляція на відеомікшер
    case web        // веб-слайди в браузері
    case stage      // екран для служителя

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .screen:  return OurWords.t("Монитор")
        case .preview: return OurWords.t("Предпросмотр")
        case .ndi:     return OurWords.t("NDI трансляция")
        case .web:     return OurWords.t("Web слайды")
        case .stage:   return OurWords.t("Экран служителя")
        }
    }
}

/// Правила одного виводу: що малювати і як.
public struct OutputRules: Sendable, Hashable {
    public var isEnabled: Bool
    public var style: SlideStyle

    /// Фон підкладки. NDI зазвичай віддають без фону, щоб мікшер поклав напис
    /// поверх своєї картинки, — за це відповідає `NdiTransparentBackGr`.
    public var drawsBackground: Bool
    public var showsReference: Bool
    public var showsSecondaryTranslations: Bool
    public var showsVerseNumbers: Bool

    /// Лише для потокових виводів.
    public var frameRate: Int
    public var sendsVideo: Bool
    public var sendsOnlyChanged: Bool
    /// Звук програми — у трансляцію. Своя настройка: в оригіналу її немає.
    public var sendsAudio: Bool = true
    /// Висота кадру трансляції; 0 — як у слайда. Своя настройка: по Wi-Fi
    /// 1080p без стиснення не проходить, 720p і 540p — удвічі-вчетверо легші.
    public var frameHeight: Int = 0

    public init(style: SlideStyle = SlideStyle(),
                isEnabled: Bool = false,
                drawsBackground: Bool = true,
                showsReference: Bool = true,
                showsSecondaryTranslations: Bool = true,
                showsVerseNumbers: Bool = false,
                frameRate: Int = 30,
                sendsVideo: Bool = false,
                sendsOnlyChanged: Bool = true) {
        self.style = style
        self.isEnabled = isEnabled
        self.drawsBackground = drawsBackground
        self.showsReference = showsReference
        self.showsSecondaryTranslations = showsSecondaryTranslations
        self.showsVerseNumbers = showsVerseNumbers
        self.frameRate = frameRate
        self.sendsVideo = sendsVideo
        self.sendsOnlyChanged = sendsOnlyChanged
    }

    /// Готує вміст слайда під правила саме цього виводу.
    public func compose(_ slide: Slide) -> Slide {
        guard !slide.isBlank else { return slide }
        var result = slide
        if !showsSecondaryTranslations { result.secondaryTexts = [] }
        if !showsReference { result.reference = "" }
        return result
    }

    /// Стиль з урахуванням правил виводу — наприклад, без підкладки для NDI.
    public var effectiveStyle: SlideStyle {
        guard !drawsBackground else { return style }
        var stripped = style
        stripped.backgroundImagePath = nil
        stripped.backgroundColor = SlideStyle.RGBA(0, 0, 0, 0)
        stripped.dimBackground = 0
        return stripped
    }
}

/// Мережеві параметри веб-виводу — порти й адреси з `[RemoteApi]`.
public struct WebOutputSettings: Sendable, Hashable {
    public var httpEnabled: Bool
    public var httpPort: Int
    public var webSocketEnabled: Bool
    public var webSocketPort: Int
    public var tcpEnabled: Bool
    public var tcpPort: Int
    public var udpEnabled: Bool
    public var udpPort: Int
    /// Шаблони сторінок з теки RemoteAPI — «свої преднастройки» веб-виводу.
    public var pages: [WebPage]

    public struct WebPage: Sendable, Hashable, Identifiable {
        public let fileName: String
        public let title: String
        public var id: String { fileName }
    }
}

/// Набір правил для всіх виводів одразу.
public struct OutputConfiguration: Sendable {
    public var rules: [OutputKind: OutputRules]
    public var web: WebOutputSettings

    public subscript(kind: OutputKind) -> OutputRules {
        get { rules[kind] ?? OutputRules() }
        set { rules[kind] = newValue }
    }

    /// Частоти кадрів NDI в тому самому порядку, в якому їх перелічує оригінал:
    /// `NdiFpsId` — це індекс у списку, а не саме число.
    ///
    /// Список знято зі знімка розкритого списку у власника: чотирнадцять
    /// значень, і шістдесяте стоїть тринадцятим, якщо рахувати з нуля, —
    /// рівно як `NdiFpsId=13` у його налаштуваннях. Колишній наш список був
    /// вигаданий (1, 2, 3, 4, 5, 6, 8, 10, …) і давав за тим самим номером 30.
    /// Дробові частоти мовлення лишаємо дробовими: це не причіпка, 59,94 і
    /// 60 — різні речі для відеомікшера.
    public static let ndiFrameRates: [Double] = [10, 12, 12.5, 14.985, 15, 23.976,
                                                 24, 25, 29.97, 30, 48, 50, 59.94, 60]

    /// Підписи зі списку автора — їх і показуємо людині.
    public static let ndiFrameRateTitles = ["10", "12 Half Film", "12.5 Half PAL",
                                            "14.985 Half NTSC", "15 Multimedia",
                                            "23.976 IVTC Film", "24 NTSC Film", "25 PAL",
                                            "29.97 NTSC", "30 Double Multimedia",
                                            "48 Double NTSC Film", "50 Double PAL",
                                            "59.94 Double NTSC", "60"]

    public init(config: IniSettings?, dataRoot: URL?) {
        let base = config.map { SlideStyle(config: $0, section: "Bible", dataRoot: dataRoot) } ?? SlideStyle()

        var screen = OutputRules(style: base, isEnabled: true)
        screen.showsVerseNumbers = config?.bool("ShowVersNum", in: "OutScreen") ?? false

        var preview = screen
        preview.isEnabled = true

        // NDI: свої прапорці, своя частота, свій фон.
        var ndi = OutputRules(style: base)
        ndi.isEnabled = config?.bool("NdiSendSlide", in: "OutScreen") ?? false
        ndi.drawsBackground = !(config?.bool("NdiTransparentBackGr", in: "OutScreen") ?? false)
        ndi.sendsVideo = config?.bool("NdiSendVideo", in: "OutScreen") ?? false
        ndi.sendsOnlyChanged = config?.bool("NdiSendOnlyChanged", in: "OutScreen") ?? true
        ndi.sendsAudio = config?.bool("NdiSendAudio", in: "OutScreen") ?? true
        ndi.frameHeight = config?.int("NdiFrameHeight", in: "OutScreen") ?? 0
        let fpsIndex = config?.int("NdiFpsId", in: "OutScreen") ?? 13
        ndi.frameRate = Self.ndiFrameRates.indices.contains(fpsIndex)
            ? Int(Self.ndiFrameRates[fpsIndex].rounded()) : 30

        // Веб малює не картинку, а HTML — оформлення задає його шаблон,
        // тому стиль тут лише для підстановки кольорів і шрифтів.
        var web = OutputRules(style: base)
        web.isEnabled = config?.bool("WEBEnabled", in: "RemoteApi") ?? false

        // Екран служителя: без фону і без другого перекладу, зате крупно.
        var stage = OutputRules(style: base)
        stage.drawsBackground = false
        stage.showsSecondaryTranslations = false

        rules = [.screen: screen, .preview: preview, .ndi: ndi, .web: web, .stage: stage]
        self.web = WebOutputSettings(
            httpEnabled: config?.bool("WEBEnabled", in: "RemoteApi") ?? false,
            httpPort: config?.int("WEBPort", in: "RemoteApi") ?? 82,
            webSocketEnabled: config?.bool("WSEnabled", in: "RemoteApi") ?? false,
            webSocketPort: config?.int("WSPort", in: "RemoteApi") ?? 8100,
            tcpEnabled: config?.bool("TCPEnabled", in: "RemoteApi") ?? false,
            tcpPort: config?.int("TCPPort", in: "RemoteApi") ?? 8101,
            udpEnabled: config?.bool("UDPEnabled", in: "RemoteApi") ?? false,
            udpPort: config?.int("UDPPort", in: "RemoteApi") ?? 8100,
            pages: Self.discoverPages(in: dataRoot?.appendingPathComponent("RemoteAPI")))
    }

    private static func discoverPages(in folder: URL?) -> [WebOutputSettings.WebPage] {
        guard let folder else { return [] }
        return WebOutputSettings.discoverPages(in: folder)
    }
}
