import AppKit

/// Дневник запуска: что и в каком порядке произошло, пока поднималось окно.
///
/// Заведён после того, как самопроверка раз за разом говорила «песенник
/// открыт», а в живом окне модуль «Песни» был пуст. Разница между проверкой и
/// настоящим запуском видна только на настоящем запуске, а посмотреть в него
/// нечем: окно уже стоит, а как оно собиралось — неизвестно. Теперь известно.
///
/// Пишется в `~/Library/Logs/slovo-start.txt`, переписывается на каждый пуск.
enum NativeTrace {

    static let path = NSString(string: "~/Library/Logs/slovo-start.txt").expandingTildeInPath

    private nonisolated(unsafe) static var started = false

    /// Снять само окно в картинку.
    ///
    /// Снимок экрана не годится: окно бывает закрыто чужими окнами и лежит на
    /// другом рабочем столе. Здесь же рисует сама программа — то, что видно
    /// человеку, и ничего сверх того.
    @MainActor
    static func snapshot(_ view: NSView, to name: String) {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        let where_ = NSString(string: "~/Library/Logs/\(name)").expandingTildeInPath
        try? data.write(to: URL(fileURLWithPath: where_))
        say("снимок окна: \(name), \(Int(view.bounds.width))×\(Int(view.bounds.height))")
    }

    static func box(_ rect: NSRect) -> String {
        "\(Int(rect.width))×\(Int(rect.height)) у (\(Int(rect.minX)),\(Int(rect.minY)))"
    }

    static func say(_ line: String) {
        let stamp = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
        let text = "\(stamp)  \(line)\n"
        if !started {
            started = true
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        handle.seekToEndOfFile()
        handle.write(Data(text.utf8))
        try? handle.close()
    }
}
