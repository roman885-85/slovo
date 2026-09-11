import AppKit
import SlovoCore

/// Замер основания: список на 3400 строк в настоящем окне.
///
/// Меряется не вызов модели, а весь путь до пикселей — так же, как мерили
/// прежнее окно, иначе числа сравнивать не с чем. На каждое действие снимается
/// четыре величины: сама работа, сборка и раскладка окна, отрисовка и всё
/// вместе. Запускается ключом `--appkit-bench`, отчёт ложится в
/// `~/Library/Logs/slovo-native-bench.txt`.
@MainActor
enum NativeBench {

    /// Лёгкий источник строк — та самая форма, ради которой всё затевалось.
    ///
    /// Песенник разбирается один раз, и из него берутся три коротких строки
    /// на песню: номер, название, подзаголовок. Значения `Song` с полным
    /// текстом всех частей в список не попадают вовсе — именно на их
    /// переносе прежнее окно теряло 70 % главного потока.
    final class SongRows: NativeListSource {
        private var numbers: [String] = []
        private var titles: [String] = []
        private var subtitles: [String] = []
        /// Показанные номера песен. Пусто — показаны все.
        private var filter: [Int]?

        var rowCount: Int { filter?.count ?? titles.count }

        func row(at index: Int) -> NativeRow {
            let song = filter.map { $0[index] } ?? index
            return NativeRow(lead: numbers[song], text: titles[song], detail: subtitles[song])
        }

        func open(_ book: SongBook) {
            numbers = book.songs.map { String($0.number) }
            titles = book.songs.map(\.title)
            subtitles = book.songs.map { $0.subtitle ?? "" }
            filter = nil
        }

        func fill(count: Int) {
            numbers = (1...count).map(String.init)
            titles = (1...count).map { "Пісня \($0): хвала і подяка Господу нашому" }
            subtitles = (1...count).map { "слова й музика, збірник \($0 % 40)" }
            filter = nil
        }

        /// Отбор по букве: список сжимается, как при наборе в быстром выборе.
        func keep(prefixContaining needle: String) {
            guard !needle.isEmpty else { filter = nil; return }
            var kept: [Int] = []
            kept.reserveCapacity(256)
            for (index, title) in titles.enumerated()
            where title.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                kept.append(index)
            }
            filter = kept
        }

        func showAll() { filter = nil }
    }

    private struct Sample {
        var model: Double = 0
        var layout: Double = 0
        var draw: Double = 0
        var total: Double = 0
    }

    private static var lines: [String] = []

    static func start(state: AppState) {
        // Библиотека читается в фоне; замерять окно, пока идёт разбор
        // пятидесяти пяти переводов, — значит мерить чужую работу.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            MainActor.assumeIsolated { run(state: state) }
        }
    }

    static func run(state: AppState) {
        let window = NativeMainWindowController.shared.show(state: state)
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.makeKeyAndOrderFront(nil)

        let rows = SongRows()
        // Від домашньої теки того, хто запускає, а не з чужим іменем
        // користувача всередині коду.
        let bookURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/VisioBible.app/Contents/Resources/app/Modules/pv3400.vbm")
        var source = "вигаданий збірник"
        if let book = try? SongBook(fileAt: bookURL) {
            rows.open(book)
            source = "\(book.title) — \(book.songs.count) песен, файл pv3400.vbm"
        } else {
            rows.fill(count: 3400)
        }

        let list = NativeList(mode: .list, metrics: .songs, heights: .uniform(34), fontSize: 13)
        list.allowsMultipleSelection = true
        list.source = rows
        NativeMainWindowController.shared.install(list, in: .workspace)

        settle(window)

        lines.append("# Замір основи вікна на AppKit")
        lines.append("")
        lines.append("Сборка рабочая. Окно 1600×1000, список во всю рабочую область.")
        lines.append("Дані: \(source).")
        lines.append("Рядків у списку: \(list.itemCount). Видно рядків: \(list.visibleItems.count).")
        lines.append("")
        lines.append("| действие | работа | сборка+раскл. | отрисовка | всего |")
        lines.append("|---|---|---|---|---|")

        // Открытие сборника: 3400 строк встают в список.
        report("відкрити збірник 3400", repeats: 11, window: window) {
            list.reload()
        }

        // Колесо мыши: список едет на три строки, большая часть строк на
        // экране остаётся прежними.
        var wheel = 0
        report("прокрутка на три рядки (колесо)", repeats: 121, window: window) {
            wheel = (wheel + 3) % max(1, list.itemCount - 30)
            list.scrollTo(wheel, place: .top)
        }

        // Прокрутка на страницу вниз и вверх — каждая строка на экране новая.
        var page = 0
        report("прокрутка на сторінку", repeats: 61, window: window) {
            page = (page + 20) % max(1, list.itemCount - 30)
            list.scrollTo(page, place: .top)
        }

        // Прыжок в случайное место: ни одной старой строки не остаётся.
        var seed = 12345
        report("стрибок у випадкове місце", repeats: 61, window: window) {
            seed = (seed &* 1103515245 &+ 12345) & 0x3FFF_FFFF
            list.scrollTo(seed % max(1, list.itemCount), place: .center)
        }

        // Обновление одной строки — того, ради чего всё это.
        list.scrollTo(0, place: .top)
        settle(window)
        var one = 0
        report("обновить одну строку", repeats: 101, window: window) {
            one = (one + 1) % max(1, list.visibleItems.count)
            list.reloadRow(list.visibleItems.lowerBound + one)
        }

        // Смена выделения: две строки меняют вид, остальные не трогаются.
        var pick = 0
        report("змінити виділення (один рядок)", repeats: 101, window: window) {
            pick = (pick + 1) % max(1, list.visibleItems.count)
            list.setSelection(IndexSet(integer: list.visibleItems.lowerBound + pick),
                              active: list.visibleItems.lowerBound + pick)
        }

        // Отрезок с Shift на две сотни строк.
        var span = 0
        report("виділити відрізок у 200 рядків", repeats: 41, window: window) {
            span = (span + 1) % 50
            list.setSelection(IndexSet(integersIn: span..<(span + 200)), active: span)
        }

        report("виділити все (3400)", repeats: 41, window: window) {
            list.setSelection(IndexSet(integersIn: 0..<list.itemCount))
            list.setSelection(IndexSet())
        }

        // Буква в быстром выборе. Отбор и перечитывание списка мерим врозь
        // нарочно: отбор — это работа песенного раздела (перебор трёх с
        // половиной тысяч названий), а не списка, и валить их в одно число
        // значит спрятать, где на самом деле теряется время.
        let letters = ["сла", "бла", "гос", "хва", "мир"]
        var letter = 0
        report("відбір за літерою (перебір 3400 назв)", repeats: 41, window: window) {
            rows.keep(prefixContaining: letters[letter % letters.count])
            letter += 1
        }
        report("перечитати список після відбору", repeats: 41, window: window) {
            list.reload()
        }
        rows.showAll()
        list.reload()
        settle(window)

        // То же самое, но с высотами по тексту: так будет жить список стихов,
        // где строка переносится и её высота заранее неизвестна.
        list.heights = .measured(estimate: 34)
        list.scrollTo(0, place: .top)
        settle(window)
        var tall = 0
        report("прокрутка при висотах за текстом", repeats: 61, window: window) {
            tall = (tall + 3) % max(1, list.itemCount - 30)
            list.scrollTo(tall, place: .top)
        }
        var tallRow = 0
        report("оновити один рядок при висотах за текстом", repeats: 61, window: window) {
            tallRow = (tallRow + 1) % max(1, list.visibleItems.count)
            list.reloadRow(list.visibleItems.lowerBound + tallRow)
        }
        list.heights = .uniform(34)
        settle(window)

        lines.append("")
        lines.append("Медіани в мілісекундах. «Робота» — сам виклик списку;")
        lines.append("«збирання+розкл.» — `layoutSubtreeIfNeeded` по вікну;")
        lines.append("«малювання» — `displayIfNeeded` по вікну; «разом» — сума.")

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(text.utf8))
        NSApp.terminate(nil)
    }

    static var reportURL: URL {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
        return logs.appendingPathComponent("slovo-native-bench.txt")
    }

    // MARK: - Измерение

    private static func report(_ name: String, repeats: Int, window: NSWindow,
                               _ body: () -> Void) {
        var samples: [Sample] = []
        samples.reserveCapacity(repeats)
        for pass in 0..<repeats {
            let sample = measure(window: window, body)
            // Первые три прохода — прогрев: шрифты, слои и полосы прокрутки
            // заводятся один раз, и в медиану им попадать незачем.
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

    /// Дать окну договорить: раскладка, отрисовка и всё, что отложено на
    /// цикл событий (поправки высот, например).
    private static func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
