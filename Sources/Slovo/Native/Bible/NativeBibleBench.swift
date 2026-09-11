import AppKit
import SlovoCore

/// Замір робочої області «Біблія» у справжньому вікні.
///
/// Міряється не виклик моделі, а весь шлях до пікселів: сама робота, збирання і
/// розкладка вікна, малювання. Інакше числа немає з чим порівнювати — колишнє вікно
/// міряли саме так, і його 214 мс на натискання це теж повний шлях.
///
/// Запускається ключем `--appkit-bible-bench`, звіт лягає в
/// `~/Library/Logs/slovo-native-bible.txt`.
@MainActor
enum NativeBibleBench {

    static var wantsBench: Bool {
        CommandLine.arguments.contains("--appkit-bible-bench")
    }

    static var reportURL: URL {
        FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs")
            .appendingPathComponent("slovo-native-bible.txt")
    }

    private static var lines: [String] = []

    static func start(state: AppState) {
        // Бібліотека читається у фоні; міряти вікно, поки розбираються півсотні
        // перекладів, значить міряти чужу роботу.
        Timer.scheduledTimer(withTimeInterval: 6, repeats: false) { _ in
            MainActor.assumeIsolated { run(state: state) }
        }
    }

    static func run(state: AppState) {
        // Замір гортає книги і переклади, а `AppState` запам'ятовує, де стояв
        // курсор. Повернемо все на місце, інакше після заміру людина відкриє
        // програму на випадковій книзі чужого перекладу.
        let restore = (module: state.primaryModuleID, bookClass: state.bookClass,
                       book: state.selectedBookIndex, chapter: state.selectedChapterNumber,
                       verses: state.selectedVerseNumbers)
        let window = NativeMainWindowController.shared.show(state: state)
        NativeBibleWorkspace.shared.attach(state: state)
        window.setContentSize(NSSize(width: 1600, height: 1000))
        window.makeKeyAndOrderFront(nil)
        settle(window)

        // Замір іде по Псалтирю: Псалом 118 — найдовший розділ Біблії,
        // 176 віршів, і саме на ньому колишнє вікно вставало помітніше за все.
        openPsalms(state: state, window: window)

        lines.append("# Замір робочої області «Біблія» на AppKit")
        lines.append("")
        lines.append("Вікно 1600×1000, чотири колонки на місці, смуга перекладів на місці.")
        lines.append("Перевод: \(state.primaryModule?.info.shortName ?? state.primaryModuleID), "
            + "книг \(state.books.count), перекладів на смузі \(state.orderedModules.count).")
        lines.append("Відкрито: \(state.currentBook?.fullName ?? "—") "
            + "\(state.selectedChapterNumber), віршів у розділі "
            + "\(state.currentChapter?.verses.count ?? 0).")
        lines.append("")
        lines.append("| действие | работа | сборка+раскл. | отрисовка | всего |")
        lines.append("|---|---|---|---|---|")

        let numbers = state.currentChapter?.verses.map(\.number) ?? []
        if numbers.count > 3 {
            var step = 0
            report("перемикання вірша (розділ із \(numbers.count) віршів)",
                   repeats: 61, window: window) {
                step = (step + 1) % numbers.count
                state.selectedVerseNumbers = [numbers[step]]
                NativeBibleBridge.shared.sync()
            }

            var pair = 0
            report("відрізок із десяти віршів (Shift)", repeats: 41, window: window) {
                pair = (pair + 1) % max(1, numbers.count - 10)
                state.selectedVerseNumbers = Array(numbers[pair..<(pair + 10)])
                NativeBibleBridge.shared.sync()
            }

            report("вся глава разом (⌘A)", repeats: 21, window: window) {
                state.selectAllVerses()
                NativeBibleBridge.shared.sync()
                state.selectedVerseNumbers = [numbers[0]]
                NativeBibleBridge.shared.sync()
            }
        }

        let chapters = state.chapters.map(\.number)
        if chapters.count > 2 {
            // Зміну розділу міряємо натроє: спершу одна правка стану — це
            // робота `AppState` (перезбирання слайда і розсилка по виводах),
            // потім відповідь вікна поверх неї. Інакше незрозуміло, кому дорікати.
            var step = 0
            report("перемикання розділу: правка стану", repeats: 41, window: window) {
                step = (step + 1) % chapters.count
                state.selectedChapterNumber = chapters[step]
            }
            NativeBibleBridge.shared.sync()
            settle(window)
            report("перемикання розділу: правка й відповідь вікна", repeats: 41, window: window) {
                step = (step + 1) % chapters.count
                state.selectedChapterNumber = chapters[step]
                NativeBibleBridge.shared.sync()
            }
            if let list = NativeBibleWorkspace.shared.verseList {
                report("перечитать список стихов", repeats: 41, window: window) {
                    list.reload()
                }
                // Скільки разів список спитав джерело на одну зміну розділу.
                // Рядків на екрані два десятки; якщо спитано втричі більше —
                // значить вікно перераховує висоти колами, а не один раз.
                NativeList.countsQueries = true
                let before = list.sourceQueries
                step = (step + 1) % chapters.count
                state.selectedChapterNumber = chapters[step]
                NativeBibleBridge.shared.sync()
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let asked = list.sourceQueries - before
                NativeList.countsQueries = false
                // Те саме перечитування за однакових висот. Вміст і
                // малювання ті самі, різниця — лише в тому, чи рахує
                // таблиця висоту кожного рядка за текстом.
                list.heights = .uniform(70)
                settle(window)
                report("перечитати список: висоти однакові", repeats: 41, window: window) {
                    list.reload()
                }
                list.heights = .measured(estimate: 30)
                settle(window)
                lines.append("| _(на одну зміну розділу джерело спитали про "
                    + "\(asked) строках, видно \(list.visibleItems.count))_ | | | | |")
            }
            // Те саме «в одну лінію»: усі рядки однієї висоти, і таблиця
            // про висоти не питає зовсім. Різниця між двома рядками —
            // ціна висот, рахованих за текстом.
            let was = InterfaceSettings.shared.verseView(.bible)
            InterfaceSettings.shared.setVerseView(.singleLine, in: .bible)
            NativeBibleBridge.shared.sync()
            settle(window)
            report("перемикання розділу: текст в одну лінію", repeats: 41, window: window) {
                step = (step + 1) % chapters.count
                state.selectedChapterNumber = chapters[step]
                NativeBibleBridge.shared.sync()
            }
            InterfaceSettings.shared.setVerseView(was, in: .bible)
            NativeBibleBridge.shared.sync()
            settle(window)
        }

        let books = state.visibleBooks.map(\.index)
        if books.count > 2 {
            var step = 0
            report("переключение книги", repeats: 41, window: window) {
                step = (step + 1) % books.count
                state.selectedBookIndex = books[step]
                NativeBibleBridge.shared.sync()
            }
        }

        // Прокрутка Псалма 118 колесом. Список їде на три рядки, і
        // більшість рядків на екрані лишається колишніми — так само, як це
        // робить рука на служінні.
        do {
            openPsalms(state: state, window: window)
            if let list = NativeBibleWorkspace.shared.verseList {
                var wheel = 0
                report("прокрутка Псалма 118 на три рядки", repeats: 61, window: window) {
                    wheel = (wheel + 3) % max(1, list.itemCount)
                    list.scrollTo(wheel, place: .top)
                }
                var page = 0
                report("прокрутка Псалма 118 на сторінку", repeats: 41, window: window) {
                    page = (page + 20) % max(1, list.itemCount)
                    list.scrollTo(page, place: .top)
                }
            }
        }

        // Клас книг і смуга перекладів.
        report("смена класса книг", repeats: 21, window: window) {
            state.bookClass = state.bookClass == .all ? .new : .all
            NativeBibleBridge.shared.sync()
        }

        if state.orderedModules.count > 1 {
            let ids = state.orderedModules.map(\.identifier)
            var step = 0
            report("смена перевода (полоса вкладок)", repeats: 21, window: window) {
                step = (step + 1) % ids.count
                state.primaryModuleID = ids[step]
                NativeBibleBridge.shared.sync()
            }
        }

        lines.append("")
        lines.append("Медіани в мілісекундах. «Робота» — правка стану й відповідь вікна;")
        lines.append("«збирання+розкл.» — `layoutSubtreeIfNeeded` по вікну;")
        lines.append("«малювання» — `displayIfNeeded` по вікну; «разом» — сума.")
        lines.append("Мета — менше 16 мс на дію: це один кадр.")

        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: reportURL, atomically: true, encoding: .utf8)
        FileHandle.standardOutput.write(Data(text.utf8))

        // Повернути курсор туди, де він стояв. Відкласти це на `defer` не можна:
        // `NSApp.terminate` іде в `exit`, звідки керування не повертається,
        // і людина знайшла б програму відкритою на чужій книзі чужого перекладу.
        // Записи откладываются, поэтому даём циклу событий их дописать.
        state.primaryModuleID = restore.module
        state.bookClass = restore.bookClass
        state.selectedBookIndex = restore.book
        state.selectedChapterNumber = restore.chapter
        state.selectedVerseNumbers = restore.verses
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        NSApp.terminate(nil)
    }

    /// Встать на Псалом 118 и дождаться, пока книга разберётся.
    private static func openPsalms(state: AppState, window: NSWindow) {
        // Нужен полный перевод: в еврейском тексте книг тридцать девять и
        // своя нумерация псалмов, и «Псалом 118» там на полтораста стихов
        // короче.
        if state.books.count < 60,
           let full = state.orderedModules.first(where: { $0.books.count >= 66 }) {
            state.primaryModuleID = full.identifier
            NativeBibleBridge.shared.sync()
            settle(window)
        }
        guard let psalms = state.books.first(where: { $0.canonicalNumber == 230 }) else { return }
        state.selectedBookIndex = psalms.index
        NativeBibleBridge.shared.sync()
        // Книга разбирается в фоне: пока глав нет, мерить нечего.
        for _ in 0..<10 where state.chapters.isEmpty { settle(window) }
        settle(window)
        if state.chapters.contains(where: { $0.number == 118 }) {
            state.selectedChapterNumber = 118
            NativeBibleBridge.shared.sync()
            settle(window)
        }
    }

    // MARK: - Измерение

    private static func report(_ name: String, repeats: Int, window: NSWindow,
                               _ body: () -> Void) {
        var work: [Double] = []
        var layout: [Double] = []
        var draw: [Double] = []
        for pass in 0..<repeats {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            let t1 = DispatchTime.now().uptimeNanoseconds
            window.contentView?.layoutSubtreeIfNeeded()
            let t2 = DispatchTime.now().uptimeNanoseconds
            window.displayIfNeeded()
            let t3 = DispatchTime.now().uptimeNanoseconds
            // Перші три проходи — прогрів: шрифти, шари і смуги прокрутки
            // заводяться один раз, і в медіану їм потрапляти нема чого.
            guard pass >= 3 else { continue }
            work.append(Double(t1 - t0) / 1_000_000)
            layout.append(Double(t2 - t1) / 1_000_000)
            draw.append(Double(t3 - t2) / 1_000_000)
        }
        guard !work.isEmpty else { return }
        func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }
        let total = median(work) + median(layout) + median(draw)
        lines.append(String(format: "| %@ | %.3f | %.3f | %.3f | %.3f |",
                            name, median(work), median(layout), median(draw), total))
    }

    /// Дати вікну договорити: розкладку, малювання і все, що відкладено на цикл
    /// подій, — поправки висот і розбір книги у фоні.
    private static func settle(_ window: NSWindow) {
        for _ in 0..<6 {
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
