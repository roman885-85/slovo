import Foundation

/// Свій дім даних «Слова».
///
/// Власник: «все переводы и модули внутри пакета всегда» — тека модулів (і
/// поруч із нею фони, шаблони, плани, шрифти, веб-сторінки) живе в пакеті
/// програми, `Contents/Resources/app`, щоб скопійований на інший комп'ютер
/// пакет був цілим. А «залишки VisioBible», яких він просив позбутися, —
/// це довідка `.chm`, мови `.lng`, стилі `.vsf`, знімки й службові ini
/// (їх викидає `deploy.sh`) та формат пісенників `.vbm`: він переводиться у
/// свій `.songbook` просто в теці модулів, а оригінали відкладаються в
/// «Імпорт з VisioBible» поруч із нею. У `~/Library/Application Support/Slovo`
/// живуть налаштування, історія, план, шаблони слайдів — як і раніше.
public enum DataHome {

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo", isDirectory: true)
    }

    /// Тека модулів, коли пакет своєї не має (відкрита збірка без даних).
    public static var modules: URL { folder.appendingPathComponent("Modules", isDirectory: true) }

    /// Куди відкладаються `.vbm`/`.vbi` після перетворення в `.songbook`.
    public static let importArchiveName = "Імпорт з VisioBible"

    /// Теки, в яких пісенники вже перетворювали, — щоб не робити цього
    /// вдруге, коли в теці навмисно лишили `.vbm`.
    public static var ledger: URL { folder.appendingPathComponent("перенесено.json") }

    public static func recordedSources() -> [String] {
        guard let data = try? Data(contentsOf: ledger),
              let list = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return list
    }

    public static func record(source: URL) {
        var list = recordedSources()
        let path = source.standardizedFileURL.path
        guard !list.contains(path) else { return }
        list.append(path)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: ledger, options: .atomic) }
    }

    public struct Report: Sendable {
        public var source = ""
        public var converted = 0
        public var archived = 0
        public var errors: [String] = []

        public init(source: String) { self.source = source }

        public var summary: String {
            "тека модулів «\(source)»: пісенників перетворено у .songbook: \(converted), .vbm/.vbi відкладено: \(archived)"
                + (errors.isEmpty ? "" : "; помилки: " + errors.joined(separator: "; "))
        }
    }

    /// Кожен `.vbm` у теці модулів → `.songbook`; оригінал разом із `.vbi`
    /// — в архів імпорту. Невдалий — лишається на місці й далі читається.
    public static func convertSongBooks(in modules: URL, archive: URL, report: inout Report) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: modules, includingPropertiesForKeys: nil,
                                                   options: [.skipsHiddenFiles])) ?? []
        for url in entries where url.pathExtension.lowercased() == "vbm" {
            let own = url.deletingPathExtension().appendingPathExtension(SongBookJSON.pathExtension)
            if !fm.fileExists(atPath: own.path) {
                do {
                    let book = try SongBook(fileAt: url)
                    try SongBookJSON.write(book, to: own)
                    report.converted += 1
                } catch {
                    report.errors.append("\(url.lastPathComponent): \(error)")
                    continue
                }
            }
            try? fm.createDirectory(at: archive, withIntermediateDirectories: true)
            for companion in [url, url.deletingPathExtension().appendingPathExtension("vbi")]
            where fm.fileExists(atPath: companion.path) {
                let parked = archive.appendingPathComponent(companion.lastPathComponent)
                if fm.fileExists(atPath: parked.path) { try? fm.removeItem(at: parked) }
                if (try? fm.moveItem(at: companion, to: parked)) != nil, companion.pathExtension.lowercased() == "vbm" {
                    report.archived += 1
                }
            }
        }
    }

    /// Перетворити пісенники в теці модулів — один раз на теку (за журналом).
    /// Повертає звіт, коли щось справді зробили.
    @discardableResult
    public static func convertSongBooksOnce(in modules: URL) -> Report? {
        guard !recordedSources().contains(modules.standardizedFileURL.path) else { return nil }
        var report = Report(source: modules.path)
        convertSongBooks(in: modules,
                         archive: modules.deletingLastPathComponent().appendingPathComponent(importArchiveName),
                         report: &report)
        record(source: modules)
        return report.converted + report.archived > 0 || !report.errors.isEmpty ? report : nil
    }
}
