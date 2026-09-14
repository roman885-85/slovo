import Foundation

/// Ресурси «Слова» в мережі: переклади, пісенники, фони, шаблони — окремо
/// від програми. Власник: «все пакеты и переводы, картинки и другие ресурсы
/// выложить отдельно на гитхаб и создать отдельную сборку без данных —
/// только программа; при запуске предложить выполнить импорт или скачать
/// из гитхаба ресурсы (с выбором); впоследствии они будут обновляться…
/// плюс выбор откуда качать: наш ресурс или переводы с гитхаба BibleQuote».
///
/// Два джерела:
///  • свій каталог `roman885-85/slovo-resources` — `catalog.json` у гілці
///    `main`, файли — assets релізу; у каталозі рід, назва, розмір, версія
///    (дата) і адреса;
///  • модулі «Цитата з Біблії» — `BibleQuote/BibleQuote-Modules` на GitHub:
///    `modules.ini` зі списком і `modules/<ім'я>.zip`, як бере планшет;
///  • реєстр MyBible (`mybible.zone`): `registry.zip` → `registry.json`,
///    переклади — `<ім'я>.zip` з одним `.SQLite3` усередині.
public struct ResourceItem: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case bible, songbook, backgrounds, templates, fonts, web
    }
    public var id: String
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// Розмір файла в байтах; 0 — невідомий (каталог BibleQuote його не каже).
    public var size: Int64
    /// Версія — дата чи будь-який рядок; змінилася — є оновлення.
    public var version: String
    public var url: String
    /// Ім'я, під яким ресурс ляже на диск (тека модуля, файл пісенника…).
    public var fileName: String
    /// Мова ресурсу (`ru`, `uk`, `en`…), коли джерело її каже — за нею
    /// групується довгий список MyBible.
    public var language: String?

    public init(id: String, kind: Kind, title: String, subtitle: String = "", size: Int64 = 0,
                version: String = "", url: String, fileName: String, language: String? = nil) {
        self.language = language
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.size = size
        self.version = version
        self.url = url
        self.fileName = fileName
    }
}

public struct ResourceCatalog: Codable, Sendable {
    public var format: String
    public var updated: String
    public var items: [ResourceItem]

    public static let format = "slovo-resources"

    public init(updated: String, items: [ResourceItem]) {
        self.format = Self.format
        self.updated = updated
        self.items = items
    }

    public static func decode(_ data: Data) throws -> ResourceCatalog {
        let catalog = try JSONDecoder().decode(ResourceCatalog.self, from: data)
        guard catalog.format == format else { throw ResourceError.badCatalog }
        return catalog
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Каталог модулів «Цитата з Біблії»: `modules.ini` — секції
    /// `[Bible_…]` з `ModuleName=` і `ModuleAuthor=`; файл —
    /// `modules/<секція>.zip`. Беремо лише Біблії, як планшет.
    public static func bibleQuote(ini text: String, base: String) -> ResourceCatalog {
        var items: [ResourceItem] = []
        var id: String?
        var name = "", author = ""
        func flush() {
            guard let section = id, section.hasPrefix("Bible_") else { id = nil; return }
            let escaped = section.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? section
            items.append(ResourceItem(id: "bq:" + section, kind: .bible,
                                      title: name.isEmpty ? section : name, subtitle: author,
                                      version: "", url: base + "modules/" + escaped + ".zip",
                                      fileName: section))
            id = nil
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            if line.hasPrefix("["), line.hasSuffix("]") {
                flush()
                id = String(line.dropFirst().dropLast())
                name = ""; author = ""
            } else if line.hasPrefix("ModuleName=") {
                name = String(line.dropFirst("ModuleName=".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("ModuleAuthor=") {
                author = String(line.dropFirst("ModuleAuthor=".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return ResourceCatalog(updated: "", items: items)
    }

    /// Реєстр MyBible: `downloads` — усі модулі; Біблії — ті, в кого ім'я
    /// файла без суфікса (`AGP`, а не `Brux.dictionary`). Адреса — перший
    /// хост із `hosts`, у якого `path` має `%s`.
    public static func myBible(registry data: Data) -> ResourceCatalog? {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let downloads = root["downloads"] as? [[String: Any]] else { return nil }
        let hosts = (root["hosts"] as? [[String: Any]] ?? [])
            .sorted { ($0["priority"] as? Int ?? 9) < ($1["priority"] as? Int ?? 9) }
        var hostPaths: [String: String] = [:]
        for host in hosts {
            if let alias = host["alias"] as? String, let path = host["path"] as? String, path.hasPrefix("https") {
                hostPaths[alias] = path
            }
        }
        var items: [ResourceItem] = []
        for entry in downloads {
            guard let file = entry["fil"] as? String, !file.contains("."),
                  let abbreviation = entry["abr"] as? String else { continue }
            // Перший https-хост зі списку модуля: `{mz}AGP` → mybible.zone.
            var link: String?
            for raw in entry["url"] as? [String] ?? [] {
                guard raw.hasPrefix("{"), let close = raw.firstIndex(of: "}") else { continue }
                let alias = String(raw[raw.index(after: raw.startIndex)..<close])
                let name = String(raw[raw.index(after: close)...])
                if let path = hostPaths[alias] {
                    let escaped = name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name
                    link = path.replacingOccurrences(of: "%s", with: escaped)
                    break
                }
            }
            guard let url = link else { continue }
            let language = entry["lng"] as? String
            let updated = entry["upd"] as? String ?? ""
            items.append(ResourceItem(id: "mb:" + abbreviation, kind: .bible,
                                      title: entry["des"] as? String ?? abbreviation,
                                      subtitle: [abbreviation, updated].filter { !$0.isEmpty }.joined(separator: " · "),
                                      size: Self.size(entry["siz"] as? String), version: updated,
                                      url: url, fileName: abbreviation + ".SQLite3", language: language))
        }
        return ResourceCatalog(updated: root["version"].map { "\($0)" } ?? "", items: items)
    }

    /// «589K», «2.6M» → байти.
    static func size(_ text: String?) -> Int64 {
        guard var text = text?.trimmingCharacters(in: .whitespaces).uppercased(), !text.isEmpty else { return 0 }
        var factor: Double = 1
        if text.hasSuffix("K") { factor = 1024; text.removeLast() }
        else if text.hasSuffix("M") { factor = 1_048_576; text.removeLast() }
        else if text.hasSuffix("G") { factor = 1_073_741_824; text.removeLast() }
        return Int64((Double(text) ?? 0) * factor)
    }
}

public enum ResourceError: Error, CustomStringConvertible {
    case badCatalog
    case network(String)
    case unpack(String)
    case place(String)

    public var description: String {
        switch self {
        case .badCatalog:           return OurWords.t("это не каталог ресурсов «Слова»")
        case .network(let text):    return OurWords.t("нет связи: %s", text)
        case .unpack(let text):     return OurWords.t("не распаковалось: %s", text)
        case .place(let text):      return OurWords.t("не удалось положить на место: %s", text)
        }
    }
}

/// Де які ресурси лежать на диску й що з них уже стоїть.
public struct ResourceLayout: Sendable {
    /// Корінь даних: тека, у якій `Modules`, `BackGrounds`, `Templates`…
    public var dataRoot: URL
    public var modules: URL

    public init(modulesFolder: URL) {
        modules = modulesFolder
        dataRoot = modulesFolder.deletingLastPathComponent()
    }

    public func destination(for item: ResourceItem) -> URL {
        switch item.kind {
        case .bible, .songbook: return modules.appendingPathComponent(item.fileName)
        case .backgrounds:      return dataRoot.appendingPathComponent("BackGrounds")
        case .templates:        return dataRoot.appendingPathComponent("Templates")
        case .fonts:            return dataRoot.appendingPathComponent("Fonts")
        case .web:              return dataRoot.appendingPathComponent("RemoteAPI")
        }
    }

    /// Чи є ресурс на диску (не питаючи журнал версій). Пісенник — у будь-
    /// якому з двох форматів: `.vbm` на диску перетворюється у `.songbook`.
    public func isPresent(_ item: ResourceItem) -> Bool {
        let fm = FileManager.default
        let target = destination(for: item)
        guard item.kind == .songbook else { return fm.fileExists(atPath: target.path) }
        let stem = target.deletingPathExtension()
        return [SongBookJSON.pathExtension, "vbm"].contains {
            fm.fileExists(atPath: stem.appendingPathExtension($0).path)
        }
    }
}

/// Журнал установлених ресурсів: `id` → версія, з якої ставили. Лежить у
/// своєму домі даних; за ним видно, що оновилося в каталозі.
public struct ResourceLedger: Codable, Sendable {
    public var installed: [String: String] = [:]

    public static var url: URL { DataHome.folder.appendingPathComponent("resources.json") }

    public static func load() -> ResourceLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(ResourceLedger.self, from: data) else { return ResourceLedger() }
        return ledger
    }

    public func save() {
        try? FileManager.default.createDirectory(at: DataHome.folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }
}
