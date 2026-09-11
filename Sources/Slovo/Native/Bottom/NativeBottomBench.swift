import AppKit
import SlovoCore

/// Замір нижнього ряду у справжньому вікні.
///
/// Міряється не виклик моделі, а весь шлях до пікселів — робота, розкладка вікна,
/// малювання. Інакше числа немає з чим порівнювати: колишнє вікно витрачало дві сотні
/// мілісекунд якраз на розкладку і малювання, а не на сам виклик.
///
/// Запускається ключем `--appkit-bottom-bench`, звіт лягає в
/// `~/Library/Logs/slovo-bottom-bench.txt`.
@MainActor
enum NativeBottomBench {

    private struct Sample {
        var model: Double = 0
        var layout: Double = 0
        var draw: Double = 0
        var total: Double = 0
    }

    private static var lines: [String] = []

    static func start(state: AppState) {
        // Бібліотека читається у фоні; заміряти вікно, поки йде розбір
        // п'ятдесяти п'яти перекладів, — значить міряти чужу роботу.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: false) { _ in
            MainActor.assumeIsolated { run(state: state) }
        }
    }

    static func run(state: AppState) {
        let window = NativeMainWindowController.shared.show(state: state)
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.makeKeyAndOrderFront(nil)
        let row = NativeBottom.install(state: state)
        settle(window)

        lines.append("# Замір нижнього ряду вікна на AppKit")
        lines.append("")
        lines.append("Окно 1600×1000. План (10), История (11), Предпросмотр (12), Управление (13).")
        lines.append("Предпросмотр \(Int(row.preview.bounds.width))×\(Int(row.preview.bounds.height)) точек.")
        lines.append("")
        lines.append("| действие | работа | сборка+раскл. | отрисовка | всего |")
        lines.append("|---|---|---|---|---|")

        previewBench(row: row, state: state, window: window)
        historyBench(row: row, window: window)
        planBench(row: row, state: state, window: window)

        lines.append("")
        lines.append("Медіани в мілісекундах. «Робота» — сам виклик;")
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
        return logs.appendingPathComponent("slovo-bottom-bench.txt")
    }

    // MARK: - Передпоказ

    /// Перемикання вірша: слайд інший, усе вікно колишнє.
    private static func previewBench(row: NativeBottomRow, state: AppState, window: NSWindow) {
        let verses = sampleVerses(state)
        let style = state.previewStyle
        lines.append("| — дані: \(verses.count) віршів, \(verses.first?.count ?? 0)…"
            + "\(verses.last?.count ?? 0) знаков | | | | |")

        var index = 0
        report("переключить стих (предпросмотр)", repeats: 61, window: window) {
            index = (index + 1) % verses.count
            row.preview.show(slide: Slide(mainText: verses[index],
                                          reference: "Ин 3:\(index + 1)"),
                             style: style)
        }

        // Той самий слайд удруге: роботи не має бути зовсім.
        let same = Slide(mainText: verses[0], reference: "Ин 3:1")
        row.preview.show(slide: same, style: style)
        settle(window)
        report("той самий слайд ще раз (нічого не змінилося)", repeats: 41, window: window) {
            row.preview.show(slide: same, style: style)
        }

        // Два переклади й адреса — найважчий слайд, три шматки тексту.
        var pair = 0
        report("слайд із двома перекладами й адресою", repeats: 41, window: window) {
            pair = (pair + 1) % verses.count
            row.preview.show(slide: Slide(mainText: verses[pair],
                                          secondaryTexts: [verses[(pair + 7) % verses.count]],
                                          reference: "Ин 3:\(pair + 1)"),
                             style: style)
        }

        var live = false
        report("показ у зал і назад (рамка)", repeats: 41, window: window) {
            live.toggle()
            row.preview.isLive = live
        }
        row.preview.isLive = false
    }

    /// Вірші для заміру: справжні, якщо бібліотека відкрилася, інакше своєї
    /// довжини — передпоказ міряється за довжиною тексту, а не за його змістом.
    private static func sampleVerses(_ state: AppState) -> [String] {
        if let verses = state.currentChapter?.verses, verses.count >= 8 {
            return verses.map(\.text)
        }
        return (1...40).map { number in
            String(repeating: "слово ", count: 12 + number % 18)
                + "і це вірш номер \(number)."
        }
    }

    // MARK: - Історія

    /// Прокрутка довгої історії. В автора список обмежено шістдесятьма
    /// рядками, але прокрутка зобов'язана коштувати однаково за будь-якої довжини —
    /// інакше перша ж вирощена межа поверне вікну затримку.
    private static func historyBench(row: NativeBottomRow, window: NSWindow) {
        let long = LongSource(count: 3000)
        let list = NativeList(mode: .list, metrics: NativeHistoryLikeMetrics.value,
                              heights: .uniform(16), fontSize: 11)
        list.frame = row.history.bounds
        row.history.addSubview(list)
        list.source = long
        settle(window)

        lines.append("| — история: \(list.itemCount) строк, видно \(list.visibleItems.count) | | | | |")

        var wheel = 0
        report("прокрутка історії на три рядки", repeats: 121, window: window) {
            wheel = (wheel + 3) % max(1, list.itemCount - 20)
            list.scrollTo(wheel, place: .top)
        }
        var jump = 12345
        report("стрибок у випадкове місце історії", repeats: 61, window: window) {
            jump = (jump &* 1103515245 &+ 12345) & 0x3FFF_FFFF
            list.scrollTo(jump % list.itemCount, place: .center)
        }
        var pick = 0
        report("клацання по рядку історії (виділення)", repeats: 61, window: window) {
            pick = (pick + 1) % max(1, list.visibleItems.count)
            list.setSelection(IndexSet(integer: list.visibleItems.lowerBound + pick))
        }

        list.source = nil
        list.removeFromSuperview()
        settle(window)
    }

    private final class LongSource: NativeListSource {
        private let captions: [String]
        init(count: Int) {
            captions = (1...count).map { "Бут. \($0)- На початку Бог створив Небо та землю." }
        }
        var rowCount: Int { captions.count }
        func row(at index: Int) -> NativeRow { NativeRow(text: captions[index], singleLine: true) }
    }

    private enum NativeHistoryLikeMetrics {
        static let value: NativeListMetrics = {
            var m = NativeListMetrics()
            m.padding = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
            m.textFontDelta = 0
            return m
        }()
    }

    // MARK: - План

    /// Перетягування пункту. Міряються дві різні речі: крок перетягування
    /// (миша поїхала — позначка вставки переїхала) і саме відпускання, коли
    /// список переставляється і перечитується.
    ///
    /// План людини замір не чіпає: він зібраний до служіння, і переставляти в
    /// ньому пункти заради чисел не можна. Міряємо на своєму списку тієї самої виробки, а
    /// зі справжнього беремо лише вартість перечитування.
    private static func planBench(row: NativeBottomRow, state: AppState, window: NSWindow) {
        let sample = SamplePlan(count: 60)
        let list = NativeList(mode: .list, metrics: NativeListLikePlan.value,
                              heights: .uniform(18), fontSize: 12)
        list.frame = row.plan.bounds
        row.plan.addSubview(list)
        list.source = sample
        let reorder = NativeListReorder(list: list)
        reorder.onMove = { [weak list] from, to in
            sample.move(from: from, to: to)
            list?.reload()
        }
        settle(window)

        lines.append("| — план: \(list.itemCount) пунктов, видно \(list.visibleItems.count) | | | | |")
        guard let table = NativeListProbe.table(in: list), table.numberOfRows > 4 else {
            list.source = nil
            list.removeFromSuperview()
            return
        }

        // Точки рахуємо в координатах таблиці (рахунок згори вниз) і переводимо
        // в координати списку: у списку рахунок знизу вгору.
        func point(row: Int, part: CGFloat) -> NSPoint {
            let rect = table.rect(ofRow: min(row, table.numberOfRows - 1))
            return list.convert(NSPoint(x: 20, y: rect.minY + rect.height * part), from: table)
        }

        reorder.begin(at: point(row: 0, part: 0.5))
        var offset = 0
        report("шаг перетаскивания пункта плана", repeats: 121, window: window) {
            offset = (offset + 1) % max(2, list.visibleItems.count - 1)
            reorder.track(to: point(row: offset, part: 0.3))
        }
        reorder.cancel()

        var from = 0
        report("відпустити пункт (перестановка й перечитування)", repeats: 41, window: window) {
            from = (from + 1) % max(2, list.itemCount - 2)
            reorder.begin(at: point(row: 0, part: 0.5))
            sample.move(from: from, to: from + 2)
            list.reload()
            reorder.cancel()
        }

        var chosen = 0
        report("клацання по пункту плану (виділення)", repeats: 61, window: window) {
            chosen = (chosen + 1) % max(1, list.visibleItems.count)
            list.click(item: list.visibleItems.lowerBound + chosen)
        }

        list.source = nil
        list.removeFromSuperview()
        settle(window)

        // Справжня панель: скільки коштує привід «план змінився». Читаємо, а
        // не правимо — план лишається таким, яким його зібрали.
        lines.append("| — настоящий план: \(DeskModel.shared.plan.count) пунктов | | | | |")
        report("повод «план изменился» (перечитать панель)", repeats: 41, window: window) {
            row.plan.reloadPlan()
        }
    }

    /// Список пунктів для заміру — ті самі рядки, що в справжнього Плану.
    private final class SamplePlan: NativeListSource {
        private var titles: [String]
        init(count: Int) {
            titles = (1...count).map { "Ів 3:\($0) - Так бо Бог полюбив світ, що дав Сина" }
        }
        var rowCount: Int { titles.count }
        func row(at index: Int) -> NativeRow { NativeRow(text: titles[index], singleLine: true) }
        /// Позиція вставки рахується ДО вилучення — так само, як у `ServicePlan`.
        func move(from: Int, to: Int) {
            guard titles.indices.contains(from), to >= 0, to <= titles.count else { return }
            let item = titles.remove(at: from)
            titles.insert(item, at: to > from ? to - 1 : to)
        }
    }

    private enum NativeListLikePlan {
        static let value: NativeListMetrics = {
            var m = NativeListMetrics()
            m.padding = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
            m.textFontDelta = 0
            return m
        }()
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

    /// Дати вікну договорити: розкладка, малювання і все, що відкладено на цикл
    /// подій, — перекладач приводів якраз звідти й працює.
    private static func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
