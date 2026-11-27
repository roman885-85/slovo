// =============================================================================
//  ShowModel.cs — показ картинок і презентацій (як ShowModel на Mac)
// =============================================================================
//  Одна машина на два режими: «відкрити — вибрати — показати — гортати» в
//  світлини й у сторінки презентації те саме. Список накопичується: додане
//  стає в кінець, «Закрити» прибирає все. Джерел у сторінки три: файл
//  картинки, презентація PowerPoint і PDF — далі вони нерозрізненні: кадр
//  іде в зал тією ж дорогою. У презентацій колода — файл зі сторінками; у
//  картинок кожна картинка — своя колода з однієї сторінки. Відкрите
//  пам'ятається між запусками (showPictureFiles / showPresentationFiles).
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

/// Розібраний документ показу (презентація чи PDF): скільки сторінок і кадр сторінки.
public interface IShowDocument : IDisposable
{
    int Count { get; }
    /// Сторінка заввишки `height` (у висоту залу — менше дасть мило на проекторі).
    SKImage? Render(int page, int height);
}

public sealed class ShowModel
{
    public enum Kind { Pictures, Presentation }

    public static IReadOnlyList<string> Extensions(Kind kind) => kind == Kind.Pictures
        ? new[] { "jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp" }
        : new[] { "pptx", "ppsx", "potx", "pptm", "ppsm", "pdf" };

    /// Звідки береться кадр сторінки: файл картинки або сторінка документа.
    public sealed record Source(string? Picture, int Document = -1, int Page = -1);

    /// Повне ім'я — для підпису й залу («Проповідь — Слайд 3»), коротке — для колонки сторінок.
    public sealed record Page(string Title, string Short, Source Source);

    /// Відкритий файл показу і його сторінки підряд у Pages.
    public sealed record Deck(string Name, string Path, int Start, int Count)
    {
        public int End => Start + Count;
        public bool Contains(int index) => index >= Start && index < End;
    }

    /// Відкривачі документів: презентація (.pptx…) і PDF — підключаються разом із ядром показу.
    public static Func<string, IShowDocument>? OpenPresentation, OpenPdf;

    public readonly Kind ShowKind;
    public readonly List<Page> Pages = new();
    public readonly List<Deck> Decks = new();
    readonly List<IShowDocument> _documents = new();
    /// Намальовані сторінки: малювати їх наново на кожен показ — частки секунди, а гортають підряд.
    readonly Dictionary<int, SKImage> _drawn = new();
    public int? Index { get; private set; }
    /// Що відкрито останнім — його ім'я видно в підписі.
    public string SourceName { get; private set; } = "";
    /// Чому показувати нічого: зразок і підстановки окремо — мову міняють при живій програмі.
    string? _problemPattern;
    string[] _problemValues = Array.Empty<string>();
    public string? Problem => _problemPattern == null ? null : Captions.T(_problemPattern, _problemValues);
    /// Пам'ятає список між запусками — лише робоче місце показу (не перевірки).
    public bool Remembers;

    public ShowModel(Kind kind) { ShowKind = kind; }

    void Note(string? pattern, params string[] values) { _problemPattern = pattern; _problemValues = values; }

    string MemoryKey => ShowKind == Kind.Pictures ? "showPictureFiles" : "showPresentationFiles";

    void Remember()
    {
        if (!Remembers) return;
        Defaults.Set(MemoryKey, string.Join("\n", Decks.Select(d => d.Path)));
    }

    /// Повернути відкрите минулого разу; зниклі файли (прибрали флешку) просто пропускаємо.
    public void Restore()
    {
        if (!Remembers || Pages.Count > 0) return;
        var alive = (Defaults.String(MemoryKey) ?? "").Split('\n', StringSplitOptions.RemoveEmptyEntries).Where(File.Exists).ToList();
        if (alive.Count == 0) return;
        Open(alive);
        Note(null);
        // Показ починають самі: після запуску нічого не стоїть вибраним у залі.
        Index = null;
        SourceName = "";
        Remember();
    }

    public bool IsEmpty => Pages.Count == 0;
    public int Count => Pages.Count;

    /// Колода, в якій стоїть поточна сторінка.
    public int? CurrentDeck => Index is { } index && Decks.FindIndex(d => d.Contains(index)) is var at and >= 0 ? at : null;

    /// Сторінки другої колонки: у презентацій — вибрана колода, у картинок — увесь список.
    public (int Start, int Count) CurrentRange
    {
        get
        {
            if (ShowKind == Kind.Pictures) return (0, Pages.Count);
            if (CurrentDeck is { } deck) return (Decks[deck].Start, Decks[deck].Count);
            if (Decks.Count > 0 && Index == null) return (Decks[0].Start, Decks[0].Count);
            return Decks.Count == 0 ? (0, Pages.Count) : (0, 0);
        }
    }

    /// Вибрати файл: сторінкою стає його перша, якщо поточна не його.
    public void SelectDeck(int position)
    {
        if (position < 0 || position >= Decks.Count) return;
        if (Index is { } index && Decks[position].Contains(index)) return;
        Index = Decks[position].Start;
    }

    /// Прибрати файл з усіма сторінками — помилилися презентацією.
    public void RemoveDeck(int position)
    {
        if (position < 0 || position >= Decks.Count) return;
        var deck = Decks[position];
        Pages.RemoveRange(deck.Start, deck.Count);
        ClearDrawn();
        Decks.RemoveAt(position);
        for (var later = 0; later < Decks.Count; later++)
            if (Decks[later].Start >= deck.End) Decks[later] = Decks[later] with { Start = Decks[later].Start - deck.Count };
        if (Index is { } current)
        {
            if (deck.Contains(current)) Index = Pages.Count == 0 ? null : Math.Min(deck.Start, Pages.Count - 1);
            else if (current >= deck.End) Index = current - deck.Count;
        }
        if (Pages.Count == 0) SourceName = "";
        Remember();
    }

    /// Що показувати в залі; null — нічого.
    public SKImage? CurrentImage => Index is { } index && index < Pages.Count ? Image(index) : null;

    public string CurrentTitle => Index is { } index && index < Pages.Count ? Pages[index].Title : "";

    /// Знак поточної сторінки, сталий, доки відкрито той самий файл (номер у списку зсувається).
    public string? CurrentPageMark => Index is { } index ? PageMark(index) : null;

    /// Те саме для будь-якої сторінки списку — щоб знати, чи стоїть у залі саме вона.
    public string? PageMark(int index)
    {
        if (index < 0 || index >= Pages.Count) return null;
        var source = Pages[index].Source;
        if (source.Picture is { } path) return "зображення|" + path;
        var file = Decks.FirstOrDefault(d => d.Contains(index))?.Path ?? "";
        return $"сторінка|{file}|{source.Page}";
    }

    // --- Відкриття -------------------------------------------------------------------------

    /// Додати вибране до відкритого. Тека розкривається цілком; повторно кинутий файл не подвоюється.
    public void Open(IEnumerable<string> paths)
    {
        Note(null);
        var list = paths.ToList();
        var first = Pages.Count;
        foreach (var path in Expand(list))
        {
            if (ShowKind == Kind.Pictures) AddPicture(path); else AddDocument(path);
        }
        if (Pages.Count > first)
        {
            // Показ ведуть із першої доданої сторінки; колишній вибір — лише якщо його не було.
            Index ??= first;
            SourceName = list.Count == 1 ? Path.GetFileName(list[0]) : Captions.T("%s из %s", (Pages.Count - first).ToString(), Pages.Count.ToString());
        }
        else if (_problemPattern == null)
            Note(ShowKind == Kind.Pictures ? "В выбранном нет ни одной картинки" : "В выбранном нет ни одной презентации");
        Remember();
    }

    /// Розкрити теки й відсіяти чуже. Порядок — як бачить людина: «10» після «9».
    List<string> Expand(List<string> paths)
    {
        var known = Extensions(ShowKind);
        var found = new List<string>();
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
            {
                found.AddRange(Directory.EnumerateFiles(path).Where(f => !Path.GetFileName(f).StartsWith('.')
                    && known.Contains(Path.GetExtension(f).TrimStart('.').ToLowerInvariant())));
                continue;
            }
            var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
            if (!File.Exists(path))
            {
                // Файла немає зовсім — про старий .ppt сказати чесніше, ніж змовчати.
                if (ShowKind == Kind.Presentation && ext == "ppt") AddDocument(path);
                continue;
            }
            if (known.Contains(ext) || ext == "ppt") found.Add(path);
        }
        found.Sort((a, b) => SwiftText.LocalizedStandardCompare(Path.GetFileName(a), Path.GetFileName(b)));
        return found;
    }

    void AddPicture(string path)
    {
        if (Pages.Any(p => p.Source.Picture is { } known && string.Equals(known, path, StringComparison.OrdinalIgnoreCase))) return;
        var name = Path.GetFileNameWithoutExtension(path);
        Pages.Add(new Page(name, name, new Source(path)));
        // Кожна картинка — своя колода з однієї сторінки: у колонці файлів видно всі.
        Decks.Add(new Deck(Path.GetFileName(path), path, Pages.Count - 1, 1));
    }

    void AddDocument(string path)
    {
        var ext = Path.GetExtension(path).TrimStart('.').ToLowerInvariant();
        // Старий двійковий .ppt — зовсім інший формат, не архів із XML.
        if (ext == "ppt")
        {
            Note("Старый формат .ppt программа не читает — пересохраните презентацию как .pptx");
            return;
        }
        var name = Path.GetFileNameWithoutExtension(path);
        IShowDocument document;
        try
        {
            var opener = ext == "pdf" ? OpenPdf : OpenPresentation;
            if (opener == null) { Note(ext == "pdf" ? "PDF не открылся: %s" : "Презентация не открылась: %s", Path.GetFileName(path)); return; }
            document = opener(path);
        }
        catch (Exception error)
        {
            if (ext == "pdf") Note("PDF не открылся: %s", Path.GetFileName(path));
            else Note(error.Message);
            return;
        }
        if (document.Count <= 0) { document.Dispose(); Note(ext == "pdf" ? "PDF не открылся: %s" : "Презентация не открылась: %s", Path.GetFileName(path)); return; }
        _documents.Add(document);
        var at = _documents.Count - 1;
        var first = Pages.Count;
        for (var page = 0; page < document.Count; page++)
        {
            var shortName = Captions.T(ext == "pdf" ? "Страница %s" : "Слайд %s", (page + 1).ToString());
            Pages.Add(new Page(name + " — " + shortName, shortName, new Source(null, at, page)));
        }
        Decks.Add(new Deck(Path.GetFileName(path), path, first, Pages.Count - first));
    }

    public void Close()
    {
        Pages.Clear();
        Decks.Clear();
        Index = null;
        ClearDrawn();
        foreach (var d in _documents) d.Dispose();
        _documents.Clear();
        SourceName = "";
        Note(null);
        Remember();
    }

    /// Прибрати одну сторінку; у презентацій сторінки живуть колодами — прибирається колода.
    public void Remove(int position)
    {
        if (position < 0 || position >= Pages.Count) return;
        var deck = Decks.FindIndex(d => d.Contains(position));
        if (deck >= 0) { RemoveDeck(deck); return; }
        Pages.RemoveAt(position);
        ClearDrawn();
        if (Index is { } current)
        {
            if (current == position) Index = position < Pages.Count ? position : Pages.Count == 0 ? null : Pages.Count - 1;
            else if (current > position) Index = current - 1;
        }
    }

    // --- Вибір і гортання ------------------------------------------------------------------

    public void Select(int? position) => Index = position is { } p && p >= 0 && p < Pages.Count ? p : null;

    /// Наступна чи попередня сторінка. По колу не ходимо: «далі» в кінці показу — кінець.
    public bool Step(int delta)
    {
        if (Index is not { } index)
        {
            if (Pages.Count == 0) return false;
            Index = delta > 0 ? 0 : Pages.Count - 1;
            return true;
        }
        var next = index + delta;
        if (next < 0 || next >= Pages.Count) return false;
        Index = next;
        return true;
    }

    // --- Картинки --------------------------------------------------------------------------

    /// Кадр сторінки в повному розмірі. Картинки береже сховище кадрів; сторінки
    /// документів малюються раз у висоту залу (1080) і пам'ятаються.
    public SKImage? Image(int position)
    {
        if (position < 0 || position >= Pages.Count) return null;
        var source = Pages[position].Source;
        if (source.Picture is { } path) return SlideImageStore.Shared.Image(path);
        if (_drawn.TryGetValue(position, out var ready)) return ready;
        if (source.Document < 0 || source.Document >= _documents.Count) return null;
        SKImage? image;
        try { image = _documents[source.Document].Render(source.Page, 1080); }
        catch (Exception error) { Journal.Say($"показ: сторінка {source.Page + 1} не намалювалась — {error.Message}"); image = null; }
        if (image != null) _drawn[position] = image;
        return image;
    }

    void ClearDrawn()
    {
        // Кадри могли піти в зал (сховище тримає свої копії ключами) — тут лише свої.
        foreach (var image in _drawn.Values) image.Dispose();
        _drawn.Clear();
    }
}
