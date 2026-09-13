import AppKit
import Accelerate
import CoreVideo
import ScreenCaptureKit
import SlovoCore

/// Захоплення екрана: монітор або вікно чужої програми — на проектор і в NDI.
///
/// Власник: «захват окна или выделенного участка монитора или весь монитор
/// или определённого окна и выводить его на проектор и ndi, с функцией
/// указки и масштабирования содержимого».
///
/// Кадр іде тією самою дорогою, що й кадр фільму: `MediaPlayerModel` роздає
/// його шарам проектора, живому екрану і каналу NDI. Тому указка, затемнення,
/// «Сховати» і сама трансляція працюють без жодної нової гілки — усе це там
/// уже є і вже перевірене.
///
/// Наближення (точка фокуса) робиться тут же: шматок кадру вирізається і
/// розтягується назад до повного розміру. Так розмір кадру в мережі не
/// стрибає, а «виділена ділянка монітора» — це той самий вирізаний шматок.
///
/// Потрібен дозвіл «Запис екрана» в системних налаштуваннях. Просити його
/// може лише сама людина: програма скаже, що дозволу немає, і назве місце.
///
/// Двигунів два. На macOS 13 і новіших — ScreenCaptureKit: він швидкий,
/// віддає кадр готовою поверхнею і сам вирішує, коли на екрані щось
/// змінилося. На macOS 11 і 12 його немає зовсім, і там працює старша пара
/// засобів (`LegacyScreenCapture`). Власник: «захват экрана работает только
/// начиная с 13 macos, а нужно с 11». Назовні різниці немає: список джерел,
/// «Показати», «Сховати» і наближення однакові.
@MainActor
final class ScreenCaptureModel: NSObject, ObservableObject {

    /// Що можна показати: монітор цілком або одне вікно.
    struct Source: Identifiable, Equatable {
        enum Kind: String { case display, window }
        let id: String
        let kind: Kind
        /// Що написано в списку.
        let title: String
        /// Другий рядок: програма для вікна, роздільність для монітора.
        let subtitle: String
        let width: Int
        let height: Int

        static func == (a: Source, b: Source) -> Bool { a.id == b.id }
    }

    @Published private(set) var sources: [Source] = []
    @Published private(set) var current: Source?
    /// Що сказати людині: скільки джерел, чи йде показ, чому не пішов.
    @Published private(set) var state = ""
    /// Скільки кадрів забрали — самоперевірці й підпису.
    @Published private(set) var frameCount = 0
    /// Чи бракує дозволу на запис екрана.
    @Published private(set) var needsPermission = false

    /// Кадр — назовні. Ставить `AppState`.
    var onFrame: ((CVPixelBuffer) -> Void)?

    /// Скільки кадрів на секунду брати. Більше 30 на служінні не треба, а
    /// кожен кадр — це робота і на пересилання, і на стиснення.
    var frameRate = 15

    /// Потік нового способу і його приймач. Тримаємо як `AnyObject`: типи
    /// ScreenCaptureKit існують лише з macOS 13, а клас має збиратися і для
    /// Big Sur.
    private var streamStorage: AnyObject?
    private var outputStorage: AnyObject?
    /// Старий двигун — для macOS 11 і 12.
    private let legacy = LegacyScreenCapture()

    /// Змусити старий двигун і на новій системі.
    ///
    /// Інакше його ніде перевірити: розробка й самоперевірка йдуть на
    /// свіжій macOS, де завжди вибирається новий спосіб, і код для Big Sur
    /// лишався б написаним наосліп. Вмикається змінною середовища
    /// `SLOVO_LEGACY_CAPTURE=1` або самоперевіркою.
    static var forcesLegacy = ProcessInfo.processInfo.environment["SLOVO_LEGACY_CAPTURE"] == "1"

    /// Який двигун працює зараз — підпису і самоперевірці.
    var usesLegacyEngine: Bool {
        if Self.forcesLegacy { return true }
        if #available(macOS 13.0, *) { return false }
        return true
    }
    private var legacyItems: [String: LegacyScreenCapture.Item] = [:]
    /// Останній сирий кадр — до наближення.
    ///
    /// Система шле кадр лише тоді, коли на екрані щось змінилося: показуєш
    /// нерухоме вікно — кадрів немає зовсім. Без цього запасу зміна
    /// наближення на такому вікні не доходила б до залу до першого руху
    /// мишею в чужій програмі.
    private var lastRaw: CVPixelBuffer?
    private var focusWatch: NSObjectProtocol?
    private var displays: [String: AnyObject] = [:]
    private var windows: [String: AnyObject] = [:]
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    /// Яким шматком кадру показуємо зараз — щоб не перезбирати запас даремно.
    private var lastCrop = CGRect(x: 0, y: 0, width: 1, height: 1)

    var isRunning: Bool { streamStorage != nil || legacy.isRunning }

    override init() {
        super.init()
        // Наближення змінилося — перемальовуємо останній кадр, не чекаючи
        // руху на чужому екрані.
        focusWatch = NotificationCenter.default.addObserver(forName: SlideFocus.shownChanged, object: nil,
                                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.redraw() }
        }
    }

    deinit { if let focusWatch { NotificationCenter.default.removeObserver(focusWatch) } }

    /// Віддати останній кадр заново — з новим наближенням.
    private func redraw() {
        guard isRunning, let raw = lastRaw else { return }
        guard let shown = zoomed(raw, crop: SlideFocus.shared.shownRect) else { return }
        frameCount &+= 1
        onFrame?(shown)
    }

    // MARK: - Список джерел

    /// Перечитати, що зараз можна показати. Кличеться при відкритті вкладки.
    func reload() async {
        if #available(macOS 13.0, *), !Self.forcesLegacy {
            await reloadModern()
        } else {
            reloadLegacy()
        }
    }

    /// Список для macOS 11 і 12 — старшими засобами.
    private func reloadLegacy() {
        legacyItems.removeAll()
        guard LegacyScreenCapture.hasPermission else {
            needsPermission = true
            sources = []
            state = OurWords.t("Нет разрешения на запись экрана. Дайте его в «Системные настройки» → "
                + "«Конфиденциальность и безопасность» → «Запись экрана» и вернитесь сюда.")
            return
        }
        needsPermission = false
        var found: [Source] = []
        for item in LegacyScreenCapture.sources() {
            legacyItems[item.id] = item
            found.append(Source(id: item.id, kind: item.isDisplay ? .display : .window,
                                title: item.title, subtitle: item.subtitle,
                                width: item.width, height: item.height))
        }
        sources = found
        state = OurWords.t("Найдено источников: %s", "\(found.count)")
    }

    @available(macOS 13.0, *)
    private func reloadModern() async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false,
                                                                               onScreenWindowsOnly: true)
            needsPermission = false
            var found: [Source] = []
            displays.removeAll()
            windows.removeAll()
            for display in content.displays {
                let id = "display-\(display.displayID)"
                displays[id] = display
                found.append(Source(id: id, kind: .display,
                                    title: OurWords.t("Монитор %s", "\(found.count + 1)"),
                                    subtitle: "\(display.width)×\(display.height)",
                                    width: display.width, height: display.height))
            }
            // Вікна власної програми не показуємо: наведена одне на одне,
            // картинка йде в нескінченність, і в залі це миготіння.
            let own = Bundle.main.bundleIdentifier
            for window in content.windows {
                guard let app = window.owningApplication, app.bundleIdentifier != own else { continue }
                let title = window.title ?? ""
                guard !title.isEmpty, window.frame.width > 120, window.frame.height > 90 else { continue }
                let id = "window-\(window.windowID)"
                windows[id] = window
                found.append(Source(id: id, kind: .window, title: title,
                                    subtitle: app.applicationName,
                                    width: Int(window.frame.width), height: Int(window.frame.height)))
            }
            sources = found
            state = OurWords.t("Найдено источников: %s", "\(found.count)")
        } catch {
            needsPermission = true
            sources = []
            state = OurWords.t("Нет разрешения на запись экрана. Дайте его в «Системные настройки» → "
                + "«Конфиденциальность и безопасность» → «Запись экрана» и вернитесь сюда.")
        }
    }

    // MARK: - Показ

    /// Почати показ джерела. Повертає `false`, якщо не вийшло, — причина
    /// лишається в `state`.
    @discardableResult
    func start(_ source: Source) -> Bool {
        stop()
        if #available(macOS 13.0, *), !Self.forcesLegacy { return startModern(source) }
        return startLegacy(source)
    }

    /// Показ на macOS 11 і 12.
    private func startLegacy(_ source: Source) -> Bool {
        guard let item = legacyItems[source.id] else {
            state = OurWords.t("Источник больше не открыт — обновите список")
            return false
        }
        if let trouble = legacy.start(item, frameRate: frameRate, frame: { [weak self] buffer in
            self?.accept(buffer)
        }) {
            state = trouble
            return false
        }
        current = source
        frameCount = 0
        state = OurWords.t("Показывается: %s", source.title)
        return true
    }

    @available(macOS 13.0, *)
    private func startModern(_ source: Source) -> Bool {
        let filter: SCContentFilter
        if source.kind == .display, let display = displays[source.id] as? SCDisplay {
            filter = SCContentFilter(display: display, excludingWindows: [])
        } else if let window = windows[source.id] as? SCWindow {
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else {
            state = OurWords.t("Источник больше не открыт — обновите список")
            return false
        }

        let configuration = SCStreamConfiguration()
        configuration.width = source.width
        configuration.height = source.height
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        // Один кадр тримаємо в себе про запас (див. `lastRaw`), тому черга
        // трохи довша за звичну трійку.
        configuration.queueDepth = 5
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, frameRate)))

        let output = StreamOutput { [weak self] buffer in
            MainActor.assumeIsolated { self?.accept(buffer) }
        }
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        do {
            try stream.addStreamOutput(output, type: .screen,
                                       sampleHandlerQueue: DispatchQueue(label: "ua.church.slovo.capture"))
        } catch {
            state = OurWords.t("Не удалось начать захват: %s", "\(error)")
            return false
        }
        self.streamStorage = stream
        self.outputStorage = output
        self.current = source
        frameCount = 0
        state = OurWords.t("Показывается: %s", source.title)
        stream.startCapture { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.stop()
                    self?.state = OurWords.t("Не удалось начать захват: %s", "\(error)")
                }
            }
        }
        return true
    }

    func stop() {
        guard isRunning else { return }
        legacy.stop()
        if #available(macOS 13.0, *), let stream = streamStorage as? SCStream {
            stream.stopCapture { _ in }
        }
        streamStorage = nil
        outputStorage = nil
        lastRaw = nil
        current = nil
        pool = nil
        poolSize = .zero
        state = ""
    }

    // MARK: - Кадр

    private func accept(_ buffer: CVPixelBuffer) {
        frameCount &+= 1
        lastRaw = buffer
        let crop = SlideFocus.shared.shownRect
        guard let shown = zoomed(buffer, crop: crop) else { return }
        onFrame?(shown)
    }

    /// Вирізати шматок і розтягнути назад до повного розміру.
    ///
    /// Розмір кадру лишається тим самим — це важливо: приймач NDI не любить,
    /// коли розмір стрибає, а сам стрибок читається в залі як мигання.
    private func zoomed(_ buffer: CVPixelBuffer, crop: CGRect) -> CVPixelBuffer? {
        guard crop.width < 0.999 || crop.height < 0.999 else { return buffer }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard width > 8, height > 8 else { return buffer }
        if poolSize != CGSize(width: width, height: height) || pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            ]
            var fresh: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &fresh) == kCVReturnSuccess else {
                return buffer
            }
            pool = fresh
            poolSize = CGSize(width: width, height: height)
        }
        guard let pool else { return buffer }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &target) == kCVReturnSuccess,
              let target else { return buffer }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        CVPixelBufferLockBaseAddress(target, [])
        defer {
            CVPixelBufferUnlockBaseAddress(target, [])
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }
        guard let from = CVPixelBufferGetBaseAddress(buffer),
              let to = CVPixelBufferGetBaseAddress(target) else { return buffer }
        let fromStride = CVPixelBufferGetBytesPerRow(buffer)
        let toStride = CVPixelBufferGetBytesPerRow(target)
        let box = CGRect(x: (crop.minX * CGFloat(width)).rounded(),
                         y: (crop.minY * CGFloat(height)).rounded(),
                         width: max(8, (crop.width * CGFloat(width)).rounded()),
                         height: max(8, (crop.height * CGFloat(height)).rounded()))
            .intersection(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        guard box.width >= 8, box.height >= 8 else { return buffer }
        var source = vImage_Buffer(data: from.advanced(by: Int(box.minY) * fromStride + Int(box.minX) * 4),
                                   height: vImagePixelCount(box.height),
                                   width: vImagePixelCount(box.width), rowBytes: fromStride)
        var destination = vImage_Buffer(data: to, height: vImagePixelCount(height),
                                        width: vImagePixelCount(width), rowBytes: toStride)
        guard vImageScale_ARGB8888(&source, &destination, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError else {
            return buffer
        }
        lastCrop = crop
        return target
    }

    /// Приймач кадрів SCStream. Окремим об'єктом, бо протокол вимагає
    /// `NSObject`, а модель уже й так головна на своїй ділянці.
    @available(macOS 13.0, *)
    private final class StreamOutput: NSObject, SCStreamOutput {
        private let deliver: (CVPixelBuffer) -> Void
        init(_ deliver: @escaping (CVPixelBuffer) -> Void) { self.deliver = deliver }

        func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                    of type: SCStreamOutputType) {
            guard type == .screen, sampleBuffer.isValid,
                  let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            // Кадр без змін система теж шле — у ньому немає готового вмісту.
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]], let raw = attachments.first?[.status] as? Int,
               let status = SCFrameStatus(rawValue: raw), status != .complete {
                return
            }
            let retained = buffer
            DispatchQueue.main.async { deliverOnMain(retained) }
            func deliverOnMain(_ value: CVPixelBuffer) { self.deliver(value) }
        }
    }
}
