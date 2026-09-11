import Foundation
import SlovoCore

/// Наші написи іншими мовами — файлами в пакеті:
/// `Contents/Resources/OurWords/<код>.json` виду
/// `{"lang": "English", "words": {"Русская строка": "English string"}}`.
///
/// Файли, а не код: власник просив повний переклад на всі мови програми,
/// а це тисяча рядків на кожну з вісімнадцяти мов. У коді вони подовжували
/// б кожну збірку і правилися б лише пересборкою; файл перекладач
/// править на місці. Українська лишається в коді — вона основна і перевіряється
/// самоперевіркою порядково.
enum OurWordsBundle {

    static var folder: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("OurWords", isDirectory: true)
    }

    /// Завантажити всі словники. Повертає код мови → число рядків.
    @discardableResult
    static func load() -> [String: Int] {
        var loaded: [String: Int] = [:]
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else {
            return loaded
        }
        for file in files where file.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let words = json["words"] as? [String: String] else { continue }
            let code = file.deletingPathExtension().lastPathComponent.lowercased()
            OurWords.register(words, for: code)
            loaded[code] = words.count
        }
        return loaded
    }
}
