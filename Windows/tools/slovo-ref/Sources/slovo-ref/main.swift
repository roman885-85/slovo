import Foundation
import SlovoCore
import CoreGraphics

// Еталон для звірки з C#-ядром: друкує те саме й у тому самому вигляді, що CoreCheck.
setvbuf(stdout, nil, _IOFBF, 1 << 20)
let args = CommandLine.arguments
guard args.count > 1 else { print("slovo-ref <тека даних> [розділ]"); exit(2) }
let data = URL(fileURLWithPath: args[1])
let only = args.count > 2 ? args[2] : ""
func want(_ s: String) -> Bool { only.isEmpty || only == s }

func fnv(_ text: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in text.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "%016llx", h)
}
func ranges(_ r: [Range<Int>]) -> String { r.map { "\($0.lowerBound)-\($0.upperBound)" }.joined(separator: ",") }
func fold(_ s: String) -> String { s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil) }

let modulesURL = data.appendingPathComponent("Modules")
let library = ModuleLibrary(modulesDirectory: modulesURL)

if want("modules") {
    print("# modules")
    print("modules \(library.modules.count) songs \(library.songFiles.count) failures \(library.failures.count)")
    for f in library.failures { print("failure \(f.directory): \(f.reason)") }
    for s in library.songFiles { print("song \(s.lastPathComponent)") }
    for m in library.modules {
        var chapters = 0, verses = 0
        var text = ""
        var foldedText = ""
        var mismatched: [String] = []
        for b in m.books {
            let cs = (try? m.chapters(ofBook: b)) ?? []
            chapters += cs.count
            for c in cs {
                verses += c.verses.count
                text += "\(b.index):\(c.number):\(c.heading ?? "-")\n"
                for v in c.verses { text += "\(c.number):\(v.number):\(v.text)\n"; foldedText += fold(v.text) + "\n" }
            }
            if b.chapterCount > 0, cs.count != b.chapterCount { mismatched.append("\(b.fullName): parsed \(cs.count) declared \(b.chapterCount)") }
        }
        print("module \(m.identifier) | \(m.format.title) | \(m.displayName) | \(m.info.shortName) | books \(m.books.count) chapters \(chapters) verses \(verses) | text \(fnv(text)) | folded \(fnv(foldedText))")
        print("  info: bible=\(m.info.isBible) ot=\(m.info.hasOldTestament) nt=\(m.info.hasNewTestament) strong=\(m.info.hasStrongNumbers) zero=\(m.info.chapterZero) rtl=\(m.info.rightToLeft) chapterSign=\(m.info.chapterSign) verseSign=\(m.info.verseSign) filter=\(m.info.htmlFilter.joined(separator: ",")) lang=\(m.info.language ?? "-")")
        for line in mismatched { print("  ! \(line)") }
        for b in m.books { print("  book \(b.index) \(b.fileName) | \(b.fullName) | \(b.shortNames.joined(separator: " ")) | \(b.chapterCount) | \(b.canonicalNumber.map(String.init) ?? "-")") }
        m.releaseCache()
    }
}

if want("verses") {
    print("# verses")
    for m in library.modules {
        for (canon, ch, vs) in [(500, 3, 16), (10, 1, 1), (230, 22, 1), (230, 151, 1), (360, 2, 28), (360, 3, 1), (460, 4, 1), (190, 1, 1)] {
            guard let book = m.books.first(where: { $0.canonicalNumber == canon }) else { print("\(m.identifier) \(canon) \(ch):\(vs) — no book"); continue }
            let chapter: Chapter? = (try? m.chapter(ch, ofBook: book)) ?? nil
            let verse = chapter?.verse(vs)
            print("\(m.identifier) \(book.buttonTitle) \(ch):\(vs) = \(verse?.text ?? "—")")
            if let h = chapter?.heading { print("  heading: \(h)") }
        }
    }
}

let samples = ["Ів 3:16", "Іван 3:16", "Ин 3:16", "Быт 1:1-3", "1Кор 13", "1 Кор 13:4-7", "John 3:16", "Пс 22", "Мт 5:3,5,7", "иак 4 -", "Об 22:21", "1 Ів 1:9", "Йоіл 3:1", "Иоан", "ин 3 16 18", "Буття 1", "Ps 23:1", "Gen 1:1-5", "коринф 1", "иис нав 1", "1-9223372036854775807", "Пс 119:1-333", "Мал 4", "Мк. 16:15", "Рим 8:28-39,1"]
if want("refs") {
    print("# refs")
    for m in library.modules {
        for s in samples {
            let found = ReferenceParser.parse(s, in: m)
            print("\(m.identifier) «\(s)» → " + found.map { "\($0.book.fullName)/\($0.chapter.map(String.init) ?? "-")/\($0.verses.map(String.init).joined(separator: ","))/\($0.match.rawValue)/\($0.isChapterValid)/\($0.displayText)" }.joined(separator: " ; "))
            let resolved = ReferenceParser.resolve(s, in: m)
            print("  resolve: \(resolved?.displayText ?? "—")")
            if let a = ScriptureAddress.parse(s, books: m.books) {
                print("  address: \(a.book.fullName) ch=\(a.chapter.map(String.init) ?? "-") first=\(a.firstVerse.map(String.init) ?? "-") last=\(a.lastVerse.map(String.init) ?? "-") whole=\(a.wantsWholeChapter) listed=\(a.listedVerses.map(String.init).joined(separator: ",")) sel=\(a.verseNumbers(available: Array(1...40)).map(String.init).joined(separator: ",")) disp=\(a.displayText(verses: [1,2,3]))")
            } else { print("  address: —") }
        }
    }
    print("verseList: " + ReferenceParser.verseList(in: "7,3,5-9,12–14,20-18,1-9223372036854775807").map(String.init).joined(separator: ","))
    print("format: " + ReferenceParser.format(verses: [3,4,5]) + " " + ReferenceParser.format(verses: [1,3,5]) + " " + ReferenceParser.format(verses: []))
    print("position: " + ReferenceFormat.position(chapter: 3, verses: [1,2,3,7,9,10]) + " " + ReferenceFormat.position(chapter: 5, verses: []))
}

if want("shortest") {
    print("# shortest")
    for m in library.modules {
        print("\(m.identifier): " + ShortBookNames.shortest(in: m.books).map { "\($0.name)=\($0.abbreviation)" }.joined(separator: "; "))
    }
}

if want("search") {
    print("# search")
    for m in library.modules {
        for q in ["Бог любов", "возлюбил", "світ", "йосип", "иосиф", "Ісус Христос", "  ", "Господь, Бог!", "аа", "ss"] {
            for whole in [false, true] {
                let o = TextSearch.run(q, in: m, options: TextSearch.Options(limit: 300, wholeWords: whole))
                print("\(m.identifier) «\(q)» whole=\(whole) hits \(o.hits.count) truncated \(o.isTruncated) scanned \(o.scannedVerses)")
                for h in o.hits.prefix(4) { print("  \(h.reference) [\(ranges(h.highlights))] \(h.segments.filter(\.isMatch).map(\.text).joined(separator: "|"))") }
            }
        }
        m.releaseCache()
    }
}

if want("numbering") {
    print("# numbering")
    let base = NumberingBase.load(dataRoot: data)
    print("base standards \(base.standards.map { "\($0.code)=\($0.description)" }.joined(separator: "; ")) modules \(base.modules.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")) rules \(base.rules.count)")
    print("rule0 \(base.rules.first.map { "\($0.kind.rawValue) \($0.sourceText) → \($0.targetText)" } ?? "-")")
    let engine = VerseNumbering.shared
    let ok = engine.loadRules(databaseAt: data.appendingPathComponent("inconsistencies.sqlite3"))
    print("rules loaded \(ok) count \(engine.ruleCount) corrections \(engine.correctionCount) standards \(engine.standards.map { "\($0.id)=\($0.title)" }.joined(separator: "; "))")
    let ru = engine.standard(id: "ru"), en = engine.standard(id: "en"), ua = engine.standard(id: "ua"), pl = engine.standard(id: "pl")
    for (b, c, vs, f, t) in [(230, 22, [1], ru, en), (230, 22, [1], en, ru), (230, 22, [1,2,3], ua, ru), (230, 22, [1], ru, ua), (230, 22, [1], ua, pl), (230, 12, [6], ru, en), (230, 113, [9], ru, en), (360, 2, [27,28,29], ru, ua), (460, 4, [1,2,6], ru, ua), (110, 4, [21,22], ru, ua), (230, 9, [], ru, en), (230, 151, [1], ru, en), (350, 11, [1], ru, en), (40, 30, [1,2], ru, en), (510, 19, [40], ru, en), (230, 51, [3], ua, pl)] {
        let spans = engine.translate(book: b, chapter: c, verses: vs, from: f, to: t, verseCount: { _ in 20 })
        print("\(f.id)→\(t.id) \(b) \(c):\(vs.map(String.init).joined(separator: ",")) = " + spans.map { "\($0.chapter):\($0.verses.map(String.init).joined(separator: ","))" }.joined(separator: " ") + " | " + engine.trace(book: b, chapter: c, verse: vs.first ?? 1, from: f, to: t))
    }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-ref-numbering-\(UUID().uuidString).json")
    try? FileManager.default.copyItem(at: data.appendingPathComponent("numbering.json"), to: tmp)
    let assignments = NumberingAssignments(fileURL: tmp)
    for a in assignments.apply(to: engine, modules: library.modules) { print("assign \(a.moduleID) = \(a.standardID) [\(a.source.rawValue)] \(a.reason)") }
    for m in library.modules { print("standard of \(m.identifier) = \(engine.standard(of: m).id)") }
    let empty = NumberingAssignments(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("slovo-ref-empty-\(UUID().uuidString).json"))
    for m in library.modules {
        let e = NumberingGuess.evidence(for: m)
        print("evidence \(m.identifier): count=\(e.psalmCount.map(String.init) ?? "-") p9=\(e.psalm9.map(String.init) ?? "-") p3=\(e.psalm3.map(String.init) ?? "-") p147=\(e.psalm147.map(String.init) ?? "-") e8=\(e.ecclesiastes8.map(String.init) ?? "-") r16=\(e.romans16.map(String.init) ?? "-") guess=\(empty.assignment(for: m).standardID)")
    }
    try? FileManager.default.removeItem(at: tmp)
    // Паралельні адреси між перекладами
    for from in library.modules {
        for to in library.modules where to.identifier != from.identifier {
            for (canon, ch, vs) in [(230, 22, [1]), (230, 9, [21]), (360, 2, [28]), (460, 4, [1]), (110, 4, [21])] {
                guard let book = from.books.first(where: { $0.canonicalNumber == canon }), let other = to.counterpart(of: book), let chapters = try? to.chapters(ofBook: other) else { continue }
                let spans = engine.existingSpans(book: book, chapter: ch, verses: vs, from: engine.standard(of: from), to: to, chapters: chapters)
                let suffix = engine.parallelSuffix(book: book, chapter: ch, verses: vs, from: engine.standard(of: from), to: to, chapters: chapters)
                print("parallel \(from.identifier)→\(to.identifier) \(canon) \(ch):\(vs.map(String.init).joined(separator: ",")) = " + spans.map { "\($0.chapter):\($0.verses.map(String.init).joined(separator: ","))" }.joined(separator: " ") + " suffix «\(suffix)»")
            }
        }
    }
    print("near: \(ModuleNameMatch.nearest("UA_Ogienko", among: ["ua_ogienka", "ubt2020"]) ?? "-") \(ModuleNameMatch.nearest("ubt2022", among: ["ubt2020"]) ?? "-")")
}

if want("lang") {
    print("# lang")
    let catalog = LanguageCatalog(directory: data.appendingPathComponent("Language"))
    print("languages \(catalog.languages.count): " + catalog.languages.map { "\($0.code)=\($0.displayName)" }.joined(separator: ", "))
    for code in ["ru", "uk", "en"] {
        guard let l = catalog.language(code: code) else { print("\(code) missing"); continue }
        print("\(code) forms \(l.forms.count) lines \(l.forms.values.reduce(0) { $0 + $1.count })")
        for key in ["Label9", "Label8", "Label1", "Label3", "N1", "N18", "N13", "N39", "N14", "N4", "N24", "N25", "N35", "N34"] {
            let e = l.entry(key, form: "MainForm")
            print("  MainForm.\(key) = «\(e?.caption ?? "—")» hint «\(e?.hint ?? "—")»")
        }
        for key in ["Label21", "BBOk", "Label44"] { print("  SettingsForm.\(key) = «\(l.caption(key, form: "SettingsForm", default: "?"))»") }
        var all = ""
        for form in l.forms.keys.sorted() { for key in l.forms[form]!.keys.sorted() { let e = l.forms[form]![key]!; all += "\(form).\(key)=\(e.caption)|\(e.hint ?? "")\n" } }
        print("  digest \(fnv(all))")
    }
}

if want("ourwords") {
    print("# ourwords")
    if let d = try? Data(contentsOf: URL(fileURLWithPath: args.count > 3 ? args[3] : "en.json")),
       let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let w = j["words"] as? [String: String] { OurWords.register(w, for: "en") }
    print("coverage " + OurWords.coverage.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ","))
    print("duplicates " + OurWords.duplicateWords.joined(separator: "|"))
    print("keys \(OurWords.russianKeys.count) digest \(fnv(OurWords.russianKeys.joined(separator: "\n")))")
    let c = OurWords.covered(in: "en"); print("covered en \(c.translated)/\(c.total) missing \(c.missing.count)")
    for lang in ["ru", "uk", "en", "de"] {
        OurWords.language = lang
        print("\(lang): \(OurWords.t("Всё загруженное и настроенное лежит в папке: %s", "/x")) | \(OurWords.t("Сдвиг глав")) | \(OurWords.t("в папке %s нет bibleqt.ini", "A", "B")) | \(OurWords.t("Растворение")) | \(OurWords.t("%s из %s", "1")) | \(OurWords.hasRussianKey("Сдвиг глав"))")
    }
    var all = ""
    OurWords.language = "uk"
    for k in OurWords.russianKeys { all += k + "=" + OurWords.t(k) + "\n" }
    print("uk digest \(fnv(all))")
    OurWords.language = "en"; all = ""
    for k in OurWords.russianKeys { all += k + "=" + OurWords.t(k) + "\n" }
    print("en digest \(fnv(all))")
    OurWords.language = "ru"
}

let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if want("ini") {
    print("# ini")
    let iniURL = data.appendingPathComponent("Slovo.ini")
    let config = try! IniSettings(fileAt: iniURL)
    print("located \(IniSettings.locateConfig()?.lastPathComponent ?? "-") sections \(config.sections.count) keys \(config.sections.values.reduce(0) { $0 + $1.count })")
    print("order " + config.moduleEntries().map { "\($0.name):\($0.isEnabled)" }.joined(separator: ","))
    let options = ProgramOptions(config: config)
    print(String(data: try! encoder.encode(options), encoding: .utf8)!)
    print("ndiFrameRate \(options.ndiFrameRate) placement \(SlideWindowPlacement(options: options).summary)")
    let settings = SlovoSettings(config: config, hotkeySets: HotkeySets.load(), dataRoot: data)
    print(String(data: try! encoder.encode(settings), encoding: .utf8)!)
    let style = SlideStyle(config: config, section: "Bible", dataRoot: data)
    print(String(data: try! encoder.encode(style), encoding: .utf8)!)
    let textStyle = SlideStyle(config: config, section: "Text", dataRoot: data)
    print(String(data: try! encoder.encode(textStyle), encoding: .utf8)!)
    let out = OutputSettings(config: config)
    print("output \(out.monitorIndex) \(out.showVerseNumbers) \(out.showSecondaryVerseNumbers) \(out.hideSlideDuration) \(out.slideWidth)x\(out.slideHeight)")
    let rf = ReferenceFormat(config: config)
    print("refformat \(rf.combinedMain.rawValue) \(rf.combinedSecondary.rawValue) \(rf.separateMain.rawValue) \(rf.separateSecondary.rawValue)")
    let palette = SongChunkPalette(config: config)
    print("palette " + palette.chunks.map { "\($0.key)=\($0.names.count)" }.joined(separator: ",") + " | " + ["Куплет 2", "Припев:", "1 Куплет", "Бридж", "Zwrotka3", "Кода.", "xyz"].map { "\($0)→\(palette.chunk(for: $0)?.key ?? "-")/\(SongChunkPalette.number(in: $0).map(String.init) ?? "-")" }.joined(separator: ","))
    let pag = PlainTextDocument.Pagination(config: config, section: "Text", style: textStyle)
    print("pagination \(pag.charactersPerLine) \(pag.linesPerPage) \(pag.minimumFillPercent) \(pag.splitsIntoPages) \(pag.splitsIntoParagraphs) \(pag.wrapsWords)")
    let doc = PlainTextDocument(title: "Оголошення", body: "Дорогі! Настройтеся на служіння.\r\n\r\nСьогодні о 18:00 молитовне зібрання в малому залі, приходьте всі, хто може, і запрошуйте друзів та рідних.\nЗавтра — недільна школа.\n\n\nДуже-довге-слово-яке-не-влазить-у-жоден-рядок-слайда-ніяк-зовсім")
    for p in [PlainTextDocument.Pagination(), pag, PlainTextDocument.Pagination(splitsIntoPages: false), PlainTextDocument.Pagination(splitsIntoParagraphs: true), PlainTextDocument.Pagination(charactersPerLine: 10, linesPerPage: 2, showsPageNumber: true)] {
        print("pages " + doc.pages(p).map { $0.replacingOccurrences(of: "\n", with: "⏎") }.joined(separator: " ‖ "))
        print("slides " + doc.slides(p).map { "\($0.reference)|\($0.isBlank)" }.joined(separator: " ‖ "))
    }
    print("summary \(doc.summary(limit: 40)) | snippet \(doc.snippet(limit: 30))")
    print("chunks " + PlainTextDocument.chunks(of: "один два три чотири п'ять шість сім вісім", budget: 9).joined(separator: "|"))
}

if want("hotkeys") {
    print("# hotkeys")
    let sets = try! HotkeySets(fileAt: data.appendingPathComponent("hotkeys.ini"))
    print("order " + sets.order.joined(separator: "|") + " preferred \(sets.preferredSetName ?? "-")")
    for name in sets.order { print("  \(name): " + sets.hotkeys(inSet: name).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.text)/\($0.value.functionNumber.map(String.init) ?? "-")" }.joined(separator: ",")) }
    print(sets.serialized())
    print("located \(HotkeySets.locateFile()?.lastPathComponent ?? "-") load \(HotkeySets.load().order.joined(separator: "|"))")
    for t in ["ctrl+alt+b", "f5", "esc", " Shift + space ", "", "+", "Ctrl+", "pgdn", "x"] { print("parse «\(t)» → \(Hotkey(text: t)?.text ?? "nil")") }
    print(String(data: try! encoder.encode(sets), encoding: .utf8)!)
}

if want("settingsjson") {
    print("# settingsjson")
    let d = try! Data(contentsOf: data.appendingPathComponent("settings.json"))
    if let s = try? JSONDecoder().decode(SlovoSettings.self, from: d) {
        print("decoded modules \(s.modules.count) webSlides \(s.webSlides.count) chunks \(s.songChunks.count)")
        print(String(data: try! encoder.encode(s), encoding: .utf8)!)
    } else { print("decode failed") }
    // Без обов'язкового поля — відмова
    var j = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
    var o = j["options"] as! [String: Any]; o.removeValue(forKey: "updateInterval"); j["options"] = o
    print("missing required → \((try? JSONDecoder().decode(SlovoSettings.self, from: try! JSONSerialization.data(withJSONObject: j))) == nil ? "fail" : "ok")")
    o = j["options"] as! [String: Any]; o["updateInterval"] = 7; o.removeValue(forKey: "ndiSendAudio"); o["buttonAction"] = 5; j["options"] = o
    print("bad enum → \((try? JSONDecoder().decode(SlovoSettings.self, from: try! JSONSerialization.data(withJSONObject: j))) == nil ? "fail" : "ok")")
}

if want("history") {
    print("# history")
    let h = ServiceHistory.read(contentsOf: data.appendingPathComponent("History.ini"))
    print("records \(h.count)")
    for r in h.records { print("  \(r.identity) | \(r.caption) | \(r.reference) | v=\(r.verses.count)") }
    print(h.journal().xml())
    let raw = try! JournalFile.read(contentsOf: data.appendingPathComponent("History.ini"))
    print("raw total \(raw.totalCount) looks \(JournalFile.looksLikeJournal(try! String(contentsOf: data.appendingPathComponent("History.ini"), encoding: .utf8)))")
    print(fnv(raw.xml()))
    let j = JournalFile.parse("<x><Journal Name=\"Text\"><Item Caption='a &amp; b &#1049; &#x41; &nbsp; &unknown;' Bad=noquote Next=\"q\" />\n<Item/></Journal><Journal Name=\"Bible\"/><Item Caption=\"lost\"/><Journal Name=\"Songs\"><Item A=\"1\r\n2\" B=\"x\u{0301}&\"/></Journal>")
    print(j.xml())
}

if want("text") {
    print("# text")
    for s in ["<p>1 <b>Вначале</b> сотворил <s>7225</s>Бог&nbsp;небо&amp;землю</p>", "a<br>b<div>c</div>&#x41;&#66;&#xD800;&mdash;&unknown;x", "<s>drop<s>inner</s>tail</s>after", "unclosed <tag", "  lots   of\u{200B}\n\t space  \r\n", "&#1049;&#123456789;", "a \u{0301}b"] {
        print("plain «\(HTMLText.plain(s).unicodeScalars.map { $0.value < 128 ? String($0) : String(format: "\\u{%X}", $0.value) }.joined())»")
    }
    for s in ["Εν<E>В начале<Fr>.<RF>прим<Rf> было <TS>Заголовок<Ts>Слово<X>logos<x>, и<D>слово", "<FI>курсив<Fi> и <RF q=a>сноска без конца"] {
        print("mysword «\(MySwordText.plain(s))»")
    }
    for s in ["Йосип і Ёлка", "ǅungla ΐ ᾳ ß ﬁ İ ı", "сло\u{0301}во", "א\u{05B8}ב", "a\u{05B8}b", "Ԑ\u{0301}ԑ\u{0301}", "e\u{0301}\u{0308}x"] {
        print("fold «\(fold(s).unicodeScalars.map { String(format: "%04X", $0.value) }.joined(separator: " "))»")
    }
    let names = ["psalm_lviv_2008-if.songbook", "psalm2000.songbook", "UA_Gyzha", "ubt2020", "umt'07", "glory.songbook", "UA_Kulish", "p_s_ua.songbook", "ivangeliya2.songbook", "vidrodzhennia.songbook", "a10", "a9", "A2", "Ёлка", "елка", "Яблуко", "ábc", "abc", "Zebra", "_x", "1.jpg", "10.jpg", "2.jpg"]
    print("sort " + names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: ","))
}

if want("slides") {
    print("# slides")
    let enc2 = JSONEncoder(); enc2.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let config = try! IniSettings(fileAt: data.appendingPathComponent("Slovo.ini"))
    let base = SlideStyle(config: config, section: "Bible", dataRoot: data)
    let schemes = SchemeLibrary(dataRoot: data, config: config)
    print("templates \(schemes.templates.count) failures \(schemes.failures.count) height \(schemes.designHeight)")
    for (file, reason) in schemes.failures.sorted(by: { $0.key < $1.key }) { print("  failure \(file): \(reason)") }
    for t in schemes.templates {
        print("template \(t.name) | \(t.scheme.name) | bg \(t.backgroundURL?.lastPathComponent ?? "-") | thumbs \(t.singleThumbnailURL?.lastPathComponent ?? "-") \(t.dualThumbnailURL?.lastPathComponent ?? "-") | presets \(t.scheme.presetNames.joined(separator: ",")) | elements \(t.scheme.elements.count)")
        for e in t.scheme.elements {
            let p1 = e.placement(.single), p2 = e.placement(.dual)
            print("  el \(e.name) type \(e.rawType) kind \(e.kind.map { "\($0.rawValue)" } ?? "-") img \(e.imageName ?? "-") mask \(e.imageMaskName ?? "-") var \(e.hasVariantParameters) box1 \(p1.box.x),\(p1.box.y),\(p1.box.width),\(p1.box.height) box2 \(p2.box.x),\(p2.box.y),\(p2.box.width),\(p2.box.height) anchor \(p1.anchor.rawValue)/\(p1.anchor.horizontal.rawValue)/\(p1.anchor.vertical.rawValue) scene \(e.scene(.single).map { "\($0.fx)/\($0.isAnimated)/\($0.fromOpacity)/\($0.fromScale)/\($0.moveFromX)/\($0.duration)" } ?? "-") imageURL \(t.imageURL(named: e.imageName)?.lastPathComponent ?? "-")")
        }
        print(String(data: try! enc2.encode(t.scheme), encoding: .utf8)!)
        for v in [SlideScheme.Variant.single, .dual] { print(String(data: try! enc2.encode(schemes.slideStyle(for: t, base: base, variant: v)), encoding: .utf8)!) }
        print(String(data: try! enc2.encode(SlidePreset(template: t, base: base, designHeight: schemes.designHeight)), encoding: .utf8)!)
    }
    print("named \(schemes.template(named: "springfade")?.name ?? "-") \(schemes.slideStyle(named: "nonexistent", base: base) == nil)")
    let presets = PresetLibrary(folder: data.appendingPathComponent("Presets"))
    print("presets \(presets.presets.count): " + presets.presets.map { "\($0.name)/\($0.forSongs)" }.joined(separator: ","))
    for kind in OutputKind.allCases { print("  assign \(kind.rawValue) = \(presets.preset(for: kind)?.name ?? "-") songs \(presets.preset(for: kind, songs: true)?.name ?? "-")") }
    for p in presets.presets { print(String(data: try! enc2.encode(p), encoding: .utf8)!) }
    for (name, make) in [("standard", SlidePreset.standard), ("song", SlidePreset.song), ("transparent", SlidePreset.transparent), ("stage", SlidePreset.stage)] as [(String, (String, SlideStyle) -> SlidePreset)] {
        print(name + " " + String(data: try! enc2.encode(make(name, base)), encoding: .utf8)!)
    }
    let tolerant = Data("{\"id\":\"DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C\",\"name\":\"T\",\"canvasWidth\":800,\"canvasHeight\":600,\"background\":{\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":1},\"fillMode\":\"fit\",\"dim\":0,\"blurRadius\":0,\"isTransparent\":false},\"objects\":[{\"kind\":\"image\",\"id\":\"51722B82-5CF8-4003-B90E-AD55985257B8\"},{\"kind\":\"songTitle\",\"id\":\"51722B82-5CF8-4003-B90E-AD55985257B9\",\"shadow\":{\"isEnabled\":true},\"secondVariant\":{\"opacity\":0.5}}],\"transition\":\"spin\",\"transitionDuration\":1}".utf8)
    if let p = try? JSONDecoder().decode(SlidePreset.self, from: tolerant) { print("tolerant " + String(data: try! enc2.encode(p), encoding: .utf8)!) } else { print("tolerant failed") }
    let strict = Data("{\"id\":\"DBA9AB16-2069-4A30-8EBA-78EAD9E2F26C\",\"name\":\"T\",\"canvasWidth\":800,\"background\":{\"color\":{\"red\":0,\"green\":0,\"blue\":0,\"alpha\":1},\"fillMode\":\"fit\",\"dim\":0,\"blurRadius\":0,\"isTransparent\":false},\"objects\":[],\"transition\":\"spin\",\"transitionDuration\":1}".utf8)
    print("strict \((try? JSONDecoder().decode(SlidePreset.self, from: strict)) == nil ? "fail" : "ok")")
    let frame = ObjectFrame(x: 0.1, y: 0.2, width: 0.5, height: 0.25, anchorX: .right, anchorY: .bottom)
    let r = frame.rect(in: CGSize(width: 1920, height: 1080))
    print("rect \(r.origin.x) \(r.origin.y) \(r.size.width) \(r.size.height)")
    let m = ObjectShadow(isEnabled: true, offsetPercent: 2.7, blurPercent: 7, angleDegrees: 90).metrics(fontSize: 50, objectHeight: 300)
    print("metrics \(m.offset.width) \(m.offset.height) \(m.blur)")
}
if want("songs") { checkSongs(data) }
if only == "vbmwrite" { vbmWrite(data) }
if only == "vbmread" { vbmRead() }
if want("plan") { checkPlan(data, library) }
if want("outputs") { checkOutputs(data) }
if want("media") { checkMedia() }
if want("resources") { checkResources(data) }
if want("import") { checkImport(data) }
if want("presentation") { checkPresentation() }
fflush(stdout)
