// =============================================================================
//  OurWords.cs — переклад наших власних написів (з Localization/OurWords.swift)
// =============================================================================

namespace Slovo.Core;

/// Переклад наших власних написів.
///
/// Написи, що є в автора, беруться з його файлів перекладу (`state.text`).
/// Але половина вікон у цій програмі — наші: майстерня веб-слайдів,
/// Конструктор, вікно налаштувань. Їхні написи ми придумали самі, і в автора їх
/// немає — тому при українській мові вони лишалися російськими.
///
/// Словник побудовано від російського рядка: так його видно просто в коді, і
/// додати переклад можна, не заводячи ключів і не переписуючи місць виклику.
/// Чого в словнику немає — лишається як є: пропущений рядок не має
/// перетворюватися на порожнє місце на екрані.
public static partial class OurWords
{
    /// Мова, якою говорити. Ставиться раз при виборі мови.
    public static string Language { get; set; } = "ru";

    public static string T(string russian)
    {
        // Правка людини з вікна «Переклад інтерфейсу» — насамперед:
        // інакше вікно обіцяло б переклад, якого на екрані не видно.
        if (overrides.TryGetValue(russian, out var own) && own.Length > 0) return own;
        if (Language == "ru") return russian;
        if (!Tables.TryGetValue(Language, out var table)) return russian;
        return table.TryGetValue(russian, out var translated) ? translated : russian;
    }

    // ── Правки з вікна «Переклад інтерфейсу» ────────────────────────────────

    /// Секція файла `.lng`, у якій лежать переклади НАШИХ написів.
    ///
    /// Автор перекладав свої форми, і вікно 7.1 знало лише їх. Наші вікна
    /// лишалися тією мовою, що зашита в словник, і перекладач не міг їх
    /// торкнутися. Тепер наші написи йдуть у файл перекладу окремою секцією:
    /// ключ — російський рядок із коду, значення — його переклад.
    public const string SectionName = "Slovo";

    private static Dictionary<string, string> overrides = new(StringComparer.Ordinal);

    /// Що людина переклала сама для поточної мови.
    public static IReadOnlyDictionary<string, string> Overrides => overrides;

    /// Застосувати правки людини для вибраної мови (секція `[Slovo]`).
    public static void ApplyOverrides(IReadOnlyDictionary<string, string> table) =>
        overrides = table.Where(pair => pair.Value.Length > 0)
            .ToDictionary(pair => pair.Key, pair => pair.Value, StringComparer.Ordinal);

    /// Вбудований переклад рядка для мови — без правок людини.
    public static string? BuiltIn(string russian, string code)
    {
        if (code == "ru") return russian;
        return Tables.TryGetValue(code, out var table) && table.TryGetValue(russian, out var value) ? value : null;
    }

    /// Усі наші рядки, відомі словнику, — список для вікна перекладу.
    /// Російський рядок служить і ключем, і «оригіналом».
    public static IReadOnlyList<string> RussianKeys
    {
        get
        {
            var keys = new HashSet<string>(UkrainianPairs.Select(pair => pair.Russian), StringComparer.Ordinal);
            foreach (var table in Tables.Values) keys.UnionWith(table.Keys);
            return keys.OrderBy(key => key, StringComparer.Ordinal).ToList();
        }
    }

    /// Переклад рядка, всередину якого підставляють значення.
    ///
    /// Перекладається ЗРАЗОК, а значення підставляються після перекладу. Місце
    /// підстановки позначено `%s` — так само, як у файлах перекладу самої
    /// старої програми. Значень може бути менше, ніж позначок, і навпаки:
    /// зайве просто не підставиться. Кожна наступна підстановка шукає `%s` з
    /// початку рядка — як на Mac.
    public static string T(string pattern, params string[] values)
    {
        var text = T(pattern);
        foreach (var value in values)
        {
            var place = text.IndexOf("%s", StringComparison.Ordinal);
            if (place < 0) break;
            text = string.Concat(text.AsSpan(0, place), value, text.AsSpan(place + 2));
        }
        return text;
    }

    /// Словники за кодом мови. Українська зашита в код; решта приїжджають
    /// файлами `OurWords/<код>.json` при старті (`Register`).
    private static Dictionary<string, Dictionary<string, string>>? tables;

    private static Dictionary<string, Dictionary<string, string>> Tables =>
        tables ??= new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal)
        {
            ["uk"] = new Dictionary<string, string>(Ukrainian, StringComparer.Ordinal),
        };

    /// Підключити словник мови. Пари мови, що вже були, лишаються; нові
    /// лягають поверх. Порожній переклад не вважається перекладом.
    public static void Register(IReadOnlyDictionary<string, string> table, string code)
    {
        if (!Tables.TryGetValue(code, out var merged))
        {
            merged = new Dictionary<string, string>(StringComparer.Ordinal);
            Tables[code] = merged;
        }
        foreach (var (key, value) in table)
            if (value.Length > 0) merged[key] = value;
    }

    /// Мови словника й число рядків у кожній — перевірці покриття.
    public static IReadOnlyDictionary<string, int> Coverage =>
        Tables.ToDictionary(pair => pair.Key, pair => pair.Value.Count);

    /// Скільки ключів українського словника перекладено на мову `code`.
    public static (int Translated, int Total, IReadOnlyList<string> Missing) Covered(string code)
    {
        var keys = new HashSet<string>(UkrainianPairs.Select(pair => pair.Russian), StringComparer.Ordinal);
        Tables.TryGetValue(code, out var table);
        var missing = keys.Where(key => table == null || !table.ContainsKey(key))
            .OrderBy(key => key, StringComparer.Ordinal).ToList();
        return (keys.Count - missing.Count, keys.Count, missing);
    }

    /// Слова, записані в словник двічі. Повтор не ронить програму, але
    /// лишається опискою: другий переклад того самого слова мовчки пропадає.
    public static IReadOnlyList<string> DuplicateWords
    {
        get
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            var twice = new List<string>();
            foreach (var (key, _) in UkrainianPairs)
                if (!seen.Add(key)) twice.Add(key);
            return twice;
        }
    }

    /// Чи є такий рядок серед РОСІЙСЬКИХ ключів перекладу: якщо він видимий на
    /// екрані при українській мові — переклад не застосувався.
    public static bool HasRussianKey(string text)
    {
        if (Language != "uk") return false;
        if (!Tables.TryGetValue(Language, out var table) || !table.TryGetValue(text, out var translated)) return false;
        return translated != text;
    }
}
