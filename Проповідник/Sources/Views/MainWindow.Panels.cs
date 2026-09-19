// =============================================================================
//  MainWindow.Panels.cs — вміст вкладок робочого місця
// =============================================================================
//  Біблія, Пісні, Презентація, Медіа, Зображення, Екран, Текст — те саме, що
//  на планшеті, тими самими шляхами пульта «Слова».
// =============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text.Json.Nodes;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed partial class MainWindow
{
    // MARK: Біблія

    ComboBox _bibleTranslations = null!;
    ListBox _bibleBooks = null!, _bibleChapters = null!, _bibleVerses = null!;
    TextBox _bibleSearch = null!;
    ListBox _bibleHits = null!;
    Control _bibleChooser = null!;
    List<JsonObject> _books = new();
    int _bibleBook = -1, _bibleChapter = -1;
    bool _fillingBible;

    Control BiblePanel()
    {
        _bibleTranslations = new ComboBox { MinWidth = 180, MaxWidth = 260, PlaceholderText = Lang.T("Переклад", "Translation") };
        _bibleTranslations.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _bibleTranslations.SelectedItem is not Choice choice) return;
            Send("bible-translation", choice.Id, byText: true);
            _ = LoadBooks();
        };
        _bibleBooks = new ListBox { ItemTemplate = Text<JsonObject>(b => (string?)b["name"] ?? "") };
        _bibleBooks.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _bibleBooks.SelectedIndex < 0) return;
            _bibleBook = (int?)_books[_bibleBooks.SelectedIndex]["position"] ?? 0;
            FillChapters();
            _ = LoadChapter(_bibleBook, 1);
        };
        _bibleChapters = new ListBox
        {
            ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel()),
            ItemTemplate = Text<int>(n => n.ToString()),
        };
        _bibleChapters.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _bibleChapters.SelectedItem is not int chapter) return;
            _ = LoadChapter(_bibleBook, chapter);
        };
        _bibleVerses = new ListBox { SelectionMode = SelectionMode.Multiple | SelectionMode.Toggle };
        _bibleVerses.ItemTemplate = new FuncDataTemplate<VerseRow>((v, _) => new TextBlock
        {
            Inlines = v == null ? null : new Avalonia.Controls.Documents.InlineCollection
            {
                new Avalonia.Controls.Documents.Run(v.Number + "  ") { Foreground = Ui.Accent, FontWeight = FontWeight.SemiBold },
                new Avalonia.Controls.Documents.Run(v.Text),
            },
            TextWrapping = TextWrapping.Wrap,
        });
        ScrollViewer.SetHorizontalScrollBarVisibility(_bibleVerses, ScrollBarVisibility.Disabled);
        _bibleVerses.DoubleTapped += (_, _) => SelectVerses(live: true);

        _bibleSearch = new TextBox { Watermark = Lang.T("Пошук за словами", "Search by words"), MinWidth = 150 };
        _bibleSearch.KeyDown += (_, e) =>
        {
            if (e.Key != Avalonia.Input.Key.Enter) return;
            var query = (_bibleSearch.Text ?? "").Trim();
            if (query.Length == 0) return;
            Send("bible-search", query, byText: true);
            _ = PollSearch(query);
        };
        _bibleHits = new ListBox { ItemTemplate = new FuncDataTemplate<HitRow>((hit, _) =>
        {
            var panel = new StackPanel { Spacing = 1, Margin = new Thickness(2, 3) };
            panel.Children.Add(new TextBlock { Text = hit?.Reference ?? "", FontWeight = FontWeight.SemiBold });
            panel.Children.Add(new TextBlock { Text = hit?.Text ?? "", TextWrapping = TextWrapping.Wrap, MaxLines = 2, Foreground = Ui.Muted, FontSize = 12 });
            return panel;
        }) };
        ScrollViewer.SetHorizontalScrollBarVisibility(_bibleHits, ScrollBarVisibility.Disabled);
        _bibleHits.SelectionChanged += (_, _) =>
        {
            if (_bibleHits.SelectedIndex < 0) return;
            Send("search-hit", new JsonObject { ["index"] = _bibleHits.SelectedIndex, ["live"] = false });
        };
        _bibleHits.DoubleTapped += (_, _) =>
        {
            if (_bibleHits.SelectedIndex < 0) return;
            Send("search-hit", new JsonObject { ["index"] = _bibleHits.SelectedIndex, ["live"] = true });
        };

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("170,6,120,6,*") };
        Put(grid, _bibleBooks, 0, Lang.T("Книга", "Book"));
        Put(grid, _bibleChapters, 2, Lang.T("Розділ", "Chapter"));
        Put(grid, _bibleVerses, 4, Lang.T("Вірші — клацніть потрібні, подвійне клацання — у зал", "Verses — click the ones you need, double click sends to the hall"));
        _bibleChooser = grid;

        var add = Ui.Button(Lang.T("У передпоказ", "To the preview"), () => SelectVerses(live: false));
        var show = Ui.Button(Lang.T("Показати в залі", "Show in the hall"), () => SelectVerses(live: true), accent: true);
        var toPlan = Ui.Button("＋ " + Lang.T("У План", "To the Plan"), () => { SelectVerses(live: false); Send("plan-add"); },
                               Lang.T("Спершу в передпоказ, потім у План", "First to the preview, then to the Plan"));
        var buttons = Ui.Row(toPlan, add, show);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 8, 0, 0);

        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Wrap(Ui.Label(Lang.T("Переклад:", "Translation:")), _bibleTranslations, _bibleSearch));
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(buttons);
        panel.Children.Add(_bibleChooser);
        _ = LoadBooks();
        return panel;
    }

    sealed record Choice(string Id, string Name)
    {
        public override string ToString() => Name;
    }
    sealed record VerseRow(int Number, string Text)
    {
        public override string ToString() => Number + ". " + Text;
    }
    sealed record HitRow(string Reference, string Text)
    {
        public override string ToString() => Reference + " — " + Text;
    }

    /// Ряд, що переноситься: у вузькій колонці підпис і поле стають одне під одним.
    static WrapPanel Wrap(params Control[] children)
    {
        var panel = new WrapPanel();
        foreach (var child in children)
        {
            child.Margin = new Thickness(0, 0, 6, 4);
            panel.Children.Add(child);
        }
        return panel;
    }

    static FuncDataTemplate<T> Text<T>(Func<T, string> line) =>
        new((item, _) => new TextBlock { Text = item == null ? "" : line(item), TextWrapping = TextWrapping.NoWrap });

    static void Put(Grid grid, Control control, int column, string caption)
    {
        var panel = new DockPanel();
        var label = Ui.Label(caption, 12, true);
        label.Margin = new Thickness(2, 0, 0, 4);
        DockPanel.SetDock(label, Dock.Top);
        panel.Children.Add(label);
        panel.Children.Add(new Border { Child = control, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        Grid.SetColumn(panel, column);
        grid.Children.Add(panel);
    }

    async Task LoadBooks()
    {
        if (!_online)
        {
            Paths.Say("Біблія: списки не читаю — зв'язку ще немає");
            return;
        }
        try
        {
            var answer = await _api.Get("/api/bible/books");
            _books = (answer["books"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            var translations = (answer["translations"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select(t => new Choice((string?)t["id"] ?? "", (string?)t["name"] ?? "")).ToList();
            var current = (string?)(answer["translation"] as JsonObject)?["id"] ?? "";
            var book = (int?)(answer["current"] as JsonObject)?["book"] ?? 0;
            var chapter = (int?)(answer["current"] as JsonObject)?["chapter"] ?? 1;
            Paths.Say($"Біблія: прийшло книг {_books.Count}, перекладів {translations.Count}");
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _fillingBible = true;
                _bibleTranslations.ItemsSource = translations;
                _bibleTranslations.SelectedItem = translations.FirstOrDefault(t => t.Id == current);
                _bibleBooks.ItemsSource = _books;
                _bibleBook = book;
                var position = _books.FindIndex(b => ((int?)b["position"] ?? -1) == book);
                _bibleBooks.SelectedIndex = position;
                FillChapters(chapter);
                _fillingBible = false;
            });
            await LoadChapter(book, chapter);
        }
        catch (Exception error)
        {
            Paths.Say("Біблія: " + error);
            Status(Api.Describe(error));
        }
    }

    void FillChapters(int select = 1)
    {
        var position = _bibleBooks.SelectedIndex;
        if (position < 0 || position >= _books.Count) return;
        var count = (int?)_books[position]["chapters"] ?? 0;
        var was = _fillingBible;
        _fillingBible = true;
        _bibleChapters.ItemsSource = Enumerable.Range(1, Math.Max(count, 1)).ToList();
        _bibleChapters.SelectedItem = select;
        _fillingBible = was;
    }

    async Task LoadChapter(int book, int chapter)
    {
        if (!_online || book < 0) return;
        try
        {
            var answer = await _api.Get($"/api/bible/chapter?book={book}&chapter={chapter}");
            var verses = (answer["verses"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select(v => new VerseRow((int?)v["number"] ?? 0, (string?)v["text"] ?? "")).ToList();
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _bibleChapter = (int?)answer["chapter"] ?? chapter;
                _fillingBible = true;
                _bibleChapters.SelectedItem = _bibleChapter;
                _bibleVerses.ItemsSource = verses;
                _fillingBible = false;
            });
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    void SelectVerses(bool live)
    {
        var numbers = _bibleVerses.SelectedItems?.OfType<VerseRow>().Select(v => v.Number).OrderBy(n => n).ToList() ?? new List<int>();
        if (numbers.Count == 0)
        {
            Status(Lang.T("Спершу клацніть вірші", "Click the verses first"));
            return;
        }
        _touched = DateTime.UtcNow;
        _ = Run(() => _api.BibleSelect(_bibleBook, _bibleChapter, numbers, live));
    }

    async Task PollSearch(string query)
    {
        for (var i = 0; i < 20; i++)
        {
            await Task.Delay(500);
            try
            {
                var answer = await _api.Get("/api/search");
                var hits = (answer["hits"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                    .Select(h => new HitRow((string?)h["reference"] ?? "", (string?)h["text"] ?? "")).ToList();
                await Dispatcher.UIThread.InvokeAsync(() =>
                {
                    _bibleHits.ItemsSource = hits;
                    ShowSearch(hits.Count > 0 || (bool?)answer["searching"] == true);
                    Status(hits.Count == 0 && (bool?)answer["searching"] != true
                        ? Lang.F("За словом «{0}» нічого не знайшлося", "Nothing found for “{0}”", query)
                        : Lang.F("Знайдено: {0}", "Found: {0}", hits.Count));
                });
                if ((bool?)answer["searching"] != true && hits.Count > 0) return;
            }
            catch (Exception error)
            {
                Status(Api.Describe(error));
                return;
            }
        }
    }

    /// Замість книг і розділів — знайдене; «До книг» вертає вибір.
    void ShowSearch(bool searching)
    {
        if (_panel.Content is not DockPanel panel) return;
        var back = Ui.Button(Lang.T("До книг і розділів", "Back to books and chapters"), () => ShowTab("bible"));
        var wrapper = new DockPanel();
        DockPanel.SetDock(back, Dock.Top);
        back.HorizontalAlignment = HorizontalAlignment.Left;
        back.Margin = new Thickness(0, 0, 0, 6);
        wrapper.Children.Add(back);
        wrapper.Children.Add(new Border { Child = _bibleHits, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        if (!searching) return;
        panel.Children.Remove(_bibleChooser);
        if (!panel.Children.Contains(wrapper)) panel.Children.Add(wrapper);
    }

    // MARK: Пісні

    ComboBox _songBooks = null!;
    TextBox _songFilterLive = null!;
    ListBox _songList = null!;
    StackPanel _songParts = null!;
    List<JsonObject> _songs = new();

    Control SongsPanel()
    {
        _songBooks = new ComboBox { MinWidth = 200, MaxWidth = 300, PlaceholderText = Lang.T("Пісенник", "Songbook") };
        _songBooks.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _songBooks.SelectedItem is not Choice choice) return;
            Send("songs-book", choice.Id, byText: true);
            _ = LoadSongs();
        };
        _songFilterLive = new TextBox { Watermark = Lang.T("Номер або назва", "Number or title"), MinWidth = 130 };
        _songFilterLive.TextChanged += (_, _) => FillSongs();
        _songList = new ListBox { ItemTemplate = Text<JsonObject>(s => $"{(int?)s["number"] ?? 0}. {(string?)s["title"] ?? ""}") };
        _songList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _songList.SelectedItem is not JsonObject song) return;
            _touched = DateTime.UtcNow;
            Send("song", (int?)song["index"] ?? 0);
        };
        _songParts = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        var parts = new ScrollViewer { Content = _songParts, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled };

        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Wrap(Ui.Label(Lang.T("Пісенник:", "Songbook:")), _songBooks, _songFilterLive));
        head.Children.Add(Ui.Hint(Lang.T("Клацніть пісню — вона в передпоказі; кнопки частин унизу виводять куплет у зал.",
                                         "Click a song — it goes to the preview; the part buttons below send a verse to the hall.")));
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(parts, Dock.Bottom);
        parts.Margin = new Thickness(0, 8, 0, 0);
        panel.Children.Add(head);
        panel.Children.Add(parts);
        panel.Children.Add(new Border { Child = _songList, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        _ = LoadSongs();
        return panel;
    }

    async Task LoadSongs()
    {
        if (!_online) return;
        try
        {
            var books = await _api.Get("/api/songs/books");
            var list = await _api.Get("/api/songs/list");
            var choices = (books["books"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select(b => new Choice((string?)b["id"] ?? "", (string?)b["title"] ?? "")).ToList();
            var current = (string?)books["current"] ?? "";
            _songs = (list["songs"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
            var selected = (int?)list["selected"] ?? -1;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _fillingBible = true;
                _songBooks.ItemsSource = choices;
                _songBooks.SelectedItem = choices.FirstOrDefault(c => c.Id == current);
                FillSongs(selected);
                _fillingBible = false;
            });
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    void FillSongs(int selected = -1)
    {
        var wanted = (_songFilterLive.Text ?? "").Trim().ToLowerInvariant();
        var shown = _songs.Where(s => wanted.Length == 0
                                      || ((string?)s["title"] ?? "").ToLowerInvariant().Contains(wanted)
                                      || ((int?)s["number"] ?? 0).ToString().StartsWith(wanted)).ToList();
        var was = _fillingBible;
        _fillingBible = true;
        _songList.ItemsSource = shown;
        if (selected >= 0)
        {
            var position = shown.FindIndex(s => ((int?)s["index"] ?? -1) == selected);
            if (position >= 0) _songList.SelectedIndex = position;
        }
        _fillingBible = was;
    }

    void FillSongParts()
    {
        if (_songParts == null || _tab != "songs") return;
        var song = _state["song"] as JsonObject;
        var parts = (song?["parts"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
        var current = (int?)song?["partIndex"] ?? -1;
        _songParts.Children.Clear();
        for (var i = 0; i < parts.Count; i++)
        {
            var index = i;
            var kind = (string?)parts[i]["title"] ?? (string?)parts[i]["kind"] ?? "";
            var button = Ui.Button(kind.Length == 0 ? (i + 1).ToString() : kind, () => Send("part", index), accent: i == current);
            _songParts.Children.Add(button);
        }
    }

    // MARK: Презентація і Зображення

    ListBox _pageList = null!;
    StackPanel _deckRow = null!;
    Image _pagePreview = null!;
    bool _pagesArePresentation;

    Control PagesPanel(bool presentation)
    {
        _pagesArePresentation = presentation;
        _deckRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
        _pageList = new ListBox { ItemTemplate = Text<PageRow>(p => p.Title) };
        _pageList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _pageList.SelectedItem is not PageRow page) return;
            _touched = DateTime.UtcNow;
            Send(presentation ? "page" : "picture", page.Index);
            _ = ShowPagePreview(page.Index);
        };
        _pagePreview = new Image { Stretch = Stretch.Uniform, MinHeight = 120 };
        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Ui.Hint(presentation
            ? Lang.T("Колоди презентацій і сторінки: клацання виводить сторінку в зал.", "Presentation decks and pages: a click shows the page in the hall.")
            : Lang.T("Картинки: клацання виводить картинку в зал.", "Pictures: a click shows the picture in the hall.")));
        // Як на планшеті: файл чи фото з цього комп'ютера — просто в показ.
        head.Children.Add(Ui.Button(presentation ? Lang.T("Файл із цього комп'ютера…", "A file from this computer…")
                                                 : Lang.T("Фото з цього комп'ютера…", "A photo from this computer…"),
                                    async () => await SendFile(presentation),
                                    presentation
                                        ? Lang.T("PDF чи PowerPoint — програма відкриє його в показі", "A PDF or PowerPoint — the program will open it in the show")
                                        : Lang.T("Картинка — програма покаже її в залі", "A picture — the program will show it in the hall")));
        if (presentation) head.Children.Add(new ScrollViewer { Content = _deckRow, HorizontalScrollBarVisibility = ScrollBarVisibility.Auto, VerticalScrollBarVisibility = ScrollBarVisibility.Disabled });
        var preview = new Border { Child = _pagePreview, Background = Brushes.Black, CornerRadius = new CornerRadius(6), MinHeight = 140, Margin = new Thickness(0, 8, 0, 0), ClipToBounds = true };
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(preview, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(preview);
        panel.Children.Add(new Border { Child = _pageList, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        if (!presentation) _ = LoadPictures();
        return panel;
    }

    sealed record PageRow(int Index, string Title)
    {
        public override string ToString() => Title;
    }

    void FillPages()
    {
        if (_pageList == null || (_tab != "presentation" && _tab != "pictures")) return;
        if (!_pagesArePresentation) return;   // картинки приходять своїм запитом
        var show = _state["presentation"] as JsonObject;
        var decks = (show?["decks"] as JsonArray ?? new JsonArray()).OfType<JsonObject>().ToList();
        var current = (int?)show?["deck"] ?? -1;
        _deckRow.Children.Clear();
        foreach (var deck in decks)
        {
            var index = (int?)deck["index"] ?? 0;
            var name = (string?)deck["name"] ?? "";
            _deckRow.Children.Add(Ui.Button(name, () => Send("deck", index), accent: index == current));
        }
        var pages = (show?["pages"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select((p, i) => new PageRow((int?)p["index"] ?? i, (string?)p["title"] ?? ((int?)p["index"] ?? i).ToString())).ToList();
        var was = _fillingBible;
        _fillingBible = true;
        _pageList.ItemsSource = pages;
        var open = (int?)show?["index"] ?? -1;
        var position = pages.FindIndex(p => p.Index == open);
        if (position >= 0) _pageList.SelectedIndex = position;
        _fillingBible = was;
    }

    async Task LoadPictures()
    {
        if (!_online) return;
        try
        {
            var answer = await _api.Get("/api/pictures");
            var pages = (answer["pages"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select(p => new PageRow((int?)p["index"] ?? 0, (string?)p["title"] ?? "")).ToList();
            var current = (int?)answer["index"] ?? -1;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _fillingBible = true;
                _pageList.ItemsSource = pages;
                var position = pages.FindIndex(p => p.Index == current);
                if (position >= 0) _pageList.SelectedIndex = position;
                _fillingBible = false;
            });
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    /// Файл із цього комп'ютера — у показ «Слова».
    async Task SendFile(bool presentation)
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = false,
            Title = presentation ? Lang.T("Файл для показу", "A file for the show") : Lang.T("Фото для залу", "A photo for the hall"),
            FileTypeFilter = new[]
            {
                new FilePickerFileType(presentation
                    ? Lang.T("Презентації", "Presentations") : Lang.T("Картинки", "Pictures"))
                {
                    Patterns = presentation
                        ? new[] { "*.pdf", "*.pptx", "*.ppt", "*.ppsx", "*.potx", "*.pptm", "*.ppsm" }
                        : new[] { "*.jpg", "*.jpeg", "*.png", "*.heic", "*.bmp", "*.gif", "*.tif", "*.tiff", "*.webp" },
                },
                FilePickerFileTypes.All,
            },
        });
        var file = files.FirstOrDefault();
        if (file?.TryGetLocalPath() is not { } path) return;
        Status(Lang.F("Надсилаю «{0}»…", "Sending “{0}”…", Path.GetFileName(path)));
        try
        {
            var bytes = await File.ReadAllBytesAsync(path);
            await _api.Upload(Path.GetFileName(path), bytes, show: !presentation);
            Status(Lang.F("«{0}» — у «Слові»", "“{0}” is in Slovo", Path.GetFileName(path)));
            if (presentation) await Task.Delay(700);
            else await LoadPictures();
        }
        catch (Exception error)
        {
            Status(Lang.F("Не вдалося: {0}", "Failed: {0}", Api.Describe(error)));
        }
    }

    async Task ShowPagePreview(int index)
    {
        try
        {
            var bytes = await _api.PageImage(index, 640, _pagesArePresentation ? "" : "pictures");
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (bytes == null) { _pagePreview.Source = null; return; }
                try { _pagePreview.Source = new Bitmap(new MemoryStream(bytes)); } catch { _pagePreview.Source = null; }
            });
        }
        catch
        {
            // Картинки сторінки може не бути — не привід писати про помилку.
        }
    }

    // MARK: Медіа

    ListBox _mediaList = null!;
    Slider _mediaPosition = null!, _mediaVolume = null!;
    TextBlock _mediaTitle = null!, _mediaTime = null!;
    Button _mediaPlay = null!, _mediaMute = null!, _mediaScreen = null!, _mediaRepeat = null!;
    bool _draggingMedia;

    Control MediaPanel()
    {
        _mediaTitle = Ui.Label("", 13, true);
        _mediaTime = new TextBlock { Foreground = Ui.Muted, FontSize = 12 };
        _mediaList = new ListBox { ItemTemplate = Text<PageRow>(p => p.Title) };
        _mediaList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _mediaList.SelectedItem is not PageRow row) return;
            _touched = DateTime.UtcNow;
            Send("media-open", row.Index);
        };
        _mediaPosition = new Slider { Minimum = 0, Maximum = 1000, Width = double.NaN };
        _mediaPosition.AddHandler(PointerPressedEvent, (_, _) => _draggingMedia = true, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        _mediaPosition.AddHandler(PointerReleasedEvent, (_, _) =>
        {
            _draggingMedia = false;
            var duration = (double?)(_state["media"] as JsonObject)?["duration"] ?? 0;
            if (duration > 0) Send("media-seek", new JsonObject { ["x"] = _mediaPosition.Value / 1000.0 * duration });
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        _mediaVolume = new Slider { Minimum = 0, Maximum = 100, Width = 140 };
        _mediaVolume.AddHandler(PointerReleasedEvent, (_, _) => Send("media-volume", new JsonObject { ["x"] = _mediaVolume.Value / 100.0 }),
                                Avalonia.Interactivity.RoutingStrategies.Tunnel);
        _mediaPlay = Ui.Button("▶ / ⏸", () => Send("media-toggle"), accent: true);
        _mediaMute = Ui.Button(Lang.T("Без звуку", "Mute"), () => Send("media-mute"));
        _mediaScreen = Ui.Button(Lang.T("На екран", "To screen"), () => Send("media-screen"),
                                 Lang.T("Чи йде відео в зал", "Whether the video goes to the hall"));
        _mediaRepeat = Ui.Button(Lang.T("Повтор", "Repeat"), () => Send("media-repeat"));

        var transport = new WrapPanel();
        foreach (var button in new[]
                 {
                     Ui.Button("⏮", () => Send("media-seek", new JsonObject { ["x"] = 0 })),
                     _mediaPlay,
                     Ui.Button("⏹", () => Send("media-stop")),
                     _mediaMute, _mediaScreen, _mediaRepeat,
                 })
        {
            button.Margin = new Thickness(0, 0, 6, 6);
            transport.Children.Add(button);
        }

        var bottom = new StackPanel { Spacing = 4, Margin = new Thickness(0, 8, 0, 0) };
        bottom.Children.Add(_mediaTitle);
        bottom.Children.Add(_mediaPosition);
        bottom.Children.Add(Ui.Row(_mediaTime, Ui.Label(Lang.T("Гучність:", "Volume:")), _mediaVolume));
        bottom.Children.Add(transport);

        var panel = new DockPanel();
        var hint = Ui.Hint(Lang.T("Список плеєра — файли додають у самій програмі.", "The player list — files are added in the program itself."));
        DockPanel.SetDock(hint, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        panel.Children.Add(hint);
        panel.Children.Add(bottom);
        panel.Children.Add(new Border { Child = _mediaList, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        _ = LoadMedia();
        return panel;
    }

    async Task LoadMedia()
    {
        if (!_online) return;
        try
        {
            var media = await _api.Get("/api/media");
            await Dispatcher.UIThread.InvokeAsync(() => ApplyMedia(media));
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    void ApplyMedia(JsonObject media)
    {
        if (_mediaList == null || _tab != "media") return;
        var playlist = (media["playlist"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
            .Select(p => new PageRow((int?)p["index"] ?? 0, (string?)p["name"] ?? "")).ToList();
        var was = _fillingBible;
        _fillingBible = true;
        _mediaList.ItemsSource = playlist;
        var open = (int?)media["index"] ?? -1;
        var position = playlist.FindIndex(p => p.Index == open);
        if (position >= 0) _mediaList.SelectedIndex = position;
        _fillingBible = was;
        _mediaTitle.Text = (string?)media["title"] ?? "";
        var duration = (double?)media["duration"] ?? 0;
        var at = (double?)media["position"] ?? 0;
        _mediaTime.Text = Time(at) + " / " + Time(duration);
        if (!_draggingMedia && duration > 0) _mediaPosition.Value = Math.Min(1000, at / duration * 1000);
        _mediaVolume.Value = ((double?)media["volume"] ?? 0.8) * 100;
        _mediaPlay.Content = (bool?)media["playing"] == true ? "⏸" : "▶";
        Accent(_mediaMute, (bool?)media["muted"] == true);
        Accent(_mediaScreen, (bool?)media["toScreen"] == true);
        Accent(_mediaRepeat, (bool?)media["repeats"] == true);
    }

    static string Time(double seconds)
    {
        if (seconds <= 0 || double.IsNaN(seconds)) return "0:00";
        var span = TimeSpan.FromSeconds(seconds);
        return span.Hours > 0 ? $"{span.Hours}:{span.Minutes:00}:{span.Seconds:00}" : $"{span.Minutes}:{span.Seconds:00}";
    }

    static void Accent(Button button, bool on)
    {
        button.Background = on ? Ui.Accent : Brushes.Transparent;
        button.Foreground = on ? Brushes.White : Brushes.Black;
    }

    // MARK: Екран

    ListBox _screenList = null!;
    TextBlock _screenNote = null!;

    Control ScreenPanel()
    {
        _screenList = new ListBox { ItemTemplate = new FuncDataTemplate<ScreenRow>((row, _) =>
        {
            var panel = new StackPanel { Spacing = 1, Margin = new Thickness(2, 3) };
            panel.Children.Add(new TextBlock { Text = row?.Title ?? "", FontWeight = FontWeight.SemiBold });
            if (!string.IsNullOrEmpty(row?.Subtitle)) panel.Children.Add(new TextBlock { Text = row.Subtitle, Foreground = Ui.Muted, FontSize = 12 });
            return panel;
        }) };
        _screenList.SelectionChanged += (_, _) =>
        {
            if (_fillingBible || _screenList.SelectedItem is not ScreenRow row) return;
            Send("screen-start", row.Index);
        };
        _screenNote = new TextBlock { Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap };
        var buttons = Ui.Row(
            Ui.Button(Lang.T("Оновити список", "Refresh the list"), () => { Send("screen-reload"); _ = Task.Run(async () => { await Task.Delay(1500); await LoadScreen(); }); }),
            Ui.Button(Lang.T("Зупинити показ", "Stop showing"), () => Send("screen-stop")));
        buttons.Margin = new Thickness(0, 8, 0, 0);
        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Ui.Hint(Lang.T("Монітори й вікна комп'ютера зі «Словом»: клацання показує вибране в залі.",
                                         "Monitors and windows of the computer running Slovo: a click shows the chosen one in the hall.")));
        head.Children.Add(_screenNote);
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(buttons);
        panel.Children.Add(new Border { Child = _screenList, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        _ = LoadScreen();
        return panel;
    }

    sealed record ScreenRow(int Index, string Title, string Subtitle)
    {
        public override string ToString() => Subtitle.Length > 0 ? Title + " — " + Subtitle : Title;
    }

    async Task LoadScreen()
    {
        if (!_online) return;
        try
        {
            var answer = await _api.Get("/api/screen");
            var sources = (answer["sources"] as JsonArray ?? new JsonArray()).OfType<JsonObject>()
                .Select(s => new ScreenRow((int?)s["index"] ?? 0, (string?)s["title"] ?? "", (string?)s["subtitle"] ?? "")).ToList();
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (_screenList == null || _tab != "screen") return;
                _fillingBible = true;
                _screenList.ItemsSource = sources;
                _fillingBible = false;
                var note = (string?)answer["note"] ?? "";
                if ((bool?)answer["permission"] == false)
                    note = Lang.T("«Слову» бракує дозволу на запис екрана (Системні параметри → Приватність і безпека → Запис екрана).",
                                  "Slovo lacks the screen recording permission (System Settings → Privacy & Security → Screen Recording).");
                _screenNote.Text = note;
            });
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    // MARK: Текст

    TextBox _textTitle = null!, _textBody = null!;
    TextBlock _textPages = null!;

    Control TextPanel()
    {
        _textTitle = new TextBox { Watermark = Lang.T("Заголовок оголошення", "Announcement title") };
        _textBody = new TextBox
        {
            Watermark = Lang.T("Текст оголошення", "Announcement text"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        _textPages = new TextBlock { Foreground = Ui.Muted, FontSize = 12 };
        var send = Ui.Button(Lang.T("У передпоказ", "To the preview"), () => SendText(live: false));
        var show = Ui.Button(Lang.T("Показати в залі", "Show in the hall"), () => SendText(live: true), accent: true);
        var pages = Ui.Row(
            Ui.Button("◀", () => Send("text-page", Math.Max(0, ((int?)_state["textPage"] ?? 0) - 1))),
            _textPages,
            Ui.Button("▶", () => Send("text-page", ((int?)_state["textPage"] ?? 0) + 1)));
        var bottom = new StackPanel { Spacing = 6, Margin = new Thickness(0, 8, 0, 0) };
        bottom.Children.Add(pages);
        var buttons = Ui.Row(send, show);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        bottom.Children.Add(buttons);
        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Ui.Hint(Lang.T("Оголошення прямо з цього комп'ютера: заголовок, текст — і в зал.",
                                         "An announcement straight from this computer: a title, the text — and into the hall.")));
        head.Children.Add(_textTitle);
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(bottom);
        panel.Children.Add(_textBody);
        _ = LoadText();
        return panel;
    }

    async Task LoadText()
    {
        if (!_online) return;
        try
        {
            var answer = await _api.Get("/api/text");
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                if (_textTitle == null || _tab != "text") return;
                if (!_textTitle.IsFocused) _textTitle.Text = (string?)answer["title"] ?? "";
                if (!_textBody.IsFocused) _textBody.Text = (string?)answer["body"] ?? "";
                var page = (int?)answer["page"] ?? 0;
                var count = (int?)answer["pages"] ?? 0;
                _state["textPage"] = page;
                _textPages.Text = count > 0 ? Lang.F("Сторінка {0} з {1}", "Page {0} of {1}", page + 1, count) : "";
            });
        }
        catch (Exception error)
        {
            Status(Api.Describe(error));
        }
    }

    void SendText(bool live)
    {
        var body = new JsonObject { ["title"] = _textTitle.Text ?? "", ["text"] = _textBody.Text ?? "" };
        _ = Run(async () =>
        {
            await _api.Command("text-set", body, 15);
            if (live) await _api.Command("text-show");
            await LoadText();
            return new JsonObject();
        });
    }
}
