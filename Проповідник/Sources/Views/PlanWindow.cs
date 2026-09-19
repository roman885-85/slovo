// =============================================================================
//  PlanWindow.cs — складання плану проповіді
// =============================================================================
//  Те саме, що екран «План проповіді» на планшеті (SermonActivity.java):
//  ліворуч вкладки Біблія, Пісні, Файл і Текст, праворуч сам план із
//  «↑ Вище», «↓ Нижче», «✕ Прибрати», три кроки вгорі й велика синя кнопка
//  «⬆ Завантажити в «Слово»» внизу. Складають удома, без зв'язку; на служінні —
//  одна кнопка.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed class PlanWindow : Window
{
    readonly Settings _settings = Settings.Load();
    readonly Library _library = new();
    SermonPlan _plan;
    bool _busy;
    bool? _online;
    readonly CancellationTokenSource _closing = new();

    /// План поїхав у «Слово» — робоче місце має стати на вкладку «План».
    public Action? Uploaded { get; set; }

    // Біблія
    ComboBox _bibles = null!;
    ListBox _books = null!, _chapters = null!, _verses = null!;
    // Пісні
    ComboBox _songbooks = null!;
    TextBox _songFilter = null!;
    ListBox _songs = null!;
    TextBlock _songPreview = null!;
    // Текст
    TextBox _heading = null!, _body = null!;
    // План
    TextBox _planTitle = null!;
    ListBox _items = null!;
    TextBlock _planCount = null!, _planEmpty = null!, _status = null!, _connection = null!;
    Button _plansButton = null!, _upload = null!, _up = null!, _down = null!, _remove = null!;
    readonly TextBlock[] _steps = new TextBlock[3];

    public PlanWindow()
    {
        Width = 1260;
        Height = 800;
        MinWidth = 980;
        MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        try { Icon = new WindowIcon(AssetLoader.Open(new Uri("avares://Propovidnyk/Resources/AppIcon-256.png"))); }
        catch { /* без значка вікна — не біда */ }

        _plan = SermonPlan.Load(_settings.LastPlan, true) ?? SermonPlan.All().FirstOrDefault() ?? new SermonPlan();
        Build();
        Closing += (_, _) =>
        {
            SavePlan();
            _closing.Cancel();
        };
        _ = WatchConnection();
    }

    // MARK: Складання вікна

    void Build()
    {
        Title = Lang.T("Проповідник Слова — план проповіді", "Slovo Preacher — sermon plan");

        _planTitle = new TextBox
        {
            Text = _plan.Title,
            Watermark = Lang.T("Назва плану, напр. «Неділя, 14 вересня»", "Plan name, e.g. “Sunday, 14 September”"),
            MinWidth = 320,
        };
        _planTitle.LostFocus += (_, _) => { _plan.Title = _planTitle.Text ?? ""; SavePlan(); RefreshPlansButton(); };

        _plansButton = Ui.Button("", () => { }, Lang.T("Інший план, новий чи видалити цей", "Another plan, a new one or delete this one"));
        var plansMenu = new MenuFlyout();
        // Перелік планів збирається в мить відкриття: між відкриттями план
        // могли перейменувати чи додати пункти.
        plansMenu.Opening += (_, _) => FillPlansMenu();
        _plansButton.Flyout = plansMenu;

        var language = new MenuFlyout();
        foreach (var (code, name) in new[] { ("auto", Lang.T("Авто (мова Windows)", "Auto (Windows language)")), ("uk", "Українська"), ("en", "English") })
        {
            var item = new MenuItem { Header = (_settings.Language == code ? "● " : "   ") + name };
            item.Click += (_, _) => ChangeLanguage(code);
            language.Items.Add(item);
        }
        var languageButton = Ui.Button("Мова / Language", () => { }, "Мова інтерфейсу / Interface language");
        languageButton.Flyout = language;

        var top = new DockPanel { LastChildFill = false, Margin = new Thickness(12, 10, 12, 6) };
        var left = Ui.Row(Ui.Label("📋 " + Lang.T("План проповіді", "Sermon plan"), 18, true), _planTitle, _plansButton);
        left.Spacing = 10;
        DockPanel.SetDock(left, Dock.Left);
        top.Children.Add(left);
        var right = Ui.Row(
            Ui.Button(Lang.T("Переклади й пісенники", "Translations and songbooks"), OpenLibrary,
                      Lang.T("Бібліотека: переклади й пісенники, з якими складається план без зв'язку", "Library: translations and songbooks for building a plan offline")),
            Ui.Button(Lang.T("Підключення…", "Connection…"), OpenConnection,
                      Lang.T("Де шукати «Слово» в мережі: адреса, порт і PIN", "Where to find Slovo on the network: address, port and PIN")),
            languageButton);
        DockPanel.SetDock(right, Dock.Right);
        top.Children.Add(right);

        var steps = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 24, Margin = new Thickness(14, 0, 12, 8) };
        var stepTexts = new[]
        {
            Lang.T("① Додайте пункти", "① Add items"),
            Lang.T("② Перевірте порядок", "② Check the order"),
            Lang.T("③ Завантажте в «Слово»", "③ Upload to Slovo"),
        };
        for (var i = 0; i < 3; i++)
        {
            _steps[i] = Ui.Label(stepTexts[i], 13);
            steps.Children.Add(_steps[i]);
        }

        var tabs = new TabControl
        {
            Items =
            {
                new TabItem { Header = Lang.T("Біблія", "Bible"), Content = BiblePanel() },
                new TabItem { Header = Lang.T("Пісні", "Songs"), Content = SongsPanel() },
                new TabItem { Header = Lang.T("Файл", "File"), Content = FilePanel() },
                new TabItem { Header = Lang.T("Текст", "Text"), Content = TextPanel() },
            },
        };

        var body = new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("3*,8,2*"),
            Margin = new Thickness(12, 0, 12, 12),
        };
        var tabsCard = Ui.Card(tabs, 6);
        Grid.SetColumn(tabsCard, 0);
        body.Children.Add(tabsCard);
        var planCard = Ui.Card(PlanPanel());
        Grid.SetColumn(planCard, 2);
        body.Children.Add(planCard);

        var root = new DockPanel { Background = Ui.Paper };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(steps, Dock.Top);
        root.Children.Add(top);
        root.Children.Add(steps);
        root.Children.Add(body);
        Content = root;

        ReloadBibles();
        ReloadSongbooks();
        RefreshPlan();
        RefreshPlansButton();
        ShowConnection();
    }

    // MARK: Біблія

    Control BiblePanel()
    {
        _bibles = new ComboBox { MinWidth = 320, PlaceholderText = Lang.T("Переклад", "Translation") };
        _bibles.SelectionChanged += (_, _) => ReloadBooks();
        _books = new ListBox { ItemTemplate = new FuncDataTemplate<Book>((b, _) => new TextBlock { Text = b?.Name ?? "", Padding = new Thickness(2) }) };
        _books.SelectionChanged += (_, _) => ReloadChapters();
        _chapters = new ListBox
        {
            ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel()),
            ItemTemplate = new FuncDataTemplate<int>((n, _) => new TextBlock { Text = n.ToString(), MinWidth = 26, TextAlignment = TextAlignment.Center }),
        };
        _chapters.SelectionChanged += (_, _) => ReloadVerses();
        _verses = new ListBox
        {
            SelectionMode = SelectionMode.Multiple | SelectionMode.Toggle,
            ItemTemplate = new FuncDataTemplate<Verse>((v, _) => new TextBlock
            {
                Inlines = v == null ? null : new Avalonia.Controls.Documents.InlineCollection
                {
                    new Avalonia.Controls.Documents.Run(v.Number + "  ") { Foreground = Ui.Accent, FontWeight = FontWeight.SemiBold },
                    new Avalonia.Controls.Documents.Run(v.Text),
                },
                TextWrapping = TextWrapping.Wrap,
            }),
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(_verses, Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("190,8,150,8,*"), RowDefinitions = new RowDefinitions("*") };
        void Put(Control control, int column, string caption)
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
        Put(_books, 0, Lang.T("Книга", "Book"));
        Put(_chapters, 2, Lang.T("Розділ", "Chapter"));
        Put(_verses, 4, Lang.T("Вірші — клацніть потрібні, ще раз знімає позначку", "Verses — click the ones you need, click again to unmark"));

        var add = Ui.Button(Lang.T("＋ Додати вірші в план", "＋ Add verses to the plan"), () => AddScripture(false), accent: true);
        var whole = Ui.Button(Lang.T("＋ Увесь розділ", "＋ Whole chapter"), () => AddScripture(true));
        var buttons = Ui.Row(whole, add);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 8, 0, 0);

        var panel = new DockPanel { Margin = new Thickness(6) };
        var head = new StackPanel { Spacing = 6 };
        head.Children.Add(Ui.Hint(Lang.T("Виберіть переклад, книгу й розділ, клацніть потрібні вірші — і «＋ Додати вірші в план».",
                                         "Choose a translation, book and chapter, click the verses you need — then “＋ Add verses to the plan”.")));
        head.Children.Add(Ui.Row(Ui.Label(Lang.T("Переклад:", "Translation:")), _bibles));
        head.Margin = new Thickness(0, 0, 0, 8);
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(buttons);
        panel.Children.Add(grid);
        return panel;
    }

    void ReloadBibles()
    {
        var chosen = (_bibles.SelectedItem as ModuleChoice)?.Module.Id;
        var modules = _library.Modules(Library.Bible).Select(m => new ModuleChoice(m)).ToList();
        _bibles.ItemsSource = modules;
        _bibles.SelectedItem = modules.FirstOrDefault(m => m.Module.Id == chosen) ?? modules.FirstOrDefault();
        if (modules.Count == 0) SetStatus(Lang.T("У бібліотеці ще немає перекладів. «Переклади й пісенники» вгорі → зі «Слова», з GitHub або з файла",
                                                 "The library has no translations yet. “Translations and songbooks” at the top → from Slovo, from GitHub or from a file"));
    }

    void ReloadBooks()
    {
        var bible = (_bibles.SelectedItem as ModuleChoice)?.Module;
        _books.ItemsSource = bible == null ? null : _library.Books(bible.Id);
        _books.SelectedIndex = bible == null ? -1 : 0;
    }

    void ReloadChapters()
    {
        var bible = (_bibles.SelectedItem as ModuleChoice)?.Module;
        var book = _books.SelectedItem as Book;
        _chapters.ItemsSource = bible == null || book == null ? null : _library.Chapters(bible.Id, book.Index);
        _chapters.SelectedIndex = book == null ? -1 : 0;
    }

    void ReloadVerses()
    {
        var bible = (_bibles.SelectedItem as ModuleChoice)?.Module;
        var book = _books.SelectedItem as Book;
        _verses.ItemsSource = bible == null || book == null || _chapters.SelectedItem is not int chapter
            ? null : _library.Verses(bible.Id, book.Index, chapter);
    }

    void AddScripture(bool whole)
    {
        var bible = (_bibles.SelectedItem as ModuleChoice)?.Module;
        if (bible == null || _books.SelectedItem is not Book book || _chapters.SelectedItem is not int chapter)
        {
            SetStatus(Lang.T("Спершу виберіть переклад, книгу й розділ", "Choose a translation, book and chapter first"));
            return;
        }
        var all = _library.Verses(bible.Id, book.Index, chapter);
        var picked = _verses.SelectedItems?.OfType<Verse>().Select(v => v.Number).ToHashSet() ?? new HashSet<int>();
        if (!whole && picked.Count == 0)
        {
            SetStatus(Lang.T("Клацніть вірші — ще раз знімає позначку", "Click verses — click again to unmark"));
            return;
        }
        var chosen = whole ? all : all.Where(v => picked.Contains(v.Number)).ToList();
        var item = new PlanItem
        {
            Type = PlanItem.Scripture,
            Module = bible.Id,
            ModuleName = bible.Name,
            BookName = book.Name,
            Canon = book.Canon,
            Book = book.Index,
            Chapter = chapter,
            Verses = whole ? new List<int>() : chosen.Select(v => v.Number).ToList(),
            Body = string.Join(" ", chosen.Select(v => v.Text)),
        };
        var name = book.ShortName.Length == 0 ? book.Name : book.ShortName.Split(' ')[0];
        item.Title = name + " " + chapter + (whole ? "" : ":" + SermonPlan.Span(item.Verses));
        AddItem(item);
        _verses.SelectedItems?.Clear();
    }

    // MARK: Пісні

    Control SongsPanel()
    {
        _songbooks = new ComboBox { MinWidth = 320, PlaceholderText = Lang.T("Пісенник", "Songbook") };
        _songbooks.SelectionChanged += (_, _) => ReloadSongs();
        _songFilter = new TextBox { Watermark = Lang.T("Номер або слова назви", "Number or words of the title"), MinWidth = 240 };
        _songFilter.TextChanged += (_, _) => ReloadSongs();
        _songs = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<Song>((s, _) => new TextBlock { Text = s == null ? "" : $"{s.Index + 1}. {s.Title}" }),
        };
        _songs.SelectionChanged += (_, _) => ShowSongPreview();
        _songs.DoubleTapped += (_, _) => AddSong();
        _songPreview = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = Ui.Muted, Margin = new Thickness(8, 0, 0, 0) };

        var add = Ui.Button(Lang.T("＋ Додати пісню в план", "＋ Add song to the plan"), AddSong, accent: true);
        add.HorizontalAlignment = HorizontalAlignment.Right;
        add.Margin = new Thickness(0, 8, 0, 0);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,*") };
        var list = new Border { Child = _songs, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) };
        grid.Children.Add(list);
        var preview = new ScrollViewer { Content = _songPreview };
        Grid.SetColumn(preview, 1);
        grid.Children.Add(preview);

        var panel = new DockPanel { Margin = new Thickness(6) };
        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 8) };
        head.Children.Add(Ui.Hint(Lang.T("Виберіть пісенник і пісню — і «＋ Додати пісню в план». Подвійне клацання теж додає.",
                                         "Choose a songbook and a song — then “＋ Add song to the plan”. A double click adds it too.")));
        head.Children.Add(Ui.Row(Ui.Label(Lang.T("Пісенник:", "Songbook:")), _songbooks, _songFilter));
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(add, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(add);
        panel.Children.Add(grid);
        return panel;
    }

    void ReloadSongbooks()
    {
        var chosen = (_songbooks.SelectedItem as ModuleChoice)?.Module.Id;
        var modules = _library.Modules(Library.Songs).Select(m => new ModuleChoice(m)).ToList();
        _songbooks.ItemsSource = modules;
        _songbooks.SelectedItem = modules.FirstOrDefault(m => m.Module.Id == chosen) ?? modules.FirstOrDefault();
    }

    void ReloadSongs()
    {
        var songbook = (_songbooks.SelectedItem as ModuleChoice)?.Module;
        _songs.ItemsSource = songbook == null ? null : _library.SongsOf(songbook.Id, _songFilter.Text ?? "");
    }

    void ShowSongPreview()
    {
        var songbook = (_songbooks.SelectedItem as ModuleChoice)?.Module;
        if (songbook == null || _songs.SelectedItem is not Song song)
        {
            _songPreview.Text = "";
            return;
        }
        _songPreview.Text = string.Join("\n\n", _library.Parts(songbook.Id, song.Index).Select(p => p.Kind + "\n" + p.Text.Trim()));
    }

    void AddSong()
    {
        var songbook = (_songbooks.SelectedItem as ModuleChoice)?.Module;
        if (songbook == null || _songs.SelectedItem is not Song song)
        {
            SetStatus(Lang.T("Спершу виберіть пісню", "Choose a song first"));
            return;
        }
        AddItem(new PlanItem
        {
            Type = PlanItem.Song,
            Module = songbook.Id,
            SongBook = songbook.Id.StartsWith("songs:", StringComparison.Ordinal) ? songbook.Id[6..] : songbook.Id,
            SongIndex = song.Index,
            Title = song.Title.Length == 0 ? (song.Index + 1).ToString() : song.Title,
            Parts = _library.Parts(songbook.Id, song.Index).Select(p => (p.Kind, p.Text)).ToList(),
        });
    }

    // MARK: Файл і текст

    Control FilePanel()
    {
        var pick = Ui.Button(Lang.T("Вибрати файл…", "Choose a file…"), async () => await PickFile(), accent: true);
        pick.HorizontalAlignment = HorizontalAlignment.Left;
        var panel = new StackPanel { Margin = new Thickness(10), Spacing = 10 };
        panel.Children.Add(Ui.Hint(Lang.T(
            "Презентація (PDF, PowerPoint), картинка чи відео. Файл копіюється в програму і на служінні їде в «Слово» разом із планом. Файл можна й просто перетягнути у вікно.",
            "A presentation (PDF, PowerPoint), picture or video. The file is copied into the program and goes to Slovo with the plan during the service. You can also drop the file onto the window.")));
        panel.Children.Add(pick);
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DropEvent, (_, e) =>
        {
#pragma warning disable CS0618 // DataTransfer з'явився в 11.3, а GetFiles на ньому ще рідний для старого шляху
            foreach (var file in e.Data.GetFiles() ?? Array.Empty<IStorageItem>())
#pragma warning restore CS0618
            {
                if (file.TryGetLocalPath() is { } path && File.Exists(path)) AddFile(path);
            }
        });
        return panel;
    }

    async Task PickFile()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = true,
            Title = Lang.T("Файл для плану", "A file for the plan"),
            FileTypeFilter = new[]
            {
                new FilePickerFileType(Lang.T("Презентації, картинки, відео", "Presentations, pictures, video"))
                {
                    Patterns = new[] { "*.pdf", "*.pptx", "*.ppt", "*.ppsx", "*.potx", "*.pptm", "*.ppsm", "*.key",
                                       "*.jpg", "*.jpeg", "*.png", "*.heic", "*.bmp", "*.gif", "*.tif", "*.tiff", "*.webp",
                                       "*.mp4", "*.mov", "*.m4v", "*.avi", "*.mkv", "*.mp3", "*.m4a", "*.wav" },
                },
                FilePickerFileTypes.All,
            },
        });
        foreach (var file in files)
        {
            if (file.TryGetLocalPath() is { } path) AddFile(path);
        }
    }

    void AddFile(string path)
    {
        try
        {
            var name = Path.GetFileName(path);
            var copy = Path.Combine(Paths.PlanFiles, Guid.NewGuid() + "-" + name);
            File.Copy(path, copy);
            AddItem(new PlanItem { Type = PlanItem.File, Name = name, Title = name, Path = copy });
        }
        catch (Exception error)
        {
            SetStatus(Lang.F("Не вдалося: {0}", "Failed: {0}", error.Message));
        }
    }

    Control TextPanel()
    {
        _heading = new TextBox { Watermark = Lang.T("Заголовок", "Title") };
        _body = new TextBox
        {
            Watermark = Lang.T("Текст оголошення", "Announcement text"),
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalContentAlignment = VerticalAlignment.Top,
        };
        var add = Ui.Button(Lang.T("＋ Додати текст у план", "＋ Add text to the plan"), AddText, accent: true);
        add.HorizontalAlignment = HorizontalAlignment.Right;
        add.Margin = new Thickness(0, 8, 0, 0);
        var panel = new DockPanel { Margin = new Thickness(6) };
        var head = new StackPanel { Spacing = 6, Margin = new Thickness(0, 0, 0, 6) };
        head.Children.Add(Ui.Hint(Lang.T("Заголовок і текст оголошення — і «＋ Додати текст у план».", "An announcement title and text — then “＋ Add text to the plan”.")));
        head.Children.Add(_heading);
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(add, Dock.Bottom);
        panel.Children.Add(head);
        panel.Children.Add(add);
        panel.Children.Add(_body);
        return panel;
    }

    void AddText()
    {
        var heading = (_heading.Text ?? "").Trim();
        var body = (_body.Text ?? "").Trim();
        if (heading.Length == 0 && body.Length == 0) return;
        var first = body.Replace('\n', ' ').Replace('\r', ' ');
        AddItem(new PlanItem
        {
            Type = PlanItem.Text,
            Heading = heading,
            Announcement = body,
            Title = heading.Length > 0 ? heading : first.Length > 60 ? first[..60] + "…" : first,
        });
        _heading.Text = "";
        _body.Text = "";
    }

    // MARK: План

    Control PlanPanel()
    {
        _planCount = Ui.Label("", 15, true);
        _planEmpty = Ui.Hint(Lang.T("План порожній. Додайте ліворуч вірші, пісні, файли чи текст", "The plan is empty. Add verses, songs, files or text on the left"));
        _items = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<PlanRow>((row, _) =>
            {
                var panel = new StackPanel { Spacing = 2, Margin = new Thickness(2, 3) };
                panel.Children.Add(new TextBlock { Text = row?.Title ?? "", FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap });
                if (!string.IsNullOrEmpty(row?.Subtitle))
                    panel.Children.Add(new TextBlock { Text = row.Subtitle, Foreground = Ui.Muted, FontSize = 12, TextWrapping = TextWrapping.Wrap, MaxLines = 2 });
                return panel;
            }),
        };
        ScrollViewer.SetHorizontalScrollBarVisibility(_items, Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled);
        _items.SelectionChanged += (_, _) => RefreshButtons();
        _items.KeyDown += (_, e) => { if (e.Key == Key.Delete) Remove(); };

        _up = Ui.Button(Lang.T("↑ Вище", "↑ Up"), () => Move(-1));
        _down = Ui.Button(Lang.T("↓ Нижче", "↓ Down"), () => Move(1));
        _remove = Ui.Button(Lang.T("✕ Прибрати", "✕ Remove"), Remove);

        _connection = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center };
        _upload = Ui.Button(Lang.T("⬆ Завантажити в «Слово»", "⬆ Upload to Slovo"), async () => await Upload(), accent: true);
        _upload.HorizontalAlignment = HorizontalAlignment.Stretch;
        _upload.HorizontalContentAlignment = HorizontalAlignment.Center;
        _upload.FontSize = 17;
        _upload.Padding = new Thickness(12, 12);
        _status = new TextBlock { FontSize = 12, Foreground = Ui.Muted, TextWrapping = TextWrapping.Wrap, HorizontalAlignment = HorizontalAlignment.Center };

        var top = new StackPanel { Spacing = 4, Margin = new Thickness(0, 0, 0, 6) };
        top.Children.Add(_planCount);
        top.Children.Add(Ui.Hint(Lang.T("Клацніть пункт, щоб вибрати, — потім «↑ Вище», «↓ Нижче» чи «✕ Прибрати».",
                                        "Click an item to select it — then “↑ Up”, “↓ Down” or “✕ Remove”.")));
        top.Children.Add(_planEmpty);
        var buttons = Ui.Row(_up, _down, _remove);
        buttons.Margin = new Thickness(0, 6, 0, 10);
        var bottom = new StackPanel { Spacing = 6 };
        bottom.Children.Add(buttons);
        bottom.Children.Add(_upload);
        bottom.Children.Add(_connection);
        bottom.Children.Add(_status);

        var panel = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        panel.Children.Add(top);
        panel.Children.Add(bottom);
        panel.Children.Add(new Border { Child = _items, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        return panel;
    }

    sealed record PlanRow(int Index, string Title, string Subtitle)
    {
        public override string ToString() => Subtitle.Length > 0 ? Title + " — " + Subtitle : Title;
    }
    sealed record ModuleChoice(Module Module)
    {
        public override string ToString() => Module.Name + (Module.ShortName.Length > 0 && Module.ShortName != Module.Name ? " (" + Module.ShortName + ")" : "");
    }

    void AddItem(PlanItem item)
    {
        _plan.Items.Add(item);
        SavePlan();
        RefreshPlan(_plan.Items.Count - 1);
        SetStatus(Lang.F("Додано: {0}", "Added: {0}", item.Title));
    }

    void Move(int delta)
    {
        var index = _items.SelectedIndex;
        var target = index + delta;
        if (index < 0 || target < 0 || target >= _plan.Items.Count) return;
        (_plan.Items[index], _plan.Items[target]) = (_plan.Items[target], _plan.Items[index]);
        SavePlan();
        RefreshPlan(target);
    }

    void Remove()
    {
        var index = _items.SelectedIndex;
        if (index < 0 || index >= _plan.Items.Count) return;
        var item = _plan.Items[index];
        if (item.Type == PlanItem.File && item.Path.Length > 0)
        {
            try { File.Delete(item.Path); } catch { /* уже нема */ }
        }
        _plan.Items.RemoveAt(index);
        SavePlan();
        RefreshPlan(Math.Min(index, _plan.Items.Count - 1));
    }

    void RefreshPlan(int select = -1)
    {
        _items.ItemsSource = _plan.Items.Select((item, i) => new PlanRow(i, $"{i + 1}.  {item.Icon}  {item.Title}", item.Subtitle)).ToList();
        if (select >= 0) _items.SelectedIndex = select;
        _planCount.Text = Lang.F("У плані: {0}", "In the plan: {0}", _plan.Items.Count);
        _planEmpty.IsVisible = _plan.Items.Count == 0;
        RefreshButtons();
    }

    void RefreshButtons()
    {
        var index = _items.SelectedIndex;
        _up.IsEnabled = index > 0;
        _down.IsEnabled = index >= 0 && index < _plan.Items.Count - 1;
        _remove.IsEnabled = index >= 0;
        _upload.IsEnabled = !_busy && _plan.Items.Count > 0;
        // Крок, на якому людина зараз: порожній план — додавати; є пункти —
        // перевіряти порядок; «Слово» на зв'язку — завантажувати.
        var step = _plan.Items.Count == 0 ? 0 : _online == true ? 2 : 1;
        for (var i = 0; i < 3; i++)
        {
            _steps[i].Foreground = i == step ? Ui.Accent : Ui.Muted;
            _steps[i].FontWeight = i == step ? FontWeight.SemiBold : FontWeight.Normal;
        }
    }

    void SavePlan()
    {
        try
        {
            _plan.Title = _planTitle?.Text ?? _plan.Title;
            if (_plan.Items.Count == 0 && string.IsNullOrWhiteSpace(_plan.Title) && !File.Exists(Path.Combine(Paths.Plans, _plan.Id + ".json"))) return;
            _plan.Save();
            _settings.LastPlan = _plan.Id;
            _settings.Save();
        }
        catch (Exception error)
        {
            SetStatus(Lang.F("План не записався: {0}", "The plan was not saved: {0}", error.Message));
        }
    }

    // MARK: Мої плани

    void RefreshPlansButton()
    {
        var count = SermonPlan.All().Count;
        _plansButton.Content = Lang.F("Мої плани ({0}) ▾", "My plans ({0}) ▾", Math.Max(count, 1));
    }

    void FillPlansMenu()
    {
        SavePlan();
        var menu = (MenuFlyout)_plansButton.Flyout!;
        menu.Items.Clear();
        foreach (var plan in SermonPlan.All())
        {
            var item = new MenuItem { Header = (plan.Id == _plan.Id ? "● " : "   ") + Lang.F("{0} · пунктів: {1}", "{0} · items: {1}", plan.DisplayTitle, plan.Items.Count) };
            item.Click += (_, _) => OpenPlan(plan);
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        var fresh = new MenuItem { Header = Lang.T("＋ Новий план", "＋ New plan") };
        fresh.Click += (_, _) => OpenPlan(new SermonPlan());
        menu.Items.Add(fresh);
        var delete = new MenuItem { Header = Lang.T("Видалити цей план", "Delete this plan") };
        delete.Click += async (_, _) =>
        {
            if (!await Ui.Ask(this, Lang.T("Видалити план", "Delete plan"),
                              Lang.F("Видалити план «{0}»?", "Delete the plan “{0}”?", _plan.DisplayTitle), Lang.T("Видалити", "Delete"))) return;
            _plan.Delete();
            OpenPlan(SermonPlan.All().FirstOrDefault() ?? new SermonPlan());
        };
        menu.Items.Add(delete);
    }

    void OpenPlan(SermonPlan plan)
    {
        _plan = plan;
        _planTitle.Text = plan.Title;
        _settings.LastPlan = plan.Id;
        _settings.Save();
        RefreshPlan();
        RefreshPlansButton();
    }

    // MARK: Бібліотека, підключення, мова

    async void OpenLibrary()
    {
        await new LibraryWindow(_library, _settings).ShowDialog(this);
        ReloadBibles();
        ReloadSongbooks();
    }

    async void OpenConnection()
    {
        await new ConnectWindow(_settings).ShowDialog(this);
        _online = null;
        ShowConnection();
    }

    void ChangeLanguage(string code)
    {
        SavePlan();
        _settings.Language = code;
        _settings.Save();
        Lang.Choice = code;
        Build();
    }

    // MARK: Зв'язок і завантаження

    async Task WatchConnection()
    {
        while (!_closing.IsCancellationRequested)
        {
            bool? reached = null;
            if (_settings.HasHost)
            {
                try
                {
                    await Api.From(_settings).State(0, _closing.Token);
                    reached = true;
                }
                catch
                {
                    reached = false;
                }
            }
            if (_closing.IsCancellationRequested) return;
            _online = reached;
            await Dispatcher.UIThread.InvokeAsync(ShowConnection);
            try { await Task.Delay(TimeSpan.FromSeconds(6), _closing.Token); } catch { return; }
        }
    }

    void ShowConnection()
    {
        if (_connection == null) return;
        if (!_settings.HasHost)
        {
            _connection.Text = Lang.T("«Слово» ще не вибрано — «Підключення…» вгорі", "Slovo is not chosen yet — “Connection…” at the top");
            _connection.Foreground = Ui.Muted;
        }
        else if (_online == null)
        {
            _connection.Text = Lang.T("Перевіряю зв'язок зі «Словом»…", "Checking the connection to Slovo…");
            _connection.Foreground = Ui.Muted;
        }
        else
        {
            var where = (_settings.Name.Length > 0 ? _settings.Name + " · " : "") + _settings.Host + ":" + _settings.Port;
            _connection.Text = (_online == true
                ? Lang.T("● «Слово» на зв'язку", "● Slovo is connected")
                : Lang.T("○ «Слово» не відповідає — перевірте мережу і програму на комп'ютері", "○ Slovo is not responding — check the network and the program on the computer")) + "  (" + where + ")";
            _connection.Foreground = _online == true ? Ui.Good : Ui.Bad;
        }
        RefreshButtons();
    }

    void SetStatus(string text) => Dispatcher.UIThread.Post(() => { if (_status != null) _status.Text = text; });

    async Task Upload()
    {
        SavePlan();
        if (_plan.Items.Count == 0)
        {
            SetStatus(Lang.T("План порожній — надсилати нічого", "The plan is empty — nothing to send"));
            return;
        }
        if (!_settings.HasHost)
        {
            await Ui.Message(this, Lang.T("Підключення", "Connection"),
                             Lang.T("Спершу виберіть «Слово»: кнопка «Підключення…» вгорі.", "Choose Slovo first: the “Connection…” button at the top."));
            OpenConnection();
            return;
        }
        if (_busy) return;
        _busy = true;
        RefreshButtons();
        try
        {
            var result = await Task.Run(() => Uploader.Upload(Api.From(_settings), _library, _plan, SetStatus));
            SetStatus(Lang.F("План у «Слові»: пунктів {0}", "The plan is in Slovo: {0} items", result.Added));
            var help = Lang.T("План проповіді тепер головний у «Слові». Гортайте «Далі» / «Назад» або клацайте пункти плану. Коли закінчите — «Повернути план служіння».",
                              "The sermon plan is now the main plan in Slovo. Use “Next” / “Back” or click plan items. When finished — “Restore the service plan”.");
            if (result.Notes.Count > 0) help += "\n\n" + string.Join("\n", result.Notes);
            await Ui.Message(this, Lang.F("План у «Слові»: пунктів {0}", "The plan is in Slovo: {0} items", result.Added), help);
            // Керування — у робочому місці: там і зал, і план, і кнопки показу.
            Uploaded?.Invoke();
            Close();
        }
        catch (Exception error)
        {
            SetStatus(Lang.F("Не вдалося: {0}", "Failed: {0}", Api.Describe(error)));
            Paths.Say("завантаження плану: " + error);
        }
        finally
        {
            _busy = false;
            RefreshButtons();
        }
    }
}
