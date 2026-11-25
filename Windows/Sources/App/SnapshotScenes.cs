// =============================================================================
//  SnapshotScenes.cs — що саме знімати (--snapshot)
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public static class SnapshotScenes
{
    static bool _done;

    public static void Register()
    {
        if (_done) return;
        _done = true;
        Snapshot.Scenes.Add(("конструктор", () => SlideConstructorWindow.Open(AppState.Shared), new Size(1240, 780)));
        Snapshot.Scenes.Add(("стиль", () => InterfaceStyleWindow.Open(AppState.Shared), new Size(460, 430)));
        Snapshot.Scenes.Add(("мова", () => LanguagePickerWindow.Open(), new Size(340, 460)));
        // «Переклад інтерфейсу» (1180×820, найменше 1060×700 — знімки туру Mac slovo-тур-перевод і -мин).
        Snapshot.Scenes.Add(("переклад", () => LocalizeWindow.Open(AppState.Shared), new Size(1180, 820)));
        Snapshot.Scenes.Add(("переклад-мин", () => LocalizeWindow.Open(AppState.Shared), new Size(1060, 700)));
        // «Нумерація» (1060×720, найменше 1000×660 — знімки туру Mac slovo-тур-нумерация і -мин).
        // Вікну потрібна бібліотека (переклади й книги) — без головного вікна її ніхто не читає.
        Snapshot.Scenes.Add(("нумерація", () => { AppState.Shared.ReloadLibrary(); return NumberingEditorWindow.Open(AppState.Shared); }, new Size(1060, 720)));
        Snapshot.Scenes.Add(("нумерація-мин", () => { AppState.Shared.ReloadLibrary(); return NumberingEditorWindow.Open(AppState.Shared); }, new Size(1000, 660)));
        // Вікно правки правила: зсув вірша Пс 9:22… на +1 у парі ru → en.
        Snapshot.Scenes.Add(("правило-нумерації", () =>
        {
            AppState.Shared.ReloadLibrary();
            Snapshot.WaitForLibrary();
            var model = new NumberingEditorModel(AppState.Shared);
            var draft = model.NewDraft();
            draft.From = "ru"; draft.To = "en"; draft.Book = 230; draft.ChapterBegin = 9; draft.VerseBegin = 22; draft.VerseTo = 1;
            return NumberingRuleSheet.Ask(new Window(), model, draft, () => { });
        }, new Size(520, 330)));
        Snapshot.Scenes.Add(("списки", ListsDemo, new Size(900, 420)));
        // Поля введення всіх видів — із вставленим текстом; ключ --focus N ставить курсор у N-те
        // (власник 24.11: «часть окон и меню в которых вставляется текст сливаются с фоном»).
        Snapshot.Scenes.Add(("поля", FieldsDemo, new Size(640, 560)));
        // Як головне вікно Mac у знімку туру (1920×1074) — плюс рядок меню, що на Windows у вікні.
        Snapshot.Scenes.Add(("заставка", () => Splash.MakeForCheck("Открываю библиотеку переводов…"), new Size(460, 260)));
        Snapshot.Scenes.Add(("головне", () => new MainWindow(AppState.Shared), new Size(1920, 1074 + RootView.Metrics.MenuBar)));
        Snapshot.Scenes.Add(("параметри", () => { var w = new SettingsWindow(); w.BuildTabs(SettingsStore.Shared); return w; }, new Size(1180, 913)));
        Snapshot.Scenes.Add(("пульт-у-браузері", () => BrowserRemoteWindow.Open(), new Size(680, 480)));
        Snapshot.Scenes.Add(("android", () => AndroidAppsWindow.Open(), new Size(640, 470)));
        // «Ресурси з GitHub» (760×560, найменше 620×420) і майстер імпорту (940×660, найменше
        // 820×560 — як знімки туру Mac slovo-тур-мастер і -мин). Кроки — ключами запуску
        // (--resources-…, --import-source, --wizard-page, --wizard-run): див. ISnapshotWork.
        Snapshot.Scenes.Add(("ресурси", () => ResourcesWindow.Open(Array.IndexOf(Environment.GetCommandLineArgs(), "--resources-updates") >= 0), new Size(760, 560)));
        Snapshot.Scenes.Add(("ресурси-мин", () => ResourcesWindow.Open(), new Size(620, 420)));
        Snapshot.Scenes.Add(("майстер", () => ImportWizardWindow.Open() ?? new Window(), new Size(940, 660)));
        Snapshot.Scenes.Add(("майстер-мин", () => ImportWizardWindow.Open() ?? new Window(), new Size(820, 560)));
        // Редактор веб-слайдів (1240×760 — знімок туру Mac slovo-тур-веб-редактор; «-мин» тур знімає
        // з рамкою найменшого вікна: вміст 720×488). Кроки — ключами --web-page <ім'я>,
        // --web-section 0…4, --web-markup (WebSlideEditorWindow.Begin).
        Snapshot.Scenes.Add(("веб-редактор", () => WebSlideEditorWindow.Open(AppState.Shared), new Size(1240, 760)));
        Snapshot.Scenes.Add(("веб-редактор-мин", () => WebSlideEditorWindow.Open(AppState.Shared), new Size(720, 488)));
    }

    sealed class Demo : IRowSource
    {
        readonly List<Row> _rows;
        public Demo(List<Row> rows) => _rows = rows;
        public int RowCount => _rows.Count;
        public Row RowAt(int index) => _rows[index];
    }

    /// Перевірка списку: вірші (висота за текстом), плитки книг, розділи.
    static Window ListsDemo()
    {
        var verses = new List<Row>();
        string[] texts =
        {
            "На початку створив Бог небо та землю.",
            "Земля ж була пустою та порожньою, і темрява була над безоднею, і Дух Божий ширяв над поверхнею води.",
            "І сказав Бог: Нехай буде світло! І постало світло.",
            "І побачив Бог світло, що воно добре, – і відділив Бог світло від темряви.",
        };
        for (var i = 0; i < 24; i++)
            verses.Add(new Row(texts[i % texts.Length], (i + 1).ToString()) { Rule = (i + 1) % 10 == 0 ? Color.FromRgb(0xE0, 0x80, 0x80) : null });
        var versesList = new RowList(ListMetrics.Verses(), 14) { Source = new Demo(verses) };
        versesList.SetMeasuredHeights(22);
        versesList.SetSelection(new[] { 0 }, 0);

        string[,] books = { { "Бут.", "Буття" }, { "Вих.", "Вихід" }, { "Лев.", "Левит" }, { "Чис.", "Числа" }, { "Повт.", "Повторення Закону" }, { "Іс.Навин.", "Книга Ісуса Навина" } };
        var bookRows = new List<Row>();
        for (var i = 0; i < books.GetLength(0); i++)
            bookRows.Add(new Row(books[i, 1], books[i, 0]) { TextColor = i < 5 ? Color.FromRgb(0x1F, 0x3A, 0x8A) : Color.FromRgb(0x2E, 0x7D, 0x32) });
        var bookList = new RowList(ListMetrics.Books(), 14) { Source = new Demo(bookRows) };
        bookList.SetTiles(74, 40, 4);
        bookList.SetSelection(new[] { 0 }, 0);

        var chapters = Enumerable.Range(1, 50).Select(n => new Row(n.ToString())).ToList();
        var chapterList = new RowList(ListMetrics.Chapters(), 14) { Source = new Demo(chapters) };
        chapterList.SetUniformHeight(22);
        chapterList.SetSelection(new[] { 0 }, 0);

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("260,80,*"), Background = Palette.Brush(Palette.WindowBackground) };
        Grid.SetColumn(bookList, 0); Grid.SetColumn(chapterList, 1); Grid.SetColumn(versesList, 2);
        bookList.Margin = new Thickness(0, 0, 1, 0); chapterList.Margin = new Thickness(0, 0, 1, 0);
        grid.Children.Add(bookList); grid.Children.Add(chapterList); grid.Children.Add(versesList);
        return new Window { Content = grid, Title = "списки" };
    }

    /// Вітрина полів введення: швидке поле, поле «Параметрів», поле вікна посилань, редактор
    /// слів пісні, поле розмітки веб-слайда, поле пошуку в Тексті. Курсор — у поле з номером
    /// `--focus N` (з одиниці), щоб побачити, як тема малює поле у фокусі.
    static Window FieldsDemo()
    {
        var links = "https://www.youtube.com/watch?v=M07ezmR1FII\nhttps://youtu.be/IjjWtx2At1U";
        var quick = new QuickField(11) { Height = 22, Width = 300 };
        quick.Text = "Ів 3:16";
        var form = new FormField(13) { Height = 24, Width = 120 };
        form.Text = "350";
        var lines = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 70, FontSize = 12, FontFamily = UiFont.Family, Text = links,
            Background = Palette.Brush(Palette.TextBackground), Foreground = Palette.Brush(Palette.Label),
            BorderBrush = Palette.Brush(Palette.Separator), BorderThickness = new Thickness(1), Padding = new Thickness(4),
        };
        var lyrics = new LyricsEditor("Куплет 1\nВеликий Бог, коли на світ дивлюся я", true, AppState.Shared.SongPalette) { Height = 70 };
        var markup = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, Height = 60, Text = "<div class=\"slide\">{{text}}</div>",
            FontFamily = new FontFamily("Cascadia Mono,Consolas,Menlo,monospace"), FontSize = 12,
            BorderThickness = new Thickness(0), Padding = new Thickness(4),
        };
        var plain = new TextBox { Text = "звичайне поле теми", Width = 300 };
        var fields = new Control[] { quick, form, lines, lyrics.Box, markup, plain };
        var panel = new StackPanel { Margin = new Thickness(16), Spacing = 10 };
        panel.Children.Add(new TextBlock { Text = "1 · швидке поле (QuickField)", FontSize = 11 });
        panel.Children.Add(quick);
        panel.Children.Add(new TextBlock { Text = "2 · поле «Параметрів» (FormField)", FontSize = 11 });
        panel.Children.Add(form);
        panel.Children.Add(new TextBlock { Text = "3 · вікно «Додати посилання» (TextBox)", FontSize = 11 });
        panel.Children.Add(lines);
        panel.Children.Add(new TextBlock { Text = "4 · слова пісні (LyricsEditor)", FontSize = 11 });
        panel.Children.Add(lyrics);
        panel.Children.Add(new TextBlock { Text = "5 · розмітка веб-слайда (TextBox теми)", FontSize = 11 });
        panel.Children.Add(markup);
        panel.Children.Add(new TextBlock { Text = "6 · звичайне поле теми", FontSize = 11 });
        panel.Children.Add(plain);
        var window = new Window { Title = "Поля", Background = Palette.Brush(Palette.WindowBackground), Content = panel };
        var args = Environment.GetCommandLineArgs();
        var at = Array.IndexOf(args, "--focus");
        if (at >= 0 && at + 1 < args.Length && int.TryParse(args[at + 1], out var n) && n >= 1 && n <= fields.Length)
        {
            var target = fields[n - 1] is QuickField q ? q.Box : fields[n - 1];
            window.Opened += (_, _) => { window.Activate(); target.Focus(); };
        }
        return window;
    }
}
