import AppKit
import Combine
import SlovoCore

/// Перекладач з мови `AppState` на мову приводів `Signals`.
///
/// `AppState`, `DeskModel` та `InterfaceSettings` — спільні файли, правити їх
/// із цієї частини роботи не можна, а приводів вони не шлють: у них один спільний
/// `objectWillChange` на всі поля разом. Якщо пустити його прямо у вікно, повернеться
/// рівно те, від чого йдемо, — «щось змінилося, перезберіть усе».
///
/// Тому тут стоїть сито. На спільне «щось змінилося» знімається знімок із
/// двох десятків скалярів, звіряється з колишнім, і назовні йдуть лише ті
/// приводи, в яких величина і справді інша. Звіряння коштує два десятки
/// порівнянь — менше за мікросекунду, і це ціна рівно один раз на дію, а
/// не на кожен список.
///
/// Тонкість про мить. `objectWillChange` приходить ДО правки, читати
/// значення в ньому марно. Звірку відкладаємо не на чергу, а на
/// `RunLoop.main.perform`: він спрацьовує в тому самому проході циклу подій,
/// яким прийшло натискання, і обов'язково до малювання. Отже вікно правиться в
/// тому самому кадрі, зайвого кадру затримки немає. А своє ж натискання звіряє одразу,
/// викликом `sync()`, — тоді робота робиться просто в обробнику клацання.
@MainActor
final class NativeBibleBridge {

    static let shared = NativeBibleBridge()

    private(set) weak var state: AppState?
    private var watchers: [AnyCancellable] = []
    private var scheduled = false
    private var snapshot = Snapshot()
    /// Спостерігачі за тим, чого немає в спільному переліку приводів: текст і фокус
    /// трьох полів швидкого вибору, поля пошуку і поля адреси. Живуть стільки
    /// ж, скільки вікно, тому тримаємо їх прямо, без жетонів.
    private var deskWatchers: [() -> Void] = []

    /// Скільки разів сито пропустило звірку вхолосту і скільки разів щось
    /// послало. Читає самоперевірка — за цими двома числами видно, працює
    /// сито чи все йде наскрізь.
    private(set) var idleSyncs = 0
    private(set) var sendingSyncs = 0

    private init() {}

    // MARK: - Запуск

    func start(state: AppState) {
        guard self.state !== state else { return }
        self.state = state
        watchers.removeAll()
        // Перший знімок мовчки: вікно тільки будується, і розсилати приводи про
        // «змінилося» нічому — підписників ще немає.
        snapshot = Snapshot(state: state)
        watch(state.objectWillChange)
        watch(DeskModel.shared.objectWillChange)
        watch(InterfaceSettings.shared.objectWillChange)
        watch(SettingsStore.shared.objectWillChange)
    }

    private func watch(_ publisher: ObservableObjectPublisher) {
        watchers.append(publisher.sink { [weak self] _ in self?.schedule() })
    }

    /// Відкласти звірку до кінця поточного проходу циклу подій.
    private func schedule() {
        guard !scheduled else { return }
        scheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            guard let self else { return }
            self.scheduled = false
            self.sync()
        }
    }

    /// Звірити стан зі знімком і розіслати приводи.
    ///
    /// Кличуть одразу після своєї ж правки стану — тоді списки стають на
    /// місце в тому самому виклику, що й клацання, а відкладена звірка застане вже
    /// звірений знімок і не зробить нічого.
    func sync() {
        guard let state else { return }
        let fresh = Snapshot(state: state)
        var kinds: [Signals.Kind] = []
        fresh.differences(from: snapshot, into: &kinds)
        snapshot = fresh

        if kinds.isEmpty {
            idleSyncs += 1
        } else {
            sendingSyncs += 1
            Signals.shared.batch {
                for kind in kinds { Signals.shared.send(kind) }
            }
        }
        // Поля вводу перечитують себе завжди: їхні величини — короткі рядки,
        // і звірка коштує дешевше, ніж ще один знімок заради неї.
        notifyDesk()
    }

    // MARK: - Поля, у яких свого приводу немає

    /// Підписатися на зміни полів вводу і фокуса. Спільного приводу на них
    /// немає навмисно: перелік `Signals.Kind` закритий і спільний на все вікно, а
    /// це стосується лише чотирьох полів Біблії.
    func watchDesk(_ body: @escaping () -> Void) {
        deskWatchers.append(body)
    }

    private func notifyDesk() {
        for body in deskWatchers { body() }
    }

    // MARK: - Знімок

    /// Рівно ті величини, за якими видно, що вікну час мінятися.
    ///
    /// Склад списків навмисно описано не самими списками, а тим, ЗВІДКИ вони
    /// взяті: перебирати півтораста віршів на кожне «щось змінилося»
    /// дорожче, ніж звірити три числа, з яких ці вірші випливають.
    @MainActor
    private struct Snapshot {
        var mode: AppState.WorkMode = .bible
        var bookClass: AppState.BookClass = .all
        var primary = ""
        var secondary: [String] = []
        var tabNamesLong = false
        var bookCount = 0
        var selectedBook = 0
        var chapterCount = 0
        var loadingChapters = false
        var selectedChapter = 0
        var chaptersRevision = 0
        var selectedVerses: [Int] = []
        var scrollTicket = 0
        var fontSize: Double = 13
        var interfaceRevision = 0
        var separatorTen = false
        var loadingLibrary = false
        var libraryError = false
        /// Скільки пісенників відкрито. За ним видно, що бібліотека дочиталася.
        var songBookCount = 0
        /// Номери складу смуги перекладів і смуги пісенників. Списки сюди не
        /// переписуємо — склад описано тим, ЗВІДКИ він узятий, як і все інше.
        var moduleRoster = 0
        var songRoster = 0
        var languageRevision = 0

        // Поля і пошук — у них свого приводу немає, звіряємо їх окремо.
        var searchShown = false
        var hitCount = 0
        var searchedQuery = ""
        var searching = false

        init() {}

        init(state: AppState) {
            let desk = DeskModel.shared
            mode = state.mode
            bookClass = state.bookClass
            primary = state.primaryModuleID
            secondary = state.secondaryModuleIDs
            tabNamesLong = state.tabNamesLong
            bookCount = state.books.count
            selectedBook = state.selectedBookIndex
            chapterCount = state.chapters.count
            loadingChapters = state.isLoadingChapters
            selectedChapter = state.selectedChapterNumber
            chaptersRevision = state.chaptersRevision
            selectedVerses = state.selectedVerseNumbers
            scrollTicket = state.scrollToCurrentVerse
            fontSize = state.listFontSize
            interfaceRevision = InterfaceSettings.shared.revision
            separatorTen = state.programOptions.separatorTenVerses
            loadingLibrary = state.isLoadingLibrary
            songBookCount = state.songBooks.count
            moduleRoster = state.moduleRosterRevision
            songRoster = state.songRosterRevision
            libraryError = state.loadError != nil
            languageRevision = state.menuRevision
            searchShown = desk.isSearchResultsShown
            // Рядки вікна результатів — вірші або пісні, залежно від вкладки.
            hitCount = desk.hits.count &* 1000 &+ desk.songHits.count
            searchedQuery = desk.searchedQuery
            searching = desk.isSearching
        }

        /// Чим цей знімок відрізняється від колишнього — у приводах.
        func differences(from old: Snapshot, into kinds: inout [Signals.Kind]) {
            if mode != old.mode { kinds.append(.mode) }
            if bookClass != old.bookClass { kinds.append(.bookClass) }
            if primary != old.primary || secondary != old.secondary
                || tabNamesLong != old.tabNamesLong || moduleRoster != old.moduleRoster {
                kinds.append(.translations)
            }
            // Склад книг випливає з перекладу і класу — перебирати самі
            // книги нема чого.
            if primary != old.primary || bookClass != old.bookClass
                || bookCount != old.bookCount {
                kinds.append(.books)
            }
            if selectedBook != old.selectedBook { kinds.append(.bookSelection) }
            if chapterCount != old.chapterCount || loadingChapters != old.loadingChapters
                || selectedBook != old.selectedBook || primary != old.primary
                || chaptersRevision != old.chaptersRevision {
                kinds.append(.chapters)
            }
            if selectedChapter != old.selectedChapter { kinds.append(.chapterSelection) }
            // Склад віршів — це переклад, книга і розділ. Плюс самі розділи:
            // книга розбирається у фоні, і прочитані розділи приходять тоді,
            // коли переклад, книга й розділ уже ті самі.
            if primary != old.primary || selectedBook != old.selectedBook
                || selectedChapter != old.selectedChapter || chapterCount != old.chapterCount
                || chaptersRevision != old.chaptersRevision {
                kinds.append(.verses)
            }
            if selectedVerses != old.selectedVerses || scrollTicket != old.scrollTicket {
                kinds.append(.verseSelection)
            }
            // Бібліотека дочиталася у фоні: переклади і пісенники з'явилися.
            if bookCount != old.bookCount || songBookCount != old.songBookCount
                || songRoster != old.songRoster || loadingLibrary != old.loadingLibrary {
                kinds.append(.library)
            }
            if languageRevision != old.languageRevision { kinds.append(.language) }
            if fontSize != old.fontSize { kinds.append(.listFontSize) }
            if interfaceRevision != old.interfaceRevision || separatorTen != old.separatorTen {
                kinds.append(.listKind)
            }
            if hitCount != old.hitCount || searchedQuery != old.searchedQuery
                || searching != old.searching {
                kinds.append(.searchResults)
            }
            if searchShown != old.searchShown || loadingLibrary != old.loadingLibrary
                || libraryError != old.libraryError {
                kinds.append(.layout)
            }
        }
    }
}
