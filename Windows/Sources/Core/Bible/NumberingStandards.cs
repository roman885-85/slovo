// =============================================================================
//  NumberingStandards.cs — хто якого стандарту нумерації дотримується
//  (з Bible/NumberingStandards.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Кому який стандарт нумерації призначено і звідки це відомо.
public sealed record NumberingAssignment(string ModuleID, string StandardID, NumberingAssignment.Source Origin, string Reason)
{
    /// Звідки взялося призначення. Порядок важливий: своє рішення власника
    /// сильніше за здогадку, здогадка — сильніша за таблицю автора.
    public enum Source
    {
        Owner,      // вибрано людиною у вікні редактора
        Guessed,    // виведено за будовою самого перекладу
        Author,     // таблиця `modules` з бази старої програми
        None,       // стандарт не визначено
    }

    public bool IsKnown => StandardID.Length > 0;

    public static string RawValue(Source source) => source switch
    {
        Source.Owner => "owner",
        Source.Guessed => "guessed",
        Source.Author => "author",
        _ => "none",
    };

    public static string Title(Source source) => source switch
    {
        Source.Owner => OurWords.T("назначено"),
        Source.Guessed => OurWords.T("догадка"),
        Source.Author => OurWords.T("из базы нумерации"),
        _ => OurWords.T("не определён"),
    };
}

/// Здогадка про стандарт за будовою самого перекладу.
///
/// Таблиця `modules` у базі старої програми описує вісім перекладів із
/// п'ятдесяти п'яти, і чотири рядки з восьми в ній хибні. Тому питаємо не
/// таблицю, а сам переклад: скільки в нього віршів у тих розділах, де
/// стандарти розходяться.
public static class NumberingGuess
{
    /// Числа, за якими розрізняються стандарти. Скрізь береться НОМЕР останнього
    /// вірша, а не їхня кількість.
    public sealed record Evidence
    {
        public int? PsalmCount { get; set; }     // скільки всього псалмів: 150, 151 — інакше переклад ділить по-своєму
        public int? Psalm9 { get; set; }         // Пс 9: у Септуагінти він увібрав у себе десятий
        public int? Psalm3 { get; set; }         // Пс 3: надписання вважається віршем чи ні
        public int? Psalm147 { get; set; }       // Пс 147: у Септуагінти це друга половина єврейського 147-го
        public int? Ecclesiastes8 { get; set; }  // Еккл 8: єдина ознака Biblia Warszawska
        public int? Romans16 { get; set; }       // для перекладів без Псалтиря — лише Новий Заповіт
    }

    /// Зібрати числа з диска. Розбір книги коштує сотні мілісекунд — кликати
    /// НЕ з головного потоку.
    public static Evidence EvidenceFor(TextModule module)
    {
        var evidence = new Evidence();
        static int? Last(IReadOnlyList<Chapter> chapters, int number)
        {
            var chapter = chapters.FirstOrDefault(c => c.Number == number);
            return chapter == null || chapter.Verses.Count == 0 ? null : chapter.Verses.Max(verse => verse.Number);
        }
        if (module.Books.FirstOrDefault(book => book.CanonicalNumber == 230) is { } psalms
            && TryChapters(module, psalms) is { } psalmChapters)
        {
            evidence.PsalmCount = psalmChapters.Count;
            evidence.Psalm9 = Last(psalmChapters, 9);
            evidence.Psalm3 = Last(psalmChapters, 3);
            evidence.Psalm147 = Last(psalmChapters, 147);
        }
        if (module.Books.FirstOrDefault(book => book.CanonicalNumber == 250) is { } ecclesiastes
            && TryChapters(module, ecclesiastes) is { } ecclesiastesChapters)
        {
            evidence.Ecclesiastes8 = Last(ecclesiastesChapters, 8);
        }
        if (evidence.Psalm9 == null
            && module.Books.FirstOrDefault(book => book.CanonicalNumber == 520) is { } romans
            && TryChapters(module, romans) is { } romansChapters)
        {
            evidence.Romans16 = Last(romansChapters, 16);
        }
        return evidence;
    }

    private static IReadOnlyList<Chapter>? TryChapters(TextModule module, BookInfo book)
    {
        try { return module.Chapters(book); }
        catch { return null; }
    }

    /// Рішення за зібраними числами.
    ///
    /// Псалтир за Септуагінтою видно одразу (9-й псалом увібрав у себе десятий,
    /// а 147-й — лише друга половина єврейського), масоретський рахунок — за
    /// ненумерованим надписанням, а польський від українського відрізняється
    /// в усій бібліотеці однією-єдиною главою.
    public static (string StandardID, string Reason)? Decide(Evidence evidence)
    {
        if (evidence.PsalmCount is { } count && count != 150 && count != 151)
        {
            // «UA_Kulish» зі своїми 149 псалмами і «Belarus_Semuha» зі 152 не
            // лягають у жоден стандарт — краще показати їх за своїми номерами.
            return null;
        }
        if (evidence.Psalm9 is { } psalm9 && psalm9 >= 30)
            return ("ru", OurWords.T("в 9-м псалме %s стихов — он вобрал в себя десятый, счёт по Септуагинте", $"{psalm9}"));
        if (evidence.Psalm147 is { } psalm147 && psalm147 <= 12)
            return ("ru", OurWords.T("в 147-м псалме %s стихов — это вторая половина еврейского 147-го, главы сдвинуты по Септуагинте", $"{psalm147}"));
        if (evidence.Psalm3 is { } psalm3)
        {
            if (psalm3 == 8)
                return ("en", OurWords.T("последний стих 3-го псалма — восьмой: надписание не нумеруется, счёт масоретский"));
            if (evidence.Ecclesiastes8 is 18)
                return ("pl", OurWords.T("последний стих 3-го псалма — %s-й, а в Еккл 8 восемнадцать стихов: так делит одна Biblia Warszawska", $"{psalm3}"));
            return ("ua", OurWords.T("последний стих 3-го псалма — %s-й при коротком 9-м: главы масоретские, надписание считается стихом", $"{psalm3}"));
        }
        // Псалтиря немає — переклад з одного Нового Заповіту. Тоді вирішує
        // Рим 16: у масоретської подачі там 27 віршів, у східної — 23-24.
        if (evidence.Romans16 is { } romans)
        {
            return romans >= 26
                ? ("en", OurWords.T("Псалтири нет; в Рим 16 %s стихов — деление как в масоретской подаче", $"{romans}"))
                : ("ru", OurWords.T("Псалтири нет; в Рим 16 %s стихов — деление как в восточной подаче", $"{romans}"));
        }
        return null;
    }

    public static (string StandardID, string Reason)? Standard(TextModule module) => Decide(EvidenceFor(module));
}

/// Хто якого стандарту дотримується: свої призначення власника, здогадки і
/// таблиця автора — в одному місці.
///
/// Свої призначення лежать окремим файлом (`numbering.json`) у теці даних, а не
/// в базі старої програми: база чужа і може бути перезаписана.
public sealed class NumberingAssignments
{
    private static readonly Lazy<NumberingAssignments> shared = new(() => new NumberingAssignments());
    public static NumberingAssignments Shared => shared.Value;

    /// Що лежить у файлі. Формат навмисно читабельний: лагодиться текстовим
    /// редактором, якщо щось пішло не так перед служінням.
    private sealed class Stored
    {
        [JsonRequired, JsonPropertyName("version")] public int Version { get; set; } = 1;
        /// Вибір людини: ім'я модуля → «ru», «en», «pl», «ua».
        [JsonRequired, JsonPropertyName("assigned")] public Dictionary<string, string> Assigned { get; set; } = new();
        /// Здогадки, вже пораховані по книгах — щоб при кожному запуску заново
        /// не розбирати Псалтир у півсотні перекладів.
        [JsonRequired, JsonPropertyName("guessed")] public Dictionary<string, string> Guessed { get; set; } = new();
        [JsonRequired, JsonPropertyName("guessReasons")] public Dictionary<string, string> GuessReasons { get; set; } = new();

        public Stored Copy() => new()
        {
            Version = Version,
            Assigned = new Dictionary<string, string>(Assigned),
            Guessed = new Dictionary<string, string>(Guessed),
            GuessReasons = new Dictionary<string, string>(GuessReasons),
        };
    }

    private readonly string fileUrl;
    private readonly object gate = new();
    private Stored stored;

    public NumberingAssignments(string? fileUrl = null)
    {
        this.fileUrl = fileUrl ?? DefaultFileUrl;
        Stored? decoded = null;
        try { decoded = SwiftJson.TryDecode<Stored>(File.ReadAllBytes(this.fileUrl)); }
        catch { }
        stored = decoded ?? new Stored();
    }

    public static string DefaultFileUrl => Path.Combine(DataHome.Folder, "numbering.json");

    public string StoreUrl => fileUrl;

    // ── Вибір власника ──────────────────────────────────────────────────────

    public string? OwnerChoice(string moduleId)
    {
        lock (gate) return stored.Assigned.GetValueOrDefault(moduleId.ToLowerInvariant());
    }

    /// Призначити стандарт вручну. `null` — зняти призначення і повернутися до здогадки.
    public bool SetOwnerChoice(string? standardId, string moduleId)
    {
        Stored snapshot;
        lock (gate)
        {
            if (!string.IsNullOrEmpty(standardId)) stored.Assigned[moduleId.ToLowerInvariant()] = standardId;
            else stored.Assigned.Remove(moduleId.ToLowerInvariant());
            snapshot = stored.Copy();
        }
        return Write(snapshot);
    }

    /// Забути пораховані здогадки: знадобиться, коли список модулів змінився.
    public bool ClearGuesses()
    {
        Stored snapshot;
        lock (gate)
        {
            stored.Guessed.Clear();
            stored.GuessReasons.Clear();
            snapshot = stored.Copy();
        }
        return Write(snapshot);
    }

    private bool Write(Stored snapshot)
    {
        try
        {
            var data = SwiftJson.EncodeBytes(snapshot, pretty: true, sortedKeys: true);
            Directory.CreateDirectory(SwiftPath.Parent(fileUrl));
            SwiftPath.WriteAtomically(fileUrl, data);
            return true;
        }
        catch
        {
            return false;
        }
    }

    // ── Розв'язання ─────────────────────────────────────────────────────────

    /// Стандарт одного перекладу з усіма поясненнями. Може знадобитися
    /// розібрати Псалтир — кликати НЕ з головного потоку.
    public NumberingAssignment AssignmentFor(TextModule module)
    {
        var id = module.Identifier;
        var key = id.ToLowerInvariant();

        string? owner, cached, cachedReason;
        lock (gate)
        {
            owner = stored.Assigned.GetValueOrDefault(key);
            cached = stored.Guessed.GetValueOrDefault(key);
            cachedReason = stored.GuessReasons.GetValueOrDefault(key);
        }

        if (owner != null)
            return new NumberingAssignment(id, owner, NumberingAssignment.Source.Owner,
                                           OurWords.T("выбрано в окне «Нумерация переводов»"));
        if (cached != null)
            return new NumberingAssignment(id, cached, NumberingAssignment.Source.Guessed,
                                           cachedReason ?? OurWords.T("посчитано по книгам перевода"));
        if (NumberingGuess.Standard(module) is { } guess)
        {
            Stored snapshot;
            lock (gate)
            {
                stored.Guessed[key] = guess.StandardID;
                stored.GuessReasons[key] = guess.Reason;
                snapshot = stored.Copy();
            }
            Write(snapshot);
            return new NumberingAssignment(id, guess.StandardID, NumberingAssignment.Source.Guessed, guess.Reason);
        }
        // Таблиця автора — останньою: у ній вісім рядків, і чотири з них
        // числами не підтверджуються. Але вона все ж краща за мовчання.
        if (AuthorRow(key) is { } match)
            return new NumberingAssignment(id, match.Value, NumberingAssignment.Source.Author, match.Reason);
        return new NumberingAssignment(id, "", NumberingAssignment.Source.None,
                                       OurWords.T("по книгам перевода стандарт не опознан"));
    }

    public List<NumberingAssignment> AssignmentsFor(IReadOnlyList<TextModule> modules) =>
        modules.Select(AssignmentFor).ToList();

    /// Порахувати все і віддати рушію. Кличеться один раз при завантаженні
    /// бібліотеки і НЕ з головного потоку: рахує по книгах з диска.
    public List<NumberingAssignment> Apply(IReadOnlyList<TextModule> modules, VerseNumbering? engine = null)
    {
        engine ??= VerseNumbering.Shared;
        var resolved = AssignmentsFor(modules);
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < resolved.Count; index++)
        {
            var item = resolved[index];
            if (!item.IsKnown) continue;
            map[item.ModuleID.ToLowerInvariant()] = item.StandardID;
            // Коротке ім'я — запасний ключ: в історії і в плані від перекладу
            // лишається лише воно. Ключ займає перший переклад із таким ім'ям.
            var shortName = modules[index].Info.ShortName.ToLowerInvariant();
            if (shortName.Length > 0) map.TryAdd(shortName, item.StandardID);
        }
        engine.Load(map);
        return resolved;
    }

    /// Що вже відомо про переклад, без читання книг з диска.
    public NumberingAssignment? KnownAssignment(string moduleId)
    {
        var key = moduleId.ToLowerInvariant();
        if (OwnerChoice(moduleId) is { } owner)
            return new NumberingAssignment(moduleId, owner, NumberingAssignment.Source.Owner,
                                           OurWords.T("выбрано в окне «Нумерация переводов»"));
        string? cached, cachedReason;
        lock (gate)
        {
            cached = stored.Guessed.GetValueOrDefault(key);
            cachedReason = stored.GuessReasons.GetValueOrDefault(key);
        }
        if (cached != null)
            return new NumberingAssignment(moduleId, cached, NumberingAssignment.Source.Guessed,
                                           cachedReason ?? OurWords.T("посчитано по книгам перевода"));
        if (AuthorRow(key) is { } match)
            return new NumberingAssignment(moduleId, match.Value, NumberingAssignment.Source.Author, match.Reason);
        return null;
    }

    /// Рядок таблиці автора для цього модуля — точний або з поправкою на
    /// описку в імені (`ua_ogienka` при теці `UA_Ogienko`). Зв'язок за близьким
    /// іменем називається в причині словами.
    internal (string Value, string Reason)? AuthorRow(string key)
    {
        var author = VerseNumbering.Shared.AuthorAssignments;
        foreach (var (name, value) in author)
            if (name.ToLowerInvariant() == key)
                return (value, OurWords.T("строка «%s» в таблице modules базы нумерации", name));
        if (ModuleNameMatch.Nearest(key, author.Keys.Select(name => name.ToLowerInvariant()).ToList()) is not { } near)
            return null;
        foreach (var (name, value) in author)
            if (name.ToLowerInvariant() == near)
                return (value, OurWords.T("строка «%s» в таблице modules базы нумерации — имя связано по близкому", name));
        return null;
    }

    /// Віддати рушію те, що вже відомо, нічого не рахуючи заново.
    public int ApplyKnown(IReadOnlyList<TextModule> modules, VerseNumbering? engine = null)
    {
        engine ??= VerseNumbering.Shared;
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var module in modules)
        {
            if (KnownAssignment(module.Identifier) is not { IsKnown: true } assignment) continue;
            map[module.Identifier.ToLowerInvariant()] = assignment.StandardID;
            var shortName = module.Info.ShortName.ToLowerInvariant();
            if (shortName.Length > 0) map.TryAdd(shortName, assignment.StandardID);
        }
        engine.Load(map);
        return map.Count;
    }
}
