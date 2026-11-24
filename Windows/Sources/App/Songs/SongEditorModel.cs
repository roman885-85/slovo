// =============================================================================
//  SongEditorModel.cs — пісенник: що відкрито й що правиться (як SongEditorModel.swift)
// =============================================================================
//  Група, пісня, частина; фільтр пісень за номером або назвою (згорнуті назви
//  кешуються); режим правки з усіма діями розділу 5.3.9 (групи, пісні, частини,
//  форматування, приспіви, номери, сортування, створення, імпорт, експорт,
//  копіювання в інший пісенник) — через SongBookEditor ядра.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed class SongEditorModel
{
    public string BookId { get; private set; } = "";
    public bool IsEditing { get; private set; }
    /// Лічильник змін — вікно перечитує списки за ним.
    public int Revision { get; private set; }
    public int? GroupIndex;
    public int? SongIndex;
    public int? PartIndex;
    public string SongQuery = "";
    public string PartQuery = "";
    public bool ShowsCatalogNumber;

    public SongBookEditor? Editor { get; private set; }
    public SongChunkPalette Palette = SongChunkPalette.FactoryDefault;
    public string? ModulesFolder;
    public SongLibrary? Library;

    public Action<string, SongBook>? OnSaved, OnReloaded;
    public Action<string>? OnLibraryChanged;
    public Action<Song, SongPart, bool>? OnPartChosen;
    public Action<Song, SongPart?>? OnAddToPlan;
    public event Action? Changed;
    /// Вікна правки (5.3.9): властивості пісенника/пісні, нова пісня, редактор частини, копіювання.
    public Action<Sheet>? OpenSheet;

    public abstract record Sheet
    {
        public sealed record BookAttributes(bool Editable) : Sheet;
        public sealed record SongAttributes(int Song, bool Editable) : Sheet;
        public sealed record NewSong : Sheet;
        public sealed record PartEditor(int Song, int? Part) : Sheet;
        public sealed record CopySongs : Sheet;
    }

    public bool HasBook => Editor != null;
    public bool IsModified => Editor?.IsModified ?? false;
    public SongBook? Book => Editor?.Book;
    public IReadOnlyList<SongGroup> Groups => Editor?.Book.Groups ?? (IReadOnlyList<SongGroup>)Array.Empty<SongGroup>();
    public bool HasGroup => GroupIndex != null;
    public bool HasSong => Song != null;
    public bool HasPart => Part != null;

    public Song? Song => SongIndex is { } i && Editor?.Book.Songs is { } songs && i >= 0 && i < songs.Count ? songs[i] : null;
    public SongPart? Part => Song is { } song && PartIndex is { } p && p >= 0 && p < song.Parts.Count ? song.Parts[p] : null;
    public SongPartAlign CurrentAlign => Part?.Align ?? SongPartAlign.Default;

    // --- Фільтр пісень ----------------------------------------------------------------

    List<string> _foldedTitles = new(), _foldedAlternates = new();
    string _foldedBookId = "";
    List<Song> _cachedSongs = new();
    string _cachedKey = "\0";

    void PrepareFolded()
    {
        if (Editor is not { } editor || _foldedBookId == BookId) return;
        _foldedBookId = BookId;
        _foldedTitles = editor.Book.Songs.Select(s => Fold(s.Title)).ToList();
        _foldedAlternates = editor.Book.Songs.Select(s => Fold(s.AlternateTitle)).ToList();
    }

    /// Пісні в списку: група, а в ній — за номером (або номером у збірнику) чи шматком назви.
    public IReadOnlyList<Song> VisibleSongs
    {
        get
        {
            if (Editor is not { } editor) return Array.Empty<Song>();
            var query = SongQuery.Trim();
            var key = $"{BookId}#{(GroupIndex?.ToString() ?? "-")}#{query}#{editor.Book.Songs.Count}";
            if (key == _cachedKey) return _cachedSongs;
            _cachedSongs = ComputeVisible(editor, query);
            _cachedKey = key;
            return _cachedSongs;
        }
    }

    public void InvalidateSongList() { _cachedKey = "\0"; _foldedBookId = ""; }

    List<Song> ComputeVisible(SongBookEditor editor, string query)
    {
        var indices = editor.SongIndices(GroupIndex);
        if (query.Length == 0) return indices.Select(i => editor.Book.Songs[i]).ToList();
        if (int.TryParse(query, out var number))
        {
            var byNumber = indices.Where(i => editor.Book.Songs[i].Number == number || editor.Book.Songs[i].CatalogNumber == number).ToList();
            if (byNumber.Count > 0) return byNumber.Select(i => editor.Book.Songs[i]).ToList();
        }
        PrepareFolded();
        var needle = Fold(query);
        return indices.Where(i => i < _foldedTitles.Count && (_foldedTitles[i].Contains(needle) || _foldedAlternates[i].Contains(needle)))
                      .Select(i => editor.Book.Songs[i]).ToList();
    }

    static string Fold(string text) => SwiftText.Fold(text).Replace("ё", "е");

    // --- Відкрити, перечитати, зберегти -------------------------------------------------

    public async Task<bool> Open(string id, string? url, SongBook? preloaded)
    {
        if (id == BookId && Editor != null) return true;
        if (!await ConfirmDiscardChanges()) return false;
        if (url == null)
        {
            Editor = null;
            BookId = id;
            ResetSelection();
            Bump();
            return true;
        }
        try
        {
            var book = preloaded ?? SongBook.FromFile(url);
            Editor = new SongBookEditor(book, url);
            BookId = id;
        }
        catch (Exception error)
        {
            Editor = null;
            BookId = id;
            Warn(SongCaptions.Error(2, "Ошибка"), SongCaptions.Error(3, "Не удалось открыть файл модуля.\n") + error.Message);
        }
        ResetSelection();
        Bump();
        return true;
    }

    public async Task ReloadBook()
    {
        InvalidateSongList();
        if (Editor is not { Url: { } url }) return;
        if (!await ConfirmDiscardChanges()) return;
        try
        {
            var book = SongBook.FromFile(url);
            Editor = new SongBookEditor(book, url);
            OnReloaded?.Invoke(BookId, book);
            ResetSelection();
            Bump();
        }
        catch (Exception error)
        {
            Warn(SongCaptions.Error(2, "Ошибка"), SongCaptions.Error(3, "Не удалось открыть файл модуля.\n") + error.Message);
        }
    }

    void ResetSelection()
    {
        GroupIndex = null;
        SongIndex = Editor?.Book.Songs.Count > 0 ? 0 : null;
        PartIndex = null;
        SongQuery = "";
        PartQuery = "";
    }

    void Bump() { Revision++; Changed?.Invoke(); }

    void Edit(Action action)
    {
        if (Editor == null) return;
        action();
        InvalidateSongList();
        Bump();
    }

    public void EnterEditMode() { if (!HasBook) return; IsEditing = true; Bump(); }

    public async Task LeaveEditMode()
    {
        if (!await ConfirmDiscardChanges()) return;
        IsEditing = false;
        Bump();
    }

    /// Пісенник змінено — зберегти? Так / Ні / Скасувати.
    public async Task<bool> ConfirmDiscardChanges()
    {
        if (Editor is not { IsModified: true } editor) return true;
        var name = editor.Book.Title.Length == 0 ? BookId : editor.Book.Title;
        var question = SongCaptions.Message(2, "Песенник \"%s\" изменён. Сохранить?").Replace("%s", name);
        switch (await SongPrompt.ThreeWay(SongCaptions.Message(3, "Сохранение Песенника"), question, "Сохранить", "Не сохранять"))
        {
            case SongPrompt.Answer.Yes: Save(); return true;
            case SongPrompt.Answer.No: return true;
            default: return false;
        }
    }

    public void Save()
    {
        if (Editor is not { IsModified: true } editor) return;
        try { editor.Save(); OnSaved?.Invoke(BookId, editor.Book); Bump(); }
        catch (Exception error) { Warn(SongCaptions.Error(1, "Ошибка при сохранении"), error.Message); }
    }

    // --- Пісенник ------------------------------------------------------------------------

    public void OpenBookAttributes(bool editable) { if (HasBook) OpenSheet?.Invoke(new Sheet.BookAttributes(editable && IsEditing)); }

    public void ApplyBookAttributes(string title, string shortName, string publisher, string revisionDate, string comment, uint charset) =>
        Edit(() => Editor!.UpdateAttributes(title, shortName, publisher, revisionDate, comment, charset));

    // --- Групи ---------------------------------------------------------------------------

    public IReadOnlyList<string> GroupTitles => new[] { SongCaptions.Message(4, "Все песни") }.Concat(Groups.Select(g => g.Name)).ToList();

    public async Task AddGroup()
    {
        var name = await SongPrompt.Input(SongCaptions.Message(5, "Создание группы"), SongCaptions.Message(6, "Введите название группы"), "");
        if (string.IsNullOrEmpty(name)) return;
        Edit(() => GroupIndex = Editor!.AddGroup(name));
    }

    public async Task RenameGroup()
    {
        if (GroupIndex is not { } index || index >= Groups.Count) return;
        var name = await SongPrompt.Input(SongCaptions.Message(15, "Редактирование группы"), SongCaptions.Message(6, "Введите название группы"), Groups[index].Name);
        if (string.IsNullOrEmpty(name)) return;
        Edit(() => Editor!.RenameGroup(index, name));
    }

    public async Task DeleteGroup()
    {
        if (GroupIndex is not { } index || index >= Groups.Count) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(1, "Удаление группы"),
                                      SongCaptions.Message(0, "Внимание! Все связи с этой группой будут разорваны. Удалить группу?"))) return;
        Edit(() => { Editor!.RemoveGroup(index); GroupIndex = null; });
    }

    public void DuplicateGroup() { if (GroupIndex is { } index && index < Groups.Count) Edit(() => GroupIndex = Editor!.DuplicateGroup(index)); }
    public void MoveGroup(int delta) { if (GroupIndex is { } index) Edit(() => { if (Editor!.MoveGroup(index, delta) is { } target) GroupIndex = target; }); }
    public bool IsSongInGroup(int group) => SongIndex is { } song && (Editor?.IsSong(song, group) ?? false);
    public void AddSongToGroup(int group) { if (SongIndex is { } song) Edit(() => Editor!.AddSong(song, group)); }

    public async Task RemoveSongFromCurrentGroup()
    {
        if (SongIndex is not { } song || GroupIndex is not { } group) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(14, "Удаление песни из группы"), SongCaptions.Message(13, "Удалить песню из группы?"))) return;
        Edit(() => Editor!.RemoveSong(song, group));
    }

    public bool DeleteRemovesFromGroupOnly => GroupIndex != null;

    // --- Пісні ---------------------------------------------------------------------------

    public void AddSong() { if (HasBook) OpenSheet?.Invoke(new Sheet.NewSong()); }

    public void CreateSong(Action<Song> mutate) => Edit(() =>
    {
        var song = new Song(Editor!.Book.Songs.Count, "");
        mutate(song);
        SongIndex = Editor.AppendSong(song);
        PartIndex = null;
    });

    public async Task DeleteSong()
    {
        if (SongIndex is not { } index) return;
        if (DeleteRemovesFromGroupOnly) { await RemoveSongFromCurrentGroup(); return; }
        if (!await SongPrompt.Confirm(SongCaptions.Message(12, "Удаление песни"), SongCaptions.Message(11, "Внимание! Песня будет удалена из всех групп."))) return;
        Edit(() =>
        {
            Editor!.RemoveSong(index);
            SongIndex = Editor.Book.Songs.Count > 0 ? Math.Min(index, Editor.Book.Songs.Count - 1) : null;
            PartIndex = null;
        });
    }

    public void DuplicateSong() { if (SongIndex is { } index) Edit(() => { if (Editor!.DuplicateSong(index) is { } copy) SongIndex = copy; }); }
    public void MoveSong(int delta) { if (SongIndex is { } index) Edit(() => { if (Editor!.MoveSong(index, delta) is { } target) SongIndex = target; }); }

    public async Task SetSongPosition()
    {
        if (SongIndex is not { } index || Editor is not { } editor) return;
        var raw = await SongPrompt.Input(SongCaptions.Message(29, "Перемещение песни"), SongCaptions.Message(30, "Укажите новую позицию песни"), (index + 1).ToString());
        if (raw == null) return;
        if (!int.TryParse(raw.Trim(), out var number) || number < 1 || number > editor.Book.Songs.Count)
        {
            Warn(SongCaptions.Message(8, "Ошибка ввода"), SongCaptions.Message(31, "Введите корректную позицию песни"));
            return;
        }
        Edit(() => { if (editor.SetSongPosition(index, number) is { } target) SongIndex = target; });
    }

    public async Task SortSongs(SongBookEditor.SongSort order)
    {
        var question = order == SongBookEditor.SongSort.ByNumber
            ? SongCaptions.Message(48, "Произвести сортировку песен по НОМЕРУ?\n(Эта операция необратима!)")
            : SongCaptions.Message(49, "Произвести сортировку песен по НАЗВАНИЮ?\n(Эта операция необратима!)");
        if (!await SongPrompt.Confirm(SongCaptions.Message(47, "Сортировка песен"), question)) return;
        Edit(() => { Editor!.SortSongs(order); SongIndex = Editor.Book.Songs.Count > 0 ? 0 : null; PartIndex = null; });
    }

    public void OpenSongAttributes(bool editable) { if (SongIndex is { } index) OpenSheet?.Invoke(new Sheet.SongAttributes(index, editable && IsEditing)); }
    public void ApplySongAttributes(int index, Action<Song> mutate) => Edit(() => Editor!.UpdateSong(index, mutate));

    // --- Частини -------------------------------------------------------------------------

    public void AddPart() { if (SongIndex is { } song) OpenSheet?.Invoke(new Sheet.PartEditor(song, null)); }
    public void OpenPartEditor() { if (SongIndex is { } song && PartIndex is { } part) OpenSheet?.Invoke(new Sheet.PartEditor(song, part)); }

    public void ApplyPart(int songIndex, int? partIndex, string kind, string text, SongPartAlign align) => Edit(() =>
    {
        if (partIndex is { } p)
        {
            Editor!.UpdatePart(p, songIndex, (ref SongPart part) => { part.Kind = kind; part.Text = text; part.Align = align; });
            PartIndex = p;
        }
        else
        {
            var position = Editor!.Book.Songs[songIndex].Parts.Count;
            PartIndex = Editor.InsertPart(new SongPart(position, kind, text, align), songIndex, position);
        }
    });

    public async Task DeletePart()
    {
        if (SongIndex is not { } song || PartIndex is not { } part) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(19, "Удаление части из песни"), SongCaptions.Message(20, "Удалить эту часть из песни?"))) return;
        Edit(() =>
        {
            Editor!.RemovePart(part, song);
            var count = Editor.Book.Songs[song].Parts.Count;
            PartIndex = count == 0 ? null : Math.Min(part, count - 1);
        });
    }

    public void DuplicatePart() { if (SongIndex is { } s && PartIndex is { } p) Edit(() => { if (Editor!.DuplicatePart(p, s) is { } copy) PartIndex = copy; }); }
    public void MovePart(int delta) { if (SongIndex is { } s && PartIndex is { } p) Edit(() => { if (Editor!.MovePart(p, s, delta) is { } target) PartIndex = target; }); }
    public void SetAlign(SongPartAlign align) { if (SongIndex is { } s && PartIndex is { } p) Edit(() => Editor!.SetAlign(align, p, s)); }
    public void FormatPart(SongTextFormat style) { if (SongIndex is { } s && PartIndex is { } p) Edit(() => Editor!.Format(style, p, s)); }

    public async Task UnformatPart()
    {
        if (SongIndex is not { } s || PartIndex is not { } p) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(26, "Отмена форматирования"), SongCaptions.Message(25, "Убрать переносы строк для этой части песни?"))) return;
        Edit(() => Editor!.Unformat(p, s));
    }

    public async Task DuplicateRefrainInSong(bool byMarker)
    {
        if (SongIndex is not { } song) return;
        string? marker = null;
        if (byMarker)
        {
            marker = await SongPrompt.Input(SongCaptions.Message(16, "Дублировать припевы по признаку"), SongCaptions.Message(22, "Строка-признак припева:"), "");
            if (marker == null) return;
        }
        else if (!await SongPrompt.Confirm(SongCaptions.Message(40, "Внимание"), SongCaptions.Message(27, "Дублировать припев после каждого куплета?"))) return;
        Edit(() => Editor!.DuplicateRefrain(song, marker, Palette));
    }

    public async Task DuplicateRefrainsEverywhere(bool byMarker)
    {
        string? marker = null;
        if (byMarker)
        {
            marker = await SongPrompt.Input(SongCaptions.Message(16, "Дублировать припевы по признаку"), SongCaptions.Message(22, "Строка-признак припева:"), "");
            if (marker == null) return;
        }
        if (!await SongPrompt.Confirm(SongCaptions.Message(40, "Внимание"), SongCaptions.Message(28, "Дублировать припев после каждого куплета\nво ВСЕХ ПЕСНЯХ?"))) return;
        Edit(() => Editor!.DuplicateRefrainsInAllSongs(marker, Palette));
    }

    public async Task FormatSong(SongTextFormat style)
    {
        if (SongIndex is not { } song) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(35, "Форматирование Песни"), SongCaptions.Message(36, "Вы уверены?"))) return;
        Edit(() => Editor!.FormatSong(style, song));
    }

    public async Task UnformatSong()
    {
        if (SongIndex is not { } song) return;
        if (!await SongPrompt.Confirm(SongCaptions.Message(34, "Отмена форматирования"), SongCaptions.Message(36, "Вы уверены?"))) return;
        Edit(() => Editor!.UnformatSong(song));
    }

    public async Task FormatAllSongs(SongTextFormat style)
    {
        if (!await SongPrompt.Confirm(SongCaptions.Message(37, "Форматирование ВСЕХ Песен"),
                                      SongCaptions.Message(36, "Вы уверены?") + "\n" + SongCaptions.Message(39, "Это может занять длительное время."))) return;
        Edit(() => Editor!.FormatAllSongs(style));
    }

    public async Task UnformatAllSongs()
    {
        if (!await SongPrompt.Confirm(SongCaptions.Message(38, "Отмена форматирования ВСЕХ Песен."), SongCaptions.Message(36, "Вы уверены?"))) return;
        Edit(() => Editor!.UnformatAllSongs());
    }

    // --- Номери ---------------------------------------------------------------------------

    public async Task ShiftCatalogNumbers(bool increase)
    {
        if (SongIndex is not { } song) return;
        var prompt = increase ? SongCaptions.Message(43, "Увеличить номера на:") : SongCaptions.Message(44, "Уменьшить номера на:");
        var raw = await SongPrompt.Input(SongCaptions.Message(42, "Изменение номеров песен"), prompt, "1");
        if (raw == null || !int.TryParse(raw.Trim(), out var value) || value == 0) return;
        Edit(() => Editor!.ShiftCatalogNumbers(song, increase ? value : -value));
    }

    public async Task ClearCatalogNumbers()
    {
        if (!await SongPrompt.Confirm(SongCaptions.Message(40, "Внимание"), SongCaptions.Message(45, "Очистить поле \"Номер в сборнике\" во ВСЕХ песнях?"))) return;
        Edit(() => Editor!.ClearCatalogNumbers());
    }

    public async Task SetCatalogNumbersToOrdinal()
    {
        if (!await SongPrompt.Confirm(SongCaptions.Message(40, "Внимание"),
                                      SongCaptions.Message(46, "Установить поле \"Номер в сборнике\" во ВСЕХ песнях равным порядковому номеру?"))) return;
        Edit(() => Editor!.SetCatalogNumbersToOrdinal());
    }

    // --- Новий, імпорт, експорт, копіювання ---------------------------------------------

    public async Task CreateBook()
    {
        if (!await ConfirmDiscardChanges()) return;
        var url = await SongPrompt.SaveFile(SongCaptions.Caption("SaveModuleDialog", "Сохранить Песенник как..."), Captions.T("Новый песенник"),
                                            new[] { SongBookJSON.PathExtension }, ModulesFolder);
        if (url == null) return;
        var name = Path.GetFileNameWithoutExtension(url);
        var editor = new SongBookEditor(SongBookEditor.NewBook(name, name), url, true);
        try { editor.Save(); }
        catch (Exception error) { Warn(SongCaptions.Error(4, "Не удалось создать файл:"), url + "\n" + error.Message); return; }
        Adopt(editor, name);
        OpenSheet?.Invoke(new Sheet.BookAttributes(true));
    }

    public void OpenCopySongs() { if (HasBook) OpenSheet?.Invoke(new Sheet.CopySongs()); }

    public async Task CopySongs(IReadOnlyList<int> indices, SongLibrary.Entry destination)
    {
        if (Editor?.Book is not { } source) return;
        try
        {
            var target = SongBook.FromFile(destination.Url);
            SongBookEditor.CopyConflict? askAll = null;
            var conflicts = new List<Song>();
            // Перший прохід — дізнатися, які пісні вже є (питання асинхронні).
            SongBookEditor.CopySongs(indices, source, SongBook.FromFile(destination.Url), song => { conflicts.Add(song); return SongBookEditor.CopyConflict.Skip; });
            var decisions = new Dictionary<string, SongBookEditor.CopyConflict>();
            foreach (var song in conflicts)
            {
                if (askAll is { } all) { decisions[song.Title] = all; continue; }
                var question = SongCaptions.Message(41, "Песня \"%s\" уже существует в приемном Песеннике.\nПерезаписать?").Replace("%s", song.Title);
                var answer = await SongPrompt.ThreeWay(SongCaptions.Message(40, "Внимание"), question, "Перезаписать", "Пропустить");
                decisions[song.Title] = answer switch
                {
                    SongPrompt.Answer.Yes => SongBookEditor.CopyConflict.Overwrite,
                    SongPrompt.Answer.No => SongBookEditor.CopyConflict.Skip,
                    _ => (askAll = SongBookEditor.CopyConflict.Skip).Value,
                };
            }
            SongBookEditor.CopySongs(indices, source, target, song => decisions.TryGetValue(song.Title, out var d) ? d : SongBookEditor.CopyConflict.Skip);
            SongBookJSON.Save(target, destination.Url);
            OnSaved?.Invoke(destination.Id, target);
        }
        catch (Exception error) { Warn(SongCaptions.Error(5, "Не удалось перезаписать файл:"), destination.Url + "\n" + error.Message); }
    }

    public async Task ImportBibleQuote()
    {
        if (!await ConfirmDiscardChanges()) return;
        var source = await SongPrompt.OpenFile(SongCaptions.Message(33, "Импорт Песенника"), new[] { "ini" });
        if (source == null) return;
        var marker = await SongPrompt.Input(SongCaptions.Message(33, "Импорт Песенника"), SongCaptions.Message(22, "Строка-признак припева:"), "");
        if (marker == null) return;
        await ImportBook(Path.GetFileNameWithoutExtension(source), () => SongBookImporter.FromBibleQuote(source, marker.Length == 0 ? null : marker, Palette));
    }

    public async Task ImportSoftProjector()
    {
        if (!await ConfirmDiscardChanges()) return;
        var source = await SongPrompt.OpenFile(SongCaptions.Message(33, "Импорт Песенника"), new[] { "sps" });
        if (source == null) return;
        await ImportBook(Path.GetFileNameWithoutExtension(source), () => SongBookImporter.FromSoftProjector(source, Palette));
    }

    async Task ImportBook(string suggestion, Func<SongBook> make)
    {
        SongBook imported;
        try { imported = make(); }
        catch (Exception error) { Warn(SongCaptions.Error(2, "Ошибка"), error.Message); return; }
        var url = await SongPrompt.SaveFile(SongCaptions.Caption("SaveModuleDialog", "Сохранить Песенник как..."), suggestion,
                                            new[] { SongBookJSON.PathExtension }, ModulesFolder);
        if (url == null) return;
        var editor = new SongBookEditor(imported, url, true);
        try { editor.Save(); }
        catch (Exception error) { Warn(SongCaptions.Error(4, "Не удалось создать файл:"), url + "\n" + error.Message); return; }
        Adopt(editor, Path.GetFileNameWithoutExtension(url));
        OpenSheet?.Invoke(new Sheet.BookAttributes(true));
    }

    public async Task ExportToTextFile()
    {
        if (Editor?.Book is not { } book) return;
        var answer = await SongPrompt.ThreeWay(SongCaptions.Message(50, "Экспорт Песенника"),
            SongCaptions.Message(55, "Экспортировать вместе со служебной информацией Песенника?\n\nДа - экспортировать тексты песен и служебную информацию\nНет - экспортировать только тексты песен"),
            "Да", "Нет");
        string text;
        switch (answer)
        {
            case SongPrompt.Answer.Yes: text = SongBookTextFile.ExportWithServiceInfo(book); break;
            case SongPrompt.Answer.No:
                text = SongBookTextFile.ExportPlain(book, ShowsCatalogNumber ? SongBookTextFile.Numbering.Catalog : SongBookTextFile.Numbering.Ordinal);
                break;
            default: return;
        }
        var url = await SongPrompt.SaveFile(SongCaptions.Caption("SaveModuleAsTextDialog", "Сохранить Песенник в текстовый файл как..."),
                                            book.ShortName.Length == 0 ? BookId : book.ShortName, new[] { "txt" }, null);
        if (url == null) return;
        try { SongBookTextFile.Write(text, url); }
        catch (Exception error) { Warn(SongCaptions.Error(4, "Не удалось создать файл:"), url + "\n" + error.Message); }
    }

    public async Task ImportFromTextFile()
    {
        if (Editor == null) return;
        var url = await SongPrompt.OpenFile(SongCaptions.Caption("loadModuleAsTextDialog", "Загрузить Песенник из текстового файла"), new[] { "txt" });
        if (url == null) return;
        if (ReadText(url) is not { } text)
        {
            Warn(SongCaptions.Error(2, "Ошибка"), SongCaptions.Error(3, "Не удалось открыть файл модуля.\n") + url);
            return;
        }
        var answer = await SongPrompt.ThreeWay(SongCaptions.Message(56, "Чтение Песенника из текстового файла"),
            SongCaptions.Message(57, "Добавить песни в конец Песенника?\n\nДа - добавить в конец\nНет - полностью заменить все песни"), "Да", "Нет");
        SongBookTextFile.ImportMode mode;
        switch (answer)
        {
            case SongPrompt.Answer.Yes: mode = SongBookTextFile.ImportMode.Append; break;
            case SongPrompt.Answer.No: mode = SongBookTextFile.ImportMode.Replace; break;
            default: return;
        }
        Edit(() =>
        {
            var current = Editor!;
            var book = current.Book;
            var added = SongBookTextFile.ImportSongs(text, book, mode, Palette);
            if (added <= 0) { Warn(SongCaptions.Error(2, "Ошибка"), SongCaptions.Message(53, "Песен не найдено")); return; }
            Editor = new SongBookEditor(book, current.Url, true);
            SongIndex = book.Songs.Count == 0 ? null : 0;
            PartIndex = null;
            IsEditing = true;
        });
    }

    void Adopt(SongBookEditor editor, string id)
    {
        Editor = editor;
        BookId = id;
        ResetSelection();
        IsEditing = true;
        OnLibraryChanged?.Invoke(id);
        Bump();
    }

    static void Warn(string title, string message) => SongPrompt.Warn(title, message);

    static string? ReadText(string path)
    {
        try
        {
            var data = File.ReadAllBytes(path);
            try { return new System.Text.UTF8Encoding(false, true).GetString(data); }
            catch { CodePage.Register(); return System.Text.Encoding.GetEncoding(1251).GetString(data); }
        }
        catch { return null; }
    }
}
