// =============================================================================
//  Signals.cs — точкові сповіщення вікна
// =============================================================================
//  Як на Mac (NativeSignals): натискання міняє одну частину вікна, і сповіщення
//  отримують лише ті, хто підписався саме на цей привід. Ніякого загального
//  перерахунку всього вікна — саме загальний перерахунок гальмував ранні версії.
//  Привід, що прийшов під час доставки того самого приводу, ставиться в чергу;
//  `Batch` збирає кілька приводів і доставляє кожен один раз.
// =============================================================================

namespace Slovo.App;

public sealed class Signals
{
    public static readonly Signals Shared = new();

    public enum Kind
    {
        Mode, BookClass, Books, BookSelection, Chapters, ChapterSelection, Verses, VerseSelection,
        Translations, Library, SongBook, SongFilter, SongSelection, SongPart, ListFontSize, ListKind,
        Slide, Live, Language, Plan, History, SearchResults, Layout,
    }

    public sealed class Token : IDisposable
    {
        internal readonly HashSet<Kind> Kinds;
        internal readonly Action<Kind> Body;
        internal readonly string Origin;
        internal bool Alive = true;
        readonly Signals _owner;

        internal Token(HashSet<Kind> kinds, Action<Kind> body, Signals owner, string origin)
        { Kinds = kinds; Body = body; _owner = owner; Origin = origin; }

        public void Dispose() { Alive = false; _owner.Forget(this); }
    }

    readonly Dictionary<Kind, List<Token>> _slots = new();
    int _batchDepth;
    readonly HashSet<Kind> _pending = new();
    readonly HashSet<Kind> _delivering = new();

    public Token Subscribe(IEnumerable<Kind> kinds, Action<Kind> body,
                           [System.Runtime.CompilerServices.CallerFilePath] string file = "",
                           [System.Runtime.CompilerServices.CallerLineNumber] int line = 0)
    {
        var set = new HashSet<Kind>(kinds);
        var token = new Token(set, body, this, $"{Path.GetFileName(file)}:{line}");
        foreach (var kind in set)
        {
            if (!_slots.TryGetValue(kind, out var list)) _slots[kind] = list = new List<Token>();
            list.Add(token);
        }
        return token;
    }

    public Token Subscribe(Kind kind, Action body,
                           [System.Runtime.CompilerServices.CallerFilePath] string file = "",
                           [System.Runtime.CompilerServices.CallerLineNumber] int line = 0) =>
        Subscribe(new[] { kind }, _ => body(), file, line);

    void Forget(Token token)
    {
        foreach (var kind in token.Kinds)
            if (_slots.TryGetValue(kind, out var list)) list.Remove(token);
    }

    /// Заміри: які підписники повільні (для самоперевірки швидкості).
    public bool Profiling { get; set; }
    public readonly List<(Kind Kind, string Origin, double Ms)> SlowCalls = new();

    public void Send(Kind kind)
    {
        if (_batchDepth > 0 || _delivering.Contains(kind)) { _pending.Add(kind); return; }
        _delivering.Add(kind);
        try
        {
            if (!_slots.TryGetValue(kind, out var list)) return;
            foreach (var token in list.ToArray())
            {
                if (!token.Alive) continue;
                if (Profiling)
                {
                    var started = System.Diagnostics.Stopwatch.GetTimestamp();
                    token.Body(kind);
                    var ms = System.Diagnostics.Stopwatch.GetElapsedTime(started).TotalMilliseconds;
                    if (ms >= 1) SlowCalls.Add((kind, token.Origin, ms));
                }
                else token.Body(kind);
            }
        }
        finally
        {
            _delivering.Remove(kind);
            if (_delivering.Count == 0 && _batchDepth == 0 && _pending.Count > 0)
            {
                var queued = _pending.ToArray();
                _pending.Clear();
                foreach (var next in queued) Send(next);
            }
        }
    }

    /// Кілька змін разом: кожен привід доставляється один раз, у кінці.
    public void Batch(Action body)
    {
        _batchDepth++;
        try { body(); }
        finally { _batchDepth--; }
        if (_batchDepth > 0) return;
        var queued = _pending.ToArray();
        _pending.Clear();
        foreach (var kind in queued) Send(kind);
    }

    public int SubscriberCount(Kind kind) => _slots.TryGetValue(kind, out var l) ? l.Count(t => t.Alive) : 0;
}
