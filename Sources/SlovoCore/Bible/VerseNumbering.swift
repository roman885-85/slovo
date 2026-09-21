import Foundation
import SQLite3

/// Стандарт нумерації розділів і віршів, якого дотримується переклад.
///
/// Це не мова і не видавництво: грецький Псалтир іде на розділ попереду
/// єврейського, надписання псалма в одних перекладах вважається віршем, а в
/// інших ні, в Йоіла і Малахії по-різному проведено межі розділів. Таких
/// стандартів одиниці, тому в кожного своє ім'я, а переклад на нього посилається.
public struct VerseNumberingStandard: Sendable, Hashable, Identifiable {
    public let id: String        // «ru», «en», «pl», «ua» — як у таблиці правил
    public let title: String     // як назвати у вікні «Редактор невідповідностей»

    public init(id: String, title: String) { self.id = id; self.title = title }

    /// Переклад, про який ми нічого не знаємо.
    ///
    /// Окреме значення, а не `nil`: з ним трансляція вироджується в
    /// тотожність і числа лишаються як є. Для показу це правильніше, ніж
    /// здогадка навмання: чужі номери збивають, а свої — ні.
    public static let unknown = VerseNumberingStandard(id: "", title: OurWords.t("не определён"))

    public var isKnown: Bool { !id.isEmpty }
}

/// Шматок адреси в чужій нумерації: один розділ і вірші в ньому.
///
/// Шматків буває кілька: уривок, що цілком лежить в одному перекладі всередині
/// розділу, в іншому переходить його межу — синодальне «Йоіл 2:27-28» це
/// «Йоіл 2:27» і «Йоіл 3:1». Пара чисел такого не виражає, тому список.
public struct VerseSpan: Sendable, Hashable {
    public let chapter: Int
    /// Порожній список означає «розділ цілком» — так само, як у `PlanItem.Scripture`.
    public let verses: [Int]

    public init(chapter: Int, verses: [Int]) { self.chapter = chapter; self.verses = verses }

    public var isWholeChapter: Bool { verses.isEmpty }
}

/// Переведення адреси з однієї нумерації в іншу.
///
/// Правила лежать у базі `inconsistencies.sqlite3` поруч із модулями старої програми:
/// 338 рядків, за якими автор оригіналу лагодив розбіжності. База читається один
/// раз і цілком розкладається в пам'яті, бо `translate` кличуть на
/// кожне натискання стрілки — зазирати за правилом на диск у цьому місці
/// означає підвісити введення.
///
/// Поки правила не прочитано (або бази зовсім немає), рушій працює вхолосту:
/// віддає ті самі числа, що отримав. Це не поломка, а потрібна поведінка —
/// програма зобов'язана поводитися як раніше і без бази автора.
public final class VerseNumbering: @unchecked Sendable {

    public static let shared = VerseNumbering()

    // MARK: - Правило

    /// Чотири види правил — рівно ті, що розрізняє сама стара програма.
    ///
    /// Імена взято з її ж запитів (`FDQueryIncD`, `IncP`, `IncOC`, `IncOV`),
    /// сенс розібрано за ними ж:
    ///  - `D`  — явна відповідність шматка, єдиний вид, де відповідь буває
    ///           відрізком із кількох віршів;
    ///  - `P`  — шматок перекладено підряд, відповідь рівно одна адреса;
    ///  - `OC` — зсув номера розділу (Псалтир за Септуагінтою проти єврейського);
    ///  - `OV` — зсув номера вірша (надписання псалма вважається віршем).
    enum RuleKind: String {
        case explicit = "D"
        case shifted = "P"
        case chapterShift = "OC"
        case verseShift = "OV"
    }

    struct Rule {
        let kind: RuleKind
        let chapterFrom: Int
        let chapterFromEnd: Int?
        let verseFrom: Int?
        let verseFromEnd: Int?
        let chapterTo: Int?
        let chapterToEnd: Int?
        let verseTo: Int?
        let verseToEnd: Int?
        /// Правило не з бази автора, а наша поправка — див. `Corrections`.
        let isCorrection: Bool

        /// Ключ єдиності такий самий, як унікальний покажчик у базі.
        /// За ним поправка поступається дорогою рядку автора, якщо той з'явиться.
        var uniqueKey: String {
            "\(kind.rawValue)|\(chapterFrom)|\(chapterFromEnd.map(String.init) ?? "")"
                + "|\(verseFrom.map(String.init) ?? "")|\(verseFromEnd.map(String.init) ?? "")"
        }
    }

    struct PairKey: Hashable {
        let from: String
        let to: String
        let book: Int
    }

    /// Розібрана таблиця цілком. Міняється лише заміною на нову —
    /// тому її можна читати з будь-якого потоку, взявши посилання під замком один раз.
    final class Table {
        let rules: [PairKey: [Rule]]
        let routes: [String: [String]]      // «звідки>куди» → ланцюжок стандартів
        let standards: [String: VerseNumberingStandard]
        let authorAssignments: [String: String]
        let databasePath: String?
        let ruleCount: Int
        let correctionCount: Int

        init(rules: [PairKey: [Rule]], routes: [String: [String]],
             standards: [String: VerseNumberingStandard],
             authorAssignments: [String: String],
             databasePath: String?, ruleCount: Int, correctionCount: Int) {
            self.rules = rules
            self.routes = routes
            self.standards = standards
            self.authorAssignments = authorAssignments
            self.databasePath = databasePath
            self.ruleCount = ruleCount
            self.correctionCount = correctionCount
        }

        static let empty = Table(rules: [:], routes: [:], standards: [:], authorAssignments: [:],
                                 databasePath: nil, ruleCount: 0, correctionCount: 0)
    }

    private let lock = NSLock()
    private var table: Table = .empty
    private var assignments: [String: String] = [:]
    private var didStartLoading = false

    private init() {}

    // MARK: - Завантаження

    /// Прочитати базу у фоні і не чекати.
    ///
    /// Кличеться при запуску: розбір 338 рядків — це частки секунди, але в головному
    /// потоці вони складаються з розбором модулів і перетворюються на помітну
    /// паузу перед появою вікна. До того як читання закінчиться, `translate`
    /// віддає ті самі числа — вікно встигає відкритися з правильним текстом.
    public func prepare(databaseAt url: URL? = nil) {
        lock.lock()
        if didStartLoading { lock.unlock(); return }
        didStartLoading = true
        lock.unlock()

        DispatchQueue.global(qos: .utility).async { [self] in
            _ = loadRules(databaseAt: url)
        }
    }

    /// Прочитати базу просто тут. Кликати НЕ з головного потоку.
    @discardableResult
    public func loadRules(databaseAt url: URL? = nil) -> Bool {
        let located = url ?? Self.locateDatabase()
        var rows: [(PairKey, Rule)] = []
        var standards: [String: VerseNumberingStandard] = [:]
        var author: [String: String] = [:]
        var path: String?

        if let located, let handle = Self.open(located) {
            defer { sqlite3_close(handle) }
            path = located.path
            rows = Self.readRules(handle)
            standards = Self.readStandards(handle)
            author = Self.readAuthorAssignments(handle)
        }

        // Поправки кладемо поверх прочитаного, але не затираючи автора: якщо
        // колись він допише той самий рядок сам, переможе його.
        var known = Set<String>()
        for (key, rule) in rows { known.insert("\(key.from)|\(key.to)|\(key.book)|\(rule.uniqueKey)") }
        var applied = 0
        for (key, rule) in Corrections.rows where !known.contains("\(key.from)|\(key.to)|\(key.book)|\(rule.uniqueKey)") {
            rows.append((key, rule))
            applied += 1
        }

        var byPair: [PairKey: [Rule]] = [:]
        for (key, rule) in rows { byPair[key, default: []].append(rule) }

        let table = Table(rules: byPair,
                          routes: Self.buildRoutes(byPair.keys),
                          standards: standards.isEmpty ? Self.builtInStandards : standards,
                          authorAssignments: author,
                          databasePath: path,
                          ruleCount: rows.count,
                          correctionCount: applied)
        lock.lock()
        self.table = table
        didStartLoading = true
        lock.unlock()
        return !rows.isEmpty
    }

    /// Рушій поверх правил, які зараз у руках, — наприклад правлених у
    /// вікні і ще не записаних у базу.
    ///
    /// Потрібен для того, щоб арифметика була одна на всю програму. До цього вікно
    /// «Редактор невідповідностей» рахувало адресу своїм розбором тих самих правил, а
    /// розбір був інший: звірка на 856 170 адресах показала 947 розбіжностей,
    /// і справжній текст модулів щоразу підтверджував не вікно. Виходило, що
    /// людина лагодить адресу за однією картиною, а зал бачить іншу.
    ///
    /// Поправки кладуться ті самі й за тим самим правилом, що при читанні бази: не
    /// затираючи рядків автора. Без них вікно рахувало б за 338 правилами, а слайд
    /// за 377 — і «зведено» було б лише на словах.
    public static func over(rules: [NumberingRule],
                            standards: [NumberingStandard] = []) -> VerseNumbering {
        var rows: [(PairKey, Rule)] = rules.map { rule in
            (PairKey(from: rule.from, to: rule.to, book: rule.book),
             Rule(kind: RuleKind(rawValue: rule.kind.rawValue) ?? .explicit,
                  chapterFrom: rule.chapterBegin,
                  chapterFromEnd: rule.chapterEnd,
                  verseFrom: rule.verseBegin,
                  verseFromEnd: rule.verseEnd,
                  chapterTo: rule.chapterTo,
                  chapterToEnd: rule.chapterToEnd,
                  verseTo: rule.verseTo,
                  verseToEnd: rule.verseToEnd,
                  isCorrection: false))
        }
        var known = Set<String>()
        for (key, rule) in rows { known.insert("\(key.from)|\(key.to)|\(key.book)|\(rule.uniqueKey)") }
        var applied = 0
        for (key, rule) in Corrections.rows
        where !known.contains("\(key.from)|\(key.to)|\(key.book)|\(rule.uniqueKey)") {
            rows.append((key, rule))
            applied += 1
        }

        var byPair: [PairKey: [Rule]] = [:]
        for (key, rule) in rows { byPair[key, default: []].append(rule) }

        var table: [String: VerseNumberingStandard] = [:]
        for item in standards {
            table[item.code] = VerseNumberingStandard(id: item.code, title: item.description)
        }

        let engine = VerseNumbering()
        engine.table = Table(rules: byPair,
                             routes: buildRoutes(byPair.keys),
                             standards: table.isEmpty ? builtInStandards : table,
                             authorAssignments: [:],
                             databasePath: nil,
                             ruleCount: rows.count,
                             correctionCount: applied)
        engine.didStartLoading = true
        return engine
    }

    /// Розкласти в пам'яті відповідність «переклад → стандарт».
    ///
    /// Ключами годяться і ім'я теки модуля, і його коротке ім'я: в історії і в
    /// плані від перекладу лишається лише коротке ім'я, а шукати треба все одно
    /// той самий стандарт. Регістр не важливий.
    public func load(assignments: [String: String]) {
        var folded: [String: String] = [:]
        folded.reserveCapacity(assignments.count)
        for (key, value) in assignments { folded[key.lowercased()] = value }
        lock.lock()
        self.assignments = folded
        lock.unlock()
    }

    // MARK: - Що зараз у пам'яті

    private var snapshot: Table {
        lock.lock(); defer { lock.unlock() }
        return table
    }

    /// Правила прочитано і трансляція щось уміє.
    public var isReady: Bool { snapshot.ruleCount > 0 }
    public var ruleCount: Int { snapshot.ruleCount }
    public var correctionCount: Int { snapshot.correctionCount }
    public var databasePath: String? { snapshot.databasePath }
    /// Стандарти в тому вигляді, в якому їх показувати людині.
    public var standards: [VerseNumberingStandard] {
        snapshot.standards.values.sorted { $0.id < $1.id }
    }
    /// Призначення з таблиці `modules` самої старої програми — як є, без правки.
    public var authorAssignments: [String: String] { snapshot.authorAssignments }

    public func standard(id: String) -> VerseNumberingStandard {
        snapshot.standards[id] ?? Self.builtInStandards[id] ?? .unknown
    }

    // MARK: - Стандарт перекладу

    /// Стандарт перекладу. Лише читання з пам'яті: кличеться при збиранні слайда,
    /// тобто на кожне натискання стрілки.
    public func standard(of module: any TextModule) -> VerseNumberingStandard {
        let table = snapshot
        lock.lock()
        let byID = assignments[module.identifier.lowercased()]
        let byShort = byID == nil ? assignments[module.info.shortName.lowercased()] : nil
        lock.unlock()
        guard let id = byID ?? byShort else { return .unknown }
        return table.standards[id] ?? Self.builtInStandards[id] ?? .unknown
    }

    public func standard(ofModule id: String) -> VerseNumberingStandard {
        lookup(id)
    }

    /// Запасний шлях для історії: там від перекладу лишилося лише коротке ім'я.
    public func standard(ofModuleShortName name: String) -> VerseNumberingStandard {
        lookup(name)
    }

    private func lookup(_ key: String) -> VerseNumberingStandard {
        let table = snapshot
        lock.lock()
        let id = assignments[key.lowercased()]
        lock.unlock()
        guard let id else { return .unknown }
        return table.standards[id] ?? Self.builtInStandards[id] ?? .unknown
    }

    // MARK: - Трансляція

    /// Переводити нічого: стандарти збігаються, один із них невідомий або
    /// дороги між ними в таблиці немає. Швидкий вихід без жодної зайвої роботи.
    public func isIdentity(from: VerseNumberingStandard, to: VerseNumberingStandard) -> Bool {
        guard from.isKnown, to.isKnown, from.id != to.id else { return true }
        return snapshot.routes["\(from.id)>\(to.id)"] == nil
    }

    /// Переведення адреси. `book` — наскрізний номер канону (`CanonicalBook`).
    ///
    /// Відповідь упорядкована за зростанням; за збіжних стандартів — один шматок
    /// з тими самими числами. Одному віршу зліва може відповідати кілька справа
    /// (грецький Пс 12:6 це єврейські 13:5 і 13:6) і навпаки — тому
    /// відповідь збирається в множину і об'єднується.
    ///
    /// `verseCount` — скільки віршів у розділі ЦІЛЬОВОГО перекладу. Потрібен в одному
    /// рідкісному випадку: правило `D`, відрізок якого переходить межу розділу
    /// (ru Ос 11:1 = en Ос 10:15–11:1). В усіх восьми таких рядках бази
    /// перший вірш відрізка і так останній у розділі, тому без підказки
    /// беремо лише його — а з підказкою розгортаємо хвіст чесно.
    public func translate(book: Int, chapter: Int, verses: [Int],
                          from: VerseNumberingStandard,
                          to: VerseNumberingStandard,
                          verseCount: ((Int) -> Int?)? = nil) -> [VerseSpan] {
        guard !isIdentity(from: from, to: to) else {
            return [VerseSpan(chapter: chapter, verses: verses)]
        }
        let table = snapshot
        guard let route = table.routes["\(from.id)>\(to.id)"] else {
            return [VerseSpan(chapter: chapter, verses: verses)]
        }

        // Розділ цілком: номери віршів не задано, отже правилам D і P
        // (вони дивляться саме на вірш) зачепитися нема за що. Рухаємо лише
        // номер розділу — цього вистачає для Псалтиря, заради якого все й затіяно.
        guard !verses.isEmpty else {
            var current = chapter
            for step in 0..<(route.count - 1) {
                current = chapterOnly(book: book, chapter: current,
                                      from: route[step], to: route[step + 1], table: table)
            }
            return [VerseSpan(chapter: current, verses: [])]
        }

        var current = verses.map { (chapter, $0) }
        for step in 0..<(route.count - 1) {
            let isLast = step == route.count - 2
            var next: [(Int, Int)] = []
            for address in current {
                next.append(contentsOf: translateStep(book: book, chapter: address.0, verse: address.1,
                                                      from: route[step], to: route[step + 1],
                                                      table: table,
                                                      verseCount: isLast ? verseCount : nil))
            }
            current = unique(next)
        }
        return spans(from: current)
    }

    /// Те саме для одного вірша — ним користується рядок адреси і перехід
    /// «показати це місце в іншому перекладі».
    public func translate(book: Int, chapter: Int, verse: Int,
                          from: VerseNumberingStandard,
                          to: VerseNumberingStandard,
                          verseCount: ((Int) -> Int?)? = nil) -> [(chapter: Int, verse: Int)] {
        translate(book: book, chapter: chapter, verses: [verse], from: from, to: to, verseCount: verseCount)
            .flatMap { span in span.verses.map { (chapter: span.chapter, verse: $0) } }
    }

    /// Книга береться з модуля, тому в неї свій порядковий номер; для
    /// правил годиться лише наскрізний номер канону. Немає його — переводити
    /// нічого: показуємо ті самі числа.
    public func translate(book: BookInfo, chapter: Int, verses: [Int],
                          from: VerseNumberingStandard,
                          to: VerseNumberingStandard,
                          verseCount: ((Int) -> Int?)? = nil) -> [VerseSpan] {
        guard let number = book.canonicalNumber else {
            return [VerseSpan(chapter: chapter, verses: verses)]
        }
        return translate(book: number, chapter: chapter, verses: verses,
                         from: from, to: to, verseCount: verseCount)
    }

    /// Яким правилом отримано відповідь — для вікна редактора і самоперевірки.
    public func trace(book: Int, chapter: Int, verse: Int,
                      from: VerseNumberingStandard, to: VerseNumberingStandard) -> String {
        guard !isIdentity(from: from, to: to) else { return OurWords.t("стандарты совпадают") }
        let table = snapshot
        guard let route = table.routes["\(from.id)>\(to.id)"] else { return OurWords.t("дороги нет") }
        var parts: [String] = []
        var current = [(chapter, verse)]
        for step in 0..<(route.count - 1) {
            let rules = table.rules[PairKey(from: route[step], to: route[step + 1], book: book)] ?? []
            var kinds: [String] = []
            for address in current {
                if let rule = rules.first(where: { $0.kind == .explicit && matches($0, address.0, address.1) }) {
                    kinds.append(rule.isCorrection ? "D (поправка)" : "D")
                } else if let rule = rules.first(where: { $0.kind == .shifted && matches($0, address.0, address.1) }) {
                    kinds.append(rule.isCorrection ? "P (поправка)" : "P")
                } else {
                    var both: [String] = []
                    if rules.contains(where: { $0.kind == .chapterShift && matches($0, address.0, address.1) }) { both.append("OC") }
                    if rules.contains(where: { $0.kind == .verseShift && matches($0, address.0, address.1) }) { both.append("OV") }
                    kinds.append(both.isEmpty ? OurWords.t("без правил") : both.joined(separator: "+"))
                }
            }
            parts.append("\(route[step])→\(route[step + 1]): \(kinds.joined(separator: ", "))")
            var next: [(Int, Int)] = []
            for address in current {
                next.append(contentsOf: translateStep(book: book, chapter: address.0, verse: address.1,
                                                      from: route[step], to: route[step + 1],
                                                      table: table, verseCount: nil))
            }
            current = unique(next)
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Один крок ланцюжка

    private func translateStep(book: Int, chapter: Int, verse: Int,
                               from: String, to: String, table: Table,
                               verseCount: ((Int) -> Int?)?) -> [(Int, Int)] {
        guard let rules = table.rules[PairKey(from: from, to: to, book: book)] else {
            return [(chapter, verse)]
        }

        // 1. D — явна відповідність. Відповідь уже в чужій нумерації, зсуви
        //    OC і OV до неї не додаються: перевірено перебором (ru Пс 12:6
        //    це en Пс 13:5-6, а не 13:4-5).
        for rule in rules where rule.kind == .explicit {
            guard matches(rule, chapter, verse) else { continue }
            return explicitAnswer(rule, chapter: chapter, verseCount: verseCount)
        }

        // 2. P — шматок перекладено підряд. Теж абсолютна відповідь: на ru Пс 113:9
        //    сходяться P і OC, і правильну відповідь en Пс 115:1 дає лише P.
        for rule in rules where rule.kind == .shifted {
            guard matches(rule, chapter, verse) else { continue }
            let chapterTo = chapter + ((rule.chapterTo ?? rule.chapterFrom) - rule.chapterFrom)
            let verseTo = verse + ((rule.verseTo ?? 0) - (rule.verseFrom ?? 0))
            return [(chapterTo, verseTo)]
        }

        // 3. Зсуви розділу і вірша незалежні й додаються: грецький Пс 11:2
        //    це єврейський Пс 12:1 — розділ на одиницю вперед, вірш на одиницю назад.
        var chapterOut = chapter
        var verseOut = verse
        if let rule = rules.first(where: { $0.kind == .chapterShift && matches($0, chapter, verse) }) {
            chapterOut += rule.chapterTo ?? 0
        }
        if let rule = rules.first(where: { $0.kind == .verseShift && matches($0, chapter, verse) }) {
            verseOut += rule.verseTo ?? 0
        }
        return [(chapterOut, verseOut)]
    }

    /// Відповідь правила `D`. Вона буває відрізком, і відрізок буває через межу розділу.
    private func explicitAnswer(_ rule: Rule, chapter: Int,
                                verseCount: ((Int) -> Int?)?) -> [(Int, Int)] {
        // Розділ-ціль задано зсувом, а не числом. Ряд «en Пс 12..13 вірш 1 →
        // ru розд 11 вірші 1..2» на розділі 12 зобов'язаний дати ru 11, а на розділі 13 — ru 12.
        let shift = chapter - rule.chapterFrom
        let first = (rule.chapterTo ?? rule.chapterFrom) + shift
        let last = (rule.chapterToEnd ?? rule.chapterTo ?? rule.chapterFrom) + shift
        let fromVerse = rule.verseTo ?? 1
        let toVerse = rule.verseToEnd ?? fromVerse

        if first >= last {
            return (min(fromVerse, toVerse)...max(fromVerse, toVerse)).map { (first, $0) }
        }

        var answer: [(Int, Int)] = []
        let tail = verseCount?(first) ?? fromVerse
        answer.append(contentsOf: (fromVerse...max(fromVerse, tail)).map { (first, $0) })
        if last > first + 1 {
            for middle in (first + 1)..<last {
                let count = verseCount?(middle) ?? 1
                answer.append(contentsOf: (1...max(1, count)).map { (middle, $0) })
            }
        }
        answer.append(contentsOf: (1...max(1, toVerse)).map { (last, $0) })
        return answer
    }

    /// Хід по розділу без віршів — працюють лише зсуви розділів.
    private func chapterOnly(book: Int, chapter: Int, from: String, to: String, table: Table) -> Int {
        guard let rules = table.rules[PairKey(from: from, to: to, book: book)],
              let rule = rules.first(where: { $0.kind == .chapterShift && coversChapter($0, chapter) })
        else { return chapter }
        return chapter + (rule.chapterTo ?? 0)
    }

    private func coversChapter(_ rule: Rule, _ chapter: Int) -> Bool {
        chapter >= rule.chapterFrom && chapter <= (rule.chapterFromEnd ?? rule.chapterFrom)
    }

    /// Чи підходить правило адресі.
    ///
    /// Порожня клітинка і NULL у базі означають одне й те саме — «немає значення», і
    /// означають вони різне для різних видів: у `D` порожній `verse_from_end` це
    /// «рівно один вірш», у `P` і `OV` — «до кінця розділу». Переплутати їх
    /// не можна: ru Пс 146:1 переїжджає в en Пс 147:1 разом з усім розділом.
    private func matches(_ rule: Rule, _ chapter: Int, _ verse: Int) -> Bool {
        guard coversChapter(rule, chapter) else { return false }
        switch rule.kind {
        case .chapterShift:
            return true
        case .explicit:
            guard let low = rule.verseFrom else { return false }
            let high = rule.verseFromEnd ?? low
            return verse >= low && verse <= high
        case .shifted, .verseShift:
            let low = rule.verseFrom ?? 1
            guard verse >= low else { return false }
            if let high = rule.verseFromEnd { return verse <= high }
            return true
        }
    }

    private func unique(_ addresses: [(Int, Int)]) -> [(Int, Int)] {
        var seen = Set<Int>()
        var result: [(Int, Int)] = []
        for address in addresses where seen.insert(address.0 &* 100_000 &+ address.1).inserted {
            result.append(address)
        }
        return result
    }

    private func spans(from addresses: [(Int, Int)]) -> [VerseSpan] {
        var byChapter: [Int: [Int]] = [:]
        for address in addresses { byChapter[address.0, default: []].append(address.1) }
        return byChapter.keys.sorted().map { VerseSpan(chapter: $0, verses: byChapter[$0]!.sorted()) }
    }

    // MARK: - Дороги між стандартами

    /// Прямих переведень у базі лише три: ru↔en, en↔pl, ru↔ua. Ні ru↔pl, ні
    /// ua↔en, ні ua↔pl там немає, тому їх доводиться вести ланцюжком
    /// ua — ru — en — pl. На кожному кроці множина адрес може розширитися,
    /// і це нормально: ua Пс 51:3 доїжджає до pl трьома віршами.
    static func buildRoutes<Keys: Collection>(_ keys: Keys) -> [String: [String]] where Keys.Element == PairKey {
        var neighbours: [String: Set<String>] = [:]
        var nodes = Set<String>()
        for key in keys {
            neighbours[key.from, default: []].insert(key.to)
            nodes.insert(key.from)
            nodes.insert(key.to)
        }
        var routes: [String: [String]] = [:]
        for start in nodes {
            var queue = [[start]]
            var visited: Set<String> = [start]
            while !queue.isEmpty {
                let path = queue.removeFirst()
                let last = path[path.count - 1]
                if path.count > 1 { routes["\(start)>\(last)"] = path }
                for next in (neighbours[last] ?? []).sorted() where !visited.contains(next) {
                    visited.insert(next)
                    queue.append(path + [next])
                }
            }
        }
        return routes
    }

    // MARK: - Читання бази

    /// Де шукати базу правил. Порядок той самий, що в теки модулів: спершу
    /// власний пакет, потім особиста тека. Установлену стару програму не
    /// перевіряємо — програма везе базу з собою.
    public static func locateDatabase() -> URL? {
        let candidates = [
            DataHome.bundleData.appendingPathComponent("inconsistencies.sqlite3"),
            DataHome.folder.appendingPathComponent("inconsistencies.sqlite3"),
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func open(_ url: URL) -> OpaquePointer? {
        var handle: OpaquePointer?
        // Лише читання: база чужа, і псувати її не можна навіть журналом.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        return handle
    }

    /// Число з клітинки. У базі впереміш лежать NULL і порожній рядок — у
    /// чотирнадцяти рядків там саме `''`. Вважаємо їх одним «немає значення»:
    /// сама стара програма у запитах пише `= '' or is null` і різниці не робить.
    private static func number(_ statement: OpaquePointer?, _ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else { return nil }
        let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : Int(text)
    }

    private static func readRules(_ handle: OpaquePointer) -> [(PairKey, Rule)] {
        let sql = """
            SELECT lng_from, lng_to, type, book_from,
                   chapter_from_begin, chapter_from_end, verse_from_begin, verse_from_end,
                   chapter_to_begin, chapter_to_end, verse_to_begin, verse_to_end
            FROM bibletrans
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }

        var rows: [(PairKey, Rule)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let from = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let to = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let type = sqlite3_column_text(statement, 2).map({ String(cString: $0) }),
                  let kind = RuleKind(rawValue: type.trimmingCharacters(in: .whitespaces)),
                  let book = number(statement, 3),
                  let chapterFrom = number(statement, 4)
            else { continue }
            let rule = Rule(kind: kind,
                            chapterFrom: chapterFrom,
                            chapterFromEnd: number(statement, 5),
                            verseFrom: number(statement, 6),
                            verseFromEnd: number(statement, 7),
                            chapterTo: number(statement, 8),
                            chapterToEnd: number(statement, 9),
                            verseTo: number(statement, 10),
                            verseToEnd: number(statement, 11),
                            isCorrection: false)
            rows.append((PairKey(from: from, to: to, book: book), rule))
        }
        return rows
    }

    private static func readStandards(_ handle: OpaquePointer) -> [String: VerseNumberingStandard] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT lng, description FROM t_info", -1, &statement, nil) == SQLITE_OK
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [String: VerseNumberingStandard] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = sqlite3_column_text(statement, 0).map({ String(cString: $0) }) else { continue }
            let description = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            // Свої назви в чотирьох відомих стандартів важливіші за авторські:
            // у `t_info` приклади перекладів переставлено місцями — «King James»
            // підписано до септуагінтного рахунку, а «Synodal» до масоретського,
            // хоча насправді навпаки. Самі імена (East/West) там правильні.
            result[id] = builtInStandards[id] ?? VerseNumberingStandard(id: id, title: description)
        }
        return result
    }

    private static func readAuthorAssignments(_ handle: OpaquePointer) -> [String: String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT name, lng FROM modules", -1, &statement, nil) == SQLITE_OK
        else { return [:] }
        defer { sqlite3_finalize(statement) }

        var result: [String: String] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 0).map({ String(cString: $0) }),
                  let lng = sqlite3_column_text(statement, 1).map({ String(cString: $0) })
            else { continue }
            result[name] = lng
        }
        return result
    }

    /// Назви стандартів словами. Потрібні й без бази: програма зобов'язана
    /// відкриватися, коли старої програми на цьому комп'ютері не встановлено.
    static let builtInStandards: [String: VerseNumberingStandard] = [
        "ru": VerseNumberingStandard(id: "ru", title: OurWords.t("Восточный, по Септуагинте (Синодальный)")),
        "en": VerseNumberingStandard(id: "en", title: OurWords.t("Западный, масоретский (King James)")),
        "pl": VerseNumberingStandard(id: "pl", title: "Польский (Biblia Warszawska)"),
        "ua": VerseNumberingStandard(id: "ua", title: "Украинский"),
    ]
}

// MARK: - Поправки до бази автора

extension VerseNumbering {

    /// Діри в базі старої програми, які видно за справжнім текстом модулів.
    ///
    /// Базу автора ми не чіпаємо: вона чужа і лежить у чужій програмі. Рядки
    /// додаються поверх неї при читанні і поступаються дорогою, якщо автор
    /// колись допише те саме місце сам.
    ///
    /// Кожен рядок перевірено звіркою двох справжніх перекладів із
    /// бібліотеки власника — рахунком віршів у розділі і самим текстом вірша.
    /// Жоден не вигаданий «для краси»: без них правила мовчки віддають або
    /// неіснуючу адресу, або сусідній вірш, а це гірше, ніж нічого.
    enum Corrections {

        static func row(_ from: String, _ to: String, _ kind: RuleKind, _ book: Int,
                        _ cfb: Int, _ cfe: Int?, _ vfb: Int?, _ vfe: Int?,
                        _ ctb: Int?, _ cte: Int?, _ vtb: Int?, _ vte: Int?) -> (PairKey, Rule) {
            (PairKey(from: from, to: to, book: book),
             Rule(kind: kind, chapterFrom: cfb, chapterFromEnd: cfe,
                  verseFrom: vfb, verseFromEnd: vfe,
                  chapterTo: ctb, chapterToEnd: cte, verseTo: vtb, verseToEnd: vte,
                  isCorrection: true))
        }

        static let rows: [(PairKey, Rule)] = [

            // ── Пс 35: випала рівно одна половина пари ────────────────────
            // Зворотний рядок (en→ru, розд 36, вірші 2.., +1) у базі є, а
            // прямого немає. Синодальний Пс 35:2 «Нечестие беззаконного говорит
            // в сердце моем» — це KJV Пс 36:1 «The transgression of the
            // wicked saith within my heart», а без цього рядка правила дають
            // 36:2. З ним кругових розбіжностей rst+→KJV стає 7 замість 19.
            row("ru", "en", .verseShift, 230, 35, nil, 2, nil, nil, nil, -1, nil),

            // ── Числа 29/30 ──────────────────────────────────────────────
            // rst+ Чис 29=39, 30=17; KJV 29=40, 30=16. Синодальне Чис 30:1
            // «И пересказал Моисей сынам Израилевым все, что повелел Господь
            // Моисею» — це KJV Чис 29:40. У bw (pl) та сама межа, що в ru.
            row("ru", "en", .explicit, 40, 30, nil, 1, nil, 29, nil, 40, nil),
            row("ru", "en", .verseShift, 40, 30, 30, 2, nil, nil, nil, -1, nil),
            row("en", "ru", .explicit, 40, 29, nil, 40, nil, 30, nil, 1, nil),
            row("en", "ru", .verseShift, 40, 30, 30, 1, nil, nil, nil, 1, nil),
            row("pl", "en", .explicit, 40, 30, nil, 1, nil, 29, nil, 40, nil),
            row("pl", "en", .verseShift, 40, 30, 30, 2, nil, nil, nil, -1, nil),
            row("en", "pl", .explicit, 40, 29, nil, 40, nil, 30, nil, 1, nil),
            row("en", "pl", .verseShift, 40, 30, 30, 1, nil, nil, nil, 1, nil),

            // ── Числа 16/17 у Biblia Warszawska ──────────────────────────
            // bw 16=35, 17=28; KJV 16=50, 17=13. Шматок en 16:36..50 переїхав
            // у pl 17:1..15, а колишній сімнадцятий розділ став слідом.
            row("en", "pl", .shifted, 40, 16, nil, 36, nil, 17, nil, 1, nil),
            row("en", "pl", .shifted, 40, 17, nil, 1, nil, 17, nil, 16, nil),
            row("pl", "en", .shifted, 40, 17, nil, 1, 15, 16, nil, 36, nil),
            row("pl", "en", .shifted, 40, 17, nil, 16, nil, 17, nil, 1, nil),

            // ── Екклезіаст 4/5 ───────────────────────────────────────────
            // rst+ Еккл 4=17, 5=19; KJV 4=16, 5=20. Синодальне Еккл 4:17
            // «Наблюдай за ногою твоею…» — це KJV Еккл 5:1 «Keep thy foot».
            // У bw межа як у ru (4=17, 5=19), тому пара en↔pl потребує
            // тієї самої поправки; розділ 8 автор уже розписав.
            row("ru", "en", .explicit, 250, 4, nil, 17, nil, 5, nil, 1, nil),
            row("ru", "en", .verseShift, 250, 5, 5, 1, nil, nil, nil, 1, nil),
            row("en", "ru", .explicit, 250, 5, nil, 1, nil, 4, nil, 17, nil),
            row("en", "ru", .verseShift, 250, 5, 5, 2, nil, nil, nil, -1, nil),
            row("pl", "en", .explicit, 250, 4, nil, 17, nil, 5, nil, 1, nil),
            row("pl", "en", .verseShift, 250, 5, 5, 1, nil, nil, nil, 1, nil),
            row("en", "pl", .explicit, 250, 5, nil, 1, nil, 4, nil, 17, nil),
            row("en", "pl", .verseShift, 250, 5, 5, 2, nil, nil, nil, -1, nil),

            // ── Осія 1/2 у Biblia Warszawska ─────────────────────────────
            // bw 1=9, 2=25; KJV 1=11, 2=23. Два останні вірші першого розділу
            // пішли в початок другого, і весь другий зсунувся на два вірші.
            row("en", "pl", .shifted, 350, 1, nil, 10, nil, 2, nil, 1, nil),
            row("en", "pl", .shifted, 350, 2, nil, 1, nil, 2, nil, 3, nil),
            row("pl", "en", .shifted, 350, 2, nil, 1, 2, 1, nil, 10, nil),
            row("pl", "en", .shifted, 350, 2, nil, 3, nil, 2, nil, 1, nil),

            // ── Дії 19 ───────────────────────────────────────────────────
            // rst+ Дії 19 = 40 віршів, KJV = 41: KJV 19:41 «And when he had
            // thus spoken, he dismissed the assembly» входить у Синодальний
            // 19:40. У bw, як і в ru, сорок віршів.
            row("ru", "en", .explicit, 510, 19, nil, 40, nil, 19, nil, 40, 41),
            row("en", "ru", .explicit, 510, 19, nil, 40, 41, 19, nil, 40, nil),
            row("pl", "en", .explicit, 510, 19, nil, 40, nil, 19, nil, 40, 41),
            row("en", "pl", .explicit, 510, 19, nil, 40, 41, 19, nil, 40, nil),

            // ── Йоіл: в українських перекладів книга з чотирьох розділів ──
            // rst+ 1=20, 2=32, 3=21; ubt2020 (і cuv'23, і ubt2022) 1=20, 2=27,
            // 3=5, 4=21. Синодальне Йоіл 2:28 «И будет после того, излию от
            // Духа Моего на всякую плоть» — это ubt2020 Йоіл 3:1 «Після цього
            // відбудеться таке, що Я зіллю Мого Духа на всіх людей».
            row("ru", "ua", .shifted, 360, 2, nil, 28, 32, 3, nil, 1, nil),
            row("ru", "ua", .shifted, 360, 3, nil, 1, nil, 4, nil, 1, nil),
            row("ua", "ru", .shifted, 360, 3, nil, 1, 5, 2, nil, 28, nil),
            row("ua", "ru", .shifted, 360, 4, nil, 1, nil, 3, nil, 1, nil),

            // ── Малахія: в українських перекладів книга з трьох розділів ──
            // rst+ 3=18, 4=6; ubt2020 3=24, четвертого розділу немає зовсім.
            // Синодальне Мал 4:1 «Ибо вот, придет день, пылающий как печь» —
            // это ubt2020 Малахії 3:19 «Адже надходить День, що палає, як піч».
            row("ru", "ua", .shifted, 460, 4, nil, 1, nil, 3, nil, 19, nil),
            row("ua", "ru", .shifted, 460, 3, nil, 19, 24, 4, nil, 1, nil),

            // ── 3 Царів 4/5 ──────────────────────────────────────────────
            // rst+ 4=34, 5=18; ubt2020 4=20, 5=32. Синодальне 3Цар 4:21
            // «Соломон владел всеми царствами от реки Евфрата» — це ubt2020
            // 1 Царів 5:1 «Отже, Соломон владарював над усіма царствами»,
            // а Синодальне 5:1 «И послал Хирам, царь Тирский» — це 5:15
            // «Тирський цар Хірам… почувши, що його син помазаний».
            row("ru", "ua", .shifted, 110, 4, nil, 21, nil, 5, nil, 1, nil),
            row("ru", "ua", .shifted, 110, 5, nil, 1, nil, 5, nil, 15, nil),
            row("ua", "ru", .shifted, 110, 5, nil, 1, 14, 4, nil, 21, nil),
            row("ua", "ru", .shifted, 110, 5, nil, 15, nil, 5, nil, 1, nil),
        ]
    }
}

// MARK: - Готова відповідь для показу поруч двох перекладів

public extension VerseNumbering {

    /// Та сама адреса в іншому перекладі, вже перевірена за його розібраними розділами.
    ///
    /// Диск не читає: розділи той, хто кличе, і так тримає в руках, а збирання слайда
    /// іде на кожне натискання. Порожня відповідь означає «місця немає» — так буває
    /// чесно: Пс 151 Септуагінти в єврейському рахунку відповідності не має, і
    /// підставляти замість нього сусідній вірш не можна, це підробка.
    func existingSpans(book: BookInfo, chapter: Int, verses: [Int],
                       from: VerseNumberingStandard,
                       to module: any TextModule, chapters: [Chapter]) -> [VerseSpan] {
        let to = standard(of: module)
        guard !isIdentity(from: from, to: to) else {
            return keepExisting([VerseSpan(chapter: chapter, verses: verses)], chapters: chapters)
        }
        let counted: (Int) -> Int? = { number in chapters.first { $0.number == number }?.verses.count }
        let translated = translate(book: book, chapter: chapter, verses: verses,
                                   from: from, to: to, verseCount: counted)
        return keepExisting(translated, chapters: chapters)
    }

    private func keepExisting(_ spans: [VerseSpan], chapters: [Chapter]) -> [VerseSpan] {
        spans.compactMap { span in
            guard let chapter = chapters.first(where: { $0.number == span.chapter }) else { return nil }
            guard !span.verses.isEmpty else { return span }
            let existing = span.verses.filter { number in chapter.verses.contains { $0.number == number } }
            return existing.isEmpty ? nil : VerseSpan(chapter: span.chapter, verses: existing)
        }
    }

    /// Зіткнення правил: адреси, накриті двома правилами одного виду.
    ///
    /// Заради них весь порядок застосування і тримається: якби на одну адресу
    /// підходили два `D`, відповідь залежала б від порядку рядків у базі. Перевіряти
    /// треба за справжніми розділами перекладу, тому довжини розділів передає той, хто кличе.
    func duplicateRules(book: Int, chapterLengths: [Int: Int],
                        from: VerseNumberingStandard, to: VerseNumberingStandard) -> [String] {
        guard let rules = snapshot.rules[PairKey(from: from.id, to: to.id, book: book)] else { return [] }
        var found: [String] = []
        for (chapter, length) in chapterLengths.sorted(by: { $0.key < $1.key }) {
            for verse in 1...max(1, length) {
                for kind in [RuleKind.explicit, .shifted, .chapterShift, .verseShift] {
                    let hits = rules.filter { $0.kind == kind && matches($0, chapter, verse) }
                    if hits.count > 1 {
                        found.append("\(from.id)→\(to.id) книга \(book) \(chapter):\(verse) — правил вида \(kind.rawValue): \(hits.count)")
                    }
                }
            }
        }
        return found
    }
}

public extension VerseNumbering {

    /// Приписка к строке адреса: «(23:1)», когда второй перевод считает иначе.
    ///
    /// Пустая строка, если номера совпадают, — приписывать «(22:1)» к «22:1»
    /// незачем. Пустая и тогда, когда места в другом переводе нет: сказать об
    /// этом должен текст слайда, а не хвост адреса.
    func parallelSuffix(book: BookInfo, chapter: Int, verses: [Int],
                        from: VerseNumberingStandard,
                        to module: any TextModule, chapters: [Chapter]) -> String {
        let spans = existingSpans(book: book, chapter: chapter, verses: verses,
                                  from: from, to: module, chapters: chapters)
        guard !spans.isEmpty else { return "" }
        let own = ReferenceFormat.position(chapter: chapter, verses: verses)
        let other = spans
            .map { ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses) }
            .joined(separator: ", ")
        return other == own ? "" : " (\(other))"
    }
}
