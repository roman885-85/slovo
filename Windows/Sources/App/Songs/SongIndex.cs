// =============================================================================
//  SongIndex.cs — назви пісень для швидкого вибору (як NativeSongIndex на Mac)
// =============================================================================
//  Назва згортається один раз (регістр, діакритика, ё→е; лишаються літери й
//  цифри, решта — один пробіл) у фоні; набране слово шукається як ПОЧАТОК
//  слова назви чи другої назви, кожне слово набору. Число — номер пісні або
//  номер у збірнику ($ID$). Поки згортки нема — повільніший прохід за назвами.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public static class SongFold
{
    public static string Fold(string text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var folded = SwiftText.Fold(text).Replace("ё", "е").Replace("Ё", "е");
        var builder = new System.Text.StringBuilder(folded.Length);
        var space = true;
        foreach (var c in folded)
        {
            if (char.IsLetterOrDigit(c)) { builder.Append(c); space = false; }
            else if (!space) { builder.Append(' '); space = true; }
        }
        if (builder.Length > 0 && builder[^1] == ' ') builder.Length--;
        return builder.ToString();
    }

    public static string[] Words(string text) => Fold(text).Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// Кожне слово набору починає якесь слово назви.
    public static bool Matches(string haystack, string[] needles) => needles.All(n => StartsWord(haystack, n));

    public static bool StartsWord(string haystack, string needle)
    {
        if (needle.Length == 0) return true;
        for (var start = haystack.IndexOf(needle, StringComparison.Ordinal); start >= 0; start = haystack.IndexOf(needle, start + 1, StringComparison.Ordinal))
            if (start == 0 || haystack[start - 1] == ' ') return true;
        return false;
    }

    public static bool Contains(string haystack, string needle) => needle.Length == 0 || haystack.Contains(needle, StringComparison.Ordinal);
}

public sealed class SongIndex
{
    sealed class Bundle
    {
        public List<string> Titles = new(), Subtitles = new(), Folded = new(), Alternates = new();
        public List<int?> Catalog = new();
        public bool IsReady;
    }

    Bundle _bundle = new();
    static readonly Dictionary<string, Bundle> Cache = new();
    static readonly List<string> Recent = new();
    const int CacheLimit = 3;

    public IReadOnlyList<string> Titles => _bundle.Titles;
    public IReadOnlyList<string> Subtitles => _bundle.Subtitles;
    public IReadOnlyList<int?> CatalogNumbers => _bundle.Catalog;
    public bool IsReady => _bundle.IsReady;
    public string Key { get; private set; } = "";
    public int HurriedFolds { get; private set; }
    public Action? OnReady;
    public int Count => _bundle.Titles.Count;

    public void Open(IReadOnlyList<Song> songs, string key)
    {
        Key = key;
        if (Cache.TryGetValue(key, out var ready)) { _bundle = ready; Touch(key); return; }
        var bundle = new Bundle
        {
            Titles = songs.Select(s => s.Title).ToList(),
            Subtitles = songs.Select(s => Subtitle(s.Author, s.Composer)).ToList(),
        };
        _bundle = bundle;
        Remember(key, bundle);
        var titles = songs.Select(s => s.Title).ToList();
        var alternates = songs.Select(s => s.AlternateTitle).ToList();
        var properties = songs.Select(s => s.Properties).ToList();
        Task.Run(() =>
        {
            var folded = titles.Select(SongFold.Fold).ToList();
            var foldedAlternates = alternates.Select(SongFold.Fold).ToList();
            var catalog = properties.Select(CatalogNumber).ToList();
            Dispatcher.UIThread.Post(() =>
            {
                bundle.Folded = folded;
                bundle.Alternates = foldedAlternates;
                bundle.Catalog = catalog;
                bundle.IsReady = true;
                if (Key == key) { _bundle = bundle; OnReady?.Invoke(); }
            });
        });
    }

    static string Subtitle(string author, string composer) =>
        author.Length == 0 ? composer : composer.Length == 0 || author == composer ? author : author + " / " + composer;

    static int? CatalogNumber(string properties)
    {
        if (properties.Length == 0) return null;
        foreach (var raw in properties.Split('\n', '\r'))
        {
            var line = raw.Trim();
            if (line.StartsWith("$ID$=") && int.TryParse(line[5..].Trim(), out var n)) return n;
        }
        return null;
    }

    static void Remember(string key, Bundle bundle)
    {
        Cache[key] = bundle;
        Touch(key);
        while (Recent.Count > CacheLimit) { Cache.Remove(Recent[0]); Recent.RemoveAt(0); }
    }

    static void Touch(string key) { Recent.Remove(key); Recent.Add(key); }

    /// Номери пісень (у пісеннику) за набраним; null — без фільтра.
    public List<int>? Filter(string query, IReadOnlyList<int>? group)
    {
        var trimmed = query.Trim();
        if (trimmed.Length == 0) return group?.ToList();
        IEnumerable<int> Pool() => group ?? Enumerable.Range(0, _bundle.Titles.Count);
        if (int.TryParse(trimmed, out var number))
        {
            var catalog = _bundle.Catalog;
            var byNumber = Pool().Where(i => i + 1 == number || (i < catalog.Count && catalog[i] == number)).ToList();
            if (byNumber.Count > 0) return byNumber;
        }
        var needles = SongFold.Words(trimmed);
        if (needles.Length == 0) return group?.ToList();
        if (!_bundle.IsReady)
        {
            HurriedFolds++;
            var titles = _bundle.Titles;
            var folded = SwiftText.Fold(trimmed);
            return Pool().Where(i => i < titles.Count && SwiftText.Fold(titles[i]).Contains(folded)).ToList();
        }
        var f = _bundle.Folded; var a = _bundle.Alternates;
        return Pool().Where(i => i < f.Count && (SongFold.Matches(f[i], needles) || SongFold.Matches(a[i], needles))).ToList();
    }
}
