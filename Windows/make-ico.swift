// Створює AppIcon.ico зі значка «Слова» — той самий малюнок, що в програми на Mac.
// (Узято з «Перенесення сайту» для Windows: там та сама задача.)
//
// Джерело вписується в прозорий квадрат із полем 6% — для квадратного значка
// «Слова» поле просто лишається прозорим, як і в самому .icns.
//
// Windows очікує в одному файлі кілька розмірів: 16 і 32 — для списку файлів,
// 48 — для великих значків, 256 — для плитки й вікна «Про програму».
// Починаючи з Vista, всередині .ico дозволено класти PNG, чим і користуємось:
// це і менший файл, і повноцінний альфа-канал без масок 1-бітної прозорості.
//
// Побічно пишемо AppIcon-256.png — той самий квадрат для іконки вікна:
// Avalonia бере її окремо від .ico, вшитої у сам .exe.

import AppKit
import CoreGraphics

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("Використання: make-ico <джерело.png> <вихід.ico> [ігнорується]")
    exit(2)
}
let src = URL(fileURLWithPath: args[1])
let outIco = URL(fileURLWithPath: args[2])
let outPng = outIco.deletingLastPathComponent()
    .appendingPathComponent(outIco.deletingPathExtension().lastPathComponent + "-256.png")

guard let data = try? Data(contentsOf: src),
      let rep = NSBitmapImageRep(data: data),
      let cg = rep.cgImage else {
    print("Не вдалося прочитати \(src.path)")
    exit(1)
}

/// Малює джерело по центру прозорого квадрата зі збереженням пропорцій.
func square(_ size: Int) -> Data? {
    guard let ctx = CGContext(data: nil, width: size, height: size,
                              bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.interpolationQuality = .high

    // Поле 6% з кожного боку — те саме число, що й у make-icns.swift.
    let inset = CGFloat(size) * 0.06
    let box = CGFloat(size) - inset * 2
    let scale = min(box / CGFloat(cg.width), box / CGFloat(cg.height))
    let w = CGFloat(cg.width) * scale
    let h = CGFloat(cg.height) * scale
    ctx.draw(cg, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))

    guard let out = ctx.makeImage() else { return nil }
    let bitmap = NSBitmapImageRep(cgImage: out)
    bitmap.size = NSSize(width: size, height: size)
    return bitmap.representation(using: .png, properties: [:])
}

let sizes = [16, 24, 32, 48, 64, 128, 256]
var images: [(size: Int, png: Data)] = []
for size in sizes {
    guard let png = square(size) else {
        print("Не вдалося намалювати розмір \(size)")
        exit(1)
    }
    images.append((size, png))
}

// -----------------------------------------------------------------------------
//  Складання контейнера .ico
// -----------------------------------------------------------------------------
//  ICONDIR:        2 байти нуля, 2 байти типу (1 = іконка), 2 байти кількості.
//  ICONDIRENTRY:   по 16 байтів на розмір; 256 записується як 0, бо під ширину
//                  відведено рівно один байт.
// -----------------------------------------------------------------------------

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
func le32(_ v: Int) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
}

var bytes: [UInt8] = []
bytes += le16(0)                 // зарезервовано
bytes += le16(1)                 // тип: іконка
bytes += le16(images.count)

var offset = 6 + images.count * 16
for image in images {
    let dimension = image.size >= 256 ? 0 : image.size
    bytes.append(UInt8(dimension))      // ширина
    bytes.append(UInt8(dimension))      // висота
    bytes.append(0)                     // палітра не використовується
    bytes.append(0)                     // зарезервовано
    bytes += le16(1)                    // площин
    bytes += le16(32)                   // біт на точку
    bytes += le32(image.png.count)
    bytes += le32(offset)
    offset += image.png.count
}
for image in images { bytes += [UInt8](image.png) }

do {
    try Data(bytes).write(to: outIco)
    if let big = images.first(where: { $0.size == 256 })?.png {
        try big.write(to: outPng)
    }
    print("Готово: \(outIco.lastPathComponent), розмірів \(images.count), \(bytes.count) байтів")
} catch {
    print("Не вдалося записати \(outIco.path): \(error.localizedDescription)")
    exit(1)
}
