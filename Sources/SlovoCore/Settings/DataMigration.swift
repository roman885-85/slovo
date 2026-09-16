import Foundation

/// Перенесення даних із пакета програми в дім даних
/// `~/Library/Application Support/Slovo` (`DataHome.folder`).
///
/// Власник 15.09.2026: дані — поза пакетом, «Application Support пусть будет
/// там все». Звідки: `Contents/Resources/app` (модулі, фони, шаблони, шрифти,
/// плани — так везли їх старі збірки й везе повний випуск). Налаштування,
/// історія й свої шаблони й так уже лежать у домі даних.
///
/// Правила обережні: нічого не перезаписується й не видаляється. Чого в новому
/// домі ще немає — переїжджає (перенесенням, а коли джерело лише для читання,
/// як пакет з образу диска, — копією). Теки з тим самим іменем зливаються
/// поелементно. Файл, що вже є в новому домі, лишається де був — новий дім
/// головніший. Кеші службової теки й умовчання пакета не чіпаються.
public enum DataMigration {

    public struct Report: Sendable {
        /// Що переїхало (шляхи відносно нового дому).
        public var moved: [String] = []
        /// Що скопійовано, бо з джерела забрати не можна.
        public var copied: [String] = []
        /// Що вже було в новому домі й лишилося в джерелі.
        public var kept: [String] = []
        public var errors: [String] = []

        public init() {}

        public var isEmpty: Bool { moved.isEmpty && copied.isEmpty && errors.isEmpty }

        public var summary: String {
            var parts: [String] = []
            if !moved.isEmpty { parts.append("перенесено \(moved.count): " + moved.prefix(12).joined(separator: ", ")) }
            if !copied.isEmpty { parts.append("скопійовано \(copied.count): " + copied.prefix(12).joined(separator: ", ")) }
            if !kept.isEmpty { parts.append("уже були в новому домі \(kept.count)") }
            if !errors.isEmpty { parts.append("помилки: " + errors.joined(separator: "; ")) }
            return parts.isEmpty ? "переносити нічого" : parts.joined(separator: "; ")
        }
    }

    /// Звіт останнього запуску — для журналу й самоперевірки.
    public nonisolated(unsafe) static var lastReport = Report()

    @discardableResult
    public static func run(target: URL = DataHome.folder,
                           bundleData: URL = DataHome.bundleData) -> Report {
        var report = Report()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            report.errors.append("не створилася тека \(target.path): \(error.localizedDescription)")
            lastReport = report
            return report
        }
        // Налаштування, історія й шаблони вже лежать у домі даних — забираємо
        // з пакета те, чого тут ще немає: модулі, фони, шаблони, шрифти, плани.
        merge(from: bundleData, into: target,
              skipping: DataHome.bundledDefaults.union(DataHome.visioBibleLeftovers),
              prefix: "", report: &report)
        lastReport = report
        return report
    }

    /// Чи лишилося в пакеті щось, чого немає в новому домі, — помічнику
    /// оновлення: тільки це й треба переносити в новий пакет.
    public static func unmigratedBundleItems(bundleData: URL, target: URL = DataHome.folder) -> [String] {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(atPath: bundleData.path)) ?? []
        return entries.filter { name in
            !name.hasPrefix(".") && !DataHome.bundledDefaults.contains(name)
                && !DataHome.visioBibleLeftovers.contains(name)
                && !fm.fileExists(atPath: target.appendingPathComponent(name).path)
        }.sorted()
    }

    private static func merge(from source: URL, into target: URL, skipping: Set<String>,
                              prefix: String, report: inout Report) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory), isDirectory.boolValue,
              source.standardizedFileURL != target.standardizedFileURL else { return }
        let entries = (try? fm.contentsOfDirectory(atPath: source.path)) ?? []
        for name in entries.sorted() where name != ".DS_Store" && !skipping.contains(name) {
            let from = source.appendingPathComponent(name)
            let to = target.appendingPathComponent(name)
            let relative = prefix.isEmpty ? name : prefix + "/" + name
            var fromIsDirectory: ObjCBool = false
            fm.fileExists(atPath: from.path, isDirectory: &fromIsDirectory)
            var toIsDirectory: ObjCBool = false
            if !fm.fileExists(atPath: to.path, isDirectory: &toIsDirectory) {
                do {
                    try fm.moveItem(at: from, to: to)
                    report.moved.append(relative)
                } catch {
                    do {
                        try fm.copyItem(at: from, to: to)
                        report.copied.append(relative)
                    } catch {
                        report.errors.append("\(relative): \(error.localizedDescription)")
                    }
                }
            } else if fromIsDirectory.boolValue, toIsDirectory.boolValue {
                merge(from: from, into: to, skipping: [], prefix: relative, report: &report)
                // Злили й нічого не лишилося — прибрати порожню теку.
                if let rest = try? fm.contentsOfDirectory(atPath: from.path),
                   rest.allSatisfy({ $0 == ".DS_Store" }) {
                    try? fm.removeItem(at: from)
                }
            } else {
                report.kept.append(relative)
            }
        }
    }
}
