// =============================================================================
//  MySwordBookNames.cs — назви книг для модулів MySword (з Bible/MySwordBookNames.swift)
// =============================================================================

namespace Slovo.Core;

/// Назви книг для модулів MySword.
///
/// У форматі MySword назв книг НЕМАЄ зовсім: у базі лише наскрізний номер
/// 1…66, а підписи малює сама програма. Порядок — протестантський канон, той
/// самий, що в `CanonicalBook.CanonicalOrder`. У скороченнях поруч із
/// російським стоїть латинське: за ним `CanonicalBook.NumberForAlias` і пошук
/// по книзі впізнають книгу так само, як у модулях решти форматів.
public static class MySwordBookNames
{
    public sealed record Entry
    {
        public string FullName { get; }
        /// Перше скорочення показується на кнопці в сітці книг.
        public IReadOnlyList<string> ShortNames { get; }

        internal Entry(string fullName, string russian, string latin)
        {
            FullName = fullName;
            ShortNames = [russian, latin];
        }

        public bool Equals(Entry? other) => other is not null && FullName == other.FullName && ShortNames.SequenceEqual(other.ShortNames);
        public override int GetHashCode() => FullName.GetHashCode();
    }

    /// 66 книг за номерами MySword: `Book(1)` — Буття, `Book(66)` — Об'явлення.
    public static readonly IReadOnlyList<Entry> All =
    [
        new("Бытие", "Быт", "Gen"),
        new("Исход", "Исх", "Ex"),
        new("Левит", "Лев", "Lev"),
        new("Числа", "Чис", "Num"),
        new("Второзаконие", "Втор", "Deut"),
        new("Иисус Навин", "Нав", "Josh"),
        new("Судьи", "Суд", "Judg"),
        new("Руфь", "Руф", "Ruth"),
        new("1 Царств", "1Цар", "1Sam"),
        new("2 Царств", "2Цар", "2Sam"),
        new("3 Царств", "3Цар", "1King"),
        new("4 Царств", "4Цар", "2King"),
        new("1 Паралипоменон", "1Пар", "1Chr"),
        new("2 Паралипоменон", "2Пар", "2Chr"),
        new("Ездра", "Езд", "Ezr"),
        new("Неемия", "Неем", "Neh"),
        new("Есфирь", "Есф", "Est"),
        new("Иов", "Иов", "Job"),
        new("Псалтирь", "Пс", "Ps"),
        new("Притчи", "Прит", "Prov"),
        new("Екклесиаст", "Еккл", "Eccl"),
        new("Песня Песней", "Песн", "Song"),
        new("Исаия", "Ис", "Isa"),
        new("Иеремия", "Иер", "Jer"),
        new("Плач Иеремии", "Плач", "Lam"),
        new("Иезекииль", "Иез", "Ezek"),
        new("Даниил", "Дан", "Dan"),
        new("Осия", "Ос", "Hos"),
        new("Иоиль", "Иоил", "Joel"),
        new("Амос", "Ам", "Amos"),
        new("Авдий", "Авд", "Obad"),
        new("Иона", "Ион", "Jonah"),
        new("Михей", "Мих", "Mic"),
        new("Наум", "Наум", "Nah"),
        new("Аввакум", "Авв", "Hab"),
        new("Софония", "Соф", "Zep"),
        new("Аггей", "Агг", "Hag"),
        new("Захария", "Зах", "Zec"),
        new("Малахия", "Мал", "Mal"),

        new("От Матфея", "Мф", "Mt"),
        new("От Марка", "Мк", "Mk"),
        new("От Луки", "Лк", "Lk"),
        new("От Иоанна", "Ин", "Jn"),
        new("Деяния", "Деян", "Acts"),
        new("Римлянам", "Рим", "Rom"),
        new("1 Коринфянам", "1Кор", "1Cor"),
        new("2 Коринфянам", "2Кор", "2Cor"),
        new("Галатам", "Гал", "Gal"),
        new("Ефесянам", "Еф", "Eph"),
        new("Филиппийцам", "Флп", "Phil"),
        new("Колоссянам", "Кол", "Col"),
        new("1 Фессалоникийцам", "1Фес", "1Thes"),
        new("2 Фессалоникийцам", "2Фес", "2Thes"),
        new("1 Тимофею", "1Тим", "1Tim"),
        new("2 Тимофею", "2Тим", "2Tim"),
        new("Титу", "Тит", "Tit"),
        new("Филимону", "Флм", "Phlm"),
        new("Евреям", "Евр", "Heb"),
        new("Иакова", "Иак", "Jas"),
        new("1 Петра", "1Пет", "1Pet"),
        new("2 Петра", "2Пет", "2Pet"),
        new("1 Иоанна", "1Ин", "1Jn"),
        new("2 Иоанна", "2Ин", "2Jn"),
        new("3 Иоанна", "3Ин", "3Jn"),
        new("Иуды", "Иуд", "Jude"),
        new("Откровение", "Откр", "Rev"),
    ];

    /// Книга за номером MySword (1…66). Поза цим проміжком — `null`.
    public static Entry? Book(int number) => number >= 1 && number <= All.Count ? All[number - 1] : null;

    /// Наскрізний номер канону за номером MySword: 1 → 10, 19 → 230, 43 → 500.
    public static int? CanonicalNumber(int number)
    {
        var order = CanonicalBook.CanonicalOrder;
        return number >= 1 && number <= order.Count ? order[number - 1] : null;
    }
}
