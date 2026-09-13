import AppKit
import Combine
import UniformTypeIdentifiers
import SlovoCore

/// Состояние разделов 5.1.5–5.1.11 руководства: окно результатов поиска (5),
/// три поля быстрого выбора (6), поиск (8), быстрый выбор места Писания (9),
/// План (10) и История (11).
///
/// Почему отдельный объект, а не поля в `AppState`: `AppState` — общий файл
/// нескольких частей работы, и его нельзя править из этой. Всё, что нужно
/// только этим разделам, живёт здесь, а `AppState` получает лишь готовые
/// команды — «выбрать книгу», «показать стих».
///
/// Объект один на программу: окно у неё тоже одно, а горячие клавиши F2–F9
/// ставят монитор событий, который должен быть ровно один на приложение.
@MainActor
final class DeskModel: ObservableObject {

    static let shared = DeskModel()

    /// Какое из трёх полей быстрого выбора (6) сейчас принимает ввод.
    enum QuickField: Int, CaseIterable, Identifiable {
        case book, chapter, verse
        var id: Int { rawValue }
    }

    // MARK: - Окно результатов поиска (5) и поиск (8)

    /// Окно показывается, только если была набрана строка поиска, нажата
    /// кнопка «Показать/скрыть результаты поиска» или Ctrl+F3 — раздел 5.1.5.
    @Published var isSearchResultsShown = false
    @Published private(set) var hits: [TextSearch.Hit] = []
    @Published private(set) var isSearching = false
    /// Доля построенного поискового индекса. Приходит только при первом
    /// обращении к модулю — на 31 тысяче стихов это несколько секунд.
    @Published private(set) var indexProgress: Double?
    @Published private(set) var isTruncated = false
    @Published private(set) var searchedQuery = ""
    /// В каком переводе получены строки списка: сменили перевод — список чужой.
    @Published private(set) var searchedModuleID = ""

    private let search = TextSearch()
    /// Отложенный запуск поиска. Первый заход в модуль читает 31 тысячу
    /// стихов, а оператор набирает слово по букве — гонять чтение на каждую
    /// букву незачем.
    private var searchDelay: DispatchWorkItem?

    /// Находка поиска по песням: песня, часть и где в тексте нашлось.
    ///
    /// На вкладке «Песни» поле поиска (8) ищет по открытому Песеннику, а не
    /// по Библии: владелец набирал слово из песни и получал стихи. Подсветка
    /// та же, что у стихов, — красные куски внутри строки.
    struct SongHit: Hashable, Identifiable {
        /// Номер песни в сборнике (с нуля) — им её открывает песенный раздел.
        let songIndex: Int
        /// Номер части; `nil` — нашлось в названии.
        let partIndex: Int?
        /// Подпись строки: «12. Название — Куплет 2».
        let title: String
        let text: String
        let highlights: [Range<Int>]
        var id: String { "\(songIndex).\(partIndex ?? -1)" }
        var segments: [TextSearch.Hit.Segment] { TextSearch.segments(of: text, highlights: highlights) }
    }
    @Published private(set) var songHits: [SongHit] = []
    /// Номер последнего запущенного поиска по песням: ответ устаревшего
    /// поиска приходит из фона и должен быть отброшен.
    private var songSearchToken = 0

    /// Сколько строк сейчас в окне результатов — по той вкладке, что открыта.
    func hitCount(mode: AppState.WorkMode) -> Int { mode == .songs ? songHits.count : hits.count }

    // MARK: - Поля быстрого выбора (6) и быстрый выбор места (9)

    @Published var bookQuery = ""
    @Published var chapterQuery = ""
    @Published var verseQuery = ""
    /// Строка поля (9) — «[Номер] Книга Глава Стих Стих_по» — живёт в
    /// `AppState.quickInput`: поле там уже было, и держать одну строку в двух
    /// местах незачем. Здесь только разбор — `applyAddress`.
    @Published var quickFocus: QuickField?

    /// Счётчики-«звонки»: увеличиваются по горячей клавише, а поле, увидев
    /// новое значение, забирает себе фокус. Через `Bool` так не сделать —
    /// повторное нажатие той же клавиши не изменило бы значения.
    @Published private(set) var searchFocusRequest = 0
    @Published private(set) var addressFocusRequest = 0
    @Published private(set) var planFocusRequest = 0

    /// Те же действия, что и клавиши, но для пунктов меню «Действия»:
    /// N20 «Поиск», N21 «Быстрый выбор», N19 «Установить фокус на План»,
    /// N31–N33 — три поля быстрого выбора.
    /// F3 и пункт меню N20 только ставят курсор в поле.
    ///
    /// Окно результатов (5) они не открывают: «Окно появляется только, если
    /// была набрана строка для поиска, была нажата горячая клавиша „Ctrl+F3“
    /// или нажата кнопка „Показать / Скрыть результаты поиска“» — событий
    /// ровно три, и передача фокуса в их число не входит.
    func focusSearchField() {
        searchFocusRequest += 1
    }
    func focusAddressField() { addressFocusRequest += 1 }
    func focusPlan() { planFocusRequest += 1 }
    func focusQuickField(_ field: QuickField) { quickFocus = field }

    /// Номер стиха, который набирают прямо над списком стихов (раздел 5.1.4:
    /// «набрать его номер бегло и нажать Enter»).
    @Published var typedVerseNumber = ""
    private var typedVerseTimeout: DispatchWorkItem?

    // MARK: - План (10)

    @Published var plan = ServicePlan()
    @Published var planSelection: Set<PlanItem.ID> = []
    /// План служіння, відкладений на час проповіді. Поки він тут, `plan` —
    /// це план проповідника: як «останній план» на диск він не пишеться, а
    /// після проповіді план служіння повертається таким, яким був.
    @Published private(set) var servicePlanAside: ServicePlan?
    var isSermon: Bool { servicePlanAside != nil }
    /// Сообщение о том, что план не прочитался или прочитался не весь.
    @Published var planWarning: String?

    private var planAutosave: DispatchWorkItem?

    // MARK: - История (11)

    /// «В историю заносятся адреса всех стихов, которые были ПЕРВЫМИ ПОКАЗАНЫ
    /// в окне слайда после их выбора» — раздел 5.1.11.
    ///
    /// Поэтому список ведёт не предпросмотр, а показ в зале: `AppState`
    /// зовёт `rememberLive(state:)` из `showCurrent()` и `present(_:live:)`.
    /// Раньше запись делал `refreshSlide()`, то есть в историю попадало и то,
    /// что оператор просто перебрал стрелками и в зал так и не отдал.
    @Published private(set) var history = ServiceHistory()
    /// Выделенная строка истории — по ней работает клавиша Del.
    @Published var historySelection: UUID?

    private var historyAutosave: DispatchWorkItem?

    // MARK: -

    /// Раскладка берётся не своим чтением `hotkeys.ini`, а общей на программу
    /// (`EffectiveHotkeys`).
    ///
    /// Клавиши в руководстве названы «по умолчанию: их можно изменить в
    /// „Настройка → Параметры → Горячие клавиши“». Пока этот раздел читал файл
    /// сам и один раз при запуске, переназначение в окне «Параметры» до F3 и
    /// F7 не доходило: нажал «Ок», а клавиша осталась прежней. Теперь спрашиваем
    /// общую раскладку на каждое нажатие — она же по «Ок» и обновляется.
    private func hotkey(_ action: String) -> Hotkey? {
        EffectiveHotkeys.hotkey(action)
    }

    private var hotkeys: Any?
    private weak var state: AppState?
    /// Подписка на смену перевода — по ней перезапускается поиск (3.3).
    private var moduleWatch: AnyCancellable?
    /// Папка данных программы: рядом с ней у оригинала History.ini, PlanDef.ini
    /// и папка Plans. Становится известна вместе с `AppState`.
    private var dataRoot: URL?

    private init() {}

    // MARK: - Поиск (8)

    /// Набор в поле (8): окно результатов (5) обязано появиться само —
    /// «Окно появляется только, если была набрана строка для поиска».
    func searchQueryChanged(_ query: String, state: AppState) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { isSearchResultsShown = true }

        searchDelay?.cancel()
        guard !trimmed.isEmpty else {
            runSearch("", state: state)
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.runSearch(trimmed, state: state) }
        searchDelay = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    /// Кнопка (6.1) «Показать / Скрыть результаты поиска» и Ctrl+F3.
    func toggleSearchResults() {
        isSearchResultsShown.toggle()
    }

    /// Курсор поставили в поле поиска — самое время построить ход по модулю.
    ///
    /// Первое обращение читает весь перевод, и на служении лучше заплатить
    /// эти секунды тогда, когда оператор только тянется к полю, чем когда он
    /// уже набрал слово и ждёт список.
    func prepareSearch(state: AppState) {
        guard let module = state.primaryModule else { return }
        guard module.identifier != searchedModuleID || hits.isEmpty else { return }
        search.prepare(module, progress: { [weak self] value in
            self?.indexProgress = value < 1 ? value : nil
        }, completion: { [weak self] in
            self?.indexProgress = nil
        })
    }

    /// Запускает поиск по текущему переводу. Предыдущий запрос отменяется —
    /// оператор набирает слово по букве, и промежуточные результаты не нужны.
    func runSearch(_ query: String, state: AppState) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // На вкладке «Песни» ищем по Песеннику — стихи там ни к чему.
        if state.mode == .songs {
            search.cancel()
            hits = []
            indexProgress = nil
            runSongSearch(trimmed)
            return
        }
        songHits = []
        guard !trimmed.isEmpty, let module = state.primaryModule else {
            search.cancel()
            hits = []
            isSearching = false
            indexProgress = nil
            isTruncated = false
            searchedQuery = ""
            return
        }

        isSearching = true
        searchedQuery = trimmed
        searchedModuleID = module.identifier

        search.start(trimmed, in: module, options: .init(limit: 500)) { [weak self] value in
            self?.indexProgress = value < 1 ? value : nil
        } completion: { [weak self] outcome in
            guard let self else { return }
            self.hits = outcome.hits
            self.isTruncated = outcome.isTruncated
            self.isSearching = false
            self.indexProgress = nil
        }
    }

    /// Вкладку сменили при набранном запросе: результаты обязаны быть по
    /// новой вкладке — стихи на Библии, песни на Песнях.
    func rerunSearch(state: AppState) {
        let query = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        runSearch(query, state: state)
    }

    /// Поиск по открытому Песеннику: в названиях и в тексте частей.
    ///
    /// Слова запроса соединяются «и», как у стихов. Перебор трёх с половиной
    /// тысяч песен идёт в стороне от главного потока: набирают по букве, а
    /// окно в это время должно листаться.
    private func runSongSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        songSearchToken &+= 1
        let token = songSearchToken
        guard !trimmed.isEmpty, let songs = NativeSongsWorkspace.shared.model.book?.songs else {
            songHits = []
            isSearching = false
            isTruncated = false
            searchedQuery = ""
            return
        }
        isSearching = true
        searchedQuery = trimmed
        let words = TextSearch.Query(trimmed).words
        NativeTrace.say("пошук за піснями: «\(trimmed)», пісень \(songs.count), запуск №\(token)")
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [SongHit] = []
            var truncated = false
            outer: for song in songs {
                let number = song.index + 1
                let inTitle = TextSearch.highlights(of: words, in: song.title, wholeWords: false)
                if !inTitle.isEmpty {
                    found.append(SongHit(songIndex: song.index, partIndex: nil,
                                         title: "\(number). \(song.title)",
                                         text: song.title, highlights: inTitle))
                }
                for (position, part) in song.parts.enumerated() {
                    // Часть песни многострочная, а строка результата одна:
                    // переносы — в « / », как их и читают вслух.
                    let line = part.text
                        .replacingOccurrences(of: "\r\n", with: " / ")
                        .replacingOccurrences(of: "\n", with: " / ")
                    let ranges = TextSearch.highlights(of: words, in: line, wholeWords: false)
                    guard !ranges.isEmpty else { continue }
                    found.append(SongHit(songIndex: song.index, partIndex: position,
                                         title: "\(number). \(song.title) — \(part.kind)",
                                         text: line, highlights: ranges))
                    if found.count >= 500 { truncated = true; break outer }
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    NativeTrace.say("пошук за піснями: №\(token) знайшов \(found.count) за "
                        + String(format: "%.2f с", Date().timeIntervalSince(started))
                        + (token == self.songSearchToken ? "" : " — устарел, отброшен"))
                    guard token == self.songSearchToken else { return }
                    self.songHits = found
                    self.isTruncated = truncated
                    self.isSearching = false
                }
            }
        }
    }

    /// Строка результата выбрана: ставим курсор на этот стих. `live` — уходит
    /// ли он сразу в зал (двойной щелчок), как в списке стихов.
    func show(_ hit: TextSearch.Hit, state: AppState, live: Bool) {
        guard let position = state.books.firstIndex(where: { $0.index == hit.bookIndex }) else { return }
        state.selectedBookIndex = position
        state.selectedChapterNumber = hit.chapter
        state.selectedVerseNumbers = [hit.verse]
        state.scrollToCurrentVerse += 1
        if live { state.showCurrent() }
    }

    // MARK: - Поля быстрого выбора (6)

    /// «Быстрый выбор Книги вводом её названия (можно сокращать)».
    /// Выбор идёт из текущего содержимого раздела — то есть из книг,
    /// отобранных «Классом» (1).
    func applyBookQuery(_ text: String, state: AppState) {
        let books = state.visibleBooks
        guard let found = ShortBookNames.book(matching: text, in: books) else { return }
        guard found.index != state.selectedBookIndex else { return }
        state.selectedBookIndex = found.index
    }

    /// «Быстрый выбор Главы вводом её номера».
    func applyChapterQuery(_ text: String, state: AppState) {
        guard let number = Int(text.filter(\.isNumber)) else { return }
        guard state.chapters.contains(where: { $0.number == number }) else { return }
        state.selectedChapterNumber = number
    }

    /// «Быстрый выбор Стиха вводом его номера или части текста».
    func applyVerseQuery(_ text: String, state: AppState) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let chapter = state.currentChapter else { return }

        if let number = Int(trimmed), chapter.verse(number) != nil {
            state.selectVerse(number, extending: false)
            state.scrollToCurrentVerse += 1
            return
        }
        // Не число — значит, кусок текста. Ищем в пределах текущей главы:
        // по всему модулю ищет поле поиска (8), а это поле — про «здесь».
        guard let found = chapter.verses.first(where: {
            TextSearch.firstMatch(of: trimmed, in: $0.text, wholeWords: false) != nil
        }) else { return }
        state.selectVerse(found.number, extending: false)
        state.scrollToCurrentVerse += 1
    }

    /// Быстрый выбор места Писания (9) — формат из раздела 5.1.9.
    @discardableResult
    func applyAddress(_ text: String, state: AppState, then: (() -> Void)? = nil) -> Bool {
        guard let address = ScriptureAddress.parse(text, books: state.books) else { return false }
        // Позицію шукаємо за номером книги, а не беремо його навпростець:
        // так відкриття не залежить від того, як модуль нумерує книги.
        guard let position = state.books.firstIndex(where: { $0.index == address.book.index }) else {
            return false
        }
        // Глави книги можуть іще читатися з диска. Раніше номери глав і
        // віршів тут бралися з ПОПЕРЕДНЬОЇ книги, і адреса, набрана на
        // телефоні, відкривалася не там. Власник: функція «не понятная и не
        // рабочая». Тепер прохання чекає на глави; главу поза межами книги
        // підтягує до найближчої наявної саме відкриття.
        state.openScripture(bookPosition: position, chapter: address.chapter ?? 1,
                            pick: { available in address.verseNumbers(available: available) },
                            then: then)
        return true
    }

    /// Tab внутри полей быстрого выбора: по кругу, как в оригинале.
    func moveQuickFocus(by delta: Int) {
        let fields = QuickField.allCases
        guard let current = quickFocus, let position = fields.firstIndex(of: current) else {
            quickFocus = fields.first
            return
        }
        let next = (position + delta + fields.count) % fields.count
        quickFocus = fields[next]
    }

    // MARK: - Набор номера стиха над списком (5.1.4)

    func appendTypedVerse(_ digit: Character) {
        // Больше четырёх цифр не бывает ни в одной главе; лишнее — промах.
        if typedVerseNumber.count >= 4 { typedVerseNumber = "" }
        typedVerseNumber.append(digit)
        restartTypedVerseTimeout()
    }

    func commitTypedVerse(state: AppState) {
        defer { clearTypedVerse() }
        guard let number = Int(typedVerseNumber), state.currentChapter?.verse(number) != nil else { return }
        state.selectVerse(number, extending: false)
        state.scrollToCurrentVerse += 1
    }

    func clearTypedVerse() {
        typedVerseTimeout?.cancel()
        typedVerseTimeout = nil
        typedVerseNumber = ""
    }

    /// Набор «бегло»: если после цифры пауза, значит номер набирать передумали.
    private func restartTypedVerseTimeout() {
        typedVerseTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.typedVerseNumber = "" }
        typedVerseTimeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    // MARK: - План (10)

    func addToPlan(_ items: [PlanItem]) {
        guard !items.isEmpty else { return }
        plan.append(contentsOf: items)
        schedulePlanAutosave()
    }

    /// План проповіді з планшета. Власник: «план проповедника не добавляется
    /// в конец существующего или не заменяет его, а становится просто
    /// приоритетным на время проповеди». Тому план служіння відкладаємо
    /// цілим, а новий план проповіді заступає місце попереднього.
    func beginSermon(_ items: [PlanItem], title: String) {
        planAutosave?.cancel()
        if servicePlanAside == nil { servicePlanAside = plan }
        var sermon = ServicePlan(items: items)
        sermon.title = title
        planSelection = []
        plan = sermon
    }

    /// Проповідь закінчено — план служіння знову на місці.
    func endSermon() {
        guard let aside = servicePlanAside else { return }
        servicePlanAside = nil
        planSelection = []
        plan = aside
    }

    /// Текущее место Писания — пункт плана. Отрывок берётся ровно тот, что
    /// выделен в списке стихов (4).
    func planItem(forSelection state: AppState) -> PlanItem? {
        guard let book = state.currentBook, !state.selectedVerseNumbers.isEmpty else { return nil }
        // Начало цитаты берём у собранного предпросмотра: он про тот же
        // отрывок и уже готов, а лезть за текстом в модуль на нажатие нельзя.
        return PlanItem.scripture(moduleID: state.primaryModuleID,
                                  book: book,
                                  chapter: state.selectedChapterNumber,
                                  verses: state.selectedVerseNumbers,
                                  quote: state.slide.mainText)
    }

    /// Часть песни — пункт плана. Имя файла песенника берём у сборника:
    /// по нему план найдёт песню и после того, как папку с модулями перенесут.
    func planItem(forSong song: Song, part: SongPart, state: AppState) -> PlanItem? {
        guard let entry = state.songLibrary?.entry(state.songBookID) else { return nil }
        return PlanItem.songPart(bookFileName: entry.url.lastPathComponent, song: song, part: part)
    }

    /// Вся песня подряд — обычный способ поставить её в план целиком.
    /// Песня в план — одним пунктом, как у автора (5.3.2). Части листаются
    /// при показе; отдельная часть кладётся своим пунктом (5.3.3).
    func planItems(forSong song: Song, state: AppState) -> [PlanItem] {
        guard let entry = state.songLibrary?.entry(state.songBookID) else { return [] }
        return [PlanItem.song(bookFileName: entry.url.lastPathComponent, song: song)]
    }

    /// Кнопка «Добавить в план» (SBAddTextToPlan) и пункт меню «Добавить в
    /// План» (N12): берёт то, что выделено сейчас, — отрывок или часть песни.
    func addCurrentToPlan(state: AppState) {
        // В режиме «Текст» тот же пункт меню обязан класть в план набранное
        // объявление: другого «текущего» там нет (раздел 5.2.2).
        if state.mode == .text {
            TextModuleModel.shared.addToPlan()
            return
        }
        if state.mode == .songs {
            guard let song = state.selectedSong else { return }
            if let index = state.songPartIndex,
               let part = song.parts.first(where: { $0.index == index }),
               let item = planItem(forSong: song, part: part, state: state) {
                addToPlan([item])
            } else {
                addToPlan(planItems(forSong: song, state: state))
            }
            return
        }
        if let item = planItem(forSelection: state) { addToPlan([item]) }
    }

    func movePlan(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        plan.move(fromOffsets: offsets, toOffset: destination)
        schedulePlanAutosave()
    }

    /// Кнопки TBPlanUp / TBPlanDown — сдвиг выделенного пункта на один шаг.
    func movePlanSelection(by delta: Int) {
        let positions = selectedPlanPositions
        guard let position = positions.first, positions.count == 1 else { return }
        let destination = delta > 0 ? position + 2 : position - 1
        guard destination >= 0, destination <= plan.count else { return }
        plan.move(fromOffsets: IndexSet(integer: position), toOffset: destination)
        schedulePlanAutosave()
    }

    /// Кнопка TBPlanDel и клавиша Del — «Удалить строку».
    func deletePlanSelection() {
        // Если мышью ничего не выделяли, удаляем поданный пункт: после
        // загрузки плана выделения ещё нет, а клавиша уже должна работать.
        let positions = selectedPlanPositions.isEmpty
            ? [plan.currentIndex].compactMap { $0 }
            : selectedPlanPositions
        guard !positions.isEmpty else { return }
        plan.remove(atOffsets: IndexSet(positions))
        planSelection = []
        schedulePlanAutosave()
    }

    func deletePlan(atOffsets offsets: IndexSet) {
        plan.remove(atOffsets: offsets)
        planSelection = []
        schedulePlanAutosave()
    }

    /// Кнопка TBPlanNew — «Очистить план».
    func clearPlan() {
        plan.removeAll()
        planSelection = []
        schedulePlanAutosave()
    }

    var selectedPlanPositions: [Int] {
        plan.items.enumerated().filter { planSelection.contains($0.element.id) }.map(\.offset).sorted()
    }

    /// Фокус стоит на списке плана (F2). Пока он там, стрелки листают план, а
    /// не стихи: иначе «Установить фокус на План» ничего бы не давало —
    /// перелистывание перехватывает `ArrowNavigator` на всё окно.
    @Published var isPlanFocused = false

    /// Стрелки внутри плана: двигаем выделение, показ при этом не трогаем.
    func stepPlanSelection(by delta: Int) {
        guard !plan.isEmpty else { return }
        let current = selectedPlanPositions.first ?? plan.currentIndex ?? 0
        let next = min(max(current + delta, 0), plan.count - 1)
        planSelection = [plan.items[next].id]
    }

    /// Пункт, выделенный в списке; если выделения нет — поданный на экран.
    var focusedPlanItem: PlanItem? {
        if let position = selectedPlanPositions.first { return plan[position] }
        return plan.current
    }

    /// Подать пункт плана на экран: щелчок по нему делает то же, что двойной
    /// щелчок по стиху или по части песни.
    func activate(_ item: PlanItem, state: AppState) {
        plan.select(id: item.id)
        switch item.content {
        case .scripture(let reference):
            // Режим переключаем до показа: вид записи в «Истории» выбирается
            // по нему, и при открытой вкладке «Песни» место Писания ложилось
            // туда записью «песня» — с адресом стиха, но без песни.
            state.mode = .bible
            // «Выбор его из плана/истории» переключает перевод, а не открывает
            // отрывок в чужом — раздел 3.3. Поиск по новому переводу
            // перезапустит подписка на `primaryModuleID`.
            if !reference.moduleID.isEmpty, reference.moduleID != state.primaryModuleID,
               state.module(reference.moduleID) != nil {
                state.primaryModuleID = reference.moduleID
            }
            guard let position = state.books.firstIndex(where: { $0.index == reference.bookIndex })
                    ?? (state.books.indices.contains(reference.bookIndex) ? reference.bookIndex : nil) else { return }
            // Порожній список віршів у пункті плану — це «уся глава». Показ —
            // лише коли місце справді стало: глави можуть іще читатися з
            // диска, і показ одразу вивів би в зал попередній вірш.
            let wanted = reference.verses
            state.openScripture(bookPosition: position, chapter: reference.chapter,
                                pick: { available in wanted.isEmpty ? available : wanted.filter { available.contains($0) } },
                                then: { state.showCurrent() })

        case .song(let reference):
            guard let library = state.songLibrary,
                  let entry = library.books.first(where: {
                      $0.url.lastPathComponent.caseInsensitiveCompare(reference.bookFileName) == .orderedSame
                  }),
                  let book = library.book(entry.id),
                  let song = reference.song(in: book),
                  // Песня целиком начинается с первой части — как двойной
                  // щелчок по названию песни (5.3.2).
                  let part = reference.part(in: book) ?? song.parts.first else { return }
            state.mode = .songs
            state.songBookID = entry.id
            state.songIndex = song.index
            state.songPartIndex = part.index
            state.showSongPart(song, part)
            state.showCurrent()

        case .text(let document):
            // Пункт «Текст» везёт содержимое с собой — искать нечего.
            // Показ отдаём модулю «Текст»: он же откроет свою вкладку.
            TextModuleModel.shared.activate(document, state: state)

        case .file(let reference):
            openPlanFile(reference, state: state)
        }
    }

    /// Пункт «Файл» із плану проповіді: презентація, картинка чи відео.
    ///
    /// Розкладаємо тим самим розбором, що й файл, кинутий у вікно, і одразу
    /// показуємо: проповідник для того й поставив його в план. Уже відкритий
    /// файл удруге не відкриваємо — інакше кожне натискання на пункт
    /// дописувало б у список показу ще одну копію.
    private func openPlanFile(_ reference: PlanItem.FileReference, state: AppState) {
        let url = reference.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            NativeTrace.say("план: немає файла «\(reference.name)»")
            return
        }
        switch NativeWindowDrop.route([url], playable: { state.media.filters.accepts($0) }) {
        case .presentation, .pictures:
            let isPresentation = ShowModel.Kind.presentation.extensions.contains(url.pathExtension.lowercased())
            let workspace = isPresentation ? NativeShowWorkspace.presentation : NativeShowWorkspace.pictures
            let wanted = url.standardizedFileURL
            if workspace.model.decks.firstIndex(where: { $0.url.standardizedFileURL == wanted }) == nil {
                workspace.open([url])
            }
            state.mode = isPresentation ? .presentation : .pictures
            guard let deck = workspace.model.decks.firstIndex(where: { $0.url.standardizedFileURL == wanted }) else {
                return
            }
            workspace.selectDeck(deck)
            workspace.selectPage(workspace.model.decks[deck].range.lowerBound)
            workspace.showCurrentPage()
        case .media(let media):
            state.media.open(media)
            state.mode = .media
            state.media.play()
        case .nothing:
            NativeTrace.say("план: «\(reference.name)» не показ і не плеєр")
        }
    }

    // MARK: - Файлы плана

    /// Планы храним в своей папке поддержки, а не рядом с VisioBible: чужую
    /// установку программа не трогает на запись. Вид файла — тот же, что у
    /// оригинала (`<JournalFile>`), поэтому план ходит в обе стороны.
    static var plansFolder: URL {
        supportFolder.appendingPathComponent(ServicePlan.folderName, isDirectory: true)
    }

    /// «При запуске VisioBible отображает последний использовавшийся вариант
    /// плана» — у оригинала это `PlanDef.ini` рядом с программой.
    private static var autosaveURL: URL {
        supportFolder.appendingPathComponent(ServicePlan.defaultFileName)
    }
    private static let lastPlanKey = "plan.lastFile"

    /// Папка планов оригинала — оттуда открываются планы, сделанные в
    /// VisioBible. Только на чтение.
    private var originalPlansFolder: URL? {
        guard let dataRoot else { return nil }
        let folder = dataRoot.appendingPathComponent(ServicePlan.folderName, isDirectory: true)
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder),
              isFolder.boolValue else { return nil }
        return folder
    }

    /// Кнопка TBPlanOpen — «Загрузить план».
    func openPlan() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Тип файла не ограничиваем: планы оригинала лежат с расширением
        // `.ini`, наши прежние — `.json`, и оба вида должны открываться.
        panel.prompt = OurWords.t("Открыть")
        panel.message = OurWords.t("Файл плана служения")
        // Если у оригинала планы есть, открываем сразу его папку: свою
        // пользователь и так найдёт, а чужую — вряд ли.
        panel.directoryURL = originalPlansFolder ?? Self.plansFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        loadPlan(from: url)
    }

    func loadPlan(from url: URL) {
        do {
            let result = try ServicePlan.readAny(contentsOf: url)
            plan = result.plan
            planSelection = []
            planWarning = result.warning
            UserDefaults.standard.set(url.path, forKey: Self.lastPlanKey)
            schedulePlanAutosave()
        } catch {
            planWarning = "\(error)"
        }
    }

    /// Кнопка TBPlanSave — «Сохранить план».
    func savePlan() {
        // План, открытый из папки оригинала, поверх чужого файла не пишем:
        // спрашиваем имя и кладём к себе.
        if let url = plan.fileURL, isWritablePlanFile(url) {
            write(to: url)
            return
        }
        let panel = NSSavePanel()
        panel.prompt = OurWords.t("Сохранить")
        panel.message = OurWords.t("Куда сохранить план служения")
        panel.nameFieldStringValue = Self.planFileName(for: plan.title)
        try? FileManager.default.createDirectory(at: Self.plansFolder, withIntermediateDirectories: true)
        panel.directoryURL = Self.plansFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        write(to: url)
    }

    /// «План служения.ini» — расширение и папка как у оригинала.
    static func planFileName(for title: String) -> String {
        let base = ServicePlan.fileName(for: title)
        return (base as NSString).deletingPathExtension + "." + ServicePlan.journalFileExtension
    }

    private func isWritablePlanFile(_ url: URL) -> Bool {
        guard let originalPlansFolder else { return true }
        return !url.path.hasPrefix(originalPlansFolder.path)
    }

    private func write(to url: URL) {
        do {
            // Свой JSON оставляем только тем файлам, которые так и заведены:
            // всё новое пишется в формате оригинала.
            if url.pathExtension.lowercased() == ServicePlan.fileExtension {
                try plan.save(to: url)
            } else {
                try plan.saveAsJournal(to: url)
            }
            planWarning = nil
            UserDefaults.standard.set(url.path, forKey: Self.lastPlanKey)
        } catch {
            planWarning = "\(error)"
        }
    }

    /// «При запуске VisioBible отображает последний использовавшийся вариант
    /// плана» — раздел 5.1.10. Держим и сам файл, и снимок несохранённой
    /// правки: план, собранный перед служением и не сохранённый в файл,
    /// пропадать при перезапуске не должен.
    private func loadLastPlan(dataRoot: URL?) {
        // Свой снимок последнего плана.
        if let result = try? ServicePlan.readAny(contentsOf: Self.autosaveURL), !result.plan.isEmpty {
            plan = result.plan
            if let path = UserDefaults.standard.string(forKey: Self.lastPlanKey),
               let restored = try? ServicePlan.readAny(contentsOf: URL(fileURLWithPath: path)),
               restored.plan.items == plan.items {
                // Снимок совпал с файлом — значит план сохранён, и «Сохранить»
                // должно писать туда же, а не спрашивать имя заново.
                plan = restored.plan
            }
            return
        }
        if let path = UserDefaults.standard.string(forKey: Self.lastPlanKey),
           let result = try? ServicePlan.readAny(contentsOf: URL(fileURLWithPath: path)),
           !result.plan.isEmpty {
            plan = result.plan
            return
        }
        // Своего снимка ещё нет — берём последний план оригинала.
        guard let dataRoot,
              let result = try? ServicePlan.readAny(
                  contentsOf: dataRoot.appendingPathComponent(ServicePlan.defaultFileName)),
              !result.plan.isEmpty else { return }
        plan = result.plan
    }

    /// Снимок пишем с задержкой: перетаскивание пункта в списке шлёт правку на
    /// каждый шаг, а файл на диске от этого не должен переписываться десятки раз.
    private func schedulePlanAutosave() {
        // План проповіді — гість на час проповіді: записаний як «останній
        // план», він підмінив би план служіння при наступному запуску.
        guard servicePlanAside == nil else { return }
        planAutosave?.cancel()
        let snapshot = plan
        let work = DispatchWorkItem {
            try? snapshot.journal().write(to: Self.autosaveURL)
        }
        planAutosave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - История (11)

    /// Показанное в зале — в историю.
    ///
    /// Единственная точка входа для `AppState`: одна строка в `showCurrent()`
    /// и одна в `present(_:live:)`. Что именно показано, берём из готового
    /// `liveSlide` — так запись одинаково работает для Библии, «Текста» и
    /// песен, и не зависит от того, кто собрал слайд.
    func rememberLive(state: AppState) {
        let slide = state.liveSlide
        let quote = slide.mainText.trimmingCharacters(in: .whitespacesAndNewlines)
        // Пустой и чёрный слайд — не место Писания: гасить экран история
        // запоминать не должна.
        guard !slide.isBlank, !quote.isEmpty || !slide.reference.isEmpty else { return }

        // Из плеера в Историю писать нечего: там не место Писания, а файл.
        guard state.mode != .media, state.mode != .pictures,
              state.mode != .presentation, state.mode != .screen else { return }

        let record: HistoryRecord
        switch state.mode {
        case .bible, .media, .pictures, .presentation, .screen:
            guard let book = state.currentBook else { return }
            record = HistoryRecord(kind: .bible,
                                   reference: slide.reference,
                                   quote: quote,
                                   bookClass: Self.classNumber(state.bookClass),
                                   bookIndex: book.index,
                                   chapter: state.selectedChapterNumber,
                                   verses: state.selectedVerseNumbers.sorted(),
                                   moduleShortName: state.primaryModule?.info.shortName ?? "",
                                   moduleShortNameSecond: state.secondaryModuleIDs.first
                                       .flatMap { state.module($0)?.info.shortName } ?? "",
                                   shortNames: book.shortNames.joined(separator: ","),
                                   fullName: book.fullName)

        case .songs:
            // «При этом выбранная часть песни добавится в историю (11)» — 5.3.
            guard let song = state.selectedSong,
                  let entry = state.songLibrary?.entry(state.songBookID) else { return }
            record = HistoryRecord(kind: .song,
                                   reference: slide.reference,
                                   quote: quote,
                                   songBookFileName: entry.url.lastPathComponent,
                                   songIndex: song.index,
                                   partIndex: state.songPartIndex ?? 0)

        case .text:
            record = HistoryRecord(kind: .text, reference: slide.reference, quote: quote)
        }

        history.remember(record)
        scheduleHistoryAutosave()
    }

    /// «Пункты истории можно удалять» — контекстное меню и клавиша Del.
    func removeHistory(_ id: UUID) {
        history.remove(id: id)
        if historySelection == id { historySelection = nil }
        scheduleHistoryAutosave()
    }

    /// «Также можно очистить всю историю».
    func clearHistory() {
        history.removeAll()
        historySelection = nil
        scheduleHistoryAutosave()
    }

    /// «Щелчок мышью по адресу стиха в истории производит выбор этого места в
    /// связке Книга-Глава-Стих» — именно выбор, а не показ: в зал история
    /// сама ничего не отдаёт.
    /// `show` — вивести в зал, а не лише відкрити. Клацання по рядку Історії
    /// показує: «повернутися до показаного» (так на планшеті й у пульті).
    /// Доти рядок лише відкривав місце в передпоказі, і на стіні нічого не
    /// мінялося — власник: «на деякі пункти не реагує».
    func activate(_ record: HistoryRecord, state: AppState, show: Bool = false) {
        historySelection = record.id
        switch record.kind {
        case .bible:
            // «При переключении на другой Библейский модуль… или выбор его из
            // плана/истории окно поиска не скрывается, а происходит поиск по
            // этому модулю» (3.3): перевод меняем, а список результатов
            // перезапустит подписка на `primaryModuleID`.
            selectModule(shortName: record.moduleShortName, state: state)
            // Режим перемикаємо, як і в пункті плану: клацнули по місцю
            // Писання — значить його і показати. Без цього рядок історії,
            // натиснутий із вкладки «Пісні», не робив нічого видимого.
            state.mode = .bible
            guard let position = state.books.firstIndex(where: { $0.index == record.bookIndex })
                    ?? (state.books.indices.contains(record.bookIndex) ? record.bookIndex : nil) else {
                NativeTrace.say("історія: книги №\(record.bookIndex) немає в «\(state.primaryModule?.info.shortName ?? "?")»")
                return
            }
            state.openScripture(bookPosition: position, chapter: record.chapter, verses: record.verses,
                                then: show ? { state.showCurrent() } : nil)

        case .song:
            guard let library = state.songLibrary,
                  let entry = library.books.first(where: {
                      $0.url.lastPathComponent.caseInsensitiveCompare(record.songBookFileName) == .orderedSame
                  }) else {
                NativeTrace.say("історія: пісенника «\(record.songBookFileName)» немає")
                return
            }
            state.mode = .songs
            state.songBookID = entry.id
            state.songIndex = record.songIndex
            state.songPartIndex = record.partIndex
            if show, let book = library.book(entry.id), book.songs.indices.contains(record.songIndex) {
                let song = book.songs[record.songIndex]
                if let part = song.parts.first(where: { $0.index == record.partIndex }) ?? song.parts.first {
                    state.showSongPart(song, part)
                    state.showCurrent()
                }
            }

        case .text:
            // Запись везёт объявление с собой — возвращаем его в модуль,
            // как это делает пункт плана.
            TextModuleModel.shared.attach(state)
            state.mode = .text
            TextModuleModel.shared.receive(reference: record.reference, text: record.quote)
            if show { state.showCurrent() }
        }
    }

    /// Номер класса книг в нумерации оригинала — им подписано поле `Class`.
    private static func classNumber(_ bookClass: AppState.BookClass) -> Int {
        switch bookClass {
        case .all:       return 0
        case .old:       return 1
        case .new:       return 2
        case .apocrypha: return 3
        }
    }

    /// Перевод по короткому имени: в файле истории записано именно оно.
    private func selectModule(shortName: String, state: AppState) {
        let name = shortName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, state.primaryModule?.info.shortName != name else { return }
        guard let module = state.allModules.first(where: {
            $0.info.shortName.caseInsensitiveCompare(name) == .orderedSame
        }) else { return }
        state.primaryModuleID = module.identifier
    }

    // MARK: - Файл истории

    /// Свой файл в папке поддержки: у оригинала история лежит рядом с
    /// программой, но чужую установку на запись мы не трогаем — читаем её
    /// один раз, чтобы вчерашние адреса не пропали, и дальше ведём свой.
    static var historyURL: URL {
        supportFolder.appendingPathComponent(ServiceHistory.fileName)
    }

    static var supportFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Slovo", isDirectory: true)
    }

    private func loadHistory(dataRoot: URL?) {
        if FileManager.default.fileExists(atPath: Self.historyURL.path) {
            history = ServiceHistory.read(contentsOf: Self.historyURL)
            return
        }
        guard let dataRoot else { return }
        history = ServiceHistory.read(contentsOf: dataRoot.appendingPathComponent(ServiceHistory.fileName))
    }

    /// Запись с задержкой: показ слайда на служении идёт очередями, и файл на
    /// диске не должен переписываться на каждое нажатие Enter.
    private func scheduleHistoryAutosave() {
        historyAutosave?.cancel()
        let snapshot = history
        let work = DispatchWorkItem { try? snapshot.write(to: Self.historyURL) }
        historyAutosave = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1, execute: work)
    }

    // MARK: - Захист журналів від самоперевірки

    /// Самоперевірка показує вірші в зал, а кожен показ лягає в Історію і
    /// за секунду — у файл. 2026-09-10 два прогони так витіснили з Історії
    /// власника «Отче наш» і старий запис Бут. 12:5: ліміт у 60 записів
    /// заповнили пробні вірші. Самим перевіркам запис потрібен — вони
    /// дивляться, чи дійшов показ до Історії, — тому запис не забороняємо,
    /// а знімаємо Історію й План до прогону і повертаємо після: і в пам'яті,
    /// і на диску.
    func keepingJournals<T>(_ body: () -> T) -> T {
        let savedHistory = history
        let savedHistorySelection = historySelection
        let savedPlan = plan
        let savedPlanSelection = planSelection
        let historyFile = try? Data(contentsOf: Self.historyURL)
        let planFile = try? Data(contentsOf: Self.autosaveURL)
        defer {
            // Відкладені записи прогону скасовуємо, інакше за секунду вони
            // перепишуть повернений файл пробними віршами.
            historyAutosave?.cancel()
            planAutosave?.cancel()
            history = savedHistory
            historySelection = savedHistorySelection
            plan = savedPlan
            planSelection = savedPlanSelection
            Self.put(historyFile, at: Self.historyURL)
            Self.put(planFile, at: Self.autosaveURL)
        }
        return body()
    }

    /// Повернути файл як був; якщо до прогону його не було — прибрати.
    private static func put(_ data: Data?, at url: URL) {
        if let data {
            try? data.write(to: url, options: .atomic)
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Горячие клавиши F2, F3, Ctrl+F3, F4, F7, F8, F9, Tab

    /// Ставится один раз, из `.onAppear` рабочей области.
    ///
    /// Через меню эти клавиши не провести: пункт с голым F7 перехватывает
    /// клавишу у всего приложения, а нам нужно отдавать её дальше, когда
    /// курсор стоит в чужом поле. Тем же способом уже сделаны Esc и стрелки.
    func installHotkeys(state: AppState) {
        self.state = state
        addMonitor()

        // Папка данных программы: там у оригинала лежат History.ini,
        // PlanDef.ini и папка Plans. Читаем их оттуда, пишем — к себе.
        let root = state.modulesFolder.deletingLastPathComponent()
        dataRoot = root
        loadHistory(dataRoot: root)
        loadLastPlan(dataRoot: root)

        // «Теперь при переключении на другой Библейский модуль (песенник) или
        // выборе его из плана/истории окно поиска не скрывается, а происходит
        // поиск по этому модулю» — раздел 3.3 «Улучшено». Раньше список
        // результатов просто помечался устаревшим и вёл в старый перевод.
        moduleWatch = state.$primaryModuleID
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self, weak state] _ in
                guard let self, let state else { return }
                // Значение приходит до того, как `AppState` перечитает книги,
                // поэтому повторный поиск ставим на следующий проход цикла.
                DispatchQueue.main.async {
                    guard !self.searchedQuery.isEmpty else { return }
                    self.runSearch(self.searchedQuery, state: state)
                }
            }

        // Монитор должен стоять первым в очереди: AppKit зовёт локальные
        // мониторы в обратном порядке установки, а `ArrowNavigator` ставит
        // свой из `onAppear` главного окна и иначе перехватывает Enter
        // раньше нас — набранный над списком номер стиха пропадал бы.
        // Порядок `onAppear` у SwiftUI не оговорён, поэтому переставляем
        // себя в начало уже после того, как сложится всё окно.
        DispatchQueue.main.async { [weak self] in self?.moveMonitorToFront() }
    }

    private func addMonitor() {
        guard hotkeys == nil else { return }
        hotkeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.handle(event) ? nil : event }
        }
    }

    private func moveMonitorToFront() {
        guard let monitor = hotkeys else { return }
        NSEvent.removeMonitor(monitor)
        hotkeys = nil
        addMonitor()
    }

    /// Совпадает ли событие с клавишей функции из `hotkeys.ini`.
    ///
    /// Таблица имён общая (`HotkeyKeyNames`), а не своя. Своя знала только
    /// F1–F20, Esc, Tab, Space и Enter: назначь человек на «Поиск» букву — и
    /// клавиша молча перестала бы работать, хотя в окне настроек стояла бы.
    private func matches(_ action: String, _ event: NSEvent, _ modifiers: NSEvent.ModifierFlags) -> Bool {
        _ = modifiers
        guard let hotkey = hotkey(action) else { return false }
        return HotkeyKeyNames.matches(hotkey, event: event)
    }

    /// Имена клавиш, которые монитор событий умеет узнать.
    ///
    /// Заведён ради самопроверки: раскладку можно переназначить в «Параметрах»,
    /// и функция, которой досталась клавиша вне этого набора, молча перестанет
    /// работать. Лучше сказать об этом в «Диагностике», чем ждать, пока
    /// оператор нажмёт её на служении.
    static var recognizableKeyNames: Set<String> { HotkeyKeyNames.allNames }

    /// Кто разбирает нажатие для каждой функции вкладки «Горячие клавиши».
    ///
    /// Перечислены все девятнадцать. Пока список был из семи, про остальные
    /// двенадцать отчёт молчал — а половина из них клавишу из окна вовсе не
    /// читала: у семи она была зашита в пункт меню, у трёх обработчика не
    /// было совсем.
    static let hotkeyOwners: [String: String] = [
        "Plan": "монитор Стола", "Search": "монитор Стола",
        "FastSearchWindow": "монитор Стола", "FastInput": "монитор Стола",
        "FastInputBook": "монитор Стола", "FastInputChapter": "монитор Стола",
        "FastInputVers": "монитор Стола",
        "ShowSlide": "пункт меню", "HideSlide": "пункт меню",
        "ShowBlankSlide": "пункт меню", "ShowBlackScreen": "пункт меню",
        "ShowBackGrOnSlide": "пункт меню", "ScreenShot": "пункт меню",
        "MainWin": "пункт меню",
        "ShowMediaPlayer": "монитор плеера", "MediaPlayerPlayPause": "монитор плеера",
        "OpenCommonBG": "монитор окна", "OpenSlideBG": "монитор окна",
        "ReactionOnCtrlE": "монитор окна",
    ]

    /// Что назначено каждой функции, кто её разбирает и узнает ли такую
    /// клавишу разбор. Порядок — как в «Параметрах» на вкладке «Горячие
    /// клавиши».
    func hotkeyReport() -> [(action: String, title: String, key: String,
                             owner: String, isRecognized: Bool)] {
        HotkeyAction.all.map { item in
            let assigned = EffectiveHotkeys.hotkey(item.iniKey)
            let key = assigned.map(Self.describe) ?? ""
            let bare = assigned?.key ?? ""
            let owner = Self.hotkeyOwners[item.iniKey] ?? "никто"
            let title = item.fallback.hasSuffix(":")
                ? String(item.fallback.dropLast()) : item.fallback
            // Клавиша отдаётся отдельно от имени разбирающего: строку «F3»
            // сличают с раскладкой окна, и приписка сбила бы сличение.
            return (item.iniKey, title, key.isEmpty ? OurWords.t("не назначена") : key,
                    owner,
                    !bare.isEmpty && owner != "никто" && Self.recognizableKeyNames.contains(bare))
        }
    }

    /// «Ctrl+F3» — так сочетание записано и в `hotkeys.ini`, и в окне настроек.
    private static func describe(_ hotkey: Hotkey) -> String {
        var parts: [String] = []
        if hotkey.control { parts.append("Ctrl") }
        if hotkey.alt { parts.append("Alt") }
        if hotkey.shift { parts.append("Shift") }
        parts.append(hotkey.key)
        return parts.joined(separator: "+")
    }

    private func handle(_ event: NSEvent) -> Bool {
        guard let state else { return false }
        // Флаги «функциональная клавиша» и «цифровой блок» приходят вместе со
        // стрелками и клавишами F1–F12 сами по себе — это часть их кода.
        // Считать их нажатыми модификаторами нельзя: тогда ни одна проверка
        // «модификаторов нет» не сработает.
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.function, .numericPad])

        // «Показать/скрыть результаты поиска» — Ctrl+F3 в поставке.
        if matches("FastSearchWindow", event, modifiers) {
            toggleSearchResults()
            return true
        }
        if matches("Search", event, modifiers) {            // F3 — поле поиска (8)
            focusSearchField()
            return true
        }
        if matches("FastInput", event, modifiers) {         // F4 — место Писания (9)
            addressFocusRequest += 1
            return true
        }
        if matches("Plan", event, modifiers) {              // F2 — фокус на План (10)
            planFocusRequest += 1
            return true
        }
        // Три поля быстрого выбора (6). В песеннике у них свои поля — подписи
        // N31–N33 у автора так и читаются: «Книги/Песни», «Стиха/Текста», —
        // поэтому клавиши работают в обоих режимах, а поле себе забирает тот,
        // кто сейчас на экране.
        if matches("FastInputBook", event, modifiers) { quickFocus = .book; return true }
        if matches("FastInputChapter", event, modifiers) { quickFocus = .chapter; return true }
        if matches("FastInputVers", event, modifiers) { quickFocus = .verse; return true }

        guard modifiers.isEmpty else { return false }

        // Tab последовательно переключает поля быстрого выбора — раздел 5.1.6.
        if event.keyCode == 48, quickFocus != nil {
            moveQuickFocus(by: 1)
            return true
        }

        // Пока фокус на Плане (F2), стрелки листают его пункты, а Enter
        // подаёт выделенный на экран. Иначе стрелки перехватил бы
        // `ArrowNavigator` и листал бы стихи — а плана оператор бы не видел.
        if isPlanFocused, !plan.isEmpty {
            switch event.keyCode {
            case 126: stepPlanSelection(by: -1); return true     // ↑
            case 125: stepPlanSelection(by: 1);  return true     // ↓
            case 36, 76:                                          // Enter
                if let item = focusedPlanItem { activate(item, state: state) }
                return true
            // «Добавлена горячая клавиша „Del“ для удаления пункта плана» —
            // раздел 3.1. На маке отдельной клавиши Del нет на всех
            // раскладках, поэтому принимаем и Backspace: у оператора должно
            // работать на любом ноутбуке, а не только на полной клавиатуре.
            case 117, 51:
                deletePlanSelection()
                return true
            default:
                break
            }
        }

        // Набранный над списком номер стиха: Enter — перейти и показать,
        // Backspace — стереть цифру, Esc — передумали.
        if !typedVerseNumber.isEmpty {
            switch event.keyCode {
            case 36, 76:                                    // Enter
                commitTypedVerse(state: state)
                state.showCurrent()
                return true
            case 51:                                        // Backspace
                typedVerseNumber.removeLast()
                return true
            case 53:                                        // Esc
                clearTypedVerse()
                return true
            default:
                break
            }
        }

        // Цифра над списком стихов: «активировать список и набрать номер».
        // Если курсор стоит в поле ввода, цифра принадлежит полю.
        guard state.mode != .songs, quickFocus == nil, !Self.isEditingText,
              let character = event.charactersIgnoringModifiers?.first, character.isNumber else {
            return false
        }
        appendTypedVerse(character)
        return true
    }

    /// Тот же признак, что и у перелистывания стрелками: активен ли сейчас
    /// редактор текста. Иначе цифры перестанут набираться в полях ввода.
    private static var isEditingText: Bool {
        guard let window = NSApp.keyWindow else { return false }
        let responder = window.firstResponder
        if let editor = window.fieldEditor(false, for: nil), responder === editor { return true }
        if let text = responder as? NSTextView { return text.isEditable }
        return false
    }
}

// MARK: - Подсказки из файла перевода

extension AppState {
    /// Всплывающая подсказка элемента (`hint` в `Language/*.lng`).
    ///
    /// У кнопок плана подпись в файле перевода — это служебное имя
    /// («TBPlanDel»), а настоящий текст лежит именно в подсказке.
    func hint(_ key: String, form: String = "MainForm", default fallback: String) -> String {
        language?.hint(key, form: form) ?? OurWords.t(fallback)
    }
}
