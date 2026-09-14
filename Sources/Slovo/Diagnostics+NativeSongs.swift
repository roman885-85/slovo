import AppKit
import SlovoCore

/// Самопроверка модуля «Песни» в новом окне.
///
/// Глазами здесь проверяется плохо: список песен выглядит одинаково и когда
/// строки настоящие, и когда они остались от прежнего сборника. Поэтому
/// каждая проверка ниже считает по-настоящему — что отдал источник, сколько
/// раз его спросили, сходится ли отбор по букве с эталонным поиском
/// `SongLibrary` и во сколько миллисекунд обходится нажатие в собранном окне.
extension Diagnostics {

    static func nativeSongsSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: nativeSongFolding())
        checks.append(contentsOf: nativeSongRows(state))
        checks.append(contentsOf: nativeSongParts(state))
        checks.append(contentsOf: nativeSongWindow(state))
        checks.append(nativeSongsLiveBook(state))
        checks.append(nativeSongsTabPath(state))
        checks.append(nativeSongFormat(state))
        return checks
    }

    /// Свій формат `.songbook`: те саме, що в `.vbm`, туди й назад; бібліотека
    /// бере свій файл, а не двійник `.vbm`; План знаходить збірник за старим
    /// ім'ям; планшет отримує `.vbm`, зібраний на льоту; редактор пише
    /// `.songbook` поруч із `.vbm`; майстер перетворює `.vbm` у `.songbook`.
    /// Власник: «формат vbi/vbm — VisioBible, для нас потрібен свій, але щоб
    /// не поламати імпорт».
    private static func nativeSongFormat(_ state: AppState) -> Check {
        let name = "Пісенник у своєму форматі .songbook: без втрат, з імпортом .vbm і експортом для планшета"
        guard let library = state.songLibrary,
              let source = library.books.first(where: { $0.url.pathExtension.lowercased() == "vbm" }),
              let book = library.book(source.id) else {
            return Check(area: songArea, name: name, status: .skipped, detail: "у бібліотеці нема жодного .vbm")
        }
        var faults: [String] = []
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("slovo-songbook-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do {
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            let vbmCopy = temp.appendingPathComponent(source.url.lastPathComponent)
            try fm.copyItem(at: source.url, to: vbmCopy)
            // 1. Майстер: .vbm → .songbook.
            let own = temp.appendingPathComponent(source.id).appendingPathExtension(SongBookJSON.pathExtension)
            try ModuleImporter.convertSongBook(from: vbmCopy, to: own)
            // 2. Туди й назад без втрат.
            let back = try SongBook(fileAt: own)
            if back.songs.count != book.songs.count { faults.append("пісень \(back.songs.count) замість \(book.songs.count)") }
            for (a, b) in zip(book.songs, back.songs) where a != b {
                faults.append("пісня «\(a.title.prefix(30))» змінилася після запису й читання")
                break
            }
            if back.groups.count != book.groups.count { faults.append("груп \(back.groups.count) замість \(book.groups.count)") }
            if back.title != book.title || back.shortName != book.shortName { faults.append("назва чи коротке ім'я змінилися") }
            // 3. Бібліотека бачить лише .songbook, коли поруч лежить .vbm.
            let files = ModuleLibrary(modulesDirectory: temp).songFiles
            if files.count != 1 || !SongBookJSON.isSongBookFile(files[0]) {
                faults.append("у теці з обома файлами бібліотека бачить \(files.map(\.lastPathComponent))")
            }
            // 4. За старим ім'ям із Плану чи «Історії».
            let small = SongLibrary(songFiles: files)
            if small.entry(fileName: source.url.lastPathComponent)?.id != source.id {
                faults.append("за ім'ям «\(source.url.lastPathComponent)» збірник не знайшовся")
            }
            // 5. Експорт у .vbm — планшету й VisioBible.
            let exported = try SongBookWriter.data(for: back)
            let reparsed = try SongBook(data: exported, name: source.id)
            if reparsed.songs.count != book.songs.count { faults.append("експорт у .vbm дав \(reparsed.songs.count) пісень") }
            // 6. Редактор пише .songbook поруч із .vbm.
            let editorFolder = temp.appendingPathComponent("редактор")
            try fm.createDirectory(at: editorFolder, withIntermediateDirectories: true)
            let editedVbm = editorFolder.appendingPathComponent(source.url.lastPathComponent)
            try fm.copyItem(at: source.url, to: editedVbm)
            let editor = SongBookEditor(book: book, url: editedVbm, isModified: true)
            let saved = try editor.save()
            if !SongBookJSON.isSongBookFile(saved) || !fm.fileExists(atPath: saved.path) {
                faults.append("редактор зберіг у «\(saved.lastPathComponent)», а не в .songbook")
            }
        } catch {
            faults.append("\(error)")
        }
        let detail = "джерело «\(source.displayName)»: \(book.songs.count) пісень, \(book.groups.count) груп; "
            + "перетворено, прочитано, експортовано в .vbm і збережено з редактора"
        return Check(area: songArea, name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? detail : faults.joined(separator: "; ") + ". " + detail)
    }

    /// Нажатие на вкладку «Песни» и вправду показывает песни.
    ///
    /// Именно этот путь владелец и проходит: он не смотрит в модель, он
    /// нажимает вкладку. Прежние проверки его не касались вовсе — они
    /// глядели на состояние, а не на то, что встало в окно.
    private static func nativeSongsTabPath(_ state: AppState) -> Check {
        let name = "Вкладка «Пісні» показує пісні"
        guard let tabs = NativeTop.modeTabs else {
            return Check(area: songArea, name: name, status: .skipped,
                         detail: "вікно AppKit не піднято")
        }
        let wasMode = state.mode
        defer { tabs.select(wasMode) }

        tabs.select(.songs)
        var trouble: [String] = []
        if tabs.chosenMode != .songs { trouble.append("вкладка не виділилася") }
        let workspace = NativeSongsWorkspace.shared
        guard let root = workspace.workspaceView else {
            return Check(area: songArea, name: name, status: .failed,
                         detail: "робочу область пісень не зібрано зовсім")
        }
        // Прежние рабочие области в ящике не снимаются, а прячутся (так
        // вкладка переключается втрое быстрее), поэтому смотрим не на первый
        // подвид, а на тот, что показан.
        let slot = NativeMainWindowController.shared.slotView(.workspace)
        let shown = slot?.subviews.first(where: { !$0.isHidden })
        if shown !== root {
            trouble.append("у робочій області вікна лежить не модуль пісень, а \(shown.map { String(describing: type(of: $0)) } ?? "ничего")")
        }
        if workspace.bookTabCount == 0 { trouble.append("смуга Пісенників порожня") }
        if workspace.model.book == nil { trouble.append("збірник не відкрито") }

        return Check(area: songArea, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "натиснули вкладку — у вікні модуль пісень, вкладок"
                             + " \(workspace.bookTabCount), пісень \(workspace.model.visibleSongs.count)"
                         : trouble.joined(separator: "; "))
    }

    /// У НАСТОЯЩЕГО модуля «Песни» открыт сборник.
    ///
    /// Проверка нарочно смотрит на живой одиночку, а не на свежесобранную
    /// копию: библиотека читается в фоне и приходит ПОЗЖЕ, чем поднимается
    /// окно. Пока об этом не знали, песенник брался один раз — в миг, когда
    /// его ещё нет, — и владелец видел модуль пустым. Своя копия этого не
    /// поймала бы никогда: ей библиотеку подают уже готовой.
    private static func nativeSongsLiveBook(_ state: AppState) -> Check {
        let name = "Пісенник відкрито в живому вікні"
        guard !state.songBooks.isEmpty else {
            return Check(area: songArea, name: name, status: .skipped,
                         detail: "у бібліотеці немає пісенників")
        }
        let workspace = NativeSongsWorkspace.shared
        guard workspace.workspaceView != nil else {
            return Check(area: songArea, name: name, status: .failed,
                         detail: "робочу область пісень не зібрано")
        }
        guard let book = workspace.model.book else {
            return Check(area: songArea, name: name, status: .failed,
                         detail: "пісенників \(state.songBooks.count), а в модулі не відкрито жодного"
                             + " — каталог не дійшов до нього після читання бібліотеки")
        }
        // Мало иметь открытый сборник: рабочая область должна ещё и стоять в
        // окне, а на полосе (33) — быть вкладки. Владелец видел «песенника
        // нет» именно потому, что смотрел на окно, а не на модель.
        var trouble: [String] = []
        if workspace.model.visibleSongs.isEmpty { trouble.append("список пісень порожній") }
        if workspace.bookTabCount == 0 { trouble.append("вкладок Пісенників немає") }
        if state.mode == .songs,
           NativeMainWindowController.shared.slotView(.workspace)?.subviews.first !== workspace.workspaceView {
            trouble.append("робоча область пісень не стоїть у вікні")
        }
        return Check(area: songArea, name: name,
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "відкрито «\(book.title)», пісень \(book.songs.count), вкладок"
                             + " \(workspace.bookTabCount) із \(state.songBooks.count) збірників"
                         : trouble.joined(separator: "; "))
    }

    private static let songArea = "Пісні у вікні AppKit"

    /// Самый большой сборник каталога, который и вправду открывается. На нём
    /// программа и вставала. Выбор общий с замером — второму перечню того же
    /// правила взяться неоткуда.
    private static func biggestSongBook(_ state: AppState) -> SongLibrary.Entry? {
        NativeSongsBench.biggestBook(state: state)
    }

    // MARK: - Свёртка и поиск по байтам

    private static func nativeSongFolding() -> [Check] {
        var checks: [Check] = []

        // Побайтовый поиск обязан отвечать ровно то же, что и обычный поиск
        // подстроки без учёта регистра и диакритики. Разойдись они — и поле
        // быстрого выбора начнёт врать, а заметить это на глаз нельзя.
        let cases: [(String, String, Bool)] = [
            ("Слава Богу", "слава", true),
            ("СЛАВА БОГУ", "слава", true),
            ("Моё сердце", "мое", true),
            ("Мое сердце", "моё", true),
            ("Śpiewnik", "spiewnik", true),
            ("Хвалите Господа", "мир", false),
            ("Хвала", "хвалам", false),
        ]
        var wrong: [String] = []
        for (haystack, needle, expected) in cases {
            let got = NativeSongFold.contains(NativeSongFold.bytes(haystack),
                                              NativeSongFold.bytes(needle))
            if got != expected { wrong.append("«\(haystack)» ⊃ «\(needle)» → \(got)") }
        }
        checks.append(Check(area: songArea, name: "Пошук за згорнутими байтами відповідає як звичайний",
                            status: wrong.isEmpty ? .ok : .failed,
                            detail: wrong.isEmpty
                                ? "звірено \(cases.count) пар: регістр, ё, діакритика, промахи"
                                : wrong.joined(separator: "; ")))

        // Пустая игла — это «показать всё», а не «не найдено ничего».
        let all = NativeSongFold.contains(NativeSongFold.bytes("будь-що"), [])
        checks.append(Check(area: songArea, name: "Порожній запит показує весь збірник",
                            status: all ? .ok : .failed,
                            detail: all ? "порожній рядок підходить усьому" : "порожній рядок не підійшов"))
        return checks
    }

    // MARK: - Источник строк списка песен

    private static func nativeSongRows(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        guard let entry = biggestSongBook(state), let library = state.songLibrary,
              let book = library.book(entry.id), !book.songs.isEmpty else {
            checks.append(Check(area: songArea, name: "Збірник для перевірки",
                                status: .warning, detail: "пісенників у каталозі немає"))
            return checks
        }

        let index = NativeSongIndex()
        index.open(songs: book.songs, key: "проверка#\(entry.id)")
        let rows = NativeSongRows(index: index)
        rows.titleFormat = state.songTitleFormat

        checks.append(Check(area: songArea, name: "Список тримає рядки, а не значення Song",
                            status: rows.rowCount == book.songs.count ? .ok : .failed,
                            detail: "у збірнику «\(entry.displayName)» \(book.songs.count) пісень, "
                                + "джерело тримає \(rows.rowCount)"))

        let first = rows.row(at: 0)
        let expectedTitle = book.songs[0].title
        let expectedSubtitle = book.songs[0].subtitle ?? ""
        checks.append(Check(area: songArea, name: "Рядок пісні: номер, назва, підзаголовок",
                            status: first.text == expectedTitle && first.detail == expectedSubtitle
                                ? .ok : .failed,
                            detail: "«\(first.lead)» «\(first.text)» / «\(first.detail)»"))

        // Отбор обязан находить ровно то же, что находит эталонный поиск
        // каталога: у автора это одно и то же поле и одно и то же правило.
        var needle = "а"
        for candidate in ["слав", "бог", "хвал", "мир", "а"]
        where !library.search(candidate, in: entry.id, limit: 5000).isEmpty {
            needle = candidate
            break
        }
        let mine = Set((index.filter(query: needle, within: nil) ?? []).map { $0 })
        let theirs = Set(library.search(needle, in: entry.id, limit: 5000)
            .filter { $0.reason == .title || $0.reason == .alternateTitle }
            .map { $0.song.index })
        let missed = theirs.subtracting(mine)
        checks.append(Check(area: songArea, name: "Відбір за літерою сходиться з пошуком каталогу",
                            status: missed.isEmpty ? .ok : .failed,
                            detail: "за «\(needle)»: у нас \(mine.count) пісень, "
                                + "у каталогу за назвами \(theirs.count), загублено \(missed.count)"))

        // Отбор по цифрам: сначала номер, и если по номеру нашлось — на этом
        // всё (5.3.5). Иначе «12» вернуло бы ещё и все названия с «12».
        let byNumber = index.filter(query: "12", within: nil) ?? []
        checks.append(Check(area: songArea, name: "Цифри в полі — це номер пісні",
                            status: byNumber.first == 11 ? .ok : .warning,
                            detail: byNumber.isEmpty
                                ? "за «12» не знайшлося нічого"
                                : "за «12» першою йде пісня № \((byNumber.first ?? 0) + 1), "
                                    + "усього \(byNumber.count)"))

        // Смена отбора не должна ничего терять: номер песни в списке и её
        // место — разные вещи, и путать их нельзя.
        rows.setFilter([5, 17, 42])
        let place = rows.position(ofSong: 17)
        let back = rows.song(at: 1)
        checks.append(Check(area: songArea, name: "Номер пісні й місце у відборі не плутаються",
                            status: place == 1 && back == 17 ? .ok : .failed,
                            detail: "пісня 17 стоїть на рядку \(place.map(String.init) ?? "—"), "
                                + "на рядку 1 пісня \(back.map(String.init) ?? "—")"))
        rows.setFilter(nil)
        return checks
    }

    // MARK: - Источник строк списка частей

    private static func nativeSongParts(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        guard let entry = biggestSongBook(state), let library = state.songLibrary,
              let book = library.book(entry.id),
              let song = book.songs.first(where: { $0.parts.count >= 2 }) else {
            checks.append(Check(area: songArea, name: "Пісня з частинами для перевірки",
                                status: .warning, detail: "підхожої пісні не знайшлося"))
            return checks
        }

        let rows = NativeSongPartRows()
        rows.reload(song: song, palette: state.songPalette)
        checks.append(Check(area: songArea, name: "Частини пісні віддаються по одній",
                            status: rows.rowCount == song.parts.count ? .ok : .failed,
                            detail: "у пісні «\(song.title)» частин \(song.parts.count), "
                                + "джерело тримає \(rows.rowCount)"))

        // `songPartIndex` хранит НОМЕР части, а не её место в списке: у первой
        // части номер бывает и нулём, и единицей.
        let last = song.parts[song.parts.count - 1].index
        checks.append(Check(area: songArea, name: "Номер частини й місце в списку — різні речі",
                            status: rows.position(ofPart: last) == song.parts.count - 1 ? .ok : .failed,
                            detail: "частина з номером \(last) стоїть на рядку "
                                + "\(rows.position(ofPart: last).map(String.init) ?? "—")"))

        // «до 8 строк текста» — столько показывает список частей у автора.
        let long = song.parts.max { $0.lines.count < $1.lines.count } ?? song.parts[0]
        if let place = rows.position(ofPart: long.index) {
            let shown = rows.row(at: place).text.split(separator: "\n", omittingEmptySubsequences: false)
            checks.append(Check(area: songArea, name: "У рядку частини не більше восьми рядків тексту",
                                status: shown.count <= 8 ? .ok : .failed,
                                detail: "у частині «\(long.kind)» рядків \(long.lines.count), "
                                    + "показано \(shown.count)"))
        }

        // Цвет части — из «Цветовой легенды частей песен» (6.4).
        let coloured = (0..<rows.rowCount).contains { rows.row(at: $0).leadColor != nil }
        checks.append(Check(area: songArea, name: "Вид частини позначено своїм кольором",
                            status: coloured ? .ok : .warning,
                            detail: coloured
                                ? "колір береться з «Колірної легенди частин пісень»"
                                : "жодна частина не пофарбувалася — легенда не дійшла"))
        return checks
    }

    // MARK: - Собранное окно

    private static func nativeSongWindow(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let songs = NativeSongsWorkspace.shared
        songs.attach(state: state)
        guard let view = songs.workspaceView else {
            checks.append(Check(area: songArea, name: "Робоча зона зібралася",
                                status: .failed, detail: "вид робочої зони не побудувався"))
            return checks
        }

        // Окно нарочно своё и одноразовое: настоящее главное окно в
        // самопроверке не поднимают, а без размеров список не покажет ни
        // одной строки и мерить будет нечего.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        window.contentView = host
        view.frame = host.bounds
        host.addSubview(view)
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        if let entry = biggestSongBook(state) {
            songs.selectBook(id: entry.id)
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
        // Свёртка названий идёт в стороне от главного потока и поспевает за
        // доли секунды. Человек за это время до поля не дотянется, а
        // самопроверка дотягивается сразу — подождём, иначе мерился бы
        // запасной путь, которого в работе не бывает.
        for _ in 0..<40 where !songs.songIndexIsReady {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        let total = songs.songRows.rowCount
        let visible = songs.songList.visibleItems.count
        checks.append(Check(area: songArea, name: "Робоча зона зібралася і показує збірник",
                            status: total > 0 && visible > 0 ? .ok : .warning,
                            detail: "відкрито «\(songs.model.bookID)», пісень \(total), "
                                + "видно рядків \(visible)"))
        guard total > 40, visible > 0 else {
            view.removeFromSuperview()
            return checks
        }

        // Главное: список спрашивает источник только про видимые строки.
        // Спросил больше — значит он всё-таки строит весь сборник, и мы
        // вернулись туда, откуда ушли.
        NativeList.countsQueries = true
        let before = songs.songList.sourceQueries
        songs.songList.reload()
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let asked = songs.songList.sourceQueries - before
        NativeList.countsQueries = false
        checks.append(Check(area: songArea, name: "Список питає лише про видимі рядки",
                            status: asked <= visible * 3 ? .ok : .failed,
                            detail: "на перечитування \(total) пісень джерело спитано \(asked) разів "
                                + "при \(visible) видимих рядках"))

        // Скорость. Числа снимаются в собранном окне, а не на голой модели:
        // владелец видит именно полный путь до пикселей.
        func measure(_ repeats: Int, _ body: () -> Void) -> Double {
            var samples: [Double] = []
            for pass in 0..<repeats {
                let start = DispatchTime.now().uptimeNanoseconds
                body()
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let end = DispatchTime.now().uptimeNanoseconds
                if pass >= 3 { samples.append(Double(end - start) / 1_000_000) }
            }
            guard !samples.isEmpty else { return 0 }
            return samples.sorted()[samples.count / 2]
        }

        let letters = ["с", "сл", "сла", "слав", "б", "бл", "бла"]
        var letter = 0
        let typing = measure(41) {
            songs.typeSongQuery(letters[letter % letters.count])
            letter += 1
        }
        songs.typeSongQuery("")
        checks.append(Check(area: songArea, name: "Літера в полі швидкого вибору вкладається в кадр",
                            status: speedStatus(typing),
                            detail: String(format: "%.2f мс на збірнику з %d пісень (кадр — 16 мс)",
                                           typing, total)))

        var jump = 12345
        let picking = measure(41) {
            jump = (jump &* 1103515245 &+ 12345) & 0x3FFF_FFFF
            songs.clickSong(row: jump % total)
        }
        checks.append(Check(area: songArea, name: "Вибір пісні вкладається в кадр",
                            status: speedStatus(picking),
                            detail: String(format: "%.2f мс зі стрибком через увесь збірник", picking)))

        var partsRow = 0
        for row in 0..<min(total, 400) where songs.partsCount(ofRow: row) >= 3 {
            songs.clickSong(row: row)
            partsRow = songs.partsCount(ofRow: row)
            break
        }
        if partsRow >= 2 {
            var part = 0
            let switching = measure(41) {
                part = (part + 1) % partsRow
                songs.clickPart(row: part, live: false)
            }
            checks.append(Check(area: songArea, name: "Перемикання куплета вкладається в кадр",
                                status: speedStatus(switching),
                                detail: String(format: "%.2f мс на пісні з %d частин",
                                               switching, partsRow)))
        }

        var step = 0
        let scrolling = measure(61) {
            step = (step + 20) % max(1, total - 30)
            songs.songList.scrollTo(step, place: .top)
        }
        checks.append(Check(area: songArea, name: "Прокрутка списку вкладається в кадр",
                            status: speedStatus(scrolling),
                            detail: String(format: "%.2f мс на сторінку вниз", scrolling)))

        if let other = state.songBooks.first(where: { $0.id != songs.model.bookID }) {
            let home = songs.model.bookID
            var flip = false
            let swapping = measure(21) {
                flip.toggle()
                songs.selectBook(id: flip ? other.id : home)
            }
            songs.selectBook(id: home)
            checks.append(Check(area: songArea, name: "Зміна Пісенника вкладається в кадр",
                                status: speedStatus(swapping),
                                detail: String(format: "%.2f мс між «%@» і «%@» (обидва розібрано)",
                                               swapping, home, other.id)))
        }

        // Свёртка названий стоит десятки миллисекунд и потому считается в
        // стороне от главного потока. Если она понадобилась здесь — значит
        // фоновый разбор не успел, и буква обошлась запасным путём.
        checks.append(Check(area: songArea, name: "Назви згорнуто не на головному потоці",
                            status: songs.hurriedFolds == 0 ? .ok : .warning,
                            detail: songs.hurriedFolds == 0
                                ? "фоновий розбір устигав завжди"
                                : "\(songs.hurriedFolds) разів довелося згорнути на місці"))

        // Сито поводов: пустая сверка не должна рассылать ничего.
        let idleBefore = songs.bridge.idleSyncs
        let sendingBefore = songs.bridge.sendingSyncs
        songs.bridge.sync()
        songs.bridge.sync()
        checks.append(Check(area: songArea, name: "Сито поводів мовчить, коли нічого не змінилося",
                            status: songs.bridge.sendingSyncs == sendingBefore ? .ok : .failed,
                            detail: "дві порожні звірки: марно "
                                + "\(songs.bridge.idleSyncs - idleBefore), з розсилкою "
                                + "\(songs.bridge.sendingSyncs - sendingBefore)"))

        // Меню песни (27) — порядок пунктов из описи окна.
        if let menu = songs.songMenu(song: 0) {
            let titles = menu.items.map { $0.isSeparatorItem ? "──" : $0.title }
            let head = Array(titles.prefix(3))
            let wanted = ["Додати до Плану", "──"]
            let plan = head.first?.contains("План") == true
            checks.append(Check(area: songArea, name: "Меню пісні починається з «Додати до Плану»",
                                status: plan && head.count > 1 && head[1] == wanted[1] ? .ok : .failed,
                                detail: titles.joined(separator: " | ")))
        }

        // Приёмник Плана подключён: без него пункты меню песни и части просто
        // не появлялись, хотя `DeskModel` для них давно написан.
        checks.append(Check(area: songArea, name: "«Додати до Плану» у пісенника підключено",
                            status: songs.model.onAddToPlan != nil ? .ok : .failed,
                            detail: songs.model.onAddToPlan != nil
                                ? "приймач плану на місці"
                                : "приймача немає — пункти меню мовчать"))

        // Щелчок по части обязан поставить и номер части в состоянии: по нему
        // потом листают стрелки и по нему же пишется «История».
        if partsRow >= 2 {
            songs.clickPart(row: 1, live: false)
            let number = state.songPartIndex
            checks.append(Check(area: songArea, name: "Клацання по частині ставить її номер у стані",
                                status: number != nil ? .ok : .failed,
                                detail: "songPartIndex = \(number.map(String.init) ?? "немає")"))
        }

        view.removeFromSuperview()
        return checks
    }

    /// Кадр — 16 мс. Вдвое быстрее кадра — хорошо, вдвое медленнее — плохо.
    private static func speedStatus(_ milliseconds: Double) -> Status {
        if milliseconds < 16 { return .ok }
        if milliseconds < 32 { return .warning }
        return .failed
    }
}
