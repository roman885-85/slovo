import AppKit
import SlovoCore

/// Замір модуля «Пісні» у справжньому вікні.
///
/// Міряється не виклик моделі, а весь шлях до пікселів: сама робота, збирання і
/// розкладка вікна, малювання. Інакше числа немає з чим порівнювати — колишнє вікно
/// міряли саме так, і його 214 мс на натискання це теж повний шлях.
///
/// Запускається ключем `--appkit-songs-bench`, звіт лягає в
/// `~/Library/Logs/slovo-native-songs.txt`.
@MainActor
enum NativeSongsBench {

    static var wantsBench: Bool {
        CommandLine.arguments.contains("--appkit-songs-bench")
    }

    /// Зняти зону «Пісні» в обличчя: зібрати її в новому вікні і записати знімок
    /// у `~/Library/Logs/slovo-native-songs.png`.
    ///
    /// Знімок береться в самого вікна, а не з екрана, навмисно: на одному
    /// моніторі вікно слайда живе на рівні заставки і закриває собою все,
    /// і з екрана знялося б воно. Ознака `--appkit-songs`.
    static var wantsPreview: Bool {
        CommandLine.arguments.contains("--appkit-songs")
    }

    static func preview(state: AppState) {
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated {
                state.mode = .songs
                NativeSongsWorkspace.shared.attach(state: state)
                guard let view = NativeSongsWorkspace.shared.workspaceView,
                      let window = NativeMainWindowController.shared.window,
                      let root = window.contentView else { return }
                NativeMainWindowController.shared.install(view, in: .workspace)
                window.setContentSize(NSSize(width: 1600, height: 1000))
                window.makeKeyAndOrderFront(nil)
                for _ in 0..<8 {
                    root.layoutSubtreeIfNeeded()
                    root.display()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                }
                let songs = NativeSongsWorkspace.shared
                print("песен \(songs.songRows.rowCount), частей \(songs.partRows.rowCount), "
                    + "видно строк \(songs.songList.visibleItems.count)")
                if let bitmap = root.bitmapImageRepForCachingDisplay(in: root.bounds),
                   let canvas = NSGraphicsContext(bitmapImageRep: bitmap) {
                    root.displayIgnoringOpacity(root.bounds, in: canvas)
                    if let data = bitmap.representation(using: .png, properties: [:]) {
                        try? data.write(to: previewURL)
                    }
                }
                // Режим у налаштування не пишемо: знімок не має міняти те, з
                // чого програма почнеться наступного разу.
                state.mode = .bible
                for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
                NSApp.terminate(nil)
            }
        }
    }

    static var previewURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("slovo-native-songs.png")
    }

    static var reportURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("slovo-native-songs.txt")
    }

    private struct Sample {
        var model = 0.0
        var layout = 0.0
        var draw = 0.0
        var total = 0.0
    }

    private static var lines: [String] = []

    static func start(state: AppState) {
        // Бібліотека читається у фоні; міряти вікно, поки розбираються півсотні
        // перекладів і два десятки пісенників, значить міряти чужу роботу.
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { run(state: state) }
        }
    }

    static func run(state: AppState) {
        // Замір гортає пісні і збірники, а програма запам'ятовує, де стояв
        // курсор. Повернемо все на місце, інакше після заміру людина відкриє
        // вікно на випадковій пісні чужого збірника.
        let restore = (book: state.songBookID, song: state.songIndex, part: state.songPartIndex,
                       mode: state.mode)
        let window = NativeMainWindowController.shared.show(state: state)
        state.mode = .songs
        let songs = NativeSongsWorkspace.shared
        songs.attach(state: state)
        songs.bridge.sync()
        if let view = songs.workspaceView {
            NativeMainWindowController.shared.install(view, in: .workspace)
        }
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.makeKeyAndOrderFront(nil)
        settle(window)

        // Міряти треба на тому збірнику, на якому програма встає: у
        // власника це «Песнь возрождения 3400». Вибираємо його за розміром
        // файла, а не за числом пісень: число відоме лише після розбору, а
        // розбирати два десятки збірників заради вибору — хвилини очікування.
        let biggest = biggestBook(state: state)
        if let biggest, biggest.id != songs.model.bookID {
            songs.selectBook(id: biggest.id)
            settle(window)
        }
        // Згортка назв іде осторонь від головного потоку — дамо їй
        // доспіти, інакше перша ж літера міряла б запасний шлях.
        for _ in 0..<20 where !songs.songIndexIsReady {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        settle(window)

        let total = songs.songRows.rowCount
        lines.append("# Замір модуля «Пісні» на AppKit")
        lines.append("")
        lines.append("Збірка робоча. Вікно 1600×1000, три списки на місці, вкладки Пісенників на місці.")
        lines.append("Відкрито Пісенник: \(songs.model.bookID), пісень \(total), "
            + "видно строк \(songs.songList.visibleItems.count).")
        lines.append("Пісенників на смузі: \(state.songBooks.count).")
        lines.append("")
        lines.append("| действие | работа | сборка+раскл. | отрисовка | всего |")
        lines.append("|---|---|---|---|---|")

        guard total > 40 else {
            lines.append("| сборник слишком мал, мерить нечего | — | — | — | — |")
            finish(state: state, restore: restore)
            return
        }

        // 1. Літера в полі швидкого вибору Пісні (31). Кожна літера — це
        // перебір усіх назв збірника і перечитування списку.
        let letters = ["с", "сл", "сла", "слав", "б", "бл", "бла", "благ"]
        var letter = 0
        report("літера в полі швидкого вибору Пісні (31)", repeats: 81, window: window) {
            songs.typeSongQuery(letters[letter % letters.count])
            letter += 1
        }
        songs.typeSongQuery("")
        settle(window)

        // Відбір окремо від списку: перебір трьох з половиною тисяч назв —
        // робота пісенного розділу, а не списку, і звалювати їх в одне число
        // значить сховати, де насправді втрачається час.
        var only = 0
        report("лише відбір (перебір \(total) назв)", repeats: 81, window: window) {
            songs.measureFilterOnly(letters[only % letters.count])
            only += 1
        }
        songs.typeSongQuery("")
        settle(window)

        // 2. Вибір пісні клацанням по видимому рядку.
        songs.songList.scrollTo(0, place: .top)
        settle(window)
        var visible = 0
        report("вибір пісні (клацання по видимому рядку)", repeats: 101, window: window) {
            visible = (visible + 1) % max(1, songs.songList.visibleItems.count)
            songs.clickSong(row: songs.songList.visibleItems.lowerBound + visible)
        }

        // Вибір пісні зі стрибком через увесь збірник: список їде, список
        // частин перечитується цілком.
        var seed = 12345
        report("вибір пісні (стрибок через увесь збірник)", repeats: 61, window: window) {
            seed = (seed &* 1103515245 &+ 12345) & 0x3FFF_FFFF
            songs.clickSong(row: seed % total)
        }

        // 3. Перемикання куплета — те, заради чого все це.
        var picked = 0
        for row in 0..<total where songs.partsCount(ofRow: row) >= 3 {
            songs.clickSong(row: row)
            picked = songs.partsCount(ofRow: row)
            break
        }
        settle(window)
        if picked >= 2 {
            var part = 0
            report("перемикання куплета (у передпоказ)", repeats: 101, window: window) {
                part = (part + 1) % picked
                songs.clickPart(row: part, live: false)
            }
            var live = 0
            report("перемикання куплета (подвійне клацання, у зал)", repeats: 61, window: window) {
                live = (live + 1) % picked
                songs.clickPart(row: live, live: true)
            }
            var arrow = 0
            report("переключение куплета стрелкой", repeats: 101, window: window) {
                arrow += 1
                _ = state.stepSongPart(by: arrow % 2 == 0 ? -1 : 1, live: false)
                songs.bridge.sync()
            }
        }

        // 4. Прокрутка списку пісень від початку до кінця.
        var wheel = 0
        report("прокрутка списка (колесо, три строки)", repeats: 121, window: window) {
            wheel = (wheel + 3) % max(1, total - 30)
            songs.songList.scrollTo(wheel, place: .top)
        }
        var page = 0
        report("прокрутка списка (страница)", repeats: 61, window: window) {
            page = (page + 20) % max(1, total - 30)
            songs.songList.scrollTo(page, place: .top)
        }
        report("прокрутка від початку до кінця збірника", repeats: 21, window: window) {
            songs.songList.scrollTo(total - 1, place: .top)
            songs.songList.scrollTo(0, place: .top)
        }

        // 5. Зміна Пісенника. Міряємо на вже розібраних: розбір файла з диска
        // — це читання і розпакування, а не робота вікна, і його міряємо окремо.
        let two = state.songBooks.filter { $0.id != songs.model.bookID }
        if let other = two.first {
            songs.selectBook(id: other.id)
            settle(window)
            songs.selectBook(id: biggest?.id ?? songs.model.bookID)
            settle(window)
            var flip = false
            let first = biggest?.id ?? songs.model.bookID
            report("зміна Пісенника (обидва вже розібрано)", repeats: 41, window: window) {
                flip.toggle()
                songs.selectBook(id: flip ? other.id : first)
            }
            songs.selectBook(id: first)
            settle(window)
        }

        report("перечитать список песен (\(total) строк)", repeats: 41, window: window) {
            songs.songList.reload()
        }

        // Скільки разів список спитав джерело на одну зміну збірника. Рядків
        // на екрані два десятки; якщо спитано втричі більше — значить вікно
        // перераховує висоти колами, а не один раз.
        NativeList.countsQueries = true
        let before = songs.songList.sourceQueries
        songs.songList.reload()
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let asked = songs.songList.sourceQueries - before
        NativeList.countsQueries = false
        lines.append("")
        lines.append("На одне перечитування списку джерело спитано \(asked) разів "
            + "при \(songs.songList.visibleItems.count) видимих рядках і \(total) піснях у збірнику.")
        lines.append("Згортання назв на головному потоці знадобилося "
            + "\(songs.hurriedFolds) разів (0 — фоновий розбір завжди встигав).")
        lines.append("Сито поводов: вхолостую \(songs.bridge.idleSyncs), "
            + "з розсилкою \(songs.bridge.sendingSyncs).")

        finish(state: state, restore: restore)
    }

    /// Найбільший Пісенник, який і справді відкривається.
    ///
    /// Вибираємо за розміром файла, а не за числом пісень: число відоме лише
    /// після розбору, а розбирати два десятки збірників заради вибору — хвилини
    /// очікування. Биті пропускаємо: у власника такий є (`UNTTP.vbm`), і він
    /// якраз найбільший у теці.
    static func biggestBook(state: AppState) -> SongLibrary.Entry? {
        guard let library = state.songLibrary else { return nil }
        let ordered = state.songBooks.sorted { fileSize($0.url) > fileSize($1.url) }
        for entry in ordered where library.book(entry.id) != nil { return entry }
        return nil
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func finish(state: AppState,
                               restore: (book: String, song: Int?, part: Int?, mode: AppState.WorkMode)) {
        lines.append("")
        lines.append("Медіани в мілісекундах. «Робота» — сам виклик;")
        lines.append("«збирання+розкл.» — `layoutSubtreeIfNeeded` по вікну;")
        lines.append("«малювання» — `displayIfNeeded` по вікну; «разом» — сума.")

        state.songBookID = restore.book
        state.songIndex = restore.song
        state.songPartIndex = restore.part
        state.mode = restore.mode
        // Запис налаштувань у `AppState` відкладений. Піти одразу — значить
        // лишити в налаштуваннях режим «Пісні», і наступний запуск (зокрема
        // самоперевірка) почнеться не з тієї вкладки.
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(text.utf8))
        NSApp.terminate(nil)
    }

    // MARK: - Вимірювання

    private static func report(_ name: String, repeats: Int, window: NSWindow,
                               _ body: () -> Void) {
        var samples: [Sample] = []
        samples.reserveCapacity(repeats)
        for pass in 0..<repeats {
            let sample = measure(window: window, body)
            // Перші три проходи — прогрів: шрифти, шари і смуги прокрутки
            // заводяться один раз, і в медіану їм потрапляти нема чого.
            if pass >= 3 { samples.append(sample) }
        }
        guard !samples.isEmpty else { return }
        func median(_ pick: (Sample) -> Double) -> String {
            let sorted = samples.map(pick).sorted()
            return String(format: "%.3f", sorted[sorted.count / 2])
        }
        lines.append("| \(name) | \(median(\.model)) | \(median(\.layout)) | "
            + "\(median(\.draw)) | \(median(\.total)) |")
    }

    private static func measure(window: NSWindow, _ body: () -> Void) -> Sample {
        var sample = Sample()
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let t1 = DispatchTime.now().uptimeNanoseconds
        window.contentView?.layoutSubtreeIfNeeded()
        let t2 = DispatchTime.now().uptimeNanoseconds
        window.displayIfNeeded()
        let t3 = DispatchTime.now().uptimeNanoseconds
        sample.model = Double(t1 - t0) / 1_000_000
        sample.layout = Double(t2 - t1) / 1_000_000
        sample.draw = Double(t3 - t2) / 1_000_000
        sample.total = Double(t3 - t0) / 1_000_000
        return sample
    }

    /// Дати вікну договорити: розкладку, малювання і все, що відкладено на цикл
    /// подій, — поправки висот, наприклад.
    private static func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
