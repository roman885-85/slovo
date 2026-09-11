import Foundation
import SlovoCore

/// Замер работы с большим песенником.
///
/// Владелец: «в песнях списки тормозят, при выводе куплета зависает на 10-20
/// секунд». У него сборник «Песнь возрождения 3300» — три тысячи песен, и
/// всякая мелочь, посчитанная на каждый кадр, там перестаёт быть мелочью.
/// Меряем то, что зовётся из тела вида, то есть по многу раз в секунду.
func runSongBench(modulesURL: URL) -> Int32 {
    let library = SongLibrary(songFiles: filesInside(modulesURL))
    print("песенников: \(library.books.count)")

    // Берём самый большой — на нём и жалуются.
    var biggest: (id: String, title: String, songs: Int) = ("", "", 0)
    for entry in library.books {
        guard let book = library.book(entry.id) else { continue }
        if book.songs.count > biggest.songs {
            biggest = (entry.id, entry.title, book.songs.count)
        }
    }
    guard !biggest.id.isEmpty, let book = library.book(biggest.id) else {
        print("не нашлось ни одного песенника"); return 1
    }
    print("самый большой: «\(biggest.title)» — песен \(biggest.songs), групп \(book.groups.count)")

    func measure(_ name: String, _ times: Int, _ body: () -> Void) {
        let start = Date()
        for _ in 0..<times { body() }
        let each = Date().timeIntervalSince(start) / Double(times) * 1000
        let mark = each > 16 ? "  ← дольше кадра" : ""
        print(String(format: "  %@ %.2f мс%@", name.padding(toLength: max(name.count, 48), withPad: " ", startingAt: 0), each, mark))
    }

    let editor = SongBookEditor(book: book, url: nil)

    print("\nчто зовётся из тела вида на каждую перерисовку:")
    measure("songIndices(inGroup: nil)", 20) { _ = editor.songIndices(inGroup: nil) }
    measure("список песен целиком (visibleSongs без запроса)", 20) {
        _ = editor.songIndices(inGroup: nil).map { editor.book.songs[$0] }
    }
    measure("тот же список с запросом (свёртка названий)", 20) {
        let needle = "бог".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        _ = editor.songIndices(inGroup: nil).map { editor.book.songs[$0] }.filter {
            $0.title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).contains(needle)
        }
    }
    measure("SongLibrary.search(\"\") — весь сборник", 20) { _ = library.search("", in: biggest.id) }
    measure("SongLibrary.search(\"бог\")", 20) { _ = library.search("бог", in: biggest.id) }

    print("\nсборка слайда куплета:")
    if let song = book.songs.first(where: { !$0.parts.isEmpty }) {
        let part = song.parts[0]
        measure("склейка строк части", 200) { _ = part.lines.joined(separator: "\n") }
        print("  песня «\(song.title)», частей \(song.parts.count), строк в первой \(part.lines.count)")
    }

    print("\nсколько весит одна песня в памяти списка:")
    let sample = book.songs.prefix(500)
    let chars = sample.reduce(0) { $0 + $1.parts.reduce(0) { $0 + $1.text.count } }
    print("  в 500 песнях \(chars) знаков текста частей — столько копируется на каждую перерисовку списка")
    return 0
}

private func filesInside(_ modulesURL: URL) -> [URL] {
    let all = (try? FileManager.default.contentsOfDirectory(at: modulesURL,
                                                            includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.pathExtension.lowercased() == "vbm" }
}
