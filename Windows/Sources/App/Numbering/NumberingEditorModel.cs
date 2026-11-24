// =============================================================================
//  NumberingEditorModel.cs — стан вікна «Редактор невідповідностей нумерації» (N40)
// =============================================================================
//  За NumberingEditorModel.swift Mac 1.3.9. Три правила, з яких зібрано решту:
//   * файл автора не відкривається зовсім — поруч працює його програма, а SQLite
//     при відкритті вміє покласти поруч журнал; робимо побайтну копію у своїй
//     теці й читаємо лише її;
//   * правки живуть у пам'яті й лягають на диск лише за «Ок» чи «Зберегти зараз»,
//     а «Скасувати» повертає знімок цілком;
//   * у кожного рядка видно походження: «у автора», «змінено», «додано», «видалено».
//  Адресу рахує ТОЙ САМИЙ рушій, що й слайд (VerseNumbering): вікно лише називає
//  правила, на яких адреса зійшлася.
// =============================================================================

using System.Text.Json;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class NumberingEditorModel
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    // ── Види рядків ─────────────────────────────────────────────────────────

    public enum Tab { Modules, Rules, Check }

    /// Походження рядка правил відносно бази автора.
    public enum RowOrigin { Author, Changed, Added, Removed }

    public static string Title(RowOrigin origin) => origin switch
    {
        RowOrigin.Author => T("у автора"),
        RowOrigin.Changed => T("изменено"),
        RowOrigin.Added => T("добавлено"),
        _ => T("удалено"),
    };

    /// Звідки взявся стандарт перекладу.
    public enum StandardOrigin { Author, Detected, Manual, None }

    public static string Title(StandardOrigin origin) => origin switch
    {
        StandardOrigin.Author => T("у автора"),
        StandardOrigin.Detected => T("определено"),
        StandardOrigin.Manual => T("вручную"),
        _ => T("нет"),
    };

    public enum MatchKind { Unknown, Working, Impossible, Score }

    /// Підсумок звірки ознак із вмістом перекладу.
    public readonly record struct MatchState(MatchKind Kind, int Hits = 0, int Total = 0, string Text = "")
    {
        public static MatchState Unknown => new(MatchKind.Unknown);
        public static MatchState Working => new(MatchKind.Working);
        public static MatchState Impossible(string why) => new(MatchKind.Impossible, Text: why);
        public static MatchState Score(int hits, int total, string missed) => new(MatchKind.Score, hits, total, missed);
    }

    /// Рядок списку перекладів.
    public sealed record ModuleRow(string Id, string Name, string Short, string Standard, StandardOrigin Origin, MatchState Match);

    /// Рядок таблиці правил — уже в тому вигляді, як його показують.
    public sealed record RuleRow(Guid Id, string KindTitle, string Letter, string BookTitle, string Source, string Target,
                                 RowOrigin Origin, int Book, int Chapter, int Verse);

    /// Правка правила в окремому вікні. Окремий тип, а не саме правило: поки вікно
    /// відкрите, у таблиці має лишатися попередній рядок.
    public sealed class RuleDraft
    {
        /// Правило, яке правимо; null — додавання нового.
        public Guid? RuleId;
        public string From = "", To = "";
        public NumberingRuleKind Kind;
        public int Book;
        public int ChapterBegin;
        public int? ChapterEnd, VerseBegin, VerseEnd, ChapterTo, ChapterToEnd, VerseTo, VerseToEnd;
    }

    /// Рядок звіту «Звірити книгу цілком».
    public sealed record ReportLine(int Chapter, int Verse, string Text);

    // ── Що показуємо ────────────────────────────────────────────────────────

    public Tab CurrentTab = Tab.Modules;
    public NumberingBase Base { get; private set; } = new();
    public bool IsLoaded { get; private set; }
    public bool IsDirty { get; private set; }
    /// Слово про оригінал: «файл автора» / «своя копія (правок: 12)».
    public string SourceNote { get; private set; } = T("читаю базу…");
    public string RefreshedNote { get; private set; } = "";
    public string Status = "";

    public List<ModuleRow> ModuleRows { get; private set; } = new();
    public string? SelectedModule;
    public bool OnlyUnassigned;
    public bool IsDetecting { get; private set; }
    /// Сходимість перераховується сама при відкритті; окрема мітка, щоб кнопки
    /// «Визначити» тим часом лишалися живими.
    public bool IsMatching { get; private set; }

    public string PairFrom = "ru", PairTo = "en";
    public Guid? SelectedRule;
    public bool OnlyMine;

    public string CheckPrimary = "", CheckSecondary = "";
    public int CheckBook = 230, CheckChapter = 1, CheckVerse = 1;
    public string AddressInput = "";
    public List<ReportLine> Report { get; private set; } = new();
    public string ReportSummary { get; private set; } = "";
    public bool IsVerifying { get; private set; }
    /// Лічильник розібраних у фоні книг: за ним вигляд перемальовує вірші.
    public int CacheTick { get; private set; }

    /// Книги канону з назвами — з основного перекладу.
    public readonly List<(int Number, string Name)> Books;
    /// Переклади для списків вкладки «Перевірка».
    public readonly List<(string Id, string Name)> Modules;

    /// Щось змінилося у фоні — вигляду перемалюватися.
    public event Action? Changed;

    // ── Внутрішнє ───────────────────────────────────────────────────────────

    readonly AppState _state;
    /// База автора як є — еталон, з яким звіряється походження.
    NumberingBase _author = new();
    /// Знімок для «Скасувати»: і правила, і видалені рядки, і призначення.
    NumberingBase _snapshot = new();
    List<NumberingRule> _snapshotRemoved = new();
    /// Рядки автора, видалені в цьому сеансі: показуємо закресленими.
    List<NumberingRule> _removed = new();
    readonly Dictionary<string, StandardOrigin> _standardOrigins = new();
    readonly Dictionary<string, MatchState> _matches = new();
    readonly HashSet<string> _pendingChapters = new();
    int _verifyToken;
    VerifyFlag? _verifyFlag;
    readonly string _dataRoot;

    /// Мітка скасування фонової звірки (читається з фону на кожному вірші).
    sealed class VerifyFlag { public volatile bool IsCancelled; }

    // ── Відкриття ───────────────────────────────────────────────────────────

    public NumberingEditorModel(AppState state)
    {
        _state = state;
        _dataRoot = Path.GetDirectoryName(state.ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')) ?? DataHome.Folder;

        var source = state.PrimaryModule ?? state.AllModules.FirstOrDefault();
        Books = new List<(int, string)>();
        foreach (var book in source?.Books ?? Array.Empty<BookInfo>())
            if (book.CanonicalNumber is { } number && Books.All(b => b.Number != number)) Books.Add((number, book.FullName));
        Books.Sort((a, b) => a.Number.CompareTo(b.Number));

        Modules = state.AllModules.Where(m => m.Info.IsBible).Select(m => (m.Identifier, m.DisplayName)).ToList();

        CheckPrimary = state.PrimaryModuleID;
        CheckSecondary = state.SecondaryModuleIDs.FirstOrDefault() ?? state.PrimaryModuleID;
        CheckBook = state.CurrentBook?.CanonicalNumber ?? (Books.Count > 0 ? Books[0].Number : 230);
        CheckChapter = state.SelectedChapterNumber;
        CheckVerse = state.SelectedVerseNumbers.Count > 0 ? state.SelectedVerseNumbers[0] : 1;

        Load();
    }

    /// Вікно відкрили знову: база на диску могла змінитися — читаємо її ще раз.
    public void Reopen()
    {
        if (IsDirty) return;
        Load();
    }

    /// Читання бази — у фоні, щоб вікно відкрилося одразу.
    void Load()
    {
        var root = _dataRoot;
        Task.Run(() =>
        {
            var copied = RefreshAuthorCopy(root);
            NumberingBase authorBase;
            try { authorBase = File.Exists(copied.Path) ? NumberingBase.LoadFrom(copied.Path) : new NumberingBase(); }
            catch { authorBase = new NumberingBase(); }
            NumberingBase? mine = null;
            if (File.Exists(NumberingBase.UserUrl))
                try { mine = NumberingBase.LoadFrom(NumberingBase.UserUrl); } catch { mine = null; }
            Dispatcher.UIThread.Post(() => Apply(authorBase, mine, copied.Refreshed));
        });
    }

    void Apply(NumberingBase authorBase, NumberingBase? mine, bool refreshed)
    {
        _author = authorBase;
        // Своя копія витісняє еталон цілком: це вже готова база, а не перелік поправок.
        Base = Clone(mine ?? authorBase);
        if (Base.Standards.Count == 0) Base.Standards = DefaultStandards.ToList();
        _snapshot = Clone(Base);
        _removed = authorBase.Rules.Where(rule => !Base.Rules.Any(r => Key(r) == Key(rule))).ToList();
        _snapshotRemoved = _removed.ToList();
        IsLoaded = true;
        IsDirty = false;

        var codes = Base.Standards.Select(s => s.Code).ToList();
        if (!codes.Contains(PairFrom)) PairFrom = codes.FirstOrDefault() ?? "ru";
        if (!codes.Contains(PairTo)) PairTo = codes.FirstOrDefault(c => c != PairFrom) ?? PairFrom;

        if (authorBase.IsEmpty) SourceNote = T("базы автора нет: искали %s", NumberingBase.OriginalUrl(_dataRoot));
        else SourceNote = mine == null ? T("файл автора") : T("своя копия (правок: %s)", OwnRowCount.ToString());
        if (refreshed && mine != null)
            RefreshedNote = T("Файл программы обновился. Ваши правки сохранены, новые строки автора помечены");
        RebuildModuleRows();
        // Сходимість уже призначених перекладів — одразу: колонка «Сходиться» для того й є,
        // щоб побачити чуже призначення до того, як на нього покластися. Нічого не пише.
        RefreshMatches();
        Changed?.Invoke();
    }

    /// Глибока копія бази (у Swift база — значення, тут — посилання).
    static NumberingBase Clone(NumberingBase source) =>
        new(source.Standards.ToList(),
            new Dictionary<string, string>(source.Modules, StringComparer.Ordinal),
            source.Rules.Select(r => r with { }).ToList());

    /// Побайтна копія бази автора у своїй теці. Оновлюється, коли в оригіналу
    /// змінилися розмір чи дата, — інакше оновлення старої програми пройшло б повз.
    static (string Path, bool Refreshed) RefreshAuthorCopy(string dataRoot)
    {
        var original = NumberingBase.OriginalUrl(dataRoot);
        var copy = Path.Combine(Path.GetDirectoryName(NumberingBase.UserUrl) ?? DataHome.Folder, "inconsistencies.author.sqlite3");
        if (!File.Exists(original)) return (copy, false);
        var source = new FileInfo(original);
        var mirror = new FileInfo(copy);
        if (mirror.Exists && mirror.Length == source.Length && mirror.LastWriteTimeUtc == source.LastWriteTimeUtc) return (copy, false);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(copy)!);
            if (mirror.Exists) File.Delete(copy);
            File.Copy(original, copy);
            File.SetLastWriteTimeUtc(copy, source.LastWriteTimeUtc);
        }
        catch (Exception error) { Journal.Say($"нумерація: копія бази автора — {error.Message}"); }
        return (copy, mirror.Exists);
    }

    /// Стандарти, коли бази автора немає зовсім: інакше призначати нічого.
    public static readonly IReadOnlyList<NumberingStandard> DefaultStandards = new[]
    {
        new NumberingStandard("en", "West standart (Masoretic, for example Synodal translation)"),
        new NumberingStandard("pl", "Poland numbering (for example Biblia Warszawska)"),
        new NumberingStandard("ru", "East standart (Septuagint, for example King James Version)"),
        new NumberingStandard("ua", "Ukrainian numbering"),
    };

    /// Наші підписи стандартів (у t_info автора приклади в двох перших рядках переставлено).
    public static string StandardTitle(string code) => code switch
    {
        "ru" => T("Восточная (септуагинтская): синодальный перевод"),
        "en" => T("Западная (масоретская): King James"),
        "pl" => T("Польская: Biblia Warszawska"),
        "ua" => T("Украинская"),
        _ => code,
    };

    public string AuthorTitle(string code) => Base.Standards.FirstOrDefault(s => s.Code == code)?.Description ?? "";

    public List<string> StandardCodes => Base.Standards.Select(s => s.Code).OrderBy(c => c, StringComparer.Ordinal).ToList();

    // ── Ключ рядка ──────────────────────────────────────────────────────────

    /// Ключ єдиності — ті самі стовпці, що в `idx1` бази автора.
    public static string Key(NumberingRule rule) => string.Join("|",
        rule.From, rule.To, rule.Kind.RawValue(), rule.Book.ToString(), rule.ChapterBegin.ToString(),
        rule.VerseBegin?.ToString() ?? "", rule.VerseEnd?.ToString() ?? "", rule.ChapterEnd?.ToString() ?? "");

    static bool SameValues(NumberingRule one, NumberingRule two) =>
        one.ChapterTo == two.ChapterTo && one.ChapterToEnd == two.ChapterToEnd && one.VerseTo == two.VerseTo && one.VerseToEnd == two.VerseToEnd;

    public RowOrigin Origin(NumberingRule rule)
    {
        var key = Key(rule);
        var original = _author.Rules.FirstOrDefault(r => Key(r) == key);
        if (original == null) return RowOrigin.Added;
        return SameValues(original, rule) ? RowOrigin.Author : RowOrigin.Changed;
    }

    /// Скільки рядків відрізняється від бази автора.
    public int OwnRowCount
    {
        get
        {
            var count = _removed.Count;
            foreach (var rule in Base.Rules) if (Origin(rule) != RowOrigin.Author) count++;
            foreach (var (name, code) in Base.Modules) if (!_author.Modules.TryGetValue(name, out var a) || a != code) count++;
            foreach (var (name, code) in _author.Modules) if (!Base.Modules.TryGetValue(name, out var b) || b != code) count++;
            return count;
        }
    }

    // ── Переклади й стандарти ───────────────────────────────────────────────

    void RebuildModuleRows()
    {
        ModuleRows = _state.AllModules.Where(m => m.Info.IsBible).Select(module =>
        {
            var code = Base.StandardCode(new[] { module.Info.ShortName, module.Identifier }) ?? "";
            return new ModuleRow(module.Identifier, module.DisplayName,
                                 module.Info.ShortName.Length == 0 ? module.Identifier : module.Info.ShortName,
                                 code,
                                 _standardOrigins.TryGetValue(module.Identifier, out var origin) ? origin : code.Length == 0 ? StandardOrigin.None : StandardOrigin.Author,
                                 _matches.TryGetValue(module.Identifier, out var match) ? match : MatchState.Unknown);
        }).OrderBy(r => r.Name, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    public List<ModuleRow> VisibleModuleRows => OnlyUnassigned ? ModuleRows.Where(r => r.Standard.Length == 0).ToList() : ModuleRows;

    public int AssignedCount => ModuleRows.Count(r => r.Standard.Length > 0);

    /// Рядки таблиці автора, яким не відповідає жоден модуль (і ім'я з опискою
    /// теж не впізнається `ModuleNameMatch`).
    public List<(string Name, string? Nearest)> OrphanNames
    {
        get
        {
            var names = _state.AllModules.SelectMany(m => new[] { m.Identifier.ToLowerInvariant(), m.Info.ShortName.ToLowerInvariant() }).Distinct().ToList();
            var known = names.ToHashSet();
            return Base.Modules.Keys.OrderBy(k => k, StringComparer.Ordinal)
                .Where(name => !known.Contains(name) && ModuleNameMatch.Nearest(name, names) == null)
                .Select(name => (name, NearestModule(name))).ToList();
        }
    }

    string? NearestModule(string name)
    {
        (string Name, int Distance)? best = null;
        foreach (var module in _state.AllModules)
            foreach (var candidate in new[] { module.Identifier, module.Info.ShortName })
            {
                if (candidate.Length == 0) continue;
                var distance = Distance(name.ToLowerInvariant(), candidate.ToLowerInvariant());
                if (best == null || distance < best.Value.Distance) best = (candidate, distance);
            }
        return best is { Distance: <= 3 } found ? found.Name : null;
    }

    /// Відстань редагування: понад три правки — «це інше ім'я».
    static int Distance(string one, string two)
    {
        if (one.Length == 0) return two.Length;
        var previous = Enumerable.Range(0, two.Length + 1).ToArray();
        for (var i = 1; i <= one.Length; i++)
        {
            var current = new int[two.Length + 1];
            current[0] = i;
            for (var j = 1; j <= two.Length; j++)
                current[j] = one[i - 1] == two[j - 1] ? previous[j - 1] : Math.Min(Math.Min(previous[j - 1], previous[j]), current[j - 1]) + 1;
            previous = current;
        }
        return previous[two.Length];
    }

    public void SetStandard(string code, string moduleId) => Assign(code, moduleId, code.Length == 0 ? StandardOrigin.None : StandardOrigin.Manual);

    void Assign(string code, string moduleId, StandardOrigin origin)
    {
        if (_state.AllModules.FirstOrDefault(m => m.Identifier == moduleId) is not { } module) return;
        // Обидва колишні ключі знімаємо: в автора переклад записано скороченням, ми пишемо
        // ім'ям теки — два рядки на один модуль сперечалися б.
        Base.Modules.Remove(module.Info.ShortName.ToLowerInvariant());
        Base.Modules.Remove(moduleId.ToLowerInvariant());
        if (code.Length > 0) Base.Modules[moduleId.ToLowerInvariant()] = code;
        _standardOrigins[moduleId] = origin;
        IsDirty = true;
        RebuildModuleRows();
        // Призначили руками — одразу рахуємо, чи сходиться призначене з самим перекладом.
        if (code.Length > 0 && origin == StandardOrigin.Manual) RefreshMatch(moduleId, code);
    }

    /// Сходимість одного перекладу — читає дві книги, тому у фоні.
    void RefreshMatch(string moduleId, string code)
    {
        _matches[moduleId] = MatchState.Working;
        RebuildModuleRows();
        var module = _state.Module(moduleId);
        if (module == null) return;
        Task.Run(() =>
        {
            MatchState answer;
            try { answer = Match(NumberingGuess.EvidenceFor(module), code); }
            catch (Exception error) { answer = MatchState.Impossible(error.Message); }
            Dispatcher.UIThread.Post(() => { _matches[moduleId] = answer; RebuildModuleRows(); Changed?.Invoke(); });
        });
    }

    /// Повернути перекладові те призначення, що стояло в автора.
    public void RestoreAuthorStandard(string moduleId)
    {
        if (_state.AllModules.FirstOrDefault(m => m.Identifier == moduleId) is not { } module) return;
        var shortKey = module.Info.ShortName.ToLowerInvariant();
        var idKey = moduleId.ToLowerInvariant();
        Base.Modules.Remove(shortKey);
        Base.Modules.Remove(idKey);
        foreach (var (name, code) in _author.Modules)
            if (name == shortKey || name == idKey) Base.Modules[name] = code;
        _standardOrigins[moduleId] = Base.StandardCode(new[] { module.Info.ShortName, moduleId }) == null ? StandardOrigin.None : StandardOrigin.Author;
        IsDirty = true;
        RebuildModuleRows();
    }

    /// Перенести рядок таблиці автора на справжнє ім'я теки.
    public void RenameAuthorRow(string name, string newName)
    {
        if (!Base.Modules.TryGetValue(name, out var code)) return;
        Base.Modules.Remove(name);
        Base.Modules[newName.ToLowerInvariant()] = code;
        IsDirty = true;
        RebuildModuleRows();
    }

    // ── Визначення стандарту за вмістом ─────────────────────────────────────

    /// Ознаки, якими стандарти різняться, і їхні очікувані значення (зняті з
    /// модулів власника): 9-й псалом східного рахунку ввібрав десятий, надписання
    /// псалма має свій номер скрізь, крім масоретського рахунку, 147-й у Септуагінти —
    /// друга половина єврейського, довгий Еккл 8 — лише в Biblia Warszawska.
    readonly record struct Signs(bool? Psalm9Joined, bool? Psalm3Counted, bool? Psalm147Short, bool? Ecclesiastes8Long)
    {
        public static Signs Expected(string code) => code switch
        {
            "ru" => new(true, true, true, false),
            "en" => new(false, false, false, false),
            "pl" => new(false, true, false, true),
            _ => new(false, true, false, false),
        };
    }

    static Signs SignsOf(NumberingGuess.Evidence evidence) => new(
        evidence.Psalm9 is { } p9 ? p9 >= 30 : null,
        evidence.Psalm3 is { } p3 ? p3 >= 9 : null,
        evidence.Psalm147 is { } p147 ? p147 <= 12 : null,
        evidence.Ecclesiastes8 is { } e8 ? e8 >= 18 : null);

    /// Наскільки призначений стандарт сходиться з вмістом перекладу.
    static MatchState Match(NumberingGuess.Evidence evidence, string code)
    {
        var seen = SignsOf(evidence);
        var want = Signs.Expected(code);
        int total = 0, hits = 0;
        var missed = new List<string>();
        void Compare(bool? left, bool? right, string name)
        {
            if (left is not { } l || right is not { } r) return;
            total++;
            if (l == r) hits++; else missed.Add(name);
        }
        Compare(seen.Psalm9Joined, want.Psalm9Joined, "Пс 9");
        Compare(seen.Psalm3Counted, want.Psalm3Counted, "Пс 3");
        Compare(seen.Psalm147Short, want.Psalm147Short, "Пс 147");
        Compare(seen.Ecclesiastes8Long, want.Ecclesiastes8Long, "Еккл 8");
        if (total == 0) return MatchState.Impossible(T("признаки не снять (нет Псалтири)"));
        return MatchState.Score(hits, total, string.Join(", ", missed));
    }

    /// Визначити стандарт у всіх перекладів (рядки «у автора» й «вручну» не чіпаємо).
    public void DetectAll() => Detect(ModuleRows.Where(r => r.Standard.Length == 0 || r.Origin == StandardOrigin.Detected).Select(r => r.Id).ToList(), false);

    /// Те саме для одного рядка — і його чіпаємо завжди: людина натиснула саме на нього.
    public void DetectSelected()
    {
        if (SelectedModule is { } id) Detect(new List<string> { id }, true);
    }

    void Detect(List<string> identifiers, bool force)
    {
        if (identifiers.Count == 0 || IsDetecting) return;
        IsDetecting = true;
        Status = T("считаю признаки у %s переводов…", identifiers.Count.ToString());
        foreach (var id in identifiers) _matches[id] = MatchState.Working;
        RebuildModuleRows();
        var modules = identifiers.Select(id => (id, _state.Module(id))).ToList();
        Task.Run(() =>
        {
            var found = new List<(string Id, string Code, string Reason, MatchState Match)>();
            foreach (var (id, module) in modules)
            {
                if (module == null) continue;
                try
                {
                    var evidence = NumberingGuess.EvidenceFor(module);
                    var guess = NumberingGuess.Decide(evidence);
                    var code = guess?.StandardID ?? "";
                    var match = code.Length == 0 ? MatchState.Impossible(T("ни один стандарт не сошёлся")) : Match(evidence, code);
                    found.Add((id, code, guess?.Reason ?? "", match));
                }
                catch (Exception error)
                {
                    // Модуль не прочитався — сказати про це в рядку, а не зависнути на «рахую…».
                    Journal.Say($"нумерація: ознаки {id} — {error.Message}");
                    found.Add((id, "", "", MatchState.Impossible(error.Message)));
                }
            }
            Dispatcher.UIThread.Post(() => { FinishDetection(found, force); Changed?.Invoke(); });
        });
    }

    void FinishDetection(List<(string Id, string Code, string Reason, MatchState Match)> found, bool force)
    {
        var assigned = 0;
        foreach (var (id, code, reason, match) in found)
        {
            _matches[id] = match;
            if (code.Length == 0) continue;
            var current = ModuleRows.FirstOrDefault(r => r.Id == id);
            if (force || current == null || current.Standard.Length == 0 || current.Origin == StandardOrigin.Detected)
            {
                Assign(code, id, StandardOrigin.Detected);
                assigned++;
            }
            if (found.Count == 1) Status = reason;
        }
        IsDetecting = false;
        if (found.Count > 1) Status = T("стандарт определён у %s переводов из %s", assigned.ToString(), found.Count.ToString());
        RebuildModuleRows();
    }

    /// Перерахувати сходимість за вже призначеним стандартом — без призначення.
    public void RefreshMatches()
    {
        var pairs = ModuleRows.Where(r => r.Standard.Length > 0).Select(r => (r.Id, r.Standard, Module: _state.Module(r.Id))).ToList();
        if (pairs.Count == 0 || IsMatching) return;
        IsMatching = true;
        Task.Run(() =>
        {
            var found = new List<(string Id, MatchState Match)>();
            foreach (var (id, code, module) in pairs)
            {
                if (module == null) continue;
                try { found.Add((id, Match(NumberingGuess.EvidenceFor(module), code))); }
                catch (Exception error) { found.Add((id, MatchState.Impossible(error.Message))); }
            }
            Dispatcher.UIThread.Post(() =>
            {
                // Рядки, які зараз рахує «Визначити», не чіпаємо: його відповідь свіжіша.
                foreach (var (id, match) in found)
                    if (!_matches.TryGetValue(id, out var now) || now.Kind != MatchKind.Working) _matches[id] = match;
                IsMatching = false;
                RebuildModuleRows();
                Changed?.Invoke();
            });
        });
    }

    // ── Правила вибраної пари ───────────────────────────────────────────────

    public List<NumberingRule> PairRules => Base.Rules.Where(r => r.From == PairFrom && r.To == PairTo).ToList();

    public List<RuleRow> RuleRows
    {
        get
        {
            var rows = PairRules.Select(r => Row(r, Origin(r))).ToList();
            rows.AddRange(_removed.Where(r => r.From == PairFrom && r.To == PairTo).Select(r => Row(r, RowOrigin.Removed)));
            if (OnlyMine) rows = rows.Where(r => r.Origin != RowOrigin.Author).ToList();
            return rows.OrderBy(r => r.Book).ThenBy(r => r.Chapter).ThenBy(r => r.Verse).ToList();
        }
    }

    RuleRow Row(NumberingRule rule, RowOrigin origin) =>
        new(rule.Id, KindTitle(rule.Kind), rule.Kind.RawValue(), $"{BookName(rule.Book)} ({rule.Book})",
            SourceText(rule), TargetText(rule), origin, rule.Book, rule.ChapterBegin, rule.VerseBegin ?? 0);

    /// Адреса-джерело рядком. Порожній «вірш по» означає різне в різних видів: у
    /// точної відповідності — рівно один вірш, у переносу й зсуву — «і далі до кінця
    /// розділу». Звідси трикрапка в одних і її відсутність в інших.
    public static string SourceText(NumberingRule rule)
    {
        var chapters = (rule.ChapterEnd ?? rule.ChapterBegin) > rule.ChapterBegin ? $"{rule.ChapterBegin}–{rule.ChapterEnd}" : $"{rule.ChapterBegin}";
        if (rule.Kind == NumberingRuleKind.OffsetChapter || rule.VerseBegin is not { } begin) return chapters;
        if (rule.VerseEnd is { } end) return end > begin ? $"{chapters}:{begin}–{end}" : $"{chapters}:{begin}";
        return rule.Kind == NumberingRuleKind.Displaced ? $"{chapters}:{begin}" : $"{chapters}:{begin}…";
    }

    /// Адреса-призначення: у зсувів число зі знаком, у переносів адреса.
    public static string TargetText(NumberingRule rule)
    {
        static string Signed(int value) => value > 0 ? $"+{value}" : $"{value}";
        switch (rule.Kind)
        {
            case NumberingRuleKind.OffsetChapter:
                return Signed(rule.ChapterTo ?? 0) + " " + T("к главе");
            case NumberingRuleKind.OffsetVerse:
            {
                var shift = Signed(rule.VerseTo ?? 0) + " " + T("к стиху");
                return rule.ChapterTo is { } to ? T("глава %s, ", to.ToString()) + shift : shift;
            }
            case NumberingRuleKind.Part:
            {
                var chapter = rule.ChapterTo?.ToString() ?? T("та же глава");
                return rule.VerseTo is { } verse ? T("%s:%s и далее", chapter, verse.ToString()) : chapter;
            }
            default:
            {
                var chapter = rule.ChapterTo?.ToString() ?? rule.ChapterBegin.ToString();
                var text = rule.VerseTo is { } verse ? $"{chapter}:{verse}" : chapter;
                if (rule.ChapterToEnd is { } lastChapter && lastChapter != rule.ChapterTo) text += $"–{lastChapter}:{rule.VerseToEnd ?? 1}";
                else if (rule.VerseToEnd is { } lastVerse && lastVerse != rule.VerseTo) text += $"–{lastVerse}";
                return text;
            }
        }
    }

    /// Тип правила словом (літеру показуємо поруч дрібним — щоб упізнавати рядок бази).
    public static string KindTitle(NumberingRuleKind kind) => kind switch
    {
        NumberingRuleKind.OffsetChapter => T("сдвиг главы"),
        NumberingRuleKind.OffsetVerse => T("сдвиг стиха"),
        NumberingRuleKind.Part => T("перенос отрывка"),
        _ => T("точное соответствие"),
    };

    public string BookName(int number) => Books.FirstOrDefault(b => b.Number == number).Name ?? T("книга %s", number.ToString());

    public NumberingRule? Rule(Guid? id) => id is not { } wanted ? null
        : Base.Rules.FirstOrDefault(r => r.Id == wanted) ?? _removed.FirstOrDefault(r => r.Id == wanted);

    public string PairNote
    {
        get
        {
            if (PairFrom == PairTo) return T("один и тот же стандарт");
            var count = PairRules.Count;
            if (count > 0) return T("правил %s", count.ToString());
            var path = Route(PairFrom, PairTo);
            if (path.Count <= 2) return T("правил нет");
            return T("прямых правил нет, считается через %s стандарт", StandardShort(path[1]));
        }
    }

    public static string StandardShort(string code) => code switch
    {
        "ru" => T("русский"),
        "en" => T("масоретский"),
        "pl" => T("польский"),
        "ua" => T("украинский"),
        _ => code,
    };

    // ── Правка правил ───────────────────────────────────────────────────────

    public RuleDraft NewDraft() => new()
    {
        From = PairFrom, To = PairTo, Kind = NumberingRuleKind.OffsetVerse,
        Book = _state.CurrentBook?.CanonicalNumber ?? (Books.Count > 0 ? Books[0].Number : 230),
        ChapterBegin = 1, VerseBegin = 1, VerseTo = 0,
    };

    public static RuleDraft DraftFrom(NumberingRule rule) => new()
    {
        RuleId = rule.Id, From = rule.From, To = rule.To, Kind = rule.Kind, Book = rule.Book,
        ChapterBegin = rule.ChapterBegin, ChapterEnd = rule.ChapterEnd, VerseBegin = rule.VerseBegin, VerseEnd = rule.VerseEnd,
        ChapterTo = rule.ChapterTo, ChapterToEnd = rule.ChapterToEnd, VerseTo = rule.VerseTo, VerseToEnd = rule.VerseToEnd,
    };

    /// Дзеркальне правило оберненої пари — відкривається вікном правки, а не пишеться
    /// мовчки: обертання переносу й точної відповідності не завжди однозначне.
    public static RuleDraft MirrorDraft(NumberingRule rule)
    {
        switch (rule.Kind)
        {
            case NumberingRuleKind.OffsetChapter:
            {
                var shift = rule.ChapterTo ?? 0;
                return new RuleDraft
                {
                    From = rule.To, To = rule.From, Kind = NumberingRuleKind.OffsetChapter, Book = rule.Book,
                    ChapterBegin = rule.ChapterBegin + shift, ChapterEnd = rule.ChapterEnd + shift, ChapterTo = -shift,
                };
            }
            case NumberingRuleKind.OffsetVerse:
            {
                var shift = rule.VerseTo ?? 0;
                return new RuleDraft
                {
                    From = rule.To, To = rule.From, Kind = NumberingRuleKind.OffsetVerse, Book = rule.Book,
                    ChapterBegin = rule.ChapterTo ?? rule.ChapterBegin, ChapterEnd = rule.ChapterEnd,
                    VerseBegin = rule.VerseBegin + shift, VerseEnd = rule.VerseEnd + shift, VerseTo = -shift,
                };
            }
            default:
                return new RuleDraft
                {
                    From = rule.To, To = rule.From, Kind = rule.Kind, Book = rule.Book,
                    ChapterBegin = rule.ChapterTo ?? rule.ChapterBegin, ChapterEnd = rule.ChapterToEnd,
                    VerseBegin = rule.VerseTo, VerseEnd = rule.VerseToEnd,
                    ChapterTo = rule.ChapterBegin, ChapterToEnd = rule.ChapterEnd, VerseTo = rule.VerseBegin, VerseToEnd = rule.VerseEnd,
                };
        }
    }

    static NumberingRule RuleOf(RuleDraft draft) =>
        new(draft.From, draft.To, draft.Kind, draft.Book, draft.ChapterBegin, draft.ChapterEnd, draft.VerseBegin, draft.VerseEnd,
            draft.ChapterTo, draft.ChapterToEnd, draft.VerseTo, draft.VerseToEnd, draft.RuleId);

    /// Записати правку правила. Відповідь — слово про помилку; null — прийнято.
    public string? Commit(RuleDraft draft)
    {
        if (draft.ChapterEnd is { } end && end < draft.ChapterBegin) return T("Начальная глава больше конечной");
        if (draft.VerseBegin is { } begin && draft.VerseEnd is { } verseEnd && verseEnd < begin) return T("Начальный стих больше конечного");
        if (draft.Kind == NumberingRuleKind.Displaced && draft.VerseBegin == null) return T("У точного соответствия должен быть задан стих");
        var rule = RuleOf(draft);
        // Єдиність — та сама, що в індексу `idx1` бази: дати SQLite впасти на записі не можна.
        if (Base.Rules.Any(r => Key(r) == Key(rule) && r.Id != rule.Id)) return T("Такое правило в этой паре уже есть");
        var index = Base.Rules.FindIndex(r => r.Id == rule.Id);
        if (index >= 0) Base.Rules[index] = rule; else Base.Rules.Add(rule);
        _removed.RemoveAll(r => Key(r) == Key(rule));
        SelectedRule = rule.Id;
        IsDirty = true;
        return null;
    }

    public void RemoveRule(Guid id)
    {
        var index = Base.Rules.FindIndex(r => r.Id == id);
        if (index < 0) return;
        var rule = Base.Rules[index];
        Base.Rules.RemoveAt(index);
        // Рядок автора пам'ятаємо закресленим: мовчки зниклий рядок виглядає як втрата.
        if (_author.Rules.Any(r => Key(r) == Key(rule))) _removed.Add(rule);
        SelectedRule = null;
        IsDirty = true;
    }

    /// Повернути рядкові авторський вигляд; доданий нами рядок — прибрати.
    public void RestoreAuthorRule(Guid id)
    {
        if (Rule(id) is not { } rule) return;
        var key = Key(rule);
        Base.Rules.RemoveAll(r => Key(r) == key);
        _removed.RemoveAll(r => Key(r) == key);
        if (_author.Rules.FirstOrDefault(r => Key(r) == key) is { } original)
        {
            var restored = original with { Id = Guid.NewGuid() };
            Base.Rules.Add(restored);
            SelectedRule = restored.Id;
        }
        else SelectedRule = null;
        IsDirty = true;
    }

    // ── Переведення адреси за правилами, що зараз у вікні ───────────────────

    /// Дорога між стандартами: пряма пара, а нема — ланцюжок (pl — en — ru — ua).
    public static List<string> Route(IReadOnlyList<NumberingRule> rules, string from, string to)
    {
        if (from == to) return new List<string> { from };
        var neighbours = new Dictionary<string, SortedSet<string>>(StringComparer.Ordinal);
        foreach (var rule in rules)
        {
            if (!neighbours.TryGetValue(rule.From, out var set)) neighbours[rule.From] = set = new SortedSet<string>(StringComparer.Ordinal);
            set.Add(rule.To);
        }
        var queue = new Queue<List<string>>();
        queue.Enqueue(new List<string> { from });
        var visited = new HashSet<string> { from };
        while (queue.Count > 0)
        {
            var path = queue.Dequeue();
            var last = path[^1];
            if (last == to) return path;
            if (!neighbours.TryGetValue(last, out var next)) continue;
            foreach (var step in next)
            {
                if (!visited.Add(step)) continue;
                queue.Enqueue(path.Append(step).ToList());
            }
        }
        return new List<string> { from };
    }

    public List<string> Route(string from, string to) => Route(Base.Rules, from, to);

    /// Порожня клітинка бази означає різне в різних видів: у `D` порожній кінець —
    /// «рівно один вірш», у `P` і `OV` — «до кінця розділу».
    static bool Covers(NumberingRule rule, int chapter, int verse)
    {
        if (chapter < rule.ChapterBegin || chapter > rule.ChapterLast) return false;
        switch (rule.Kind)
        {
            case NumberingRuleKind.OffsetChapter: return true;
            case NumberingRuleKind.Displaced:
                if (rule.VerseBegin is not { } low) return false;
                return verse >= low && verse <= (rule.VerseEnd ?? low);
            default:
                var from = rule.VerseBegin ?? 1;
                if (verse < from) return false;
                return rule.VerseEnd is not { } high || verse <= high;
        }
    }

    /// Переведення набору віршів цілком, з ланцюжком. Адресу рахує СПІЛЬНИЙ рушій
    /// (`VerseNumbering`) — той, що збирає слайд; тут лише називаються правила.
    public static (List<VerseSpan> Spans, List<NumberingRule> Rules, List<string> Path) Translate(
        IReadOnlyList<NumberingRule> rules, int book, int chapter, IReadOnlyList<int> verses, string from, string to)
    {
        if (from == to || verses.Count == 0) return (new List<VerseSpan> { new(chapter, verses.ToList()) }, new(), new List<string> { from });
        var path = Route(rules, from, to);
        if (path.Count <= 1) return (new List<VerseSpan> { new(chapter, verses.ToList()) }, new(), path);

        var engine = VerseNumbering.Over(rules);
        var spans = engine.Translate(book, chapter, verses, new VerseNumberingStandard(from, from), new VerseNumberingStandard(to, to));

        var fired = new List<NumberingRule>();
        var current = verses.Select(v => (Chapter: chapter, Verse: v)).ToList();
        for (var index = 0; index < path.Count - 1; index++)
        {
            var stepFrom = path[index];
            var stepTo = path[index + 1];
            var next = new List<(int Chapter, int Verse)>();
            foreach (var address in current)
            {
                foreach (var rule in FiredRules(rules, book, address.Chapter, address.Verse, stepFrom, stepTo))
                    if (fired.All(r => r.Id != rule.Id)) fired.Add(rule);
                next.AddRange(engine.TranslateVerse(book, address.Chapter, address.Verse,
                                                     new VerseNumberingStandard(stepFrom, stepFrom), new VerseNumberingStandard(stepTo, stepTo)));
            }
            var seen = new HashSet<(int, int)>();
            current = next.Where(a => seen.Add(a)).ToList();
        }
        return (spans, fired, path);
    }

    /// Рядки, що накривають адресу, — у тому порядку важливості, що й у рушія:
    /// спершу `D`, далі `P`, інакше додавання `OC` і `OV`. Числа тут не рахуються.
    static List<NumberingRule> FiredRules(IReadOnlyList<NumberingRule> all, int book, int chapter, int verse, string from, string to)
    {
        var rules = all.Where(r => r.From == from && r.To == to && r.Book == book).ToList();
        if (rules.FirstOrDefault(r => r.Kind == NumberingRuleKind.Displaced && Covers(r, chapter, verse)) is { } displaced) return new() { displaced };
        if (rules.FirstOrDefault(r => r.Kind == NumberingRuleKind.Part && Covers(r, chapter, verse)) is { } part) return new() { part };
        var fired = new List<NumberingRule>();
        if (rules.FirstOrDefault(r => r.Kind == NumberingRuleKind.OffsetChapter && Covers(r, chapter, verse)) is { } chapterShift) fired.Add(chapterShift);
        if (rules.FirstOrDefault(r => r.Kind == NumberingRuleKind.OffsetVerse && Covers(r, chapter, verse)) is { } verseShift) fired.Add(verseShift);
        return fired;
    }

    /// Те саме зі словами про те, яким правилом отримано адресу (смуга пояснення).
    public (List<VerseSpan> Spans, string Reason, NumberingRule? Rule) Translate(int book, int chapter, IReadOnlyList<int> verses, string from, string to)
    {
        if (from == to) return (new() { new VerseSpan(chapter, verses.ToList()) }, T("стандарты совпадают, адрес не меняется"), null);
        var answer = Translate(Base.Rules, book, chapter, verses, from, to);
        if (answer.Path.Count <= 1) return (answer.Spans, T("дороги между стандартами нет, адрес не меняется"), null);
        string reason;
        if (answer.Rules.Count == 0) reason = T("правил для этого места нет, адрес не меняется");
        else
            reason = (answer.Rules.Count > 1 ? T("правила: ") : T("правило: "))
                   + string.Join("; ", answer.Rules.Select(rule => $"{KindTitle(rule.Kind)} {SourceText(rule)} → {TargetText(rule)} ({Title(Origin(rule))})"));
        if (answer.Path.Count > 2)
            reason = T("через %s стандарт: ", StandardShort(answer.Path[1])) + string.Join(" → ", answer.Path) + "; " + reason;
        return (answer.Spans, reason, answer.Rules.FirstOrDefault());
    }

    public string StandardCode(string moduleId)
    {
        if (_state.AllModules.FirstOrDefault(m => m.Identifier == moduleId) is not { } module) return "";
        return Base.StandardCode(new[] { module.Info.ShortName, module.Identifier }) ?? "";
    }

    // ── Текст для вкладки «Перевірка» ───────────────────────────────────────

    /// Розібрана книга перекладу; з диска тут не читаємо: чого немає — у чергу,
    /// дорисуємо, коли прийде.
    public IReadOnlyList<Chapter>? Chapters(string moduleId, int canonical)
    {
        if (_state.Module(moduleId) is not { } module || module.Books.FirstOrDefault(b => b.CanonicalNumber == canonical) is not { } book) return null;
        if (module.CachedChapters(book) is { } ready) return ready;
        var token = $"{moduleId}|{canonical}";
        if (!_pendingChapters.Add(token)) return null;
        Task.Run(() =>
        {
            try { module.Chapters(book); } catch { /* книга не читається — так і лишиться порожньою */ }
            Dispatcher.UIThread.Post(() => { _pendingChapters.Remove(token); CacheTick++; Changed?.Invoke(); });
        });
        return null;
    }

    /// Розбір рядка швидкого набору — тим самим розбором, що й поле головного вікна.
    public void ApplyAddressInput()
    {
        if ((_state.Module(CheckPrimary) ?? _state.PrimaryModule) is not { } module) return;
        if (ScriptureAddress.Parse(AddressInput, module.Books) is not { } address)
        {
            Status = T("адрес не разобран");
            return;
        }
        if (address.Book.CanonicalNumber is { } canonical) CheckBook = canonical;
        CheckChapter = address.Chapter ?? 1;
        CheckVerse = address.FirstVerse ?? (address.ListedVerses.Count > 0 ? address.ListedVerses[0] : 1);
        Status = "";
    }

    public void RefreshAddressInput() => AddressInput = $"{BookName(CheckBook)} {CheckChapter}:{CheckVerse}";

    // ── Звірка книги цілком ─────────────────────────────────────────────────

    /// Перевести кожен наявний вірш книги й порахувати промахи. Опорні числа:
    /// на Псалтирі RU_RST → KJV із 2527 віршів мимо проходить один; десятки —
    /// модулю призначено не той стандарт.
    public void VerifyBook()
    {
        if (IsVerifying) { StopVerify(); return; }
        var from = StandardCode(CheckPrimary);
        var to = StandardCode(CheckSecondary);
        if (from.Length == 0 || to.Length == 0) { ReportSummary = T("стандарт не назначен обоим переводам"); return; }
        if (_state.Module(CheckPrimary) is not { } source || _state.Module(CheckSecondary) is not { } target
            || source.Books.FirstOrDefault(b => b.CanonicalNumber == CheckBook) is not { } sourceBook
            || target.Books.FirstOrDefault(b => b.CanonicalNumber == CheckBook) is not { } targetBook)
        {
            ReportSummary = T("этой книги нет в одном из переводов");
            return;
        }
        var token = ++_verifyToken;
        var flag = _verifyFlag = new VerifyFlag();
        IsVerifying = true;
        Report = new();
        ReportSummary = T("сверяю…");
        var canonical = CheckBook;
        // Правила — значенням до фону: тисячі стрибків на головний потік заради тієї
        // самої таблиці — це й є «програма думає».
        var rules = Base.Rules.Select(r => r with { }).ToList();
        Task.Run(() =>
        {
          try
          {
            IReadOnlyList<Chapter> left, right;
            try { left = source.Chapters(sourceBook); } catch { left = Array.Empty<Chapter>(); }
            try { right = target.Chapters(targetBook); } catch { right = Array.Empty<Chapter>(); }
            var known = new HashSet<long>();
            foreach (var chapter in right)
                foreach (var verse in chapter.Verses) known.Add(chapter.Number * 100_000L + verse.Number);
            var lines = new List<ReportLine>();
            int total = 0, missed = 0, merged = 0;
            var hit = new HashSet<long>();
            foreach (var chapter in left)
            {
                if (flag.IsCancelled) break;
                foreach (var verse in chapter.Verses)
                {
                    if (flag.IsCancelled) break;
                    total++;
                    var answer = Translate(rules, canonical, chapter.Number, new[] { verse.Number }, from, to).Spans;
                    var landed = 0;
                    foreach (var span in answer)
                        foreach (var number in span.Verses)
                        {
                            var key = span.Chapter * 100_000L + number;
                            if (!known.Contains(key)) continue;
                            landed++;
                            if (!hit.Add(key)) merged++;
                        }
                    if (landed > 0) continue;
                    missed++;
                    if (lines.Count >= 40) continue;
                    var address = answer.Count > 0 ? ReferenceFormat.Position(answer[0].Chapter, answer[0].Verses) : "—";
                    lines.Add(new ReportLine(chapter.Number, verse.Number,
                        T("%s:%s → %s — такого места во втором переводе нет", chapter.Number.ToString(), verse.Number.ToString(), address)));
                }
            }
            var orphans = known.Count - hit.Count;
            var summary = flag.IsCancelled
                ? T("сверка остановлена на %s стихах", total.ToString())
                : T("стихов %s, мимо %s, без соответствия во втором переводе %s, слияний %s", total.ToString(), missed.ToString(), orphans.ToString(), merged.ToString());
            Dispatcher.UIThread.Post(() =>
            {
                if (_verifyToken != token) return;
                Report = lines;
                ReportSummary = summary;
                IsVerifying = false;
                Changed?.Invoke();
            });
          }
          catch (Exception error)
          {
              Dispatcher.UIThread.Post(() =>
              {
                  if (_verifyToken != token) return;
                  ReportSummary = error.Message;
                  IsVerifying = false;
                  Changed?.Invoke();
              });
          }
        });
    }

    public void StopVerify()
    {
        if (_verifyFlag != null) _verifyFlag.IsCancelled = true;
        IsVerifying = false;
        ReportSummary = T("сверка остановлена");
    }

    // ── Запис і відкат ──────────────────────────────────────────────────────

    public string UserFilePath => NumberingBase.UserUrl;
    public bool HasOwnCopy => File.Exists(NumberingBase.UserUrl);

    /// Записати свою копію. Відповідь — слово про помилку; null — записано.
    /// Правок немає — не пишемо нічого: порожня своя копія гірша за її відсутність.
    public string? Save()
    {
        if (OwnRowCount == 0)
        {
            IsDirty = false;
            _snapshot = Clone(Base);
            _snapshotRemoved = _removed.ToList();
            return null;
        }
        try
        {
            Base.Save();
            try { WriteOrigins(); } catch (Exception error) { Journal.Say($"нумерація: походження рядків — {error.Message}"); }
            MirrorOwnerChoices();
            _snapshot = Clone(Base);
            _snapshotRemoved = _removed.ToList();
            IsDirty = false;
            SourceNote = T("своя копия (правок: %s)", OwnRowCount.ToString());
            _state.ReloadNumbering();
            return null;
        }
        catch (Exception error) { return error.Message; }
    }

    /// Походження рядків — окремим файлом: у самій базі схема автора, і зайвий
    /// стовпець зламав би сумісність.
    void WriteOrigins()
    {
        var rules = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var rule in Base.Rules)
        {
            var origin = Origin(rule);
            if (origin != RowOrigin.Author) rules[Key(rule)] = Title(origin);
        }
        foreach (var rule in _removed) rules[Key(rule)] = Title(RowOrigin.Removed);
        var modules = new SortedDictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, code) in Base.Modules)
        {
            var had = _author.Modules.TryGetValue(name, out var authorCode);
            if (!had || authorCode != code) modules[name] = had ? Title(RowOrigin.Changed) : Title(RowOrigin.Added);
        }
        foreach (var name in _author.Modules.Keys) if (!Base.Modules.ContainsKey(name)) modules[name] = Title(RowOrigin.Removed);
        var json = JsonSerializer.Serialize(new SortedDictionary<string, object> { ["modules"] = modules, ["rules"] = rules, ["version"] = 1 },
                                            new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
        var path = Path.Combine(Path.GetDirectoryName(NumberingBase.UserUrl)!, "inconsistencies.origin.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllText(path + ".tmp", json);
        File.Move(path + ".tmp", path, overwrite: true);
    }

    /// Те саме призначення — у свій файл стандартів: двома шляхами його читають дві
    /// частини програми, і розходитися їм не можна.
    void MirrorOwnerChoices()
    {
        foreach (var row in ModuleRows)
            if (row.Standard.Length > 0 && row.Origin != StandardOrigin.Author) NumberingAssignments.Shared.SetOwnerChoice(row.Standard, row.Id);
        NumberingAssignments.Shared.ApplyKnown(_state.AllModules);
    }

    /// «Скасувати»: знімок повертається цілком, на диск нічого не йшло.
    public void Revert()
    {
        Base = Clone(_snapshot);
        _removed = _snapshotRemoved.ToList();
        IsDirty = false;
        RebuildModuleRows();
    }

    /// «Повернути все як в автора»: своя копія стирається, читаємо еталон.
    public void DropOwnCopy()
    {
        var authorCopy = Path.Combine(Path.GetDirectoryName(NumberingBase.UserUrl) ?? DataHome.Folder, "inconsistencies.author.sqlite3");
        if (SameFile(NumberingBase.UserUrl, NumberingBase.OriginalUrl(_dataRoot)))
        {
            // Тека даних і є тека «Слова» (звичайна установка): база автора й своя копія —
            // той самий файл. Стерти його — лишитися без нумерації зовсім (на Mac так і
            // стається). Повертаємо на місце побайтну копію автора, знято при відкритті.
            try { if (File.Exists(authorCopy)) File.Copy(authorCopy, NumberingBase.UserUrl, overwrite: true); }
            catch (Exception error) { Journal.Say($"нумерація: повернення бази автора — {error.Message}"); }
        }
        else
            try { File.Delete(NumberingBase.UserUrl); } catch { /* немає — і добре */ }
        try { File.Delete(Path.Combine(Path.GetDirectoryName(NumberingBase.UserUrl)!, "inconsistencies.origin.json")); } catch { }
        Base = Clone(_author);
        if (Base.Standards.Count == 0) Base.Standards = DefaultStandards.ToList();
        _removed = new();
        _snapshot = Clone(Base);
        _snapshotRemoved = new();
        _standardOrigins.Clear();
        IsDirty = false;
        SourceNote = T("файл автора");
        RefreshedNote = "";
        RebuildModuleRows();
        _state.ReloadNumbering();
    }

    /// Показати свою копію в Провіднику; ще не заведена — відкрити саму теку.
    public void RevealOwnCopy()
    {
        var path = NumberingBase.UserUrl;
        if (File.Exists(path)) { Explorer.Show(path); return; }
        var folder = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(folder);
        Explorer.Show(folder);
    }

    static bool SameFile(string one, string two) =>
        string.Equals(Path.GetFullPath(one), Path.GetFullPath(two), OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    /// Правки поза моделлю (лист правила) — позначити змінене.
    public void MarkDirty() => IsDirty = true;
}
