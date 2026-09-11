import Foundation

/// Назви книг для модулів MySword.
///
/// У форматі MySword назв книг НЕМАЄ зовсім: у базі лише наскрізний номер
/// 1…66, а підписи малює сама програма за мовою свого інтерфейсу. Отже,
/// таблицю доводиться тримати в себе.
///
/// Порядок — протестантський канон, той самий, що в `CanonicalBook.canonicalOrder`
/// і в самої MySword: 1 Буття … 39 Малахія, 40 Матвій, 43 Іван, 66 Об'явлення.
/// Узяти готовий список із `ShortBookNames.russianSynodal` не можна: там Новий
/// Заповіт іде синодальним порядком — соборні послання стоять перед посланнями
/// Павла, — і з 45-ї книги підписи роз'їхалися б на десять рядків.
///
/// У скороченнях поруч із російським стоїть латинське. Воно не для показу: за ним
/// `CanonicalBook.number(forAlias:)` і пошук по книзі впізнають книгу так само, як
/// у модулях решти форматів.
public enum MySwordBookNames {

    public struct Entry: Sendable, Hashable {
        public let fullName: String
        /// Перше скорочення показується на кнопці в сітці книг.
        public let shortNames: [String]

        init(_ fullName: String, _ russian: String, _ latin: String) {
            self.fullName = fullName
            self.shortNames = [russian, latin]
        }
    }

    /// 66 книг за номерами MySword: `book(1)` — Буття, `book(66)` — Об'явлення.
    public static let all: [Entry] = [
        Entry("Бытие", "Быт", "Gen"),
        Entry("Исход", "Исх", "Ex"),
        Entry("Левит", "Лев", "Lev"),
        Entry("Числа", "Чис", "Num"),
        Entry("Второзаконие", "Втор", "Deut"),
        Entry("Иисус Навин", "Нав", "Josh"),
        Entry("Судьи", "Суд", "Judg"),
        Entry("Руфь", "Руф", "Ruth"),
        Entry("1 Царств", "1Цар", "1Sam"),
        Entry("2 Царств", "2Цар", "2Sam"),
        Entry("3 Царств", "3Цар", "1King"),
        Entry("4 Царств", "4Цар", "2King"),
        Entry("1 Паралипоменон", "1Пар", "1Chr"),
        Entry("2 Паралипоменон", "2Пар", "2Chr"),
        Entry("Ездра", "Езд", "Ezr"),
        Entry("Неемия", "Неем", "Neh"),
        Entry("Есфирь", "Есф", "Est"),
        Entry("Иов", "Иов", "Job"),
        Entry("Псалтирь", "Пс", "Ps"),
        Entry("Притчи", "Прит", "Prov"),
        Entry("Екклесиаст", "Еккл", "Eccl"),
        Entry("Песня Песней", "Песн", "Song"),
        Entry("Исаия", "Ис", "Isa"),
        Entry("Иеремия", "Иер", "Jer"),
        Entry("Плач Иеремии", "Плач", "Lam"),
        Entry("Иезекииль", "Иез", "Ezek"),
        Entry("Даниил", "Дан", "Dan"),
        Entry("Осия", "Ос", "Hos"),
        Entry("Иоиль", "Иоил", "Joel"),
        Entry("Амос", "Ам", "Amos"),
        Entry("Авдий", "Авд", "Obad"),
        Entry("Иона", "Ион", "Jonah"),
        Entry("Михей", "Мих", "Mic"),
        Entry("Наум", "Наум", "Nah"),
        Entry("Аввакум", "Авв", "Hab"),
        Entry("Софония", "Соф", "Zep"),
        Entry("Аггей", "Агг", "Hag"),
        Entry("Захария", "Зах", "Zec"),
        Entry("Малахия", "Мал", "Mal"),

        Entry("От Матфея", "Мф", "Mt"),
        Entry("От Марка", "Мк", "Mk"),
        Entry("От Луки", "Лк", "Lk"),
        Entry("От Иоанна", "Ин", "Jn"),
        Entry("Деяния", "Деян", "Acts"),
        Entry("Римлянам", "Рим", "Rom"),
        Entry("1 Коринфянам", "1Кор", "1Cor"),
        Entry("2 Коринфянам", "2Кор", "2Cor"),
        Entry("Галатам", "Гал", "Gal"),
        Entry("Ефесянам", "Еф", "Eph"),
        Entry("Филиппийцам", "Флп", "Phil"),
        Entry("Колоссянам", "Кол", "Col"),
        Entry("1 Фессалоникийцам", "1Фес", "1Thes"),
        Entry("2 Фессалоникийцам", "2Фес", "2Thes"),
        Entry("1 Тимофею", "1Тим", "1Tim"),
        Entry("2 Тимофею", "2Тим", "2Tim"),
        Entry("Титу", "Тит", "Tit"),
        Entry("Филимону", "Флм", "Phlm"),
        Entry("Евреям", "Евр", "Heb"),
        Entry("Иакова", "Иак", "Jas"),
        Entry("1 Петра", "1Пет", "1Pet"),
        Entry("2 Петра", "2Пет", "2Pet"),
        Entry("1 Иоанна", "1Ин", "1Jn"),
        Entry("2 Иоанна", "2Ин", "2Jn"),
        Entry("3 Иоанна", "3Ин", "3Jn"),
        Entry("Иуды", "Иуд", "Jude"),
        Entry("Откровение", "Откр", "Rev"),
    ]

    /// Книга за номером MySword (1…66). Поза цим проміжком — `nil`: сама
    /// MySword такі посилання вважає недійсними.
    public static func book(_ number: Int) -> Entry? {
        guard (1...all.count).contains(number) else { return nil }
        return all[number - 1]
    }

    /// Наскрізний номер канону за номером MySword: 1 → 10, 19 → 230, 43 → 500.
    ///
    /// Перерахунок позиційний, без таблиці відповідності: `canonicalOrder` — ті самі
    /// 66 книг у тому самому порядку, тому індекс сходиться один в один.
    public static func canonicalNumber(_ number: Int) -> Int? {
        let order = CanonicalBook.canonicalOrder
        guard (1...order.count).contains(number) else { return nil }
        return order[number - 1]
    }
}
