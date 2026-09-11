import Foundation

/// Каталог модулів: обходить теку `Modules` і відкриває все, що там лежить.
public struct ModuleLibrary {

    public struct LoadFailure: Sendable {
        public let directory: String
        public let reason: String
    }

    /// Модулі обох форматів упереміш — зовні різниця не важлива.
    public let modules: [TextModule]
    public let failures: [LoadFailure]
    public let songFiles: [URL]

    /// - Parameter extraModules: шляхи зі списку «Модулі» вікна «Параметри»,
    ///   що лежать поза текою `Modules`. Тека обходиться цілком, а ці
    ///   відкриваються поіменно: без них модуль, доданий кнопкою «+» з
    ///   іншого диска, потрапляв у список налаштувань, але ніколи не відкривався —
    ///   і на смузі перекладів не з'являвся (власник: «переводы Библии не
    ///   добавляются при включении их в модулях»).
    public init(modulesDirectory: URL, extraModules: [URL] = []) {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: modulesDirectory,
                                                   includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []

        var modules: [TextModule] = []
        var failures: [LoadFailure] = []
        var songs: [URL] = []

        let inside = entries.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        // Чужі шляхи — після своїх: за однакового імені перемагає тека
        // програми, а повтор зовні мовчки пропускається.
        let root = modulesDirectory.standardizedFileURL.path
        let outside = extraModules
            .map(\.standardizedFileURL)
            .filter { !$0.path.hasPrefix(root + "/") && $0.path != root }
        var seen: Set<String> = []

        for entry in inside + outside {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            guard seen.insert(entry.lastPathComponent.lowercased()).inserted else { continue }

            if isDirectory {
                do {
                    modules.append(try BibleModule(directory: entry))
                } catch {
                    failures.append(LoadFailure(directory: entry.lastPathComponent, reason: "\(error)"))
                }
                continue
            }

            switch entry.pathExtension.lowercased() {
            case "vbm":
                songs.append(entry)
            case "sqlite3", "sqlite":
                // Супутники модуля MyBible — словники, коментарі, перехресні
                // посилання — лежать поруч і віршів не містять: їх пропускаємо.
                let name = entry.deletingPathExtension().lastPathComponent.lowercased()
                let companions = ["commentaries", "dictionary", "crossreferences", "subheadings", "plan", "notes"]
                guard !companions.contains(where: { name.hasSuffix(".\($0)") }) else { continue }
                do {
                    modules.append(try MyBibleModule(fileAt: entry))
                } catch {
                    failures.append(LoadFailure(directory: entry.lastPathComponent, reason: "\(error)"))
                }
            case "mybible":
                // В одне розширення MySword кладе все підряд, а тип модуля
                // стоїть перед ним. Вірші є лише в `.bbl`; коментарі
                // `.cmt`, словники `.dct`, щоденники `.jor` і особисті нотатки
                // (зовсім без типу) показувати нічим — їх пропускаємо мовчки,
                // як і супутників MyBible рядком вище.
                guard MySwordModule.isBibleModuleName(entry.lastPathComponent) else { continue }
                do {
                    modules.append(try MySwordModule(fileAt: entry))
                } catch {
                    failures.append(LoadFailure(directory: entry.lastPathComponent, reason: "\(error)"))
                }
            default:
                break
            }
        }

        self.modules = modules
        self.failures = failures
        self.songFiles = songs
    }

    public func module(withIdentifier id: String) -> TextModule? {
        modules.first { $0.identifier.caseInsensitiveCompare(id) == .orderedSame }
    }
}
