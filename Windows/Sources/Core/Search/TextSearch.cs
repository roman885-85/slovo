// =============================================================================
//  TextSearch.cs — пошук по тексту модуля (з Search/TextSearch.swift)
// =============================================================================
//  Межі збігів (`Highlights`) — у знаках UTF-16 вихідного рядка (так рахують
//  поля й підсвічування в .NET); на Mac — у знаках Swift (графемах). Для
//  кирилиці й латиниці без комбінованих позначок числа однакові.
// =============================================================================

using System.Diagnostics;
using System.Text;

namespace Slovo.Core;

/// Проміжок `LowerBound..<UpperBound` (у Swift — `Range<Int>`).
public readonly record struct IntRange(int LowerBound, int UpperBound)
{
    public int Count => UpperBound - LowerBound;
}

/// Пошук по тексту модуля — розділ 5.1.8 посібника.
///
/// «Слова можно писать не полностью. Поиск производится строго по введенным
/// словам.» Звідси правило відбору: запит ділиться на слова, і вірш підходить,
/// коли в ньому знайшлося КОЖНЕ слово — у будь-якому місці і в будь-якому порядку.
///
/// Модуль — це 31 тисяча віршів, і перший пошук зобов'язаний їх усі прочитати.
/// Тому читання йде у фоні, на головний потік повертаються лише готові
/// результати, а будь-який новий запит скасовує попередній. Згорнутий текст
/// лишається в `Index`, тому нормалізація оплачується один раз за модуль.
public sealed class TextSearch
{
    // ── Що шукати ───────────────────────────────────────────────────────────

    public sealed record Options
    {
        /// Скільки віршів показати. Слово «Бог» трапляється понад три тисячі разів.
        public int Limit { get; init; } = 300;
        /// Лише цілі слова: «дар» без «удар» і «дарования». У полі пошуку (8)
        /// завжди вимкнено: посібник просить не дописувати закінчення.
        public bool WholeWords { get; init; }
        /// Номери книг модуля, якими йти. `null` — весь модуль.
        public IReadOnlyList<int>? BookIndices { get; init; }
    }

    /// Розібраний запит: ті самі «введені слова». Згорнуті копії слів рахуємо
    /// один раз на запит, а не на кожен із 31 тисячі віршів.
    public sealed class Query
    {
        public string Text { get; }
        public IReadOnlyList<string> Words { get; }
        internal IReadOnlyList<string> FoldedWords { get; }

        public Query(string text)
        {
            var trimmed = text.TrimWhitespacesAndNewlines();
            Text = trimmed;
            // Розділяють і пробіли, і розділові знаки: власник — «при поиске
            // игнорировать знаки пунктуации, брать в поиск только слова». Апостроф
            // теж розділяє: «з'явився» стає двома словами.
            var parts = new List<string>();
            var current = new StringBuilder();
            foreach (var character in SwiftText.Characters(trimmed))
            {
                if (!SwiftText.IsLetter(character) && !SwiftText.IsNumber(character))
                {
                    if (current.Length > 0) parts.Add(current.ToString());
                    current.Clear();
                    continue;
                }
                current.Append(character);
            }
            if (current.Length > 0) parts.Add(current.ToString());
            Words = parts;
            FoldedWords = parts.Select(Index.Fold).Where(word => word.Length > 0).ToList();
        }

        public bool IsEmpty => FoldedWords.Count == 0;
    }

    // ── Що знайшли ──────────────────────────────────────────────────────────

    public sealed record Hit
    {
        public int BookIndex { get; }
        public string BookName { get; }        // скорочення для підпису
        public int Chapter { get; }
        public int Verse { get; }
        /// Повний текст вірша — він же піде на слайд.
        public string Text { get; }
        /// Зсуви всіх знайдених слів у `Text`, за зростанням і без перекриттів.
        public IReadOnlyList<IntRange> Highlights { get; }

        public Hit(int bookIndex, string bookName, int chapter, int verse, string text, IReadOnlyList<IntRange> highlights)
        {
            BookIndex = bookIndex;
            BookName = bookName;
            Chapter = chapter;
            Verse = verse;
            Text = text;
            Highlights = highlights;
        }

        public string Id => $"{BookIndex}.{Chapter}.{Verse}";

        public string Reference => $"{BookName} {Chapter}:{Verse}";

        /// Перший збіг — ним підписано вірш, до нього прокручується список.
        public IntRange Highlight => Highlights.Count > 0 ? Highlights[0] : new IntRange(0, 0);

        /// Шматок рядка і ознака «це знайдене слово».
        public readonly record struct Segment(string Text, bool IsMatch);

        /// Текст вірша, розкладений на шматки для підсвічування.
        public List<Segment> Segments => TextSearch.Segments(Text, Highlights);

        public bool Equals(Hit? other) =>
            other is not null && BookIndex == other.BookIndex && BookName == other.BookName && Chapter == other.Chapter
            && Verse == other.Verse && Text == other.Text && Highlights.SequenceEqual(other.Highlights);

        public override int GetHashCode() => HashCode.Combine(BookIndex, Chapter, Verse);
    }

    public sealed record Outcome(string Query, IReadOnlyList<Hit> Hits, bool IsTruncated, int ScannedVerses, double Duration)
    {
        public static Outcome Empty(string query) => new(query, Array.Empty<Hit>(), false, 0, 0);
    }

    // ── Згорнутий текст модуля ──────────────────────────────────────────────

    /// Усі вірші модуля із заздалегідь згорнутою копією тексту: згорнуті вірші
    /// лежать підряд в одному буфері, а порівняння йде по знаках.
    public sealed class Index
    {
        internal readonly record struct Entry(int BookIndex, string BookName, int Chapter, int Verse, string Text,
                                              int FoldedStart, int FoldedLength);

        public string ModuleIdentifier { get; }
        internal readonly List<Entry> Entries;
        internal readonly string Storage;

        public int VerseCount => Entries.Count;

        private Index(string moduleIdentifier, List<Entry> entries, string storage)
        {
            ModuleIdentifier = moduleIdentifier;
            Entries = entries;
            Storage = storage;
        }

        /// Читає і згортає весь модуль. `null` — збирання скасували на півдорозі;
        /// половину модуля запам'ятовувати не можна, інакше пошук мовчки брехатиме.
        public static Index? Build(TextModule module, Func<bool>? isCancelled = null, Action<double>? progress = null)
        {
            var entries = new List<Entry>(32_000);
            var storage = new StringBuilder(4 << 20);
            var books = module.Books;

            for (var position = 0; position < books.Count; position++)
            {
                if (isCancelled?.Invoke() == true) return null;
                var book = books[position];
                IReadOnlyList<Chapter> chapters;
                try { chapters = module.Chapters(book); }
                catch { continue; }
                var bookName = book.ShortNames.Count > 0 ? book.ShortNames[0] : book.FullName;

                foreach (var chapter in chapters)
                {
                    foreach (var verse in chapter.Verses)
                    {
                        var start = storage.Length;
                        storage.Append(Fold(verse.Text));
                        entries.Add(new Entry(book.Index, bookName, chapter.Number, verse.Number, verse.Text,
                                              start, storage.Length - start));
                    }
                }
                progress?.Invoke((double)(position + 1) / Math.Max(books.Count, 1));
            }
            return new Index(module.Identifier, entries, storage.ToString());
        }

        internal static string Fold(string text) => SwiftText.Fold(text);
    }

    // ── Фоновий пошук ───────────────────────────────────────────────────────

    private readonly object gate = new();
    private readonly object queueGate = new();
    private Task queueTail = Task.CompletedTask;
    /// Номер живого запиту. Скасування — це зміна номера, а не спільний прапорець.
    private int currentToken;
    /// Чіпається лише з черги, тому замка не вимагає.
    private Index? index;

    public TextSearch() { }

    /// Послідовна черга (на Mac — `DispatchQueue` «ua.slovo.text-search»).
    private void Enqueue(Action work)
    {
        lock (queueGate)
            queueTail = queueTail.ContinueWith(_ => work(), CancellationToken.None,
                                               TaskContinuationOptions.None, TaskScheduler.Default);
    }

    /// Віддати результат «на головний потік»: у контекст, з якого кликали.
    private static void Post(SynchronizationContext? context, Action action)
    {
        if (context != null) context.Post(_ => action(), null);
        else action();
    }

    /// Запускає пошук, скасувавши попередній. Обидва замикання кличуться в
    /// контексті потоку, що кликав (головному); у скасованого запиту — жодне.
    /// `progress` — частка прочитаного модуля, 0…1, лише при першому звертанні.
    public void Start(string query, TextModule module, Options? options = null,
                      Action<double>? progress = null, Action<Outcome>? completion = null)
    {
        var context = SynchronizationContext.Current;
        int token;
        lock (gate) token = ++currentToken;

        var trimmed = query.TrimWhitespacesAndNewlines();
        if (trimmed.Length == 0)
        {
            Post(context, () => completion?.Invoke(Outcome.Empty(trimmed)));
            return;
        }

        Enqueue(() =>
        {
            bool Stale() => IsStale(token);
            // Хід будується один раз на модуль і за зміни запиту не скасовується:
            // інакше набір по літері не давав би йому закінчитися. Прогрес теж
            // шлемо завжди, навіть застарілому запиту.
            var prepared = PreparedIndex(module, value =>
            {
                if (progress != null) Post(context, () => progress(value));
            });
            if (prepared == null) return;

            var outcome = Search(trimmed, prepared, options ?? new Options(), Stale);
            if (Stale()) return;
            Post(context, () => completion?.Invoke(outcome));
        });
    }

    /// Побудувати хід заздалегідь, нічого не шукаючи.
    public void Prepare(TextModule module, Action<double>? progress = null, Action? completion = null)
    {
        var context = SynchronizationContext.Current;
        Enqueue(() =>
        {
            PreparedIndex(module, value =>
            {
                if (progress != null) Post(context, () => progress(value));
            });
            if (completion != null) Post(context, completion);
        });
    }

    /// Забути поточний запит: його результат уже не прийде.
    public void Cancel()
    {
        lock (gate) currentToken++;
    }

    /// Віддати пам'ять, зайняту згорнутим текстом. Сам модуль не чіпаємо.
    public void ReleaseIndex() => Enqueue(() => index = null);

    private bool IsStale(int token)
    {
        lock (gate) return token != currentToken;
    }

    private Index? PreparedIndex(TextModule module, Action<double>? progress)
    {
        if (index != null && index.ModuleIdentifier == module.Identifier) return index;
        var built = Index.Build(module, null, progress);
        if (built == null) return null;
        index = built;
        return built;
    }

    // ── Сам обхід ───────────────────────────────────────────────────────────

    /// Разовий синхронний пошук: сам збирає індекс і сам його викидає.
    public static Outcome Run(string query, TextModule module, Options? options = null,
                              Func<bool>? isCancelled = null, Action<double>? progress = null)
    {
        var trimmed = query.TrimWhitespacesAndNewlines();
        if (trimmed.Length == 0) return Outcome.Empty(trimmed);
        var built = Index.Build(module, isCancelled, progress);
        if (built == null) return Outcome.Empty(trimmed);
        return Search(trimmed, built, options ?? new Options(), isCancelled);
    }

    public static Outcome Search(string query, Index index, Options? options = null, Func<bool>? isCancelled = null) =>
        Search(new Query(query), index, options, isCancelled);

    /// Пошук за готовим індексом. Відбір двоступеневий: за згорнутим текстом
    /// відсіюємо все зайве, і лише для вцілілих віршів шукаємо межі збігу у
    /// вихідному рядку. Вірш підходить, коли в ньому знайшлися ВСІ слова запиту.
    public static Outcome Search(Query query, Index index, Options? options = null, Func<bool>? isCancelled = null)
    {
        options ??= new Options();
        var clock = Stopwatch.StartNew();
        if (query.IsEmpty) return Outcome.Empty(query.Text);

        var wanted = options.BookIndices is { } indices ? new HashSet<int>(indices) : null;
        var hits = new List<Hit>();
        var scanned = 0;
        var truncated = false;
        var storage = index.Storage.AsSpan();

        foreach (var entry in index.Entries)
        {
            if ((scanned & 0x3FF) == 0 && isCancelled?.Invoke() == true) break;
            if (wanted != null && !wanted.Contains(entry.BookIndex)) continue;
            scanned += 1;

            // Швидкий відсів: хоча б одного слова немає — вірш мимо.
            var folded = storage.Slice(entry.FoldedStart, entry.FoldedLength);
            var missing = false;
            foreach (var word in query.FoldedWords)
            {
                if (folded.IndexOf(word.AsSpan(), StringComparison.Ordinal) >= 0) continue;
                missing = true;
                break;
            }
            if (missing) continue;

            var ranges = Highlights(query.Words, entry.Text, options.WholeWords);
            // Згорнутий рядок міняє довжину («ß» → «ss»), тому збіг у згорнутому
            // тексті зрідка не підтверджується в самому вірші. Такий вірш не показуємо.
            if (ranges.Count == 0) continue;
            if (hits.Count >= options.Limit)
            {
                truncated = true;
                break;
            }
            hits.Add(new Hit(entry.BookIndex, entry.BookName, entry.Chapter, entry.Verse, entry.Text, ranges));
        }

        return new Outcome(query.Text, hits, truncated, scanned, clock.Elapsed.TotalSeconds);
    }

    /// Розкласти рядок на шматки за знайденими відрізками. Спільна для віршів і пісень.
    public static List<Hit.Segment> Segments(string text, IReadOnlyList<IntRange> highlights)
    {
        var result = new List<Hit.Segment>();
        var position = 0;
        foreach (var range in highlights)
        {
            var lower = Math.Min(Math.Max(range.LowerBound, position), text.Length);
            var upper = Math.Min(Math.Max(range.UpperBound, lower), text.Length);
            if (lower > position) result.Add(new Hit.Segment(text[position..lower], false));
            if (upper > lower) result.Add(new Hit.Segment(text[lower..upper], true));
            position = upper;
        }
        if (position < text.Length) result.Add(new Hit.Segment(text[position..], false));
        return result;
    }

    /// Усі входження всіх слів запиту у вірш. Порожній список означає «вірш не
    /// підходить»: слово, якого немає, робить негодним весь вірш.
    public static List<IntRange> Highlights(IReadOnlyList<string> words, string text, bool wholeWords)
    {
        if (words.Count == 0 || text.Length == 0) return new List<IntRange>();
        var prepared = SwiftText.FoldedSearch.Prepare(text);
        var found = new List<IntRange>();

        foreach (var word in words)
        {
            if (word.Length == 0) continue;
            var ranges = AllMatches(word, text, prepared, wholeWords);
            if (ranges.Count == 0) return new List<IntRange>();
            found.AddRange(ranges);
        }

        // Слова запиту можуть перетнутися в тексті («сын» і «сына») — склеюємо.
        found.Sort((a, b) => a.LowerBound == b.LowerBound ? a.UpperBound.CompareTo(b.UpperBound) : a.LowerBound.CompareTo(b.LowerBound));
        var merged = new List<IntRange>();
        foreach (var range in found)
        {
            if (merged.Count > 0 && range.LowerBound <= merged[^1].UpperBound)
                merged[^1] = new IntRange(merged[^1].LowerBound, Math.Max(merged[^1].UpperBound, range.UpperBound));
            else
                merged.Add(range);
        }
        return merged;
    }

    /// Кожне входження слова у вірш — у зсувах вихідного рядка.
    private static List<IntRange> AllMatches(string needle, string text, SwiftText.FoldedSearch prepared, bool wholeWords)
    {
        var result = new List<IntRange>();
        if (needle.Length == 0) return result;
        var folded = SwiftText.Fold(needle);
        var from = 0;
        while (from < text.Length && prepared.Find(folded, from) is { } range)
        {
            if (!wholeWords || IsWholeWord(range.Start, range.End, text)) result.Add(new IntRange(range.Start, range.End));
            // З наступного знака, а не з кінця збігу: інакше «аа» в «ааа»
            // знайшлося б один раз замість двох.
            if (range.Start >= text.Length) break;
            from = range.Start + 1;
        }
        return result;
    }

    /// Перший збіг у вірші (у Swift — `Range<String.Index>`).
    public static (int Start, int End)? FirstMatch(string needle, string text, bool wholeWords)
    {
        if (needle.Length == 0 || text.Length == 0) return null;
        var prepared = SwiftText.FoldedSearch.Prepare(text);
        var folded = SwiftText.Fold(needle);
        var from = 0;
        while (from < text.Length && prepared.Find(folded, from) is { } range)
        {
            if (!wholeWords || IsWholeWord(range.Start, range.End, text)) return range;
            if (range.Start >= text.Length) break;
            from = range.Start + 1;
        }
        return null;
    }

    private static bool IsWholeWord(int start, int end, string text)
    {
        if (start > 0)
        {
            // Знак Swift перед збігом — разом із позначками, що до нього прилипли.
            var before = start - 1;
            while (before > 0 && (SwiftText.IsMark(text[before]) || char.IsLowSurrogate(text[before]))) before--;
            var character = CharacterAt(text, before);
            if (SwiftText.IsLetter(character) || SwiftText.IsNumber(character)) return false;
        }
        if (end < text.Length)
        {
            var character = CharacterAt(text, end);
            if (SwiftText.IsLetter(character) || SwiftText.IsNumber(character)) return false;
        }
        return true;
    }

    private static string CharacterAt(string text, int index) =>
        char.IsHighSurrogate(text[index]) && index + 1 < text.Length ? text.Substring(index, 2) : text[index].ToString();
}
