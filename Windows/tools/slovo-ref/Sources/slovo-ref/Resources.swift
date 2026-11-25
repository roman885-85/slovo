import Foundation
import SlovoCore

// Еталон розділу `resources` — дзеркало CoreCheck.Resources.cs.
let resModulesIni = "\u{FEFF}[Bible_RST]\nModuleName= Синодальный перевод \nModuleAuthor=РБО\n[Commentary_X]\nModuleName=Comm\n[Bible_UA Ogienko]\nModuleName=\nModuleAuthor= Огієнко\r\n[Bible_Переклад]\nModuleName=Переклад\n  [Bible_Spaced]  \nModuleName=Spaced\n[Bible_a?b#c%d:e]\n[]\n[\n[Bible_Last]\nModuleAuthor=x"
let resRegistry = "{\"version\": 12, \"hosts\": [{\"alias\":\"mz\",\"path\":\"https://mybible.zone/dl/?file=%s\",\"priority\":2},{\"alias\":\"mz\",\"path\":\"https://mirror.example/%s.zip\",\"priority\":1},{\"alias\":\"ht\",\"path\":\"http://insecure/%s\"},{\"alias\":\"gh\",\"path\":\"https://github.example/%s\",\"priority\":true},{\"alias\":\"x\"}],\"downloads\":[{\"fil\":\"AGP\",\"abr\":\"AGP\",\"des\":\"Агапе\\n76 книг \",\"lng\":\"uk\",\"upd\":\"2023-01-02\",\"siz\":\"589K\",\"url\":[\"{ht}AGP\",\"{mz}AGP\"]},{\"fil\":\"Brux.dictionary\",\"abr\":\"BRX\",\"url\":[\"{mz}Brux\"]},{\"fil\":\"UBIO'62\",\"abr\":\"UBIO'62\",\"des\":\"\",\"siz\":\"2.6M\",\"url\":[\"{mz}UBIO%2762\"]},{\"fil\":\"ФІЛ\",\"abr\":\"ФІЛ\",\"siz\":\"1G\",\"url\":[\"{mz}%D0%A4%D0%86%D0%9B\"]},{\"fil\":\"Raw\",\"abr\":\"Raw name\",\"url\":[\"{gh}Raw name'x\"],\"siz\":\"12\"},{\"fil\":\"Bad\",\"abr\":\"Bad\",\"url\":[\"mz}AGP\",\"{zz}AGP\"]},{\"fil\":\"Num\",\"abr\":5,\"url\":[\"{mz}N\"]},{\"fil\":\"Pct\",\"abr\":\"Pct\",\"url\":[\"{mz}50%zz\"],\"siz\":\"x\"},{\"fil\":\"Arr\",\"abr\":\"Arr\",\"url\":[\"{mz}A\", 5]},{\"fil\":\"Multi\",\"abr\":\"Multi\",\"des\":\"  \\n  \",\"lng\":null,\"upd\":5,\"url\":[\"{gh}M\"]}]}"
let resTranslationsCsv = "\u{FEFF}languageCode,translationId,languageName,languageNameInEnglish,dialect,homeDomain,title,description,Redistributable,Copyright,UpdateDate,publicationURL,OTbooks,OTchapters,OTverses,NTbooks,NTchapters,NTverses,DCbooks,DCchapters,DCverses,FCBHID,Certified,inScript,swordName,rodCode,textDirection,downloadable,font,shortTitle,PODISBN,script,sourceDate\r\nukr,ukr1996,Українська,Ukrainian,,x,\"Біблія, переклад \"\"Огієнка\"\"\",desc,True,c,2023-04-05,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,True,,Огієнко,,Cyrl,2020\r\neng,engkjv,English,English,,x,King James Version,\"multi\nline\",true,c,2024-01-01,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,,,KJV,,Latn,2020\nrus,rusnr,Русский,Russian,,x,НРП,d,false,c,2025-01-01,u,39,929,23145,27,260,7957,0,0,0,,,,,,ltr,True,,НРП,,Cyrl,2020\nxyz,xyz1,X,X,,x,Title,d,True,c,2022-02-02,u,0,0,0,0,0,0,0,0,0,,,,,,ltr,True,,T,,Latn,2020\nabc,abc1,A,A,,x,,d,TRUE,c,,u,1,1,5,0,0,0,0,0,x,,,,,,ltr,False,,Short,,Latn,\n\nqqq,qqq1,Q,Q,,x,, d ,True,c,2026-12-31,u,1,1, 7 ,0,0,0,0,0,0,,,,,,ltr,yes,,Коротко,,Latn,\ndeu,  ,D,D,,x,T,d,True,c,2021-01-01,u,1,1,1,0,0,0,0,0,0\nfra,fra1,F,French,,x,Bible,d,True,c,2020-01-01,u,1,1,1"
let resSongbooksHtml = "<html><body>\n<h3> Russian </h3>\n<p>* Песнь Возрождения - 3300 песен - <a href=\"songbooks/pv3300.sps\">скачать</a></p>\n<p>Гимны &quot;Надежды&quot;&nbsp;<b>новые</b> - <a  href=\"songbooks/hymns%20new.zip\" >zip</a></p>\n<h3>Ukrainian</h3>\n<p>Євангельські пісні - <a href=\"songbooks/Євангельські пісні.sps\">x</a></p>\n<p><a href=\"songbooks/pv3300.sps\">дубль</a></p>\n<h3>Klingon</h3>\n<p>Very long title that goes on and on and on and on and on and on and on and on and on and on and on - <a href=\"songbooks/long.sps\">x</a></p>\n<p> - <a HREF=\"songbooks/UPPER.SPS\">x</a></p>\n<a href=\"songbooks/not.txt\">no</a>\n</body></html>"
let resOwnCatalog = "{\"format\":\"slovo-resources\",\"updated\":\"2026-11-01\",\"items\":[{\"id\":\"bible:ubt2020\",\"kind\":\"bible\",\"title\":\"УБТ\",\"subtitle\":\"s\",\"size\":123,\"version\":\"v1\",\"url\":\"https://x/a.zip\",\"fileName\":\"ubt2020\",\"language\":\"uk\",\"extra\":1},{\"id\":\"songbook:glory\",\"kind\":\"songbook\",\"title\":\"Glory\",\"subtitle\":\"\",\"size\":0,\"version\":\"\",\"url\":\"https://x/b.zip\",\"fileName\":\"glory.songbook\"}]}"

func itemText(_ i: ResourceItem) -> String {
    "\(i.id) | \(i.kind.rawValue) | \(esc(i.title)) | \(esc(i.subtitle)) | \(i.size) | \(i.version) | \(i.url) | \(i.fileName) | \(i.language ?? "nil")"
}
func printCatalog(_ label: String, _ c: ResourceCatalog?) {
    guard let c else { print("\(label): nil"); return }
    print("\(label): format \(c.format) updated «\(c.updated)» items \(c.items.count)")
    for i in c.items { print("  " + itemText(i)) }
}
func resourceErrorKind(_ e: ResourceError) -> String {
    switch e { case .badCatalog: return "BadCatalog"; case .network: return "Network"; case .unpack: return "Unpack"; case .place: return "Place" }
}
func relative(_ path: String, _ root: String) -> String {
    for prefix in [root, "/private" + root] where path.hasPrefix(prefix + "/") { return String(path.dropFirst(prefix.count + 1)) }
    // На macOS /var — посилання на /private/var: той самий корінь буває записаний обома способами.
    return path == root || path == "/private" + root ? "." : path
}
func tree(_ root: URL) -> [String] {
    let all = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
    return all.map { url -> String in
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        return relative(url.path, root.path) + (isDir.boolValue ? "/" : "")
    }.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
}
func moduleText(_ m: any TextModule) -> String {
    var t = "\(m.info.name)|\(m.info.shortName)|\(m.info.language ?? "-")|\(m.info.rightToLeft)\n"
    for b in m.books {
        t += "\(b.index):\(b.fullName):\(b.shortNames.joined(separator: " ")):\(b.canonicalNumber.map(String.init) ?? "-")\n"
        let chapters = (try? m.chapters(ofBook: b)) ?? []
        for c in chapters { for v in c.verses { t += "\(c.number):\(v.number):\(v.text)\n" } }
    }
    return t
}
func failureCategory(_ reason: String) -> String {
    guard let colon = reason.firstIndex(of: ":") else { return reason }
    let head = String(reason[..<colon])
    let detail = reason[reason.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
    return detail == OurWords.t("в архиве нет модуля") ? "\(head): \(detail)" : head
}

func checkResources(_ data: URL) {
    print("# resources")
    printCatalog("bibleQuote", ResourceCatalog.bibleQuote(ini: resModulesIni, base: ResourceHub.bibleQuoteBase))
    printCatalog("bibleQuote2", ResourceCatalog.bibleQuote(ini: "[Bible_X]\r\nModuleName=X\r\n", base: "https://base/"))
    printCatalog("myBible", ResourceCatalog.myBible(registry: Data(resRegistry.utf8)))
    for (label, text) in [("myBible bom", "\u{FEFF}{\"version\":\"v2\",\"downloads\":[]}"), ("myBible float", "{\"version\":1.0,\"downloads\":[]}"),
                          ("myBible bool", "{\"version\":true,\"downloads\":[]}"), ("myBible none", "{\"downloads\":[]}"),
                          ("myBible null", "{\"version\":null,\"downloads\":[]}"), ("myBible bad", "{\"downloads\":5}"),
                          ("myBible array", "[1,2]"), ("myBible broken", "{\"downloads\":["), ("myBible mixed", "{\"downloads\":[{\"fil\":\"A\"},5]}")] {
        printCatalog(label, ResourceCatalog.myBible(registry: Data(text.utf8)))
    }
    printCatalog("eBible", ResourceCatalog.eBible(csv: resTranslationsCsv))
    printCatalog("eBible empty", ResourceCatalog.eBible(csv: ""))
    printCatalog("eBible noid", ResourceCatalog.eBible(csv: "title,x\nA,1\n"))
    printCatalog("softProjector", ResourceCatalog.softProjector(html: resSongbooksHtml, base: ResourceHub.softProjectorBase))
    printCatalog("softProjector noslash", ResourceCatalog.softProjector(html: resSongbooksHtml, base: "https://softprojector.org"))
    let own = try! ResourceCatalog.decode(Data(resOwnCatalog.utf8))
    printCatalog("own", own)
    print(String(data: try! own.encoded(), encoding: .utf8)!)
    for (label, text) in [("own wrong format", resOwnCatalog.replacingOccurrences(of: "slovo-resources", with: "other")),
                          ("own missing size", resOwnCatalog.replacingOccurrences(of: "\"size\":123,", with: "")),
                          ("own bad kind", resOwnCatalog.replacingOccurrences(of: "\"kind\":\"bible\"", with: "\"kind\":\"video\"")),
                          ("own no language", resOwnCatalog.replacingOccurrences(of: ",\"language\":\"uk\"", with: ""))] {
        do { printCatalog(label, try ResourceCatalog.decode(Data(text.utf8))) }
        catch let e as ResourceError { print("\(label): \(resourceErrorKind(e)) \(e)") }
        catch { print("\(label): decode fail") }
    }
    print("errors " + [ResourceError.badCatalog, .network("a"), .unpack("b"), .place("c")].map { "\($0)" }.joined(separator: " | "))
    print("sources " + ResourceHub.Source.allCases.map { s in "\(s.rawValue)=" + ResourceItem.Kind.allCases.filter { s.kinds.contains($0) }.map(\.rawValue).joined(separator: "+") }.joined(separator: ","))
    print("urls \(ResourceHub.ownCatalogURL) \(ResourceHub.bibleQuoteBase) \(ResourceHub.myBibleRegistryURL) \(ResourceHub.eBibleCatalogURL) \(ResourceHub.softProjectorPageURL) \(ResourceHub.softProjectorBase)")
    print("pct «\("Біблія 1:2?#%[]~'é😀".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)!)» «\("UBIO%2762".removingPercentEncoding ?? "nil")» «\("%zz".removingPercentEncoding ?? "nil")» «\("%FF".removingPercentEncoding ?? "nil")»")

    let fm = FileManager.default
    let outputPath = ProcessInfo.processInfo.environment["SLOVO_CHECK_OUT"].flatMap { $0.isEmpty ? nil : $0 } ?? fm.temporaryDirectory.path
    let work = URL(fileURLWithPath: outputPath).appendingPathComponent("slovo-check-res-" + UUID().uuidString)
    try! fm.createDirectory(at: work, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: work) }

    let vplFolder = work.appendingPathComponent("vpl")
    try! fm.createDirectory(at: vplFolder.appendingPathComponent("a"), withIntermediateDirectories: true)
    try! fm.createDirectory(at: vplFolder.appendingPathComponent("b"), withIntermediateDirectories: true)
    try! Data("r".utf8).write(to: vplFolder.appendingPathComponent("a/readme.txt"))
    try! Data("h".utf8).write(to: vplFolder.appendingPathComponent(".hidden.txt"))
    let vplText = "\u{FEFF}JHN 1:1 In the beginning was the Word\r\nJHN 1:2  The same \r\nJHN 1:3\r\nGEN 2:1-3 Thus the heavens\nXYZ 1:1 no\njhn 3:16 For God so loved\nREV 22:21 The grace\n\nPSA 23 1 The LORD\nMAT 1::1 Колінна\nSNG 1:1 Song\nPSA x:1 bad"
    try! Data(vplText.utf8).write(to: vplFolder.appendingPathComponent("b/tst_vpl.txt"))
    print("findText \(relative(EBibleVPL.findText(in: vplFolder)?.path ?? "-", vplFolder.path))")
    try! fm.removeItem(at: vplFolder.appendingPathComponent("b/tst_vpl.txt"))
    print("findText fallback \(relative(EBibleVPL.findText(in: vplFolder)?.path ?? "-", vplFolder.path)) empty \(EBibleVPL.findText(in: work.appendingPathComponent("nothing"))?.path ?? "-")")
    let vplPath = work.appendingPathComponent("tst_vpl.txt")
    try! Data(vplText.utf8).write(to: vplPath)
    let moduleDb = work.appendingPathComponent("out").appendingPathComponent("TST.SQLite3")
    let count = try! EBibleVPL.convert(text: vplPath, to: moduleDb, description: .init(title: "Тест", abbreviation: "TST", language: "en", copyright: "© x · eBible.org", rightToLeft: true))
    let vplModule = try! MyBibleModule(fileAt: moduleDb)
    print("vpl verses \(count) files \(tree(work.appendingPathComponent("out")).joined(separator: ","))")
    print(esc(moduleText(vplModule)))
    vplModule.releaseCache()
    try! Data("nothing here\nXYZ 1:1 a\n".utf8).write(to: work.appendingPathComponent("none.txt"))
    do { _ = try EBibleVPL.convert(text: work.appendingPathComponent("none.txt"), to: work.appendingPathComponent("out/N.SQLite3"), description: .init(title: "", abbreviation: "", language: "", copyright: "", rightToLeft: false)) }
    catch let f as EBibleVPL.Failure {
        if case .noVerses = f { print("vpl failure NoVerses \(f)") } else { print("vpl failure Database \(f)") }
    } catch {}

    let layout = ResourceLayout(modulesFolder: work.appendingPathComponent("data/Modules"))
    try! fm.createDirectory(at: layout.modules, withIntermediateDirectories: true)
    try! Data("x".utf8).write(to: layout.modules.appendingPathComponent("glory.vbm"))
    for kind in ResourceItem.Kind.allCases {
        let item = ResourceItem(id: "t:" + kind.rawValue, kind: kind, title: "T", url: "", fileName: kind == .songbook ? "glory.songbook" : "X")
        print("layout \(kind.rawValue) → \(relative(layout.destination(for: item).path, work.path)) present \(layout.isPresent(item))")
    }
    print("layout root \(relative(layout.dataRoot.path, work.path)) modules \(relative(layout.modules.path, work.path))")

    func stage(_ name: String, _ files: [String], _ fileName: String) {
        let staging = work.appendingPathComponent("stage-" + name)
        for file in files {
            let path = staging.appendingPathComponent(String(file.hasSuffix("/") ? file.dropLast() : Substring(file)))
            if file.hasSuffix("/") { try! fm.createDirectory(at: path, withIntermediateDirectories: true) }
            else {
                try! fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                try! Data("x".utf8).write(to: path)
            }
        }
        try! fm.createDirectory(at: staging, withIntermediateDirectories: true)
        let found = ResourceHub.payload(in: staging, for: ResourceItem(id: "p", kind: .bible, title: "P", url: "", fileName: fileName))
        let text: String
        switch found {
        case .item(let u)?: text = "Item " + relative(u.path, staging.path)
        case .files(let u)?: text = "Files " + relative(u.path, staging.path)
        case nil: text = "nil"
        }
        print("payload \(name) → \(text)")
    }
    stage("nested", ["nested/Modules/glory.vbm", "other.vbm"], "glory.vbm")
    stage("hidden", [".SQLite3", "readme.txt"], "X.SQLite3")
    stage("two", ["a.sqlite3", "b.SQLite3"], "X.SQLite3")
    stage("ini", ["Wrapper/Mod/bibleqt.ini", "Wrapper/Mod/01.htm", "Wrapper/x/y/BIBLEQT.INI"], "Mod")
    stage("flat", ["bibleqt.ini", "01.htm"], "Mod")
    stage("single", ["Fonts/a.ttf"], "Fonts")
    stage("many", ["a/x", "b/y"], "Z")
    stage("macosx", ["__MACOSX/x.vbm", "real/x.vbm"], "x.vbm")
    stage("mybible", ["deep/UKJV.bbl.mybible"], "UKJV.mybible")
    stage("empty", [], "Z")

    guard let fixtures = ProcessInfo.processInfo.environment["SLOVO_RES_FIXTURES"], !fixtures.isEmpty else {
        print("install skipped: no SLOVO_RES_FIXTURES"); return
    }
    func url(_ name: String) -> String { URL(fileURLWithPath: fixtures).appendingPathComponent(name).absoluteString }
    let items: [ResourceItem] = [
        ResourceItem(id: "bq:TestBQ", kind: .bible, title: "Тест BQ", version: "1", url: url("bq-module.zip"), fileName: "TestBQ"),
        ResourceItem(id: "bq:Flat", kind: .bible, title: "Flat", version: "2", url: url("bq-flat.zip"), fileName: "Flat"),
        ResourceItem(id: "mb:MB", kind: .bible, title: "MB", version: "3", url: url("mybible.zip"), fileName: "MB.SQLite3"),
        ResourceItem(id: "mb:Named", kind: .bible, title: "Named", version: "4", url: url("mybible-named.zip"), fileName: "Named.SQLite3"),
        ResourceItem(id: "mb:Two", kind: .bible, title: "Two", version: "5", url: url("mybible-two.zip"), fileName: "Two.SQLite3"),
        ResourceItem(id: "eb:tst", kind: .bible, title: "eBible тест", subtitle: "tst · Test · 2024", size: 0, version: "6", url: url("ebible.zip"), fileName: "tst.SQLite3", language: "en"),
        ResourceItem(id: "eb:none", kind: .bible, title: "none", version: "7", url: url("ebible-empty.zip"), fileName: "none.SQLite3"),
        ResourceItem(id: "songbook:bel", kind: .songbook, title: "Bel", version: "8", url: url("songbook-vbm.zip"), fileName: "bel.songs.vbm"),
        ResourceItem(id: "songbook:eng", kind: .songbook, title: "Eng", version: "9", url: url("songbook-other.zip"), fileName: "englishworship.vbm"),
        ResourceItem(id: "songbook:wrong", kind: .songbook, title: "Wrong", version: "18", url: url("songbook-other.zip"), fileName: "english.songbook"),
        ResourceItem(id: "sp:bare", kind: .songbook, title: "Голий SP", version: "10", url: url("bare.sps"), fileName: "bare.songbook"),
        ResourceItem(id: "sp:zip", kind: .songbook, title: "SP zip", version: "11", url: url("sps.zip"), fileName: "spzip.songbook"),
        ResourceItem(id: "backgrounds:a", kind: .backgrounds, title: "Фони", version: "12", url: url("backgrounds.zip"), fileName: "BackGrounds"),
        ResourceItem(id: "templates:a", kind: .templates, title: "Шаблони", version: "13", url: url("templates.zip"), fileName: "Templates"),
        ResourceItem(id: "bible:empty", kind: .bible, title: "Empty", version: "14", url: url("empty.zip"), fileName: "Empty"),
        ResourceItem(id: "bible:notzip", kind: .bible, title: "Not zip", version: "15", url: url("notzip.zip"), fileName: "NotZip"),
        ResourceItem(id: "bible:missing", kind: .bible, title: "Missing", version: "16", url: url("missing.zip"), fileName: "Missing"),
        ResourceItem(id: "bible:badurl", kind: .bible, title: "Bad url", version: "17", url: "not a url", fileName: "Bad"),
    ]
    try! Data("old twin".utf8).write(to: layout.modules.appendingPathComponent("bare.vbm"))
    let hub = ResourceHub(layout: layout)
    let lock = NSLock()
    var log: [ResourceHub.Progress] = []
    var result: ResourceHub.Outcome?
    let done = DispatchSemaphore(value: 0)
    hub.install(items, progress: { p in lock.lock(); log.append(p); lock.unlock() }, completion: { o in result = o; done.signal() })
    done.wait()
    let outcome = result!
    print("installed " + outcome.installed.map { $0.id }.joined(separator: ","))
    for (item, reason) in outcome.failures { print("failed \(item.id): \(failureCategory(reason))") }
    var order: [String] = []
    for p in log where !order.contains(p.item.id) { order.append(p.item.id) }
    for id in order {
        let group = log.filter { $0.item.id == id }
        let fractions = group.map(\.fraction)
        let monotonic = zip(fractions, fractions.dropFirst()).allSatisfy { a, b in a == nil || b == nil || b! >= a! }
        print("progress \(id): first \(fractions[0] ?? -1) last \(fractions.last! ?? -1) monotonic \(monotonic) index \(group[0].index)/\(group[0].total)")
    }
    print("tree " + tree(work.appendingPathComponent("data")).joined(separator: " "))
    for module in ["TestBQ", "Flat"] {
        print("module \(module) \(fnv(moduleText(try! BibleModule(directory: layout.modules.appendingPathComponent(module)))))")
    }
    for module in ["MB.SQLite3", "Named.SQLite3", "tst.SQLite3"] {
        let opened = try! MyBibleModule(fileAt: layout.modules.appendingPathComponent(module))
        print("module \(module) \(esc(moduleText(opened)))")
        opened.releaseCache()
    }
    for book in ["bel.songs.songbook", "englishworship.songbook", "bare.songbook", "spzip.songbook"] {
        var opened = try! SongBook(fileAt: layout.modules.appendingPathComponent(book))
        let temporary = opened.shortName.hasPrefix("slovo-sps-") && opened.shortName.utf16.count == 46
        if temporary { opened.shortName = "slovo-sps-<UUID>" }
        print("songbook \(book) \(songDigest(opened)) temporary short name \(temporary)")
    }
    let ledger = ResourceLedger.load()
    print("ledger " + ledger.installed.filter { pair in items.contains { $0.id == pair.key } }.sorted { Array($0.key.utf16).lexicographicallyPrecedes(Array($1.key.utf16)) }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
}
