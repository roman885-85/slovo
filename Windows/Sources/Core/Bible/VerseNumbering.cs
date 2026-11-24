// =============================================================================
//  VerseNumbering.cs — переведення адреси між нумераціями перекладів
//  (з Bible/VerseNumbering.swift)
// =============================================================================

namespace Slovo.Core;

/// Стандарт нумерації розділів і віршів, якого дотримується переклад.
///
/// Це не мова і не видавництво: грецький Псалтир іде на розділ попереду
/// єврейського, надписання псалма в одних перекладах вважається віршем, а в
/// інших ні. Таких стандартів одиниці, тому в кожного своє ім'я.
public readonly record struct VerseNumberingStandard(string Id, string Title)
{
    private static readonly Lazy<VerseNumberingStandard> unknown = new(() => new("", OurWords.T("не определён")));

    /// Переклад, про який ми нічого не знаємо. Окреме значення, а не `null`: з
    /// ним трансляція вироджується в тотожність і числа лишаються як є.
    public static VerseNumberingStandard Unknown => unknown.Value;

    public bool IsKnown => Id.Length > 0;
}

/// Шматок адреси в чужій нумерації: один розділ і вірші в ньому.
///
/// Шматків буває кілька: синодальне «Йоіл 2:27-28» — це «Йоіл 2:27» і
/// «Йоіл 3:1». Пара чисел такого не виражає, тому список.
public readonly record struct VerseSpan(int Chapter, IReadOnlyList<int> Verses)
{
    /// Порожній список означає «розділ цілком».
    public bool IsWholeChapter => Verses.Count == 0;

    public bool Equals(VerseSpan other) => Chapter == other.Chapter && Verses.SequenceEqual(other.Verses);
    public override int GetHashCode() => HashCode.Combine(Chapter, Verses.Count);
}

/// Переведення адреси з однієї нумерації в іншу.
///
/// Правила лежать у базі `inconsistencies.sqlite3`: 338 рядків, за якими автор
/// оригіналу лагодив розбіжності. База читається один раз і цілком лягає в
/// пам'ять, бо `Translate` кличуть на кожне натискання стрілки. Поки правила не
/// прочитано (або бази немає), рушій працює вхолосту: віддає ті самі числа.
public sealed class VerseNumbering
{
    public static VerseNumbering Shared { get; } = new();

    // ── Правило ─────────────────────────────────────────────────────────────

    /// Чотири види правил — рівно ті, що розрізняє сама стара програма:
    /// `D` — явна відповідність шматка; `P` — шматок перекладено підряд;
    /// `OC` — зсув номера розділу; `OV` — зсув номера вірша.
    internal enum RuleKind { Explicit, Shifted, ChapterShift, VerseShift }

    internal static string Raw(RuleKind kind) => kind switch
    {
        RuleKind.Explicit => "D",
        RuleKind.Shifted => "P",
        RuleKind.ChapterShift => "OC",
        _ => "OV",
    };

    internal static RuleKind? KindFromRaw(string raw) => raw switch
    {
        "D" => RuleKind.Explicit,
        "P" => RuleKind.Shifted,
        "OC" => RuleKind.ChapterShift,
        "OV" => RuleKind.VerseShift,
        _ => null,
    };

    internal sealed record Rule(RuleKind Kind, int ChapterFrom, int? ChapterFromEnd, int? VerseFrom, int? VerseFromEnd,
                                int? ChapterTo, int? ChapterToEnd, int? VerseTo, int? VerseToEnd, bool IsCorrection)
    {
        /// Ключ єдиності такий самий, як унікальний покажчик у базі.
        public string UniqueKey =>
            $"{Raw(Kind)}|{ChapterFrom}|{(ChapterFromEnd is { } e ? $"{e}" : "")}"
            + $"|{(VerseFrom is { } v ? $"{v}" : "")}|{(VerseFromEnd is { } ve ? $"{ve}" : "")}";
    }

    internal readonly record struct PairKey(string From, string To, int Book);

    /// Розібрана таблиця цілком. Міняється лише заміною на нову.
    internal sealed class Table
    {
        public readonly Dictionary<PairKey, List<Rule>> Rules;
        public readonly Dictionary<string, List<string>> Routes;      // «звідки>куди» → ланцюжок стандартів
        public readonly Dictionary<string, VerseNumberingStandard> Standards;
        public readonly Dictionary<string, string> AuthorAssignments;
        public readonly string? DatabasePath;
        public readonly int RuleCount;
        public readonly int CorrectionCount;

        public Table(Dictionary<PairKey, List<Rule>> rules, Dictionary<string, List<string>> routes,
                     Dictionary<string, VerseNumberingStandard> standards, Dictionary<string, string> authorAssignments,
                     string? databasePath, int ruleCount, int correctionCount)
        {
            Rules = rules;
            Routes = routes;
            Standards = standards;
            AuthorAssignments = authorAssignments;
            DatabasePath = databasePath;
            RuleCount = ruleCount;
            CorrectionCount = correctionCount;
        }

        public static readonly Table Empty = new(new(), new(), new(), new(), null, 0, 0);
    }

    private readonly object gate = new();
    private Table table = Table.Empty;
    private Dictionary<string, string> assignments = new(StringComparer.Ordinal);
    private bool didStartLoading;

    private VerseNumbering() { }

    // ── Завантаження ────────────────────────────────────────────────────────

    /// Прочитати базу у фоні і не чекати. До того як читання закінчиться,
    /// `Translate` віддає ті самі числа — вікно встигає відкритися.
    public void Prepare(string? databasePath = null)
    {
        lock (gate)
        {
            if (didStartLoading) return;
            didStartLoading = true;
        }
        Task.Run(() => LoadRules(databasePath));
    }

    /// Прочитати базу просто тут. Кликати НЕ з головного потоку.
    public bool LoadRules(string? databasePath = null)
    {
        var located = databasePath ?? LocateDatabase();
        var rows = new List<(PairKey Key, Rule Rule)>();
        var standards = new Dictionary<string, VerseNumberingStandard>(StringComparer.Ordinal);
        var author = new Dictionary<string, string>(StringComparer.Ordinal);
        string? path = null;

        if (located != null && SqliteAccess.OpenReadOnly(located) is { } handle)
        {
            using (handle)
            {
                path = located;
                rows = ReadRules(handle);
                standards = ReadStandards(handle);
                author = ReadAuthorAssignments(handle);
            }
        }

        // Поправки кладемо поверх прочитаного, але не затираючи автора.
        var applied = AddCorrections(rows);

        var byPair = Group(rows);
        var built = new Table(byPair, BuildRoutes(byPair.Keys),
                              standards.Count == 0 ? new Dictionary<string, VerseNumberingStandard>(BuiltInStandards) : standards,
                              author, path, rows.Count, applied);
        lock (gate)
        {
            table = built;
            didStartLoading = true;
        }
        return rows.Count > 0;
    }

    private static int AddCorrections(List<(PairKey Key, Rule Rule)> rows)
    {
        var known = new HashSet<string>(rows.Select(row => $"{row.Key.From}|{row.Key.To}|{row.Key.Book}|{row.Rule.UniqueKey}"),
                                        StringComparer.Ordinal);
        var applied = 0;
        foreach (var (key, rule) in Corrections.Rows)
        {
            if (known.Contains($"{key.From}|{key.To}|{key.Book}|{rule.UniqueKey}")) continue;
            rows.Add((key, rule));
            applied += 1;
        }
        return applied;
    }

    private static Dictionary<PairKey, List<Rule>> Group(List<(PairKey Key, Rule Rule)> rows)
    {
        var byPair = new Dictionary<PairKey, List<Rule>>();
        foreach (var (key, rule) in rows)
        {
            if (!byPair.TryGetValue(key, out var list)) byPair[key] = list = new List<Rule>();
            list.Add(rule);
        }
        return byPair;
    }

    /// Рушій поверх правил, які зараз у руках, — наприклад правлених у вікні
    /// і ще не записаних у базу. Арифметика одна на всю програму: вікно
    /// «Редактор невідповідностей» рахує тим самим рушієм, що й слайд.
    public static VerseNumbering Over(IReadOnlyList<NumberingRule> rules, IReadOnlyList<NumberingStandard>? standards = null)
    {
        var rows = rules.Select(rule => (new PairKey(rule.From, rule.To, rule.Book),
                                         new Rule(KindFromRaw(rule.Kind.RawValue()) ?? RuleKind.Explicit,
                                                  rule.ChapterBegin, rule.ChapterEnd, rule.VerseBegin, rule.VerseEnd,
                                                  rule.ChapterTo, rule.ChapterToEnd, rule.VerseTo, rule.VerseToEnd,
                                                  false))).ToList();
        var applied = AddCorrections(rows);
        var byPair = Group(rows);

        var named = new Dictionary<string, VerseNumberingStandard>(StringComparer.Ordinal);
        foreach (var item in standards ?? Array.Empty<NumberingStandard>())
            named[item.Code] = new VerseNumberingStandard(item.Code, item.Description);

        var engine = new VerseNumbering();
        engine.table = new Table(byPair, BuildRoutes(byPair.Keys),
                                 named.Count == 0 ? new Dictionary<string, VerseNumberingStandard>(BuiltInStandards) : named,
                                 new Dictionary<string, string>(), null, rows.Count, applied);
        engine.didStartLoading = true;
        return engine;
    }

    /// Розкласти в пам'яті відповідність «переклад → стандарт». Ключами годяться
    /// і ім'я теки модуля, і його коротке ім'я. Регістр не важливий.
    public void Load(IReadOnlyDictionary<string, string> assignments)
    {
        var folded = new Dictionary<string, string>(assignments.Count, StringComparer.Ordinal);
        foreach (var (key, value) in assignments) folded[key.ToLowerInvariant()] = value;
        lock (gate) this.assignments = folded;
    }

    // ── Що зараз у пам'яті ──────────────────────────────────────────────────

    private Table Snapshot
    {
        get { lock (gate) return table; }
    }

    /// Правила прочитано і трансляція щось уміє.
    public bool IsReady => Snapshot.RuleCount > 0;
    public int RuleCount => Snapshot.RuleCount;
    public int CorrectionCount => Snapshot.CorrectionCount;
    public string? DatabasePath => Snapshot.DatabasePath;
    /// Стандарти в тому вигляді, в якому їх показувати людині.
    public IReadOnlyList<VerseNumberingStandard> Standards =>
        Snapshot.Standards.Values.OrderBy(standard => standard.Id, StringComparer.Ordinal).ToList();
    /// Призначення з таблиці `modules` самої старої програми — як є, без правки.
    public IReadOnlyDictionary<string, string> AuthorAssignments => Snapshot.AuthorAssignments;

    /// `standard(id:)`.
    public VerseNumberingStandard Standard(string id) =>
        Snapshot.Standards.TryGetValue(id, out var known) ? known
        : BuiltInStandards.TryGetValue(id, out var builtIn) ? builtIn
        : VerseNumberingStandard.Unknown;

    // ── Стандарт перекладу ──────────────────────────────────────────────────

    /// Стандарт перекладу (`standard(of:)`). Лише читання з пам'яті.
    public VerseNumberingStandard StandardOf(TextModule module)
    {
        var snapshot = Snapshot;
        string? byId, byShort = null;
        lock (gate)
        {
            byId = assignments.GetValueOrDefault(module.Identifier.ToLowerInvariant());
            if (byId == null) byShort = assignments.GetValueOrDefault(module.Info.ShortName.ToLowerInvariant());
        }
        if ((byId ?? byShort) is not { } id) return VerseNumberingStandard.Unknown;
        return snapshot.Standards.TryGetValue(id, out var known) ? known
            : BuiltInStandards.TryGetValue(id, out var builtIn) ? builtIn
            : VerseNumberingStandard.Unknown;
    }

    /// `standard(ofModule:)`.
    public VerseNumberingStandard StandardOfModule(string id) => Lookup(id);

    /// Запасний шлях для історії: там від перекладу лишилося лише коротке ім'я.
    public VerseNumberingStandard StandardOfModuleShortName(string name) => Lookup(name);

    private VerseNumberingStandard Lookup(string key)
    {
        var snapshot = Snapshot;
        string? id;
        lock (gate) id = assignments.GetValueOrDefault(key.ToLowerInvariant());
        if (id == null) return VerseNumberingStandard.Unknown;
        return snapshot.Standards.TryGetValue(id, out var known) ? known
            : BuiltInStandards.TryGetValue(id, out var builtIn) ? builtIn
            : VerseNumberingStandard.Unknown;
    }

    // ── Трансляція ──────────────────────────────────────────────────────────

    /// Переводити нічого: стандарти збігаються, один із них невідомий або
    /// дороги між ними в таблиці немає.
    public bool IsIdentity(VerseNumberingStandard from, VerseNumberingStandard to)
    {
        if (!from.IsKnown || !to.IsKnown || from.Id == to.Id) return true;
        return !Snapshot.Routes.ContainsKey($"{from.Id}>{to.Id}");
    }

    /// Переведення адреси. `book` — наскрізний номер канону (`CanonicalBook`).
    ///
    /// Відповідь упорядкована за зростанням. Одному віршу зліва може відповідати
    /// кілька справа (грецький Пс 12:6 це єврейські 13:5 і 13:6) і навпаки.
    /// `verseCount` — скільки віршів у розділі ЦІЛЬОВОГО перекладу: потрібен
    /// правилу `D`, відрізок якого переходить межу розділу.
    public List<VerseSpan> Translate(int book, int chapter, IReadOnlyList<int> verses,
                                     VerseNumberingStandard from, VerseNumberingStandard to,
                                     Func<int, int?>? verseCount = null)
    {
        if (IsIdentity(from, to)) return [new VerseSpan(chapter, verses.ToList())];
        var snapshot = Snapshot;
        if (!snapshot.Routes.TryGetValue($"{from.Id}>{to.Id}", out var route))
            return [new VerseSpan(chapter, verses.ToList())];

        // Розділ цілком: номери віршів не задано, отже правилам D і P зачепитися
        // нема за що. Рухаємо лише номер розділу — цього вистачає для Псалтиря.
        if (verses.Count == 0)
        {
            var currentChapter = chapter;
            for (var step = 0; step < route.Count - 1; step++)
                currentChapter = ChapterOnly(book, currentChapter, route[step], route[step + 1], snapshot);
            return [new VerseSpan(currentChapter, Array.Empty<int>())];
        }

        var current = verses.Select(verse => (chapter, verse)).ToList();
        for (var step = 0; step < route.Count - 1; step++)
        {
            var isLast = step == route.Count - 2;
            var next = new List<(int, int)>();
            foreach (var (c, v) in current)
                next.AddRange(TranslateStep(book, c, v, route[step], route[step + 1], snapshot, isLast ? verseCount : null));
            current = Unique(next);
        }
        return Spans(current);
    }

    /// Те саме для одного вірша.
    public List<(int Chapter, int Verse)> TranslateVerse(int book, int chapter, int verse,
                                                         VerseNumberingStandard from, VerseNumberingStandard to,
                                                         Func<int, int?>? verseCount = null) =>
        Translate(book, chapter, [verse], from, to, verseCount)
            .SelectMany(span => span.Verses.Select(v => (span.Chapter, v))).ToList();

    /// Книга з модуля: для правил годиться лише наскрізний номер канону.
    /// Немає його — переводити нічого: показуємо ті самі числа.
    public List<VerseSpan> Translate(BookInfo book, int chapter, IReadOnlyList<int> verses,
                                     VerseNumberingStandard from, VerseNumberingStandard to,
                                     Func<int, int?>? verseCount = null)
    {
        if (book.CanonicalNumber is not { } number) return [new VerseSpan(chapter, verses.ToList())];
        return Translate(number, chapter, verses, from, to, verseCount);
    }

    /// Яким правилом отримано відповідь — для вікна редактора і самоперевірки.
    public string Trace(int book, int chapter, int verse, VerseNumberingStandard from, VerseNumberingStandard to)
    {
        if (IsIdentity(from, to)) return OurWords.T("стандарты совпадают");
        var snapshot = Snapshot;
        if (!snapshot.Routes.TryGetValue($"{from.Id}>{to.Id}", out var route)) return OurWords.T("дороги нет");
        var parts = new List<string>();
        var current = new List<(int, int)> { (chapter, verse) };
        for (var step = 0; step < route.Count - 1; step++)
        {
            var rules = snapshot.Rules.GetValueOrDefault(new PairKey(route[step], route[step + 1], book)) ?? new List<Rule>();
            var kinds = new List<string>();
            foreach (var (c, v) in current)
            {
                if (rules.FirstOrDefault(rule => rule.Kind == RuleKind.Explicit && Matches(rule, c, v)) is { } d)
                    kinds.Add(d.IsCorrection ? "D (поправка)" : "D");
                else if (rules.FirstOrDefault(rule => rule.Kind == RuleKind.Shifted && Matches(rule, c, v)) is { } p)
                    kinds.Add(p.IsCorrection ? "P (поправка)" : "P");
                else
                {
                    var both = new List<string>();
                    if (rules.Any(rule => rule.Kind == RuleKind.ChapterShift && Matches(rule, c, v))) both.Add("OC");
                    if (rules.Any(rule => rule.Kind == RuleKind.VerseShift && Matches(rule, c, v))) both.Add("OV");
                    kinds.Add(both.Count == 0 ? OurWords.T("без правил") : string.Join("+", both));
                }
            }
            parts.Add($"{route[step]}→{route[step + 1]}: {string.Join(", ", kinds)}");
            var next = new List<(int, int)>();
            foreach (var (c, v) in current)
                next.AddRange(TranslateStep(book, c, v, route[step], route[step + 1], snapshot, null));
            current = Unique(next);
        }
        return string.Join("; ", parts);
    }

    // ── Один крок ланцюжка ──────────────────────────────────────────────────

    private List<(int, int)> TranslateStep(int book, int chapter, int verse, string from, string to, Table snapshot,
                                           Func<int, int?>? verseCount)
    {
        if (!snapshot.Rules.TryGetValue(new PairKey(from, to, book), out var rules)) return [(chapter, verse)];

        // 1. D — явна відповідність. Відповідь уже в чужій нумерації, зсуви OC і
        //    OV до неї не додаються (ru Пс 12:6 це en Пс 13:5-6, а не 13:4-5).
        foreach (var rule in rules)
        {
            if (rule.Kind != RuleKind.Explicit || !Matches(rule, chapter, verse)) continue;
            return ExplicitAnswer(rule, chapter, verseCount);
        }

        // 2. P — шматок перекладено підряд. Теж абсолютна відповідь: на ru Пс 113:9
        //    сходяться P і OC, і правильну відповідь en Пс 115:1 дає лише P.
        foreach (var rule in rules)
        {
            if (rule.Kind != RuleKind.Shifted || !Matches(rule, chapter, verse)) continue;
            var chapterTo = chapter + ((rule.ChapterTo ?? rule.ChapterFrom) - rule.ChapterFrom);
            var verseTo = verse + ((rule.VerseTo ?? 0) - (rule.VerseFrom ?? 0));
            return [(chapterTo, verseTo)];
        }

        // 3. Зсуви розділу і вірша незалежні й додаються: грецький Пс 11:2 —
        //    єврейський Пс 12:1, розділ на одиницю вперед, вірш на одиницю назад.
        var chapterOut = chapter;
        var verseOut = verse;
        if (rules.FirstOrDefault(rule => rule.Kind == RuleKind.ChapterShift && Matches(rule, chapter, verse)) is { } oc)
            chapterOut += oc.ChapterTo ?? 0;
        if (rules.FirstOrDefault(rule => rule.Kind == RuleKind.VerseShift && Matches(rule, chapter, verse)) is { } ov)
            verseOut += ov.VerseTo ?? 0;
        return [(chapterOut, verseOut)];
    }

    /// Відповідь правила `D`. Вона буває відрізком, і відрізок буває через межу розділу.
    private static List<(int, int)> ExplicitAnswer(Rule rule, int chapter, Func<int, int?>? verseCount)
    {
        // Розділ-ціль задано зсувом, а не числом.
        var shift = chapter - rule.ChapterFrom;
        var first = (rule.ChapterTo ?? rule.ChapterFrom) + shift;
        var last = (rule.ChapterToEnd ?? rule.ChapterTo ?? rule.ChapterFrom) + shift;
        var fromVerse = rule.VerseTo ?? 1;
        var toVerse = rule.VerseToEnd ?? fromVerse;

        if (first >= last)
            return Range(Math.Min(fromVerse, toVerse), Math.Max(fromVerse, toVerse)).Select(v => (first, v)).ToList();

        var answer = new List<(int, int)>();
        var tail = verseCount?.Invoke(first) ?? fromVerse;
        answer.AddRange(Range(fromVerse, Math.Max(fromVerse, tail)).Select(v => (first, v)));
        if (last > first + 1)
        {
            for (var middle = first + 1; middle < last; middle++)
            {
                var count = verseCount?.Invoke(middle) ?? 1;
                answer.AddRange(Range(1, Math.Max(1, count)).Select(v => (middle, v)));
            }
        }
        answer.AddRange(Range(1, Math.Max(1, toVerse)).Select(v => (last, v)));
        return answer;
    }

    /// Замкнений проміжок `low...high` Swift.
    private static IEnumerable<int> Range(int low, int high) => Enumerable.Range(low, high - low + 1);

    /// Хід по розділу без віршів — працюють лише зсуви розділів.
    private static int ChapterOnly(int book, int chapter, string from, string to, Table snapshot)
    {
        if (!snapshot.Rules.TryGetValue(new PairKey(from, to, book), out var rules)) return chapter;
        var rule = rules.FirstOrDefault(candidate => candidate.Kind == RuleKind.ChapterShift && CoversChapter(candidate, chapter));
        return rule == null ? chapter : chapter + (rule.ChapterTo ?? 0);
    }

    private static bool CoversChapter(Rule rule, int chapter) =>
        chapter >= rule.ChapterFrom && chapter <= (rule.ChapterFromEnd ?? rule.ChapterFrom);

    /// Чи підходить правило адресі. Порожня клітинка і NULL у базі означають
    /// «немає значення», і означають вони різне для різних видів: у `D`
    /// порожній `verse_from_end` — «рівно один вірш», у `P` і `OV` — «до кінця розділу».
    private static bool Matches(Rule rule, int chapter, int verse)
    {
        if (!CoversChapter(rule, chapter)) return false;
        switch (rule.Kind)
        {
            case RuleKind.ChapterShift:
                return true;
            case RuleKind.Explicit:
            {
                if (rule.VerseFrom is not { } low) return false;
                var high = rule.VerseFromEnd ?? low;
                return verse >= low && verse <= high;
            }
            default:
            {
                var low = rule.VerseFrom ?? 1;
                if (verse < low) return false;
                return rule.VerseFromEnd is not { } high || verse <= high;
            }
        }
    }

    private static List<(int, int)> Unique(List<(int, int)> addresses)
    {
        var seen = new HashSet<long>();
        var result = new List<(int, int)>();
        foreach (var address in addresses)
            if (seen.Add(unchecked((long)address.Item1 * 100_000 + address.Item2))) result.Add(address);
        return result;
    }

    private static List<VerseSpan> Spans(List<(int, int)> addresses)
    {
        var byChapter = new Dictionary<int, List<int>>();
        foreach (var (chapter, verse) in addresses)
        {
            if (!byChapter.TryGetValue(chapter, out var list)) byChapter[chapter] = list = new List<int>();
            list.Add(verse);
        }
        return byChapter.Keys.OrderBy(key => key)
            .Select(key => new VerseSpan(key, byChapter[key].OrderBy(v => v).ToList())).ToList();
    }

    // ── Дороги між стандартами ──────────────────────────────────────────────

    /// Прямих переведень у базі лише три: ru↔en, en↔pl, ru↔ua. Решту доводиться
    /// вести ланцюжком ua — ru — en — pl (пошук ушир, сусіди — за абеткою).
    internal static Dictionary<string, List<string>> BuildRoutes(IEnumerable<PairKey> keys)
    {
        var neighbours = new Dictionary<string, HashSet<string>>(StringComparer.Ordinal);
        var nodes = new HashSet<string>(StringComparer.Ordinal);
        foreach (var key in keys)
        {
            if (!neighbours.TryGetValue(key.From, out var set)) neighbours[key.From] = set = new HashSet<string>(StringComparer.Ordinal);
            set.Add(key.To);
            nodes.Add(key.From);
            nodes.Add(key.To);
        }
        var routes = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var start in nodes)
        {
            var queue = new Queue<List<string>>();
            queue.Enqueue([start]);
            var visited = new HashSet<string>(StringComparer.Ordinal) { start };
            while (queue.Count > 0)
            {
                var path = queue.Dequeue();
                var last = path[^1];
                if (path.Count > 1) routes[$"{start}>{last}"] = path;
                var next = neighbours.TryGetValue(last, out var around) ? around : new HashSet<string>();
                foreach (var node in next.OrderBy(name => name, StringComparer.Ordinal))
                {
                    if (!visited.Add(node)) continue;
                    queue.Enqueue([.. path, node]);
                }
            }
        }
        return routes;
    }

    // ── Читання бази ────────────────────────────────────────────────────────

    /// Де шукати базу правил: спершу умовчання програми (на Mac — пакет), потім
    /// особиста тека. Установлену стару програму не перевіряємо.
    public static string? LocateDatabase()
    {
        string[] candidates =
        [
            Path.Combine(DataHome.BundleData, "inconsistencies.sqlite3"),
            Path.Combine(DataHome.Folder, "inconsistencies.sqlite3"),
        ];
        return candidates.FirstOrDefault(SwiftPath.Exists);
    }

    /// Число з клітинки. NULL і порожній рядок — одне «немає значення»: сама
    /// стара програма у запитах пише `= '' or is null` і різниці не робить.
    private static int? Number(Microsoft.Data.Sqlite.SqliteDataReader row, int index)
    {
        if (SqliteAccess.Text(row, index) is not { } raw) return null;
        var text = raw.TrimWhitespaces();
        return text.Length == 0 ? null : SwiftText.ParseInt(text);
    }

    private static List<(PairKey, Rule)> ReadRules(Microsoft.Data.Sqlite.SqliteConnection handle)
    {
        const string sql = """
            SELECT lng_from, lng_to, type, book_from,
                   chapter_from_begin, chapter_from_end, verse_from_begin, verse_from_end,
                   chapter_to_begin, chapter_to_end, verse_to_begin, verse_to_end
            FROM bibletrans
            """;
        var rows = new List<(PairKey, Rule)>();
        SqliteAccess.Each(handle, sql, row =>
        {
            if (SqliteAccess.Text(row, 0) is not { } from || SqliteAccess.Text(row, 1) is not { } to
                || SqliteAccess.Text(row, 2) is not { } type || KindFromRaw(type.TrimWhitespaces()) is not { } kind
                || Number(row, 3) is not { } book || Number(row, 4) is not { } chapterFrom) return;
            var rule = new Rule(kind, chapterFrom, Number(row, 5), Number(row, 6), Number(row, 7),
                                Number(row, 8), Number(row, 9), Number(row, 10), Number(row, 11), false);
            rows.Add((new PairKey(from, to, book), rule));
        });
        return rows;
    }

    private static Dictionary<string, VerseNumberingStandard> ReadStandards(Microsoft.Data.Sqlite.SqliteConnection handle)
    {
        var result = new Dictionary<string, VerseNumberingStandard>(StringComparer.Ordinal);
        SqliteAccess.Each(handle, "SELECT lng, description FROM t_info", row =>
        {
            if (SqliteAccess.Text(row, 0) is not { } id) return;
            var description = SqliteAccess.Text(row, 1) ?? "";
            // Свої назви в чотирьох відомих стандартів важливіші за авторські:
            // у `t_info` приклади перекладів переставлено місцями.
            result[id] = BuiltInStandards.TryGetValue(id, out var builtIn) ? builtIn : new VerseNumberingStandard(id, description);
        });
        return result;
    }

    private static Dictionary<string, string> ReadAuthorAssignments(Microsoft.Data.Sqlite.SqliteConnection handle)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        SqliteAccess.Each(handle, "SELECT name, lng FROM modules", row =>
        {
            if (SqliteAccess.Text(row, 0) is not { } name || SqliteAccess.Text(row, 1) is not { } lng) return;
            result[name] = lng;
        });
        return result;
    }

    private static readonly Lazy<Dictionary<string, VerseNumberingStandard>> builtInStandards = new(() =>
        new Dictionary<string, VerseNumberingStandard>(StringComparer.Ordinal)
        {
            ["ru"] = new("ru", OurWords.T("Восточный, по Септуагинте (Синодальный)")),
            ["en"] = new("en", OurWords.T("Западный, масоретский (King James)")),
            ["pl"] = new("pl", "Польский (Biblia Warszawska)"),
            ["ua"] = new("ua", "Украинский"),
        });

    /// Назви стандартів словами. Потрібні й без бази.
    internal static IReadOnlyDictionary<string, VerseNumberingStandard> BuiltInStandards => builtInStandards.Value;

    // ── Поправки до бази автора ─────────────────────────────────────────────

    /// Діри в базі старої програми, які видно за справжнім текстом модулів.
    /// Базу автора ми не чіпаємо: рядки додаються поверх неї при читанні і
    /// поступаються дорогою, якщо автор колись допише те саме місце сам. Кожен
    /// рядок перевірено звіркою двох справжніх перекладів.
    internal static class Corrections
    {
        private static (PairKey, Rule) Row(string from, string to, RuleKind kind, int book,
                                           int cfb, int? cfe, int? vfb, int? vfe,
                                           int? ctb, int? cte, int? vtb, int? vte) =>
            (new PairKey(from, to, book), new Rule(kind, cfb, cfe, vfb, vfe, ctb, cte, vtb, vte, true));

        private const RuleKind D = RuleKind.Explicit;
        private const RuleKind P = RuleKind.Shifted;
        private const RuleKind OV = RuleKind.VerseShift;

        public static readonly IReadOnlyList<(PairKey Key, Rule Rule)> Rows =
        [
            // ── Пс 35: випала рівно одна половина пари ──────────────────────
            // Синодальний Пс 35:2 — це KJV Пс 36:1; без цього рядка правила дають 36:2.
            Row("ru", "en", OV, 230, 35, null, 2, null, null, null, -1, null),

            // ── Числа 29/30 ─────────────────────────────────────────────────
            // Синодальне Чис 30:1 — це KJV Чис 29:40. У bw (pl) та сама межа, що в ru.
            Row("ru", "en", D, 40, 30, null, 1, null, 29, null, 40, null),
            Row("ru", "en", OV, 40, 30, 30, 2, null, null, null, -1, null),
            Row("en", "ru", D, 40, 29, null, 40, null, 30, null, 1, null),
            Row("en", "ru", OV, 40, 30, 30, 1, null, null, null, 1, null),
            Row("pl", "en", D, 40, 30, null, 1, null, 29, null, 40, null),
            Row("pl", "en", OV, 40, 30, 30, 2, null, null, null, -1, null),
            Row("en", "pl", D, 40, 29, null, 40, null, 30, null, 1, null),
            Row("en", "pl", OV, 40, 30, 30, 1, null, null, null, 1, null),

            // ── Числа 16/17 у Biblia Warszawska ─────────────────────────────
            Row("en", "pl", P, 40, 16, null, 36, null, 17, null, 1, null),
            Row("en", "pl", P, 40, 17, null, 1, null, 17, null, 16, null),
            Row("pl", "en", P, 40, 17, null, 1, 15, 16, null, 36, null),
            Row("pl", "en", P, 40, 17, null, 16, null, 17, null, 1, null),

            // ── Екклезіаст 4/5 ──────────────────────────────────────────────
            // Синодальне Еккл 4:17 «Наблюдай за ногою твоею…» — це KJV Еккл 5:1.
            Row("ru", "en", D, 250, 4, null, 17, null, 5, null, 1, null),
            Row("ru", "en", OV, 250, 5, 5, 1, null, null, null, 1, null),
            Row("en", "ru", D, 250, 5, null, 1, null, 4, null, 17, null),
            Row("en", "ru", OV, 250, 5, 5, 2, null, null, null, -1, null),
            Row("pl", "en", D, 250, 4, null, 17, null, 5, null, 1, null),
            Row("pl", "en", OV, 250, 5, 5, 1, null, null, null, 1, null),
            Row("en", "pl", D, 250, 5, null, 1, null, 4, null, 17, null),
            Row("en", "pl", OV, 250, 5, 5, 2, null, null, null, -1, null),

            // ── Осія 1/2 у Biblia Warszawska ────────────────────────────────
            Row("en", "pl", P, 350, 1, null, 10, null, 2, null, 1, null),
            Row("en", "pl", P, 350, 2, null, 1, null, 2, null, 3, null),
            Row("pl", "en", P, 350, 2, null, 1, 2, 1, null, 10, null),
            Row("pl", "en", P, 350, 2, null, 3, null, 2, null, 1, null),

            // ── Дії 19 ──────────────────────────────────────────────────────
            // KJV 19:41 входить у Синодальний 19:40. У bw, як і в ru, сорок віршів.
            Row("ru", "en", D, 510, 19, null, 40, null, 19, null, 40, 41),
            Row("en", "ru", D, 510, 19, null, 40, 41, 19, null, 40, null),
            Row("pl", "en", D, 510, 19, null, 40, null, 19, null, 40, 41),
            Row("en", "pl", D, 510, 19, null, 40, 41, 19, null, 40, null),

            // ── Йоіл: в українських перекладів книга з чотирьох розділів ────
            Row("ru", "ua", P, 360, 2, null, 28, 32, 3, null, 1, null),
            Row("ru", "ua", P, 360, 3, null, 1, null, 4, null, 1, null),
            Row("ua", "ru", P, 360, 3, null, 1, 5, 2, null, 28, null),
            Row("ua", "ru", P, 360, 4, null, 1, null, 3, null, 1, null),

            // ── Малахія: в українських перекладів книга з трьох розділів ────
            Row("ru", "ua", P, 460, 4, null, 1, null, 3, null, 19, null),
            Row("ua", "ru", P, 460, 3, null, 19, 24, 4, null, 1, null),

            // ── 3 Царів 4/5 ─────────────────────────────────────────────────
            Row("ru", "ua", P, 110, 4, null, 21, null, 5, null, 1, null),
            Row("ru", "ua", P, 110, 5, null, 1, null, 5, null, 15, null),
            Row("ua", "ru", P, 110, 5, null, 1, 14, 4, null, 21, null),
            Row("ua", "ru", P, 110, 5, null, 15, null, 5, null, 1, null),
        ];
    }

    // ── Готова відповідь для показу поруч двох перекладів ───────────────────

    /// Та сама адреса в іншому перекладі, вже перевірена за його розібраними
    /// розділами. Порожня відповідь означає «місця немає» — так буває чесно:
    /// Пс 151 Септуагінти в єврейському рахунку відповідності не має.
    public List<VerseSpan> ExistingSpans(BookInfo book, int chapter, IReadOnlyList<int> verses,
                                         VerseNumberingStandard from, TextModule to, IReadOnlyList<Chapter> chapters)
    {
        var target = StandardOf(to);
        if (IsIdentity(from, target)) return KeepExisting([new VerseSpan(chapter, verses.ToList())], chapters);
        int? Counted(int number) => chapters.FirstOrDefault(c => c.Number == number)?.Verses.Count;
        var translated = Translate(book, chapter, verses, from, target, Counted);
        return KeepExisting(translated, chapters);
    }

    private static List<VerseSpan> KeepExisting(List<VerseSpan> spans, IReadOnlyList<Chapter> chapters)
    {
        var result = new List<VerseSpan>();
        foreach (var span in spans)
        {
            var chapter = chapters.FirstOrDefault(c => c.Number == span.Chapter);
            if (chapter == null) continue;
            if (span.Verses.Count == 0)
            {
                result.Add(span);
                continue;
            }
            var existing = span.Verses.Where(number => chapter.Verses.Any(verse => verse.Number == number)).ToList();
            if (existing.Count > 0) result.Add(new VerseSpan(span.Chapter, existing));
        }
        return result;
    }

    /// Зіткнення правил: адреси, накриті двома правилами одного виду.
    public List<string> DuplicateRules(int book, IReadOnlyDictionary<int, int> chapterLengths,
                                       VerseNumberingStandard from, VerseNumberingStandard to)
    {
        if (!Snapshot.Rules.TryGetValue(new PairKey(from.Id, to.Id, book), out var rules)) return new List<string>();
        var found = new List<string>();
        foreach (var (chapter, length) in chapterLengths.OrderBy(pair => pair.Key))
        {
            for (var verse = 1; verse <= Math.Max(1, length); verse++)
            {
                foreach (var kind in new[] { RuleKind.Explicit, RuleKind.Shifted, RuleKind.ChapterShift, RuleKind.VerseShift })
                {
                    var hits = rules.Count(rule => rule.Kind == kind && Matches(rule, chapter, verse));
                    if (hits > 1)
                        found.Add($"{from.Id}→{to.Id} книга {book} {chapter}:{verse} — правил вида {Raw(kind)}: {hits}");
                }
            }
        }
        return found;
    }

    /// Приписка до рядка адреси: «(23:1)», коли другий переклад рахує інакше.
    /// Порожньо, якщо номери збігаються або місця в другому перекладі немає.
    public string ParallelSuffix(BookInfo book, int chapter, IReadOnlyList<int> verses,
                                 VerseNumberingStandard from, TextModule to, IReadOnlyList<Chapter> chapters)
    {
        var spans = ExistingSpans(book, chapter, verses, from, to, chapters);
        if (spans.Count == 0) return "";
        var own = ReferenceFormat.Position(chapter, verses);
        var other = string.Join(", ", spans.Select(span => ReferenceFormat.Position(span.Chapter, span.Verses)));
        return other == own ? "" : $" ({other})";
    }
}
