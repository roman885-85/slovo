import AppKit
import CoreGraphics
import CoreVideo
import SlovoCore

/// Захоплення екрана для macOS 11 і 12 — там, де ScreenCaptureKit ще немає.
///
/// Власник: «захват экрана работает только начиная с 13 macos, а нужно с
/// 11». ScreenCaptureKit з'явився в macOS 12.3 і по-справжньому в 13, а
/// програма мусить іти від Big Sur. Тому тут — старша пара засобів, яка
/// працює скрізь від 10.х:
///
/// — монітор бере `CGDisplayStream`: система сама шле кадр, коли на екрані
///   щось змінилося, і віддає його готовою `IOSurface` — без копіювання;
/// — вікно бере `CGWindowListCreateImage` за годинником. Потокового способу
///   зняти чуже вікно на цих системах немає взагалі, і знімок за тактом —
///   єдине, що є. Тому вікно тут коштує дорожче за монітор, і частоту для
///   нього краще тримати невисокою.
///
/// Обидва засоби в macOS 14 оголошено застарілими — і саме тому вони тут, а
/// не в спільному коді: на 13 і новіших працює ScreenCaptureKit, а сюди
/// заходять лише старі системи.
@MainActor
final class LegacyScreenCapture {

    /// Джерело в списку — той самий склад, що й у нового способу.
    struct Item {
        let id: String
        let isDisplay: Bool
        let title: String
        let subtitle: String
        let width: Int
        let height: Int
        /// Номер монітора або вікна — за ним і починаємо показ.
        let number: UInt32
    }

    /// Чи дано дозвіл «Запис екрана». Без нього список вікон приходить без
    /// назв, а кадри — чорні; і те й те виглядало б як поломка програми.
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Попросити дозвіл. Система покаже своє віконце — натискає людина.
    @discardableResult
    static func askPermission() -> Bool { CGRequestScreenCaptureAccess() }

    /// Що зараз можна показати.
    static func sources() -> [Item] {
        var found: [Item] = []

        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        if CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success {
            for index in 0..<Int(count) {
                let display = ids[index]
                let width = CGDisplayPixelsWide(display)
                let height = CGDisplayPixelsHigh(display)
                found.append(Item(id: "display-\(display)", isDisplay: true,
                                  title: OurWords.t("Монитор %s", "\(index + 1)"),
                                  subtitle: "\(width)×\(height)",
                                  width: width, height: height, number: display))
            }
        }

        // Вікна чужих програм. Свої не беремо: наведене саме на себе вікно
        // дає картинку в нескінченність, і в залі це миготіння.
        let own = ProcessInfo.processInfo.processIdentifier
        let listing = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] ?? []
        for window in listing {
            guard let number = window[kCGWindowNumber as String] as? UInt32,
                  let pid = window[kCGWindowOwnerPID as String] as? Int32, pid != own,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double,
                  width > 120, height > 90 else { continue }
            let title = (window[kCGWindowName as String] as? String) ?? ""
            let owner = (window[kCGWindowOwnerName as String] as? String) ?? ""
            // Без дозволу система не називає вікон зовсім — тоді підписуємо
            // їх програмою, щоб список не був рядом порожніх рядків.
            let name = title.isEmpty ? owner : title
            guard !name.isEmpty else { continue }
            found.append(Item(id: "window-\(number)", isDisplay: false,
                              title: name, subtitle: owner,
                              width: Int(width), height: Int(height), number: number))
        }
        return found
    }

    // MARK: - Показ

    private var stream: CGDisplayStream?
    private var timer: Timer?
    private var onFrame: ((CVPixelBuffer) -> Void)?

    var isRunning: Bool { stream != nil || timer != nil }

    /// Почати показ. Повертає причину невдачі або `nil`, якщо пішло.
    func start(_ item: Item, frameRate: Int, frame: @escaping (CVPixelBuffer) -> Void) -> String? {
        stop()
        onFrame = frame
        guard Self.hasPermission else {
            return OurWords.t("Нет разрешения на запись экрана. Дайте его в «Системные настройки» → "
                + "«Конфиденциальность и безопасность» → «Запись экрана» и вернитесь сюда.")
        }
        return item.isDisplay ? startDisplay(item, frameRate: frameRate)
                              : startWindow(item, frameRate: frameRate)
    }

    private func startDisplay(_ item: Item, frameRate: Int) -> String? {
        let queue = DispatchQueue(label: "ua.church.slovo.capture.legacy")
        // Найменший проміжок між кадрами — тим самим ключем, що й у нового
        // способу: більше тридцяти на служінні не треба.
        let properties: [CFString: Any] = [
            CGDisplayStream.minimumFrameTime: 1.0 / Double(max(1, frameRate)),
            CGDisplayStream.showCursor: true,
        ]
        let created = CGDisplayStream(dispatchQueueDisplay: item.number,
                                      outputWidth: item.width,
                                      outputHeight: item.height,
                                      pixelFormat: Int32(kCVPixelFormatType_32BGRA),
                                      properties: properties as CFDictionary,
                                      queue: queue) { status, _, surface, _ in
            guard status == .frameComplete, let surface else { return }
            // `CVPixelBufferCreateWithIOSurface` віддає некеровану посилку —
            // забираємо її собі одразу, інакше кадр протече.
            var made: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &made) == kCVReturnSuccess,
                  let buffer = made?.takeRetainedValue() else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.onFrame?(buffer) }
            }
        }
        guard let created else {
            return OurWords.t("Не удалось начать захват: %s", "CGDisplayStream")
        }
        stream = created
        guard created.start() == .success else {
            stream = nil
            return OurWords.t("Не удалось начать захват: %s", "CGDisplayStream.start")
        }
        return nil
    }

    private func startWindow(_ item: Item, frameRate: Int) -> String? {
        // Знімок вікна коштує дорого, і брати його частіше за п'ятнадцять
        // разів на секунду немає сенсу: рука в чужій програмі рухається
        // повільніше, а машина на старій системі й так не з нових.
        let step = 1.0 / Double(max(1, min(15, frameRate)))
        guard shoot(window: item.number) != nil else {
            return OurWords.t("Источник больше не открыт — обновите список")
        }
        timer = Timer.scheduledTimer(withTimeInterval: step, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let buffer = self.shoot(window: item.number) else { return }
                self.onFrame?(buffer)
            }
        }
        return nil
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let stream { _ = stream.stop() }
        stream = nil
        onFrame = nil
    }

    // MARK: - Знімок вікна

    private var shotPool: CVPixelBufferPool?
    private var shotSize = CGSize.zero

    private func shoot(window: CGWindowID) -> CVPixelBuffer? {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, window,
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1, image.height > 1 else { return nil }
        let size = CGSize(width: image.width, height: image.height)
        if shotPool == nil || shotSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: image.width,
                kCVPixelBufferHeightKey: image.height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var pool: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess
            else { return nil }
            shotPool = pool
            shotSize = size
        }
        guard let shotPool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, shotPool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer),
              let context = CGContext(data: base, width: image.width, height: image.height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                          | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}
