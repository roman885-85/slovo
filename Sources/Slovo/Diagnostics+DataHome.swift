import Foundation
import SlovoCore

/// Дані в пакеті, без залишків VisioBible — `--check=дім`.
/// Власник: «все переводы и модули внутри пакета всегда» і «избавиться от
/// остатков VisioBible».
extension Diagnostics {

    static func dataHomeSection(state: AppState) -> [Check] {
        let area = "Дім даних"
        var checks: [Check] = []
        let fm = FileManager.default

        // 1. Тека модулів програми існує й читається; у пакеті з даними — саме в пакеті.
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app/Modules")
        let folder = state.modulesFolder
        let readable = fm.fileExists(atPath: folder.path)
        let expectedInBundle = fm.fileExists(atPath: inBundle.path) && Defaults.modulesFolder == nil
        let placed = !expectedInBundle || folder.standardizedFileURL.path == inBundle.standardizedFileURL.path
        checks.append(Check(area: area, name: "Тека модулів: у пакеті, коли пакет має дані",
                            status: readable && placed ? .ok : .failed,
                            detail: folder.path + (expectedInBundle ? " (пакет має Modules — беремо їх)" : " (у пакеті даних нема — свій дім)")))

        // 2. Залишків VisioBible у пакеті нема.
        let app = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app")
        let junk = ["Help", "Language", "Styles", "ScreenShots", "fonts_correct.ini", "hebrnew.ini", "shortnames.json"]
            .filter { fm.fileExists(atPath: app.appendingPathComponent($0).path) }
        checks.append(Check(area: area, name: "У пакеті нема залишків VisioBible",
                            status: junk.isEmpty ? .ok : .failed,
                            detail: junk.isEmpty ? "Help, Language, Styles, ScreenShots і службові ini відсутні"
                                : "лишилося: " + junk.joined(separator: ", ")))

        // 3. Своє в пакеті на місці.
        let own = ["Slovo.ini", "hotkeys.ini", "ЧИТАТИ.md"].filter { !fm.fileExists(atPath: app.appendingPathComponent($0).path) }
        checks.append(Check(area: area, name: "Своє в пакеті: умовчання, клавіші, довідка",
                            status: own.isEmpty ? .ok : .failed,
                            detail: own.isEmpty ? "Slovo.ini, hotkeys.ini, ЧИТАТИ.md є" : "бракує: " + own.joined(separator: ", ")))

        // Фони за умовчанням — як у повній збірці власника (15.09): загальний —
        // хрест, фон слайда — Black.jpg; файли — у BackGrounds ресурсів.
        let defaultsName = "Фони за умовчанням — як у повній збірці (хрест і Black.jpg)"
        if let url = IniSettings.locateConfig(), let ini = try? IniSettings(fileAt: url) {
            let common = ini.string("CommonBackgrFileName", in: "settings") ?? ""
            let slide = ini.string("SlideBackgrFileName", in: "settings") ?? ""
            let root = state.modulesFolder.deletingLastPathComponent()
            func present(_ relative: String) -> Bool {
                !relative.isEmpty && fm.fileExists(atPath: root.appendingPathComponent(relative.replacingOccurrences(of: "\\", with: "/")).path)
            }
            var trouble: [String] = []
            if common != "BackGrounds\\606958597094a-depositphotos_9766771_xl-2015.jpg" { trouble.append("загальний фон «\(common)»") }
            if slide != "BackGrounds\\Black.jpg" { trouble.append("фон слайда «\(slide)»") }
            let filesNote = present(common) && present(slide) ? "файли на місці в \(root.lastPathComponent)"
                : "файлів у теці даних нема (збірка «лише програма» до завантаження фонів)"
            checks.append(Check(area: area, name: defaultsName, status: trouble.isEmpty ? .ok : .failed,
                                detail: trouble.isEmpty ? "у Slovo.ini: \(common), \(slide); \(filesNote); зараз: загальний «\((state.commonBackgroundPath as NSString?)?.lastPathComponent ?? "—")», слайда «\((state.slideBackgroundPath as NSString?)?.lastPathComponent ?? "—")»"
                                                        : trouble.joined(separator: "; ")))
        } else {
            checks.append(Check(area: area, name: defaultsName, status: .skipped, detail: "Slovo.ini не знайдено"))
        }
        // 4. Пісенники .vbm у теці модулів → .songbook один раз; оригінали — в архів.
        // Джерело — збірник, який бібліотека справді відкриває (у власника є
        // битий UNTTP.vbm — його не беремо); `.vbm` для проби збираємо самі.
        wait(untilTrue: { state.songLibrary != nil && !state.isLoadingLibrary }, seconds: 10)
        guard let library = state.songLibrary,
              let sample = library.books.first(where: { library.book($0.id)?.songs.isEmpty == false }) else {
            checks.append(Check(area: area, name: "Пісенники VisioBible переводяться у .songbook на місці", status: .skipped, detail: "нема пісенника для проби"))
            return checks
        }
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-дім-\(UUID().uuidString)")
        let modules = temp.appendingPathComponent("app/Modules")
        defer { try? fm.removeItem(at: temp) }
        var faults: [String] = []
        var lines: [String] = []
        do {
            try fm.createDirectory(at: modules, withIntermediateDirectories: true)
            let stem = sample.url.deletingPathExtension().lastPathComponent
            let vbm = modules.appendingPathComponent(stem + ".vbm")
            guard let book = library.book(sample.id) else { throw SongBookError.damaged(stem) }
            try SongBookWriter.data(for: book).write(to: vbm)
            try Data("index".utf8).write(to: modules.appendingPathComponent(stem + ".vbi"))
            var report = DataHome.Report(source: modules.path)
            DataHome.convertSongBooks(in: modules, archive: temp.appendingPathComponent("app/\(DataHome.importArchiveName)"), report: &report)
            lines.append(report.summary)
            let listed = (try? fm.contentsOfDirectory(atPath: modules.path)) ?? []
            if !listed.contains(stem + ".songbook") { faults.append("нема \(stem).songbook") }
            if listed.contains(where: { $0.hasSuffix(".vbm") || $0.hasSuffix(".vbi") }) { faults.append("у теці модулів лишилися .vbm/.vbi") }
            let archived = (try? fm.contentsOfDirectory(atPath: temp.appendingPathComponent("app/\(DataHome.importArchiveName)").path)) ?? []
            if !(archived.contains(stem + ".vbm") && archived.contains(stem + ".vbi")) { faults.append("оригінали не в архіві: \(archived)") }
            let small = SongLibrary(modulesDirectory: modules)
            if small.books.count != 1 || small.book(small.books[0].id)?.songs.isEmpty != false { faults.append("бібліотека не відкрила .songbook") }
            if small.entry(fileName: stem + ".vbm")?.id != stem { faults.append("за старим ім'ям .vbm не знаходиться") }
            var again = DataHome.Report(source: modules.path)
            DataHome.convertSongBooks(in: modules, archive: temp.appendingPathComponent("app/\(DataHome.importArchiveName)"), report: &again)
            if again.converted != 0 || again.archived != 0 { faults.append("удруге щось перетворило: \(again.summary)") }
        } catch {
            faults.append("\(error)")
        }
        checks.append(Check(area: area, name: "Пісенники VisioBible переводяться у .songbook на місці",
                            status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; ")))
        return checks
    }
}
