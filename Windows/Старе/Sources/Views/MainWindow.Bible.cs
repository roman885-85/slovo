// =============================================================================
//  MainWindow.Bible.cs — робоча область «Біблія»
// =============================================================================
//  Смуга перекладів (7) — вкладки увімкнених перекладів; клацання вибирає
//  основний, правою кнопкою — другий переклад на той самий слайд. Під нею
//  швидкий вибір (9: «Ів 3:16») і пошук за словами (8) з вікном результатів
//  (5). Ліворуч — клас і книги (1, 2), посередині — розділи (3), праворуч —
//  вірші (4): клацання — у передпоказ, подвійне чи Enter — у зал, Ctrl —
//  кілька віршів на один слайд.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace Slovo.Views;

public sealed partial class MainWindow
{
    readonly StackPanel _translations = new() { Orientation = Orientation.Horizontal, Spacing = 4 };
    readonly TextBox _quickBox = new() { Width = 180 };
    readonly TextBox _searchBox = new() { Width = 220 };
    readonly ComboBox _bookClass = new() { Width = 150 };
    readonly ListBox _booksList = new();
    readonly WrapPanel _chaptersPanel = new() { Orientation = Orientation.Horizontal };
    readonly ListBox _versesList = new() { SelectionMode = SelectionMode.Multiple };
    readonly ListBox _searchList = new();
    readonly TextBlock _searchNote = new() { Foreground = Ui.Muted, FontSize = 12 };
    readonly Border _searchPane = new() { IsVisible = false };
    readonly TextBlock _chapterTitle = new() { FontWeight = FontWeight.SemiBold };
    bool _fillingBible;
    List<(int Position, Book Book)> _visibleBooks = new();

    Control BuildBible()
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("230,4,*,4,2*"), RowDefinitions = new RowDefinitions("Auto,*") };

        // Смуга перекладів + швидкий вибір + пошук.
        var strip = new DockPanel { Margin = new Thickness(0, 2, 0, 6) };
        var tools = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, HorizontalAlignment = HorizontalAlignment.Right };
        _quickBox.Watermark = Lang.T("Швидкий вибір: Ів 3:16", "Quick input: Jn 3:16");
        ToolTip.SetTip(_quickBox, Lang.T("Адреса: книга, розділ, вірші («Ів 3:16-18», «Быт 1»); лише цифри — вірш у відкритому розділі. Enter — у передпоказ, Ctrl+Enter — у зал.",
                                        "Address: book, chapter, verses (“Jn 3:16-18”, “Gen 1”); digits only — a verse in the open chapter. Enter — preview, Ctrl+Enter — hall."));
        _quickBox.KeyDown += (_, e) =>
        {
            if (e.Key != Avalonia.Input.Key.Enter) return;
            var live = e.KeyModifiers.HasFlag(KeyModifiers.Control);
            if (_state.ApplyQuickInput(_quickBox.Text ?? "", live)) { _quickBox.Text = ""; _versesList.Focus(); }
            else _quickBox.Background = Brushes.MistyRose;
            e.Handled = true;
        };
        _quickBox.TextChanged += (_, _) => _quickBox.Background = Brushes.White;
        _searchBox.Watermark = Lang.T("Пошук за словами (F3)", "Word search (F3)");
        ToolTip.SetTip(_searchBox, Lang.T("Усі слова запиту в будь-якому порядку, за початком слова: «имеет жизнь». Enter — шукати.", "All words of the query in any order, by word beginning. Enter — search."));
        _searchBox.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { _state.RunSearch(_searchBox.Text ?? ""); e.Handled = true; } };
        var searchButton = Ui.Button(Lang.T("Шукати", "Search"), () => _state.RunSearch(_searchBox.Text ?? ""), Lang.T("Шукати за словами в основному перекладі", "Search by words in the main translation"));
        var toggleResults = Ui.Button("≡", () => { _state.IsSearchShown = !_state.IsSearchShown; RefreshSearch(); }, Lang.T("Показати / сховати результати пошуку (Ctrl+F3)", "Show / hide search results (Ctrl+F3)"));
        tools.Children.Add(_quickBox);
        tools.Children.Add(_searchBox);
        tools.Children.Add(searchButton);
        tools.Children.Add(toggleResults);
        DockPanel.SetDock(tools, Dock.Right);
        strip.Children.Add(tools);
        var translationsScroll = new ScrollViewer { Content = _translations, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };
        strip.Children.Add(translationsScroll);
        Grid.SetColumnSpan(strip, 5);
        grid.Children.Add(strip);

        // Книги.
        var left = new DockPanel();
        foreach (var (key, title) in new[] { ("all", Lang.T("Усі книги", "All books")), ("old", Lang.T("Старий Заповіт", "Old Testament")), ("new", Lang.T("Новий Заповіт", "New Testament")), ("other", Lang.T("Інші книги", "Other books")) })
            _bookClass.Items.Add(new ComboBoxItem { Content = title, Tag = key });
        _bookClass.SelectedIndex = 0;
        _bookClass.SelectionChanged += (_, _) =>
        {
            if (_fillingBible) return;
            _state.BookClass = (_bookClass.SelectedItem as ComboBoxItem)?.Tag as string ?? "all";
            RefreshBooks();
        };
        DockPanel.SetDock(_bookClass, Dock.Top);
        _bookClass.Margin = new Thickness(0, 0, 0, 4);
        _bookClass.HorizontalAlignment = HorizontalAlignment.Stretch;
        left.Children.Add(_bookClass);
        _booksList.ItemTemplate = new FuncDataTemplate<(int Position, Book Book)>((item, _) => new TextBlock
        {
            Text = item.Book?.Name ?? "", Margin = new Thickness(4, 1),
        });
        _booksList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _booksList.SelectedIndex < 0 || _booksList.SelectedIndex >= _visibleBooks.Count) return;
            _state.SelectBook(_visibleBooks[_booksList.SelectedIndex].Position);
        };
        _fontLists.Add(_booksList);
        left.Children.Add(_booksList);
        Grid.SetRow(left, 1);
        grid.Children.Add(left);

        grid.Children.Add(Splitter(1));

        // Розділи.
        var middle = new DockPanel();
        _chapterTitle.Margin = new Thickness(4, 4);
        DockPanel.SetDock(_chapterTitle, Dock.Top);
        middle.Children.Add(_chapterTitle);
        middle.Children.Add(new ScrollViewer { Content = _chaptersPanel });
        Grid.SetRow(middle, 1); Grid.SetColumn(middle, 2);
        grid.Children.Add(middle);

        grid.Children.Add(Splitter(3));

        // Вірші + результати пошуку.
        var right = new DockPanel();
        _versesList.ItemTemplate = new FuncDataTemplate<Verse>((verse, _) =>
        {
            if (verse == null) return new TextBlock();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Margin = new Thickness(2, 1) };
            row.Children.Add(new TextBlock { Text = verse.Number.ToString(), FontWeight = FontWeight.Bold, MinWidth = 26, Foreground = Ui.Accent });
            row.Children.Add(new TextBlock { Text = verse.Text, TextWrapping = TextWrapping.Wrap, MaxWidth = 640 });
            return row;
        });
        _versesList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible) return;
            var numbers = _versesList.SelectedItems?.OfType<Verse>().Select(v => v.Number).ToList() ?? new List<int>();
            if (numbers.Count > 0) _state.SelectVerses(numbers, false);
        };
        _versesList.DoubleTapped += (_, _) => { if (!_fillingBible) _state.ShowCurrent(); };
        _versesList.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { _state.ShowCurrent(); e.Handled = true; } };
        _fontLists.Add(_versesList);

        _searchList.ItemTemplate = new FuncDataTemplate<AppState.SearchHit>((hit, _) =>
        {
            if (hit == null) return new TextBlock();
            var row = new StackPanel { Margin = new Thickness(2, 1) };
            row.Children.Add(new TextBlock { Text = hit.Reference, FontWeight = FontWeight.SemiBold, Foreground = Ui.Accent, FontSize = 12 });
            row.Children.Add(new TextBlock { Text = hit.Text, TextWrapping = TextWrapping.Wrap, MaxWidth = 640 });
            return row;
        });
        _searchList.SelectionChanged += (_, _) => { if (!_fillingBible && _searchList.SelectedIndex >= 0) _state.ShowHit(_searchList.SelectedIndex, false); };
        _searchList.DoubleTapped += (_, _) => { if (_searchList.SelectedIndex >= 0) _state.ShowHit(_searchList.SelectedIndex, true); };
        _fontLists.Add(_searchList);
        var searchHead = new DockPanel();
        var closeSearch = Ui.Button("×", () => { _state.IsSearchShown = false; RefreshSearch(); }, Lang.T("Сховати результати пошуку", "Hide search results"));
        DockPanel.SetDock(closeSearch, Dock.Right);
        searchHead.Children.Add(closeSearch);
        _searchNote.VerticalAlignment = VerticalAlignment.Center;
        searchHead.Children.Add(_searchNote);
        var searchBody = new DockPanel();
        DockPanel.SetDock(searchHead, Dock.Top);
        searchBody.Children.Add(searchHead);
        searchBody.Children.Add(_searchList);
        _searchPane.Child = searchBody;
        _searchPane.Height = 200;
        _searchPane.BorderBrush = Ui.Line;
        _searchPane.BorderThickness = new Thickness(0, 1, 0, 0);
        _searchPane.Padding = new Thickness(0, 4, 0, 0);
        DockPanel.SetDock(_searchPane, Dock.Bottom);
        right.Children.Add(_searchPane);
        right.Children.Add(_versesList);
        Grid.SetRow(right, 1); Grid.SetColumn(right, 4);
        grid.Children.Add(right);
        return grid;
    }

    static GridSplitter Splitter(int column)
    {
        var splitter = new GridSplitter { Background = Brushes.Transparent, Width = 4 };
        Grid.SetColumn(splitter, column);
        Grid.SetRow(splitter, 1);
        return splitter;
    }

    void RefreshTranslations()
    {
        _translations.Children.Clear();
        foreach (var module in _state.Modules)
        {
            var isPrimary = module.Id == _state.PrimaryModuleId;
            var isSecondary = _state.SecondaryModuleIds.Contains(module.Id);
            var button = new Button
            {
                Content = _state.Settings.TabNamesLong ? module.Name : (module.ShortName.Length > 0 ? module.ShortName : module.Name),
                Padding = new Thickness(10, 4),
                Background = isPrimary ? Ui.Accent : isSecondary ? Ui.Good : Ui.AccentSoft,
                Foreground = isPrimary || isSecondary ? Brushes.White : Brushes.Black,
                FontWeight = isPrimary ? FontWeight.SemiBold : FontWeight.Normal,
            };
            ToolTip.SetTip(button, module.Name + "\n" + Lang.T("Клацання — основний переклад; права кнопка — другий переклад на той самий слайд", "Click — main translation; right button — second translation on the same slide"));
            var id = module.Id;
            button.Click += (_, _) => _state.SelectPrimary(id);
            button.AddHandler(PointerPressedEvent, (_, e) =>
            {
                if (e.GetCurrentPoint(button).Properties.IsRightButtonPressed) { _state.ToggleSecondary(id); e.Handled = true; }
            }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
            _translations.Children.Add(button);
        }
        if (_state.Modules.Count == 0)
            _translations.Children.Add(Ui.Hint(Lang.T("Перекладів ще немає — меню «Файл» → «Переклади, пісенники, фони, шаблони…»", "No translations yet — File → Translations, songbooks, backgrounds, templates…")));
    }

    void RefreshBooks()
    {
        _fillingBible = true;
        try
        {
            _visibleBooks = _state.VisibleBooks();
            _booksList.ItemsSource = _visibleBooks.ToList();
            var at = _visibleBooks.FindIndex(p => p.Position == _state.SelectedBookIndex);
            _booksList.SelectedIndex = at;
            if (at >= 0) _booksList.ScrollIntoView(at);
        }
        finally { _fillingBible = false; }
        RefreshChapters();
        RefreshVerses();
    }

    void RefreshChapters()
    {
        _chaptersPanel.Children.Clear();
        var book = _state.CurrentBook;
        _chapterTitle.Text = book == null ? "" : book.Name + " · " + Lang.T("розділ", "chapter") + " " + _state.SelectedChapter;
        foreach (var chapter in _state.Chapters)
        {
            var number = chapter;
            var current = chapter == _state.SelectedChapter;
            var button = new Button
            {
                Content = number.ToString(), Width = 42, Height = 32, Margin = new Thickness(2),
                HorizontalContentAlignment = HorizontalAlignment.Center,
                Background = current ? Ui.Accent : Ui.Paper, Foreground = current ? Brushes.White : Brushes.Black,
                FontWeight = current ? FontWeight.Bold : FontWeight.Normal,
            };
            button.Click += (_, _) => _state.SelectChapter(number);
            _chaptersPanel.Children.Add(button);
        }
    }

    void RefreshVerses()
    {
        _fillingBible = true;
        try
        {
            _versesList.ItemsSource = _state.Verses.ToList();
            RefreshVerseSelection();
        }
        finally { _fillingBible = false; }
    }

    void RefreshVerseSelection()
    {
        var was = _fillingBible;
        _fillingBible = true;
        try
        {
            var items = _versesList.ItemsSource as List<Verse> ?? new List<Verse>();
            var selected = items.Where(v => _state.SelectedVerses.Contains(v.Number)).ToList();
            _versesList.SelectedItems?.Clear();
            foreach (var verse in selected) _versesList.SelectedItems?.Add(verse);
            if (selected.Count > 0) _versesList.ScrollIntoView(selected[0]);
        }
        finally { _fillingBible = was; }
    }

    void RefreshSearch()
    {
        _searchPane.IsVisible = _state.IsSearchShown && (_state.Hits.Count > 0 || _state.IsSearching || _state.SearchedQuery.Length > 0);
        _fillingBible = true;
        try
        {
            _searchList.ItemsSource = _state.Hits.ToList();
            _searchNote.Text = _state.IsSearching ? Lang.T("Шукаю…", "Searching…")
                : _state.SearchedQuery.Length == 0 ? ""
                : Lang.F("«{0}»: знайдено {1}{2}. Клацання — у передпоказ, подвійне — у зал.", "“{0}”: found {1}{2}. Click — preview, double-click — hall.", _state.SearchedQuery, _state.Hits.Count, _state.IsTruncated ? "+" : "");
        }
        finally { _fillingBible = false; }
    }
}
