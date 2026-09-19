import AppKit
import SlovoCore

/// Замечание владельца: «при изменении стилей отображения интерфейса часть
/// текста теряется (названия, содержимое текстов песен, Библии и др.),
/// происходит наползание текста за видимые границы».
///
/// Проверяем то самое: перебираем виды списков («Значки», «Мал. значки»,
/// «Список», «Таблица», «одна линия» / «много строк») и кегли ползунка (20),
/// а потом спрашиваем у каждой строки, вмещается ли её текст в отведённую
/// высоту. Не вмещается — это и есть «наползание».
extension Diagnostics {

    static func listStylesSection(state: AppState) -> [Check] {
        let area = "Вигляд списків"
        let interface = InterfaceSettings.shared
        let wasFont = state.listFontSize
        let wasMode = state.mode
        let wasSongBooks = interface.bookView(.songs)
        let wasSongVerses = interface.verseView(.songs)
        let wasBibleBooks = interface.bookView(.bible)
        let wasBibleVerses = interface.verseView(.bible)

        defer {
            interface.setBookView(wasSongBooks, in: .songs)
            interface.setVerseView(wasSongVerses, in: .songs)
            interface.setBookView(wasBibleBooks, in: .bible)
            interface.setVerseView(wasBibleVerses, in: .bible)
            Signals.shared.send(.listKind)
            state.listFontSize = wasFont
            Signals.shared.send(.listFontSize)
            state.mode = wasMode
            settle()
        }

        var checks: [Check] = []
        checks.append(startupFitCheck(state: state))
        checks.append(listWidthCheck())
        checks.append(fitCheck(area: area, state: state, scope: .bible, title: "Біблія"))
        checks.append(fitCheck(area: area, state: state, scope: .songs, title: "Пісні"))
        checks.append(hitCheck(area: area, state: state, scope: .bible, title: "Біблія"))
        checks.append(hitCheck(area: area, state: state, scope: .songs, title: "Пісні"))
        return checks
    }

    /// Дати вікну перерисуватися: висоти рядків наводяться відкладено.
    private static func settle() {
        for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    /// Списки режиму й те, як їх звати в звіті.
    private static func lists(for scope: InterfaceSettings.ListScope) -> [(String, NativeList)] {
        switch scope {
        case .songs:
            let songs = NativeSongsWorkspace.shared
            var result: [(String, NativeList)] = []
            if let list = songs.songList { result.append(("пісні", list)) }
            if let list = songs.partList { result.append(("частини", list)) }
            if let list = songs.groupList { result.append(("групи", list)) }
            return result
        default:
            let bible = NativeBibleWorkspace.shared
            var result: [(String, NativeList)] = []
            if let column = bible.bookColumn { result.append(("книги", column.bookList)) }
            if let column = bible.chapterColumn { result.append(("розділи", column.chapterList)) }
            if let column = bible.verseColumn { result.append(("вірші", column.verseList)) }
            return result
        }
    }

    /// Власник: «вибір книги Біблії в режимі списку не відповідає положенню
    /// вказівника миші». Клацаємо в середину кожного видимого рядка тим самим
    /// шляхом, що й миша (`NativeListProbe.item(at:)`), і рядок під вказівником
    /// мусить бути саме тим, у який клацнули.
    private static func hitCheck(area: String, state: AppState,
                                 scope: InterfaceSettings.ListScope, title: String) -> Check {
        let name = "\(title): клацання влучає в той рядок, що під вказівником"
        let interface = InterfaceSettings.shared
        state.mode = scope == .songs ? .songs : .bible
        settle()
        var faults: [String] = []
        var tried = 0
        var perView: [String: (ok: Int, miss: Int)] = [:]
        for books in InterfaceSettings.BookViewMode.allCases {
            for font in [13.0, 22.0] {
                interface.setBookView(books, in: scope)
                Signals.shared.send(.listKind)
                state.listFontSize = font
                Signals.shared.send(.listFontSize)
                settle()
                for (label, list) in lists(for: scope) {
                    guard let table = NativeListProbe.table(in: list), list.rowsNow > 0 else { continue }
                    let visible = list.visibleItems
                    for item in visible.prefix(24) {
                        guard let rect = list.frameOfItem(item) else { continue }
                        // Три точки в рядку: ліворуч, посередині, праворуч.
                        for part in [0.15, 0.5, 0.85] {
                            let point = NSPoint(x: rect.minX + rect.width * part, y: rect.midY)
                            tried += 1
                            let hit = list.item(atListPoint: point)
                            var tally = perView[books.rawValue] ?? (0, 0)
                            if hit == item { tally.ok += 1 } else { tally.miss += 1 }
                            perView[books.rawValue] = tally
                            guard hit != item else { continue }
                            let fault = String(format: "%@ · %@ · %@ · кегль %.0f: клацнули в рядок %d (%.0f,%.0f), а влучили в %@",
                                               title, label, books.rawValue, font, item, point.x, point.y,
                                               hit.map(String.init) ?? "нікуди")
                            if faults.count < 6, !faults.contains(fault) { faults.append(fault) }
                            _ = table
                        }
                    }
                }
            }
        }
        let detail = "клацань: \(tried); по виглядах: "
            + perView.keys.sorted().map { "\($0) влучило \(perView[$0]!.ok), повз \(perView[$0]!.miss)" }.joined(separator: ", ")
        guard faults.isEmpty else {
            return Check(area: area, name: name, status: .failed, detail: faults.joined(separator: "; ") + ". " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Як списки виглядають одразу після запуску — нічого не перемикаючи.
    ///
    /// Власник: «при запуске программы часто окно со списком стихов или
    /// куплетов отображается с перекрытием некоторых строк, исправляется если
    /// переключить песню или главу». Перемикання все лагодить, тож міряти
    /// треба саме перший показ: спершу вірші, як їх відкрила програма, потім
    /// куплети першої-ліпшої пісні.
    static func startupFitCheck(state: AppState) -> Check {
        var faults: [String] = []
        var lines: [String] = []
        func look(_ label: String, _ list: NativeList) {
            let rows = min(list.rowsNow, 60)
            guard rows > 0 else { return }
            var worst = 0.0
            for index in 0..<rows {
                guard let fit = list.fit(ofRow: index) else { continue }
                worst = max(worst, fit.drawn - fit.given)
                guard fit.drawn > fit.given + 0.5 else { continue }
                faults.append(String(format: "%@, рядок %d: намальовано %.0f, а місця %.0f", label, index + 1, fit.drawn, fit.given))
                break
            }
            lines.append(String(format: "%@: рядків %d, найтісніший із запасом %.0f", label, rows, -worst))
        }
        for (label, list) in lists(for: .bible) where label == "вірші" { look("вірші", list) }
        // Пісні: як їх побачить людина, що відкрила вкладку вперше.
        state.mode = .songs
        settle()
        for (label, list) in lists(for: .songs) where label == "частини" || label == "пісні" { look(label, list) }
        return Check(area: "Вигляд списків", name: "Одразу після запуску рядки не наповзають",
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty ? lines.joined(separator: "; ") : faults.joined(separator: "; "))
    }

    /// Список, зміряний на широкому місці, а показаний на вузькому.
    ///
    /// Власник 19.09.2026: «при запуске программы часто окно со списком
    /// стихов или куплетов отображается с перекрытием некоторых строк,
    /// исправляется если переключить песню или главу». Саме так і буває,
    /// коли висоти рядків зміряно за однієї ширини, а малюються вони за
    /// іншої: при запуску вікно спершу розкладається на всю ширину, а потім
    /// стовпці стають на свої місця.
    static func listWidthCheck() -> Check {
        let name = "Рядки не наповзають, коли список став вужчим"
        let list = NativeList(mode: .list, metrics: .verses, heights: .measured(estimate: 30), fontSize: 13)
        let source = WidthProbe()
        list.source = source
        let holder = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        holder.addSubview(list)
        list.frame = holder.bounds
        let window = bench(for: holder, size: NSSize(width: 640, height: 400))
        defer { window.orderOut(nil) }
        list.reload()
        holder.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        wait(untilTrue: { false }, seconds: 0.3)
        let wide = (0..<source.rowCount).compactMap { list.fit(ofRow: $0) }
        // Стало вдвічі вужче — текст переноситься більше разів.
        list.frame = NSRect(x: 0, y: 0, width: 300, height: 400)
        list.needsLayout = true
        holder.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        wait(untilTrue: { false }, seconds: 0.3)
        var faults: [String] = []
        for index in 0..<source.rowCount {
            guard let fit = list.fit(ofRow: index) else { continue }
            if fit.drawn > fit.given + 0.5 {
                faults.append(String(format: "рядок %d: намальовано %.0f, а місця %.0f", index + 1, fit.drawn, fit.given))
            }
        }
        return Check(area: "Вигляд списків", name: name, status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                        ? "на 640 пт: \(wide.map { Int($0.given) }); після звуження до 300 пт усі рядки вміщаються"
                        : faults.joined(separator: "; "))
    }

    /// Джерело для перевірки ширини: довгі вірші, які на вузькому місці
    /// переносяться більше разів, ніж на широкому.
    private final class WidthProbe: NSObject, NativeListSource {
        private let texts = [
            "На початку Бог створив небо та землю, а земля була пуста та порожня, і темрява була над безоднею",
            "І сказав Бог: Хай станеться світло! І сталося світло, і побачив Бог світло, що добре воно",
            "І назвав Бог світло: День, а темряву назвав: Ніч. І був вечір, і був ранок, день перший",
        ]
        var rowCount: Int { texts.count }
        func row(at index: Int) -> NativeRow {
            var row = NativeRow()
            row.lead = "\(index + 1)"
            row.text = texts[index]
            return row
        }
    }

    private static func fitCheck(area: String, state: AppState,
                                 scope: InterfaceSettings.ListScope, title: String) -> Check {
        let name = "\(title): текст уміщається в рядок за будь-якого вигляду й кегля"
        let interface = InterfaceSettings.shared
        state.mode = scope == .songs ? .songs : .bible
        settle()
        guard !lists(for: scope).isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "списків немає (вікно не зібране)")
        }

        var faults: [String] = []
        var measured = 0
        // Скільки рядків усе-таки ріже три крапки: це не поломка (у вузькій
        // плитці інакше не буває), але видно, чи не поменшало їх від правок.
        var cutRows = 0
        for books in InterfaceSettings.BookViewMode.allCases {
            for verses in InterfaceSettings.VerseViewMode.allCases {
                for font in [9.0, 13.0, 18.0, 22.0] {
                    interface.setBookView(books, in: scope)
                    interface.setVerseView(verses, in: scope)
                    Signals.shared.send(.listKind)
                    state.listFontSize = font
                    Signals.shared.send(.listFontSize)
                    settle()

                    for (label, list) in lists(for: scope) {
                        let rows = min(list.rowsNow, 40)
                        guard rows > 0 else { continue }
                        for index in 0..<rows {
                            guard let fit = list.fit(ofRow: index) else { continue }
                            measured += 1
                            if fit.cut { cutRows += 1 }
                            // Півточки — це округлення, а не наповзання.
                            guard fit.drawn > fit.given + 0.5 else { continue }
                            let fault = String(format: "%@ · %@ · кегль %.0f: намальовано %.0f, а рядок %.0f",
                                               title, label, font, fit.drawn, fit.given)
                            if !faults.contains(fault) { faults.append(fault) }
                            break
                        }
                    }
                }
            }
        }
        // Знімок найважчого сполучення — щоб було на що подивитися очима:
        // плитка й найбільший кегль.
        interface.setBookView(.icons, in: scope)
        interface.setVerseView(.multiline, in: scope)
        Signals.shared.send(.listKind)
        state.listFontSize = 22
        Signals.shared.send(.listFontSize)
        settle()
        var picture = ""
        if let root = NativeMainWindowController.shared.root {
            let file = "slovo-вигляд-\(title).png"
            if snapshot(root, to: file) { picture = "; знімок ~/Library/Logs/" + file }
        }
        let detail = "перевірено рядків: \(measured); з трьома крапками: \(cutRows)" + picture
        guard faults.isEmpty else {
            return Check(area: area, name: name, status: .failed,
                         detail: faults.prefix(6).joined(separator: "; ") + ". " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }
}
