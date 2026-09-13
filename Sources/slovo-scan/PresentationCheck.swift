import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import SlovoCore

/// Прогон разборщика презентаций по настоящему файлу.
///
/// Нужен затем, что вид слайда проверяется только глазами: числа скажут, что
/// разобралось десять надписей, и промолчат о том, что все десять стоят одна
/// на другой. Утилита пишет каждый слайд картинкой в папку — их и смотрят.
///
///     slovo-scan <Modules> --pptx <файл> [<куда класть>]
func runPresentationCheck(args: [String]) -> Int32 {
    guard let at = args.firstIndex(of: "--pptx"), args.count > at + 1 else {
        print("использование: … --pptx <файл.pptx> [папка для картинок]")
        return 2
    }
    let url = URL(fileURLWithPath: args[at + 1])
    let outputFolder = args.count > at + 2
        ? URL(fileURLWithPath: args[at + 2])
        : FileManager.default.temporaryDirectory.appendingPathComponent("slovo-pptx")

    let document: PPTXDocument
    let started = Date()
    do {
        document = try PPTXDocument(fileAt: url)
    } catch {
        print("не открылось: \(error)")
        return 1
    }
    let opened = Date().timeIntervalSince(started)

    let inches = CGSize(width: document.canvasSize.width / 914_400,
                        height: document.canvasSize.height / 914_400)
    print("файл: \(url.lastPathComponent)")
    print("холст: \(Int(document.canvasSize.width))×\(Int(document.canvasSize.height)) EMU "
          + String(format: "(%.2f×%.2f дюйма, %.2f:1)", inches.width, inches.height,
                   inches.width / max(inches.height, 0.001)))
    print("слайдов: \(document.count), разобрано за " + String(format: "%.0f мс", opened * 1000))

    try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
    let height = 1080.0
    let width = height * (document.canvasSize.width / max(document.canvasSize.height, 1))

    var drawn = 0
    for (index, slide) in document.slides.enumerated() {
        let texts = slide.shapes.flatMap { $0.paragraphs }.flatMap { $0.runs }.map(\.text)
        let pictures = slide.shapes.filter { if case .picture = $0.fill { return true }; return false }
        var background = "нет"
        switch slide.background {
        case .none: background = "нет"
        case .solid: background = "цвет"
        case .picture(let part): background = "картинка \((part as NSString).lastPathComponent)"
        case .texture(let part, _, _): background = "текстура теми \((part as NSString).lastPathComponent)"
        }
        print("  \(index + 1): фигур \(slide.shapes.count), картинок \(pictures.count), "
              + "фон \(background); текст: "
              + (texts.isEmpty ? "—" : "«" + texts.joined(separator: " ").prefix(70) + "»"))

        guard let image = PPTXRenderer.image(of: slide, in: document,
                                             size: CGSize(width: width, height: height)) else {
            print("     кадр не нарисовался")
            continue
        }
        let file = outputFolder.appendingPathComponent(String(format: "slide-%02d.png", index + 1))
        if let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            drawn += 1
        }
    }
    print("картинок записано: \(drawn) → \(outputFolder.path)")
    return drawn == document.count ? 0 : 1
}
