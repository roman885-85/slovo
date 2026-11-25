import Foundation
import SlovoCore

// Еталон розділу `plan` — дзеркало CoreCheck.Plan.cs рядок у рядок.

func maskTime(_ json: String) -> String {
    let re = try! NSRegularExpression(pattern: "\"savedAt\" : \"[^\"]*\"")
    return re.stringByReplacingMatches(in: json, range: NSRange(json.startIndex..., in: json), withTemplate: "\"savedAt\" : \"<час>\"")
}

func itemLine(_ item: PlanItem, withId: Bool = true) -> String {
    let content: String
    switch item.kind {
    case .scripture:
        let s = item.scripture!
        content = "module=\(s.moduleID) book=\(s.bookIndex) chapter=\(s.chapter) verses=\(s.verses.map(String.init).joined(separator: ","))"
    case .song:
        let s = item.songPart!
        content = "songBook=\(s.bookFileName) song=\(s.songIndex) part=\(iv(s.partIndex)) whole=\(s.isWholeSong)"
    case .text:
        let d = item.plainText!
        content = "heading=«\(esc(d.title))» body=«\(esc(d.body))»"
    case .file:
        let f = item.file!
        content = "path=\(f.path) name=\(f.name)"
    }
    let id = withId ? item.id.uuidString + " " : ""
    return "\(id)\(item.kind.rawValue) «\(esc(item.title))» sub «\(item.subtitle.map(esc) ?? "nil")» \(content)"
}

func planState(_ plan: ServicePlan) -> String {
    "cur \(iv(plan.currentIndex)) unsaved \(plan.hasUnsavedChanges) next \(plan.canGoToNext) prev \(plan.canGoToPrevious) [\(plan.items.map(\.title).joined(separator: "|"))]"
}

func planErrorKind(_ e: PlanError) -> String {
    switch e {
    case .notAPlan: return "NotAPlan"
    case .unreadable: return "Unreadable"
    case .unsupportedItem: return "UnsupportedItem"
    case .noFile: return "NoFile"
    }
}

func checkPlan(_ data: URL, _ library: ModuleLibrary) {
    print("# plan")
    let module = library.modules.first { $0.identifier == "ubt2020" } ?? library.modules[0]
    let songs = SongLibrary(modulesDirectory: data.appendingPathComponent("Modules"))
    let songBookId = songs.books[0].id
    let songBook = songs.book(songBookId)!
    let songFile = songs.books[0].url.lastPathComponent
    func fixed(_ item: PlanItem, _ n: Int) -> PlanItem {
        var copy = item
        copy.id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
        return copy
    }
    let john = module.books[min(42, module.books.count - 1)]
    let psalms = module.books[min(18, module.books.count - 1)]
    let song3 = songBook.songs[3]
    var items: [PlanItem] = [
        fixed(.scripture(moduleID: module.identifier, book: john, chapter: 3, verses: [18, 16, 17, 16], quote: "Бо так полюбив Бог світ,\nщо дав Сина\r\n"), 1),
        fixed(.scripture(moduleID: module.identifier, book: psalms, chapter: 23, verses: []), 2),
        fixed(.songPart(bookFileName: songFile, song: song3, part: song3.parts[min(1, song3.parts.count - 1)]), 3),
        fixed(.song(bookFileName: songFile, song: songBook.songs[5]), 4),
        fixed(.text(PlainTextDocument(title: "Оголошення", body: "Після служіння — братське спілкування.\nВсі запрошені / ласкаво просимо")), 5),
        fixed(.text(PlainTextDocument(title: "", body: "")), 6),
        fixed(.file(URL(fileURLWithPath: "/tmp/slides/Презентація.pptx"), title: "  "), 7),
        fixed(.file(URL(fileURLWithPath: "/tmp/media/відео.mp4"), title: " Проповідь "), 8),
        fixed(.songPart(bookFileName: songFile, song: Song(index: 9, title: "", parts: [SongPart(index: 2, kind: "  ", text: "Рядок 1\nРядок 2")]), part: SongPart(index: 2, kind: "  ", text: "Рядок 1\nРядок 2")), 9),
        fixed(.song(bookFileName: songFile, song: Song(index: 10, title: "")), 10),
    ]
    items += PlanItem.songParts(bookFile: URL(fileURLWithPath: "/x/" + songFile), book: songBook, song: songBook.songs[0]).enumerated().map { fixed($0.element, 20 + $0.offset) }
    for item in items { print("item " + itemLine(item)) }
    for item in items.prefix(4) {
        if let s = item.scripture {
            print("  resolve book=\(s.book(in: module)?.fullName ?? "-") verses=\(s.verses(in: module).map { String($0.number) }.joined(separator: ",")) text=«\(esc(s.text(in: module) ?? "nil"))» numbered=«\(esc(s.text(in: module, withNumbers: true) ?? "nil"))»")
        }
        if let s = item.songPart {
            print("  resolve file=\(s.file(among: [URL(fileURLWithPath: "/a/GLORY.SONGBOOK")] + songs.books.map(\.url))?.lastPathComponent ?? "-") song=\(s.song(in: songBook)?.title ?? "-") part=\(s.part(in: songBook).map { esc($0.kind) } ?? "-")")
        }
    }
    let missing = PlanItem.Scripture(moduleID: "x", bookIndex: 999, chapter: 1, verses: [1])
    print("resolve missing \(missing.book(in: module)?.fullName ?? "-") \(missing.verses(in: module).count) \(missing.text(in: module) ?? "nil") chapter0 \(PlanItem.Scripture(moduleID: "x", bookIndex: 0, chapter: 0).verses(in: module).count) absent \(PlanItem.Scripture(moduleID: "x", bookIndex: 0, chapter: 1, verses: [999, 2, 1]).verses(in: module).map { String($0.number) }.joined(separator: ","))")

    var plan = ServicePlan(title: "Недільне служіння / ранок", items: items)
    print("plan \(planState(plan)) count \(plan.count) empty \(plan.isEmpty) current \(plan.current?.title ?? "-") id \(plan.currentItemID?.uuidString ?? "-")")
    let json = String(data: try! plan.jsonData(), encoding: .utf8)!
    print(maskTime(json))
    print("json bytes \(maskTime(json).utf8.count) \(fnv(maskTime(json)))")

    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("slovo-check-plan-" + UUID().uuidString)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let path = folder.appendingPathComponent("Plans").appendingPathComponent(ServicePlan.fileName(for: plan.title))
    try! plan.save(to: path)
    let savedText = try! String(contentsOf: path, encoding: .utf8)
    print("saved \(plan.fileURL!.lastPathComponent) unsaved \(plan.hasUnsavedChanges) same bytes \(savedText == json || maskTime(savedText) == maskTime(json))")
    let back = try! ServicePlan.read(contentsOf: path)
    print("read back skipped \(back.skippedItems) has \(back.hasSkippedItems) warning \(back.warning ?? "nil") title «\(back.plan.title)» file \(back.plan.fileURL!.lastPathComponent) \(planState(back.plan))")
    for item in back.plan.items { print("  back " + itemLine(item)) }
    print("items equal \(back.plan.items == plan.items) same as saved json \(maskTime(String(data: try! back.plan.jsonData(), encoding: .utf8)!) == maskTime(json))")
    var retitled = back.plan
    retitled.title = "Інша назва"
    print("retitled unsaved \(retitled.hasUnsavedChanges)")
    do { var empty = ServicePlan(); try empty.save() } catch let e as PlanError { print("save no file: \(e) kind \(planErrorKind(e))") } catch {}

    let journal = plan.journal()
    print(journal.xml())
    let fromJournal = ServicePlan(journal: journal)
    print("journal back \(planState(fromJournal))")
    for item in fromJournal.items { print("  journal " + itemLine(item, withId: false)) }
    let journalPath = folder.appendingPathComponent("Plans").appendingPathComponent("План.ini")
    try! plan.saveAsJournal(to: journalPath)
    print("journal saved \(plan.fileURL!.lastPathComponent) unsaved \(plan.hasUnsavedChanges)")
    let any = try! ServicePlan.readAny(contentsOf: journalPath)
    print("readAny journal «\(any.plan.title)» \(any.skippedItems) file \(any.plan.fileURL!.lastPathComponent) \(planState(any.plan))")
    let anyJson = try! ServicePlan.readAny(contentsOf: path)
    print("readAny json «\(anyJson.plan.title)» \(anyJson.skippedItems) \(anyJson.plan.count)")

    let original = "\u{FEFF}<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<VisioBibleJournal>\r\n<Journal Name=\"Songs\">\r\n"
        + "<Item Caption=\"Пісня перша\" Quote=\"Слова\" SongBook=\"pv3055.vbm\" Song=\"12\" Part=\"-1\"/>\r\n"
        + "<Item Caption=\"\" SongBook=\"glory.vbm\" Song=\"-4\" Part=\"2\" Order=\"1\"/>\r\n<Item Caption=\"без збірника\"/>\r\n</Journal>\r\n"
        + "<Journal Name=\"Bible\">\r\n<Item Caption=\"Ин.- Вначале было Слово\" Reference=\"\" Quote=\"Вначале было Слово\" Book=\"42\" Chapter=\"0\" Verse=\"0\" VersesRangeCount=\"2\"/>\r\n"
        + "<Item Reference=\"Пс 22\" Book=\"18\" Chapter=\"21\" Verse=\"4\" VersesRangeCount=\"9999\" Order=\"0\"/>\r\n<Item Book=\"-1\"/>\r\n"
        + "<Item Reference=\"\" Caption=\"\" Book=\"1\" Verses=\"3, 1-2\" Module=\"RST\"/>\r\n</Journal>\r\n"
        + "<Journal Name=\"Text\">\r\n<Item Caption=\"Оголошення\" Reference=\"\" Quote=\"\"/>\r\n<Item Caption=\"\" Reference=\"Заголовок\" Quote=\"Текст\"/>\r\n"
        + "<Item/>\r\n<Item Caption=\"\" File=\"/a/b/c.pptx\"/>\r\n<Item Caption=\"Файл\" File=\"/a/b/d.mp4\" Heading=\"x\" Body=\"y\" Order=\"2\"/>\r\n</Journal>\r\n</VisioBibleJournal>\r\n"
    let originalPath = folder.appendingPathComponent("PlanDef.ini")
    try! Data(original.utf8).write(to: originalPath)
    let parsed = try! ServicePlan.readAny(contentsOf: originalPath)
    print("original «\(parsed.plan.title)» \(planState(parsed.plan))")
    for item in parsed.plan.items { print("  original " + itemLine(item, withId: false)) }

    let cases = [
        "[{\"type\":\"scripture\",\"book\":\"42\",\"chapter\":3.0,\"verses\":\"16-18, 20\"},{\"book\":1,\"chapter\":-1},{\"songBook\":\"a.vbm\",\"song\":\"2\",\"part\":1.9},{\"heading\":\"\",\"body\":\"\"},{\"path\":\"/x/y.mp4\"},{\"type\":\"video\"},7,null,{\"type\":\"SONG\",\"songBook\":\"\",\"song\":1,\"part\":1},{\"id\":\"dba9ab16-2069-4a30-8eba-78ead9e2f26c\",\"type\":\"text\",\"title\":\"  \",\"heading\":\"Заголовок\",\"body\":\"Тіло\"}]",
        "{\"title\":\"\",\"items\":[]}",
        "{\"format\":\"slovo.plan\"}",
        "{\"foo\":1}",
        "not json",
        "\"string\"",
        "{\"title\":\"T\",\"items\":{\"a\":1}}",
        "\u{FEFF}{\"title\":\"Перший\",\"title\":\"Другий\",\"items\":[{\"type\":\"scripture\",\"book\":0,\"chapter\":0,\"verses\":[3,1,2.0,],},],}",
        "{\"title\":5,\"items\":[{\"book\":1e2,\"chapter\":\"12\",\"verses\":5},{\"book\":3.7,\"chapter\":2,\"verses\":[1,2.5]},{\"book\":1,\"chapter\":1,\"verses\":\"-5-7;9 1--3 4-2, 1-9223372036854775807\"},{\"book\":1,\"chapter\":1,\"verses\":-1},{\"book\":1,\"chapter\":1,\"verses\":[-3,4]},{\"songBook\":\"s\",\"song\":1,\"part\":\"x\"},{\"songBook\":\"s\",\"song\":1,\"part\":null},{\"type\":\"file\",\"path\":\"\"},{\"type\":\"plaintext\"},{\"type\":\"bible\",\"book\":true,\"chapter\":1},{\"type\":\"verse\",\"book\":1,\"chapter\":1,\"title\":7,\"subtitle\":8,\"id\":5}]}",
        "{\"items\":[{\"book\":1e400,\"chapter\":1},{\"book\":-0,\"chapter\":-0.5},{\"book\":2,\"chapter\":\" 3 \"}]}",
    ]
    for (n, text) in cases.enumerated() {
        let file = folder.appendingPathComponent("case\(n).json")
        try! Data(text.utf8).write(to: file)
        do {
            let result = try ServicePlan.read(contentsOf: file)
            print("case \(n): «\(result.plan.title)» skipped \(result.skippedItems) warning \(result.warning ?? "nil") \(planState(result.plan))")
            for item in result.plan.items {
                print("  \(item.id.uuidString == "DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C" ? "fixed-id " : "")\(itemLine(item, withId: false))")
            }
        } catch let e as PlanError {
            print("case \(n): error \(planErrorKind(e)) \(e)")
        } catch { print("case \(n): other \(error)") }
    }
    do { _ = try ServicePlan.read(contentsOf: folder.appendingPathComponent("нема.json")) }
    catch let e as PlanError {
        if case .unreadable(let name, _) = e { print("missing file kind \(planErrorKind(e)) name \(name)") } else { print("missing file kind \(planErrorKind(e)) name ") }
    } catch {}

    let plansDir = ServicePlan.plansDirectory(dataRoot: folder)
    for (name, minutes) in [("a.json", 30), ("b.JSON", 10), ("c.json", 20), ("d.ini", 5), (".e.json", 1)] {
        let target = plansDir.appendingPathComponent(name)
        try! Data("{}".utf8).write(to: target)
        var parts = DateComponents(); parts.year = 2026; parts.month = 1; parts.day = 1; parts.hour = 0; parts.minute = minutes
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        try! fm.setAttributes([.modificationDate: calendar.date(from: parts)!], ofItemAtPath: target.path)
    }
    print("saved plans \(ServicePlan.savedPlans(in: plansDir).map(\.lastPathComponent).joined(separator: ",")) dir \(plansDir.lastPathComponent)")

    var nav = ServicePlan(title: "Навігація", items: Array(items.prefix(5)))
    print("nav start \(planState(nav))")
    print("nav next \(nav.goToNext()?.title ?? "nil") \(nav.goToNext()?.title ?? "nil") \(planState(nav))")
    nav.insert(items[5], at: 0)
    print("nav insert0 \(planState(nav))")
    nav.insert(items[6], at: 99)
    print("nav insert99 \(planState(nav))")
    nav.move(fromOffsets: IndexSet([0, 2]), toOffset: 5)
    print("nav move \(planState(nav))")
    nav.move(from: 4, to: 1)
    print("nav move1 \(planState(nav))")
    nav.move(from: 1, to: 4)
    print("nav move2 \(planState(nav))")
    nav.move(fromOffsets: IndexSet([9]), toOffset: 1)
    nav.move(fromOffsets: IndexSet([1]), toOffset: 99)
    print("nav move bad \(planState(nav))")
    print("nav remove \(nav.remove(at: 2)?.title ?? "nil") \(nav.remove(at: 99)?.title ?? "nil") \(planState(nav))")
    nav.remove(atOffsets: IndexSet([0, 1, 50]))
    print("nav remove offsets \(planState(nav))")
    nav.select(at: 99)
    print("nav select99 \(planState(nav)) prev \(nav.goToPrevious()?.title ?? "nil") \(planState(nav))")
    nav.select(id: nav.items[0].id)
    print("nav select id \(planState(nav)) prev \(nav.goToPrevious()?.title ?? "nil")")
    nav.remove(id: nav.items[0].id)
    nav.replace(at: 0, with: items[7])
    nav.replace(at: 9, with: items[7])
    print("nav replace \(planState(nav)) at0 \(nav[0]?.title ?? "nil") at9 \(nav[9]?.title ?? "nil")")
    nav.append(items[8])
    nav.append(contentsOf: [items[9], items[1]])
    nav.append(contentsOf: [])
    print("nav append \(planState(nav))")
    nav.removeAll()
    print("nav cleared \(planState(nav)) next \(nav.goToNext()?.title ?? "nil")")
    nav.append(items[0])
    print("nav append after clear \(planState(nav))")
    var copy = nav
    copy.append(items[1])
    print("copy independent \(nav.count) \(copy.count) equal \(nav == nav)")

    print("format \(PlanItem.formatVerses([7, 3, 1, 2, 3, -1, 9, 8])) | \(PlanItem.formatVerses([])) | \(PlanItem.formatVerses([5]))")
    for text in ["1-3, 7", "-5-7;9 1--3 4-2", "", "x,1,,2- 4", "3-1000000", " 10 - 12 ", "1-9223372036854775807"] {
        let parsed = PlanItem.parseVerses(text)
        print("parse «\(text)» → \(parsed.prefix(12).map(String.init).joined(separator: ",")) (\(parsed.count))")
    }
    for title in ["Недільне служіння / ранок", "  ", "a:b*c?\"d\"<e>|f\\g", "Табуляція\tі\u{07}дзвінок", "План"] {
        print("fileName «\(esc(title))» → \(ServicePlan.fileName(for: title))")
    }
    print("reference \(PlanItem.reference(book: john, chapter: 3, verses: [16, 17, 18, 20])) \(PlanItem.reference(book: john, chapter: 3, verses: []))")
    print("kinds \(PlanItem.Kind.allCases.map { "\($0.rawValue)=\($0.title)" }.joined(separator: ","))")
    print("errors \(PlanError.notAPlan) | \(PlanError.unreadable("a.json", "причина")) | \(PlanError.unsupportedItem("x")) | \(PlanError.noFile)")
    print("names \(ServicePlan.formatMarker) \(ServicePlan.formatVersion) \(ServicePlan.fileExtension) \(ServicePlan.folderName) \(ServicePlan.defaultFileName) \(ServicePlan.journalFileExtension)")
}
