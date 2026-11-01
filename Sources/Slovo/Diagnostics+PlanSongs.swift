import AppKit
import SlovoCore

/// Пісня з Плану: у залі вона є, а куплетів у вкладці «Пісні» немає.
///
/// Власник 01.11: «в плане есть песня, при нажатии для выбора, песня
/// отображается на экране, но отсутствуют куплеты в разделе с текстом песни,
/// переключение куплетов невозможно… Проблема плавающая». Перевірка
/// проходить усі пісні Плану в різному порядку — з переходами між
/// збірниками, з вкладки «Біблія», з увімкненим відбором у списку пісень — і
/// після кожного клацання звіряє: яку пісню взяла вкладка, скільки в неї
/// частин у даних і скільки рядків справді в списку.
extension Diagnostics {

    static func planSongsSection(state: AppState) -> [Check] {
        let area = "План"
        let name = "Пісня з Плану: куплети на місці після кожного клацання"
        wait(untilTrue: { state.songLibrary != nil && !state.songBooks.isEmpty }, seconds: 30)
        guard let library = state.songLibrary else {
            return [Check(area: area, name: name, status: .skipped, detail: "бібліотека пісень не прочиталася")]
        }
        let items = DeskModel.shared.plan.items.filter {
            if case .song = $0.content { return true }
            return false
        }
        guard items.count >= 2 else {
            return [Check(area: area, name: name, status: .skipped, detail: "у Плані менше двох пісень")]
        }
        let songs = NativeSongsWorkspace.shared
        let wasMode = state.mode, wasLive = state.isLive
        defer {
            songs.typeSongQuery("")
            state.isLive = wasLive
            state.mode = wasMode
            Signals.shared.send(.mode)
        }
        func settle(_ seconds: Double = 0.35) { wait(untilTrue: { false }, seconds: seconds) }
        func go(_ mode: AppState.WorkMode) {
            state.mode = mode
            Signals.shared.send(.mode)
            settle(0.3)
        }

        /// Що мало стати: збірник, назва, число частин — з тієї самої
        /// бібліотеки, з якої План бере пісню для залу.
        func expected(_ item: PlanItem) -> (bookID: String, title: String, parts: Int)? {
            guard case .song(let reference) = item.content,
                  let entry = library.entry(fileName: reference.bookFileName),
                  let book = library.book(entry.id),
                  let song = reference.song(in: book) else { return nil }
            return (entry.id, song.title, song.parts.count)
        }

        var faults: [String] = []
        var steps = 0
        var titles: [String] = []
        for (number, item) in items.enumerated() {
            guard let want = expected(item) else {
                titles.append("\(number + 1): НЕ ЗНАЙДЕНО")
                continue
            }
            titles.append("\(number + 1): «\(want.title.prefix(22))» (\(want.bookID), частин \(want.parts))")
        }

        /// Клацнути пункт і звірити вкладку з очікуваним.
        func activate(_ position: Int, _ label: String) {
            let item = items[position]
            DeskModel.shared.activate(item, state: state)
            settle()
            steps += 1
            guard let want = expected(item) else { return }
            let model = songs.model
            let rows = songs.partRows.rowCount
            let table = songs.partList.rowsInTable
            let title = model.song?.title ?? "—"
            let good = model.bookID == want.bookID && title == want.title
                && rows == want.parts && table == want.parts && rows > 0
            if !good {
                faults.append("\(label), пункт \(position + 1) «\(want.title.prefix(20))»: вкладка — збірник \(model.bookID)"
                    + " (чекали \(want.bookID)), пісня «\(title.prefix(20))», частин у даних \(rows), рядків у списку \(table)"
                    + " (чекали \(want.parts)); стан: збірник \(state.songBookID), пісня \(state.songIndex ?? -1),"
                    + " у вкладці \(model.songIndex ?? -1), відбір «\(model.songQuery)»")
            }
        }

        // 1. Підряд, як іде служіння, і навпаки.
        go(.songs)
        for position in items.indices { activate(position, "підряд") }
        for position in items.indices.reversed() { activate(position, "назад") }
        // 2. Кожна пара: з одного пункту на інший — і між різними збірниками.
        for first in items.indices {
            for second in items.indices where second != first {
                activate(first, "пара \(first + 1)→\(second + 1)")
                activate(second, "пара \(first + 1)→\(second + 1)")
            }
        }
        // 3. Клацання з вкладки «Біблія»: План сам переводить на «Пісні».
        for position in items.indices {
            go(.bible)
            activate(position, "з Біблії")
        }
        // 4. У списку пісень стоїть відбір швидкого вибору (оператор шукав
        //    іншу пісню) — пісня з Плану мусить знайтися все одно.
        for position in items.indices {
            go(.songs)
            songs.typeSongQuery("старий")
            settle(0.3)
            activate(position, "з відбором «старий»")
        }
        songs.typeSongQuery("")

        let summary = "пісень у Плані \(items.count): " + titles.joined(separator: "; ")
            + "; переходів \(steps), невдалих \(faults.count); пісня приходила раніше за свій збірник"
            + " \(songs.bookOpenedForStateSongForCheck) раз(и)"
        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: summary + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.prefix(12).joined(separator: " | ")
                                         + (faults.count > 12 ? " | … ще \(faults.count - 12)" : "")))]
    }
}
