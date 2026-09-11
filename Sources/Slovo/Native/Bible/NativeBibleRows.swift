import AppKit
import SlovoCore

/// Розфарбування книг за розділами канону в кольорах AppKit.
///
/// Числа не переписано заново: розділ книги береться в `BookPalette`, і якщо
/// автор поправить межі розділів, вони поправляться тут самі. Окремим
/// переліком тут лише кольори — `Color` зі SwiftUI списку не годиться, а
/// перераховувати його в `NSColor` на кожен рядок значить платити за це
/// двадцять разів на кадр.
enum NativeBookColors {

    static func color(for book: BookInfo) -> NSColor {
        switch BookPalette.section(for: book) {
        case .law:        return NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.42, alpha: 1)
        case .history:    return NSColor(calibratedRed: 0.00, green: 0.45, blue: 0.20, alpha: 1)
        case .poetry:     return NSColor(calibratedRed: 0.00, green: 0.42, blue: 0.38, alpha: 1)
        case .prophets:   return NSColor(calibratedRed: 0.32, green: 0.30, blue: 0.05, alpha: 1)
        case .gospels:    return NSColor(calibratedRed: 0.70, green: 0.10, blue: 0.10, alpha: 1)
        case .acts:       return NSColor(calibratedRed: 0.55, green: 0.20, blue: 0.05, alpha: 1)
        case .epistles:   return NSColor(calibratedRed: 0.13, green: 0.25, blue: 0.62, alpha: 1)
        case .revelation: return NSColor(calibratedRed: 0.45, green: 0.10, blue: 0.45, alpha: 1)
        case .other:      return .labelColor
        }
    }
}

// MARK: - Клас (1)

/// Чотири кнопки стовпчиком: Уся Біблія, Стар.Заповіт, Нов.Заповіт, Неканон.
///
/// Рядків усього чотири, і все одно це джерело, а не набір кнопок: тоді
/// підсвічування вибраного, шрифт і заливка живуть за тими самими правилами, що й у
/// трьох сусідніх колонках, а підписи перечитуються на зміні мови одним
/// рухом.
@MainActor
final class NativeBookClassRows: NativeListSource {

    private var titles: [String] = []
    let classes = AppState.BookClass.allCases

    var rowCount: Int { titles.count }

    func row(at index: Int) -> NativeRow {
        NativeRow(text: titles[index], singleLine: true)
    }

    func reload(state: AppState) {
        titles = classes.map { $0.title(in: state) }
    }
}

// MARK: - Книга (2)

/// Книги відкритого перекладу, відібрані Класом.
///
/// У список кладуться чотири короткі масиви, а не сімдесят сім значень
/// `BookInfo`: скорочення, повне ім'я, число розділів і готовий колір розділу.
/// Збираються вони один раз на зміну перекладу або класу, а не на натискання.
@MainActor
final class NativeBookRows: NativeListSource {

    private var abbreviations: [String] = []
    private var names: [String] = []
    private var chapterCounts: [String] = []
    private var colors: [NSColor] = []
    /// Номер книги в модулі — його чекає `AppState.selectedBookIndex`.
    private(set) var bookIndexes: [Int] = []
    /// Зворотне переведення: номер книги → рядок списку.
    private var positions: [Int: Int] = [:]

    /// Вигляд списку (22): значки, мал. значки, список, таблиця.
    var mode: InterfaceSettings.BookViewMode = .icons

    var rowCount: Int { names.count }

    func row(at index: Int) -> NativeRow {
        switch mode {
        case .icons:
            return NativeRow(lead: abbreviations[index], text: names[index],
                             textColor: colors[index], tooltip: names[index])
        case .smallIcons:
            // Клітинка дрібна: у ній одне скорочення, а повне ім'я — у підказці.
            return NativeRow(lead: abbreviations[index], text: "",
                             textColor: colors[index], tooltip: names[index])
        case .list:
            return NativeRow(lead: abbreviations[index], text: names[index],
                             leadColor: colors[index], textColor: colors[index],
                             singleLine: true, tooltip: names[index])
        case .table:
            return NativeRow(lead: abbreviations[index], text: names[index],
                             detail: chapterCounts[index],
                             leadColor: colors[index],
                             singleLine: true, tooltip: names[index])
        }
    }

    func reload(state: AppState) {
        let books = state.visibleBooks
        abbreviations = books.map(\.buttonTitle)
        names = books.map(\.fullName)
        chapterCounts = books.map { String($0.chapterCount) }
        colors = books.map(NativeBookColors.color(for:))
        bookIndexes = books.map(\.index)
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(bookIndexes.count)
        for (position, index) in bookIndexes.enumerated() { positions[index] = position }
    }

    /// Рядок списку, на якому стоїть ця книга. Немає її у відборі — nil.
    func position(ofBook index: Int) -> Int? { positions[index] }
}

// MARK: - Розділ (3)

@MainActor
final class NativeChapterRows: NativeListSource {

    private var titles: [String] = []
    private(set) var numbers: [Int] = []
    private var positions: [Int: Int] = [:]

    var rowCount: Int { titles.count }

    func row(at index: Int) -> NativeRow {
        NativeRow(text: titles[index], singleLine: true)
    }

    func reload(state: AppState) {
        numbers = state.chapters.map(\.number)
        titles = numbers.map(String.init)
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(numbers.count)
        for (position, number) in numbers.enumerated() { positions[number] = position }
    }

    func position(ofChapter number: Int) -> Int? { positions[number] }
}

// MARK: - Вірш (4)

/// Вірші відкритого розділу.
///
/// У список ідуть два масиви готових рядків — номер і текст. Значення `Verse`
/// сюди не потрапляють: у псалмі 118 їх сто сімдесят шість, і переносити їх на
/// кожне натискання нема чого.
@MainActor
final class NativeVerseRows: NativeListSource {

    /// Червона риска під кожним десятим віршем — налаштування `SeparatorTenLine`.
    private static let ruleColor = NSColor(calibratedRed: 0.78, green: 0.20, blue: 0.20, alpha: 0.7)

    private var labels: [String] = []
    private var texts: [String] = []
    private(set) var numbers: [Int] = []
    private var positions: [Int: Int] = [:]

    /// «Текст в одну лінію», кнопка (21).
    var singleLine = false
    /// (15) «Розділ. лінією по 10 віршів».
    var separator = false

    /// Кому йдуть пункти меню правої кнопки.
    weak var state: AppState?

    var rowCount: Int { texts.count }

    func row(at index: Int) -> NativeRow {
        NativeRow(lead: labels[index], text: texts[index],
                  rule: separator && numbers[index] % 10 == 0 ? Self.ruleColor : nil,
                  singleLine: singleLine)
    }

    func reload(state: AppState) {
        self.state = state
        let verses = state.currentChapter?.verses ?? []
        numbers = verses.map(\.number)
        labels = numbers.map(String.init)
        texts = verses.map(\.text)
        positions.removeAll(keepingCapacity: true)
        positions.reserveCapacity(numbers.count)
        for (position, number) in numbers.enumerated() { positions[number] = position }
    }

    func position(ofVerse number: Int) -> Int? { positions[number] }

    /// Меню правої кнопки списку віршів — розділ 5.1.4.
    ///
    /// Склад і порядок беруться в `VerseMenuEntry`: там же їх читає
    /// самоперевірка, і другого переліку тих самих трьох пунктів заводити не можна —
    /// інакше меню вікна SwiftUI і меню вікна AppKit розійдуться мовчки.
    func menu(at index: Int) -> NSMenu? {
        guard let state, numbers.indices.contains(index) else { return nil }
        let number = numbers[index]
        let menu = NSMenu()
        for entry in VerseMenuEntry.allCases {
            let item = NSMenuItem(title: state.text(entry.rawValue, default: entry.fallback),
                                  action: #selector(NativeVerseMenuTarget.fire(_:)),
                                  keyEquivalent: "")
            let target = NativeVerseMenuTarget(entry: entry, verse: number, rows: self)
            item.target = target
            item.representedObject = target
            menu.addItem(item)
            if entry.isFollowedByDivider { menu.addItem(.separator()) }
        }
        return menu
    }

    /// Праве клацання по невиділеному вірші працює з ним, а не з колишнім
    /// виділенням. Уже виділене не чіпаємо: інакше меню по уривку з п'яти
    /// віршів звузило б його до одного, і в план пішло б не те.
    fileprivate func perform(_ entry: VerseMenuEntry, verse: Int) {
        guard let state else { return }
        if !state.selectedVerseNumbers.contains(verse) {
            state.selectVerse(verse, extending: false)
        }
        switch entry {
        case .addToPlan:
            DeskModel.shared.addCurrentToPlan(state: state)
        case .copyToText:
            TextModuleModel.shared.receive(from: state)
            state.mode = .text
        case .copyToClipboard:
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(state.slide.mainText, forType: .string)
        }
        NativeBibleBridge.shared.sync()
    }
}

/// Приймач пункту меню. Меню будується в мить клацання і живе до його закриття,
/// тому ціль пункту тримається самим пунктом через `representedObject`.
@MainActor
private final class NativeVerseMenuTarget: NSObject {
    private let entry: VerseMenuEntry
    private let verse: Int
    private weak var rows: NativeVerseRows?

    init(entry: VerseMenuEntry, verse: Int, rows: NativeVerseRows) {
        self.entry = entry
        self.verse = verse
        self.rows = rows
    }

    @objc func fire(_ sender: Any?) {
        rows?.perform(entry, verse: verse)
    }
}
