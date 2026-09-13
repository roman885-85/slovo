import AppKit
import SlovoCore

/// Знімки слайдів презентації нашим малюванням — щоб порівняти з тим, як
/// їх показує PowerPoint. Тільки по запиту: `SLOVO_PPTX=/шлях/до/файла.pptx`
/// і `--check=презентація-знімки`; картинки лягають у ~/Library/Logs.
///
/// Власник: «при перегляді презентації слайд спотворений, частини інформації
/// немає, текст зміщується, відсутні ефекти (немає тіней)».
extension Diagnostics {

    static func slideShotsSection(state: AppState) -> [Check] {
        let area = "Презентація"
        guard let path = ProcessInfo.processInfo.environment["SLOVO_PPTX"], !path.isEmpty else { return [] }
        let url = URL(fileURLWithPath: path)
        let name = "Знімки слайдів «\(url.lastPathComponent)»"
        let document: PPTXDocument
        do {
            document = try PPTXDocument(fileAt: url)
        } catch {
            return [Check(area: area, name: name, status: .failed, detail: "не відкрився: \(error)")]
        }
        var written: [String] = []
        for (index, slide) in document.slides.enumerated() {
            // Розмір — як у програмі: висота 1080, ширина від пропорції полотна.
            let width = (1080 * document.canvasSize.width / max(1, document.canvasSize.height)).rounded()
            guard let image = PPTXRenderer.image(of: slide, in: document, size: CGSize(width: width, height: 1080)) else {
                written.append("слайд \(index + 1): не намалювався")
                continue
            }
            let rep = NSBitmapImageRep(cgImage: image)
            guard let data = rep.representation(using: .png, properties: [:]) else { continue }
            let file = "slovo-слайд-\(index + 1).png"
            let target = NSString(string: "~/Library/Logs/\(file)").expandingTildeInPath
            do { try data.write(to: URL(fileURLWithPath: target)); written.append(file) } catch { written.append("\(file): \(error)") }
            // Що розібрано на слайді — фігури, текст, ефекти.
            let shapes = slide.shapes.map { shape -> String in
                let text = shape.paragraphs.flatMap(\.runs).map(\.text).joined().prefix(30)
                return String(format: "[%.2f,%.2f %.2f×%.2f] «%@»", shape.frame.minX, shape.frame.minY,
                              shape.frame.width, shape.frame.height, String(text))
            }
            NativeTrace.say("слайд \(index + 1): фігур \(slide.shapes.count): " + shapes.joined(separator: "; "))
        }
        return [Check(area: area, name: name, status: .ok, detail: "слайдів \(document.slides.count): " + written.joined(separator: ", "))]
    }
}
