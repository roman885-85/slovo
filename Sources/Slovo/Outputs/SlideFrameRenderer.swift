import AppKit
import CoreVideo
import Combine
import SlovoCore

/// Как в кадре записана прозрачность.
///
/// CoreGraphics умеет рисовать только в «умноженную» альфу: цвет уже
/// затемнён своей прозрачностью. NDI в формате BGRA ждёт обратного —
/// чистый цвет и отдельно альфу, иначе полупрозрачные края букв на
/// микшере получают тёмную кайму. Поэтому режим приходится различать явно.
enum FrameAlpha {
    /// Как рисует CoreGraphics: цвет уже умножен на альфу.
    case premultiplied
    /// Как ждёт NDI: цвет и альфа независимы.
    case straight
}

/// Готовый кадр: и картинкой, и сырыми байтами.
///
/// Держим оба представления, потому что у них разные потребители.
/// `CGImage` нужен предпросмотру и сохранению в PNG, а в сеть уходит
/// плоский буфер, где никакого CoreGraphics уже нет.
///
/// `@unchecked Sendable` здесь честно: все поля неизменяемы, а `CGImage` —
/// иммутабельный CF-объект. Кадр специально ездит между главным потоком,
/// который его рисует, и очередью канала, которая его отправляет.
struct RenderedFrame: @unchecked Sendable {
    /// Байты в порядке B, G, R, A — ровно так их ждёт и NDI, и CVPixelBuffer.
    let pixels: Data
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let alpha: FrameAlpha
    /// Отпечаток содержимого. По нему режим «слать только при изменении»
    /// отличает новый кадр от повтора, не сравнивая мегабайты пикселей.
    let identity: Int
    let image: CGImage

    /// Есть ли в кадре хоть одна не полностью непрозрачная точка.
    /// Просьба «фон прозрачный» слишком легко теряется по дороге —
    /// в стиле, в контексте отрисовки, в настройках вывода, — поэтому
    /// факт прозрачности проверяем по самим байтам, а не по флагу.
    let hasTransparency: Bool

    /// Значение угловой точки — самая быстрая проверка, что фон действительно
    /// прозрачный: в углу слайда текста не бывает никогда.
    var topLeftPixel: (b: UInt8, g: UInt8, r: UInt8, a: UInt8) {
        pixels.withUnsafeBytes { raw in
            let p = raw.bindMemory(to: UInt8.self)
            guard p.count >= 4 else { return (0, 0, 0, 0) }
            return (p[0], p[1], p[2], p[3])
        }
    }

    func pngData() -> Data? {
        // Через AppKit, а не ImageIO: лишних зависимостей у приложения нет,
        // а альфу NSBitmapImageRep сохраняет корректно.
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Внеэкранная отрисовка слайда в кадр заданного размера.
///
/// Почему `ImageRenderer`, а не `NSHostingView` в скрытом окне:
/// у `NSHostingView` слой рисуется в непрозрачный бэкинг окна, и
/// `cacheDisplay(in:to:)` возвращает либо чёрный прямоугольник, либо пустоту,
/// пока вид не попал в живое окно на экране. Альфа при этом теряется —
/// а весь смысл NDI-кадра как раз в ней. `ImageRenderer` (macOS 13+) рисует
/// вид без окна и при `isOpaque = false` честно отдаёт прозрачный фон,
/// поэтому берём его. Побочная выгода — не нужно держать скрытое окно,
/// которое мигало бы в Mission Control.
///
/// SwiftUI считает раскладку только на главном потоке, обойти это нельзя.
/// Поэтому единственный доступный рычаг — рисовать редко: кадр строится
/// заново лишь когда изменилось содержимое или размер, а всё остальное
/// (перекладывание байтов, снятие умножения на альфу) вынесено в
/// `nonisolated`-методы, которые вызывающий волен исполнять в фоне.
@MainActor
final class SlideFrameRenderer {

    /// Снимок вида: картинка плюс отпечаток содержимого, по которому видно,
    /// что рисовать заново незачем.
    struct Snapshot: @unchecked Sendable {
        let image: CGImage
        let identity: Int
    }

    /// Размер кадра в пикселях. Масштаб держим равным единице: на Retina-машине
    /// `ImageRenderer` по умолчанию нарисовал бы вдвое больше, и в сеть ушёл бы
    /// кадр не того разрешения, о котором договорились с микшером.
    var size: CGSize {
        didSet { if size != oldValue { cached = nil } }
    }

    private var cached: Snapshot?

    init(size: CGSize = CGSize(width: 1920, height: 1080)) {
        self.size = size
    }

    /// Сбросить кэш — например, когда сменился зарегистрированный шрифт.
    func invalidate() { cached = nil }

    // MARK: - Главный поток

    /// Картинка слайда. Повторный вызов с тем же содержимым не трогает SwiftUI.
    func snapshot(slide: Slide, style: SlideStyle,
                  preset: SlidePreset? = nil,
                  texts: ConstructorSample = ConstructorSample(),
                  drawsBackground: Bool = true,
                  clock: Double? = nil,
                  backgroundOverride: String? = nil,
                  imageURL: @escaping (String?) -> URL? = { _ in nil }) -> Snapshot? {
        var identity = Self.identity(slide: slide, style: style, size: size, preset: preset,
                                     drawsBackground: drawsBackground)
        // Кадр анимации — свой на каждую миллисекунду: складывать их в кэш
        // по общему отпечатку значило бы показать один и тот же кадр весь
        // переход.
        if let clock { identity = identity &+ Int(clock * 1000) &* 31 }
        if let backgroundOverride { identity = identity &+ backgroundOverride.hashValue }
        if clock == nil, let cached, cached.identity == identity { return cached }

        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let pointSize = CGSize(width: width, height: height)

        let order = SlideDrawing.Order(slide: slide, style: style, preset: preset, texts: texts,
                                       drawsBackground: drawsBackground, clock: clock,
                                       backgroundOverride: backgroundOverride,
                                       withSecondTranslation: !slide.secondaryTexts.isEmpty,
                                       imageURL: imageURL)
        // Подложку не заливаем: прозрачность — весь смысл кадра для NDI, а
        // цвет фона положит сам рисовальщик, если фон рисовать велено.
        guard let image = SlideDrawing.image(order, size: pointSize, opaque: false) else { return nil }
        let result = Snapshot(image: image, identity: identity)
        if clock == nil { cached = result }
        return result
    }

    /// Полный кадр «одним вызовом» — для разовых задач: сохранить PNG,
    /// показать предпросмотр, проверить прозрачность.
    func frame(slide: Slide, style: SlideStyle, alpha: FrameAlpha = .straight) -> RenderedFrame? {
        guard let snapshot = snapshot(slide: slide, style: style) else { return nil }
        return Self.pack(snapshot, alpha: alpha)
    }

    /// Отпечаток содержимого кадра. Размер входит в него намеренно: та же
    /// надпись в другом разрешении — другой кадр.
    static func identity(slide: Slide, style: SlideStyle, size: CGSize,
                         preset: SlidePreset? = nil,
                         drawsBackground: Bool = true) -> Int {
        var hasher = Hasher()
        hasher.combine(slide)
        hasher.combine(style)
        hasher.combine(preset)
        hasher.combine(drawsBackground)
        hasher.combine(Int(size.width.rounded()))
        hasher.combine(Int(size.height.rounded()))
        return hasher.finalize()
    }

    // MARK: - Можно вызывать из фона

    /// Раскладывает картинку в плоский BGRA-буфер.
    ///
    /// Отдельный шаг, а не часть отрисовки: здесь нет ни SwiftUI, ни AppKit,
    /// поэтому вызывающий может увести эту работу с главного потока.
    nonisolated static func pack(_ snapshot: Snapshot, alpha: FrameAlpha) -> RenderedFrame? {
        pack(snapshot.image, identity: snapshot.identity, alpha: alpha)
    }

    nonisolated static func pack(_ image: CGImage, identity: Int, alpha: FrameAlpha) -> RenderedFrame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var pixels = Data(count: bytesPerRow * height)
        var transparent = false

        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            // premultipliedFirst + byteOrder32Little даёт в памяти именно
            // B, G, R, A — тот единственный порядок, который понимают и NDI,
            // и CVPixelBuffer формата 32BGRA.
            let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
            guard let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: bitmapInfo) else { return false }
            // Свежий контекст формально уже нулевой, но `clear` дешевле, чем
            // потом искать причину, почему в кадре осталась чужая картинка.
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = bytesPerRow * height
            transparent = Self.hasTransparency(bytes, count: count)
            if alpha == .straight && transparent {
                Self.unpremultiply(bytes, count: count)
            }
            return true
        }
        guard drawn else { return nil }

        return RenderedFrame(pixels: pixels,
                             width: width,
                             height: height,
                             bytesPerRow: bytesPerRow,
                             // Если прозрачных точек нет, умножение ничего не
                             // изменило — кадр одинаково верен в обоих режимах.
                             alpha: transparent ? alpha : .premultiplied,
                             identity: identity,
                             image: image,
                             hasTransparency: transparent)
    }

    /// Кадр в `CVPixelBuffer` — для тех приёмников, что работают через
    /// CoreVideo (запись, AVFoundation, аппаратный кодировщик).
    ///
    /// `kCVPixelFormatType_32BGRA` по соглашению хранит умноженную альфу,
    /// поэтому кадр, подготовленный для NDI, приходится умножить обратно.
    nonisolated static func pixelBuffer(from frame: RenderedFrame) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey: frame.width,
            kCVPixelBufferHeightKey: frame.height,
            // Без IOSurface буфер нельзя отдать ни кодировщику, ни слою.
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         frame.width,
                                         frame.height,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &buffer)
        guard status == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let destination = CVPixelBufferGetBaseAddress(buffer) else { return nil }

        let destinationStride = CVPixelBufferGetBytesPerRow(buffer)
        frame.pixels.withUnsafeBytes { raw in
            guard let source = raw.baseAddress else { return }
            // Ширина строки у CoreVideo своя, выровненная, — копируем построчно.
            let copyLength = min(frame.bytesPerRow, destinationStride)
            for row in 0..<frame.height {
                let from = source.advanced(by: row * frame.bytesPerRow)
                let to = destination.advanced(by: row * destinationStride)
                memcpy(to, from, copyLength)
            }
        }

        if frame.alpha == .straight {
            let bytes = destination.assumingMemoryBound(to: UInt8.self)
            for row in 0..<frame.height {
                premultiply(bytes.advanced(by: row * destinationStride), count: frame.width * 4)
            }
        }
        return buffer
    }

    // MARK: - Байты

    private nonisolated static func hasTransparency(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) -> Bool {
        var index = 3
        while index < count {
            if bytes[index] != 255 { return true }
            index += 4
        }
        return false
    }

    /// Делит цвет обратно на альфу. Округление «половина вверх» повторяет то,
    /// что делает CoreGraphics при умножении, — иначе после двух преобразований
    /// белый текст уплывает в серый.
    private nonisolated static func unpremultiply(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
        var index = 0
        while index + 3 < count {
            let a = Int(bytes[index + 3])
            if a != 0 && a != 255 {
                for channel in 0..<3 {
                    let value = (Int(bytes[index + channel]) * 255 + a / 2) / a
                    bytes[index + channel] = UInt8(min(255, value))
                }
            } else if a == 0 {
                // Полностью прозрачная точка не несёт цвета; оставляем нули,
                // чтобы приёмник не выцарапал из неё мусор.
                bytes[index] = 0; bytes[index + 1] = 0; bytes[index + 2] = 0
            }
            index += 4
        }
    }

    private nonisolated static func premultiply(_ bytes: UnsafeMutablePointer<UInt8>, count: Int) {
        var index = 0
        while index + 3 < count {
            let a = Int(bytes[index + 3])
            if a != 255 {
                for channel in 0..<3 {
                    bytes[index + channel] = UInt8((Int(bytes[index + channel]) * a + 127) / 255)
                }
            }
            index += 4
        }
    }
}
