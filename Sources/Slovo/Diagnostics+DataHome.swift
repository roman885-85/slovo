import Foundation
import SlovoCore

/// Свій дім даних: перенесення з чужого кореня (пакет, VisioBible) —
/// `--check=дім`. Власник: «избавиться от остатков VisioBible».
extension Diagnostics {

    static func dataHomeSection(state: AppState) -> [Check] {
        let area = "Дім даних"
        var checks: [Check] = []
        let fm = FileManager.default

        // Чужий корінь чи свій — за шляхом.
        let foreign = DataHome.isForeign(modulesFolder: URL(fileURLWithPath: "/Users/x/Documents/Слово/Слово.app/Contents/Resources/app/Modules"))
            && DataHome.isForeign(modulesFolder: URL(fileURLWithPath: "/Users/x/Applications/VisioBible.app/Contents/Resources/app/Modules"))
            && !DataHome.isForeign(modulesFolder: DataHome.modules)
            && !DataHome.isForeign(modulesFolder: URL(fileURLWithPath: "/Volumes/Дані/Modules"))
        checks.append(Check(area: area, name: "Чужий корінь упізнається за шляхом",
                            status: foreign ? .ok : .failed,
                            detail: "усередині .app і VisioBible — чужий; свій дім і зовнішня тека — свої"))

        // Тимчасовий «старий корінь» у дусі Resources/app.
        guard let library = state.songLibrary,
              let vbm = library.books.first(where: { $0.url.pathExtension.lowercased() == "vbm" })
                ?? library.books.first else {
            checks.append(Check(area: area, name: "Перенесення з чужого кореня", status: .skipped, detail: "нема жодного пісенника для проби"))
            return checks
        }
        let moduleFolder = ((try? fm.contentsOfDirectory(at: state.modulesFolder, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .first { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-дім-\(UUID().uuidString)")
        let oldRoot = temp.appendingPathComponent("Слово.app/Contents/Resources/app")
        let home = temp.appendingPathComponent("дім")
        defer { try? fm.removeItem(at: temp) }
        var faults: [String] = []
        var lines: [String] = []
        do {
            for name in ["Modules", "BackGrounds", "Templates/Проба", "Language", "Help", "Styles"] {
                try fm.createDirectory(at: oldRoot.appendingPathComponent(name), withIntermediateDirectories: true)
            }
            // Пісенник .vbm або .songbook — як є; .vbi поруч; тека модуля.
            let songSource = vbm.url
            let songCopy = oldRoot.appendingPathComponent("Modules").appendingPathComponent(songSource.lastPathComponent)
            try fm.copyItem(at: songSource, to: songCopy)
            if songSource.pathExtension.lowercased() == "vbm" {
                try Data("index".utf8).write(to: songCopy.deletingPathExtension().appendingPathExtension("vbi"))
            }
            if let moduleFolder {
                try fm.copyItem(at: moduleFolder, to: oldRoot.appendingPathComponent("Modules").appendingPathComponent(moduleFolder.lastPathComponent))
            }
            try Data("jpg".utf8).write(to: oldRoot.appendingPathComponent("BackGrounds/фон.jpg"))
            try Data("sch".utf8).write(to: oldRoot.appendingPathComponent("Templates/Проба/Проба.sch"))
            try Data("lng".utf8).write(to: oldRoot.appendingPathComponent("Language/uk.lng"))
            try Data("chm".utf8).write(to: oldRoot.appendingPathComponent("Help/VisioBible_uk.chm"))
            try Data("vsf".utf8).write(to: oldRoot.appendingPathComponent("Styles/Carbon.vsf"))
            try Data("ini".utf8).write(to: oldRoot.appendingPathComponent("hebrnew.ini"))

            let report = DataHome.migrate(from: oldRoot, into: home)
            lines.append(report.summary)
            let modules = home.appendingPathComponent("Modules")
            let listed = (try? fm.contentsOfDirectory(atPath: modules.path)) ?? []
            let stem = songSource.deletingPathExtension().lastPathComponent
            if !listed.contains(stem + ".songbook") { faults.append("у домі нема \(stem).songbook") }
            if listed.contains(where: { $0.hasSuffix(".vbm") || $0.hasSuffix(".vbi") }) { faults.append("у модулях дому лишилися .vbm/.vbi") }
            let archive = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent(DataHome.importArchiveName).path)) ?? []
            if songSource.pathExtension.lowercased() == "vbm", !(archive.contains(stem + ".vbm") && archive.contains(stem + ".vbi")) {
                faults.append("оригінал .vbm/.vbi не відкладено в «\(DataHome.importArchiveName)»: \(archive)")
            }
            if let moduleFolder, !listed.contains(moduleFolder.lastPathComponent) { faults.append("тека модуля «\(moduleFolder.lastPathComponent)» не переїхала") }
            if !fm.fileExists(atPath: home.appendingPathComponent("BackGrounds/фон.jpg").path) { faults.append("фон не переїхав") }
            if !fm.fileExists(atPath: home.appendingPathComponent("Templates/Проба/Проба.sch").path) { faults.append("шаблон не переїхав") }
            for stranger in ["Language", "Help", "Styles", "hebrnew.ini"] where fm.fileExists(atPath: home.appendingPathComponent(stranger).path) {
                faults.append("«\(stranger)» переїхало, хоч не мало")
            }
            // Прочитати перетворений збірник тією самою бібліотекою.
            let small = SongLibrary(modulesDirectory: modules)
            if small.books.count != 1 || small.book(small.books[0].id)?.songs.isEmpty != false {
                faults.append("бібліотека в домі не відкрила перетворений збірник")
            }
            if small.entry(fileName: stem + ".vbm")?.id != stem { faults.append("за старим ім'ям .vbm збірник у домі не знаходиться") }
            // Удруге — нічого не копіює й не перетворює.
            let again = DataHome.migrate(from: oldRoot, into: home)
            let copiedAgain = again.copied.values.reduce(0, +)
            if copiedAgain != 0 || again.converted != 0 { faults.append("повторне перенесення скопіювало \(copiedAgain), перетворило \(again.converted)") }
            lines.append("удруге: нічого нового")
        } catch {
            faults.append("\(error)")
        }
        checks.append(Check(area: area, name: "Перенесення з чужого кореня у свій дім",
                            status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; ")))

        // Свій дім у самій програмі: тека модулів — не в пакеті.
        let own = !DataHome.isForeign(modulesFolder: state.modulesFolder)
        checks.append(Check(area: area, name: "Тека модулів програми — не всередині пакета",
                            status: own ? .ok : .failed, detail: state.modulesFolder.path))
        return checks
    }
}
