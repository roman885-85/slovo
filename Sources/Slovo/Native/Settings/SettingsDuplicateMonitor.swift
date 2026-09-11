import Foundation

/// Один монитор в списке «Дублирование слайда на мониторы» (12).
///
/// В `VisioBible.ini` это одна строка ключа `DoubleMonitors`. Своего формата
/// у нас нет: имя и прямоугольник записаны через `|`, признак включённости —
/// последним полем, как и в остальных списках оригинала (`BiblePath`,
/// `PicturePath`).
struct SettingsDuplicateMonitor: Identifiable, Hashable {
    var name: String
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var isEnabled: Bool
    /// Ручная настройка (12.1) — её можно переименовать и удалить,
    /// системный монитор нельзя.
    var isCustom: Bool

    var id: String { name }

    init(name: String, x: Int, y: Int, width: Int, height: Int, isEnabled: Bool, isCustom: Bool) {
        self.name = name
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.isEnabled = isEnabled
        self.isCustom = isCustom
    }

    init?(raw: String) {
        let fields = raw.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard fields.count >= 6, !fields[0].isEmpty else { return nil }
        self.init(name: fields[0],
                  x: Int(fields[1]) ?? 0,
                  y: Int(fields[2]) ?? 0,
                  width: Int(fields[3]) ?? 800,
                  height: Int(fields[4]) ?? 600,
                  isEnabled: fields[5] != "0",
                  isCustom: fields.count > 6 ? fields[6] != "0" : false)
    }

    var raw: String {
        "\(name)|\(x)|\(y)|\(width)|\(height)|\(isEnabled ? 1 : 0)|\(isCustom ? 1 : 0)"
    }
}
