// =============================================================================
//  AppState.Songs.cs — пісні в стані програми (як пісенна частина AppState.swift)
// =============================================================================
//  Пісенники — ті, що лишили ввімкненими на вкладці «Модулі» (кого там немає —
//  показуємо). Частина пісні йде на слайд так само, як вірш: SongSlideComposer
//  ділить довгий куплет на сторінки, ставить номер пісні в адресу й знак кінця
//  після останньої частини. Стрілки на вкладці «Пісні» гортають сторінки й
//  частини, а не Біблію — навіть на краю пісні.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    public SongLibrary? SongLibrary { get; private set; }
    /// Пісенники, лишені ввімкненими на вкладці «Модулі».
    public List<SongLibrary.Entry> SongBooks { get; private set; } = new();
    /// Увесь каталог (і вимкнені) — вікну «Параметри».
    public IReadOnlyList<SongLibrary.Entry> AllSongBooks => SongLibrary?.Books ?? (IReadOnlyList<SongLibrary.Entry>)Array.Empty<SongLibrary.Entry>();
    public int SongRosterRevision { get; private set; }

    string _songBookId = "";
    public string SongBookID
    {
        get => _songBookId;
        set { if (_songBookId == value) return; _songBookId = value; Signals.Shared.Send(Signals.Kind.SongBook); RememberSongState(); }
    }
    public string SongQuery = "";
    /// Номер пісні в пісеннику (як songIndex на Mac).
    public int? SongIndex { get; set; }
    /// НОМЕР частини (SongPart.Index), а не її місце в списку — так його ставлять і
    /// список частин, і план, і історія.
    public int? SongPartIndex { get; set; }

    SongSlideComposer _songComposer = new();
    List<SongSlide> _songPages = new();
    int _songPageIndex;
    (Song Song, SongPart Part)? _shownSong;
    string _liveSongTitle = "";

    /// Пісня на слайді (тримаємо, а не шукаємо заново: збирання слайда — на будь-яку зміну).
    public Song? ShownSong => _shownSong?.Song;
    public SongPart? ShownPart => _shownSong?.Part;
    public SongChunkPalette SongPalette => SettingsStore.Shared.Settings.SongPalette;

    /// Як підписувати пісню: номер у збірнику, у дужках, крапка після номера.
    public SongTitleFormat SongTitleFormat
    {
        get
        {
            var o = SettingsStore.Shared.Settings.Options;
            return new SongTitleFormat(o.SongNumberInCollection, o.SongDotAfterNumber, o.SongNumberInBrackets);
        }
    }

    /// Пісенники — разом із бібліотекою (applyLoaded на Mac).
    void LoadSongs(ModuleLibrary? loaded, IniSettings? config)
    {
        SongLibrary = new SongLibrary(loaded?.SongFiles ?? (IReadOnlyList<string>)Array.Empty<string>());
        RebuildSongBooks(SettingsStore.Shared.Settings.Modules);
        if (config != null) _songComposer = new SongSlideComposer(config);
        var remembered = Defaults.String("lastSongBook");
        if (remembered is { Length: > 0 } && SongBooks.Any(b => b.Id == remembered))
        {
            _songBookId = remembered;
            SongIndex = Defaults.Has("lastSongIndex") ? Defaults.Int("lastSongIndex") : null;
            SongPartIndex = Defaults.Has("lastSongPart") ? Defaults.Int("lastSongPart") : null;
        }
        if (_songBookId.Length == 0) _songBookId = SongBooks.FirstOrDefault().Id ?? "";
        Signals.Shared.Send(Signals.Kind.SongBook);
    }

    /// Видимий список пісенників за галочками «Модулів»; кого галочки не стосувалися —
    /// показуємо (ховати те, чого людина не вимикала, не можна).
    public void RebuildSongBooks(IEnumerable<ModuleRosterEntry> entries)
    {
        var flags = new Dictionary<string, bool>();
        foreach (var entry in entries.Where(e => e.IsSongBook)) flags[entry.Name.ToLowerInvariant()] = entry.IsEnabled;
        // Галочку ставили на «pv3055.vbm», а збірник уже «pv3055.songbook»: шукаємо й за старим ім'ям.
        var visible = AllSongBooks.Where(b =>
            flags.TryGetValue(Path.GetFileName(b.Url).ToLowerInvariant(), out var on) ? on
            : flags.TryGetValue(b.Id.ToLowerInvariant() + ".vbm", out var old) ? old : true).ToList();
        if (visible.Select(b => b.Id).SequenceEqual(SongBooks.Select(b => b.Id))) return;
        SongBooks = visible;
        SongRosterRevision++;
        // Відкритий пісенник вимкнули — на перший, що лишився.
        if (!visible.Any(b => b.Id == _songBookId))
        {
            _songBookId = visible.FirstOrDefault().Id ?? "";
            SongIndex = null;
            SongPartIndex = null;
        }
        Signals.Shared.Send(Signals.Kind.SongBook);
    }

    public List<SongMatch> SongMatches =>
        SongLibrary is { } library && _songBookId.Length > 0 ? library.Search(SongQuery, _songBookId) : new List<SongMatch>();

    public Song? SelectedSong =>
        SongIndex is { } index && SongLibrary?.Book(_songBookId)?.Songs is { } songs && index >= 0 && index < songs.Count ? songs[index] : null;

    /// Стрілки на вкладці «Пісні» гортають частини пісні. Край пісні теж наш: інакше
    /// стрілка на останньому куплеті підмінила б слайд місцем Писання.
    public bool StepSongPart(int delta, bool live)
    {
        if ((_shownSong?.Song ?? SelectedSong) is not { Parts.Count: > 0 } song) return false;
        // Спершу сторінки всередині частини.
        var nextPage = _songPageIndex + delta;
        if (_songPages.Count > 1 && nextPage >= 0 && nextPage < _songPages.Count)
        {
            _songPageIndex = nextPage;
            ShowSongPage();
            if (live) ShowCurrentSlide();
            return true;
        }
        var current = SongPartIndex ?? song.Parts[0].Index;
        var position = song.Parts.FindIndex(p => p.Index == current);
        if (position < 0) position = 0;
        var next = position + delta;
        if (next < 0 || next >= song.Parts.Count) return true;
        var part = song.Parts[next];
        SongPartIndex = part.Index;
        ShowSongPart(song, part);
        // Назад — на ОСТАННЮ сторінку попередньої частини.
        if (delta < 0 && _songPages.Count > 1)
        {
            _songPageIndex = _songPages.Count - 1;
            ShowSongPage();
        }
        if (live) ShowCurrentSlide();
        Signals.Shared.Send(Signals.Kind.SongPart);
        return true;
    }

    /// Частина пісні йде на слайд так само, як вірш: свій текст, своя адреса.
    public void ShowSongPart(Song song, SongPart part)
    {
        _shownSong = (song, part);
        var isLast = song.Parts.Count > 0 && song.Parts[^1].Index == part.Index;
        _songPages = _songComposer.Slides(part, song, SongBookShortName, isLast);
        _songPageIndex = 0;
        ShowSongPage();
        RememberSongState();
    }

    string SongBookShortName => AllSongBooks.FirstOrDefault(b => b.Id == _songBookId).ShortName ?? "";

    void ShowSongPage()
    {
        Slide = _songPageIndex >= 0 && _songPageIndex < _songPages.Count ? _songPages[_songPageIndex].Slide : Slide.Blank;
        Publish();
    }

    /// Перезбирання на вкладці «Пісні»: ту саму сторінку, на якій стоїмо.
    void RefreshSongSlide()
    {
        if (_songPages.Count > 0) ShowSongPage();
        else if (_shownSong is { } shown) ShowSongPart(shown.Song, shown.Part);
        else { Slide = Slide.Blank; Publish(); }
    }

    /// Запис «Історії» для частини пісні.
    HistoryRecord? SongRecord(Slide slide, string quote)
    {
        if ((_shownSong?.Song ?? SelectedSong) is not { } song) return null;
        if (SongLibrary?.EntryFor(_songBookId) is not { } entry) return null;
        return new HistoryRecord(HistoryRecord.Kind.Song, HistoryRecord.CaptionFor(slide.Reference, quote), slide.Reference, quote,
                                 songBookFileName: Path.GetFileName(entry.Url), songIndex: song.Index, partIndex: SongPartIndex ?? 0);
    }

    /// Відкрити запис пісні з «Історії» (і показати).
    void OpenSongRecord(HistoryRecord record, bool show)
    {
        if (SongLibrary?.EntryForFileName(record.SongBookFileName) is not { } entry)
        {
            Journal.Say($"історія: пісенника «{record.SongBookFileName}» немає");
            return;
        }
        if (Mode != WorkMode.Songs) { Mode = WorkMode.Songs; Signals.Shared.Send(Signals.Kind.Mode); }
        SongBookID = entry.Id;
        SongIndex = record.SongIndex;
        SongPartIndex = record.PartIndex;
        Signals.Shared.Send(Signals.Kind.SongSelection);
        if (show && SongLibrary.Book(entry.Id) is { } book && record.SongIndex >= 0 && record.SongIndex < book.Songs.Count)
        {
            var song = book.Songs[record.SongIndex];
            var part = song.Parts.FirstOrDefault(p => p.Index == record.PartIndex);
            if (song.Parts.Count > 0)
            {
                ShowSongPart(song, part.Text != null ? part : song.Parts[0]);
                ShowCurrentSlide();
            }
        }
    }

    void RememberSongState()
    {
        if (!_isRestored) return;
        Defaults.Set("lastSongBook", _songBookId);
        if (SongIndex is { } song) Defaults.Set("lastSongIndex", song); else Defaults.Remove("lastSongIndex");
        if (SongPartIndex is { } part) Defaults.Set("lastSongPart", part); else Defaults.Remove("lastSongPart");
    }

    /// «Додати в План» із пісні чи частини (підключається з перенесенням Плану).
    public Action<Song, SongPart?>? AddSongToPlan;

    /// Пісенник зберегли чи перечитали — каталог бере нову книгу.
    public void AdoptSongBook(string id, SongBook book)
    {
        SongLibrary?.Adopt(book, id);
        SongRosterRevision++;
        Signals.Shared.Send(Signals.Kind.SongBook);
    }
}
