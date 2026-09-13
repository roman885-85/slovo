import AppKit
import SlovoCore

/// Замечания владельца: «план не всегда срабатывает, но при каких-то условиях
/// начинает работать», «история работает некорректно, некоторые пункты
/// работают, на некоторые не реагирует».
///
/// Берём его настоящую Историю и План и жмём на каждую запись тем же путём,
/// что и щелчок: после нажатия программа обязана стоять ровно там, куда
/// запись ведёт. Которые не привели — перечисляем с причиной.
extension Diagnostics {

    static func journalSection(state: AppState) -> [Check] {
        let area = "План та Історія"
        let desk = DeskModel.shared
        let wasMode = state.mode, wasLive = state.isLive
        let wasBook = state.selectedBookIndex, wasChapter = state.selectedChapterNumber
        let wasVerses = state.selectedVerseNumbers
        let wasSongBook = state.songBookID, wasSong = state.songIndex, wasPart = state.songPartIndex
        let wasSelection = desk.historySelection
        defer {
            state.isLive = wasLive
            state.mode = wasMode
            state.songBookID = wasSongBook
            state.songIndex = wasSong
            state.songPartIndex = wasPart
            state.openScripture(bookPosition: min(wasBook, max(0, state.books.count - 1)),
                                chapter: wasChapter, verses: wasVerses)
            desk.historySelection = wasSelection
            NativeBibleBridge.shared.sync()
        }
        return [historyCheck(area: area, state: state), planCheck(area: area, state: state)]
    }

    /// Куди дійшла програма після натискання — одним рядком для звіту.
    private static func whereNow(_ state: AppState) -> String {
        switch state.mode {
        case .bible:
            let book = state.books.indices.contains(state.selectedBookIndex)
                ? state.books[state.selectedBookIndex].fullName : "?"
            return "Біблія: \(book) \(state.selectedChapterNumber):\(state.selectedVerseNumbers.map(String.init).joined(separator: ","))"
        case .songs:
            let file = state.songLibrary?.entry(state.songBookID)?.url.lastPathComponent ?? "?"
            return "Пісні: \(file) №\(state.songIndex.map(String.init) ?? "—") частина \(state.songPartIndex.map(String.init) ?? "—")"
        default:
            return "режим \(state.mode)"
        }
    }

    private static func historyCheck(area: String, state: AppState) -> Check {
        let desk = DeskModel.shared
        let records = Array(desk.history.records.prefix(80))
        let name = "Історія: кожен запис веде туди, куди обіцяє"
        guard !records.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "історія порожня")
        }
        var faults: [String] = []
        var kinds: [String: Int] = [:]
        for record in records {
            let kind: String
            switch record.kind { case .bible: kind = "Біблія"; case .song: kind = "пісня"; case .text: kind = "текст" }
            kinds[kind, default: 0] += 1
            desk.activate(record, state: state)
            let reason = waitForArrival(state, record: record)
            guard let reason else { continue }
            if faults.count < 8 {
                faults.append("«\(record.caption.prefix(40))» (\(kind)): \(reason); тепер \(whereNow(state))")
            }
        }
        let detail = "записів \(records.count): " + kinds.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
        guard faults.isEmpty else {
            return Check(area: area, name: name, status: .failed,
                         detail: "не привели \(faults.count)+: " + faults.joined(separator: " | ") + ". " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    /// Чекаємо, поки програма стане на місце запису (розділи можуть читатися
    /// з диска), і повертаємо, що не так, якщо не стала.
    private static func waitForArrival(_ state: AppState, record: HistoryRecord) -> String? {
        switch record.kind {
        case .bible:
            wait(untilTrue: {
                state.mode == .bible && !state.isLoadingChapters
                    && state.books.indices.contains(state.selectedBookIndex)
                    && state.books[state.selectedBookIndex].index == record.bookIndex
                    && state.selectedChapterNumber == record.chapter
                    && (record.verses.isEmpty || state.selectedVerseNumbers == record.verses)
            }, seconds: 8)
            guard state.mode == .bible else { return "режим не Біблія" }
            guard state.books.indices.contains(state.selectedBookIndex),
                  state.books[state.selectedBookIndex].index == record.bookIndex else {
                return "книга №\(record.bookIndex) не відкрилася (переклад «\(record.moduleShortName)», зараз «\(state.primaryModule?.info.shortName ?? "?")»)"
            }
            guard state.selectedChapterNumber == record.chapter else { return "розділ \(record.chapter) не відкрився" }
            guard record.verses.isEmpty || state.selectedVerseNumbers == record.verses else {
                return "вірші \(record.verses) не вибралися"
            }
            return nil
        case .song:
            wait(untilTrue: {
                state.mode == .songs && state.songIndex == record.songIndex && state.songPartIndex == record.partIndex
            }, seconds: 5)
            guard state.mode == .songs else { return "режим не Пісні" }
            let file = state.songLibrary?.entry(state.songBookID)?.url.lastPathComponent ?? ""
            guard file.caseInsensitiveCompare(record.songBookFileName) == .orderedSame else {
                return "пісенник «\(record.songBookFileName)» не відкрився"
            }
            guard state.songIndex == record.songIndex else { return "пісня №\(record.songIndex) не вибралася" }
            guard state.songPartIndex == record.partIndex else { return "частина \(record.partIndex) не вибралася" }
            return nil
        case .text:
            wait(untilTrue: { state.mode == .text }, seconds: 3)
            return state.mode == .text ? nil : "режим не Текст"
        }
    }

    private static func planCheck(area: String, state: AppState) -> Check {
        let desk = DeskModel.shared
        let items = desk.plan.items
        let name = "План: кожен пункт відкривається й показується"
        guard !items.isEmpty else {
            return Check(area: area, name: name, status: .skipped, detail: "план порожній")
        }
        var faults: [String] = []
        var kinds: [String: Int] = [:]
        for item in items.prefix(40) {
            var reason: String?
            desk.activate(item, state: state)
            switch item.content {
            case .scripture(let reference):
                kinds["Біблія", default: 0] += 1
                wait(untilTrue: {
                    state.mode == .bible && !state.isLoadingChapters
                        && state.books.indices.contains(state.selectedBookIndex)
                        && state.books[state.selectedBookIndex].index == reference.bookIndex
                        && state.selectedChapterNumber == reference.chapter
                        && (reference.verses.isEmpty || state.selectedVerseNumbers == reference.verses)
                        && state.isLive
                }, seconds: 8)
                if state.mode != .bible { reason = "режим не Біблія" }
                else if !(state.books.indices.contains(state.selectedBookIndex)
                          && state.books[state.selectedBookIndex].index == reference.bookIndex) {
                    reason = "книга №\(reference.bookIndex) не відкрилася (модуль «\(reference.moduleID)»)"
                } else if state.selectedChapterNumber != reference.chapter { reason = "розділ не відкрився" }
                else if !reference.verses.isEmpty && state.selectedVerseNumbers != reference.verses { reason = "вірші не вибралися" }
                else if !state.isLive { reason = "у зал не пішло" }
            case .song(let reference):
                kinds["пісня", default: 0] += 1
                wait(untilTrue: { state.mode == .songs && state.songIndex == reference.songIndex && state.isLive }, seconds: 5)
                if state.mode != .songs { reason = "режим не Пісні" }
                else if state.songIndex != reference.songIndex { reason = "пісня №\(reference.songIndex) з «\(reference.bookFileName)» не вибралася" }
                else if !state.isLive { reason = "у зал не пішло" }
            case .text:
                kinds["текст", default: 0] += 1
                wait(untilTrue: { state.mode == .text }, seconds: 3)
                if state.mode != .text { reason = "режим не Текст" }
            case .file(let reference):
                kinds["файл", default: 0] += 1
                wait(untilTrue: { [.presentation, .pictures, .media].contains(state.mode) }, seconds: 8)
                if ![.presentation, .pictures, .media].contains(state.mode) { reason = "файл «\(reference.name)» не відкрився" }
            }
            if let reason, faults.count < 8 {
                faults.append("«\(item.title.prefix(40))»: \(reason); тепер \(whereNow(state))")
            }
        }
        let detail = "пунктів \(items.count): " + kinds.map { "\($0.key) \($0.value)" }.sorted().joined(separator: ", ")
        guard faults.isEmpty else {
            return Check(area: area, name: name, status: .failed,
                         detail: "не відкрилися \(faults.count)+: " + faults.joined(separator: " | ") + ". " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }
}
