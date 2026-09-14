import Foundation

/// Свій дім даних «Слова»: `~/Library/Application Support/Slovo`.
///
/// Доти корінь даних був там, де тека модулів, — у власника це копія
/// VisioBible всередині пакета (`Слово.app/Contents/Resources/app`, 435 МБ:
/// модулі, фони, шаблони, мови, довідка, стилі…). Власник: «избавиться от
/// остатков VisioBible и неиспользуемых файлов». Тепер дані живуть у своєму
/// домі, а пакет — лише програма; те, що було в чужому корені, переноситься
/// сюди один раз (`migrate`), пісенники — у свій формат `.songbook`.
public enum DataHome {

    public static var folder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo", isDirectory: true)
    }

    public static var modules: URL { folder.appendingPathComponent("Modules", isDirectory: true) }

    /// Теки, які переїжджають із чужого кореня: імена ті самі, бо на них
    /// посилаються налаштування (`Modules\rst+\`, `BackGrounds\…`).
    public static let movableFolders = ["Modules", "BackGrounds", "Templates", "Plans", "Fonts", "RemoteAPI"]
    /// Те, що НЕ переїжджає: довідка VisioBible, її мови (`.lng` — інтерфейс
    /// іде зі свого словника), стилі `.vsf`, знімки, службові ini.
    public static let leftBehind = ["Help", "Language", "Styles", "ScreenShots", "fonts_correct.ini", "hebrnew.ini", "shortnames.json"]
    /// Куди відкладаються `.vbm`/`.vbi` після перетворення в `.songbook`.
    public static let importArchiveName = "Імпорт з VisioBible"

    /// Чужий корінь: усередині пакета програми або установленого VisioBible.
    public static func isForeign(modulesFolder url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains(".app/Contents/Resources/app") || path.lowercased().contains("visiobible")
    }

    /// Звідки можна перенести дані, коли свого дому ще нема: тека даних,
    /// відкладена `deploy.sh` поруч із пакетом, сусідні пакети «Слова»,
    /// установлений VisioBible.
    public static func migrationCandidates(near bundle: URL) -> [URL] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        var roots: [URL] = []
        let beside = bundle.deletingLastPathComponent()
        roots.append(beside.appendingPathComponent("Дані з пакета (VisioBible)"))
        for base in [beside, home.appendingPathComponent("Desktop"), home.appendingPathComponent("Documents/Слово")] {
            for entry in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where entry.hasSuffix(".app") {
                roots.append(base.appendingPathComponent(entry).appendingPathComponent("Contents/Resources/app"))
            }
        }
        for base in [home.appendingPathComponent("Applications"), URL(fileURLWithPath: "/Applications")] {
            for entry in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where entry.lowercased().hasPrefix("visiobible") {
                roots.append(base.appendingPathComponent(entry).appendingPathComponent("Contents/Resources/app"))
            }
        }
        let support = home.appendingPathComponent("Library/Application Support")
        for entry in (try? fm.contentsOfDirectory(atPath: support.path)) ?? [] where entry.lowercased().hasPrefix("visiobible") {
            roots.append(support.appendingPathComponent(entry))
        }
        return roots.filter { fm.fileExists(atPath: $0.appendingPathComponent("Modules").path) }
    }

    public struct Report: Sendable {
        public var source = ""
        public var copied: [String: Int] = [:]
        public var converted = 0
        public var archived = 0
        public var errors: [String] = []
        public var seconds = 0.0

        public var summary: String {
            let folders = movableFolders.compactMap { name -> String? in
                guard let count = copied[name], count > 0 else { return nil }
                return "\(name) \(count)"
            }
            return "перенесено з «\(source)»: " + (folders.isEmpty ? "нічого нового" : folders.joined(separator: ", "))
                + "; пісенників перетворено у .songbook: \(converted), .vbm/.vbi відкладено: \(archived)"
                + (errors.isEmpty ? "" : "; помилки: " + errors.joined(separator: "; "))
                + String(format: "; %.1f с", seconds)
        }
    }

    /// Перенести дані з чужого кореня у свій дім. КОПІЮЄ, а не переносить:
    /// чужий пакет чи установка лишаються цілими. Те, що в домі вже є, не
    /// перезаписує. Після копіювання кожен `.vbm` у теці модулів
    /// перетворюється на `.songbook`, а сам `.vbm` з `.vbi` відкладається в
    /// «Імпорт з VisioBible» — так у модулях лишається лише свій формат.
    @discardableResult
    public static func migrate(from oldRoot: URL, into home: URL = DataHome.folder) -> Report {
        let fm = FileManager.default
        let started = Date()
        var report = Report(source: oldRoot.path)
        do {
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
        } catch {
            report.errors.append("дім не створюється: \(error)")
            return report
        }
        for name in movableFolders {
            let source = oldRoot.appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            let target = home.appendingPathComponent(name)
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            var count = 0
            let archive = home.appendingPathComponent(importArchiveName)
            for entry in (try? fm.contentsOfDirectory(atPath: source.path)) ?? [] where !entry.hasPrefix(".") {
                let destination = target.appendingPathComponent(entry)
                guard !fm.fileExists(atPath: destination.path) else { continue }
                // Пісенник VisioBible, який уже перетворено (є `.songbook`) або
                // відкладено в архів, — не копіюємо вдруге.
                let ext = (entry as NSString).pathExtension.lowercased()
                if name == "Modules", ext == "vbm" || ext == "vbi" {
                    let stem = (entry as NSString).deletingPathExtension
                    if fm.fileExists(atPath: target.appendingPathComponent(stem + "." + SongBookJSON.pathExtension).path)
                        || fm.fileExists(atPath: archive.appendingPathComponent(entry).path) { continue }
                }
                do {
                    try fm.copyItem(at: source.appendingPathComponent(entry), to: destination)
                    count += 1
                } catch {
                    report.errors.append("\(name)/\(entry): \(error.localizedDescription)")
                }
            }
            report.copied[name] = count
        }
        // База правил нумерації — поруч із модулями, як і була.
        let rules = oldRoot.appendingPathComponent("inconsistencies.sqlite3")
        let rulesTarget = home.appendingPathComponent("inconsistencies.sqlite3")
        if fm.fileExists(atPath: rules.path), !fm.fileExists(atPath: rulesTarget.path) {
            try? fm.copyItem(at: rules, to: rulesTarget)
        }
        convertSongBooks(in: home.appendingPathComponent("Modules"), archive: home.appendingPathComponent(importArchiveName), report: &report)
        report.seconds = Date().timeIntervalSince(started)
        return report
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
}
