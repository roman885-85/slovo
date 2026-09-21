import Foundation

/// Кому який стандарт нумерації призначено і звідки це відомо.
public struct NumberingAssignment: Sendable, Hashable {

    /// Звідки взялося призначення. Порядок важливий: своє рішення власника
    /// сильніше за здогадку, здогадка — сильніша за таблицю автора.
    public enum Source: String, Sendable, Hashable {
        case owner      // вибрано людиною у вікні редактора
        case guessed    // виведено за будовою самого перекладу
        case author     // таблиця `modules` з бази старої програми
        case none       // стандарт не визначено

        public var title: String {
            switch self {
            case .owner:   return OurWords.t("назначено")
            case .guessed: return OurWords.t("догадка")
            case .author:  return OurWords.t("из базы нумерации")
            case .none:    return OurWords.t("не определён")
            }
        }
    }

    public let moduleID: String
    public let standardID: String
    public let source: Source
    /// Чим підтверджується — числами справжнього перекладу, а не загальними словами.
    public let reason: String

    public init(moduleID: String, standardID: String, source: Source, reason: String) {
        self.moduleID = moduleID
        self.standardID = standardID
        self.source = source
        self.reason = reason
    }

    public var isKnown: Bool { !standardID.isEmpty }
}

/// Здогадка про стандарт за будовою самого перекладу.
///
/// Таблиця `modules` у базі старої програми описує вісім перекладів із
/// п'ятдесяти п'яти, і чотири рядки з восьми в ній хибні — це видно за
/// числами: «МСЦ'22», записаний українським, при переведенні як український дає
/// 772 промахи, а як східний — чотири. Тому питаємо не таблицю, а
/// сам переклад: скільки в нього віршів у тих розділах, де стандарти розходяться.
public enum NumberingGuess {

    /// Числа, за якими розрізняються стандарти. Більше нічого для рішення
    /// не потрібно, і це добре: читати доводиться всього дві-три книги.
    ///
    /// Скрізь береться НОМЕР останнього вірша, а не їхня кількість. Різниця не
    /// причіпка: в «ubt2022» надписання псалма розмічено так, що наш розбір
    /// його не підхоплює, і за кількістю псалом виглядає масоретським,
    /// хоча останній вірш у нього дев'ятий — український.
    public struct Evidence: Sendable, Hashable {
        public var psalmCount: Int?      // скільки всього псалмів: 150, 151 — інакше переклад ділить по-своєму
        public var psalm9: Int?          // Пс 9: у Септуагінти він увібрав у себе десятий
        public var psalm3: Int?          // Пс 3: надписання вважається віршем чи ні
        public var psalm147: Int?        // Пс 147: у Септуагінти це друга половина єврейського 147-го
        public var ecclesiastes8: Int?   // Еккл 8: єдина ознака Biblia Warszawska
        public var romans16: Int?        // для перекладів без Псалтиря — лише Новий Заповіт

        public init(psalmCount: Int? = nil, psalm9: Int? = nil, psalm3: Int? = nil,
                    psalm147: Int? = nil, ecclesiastes8: Int? = nil, romans16: Int? = nil) {
            self.psalmCount = psalmCount
            self.psalm9 = psalm9
            self.psalm3 = psalm3
            self.psalm147 = psalm147
            self.ecclesiastes8 = ecclesiastes8
            self.romans16 = romans16
        }
    }

    /// Зібрати числа з диска. Розбір книги коштує сотні мілісекунд —
    /// кликати НЕ з головного потоку.
    public static func evidence(for module: any TextModule) -> Evidence {
        var evidence = Evidence()
        func last(_ chapters: [Chapter], _ number: Int) -> Int? {
            chapters.first { $0.number == number }?.verses.map(\.number).max()
        }
        if let psalms = module.books.first(where: { $0.canonicalNumber == 230 }),
           let chapters = try? module.chapters(ofBook: psalms) {
            evidence.psalmCount = chapters.count
            evidence.psalm9 = last(chapters, 9)
            evidence.psalm3 = last(chapters, 3)
            evidence.psalm147 = last(chapters, 147)
        }
        if let ecclesiastes = module.books.first(where: { $0.canonicalNumber == 250 }),
           let chapters = try? module.chapters(ofBook: ecclesiastes) {
            evidence.ecclesiastes8 = last(chapters, 8)
        }
        if evidence.psalm9 == nil,
           let romans = module.books.first(where: { $0.canonicalNumber == 520 }),
           let chapters = try? module.chapters(ofBook: romans) {
            evidence.romans16 = last(chapters, 16)
        }
        return evidence
    }

    /// Рішення за зібраними числами.
    ///
    /// Дерево коротке, бо стандарти розходяться в різних місцях:
    /// Псалтир за Септуагінтою видно одразу (9-й псалом увібрав у себе десятий,
    /// а 147-й — лише друга половина єврейського), масоретський рахунок — за
    /// ненумерованим надписанням, а польський від українського відрізняється в
    /// усій бібліотеці однією-єдиною главою.
    public static func decide(_ evidence: Evidence) -> (standardID: String, reason: String)? {
        if let count = evidence.psalmCount, count != 150, count != 151 {
            // «UA_Kulish» зі своїми 149 псалмами і «Belarus_Semuha» зі 152 не
            // лягають у жоден стандарт. Гадати про них — значить підставити
            // у вікно чужий вірш; краще показати їх за своїми номерами.
            return nil
        }
        if let psalm9 = evidence.psalm9, psalm9 >= 30 {
            return ("ru", OurWords.t("в 9-м псалме %s стихов — он вобрал в себя десятый, счёт по Септуагинте", "\(psalm9)"))
        }
        if let psalm147 = evidence.psalm147, psalm147 <= 12 {
            return ("ru", OurWords.t("в 147-м псалме %s стихов — это вторая половина еврейского 147-го, главы сдвинуты по Септуагинте", "\(psalm147)"))
        }
        if let psalm3 = evidence.psalm3 {
            if psalm3 == 8 {
                return ("en", OurWords.t("последний стих 3-го псалма — восьмой: надписание не нумеруется, счёт масоретский"))
            }
            if let eccl = evidence.ecclesiastes8, eccl == 18 {
                return ("pl", OurWords.t("последний стих 3-го псалма — %s-й, а в Еккл 8 восемнадцать стихов: так делит одна Biblia Warszawska", "\(psalm3)"))
            }
            return ("ua", OurWords.t("последний стих 3-го псалма — %s-й при коротком 9-м: главы масоретские, надписание считается стихом", "\(psalm3)"))
        }
        // Псалтиря немає — переклад з одного Нового Заповіту. Тоді вирішує
        // Рим 16: у масоретської подачі там 27 віршів, у східної — 23-24.
        if let romans = evidence.romans16 {
            return romans >= 26
                ? ("en", OurWords.t("Псалтири нет; в Рим 16 %s стихов — деление как в масоретской подаче", "\(romans)"))
                : ("ru", OurWords.t("Псалтири нет; в Рим 16 %s стихов — деление как в восточной подаче", "\(romans)"))
        }
        return nil
    }

    public static func standard(for module: any TextModule) -> (standardID: String, reason: String)? {
        decide(evidence(for: module))
    }
}

/// Хто якого стандарту дотримується: свої призначення власника, здогадки і
/// таблиця автора — в одному місці.
///
/// Свої призначення лежать окремим файлом у теці підтримки програми, а не
/// в базі старої програми: база чужа, вона всередині чужого застосунку і може бути
/// перезаписана його оновленням. Власник править свій файл, база автора
/// лишається неторканою.
public final class NumberingAssignments: @unchecked Sendable {

    public static let shared = NumberingAssignments()

    /// Що лежить у файлі. Формат навмисно читабельний: лагодиться текстовим
    /// редактором, якщо щось пішло не так перед служінням.
    private struct Stored: Codable {
        var version: Int = 1
        /// Вибір людини: ім'я модуля → «ru», «en», «pl», «ua».
        var assigned: [String: String] = [:]
        /// Здогадки, вже пораховані по книгах. Тримаємо їх, щоб при кожному
        /// запуску заново не розбирати Псалтир у півсотні перекладів.
        var guessed: [String: String] = [:]
        var guessReasons: [String: String] = [:]
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var stored: Stored

    public init(fileURL: URL = NumberingAssignments.defaultFileURL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        } else {
            stored = Stored()
        }
    }

    public static var defaultFileURL: URL {
        DataHome.folder.appendingPathComponent("numbering.json")
    }

    public var storeURL: URL { fileURL }

    // MARK: - Вибір власника

    public func ownerChoice(forModule id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return stored.assigned[id.lowercased()]
    }

    /// Призначити стандарт вручну. `nil` — зняти призначення і повернутися до здогадки.
    @discardableResult
    public func setOwnerChoice(_ standardID: String?, forModule id: String) -> Bool {
        lock.lock()
        if let standardID, !standardID.isEmpty {
            stored.assigned[id.lowercased()] = standardID
        } else {
            stored.assigned.removeValue(forKey: id.lowercased())
        }
        let snapshot = stored
        lock.unlock()
        return write(snapshot)
    }

    /// Забути пораховані здогадки: знадобиться, коли список модулів змінився
    /// або переклад перевстановили.
    @discardableResult
    public func clearGuesses() -> Bool {
        lock.lock()
        stored.guessed.removeAll()
        stored.guessReasons.removeAll()
        let snapshot = stored
        lock.unlock()
        return write(snapshot)
    }

    private func write(_ snapshot: Stored) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return false }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return (try? data.write(to: fileURL, options: .atomic)) != nil
    }

    // MARK: - Розв'язання

    /// Стандарт одного перекладу з усіма поясненнями.
    ///
    /// Може знадобитися розібрати Псалтир — кликати НЕ з головного потоку.
    public func assignment(for module: any TextModule) -> NumberingAssignment {
        let id = module.identifier
        let key = id.lowercased()

        lock.lock()
        let owner = stored.assigned[key]
        let cached = stored.guessed[key]
        let cachedReason = stored.guessReasons[key]
        lock.unlock()

        if let owner {
            return NumberingAssignment(moduleID: id, standardID: owner, source: .owner,
                                       reason: OurWords.t("выбрано в окне «Нумерация переводов»"))
        }
        if let cached {
            return NumberingAssignment(moduleID: id, standardID: cached, source: .guessed,
                                       reason: cachedReason ?? OurWords.t("посчитано по книгам перевода"))
        }
        if let guess = NumberingGuess.standard(for: module) {
            lock.lock()
            stored.guessed[key] = guess.standardID
            stored.guessReasons[key] = guess.reason
            let snapshot = stored
            lock.unlock()
            _ = write(snapshot)
            return NumberingAssignment(moduleID: id, standardID: guess.standardID,
                                       source: .guessed, reason: guess.reason)
        }
        // Таблиця автора — останньою: у ній вісім рядків, і чотири з них
        // числами не підтверджуються. Але для перекладу, про який нам сказати
        // нічого, вона все ж краща за мовчання.
        if let match = authorRow(key) {
            return NumberingAssignment(moduleID: id, standardID: match.value, source: .author,
                                       reason: match.reason)
        }
        return NumberingAssignment(moduleID: id, standardID: "", source: .none,
                                   reason: OurWords.t("по книгам перевода стандарт не опознан"))
    }

    public func assignments(for modules: [any TextModule]) -> [NumberingAssignment] {
        modules.map { assignment(for: $0) }
    }

    /// Порахувати все і віддати рушію. Кличеться один раз при завантаженні
    /// бібліотеки і НЕ з головного потоку: рахує по книгах з диска.
    @discardableResult
    public func apply(to engine: VerseNumbering = .shared, modules: [any TextModule]) -> [NumberingAssignment] {
        let resolved = assignments(for: modules)
        var map: [String: String] = [:]
        for (index, item) in resolved.enumerated() where item.isKnown {
            map[item.moduleID.lowercased()] = item.standardID
            // Коротке ім'я — запасний ключ: в історії і в плані від перекладу
            // лишається лише воно. Якщо два переклади носять одне коротке ім'я,
            // ключ займає перший — інакше стандарт залежав би від порядку тек.
            let short = modules[index].info.shortName.lowercased()
            if !short.isEmpty, map[short] == nil { map[short] = item.standardID }
        }
        engine.load(assignments: map)
        return resolved
    }
}

public extension NumberingAssignments {

    /// Що вже відомо про переклад, без читання книг з диска.
    ///
    /// Потрібно там, де чекати не можна: вікно діагностики і список перекладів
    /// відкриваються в головному потоці, а розбір Псалтиря коштує півсекунди.
    func knownAssignment(forModule id: String) -> NumberingAssignment? {
        let key = id.lowercased()
        if let owner = ownerChoice(forModule: id) {
            return NumberingAssignment(moduleID: id, standardID: owner, source: .owner,
                                       reason: OurWords.t("выбрано в окне «Нумерация переводов»"))
        }
        lock.lock()
        let cached = stored.guessed[key]
        let cachedReason = stored.guessReasons[key]
        lock.unlock()
        if let cached {
            return NumberingAssignment(moduleID: id, standardID: cached, source: .guessed,
                                       reason: cachedReason ?? OurWords.t("посчитано по книгам перевода"))
        }
        if let match = authorRow(key) {
            return NumberingAssignment(moduleID: id, standardID: match.value, source: .author,
                                       reason: match.reason)
        }
        return nil
    }
}

extension NumberingAssignments {

    /// Рядок таблиці автора для цього модуля — точний або з поправкою на
    /// описку в імені (`ua_ogienka` при теці `UA_Ogienko`). Зв'язок за близьким
    /// іменем називається в причині словами: мовчки підміняти ім'я не можна, людина
    /// має право бачити, звідки взявся стандарт.
    func authorRow(_ key: String) -> (value: String, reason: String)? {
        let author = VerseNumbering.shared.authorAssignments
        if let match = author.first(where: { $0.key.lowercased() == key }) {
            return (match.value, OurWords.t("строка «%s» в таблице modules базы нумерации", "\(match.key)"))
        }
        guard let near = ModuleNameMatch.nearest(key, among: author.keys.map { $0.lowercased() }),
              let match = author.first(where: { $0.key.lowercased() == near }) else { return nil }
        return (match.value,
                OurWords.t("строка «%s» в таблице modules базы нумерации — имя связано по близкому", "\(match.key)"))
    }
}

public extension NumberingAssignments {

    /// Віддати рушію те, що вже відомо, нічого не рахуючи заново.
    ///
    /// Диск не читає: годиться там, де чекати не можна — при відкритті вікна
    /// діагностики або списку перекладів. Переклади, про які ще не рахували,
    /// просто лишаться без стандарту і покажуться за своїми номерами.
    @discardableResult
    func applyKnown(to engine: VerseNumbering = .shared, modules: [any TextModule]) -> Int {
        var map: [String: String] = [:]
        for module in modules {
            guard let assignment = knownAssignment(forModule: module.identifier), assignment.isKnown else { continue }
            map[module.identifier.lowercased()] = assignment.standardID
            let short = module.info.shortName.lowercased()
            if !short.isEmpty, map[short] == nil { map[short] = assignment.standardID }
        }
        engine.load(assignments: map)
        return map.count
    }
}
