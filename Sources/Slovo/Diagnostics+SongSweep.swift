import AppKit
import SlovoCore

/// Широкий прогін по куплетах: багато пісень, різні ширини вікна й кеглі.
///
/// Власник утретє: «баг с широкими строками в куплетах остался». Вузька
/// перевірка («Куплети: рядок за текстом, без порожнечі») дивилася ОДНУ
/// пісню, в одному вікні 1600×900, одним кеглем і лише на видимі рядки — і
/// вона проходить. Отже, ловити треба ширше: пісень десятки, ширина вікна
/// в нього інша, кегль він крутить повзунком, а куплети гортає до кінця.
///
/// Міряємо те саме, що й раніше, але для КОЖНОГО рядка кожної взятої пісні:
/// скільки рядкові треба (`drawn`) і скільки дали (`given`). Зайве — це
/// порожнеча (рядок «широкий»), `cut` — обрізаний текст.
extension Diagnostics {

    @MainActor
    static func songPartSweepSection(state: AppState) -> [Check] {
        let area = "Пісні у вікні AppKit"
        let name = "Куплети: прогін по багатьох піснях, ширинах і кеглях"
        let songs = NativeSongsWorkspace.shared
        songs.attach(state: state)
        guard let view = songs.workspaceView, let library = state.songLibrary else {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "робоча зона або пісенник недоступні")]
        }
        // Усі збірники, а не один: власник співає зі свого («ВІДРОДЖЕННЯ»),
        // а широку порожнечу він бачить саме там, де вона є.
        let entries = state.songBooks

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        window.contentView = host
        let home = view.superview
        let place = view.frame
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        defer {
            view.removeFromSuperview()
            if let home {
                view.frame = place
                home.addSubview(view)
                home.layoutSubtreeIfNeeded()
            }
        }

        // Налаштування — чужі: вид тексту й кегль живуть в одному сховищі з
        // робочою копією власника, і повернути їх треба точно, як було.
        let chosenView = InterfaceSettings.shared.verseView(.songs)
        let chosenFont = state.listFontSize
        defer {
            state.listFontSize = chosenFont
            InterfaceSettings.shared.setVerseView(chosenView, in: .songs)
            songs.applyInterfaceNow()
            songs.applyPartViewButtons()
        }

        struct Worst {
            var points: CGFloat = 0
            var where_ = ""
        }
        var emptiness = Worst()
        var cuts = 0
        var cutExample = ""
        var widthsMismatch = ""
        var measured = 0
        var songsSeen = 0
        var booksSeen = 0

        func settle(_ seconds: TimeInterval) {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(seconds))
            window.displayIfNeeded()
        }

        // Вікно в нього 1920×957, вид тексту — «в одну лінію»; кегль він
        // крутить повзунком. Беремо кілька правдоподібних поєднань.
        let shapes: [(width: CGFloat, font: Double)] = [(1920, 13), (1920, 17), (1180, 13)]
        let modes: [InterfaceSettings.VerseViewMode] = [.singleLine, .multiline]

        for entry in entries.prefix(14) {
            guard let book = library.book(entry.id) else { continue }
            booksSeen += 1
            songs.selectBook(id: entry.id)
            for _ in 0..<40 where !songs.songIndexIsReady {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            // Найважчі пісні: довгі куплети — там порожнеча й вилазить.
            func weight(_ song: Song) -> Int { song.parts.reduce(0) { $0 + $1.text.count } }
            let sample = book.songs.sorted { weight($0) > weight($1) }.prefix(6).map(\.index)
            let titles = Dictionary(book.songs.map { ($0.index, $0.title) },
                                    uniquingKeysWith: { first, _ in first })

            for mode in modes {
                InterfaceSettings.shared.setVerseView(mode, in: .songs)
                for shape in shapes {
                    window.setContentSize(NSSize(width: shape.width, height: 900))
                    host.frame = NSRect(x: 0, y: 0, width: shape.width, height: 900)
                    view.frame = host.bounds
                    state.listFontSize = shape.font
                    songs.applyInterfaceNow()
                    settle(0.15)

                    for song in sample {
                        songs.reveal(song: song, part: nil, live: false)
                        settle(0.2)
                        let rows = songs.partList.rowsNow
                        guard rows > 0 else { continue }
                        songsSeen += 1
                        // Гортаємо, як людина: рядок, якого ще не показували,
                        // стоїть на чорновій оцінці висоти — міряти його
                        // марно. Дивимося лише на те, що справді показалося.
                        var seen: [Int] = []
                        var reached = -1
                        while reached < rows - 1 {
                            songs.partList.scrollTo(reached + 1, place: .top)
                            // Будуємо рядки, як їх побудувало б показане
                            // вікно, і чекаємо довше за сторожа висот (він
                            // міряє через чверть секунди після показу).
                            songs.partList.materializeVisibleForCheck()
                            settle(0.35)
                            songs.partList.materializeVisibleForCheck()
                            let visible = songs.partList.visibleRows
                            guard !visible.isEmpty else { break }
                            for row in visible where !seen.contains(row) { seen.append(row) }
                            let last = visible.upperBound - 1
                            if last <= reached { break }
                            reached = last
                        }
                        for row in seen {
                            guard let fit = songs.partList.fit(ofRow: row) else { continue }
                            measured += 1
                            let waste = fit.given - fit.drawn
                            if waste > emptiness.points {
                                emptiness.points = waste
                                let pair = songs.partList.widths(ofRow: row)
                                emptiness.where_ = "«\(entry.id)» / «\(titles[song] ?? "?")», частина \(row + 1), "
                                    + "\(Int(shape.width)) пт, кегль \(Int(shape.font)), "
                                    + (mode == .singleLine ? "одна лінія" : "багато рядків")
                                    + "; дано \(Int(fit.given)), треба \(Int(fit.drawn)), "
                                    + "міряно по \(Int(pair.measured)), клітинка \(Int(pair.cell)), "
                                    + "висоти списку: \(songs.partList.heightsKindForCheck)"
                            }
                            if fit.cut || fit.drawn > fit.given + 0.5 {
                                cuts += 1
                                if cutExample.isEmpty {
                                    cutExample = "«\(entry.id)» / «\(titles[song] ?? "?")», частина \(row + 1), "
                                        + "треба \(Int(fit.drawn)), дали \(Int(fit.given)), "
                                        + "\(Int(shape.width)) пт, кегль \(Int(shape.font))"
                                }
                            }
                        }
                        if widthsMismatch.isEmpty {
                            let pair = songs.partList.widths(ofRow: 0)
                            if pair.cell > 1, abs(pair.cell - pair.measured) > 1 {
                                widthsMismatch = "міряно по \(Int(pair.measured)), клітинка \(Int(pair.cell))"
                                    + " (\(Int(shape.width)) пт)"
                            }
                        }
                    }
                }
            }
        }

        var checks: [Check] = []
        // Ширини звіряємо, але за ними не судимо: клітинка встигає побути
        // вужчою під час перерозкладки, а важить те, чи вийшла від цього
        // зайва висота або обрізаний текст. Їх і питаємо.
        checks.append(Check(area: area, name: name,
                            status: emptiness.points <= 24 && cuts == 0 ? .ok : .failed,
                            detail: "збірників \(booksSeen), пісень \(songsSeen), поєднань \(shapes.count * modes.count), "
                                + "рядків зміряно \(measured); "
                                + "найбільша порожнеча \(Int(emptiness.points)) тчк"
                                + (emptiness.where_.isEmpty ? "" : " — \(emptiness.where_)")
                                + "; обрізаних рядків \(cuts)"
                                + (cutExample.isEmpty ? "" : " (\(cutExample))")
                                + (widthsMismatch.isEmpty ? "" : "; ширини розійшлися: \(widthsMismatch)")))
        return checks
    }
}
