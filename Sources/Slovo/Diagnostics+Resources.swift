import Foundation
import SlovoCore

/// Ресурси з GitHub без мережі — `--check=ресурси`: каталог туди й назад,
/// розбір `modules.ini` «Цитати з Біблії», установлення zip-а з диска
/// (`file://` — той самий шлях, що й з мережі) у тимчасову теку модулів,
/// журнал версій і стан «є / оновлення».
extension Diagnostics {

    static func resourcesSection(state: AppState) -> [Check] {
        let area = "Ресурси"
        var checks: [Check] = []
        let fm = FileManager.default

        // 1. Каталог: запис і читання.
        let sample = ResourceCatalog(updated: "2026-09-14", items: [
            ResourceItem(id: "bible:X", kind: .bible, title: "Проба", subtitle: "X", size: 10, version: "2026-09-14",
                         url: "https://example.com/module-X.zip", fileName: "X"),
        ])
        var round = false
        if let data = try? sample.encoded(), let back = try? ResourceCatalog.decode(data) {
            round = back.items == sample.items && back.updated == sample.updated
        }
        let bad = (try? ResourceCatalog.decode(Data("{\"format\":\"other\",\"updated\":\"\",\"items\":[]}".utf8))) == nil
        checks.append(Check(area: area, name: "Каталог ресурсів пишеться й читається", status: round && bad ? .ok : .failed,
                            detail: round ? "туди й назад без змін; чужий формат відхилено" : "розбіжність після читання"))

        // 2. modules.ini «Цитати з Біблії».
        let ini = "\u{FEFF}[Bible_English_KJV-1769_2019-05-30]\nModuleName=The Bible (KJV 1769)\nModuleAuthor=KJV\n\n[Dictionary_X]\nModuleName=Словник\n\n[Bible_Russian_RST]\nModuleName=Синодальный\n"
        let quote = ResourceCatalog.bibleQuote(ini: ini, base: ResourceHub.bibleQuoteBase)
        let quoteOK = quote.items.count == 2 && quote.items[0].title == "The Bible (KJV 1769)"
            && quote.items[0].url.hasSuffix("modules/Bible_English_KJV-1769_2019-05-30.zip")
            && quote.items[1].fileName == "Bible_Russian_RST" && quote.items.allSatisfy { $0.kind == .bible }
        checks.append(Check(area: area, name: "modules.ini «Цитати з Біблії» розбирається", status: quoteOK ? .ok : .failed,
                            detail: "\(quote.items.count) Біблії (словник пропущено): " + quote.items.map(\.title).joined(separator: ", ")))

        // 3. Установлення з диска: модуль із теки модулів → zip → у тимчасову теку.
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-ресурси-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let name = "Установлення zip кладе модуль у теку модулів і веде журнал версій"
        guard let module = state.allModules.first(where: { $0.format == .bibleQuote }),
              let sourceFolder = ((try? fm.contentsOfDirectory(at: state.modulesFolder, includingPropertiesForKeys: nil)) ?? [])
                .first(where: { $0.lastPathComponent.caseInsensitiveCompare(module.identifier) == .orderedSame }) else {
            checks.append(Check(area: area, name: name, status: .skipped, detail: "нема модуля «Цитата з Біблії» для проби"))
            return checks
        }
        var faults: [String] = []
        var lines: [String] = []
        do {
            let zips = temp.appendingPathComponent("zips"), home = temp.appendingPathComponent("app/Modules")
            try fm.createDirectory(at: zips, withIntermediateDirectories: true)
            try fm.createDirectory(at: home, withIntermediateDirectories: true)
            let zip = zips.appendingPathComponent("module.zip")
            let ditto = Process()
            ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            ditto.arguments = ["-c", "-k", "--keepParent", "--norsrc", sourceFolder.path, zip.path]
            try ditto.run(); ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else { throw ResourceError.unpack("ditto \(ditto.terminationStatus)") }
            let item = ResourceItem(id: "bible:" + module.identifier, kind: .bible, title: module.info.name,
                                    version: "2026-09-14", url: zip.absoluteString, fileName: sourceFolder.lastPathComponent)
            let hub = ResourceHub(layout: ResourceLayout(modulesFolder: home))
            let ledgerBefore = ResourceLedger.load()
            defer { ledgerBefore.save() }   // журнал — спільний файл, вертаємо як було
            var outcome: ResourceHub.Outcome?
            let done = DispatchSemaphore(value: 0)
            hub.install([item], progress: { _ in }, completion: { result in outcome = result; done.signal() })
            let deadline = Date().addingTimeInterval(30)
            while done.wait(timeout: .now() + 0.1) == .timedOut && Date() < deadline {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
            }
            guard let outcome else { throw ResourceError.network("час вийшов") }
            if outcome.installed.count != 1 { faults.append("не встановлено: " + outcome.failures.map { $0.1 }.joined(separator: "; ")) }
            let placed = home.appendingPathComponent(sourceFolder.lastPathComponent)
            if !fm.fileExists(atPath: placed.appendingPathComponent("bibleqt.ini").path) { faults.append("bibleqt.ini не на місці") }
            let opened = ModuleLibrary(modulesDirectory: home)
            if opened.modules.count != 1 { faults.append("бібліотека в теці бачить \(opened.modules.count) модулів") }
            let ledger = ResourceLedger.load()
            if ledger.installed[item.id] != "2026-09-14" { faults.append("журнал версій не записав ресурс") }
            if !hub.layout.isPresent(item) { faults.append("isPresent не бачить установлене") }
            lines.append("модуль «\(module.info.name)» через zip: на місці, у журналі версія 2026-09-14")
        } catch {
            faults.append("\(error)")
        }
        checks.append(Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                            detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; ")))

        // 4. Оновлення програми: помічник переносить дані зі старого пакета
        //    в новий («лише програма») і підмінює пакет.
        do {
            let root = temp.appendingPathComponent("оновлення")
            let old = root.appendingPathComponent("Слово.app")
            let staging = root.appendingPathComponent(".slovo-update-проба")
            let fresh = staging.appendingPathComponent("Слово.app")
            for (bundle, marker) in [(old, "стара"), (fresh, "нова")] {
                try fm.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
                try Data(marker.utf8).write(to: bundle.appendingPathComponent("Contents/MacOS/Slovo"))
                // Помічник перевіряє, що новий пакет має виконуваний файл.
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bundle.appendingPathComponent("Contents/MacOS/Slovo").path)
                try fm.createDirectory(at: bundle.appendingPathComponent("Contents/Resources/app"), withIntermediateDirectories: true)
                try Data(marker.utf8).write(to: bundle.appendingPathComponent("Contents/Resources/app/Slovo.ini"))
            }
            try fm.createDirectory(at: old.appendingPathComponent("Contents/Resources/app/Modules/rst+"), withIntermediateDirectories: true)
            try Data("ini".utf8).write(to: old.appendingPathComponent("Contents/Resources/app/Modules/rst+/bibleqt.ini"))
            try fm.createDirectory(at: old.appendingPathComponent("Contents/Resources/app/Templates"), withIntermediateDirectories: true)
            let script = AppUpdater.helperScript(pid: 999_999, bundle: old, fresh: fresh, staging: staging, relaunch: false)
            let file = root.appendingPathComponent("replace.sh")
            try script.write(to: file, atomically: true, encoding: .utf8)
            let run = Process()
            run.executableURL = URL(fileURLWithPath: "/bin/sh")
            run.arguments = [file.path]
            try run.run(); run.waitUntilExit()
            var trouble: [String] = []
            let binary = (try? String(contentsOf: old.appendingPathComponent("Contents/MacOS/Slovo"), encoding: .utf8)) ?? ""
            if binary != "нова" { trouble.append("пакет не підмінено (\(binary))") }
            if !fm.fileExists(atPath: old.appendingPathComponent("Contents/Resources/app/Modules/rst+/bibleqt.ini").path) { trouble.append("модулі не перейшли в новий пакет") }
            if !fm.fileExists(atPath: old.appendingPathComponent("Contents/Resources/app/Templates").path) { trouble.append("шаблони не перейшли") }
            let ini = (try? String(contentsOf: old.appendingPathComponent("Contents/Resources/app/Slovo.ini"), encoding: .utf8)) ?? ""
            if ini != "нова" { trouble.append("умовчання не з нового пакета") }
            if fm.fileExists(atPath: staging.path) || fm.fileExists(atPath: old.path + ".old") { trouble.append("лишилися тимчасові теки") }
            // Нового пакета нема (теку стерли) — старий лишається цілим на місці.
            let lost = root.appendingPathComponent(".slovo-update-стерта/Слово.app")
            let second = AppUpdater.helperScript(pid: 999_999, bundle: old, fresh: lost,
                                                 staging: lost.deletingLastPathComponent(), relaunch: false)
            let file2 = root.appendingPathComponent("replace2.sh")
            try second.write(to: file2, atomically: true, encoding: .utf8)
            let run2 = Process()
            run2.executableURL = URL(fileURLWithPath: "/bin/sh")
            run2.arguments = [file2.path]
            run2.standardError = FileHandle.nullDevice
            try run2.run(); run2.waitUntilExit()
            let kept = (try? String(contentsOf: old.appendingPathComponent("Contents/MacOS/Slovo"), encoding: .utf8)) ?? ""
            if kept != "нова" || !fm.fileExists(atPath: old.appendingPathComponent("Contents/Resources/app/Modules/rst+/bibleqt.ini").path) {
                trouble.append("без нового пакета старий не лишився цілим")
            }
            checks.append(Check(area: area, name: "Оновлення програми зберігає переклади й дані пакета",
                                status: trouble.isEmpty ? .ok : .failed,
                                detail: trouble.isEmpty ? "новий пакет на місці, Modules і Templates перейшли зі старого, Slovo.ini — нове; без нового пакета старий лишається цілим" : trouble.joined(separator: "; ")))
        } catch {
            checks.append(Check(area: area, name: "Оновлення програми зберігає переклади й дані пакета", status: .failed, detail: "\(error)"))
        }

        // 5. Вміст архіву знаходиться, хоч би як його запакували (баг 0.8:
        //    «Modules/pv3055.songbook» лягав текою), і вже зіпсоване лагодиться.
        do {
            let root = temp.appendingPathComponent("архіви")
            func make(_ name: String, _ files: [String]) throws -> URL {
                let folder = root.appendingPathComponent(name)
                for file in files {
                    let url = folder.appendingPathComponent(file)
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try Data("x".utf8).write(to: url)
                }
                return folder
            }
            func item(_ file: String, _ kind: ResourceItem.Kind = .songbook) -> ResourceItem {
                ResourceItem(id: file, kind: kind, title: file, url: "file:///x.zip", fileName: file)
            }
            var trouble: [String] = []
            func expect(_ result: ResourceHub.Payload?, _ tail: String, files: Bool = false, _ label: String) {
                switch result {
                case .item(let url)? where !files && url.path.hasSuffix(tail): break
                case .files(let url)? where files && url.path.hasSuffix(tail): break
                default: trouble.append("\(label): \(String(describing: result))")
                }
            }
            expect(ResourceHub.payload(in: try make("обгортка", ["Modules/pv3055.songbook"]), for: item("pv3055.songbook")),
                   "Modules/pv3055.songbook", "пісенник у теці-обгортці")
            expect(ResourceHub.payload(in: try make("просто", ["pv3055.songbook"]), for: item("pv3055.songbook")),
                   "просто/pv3055.songbook", "пісенник без обгортки")
            expect(ResourceHub.payload(in: try make("mybible", [".SQLite3"]), for: item("AGP.SQLite3", .bible)),
                   "mybible/.SQLite3", "безіменний .SQLite3 MyBible")
            expect(ResourceHub.payload(in: try make("mysword", ["Modules/UKJV.bbl.mybible"]), for: item("UKJV.bbl.mybible", .bible)),
                   "Modules/UKJV.bbl.mybible", "MySword у теці-обгортці")
            expect(ResourceHub.payload(in: try make("bq-файли", ["bibleqt.ini", "01.htm"]), for: item("Bible_X", .bible)),
                   "bq-файли", files: true, "файли «Цитати з Біблії» без теки")
            expect(ResourceHub.payload(in: try make("bq-тека", ["rst+/bibleqt.ini", "rst+/01.htm"]), for: item("rst+", .bible)),
                   "bq-тека/rst+", "тека «Цитати з Біблії»")
            // Лагодження: тека «a.songbook/» з файлом «a.songbook».
            let broken = try make("зіпсоване", ["a.songbook/a.songbook", "UKJV.bbl.mybible/UKJV.bbl.mybible", "rst+/bibleqt.ini"])
            let fixed = DataHome.repairNestedModules(in: broken)
            var isDir: ObjCBool = false
            if fixed != 2 { trouble.append("полагоджено \(fixed) замість 2") }
            if !(fm.fileExists(atPath: broken.appendingPathComponent("a.songbook").path, isDirectory: &isDir) && !isDir.boolValue) {
                trouble.append("a.songbook не став файлом")
            }
            if !fm.fileExists(atPath: broken.appendingPathComponent("rst+/bibleqt.ini").path) { trouble.append("звичайну теку модуля зачепило") }
            checks.append(Check(area: area, name: "Вміст архіву знаходиться за будь-якого пакування; тека замість файла лагодиться",
                                status: trouble.isEmpty ? .ok : .failed,
                                detail: trouble.isEmpty ? "обгортка «Modules/», безіменний .SQLite3, MySword, «Цитата з Біблії» текою й файлами; полагоджено 2" : trouble.joined(separator: "; ")))
        } catch {
            checks.append(Check(area: area, name: "Вміст архіву знаходиться за будь-якого пакування; тека замість файла лагодиться", status: .failed, detail: "\(error)"))
        }

        // 6. Список модулів у налаштуваннях зводиться з тим, що є на диску.
        do {
            let root = temp.appendingPathComponent("реєстр")
            let modules = root.appendingPathComponent("Modules")
            try fm.createDirectory(at: modules.appendingPathComponent("rst+"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: modules.appendingPathComponent("pv3055.songbook"))
            try fm.createDirectory(at: modules.appendingPathComponent("Новий"), withIntermediateDirectories: true)
            let store = SettingsStore.shared
            let saved = store.settings.modules
            defer { store.settings.modules = saved }
            store.settings.modules = [
                ModuleRosterEntry(path: "Modules\\rst+\\", name: "rst+", isEnabled: true),
                ModuleRosterEntry(path: "Modules\\UA_Ogienko\\", name: "UA_Ogienko", isEnabled: true),
                ModuleRosterEntry(path: "Modules\\pv3055.vbm", name: "pv3055.vbm", isEnabled: false),
                ModuleRosterEntry(path: "/Volumes/Зовнішній/Modules/KJV/", name: "KJV", isEnabled: true),
            ]
            let changed = store.syncModuleRoster(libraryIdentifiers: ["rst+", "новий"], songBookStems: ["pv3055"],
                                                 modulesFolder: modules, dataRoot: root)
            let names = store.settings.modules.map(\.name)
            let songbook = store.settings.modules.first { $0.name == "pv3055.songbook" }
            let ok = changed && names == ["rst+", "pv3055.songbook", "KJV", "Новий"] && songbook?.isEnabled == false
                && songbook?.path == "Modules\\pv3055.songbook"
            checks.append(Check(area: area, name: "Список модулів у налаштуваннях — за тим, що є на диску", status: ok ? .ok : .failed,
                                detail: "стало: " + store.settings.modules.map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
                                    + " — зник UA_Ogienko без файла, pv3055.vbm → .songbook із тією самою галочкою, зовнішній KJV лишився, «Новий» додано"))
        } catch {
            checks.append(Check(area: area, name: "Список модулів у налаштуваннях — за тим, що є на диску", status: .failed, detail: "\(error)"))
        }

        // 7. Застарілі повні шляхи картинок знаходяться в поточних теках даних.
        do {
            let root = temp.appendingPathComponent("дані")
            try fm.createDirectory(at: root.appendingPathComponent("BackGrounds"), withIntermediateDirectories: true)
            try fm.createDirectory(at: root.appendingPathComponent("Templates/Autumn"), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: root.appendingPathComponent("BackGrounds/Black.jpg"))
            try Data("x".utf8).write(to: root.appendingPathComponent("Templates/Autumn/Осень3.jpg"))
            let saved = DataPaths.roots
            defer { DataPaths.roots = saved }
            DataPaths.roots = [root]
            let a = DataPaths.existing("/Users/нікого/Desktop/Слово.app/Contents/Resources/app/BackGrounds/Black.jpg")
            let b = DataPaths.existing("/Users/нікого/Desktop/Слово/Слово.app/Contents/Resources/app/Templates/Autumn/Осень3.jpg")
            let c = DataPaths.existing("/Інше/місце/BackGrounds/Black.jpg")
            let d = DataPaths.existing("/Users/нікого/Desktop/Слово.app/Contents/Resources/app/BackGrounds/нема.jpg")
            let ok = a?.hasSuffix("дані/BackGrounds/Black.jpg") == true && b?.hasSuffix("дані/Templates/Autumn/Осень3.jpg") == true
                && c?.hasSuffix("дані/BackGrounds/Black.jpg") == true && d == nil
            checks.append(Check(area: area, name: "Фони й картинки шаблонів знаходяться за застарілим повним шляхом", status: ok ? .ok : .failed,
                                detail: "фон із пакета на Робочому столі → \(a ?? "нема"); картинка шаблону зі старої теки → \(b ?? "нема"); неіснуючий → \(d ?? "нема")"))
        } catch {
            checks.append(Check(area: area, name: "Фони й картинки шаблонів знаходяться за застарілим повним шляхом", status: .failed, detail: "\(error)"))
        }

        // 8. Адреси реєстру MyBible не кодуються вдруге (404 на «UBIO'62», «ФІЛ»).
        let registry = Data(#"""
        {"version": 1, "hosts": [{"alias": "mz", "path": "https://mybible.zone/repository/modules/%s.zip", "priority": 1}],
         "downloads": [{"abr": "UBIO'62", "fil": "UBIO'62", "lng": "uk", "url": ["{mz}UBIO%2762"], "siz": "2.1M"},
                       {"abr": "ФІЛ", "fil": "ФІЛ", "lng": "uk", "url": ["{mz}%D0%A4%D0%86%D0%9B"], "siz": "2.5M"},
                       {"abr": "AGP", "fil": "AGP", "lng": "ru", "url": ["{mz}AGP"], "siz": "589K",
                        "des": "Біблія. Новий переклад УБТ Рафаїла Турконяка (1997-2007)\n76 книг"}]}
        """#.utf8)
        let links = ResourceCatalog.myBible(registry: registry)?.items.map(\.url) ?? []
        let wanted = ["https://mybible.zone/repository/modules/UBIO%2762.zip",
                      "https://mybible.zone/repository/modules/%D0%A4%D0%86%D0%9B.zip",
                      "https://mybible.zone/repository/modules/AGP.zip"]
        checks.append(Check(area: area, name: "Адреси реєстру MyBible не кодуються вдруге", status: links == wanted ? .ok : .failed,
                            detail: links.joined(separator: " · ")))
        let joinedTitle = ResourceCatalog.myBible(registry: registry)?.items.last?.title ?? ""
        checks.append(Check(area: area, name: "Назва з реєстру MyBible — в один рядок",
                            status: joinedTitle == "Біблія. Новий переклад УБТ Рафаїла Турконяка (1997-2007) 76 книг" ? .ok : .failed,
                            detail: "«\(joinedTitle.replacingOccurrences(of: "\n", with: "⏎"))»"))

        // 9. Опис випуску без Markdown.
        let plain = AppUpdater.plain("## Що нового\n- **Пісенники** — [slovo-resources](https://github.com/x) і `.songbook`")
        checks.append(Check(area: area, name: "Опис випуску у вікні — без розмітки Markdown",
                            status: plain.contains("**") || plain.contains("](") || plain.contains("##") || plain.contains("`") ? .failed : .ok,
                            detail: plain.replacingOccurrences(of: "\n", with: " / ")))
        let wrapped = AppUpdater.plain("Оновлення 0.85 — лише програма. Ставиться з 0.84 (з 0.82\nі 0.83 —\nлише вручну).\n\n## Що нового\n\n- **Вставка** працює: у меню\n  з'явився розділ.\n- Друге.\n1. Крок\n   далі.\nКінець абзацу\n")
        let wrappedWanted = "Оновлення 0.85 — лише програма. Ставиться з 0.84 (з 0.82 і 0.83 — лише вручну).\n\nЩо нового\n\n- Вставка працює: у меню з'явився розділ.\n- Друге.\n1. Крок далі. Кінець абзацу"
        checks.append(Check(area: area, name: "Опис випуску у вікні — абзаци без ручних переносів",
                            status: wrapped == wrappedWanted ? .ok : .failed,
                            detail: wrapped.replacingOccurrences(of: "\n", with: " / ")))

        // 10. Версії програми порівнюються як десяткові.
        let versions = AppUpdater.isNewer("0.8", than: "0.69") && AppUpdater.isNewer("0.7", than: "0.68")
            && AppUpdater.isNewer("0.65", than: "0.6") && AppUpdater.isNewer("1.0", than: "0.99")
            && !AppUpdater.isNewer("0.69", than: "0.8") && !AppUpdater.isNewer("0.8", than: "0.80")
            && AppUpdater.isNewer("0.68.1", than: "0.68") && AppUpdater.isNewer("0.69.10", than: "0.69.9")
        checks.append(Check(area: area, name: "Версії програми порівнюються як десяткові", status: versions ? .ok : .failed,
                            detail: "0.8 > 0.69, 0.7 > 0.68, 0.65 > 0.6, 1.0 > 0.99, 0.8 = 0.80, 0.68.1 > 0.68, 0.69.10 > 0.69.9"))

        checks.append(importArchivesInFolder(area: area))
        checks.append(contentsOf: extraSources(area: area))

        // Оновлення з копії App Translocation: пакет не там, звідки запущено.
        let moved = URL(fileURLWithPath: "/private/var/folders/n3/x/T/AppTranslocation/3F6D/d/Слово.app")
        let home = URL(fileURLWithPath: "/Applications/Слово.app")
        let translocationOK = AppUpdater.isTranslocated(moved) && !AppUpdater.isTranslocated(home)
            && AppUpdater.originalBundleURL(of: home) == home
        let preview = NativeUpdateWindow.previewForCheck(to: "slovo-оновлення-вікно.png")
        checks.append(Check(area: area, name: "Вікно ходу оновлення в стилі заставки: смужка й рядок кроку",
                            status: preview ? .ok : .failed,
                            detail: preview ? "знімок ~/Library/Logs/slovo-оновлення-вікно.png" : "знімок не записався"))
        checks.append(Check(area: area, name: "Оновлення бачить копію App Translocation і не пише поруч із нею",
                            status: translocationOK ? .ok : .failed,
                            detail: "копія з AppTranslocation впізнається; звичайний пакет лишається собою; справжнє місце — SecTranslocateCreateOriginalPathForURL"))
        return checks
    }

    /// Нові джерела без мережі: eBible.org (каталог CSV, VPL → MyBible) і
    /// пісенники SoftProjector (сторінка, найстаріший текстовий `.sps`).
    private static func extraSources(area: String) -> [Check] {
        var checks: [Check] = []
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slovo-джерела-\(UUID().uuidString)")
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // 1. Каталог eBible.org: лише вільні й доступні, мова дволітерна.
        let csv = #"""
            \#u{FEFF}"languageCode","translationId","languageNameInEnglish","title","Redistributable","UpdateDate","OTverses","NTverses","DCverses","downloadable","shortTitle"
            "eng","engwebp","English","World English Bible","True","2026-09-12","23145","7957","0","True","WEB"
            "ukr","ukr1871","Ukrainian","Святе Письмо, ""Куліш""","True","2025-01-02","0","7957","0","True",""
            "deu","deu1912","German","Luther 1912","False","2024-01-01","23145","7957","0","True",""
            """#
        let eb = ResourceCatalog.eBible(csv: csv)
        let ebOK = eb.items.map(\.id) == ["eb:engwebp", "eb:ukr1871"] && eb.items.map(\.language) == ["en", "uk"]
            && eb.items[1].title == "Святе Письмо, \"Куліш\"" && eb.items[0].url.hasSuffix("/engwebp_vpl.zip")
        checks.append(Check(area: area, name: "Каталог eBible.org: вільні переклади, мова uk/en, лапки в назві",
                            status: ebOK ? .ok : .failed,
                            detail: eb.items.map { "\($0.id) \($0.language ?? "—") «\($0.title)»" }.joined(separator: "; ")))

        // 2. VPL → модуль MyBible, який програма відкриває.
        let vpl = root.appendingPathComponent("test_vpl.txt")
        let module = root.appendingPathComponent("Modules/test.SQLite3")
        try? "GEN 1:1 In the beginning, God created the heavens and the earth.\nGEN 1:2 The earth was formless.\nPSA 23:1 The LORD is my shepherd.\nJOH 3:16 For God so loved the world.\nXYZ 1:1 skipped\n"
            .write(to: vpl, atomically: true, encoding: .utf8)
        var vplDetail = ""
        var vplOK = false
        do {
            let count = try EBibleVPL.convert(text: vpl, to: module, description: .init(
                title: "Test Bible", abbreviation: "TST", language: "en", copyright: "public domain", rightToLeft: false))
            let opened = try MyBibleModule(fileAt: module)
            let john = opened.books.first { $0.canonicalNumber == 500 }
            let text = try john.flatMap { try opened.chapters(ofBook: $0).first?.verses.first?.text } ?? ""
            vplOK = count == 4 && opened.books.count == 3 && text == "For God so loved the world." && opened.info.name == "Test Bible"
            vplDetail = "віршів \(count), книг \(opened.books.count) (\(opened.books.map(\.fullName).joined(separator: ", "))); Ів 3:16 «\(text)»"
        } catch {
            vplDetail = "\(error)"
        }
        checks.append(Check(area: area, name: "eBible.org: VPL стає модулем MyBible, який програма читає",
                            status: vplOK ? .ok : .failed, detail: vplDetail))

        // 3. Сторінка пісенників SoftProjector.
        let html = """
            <h3>English</h3>
            <p>Christian Hymns - <a href="songbooks/Christian_Hymns.zip">Christian_Hymns.zip</a><br>
            Worship Songs - <a href="songbooks/englishworship.sps">englishworship.sps</a> * works only with version 2</p>
            <h3>Ukrainian</h3>
            <p>Євангелски Пісні - <a href="songbooks/EvangelskiPisni.zip">EvangelskiPisni.zip</a><br>
            Пiснi Спасенних - <a href="songbooks/PisniSpasennyh.zip">
            PisniSpasennyh.zip</a><br>
            """
        let sp = ResourceCatalog.softProjector(html: html, base: "https://softprojector.org/")
        let spOK = sp.items.map(\.id) == ["sp:Christian_Hymns", "sp:englishworship", "sp:EvangelskiPisni", "sp:PisniSpasennyh"]
            && sp.items.map(\.language) == ["en", "en", "uk", "uk"] && sp.items[2].title == "Євангелски Пісні"
            && sp.items.allSatisfy { $0.kind == .songbook && $0.fileName.hasSuffix(".songbook") }
        checks.append(Check(area: area, name: "Пісенники SoftProjector: назви, мови, файли",
                            status: spOK ? .ok : .failed,
                            detail: sp.items.map { "\($0.id) \($0.language ?? "—") «\($0.title)»" }.joined(separator: "; ")))

        // 4. Найстаріший текстовий .sps.
        let old = root.appendingPathComponent("old.sps")
        try? "##0\n##Проба пісень\n##(c) проба\n1#$#Боже, славимо Тебе#$##$##$##$##$#Куплет 1 @%Боже, славимо Тебе @%і хвалу Тобі приносим@$Приспів@%Слава Тобі#$##$#left#$#\n2#$#Друга#$##$#G#$##$##$#Verse 1.@%Рядок#$##$##$#\n"
            .write(to: old, atomically: true, encoding: .utf8)
        var oldDetail = ""
        var oldOK = false
        do {
            let book = try SongBookImporter.fromSoftProjector(fileAt: old)
            let first = book.songs.first
            oldOK = book.title == "Проба пісень" && book.songs.count == 2 && first?.parts.count == 2
                && first?.parts.last?.text == "Слава Тобі"
            oldDetail = "«\(book.title)»: пісень \(book.songs.count); у першій частин \(first?.parts.count ?? 0): "
                + (first?.parts.map { "\($0.kind): \($0.text.prefix(20))" }.joined(separator: " | ") ?? "")
        } catch {
            oldDetail = "\(error)"
        }
        checks.append(Check(area: area, name: "Пісенник SoftProjector 1.x (текст «##», «#$#») читається",
                            status: oldOK ? .ok : .failed, detail: oldDetail))
        return checks
    }

    /// Майстер імпорту: тека, де модулі лежать архівами (тека завантажень), і
    /// тека лише з пісенниками `.songbook`.
    ///
    /// У 0.84 архіви в теці мовчки пропускались, а тека з одними `.songbook`
    /// відкидалась словами «нічого імпортувати».
    private static func importArchivesInFolder(area: String) -> Check {
        let name = "Імпорт: архіви модулів у теці та тека лише з пісенниками"
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("slovo-архіви-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let build = root.appendingPathComponent("збирання")
        let folder = root.appendingPathComponent("завантаження")
        let songs = root.appendingPathComponent("пісенники")
        var trouble: [String] = []
        func zip(_ from: URL, _ to: URL, keepParent: Bool) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k"] + (keepParent ? ["--keepParent"] : []) + [from.path, to.path]
            try? process.run()
            process.waitUntilExit()
        }
        do {
            let module = build.appendingPathComponent("Bible_Проба_Касіян")
            try fm.createDirectory(at: module, withIntermediateDirectories: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try fm.createDirectory(at: songs, withIntermediateDirectories: true)
            try "BibleName = Проба Касіяна\r\nBibleShortName = ПКас\r\nBookQty = 0\r\n"
                .write(to: module.appendingPathComponent("bibleqt.ini"), atomically: true, encoding: .utf8)
            zip(module, folder.appendingPathComponent("kassian.zip"), keepParent: true)
            zip(module, folder.appendingPathComponent("плоский.zip"), keepParent: false)
            let other = build.appendingPathComponent("нотатки.txt")
            try "не модуль".write(to: other, atomically: true, encoding: .utf8)
            zip(other, folder.appendingPathComponent("інше.zip"), keepParent: false)
            try "{}".write(to: songs.appendingPathComponent("проба.songbook"), atomically: true, encoding: .utf8)
        } catch {
            return Check(area: area, name: name, status: .skipped, detail: "не зібрано джерело: \(error)")
        }

        let destination = ImportDestination(dataRoot: root.appendingPathComponent("куди"))
        if let source = try? ModuleImporter.source(at: folder) {
            let modules = ModuleImporter.inventory(of: source, destination: destination).modules
            let targets = modules.map(\.destinationURL.lastPathComponent).sorted()
            if targets != ["Bible_Проба_Касіян", "плоский"] {
                trouble.append("з трьох архівів узято \(targets) замість модуля з обгорткою й модуля без неї")
            }
            if let first = modules.first(where: { $0.destinationURL.lastPathComponent == "Bible_Проба_Касіян" }),
               first.title != "ПКас" {
                trouble.append("назва модуля з архіву «\(first.title)», а не «ПКас»")
            }
        } else {
            trouble.append("тека з архівами модулів не прийнята як джерело")
        }
        if (try? ModuleImporter.source(at: songs)) == nil {
            trouble.append("тека лише з .songbook не прийнята як джерело")
        }
        if ModuleImporter.looksLikeDataFolder(folder) {
            trouble.append("обхід дисків відкриває архіви (має дивитися лише на розпаковане)")
        }
        return Check(area: area, name: name, status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "тека з 3 архівами дала 2 модулі (з обгорткою й без), чужий zip пропущено; тека з .songbook прийнята"
                         : trouble.joined(separator: "; "))
    }

    /// Те саме, але з мережею — `--check=ресурси-мережа`: свій каталог і
    /// «Цитата з Біблії» читаються з GitHub; найменший ресурс із кожного
    /// джерела встановлюється в тимчасову теку; програма бачить останній
    /// випуск; вікно «Ресурси з GitHub» показує каталог (знімок).
    static func resourcesNetworkSection(state: AppState) -> [Check] {
        let area = "Ресурси (мережа)"
        var checks: [Check] = []
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-мережа-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        let ledgerBefore = ResourceLedger.load()
        defer { ledgerBefore.save() }

        func fetch(_ source: ResourceHub.Source, hub: ResourceHub) -> Result<ResourceCatalog, ResourceError> {
            var answer: Result<ResourceCatalog, ResourceError>?
            hub.fetchCatalog(source) { answer = $0 }
            wait(untilTrue: { answer != nil }, seconds: 30)
            return answer ?? .failure(.network("час вийшов"))
        }
        // Скільки разів прийшов проміжний хід завантаження (0 < частка < 1).
        // Нуль на великому файлі — смужка у вікні ресурсів стоїть на місці.
        final class Ticks: @unchecked Sendable { var count = 0 }
        let ticks = Ticks()
        func install(_ item: ResourceItem, hub: ResourceHub) -> ResourceHub.Outcome? {
            var outcome: ResourceHub.Outcome?
            ticks.count = 0
            hub.install([item], progress: { step in
                if let fraction = step.fraction, fraction > 0, fraction < 1 { ticks.count += 1 }
            }, completion: { outcome = $0 })
            wait(untilTrue: { outcome != nil }, seconds: 180)
            return outcome
        }

        for source in ResourceHub.Source.allCases {
            let label: String
            switch source {
            case .slovo:      label = "свій каталог slovo-resources"
            case .bibleQuote: label = "«Цитата з Біблії» на GitHub"
            case .myBible:    label = "реєстр MyBible"
            case .eBible:     label = "eBible.org (VPL → MyBible)"
            case .softProjector: label = "пісенники SoftProjector"
            }
            let modules = temp.appendingPathComponent(source.rawValue + "/app/Modules")
            try? fm.createDirectory(at: modules, withIntermediateDirectories: true)
            let hub = ResourceHub(layout: ResourceLayout(modulesFolder: modules))
            switch fetch(source, hub: hub) {
            case .failure(let error):
                checks.append(Check(area: area, name: "Каталог: " + label, status: .failed, detail: "\(error)"))
            case .success(let catalog):
                let kinds = Dictionary(grouping: catalog.items, by: \.kind).map { "\($0.key.rawValue) \($0.value.count)" }.sorted()
                checks.append(Check(area: area, name: "Каталог: " + label, status: catalog.items.isEmpty ? .failed : .ok,
                                    detail: "ресурсів \(catalog.items.count): " + kinds.joined(separator: ", ")))
                // Найменший переклад (для BibleQuote розмір невідомий — перший за абеткою з «Russian»).
                let bibles = catalog.items.filter { $0.kind == .bible }
                let pick: ResourceItem?
                switch source {
                case .slovo:      pick = bibles.filter { $0.size > 0 }.min { $0.size < $1.size }
                case .bibleQuote: pick = bibles.first { $0.fileName.contains("Russian_RST") } ?? bibles.first
                case .myBible:    pick = bibles.filter { $0.language == "uk" && $0.size > 0 }.min { $0.size < $1.size }
                case .eBible:     pick = bibles.filter { $0.language == "uk" }.min { $0.size < $1.size }
                                      ?? bibles.filter { $0.language == "en" }.min { $0.size < $1.size }
                // Найстаріший текстовий формат — «Євангельські пісні».
                case .softProjector: pick = catalog.items.first { $0.id == "sp:EvangelskiPisni" } ?? catalog.items.first
                }
                guard let item = pick else { continue }
                let started = Date()
                guard let outcome = install(item, hub: hub) else {
                    checks.append(Check(area: area, name: "Установлення з мережі: " + label, status: .failed, detail: "час вийшов"))
                    continue
                }
                if item.kind == .songbook {
                    let file = modules.appendingPathComponent(item.fileName)
                    let songs = (try? SongBook(fileAt: file))?.songs.count ?? 0
                    let ok = outcome.installed.count == 1 && songs > 0
                    checks.append(Check(area: area, name: "Установлення з мережі: " + label, status: ok ? .ok : .failed,
                                        detail: "«\(item.title)» за \(String(format: "%.1f", Date().timeIntervalSince(started))) с; пісень \(songs)"
                                            + (outcome.failures.isEmpty ? "" : "; " + outcome.failures.map { $0.1 }.joined(separator: "; "))))
                    continue
                }
                let opened = ModuleLibrary(modulesDirectory: modules)
                let verses: Int = {
                    guard let module = opened.modules.first, let book = module.books.first,
                          let chapter = try? module.chapters(ofBook: book).first else { return 0 }
                    return chapter.verses.count
                }()
                let movingBar = source != .eBible || ticks.count > 0
                let ok = outcome.installed.count == 1 && opened.modules.count == 1 && verses > 0 && movingBar
                checks.append(Check(area: area, name: "Установлення з мережі: " + label, status: ok ? .ok : .failed,
                                    detail: "хід завантаження: \(ticks.count) разів; «\(item.title)» (\(item.size / 1024) КБ) за \(String(format: "%.1f", Date().timeIntervalSince(started))) с; "
                                        + "бібліотека бачить модулів \(opened.modules.count), віршів у першому розділі \(verses)"
                                        + (outcome.failures.isEmpty ? "" : "; " + outcome.failures.map { $0.1 }.joined(separator: "; "))))
            }
        }

        // Останній випуск програми.
        var release: Result<AppUpdater.Release, ResourceError>?
        AppUpdater.fetchLatest { release = $0 }
        wait(untilTrue: { release != nil }, seconds: 30)
        switch release {
        case .success(let found)?:
            let ok = found.zip != nil && !found.version.isEmpty
            checks.append(Check(area: area, name: "Останній випуск програми на GitHub", status: ok ? .ok : .failed,
                                detail: "\(found.tag), файл: \(found.zip.map { ($0 as NSString).lastPathComponent } ?? "нема"), \(found.size / 1_048_576) МБ; у нас \(AppUpdater.currentVersion)"
                                    + (AppUpdater.isNewer(found.version, than: AppUpdater.currentVersion) ? " — є оновлення" : " — оновлень нема")))
        case .failure(let error)?:
            checks.append(Check(area: area, name: "Останній випуск програми на GitHub", status: .failed, detail: "\(error)"))
        case nil:
            checks.append(Check(area: area, name: "Останній випуск програми на GitHub", status: .failed, detail: "час вийшов"))
        }

        // Вікно з каталогом — знімок.
        NativeResourcesWindow.show(state: state)
        wait(untilTrue: { NativeResourcesWindow.rowsForCheck > 0 }, seconds: 30)
        let rows = NativeResourcesWindow.rowsForCheck
        let picture = NativeResourcesWindow.snapshotForCheck(to: "slovo-ресурси-вікно.png")
        checks.append(Check(area: area, name: "Вікно «Ресурси з GitHub» показує каталог", status: rows > 0 ? .ok : .failed,
                            detail: "рядків \(rows)" + (picture ? "; знімок ~/Library/Logs/slovo-ресурси-вікно.png" : "")))
        NativeResourcesWindow.closeForCheck()
        return checks
    }
}
