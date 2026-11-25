import Foundation
import SlovoCore
import Compression
import SQLite3

// Еталон розділу `songs` — дзеркало CoreCheck.Songs.cs рядок у рядок.

func esc(_ s: String) -> String { s.replacingOccurrences(of: "\r", with: "␍").replacingOccurrences(of: "\n", with: "⏎") }
func fnvBytes(_ d: Data) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in d { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "%016llx", h)
}
func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }
func iv(_ v: Int?) -> String { v.map(String.init) ?? "-" }
func channel(_ v: Double) -> Int { Int((v * 255).rounded()) }
func rgb(_ c: SlideStyle.RGBA?) -> String {
    guard let c else { return "-" }
    return "\(channel(c.red))/\(channel(c.green))/\(channel(c.blue))/\(channel(c.alpha))"
}
func songLine(_ s: Song) -> String {
    var t = "S\(s.index)\u{1}\(s.title)\u{1}\(s.alternateTitle)\u{1}\(s.author)\u{1}\(s.composer)\u{1}\(s.note)\u{1}\(s.properties)\n"
    for p in s.parts { t += "P\(p.index)\u{1}\(p.kind)\u{1}\(p.text)\u{1}\(p.align.rawValue)\n" }
    return t
}
func songDigest(_ b: SongBook) -> String {
    var t = "\(b.title)\u{1}\(b.shortName)\u{1}\(b.publisher)\u{1}\(b.revisionDate)\u{1}\(b.comment)\u{1}\(b.formatVersion)\u{1}\(b.flags)\u{1}\(b.charset)\n"
    for s in b.songs { t += songLine(s) }
    for g in b.groups { t += "G\(g.name)\u{1}" + g.songIndices.map(String.init).joined(separator: ",") + "\n" }
    return fnv(t)
}
func reasonName(_ r: SongMatch.Reason) -> String {
    switch r {
    case .listing: return "listing"
    case .number: return "number"
    case .catalogNumber: return "catalogNumber"
    case .title: return "title"
    case .alternateTitle: return "alternateTitle"
    case .author: return "author"
    }
}
func printSong(_ s: Song, _ format: SongTitleFormat, _ palette: SongChunkPalette, _ indent: String = "  ") {
    print("\(indent)song \(s.index) n\(s.number) cat \(iv(s.catalogNumber)) «\(esc(s.title))» alt «\(esc(s.alternateTitle))» by «\(esc(s.author))» / «\(esc(s.composer))» note «\(esc(s.note))» sub \(s.subtitle ?? "-") first «\(esc(s.firstLine))» tune «\(s.tune)» catText «\(s.catalogNumberText)» list «\(format.title(of: s))»")
    print("\(indent)  props \(s.propertyPairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")) raw «\(esc(s.properties))»")
    for p in s.parts {
        print("\(indent)  part \(p.index) «\(esc(p.kind))» \(p.align.rawValue) chunk \(palette.chunk(for: p.kind)?.key ?? "-") lines \(p.lines.count) «\(esc(p.text))»")
    }
}
func inflateZlib(_ data: Data, capacity: Int) -> Data {
    let raw = data.dropFirst(2)
    return raw.withUnsafeBytes { input -> Data in
        let src = input.bindMemory(to: UInt8.self).baseAddress!
        let room = capacity + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: room)
        defer { dst.deallocate() }
        let n = compression_decode_buffer(dst, room, src, raw.count, nil, COMPRESSION_ZLIB)
        return Data(bytes: dst, count: n)
    }
}
func u32(_ d: Data, _ at: Int) -> UInt32 {
    UInt32(d[at]) | UInt32(d[at + 1]) << 8 | UInt32(d[at + 2]) << 16 | UInt32(d[at + 3]) << 24
}

let songQueries = ["1", "12", "100", "бог", "Бог", "ГОСПОДЬ", "spiewnik", "ё", "Ісус", "иисус", "  ", "", "xyz", "1728", "+5", "Ｇｏｄ", "lord", "Свят"]

func checkSongs(_ data: URL) {
    print("# songs")
    let config = try! IniSettings(fileAt: data.appendingPathComponent("Slovo.ini"))
    let palette = SongChunkPalette(config: config)
    let format = SongTitleFormat(config: config)
    let library = SongLibrary(modulesDirectory: data.appendingPathComponent("Modules"))
    print("library \(library.books.count): " + library.books.map(\.id).joined(separator: ","))
    print("titleFormat \(format.showsNumber) \(format.dotAfterNumber) \(format.numberInBrackets) \(format.number(7)) \(SongTitleFormat(numberInBrackets: true).number(7)) \(SongTitleFormat(dotAfterNumber: false).number(7))")
    let composers: [(String, SongSlideComposer)] = [
        ("default", SongSlideComposer()),
        ("config", SongSlideComposer(config: config)),
        ("split", SongSlideComposer(options: .init(splitsLongParts: true, linesPerPage: 2, showsNumber: true, showsTitle: true, showsBookShortName: true, endMarker: "***"), palette: palette)),
    ]
    var loaded: [(String, SongBook)] = []
    for id in library.books.map(\.id) {
        let book = library.book(id)
        let e = library.entry(id)!
        print("book \(e.id) | \(e.url.lastPathComponent) | \(esc(e.title)) | \(esc(e.shortName)) | \(esc(e.publisher)) | \(esc(e.revisionDate)) | \(esc(e.comment)) | count \(iv(e.songCount)) loaded \(e.isLoaded) | \(esc(e.displayName))")
        guard let book else { print("  failure \(e.failure ?? "")"); continue }
        loaded.append((id, book))
        print("  songs \(book.songs.count) parts \(book.songs.reduce(0) { $0 + $1.parts.count }) groups \(book.groups.count) header \(book.formatVersion) \(book.flags) \(book.charset) digest \(songDigest(book))")
        for g in book.groups { print("  group \(esc(g.name)): \(g.songIndices.map(String.init).joined(separator: ","))") }
        let picks = Array(Set([0, 1, 2, book.songs.count - 1])).filter { $0 >= 0 && $0 < book.songs.count }.sorted()
        for i in picks { printSong(book.songs[i], format, palette) }
        for q in songQueries {
            let found = library.search(q, in: id)
            print("  search «\(q)» \(found.count): " + found.prefix(6).map { "\($0.id):\(reasonName($0.reason))" }.joined(separator: " "))
        }
        print("  numbered 5 \(library.song(number: 5, in: id).map { String($0.index) } ?? "-") 99999 \(library.song(number: 99999, in: id).map { String($0.index) } ?? "-") at 3 \(library.song(at: 3, in: id)?.title ?? "-")")

        let maxParts = book.songs.map(\.parts.count).max() ?? 0
        let richest = book.songs.isEmpty ? -1 : (book.songs.firstIndex { $0.parts.count == maxParts } ?? -1)
        let slideSongs = Array(Set([0, book.songs.count - 1, richest])).filter { $0 >= 0 && $0 < book.songs.count }.sorted()
        for (name, composer) in composers {
            for i in slideSongs {
                let song = book.songs[i]
                let slides = composer.slides(for: song, bookShortName: book.shortName)
                print("  slides \(name) \(song.index): \(slides.count) part1 \(composer.slides(forPartAt: 1, of: song, bookShortName: book.shortName).count)")
                for s in slides {
                    print("    \(s.id) \(s.pageCount) \(s.isSinglePage) «\(esc(s.partKind))» \(s.chunkKey ?? "-") \(rgb(s.color)) blank \(s.slide.isBlank) ref «\(s.slide.reference)» «\(esc(s.slide.mainText))»")
                }
            }
        }
        let json = try! SongBookJSON.data(for: book)
        print("  json \(json.count) \(fnvBytes(json)) back \(songDigest(try! SongBookJSON.book(from: json, name: "x")))")
        let vbm = try! SongBookWriter.data(for: book)
        let compressed = Int(u32(vbm, 20))
        let start = vbm.count - 4 - compressed
        let body = inflateZlib(vbm.subdata(in: start..<vbm.count), capacity: Int(u32(vbm, 24)))
        print("  vbm head \(hex(vbm.subdata(in: 0..<20))) \(u32(vbm, 24)) \(hex(vbm.subdata(in: 28..<72))) names \(hex(vbm.subdata(in: 72..<start))) tail \(hex(vbm.subdata(in: (vbm.count - 4)..<vbm.count))) body \(body.count) \(fnvBytes(body)) back \(songDigest(try! SongBook(data: vbm, name: "x")))")
        let exported = SongBookTextFile.exportWithServiceInfo(book)
        let reimported = SongBookTextFile.songs(from: exported, palette: palette)
        let differing = (0..<min(reimported.count, book.songs.count)).filter { songLine(reimported[$0]) != songLine(book.songs[$0]) }.count
        var rebook = book
        rebook.songs = reimported
        print("  text \(exported.utf8.count) \(fnv(exported)) songs \(reimported.count) differing \(differing) digest \(songDigest(rebook))")
        print("  plain \(fnv(SongBookTextFile.exportPlain(book))) \(fnv(SongBookTextFile.exportPlain(book, numbering: .catalog)))")
    }
    library.unloadAll()
    print("after unload: " + library.books.map { "\($0.id)=\($0.isLoaded)" }.joined(separator: ","))
    print("entry by file: \(library.entry(fileName: "GLORY.VBM")?.id ?? "-") \(library.entry(fileName: "pv3055.songbook")?.id ?? "-") \(library.entry(fileName: "nope.vbm")?.id ?? "-") cache \(library.cacheLimit)")
    songEditing(loaded, palette, format)
    songFormatting(palette)
    songImports(data, palette, format)
}

func songEditing(_ loaded: [(String, SongBook)], _ palette: SongChunkPalette, _ format: SongTitleFormat) {
    print("# songs editing")
    var chosen = Array(loaded.filter { $0.1.songs.count >= 6 }.prefix(2))
    if let biggest = loaded.max(by: { $0.1.songs.count < $1.1.songs.count }) { chosen.append(biggest) }
    for (id, original) in chosen {
        print("edit \(id)")
        let originalDigest = songDigest(original)
        let editor = SongBookEditor(book: original, url: URL(fileURLWithPath: "/tmp/" + id + ".vbm"))
        func groups() -> String { editor.book.groups.map { "\($0.name)[\($0.songIndices.map(String.init).joined(separator: ","))]" }.joined(separator: " ") }
        func titles(_ n: Int) -> String { editor.book.songs.prefix(n).map { "\($0.index):\($0.title)" }.joined(separator: "|") }
        print("  modified \(editor.isModified) url \(editor.url?.path ?? "")")
        let g = editor.addGroup(named: "Тест")
        editor.addSong(5, toGroup: g)
        editor.addSong(0, toGroup: g)
        editor.addSong(3, toGroup: g)
        editor.addSong(3, toGroup: g)
        editor.addSong(999999, toGroup: g)
        let g2 = editor.addGroup(named: "Другий")
        editor.addSong(1, toGroup: g2)
        print("  groups \(groups()) modified \(editor.isModified) in group \(editor.songIndices(inGroup: g).map(String.init).joined(separator: ",")) all \(editor.songIndices(inGroup: nil).count) bad \(editor.songIndices(inGroup: 99).count)")
        print("  dup group \(iv(editor.duplicateGroup(at: g))) \(groups())")
        print("  move group \(iv(editor.moveGroup(at: 0, by: 1))) \(iv(editor.moveGroup(at: 0, by: -1))) \(groups())")
        editor.renameGroup(at: 1, to: "Перейменована")
        editor.removeSong(0, fromGroup: 1)
        print("  renamed \(groups()) isSong \(editor.isSong(5, inGroup: 1)) \(editor.isSong(0, inGroup: 1))")
        let inserted = editor.insertSong(Song(index: 0, title: "Нова пісня", author: "Я", parts: [SongPart(index: 0, kind: "Куплет 1", text: "Рядок один\r\nРядок два"), SongPart(index: 1, kind: "Припев", text: "Хор")]), at: 2)
        print("  insert \(inserted) \(groups()) \(titles(5))")
        editor.removeSong(at: 1)
        print("  remove \(groups()) \(titles(4))")
        print("  dup song \(iv(editor.duplicateSong(at: 0))) \(iv(editor.duplicateSong(at: 0))) \(titles(4)) \(groups())")
        print("  position \(iv(editor.setSongPosition(at: 0, to: 4))) \(titles(5)) \(groups())")
        print("  move \(iv(editor.moveSong(at: 3, by: -1))) \(iv(editor.moveSong(at: 0, by: -1))) \(titles(5)) \(groups())")
        editor.shiftCatalogNumbers(from: 2, by: 10)
        print("  shift \(editor.book.songs.prefix(6).map(\.catalogNumberText).joined(separator: ","))")
        editor.shiftCatalogNumbers(from: 0, by: -100000)
        print("  shift down \(editor.book.songs.prefix(6).map(\.catalogNumberText).joined(separator: ","))")
        editor.setCatalogNumbersToOrdinal()
        print("  ordinal \(editor.book.songs.prefix(6).map(\.catalogNumberText).joined(separator: ",")) \(esc(editor.book.songs[0].properties))")
        editor.clearCatalogNumbers()
        print("  cleared \(editor.book.songs.prefix(6).map(\.catalogNumberText).joined(separator: ",")) «\(esc(editor.book.songs[0].properties))»")
        let target = 2
        print("  part insert \(iv(editor.insertPart(SongPart(index: 9, kind: "Бридж", text: "Міст  через\nрічку"), inSongAt: target, at: 1))) dup \(iv(editor.duplicatePart(at: 0, inSongAt: target))) move \(iv(editor.movePart(at: 0, inSongAt: target, by: 2))) \(iv(editor.movePart(at: 0, inSongAt: target, by: -1)))")
        editor.removePart(at: 1, inSongAt: target)
        editor.setAlign(.center, forPartAt: 0, inSongAt: target)
        editor.format(.byLiters, partAt: 1, inSongAt: target)
        editor.format(.byOptimalSize, partAt: 0, inSongAt: target)
        editor.updatePart(at: 2, inSongAt: target) { $0.kind = "Змінено" }
        editor.updateSong(at: target) { $0.title += " (змінено)" }
        printSong(editor.book.songs[target], format, palette, "  ")
        editor.unformat(partAt: 0, inSongAt: target)
        editor.format(.byLiters, songAt: 3)
        printSong(editor.book.songs[3], format, palette, "  ")
        editor.unformat(songAt: 3)
        print("  unformat «\(esc(editor.book.songs[target].parts[0].text))» «\(esc(editor.book.songs[3].parts.first?.text ?? ""))»")
        print("  refrain \(editor.duplicateRefrain(inSongAt: target)) \(editor.duplicateRefrain(inSongAt: target, marker: "через")) all \(editor.duplicateRefrainsInAllSongs(palette: palette)) marker \(editor.duplicateRefrainsInAllSongs(marker: "Господь", palette: palette))")
        print("  after refrain \(songDigest(editor.book))")
        editor.sortSongs(.byTitle)
        print("  by title \(songDigest(editor.book)) \(titles(8)) \(groups())")
        editor.sortSongs(.byNumber)
        print("  by number \(songDigest(editor.book)) \(titles(8)) \(groups())")
        let fresh = SongBookEditor(book: original, url: nil)
        fresh.sortSongs(.byNumber)
        print("  original by number \(songDigest(fresh.book)) \(fresh.book.songs.prefix(8).map { "\($0.catalogNumberText):\($0.title)" }.joined(separator: "|"))")
        fresh.sortSongs(.byTitle)
        print("  original by title \(songDigest(fresh.book)) \(fresh.book.songs.prefix(12).map(\.title).joined(separator: "|"))")
        fresh.formatAllSongs(.byOptimalSize)
        print("  format all optimal \(songDigest(fresh.book))")
        fresh.formatAllSongs(.byLiters)
        print("  format all liters \(songDigest(fresh.book))")
        fresh.unformatAllSongs()
        print("  unformat all \(songDigest(fresh.book))")
        editor.updateAttributes(title: "Нова назва", shortName: "НН", publisher: "Видавець", revisionDate: "2026", comment: "Примітка", charset: 1)
        print("  attributes \(songDigest(editor.book)) original untouched \(songDigest(original) == originalDigest)")
        var destination = loaded[0].1
        var turn = 0
        let counts = SongBookEditor.copySongs([2, 0, 5, 0, 999], from: original, into: &destination) { _ in
            defer { turn += 1 }
            switch turn % 3 { case 0: return .overwrite; case 1: return .skip; default: return .append }
        }
        print("  copy \(counts.added) \(counts.overwritten) asked \(turn) \(songDigest(destination))")
        var selfBook = original
        let again = SongBookEditor.copySongs([0, 1], from: original, into: &selfBook) { _ in .append }
        print("  copy self \(again.added) \(again.overwritten) \(selfBook.songs.count) \(selfBook.songs.suffix(2).map { "\($0.index):\($0.title)" }.joined(separator: "|"))")
    }
    let empty = SongBookEditor.newBook(title: "Новий", shortName: "Н")
    let newEditor = SongBookEditor(book: empty, url: nil)
    newEditor.sortSongs(.byTitle)
    print("new book \(songDigest(newEditor.book)) modified \(newEditor.isModified) index \(newEditor.appendSong(Song(index: 5, title: "Одна"))) \(newEditor.book.songs[0].index)")
    do { try newEditor.save() } catch { print("save without url: \(error)") }
}

func songFormatting(_ palette: SongChunkPalette) {
    print("# songs formatting")
    let samples = [
        "Боже, я Тебе люблю\nІ серцем, і душею\r\nХвалу Тобі співаю",
        "  один   два\tтри\u{0B}чотири  \r\n\r\n п'ять",
        "ВІН ЖИВИЙ! він воскрес. Алилуя Амінь",
        "",
        "слово",
        "Ångström élan Ünter ǅungla «Лапки» Ⅻ ⓐ Ⓐ 1Друге",
        "a\u{0301} b\u{0301}c E\u{0301} Éd",
        "Хвала Тобі, Господи, хвала Тобі навіки, бо Ти великий і святий, і милість Твоя вічна",
        "Слава Богу за все що Він зробив для нас у цьому житті і в майбутньому віці",
    ]
    for s in samples {
        print("format «\(esc(s))» un «\(esc(SongTextFormatter.unformat(s)))» lit «\(esc(SongTextFormatter.byLiters(s)))» opt «\(esc(SongTextFormatter.byOptimalSize(s)))» opt10 «\(esc(SongTextFormatter.byOptimalSize(s, targetLineLength: 10)))»")
    }
    let text = "вступ без назви\r\n\r\n#Куплет 1\r\n$Align$=Center\r\nРядок\r\n\r\nПриспів\nТекст приспіву\n#Своя назва \n$Foo$=bar\nМостом шли\nМост\n$ALIGN$=left\nкінець\r#\n#Verse 3.\n\n"
    let parts = SongTextMarkup.parts(from: text, palette: palette)
    for p in parts { print("markup part \(p.index) «\(esc(p.kind))» \(p.align.rawValue) «\(esc(p.text))»") }
    print("markup text «\(esc(SongTextMarkup.text(of: parts)))»")
    print("markup default \(SongTextMarkup.parts(from: text).count) empty \(SongTextMarkup.parts(from: "").count) blank \(SongTextMarkup.parts(from: "\n\n").count)")
    for line in SongTextMarkup.markup(of: text + "\u{2028}Кода\u{2029}$X$=1\r\n#Приспів:", palette: palette) {
        let kind: String, color: SlideStyle.RGBA?
        switch line.role {
        case .body: kind = "Body"; color = nil
        case .heading: kind = "Heading"; color = nil
        case .keywordHeading(let c): kind = "KeywordHeading"; color = c
        case .parameter: kind = "Parameter"; color = nil
        }
        print("markup line \(line.start) \(line.length) \(kind) \(rgb(color))")
    }
    let file = "\u{FEFF}преамбула\r\n---\r\nПерша\r\n$AltTitle$=Друга назва\r\n$Poet$=Автор\r\n$Composer$=Композитор\r\n$DateCreate$=03.12.2013\r\n$Tune$=C\r\n$ID$=12\r\n$Custom$=x\r\n#Куплет 1\r\n$Align$=Left\r\nРядок 1\r\n\r\n#Приспів\r\nПри\r\n----\r\n---\r\n\r\n---\r\n Пробіл\r\n\r\n$Note$=стара\r\nбез частин\r\nПриспів\r\nхор\r\n"
    let songs = SongBookTextFile.songs(from: file, palette: palette)
    print("textfile songs \(songs.count)")
    for s in songs { printSong(s, SongTitleFormat(), palette, "  ") }
    var book = SongBook(title: "Т", shortName: "т", songs: [Song(index: 0, title: "Стара")], groups: [SongGroup(name: "Г", songIndices: [0, 1, 7])])
    print("import append \(SongBookTextFile.importSongs(from: file, into: &book, mode: .append, palette: palette)) \(book.songs.count) \(book.songs.map { String($0.index) }.joined(separator: ",")) groups \(book.groups[0].songIndices.map(String.init).joined(separator: ","))")
    print("import replace \(SongBookTextFile.importSongs(from: file, into: &book, mode: .replace, palette: palette)) \(book.songs.count) groups [\(book.groups[0].songIndices.map(String.init).joined(separator: ","))] none \(SongBookTextFile.importSongs(from: "без пісень", into: &book, mode: .replace))")
    print("export «\(esc(SongBookTextFile.exportWithServiceInfo(book)))»")
    print("plain «\(esc(SongBookTextFile.exportPlain(book, numbering: .catalog)))»")
    let aligns = SongPartAlign.allCases.map { "\($0.rawValue):\($0.exportName ?? "-")" }
    print("aligns \(aligns.joined(separator: " ")) parse \([" Left ", "RIGHT", "center", "", "middle"].map { SongPartAlign(exportName: $0).map { String($0.rawValue) } ?? "nil" }.joined(separator: ","))")
    var props = Song(index: 0, title: "x", properties: "$ID$=1\r\n$TUNE$= G \n\n$ID$=2\rfoo=bar\n $X$=a=b")
    print("props \(props.propertyPairs.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ";")) cat \(iv(props.catalogNumber)) tune «\(props.tune)»")
    props.setProperty("ID", "5")
    props.setProperty("$X$", "")
    print("props set «\(esc(props.properties))»")
    print("subtitle «\(Song(index: 0, title: "a", author: "Іван", composer: "Іван").subtitle ?? "")» «\(Song(index: 0, title: "a", author: "", composer: "Петро").subtitle ?? "")» «\(Song(index: 0, title: "a", author: "Й", composer: "И\u{0306}").subtitle ?? "")» «\(Song(index: 0, title: "a").subtitle ?? "nil")»")
}

func failureName(_ f: SongBookImporter.Failure) -> String {
    switch f {
    case .cannotOpen: return "cannotOpen"
    case .notASongSource: return "notASongSource"
    case .empty: return "empty"
    case .unexpectedStructure: return "unexpectedStructure"
    case .unsupportedVersion: return "unsupportedVersion"
    }
}

func makeSqlite(_ url: URL, _ version: Int, _ script: String) {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let db = handle else { fatalError("sqlite") }
    defer { sqlite3_close(db) }
    guard sqlite3_exec(db, "PRAGMA user_version = \(version);" + script, nil, nil, nil) == SQLITE_OK else { fatalError(String(cString: sqlite3_errmsg(db))) }
}

func songImports(_ data: URL, _ palette: SongChunkPalette, _ format: SongTitleFormat) {
    print("# songs import")
    for t in SoftProjectorSelfTest.run() {
        print("selftest \(t.name) | expects \(t.expectsSuccess) passed \(t.passed) | \(t.outcome)")
    }
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("slovo-check-sps-" + UUID().uuidString)
    try! fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let text1 = "##4\r\n##Євангельські пісні\r\n##Опис@%другий рядок\r\n"
        + "1#$#Велика благодать#$#кат#$#G#$#Слова#$#Музика#$#Куплет 1.@%Рядок один@%Рядок два@$Приспів:@%Хор співає@$&Приспів@%ще#$#нотатка@%два#$#0#$#Arial\r\n"
        + "#$#без номера#$#к#$##$##$##$#Verse 2@%a\r\n"
        + "не пісня\r\n"
        + " 12 #$#  Третя  #$#к#$#Am#$#А#$#М#$#Перший рядок@%другий@$@%Третій блок#$#\r\n"
    let xml = "<?xml version=\"1.0\" encoding=\"UTF-16\"?>\n<spSongBook version=\"2.0\"><SongBook><name>Збірка XML</name><about>Опис\nу два рядки</about></SongBook>"
        + "<Song><number> 7 </number><title>Пісня</title><lyrics>Verse 1\nрядок &amp; ще\n&amp;Chorus\nхор</lyrics><key>D</key><poet>Поет</poet><note>н</note><created>2020</created></Song>"
        + "<song number=\"x\"><songtitle>Друга</songtitle><text>a@%b@$c</text></song><Song number=\"9\"><body/></Song></spSongBook>"
    let files: [(String, Data)] = [
        ("v1-utf8.sps", Data([0xEF, 0xBB, 0xBF]) + Data(text1.utf8)),
        ("v1-cp1251.sps", text1.data(using: .windowsCP1251)!),
        ("v1-empty.sps", Data("##0\r\n##Порожній\r\n".utf8)),
        ("xml-utf16.sps", Data([0xFF, 0xFE]) + xml.data(using: .utf16LittleEndian)!),
        ("xml-noroot.sps", Data("<?xml version=\"1.0\"?><root><Song><title>a</title></Song></root>".utf8)),
        ("xml-nosongs.sps", Data("\n  <spSongBook version=\"1\"><SongBook><title>T</title></SongBook></spSongBook>".utf8)),
        ("xml-broken.sps", Data("<?xml version=\"1.0\"?><spSongBook><Song><title>x</title></spSongBook>".utf8)),
        ("junk.sps", Data([0x4A, 0x55, 0x4E, 0x4B, 0x01, 0x02, 0xFF, 0x20, 0x7E, 0x7F]) + Data("Привіт, це не пісенник зовсім".utf8)),
    ]
    for (name, bytes) in files { try! bytes.write(to: folder.appendingPathComponent(name)) }
    makeSqlite(folder.appendingPathComponent("db-custom.sps"), 1,
               "CREATE TABLE Extra (a TEXT);"
               + "CREATE TABLE \"SongBook\" (Name TEXT, Description TEXT);"
               + "INSERT INTO SongBook VALUES ('Своя база', 'Опис\n\nбази');"
               + "CREATE TABLE Hymns (num TEXT, Song_Title TEXT, LYRICS TEXT, author TEXT, composer TEXT, comment TEXT, created TEXT, key TEXT);"
               + "INSERT INTO Hymns VALUES ('12a', 'Перший', 'Строфа один\nрядок\n\nСтрофа два', 'А', 'К', 'нотатка\nдва', '2001', 'E');"
               + "INSERT INTO Hymns VALUES (' 7 ', '', 'Chorus 2:\nхор', NULL, NULL, NULL, NULL, NULL);"
               + "INSERT INTO Hymns VALUES (NULL, '', '', '', '', '', '', '');"
               + "INSERT INTO Hymns VALUES (3.7, 'Дробовий', 'Slide 1\nвставка\nEnding\nкінець', '', '', '', '', '');")
    makeSqlite(folder.appendingPathComponent("db-notable.sps"), 2, "CREATE TABLE Alpha (id INTEGER, caption TEXT, note TEXT); CREATE TABLE Beta (x INTEGER);")
    makeSqlite(folder.appendingPathComponent("db-future.sps"), 3, "CREATE TABLE Songs (title TEXT, song_text TEXT);")
    makeSqlite(folder.appendingPathComponent("db-empty.sps"), 2, "CREATE TABLE Songs (title TEXT, song_text TEXT);")
    makeSqlite(folder.appendingPathComponent("db-blank.sps"), 2, "")
    makeSqlite(folder.appendingPathComponent("db-norows.sps"), 2, "CREATE TABLE Songs (title TEXT, song_text TEXT); INSERT INTO Songs VALUES ('', '');")

    let all = (try! fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)).sorted { $0.lastPathComponent < $1.lastPathComponent }
    for url in all {
        let name = url.lastPathComponent
        do {
            let raw = try SongBookImporter.readSoftProjector(fileAt: url)
            print("sps \(name): origin «\(raw.origin)» title «\(raw.title)» info «\(esc(raw.info))» rows \(raw.songs.count) | "
                  + raw.songs.map { "\(iv($0.number))/\(esc($0.title))/\(esc($0.tune))/\(esc($0.words))/\(esc($0.music))/\(esc($0.notes))/\(esc($0.date))/\(esc($0.text))" }.joined(separator: " ; "))
            let book = try SongBookImporter.fromSoftProjector(fileAt: url, palette: palette)
            print("  book «\(book.title)» «\(book.shortName)» «\(esc(book.comment))» songs \(book.songs.count) digest \(songDigest(book))")
            for s in book.songs { printSong(s, format, palette, "  ") }
        } catch let f as SongBookImporter.Failure {
            let message = "\(f)".contains("XML не разобрался") ? "XML не разобрался" : esc("\(f)")
            print("sps \(name): failure \(failureName(f)) | \(message)")
        } catch {
            print("sps \(name): other \(error)")
        }
    }

    let gyzha = data.appendingPathComponent("Modules").appendingPathComponent("UA_Gyzha")
    for (url, marker) in [(gyzha, nil), (gyzha.appendingPathComponent("bibleqt.ini"), "Господь"), (gyzha, "  ")] as [(URL, String?)] {
        do {
            let book = try SongBookImporter.fromBibleQuote(iniAt: url, refrainMarker: marker, palette: palette)
            print("bq «\(marker ?? "nil")» «\(book.title)» «\(book.shortName)» «\(book.publisher)» «\(book.comment)» songs \(book.songs.count) parts \(book.songs.reduce(0) { $0 + $1.parts.count }) digest \(songDigest(book))")
            for i in [0, 1, book.songs.count - 1] { printSong(book.songs[i], format, palette, "  ") }
        } catch let f as SongBookImporter.Failure {
            print("bq failure \(failureName(f)) | \(esc("\(f)"))")
        } catch { print("bq other \(error)") }
    }
    do {
        _ = try SongBookImporter.fromBibleQuote(iniAt: data.appendingPathComponent("Modules").appendingPathComponent("немає"), refrainMarker: nil)
    } catch let f as SongBookImporter.Failure {
        print("bq missing \(failureName(f)) | \(esc("\(f)"))")
    } catch { print("bq missing other \(error)") }
}

func checkOutput() -> URL {
    guard let path = ProcessInfo.processInfo.environment["SLOVO_CHECK_OUT"], !path.isEmpty else { fatalError("SLOVO_CHECK_OUT") }
    return URL(fileURLWithPath: path)
}

func vbmWrite(_ data: URL) {
    print("# vbmwrite")
    let out = checkOutput()
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    let library = SongLibrary(modulesDirectory: data.appendingPathComponent("Modules"))
    for id in library.books.map(\.id) {
        guard let book = library.book(id) else { continue }
        try! SongBookWriter.data(for: book).write(to: out.appendingPathComponent(id + ".vbm"))
        print("wrote \(id) \(songDigest(book))")
    }
}

func vbmRead() {
    print("# vbmread")
    let files = ((try? FileManager.default.contentsOfDirectory(at: checkOutput(), includingPropertiesForKeys: nil)) ?? [])
        .filter { $0.pathExtension == "vbm" }.sorted { $0.path < $1.path }
    for url in files {
        do { print("read \(url.lastPathComponent) \(songDigest(try SongBook(fileAt: url)))") }
        catch { print("read \(url.lastPathComponent) failed \(error)") }
    }
}
