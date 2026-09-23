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
                        // Гортаємо, як людина, і міряємо КОЖНУ сторінку
                        // одразу: сторож висот скидає виміряне в тих рядків,
                        // що поїхали з очей, і міряти їх потім — те саме, що
                        // міряти невидиме.
                        var reached = -1
                        var pages = 0
                        while reached < rows - 1, pages < 12 {
                            pages += 1
                            songs.partList.scrollTo(reached + 1, place: .top)
                            songs.partList.materializeVisibleForCheck()
                            settle(0.3)
                            songs.partList.materializeVisibleForCheck()
                            let visible = songs.partList.visibleRows
                            guard !visible.isEmpty else { break }
                            for row in visible {
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
                                        + "запам'ятовано \(Int(songs.partList.measuredHeightForCheck(ofRow: row)))"
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
                            let last = visible.upperBound - 1
                            if last <= reached { break }
                            reached = last
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

        // MARK: Перетягування панелі фонограм
        //
        // Власник: «песенник 3055, песня 2176, при перетягивании размера
        // блока минусовок слова опять растягиваются по ширине». Тягнемо межу
        // панелі так само, як рука, і одразу міряємо куплети: після зміни
        // висоти списку на нього стає (чи зникає) смуга прокрутки, а з нею
        // міняється ширина — рівно той випадок, на якому висоти лишалися
        // чорновими.
        var gripTrouble = ""
        if let songs3055 = entries.first(where: { $0.id.contains("pv3055") }) ?? entries.first,
           let root = songs.rootForCheck {
            songs.selectBook(id: songs3055.id)
            for _ in 0..<40 where !songs.songIndexIsReady {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            window.setContentSize(NSSize(width: 1920, height: 1000))
            host.frame = NSRect(x: 0, y: 0, width: 1920, height: 1000)
            view.frame = host.bounds
            state.listFontSize = 13
            songs.applyInterfaceNow()
            settle(0.3)
            // Пісня 2176 у збірнику: шукаємо за номером, а не за місцем.
            if let book = library.book(songs3055.id),
               let wanted = book.songs.first(where: { $0.number == 2176 }) ?? book.songs.last {
                songs.reveal(song: wanted.index, part: nil, live: false)
                settle(0.4)
                for step in [CGFloat(-160), 160, -90, 60] {
                    root.dragBackingForCheck(by: step)
                    settle(0.4)
                    songs.partList.materializeVisibleForCheck()
                    settle(0.3)
                    songs.partList.materializeVisibleForCheck()
                    for row in songs.partList.visibleRows {
                        guard let fit = songs.partList.fit(ofRow: row) else { continue }
                        measured += 1
                        let waste = fit.given - fit.drawn
                        if waste > 24, gripTrouble.isEmpty {
                            gripTrouble = "після зсуву на \(Int(step)) тчк: частина \(row + 1), "
                                + "дано \(Int(fit.given)), треба \(Int(fit.drawn)), "
                                + "запам'ятовано \(Int(songs.partList.measuredHeightForCheck(ofRow: row)))"
                        }
                        if waste > emptiness.points {
                            emptiness.points = waste
                            emptiness.where_ = "«\(songs3055.id)», пісня 2176, частина \(row + 1), "
                                + "після перетягування панелі фонограм на \(Int(step)) тчк"
                        }
                    }
                }
            }
        }
        checks.append(Check(area: area, name: "Куплети після перетягування панелі фонограм",
                            status: gripTrouble.isEmpty ? .ok : .failed,
                            detail: gripTrouble.isEmpty
                                ? "межу панелі посунуто чотири рази — рядки лишилися за текстом"
                                : gripTrouble))


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
