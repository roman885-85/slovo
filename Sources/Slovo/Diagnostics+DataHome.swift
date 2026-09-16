import AppKit
import SlovoCore

/// Дім даних поза пакетом — `--check=дім`.
///
/// Власник 15.09.2026: «Application Support пусть будет там все». До 0.94
/// модулі й ресурси лежали в пакеті, і помічник оновлення, перенісши їх у
/// новий пакет, підписував його заново — macOS щоразу забувала дозвіл на
/// запис екрана. Тепер у пакеті лише умовчання, а все людське — у
/// `DataHome.folder`; сюди ж перевіряємо перенесення (`DataMigration`) і те,
/// що повна адреса написана в довідці й налаштуваннях.
extension Diagnostics {

    static func dataHomeSection(state: AppState) -> [Check] {
        let area = "Дім даних"
        var checks: [Check] = []
        let fm = FileManager.default

        // 1. Тека модулів — у домі даних, а не в пакеті (свою людина може
        //    вибрати сама: тоді дивимося лише, що вона читається).
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/app")
        let folder = state.modulesFolder
        let readable = fm.fileExists(atPath: folder.path)
        let chosen = Defaults.modulesFolder != nil
        let underBundle = folder.standardizedFileURL.path.hasPrefix(inBundle.standardizedFileURL.path)
        checks.append(Check(area: area, name: "Тека модулів — у домі даних, не в пакеті",
                            status: readable && (chosen || !underBundle) ? .ok : .failed,
                            detail: folder.path + (chosen ? " (теку вибрала людина)" : "") + "; дім даних: " + DataHome.displayPath))

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

        // 3a. Даних у пакеті не лишилося: усе переніс `DataMigration` на
        //     старті. Поки щось лежить, оновлення мусило б це везти й
        //     переписувати підпис — а з ним і дозволи macOS.
        let leftovers = DataMigration.unmigratedBundleItems(bundleData: DataHome.bundleData)
        checks.append(Check(area: area, name: "У пакеті нема даних — оновленню нічого нести",
                            status: leftovers.isEmpty ? .ok : .failed,
                            detail: leftovers.isEmpty
                                ? "у Contents/Resources/app лише умовчання; перенесено на старті: " + DataMigration.lastReport.summary
                                : "лишилося в пакеті: " + leftovers.joined(separator: ", ")))

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
        checks += migrationChecks(state: state)
        return checks
    }

    /// Чи написано рядок на сторінці: у підписі, у полі чи в підказці.
    private static func writtenSomewhere(_ text: String, in view: NSView) -> Bool {
        if let field = view as? NSTextField, field.stringValue.contains(text) { return true }
        if view.toolTip?.contains(text) == true { return true }
        return view.subviews.contains { writtenSomewhere(text, in: $0) }
    }

    /// Перенесення даних із пакета в дім даних на вигаданих теках: нічого не
    /// перезаписується, зайвого не лишається, а повна адреса написана там, де
    /// власник просив її бачити, — у налаштуваннях і в довідці.
    private static func migrationChecks(state: AppState) -> [Check] {
        let area = "Дім даних"
        var checks: [Check] = []
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-перенесення-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        var faults: [String] = []
        var lines: [String] = []
        do {
            let bundle = temp.appendingPathComponent("Слово.app/Contents/Resources/app")
            let home = temp.appendingPathComponent("дім")
            // У пакеті: модулі, фони, умовчання. У домі: свій фон із тим
            // самим іменем і свої налаштування — їх чіпати не можна.
            try fm.createDirectory(at: bundle.appendingPathComponent("Modules/rst+"), withIntermediateDirectories: true)
            try Data("ini".utf8).write(to: bundle.appendingPathComponent("Modules/rst+/bibleqt.ini"))
            try fm.createDirectory(at: bundle.appendingPathComponent("BackGrounds"), withIntermediateDirectories: true)
            try Data("пакет".utf8).write(to: bundle.appendingPathComponent("BackGrounds/Black.jpg"))
            try Data("пакет".utf8).write(to: bundle.appendingPathComponent("BackGrounds/Cross.jpg"))
            try Data("умовчання".utf8).write(to: bundle.appendingPathComponent("Slovo.ini"))
            // Залишок VisioBible у пакеті: мови `.lng`. Наші виправлені
            // переклади лежать удома в теці з тим самим іменем — злити їх
            // не можна, у списку мов з'явилося б чуже.
            try fm.createDirectory(at: bundle.appendingPathComponent("Language"), withIntermediateDirectories: true)
            try Data("чуже".utf8).write(to: bundle.appendingPathComponent("Language/Ukrainian.lng"))
            try fm.createDirectory(at: home.appendingPathComponent("Language"), withIntermediateDirectories: true)
            try Data("своє".utf8).write(to: home.appendingPathComponent("Language/uk.lng"))
            try fm.createDirectory(at: home.appendingPathComponent("BackGrounds"), withIntermediateDirectories: true)
            try Data("людське".utf8).write(to: home.appendingPathComponent("BackGrounds/Black.jpg"))
            try Data("людські".utf8).write(to: home.appendingPathComponent("settings.json"))

            let report = DataMigration.run(target: home, bundleData: bundle)
            lines.append(report.summary)
            if !fm.fileExists(atPath: home.appendingPathComponent("Modules/rst+/bibleqt.ini").path) { faults.append("модулі не переїхали") }
            if !fm.fileExists(atPath: home.appendingPathComponent("BackGrounds/Cross.jpg").path) { faults.append("новий фон із пакета не переїхав") }
            let kept = (try? String(contentsOf: home.appendingPathComponent("BackGrounds/Black.jpg"), encoding: .utf8)) ?? ""
            if kept != "людське" { faults.append("однойменний фон перезаписано пакетним («\(kept)»)") }
            if !fm.fileExists(atPath: home.appendingPathComponent("settings.json").path) { faults.append("налаштування зникли") }
            if !fm.fileExists(atPath: bundle.appendingPathComponent("Slovo.ini").path) { faults.append("умовчання забрали з пакета") }
            if fm.fileExists(atPath: bundle.appendingPathComponent("Modules").path) { faults.append("модулі лишилися і в пакеті") }
            // Помічнику оновлення нести більше нічого: усе, чого дім не мав,
            // переїхало, а однойменне (людське) вдома й так новіше.
            let rest = DataMigration.unmigratedBundleItems(bundleData: bundle, target: home)
            if !rest.isEmpty { faults.append("після перенесення лишилося нести: \(rest)") }
            if !fm.fileExists(atPath: bundle.appendingPathComponent("BackGrounds/Black.jpg").path) {
                faults.append("однойменний файл забрали з пакета замість того, щоб лишити")
            }
            let languages = (try? fm.contentsOfDirectory(atPath: home.appendingPathComponent("Language").path))?.sorted() ?? []
            if languages != ["uk.lng"] { faults.append("у теці мов з'явилося чуже з пакета: \(languages)") }
            // Другий прогін нічого не робить — крім того, що вже лежало вдома.
            let again = DataMigration.run(target: home, bundleData: bundle)
            if !again.moved.isEmpty || !again.copied.isEmpty { faults.append("удруге щось перенесло: \(again.summary)") }
        } catch {
            faults.append("\(error)")
        }
        checks.append(Check(area: area, name: "Дані з пакета переїжджають у дім і нічого не затирають",
                            status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; ")))

        // Повна адреса — там, де власник просив: у «Параметри → Шляхи» і в довідці.
        let path = DataHome.displayPath
        let root = NativeSettingsWindow.shared.build(state: state)
        let stand = bench(for: root, size: NSSize(width: 880, height: 640))
        var written = false
        if let tabs = root.subviews.compactMap({ $0 as? NSTabView }).first,
           let index = tabs.tabViewItems.firstIndex(where: { ($0.identifier as? String) == state.vb("TSPath", "Пути") }) {
            tabs.selectTabViewItem(at: index)
            root.layoutSubtreeIfNeeded()
            written = tabs.tabViewItems[index].view.map { writtenSomewhere(path, in: $0) } ?? false
        }
        stand.orderOut(nil)
        NativeSettingsWindow.shared.discard()
        checks.append(Check(area: area, name: "У «Параметрах → Шляхи» написано повну адресу даних",
                            status: written ? .ok : .failed,
                            detail: written ? path : "адреси на сторінці немає"))
        let help = NativeHelpWindow.page(language: "uk", topic: "data") ?? ""
        let helpEn = NativeHelpWindow.page(language: "en", topic: "data") ?? ""
        let inHelp = help.contains(path) && helpEn.contains(path) && !help.contains("{{DATA}}")
        checks.append(Check(area: area, name: "У довідці обома мовами написано повну адресу даних",
                            status: inHelp ? .ok : .failed,
                            detail: inHelp ? "розділ «Де лежать дані»: " + path : "адреса не підставилася"))
        return checks
    }
}
