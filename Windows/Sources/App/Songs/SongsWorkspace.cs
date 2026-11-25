// =============================================================================
//  SongsWorkspace.cs — вкладка «Пісні» (як NativeSongsWorkspace, NativeSongBridge,
//  NativeSongsToolbars на Mac)
// =============================================================================
//  Три колонки: «Група:» (усі пісні й групи), «Пісня:» (рядок швидкого вибору
//  номером чи назвою зі стрілками ↑↓, список), «Текст:» (кнопки вигляду (21),
//  пошук частини словами, частини кольором палітри). Клацання по частині —
//  передпоказ, подвійне — зал; подвійне по пісні — перша частина в зал.
//  Вкладки пісенників на вкладці «Пісні» стоять на смузі перекладів. Режим
//  правки відкриває смуги кнопок над колонками; меню правої кнопки — як на Mac.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class SongsWorkspace
{
    readonly AppState _state;
    public readonly SongEditorModel Model = new();
    readonly SongIndex _index = new();
    readonly SongGroupRows _groupRows = new();
    public readonly SongRows SongRows;
    public readonly SongPartRows PartRows = new();
    public readonly RowList GroupList, SongList, PartList;
    public readonly SongHeader Header = new();
    readonly ColumnsView _columns = new();
    readonly SongColumn _groupColumn = new(), _songColumn = new(), _partColumn = new();
    readonly SongColumnTitle _groupTitle = new(), _songTitle = new(), _partTitle = new();
    readonly IconButtonRow _partViewButtons = new();
    readonly SongToolStrip _groupStrip = new(), _songStrip = new(), _partStrip = new();
    readonly SongQuickRow _songQuick, _partQuick;
    readonly SongButton _prevSong, _nextSong;
    readonly Dictionary<string, SongButton> _groupButtons = new(), _songButtons = new(), _partButtons = new();
    List<SongButton> _mainButtons = new();
    SongButton? _saveButton;
    public readonly LayoutPanel View;
    public readonly BackingTrackBar Backing;
    public bool LongBookNames = true;
    string _filterKey = "\0", _openedBookId = "";
    int _openedRevision;
    readonly Dictionary<string, int> _editions = new();
    int? _lastStateSong, _lastStatePart;
    bool _builtEditing;
    InterfaceSettings.BookViewMode? _appliedSongView;
    Snapshot _snapshot;

    public SongsWorkspace(AppState state)
    {
        _state = state;
        SongRows = new SongRows(_index);
        var font = state.ListFontSize;
        GroupList = new RowList(SongMetrics.Groups(), font) { Source = _groupRows };
        GroupList.SetUniformHeight(22);
        GroupList.OnSelect = (_, active, cause) => { if (cause != SelectCause.Code) ChooseGroup(active); };
        GroupList.OnContextMenu = GroupMenu;
        SongList = new RowList(SongMetrics.Songs(), font) { Source = SongRows };
        SongList.SetUniformHeight(34);
        SongList.OnSelect = (_, active, cause) => { if (cause != SelectCause.Code) ChooseSong(active); };
        SongList.OnActivate = ActivateSong;
        SongList.OnContextMenu = row => SongRows.SongAt(row) is { } song ? SongMenu(song) : null;
        // Частини переносяться за словами: висота рядка — за текстом.
        PartList = new RowList(SongMetrics.Parts(), font) { Source = PartRows };
        PartList.SetMeasuredHeights(86);
        PartList.OnSelect = (_, active, cause) => { if (cause != SelectCause.Code) ChoosePart(active, false); };
        PartList.OnActivate = row => ChoosePart(row, true);
        PartList.OnContextMenu = row => row >= 0 && row < PartRows.Numbers.Count ? PartMenu(PartRows.Numbers[row]) : null;
        foreach (var list in new[] { GroupList, SongList, PartList }) list.OnZoom = delta => _state.ZoomLists(delta > 0 ? 1 : -1);

        _prevSong = new SongButton("chevron.up", SongCaptions.Hint("PSBFindPrevSong", "Найти предыдущую песню"), () => _ = StepSong(-1));
        _nextSong = new SongButton("chevron.down", SongCaptions.Hint("PSBFindNextSong", "Найти следующую песню"), () => _ = StepSong(1));
        _songQuick = new SongQuickRow(new[] { _prevSong, _nextSong });
        _partQuick = new SongQuickRow();
        ConfigureModel();
        ConfigureQuickFields();
        BuildHeader();
        BuildStrips();

        _groupColumn.Install(new SongColumn.Piece[] { new(_groupTitle, SongColumnTitle.Height), new(_groupStrip, SongToolStrip.Height), new(GroupList, 0) });
        _songColumn.Install(new SongColumn.Piece[]
        {
            new(_songTitle, SongColumnTitle.Height), new(_songStrip, SongToolStrip.Height), new(_songQuick, SongQuickRow.Height), new(SongList, 0),
        });
        _partViewButtons.Install(Enum.GetValues<InterfaceSettings.VerseViewMode>().Select(mode =>
            new IconButton(InterfaceSettings.Caption(mode).Symbol)
            {
                Pressed = () =>
                {
                    InterfaceSettings.Shared.SetVerseView(mode, InterfaceSettings.ListScope.Songs);
                    ApplyInterface(true);
                    ApplyPartViewButtons();
                },
            }));
        ApplyPartViewButtons();
        _partColumn.Install(new SongColumn.Piece[]
        {
            new(_partTitle, SongColumnTitle.Height), new(_partStrip, SongToolStrip.Height), new(_partViewButtons, IconButtonRow.RowHeight),
            new(_partQuick, SongQuickRow.Height), new(PartList, 0),
        });
        _columns.Install(new[]
        {
            new ColumnsView.Column(_groupColumn, 150, 190, 320), new ColumnsView.Column(_songColumn, 220, 340, 520),
            new ColumnsView.Column(_partColumn, 240, 240, 0),
        });
        Backing = new BackingTrackBar(state.Backing);
        View = new SongsRootView(Header, _columns, Backing);
        ApplyCaptions();
        ApplyEditMode();
        Subscribe();
        PlaceBookTabs(state.Mode == WorkMode.Songs);
        ApplyInterface(true);
        _snapshot = new Snapshot(state, Model);
        OpenCurrentBook();
    }

    // --- Модель ↔ стан ---------------------------------------------------------------

    void ConfigureModel()
    {
        Model.ModulesFolder = _state.ModulesFolder;
        Model.Library = _state.SongLibrary;
        Model.Palette = _state.SongPalette;
        // Одиночне клацання готує частину в передпоказі, подвійне — у зал.
        Model.OnPartChosen = (song, part, live) =>
        {
            _state.SongPartIndex = part.Index;
            _state.ShowSongPart(song, part);
            if (live) _state.ShowCurrentSlide();
        };
        Model.OnAddToPlan = (song, part) => _state.AddSongToPlan?.Invoke(song, part);
        Model.OnSaved = (id, book) => { _state.AdoptSongBook(id, book); RefreshTabs(); };
        Model.OnReloaded = (id, book) => { _state.AdoptSongBook(id, book); RefreshTabs(); };
        Model.OnLibraryChanged = id => { _state.ReloadLibrary(); _state.SongBookID = id; };
        Model.OpenSheet = sheet => SongSheets.Open(sheet, this);
        // Пошук (8) на вкладці «Пісні» шукає тут: пісні Пісенника, відкрити знахідку, чи вона поточна.
        _state.OpenSongs = () => Model.Book?.Songs;
        _state.RevealSong = Reveal;
        _state.IsCurrentSongHit = hit => Model.SongIndex == hit.SongIndex && (hit.PartIndex == null || Model.PartIndex == hit.PartIndex);
        // Згорнуті назви доспіли у фоні — набране за цей час перепитується вже за ними.
        _index.OnReady = () => { _filterKey = "\0"; ApplyFilter(true); };
    }

    /// Звірити стан і модель і розіслати приводи (як NativeSongBridge.sync).
    public void Sync()
    {
        var fresh = new Snapshot(_state, Model);
        var kinds = fresh.Differences(_snapshot);
        _snapshot = fresh;
        if (kinds.Count > 0) Signals.Shared.Batch(() => { foreach (var kind in kinds) Signals.Shared.Send(kind); });
        SyncChrome();
    }

    readonly record struct Snapshot(string BookId, string StateBookId, int Revision, bool IsEditing, bool IsModified, int GroupIndex,
                                    int SongIndex, int StateSong, int PartIndex, int StatePart, string SongQuery, bool ShowsCatalogNumber,
                                    int SongCount, int GroupCount, int BookCount, double FontSize, SongTitleFormat TitleFormat)
    {
        public Snapshot(AppState state, SongEditorModel model) : this(model.BookId, state.SongBookID, model.Revision, model.IsEditing, model.IsModified,
            model.GroupIndex ?? -1, model.SongIndex ?? -1, state.SongIndex ?? -1, model.PartIndex ?? -1, state.SongPartIndex ?? -1, model.SongQuery,
            model.ShowsCatalogNumber, model.Book?.Songs.Count ?? 0, model.Book?.Groups.Count ?? 0, state.SongBooks.Count, state.ListFontSize, state.SongTitleFormat) { }

        public List<Signals.Kind> Differences(Snapshot old)
        {
            var kinds = new List<Signals.Kind>();
            if (BookId != old.BookId || Revision != old.Revision || SongCount != old.SongCount || BookCount != old.BookCount
                || GroupCount != old.GroupCount || StateBookId != old.StateBookId) kinds.Add(Signals.Kind.SongBook);
            if (GroupIndex != old.GroupIndex || SongQuery != old.SongQuery || ShowsCatalogNumber != old.ShowsCatalogNumber
                || !TitleFormat.Equals(old.TitleFormat)) kinds.Add(Signals.Kind.SongFilter);
            if (SongIndex != old.SongIndex || StateSong != old.StateSong) kinds.Add(Signals.Kind.SongSelection);
            if (PartIndex != old.PartIndex || StatePart != old.StatePart) kinds.Add(Signals.Kind.SongPart);
            if (IsEditing != old.IsEditing || IsModified != old.IsModified) kinds.Add(Signals.Kind.ListKind);
            return kinds;
        }
    }

    /// Дія моделі із запитаннями — дочекатися й звірити.
    async void Run(Func<Task> action)
    {
        try { await action(); }
        catch (Exception error) { Journal.Say($"пісні: {error.Message}"); }
        Sync();
    }

    void Do(Action action) { action(); Sync(); }

    // --- Підписи, поля ---------------------------------------------------------------

    void ApplyCaptions()
    {
        _groupTitle.Text = SongCaptions.Caption("Label1", "Группа:");
        _songTitle.Text = SongCaptions.Caption("Label2", "Песня:");
        _partTitle.Text = SongCaptions.Caption("Label3", "Текст:");
        _songQuick.Field.Placeholder = Captions.T("Номер или название песни…");
        _partQuick.Field.Placeholder = Captions.T("Слова из текста песни…");
        ToolTip.SetTip(_songQuick.Field, SongCaptions.Hint("ENameFastInput", "Быстрый выбор Песни вводом её номера или названия"));
        ToolTip.SetTip(_partQuick.Field, SongCaptions.Hint("ETextFastInput", "Быстрый выбор Части Песни вводом части её текста"));
        Header.ModifiedTitle = Captions.T("изменён");
        _prevSong.SetHint(SongCaptions.Hint("PSBFindPrevSong", "Найти предыдущую песню"));
        _nextSong.SetHint(SongCaptions.Hint("PSBFindNextSong", "Найти следующую песню"));
    }

    void ConfigureQuickFields()
    {
        _songQuick.Field.OnChange = text => { Model.SongQuery = text; ApplyFilter(true); Sync(); };
        _songQuick.Field.OnSubmit = _ => ChooseFirstMatch();
        _partQuick.Field.OnChange = text => { Model.PartQuery = text; JumpToMatchingPart(); Sync(); };
    }

    /// Поля швидкого вибору (F7/F9) на вкладці «Пісні» — свої: книга = пісня, вірш = текст.
    public bool FocusQuick(KeyHandling.QuickFieldKind kind)
    {
        if (_state.Mode != WorkMode.Songs) return false;
        if (kind == KeyHandling.QuickFieldKind.Book) _songQuick.Field.FocusField();
        else if (kind == KeyHandling.QuickFieldKind.Verse) _partQuick.Field.FocusField();
        else return false;
        return true;
    }

    public KeyHandling.QuickFieldKind? FocusedQuick =>
        _songQuick.Field.IsFocusedField ? KeyHandling.QuickFieldKind.Book : _partQuick.Field.IsFocusedField ? KeyHandling.QuickFieldKind.Verse : null;

    /// Клавіші пісенника, коли курсор не в полі (як NativeSongKeys): Ctrl+S — зберегти;
    /// у режимі правки без відкритого вікна Ins — нова частина, Shift+Ins — копія,
    /// Del і Backspace — видалити (з підтвердженням), Ctrl+Enter — правка частини.
    public bool HandleKey(Hotkey pressed)
    {
        if (_state.Mode != WorkMode.Songs) return false;
        if (pressed == new Hotkey(true, false, false, "S")) { Do(Model.Save); return true; }
        if (!Model.IsEditing || SongSheets.IsOpen) return false;
        switch (pressed)
        {
            case { Control: false, Alt: false, Shift: false, Key: "Ins" }: Do(Model.AddPart); break;
            case { Control: false, Alt: false, Shift: true, Key: "Ins" }: Do(Model.DuplicatePart); break;
            case { Control: false, Alt: false, Shift: false, Key: "Del" or "BackSpace" }: Run(Model.DeletePart); break;
            case { Control: true, Alt: false, Shift: false, Key: "Enter" }: Do(Model.OpenPartEditor); break;
            default: return false;
        }
        return true;
    }

    /// Ctrl+E (30.1, 30.4): увійти в режим правки чи вийти — вихід питає про незбережене.
    public bool ToggleEditMode()
    {
        if (_state.Mode != WorkMode.Songs) return false;
        if (Model.IsEditing) Run(Model.LeaveEditMode); else Do(Model.EnterEditMode);
        return true;
    }

    void JumpToMatchingPart()
    {
        var needle = SongFold.Fold(Model.PartQuery.Trim());
        if (needle.Length == 0 || Model.Song is not { } song) return;
        for (var position = 0; position < song.Parts.Count; position++)
        {
            var part = song.Parts[position];
            if (!SongFold.Contains(SongFold.Fold(part.Text), needle) && !SongFold.Contains(SongFold.Fold(part.Kind), needle)) continue;
            ChoosePart(position, false);
            return;
        }
    }

    void ChooseFirstMatch()
    {
        if (SongRows.RowCount == 0) return;
        ChooseSong(0);
        SongList.ScrollTo(0, ScrollPlace.Center);
    }

    /// ↑↓ біля поля: попередня/наступна пісня; на краю — питання, чи йти з початку.
    public async Task StepSong(int delta)
    {
        var total = SongRows.RowCount;
        if (total == 0) { SongPrompt.Warn(SongCaptions.Message(52, "Поиск песни"), SongCaptions.Message(53, "Песен не найдено")); return; }
        if (Model.SongIndex is not { } song || SongRows.PositionOfSong(song) is not { } current) { ChooseSong(delta > 0 ? 0 : total - 1); return; }
        var next = current + delta;
        if (next >= total)
        {
            if (!await SongPrompt.Confirm(SongCaptions.Message(52, "Поиск песни"), SongCaptions.Message(51, "Достигли конца Песенника. Искать с начала?"))) return;
            ChooseSong(0);
        }
        else if (next < 0)
        {
            if (!await SongPrompt.Confirm(SongCaptions.Message(52, "Поиск песни"), SongCaptions.Message(54, "Достигли начала Песенника. Искать с конца?"))) return;
            ChooseSong(total - 1);
        }
        else ChooseSong(next);
        if (Model.SongIndex is { } chosen && SongRows.PositionOfSong(chosen) is { } position) SongList.ScrollTo(position, ScrollPlace.Center);
    }

    // --- Вибір -------------------------------------------------------------------------

    void ChooseGroup(int row)
    {
        Model.GroupIndex = row == 0 ? null : row - 1;
        ApplyFilter(true);
        Model.SongIndex = SongRows.SongAt(0);
        _lastStateSong = Model.SongIndex;
        _state.SongIndex = Model.SongIndex;
        Model.PartIndex = null;
        Sync();
    }

    void ChooseSong(int row)
    {
        if (SongRows.SongAt(row) is not { } song) return;
        Model.SongIndex = song;
        _lastStateSong = song;
        _state.SongIndex = song;
        Model.PartIndex = null;
        Model.PartQuery = "";
        _partQuick.Field.Text = "";
        Sync();
    }

    /// Подвійне клацання по пісні — перша частина одразу в зал.
    void ActivateSong(int row)
    {
        if (SongRows.SongAt(row) is not { } index) return;
        Model.SongIndex = index;
        Sync();
        if (Model.Song is not { Parts.Count: > 0 } song) return;
        Model.PartIndex = 0;
        Model.OnPartChosen?.Invoke(song, song.Parts[0], true);
        Sync();
    }

    void ChoosePart(int row, bool live)
    {
        if (Model.Song is not { } song || row < 0 || row >= song.Parts.Count) return;
        Model.PartIndex = row;
        _lastStatePart = song.Parts[row].Index;
        Model.OnPartChosen?.Invoke(song, song.Parts[row], live);
        Sync();
    }

    /// Пісня з пошуку чи плану: зняти групу й фільтр, стати на неї (і частину).
    public void Reveal(int songIndex, int? part, bool live)
    {
        if (Model.Editor?.Book.Songs is not { } songs || songIndex < 0 || songIndex >= songs.Count) return;
        if (Model.GroupIndex != null) { Model.GroupIndex = null; GroupList.SetSelection(new[] { 0 }, 0); }
        if (Model.SongQuery.Length > 0) { Model.SongQuery = ""; _songQuick.Field.Text = ""; }
        ApplyFilter(true);
        Model.SongIndex = songIndex;
        _lastStateSong = songIndex;
        _state.SongIndex = songIndex;
        Model.PartIndex = null;
        Model.PartQuery = "";
        _partQuick.Field.Text = "";
        var song = songs[songIndex];
        if (part is { } p && p >= 0 && p < song.Parts.Count)
        {
            Model.PartIndex = p;
            _lastStatePart = song.Parts[p].Index;
            Model.OnPartChosen?.Invoke(song, song.Parts[p], live);
        }
        Sync();
        ApplySongSelection(true);
    }

    /// Для замірів (Bench, як typeSongQuery на Mac): набрати текст у полі швидкого вибору
    /// пісні — тим самим шляхом, що й клавіатура.
    public void TypeSongQuery(string text)
    {
        _songQuick.Field.Text = text;
        Model.SongQuery = text;
        ApplyFilter(true);
        Sync();
    }

    /// Для замірів (measureFilterOnly на Mac): лише відбір назв, без списку й вікна.
    public int FilterOnly(string text) => _index.Filter(text, null)?.Count ?? -1;

    /// Указник назв збірника розібрано у фоні (songIndexIsReady на Mac).
    public bool SongIndexIsReady => _index.IsReady;
    public int HurriedFolds => _index.HurriedFolds;

    void ApplyFilter(bool reload)
    {
        var key = $"{_index.Key}#{(Model.GroupIndex?.ToString() ?? "-")}#{Model.SongQuery}#{Model.ShowsCatalogNumber}#{SongRows.TitleFormat.ShowsNumber}";
        if (key == _filterKey) return;
        _filterKey = key;
        IReadOnlyList<int>? pool = Model.GroupIndex is { } group && Model.Editor is { } editor ? editor.SongIndices(group) : null;
        SongRows.SetFilter(_index.Filter(Model.SongQuery, pool));
        if (!reload) return;
        SongList.Reload();
        ApplySongSelection(false);
    }

    void ApplySongSelection(bool scroll)
    {
        if (Model.SongIndex is not { } song || SongRows.PositionOfSong(song) is not { } position) { SongList.SetSelection(Array.Empty<int>()); return; }
        SongList.SetSelection(new[] { position }, position);
        var (first, end) = SongList.VisibleItems;
        if (!scroll || (position >= first && position < end)) return;
        SongList.ScrollTo(position, ScrollPlace.Center);
    }

    void ReloadParts()
    {
        PartRows.Reload(Model.Song, Model.Palette);
        PartList.Reload();
        ApplyPartSelection();
    }

    void ApplyPartSelection()
    {
        if (Model.PartIndex is not { } position || position >= PartRows.RowCount) { PartList.SetSelection(Array.Empty<int>()); return; }
        PartList.SetSelection(new[] { position }, position);
        PartList.ScrollTo(position, ScrollPlace.Nearest);
    }

    void ApplyPart(int number) { if (PartRows.PositionOfPart(number) is { } position) Model.PartIndex = position; }

    // --- Пісенник ------------------------------------------------------------------------

    void OpenCurrentBook()
    {
        if (_state.SongLibrary is not { } library) return;
        var id = _state.SongBookID;
        if (id.Length == 0 || library.EntryFor(id) is not { } entry) { RefreshTabs(); return; }
        Run(async () =>
        {
            await Model.Open(id, entry.Url, library.LoadedBook(id));
            if (_state.SongIndex is { } remembered && Model.Book?.Songs is { } songs && remembered >= 0 && remembered < songs.Count)
                Model.SongIndex = remembered;
            _lastStateSong = _state.SongIndex;
            ReloadBook();
            if (_state.SongPartIndex is { } part) { _lastStatePart = part; ApplyPart(part); ApplyPartSelection(); }
        });
    }

    public void SelectBook(string id)
    {
        if (_state.SongLibrary is not { } library || library.EntryFor(id) is not { } entry) return;
        Run(async () =>
        {
            if (!await Model.Open(id, entry.Url, library.Book(id))) return;
            _state.SongBookID = id;
        });
    }

    void ReloadBook()
    {
        if (_state.SongBookID.Length > 0 && _state.SongBookID != Model.BookId && _state.SongLibrary?.EntryFor(_state.SongBookID) is { } entry)
        {
            Run(async () => { await Model.Open(entry.Id, entry.Url, _state.SongLibrary?.Book(entry.Id)); ReloadBook(); });
            return;
        }
        var songs = Model.Book?.Songs ?? (IReadOnlyList<Song>)Array.Empty<Song>();
        _index.Open(songs, IndexKey(songs));
        _filterKey = "\0";
        _groupRows.Reload(Model.GroupTitles, Model.Groups);
        GroupList.Reload();
        var groupRow = (Model.GroupIndex ?? -1) + 1;
        GroupList.SetSelection(new[] { groupRow }, groupRow);
        SongRows.TitleFormat = _state.SongTitleFormat;
        SongRows.ShowsCatalogNumber = Model.ShowsCatalogNumber;
        ApplyFilter(true);
        ApplySongSelection(true);
        ReloadParts();
        RefreshTabs();
        ApplyEditMode();
    }

    /// Ключ кешу згортки: інша книга — заново; правка тієї самої — нове видання.
    string IndexKey(IReadOnlyList<Song> songs)
    {
        if (Model.BookId != _openedBookId) { _openedBookId = Model.BookId; _openedRevision = Model.Revision; }
        else if (Model.Revision != _openedRevision)
        {
            _openedRevision = Model.Revision;
            _editions[Model.BookId] = _editions.GetValueOrDefault(Model.BookId) + 1;
        }
        return $"{Model.BookId}#{songs.Count}#{_editions.GetValueOrDefault(Model.BookId)}";
    }

    /// Пісню вибрали ззовні (історія, план, пульт) — стати на неї.
    bool AdoptSongFromState()
    {
        if (_state.SongIndex is not { } wanted || wanted == _lastStateSong) return false;
        if (_state.SongBookID.Length > 0 && _state.SongBookID != Model.BookId) ReloadBook();
        _lastStateSong = wanted;
        if (wanted == Model.SongIndex || Model.Editor?.Book.Songs is not { } songs || wanted < 0 || wanted >= songs.Count) return false;
        Model.SongIndex = wanted;
        Model.PartIndex = null;
        if (SongRows.PositionOfSong(wanted) == null)
        {
            if (Model.GroupIndex != null) { Model.GroupIndex = null; GroupList.SetSelection(new[] { 0 }, 0); }
            if (Model.SongQuery.Length > 0) { Model.SongQuery = ""; _songQuick.Field.Text = ""; }
            ApplyFilter(true);
        }
        return true;
    }

    void AdoptPartFromState()
    {
        if (_state.SongPartIndex is not { } number || number == _lastStatePart) return;
        _lastStatePart = number;
        if (PartRows.PositionOfPart(number) is { } position && position != Model.PartIndex) Model.PartIndex = position;
    }

    public void RefreshTabs()
    {
        var tabs = _state.SongBooks.Select(e => new SongBookTabs.Tab(e.Id, e.DisplayName, e.ShortName, e.Failure ?? e.DisplayName, e.Url));
        Header.Tabs.SetTabs(tabs, Model.BookId, LongBookNames, Captions.T("Песенников нет"));
    }

    void SetLongBookNames(bool on) { LongBookNames = on; RefreshTabs(); }

    /// На вкладці «Пісні» вкладки пісенників стоять на смузі перекладів, на інших — у шапці.
    void PlaceBookTabs(bool songs)
    {
        var strip = MainWindow.Shared?.Strip;
        Header.KeepsTabs = !songs;
        if (songs)
        {
            if (Header.Tabs.Parent is Panel parent && parent != strip) parent.Children.Remove(Header.Tabs);
            strip?.ShowGuestTabs(Header.Tabs);
        }
        else
        {
            strip?.ShowGuestTabs(null);
            if (Header.Tabs.Parent == null) Header.Children.Add(Header.Tabs);
            Header.InvalidateArrange();
        }
    }

    // --- Вигляд (22)/(21) -----------------------------------------------------------------

    void ApplyPartViewButtons()
    {
        var current = InterfaceSettings.Shared.VerseView(InterfaceSettings.ListScope.Songs);
        var modes = Enum.GetValues<InterfaceSettings.VerseViewMode>();
        for (var i = 0; i < modes.Length && i < _partViewButtons.Buttons.Count; i++)
        {
            _partViewButtons.Buttons[i].IsOn = modes[i] == current;
            var (key, fallback, _) = InterfaceSettings.Caption(modes[i]);
            ToolTip.SetTip(_partViewButtons.Buttons[i], SongCaptions.Hint(key, fallback));
            _partViewButtons.Buttons[i].InvalidateVisual();
        }
    }

    void ApplyInterface(bool force = false)
    {
        var settings = InterfaceSettings.Shared;
        var font = _state.ListFontSize;
        var single = settings.VerseView(InterfaceSettings.ListScope.Songs) == InterfaceSettings.VerseViewMode.SingleLine;
        if (PartRows.SingleLine != single || force)
        {
            PartRows.SingleLine = single;
            PartList.SetMeasuredHeights(86);
            PartList.Reload();
        }
        var kind = settings.BookView(InterfaceSettings.ListScope.Songs);
        if (!force && _appliedSongView == kind) return;
        _appliedSongView = kind;
        switch (kind)
        {
            case InterfaceSettings.BookViewMode.Icons: SongList.SetTiles(210, Math.Ceiling(font * 3.2), 3); break;
            case InterfaceSettings.BookViewMode.SmallIcons: SongList.SetTiles(150, Math.Ceiling(font * 2.2), 2); break;
            default: SongList.SetList(); break;
        }
        SongList.SetUniformHeight(kind == InterfaceSettings.BookViewMode.Table ? Math.Ceiling(font * 1.8) : 34);
        SongList.Reload();
    }

    // --- Приводи ----------------------------------------------------------------------

    void Subscribe()
    {
        Signals.Shared.Subscribe(Signals.Kind.Mode, () => PlaceBookTabs(_state.Mode == WorkMode.Songs));
        Signals.Shared.Subscribe(Signals.Kind.Library, () =>
        {
            if (_state.SongLibrary is not { } fresh) return;
            var isFresh = !ReferenceEquals(Model.Library, fresh);
            if (isFresh) Model.Library = fresh;
            if (_state.SongBookID.Length == 0 && _state.SongBooks.Count > 0) _state.SongBookID = _state.SongBooks[0].Id;
            RefreshTabs();
            if (isFresh || Model.BookId != _state.SongBookID) OpenCurrentBook();
        });
        Signals.Shared.Subscribe(Signals.Kind.SongBook, ReloadBook);
        Signals.Shared.Subscribe(Signals.Kind.SongFilter, () =>
        {
            SongRows.TitleFormat = _state.SongTitleFormat;
            SongRows.ShowsCatalogNumber = Model.ShowsCatalogNumber;
            ApplyFilter(true);
        });
        Signals.Shared.Subscribe(Signals.Kind.SongSelection, () =>
        {
            var fromState = AdoptSongFromState();
            ApplySongSelection(true);
            ReloadParts();
            if (fromState && _state.SongPartIndex is { } number) { _lastStatePart = number; ApplyPart(number); ApplyPartSelection(); }
        });
        Signals.Shared.Subscribe(Signals.Kind.SongPart, () => { AdoptPartFromState(); ApplyPartSelection(); });
        Signals.Shared.Subscribe(Signals.Kind.ListFontSize, () =>
        {
            var size = _state.ListFontSize;
            GroupList.FontSize = SongList.FontSize = PartList.FontSize = size;
            ApplyInterface(true);
        });
        Signals.Shared.Subscribe(Signals.Kind.ListKind, () =>
        {
            if (_builtEditing != Model.IsEditing) { _builtEditing = Model.IsEditing; BuildHeader(); }
            ApplyEditMode();
            ApplyInterface();
            ApplyPartViewButtons();
        });
        Signals.Shared.Subscribe(Signals.Kind.Language, () =>
        {
            ApplyCaptions();
            BuildHeader();
            BuildStrips();
            ApplyEditMode();
            ReloadBook();
        });
        Model.Changed += () => Dispatcher.UIThread.Post(Sync);
    }

    void SyncChrome()
    {
        Header.IsModified = Model.IsModified;
        if (_saveButton != null) _saveButton.IsActive = Model.IsModified;
        Header.Tabs.SetCurrent(Model.BookId);
        if (_songQuick.Field.Text != Model.SongQuery) _songQuick.Field.Text = Model.SongQuery;
        if (_partQuick.Field.Text != Model.PartQuery) _partQuick.Field.Text = Model.PartQuery;
    }

    // --- Кнопки й меню --------------------------------------------------------------------

    static MenuItem Item(string title, Action? run, bool enabled = true, string? hint = null)
    {
        var item = new MenuItem { Header = title.Replace("&", ""), IsEnabled = enabled && run != null };
        if (run != null) item.Click += (_, _) => run();
        if (hint != null) ToolTip.SetTip(item, hint);
        return item;
    }

    static MenuItem Sub(string title, params Control[] items) => new() { Header = title.Replace("&", ""), ItemsSource = items };
    static ContextMenu Menu(params Control[] items) => new() { ItemsSource = items };
    static string Mark(bool on) => on ? "✓ " : "";

    void BuildHeader()
    {
        _builtEditing = Model.IsEditing;
        var buttons = new List<SongButton>();
        if (Model.IsEditing)
        {
            buttons.Add(new SongButton("eye", SongCaptions.Hint("TBViewMode", "Перейти в режим просмотра"), () => Run(Model.LeaveEditMode)));
            buttons.Add(new SongButton("square.and.pencil", SongCaptions.Hint("TBParamEdit", "Редактировать атрибуты Песенника"),
                                       () => Do(() => Model.OpenBookAttributes(true))));
            _saveButton = new SongButton("square.and.arrow.down", SongCaptions.Hint("TBSave", "Сохранить Песенник (Ctrl+S)"), () => Do(Model.Save))
            {
                IsActive = Model.IsModified,
            };
            buttons.Add(_saveButton);
        }
        else
        {
            buttons.Add(new SongButton("pencil", SongCaptions.Hint("TBEditMode", "Перейти в режим редактирования"), () => Do(Model.EnterEditMode)));
            buttons.Add(new SongButton("info.circle", SongCaptions.Hint("TBParamShow", "Атрибуты Песенника"), () => Do(() => Model.OpenBookAttributes(false))));
            _saveButton = null;
        }
        var manage = new SongButton("books.vertical", SongCaptions.Hint("TBNewModule", "Песенник...")) { MenuBuilder = ManageMenu };
        var items = buttons.Select(b => (SongToolStrip.Item)new SongToolStrip.Item.Button(b)).ToList();
        items.Add(new SongToolStrip.Item.Divider());
        items.Add(new SongToolStrip.Item.Button(manage));
        _mainButtons = buttons;
        Header.Toolbar.Install(items);
        Header.ToolbarWidth = (buttons.Count + 1) * (SongButton.Size.Width + 1) + 18;
        Header.Tabs.OnSelect = SelectBook;
        Header.Tabs.OnMenu = BookTabMenu;
    }

    ContextMenu ManageMenu() => Menu(
        Item(SongCaptions.Caption("NNewModule", "Создать новый Песенник"), () => Run(Model.CreateBook)),
        Item(SongCaptions.Caption("NCopySongsToEnotherModule", "Скопировать песни в другой Песенник"), () => Do(Model.OpenCopySongs), Model.HasBook),
        new Separator(),
        Sub(SongCaptions.Caption("OpenImportDialog", "Импортировать Песенник из..."),
            Item(SongCaptions.Caption("NImportModuleBQ", "Импортировать из BibleQuote модуля"), () => Run(Model.ImportBibleQuote),
                 hint: Captions.T("Модуль-песенник «Цитата из Библии»: папка с bibleqt.ini")),
            Item(SongCaptions.Caption("NImportModuleSoftProject", "Импортировать из SoftProjector модуля"), () => Run(Model.ImportSoftProjector),
                 hint: Captions.T("Песенник SoftProjector: файл .sps"))),
        Item(SongCaptions.Caption("NImportModuleFromText", "Импортировать Песенник из текстового файла"), () => Run(Model.ImportFromTextFile), Model.HasBook,
             Captions.T("Текстовый файл .txt в том виде, в каком его выгружает «Экспортировать Песенник в текстовый файл»")),
        Item(SongCaptions.Caption("NExportModuleAsText", "Экспортировать Песенник в текстовый файл"), () => Run(Model.ExportToTextFile), Model.HasBook));

    SongButton Btn(Dictionary<string, SongButton> into, string name, string symbol, string hint, Action action)
    {
        var made = new SongButton(symbol, hint, action);
        into[name] = made;
        return made;
    }

    static SongToolStrip.Item B(SongButton button) => new SongToolStrip.Item.Button(button);
    static readonly SongToolStrip.Item Line = new SongToolStrip.Item.Divider();

    void BuildStrips()
    {
        _groupButtons.Clear(); _songButtons.Clear(); _partButtons.Clear();
        _groupStrip.Install(new[]
        {
            B(Btn(_groupButtons, "add", "plus", SongCaptions.Hint("TBAddGroup", "Создать новую группу"), () => Run(Model.AddGroup))),
            B(Btn(_groupButtons, "del", "trash", SongCaptions.Hint("TBDelGroup", "Удалить группу"), () => Run(Model.DeleteGroup))),
            B(Btn(_groupButtons, "dup", "doc.on.doc", SongCaptions.Hint("TBCopyGroup", "Дублировать группу"), () => Do(Model.DuplicateGroup))),
            B(Btn(_groupButtons, "edit", "pencil", SongCaptions.Hint("TBChangeGroup", "Изменить атрибуты группы"), () => Run(Model.RenameGroup))),
            Line,
            B(Btn(_groupButtons, "up", "arrow.up", SongCaptions.Hint("TBUpGroup", "Переместить выше"), () => Do(() => Model.MoveGroup(-1)))),
            B(Btn(_groupButtons, "down", "arrow.down", SongCaptions.Hint("TBDownGroup", "Переместить ниже"), () => Do(() => Model.MoveGroup(1)))),
        });
        var sort = new SongButton("arrow.up.arrow.down", SongCaptions.Hint("TBSongsSort", "Сортировка"))
        {
            MenuBuilder = () => Menu(
                Item(SongCaptions.Caption("NSortByNum", "По Номеру"), () => Run(() => Model.SortSongs(SongBookEditor.SongSort.ByNumber))),
                Item(SongCaptions.Caption("NSortByLiter", "По Названию"), () => Run(() => Model.SortSongs(SongBookEditor.SongSort.ByTitle)))),
        };
        _songButtons["sort"] = sort;
        _songStrip.Install(new[]
        {
            B(Btn(_songButtons, "add", "plus", SongCaptions.Hint("TBNewSong", "Создать новую песню"), () => Do(Model.AddSong))),
            B(Btn(_songButtons, "del", "trash", SongCaptions.Hint("TBDelSong", "Удалить песню"), () => Run(Model.DeleteSong))),
            B(Btn(_songButtons, "dup", "doc.on.doc", SongCaptions.Hint("TBCopySong", "Дублировать песню"), () => Do(Model.DuplicateSong))),
            B(Btn(_songButtons, "edit", "pencil", SongCaptions.Hint("TBChangeSong", "Изменить атрибуты и текст песни"), () => Do(() => Model.OpenSongAttributes(true)))),
            Line,
            B(Btn(_songButtons, "up", "arrow.up", SongCaptions.Hint("TBUpSong", "Переместить выше"), () => Do(() => Model.MoveSong(-1)))),
            B(Btn(_songButtons, "down", "arrow.down", SongCaptions.Hint("TBDownSong", "Переместить ниже"), () => Do(() => Model.MoveSong(1)))),
            B(Btn(_songButtons, "position", "number", SongCaptions.Hint("TBSetNumSong", "Установить новую позицию песни"), () => Run(Model.SetSongPosition))),
            Line,
            B(sort),
        });
        var format = new SongButton("textformat", SongCaptions.Hint("TBFormat", "Форматирование текста"))
        {
            MenuBuilder = () => Menu(
                Item(SongCaptions.Caption("NFormatByLiters", "Разбиение по Заглавным Буквам"), () => Do(() => Model.FormatPart(SongTextFormat.ByLiters)), Model.HasPart),
                Item(SongCaptions.Caption("NFormatByOptimalSize", "Оптимальное размещение на экране"), () => Do(() => Model.FormatPart(SongTextFormat.ByOptimalSize)), Model.HasPart)),
        };
        _partButtons["format"] = format;
        _partStrip.Install(new[]
        {
            B(Btn(_partButtons, "add", "plus", SongCaptions.Hint("TBNewBody", "Создать новую часть песни (Ins)"), () => Do(Model.AddPart))),
            B(Btn(_partButtons, "del", "trash", SongCaptions.Hint("TBDelBody", "Удалить часть песни (Del)"), () => Run(Model.DeletePart))),
            B(Btn(_partButtons, "dup", "doc.on.doc", SongCaptions.Hint("TBCopyBody", "Дублировать часть песни (Shift+Ins)"), () => Do(Model.DuplicatePart))),
            B(Btn(_partButtons, "edit", "pencil", SongCaptions.Hint("TBChangeBody", "Изменить содержимое части песни (Ctrl+Enter)"), () => Do(Model.OpenPartEditor))),
            Line,
            B(Btn(_partButtons, "up", "arrow.up", SongCaptions.Hint("TBUpBody", "Переместить выше"), () => Do(() => Model.MovePart(-1)))),
            B(Btn(_partButtons, "down", "arrow.down", SongCaptions.Hint("TBDownBody", "Переместить ниже"), () => Do(() => Model.MovePart(1)))),
            Line,
            B(Btn(_partButtons, "align0", "text.justify", SongCaptions.Hint("TBAlignDefault", "Выравнивание по умолчанию"), () => Do(() => Model.SetAlign(SongPartAlign.Default)))),
            B(Btn(_partButtons, "align1", "text.alignleft", SongCaptions.Hint("TBAlignLeft", "Выравнивание по левому краю"), () => Do(() => Model.SetAlign(SongPartAlign.Left)))),
            B(Btn(_partButtons, "align2", "text.aligncenter", SongCaptions.Hint("TBAlignCenter", "Выравнивание по центру"), () => Do(() => Model.SetAlign(SongPartAlign.Center)))),
            B(Btn(_partButtons, "align3", "text.alignright", SongCaptions.Hint("TBAlignRight", "Выравнивание по правому краю"), () => Do(() => Model.SetAlign(SongPartAlign.Right)))),
            Line,
            B(format),
            B(Btn(_partButtons, "unformat", "arrow.uturn.left", SongCaptions.Hint("TBUnformat", "Отмена форматирования"), () => Run(Model.UnformatPart))),
        });
    }

    void ApplyEditMode()
    {
        var editing = Model.IsEditing;
        _groupColumn.SetVisible(editing, 1);
        _songColumn.SetVisible(editing, 1);
        _partColumn.SetVisible(editing, 1);
        foreach (var (name, button) in _groupButtons) button.IsActive = name == "add" || Model.HasGroup;
        foreach (var (name, button) in _songButtons) button.IsActive = name is "add" or "sort" || Model.HasSong;
        foreach (var (name, button) in _partButtons)
        {
            if (name.StartsWith("align"))
            {
                button.IsActive = Model.HasPart;
                button.IsOn = Model.HasPart && AlignNamed(name) == Model.CurrentAlign;
            }
            else button.IsActive = name == "add" ? Model.HasSong : Model.HasPart;
        }
        foreach (var button in _mainButtons) if (button != _saveButton) button.IsActive = Model.HasBook;
        if (_saveButton != null) _saveButton.IsActive = Model.IsModified;
        Header.IsModified = Model.IsModified;
    }

    static SongPartAlign AlignNamed(string name) => name switch
    {
        "align1" => SongPartAlign.Left, "align2" => SongPartAlign.Center, "align3" => SongPartAlign.Right, _ => SongPartAlign.Default,
    };

    ContextMenu? BookTabMenu(string id)
    {
        if (_state.SongLibrary?.EntryFor(id) is not { } entry) return null;
        return Menu(
            Item(Mark(LongBookNames) + Captions.Caption("N_LongName", "Длинное название"), () => SetLongBookNames(true)),
            Item(Mark(!LongBookNames) + Captions.Caption("N_ShortName", "Короткое название"), () => SetLongBookNames(false)),
            new Separator(),
            Item(Captions.Caption("NReloadModule", "Перезагрузить модуль"), () => Run(async () =>
            {
                if (id != Model.BookId && _state.SongLibrary?.EntryFor(id) is { } e) await Model.Open(id, e.Url, _state.SongLibrary.Book(id));
                await Model.ReloadBook();
            })),
            Item(Captions.Caption("NOpenModuleFolder", "Открыть папку с модулем"), () => Explorer.Show(entry.Url)));
    }

    ContextMenu? GroupMenu(int row)
    {
        if (!Model.IsEditing) return null;
        Model.GroupIndex = row == 0 ? null : row - 1;
        Sync();
        return Menu(
            Item(SongCaptions.Caption("NDoubleRefrainAll", "Дублировать припевы во ВСЕХ песнях!"), () => Run(() => Model.DuplicateRefrainsEverywhere(false))),
            Item(SongCaptions.Caption("NDoubleRefrainByPrizAll", "Дублировать припевы по признаку во ВСЕХ песнях!"), () => Run(() => Model.DuplicateRefrainsEverywhere(true))),
            new Separator(),
            Sub(SongCaptions.Caption("N8", "Форматирование ВСЕХ песен"),
                Item(SongCaptions.Caption("NFormatAllSongByLiters", "Разбиение по Заглавным Буквам"), () => Run(() => Model.FormatAllSongs(SongTextFormat.ByLiters))),
                Item(SongCaptions.Caption("NFormatAllSongByOptimalSize", "Оптимальное размещение на экране"), () => Run(() => Model.FormatAllSongs(SongTextFormat.ByOptimalSize))),
                new Separator(),
                Item(SongCaptions.Caption("NAllSongUnformat", "Отмена форматирования"), () => Run(Model.UnformatAllSongs))),
            new Separator(),
            Item(SongCaptions.Caption("N15", "Очистить поле \"Номер в сборнике\" во ВСЕХ песнях"), () => Run(Model.ClearCatalogNumbers)),
            Item(SongCaptions.Caption("N16", "Установить поле \"Номер в сборнике\" во ВСЕХ песнях равным порядковому номеру"), () => Run(Model.SetCatalogNumbersToOrdinal)));
    }

    ContextMenu? SongMenu(int index)
    {
        if (Model.SongIndex != index) { Model.SongIndex = index; Model.PartIndex = null; Sync(); }
        if (Model.Song is not { } song) return null;
        var items = new List<Control>
        {
            Item(SongCaptions.Caption("MIAddToPlan", "Добавить в План"), () => Model.OnAddToPlan?.Invoke(song, null), _state.AddSongToPlan != null),
            new Separator(),
            Item(SongCaptions.Caption("N18", "Изменить атрибуты и текст песни"), () => Do(() => { Model.EnterEditMode(); Model.OpenSongAttributes(true); })),
            Item(SongCaptions.Caption("N19", "Просмотр атрибутов и текста песни"), () => Do(() => Model.OpenSongAttributes(false))),
            new Separator(),
            Item(SongCaptions.Caption("NShowNumPP", "Показать номер по порядку"), () => Do(() => Model.ShowsCatalogNumber = false)),
            Item(SongCaptions.Caption("NShowNumLog", "Показать номер в сборнике"), () => Do(() => Model.ShowsCatalogNumber = true)),
        };
        if (!Model.IsEditing) return Menu(items.ToArray());
        if (Model.Groups.Count > 0)
        {
            items.Add(new Separator());
            items.Add(Sub(SongCaptions.Caption("NAddToGroup", "Добавить в Группу"),
                Model.Groups.Select((group, offset) => (Control)Item(group.Name, () => Do(() => Model.AddSongToGroup(offset)), !Model.IsSongInGroup(offset))).ToArray()));
        }
        items.Add(new Separator());
        items.Add(Item(SongCaptions.Caption("NDoubleRefrain", "Дублировать припев"), () => Run(() => Model.DuplicateRefrainInSong(false))));
        items.Add(Item(SongCaptions.Caption("NDoubleRefrainByPrizn", "Дублировать припев по признаку"), () => Run(() => Model.DuplicateRefrainInSong(true))));
        items.Add(Sub(SongCaptions.Caption("NSongFormat", "Форматировать песню"),
            Item(SongCaptions.Caption("NFormatSongByLiters", "Разбиение по Заглавным Буквам"), () => Run(() => Model.FormatSong(SongTextFormat.ByLiters))),
            Item(SongCaptions.Caption("NFormatSongByOptimalSize", "Оптимальное размещение на экране"), () => Run(() => Model.FormatSong(SongTextFormat.ByOptimalSize))),
            new Separator(),
            Item(SongCaptions.Caption("NSongUnformat", "Отмена форматирования"), () => Run(Model.UnformatSong))));
        items.Add(Sub(SongCaptions.Caption("N13", "Номера в сборнике"),
            Item(SongCaptions.Caption("NLogNumAddBy", "Увеличить от этой песни и до конца на..."), () => Run(() => Model.ShiftCatalogNumbers(true))),
            Item(SongCaptions.Caption("NLogNumSubBy", "Уменьшить от этой песни и до конца на..."), () => Run(() => Model.ShiftCatalogNumbers(false)))));
        return Menu(items.ToArray());
    }

    ContextMenu? PartMenu(int number)
    {
        if (Model.Song is not { } song) return null;
        var position = song.Parts.FindIndex(p => p.Index == number);
        if (position < 0) return null;
        var part = song.Parts[position];
        var items = new List<Control>
        {
            Item(SongCaptions.Caption("MenuItem1", "Добавить в План"), () => Model.OnAddToPlan?.Invoke(song, part), _state.AddSongToPlan != null),
        };
        if (Model.IsEditing)
            items.Add(Item(SongCaptions.Hint("TBChangeBody", "Изменить содержимое части песни"), () => Do(() => { Model.PartIndex = position; Model.OpenPartEditor(); })));
        return Menu(items.ToArray());
    }
}

/// Корінь вкладки: шапка 30 точок, під нею колонки, внизу панель фонограм.
/// Висоту панелі тягнуть за межу над нею і за нижній край; вона «прилипає» до двох
/// станів — смужки в один ряд і повної панелі (NativeSongsRootView Mac 1.3.9).
public sealed class SongsRootView : LayoutPanel
{
    readonly SongHeader _header;
    readonly ColumnsView _columns;
    readonly BackingTrackBar _backing;
    readonly Border _rule = new();
    /// Межа над панеллю і та сама межа знизу — висоту міняють з обох країв.
    public readonly HeightGrip HeightGrip = new(), BottomGrip = new();
    const string HeightKey = "backingPanelHeight";
    const double Gap = 6, BottomEdge = 5;

    public SongsRootView(SongHeader header, ColumnsView columns, BackingTrackBar backing)
    {
        _header = header;
        _columns = columns;
        _backing = backing;
        Children.Add(header);
        Children.Add(_rule);
        Children.Add(columns);
        Children.Add(HeightGrip);
        Children.Add(backing);
        // Поверх панелі: інакше події миші забирає вона.
        Children.Add(BottomGrip);
        _rule.Background = Palette.Brush(Palette.Separator);
        Palette.Changed += () => _rule.Background = Palette.Brush(Palette.Separator);
        // Верхня межа: вгору — панель вища; нижня — навпаки, вниз — вища.
        HeightGrip.OnDrag = delta => ResizeBacking(-delta);
        BottomGrip.OnDrag = delta => ResizeBacking(delta);
        foreach (var grip in new[] { HeightGrip, BottomGrip })
        {
            grip.OnBegin = BeginBackingDrag;
            grip.OnEnd = EndBackingDrag;
            grip.OnReset = () =>
            {
                var was = _backing.Bounds.Height;
                Widths.Reset(HeightKey);
                _target = null;
                // Подвійне клацання вертає звичну висоту — теж плавно.
                GlideBacking(was, BackingHeight);
            };
        }
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        ApplyCaptions();
    }

    void ApplyCaptions()
    {
        var tip = Captions.T("Потяните вверх или вниз — высота панели фонограмм; двойной щелчок — как было");
        ToolTip.SetTip(HeightGrip, tip);
        ToolTip.SetTip(BottomGrip, tip);
    }

    // --- Висота панелі ---------------------------------------------------------------

    /// Число, яке веде рука (своє, не прив'язане до «прилиплої» висоти); куди панель
    /// їде; число руки в мить останнього перемикання (запас ходу на порозі).
    double? _hand, _target, _flipGuard, _gliding;
    DispatcherTimer? _glide;

    /// Вище панель не піднімається: спискам пісень лишається хоч кілька рядків.
    double MaximumBackingHeight
    {
        get
        {
            // Під час розкладки Bounds ще старі (на першій — нульові): беремо розмір, яким розкладають.
            var free = Math.Max(0, (_height > 0 ? _height : Bounds.Height) - SongHeader.Height - 1 - 8);
            return Math.Max(BackingTrackBar.CollapsedHeight, free - 180);
        }
    }

    /// Висота панелі зараз: поки панель їде — проміжна, інакше збережена, прилиплa до стану.
    public double BackingHeight
    {
        get
        {
            if (_gliding is { } gliding) return Math.Min(MaximumBackingHeight, Math.Max(BackingTrackBar.CollapsedHeight, gliding));
            var saved = Math.Min(MaximumBackingHeight,
                Widths.Value(HeightKey, BackingTrackBar.MinimumHeight + 40, BackingTrackBar.CollapsedHeight, MaximumBackingHeight));
            // Той самий поділ, що й при перетягуванні: або смужка, або повна панель.
            if (saved < BackingTrackBar.MinimumHeight - 24) return BackingTrackBar.CollapsedHeight;
            return Math.Max(BackingTrackBar.MinimumHeight, saved);
        }
    }

    /// Куди панель їде — перевірці: поки триває плавний хід, висота проміжна.
    public double BackingTarget => _target ?? BackingHeight;

    /// Посунути межу: додатне — панель вища. Висота прилипає: нижче повної — смужка,
    /// вище — повна; 24 точки руху — і стан міняється, назад — лише через 40.
    public void ResizeBacking(double delta)
    {
        var goal = _target ?? BackingHeight;
        var start = _hand ?? goal;
        var raw = Math.Min(MaximumBackingHeight + 120, Math.Max(0, start + delta));
        _hand = raw;
        var wasCollapsed = goal <= BackingTrackBar.CollapsedHeight + 1;
        double snapped = wasCollapsed
            ? (raw > BackingTrackBar.CollapsedHeight + 24 ? Math.Max(BackingTrackBar.MinimumHeight, raw) : BackingTrackBar.CollapsedHeight)
            : (raw < BackingTrackBar.MinimumHeight - 24 ? BackingTrackBar.CollapsedHeight : Math.Max(BackingTrackBar.MinimumHeight, raw));
        if (_flipGuard is { } flip && Math.Abs(raw - flip) < 40) snapped = goal;
        Widths.Set(HeightKey, snapped, BackingTrackBar.CollapsedHeight, MaximumBackingHeight);
        var was = _backing.Bounds.Height;
        var changedState = (snapped == BackingTrackBar.CollapsedHeight) != wasCollapsed;
        _target = snapped;
        if (changedState)
        {
            // Рука вже «перетягнула» панель у новий стан — далі рахунок від нього.
            _hand = snapped;
            _flipGuard = raw;
            GlideBacking(was, snapped);
        }
        else if (_glide != null) GlideBacking(was, snapped);
        else InvalidateArrange();
    }

    public void BeginBackingDrag()
    {
        _hand = _target ?? BackingHeight;
        _flipGuard = null;
    }

    public void EndBackingDrag()
    {
        _hand = null;
        _flipGuard = null;
        var target = _target ?? BackingHeight;
        if (Math.Abs(_backing.Bounds.Height - target) > 1) GlideBacking(_backing.Bounds.Height, target);
    }

    /// Плавний перехід між смужкою й повним виглядом: 0,22 с, швидше на початку.
    void GlideBacking(double from, double to)
    {
        StopGlide();
        if (Math.Abs(to - from) <= 1 || Program.Snapshotting) { InvalidateArrange(); return; }
        var started = Environment.TickCount64;
        const double duration = 0.22;
        _gliding = from;
        _glide = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) =>
        {
            var part = Math.Min(1, (Environment.TickCount64 - started) / 1000.0 / duration);
            var eased = 1 - Math.Pow(1 - part, 3);
            _gliding = from + (to - from) * eased;
            if (part >= 1) StopGlide();
            InvalidateArrange();
        });
        _glide.Start();
    }

    void StopGlide()
    {
        _glide?.Stop();
        _glide = null;
        _gliding = null;
    }

    double _height;

    protected override void Arrangement(Size size)
    {
        _height = size.Height;
        Place(_header, new Rect(0, 0, size.Width, SongHeader.Height));
        Place(_rule, new Rect(0, SongHeader.Height, size.Width, 1));
        var top = SongHeader.Height + 1;
        var panel = BackingHeight;
        var columnsHeight = Math.Max(0, size.Height - top - panel - Gap);
        Place(_columns, new Rect(0, top, size.Width, columnsHeight));
        Place(HeightGrip, new Rect(0, top + columnsHeight, size.Width, Gap));
        Place(_backing, new Rect(0, top + columnsHeight + Gap, size.Width, panel));
        // Нижня межа лежить ПОВЕРХ нижнього краю панелі: місця не забирає.
        Place(BottomGrip, new Rect(0, Math.Max(0, top + columnsHeight + Gap + panel - BottomEdge), size.Width, BottomEdge));
    }
}
