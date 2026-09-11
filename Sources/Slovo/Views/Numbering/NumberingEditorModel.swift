import AppKit
import Foundation
import SlovoCore

/// Состояние окна «Редактор несоответствий нумерации переводов Библии» (N40).
///
/// У автора эта форма не переведена ни на один язык: он правит базу у себя и
/// раздаёт её готовой. Значит, окно это мастерская, и вся ответственность за
/// сохранность чужого файла на нас. Отсюда три правила, из которых собрано
/// всё остальное:
///
///  * файл автора не открывается вовсе — рядом с ним работает его программа,
///    а SQLite при открытии умеет положить рядом журнал. Делаем побайтную
///    копию в своей папке и читаем только её;
///  * правки живут значением в памяти и ложатся на диск лишь по «Ок» или по
///    кнопке «Сохранить сейчас», а «Отменить» возвращает снимок целиком;
///  * у каждой строки видно происхождение: «у автора», «изменено»,
///    «добавлено», «удалено». Без этого править чужую базу страшно.
@MainActor
final class NumberingEditorModel: ObservableObject {

    // MARK: - Виды строк

    enum Tab: String, CaseIterable, Identifiable {
        case modules, rules, check
        var id: String { rawValue }
    }

    /// Происхождение строки правил относительно базы автора.
    enum RowOrigin: String {
        case author, changed, added, removed

        var title: String {
            switch self {
            case .author:  return OurWords.t("у автора")
            case .changed: return OurWords.t("изменено")
            case .added:   return OurWords.t("добавлено")
            case .removed: return OurWords.t("удалено")
            }
        }
    }

    /// Откуда взялся стандарт перевода.
    enum StandardOrigin: String {
        case author, detected, manual, none

        var title: String {
            switch self {
            case .author:   return OurWords.t("у автора")
            case .detected: return OurWords.t("определено")
            case .manual:   return OurWords.t("вручную")
            case .none:     return OurWords.t("нет")
            }
        }
    }

    /// Итог сверки признаков с содержимым перевода.
    enum MatchState: Equatable {
        case unknown                       // ещё не считали
        case working                       // считается в фоне
        case impossible(String)            // признаки не снять — и почему
        case score(Int, Int, String)       // сошлось, всего, чем расходится
    }

    /// Строка списка переводов. Значением и `Equatable` — список из полусотни
    /// строк с выпадающими списками внутри пересобирать на каждое нажатие
    /// нельзя, как в `BookList` и `VerseList`.
    struct ModuleRow: Identifiable, Equatable {
        let id: String          // имя папки модуля
        let name: String        // полное название перевода
        let short: String       // сокращение, под которым он в базе автора
        var standard: String    // пусто — стандарт не назначен
        var origin: StandardOrigin
        var match: MatchState
    }

    /// Строка таблицы правил — уже в том виде, в каком её показывают.
    struct RuleRow: Identifiable, Equatable {
        let id: UUID
        let kindTitle: String
        let letter: String
        let bookTitle: String
        let source: String
        let target: String
        let origin: RowOrigin
        /// Ключи сортировки: книга, глава, стих.
        let book: Int
        let chapter: Int
        let verse: Int
    }

    /// Правка правила в отдельном листе. Отдельный тип, а не само правило:
    /// пока лист открыт, в таблице должна оставаться прежняя строка.
    struct RuleDraft: Identifiable {
        var id = UUID()
        /// Правило, которое правим. `nil` — добавление нового.
        var ruleID: UUID?
        var from: String
        var to: String
        var kind: NumberingRuleKind
        var book: Int
        var chapterBegin: Int
        var chapterEnd: Int?
        var verseBegin: Int?
        var verseEnd: Int?
        var chapterTo: Int?
        var chapterToEnd: Int?
        var verseTo: Int?
        var verseToEnd: Int?
    }

    /// Строка отчёта «Сверить книгу целиком».
    struct ReportLine: Identifiable, Equatable {
        let id = UUID()
        let chapter: Int
        let verse: Int
        let text: String
    }

    // MARK: - Что показываем

    @Published var tab: Tab = .modules

    @Published private(set) var base = NumberingBase()
    @Published private(set) var isLoaded = false
    @Published private(set) var isDirty = false
    /// Слово об оригинале: «файл автора» / «своя копия (правок: 12)» и
    /// сообщение о том, что автор свою базу обновил.
    @Published private(set) var sourceNote = "читаю базу…"
    @Published private(set) var refreshedNote = ""
    @Published var status = ""

    @Published private(set) var moduleRows: [ModuleRow] = []
    @Published var selectedModule: String?
    @Published var onlyUnassigned = false
    @Published private(set) var isDetecting = false
    /// Сходимость пересчитывается сама при открытии окна. Отдельная метка,
    /// а не общая с определением: пока идёт этот пересчёт, кнопки «Определить»
    /// должны оставаться живыми — иначе окно встречает человека запертым.
    @Published private(set) var isMatching = false

    @Published var pairFrom = "ru"
    @Published var pairTo = "en"
    @Published var selectedRule: UUID?
    @Published var onlyMine = false
    @Published var draft: RuleDraft?

    @Published var checkPrimary = ""
    @Published var checkSecondary = ""
    @Published var checkBook = 230
    @Published var checkChapter = 1
    @Published var checkVerse = 1
    @Published var addressInput = ""
    @Published private(set) var report: [ReportLine] = []
    @Published private(set) var reportSummary = ""
    @Published private(set) var isVerifying = false

    /// Счётчик разобранных в фоне книг: по нему вид перерисовывает стихи,
    /// когда книга наконец прочиталась с диска.
    @Published private(set) var cacheTick = 0

    /// Книги канона с названиями — из основного перевода.
    let books: [(number: Int, name: String)]
    /// Переводы для выпадающих списков вкладки «Проверка».
    let modules: [(id: String, name: String)]

    // MARK: - Внутреннее

    private let state: AppState
    /// База автора как она есть — эталон, с которым сверяется происхождение.
    private var author = NumberingBase()
    /// Снимок для «Отменить»: и правила, и удалённые строки, и назначения.
    private var snapshot = NumberingBase()
    private var snapshotRemoved: [NumberingRule] = []
    /// Строки автора, удалённые в этом сеансе. Показываем зачёркнутыми,
    /// пока окно открыто: молча исчезнувшая строка выглядит как потеря.
    private var removed: [NumberingRule] = []
    /// Откуда взялся стандарт перевода — по имени папки.
    private var standardOrigins: [String: StandardOrigin] = [:]
    private var matches: [String: MatchState] = [:]
    private var pendingChapters: Set<String> = []
    private var verifyToken = 0
    private var verifyFlag: VerifyFlag?

    /// Метка отмены фоновой сверки. Отдельным классом, потому что читать её
    /// приходится из фона на каждом стихе, а ходить за ответом на главный
    /// поток две с половиной тысячи раз — значит подвесить окно.
    final class VerifyFlag: @unchecked Sendable {
        var isCancelled = false
    }

    private let dataRoot: URL

    // MARK: - Открытие

    init(state: AppState) {
        self.state = state
        dataRoot = state.modulesFolder.deletingLastPathComponent()

        let source = state.primaryModule ?? state.allModules.first
        books = (source?.books ?? [])
            .compactMap { book in book.canonicalNumber.map { (number: $0, name: book.fullName) } }
            .reduce(into: [(number: Int, name: String)]()) { result, item in
                if !result.contains(where: { $0.number == item.number }) { result.append(item) }
            }
            .sorted { $0.number < $1.number }

        modules = state.allModules
            .filter { $0.info.isBible }
            .map { (id: $0.identifier, name: $0.displayName) }

        checkPrimary = state.primaryModuleID
        checkSecondary = state.secondaryModuleIDs.first ?? state.primaryModuleID
        checkBook = state.currentBook?.canonicalNumber ?? books.first?.number ?? 230
        checkChapter = state.selectedChapterNumber
        checkVerse = state.selectedVerseNumbers.first ?? 1

        load()
    }

    /// Окно открыли заново. База на диске могла измениться — и нашей же
    /// кнопкой «Вернуть всё как у автора», и обновлением VisioBible; читаем
    /// её ещё раз, а не показываем вчерашнее.
    func reopen() {
        guard !isDirty else { return }
        load()
    }

    /// Чтение базы. Данных мало, но диск может быть занят, а окно обязано
    /// открыться сразу — поэтому читаем в фоне, а раскладываем уже здесь.
    private func load() {
        let root = dataRoot
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let copied = Self.refreshAuthorCopy(dataRoot: root)
            let authorBase = (try? NumberingBase.load(from: copied.url)) ?? NumberingBase()
            let mine = FileManager.default.fileExists(atPath: NumberingBase.userURL.path)
                ? try? NumberingBase.load(from: NumberingBase.userURL)
                : nil
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.apply(author: authorBase, mine: mine, refreshed: copied.refreshed)
                }
            }
        }
    }

    private func apply(author authorBase: NumberingBase, mine: NumberingBase?, refreshed: Bool) {
        author = authorBase
        // Своя копия вытесняет эталон целиком: это уже готовая база, а не
        // список поправок к авторской.
        base = mine ?? authorBase
        if base.standards.isEmpty { base.standards = Self.defaultStandards }
        snapshot = base
        removed = authorBase.rules.filter { rule in
            !base.rules.contains { Self.key($0) == Self.key(rule) }
        }
        snapshotRemoved = removed
        isLoaded = true
        isDirty = false

        let codes = base.standards.map(\.code)
        if !codes.contains(pairFrom) { pairFrom = codes.first ?? "ru" }
        if !codes.contains(pairTo) { pairTo = codes.first { $0 != pairFrom } ?? pairFrom }

        if authorBase.isEmpty {
            sourceNote = OurWords.t("базы автора нет: искали %s",
                                    NumberingBase.originalURL(dataRoot: dataRoot).path)
        } else {
            sourceNote = mine == nil ? OurWords.t("файл автора")
                                     : OurWords.t("своя копия (правок: %s)", "\(ownRowCount)")
        }
        if refreshed, mine != nil {
            refreshedNote = OurWords.t("Файл программы обновился. Ваши правки сохранены, новые строки автора помечены")
        }
        rebuildModuleRows()
        // Сходимость по уже назначенным переводам считаем сразу: колонка
        // «Сходится» нужна как раз для того, чтобы увидеть чужое назначение
        // до того, как на него положились. Ничего не записывает.
        refreshMatches()
    }

    /// Побайтная копия базы автора в своей папке.
    ///
    /// Читаем всегда её, а не оригинал: рядом с оригиналом работает программа
    /// владельца, и лезть в её папку даже на чтение мы права не имеем.
    /// Копию обновляем, когда у оригинала изменились размер или дата, — иначе
    /// обновление VisioBible прошло бы мимо нас.
    nonisolated private static func refreshAuthorCopy(dataRoot: URL) -> (url: URL, refreshed: Bool) {
        let manager = FileManager.default
        let original = NumberingBase.originalURL(dataRoot: dataRoot)
        let copy = NumberingBase.userURL.deletingLastPathComponent()
            .appendingPathComponent("inconsistencies.author.sqlite3")
        guard let source = try? manager.attributesOfItem(atPath: original.path) else {
            return (copy, false)
        }
        let mirror = try? manager.attributesOfItem(atPath: copy.path)
        let sameSize = (mirror?[.size] as? NSNumber)?.intValue == (source[.size] as? NSNumber)?.intValue
        let sameDate = (mirror?[.modificationDate] as? Date) == (source[.modificationDate] as? Date)
        if mirror != nil, sameSize, sameDate { return (copy, false) }

        try? manager.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: copy)
        try? manager.copyItem(at: original, to: copy)
        return (copy, mirror != nil)
    }

    /// Стандарты, когда базы автора нет вовсе: без них окно открывается без
    /// единого стандарта и назначать нечего.
    static let defaultStandards: [NumberingStandard] = [
        NumberingStandard(code: "en", description: "West standart (Masoretic, for example Synodal translation)"),
        NumberingStandard(code: "pl", description: "Poland numbering (for example Biblia Warszawska)"),
        NumberingStandard(code: "ru", description: "East standart (Septuagint, for example King James Version)"),
        NumberingStandard(code: "ua", description: "Ukrainian numbering"),
    ]

    /// Наши подписи стандартов. Авторские в `t_info` показываем рядом мелким:
    /// у него в двух первых строках примеры переставлены местами — «King
    /// James» подписан септуагинтному счёту, — а узнавать строку базы надо.
    static func standardTitle(_ code: String) -> String {
        switch code {
        case "ru": return OurWords.t("Восточная (септуагинтская): синодальный перевод")
        case "en": return OurWords.t("Западная (масоретская): King James")
        case "pl": return OurWords.t("Польская: Biblia Warszawska")
        case "ua": return OurWords.t("Украинская")
        default:   return code
        }
    }

    func authorTitle(_ code: String) -> String {
        base.standards.first { $0.code == code }?.description ?? ""
    }

    var standardCodes: [String] { base.standards.map(\.code).sorted() }

    // MARK: - Ключ строки

    /// Ключ единственности — те же столбцы, что в `idx1` базы автора. По нему
    /// строка узнаётся между чтениями: `id` у правила своё на каждую загрузку.
    nonisolated static func key(_ rule: NumberingRule) -> String {
        [rule.from, rule.to, rule.kind.rawValue, "\(rule.book)", "\(rule.chapterBegin)",
         rule.verseBegin.map(String.init) ?? "", rule.verseEnd.map(String.init) ?? "",
         rule.chapterEnd.map(String.init) ?? ""].joined(separator: "|")
    }

    private static func sameValues(_ one: NumberingRule, _ two: NumberingRule) -> Bool {
        one.chapterTo == two.chapterTo && one.chapterToEnd == two.chapterToEnd
            && one.verseTo == two.verseTo && one.verseToEnd == two.verseToEnd
    }

    func origin(of rule: NumberingRule) -> RowOrigin {
        guard let original = author.rules.first(where: { Self.key($0) == Self.key(rule) }) else { return .added }
        return Self.sameValues(original, rule) ? .author : .changed
    }

    /// Сколько строк отличается от базы автора — это число стоит в полосе
    /// инструментов и решает, писать ли свою копию вообще.
    var ownRowCount: Int {
        var count = removed.count
        for rule in base.rules where origin(of: rule) != .author { count += 1 }
        for (name, code) in base.modules where author.modules[name] != code { count += 1 }
        for (name, code) in author.modules where base.modules[name] != code { count += 1 }
        return count
    }

    // MARK: - Переводы и стандарты

    private func rebuildModuleRows() {
        moduleRows = state.allModules
            .filter { $0.info.isBible }
            .map { module in
                let code = base.standardCode(forModuleNames: [module.info.shortName, module.identifier]) ?? ""
                return ModuleRow(id: module.identifier,
                                 name: module.displayName,
                                 short: module.info.shortName.isEmpty ? module.identifier : module.info.shortName,
                                 standard: code,
                                 origin: standardOrigins[module.identifier] ?? (code.isEmpty ? .none : .author),
                                 match: matches[module.identifier] ?? .unknown)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var visibleModuleRows: [ModuleRow] {
        onlyUnassigned ? moduleRows.filter { $0.standard.isEmpty } : moduleRows
    }

    var assignedCount: Int { moduleRows.filter { !$0.standard.isEmpty }.count }

    /// Строки таблицы автора, которым не отвечает ни один модуль.
    ///
    /// Строка с опиской в имени сюда больше не попадает: `ua_ogienka` при
    /// папке `UA_Ogienko` связывается с ней сама (`ModuleNameMatch`), и
    /// показывать её как потерянную значило бы звать чинить то, что работает.
    /// Саму строку базы мы при этом не трогаем — она чужая.
    var orphanNames: [(name: String, nearest: String?)] {
        let names = Array(Set(state.allModules.flatMap {
            [$0.identifier.lowercased(), $0.info.shortName.lowercased()]
        }))
        let known = Set(names)
        return base.modules.keys.sorted()
            .filter { !known.contains($0) && ModuleNameMatch.nearest($0, among: names) == nil }
            .map { name in (name: name, nearest: nearestModule(to: name)) }
    }

    private func nearestModule(to name: String) -> String? {
        var best: (String, Int)?
        for module in state.allModules {
            for candidate in [module.identifier, module.info.shortName] where !candidate.isEmpty {
                let distance = Self.distance(name.lowercased(), candidate.lowercased())
                if best == nil || distance < best!.1 { best = (candidate, distance) }
            }
        }
        guard let best, best.1 <= 3 else { return nil }
        return best.0
    }

    /// Расстояние редактирования — им подбираем ближайшее имя папки.
    /// Больше трёх правок значит «это другое имя», и предлагать его вредно.
    nonisolated private static func distance(_ one: String, _ two: String) -> Int {
        let a = Array(one), b = Array(two)
        if a.isEmpty { return b.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1]
                    ? previous[j - 1]
                    : min(previous[j - 1], previous[j], current[j - 1]) + 1
            }
            previous = current
        }
        return previous[b.count]
    }

    func setStandard(_ code: String, forModule id: String) {
        assign(code, module: id, origin: code.isEmpty ? .none : .manual)
    }

    private func assign(_ code: String, module id: String, origin: StandardOrigin) {
        guard let module = state.allModules.first(where: { $0.identifier == id }) else { return }
        // Прежние ключи снимаем оба: у автора перевод записан сокращением, а
        // мы пишем именем папки, и две строки на один модуль спорили бы.
        base.modules.removeValue(forKey: module.info.shortName.lowercased())
        base.modules.removeValue(forKey: id.lowercased())
        if !code.isEmpty { base.modules[id.lowercased()] = code }
        standardOrigins[id] = origin
        isDirty = true
        rebuildModuleRows()
        // Назначили руками — тут же считаем, сходится ли назначенное с самим
        // переводом. Иначе колонка «Сходится» молчит ровно там, где человек
        // только что принял решение и ждёт подтверждения.
        if !code.isEmpty, origin == .manual { refreshMatch(forModule: id, code: code) }
    }

    /// Сходимость одного перевода. Читает две книги — значит, в фоне.
    private func refreshMatch(forModule id: String, code: String) {
        matches[id] = .working
        rebuildModuleRows()
        let library = state.library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let module = library?.module(withIdentifier: id) else { return }
            let answer = Self.match(NumberingGuess.evidence(for: module), code: code)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.matches[id] = answer
                    self.rebuildModuleRows()
                }
            }
        }
    }

    /// Вернуть переводу то назначение, что стояло у автора.
    func restoreAuthorStandard(forModule id: String) {
        guard let module = state.allModules.first(where: { $0.identifier == id }) else { return }
        base.modules.removeValue(forKey: module.info.shortName.lowercased())
        base.modules.removeValue(forKey: id.lowercased())
        for (name, code) in author.modules
        where name == module.info.shortName.lowercased() || name == id.lowercased() {
            base.modules[name] = code
        }
        // Пишем полное имя случая: голое `.none` Swift понял бы как «стереть
        // запись», и происхождение стандарта потерялось бы вместе с ней.
        standardOrigins[id] = base.standardCode(forModuleNames: [module.info.shortName, id]) == nil
            ? StandardOrigin.none : StandardOrigin.author
        isDirty = true
        rebuildModuleRows()
    }

    /// Перенести строку авторской таблицы на настоящее имя папки.
    func renameAuthorRow(_ name: String, to newName: String) {
        guard let code = base.modules[name] else { return }
        base.modules.removeValue(forKey: name)
        base.modules[newName.lowercased()] = code
        isDirty = true
        rebuildModuleRows()
    }

    // MARK: - Определение стандарта по содержимому

    /// Признаки, которыми стандарты различаются, и их ожидаемые значения.
    ///
    /// Числа сняты с модулей владельца: 9-й псалом восточного счёта вобрал в
    /// себя десятый, у надписания псалма свой номер везде, кроме масоретского
    /// счёта, 147-й псалом у Септуагинты — вторая половина еврейского, а
    /// длинный Еккл 8 во всей библиотеке только у Biblia Warszawska.
    struct Signs: Equatable {
        var psalm9Joined: Bool?
        var psalm3Counted: Bool?
        var psalm147Short: Bool?
        var ecclesiastes8Long: Bool?

        static func expected(_ code: String) -> Signs {
            switch code {
            case "ru": return Signs(psalm9Joined: true, psalm3Counted: true,
                                    psalm147Short: true, ecclesiastes8Long: false)
            case "en": return Signs(psalm9Joined: false, psalm3Counted: false,
                                    psalm147Short: false, ecclesiastes8Long: false)
            case "pl": return Signs(psalm9Joined: false, psalm3Counted: true,
                                    psalm147Short: false, ecclesiastes8Long: true)
            default:   return Signs(psalm9Joined: false, psalm3Counted: true,
                                    psalm147Short: false, ecclesiastes8Long: false)
            }
        }
    }

    nonisolated private static func signs(_ evidence: NumberingGuess.Evidence) -> Signs {
        Signs(psalm9Joined: evidence.psalm9.map { $0 >= 30 },
              psalm3Counted: evidence.psalm3.map { $0 >= 9 },
              psalm147Short: evidence.psalm147.map { $0 <= 12 },
              ecclesiastes8Long: evidence.ecclesiastes8.map { $0 >= 18 })
    }

    /// Насколько назначенный стандарт сходится с содержимым перевода.
    nonisolated private static func match(_ evidence: NumberingGuess.Evidence,
                                          code: String) -> MatchState {
        let seen = signs(evidence)
        let want = Signs.expected(code)
        var total = 0, hits = 0
        var missed: [String] = []
        func compare(_ left: Bool?, _ right: Bool?, _ name: String) {
            guard let left, let right else { return }
            total += 1
            if left == right { hits += 1 } else { missed.append(name) }
        }
        compare(seen.psalm9Joined, want.psalm9Joined, "Пс 9")
        compare(seen.psalm3Counted, want.psalm3Counted, "Пс 3")
        compare(seen.psalm147Short, want.psalm147Short, "Пс 147")
        compare(seen.ecclesiastes8Long, want.ecclesiastes8Long, "Еккл 8")
        guard total > 0 else { return .impossible(OurWords.t("признаки не снять (нет Псалтири)")) }
        return .score(hits, total, missed.joined(separator: ", "))
    }

    /// Определить стандарт у всех переводов сразу.
    ///
    /// Читает Псалтирь и Екклесиаста у полусотни модулей — работа на секунды,
    /// поэтому только в фоне и порциями: строки таблицы получают ответ по
    /// мере готовности, а окно всё это время отзывается.
    ///
    /// Строки «у автора» и «вручную» не трогаем: решение человека молча
    /// пропадать не должно.
    func detectAll() {
        let targets = moduleRows
            .filter { $0.standard.isEmpty || $0.origin == .detected }
            .map(\.id)
        detect(targets, force: false)
    }

    /// То же для одной строки — и её трогаем всегда: человек нажал именно на неё.
    func detectSelected() {
        guard let id = selectedModule else { return }
        detect([id], force: true)
    }

    private func detect(_ identifiers: [String], force: Bool) {
        guard !identifiers.isEmpty, !isDetecting else { return }
        isDetecting = true
        status = OurWords.t("считаю признаки у %s переводов…", "\(identifiers.count)")
        for id in identifiers { matches[id] = .working }
        rebuildModuleRows()

        let library = state.library
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(String, String, String, MatchState)] = []
            for id in identifiers {
                guard let module = library?.module(withIdentifier: id) else { continue }
                let evidence = NumberingGuess.evidence(for: module)
                let guess = NumberingGuess.decide(evidence)
                let code = guess?.standardID ?? ""
                let state = code.isEmpty
                    ? MatchState.impossible(OurWords.t("ни один стандарт не сошёлся"))
                    : Self.match(evidence, code: code)
                found.append((id, code, guess?.reason ?? "", state))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.finishDetection(found, force: force)
                }
            }
        }
    }

    private func finishDetection(_ found: [(String, String, String, MatchState)], force: Bool) {
        var assigned = 0
        for (id, code, reason, match) in found {
            matches[id] = match
            guard !code.isEmpty else { continue }
            let current = moduleRows.first { $0.id == id }
            let mayAssign = force || (current?.standard.isEmpty ?? true) || current?.origin == .detected
            if mayAssign {
                assign(code, module: id, origin: .detected)
                assigned += 1
            }
            if found.count == 1 { status = reason }
        }
        isDetecting = false
        if found.count > 1 { status = OurWords.t("стандарт определён у %s переводов из %s",
                                                 "\(assigned)", "\(found.count)") }
        rebuildModuleRows()
    }

    /// Пересчитать сходимость по уже назначенному стандарту — без назначения.
    func refreshMatches() {
        let pairs = moduleRows.filter { !$0.standard.isEmpty }.map { ($0.id, $0.standard) }
        guard !pairs.isEmpty, !isMatching else { return }
        isMatching = true
        let library = state.library
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var found: [(String, MatchState)] = []
            for (id, code) in pairs {
                guard let module = library?.module(withIdentifier: id) else { continue }
                found.append((id, Self.match(NumberingGuess.evidence(for: module), code: code)))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Строки, которые в этот миг считает «Определить»,
                    // не трогаем: его ответ свежее нашего.
                    for (id, match) in found where self.matches[id] != .working {
                        self.matches[id] = match
                    }
                    self.isMatching = false
                    self.rebuildModuleRows()
                }
            }
        }
    }

    // MARK: - Правила выбранной пары

    var pairRules: [NumberingRule] {
        base.rules.filter { $0.from == pairFrom && $0.to == pairTo }
    }

    var ruleRows: [RuleRow] {
        var rows = pairRules.map { row(for: $0, origin: origin(of: $0)) }
        rows += removed
            .filter { $0.from == pairFrom && $0.to == pairTo }
            .map { row(for: $0, origin: .removed) }
        if onlyMine { rows = rows.filter { $0.origin != .author } }
        return rows.sorted {
            ($0.book, $0.chapter, $0.verse) < ($1.book, $1.chapter, $1.verse)
        }
    }

    private func row(for rule: NumberingRule, origin: RowOrigin) -> RuleRow {
        RuleRow(id: rule.id,
                kindTitle: Self.kindTitle(rule.kind),
                letter: rule.kind.rawValue,
                bookTitle: "\(bookName(rule.book)) (\(rule.book))",
                source: Self.sourceText(rule),
                target: Self.targetText(rule),
                origin: origin,
                book: rule.book,
                chapter: rule.chapterBegin,
                verse: rule.verseBegin ?? 0)
    }

    /// Адрес-источник строкой.
    ///
    /// Пустой «стих по» значит разное у разных видов, и написать одинаково
    /// нельзя: у точного соответствия это ровно один стих, а у переноса и
    /// сдвига — «и дальше до конца главы». Отсюда многоточие у одних и его
    /// отсутствие у других.
    static func sourceText(_ rule: NumberingRule) -> String {
        let chapters = (rule.chapterEnd ?? rule.chapterBegin) > rule.chapterBegin
            ? "\(rule.chapterBegin)–\(rule.chapterEnd!)"
            : "\(rule.chapterBegin)"
        guard rule.kind != .offsetChapter, let begin = rule.verseBegin else { return chapters }
        if let end = rule.verseEnd { return end > begin ? "\(chapters):\(begin)–\(end)" : "\(chapters):\(begin)" }
        return rule.kind == .displaced ? "\(chapters):\(begin)" : "\(chapters):\(begin)…"
    }

    /// Адрес-назначение строкой: у сдвигов число со знаком, у переносов адрес.
    static func targetText(_ rule: NumberingRule) -> String {
        func signed(_ value: Int) -> String { value > 0 ? "+\(value)" : "\(value)" }
        switch rule.kind {
        case .offsetChapter:
            return signed(rule.chapterTo ?? 0) + " к главе"
        case .offsetVerse:
            let shift = signed(rule.verseTo ?? 0) + " к стиху"
            return rule.chapterTo.map { OurWords.t("глава %s, ", "\($0)") + shift } ?? shift
        case .part:
            let chapter = rule.chapterTo.map(String.init) ?? "та же глава"
            return rule.verseTo.map { OurWords.t("%s:%s и далее", "\(chapter)", "\($0)") } ?? chapter
        case .displaced:
            let chapter = rule.chapterTo.map(String.init) ?? "\(rule.chapterBegin)"
            var text = rule.verseTo.map { "\(chapter):\($0)" } ?? chapter
            if let lastChapter = rule.chapterToEnd, lastChapter != rule.chapterTo {
                text += "–\(lastChapter):\(rule.verseToEnd ?? 1)"
            } else if let lastVerse = rule.verseToEnd, lastVerse != rule.verseTo {
                text += "–\(lastVerse)"
            }
            return text
        }
    }

    /// Тип правила словом. Букву показываем рядом мелким: человеку надо и
    /// понимать, что он правит, и узнавать строку в базе автора.
    static func kindTitle(_ kind: NumberingRuleKind) -> String {
        switch kind {
        case .offsetChapter: return OurWords.t("сдвиг главы")
        case .offsetVerse:   return OurWords.t("сдвиг стиха")
        case .part:          return OurWords.t("перенос отрывка")
        case .displaced:     return OurWords.t("точное соответствие")
        }
    }

    func bookName(_ number: Int) -> String {
        books.first { $0.number == number }?.name ?? OurWords.t("книга %s", "\(number)")
    }

    func rule(_ id: UUID?) -> NumberingRule? {
        guard let id else { return nil }
        return base.rules.first { $0.id == id } ?? removed.first { $0.id == id }
    }

    var pairNote: String {
        if pairFrom == pairTo { return OurWords.t("один и тот же стандарт") }
        let count = pairRules.count
        if count > 0 { return OurWords.t("правил %s", "\(count)") }
        let path = route(from: pairFrom, to: pairTo)
        guard path.count > 2 else { return OurWords.t("правил нет") }
        return OurWords.t("прямых правил нет, считается через %s стандарт",
                          Self.standardShort(path[1]))
    }

    static func standardShort(_ code: String) -> String {
        switch code {
        case "ru": return OurWords.t("русский")
        case "en": return OurWords.t("масоретский")
        case "pl": return OurWords.t("польский")
        case "ua": return OurWords.t("украинский")
        default:   return code
        }
    }

    // MARK: - Правка правил

    func newDraft() -> RuleDraft {
        RuleDraft(ruleID: nil, from: pairFrom, to: pairTo, kind: .offsetVerse,
                  book: state.currentBook?.canonicalNumber ?? books.first?.number ?? 230,
                  chapterBegin: 1, verseBegin: 1, verseTo: 0)
    }

    func draft(from rule: NumberingRule) -> RuleDraft {
        RuleDraft(ruleID: rule.id, from: rule.from, to: rule.to, kind: rule.kind, book: rule.book,
                  chapterBegin: rule.chapterBegin, chapterEnd: rule.chapterEnd,
                  verseBegin: rule.verseBegin, verseEnd: rule.verseEnd,
                  chapterTo: rule.chapterTo, chapterToEnd: rule.chapterToEnd,
                  verseTo: rule.verseTo, verseToEnd: rule.verseToEnd)
    }

    /// Зеркальное правило обратной пары: «откуда» и «куда» меняются местами.
    ///
    /// Открываем его листом правки, а не записываем молча: обращение переноса
    /// и точного соответствия не всегда однозначно, и последнее слово должно
    /// остаться за человеком.
    func mirrorDraft(of rule: NumberingRule) -> RuleDraft {
        switch rule.kind {
        case .offsetChapter:
            let shift = rule.chapterTo ?? 0
            return RuleDraft(ruleID: nil, from: rule.to, to: rule.from, kind: .offsetChapter,
                             book: rule.book,
                             chapterBegin: rule.chapterBegin + shift,
                             chapterEnd: rule.chapterEnd.map { $0 + shift },
                             chapterTo: -shift)
        case .offsetVerse:
            let shift = rule.verseTo ?? 0
            return RuleDraft(ruleID: nil, from: rule.to, to: rule.from, kind: .offsetVerse,
                             book: rule.book,
                             chapterBegin: rule.chapterTo ?? rule.chapterBegin,
                             chapterEnd: rule.chapterEnd,
                             verseBegin: rule.verseBegin.map { $0 + shift },
                             verseEnd: rule.verseEnd.map { $0 + shift },
                             verseTo: -shift)
        case .part, .displaced:
            return RuleDraft(ruleID: nil, from: rule.to, to: rule.from, kind: rule.kind,
                             book: rule.book,
                             chapterBegin: rule.chapterTo ?? rule.chapterBegin,
                             chapterEnd: rule.chapterToEnd,
                             verseBegin: rule.verseTo,
                             verseEnd: rule.verseToEnd,
                             chapterTo: rule.chapterBegin,
                             chapterToEnd: rule.chapterEnd,
                             verseTo: rule.verseBegin,
                             verseToEnd: rule.verseEnd)
        }
    }

    /// Записать лист правки. Ответ — слово об ошибке; `nil` значит «принято».
    func commit(_ draft: RuleDraft) -> String? {
        if let end = draft.chapterEnd, end < draft.chapterBegin { return OurWords.t("Начальная глава больше конечной") }
        if let begin = draft.verseBegin, let end = draft.verseEnd, end < begin {
            return OurWords.t("Начальный стих больше конечного")
        }
        if draft.kind == .displaced, draft.verseBegin == nil {
            return OurWords.t("У точного соответствия должен быть задан стих")
        }
        var rule = NumberingRule(from: draft.from, to: draft.to, kind: draft.kind, book: draft.book,
                                 chapterBegin: draft.chapterBegin, chapterEnd: draft.chapterEnd,
                                 verseBegin: draft.verseBegin, verseEnd: draft.verseEnd,
                                 chapterTo: draft.chapterTo, chapterToEnd: draft.chapterToEnd,
                                 verseTo: draft.verseTo, verseToEnd: draft.verseToEnd)
        if let id = draft.ruleID { rule.id = id }

        // Единственность — та же, что у указателя `idx1` в базе. Дать SQLite
        // упасть на записи нельзя: человек узнает о беде через полчаса.
        let twin = base.rules.first { Self.key($0) == Self.key(rule) && $0.id != rule.id }
        if twin != nil { return OurWords.t("Такое правило в этой паре уже есть") }

        if let index = base.rules.firstIndex(where: { $0.id == rule.id }) {
            base.rules[index] = rule
        } else {
            base.rules.append(rule)
        }
        removed.removeAll { Self.key($0) == Self.key(rule) }
        selectedRule = rule.id
        isDirty = true
        return nil
    }

    func removeRule(_ id: UUID) {
        guard let index = base.rules.firstIndex(where: { $0.id == id }) else { return }
        let rule = base.rules.remove(at: index)
        // Строку автора помним зачёркнутой: молча исчезнувшая строка выглядит
        // как потеря, а вернуть её надо уметь одной кнопкой.
        if author.rules.contains(where: { Self.key($0) == Self.key(rule) }) { removed.append(rule) }
        selectedRule = nil
        isDirty = true
    }

    /// Вернуть строке авторский вид; для добавленной нами строки — убрать её.
    func restoreAuthorRule(_ id: UUID) {
        guard let rule = rule(id) else { return }
        let key = Self.key(rule)
        base.rules.removeAll { Self.key($0) == key }
        removed.removeAll { Self.key($0) == key }
        if let original = author.rules.first(where: { Self.key($0) == key }) {
            var restored = original
            restored.id = UUID()
            base.rules.append(restored)
            selectedRule = restored.id
        } else {
            selectedRule = nil
        }
        isDirty = true
    }

    // MARK: - Перевод адреса по правилам, которые сейчас в окне

    /// Дорога между стандартами: прямая пара, а если её нет — цепочка.
    ///
    /// Пар в базе шесть и они несимметричны, а стандартов четыре: pl — en —
    /// ru — ua. Значит ua→en считается через русский, и человеку об этом
    /// говорим прямо: на переносах цепочка может потерять точность.
    nonisolated static func route(rules: [NumberingRule], from: String, to: String) -> [String] {
        guard from != to else { return [from] }
        var neighbours: [String: Set<String>] = [:]
        for rule in rules { neighbours[rule.from, default: []].insert(rule.to) }
        var queue = [[from]]
        var visited: Set<String> = [from]
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard let last = path.last else { continue }
            if last == to { return path }
            for next in (neighbours[last] ?? []).sorted() where !visited.contains(next) {
                visited.insert(next)
                queue.append(path + [next])
            }
        }
        return [from]
    }

    func route(from: String, to: String) -> [String] {
        Self.route(rules: base.rules, from: from, to: to)
    }

    /// Пустая клетка базы значит разное у разных видов: у `D` пустой конец
    /// стихов — это «ровно один стих», у `P` и `OV` — «до конца главы».
    nonisolated private static func covers(_ rule: NumberingRule, chapter: Int, verse: Int) -> Bool {
        guard chapter >= rule.chapterBegin, chapter <= rule.chapterLast else { return false }
        switch rule.kind {
        case .offsetChapter:
            return true
        case .displaced:
            guard let low = rule.verseBegin else { return false }
            return verse >= low && verse <= (rule.verseEnd ?? low)
        case .part, .offsetVerse:
            let low = rule.verseBegin ?? 1
            guard verse >= low else { return false }
            if let high = rule.verseEnd { return verse <= high }
            return true
        }
    }

    /// Перевод набора стихов целиком, включая цепочку.
    ///
    /// Сам адрес считает ОБЩИЙ движок (`VerseNumbering`) — тот же, что собирает
    /// слайд. Своей арифметики здесь больше нет: пока она была, окно и проектор
    /// расходились на 947 адресах из 856 170, и всякий раз прав оказывался не
    /// тот, кого показывало окно.
    ///
    /// Здесь остаётся одно: НАЗВАТЬ правила, на которых адрес сошёлся, — это
    /// подпись под ответом, а не сам ответ. Правило ищется тем же перебором,
    /// но ничего не считает.
    nonisolated static func translate(rules: [NumberingRule], book: Int, chapter: Int, verses: [Int],
                                      from: String, to: String) -> (spans: [VerseSpan], rules: [NumberingRule], path: [String]) {
        guard from != to, !verses.isEmpty else {
            return ([VerseSpan(chapter: chapter, verses: verses)], [], [from])
        }
        let path = route(rules: rules, from: from, to: to)
        guard path.count > 1 else { return ([VerseSpan(chapter: chapter, verses: verses)], [], path) }

        let engine = VerseNumbering.over(rules: rules)
        let spans = engine.translate(book: book, chapter: chapter, verses: verses,
                                     from: VerseNumberingStandard(id: from, title: from),
                                     to: VerseNumberingStandard(id: to, title: to))

        // Какие строки сработали. Идём по той же цепочке и тем же адресам,
        // что и движок, но берём у него, а не считаем заново.
        var fired: [NumberingRule] = []
        var current = verses.map { (chapter, $0) }
        for index in 0..<(path.count - 1) {
            let from = path[index], to = path[index + 1]
            var next: [(Int, Int)] = []
            for address in current {
                for rule in firedRules(rules: rules, book: book,
                                       chapter: address.0, verse: address.1, from: from, to: to)
                where !fired.contains(where: { $0.id == rule.id }) {
                    fired.append(rule)
                }
                let moved = engine.translate(book: book, chapter: address.0, verse: address.1,
                                             from: VerseNumberingStandard(id: from, title: from),
                                             to: VerseNumberingStandard(id: to, title: to))
                next.append(contentsOf: moved.map { ($0.chapter, $0.verse) })
            }
            var seen = Set<Int>()
            current = next.filter { seen.insert($0.0 &* 100_000 &+ $0.1).inserted }
        }
        return (spans, fired, path)
    }

    /// Строки, накрывающие этот адрес, — в том же порядке важности, в каком их
    /// разбирает движок: сперва `D`, потом `P`, иначе сложение `OC` и `OV`.
    /// Числа тут не считаются вовсе, только называются правила.
    nonisolated private static func firedRules(rules all: [NumberingRule], book: Int,
                                               chapter: Int, verse: Int,
                                               from: String, to: String) -> [NumberingRule] {
        let rules = all.filter { $0.from == from && $0.to == to && $0.book == book }
        if let rule = rules.first(where: { $0.kind == .displaced && covers($0, chapter: chapter, verse: verse) }) {
            return [rule]
        }
        if let rule = rules.first(where: { $0.kind == .part && covers($0, chapter: chapter, verse: verse) }) {
            return [rule]
        }
        var fired: [NumberingRule] = []
        if let rule = rules.first(where: { $0.kind == .offsetChapter && covers($0, chapter: chapter, verse: verse) }) {
            fired.append(rule)
        }
        if let rule = rules.first(where: { $0.kind == .offsetVerse && covers($0, chapter: chapter, verse: verse) }) {
            fired.append(rule)
        }
        return fired
    }

    /// То же со словами о том, каким правилом получен адрес: их показывает
    /// полоса объяснения под двумя переводами.
    func translate(book: Int, chapter: Int, verses: [Int],
                   from: String, to: String) -> (spans: [VerseSpan], reason: String, rule: NumberingRule?) {
        guard from != to else {
            return ([VerseSpan(chapter: chapter, verses: verses)], OurWords.t("стандарты совпадают, адрес не меняется"), nil)
        }
        let answer = Self.translate(rules: base.rules, book: book, chapter: chapter, verses: verses,
                                    from: from, to: to)
        guard answer.path.count > 1 else {
            return (answer.spans, OurWords.t("дороги между стандартами нет, адрес не меняется"), nil)
        }
        var reason: String
        if answer.rules.isEmpty {
            reason = OurWords.t("правил для этого места нет, адрес не меняется")
        } else {
            reason = (answer.rules.count > 1 ? "правила: " : "правило: ")
                + answer.rules.map { rule in
                    "\(Self.kindTitle(rule.kind)) \(Self.sourceText(rule)) → \(Self.targetText(rule))"
                        + " (\(origin(of: rule).title))"
                }.joined(separator: "; ")
        }
        if answer.path.count > 2 {
            reason = OurWords.t("через %s стандарт: ", Self.standardShort(answer.path[1]))
                + answer.path.joined(separator: " → ") + "; " + reason
        }
        return (answer.spans, reason, answer.rules.first)
    }

    func standardCode(ofModule id: String) -> String {
        guard let module = state.allModules.first(where: { $0.identifier == id }) else { return "" }
        return base.standardCode(forModuleNames: [module.info.shortName, module.identifier]) ?? ""
    }

    // MARK: - Текст для вкладки «Проверка»

    /// Разобранная книга перевода. С диска здесь не читаем: разбор Псалтири
    /// стоит полсекунды, а окно обязано отзываться. Чего нет — ставим в
    /// очередь и дорисовываем, когда придёт.
    func chapters(ofModule id: String, canonical: Int) -> [Chapter]? {
        guard let module = state.module(id),
              let book = module.books.first(where: { $0.canonicalNumber == canonical })
        else { return nil }
        if let ready = module.cachedChapters(ofBook: book) { return ready }

        let token = "\(id)|\(canonical)"
        guard !pendingChapters.contains(token) else { return nil }
        pendingChapters.insert(token)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = try? module.chapters(ofBook: book)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pendingChapters.remove(token)
                    self.cacheTick &+= 1
                }
            }
        }
        return nil
    }

    /// Разбор строки быстрого набора — тем же разбором, что и поле (9)
    /// главного окна: человеку не нужно помнить два разных правила записи.
    func applyAddressInput() {
        guard let module = state.module(checkPrimary) ?? state.primaryModule else { return }
        guard let address = ScriptureAddress.parse(addressInput, books: module.books) else {
            status = OurWords.t("адрес не разобран")
            return
        }
        if let canonical = address.book.canonicalNumber { checkBook = canonical }
        checkChapter = address.chapter ?? 1
        checkVerse = address.firstVerse ?? address.listedVerses.first ?? 1
        status = ""
    }

    func refreshAddressInput() {
        addressInput = "\(bookName(checkBook)) \(checkChapter):\(checkVerse)"
    }

    // MARK: - Сверка книги целиком

    /// Перевести каждый существующий стих книги и посчитать промахи.
    ///
    /// Числа опорные: на Псалтири RU_RST → KJV из 2527 стихов мимо проходит
    /// один. Если счётчик «мимо» вдруг десятки, значит модулю назначен не тот
    /// стандарт, — ради этого сверка и нужна.
    func verifyBook() {
        guard !isVerifying else { stopVerify(); return }
        let from = standardCode(ofModule: checkPrimary)
        let to = standardCode(ofModule: checkSecondary)
        guard !from.isEmpty, !to.isEmpty else {
            reportSummary = OurWords.t("стандарт не назначен обоим переводам")
            return
        }
        guard let source = state.module(checkPrimary), let target = state.module(checkSecondary),
              let sourceBook = source.books.first(where: { $0.canonicalNumber == checkBook }),
              let targetBook = target.books.first(where: { $0.canonicalNumber == checkBook })
        else {
            reportSummary = OurWords.t("этой книги нет в одном из переводов")
            return
        }

        verifyToken &+= 1
        let token = verifyToken
        let flag = VerifyFlag()
        verifyFlag = flag
        isVerifying = true
        report = []
        reportSummary = "сверяю…"
        let canonical = checkBook
        // Правила забираем значением до фона: 2500 прыжков на главный поток
        // ради одной и той же таблицы — это и есть «программа думает».
        let rules = base.rules

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let left = (try? source.chapters(ofBook: sourceBook)) ?? []
            let right = (try? target.chapters(ofBook: targetBook)) ?? []
            var known: Set<Int> = []
            for chapter in right {
                for verse in chapter.verses { known.insert(chapter.number &* 100_000 &+ verse.number) }
            }

            var lines: [ReportLine] = []
            var total = 0, missed = 0, merged = 0
            var hit: Set<Int> = []

            for chapter in left {
                guard !flag.isCancelled else { break }
                for verse in chapter.verses {
                    guard !flag.isCancelled else { break }
                    total += 1
                    let answer = Self.translate(rules: rules, book: canonical, chapter: chapter.number,
                                                verses: [verse.number], from: from, to: to).spans
                    var landed = 0
                    for span in answer {
                        for number in span.verses {
                            let key = span.chapter &* 100_000 &+ number
                            if known.contains(key) {
                                landed += 1
                                if !hit.insert(key).inserted { merged += 1 }
                            }
                        }
                    }
                    if landed == 0 {
                        missed += 1
                        if lines.count < 40 {
                            let address = answer.first.map {
                                ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses)
                            } ?? "—"
                            lines.append(ReportLine(chapter: chapter.number, verse: verse.number,
                                                    text: OurWords.t("%s:%s → %s — такого места во втором переводе нет", "\(chapter.number)", "\(verse.number)", "\(address)")))
                        }
                    }
                }
            }
            let orphans = known.count - hit.count
            let summary = flag.isCancelled
                ? OurWords.t("сверка остановлена на %s стихах", "\(total)")
                : OurWords.t("стихов %s, мимо %s, без соответствия во втором переводе %s, слияний %s",
                             "\(total)", "\(missed)", "\(orphans)", "\(merged)")

            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.verifyToken == token else { return }
                    self.report = lines
                    self.reportSummary = summary
                    self.isVerifying = false
                }
            }
        }
    }

    func stopVerify() {
        verifyFlag?.isCancelled = true
        isVerifying = false
        reportSummary = "сверка остановлена"
    }

    // MARK: - Запись и откат

    var userFilePath: String { NumberingBase.userURL.path }
    var hasOwnCopy: Bool { FileManager.default.fileExists(atPath: NumberingBase.userURL.path) }

    /// Записать свою копию. Ответ — слово об ошибке; `nil` значит «записано».
    ///
    /// Правок нет — не пишем ничего и файла не заводим: пустая своя копия
    /// хуже её отсутствия. Назавтра автор обновит базу, а мы будем читать
    /// вчерашнюю.
    @discardableResult
    func save() -> String? {
        guard ownRowCount > 0 else {
            isDirty = false
            snapshot = base
            snapshotRemoved = removed
            return nil
        }
        do {
            try base.save()
            try? writeOrigins()
            mirrorOwnerChoices()
            snapshot = base
            snapshotRemoved = removed
            isDirty = false
            sourceNote = OurWords.t("своя копия (правок: %s)", "\(ownRowCount)")
            NotificationCenter.default.post(name: .slovoNumberingChanged, object: nil)
            state.reloadNumbering()
            return nil
        } catch {
            return "\(error)"
        }
    }

    /// Список происхождения строк. В самой базе ему места нет: там схема
    /// автора, и лишний столбец сломал бы совместимость.
    private struct OriginFile: Codable {
        var version = 1
        var rules: [String: String]
        var modules: [String: String]
    }

    private func writeOrigins() throws {
        var rules: [String: String] = [:]
        for rule in base.rules {
            let origin = origin(of: rule)
            if origin != .author { rules[Self.key(rule)] = origin.title }
        }
        for rule in removed { rules[Self.key(rule)] = RowOrigin.removed.title }

        var modules: [String: String] = [:]
        for name in base.modules.keys where author.modules[name] != base.modules[name] {
            modules[name] = author.modules[name] == nil ? RowOrigin.added.title : RowOrigin.changed.title
        }
        for name in author.modules.keys where base.modules[name] == nil {
            modules[name] = RowOrigin.removed.title
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(OriginFile(rules: rules, modules: modules))
        let url = NumberingBase.userURL.deletingLastPathComponent()
            .appendingPathComponent("inconsistencies.origin.json")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// То же назначение — в свой файл стандартов. Двумя путями его читают две
    /// части программы, и разъезжаться им нельзя.
    private func mirrorOwnerChoices() {
        for row in moduleRows where !row.standard.isEmpty && row.origin != .author {
            NumberingAssignments.shared.setOwnerChoice(row.standard, forModule: row.id)
        }
        NumberingAssignments.shared.applyKnown(modules: state.allModules)
    }

    /// «Отменить»: снимок возвращается целиком, на диск ничего не уходило.
    func revert() {
        base = snapshot
        removed = snapshotRemoved
        isDirty = false
        rebuildModuleRows()
    }

    /// «Вернуть всё как у автора»: своя копия стирается, читаем эталон.
    func dropOwnCopy() {
        try? FileManager.default.removeItem(at: NumberingBase.userURL)
        try? FileManager.default.removeItem(at: NumberingBase.userURL.deletingLastPathComponent()
            .appendingPathComponent("inconsistencies.origin.json"))
        base = author
        if base.standards.isEmpty { base.standards = Self.defaultStandards }
        removed = []
        snapshot = base
        snapshotRemoved = []
        standardOrigins.removeAll()
        isDirty = false
        sourceNote = "файл автора"
        refreshedNote = ""
        rebuildModuleRows()
        state.reloadNumbering()
    }

    /// Показать свою копию в Finder; ещё не заведена — открыть саму папку.
    func revealOwnCopy() {
        let url = NumberingBase.userURL
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let folder = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([folder])
        }
    }
}
