// =============================================================================
//  AppState.Desk.cs — Пісні, Текст, Зображення, План, Історія, пошук
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo;

public sealed partial class AppState
{
    // MARK: Пісні

    public List<Module> SongBooks { get; private set; } = new();
    public string SongBookId => Settings.SongBook;
    public Module? SongBook => SongBooks.FirstOrDefault(b => b.Id == SongBookId);
    public string SongQuery { get; private set; } = "";
    public List<Song> SongList { get; private set; } = new();
    public int? SongIndex { get; private set; }
    public Song? CurrentSong => SongIndex is int index ? Library.SongAt(SongBookId, index) : null;
    public List<Part> Parts { get; private set; } = new();
    public List<SongSlide> SongSlides { get; private set; } = new();
    /// Поточний слайд пісні — місце в `SongSlides`.
    public int SongSlideIndex { get; private set; } = -1;
    public int? PartIndex => SongSlideIndex >= 0 && SongSlideIndex < SongSlides.Count ? SongSlides[SongSlideIndex].PartIndex : null;

    public SongComposer Composer => new()
    {
        SplitsLongParts = Settings.Songs.VersSubDivide,
        ShowsNumber = Settings.SongNumberPP,
        EndMarker = Settings.SongsEndMarker,
        Palette = Palette,
    };

    void ReloadSongBooks()
    {
        SongBooks = Library.Modules(Library.Songs);
        if (SongBook == null) Settings.SongBook = SongBooks.FirstOrDefault()?.Id ?? "";
        ReloadSongList();
    }

    void ReloadSongList()
    {
        if (SongBook == null) { SongList = new List<Song>(); SongIndex = null; Parts = new List<Part>(); SongSlides = new List<SongSlide>(); SongSlideIndex = -1; return; }
        var query = SongQuery.Trim();
        var byTitle = Library.SongsOf(SongBookId, query);
        if (query.Length >= 3 && query.Any(char.IsLetter))
        {
            var byWords = Library.SongsWithWords(SongBookId, query);
            var seen = byTitle.Select(s => s.Index).ToHashSet();
            byTitle.AddRange(byWords.Where(s => !seen.Contains(s.Index)));
        }
        SongList = byTitle;
        if (SongIndex is int index && Library.SongAt(SongBookId, index) == null) { SongIndex = null; Parts = new List<Part>(); SongSlides = new List<SongSlide>(); SongSlideIndex = -1; }
    }

    public void SelectSongBook(string id)
    {
        if (!SongBooks.Any(b => b.Id == id)) return;
        if (Settings.SongBook != id)
        {
            Settings.SongBook = id;
            SongIndex = null;
            Parts = new List<Part>();
            SongSlides = new List<SongSlide>();
            SongSlideIndex = -1;
        }
        ReloadSongList();
        if (Mode == "songs") RefreshSlide();
        Raise(Change.Songs);
    }

    public void FilterSongs(string query)
    {
        SongQuery = query;
        ReloadSongList();
        Raise(Change.Songs);
    }

    /// Пісня вибрана: частини в список, перший слайд — у передпоказ.
    public void SelectSong(int index, bool live)
    {
        var song = Library.SongAt(SongBookId, index);
        if (song == null) return;
        SongIndex = index;
        Parts = Library.Parts(SongBookId, index);
        SongSlides = Composer.Slides(Parts, index + 1, song.Title);
        SongSlideIndex = SongSlides.Count > 0 ? 0 : -1;
        if (Mode != "songs") { _mode = "songs"; Settings.LastMode = "songs"; Raise(Change.Mode); }
        RefreshSlide();
        if (live) ShowCurrent();
        Raise(Change.SongParts);
    }

    /// Частина пісні — перша її сторінка.
    public void SelectPart(int partIndex, bool live)
    {
        var at = SongSlides.FindIndex(s => s.PartIndex == partIndex);
        if (at < 0) return;
        SongSlideIndex = at;
        if (Mode != "songs") { _mode = "songs"; Settings.LastMode = "songs"; Raise(Change.Mode); }
        RefreshSlide();
        Raise(Change.SongParts);
        if (live) ShowCurrent();
    }

    public void SelectSongSlide(int slideIndex, bool live)
    {
        if (slideIndex < 0 || slideIndex >= SongSlides.Count) return;
        SongSlideIndex = slideIndex;
        RefreshSlide();
        Raise(Change.SongParts);
        if (live) ShowCurrent();
    }

    /// Стрілка в режимі пісень: наступний / попередній слайд пісні.
    public bool StepSongPart(int delta, bool live)
    {
        if (SongSlides.Count == 0) return false;
        var next = SongSlideIndex + delta;
        if (next < 0 || next >= SongSlides.Count) return false;
        SongSlideIndex = next;
        RefreshSlide();
        Raise(Change.SongParts);
        if (live) ShowCurrent();
        return true;
    }

    Slide CurrentSongSlide() =>
        SongSlideIndex >= 0 && SongSlideIndex < SongSlides.Count ? SongSlides[SongSlideIndex].Slide : Slide.Blank;

    /// Назва пісні для списку — з номером за налаштуваннями.
    public string SongListTitle(Song song) =>
        SongTitleFormat.Title(song.Index, song.Title, Settings.SongNumberInCollection, Settings.SongDotAfterNumber, Settings.SongNumberInBrackets);

    /// Пісенник змінився на диску бібліотеки (редактор) — перечитати.
    public void SongBookChanged(string id)
    {
        ReloadSongBooks();
        if (SongBookId == id && SongIndex is int index) SelectSong(Math.Min(index, Math.Max(0, Library.Count("songs", id) - 1)), false);
        Raise(Change.Songs);
        Raise(Change.Library);
    }

    // MARK: Текст

    public TextDocument Text { get; private set; } = new();
    public List<string> TextPages { get; private set; } = new();
    public int TextPageIndex { get; set; }

    public void SetText(string title, string body)
    {
        Text = new TextDocument(title, body);
        TextPages = Text.Pages(PaginationFor("text"));
        TextPageIndex = Math.Clamp(TextPageIndex, 0, Math.Max(0, TextPages.Count - 1));
        if (Mode == "text") RefreshSlide();
        Raise(Change.Text);
    }

    public void ClearText() { TextPageIndex = 0; SetText("", ""); }

    public void SelectTextPage(int index, bool live)
    {
        if (TextPages.Count == 0) return;
        TextPageIndex = Math.Clamp(index, 0, TextPages.Count - 1);
        if (Mode != "text") { _mode = "text"; Settings.LastMode = "text"; Raise(Change.Mode); }
        RefreshSlide();
        Raise(Change.Text);
        if (live) ShowCurrent();
    }

    public bool StepTextPage(int delta, bool live)
    {
        var next = TextPageIndex + delta;
        if (next < 0 || next >= TextPages.Count) return false;
        SelectTextPage(next, live);
        return true;
    }

    /// «Показати в залі» з вкладки «Текст».
    public void ShowText()
    {
        if (Mode != "text") { _mode = "text"; Settings.LastMode = "text"; Raise(Change.Mode); }
        TextPages = Text.Pages(PaginationFor("text"));
        TextPageIndex = Math.Clamp(TextPageIndex, 0, Math.Max(0, TextPages.Count - 1));
        RefreshSlide();
        ShowCurrent();
    }

    Slide CurrentTextSlide()
    {
        var slides = Text.Slides(PaginationFor("text"));
        TextPages = slides.Select(s => s.MainText).ToList();
        if (slides.Count == 0) return Slide.Blank;
        TextPageIndex = Math.Clamp(TextPageIndex, 0, slides.Count - 1);
        return slides[TextPageIndex];
    }

    // MARK: Зображення

    public List<string> Pictures { get; private set; } = new();
    public int? PictureIndex { get; private set; }
    public string? CurrentPicture => PictureIndex is int index && index >= 0 && index < Pictures.Count ? Pictures[index] : null;

    static readonly string[] PictureExtensions = { ".jpg", ".jpeg", ".png", ".bmp", ".gif", ".webp" };

    public static bool IsPictureFile(string path) => PictureExtensions.Contains(Path.GetExtension(path).ToLowerInvariant());

    public void ReloadPictures()
    {
        var folders = new List<string> { Paths.Backgrounds, Paths.Uploads };
        folders.AddRange(Settings.PicturePaths.Where(Directory.Exists));
        var files = new List<string>();
        foreach (var folder in folders.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try { files.AddRange(Directory.GetFiles(folder).Where(IsPictureFile).OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase)); }
            catch { /* теки нема */ }
        }
        var current = CurrentPicture;
        Pictures = files;
        PictureIndex = current == null ? null : (Pictures.IndexOf(current) is var at && at >= 0 ? at : null);
        Raise(Change.Pictures);
    }

    public void SelectPicture(int index)
    {
        if (index < 0 || index >= Pictures.Count) return;
        PictureIndex = index;
        if (Mode != "pictures") { _mode = "pictures"; Settings.LastMode = "pictures"; Raise(Change.Mode); }
        RefreshSlide();
        Raise(Change.Pictures);
    }

    public void ShowPicture(int index)
    {
        SelectPicture(index);
        if (CurrentPicture == null) return;
        ShowCurrent();
    }

    /// Файл, що прийшов із пульта чи з диска: скопіювати в теку й показати.
    public string? AddPicture(string path, bool show)
    {
        if (!File.Exists(path) || !IsPictureFile(path)) return null;
        var target = Path.Combine(Paths.Uploads, Path.GetFileName(path));
        if (!string.Equals(Path.GetFullPath(target), Path.GetFullPath(path), StringComparison.OrdinalIgnoreCase))
        {
            try { File.Copy(path, target, true); } catch (Exception error) { Paths.Say("картинка не скопіювалася: " + error.Message); return null; }
        }
        SlideRenderer.Forget(target);
        ReloadPictures();
        var at = Pictures.FindIndex(p => string.Equals(p, target, StringComparison.OrdinalIgnoreCase));
        if (at < 0) return null;
        if (show) ShowPicture(at); else SelectPicture(at);
        return target;
    }

    public bool StepPicture(int delta, bool live)
    {
        if (Pictures.Count == 0) return false;
        var next = (PictureIndex ?? -1) + delta;
        if (next < 0 || next >= Pictures.Count) return false;
        if (live) ShowPicture(next); else SelectPicture(next);
        return true;
    }

    // MARK: Стрілки — за режимом

    /// «Далі»/«Назад» — те саме, що стрілки; `live` — із показом у залі.
    public void Step(int delta, bool live)
    {
        switch (Mode)
        {
            case "songs": if (!StepSongPart(delta, live) && live) ShowCurrent(); break;
            case "text": if (!StepTextPage(delta, live) && live) ShowCurrent(); break;
            case "pictures": StepPicture(delta, live); break;
            default: StepVerse(delta, live); break;
        }
    }

    // MARK: План

    public ServicePlan Plan { get; private set; } = new();
    public int PlanSelection { get; set; } = -1;
    ServicePlan? _servicePlanAside;
    public bool IsSermon => _servicePlanAside != null;
    public ServiceHistory History { get; private set; } = new();
    public Guid? HistorySelection { get; set; }

    void LoadDesk()
    {
        History = ServiceHistory.Load();
        try
        {
            var last = Settings.LastPlan;
            if (last.Length > 0 && File.Exists(last)) Plan = ServicePlan.Load(last);
            else
            {
                var saved = ServicePlan.SavedPlans();
                if (saved.Count > 0) Plan = ServicePlan.Load(saved[0]);
            }
        }
        catch (Exception error) { Paths.Say("план не прочитався: " + error.Message); Plan = new ServicePlan(); }
        _mode = Modes.Contains(Settings.LastMode) ? Settings.LastMode : "bible";
        ReloadPictures();
        RefreshSlide();
    }

    /// «Додати в План»: те, що вибрано в поточному режимі.
    public PlanItem? PlanItemForSelection()
    {
        switch (Mode)
        {
            case "bible":
                var book = CurrentBook;
                if (book == null || SelectedVerses.Count == 0 || PrimaryModule == null) return null;
                return PlanItem.Scripture(PrimaryModuleId, book, SelectedBookIndex, SelectedChapter, SelectedVerses, TextIn(PrimaryModuleId, false));
            case "songs":
                var song = CurrentSong;
                if (song == null) return null;
                if (PartIndex is int part && Parts.Count > part) return PlanItem.SongPart(SongBookFileName(SongBookId), song.Index, song.Title, Parts.First(p => p.Index == part));
                return PlanItem.Song(SongBookFileName(SongBookId), song.Index, song.Title, Parts.FirstOrDefault()?.Text);
            case "text":
                return Text.IsEmpty ? null : PlanItem.Text(Text);
            case "pictures":
                return CurrentPicture == null ? null : PlanItem.File(CurrentPicture);
        }
        return null;
    }

    /// Пісня цілком — один пункт.
    public PlanItem? PlanItemForWholeSong()
    {
        var song = CurrentSong;
        if (song == null) return null;
        return PlanItem.Song(SongBookFileName(SongBookId), song.Index, song.Title, Parts.FirstOrDefault()?.Text);
    }

    /// Ім'я файла пісенника в плані — як на Mac: `glory.songbook`, `pv3055.vbm`.
    public static string SongBookFileName(string moduleId) => moduleId.StartsWith("songs:", StringComparison.Ordinal) ? moduleId[6..] : moduleId;

    /// Пісенник за ім'ям файла з плану — за основою імені, без розширення.
    public Module? SongBookByFileName(string fileName)
    {
        var stem = Path.GetFileNameWithoutExtension(fileName).ToLowerInvariant();
        return SongBooks.FirstOrDefault(b => SongBookFileName(b.Id).Equals(fileName, StringComparison.OrdinalIgnoreCase))
            ?? SongBooks.FirstOrDefault(b => Path.GetFileNameWithoutExtension(SongBookFileName(b.Id)).ToLowerInvariant() == stem);
    }

    public void AddToPlan(PlanItem item)
    {
        Plan.Append(item);
        PlanSelection = Plan.Items.Count - 1;
        SchedulePlanSave();
        Raise(Change.Plan);
    }

    public void AddToPlan(IEnumerable<PlanItem> items)
    {
        var list = items.ToList();
        if (list.Count == 0) return;
        Plan.Append(list);
        PlanSelection = Plan.Items.Count - 1;
        SchedulePlanSave();
        Raise(Change.Plan);
    }

    public void AddCurrentToPlan()
    {
        var item = PlanItemForSelection();
        if (item != null) AddToPlan(item);
    }

    public void RemovePlanItem(int index)
    {
        if (Plan.RemoveAt(index) == null) return;
        PlanSelection = Math.Min(index, Plan.Items.Count - 1);
        SchedulePlanSave();
        Raise(Change.Plan);
    }

    public void MovePlanItem(int index, int delta)
    {
        var moved = Plan.Move(index, delta);
        PlanSelection = moved;
        SchedulePlanSave();
        Raise(Change.Plan);
    }

    public void ClearPlan()
    {
        Plan.Clear();
        PlanSelection = -1;
        SchedulePlanSave();
        Raise(Change.Plan);
    }

    public void RenamePlan(string title)
    {
        var clean = title.Trim();
        if (clean.Length == 0 || clean == Plan.Title) return;
        var oldPath = Plan.FilePath;
        Plan.Title = clean;
        Plan.FilePath = Path.Combine(Paths.Plans, ServicePlan.FileName(clean));
        Plan.HasUnsavedChanges = true;
        SavePlanQuietly();
        if (oldPath != null && oldPath != Plan.FilePath && File.Exists(oldPath)) { try { File.Delete(oldPath); } catch { /* лишиться копія */ } }
        Raise(Change.Plan);
    }

    public void NewPlan(string title)
    {
        SavePlanQuietly();
        Plan = new ServicePlan(title.Trim().Length == 0 ? Lang.T("План служіння", "Service plan") : title.Trim());
        Plan.FilePath = Path.Combine(Paths.Plans, ServicePlan.FileName(Plan.Title));
        PlanSelection = -1;
        SavePlanQuietly();
        Raise(Change.Plan);
    }

    public void LoadPlan(string path)
    {
        SavePlanQuietly();
        Plan = ServicePlan.Load(path);
        Settings.LastPlan = path;
        PlanSelection = Plan.Items.Count > 0 ? 0 : -1;
        Raise(Change.Plan);
    }

    public void SavePlanAs(string path)
    {
        Plan.Save(path);
        Settings.LastPlan = path;
        Raise(Change.Plan);
    }

    /// Автозбереження: план лягає у свою теку сам, як на Mac.
    void SchedulePlanSave() => SavePlanQuietly();

    public void SavePlanQuietly()
    {
        try
        {
            if (IsSermon) return;
            if (!Plan.HasUnsavedChanges && Plan.FilePath != null) return;
            var path = Plan.FilePath ?? Path.Combine(Paths.Plans, ServicePlan.FileName(Plan.Title));
            Plan.Save(path);
            Settings.LastPlan = path;
        }
        catch (Exception error) { Paths.Say("план не записався: " + error.Message); }
    }

    /// Пункт плану в зал (чи в передпоказ).
    public bool ActivatePlan(int index, bool live)
    {
        if (index < 0 || index >= Plan.Items.Count) return false;
        var item = Plan.Items[index];
        PlanSelection = index;
        var ok = Activate(item, live);
        Raise(Change.Plan);
        return ok;
    }

    bool Activate(PlanItem item, bool live)
    {
        switch (item.Kind)
        {
            case PlanKind.Scripture:
            {
                if (item.ModuleId.Length > 0 && Module(item.ModuleId) != null && item.ModuleId != PrimaryModuleId) SelectPrimary(item.ModuleId);
                var verses = item.Verses.Count == 0 ? new List<int>() : item.Verses;
                var ok = OpenScripture(item.BookIndex, item.Chapter, verses, live);
                if (ok && item.Verses.Count == 0) SelectAllVerses(live);
                return ok;
            }
            case PlanKind.Song:
            {
                var book = SongBookByFileName(item.SongBook);
                if (book == null) return false;
                SelectSongBook(book.Id);
                if (Library.SongAt(book.Id, item.SongIndex) == null) return false;
                SelectSong(item.SongIndex, false);
                if (item.PartIndex is int part) SelectPart(part, live);
                else if (live) ShowCurrent();
                return true;
            }
            case PlanKind.Text:
                TextPageIndex = 0;
                SetText(item.Heading, item.Body);
                if (Mode != "text") { _mode = "text"; Settings.LastMode = "text"; Raise(Change.Mode); }
                RefreshSlide();
                if (live) ShowCurrent();
                return true;
            case PlanKind.File:
                if (IsPictureFile(item.Path) && File.Exists(item.Path))
                {
                    AddPicture(item.Path, live);
                    return true;
                }
                return false;
        }
        return false;
    }

    /// План проповіді з планшета чи «Проповідника» заступає план служіння.
    public void BeginSermon(List<PlanItem> items, string title)
    {
        if (!IsSermon) { SavePlanQuietly(); _servicePlanAside = Plan; }
        Plan = new ServicePlan(title.Length == 0 ? Lang.T("План проповіді", "Sermon plan") : title);
        Plan.Append(items);
        PlanSelection = items.Count > 0 ? 0 : -1;
        Raise(Change.Plan);
    }

    public void EndSermon()
    {
        if (_servicePlanAside == null) return;
        Plan = _servicePlanAside;
        _servicePlanAside = null;
        PlanSelection = Plan.Items.Count > 0 ? 0 : -1;
        Raise(Change.Plan);
    }

    // MARK: Історія

    void RememberLive()
    {
        if (LiveSlide.IsBlank && LivePicture == null) return;
        HistoryRecord? record = null;
        switch (LiveMode)
        {
            case "bible":
                var book = CurrentBook;
                if (book == null) return;
                record = new HistoryRecord
                {
                    Kind = HistoryKind.Bible, Reference = LiveSlide.Reference, Quote = LiveSlide.MainText,
                    Caption = HistoryRecord.MakeCaption(LiveSlide.Reference, LiveSlide.MainText),
                    ModuleId = PrimaryModuleId, BookIndex = SelectedBookIndex, Chapter = SelectedChapter, Verses = SelectedVerses.ToList(),
                };
                break;
            case "songs":
                var song = CurrentSong;
                if (song == null) return;
                record = new HistoryRecord
                {
                    Kind = HistoryKind.Song, Reference = song.Title, Quote = LiveSlide.MainText,
                    Caption = HistoryRecord.MakeCaption(song.Title + (LiveSlide.Reference.Length > 0 ? " · " + LiveSlide.Reference : ""), LiveSlide.MainText),
                    SongBook = SongBookId, SongIndex = song.Index, PartIndex = PartIndex ?? 0,
                };
                break;
            case "text":
                if (Text.IsEmpty) return;
                record = new HistoryRecord
                {
                    Kind = HistoryKind.Text, Reference = Text.Title, Quote = Text.Body,
                    Caption = Text.Summary(), Heading = Text.Title, Body = Text.Body,
                };
                break;
        }
        if (record == null) return;
        History.Remember(record);
        History.Save();
        Raise(Change.History);
    }

    public bool ActivateHistory(int index, bool live)
    {
        if (index < 0 || index >= History.Records.Count) return false;
        var record = History.Records[index];
        HistorySelection = record.Id;
        switch (record.Kind)
        {
            case HistoryKind.Bible:
                if (record.ModuleId.Length > 0 && Module(record.ModuleId) != null && record.ModuleId != PrimaryModuleId) SelectPrimary(record.ModuleId);
                return OpenScripture(record.BookIndex, record.Chapter, record.Verses, live);
            case HistoryKind.Song:
                if (!SongBooks.Any(b => b.Id == record.SongBook)) return false;
                SelectSongBook(record.SongBook);
                if (Library.SongAt(record.SongBook, record.SongIndex) == null) return false;
                SelectSong(record.SongIndex, false);
                SelectPart(record.PartIndex, live);
                return true;
            default:
                TextPageIndex = 0;
                SetText(record.Heading, record.Body);
                if (Mode != "text") { _mode = "text"; Settings.LastMode = "text"; Raise(Change.Mode); }
                RefreshSlide();
                if (live) ShowCurrent();
                return true;
        }
    }

    public void RemoveHistory(Guid id) { History.Remove(id); History.Save(); Raise(Change.History); }
    public void ClearHistory() { History.Clear(); History.Save(); Raise(Change.History); }

    // MARK: Пошук за словами

    public sealed record SearchHit(int Position, Book Book, int Chapter, int Verse, string Text)
    {
        public string Reference => BookNames.ButtonTitle(Book) + " " + Chapter + ":" + Verse;
    }

    public List<SearchHit> Hits { get; private set; } = new();
    public string SearchedQuery { get; private set; } = "";
    public bool IsSearching { get; private set; }
    public bool IsTruncated { get; private set; }
    public bool IsSearchShown { get; set; }

    string _indexedModule = "";
    List<(VerseAt Verse, string Folded)>? _index;
    CancellationTokenSource? _searching;

    /// Пошук: усі слова запиту, у будь-якому порядку, за початком слова.
    public void RunSearch(string query)
    {
        var clean = query.Trim();
        SearchedQuery = clean;
        _searching?.Cancel();
        if (clean.Length == 0 || PrimaryModule == null) { Hits = new List<SearchHit>(); IsSearching = false; Raise(Change.Search); return; }
        var moduleId = PrimaryModuleId;
        var books = Books;
        var words = clean.Split(new[] { ' ', ',', '.', ';', ':', '!', '?', '"', '«', '»', '(', ')', '\'', '’', '-' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(w => ReferenceParser.Fold(w)).Where(w => w.Length > 0).ToList();
        if (words.Count == 0) { Hits = new List<SearchHit>(); Raise(Change.Search); return; }
        IsSearching = true;
        IsSearchShown = true;
        Raise(Change.Search);
        var token = new CancellationTokenSource();
        _searching = token;
        Task.Run(() =>
        {
            try
            {
                var index = IndexFor(moduleId);
                var found = new List<SearchHit>();
                var truncated = false;
                foreach (var (verse, folded) in index)
                {
                    if (token.IsCancellationRequested) return;
                    var all = true;
                    foreach (var word in words)
                        if (!folded.Contains(word, StringComparison.Ordinal)) { all = false; break; }
                    if (!all) continue;
                    var book = verse.Book < books.Count ? books[verse.Book] : null;
                    if (book == null) continue;
                    found.Add(new SearchHit(verse.Book, book, verse.Chapter, verse.Number, verse.Text));
                    if (found.Count >= 300) { truncated = true; break; }
                }
                if (token.IsCancellationRequested) return;
                _ = Invoke(() =>
                {
                    if (token.IsCancellationRequested) return;
                    Hits = found;
                    IsTruncated = truncated;
                    IsSearching = false;
                    Raise(Change.Search);
                });
            }
            catch (Exception error)
            {
                Paths.Say("пошук: " + error.Message);
                _ = Invoke(() => { IsSearching = false; Raise(Change.Search); });
            }
        });
    }

    List<(VerseAt Verse, string Folded)> IndexFor(string moduleId)
    {
        lock (_sync)
        {
            if (_index != null && _indexedModule == moduleId) return _index;
        }
        var built = Library.AllVerses(moduleId).Select(v => (v, ReferenceParser.Fold(v.Text))).ToList();
        lock (_sync) { _index = built; _indexedModule = moduleId; }
        return built;
    }

    public bool ShowHit(int index, bool live)
    {
        if (index < 0 || index >= Hits.Count) return false;
        var hit = Hits[index];
        return OpenScripture(hit.Position, hit.Chapter, new List<int> { hit.Verse }, live);
    }
}
