// =============================================================================
//  AppState.Search.cs — пошук (8) і вікно результатів (5), як у DeskModel на Mac
// =============================================================================
//  Набір у полі «Пошук» сам відкриває вікно результатів («вікно з'являється
//  лише, якщо набрали рядок для пошуку») і через 0,25 с шукає в основному
//  перекладі — попередній запит скасовується, проміжні результати не потрібні.
//  Хід по модулю будується один раз (TextSearch тримає його в черзі) — і
//  заздалегідь, коли курсор лише ставлять у поле. Змінили вкладку чи основний
//  переклад — набране слово шукається знову, уже там.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    readonly TextSearch _search = new();
    DispatcherTimer? _searchDelay;

    /// Те, що зараз набрано в полі (8).
    public string SearchQuery { get; private set; } = "";
    /// Вікно результатів (5) видно: набрали слово, Ctrl+F3 або кнопка (6.1).
    public bool IsSearchResultsShown { get; private set; }
    public IReadOnlyList<TextSearch.Hit> Hits { get; private set; } = Array.Empty<TextSearch.Hit>();
    public bool IsSearching { get; private set; }
    /// Частка прочитаного модуля, поки будується хід; null — не будується.
    public double? IndexProgress { get; private set; }
    public bool IsSearchTruncated { get; private set; }
    public string SearchedQuery { get; private set; } = "";
    string _searchedModuleId = "";

    /// Поставити курсор у поле пошуку (F3): поле живе у смузі перекладів.
    public event Action? SearchFieldFocusRequested;
    public void FocusSearchField() => SearchFieldFocusRequested?.Invoke();

    /// Скільки рядків у вікні результатів — за відкритою вкладкою.
    public int HitCount => Mode == WorkMode.Songs ? SongHits.Count : Hits.Count;

    /// Знахідка на вкладці «Пісні»: пісня (з нуля), частина (null — знайшлося в назві),
    /// підпис «12. Назва — Куплет» і рядок частини, де переноси стали « / ».
    public sealed record SongHit(int SongIndex, int? PartIndex, string Title, string Text, IReadOnlyList<IntRange> Highlights)
    {
        public List<TextSearch.Hit.Segment> Segments => TextSearch.Segments(Text, Highlights);
    }
    public IReadOnlyList<SongHit> SongHits { get; private set; } = Array.Empty<SongHit>();
    /// Номер останнього пошуку за піснями: відповідь застарілого приходить із фону й відкидається.
    int _songSearchToken;
    /// Пісні відкритого Пісенника, відкрити знахідку, чи стоїть на ній курсор — дає вкладка «Пісні».
    public Func<IReadOnlyList<Song>?>? OpenSongs;
    public Action<int, int?, bool>? RevealSong;
    public Func<SongHit, bool>? IsCurrentSongHit;

    void SearchChanged() => Signals.Shared.Send(Signals.Kind.SearchResults);

    /// Відповіді пошуку приходять у контекст потоку, що кликав; якщо його
    /// немає (знімки без екрана), переносимо на головний потік самі.
    static void OnUi(Action action)
    {
        if (Dispatcher.UIThread.CheckAccess()) action();
        else Dispatcher.UIThread.Post(action);
    }

    void SetSearchResultsShown(bool shown)
    {
        if (IsSearchResultsShown == shown) return;
        IsSearchResultsShown = shown;
        Signals.Shared.Send(Signals.Kind.Layout);
    }

    /// Набір у полі (8).
    public void SearchQueryChanged(string query)
    {
        SearchQuery = query;
        var trimmed = query.Trim();
        if (trimmed.Length > 0) SetSearchResultsShown(true);
        _searchDelay?.Stop();
        if (trimmed.Length == 0) { RunSearch(""); return; }
        _searchDelay = new DispatcherTimer(TimeSpan.FromSeconds(0.25), DispatcherPriority.Normal, (sender, _) =>
        {
            ((DispatcherTimer)sender!).Stop();
            RunSearch(trimmed);
        });
        _searchDelay.Start();
    }

    /// Кнопка (6.1) «Показати / сховати результати пошуку» і Ctrl+F3.
    public void ToggleSearchResults() => SetSearchResultsShown(!IsSearchResultsShown);
    public void HideSearchResults() => SetSearchResultsShown(false);

    /// Курсор поставили в поле пошуку — саме час будувати хід по модулю:
    /// краще заплатити ці секунди, поки оператор лише тягнеться до поля.
    public void PrepareSearch()
    {
        if (PrimaryModule is not { } module) return;
        if (module.Identifier == _searchedModuleId && Hits.Count > 0) return;
        _search.Prepare(module,
            value => OnUi(() => { IndexProgress = value < 1 ? value : null; SearchChanged(); }),
            () => OnUi(() => { IndexProgress = null; SearchChanged(); }));
    }

    /// Пошук у поточному перекладі; попередній запит скасовується.
    public void RunSearch(string query)
    {
        var trimmed = query.Trim();
        // На вкладці «Пісні» шукаємо в Пісеннику — вірші там ні до чого.
        if (Mode == WorkMode.Songs)
        {
            _search.Cancel();
            Hits = Array.Empty<TextSearch.Hit>();
            IndexProgress = null;
            RunSongSearch(trimmed);
            return;
        }
        SongHits = Array.Empty<SongHit>();
        if (trimmed.Length == 0 || PrimaryModule is not { } module)
        {
            _search.Cancel();
            Hits = Array.Empty<TextSearch.Hit>();
            IsSearching = false;
            IndexProgress = null;
            IsSearchTruncated = false;
            SearchedQuery = "";
            SearchChanged();
            return;
        }
        IsSearching = true;
        SearchedQuery = trimmed;
        _searchedModuleId = module.Identifier;
        SearchChanged();
        _search.Start(trimmed, module, new TextSearch.Options { Limit = 500 },
            value => OnUi(() => { IndexProgress = value < 1 ? value : null; SearchChanged(); }),
            outcome => OnUi(() =>
            {
                Hits = outcome.Hits;
                IsSearchTruncated = outcome.IsTruncated;
                IsSearching = false;
                IndexProgress = null;
                SearchChanged();
            }));
    }

    /// Пошук у відкритому Пісеннику — у назвах і тексті частин. Слова запиту
    /// з'єднуються «і», як у віршів; перебір тисяч пісень іде у фоні, щоб вікно листалося.
    void RunSongSearch(string query)
    {
        var token = ++_songSearchToken;
        if (query.Length == 0 || OpenSongs?.Invoke() is not { } open)
        {
            SongHits = Array.Empty<SongHit>();
            IsSearching = false;
            IsSearchTruncated = false;
            SearchedQuery = "";
            SearchChanged();
            return;
        }
        IsSearching = true;
        SearchedQuery = query;
        SearchChanged();
        var words = new TextSearch.Query(query).Words;
        var songs = open.ToList();
        var started = DateTime.Now;
        Task.Run(() =>
        {
            var found = new List<SongHit>();
            var truncated = false;
            foreach (var song in songs)
            {
                var number = song.Index + 1;
                var inTitle = TextSearch.Highlights(words, song.Title, false);
                if (inTitle.Count > 0) found.Add(new SongHit(song.Index, null, $"{number}. {song.Title}", song.Title, inTitle));
                for (var position = 0; position < song.Parts.Count && !truncated; position++)
                {
                    var part = song.Parts[position];
                    // Частина багаторядкова, а рядок результату один: переноси — « / », як читають уголос.
                    var line = part.Text.Replace("\r\n", " / ").Replace("\n", " / ");
                    var ranges = TextSearch.Highlights(words, line, false);
                    if (ranges.Count == 0) continue;
                    found.Add(new SongHit(song.Index, position, $"{number}. {song.Title} — {part.Kind}", line, ranges));
                    if (found.Count >= 500) truncated = true;
                }
                if (truncated) break;
            }
            Dispatcher.UIThread.Post(() =>
            {
                Journal.Say($"пошук за піснями: №{token} «{query}» знайшов {found.Count} за {(DateTime.Now - started).TotalSeconds:0.00} с"
                            + (token == _songSearchToken ? "" : " — застарів, відкинуто"));
                if (token != _songSearchToken) return;
                SongHits = found;
                IsSearchTruncated = truncated;
                IsSearching = false;
                SearchChanged();
            });
        });
    }

    /// Змінили вкладку чи переклад при набраному запиті — шукаємо знову.
    public void RerunSearch()
    {
        var query = SearchQuery.Trim();
        if (query.Length == 0) return;
        RunSearch(query);
    }

    /// Рядок результату вибрано: курсор на цей вірш; `live` — одразу в зал
    /// (подвійне клацання), як у списку віршів.
    public void ShowHit(TextSearch.Hit hit, bool live) =>
        OpenPlace(hit.BookIndex, hit.Chapter, new[] { hit.Verse }, live);

    /// Чи стоїть курсор на цьому рядку результату.
    public bool IsCurrentHit(TextSearch.Hit hit) =>
        hit.BookIndex == CurrentBook?.Index && hit.Chapter == SelectedChapterNumber
        && SelectedVerseNumbers.Contains(hit.Verse);
}
