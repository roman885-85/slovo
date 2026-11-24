// =============================================================================
//  SongSheets.cs — вікна правки пісенника (як NativeSongSheets і NativeSongDialogs)
// =============================================================================
//  «Атрибути Пісенника» (520×300), «Пісня» з полями й текстом (760×480, ключі
//  частин #Куплет…, $Align$), «Частина пісні» (520×460: вид, вирівнювання,
//  форматування), «Копіювання пісень в інший Пісенник» (620×560). Заголовок
//  напівжирний 13 пт угорі, кнопки праворуч унизу; Esc — скасувати, Enter — Ок.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public static class SongSheets
{
    static Window? _open;
    public static bool IsOpen => _open != null;
    /// Відкрите вікно — для знімка (--sheet).
    public static Window? Current => _open;

    static string SongForm(string key, string fallback) => Captions.FormCaption(key, "SongEditNameForm", fallback);
    static string ChunkForm(string key, string fallback) => Captions.FormCaption(key, "SongEditChunkForm", fallback);
    static string CopyForm(string key, string fallback) => Captions.FormCaption(key, "ImportSongsDialogForm", fallback);

    static IReadOnlyList<string> ChunkNames
    {
        get
        {
            string[] fallback = { "Куплет", "Припев", "Запев", "Мост", "Вступление", "Кода" };
            return fallback.Select((f, i) => ChunkForm($"ChunksName{i}", f)).ToList();
        }
    }

    static readonly (uint Value, string Title)[] Charsets =
    {
        (512, "UNICODE"), (1, "По умолчанию"), (0, "ANSI"), (204, "Кириллица"), (238, "Восточноевропейская"),
        (161, "Греческая"), (162, "Турецкая"), (177, "Иврит"), (186, "Балтийская"),
    };

    /// Відкрити вікно для прохання моделі (одне за раз).
    public static void Open(SongEditorModel.Sheet sheet, SongsWorkspace workspace)
    {
        _open?.Close();
        var model = workspace.Model;
        Window? window = sheet switch
        {
            SongEditorModel.Sheet.BookAttributes b when model.Book is { } book => BookAttributes(b.Editable, book, (t, s, p, d, c, cs) =>
                model.ApplyBookAttributes(t, s, p, d, c, cs)),
            SongEditorModel.Sheet.SongAttributes s when model.Book is { } book && s.Song >= 0 && s.Song < book.Songs.Count =>
                SongAttributes(s.Editable, model.Palette, book.Songs[s.Song], null, mutate => model.ApplySongAttributes(s.Song, mutate)),
            SongEditorModel.Sheet.NewSong => SongAttributes(true, model.Palette, new Song(0, ""), SongCaptions.Message(9, "Создание песни"), model.CreateSong),
            SongEditorModel.Sheet.PartEditor p when model.Book is { } book && p.Song >= 0 && p.Song < book.Songs.Count =>
                PartSheet(book.Songs[p.Song].Title,
                          p.Part is { } i && i >= 0 && i < book.Songs[p.Song].Parts.Count ? book.Songs[p.Song].Parts[i] : null,
                          (kind, text, align) => model.ApplyPart(p.Song, p.Part, kind, text, align)),
            SongEditorModel.Sheet.CopySongs when model.Book is { } book => CopySongs(book.Title.Length == 0 ? model.BookId : book.Title, book.Songs,
                AppState.Shared.SongBooks.Where(e => e.Id != model.BookId).ToList(), (indices, entry) => _ = model.CopySongs(indices, entry)),
            _ => null,
        };
        if (window == null) return;
        _open = window;
        window.Closed += (_, _) => { if (_open == window) _open = null; workspace.Sync(); };
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
    }

    // --- Каркас --------------------------------------------------------------------------

    sealed class Sheet : Window
    {
        public readonly LayoutPanel Body = new();
        readonly BottomCaption _heading = new() { FontSize = 13, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        public readonly List<PushButton> Buttons = new();
        public Action<Size>? Arrange;

        public Sheet(string heading, double width, double height)
        {
            Title = "";
            Width = width; Height = height; MinWidth = 520; MinHeight = 360;
            WindowStartupLocation = WindowStartupLocation.CenterOwner;
            Background = Palette.Brush(Palette.WindowBackground);
            _heading.Text = heading;
            Body.Children.Add(_heading);
            Body.Layout = size =>
            {
                Body.Place(_heading, new Rect(16, 14, size.Width - 32, 18));
                var right = size.Width - 16;
                foreach (var button in Buttons.AsEnumerable().Reverse())
                {
                    var w = Math.Max(90, button.FittingWidth + 24);
                    Body.Place(button, new Rect(right - w, size.Height - 40, w, 24));
                    right -= w + 8;
                }
                Arrange?.Invoke(size);
            };
            Content = Body;
            KeyDown += (_, e) =>
            {
                if (e.Key == Key.Escape) { Close(); e.Handled = true; }
            };
        }

        public void AddButtons(params PushButton[] buttons)
        {
            foreach (var b in buttons) { Buttons.Add(b); Body.Children.Add(b); }
        }
    }

    static BottomCaption RightLabel(string text) => new() { Text = text, FontSize = 11, Align = TextAlignment.Right, Color = () => Palette.Label };

    static FormField Field(string value, bool editable)
    {
        var field = new FormField(12) { Text = value };
        field.Box.IsReadOnly = !editable;
        return field;
    }

    /// Поле тексту: у «Пісні» — моноширинне (як NativeSongLyricsView), у частині — звичайний шрифт 12.
    static TextBox Editor(string text, bool editable, bool monospace = false) => new()
    {
        Text = text, AcceptsReturn = true, AcceptsTab = false, TextWrapping = TextWrapping.Wrap, IsReadOnly = !editable,
        FontFamily = monospace ? new FontFamily("Cascadia Mono,Consolas,Menlo,monospace") : UiFont.Family, FontSize = 12, Padding = new Thickness(4),
        BorderThickness = new Thickness(1), BorderBrush = Palette.Brush(Palette.Separator), Background = Palette.Brush(Palette.TextBackground),
        Foreground = Palette.Brush(Palette.Label),
    };

    // --- Атрибути пісенника -----------------------------------------------------------------

    static Window BookAttributes(bool editable, SongBook book, Action<string, string, string, string, string, uint> apply)
    {
        var sheet = new Sheet((editable ? SongForm("TextMessages0", "Редактирование") : SongForm("TextMessages9", "Просмотр"))
                              + " " + SongForm("TextMessages2", "атрибутов Песенника"), 520, 300);
        var values = new[] { book.Title, book.ShortName, book.Publisher, book.RevisionDate, book.Comment };
        var fields = values.Select(v => Field(v, editable)).ToList();
        var titles = new[] { SongForm("Label2", "Название:"), SongForm("TextMessages6", "Коротк.назв.:"), SongForm("TextMessages8", "Copyright:"),
                             SongForm("Label5", "Дата:"), SongForm("Label6", "Заметки:"), SongForm("Label8", "Кодировка:") };
        var labels = titles.Select(RightLabel).ToList();
        var charset = new PopupButton(Charsets.Select(c => Captions.T(c.Title)), Math.Max(0, Array.FindIndex(Charsets, c => c.Value == book.Charset)))
        { IsEnabled = editable };
        var warning = new BottomCaption
        {
            Text = Captions.T("Для всех новых Песенников необходимо использовать кодировку «UNICODE»."), FontSize = 11, Color = () => Palette.SystemOrange,
            IsVisible = editable && book.Charset != SongBook.UnicodeCharset,
        };
        foreach (Control c in labels.Cast<Control>().Concat(fields).Append(charset).Append(warning)) sheet.Body.Children.Add(c);
        if (editable)
        {
            var cancel = new PushButton(SongForm("BBCancel", "Отменить")) { Pressed = sheet.Close };
            var ok = new PushButton(SongForm("BBSave", "Ок")) { Prominent = true };
            ok.Pressed = () =>
            {
                apply(fields[0].Text, fields[1].Text, fields[2].Text, fields[3].Text, fields[4].Text, Charsets[Math.Clamp(charset.SelectedIndex, 0, Charsets.Length - 1)].Value);
                sheet.Close();
            };
            sheet.AddButtons(cancel, ok);
        }
        else sheet.AddButtons(new PushButton(SongForm("BBClose", "Ок")) { Prominent = true, Pressed = sheet.Close });
        sheet.Arrange = size =>
        {
            double top = 46;
            for (var i = 0; i < fields.Count; i++)
            {
                sheet.Body.Place(labels[i], new Rect(16, top + 3, 130, 16));
                sheet.Body.Place(fields[i], new Rect(154, top, size.Width - 170, 22));
                top += 28;
            }
            sheet.Body.Place(labels[5], new Rect(16, top + 3, 130, 16));
            sheet.Body.Place(charset, new Rect(154, top, 220, 22));
            top += 30;
            sheet.Body.Place(warning, new Rect(16, top, size.Width - 32, 16));
        };
        return sheet;
    }

    // --- Пісня -----------------------------------------------------------------------------

    static Window SongAttributes(bool editable, SongChunkPalette palette, Song song, string? heading, Action<Action<Song>> apply)
    {
        var sheet = new Sheet(heading is { Length: > 0 } ? heading
                              : (editable ? SongForm("TextMessages0", "Редактирование") : SongForm("TextMessages9", "Просмотр")) + " " + SongForm("TextMessages1", "песни"),
                              760, 480);
        var values = new[] { song.Title, song.AlternateTitle, song.Author, song.Composer, song.Note, song.Tune, song.CatalogNumberText };
        var fields = values.Select(v => Field(v, editable)).ToList();
        var titles = new[] { SongForm("Label2", "Название:"), SongForm("Label1", "Альтерн. название:"), SongForm("Label4", "Слова:"),
                             SongForm("Label3", "Музыка:"), SongForm("Label5", "Дата:"), SongForm("Label7", "Тональность:"), SongForm("LLogicNum", "Номер в сборнике:") };
        var labels = titles.Select(RightLabel).ToList();
        var lyrics = new LyricsEditor(SongTextMarkup.Text(song.Parts).Replace("\r\n", "\n"), editable, palette);
        void Insert(string keyword) => lyrics.Insert(keyword);
        var keywords = new PushButton(SongForm("PSBInsKeyWord", "Вставить ключ") + " ⌄") { IsEnabled = editable };
        keywords.Pressed = () =>
        {
            var entries = palette.Chunks.Select(c => new MenuEntry(c.Title, () => Insert("#" + c.Title))).ToList();
            var first = true;
            foreach (var value in new[] { "$Align$=Left", "$Align$=Center", "$Align$=Right" })
            {
                var chosen = value;
                entries.Add(new MenuEntry(chosen, () => Insert(chosen), StartsGroup: first));
                first = false;
            }
            var menu = MenuStrip.Build(entries);
            menu.PlacementTarget = keywords;
            menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
            menu.Open(keywords);
        };
        foreach (Control c in labels.Cast<Control>().Concat(fields).Append(lyrics).Append(keywords)) sheet.Body.Children.Add(c);
        if (editable)
        {
            var cancel = new PushButton(SongForm("BBCancel", "Отменить")) { Pressed = sheet.Close };
            var ok = new PushButton(SongForm("BBSave", "Ок")) { Prominent = true };
            ok.Pressed = () =>
            {
                var parts = SongTextMarkup.Parts(lyrics.Text, palette);
                var v = fields.Select(f => f.Text).ToList();
                apply(s =>
                {
                    s.Title = v[0]; s.AlternateTitle = v[1]; s.Author = v[2]; s.Composer = v[3]; s.Note = v[4];
                    s.SetProperty("$TUNE$", v[5]);
                    s.SetProperty("$ID$", v[6].Length == 0 ? null : v[6]);
                    s.Parts = parts;
                });
                sheet.Close();
            };
            sheet.AddButtons(cancel, ok);
        }
        else sheet.AddButtons(new PushButton(SongForm("BBClose", "Ок")) { Prominent = true, Pressed = sheet.Close });
        sheet.Arrange = size =>
        {
            double top = 46;
            for (var i = 0; i < fields.Count; i++)
            {
                sheet.Body.Place(labels[i], new Rect(16, top + 3, 140, 16));
                sheet.Body.Place(fields[i], new Rect(164, top, 200, 22));
                top += 28;
            }
            const double left = 380;
            sheet.Body.Place(keywords, new Rect(size.Width - 176, 44, 160, 22));
            sheet.Body.Place(lyrics, new Rect(left, 72, size.Width - left - 16, Math.Max(0, size.Height - 72 - 52)));
        };
        return sheet;
    }

    // --- Частина пісні ----------------------------------------------------------------------

    static Window PartSheet(string songTitle, SongPart? part, Action<string, string, SongPartAlign> apply)
    {
        var sheet = new Sheet(part == null ? SongCaptions.Message(17, "Создание новой части") : SongCaptions.Message(18, "Редактирование части"), 520, 460);
        var align = part?.Align ?? SongPartAlign.Default;
        var songLine = new BottomCaption { Text = ChunkForm("Label1", "Песня:") + "  " + songTitle, FontSize = 12, Color = () => Palette.Label };
        var kind = new FormField(12) { Text = part?.Kind ?? ChunkNames.FirstOrDefault() ?? "Куплет" };
        var kinds = new PushButton("", "chevron.down", ControlSize.Small);
        kinds.Pressed = () =>
        {
            var menu = MenuStrip.Build(ChunkNames.Select(n => new MenuEntry(n, () => kind.Text = n)).ToList());
            menu.PlacementTarget = kind;
            menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
            menu.Open(kind);
        };
        var text = Editor((part?.Text ?? "").Replace("\r\n", "\n"), true);
        var marks = new (string Title, SongPartAlign Value, string Hint)[]
        {
            ("≡", SongPartAlign.Default, ChunkForm("TBAlignDefault", "Выравнивание по умолчанию")),
            ("⇤", SongPartAlign.Left, ChunkForm("TBAlignLeft", "Выравнивание по левому краю")),
            ("↔", SongPartAlign.Center, ChunkForm("TBAlignCenter", "Выравнивание по центру")),
            ("⇥", SongPartAlign.Right, ChunkForm("TBAlignRight", "Выравнивание по правому краю")),
        };
        var alignButtons = new List<PushButton>();
        // Вибране вирівнювання — підпис кольором акценту (contentTintColor на Mac).
        void MarkAlign()
        {
            for (var i = 0; i < 4; i++)
            {
                var on = marks[i].Value == align;
                alignButtons[i].TitleTint = on ? () => Palette.Accent : null;
                alignButtons[i].InvalidateVisual();
            }
        }
        foreach (var (title, value, hint) in marks)
        {
            var chosen = value;
            var b = new PushButton(title) { Pressed = () => { align = chosen; MarkAlign(); } };
            ToolTip.SetTip(b, hint);
            alignButtons.Add(b);
        }
        var format = new PushButton("¶");
        ToolTip.SetTip(format, ChunkForm("TBFormat", "Форматирование текста"));
        format.Pressed = () =>
        {
            var menu = MenuStrip.Build(new List<MenuEntry>
            {
                new(SongCaptions.Caption("NFormatByLiters", "Разбиение по Заглавным Буквам"), () => text.Text = SongTextFormatter.ByLiters(text.Text ?? "")),
                new(SongCaptions.Caption("NFormatByOptimalSize", "Оптимальное размещение на экране"), () => text.Text = SongTextFormatter.ByOptimalSize(text.Text ?? "")),
            });
            menu.PlacementTarget = format;
            menu.Open(format);
        };
        var unformat = new PushButton("↺") { Pressed = () => text.Text = SongTextFormatter.Unformat(text.Text ?? "") };
        ToolTip.SetTip(unformat, ChunkForm("TBUnformat", "Отмена форматирования"));
        alignButtons.Add(format);
        alignButtons.Add(unformat);
        foreach (Control c in new Control[] { songLine, kind, kinds, text }.Concat(alignButtons)) sheet.Body.Children.Add(c);
        var cancel = new PushButton(ChunkForm("BBCancel", "Отменить")) { Pressed = sheet.Close };
        var ok = new PushButton(ChunkForm("BBSave", "Ок")) { Prominent = true };
        ok.Pressed = () => { apply(kind.Text, (text.Text ?? "").Replace("\n", "\r\n"), align); sheet.Close(); };
        sheet.AddButtons(cancel, ok);
        MarkAlign();
        sheet.Arrange = size =>
        {
            sheet.Body.Place(songLine, new Rect(16, 42, size.Width - 32, 18));
            // Поле з випадним списком (NSComboBox 260 завширшки): стрілка — у правому краї поля.
            sheet.Body.Place(kind, new Rect(16, 68, 238, 24));
            sheet.Body.Place(kinds, new Rect(250, 68, 30, 24));
            for (var i = 0; i < alignButtons.Count; i++) sheet.Body.Place(alignButtons[i], new Rect(16 + i * 34, 100, 30, 24));
            sheet.Body.Place(text, new Rect(16, 132, size.Width - 32, Math.Max(0, size.Height - 132 - 52)));
        };
        return sheet;
    }

    // --- Копіювання пісень --------------------------------------------------------------------

    sealed class CopyRows : IRowSource
    {
        readonly IReadOnlyList<Song> _songs;
        public CopyRows(IReadOnlyList<Song> songs) { _songs = songs; }
        public int RowCount => _songs.Count;
        public Row RowAt(int index) => new(_songs[index].Title, _songs[index].Index.ToString()) { SingleLine = true };
    }

    static Window CopySongs(string sourceName, IReadOnlyList<Song> songs, IReadOnlyList<SongLibrary.Entry> destinations, Action<IReadOnlyList<int>, SongLibrary.Entry> copy)
    {
        var sheet = new Sheet(CopyForm("ImportSongsDialogForm", "Копирование песен в другой Песенник"), 620, 560);
        var sourceLine = new BottomCaption { Text = CopyForm("Label4", "Исходный песенник:") + "  " + sourceName, FontSize = 12, Color = () => Palette.Label };
        var destination = new PopupButton(destinations.Select(d => d.DisplayName));
        var query = new FormField(12);
        var list = new RowList(new ListMetrics { LeadWidth = 44 }, 13) { Source = new CopyRows(songs), AllowsMultipleSelection = true };
        list.SetUniformHeight(22);
        var chosen = new HashSet<int>();
        int? found = null;
        list.OnSelect = (rows, _, _) => { chosen.Clear(); foreach (var r in rows) chosen.Add(songs[r].Index); };
        void Step(int delta)
        {
            var needle = query.Text.ToLowerInvariant();
            if (needle.Length == 0) return;
            var start = (found ?? -1) + delta;
            var order = delta > 0 ? Enumerable.Range(0, songs.Count) : Enumerable.Range(0, songs.Count).Reverse();
            int? next = null;
            foreach (var i in order)
                if ((delta > 0 ? i >= start : i <= start) && songs[i].Title.ToLowerInvariant().Contains(needle)) { next = i; break; }
            if (next is not { } hit) return;
            found = hit;
            list.ScrollTo(hit, ScrollPlace.Center);
        }
        var cancel = new PushButton(CopyForm("BBCancel", "Отменить")) { Pressed = sheet.Close };
        var ok = new PushButton(CopyForm("BBOk", "Ок")) { Prominent = true };
        ok.Pressed = () =>
        {
            if (chosen.Count > 0 && destination.SelectedIndex >= 0 && destination.SelectedIndex < destinations.Count)
                copy(chosen.OrderBy(i => i).ToList(), destinations[destination.SelectedIndex]);
            sheet.Close();
        };
        var prev = new PushButton("↑") { Pressed = () => Step(-1) };
        ToolTip.SetTip(prev, CopyForm("PngSBSearchPrev", "Искать предыдущее"));
        var next = new PushButton("↓") { Pressed = () => Step(1) };
        ToolTip.SetTip(next, CopyForm("PngSBSearchNext", "Искать следующее"));
        var all = new PushButton("☑") { Pressed = () => { chosen.Clear(); foreach (var s in songs) chosen.Add(s.Index); list.SetSelection(Enumerable.Range(0, songs.Count), 0); } };
        ToolTip.SetTip(all, CopyForm("PngSBSelAll", "Выделить все песни"));
        var none = new PushButton("☐") { Pressed = () => { chosen.Clear(); list.SetSelection(Array.Empty<int>()); } };
        ToolTip.SetTip(none, CopyForm("PngSBSelNone", "Снять выделение со всех песен"));
        foreach (Control c in new Control[] { sourceLine, destination, query, list, prev, next, all, none }) sheet.Body.Children.Add(c);
        sheet.AddButtons(cancel, ok);
        sheet.Arrange = size =>
        {
            sheet.Body.Place(sourceLine, new Rect(16, 42, size.Width - 32, 18));
            sheet.Body.Place(destination, new Rect(16, 68, 320, 24));
            sheet.Body.Place(query, new Rect(16, 100, 220, 22));
            sheet.Body.Place(prev, new Rect(244, 100, 30, 22));
            sheet.Body.Place(next, new Rect(278, 100, 30, 22));
            sheet.Body.Place(all, new Rect(size.Width - 86, 100, 30, 22));
            sheet.Body.Place(none, new Rect(size.Width - 50, 100, 30, 22));
            sheet.Body.Place(list, new Rect(16, 132, size.Width - 32, Math.Max(0, size.Height - 132 - 52)));
        };
        return sheet;
    }
}
