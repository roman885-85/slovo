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
            checks.append(Check(area: area, name: "Оновлення програми зберігає переклади й дані пакета",
                                status: trouble.isEmpty ? .ok : .failed,
                                detail: trouble.isEmpty ? "новий пакет на місці, Modules і Templates перейшли зі старого, Slovo.ini — нове" : trouble.joined(separator: "; ")))
        } catch {
            checks.append(Check(area: area, name: "Оновлення програми зберігає переклади й дані пакета", status: .failed, detail: "\(error)"))
        }

        // 5. Версії програми порівнюються числами, а не рядками.
        let versions = AppUpdater.isNewer("0.8", than: "0.69") && AppUpdater.isNewer("0.7", than: "0.68")
            && AppUpdater.isNewer("0.65", than: "0.6") && AppUpdater.isNewer("1.0", than: "0.99")
            && !AppUpdater.isNewer("0.69", than: "0.8") && !AppUpdater.isNewer("0.8", than: "0.80")
            && AppUpdater.isNewer("0.68.1", than: "0.68") && AppUpdater.isNewer("0.69.10", than: "0.69.9")
        checks.append(Check(area: area, name: "Версії програми порівнюються як десяткові", status: versions ? .ok : .failed,
                            detail: "0.8 > 0.69, 0.7 > 0.68, 0.65 > 0.6, 1.0 > 0.99, 0.8 = 0.80, 0.68.1 > 0.68, 0.69.10 > 0.69.9"))
        return checks
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
        func install(_ item: ResourceItem, hub: ResourceHub) -> ResourceHub.Outcome? {
            var outcome: ResourceHub.Outcome?
            hub.install([item], progress: { _ in }, completion: { outcome = $0 })
            wait(untilTrue: { outcome != nil }, seconds: 180)
            return outcome
        }

        for source in ResourceHub.Source.allCases {
            let label: String
            switch source {
            case .slovo:      label = "свій каталог slovo-resources"
            case .bibleQuote: label = "«Цитата з Біблії» на GitHub"
            case .myBible:    label = "реєстр MyBible"
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
                }
                guard let item = pick else { continue }
                let started = Date()
                guard let outcome = install(item, hub: hub) else {
                    checks.append(Check(area: area, name: "Установлення з мережі: " + label, status: .failed, detail: "час вийшов"))
                    continue
                }
                let opened = ModuleLibrary(modulesDirectory: modules)
                let verses: Int = {
                    guard let module = opened.modules.first, let book = module.books.first,
                          let chapter = try? module.chapters(ofBook: book).first else { return 0 }
                    return chapter.verses.count
                }()
                let ok = outcome.installed.count == 1 && opened.modules.count == 1 && verses > 0
                checks.append(Check(area: area, name: "Установлення з мережі: " + label, status: ok ? .ok : .failed,
                                    detail: "«\(item.title)» (\(item.size / 1024) КБ) за \(String(format: "%.1f", Date().timeIntervalSince(started))) с; "
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
