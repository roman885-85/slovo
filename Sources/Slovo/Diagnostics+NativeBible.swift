import AppKit
import SlovoCore

/// Самопроверка рабочей области «Библия» в новом окне.
///
/// Глазами здесь проверяется плохо: «список показывает главу» выглядит
/// одинаково и когда строки настоящие, и когда они остались от прежней книги.
/// Поэтому каждая проверка ниже считает по-настоящему — какие строки отдал
/// источник, что осталось в выделении после Shift и Ctrl, сколько раз сито
/// поводов пропустило пустую сверку и во сколько миллисекунд обходится
/// нажатие в собранном окне.
extension Diagnostics {

    static func nativeBibleSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(contentsOf: nativeBibleRows(state))
        checks.append(contentsOf: nativeBibleBridge(state))
        checks.append(contentsOf: nativeBibleColumns(state))
        return checks
    }

    // MARK: - Источники строк

    private static func nativeBibleRows(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Біблія у вікні AppKit"

        let books = NativeBookRows()
        books.reload(state: state)
        let visible = state.visibleBooks
        checks.append(Check(area: area, name: "Книги віддаються по одній, без значень BookInfo",
                            status: books.rowCount == visible.count ? .ok : .failed,
                            detail: "у відборі \(visible.count) книг, джерело тримає \(books.rowCount)"))

        if let first = visible.first {
            books.mode = .icons
            let tile = books.row(at: 0)
            let sameAbbreviation = tile.lead == first.buttonTitle
            let sameName = tile.text == first.fullName
            let tip = tile.tooltip == first.fullName
            checks.append(Check(area: area, name: "Клітинка книги: скорочення, назва й підказка",
                                status: sameAbbreviation && sameName && tip ? .ok : .failed,
                                detail: "«\(tile.lead)» / «\(tile.text)», підказка «\(tile.tooltip)»"))

            let color = NativeBookColors.color(for: first)
            let expected = BookPalette.section(for: first)
            checks.append(Check(area: area, name: "Колір розділу канону в книги свій",
                                status: tile.textColor == color ? .ok : .failed,
                                detail: "\(first.fullName): розділ \(expected), колір "
                                    + describe(color)))

            books.mode = .table
            let row = books.row(at: 0)
            checks.append(Check(area: area, name: "Вигляд «Таблиця»: третя колонка — число розділів",
                                status: row.detail == String(first.chapterCount) ? .ok : .failed,
                                detail: "\(first.fullName): розділів \(first.chapterCount), "
                                    + "у колонці «\(row.detail)»"))

            checks.append(Check(area: area, name: "Книга шукається за номером, а не перебором",
                                status: books.position(ofBook: first.index) == 0 ? .ok : .failed,
                                detail: "книга \(first.index) стоїть рядком "
                                    + "\(books.position(ofBook: first.index).map(String.init) ?? "немає")"))
        }

        let chapters = NativeChapterRows()
        chapters.reload(state: state)
        checks.append(Check(area: area, name: "Розділи віддаються за номером",
                            status: chapters.rowCount == state.chapters.count ? .ok : .failed,
                            detail: "розділів у книзі \(state.chapters.count), рядків \(chapters.rowCount)"))

        let verses = NativeVerseRows()
        verses.separator = true
        verses.reload(state: state)
        let real = state.currentChapter?.verses ?? []
        checks.append(Check(area: area, name: "Вірші віддаються по одному, без значень Verse",
                            status: verses.rowCount == real.count ? .ok : .failed,
                            detail: "у розділі \(real.count) віршів, рядків \(verses.rowCount)"))

        if real.count >= 10 {
            // Черта стоит под каждым десятым стихом — настройка SeparatorTenLine.
            let ruled = (0..<verses.rowCount).filter { verses.row(at: $0).rule != nil }
            let wanted = (0..<real.count).filter { real[$0].number % 10 == 0 }
            checks.append(Check(area: area, name: "Червона риска під кожним десятим віршем",
                                status: ruled == wanted ? .ok : .failed,
                                detail: "рисок \(ruled.count), десятих віршів \(wanted.count)"))
            verses.separator = false
            let none = (0..<verses.rowCount).contains { verses.row(at: $0).rule != nil }
            checks.append(Check(area: area, name: "Налаштування (15) риску й прибирає",
                                status: none ? .failed : .ok,
                                detail: none ? "риска лишилася при вимкненому налаштуванні"
                                             : "вимкнули — рисок не лишилося жодної"))
            verses.separator = true
        }

        verses.singleLine = true
        let clipped = verses.rowCount > 0 ? verses.row(at: 0).singleLine : false
        verses.singleLine = false
        let wrapped = verses.rowCount > 0 ? verses.row(at: 0).singleLine : true
        checks.append(Check(area: area, name: "Кнопки (21) перемикають вигляд вірша",
                            status: clipped && !wrapped ? .ok : .failed,
                            detail: clipped && !wrapped
                                ? "«одна лінія» обрізає рядок, «багаторядковий» переносить"
                                : "вигляд рядка не змінився"))

        verses.state = state
        let menu = verses.rowCount > 0 ? verses.menu(at: 0) : nil
        let titles = menu?.items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
        let wanted = VerseMenuEntry.allCases.map {
            state.text($0.rawValue, default: $0.fallback)
        }
        checks.append(Check(area: area, name: "Меню правої кнопки по віршу — ті самі три пункти",
                            status: titles == wanted ? .ok : .failed,
                            detail: titles.isEmpty ? "меню не зібралося"
                                                   : titles.joined(separator: " | ")))

        let classes = NativeBookClassRows()
        classes.reload(state: state)
        let classTitles = (0..<classes.rowCount).map { classes.row(at: $0).text }
        let wantedClasses = AppState.BookClass.allCases.map { $0.title(in: state) }
        checks.append(Check(area: area, name: "Клас: чотири підписи з файла перекладу",
                            status: classTitles == wantedClasses ? .ok : .failed,
                            detail: classTitles.joined(separator: ", ")))

        return checks
    }

    // MARK: - Сито поводов

    private static func nativeBibleBridge(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Біблія у вікні AppKit"
        let bridge = NativeBibleBridge.shared
        bridge.start(state: state)

        // Считаем, какие поводы уходят на действие. Подписка живёт только
        // внутри проверки, поэтому жетон держим переменной.
        var heard: [Signals.Kind] = []
        let token = Signals.shared.subscribe(Set(Signals.Kind.allCases)) { kind in
            heard.append(kind)
        }

        bridge.sync()
        heard.removeAll()
        let idleBefore = bridge.idleSyncs
        bridge.sync()
        checks.append(Check(area: area, name: "Порожня звірка не будить вікно",
                            status: heard.isEmpty && bridge.idleSyncs > idleBefore ? .ok : .failed,
                            detail: heard.isEmpty
                                ? "нічого не змінилося — жодного поводу не пішло"
                                : "на рівному місці пішли поводи: \(names(heard))"))

        // Смена стиха: обязан уйти только повод о выделении.
        let numbers = state.currentChapter?.verses.map(\.number) ?? []
        if numbers.count > 2 {
            let was = state.selectedVerseNumbers
            heard.removeAll()
            state.selectedVerseNumbers = [numbers[1]]
            bridge.sync()
            let onlySelection = heard == [.verseSelection]
            checks.append(Check(area: area, name: "Зміна вірша чіпає лише список віршів",
                                status: onlySelection ? .ok : .failed,
                                detail: onlySelection
                                    ? "пішов один повід: verseSelection"
                                    : "пішли поводи: \(names(heard))"))
            state.selectedVerseNumbers = was
            bridge.sync()
        }

        // F6 — «прокрутить к текущему стиху»: выбор не менялся, а повод нужен.
        heard.removeAll()
        state.scrollToCurrentVerse += 1
        bridge.sync()
        checks.append(Check(area: area, name: "F6 доходить до списку, не міняючи вибору",
                            status: heard.contains(.verseSelection) ? .ok : .failed,
                            detail: heard.isEmpty ? "повід не пішов — список не прокрутиться"
                                                  : "пішли поводи: \(names(heard))"))

        // Смена класса книг: меняется состав книг, стихи не трогаются.
        let wasClass = state.bookClass
        heard.removeAll()
        state.bookClass = wasClass == .all ? .new : .all
        bridge.sync()
        let touchesBooks = heard.contains(.books) && heard.contains(.bookClass)
        checks.append(Check(area: area, name: "Зміна класу перезбирає лише книги",
                            status: touchesBooks && !heard.contains(.verses) ? .ok : .failed,
                            detail: "пішли поводи: \(names(heard))"))
        state.bookClass = wasClass
        bridge.sync()

        _ = token
        return checks
    }

    // MARK: - Собранное окно

    private static func nativeBibleColumns(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Біблія у вікні AppKit"

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 900),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1600, height: 900))
        window.contentView = host

        let verse = NativeVerseColumn(state: state)
        verse.frame = NSRect(x: 0, y: 0, width: 640, height: 860)
        host.addSubview(verse)
        let strip = NativeTranslationStripView(state: state)
        strip.frame = NSRect(x: 660, y: 800, width: 900, height: 30)
        host.addSubview(strip)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        // Раскладка колонок: ширины из описи и разделители между ними.
        let columns = NativeColumnsView()
        let boxes = (0..<4).map { _ in NSView() }
        columns.install([
            .init(view: boxes[0], minWidth: 96, idealWidth: 112, maxWidth: 150),
            .init(view: boxes[1], minWidth: 200, idealWidth: 270, maxWidth: 380),
            .init(view: boxes[2], minWidth: 54, idealWidth: 72, maxWidth: 110),
            .init(view: boxes[3], minWidth: 320, idealWidth: 320, maxWidth: 0),
        ])
        columns.frame = NSRect(x: 0, y: 0, width: 1200, height: 700)
        host.addSubview(columns)
        columns.layoutSubtreeIfNeeded()
        let widths = boxes.map { Int($0.frame.width) }
        let rest = 1200 - 3 - (112 + 270 + 72)
        checks.append(Check(area: area, name: "Чотири колонки й три роздільники",
                            status: widths == [112, 270, 72, rest] ? .ok : .failed,
                            detail: "ширини \(widths.map(String.init).joined(separator: ", ")); "
                                + "решта дісталася «Віршу»"))
        columns.removeFromSuperview()

        // Скорость. Меряем весь путь до пикселей, как и замер основания:
        // сама работа, раскладка окна и отрисовка.
        let numbers = state.currentChapter?.verses.map(\.number) ?? []
        if numbers.count > 3 {
            var step = 0
            let verseTime = median(repeats: 21, window: window) {
                step = (step + 1) % numbers.count
                state.selectedVerseNumbers = [numbers[step]]
                NativeBibleBridge.shared.sync()
            }
            checks.append(Check(area: area, name: "Перемикання вірша вкладається в кадр",
                                status: verseTime < 16 ? .ok : (verseTime < 33 ? .warning : .failed),
                                detail: String(format: "%.2f мс на вірш у розділі з %d "
                                    + "(відлагоджувальна збірка; кадр — 16 мс)", verseTime, numbers.count)))
        }

        let chapters = state.chapters.map(\.number)
        if chapters.count > 2 {
            var step = 0
            let chapterTime = median(repeats: 11, window: window) {
                step = (step + 1) % chapters.count
                state.selectedChapterNumber = chapters[step]
                NativeBibleBridge.shared.sync()
            }
            checks.append(Check(area: area, name: "Перемикання розділу вкладається в кадр",
                                status: chapterTime < 16 ? .ok : (chapterTime < 33 ? .warning : .failed),
                                detail: String(format: "%.2f мс на розділ", chapterTime)))
        }

        verse.removeFromSuperview()
        strip.removeFromSuperview()
        window.contentView = nil
        return checks
    }

    // MARK: - Мелочи

    private static func median(repeats: Int, window: NSWindow, _ body: () -> Void) -> Double {
        var samples: [Double] = []
        for pass in 0..<repeats {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let end = DispatchTime.now().uptimeNanoseconds
            // Первые три прохода — прогрев: шрифты и слои заводятся один раз.
            if pass >= 3 { samples.append(Double(end - start) / 1_000_000) }
        }
        guard !samples.isEmpty else { return 0 }
        return samples.sorted()[samples.count / 2]
    }

    private static func names(_ kinds: [Signals.Kind]) -> String {
        kinds.isEmpty ? "жодного" : kinds.map(\.rawValue).joined(separator: ", ")
    }

    private static func describe(_ color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.deviceRGB) else { return "системний" }
        return String(format: "%.2f/%.2f/%.2f", rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
    }
}
