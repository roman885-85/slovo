import Foundation
import SlovoCore

// Еталон розділу `import` — дзеркало CoreCheck.Import.cs.

func maskPaths(_ text: String, _ roots: [(String, String)]) -> String {
    var result = text
    for (root, name) in roots {
        let bare = root.hasPrefix("/private/") ? String(root.dropFirst("/private".count)) : root
        result = result.replacingOccurrences(of: "/private" + bare, with: name).replacingOccurrences(of: bare, with: name)
    }
    let temp = FileManager.default.temporaryDirectory.path
    let bareTemp = temp.hasPrefix("/private/") ? String(temp.dropFirst("/private".count)) : temp
    let re = try! NSRegularExpression(pattern: "(/private)?" + NSRegularExpression.escapedPattern(for: bareTemp) + "/slovo-import-[0-9A-F-]{36}")
    return re.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result), withTemplate: "<TMP>")
}
func unixSeconds(_ date: Date?) -> Int { date.map { Int(floor($0.timeIntervalSince1970)) } ?? -1 }
func categoryName(_ c: ImportItem.Category) -> String { c.rawValue }
func conditionName(_ c: ImportItem.Condition) -> String { c.rawValue }
func sourceKindName(_ k: ImportSource.Kind) -> String {
    switch k { case .installed: return "Installed"; case .folder: return "Folder"; case .archive: return "Archive" }
}
func problemKindName(_ p: ImportProblem) -> String {
    switch p {
    case .nothingToImport: return "NothingToImport"
    case .badConfig: return "BadConfig"
    case .alreadyAdded: return "AlreadyAdded"
    case .unpackFailed: return "UnpackFailed"
    case .destinationNotWritable: return "DestinationNotWritable"
    }
}
func setDate(_ path: String, _ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) {
    var parts = DateComponents(); parts.year = y; parts.month = mo; parts.day = d; parts.hour = h; parts.minute = mi
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
    try! FileManager.default.setAttributes([.modificationDate: calendar.date(from: parts)!], ofItemAtPath: path)
}

func checkImport(_ data: URL) {
    print("# import")
    guard let fixtures = ProcessInfo.processInfo.environment["SLOVO_IMPORT_FIXTURES"], !fixtures.isEmpty else {
        print("import skipped: no SLOVO_IMPORT_FIXTURES"); return
    }
    let fm = FileManager.default
    let outputPath = ProcessInfo.processInfo.environment["SLOVO_CHECK_OUT"].flatMap { $0.isEmpty ? nil : $0 } ?? fm.temporaryDirectory.path
    let work = URL(fileURLWithPath: outputPath).appendingPathComponent("slovo-check-import-" + UUID().uuidString)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }
    func m(_ text: String) -> String { maskPaths(text, [(work.path, "<WORK>"), (fixtures, "<FX>")]) }
    func itemLine(_ item: ImportItem) -> String {
        m("\(item.id) | \(categoryName(item.category)) | \(item.title) | \(item.subtitle) | src \(item.sourceURL.path) | dst \(item.destinationURL.path) | comp [\(item.companions.map(\.path).joined(separator: ","))] | \(conditionName(item.condition)) | \(item.byteSize) | \(item.sourceURL.path.contains("slovo-import-") ? "-" : String(unixSeconds(item.modified))) | sel \(item.isSelected)")
    }
    let fx = URL(fileURLWithPath: fixtures)
    let src = fx.appendingPathComponent("src")
    for (label, url, archives) in [("src", src, false), ("modules", src.appendingPathComponent("Modules"), false), ("bq", src.appendingPathComponent("Modules/TestBQ"), false),
                                   ("emptydir", fx.appendingPathComponent("emptydir"), true), ("zipsonly", fx.appendingPathComponent("zipsonly"), false),
                                   ("zipsonly+", fx.appendingPathComponent("zipsonly"), true), ("songsonly", fx.appendingPathComponent("songsonly"), false),
                                   ("missing", fx.appendingPathComponent("nope"), true), ("file", src.appendingPathComponent("VisioBible.ini"), true)] {
        print("looks \(label) \(ModuleImporter.looksLikeDataFolder(url, archives: archives))")
    }
    let dst = work.appendingPathComponent("dst")
    let destination = ImportDestination(dataRoot: dst)
    for f in ["Modules", "Templates", "BackGrounds"] { try! fm.createDirectory(at: dst.appendingPathComponent(f), withIntermediateDirectories: true) }
    try! fm.copyItem(at: src.appendingPathComponent("Modules/vidrodzhennia.songbook"), to: dst.appendingPathComponent("Modules/vidrodzhennia.songbook"))
    setDate(dst.appendingPathComponent("Modules/vidrodzhennia.songbook").path, 2020, 1, 1, 0, 0)
    try! Data("old".utf8).write(to: dst.appendingPathComponent("Templates/Autumn.sch"))
    setDate(dst.appendingPathComponent("Templates/Autumn.sch").path, 2019, 12, 31, 23, 59)
    try! Data("a-old".utf8).write(to: dst.appendingPathComponent("BackGrounds/a.jpg"))
    setDate(dst.appendingPathComponent("BackGrounds/a.jpg").path, 2019, 1, 1, 0, 0)
    print("destination modules \(m(destination.modulesFolder.path)) templates \(m(destination.templatesFolder.path)) backgrounds \(m(destination.backgroundsFolder.path)) plans \(m(destination.plansFolder.path)) safe \(destination.isSafeToWrite) library \(ImportDestination.applicationLibrary.dataRoot.lastPathComponent)")
    for path in ["/Applications/VisioBible.app/Contents/Resources/app", "/Users/x/Library/Application Support/CrossOver/Bottles/b/drive_c/x", "/x/drive_c/y", "/Apps/Слово.app/Contents/data", "/Users/x/Data", "C:\\Users\\x\\AppData\\Roaming\\Slovo"] {
        print("safe \(path) \(ImportDestination(dataRoot: URL(fileURLWithPath: path)).isSafeToWrite)")
    }
    let source = try! ModuleImporter.source(atFolder: src)
    print(m("source \(sourceKindName(source.kind)) «\(source.version)» url \(source.url.path) origin \(source.originURL.path) id \(source.id) path \(source.path)"))
    let cases: [(String, () throws -> ImportSource)] = [
        ("again", { try ModuleImporter.source(atFolder: src, existing: [source]) }),
        ("emptydir", { try ModuleImporter.source(atFolder: fx.appendingPathComponent("emptydir")) }),
        ("badini", { try ModuleImporter.source(atFolder: fx.appendingPathComponent("badini")) }),
        ("file", { try ModuleImporter.source(at: src.appendingPathComponent("Modules/bel.songs.vbm")) }),
        ("zipsonly", { try ModuleImporter.source(at: fx.appendingPathComponent("zipsonly")) }),
        ("archive", { try ModuleImporter.source(at: fx.appendingPathComponent("olddata.zip")) }),
        ("archive again", { try ModuleImporter.source(atArchive: fx.appendingPathComponent("olddata.zip"), existing: [ImportSource(version: "v", url: URL(fileURLWithPath: "/x"), originURL: fx.appendingPathComponent("olddata.zip"), kind: .archive)]) }),
        ("empty zip", { try ModuleImporter.source(atArchive: fx.appendingPathComponent("empty.zip")) }),
        ("no modules zip", { try ModuleImporter.source(atArchive: fx.appendingPathComponent("nomodules.zip")) }),
    ]
    for (label, action) in cases {
        do {
            let found = try action()
            print(m("source \(label): \(sourceKindName(found.kind)) «\(found.version)» url \(found.kind == .archive ? found.url.lastPathComponent : found.url.path) origin \(found.originURL.path)"))
            if label == "zipsonly" || label == "archive" {
                let other = ModuleImporter.inventory(of: found, destination: destination)
                print("  inventory empty \(other.isEmpty) modules \(other.modules.count) templates \(other.templates.count) images \(other.images.count)")
                for item in other.modules + other.templates + other.images { print("  " + itemLine(item)) }
            }
        } catch let p as ImportProblem {
            if case .unpackFailed(let path, _) = p { print(m("source \(label): \(problemKindName(p)) \(path) key \(p.messageKey ?? "nil")")) }
            else { print(m("source \(label): \(problemKindName(p)) \(p) key \(p.messageKey ?? "nil")")) }
        } catch { print("source \(label): other \(error)") }
    }
    let inventory = ModuleImporter.inventory(of: source, destination: destination)
    print("inventory empty \(inventory.isEmpty) modules \(inventory.modules.count) templates \(inventory.templates.count) images \(inventory.images.count) selected \(inventory.selected.count) songs \(inventory.selected(.songBook).count)")
    for item in inventory.modules + inventory.templates + inventory.images { print(itemLine(item)) }
    for item in inventory.modules { print("validate \(item.id): \(ModuleImporter.validate(item).map { m(esc($0)) } ?? "ok")") }
    var steps: [String] = []
    let outcome = ModuleImporter.run(inventory, destination: destination) { title, fraction in steps.append("\(title)@\(Int(fraction * 1000))") }
    print("run modules \(outcome.modules.joined(separator: "|")) templates \(outcome.templates.joined(separator: "|")) images \(outcome.images.joined(separator: "|")) total \(outcome.total)")
    for f in outcome.failures { print(m("run failure \(f.title): \(esc(f.reason))")) }
    print(m("run imported " + outcome.importedModules.map(\.path).joined(separator: " ")))
    print("run steps " + steps.joined(separator: " "))
    print("tree " + tree(dst).joined(separator: " "))
    print("converted \(songDigest(try! SongBook(fileAt: dst.appendingPathComponent("Modules/bel.songs.songbook")))) kept \(songDigest(try! SongBook(fileAt: dst.appendingPathComponent("Modules/vidrodzhennia.songbook")))) module \(fnv(moduleText(try! BibleModule(directory: dst.appendingPathComponent("Modules/TestBQ")))))")
    let after = ModuleImporter.inventory(of: source, destination: destination)
    print("after " + (after.modules + after.templates + after.images).map { "\($0.id)=\(conditionName($0.condition))/\($0.isSelected)" }.joined(separator: " "))
    func deselected(_ items: [ImportItem], keep: (ImportItem) -> Bool = { _ in false }) -> [ImportItem] { items.map { var c = $0; c.isSelected = keep($0); return c } }
    let manual = ImportInventory(source: source, modules: deselected(inventory.modules), templates: deselected(inventory.templates), images: deselected(inventory.images, keep: { $0.title == "a.jpg" }))
    let second = ModuleImporter.run(manual, destination: destination)
    print("manual images \(second.images.joined(separator: ",")) total \(second.total) failures \(second.failures.count) a.jpg «\(try! String(contentsOf: dst.appendingPathComponent("BackGrounds/a.jpg"), encoding: .utf8))»")
    let unsafeRun = ModuleImporter.run(inventory, destination: ImportDestination(dataRoot: URL(fileURLWithPath: "/x/drive_c/y")))
    print("unsafe failures \(unsafeRun.failures.map { "\($0.title): \($0.reason)" }.joined(separator: " | ")) total \(unsafeRun.total)")
    let language = LanguageCatalog(directory: data.appendingPathComponent("Language")).language(code: "ru")
    for p in [ImportProblem.nothingToImport("/a/b"), .badConfig("/a/b"), .alreadyAdded("/a/b"), .unpackFailed("x.zip", "причина"), .destinationNotWritable("/a/b")] {
        print("problem \(problemKindName(p)) «\(p)» key \(p.messageKey ?? "nil") path \(p.path) ru «\(esc(p.localized(language)))» none «\(p.localized(nil))» text «\(esc(ImportProblem.text(for: p, language: language)))»")
    }
    print("problem other «\(ImportProblem.text(for: SongBookError.inflateFailed, language: language))»")
}
