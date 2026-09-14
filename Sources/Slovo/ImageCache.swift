import AppKit
import SlovoCore

/// Кэш картинок, читаемых с диска.
///
/// Виды SwiftUI перестраиваются часто — на каждое изменение состояния, а не
/// раз на кадр. Вызов `NSImage(contentsOfFile:)` прямо в теле вида означал,
/// что фон слайда заново читался и раскодировался при каждой перерисовке:
/// на снимке экрана это не видно, а руками ощущается как «программа думает».
/// Отдельно кэшируем уменьшенные миниатюры — раскладка фонов рисует их
/// десятками, и полноразмерные там не нужны.
@MainActor
enum ImageCache {

    private static var full: [String: NSImage] = [:]
    private static var thumbnails: [String: NSImage] = [:]

    /// Ограничение на всякий случай: у пользователя может быть сотня фонов,
    /// а полноразмерная фотография — это десятки мегабайт в памяти.
    private static let fullLimit = 12

    static func image(atPath path: String) -> NSImage? {
        if let cached = full[path] { return cached }
        guard let image = NSImage(contentsOfFile: DataPaths.existing(path) ?? path) else { return nil }

        if full.count >= fullLimit { full.removeAll() }
        full[path] = image
        return image
    }

    static func thumbnail(at url: URL, height: CGFloat = 96) -> NSImage? {
        let key = "\(url.path)#\(Int(height))"
        if let cached = thumbnails[key] { return cached }

        let located = DataPaths.existing(url.path).map { URL(fileURLWithPath: $0) } ?? url
        guard let source = NSImage(contentsOf: located) else { return nil }
        let size = source.size
        guard size.height > 0 else { return nil }

        let scale = min(1, height / size.height)
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())

        let small = NSImage(size: target)
        small.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: target),
                    from: NSRect(origin: .zero, size: size),
                    operation: .copy, fraction: 1)
        small.unlockFocus()

        thumbnails[key] = small
        return small
    }

    static func clear() {
        full.removeAll()
        thumbnails.removeAll()
    }
}
