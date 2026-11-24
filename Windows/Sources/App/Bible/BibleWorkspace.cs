// =============================================================================
//  BibleWorkspace.cs — вкладка «Біблія»: Клас | Книга | Розділ | Вірш
// =============================================================================
//  Як NativeBibleWorkspace + NativeBibleColumns + NativeVerseColumn на Mac:
//  чотири колонки з підписами («Клас:», «Книга:», «Розділ:», «Вірш:»), межі
//  тягнуться (ширини 96…150, 200…380, 54…110, решта — віршам). Книга — плиткою
//  (скорочення + назва кольором розділу канону) або списком; під колонками —
//  поля швидкого вводу. Вірші — висота рядка за текстом, червона риска під
//  кожним десятим. Клацання готує вірш у перегляді, подвійне — у зал.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public static class BookPalette
{
    static Color C(double r, double g, double b) => Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));
    public static Color ColorOf(BookInfo book) => book.CanonicalNumber switch
    {
        >= 10 and <= 50 => C(0.10, 0.14, 0.42),
        >= 60 and <= 190 => C(0.00, 0.45, 0.20),
        >= 220 and <= 260 => C(0.00, 0.42, 0.38),
        >= 290 and <= 460 => C(0.32, 0.30, 0.05),
        >= 470 and <= 500 => C(0.70, 0.10, 0.10),
        510 => C(0.55, 0.20, 0.05),
        >= 520 and <= 720 => C(0.13, 0.25, 0.62),
        730 => C(0.45, 0.10, 0.45),
        _ => Palette.Label,
    };
}

public sealed class BibleWorkspace
{
    readonly AppState _state;
    public readonly ColumnsView View = new();
    readonly LabelledPane[] _panes = { new(), new(), new(), new() };
    public readonly RowList ClassList, BookList, ChapterList, VerseList;
    public readonly QuickField BookQuick = new(), ChapterQuick = new(), VerseQuick = new();
    readonly ClassRows _classRows;
    readonly BookRows _bookRows;
    readonly ChapterRows _chapterRows;
    readonly VerseRows _verseRows;

    public BibleWorkspace(AppState state)
    {
        _state = state;
        _classRows = new ClassRows();
        _bookRows = new BookRows(state);
        _chapterRows = new ChapterRows(state);
        _verseRows = new VerseRows(state);

        ClassList = new RowList(new ListMetrics { Padding = new Thickness(6, 3, 6, 3), TextFontDelta = 0 }, 12) { Source = _classRows };
        ClassList.SetUniformHeight(20);
        ClassList.OnSelect = (_, i, cause) =>
        {
            if (cause == SelectCause.Code || i < 0 || i >= 4) return;
            _state.BookClass = (BookClass)i;
            Signals.Shared.Send(Signals.Kind.BookClass);
            Signals.Shared.Send(Signals.Kind.Books);
        };

        var font = state.ListFontSize;
        BookList = new RowList(new ListMetrics { LeadFontDelta = -1, DetailFontDelta = Math.Max(8 - font, -4) }, font) { Source = _bookRows };
        ApplyBookMode();
        BookList.OnSelect = (_, i, cause) =>
        {
            if (cause == SelectCause.Code || _bookRows.Position(i) is not { } book || _state.SelectedBookIndex == book) return;
            _state.SelectedBookIndex = book;
        };

        ChapterList = new RowList(ListMetrics.Chapters(), font) { Source = _chapterRows };
        ChapterList.SetUniformHeight(Math.Ceiling(UiFont.LineHeight(font)) + 6);
        ChapterList.OnSelect = (_, i, cause) =>
        {
            if (cause == SelectCause.Code || i < 0 || i >= _state.Chapters.Count) return;
            _state.SelectedChapterNumber = _state.Chapters[i].Number;
        };

        VerseList = new RowList(ListMetrics.Verses(), font) { Source = _verseRows, AllowsMultipleSelection = true };
        VerseList.SetMeasuredHeights(22);
        VerseList.OnSelect = (selection, active, cause) => { if (cause != SelectCause.Code) Chose(active, selection, cause, false); };
        VerseList.OnActivate = i => Chose(i, new[] { i }, SelectCause.DoubleClick, true);

        foreach (var list in new[] { BookList, ChapterList, VerseList })
            list.OnZoom = delta => _state.ZoomLists(delta > 0 ? 1 : -1);

        // Кнопки (22): «плиткою» — «списком»; (21): багаторядковий — в одну лінію.
        _bookButtons = IconRow(("square.grid.2x2", () => InterfaceSettings.Shared.SetBooksFlow(true, _state.ListScope)),
                               ("list.bullet", () => InterfaceSettings.Shared.SetBooksFlow(false, _state.ListScope)));
        _verseButtons = IconRow(
            (InterfaceSettings.Caption(InterfaceSettings.VerseViewMode.Multiline).Symbol,
             () => InterfaceSettings.Shared.SetVerseView(InterfaceSettings.VerseViewMode.Multiline, _state.ListScope)),
            (InterfaceSettings.Caption(InterfaceSettings.VerseViewMode.SingleLine).Symbol,
             () => InterfaceSettings.Shared.SetVerseView(InterfaceSettings.VerseViewMode.SingleLine, _state.ListScope)));
        var bookColumn = Column(BookList, BookQuick, _bookButtons);
        var chapterColumn = Column(ChapterList, ChapterQuick, null);
        var verseColumn = Column(VerseList, VerseQuick, _verseButtons);
        ApplyVerseKind(true);
        // Як на Mac: кнопки (22) підсвічуються одразу, (21) — після першого
        // вибору вигляду (NativeVerseColumn на старті applyButtons не кличе).
        ApplyButtons(verses: false);
        var classColumn = new Border { Child = ClassList, Padding = new Thickness(4), Background = Palette.Brush(Palette.TextBackground) };
        Palette.Changed += () => classColumn.Background = Palette.Brush(Palette.TextBackground);
        _panes[0].Install(classColumn);
        _panes[1].Install(bookColumn);
        _panes[2].Install(chapterColumn);
        _panes[3].Install(verseColumn);
        View.Install(new[]
        {
            new ColumnsView.Column(_panes[0], 96, 112, 150), new ColumnsView.Column(_panes[1], 200, 270, 380),
            new ColumnsView.Column(_panes[2], 54, 72, 110), new ColumnsView.Column(_panes[3], 320, 320, 0),
        });
        // Поля швидкого вибору (6): набір одразу веде до книги/розділу/вірша.
        BookQuick.OnChange = BookQuick.OnSubmit = ApplyBookQuery;
        ChapterQuick.OnChange = ChapterQuick.OnSubmit = ApplyChapterQuery;
        VerseQuick.OnChange = VerseQuick.OnSubmit = ApplyVerseQuery;
        KeyHandling.FocusQuick = kind =>
        {
            if (_state.Mode != WorkMode.Bible) return false;
            (kind switch { KeyHandling.QuickFieldKind.Book => BookQuick, KeyHandling.QuickFieldKind.Chapter => ChapterQuick, _ => VerseQuick }).FocusField();
            return true;
        };
        KeyHandling.FocusedQuick = () => BookQuick.IsFocusedField ? KeyHandling.QuickFieldKind.Book
            : ChapterQuick.IsFocusedField ? KeyHandling.QuickFieldKind.Chapter
            : VerseQuick.IsFocusedField ? KeyHandling.QuickFieldKind.Verse : null;
        _state.ScrollToCurrentVerseRequested += () => { _scrolledVerse = null; ApplyVerseSelection(true); };
        // F6 — фокус на вірші: список стає до вибраного й бере клавіатуру.
        KeyHandling.FocusVerses = () =>
        {
            if (_state.Mode != WorkMode.Bible) return;
            _scrolledVerse = null;
            ApplyVerseSelection(true);
            VerseList.Focus();
        };
        BookQuick.Placeholder = Captions.T("Название книги…");
        ChapterQuick.Placeholder = Captions.T("№ главы");
        VerseQuick.Placeholder = Captions.T("№ стиха или слова из текста");
        ApplyCaptions();

        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        Signals.Shared.Subscribe(new[] { Signals.Kind.Books, Signals.Kind.BookClass, Signals.Kind.Translations }, _ =>
        {
            _bookRows.Reload(); BookList.Reload(); ApplyBookSelection(); ClassList.SetSelection(new[] { (int)_state.BookClass }, (int)_state.BookClass);
        });
        Signals.Shared.Subscribe(Signals.Kind.BookSelection, ApplyBookSelection);
        Signals.Shared.Subscribe(Signals.Kind.Chapters, () => { ChapterList.Reload(); ApplyChapterSelection(); });
        Signals.Shared.Subscribe(Signals.Kind.ChapterSelection, ApplyChapterSelection);
        Signals.Shared.Subscribe(Signals.Kind.Verses, () =>
        {
            VerseList.Reload();
            // Зміна розділу при тому самому номері вірша вибору не міняє, а список
            // лишається там, куди його відвели колесом, — прокручуємо примусово.
            _scrolledVerse = null;
            ApplyVerseSelection(true);
        });
        Signals.Shared.Subscribe(Signals.Kind.VerseSelection, () => ApplyVerseSelection(!_pickedHere));
        Signals.Shared.Subscribe(Signals.Kind.ListKind, () =>
        {
            ApplyBookMode();
            ApplyVerseKind(false);
            ApplyButtons();
        });
        Signals.Shared.Subscribe(Signals.Kind.ListFontSize, () =>
        {
            var size = _state.ListFontSize;
            BookList.FontSize = ChapterList.FontSize = VerseList.FontSize = size;
            ChapterList.SetUniformHeight(Math.Ceiling(UiFont.LineHeight(size)) + 6);
            ApplyBookMode(true);
            ApplyVerseKind(true);
        });
        ClassList.SetSelection(new[] { 0 }, 0);
    }

    static Control Column(RowList list, QuickField quick, IconButtonRow? icons)
    {
        var panel = new LayoutPanel();
        var hair = new Border { Background = Palette.Brush(Palette.Separator) };
        Palette.Changed += () => hair.Background = Palette.Brush(Palette.Separator);
        if (icons != null) { panel.Children.Add(icons); panel.Children.Add(hair); }
        panel.Children.Add(list);
        panel.Children.Add(quick);
        panel.Layout = size =>
        {
            var top = icons != null ? IconButtonRow.RowHeight + 1 : 0;
            if (icons != null)
            {
                panel.Place(icons, new Rect(0, 0, size.Width, IconButtonRow.RowHeight));
                panel.Place(hair, new Rect(0, IconButtonRow.RowHeight, size.Width, 1));
            }
            var quickHeight = QuickField.FieldHeight;
            var listHeight = Math.Max(0, size.Height - top - quickHeight - 2);
            panel.Place(list, new Rect(0, top, size.Width, listHeight));
            panel.Place(quick, new Rect(0, top + listHeight + 2, size.Width, quickHeight));
        };
        return panel;
    }

    static IconButtonRow IconRow(params (string Symbol, Action Action)[] buttons)
    {
        var row = new IconButtonRow();
        row.Install(buttons.Select(b => new IconButton(b.Symbol) { Pressed = b.Action }));
        return row;
    }

    IconButtonRow? _bookButtons, _verseButtons;
    InterfaceSettings.BookViewMode? _appliedBookMode;
    bool? _appliedSingleLine;
    bool _pickedHere;
    int? _scrolledVerse;

    /// Вигляд вікна вибору Книги — чотири види меню «Інтерфейс» (N8–N11).
    void ApplyBookMode(bool force = false)
    {
        var mode = InterfaceSettings.Shared.BookView(_state.ListScope);
        if (!force && mode == _appliedBookMode) return;
        _appliedBookMode = mode;
        _bookRows.Mode = mode;
        var font = _state.ListFontSize;
        var title = Math.Ceiling(Math.Max(7, font - 1)) + 4;
        var caption = Math.Ceiling(Math.Max(8, font - 4)) + 4;
        var rowHeight = Math.Ceiling(UiFont.LineHeight(font)) + 6;
        switch (mode)
        {
            case InterfaceSettings.BookViewMode.Icons:
                BookList.Metrics = new ListMetrics { LeadFontDelta = -1, DetailFontDelta = Math.Max(8 - font, -4) };
                BookList.SetTiles(74, title + caption + 1 + 14, 3);
                BookList.SetUniformHeight(title + caption + 1 + 14);
                BookList.HeaderTitles = null;
                break;
            case InterfaceSettings.BookViewMode.SmallIcons:
                BookList.Metrics = new ListMetrics { LeadFontDelta = -1 };
                BookList.SetTiles(52, title + 12, 3);
                BookList.SetUniformHeight(title + 12);
                BookList.HeaderTitles = null;
                break;
            case InterfaceSettings.BookViewMode.List:
            {
                var m = ListMetrics.Books(); m.LeadFontDelta = -1;
                BookList.Metrics = m;
                BookList.SetList();
                BookList.SetUniformHeight(rowHeight);
                BookList.HeaderTitles = null;
                break;
            }
            default:
            {
                var m = ListMetrics.Books(); m.LeadWidth = 58; m.LeadFontDelta = -1; m.DetailWidth = 44;
                BookList.Metrics = m;
                BookList.SetList();
                BookList.SetUniformHeight(rowHeight);
                // Заголовки колонок — з файла перекладу автора, ті самі слова, що й у таблиці модулів.
                BookList.HeaderTitles = new[]
                {
                    Captions.FormCaption("LVBiblesPath->Column1", "SettingsForm", "Сокращ."),
                    Captions.FormCaption("LVBiblesPath->Column0", "SettingsForm", "Название"),
                    Captions.T("Глав"),
                };
                break;
            }
        }
        BookList.Reload();
        ApplyBookSelection();
    }

    /// Вигляд списку віршів (21): в одну лінію — усі рядки однієї висоти (найшвидше);
    /// багаторядковий — висота за текстом.
    void ApplyVerseKind(bool force)
    {
        var single = InterfaceSettings.Shared.VerseView(_state.ListScope) == InterfaceSettings.VerseViewMode.SingleLine;
        if (!force && single == _appliedSingleLine) return;
        _appliedSingleLine = single;
        _verseRows.SingleLine = single;
        var line = Math.Ceiling(UiFont.LineHeight(Math.Max(7, _state.ListFontSize + 1)));
        if (single) VerseList.SetUniformHeight(line + 10); else VerseList.SetMeasuredHeights(line + 10);
        VerseList.Reload();
        ApplyVerseSelection(false);
    }

    /// Кнопка поточного вигляду — підсвічена.
    void ApplyButtons(bool verses = true)
    {
        var flowing = InterfaceSettings.Shared.BooksAreFlowing(_state.ListScope);
        if (_bookButtons is { } books && books.Buttons.Count == 2)
        {
            books.Buttons[0].IsOn = flowing;
            books.Buttons[1].IsOn = !flowing;
            ToolTip.SetTip(books.Buttons[0], Captions.MainHint("PngSBBookFlow", "Книги плиткой"));
            ToolTip.SetTip(books.Buttons[1], Captions.MainHint("PngSBBookOneLine", "Книги списком"));
            foreach (var b in books.Buttons) b.InvalidateVisual();
        }
        var view = InterfaceSettings.Shared.VerseView(_state.ListScope);
        if (_verseButtons is { } row && row.Buttons.Count == 2)
        {
            var prefix = InterfaceSettings.HintPrefix(_state.ListScope);
            var modes = new[] { InterfaceSettings.VerseViewMode.Multiline, InterfaceSettings.VerseViewMode.SingleLine };
            for (var i = 0; i < 2; i++)
            {
                if (verses) row.Buttons[i].IsOn = modes[i] == view;
                var (key, fallback, _) = InterfaceSettings.Caption(modes[i]);
                ToolTip.SetTip(row.Buttons[i], Captions.MainHint(prefix + key, fallback));
                row.Buttons[i].InvalidateVisual();
            }
        }
    }

    void ApplyCaptions()
    {
        _panes[0].Caption = Captions.Caption("Label9", "Класс:");
        _panes[1].Caption = Captions.Caption("Label8", "Книга:");
        _panes[2].Caption = Captions.Caption("Label1", "Глава:");
        _panes[3].Caption = Captions.Caption("Label3", "Стих:");
        ClassList.Reload();
    }

    int? _scrolledBook, _scrolledChapter;

    void ApplyBookSelection()
    {
        if (_bookRows.RowOf(_state.SelectedBookIndex) is not { } row) { BookList.SetSelection(Array.Empty<int>()); _scrolledBook = null; return; }
        BookList.SetSelection(new[] { row }, row);
        if (row == _scrolledBook) return;
        _scrolledBook = row;
        BookList.ScrollTo(row, ScrollPlace.Center);
    }

    void ApplyChapterSelection()
    {
        var index = _state.Chapters.FindIndex(c => c.Number == _state.SelectedChapterNumber);
        if (index < 0) { ChapterList.SetSelection(Array.Empty<int>()); _scrolledChapter = null; return; }
        ChapterList.SetSelection(new[] { index }, index);
        if (index == _scrolledChapter) return;
        _scrolledChapter = index;
        ChapterList.ScrollTo(index, ScrollPlace.Center);
    }

    /// «Швидкий вибір Книги вводом її назви (можна скорочувати)» — з книг класу (1).
    void ApplyBookQuery(string text)
    {
        var visible = _state.VisibleBooks;
        if (ShortBookNames.Book(text, visible.Select(b => b.Book).ToList()) is not { } found) return;
        var position = visible.FirstOrDefault(b => b.Book.Index == found.Index).Position;
        if (visible.All(b => b.Book.Index != found.Index) || position == _state.SelectedBookIndex) return;
        _state.SelectedBookIndex = position;
    }

    /// «Швидкий вибір Розділу вводом його номера».
    void ApplyChapterQuery(string text)
    {
        if (!int.TryParse(new string(text.Where(char.IsDigit).ToArray()), out var number)) return;
        if (!_state.Chapters.Any(c => c.Number == number)) return;
        _state.SelectedChapterNumber = number;
    }

    /// «Швидкий вибір Вірша вводом його номера або частини тексту» — у межах розділу.
    void ApplyVerseQuery(string text)
    {
        var trimmed = text.Trim();
        if (trimmed.Length == 0 || _state.CurrentChapter is not { } chapter) return;
        if (int.TryParse(trimmed, out var number) && chapter.VerseNumbered(number) != null)
        {
            _state.SelectVerse(number, false);
            _scrolledVerse = null;
            ApplyVerseSelection(true);
            return;
        }
        var found = chapter.Verses.FirstOrDefault(v => TextSearch.FirstMatch(trimmed, v.Text, false) != null);
        if (found.Text == null) return;
        _state.SelectVerse(found.Number, false);
        _scrolledVerse = null;
        ApplyVerseSelection(true);
    }

    /// Shift — відрізок підряд, Ctrl — окремий вірш; протяжка мишею — відрізок від
    /// рядка натискання; рішення приймає стан (як chose у NativeVerseColumn).
    void Chose(int index, IReadOnlyCollection<int> selection, SelectCause cause, bool live)
    {
        if (_state.CurrentChapter is not { } chapter || index < 0 || index >= chapter.Verses.Count) return;
        var numbers = chapter.Verses.Select(v => v.Number).ToList();
        _pickedHere = true;
        try
        {
            if (cause == SelectCause.Keyboard && selection.Count == numbers.Count && numbers.Count > 1)
            {
                _state.SelectAllVerses();
            }
            else if (cause == SelectCause.Drag && selection.Count > 0)
            {
                var first = selection.Min(); var last = selection.Max();
                var origin = index == last ? first : last;
                _state.SelectVerse(numbers[origin], AppState.VerseSelection.Replace);
                if (origin != index) _state.SelectVerse(numbers[index], AppState.VerseSelection.Extend);
            }
            else
            {
                var flags = VerseList.LastModifiers;
                var mode = flags.HasFlag(KeyModifiers.Shift) ? AppState.VerseSelection.Extend
                    : flags.HasFlag(KeyModifiers.Control) || flags.HasFlag(KeyModifiers.Meta) ? AppState.VerseSelection.Toggle
                    : AppState.VerseSelection.Replace;
                _state.ChooseVerse(numbers[index], mode, live);
            }
        }
        finally { _pickedHere = false; }
        // Стан — єдина правда про виділення: те, що список устиг нарахувати сам, перекривається.
        ApplyVerseSelection(false);
    }

    void ApplyVerseSelection(bool scroll)
    {
        if (_state.CurrentChapter is not { } chapter) { VerseList.SetSelection(Array.Empty<int>()); return; }
        var rows = _state.SelectedVerseNumbers.Select(n => chapter.Verses.ToList().FindIndex(v => v.Number == n)).Where(i => i >= 0).OrderBy(i => i).ToList();
        int? first = rows.Count > 0 ? rows[0] : null;
        VerseList.SetSelection(rows, first);
        if (!scroll || first is not { } target || target == _scrolledVerse) return;
        _scrolledVerse = target;
        VerseList.ScrollTo(target, ScrollPlace.Center);
    }

    // --- Джерела рядків ------------------------------------------------------------

    sealed class ClassRows : IRowSource
    {
        public int RowCount => 4;
        public Row RowAt(int index) => new(Captions.Caption(((BookClass)index).CaptionKey(), ((BookClass)index).Title())) { SingleLine = true };
    }

    sealed class BookRows : IRowSource
    {
        readonly AppState _state;
        List<(BookInfo Book, int Position)> _books = new();
        public InterfaceSettings.BookViewMode Mode = InterfaceSettings.BookViewMode.Icons;
        public BookRows(AppState state) { _state = state; Reload(); }
        public void Reload() => _books = _state.VisibleBooks;
        public int RowCount => _books.Count;
        public int? Position(int row) => row >= 0 && row < _books.Count ? _books[row].Position : null;
        public int? RowOf(int position) { var i = _books.FindIndex(b => b.Position == position); return i < 0 ? null : i; }
        public Row RowAt(int index)
        {
            var book = _books[index].Book;
            var color = BookPalette.ColorOf(book);
            return Mode switch
            {
                InterfaceSettings.BookViewMode.Icons => new Row(book.FullName, book.ButtonTitle) { TextColor = color, Tooltip = book.FullName },
                InterfaceSettings.BookViewMode.SmallIcons => new Row("", book.ButtonTitle) { TextColor = color, LeadColor = color, Tooltip = book.FullName },
                InterfaceSettings.BookViewMode.List => new Row(book.FullName, book.ButtonTitle) { LeadColor = color, TextColor = color, SingleLine = true, Tooltip = book.FullName },
                _ => new Row(book.FullName, book.ButtonTitle, (_state.PrimaryModule?.Chapters(book).Count ?? 0).ToString())
                     { LeadColor = color, TextColor = color, SingleLine = true, Tooltip = book.FullName },
            };
        }
    }

    sealed class ChapterRows : IRowSource
    {
        readonly AppState _state;
        public ChapterRows(AppState state) { _state = state; }
        public int RowCount => _state.Chapters.Count;
        public Row RowAt(int index) => new(_state.Chapters[index].Number.ToString()) { SingleLine = true };
    }

    sealed class VerseRows : IRowSource
    {
        readonly AppState _state;
        public VerseRows(AppState state) { _state = state; }
        /// «Текст в одну лінію» (кнопки (21)).
        public bool SingleLine;
        public int RowCount => _state.CurrentChapter?.Verses.Count ?? 0;
        public Row RowAt(int index)
        {
            var verse = _state.CurrentChapter!.Verses[index];
            // Червона риска під кожним десятим віршем (налаштування «Розділ. лінією по 10 віршів»).
            var rule = SettingsStore.Shared.Settings.Options.SeparatorTenVerses && verse.Number % 10 == 0
                ? Color.FromRgb(0xE8, 0x9A, 0x9A) : (Color?)null;
            return new Row(verse.Text, verse.Number.ToString()) { Rule = rule, SingleLine = SingleLine };
        }

        /// Меню правої кнопки списку віршів (5.1.4): «Додати в План», риска,
        /// «Скопіювати у вкладку «Текст»», «Скопіювати в буфер обміну».
        public ContextMenu? MenuAt(int index)
        {
            if (_state.CurrentChapter is not { } chapter || index < 0 || index >= chapter.Verses.Count) return null;
            var number = chapter.Verses[index].Number;
            string Caption(string key, string fallback) => Captions.Caption(key, fallback).Replace("&", "");
            return MenuStrip.Build(new[]
            {
                new MenuEntry(Caption("MIAddToPlan", "Добавить в План"), () => Perform(number, () => _state.AddCurrentToPlan())),
                new MenuEntry(Caption("MICopyToText", "Скопировать во вкладку «Текст»"), () => Perform(number, () =>
                {
                    TextModuleModel.Shared.Receive(_state.Slide.Reference, _state.Slide.MainText);
                    _state.Mode = WorkMode.Text;
                    Signals.Shared.Send(Signals.Kind.Mode);
                }), StartsGroup: true),
                new MenuEntry(Caption("MICopyToClipboard", "Скопировать в буфер обмена (Ctrl + C)"), () => Perform(number, () =>
                {
                    if (MainWindow.Shared?.Clipboard is { } board) _ = board.SetTextAsync(_state.Slide.MainText);
                })),
            });
        }

        /// Права кнопка по невиділеному вірші працює з ним, а не з колишнім виділенням;
        /// уже виділений уривок не звужуємо — інакше в план пішов би не той.
        void Perform(int verse, Action action)
        {
            if (!_state.SelectedVerseNumbers.Contains(verse)) _state.SelectVerse(verse, extending: false);
            action();
        }
    }
}
