import Foundation
import SlovoCore
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Еталон розділу `presentation` — дзеркало CoreCheck.Presentation.cs.

func cgColorText(_ c: CGColor?) -> String {
    guard let c, let p = c.components, p.count >= 4 else { return c == nil ? "-" : "?" }
    return "\(Double(p[0])),\(Double(p[1])),\(Double(p[2])),\(Double(p[3]))"
}
func rectText(_ r: CGRect) -> String { "\(Double(r.minX)) \(Double(r.minY)) \(Double(r.width)) \(Double(r.height))" }
func fillText(_ f: PPTXDocument.Fill) -> String {
    switch f {
    case .none: return "none"
    case .solid(let c): return "solid " + cgColorText(c)
    case .texture(let part, let tile, let duotone): return "texture \(part) tile \(tile.map { "\($0)" } ?? "-") duotone \(duotone.map { cgColorText($0.dark) + "/" + cgColorText($0.light) } ?? "-")"
    case .picture(let part): return "picture " + part
    case .gradient(let g):
        let kind: String
        switch g.kind {
        case .linear(let angle): kind = "linear \(angle)"
        case .rectangular(let focus): kind = "rect " + rectText(focus)
        case .radial(let focus): kind = "radial " + rectText(focus)
        }
        return "gradient " + kind + " stops " + g.stops.map { "\($0.position):\(cgColorText($0.color))" }.joined(separator: ";")
    }
}
func shadowText(_ s: PPTXDocument.Shadow?) -> String {
    guard let s else { return "-" }
    return "\(Double(s.offset.width)),\(Double(s.offset.height)) blur \(s.blur) \(cgColorText(s.color))"
}

func checkPresentation() {
    print("# presentation")
    guard let file = ProcessInfo.processInfo.environment["SLOVO_PPTX"], !file.isEmpty else { print("presentation skipped: no SLOVO_PPTX"); return }
    let url = URL(fileURLWithPath: file)
    let reader = try! ZipArchive.open(url)
    print("zip names \(reader.names.joined(separator: " "))")
    print("zip contains \(reader.contains("ppt/presentation.xml")) \(reader.contains("nope")) part \((try? reader.part("nope")) ?? nil == nil ? "nil" : "?") png \((try? reader.part("ppt/media/texture.png"))??.count ?? -1) text \(fnv(((try? reader.text("ppt/slides/slide1.xml")) ?? nil) ?? ""))")
    let document = try! PPTXDocument(fileAt: url)
    print("file \(url.lastPathComponent) canvas \(Double(document.canvasSize.width)) \(Double(document.canvasSize.height)) count \(document.count) parts \(document.slideParts.joined(separator: " "))")
    for (index, slide) in document.slides.enumerated() {
        print("slide \(index): bg \(fillText(slide.background)) shapes \(slide.shapes.count)")
        for (number, shape) in slide.shapes.enumerated() {
            print("  shape \(number): frame \(rectText(shape.frame)) fill \(fillText(shape.fill)) stroke \(cgColorText(shape.strokeColor)) \(shape.strokeWidth) outline \(shape.outline.rawValue) rot \(shape.rotation) flip \(shape.flipH) \(shape.flipV) crop \(shape.crop.left) \(shape.crop.top) \(shape.crop.right) \(shape.crop.bottom) empty \(shape.crop.isEmpty) anchor \(shape.anchor) scale \(shape.fontScale) autofit \(shape.autofit) shadow \(shadowText(shape.shadow)) textShadow \(shadowText(shape.textShadow))")
            for (p, paragraph) in shape.paragraphs.enumerated() {
                print("    para \(p): align \(paragraph.alignment) indent \(paragraph.indent) bullet «\(paragraph.bullet ?? "-")» marL \(paragraph.marginLeft) first \(paragraph.firstIndent) buFont \(paragraph.bulletFont ?? "-") buColor \(cgColorText(paragraph.bulletColor)) buSize \(paragraph.bulletSize.map { "\($0)" } ?? "-")")
                for run in paragraph.runs {
                    print("      run «\(esc(run.text))» size \(run.size) \(run.isBold) \(run.isItalic) \(run.isUnderlined) color \(cgColorText(run.color)) font \(run.fontName ?? "-")")
                }
            }
        }
    }
    let output = ProcessInfo.processInfo.environment["SLOVO_CHECK_OUT"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0).appendingPathComponent("pptx-swift") }
    if let output { try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
    let height = 1080.0
    let width = height * (Double(document.canvasSize.width) / max(Double(document.canvasSize.height), 1))
    for (index, slide) in document.slides.enumerated() {
        for target in [CGSize(width: width, height: height), CGSize(width: 192, height: 108)] {
            let image = PPTXRenderer.image(of: slide, in: document, size: target)
            print("render \(index) \(Double(target.width))x\(Double(target.height)): \(image.map { "\($0.width)x\($0.height)" } ?? "nil")")
            if let image, let output, target.height == height {
                let file = output.appendingPathComponent(String(format: "slide-%02d.png", index + 1))
                if let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) {
                    CGImageDestinationAddImage(destination, image, nil)
                    CGImageDestinationFinalize(destination)
                }
            }
        }
    }
    print("render zero \(PPTXRenderer.image(of: document.slides[0], in: document, size: CGSize(width: 0, height: 10)) == nil ? "nil" : "?")")

    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("slovo-check-pptx-" + UUID().uuidString)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    try! Data("not a zip".utf8).write(to: folder.appendingPathComponent("text.pptx"))
    func zip(_ name: String, _ entry: String, _ content: String) {
        let staging = folder.appendingPathComponent("staging-" + name)
        let path = staging.appendingPathComponent(entry)
        try! fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(content.utf8).write(to: path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", staging.path, folder.appendingPathComponent(name).path]
        try! process.run(); process.waitUntilExit()
    }
    zip("noppt.pptx", "word/document.xml", "<x/>")
    zip("noslides.pptx", "ppt/presentation.xml", "<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"/>")
    zip("badxml.pptx", "ppt/presentation.xml", "<p:presentation")
    for name in ["text.pptx", "noppt.pptx", "noslides.pptx", "badxml.pptx"] {
        do {
            let opened = try PPTXDocument(fileAt: folder.appendingPathComponent(name))
            print("open \(name): \(opened.count)")
        } catch {
            print("open \(name): \(error)")
        }
    }
}
