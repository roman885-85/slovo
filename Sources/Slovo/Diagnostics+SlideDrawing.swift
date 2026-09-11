import AppKit
import ImageIO
import UniformTypeIdentifiers
import SlovoCore

/// Сверка двух отрисовок слайда: прежней, на SwiftUI, и новой, на CoreGraphics.
///
/// Переписывать отрисовку зала «на глазок» нельзя: слайд обязан выглядеть
/// точно так же, как вчера, иначе на служении это заметят первыми. Поэтому
/// один и тот же слайд рисуется обоими путями, картинки сравниваются числами
/// и обе кладутся файлами рядом с отчётом — чтобы человек мог посмотреть.
extension Diagnostics {

    static func slideDrawingSection(state: AppState) -> [Check] {
        let size = CGSize(width: 960, height: 540)
        let slide = Slide(mainText: "Бо так полюбив Бог світ, що дав Сина Свого Однородженого, "
                              + "щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне.",
                          secondaryTexts: ["Ибо так возлюбил Бог мир, что отдал Сына Своего "
                              + "Единородного, дабы всякий верующий в Него не погиб, "
                              + "но имел жизнь вечную."],
                          reference: "Ів. 3:16")
        let style = state.outputs[.screen].effectiveStyle

        // Кадр трансляции и кадр зала обязаны быть одним и тем же: с этого
        // дня их рисует один код, и проверка сторожит, чтобы он не разошёлся.
        let renderer = SlideFrameRenderer(size: size)
        guard let network = renderer.snapshot(slide: slide, style: style)?.image else {
            return [Check(area: "Малювання", name: "Кадр трансляції малюється",
                          status: .failed, detail: "малювальник не віддав картинки")]
        }
        guard let hall = SlideDrawing.image(.init(slide: slide, style: style, preset: nil),
                                            size: size, opaque: true) else {
            return [Check(area: "Малювання", name: "Кадр залу малюється",
                          status: .failed, detail: "малювальник не віддав картинки")]
        }

        write(hall, named: "slovo-слайд-зал.png")
        write(network, named: "slovo-слайд-трансляция.png")

        var checks: [Check] = []
        guard let left = readable(network), let right = readable(hall) else {
            return [Check(area: "Малювання", name: "Кадри порівнянні",
                          status: .failed, detail: "кадри не прочиталися")]
        }

        // Прямое сравнение точка в точку: разница может быть только в
        // подложке (у трансляции она бывает прозрачной), но не в буквах.
        var different = 0
        var checked = 0
        for y in stride(from: 0, to: left.height, by: 2) {
            for x in stride(from: 0, to: left.width, by: 2) {
                let at = (y * left.width + x) * 4
                checked += 1
                let delta = abs(Int(left.bytes[at]) - Int(right.bytes[at]))
                    + abs(Int(left.bytes[at + 1]) - Int(right.bytes[at + 1]))
                    + abs(Int(left.bytes[at + 2]) - Int(right.bytes[at + 2]))
                if delta > 24 { different += 1 }
            }
        }
        let share = Double(different) / Double(max(checked, 1))
        checks.append(Check(area: "Малювання", name: "Зал і трансляція малюють одне й те саме",
                            status: share < 0.005 ? .ok : (share < 0.03 ? .warning : .failed),
                            detail: String(format: "точок розійшлося %.2f %%", share * 100)))

        // Доля «чернил»: сколько точек отличается от подложки. У двух
        // отрисовок одного слайда она обязана сойтись — это и есть «текста
        // столько же и он там же».
        let inkOld = ink(left)
        let inkNew = ink(right)
        let spread = abs(inkOld - inkNew) / max(inkOld, 0.0001)
        checks.append(Check(area: "Малювання", name: "На слайді є що показувати",
                            status: spread < 0.15 ? .ok : (spread < 0.3 ? .warning : .failed),
                            detail: String(format: "зайнято точок: у трансляції %.2f %%, у залі %.2f %% "
                                           + "(розбіжність %.0f %%)", inkOld * 100, inkNew * 100,
                                           spread * 100)))

        // Где именно стоит текст: сравниваем по строкам, а не по точкам —
        // сглаживание у двух движков разное, а места строк совпадать обязаны.
        let rowsOld = rows(left)
        let rowsNew = rows(right)
        let shifted = zip(rowsOld, rowsNew).filter { abs($0 - $1) > 0.08 }.count
        checks.append(Check(area: "Малювання", name: "Рядки стоять на попередніх місцях",
                            status: shifted == 0 ? .ok : (shifted < 3 ? .warning : .failed),
                            detail: "рядків полотна \(rowsOld.count), розійшлися \(shifted); "
                                + "картинки лежать у ~/Library/Logs/slovo-слайд-*.png"))
        return checks
    }

    /// Доля закрашенных точек: всё, что заметно отличается от угла кадра.
    private static func ink(_ frame: (bytes: [UInt8], width: Int, height: Int)) -> Double {
        let base = (Int(frame.bytes[0]), Int(frame.bytes[1]), Int(frame.bytes[2]))
        var count = 0
        for y in stride(from: 0, to: frame.height, by: 2) {
            for x in stride(from: 0, to: frame.width, by: 2) {
                let at = (y * frame.width + x) * 4
                let difference = abs(Int(frame.bytes[at]) - base.0)
                    + abs(Int(frame.bytes[at + 1]) - base.1)
                    + abs(Int(frame.bytes[at + 2]) - base.2)
                if difference > 90 { count += 1 }
            }
        }
        return Double(count) / Double((frame.width / 2) * (frame.height / 2))
    }

    /// Сколько «чернил» в каждой строке холста — отпечаток раскладки.
    private static func rows(_ frame: (bytes: [UInt8], width: Int, height: Int)) -> [Double] {
        let base = (Int(frame.bytes[0]), Int(frame.bytes[1]), Int(frame.bytes[2]))
        var result: [Double] = []
        for y in stride(from: 0, to: frame.height, by: 4) {
            var count = 0
            for x in stride(from: 0, to: frame.width, by: 2) {
                let at = (y * frame.width + x) * 4
                let difference = abs(Int(frame.bytes[at]) - base.0)
                    + abs(Int(frame.bytes[at + 1]) - base.1)
                    + abs(Int(frame.bytes[at + 2]) - base.2)
                if difference > 90 { count += 1 }
            }
            result.append(Double(count) / Double(frame.width / 2))
        }
        return result
    }

    private static func readable(_ image: CGImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = bytes.withUnsafeMutableBytes({ raw -> CGContext? in
            CGContext(data: raw.baseAddress, width: width, height: height,
                      bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (bytes, width, height)
    }

    private static func write(_ image: CGImage, named name: String) {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(name)")
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
