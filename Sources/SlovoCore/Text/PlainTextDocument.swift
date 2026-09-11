import Foundation

/// Модуль «Текст» (розділ 5.2 посібника): довільний текст, який
/// виводиться на слайд так само, як вірш.
///
/// Полів рівно два, і обидва зайняли готові місця на слайді:
/// заголовок (23) малюється там, де в режимі «Біблія» стоїть адреса місця
/// Писання, а сам текст (25) — там, де стоїть цитата. Тому власного
/// оформлення в документа немає: він віддає готовий `Slide`, а як цей слайд
/// виглядає, вирішує стиль режиму.
///
/// Оформлення в «Тексту» своє, а не біблійне: у `VisioBible.ini` секція
/// `[Text]` — повноцінна пара до `[Bible]`, зі своїм шаблоном
/// (`DefaultScheme=Info default`), своїм фоном, кольорами, контуром і своїми
/// ознаками розбиття (`PageSubDivide=1`, `VersSubDivide=0`). Читати її
/// треба цілком: `SlideStyle(config:section: "Text", dataRoot:)` для вигляду
/// і `Pagination(config:section: "Text")` — для розбиття.
///
/// Модель навмисно нічого не знає про інтерфейс: той самий вміст
/// знадобиться і передпоказу, і проектору, і NDI, і веб-слайдам.
public struct PlainTextDocument: Sendable, Hashable, Codable {

    /// Заголовок тексту (23). На слайді займає місце адреси.
    public var title: String
    /// Довільний текст (25). На слайді займає місце цитати.
    public var body: String

    public init(title: String = "", body: String = "") {
        self.title = title
        self.body = body
    }

    /// Порожній документ — це «показувати нічого», а не порожній слайд:
    /// пробіли і переноси рядків за вміст не вважаємо.
    public var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Кнопка «Очистити текст» (24, `SBClearText`) — посібник вимагає
    /// очищати обидва поля одразу, і текст (25), і заголовок (23).
    public mutating func clear() {
        title = ""
        body = ""
    }

    // MARK: - Приймання тексту з модуля «Біблія»

    /// Куди подіти те, що вже набрано, коли приходить новий текст.
    public enum Reception: String, Sendable, Codable, CaseIterable {
        /// Пункт меню називається «Скопировать во вкладку "Текст"»: копія
        /// заміщує вміст вкладки цілком, як заміщує буфер обміну.
        case replace
        /// Дописати знизу — так із кількох місць збирається одне оголошення.
        case append
    }

    /// Вірш (або кілька віршів) зі списку (4) через контекстне меню
    /// `MICopyToText` — «Скопировать во вкладку "Текст"».
    ///
    /// Адреса йде в заголовок, а не приписується до тексту: заголовок стоїть
    /// на слайді рівно там, де стояла адреса, тому скопійований уривок
    /// виглядає в залі так само, як виглядав із режиму «Біблія».
    public static func scripture(reference: String, text: String) -> PlainTextDocument {
        PlainTextDocument(title: reference, body: text)
    }

    public mutating func receive(reference: String, text: String, mode: Reception = .replace) {
        switch mode {
        case .replace:
            title = reference
            body = text
        case .append:
            if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = reference }
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            body = trimmed.isEmpty ? text : trimmed + "\n" + text
        }
    }

    // MARK: - Підписи в списках

    /// Рядок для «Плану» (10) та «Історії» (11).
    ///
    /// В оригіналі пункт виглядає як «Дорогие! - Настройтесь на …»:
    /// заголовок, тире і початок тексту. Без початку тексту два оголошення з
    /// однаковим заголовком у списку не розрізнити.
    public func summary(limit: Int = 120) -> String {
        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = snippet(limit: limit)
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " - " + tail
    }

    /// Початок тексту одним рядком — переноси рядків у списку не потрібні.
    public func snippet(limit: Int = 120) -> String {
        let flat = body
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    // MARK: - Розбиття довгого тексту на слайди

    /// Як довгий текст лягає на слайди. Це ті самі «Опції роботи» (15),
    /// що й у Біблії, лише читаються з секції `[Text]`: в одного й того самого
    /// користувача розбиття на вірші для Біблії ввімкнено, а для тексту ні.
    public struct Pagination: Sendable, Hashable, Codable {

        /// `PageSubDivide` — «Розбивати на сторінки».
        public var splitsIntoPages: Bool

        /// `VersSubDivide` — «Розбивати на вірші».
        ///
        /// У довільного тексту віршів немає, і одиницею служить рядок,
        /// набраний у полі (25): це єдина межа, яку в цьому
        /// полі розставляє сам оператор.
        public var splitsIntoParagraphs: Bool

        /// `WordWrap` — «Автоперенос слів». У режимі «Біблія» він завжди
        /// ввімкнений і заблокований від зміни, а в «Тексті» його можна
        /// вимкнути — тоді довгий рядок лишається одним рядком слайда
        /// і на частини не ріжеться.
        public var wrapsWords: Bool

        /// Порожній рядок у наборі — розрив, поставлений оператором вручну.
        ///
        /// Враховується лише коли ввімкнено хоч якесь розбиття:
        /// посібник прямо вимагає, щоб за обох вимкнених способів
        /// весь текст ішов на один слайд, яким би дрібним не вийшов шрифт.
        public var blankLineBreaksPage: Bool

        /// Скільки знаків уміщається в рядок слайда за мінімального кегля.
        public var charactersPerLine: Int

        /// Скільки таких рядків уміщається на слайд.
        public var linesPerPage: Int

        /// `percentfillingpage` — «Мінімальний відсоток заповнення для
        /// створення нової сторінки». Хвіст, який заповнить слайд менше
        /// ніж на стільки, окремою сторінкою не робимо: він лишається на
        /// попередній, а шрифт там стає трохи дрібнішим.
        public var minimumFillPercent: Double

        /// Номер сторінки («2/3») у заголовку. За умовчанням вимкнено:
        /// заголовок пише оператор, і дописувати в нього службові цифри,
        /// які побачить зал, програма не повинна.
        public var showsPageNumber: Bool

        public init(splitsIntoPages: Bool = true,
                    splitsIntoParagraphs: Bool = false,
                    wrapsWords: Bool = true,
                    blankLineBreaksPage: Bool = true,
                    charactersPerLine: Int = 21,
                    linesPerPage: Int = 6,
                    minimumFillPercent: Double = 30,
                    showsPageNumber: Bool = false) {
            self.splitsIntoPages = splitsIntoPages
            self.splitsIntoParagraphs = splitsIntoParagraphs
            self.wrapsWords = wrapsWords
            self.blankLineBreaksPage = blankLineBreaksPage
            self.charactersPerLine = max(1, charactersPerLine)
            self.linesPerPage = max(1, linesPerPage)
            self.minimumFillPercent = min(max(minimumFillPercent, 0), 100)
            self.showsPageNumber = showsPageNumber
        }

        /// Налаштування як їх виставив користувач в оригіналі.
        ///
        /// `style` не обов'язковий, але з ним оцінка чесніша: поля та інтерліньяж
        /// беруться з того самого стилю, яким слайд і буде намальовано, а не з
        /// умовчань. Стиль режиму «Текст» збирається з тієї самої секції —
        /// `SlideStyle(config:section:dataRoot:)`.
        public init(config: IniSettings, section: String = "Text", style: SlideStyle? = nil) {
            // Мінімальний кегль в оригіналі записано часткою висоти слайда
            // у відсотках (`fontminsize=11`), як і все інше в стилі:
            // якби рахувати його пунктами на макеті 800×600, на слайд улізло
            // б шість тисяч знаків і розбиття не спрацьовувало б ніколи.
            let minFont = (config.double("fontminsize", in: section) ?? 11) / 100
            let capacity = Pagination.capacity(
                slideWidth: Double(config.int("width", in: "OutScreen") ?? 800),
                slideHeight: Double(config.int("height", in: "OutScreen") ?? 600),
                minFontFraction: minFont,
                lineSpacing: style?.lineSpacing ?? 0.18,
                horizontalInset: style?.horizontalInset ?? 0.06,
                verticalInset: style?.verticalInset ?? 0.06)

            self.init(splitsIntoPages: config.bool("PageSubDivide", in: section) ?? true,
                      splitsIntoParagraphs: config.bool("VersSubDivide", in: section) ?? false,
                      wrapsWords: config.bool("WordWrap", in: section) ?? true,
                      blankLineBreaksPage: true,
                      charactersPerLine: capacity.charactersPerLine,
                      linesPerPage: capacity.linesPerPage,
                      minimumFillPercent: config.double("percentfillingpage", in: "OutScreen") ?? 30,
                      showsPageNumber: false)
        }

        /// Скільки знаків і рядків уміщається на слайд за мінімального кегля.
        ///
        /// Точну відповідь знає лише той, хто малює, — він один міряє
        /// справжній шрифт. Тут потрібна оцінка, і вона береться з геометрії:
        /// середня ширина знака в пропорційного шрифту — приблизно
        /// половина кегля, висота рядка — кегль з інтерліньяжем. На
        /// налаштуваннях користувача (800×600, мінімум 11 %) виходить 21 знак
        /// у рядку і 6 рядків, і це сходиться з картинкою в посібнику:
        /// там оголошення з 63 знаків займає рівно чотири рядки слайда.
        public static func capacity(slideWidth: Double = 800,
                                    slideHeight: Double = 600,
                                    minFontFraction: Double = 0.11,
                                    lineSpacing: Double = 0.18,
                                    horizontalInset: Double = 0.06,
                                    verticalInset: Double = 0.06)
            -> (charactersPerLine: Int, linesPerPage: Int) {

            let font = max(slideHeight * minFontFraction, 1)
            let lineHeight = font * (1 + max(lineSpacing, 0))
            let usableHeight = slideHeight * (1 - 2 * min(max(verticalInset, 0), 0.4))
            let usableWidth = slideWidth * (1 - 2 * min(max(horizontalInset, 0), 0.4))

            return (charactersPerLine: max(8, Int(usableWidth / (font * 0.5))),
                    linesPerPage: max(1, Int(usableHeight / lineHeight)))
        }
    }

    /// Текст, розкладений по сторінках. Кожна сторінка — те, що піде
    /// на один слайд.
    public func pages(_ pagination: Pagination = Pagination()) -> [String] {
        let lines = Self.normalizedLines(body)
        guard !lines.isEmpty else {
            // Заголовок без тексту — теж слайд: у залі видно один рядок
            // на місці адреси. Порожній документ не дає жодної сторінки.
            return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [""]
        }

        let blocks = Self.blocks(of: lines, pagination)
        guard pagination.splitsIntoPages else {
            return blocks.map { $0.joined(separator: "\n") }
        }
        return blocks
            .flatMap { Self.paginate($0, pagination) }
            .map { $0.joined(separator: "\n") }
    }

    /// Готові слайди. Збираються рівно як біблійні: текст на місці
    /// цитати, заголовок на місці адреси.
    public func slides(_ pagination: Pagination = Pagination()) -> [Slide] {
        let texts = pages(pagination)
        guard !texts.isEmpty else { return [] }

        let head = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return texts.enumerated().map { index, text in
            Slide(mainText: text,
                  secondaryTexts: [],
                  reference: reference(head, page: index, of: texts.count, pagination),
                  isBlank: text.isEmpty && head.isEmpty)
        }
    }

    /// Один слайд за номером сторінки — те, що потрібно стрілкам перегортання.
    /// Номер за межами набору не вважається помилкою: він притискається до краю,
    /// бо стрілка на останній сторінці не має гасити екран.
    public func slide(atPage index: Int, _ pagination: Pagination = Pagination()) -> Slide {
        let all = slides(pagination)
        guard !all.isEmpty else { return .blank }
        return all[min(max(index, 0), all.count - 1)]
    }

    public func pageCount(_ pagination: Pagination = Pagination()) -> Int {
        pages(pagination).count
    }

    private func reference(_ head: String, page: Int, of count: Int,
                           _ pagination: Pagination) -> String {
        guard pagination.showsPageNumber, count > 1 else { return head }
        let number = "\(page + 1)/\(count)"
        return head.isEmpty ? number : head + " · " + number
    }

    // MARK: - Розбір набраного тексту

    /// Рядки без хвостових пробілів і без порожніх рядків по краях.
    /// Перенос рядка з Windows (`\r\n`) дає тут одну межу, а не дві.
    ///
    /// Відкрито назовні навмисно: повного Xcode на машині немає, `XCTest` у
    /// Command Line Tools не постачається, і перевірки живуть у консольній цілі
    /// `slovo-scan` (`--text`), а не в тестовій. Через `@testable` їх звідти
    /// не дістати.
    public static func normalizedLines(_ text: String) -> [String] {
        var lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        while lines.first?.isEmpty == true { lines.removeFirst() }
        while lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }

    /// Шматки тексту, які не можна змішувати на одному слайді.
    private static func blocks(of lines: [String], _ pagination: Pagination) -> [[String]] {
        if pagination.splitsIntoParagraphs {
            return lines.filter { !$0.isEmpty }.map { [$0] }
        }
        // Порожній рядок ріже лише за ввімкненого розбиття — інакше
        // посібник вимагає один слайд на весь набраний текст.
        guard pagination.blankLineBreaksPage, pagination.splitsIntoPages else { return [lines] }

        var blocks: [[String]] = [[]]
        for line in lines {
            if line.isEmpty {
                if !blocks[blocks.count - 1].isEmpty { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        blocks.removeAll { $0.isEmpty }
        return blocks
    }

    /// Один шматок, розкладений по сторінках.
    private static func paginate(_ block: [String], _ pagination: Pagination) -> [[String]] {
        let capacity = pagination.linesPerPage
        let budget = capacity * pagination.charactersPerLine

        // Спершу рядки, які самі по собі не влазять у слайд.
        // Посібник: якщо один вірш настільки великий, що не вміщається за
        // мінімального кегля, він розбивається на частини. Тут те саме, але
        // різати має сенс лише за ввімкненого переносу слів: без нього
        // довгий рядок так і лишається одним рядком.
        //
        // `isContinuation` позначає шматки одного розрізаного рядка. Якщо два
        // такі шматки все ж опинилися на одному слайді, між ними потрібен
        // пробіл, а не перенос рядка: інакше посеред фрази стане жорсткий
        // розрив, якого в наборі не було.
        var units: [(text: String, isContinuation: Bool)] = []
        for line in block {
            if displayHeight(line, pagination) <= capacity || !pagination.wrapsWords {
                units.append((line, false))
            } else {
                for (index, chunk) in chunks(of: line, budget: budget).enumerated() {
                    units.append((chunk, index > 0))
                }
            }
        }

        var pages: [[String]] = []
        var current: [String] = []
        var used = 0

        func height(_ lines: [String]) -> Int {
            lines.reduce(0) { $0 + displayHeight($1, pagination) }
        }

        for unit in units {
            let added = displayHeight(unit.text, pagination)
            if !current.isEmpty, used + added > capacity {
                pages.append(current)
                current = []
                used = 0
            }
            if unit.isContinuation, !current.isEmpty {
                current[current.count - 1] += " " + unit.text
            } else {
                current.append(unit.text)
            }
            // Склейка двох шматків в один рядок могла вийти коротшою за суму:
            // висоту сторінки після неї рахуємо заново, а не додаємо.
            used = height(current)
        }
        if !current.isEmpty { pages.append(current) }

        // Хвіст у півтора рядка окремим слайдом виглядає як збій показу,
        // і оригінал такої сторінки не створює — це і є «мінімальний
        // відсоток заповнення».
        if pages.count > 1 {
            let tail = pages[pages.count - 1].reduce(0) { $0 + displayHeight($1, pagination) }
            let fill = Double(tail) / Double(capacity) * 100
            if fill < pagination.minimumFillPercent {
                let last = pages.removeLast()
                pages[pages.count - 1].append(contentsOf: last)
            }
        }
        return pages
    }

    /// Скільки рядків слайда займе один набраний рядок.
    private static func displayHeight(_ line: String, _ pagination: Pagination) -> Int {
        guard pagination.wrapsWords else { return 1 }
        let count = line.count
        guard count > pagination.charactersPerLine else { return 1 }
        return Int((Double(count) / Double(pagination.charactersPerLine)).rounded(.up))
    }

    /// Довгий рядок, розрізаний за межами слів.
    /// Слово, довше за цілий слайд, рубаємо посередині — інакше воно заблокує
    /// розбиття і потягне за собою весь залишок тексту.
    ///
    /// Відкрито назовні з тієї самої причини, що й `normalizedLines`.
    public static func chunks(of line: String, budget: Int) -> [String] {
        let limit = max(1, budget)
        guard line.count > limit else { return [line] }

        var result: [String] = []
        var current = ""

        for word in line.split(separator: " ", omittingEmptySubsequences: true) {
            var piece = String(word)
            while piece.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(String(piece.prefix(limit)))
                piece = String(piece.dropFirst(limit))
            }
            if current.isEmpty {
                current = piece
            } else if current.count + 1 + piece.count <= limit {
                current += " " + piece
            } else {
                result.append(current)
                current = piece
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.isEmpty ? [line] : result
    }
}
