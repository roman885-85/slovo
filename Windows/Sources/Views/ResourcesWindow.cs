// =============================================================================
//  ResourcesWindow.cs — переклади, пісенники, фони й шаблони: звідки взяти
// =============================================================================
//  Чотири шляхи, як на Mac: ресурси «Слова» на GitHub (переклади, пісенники,
//  фони, шаблони, шрифти), модулі «Цитата з Біблії», «Слово» в мережі (інший
//  комп'ютер зі «Словом»), файл чи тека з диска (у тому числі тека VisioBible).
// =============================================================================

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Slovo.Views;

public sealed class ResourcesWindow : Window
{
    readonly AppState _state;
    readonly MainWindow _owner;
    readonly TextBlock _status = new() { Foreground = Ui.Muted, TextWrapping = TextWrapping.Wrap };
    readonly CancellationTokenSource _closing = new();

    public ResourcesWindow(AppState state, MainWindow owner)
    {
        _state = state;
        _owner = owner;
        Title = Lang.T("Переклади, пісенники, фони, шаблони", "Translations, songbooks, backgrounds, templates");
        Width = 820;
        Height = 620;
        MinWidth = 640;
        MinHeight = 440;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var tabs = new TabControl();
        tabs.Items.Add(new TabItem { Header = Lang.T("Ресурси «Слова»", "Slovo resources"), Content = BuildCatalog(true) });
        tabs.Items.Add(new TabItem { Header = Lang.T("«Цитата з Біблії»", "Bible Quote"), Content = BuildCatalog(false) });
        tabs.Items.Add(new TabItem { Header = Lang.T("«Слово» в мережі", "Slovo on the network"), Content = BuildFromSlovo() });
        tabs.Items.Add(new TabItem { Header = Lang.T("З файла чи теки", "From a file or folder"), Content = BuildFromDisk() });
        var root = new DockPanel { Margin = new Thickness(12) };
        _status.Margin = new Thickness(0, 8, 0, 0);
        DockPanel.SetDock(_status, Dock.Bottom);
        root.Children.Add(_status);
        root.Children.Add(tabs);
        Content = root;
        Closing += (_, _) => _closing.Cancel();
    }

    void Say(string text) => Avalonia.Threading.Dispatcher.UIThread.Post(() => _status.Text = text);

    void Adopt(ImportResult result)
    {
        _owner.AdoptImport(result);
        Say(result.Summary() + (result.Failures.Count > 0 ? "\n" + string.Join("\n", result.Failures) : ""));
    }

    // MARK: Каталоги

    Control BuildCatalog(bool slovo)
    {
        var list = new ListBox { SelectionMode = SelectionMode.Multiple };
        var filter = new TextBox { Watermark = Lang.T("Відбір за назвою чи мовою", "Filter by title or language"), Width = 260 };
        var kindBox = new ComboBox { Width = 170 };
        foreach (var (key, title) in new[] { ("", Lang.T("Усе", "All")), ("bible", Lang.T("Переклади", "Translations")), ("songbook", Lang.T("Пісенники", "Songbooks")), ("backgrounds", Lang.T("Фони", "Backgrounds")), ("templates", Lang.T("Шаблони", "Templates")), ("fonts", Lang.T("Шрифти", "Fonts")) })
            kindBox.Items.Add(new ComboBoxItem { Content = title, Tag = key });
        kindBox.SelectedIndex = 0;
        kindBox.IsVisible = slovo;
        var items = new List<ResourceItem>();
        var installed = new HashSet<string>();
        void Fill()
        {
            var needle = (filter.Text ?? "").Trim().ToLowerInvariant();
            var kind = (kindBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
            var shown = items.Where(i => (kind.Length == 0 || i.Kind == kind) && (needle.Length == 0 || i.Title.ToLowerInvariant().Contains(needle) || i.Subtitle.ToLowerInvariant().Contains(needle) || i.Language.ToLowerInvariant().Contains(needle))).ToList();
            list.ItemsSource = shown.Select(i => new ListBoxItem
            {
                Content = (installed.Contains(i.Id) ? "✓ " : "") + KindMark(i.Kind) + " " + i.Title + (i.Subtitle.Length > 0 ? " — " + i.Subtitle : "") + (i.Language.Length > 0 ? "  [" + i.Language + "]" : "") + (i.Size > 0 ? "  " + Math.Max(1, i.Size / 1_000_000) + " МБ" : ""),
                Tag = i,
            }).ToList();
        }
        filter.TextChanged += (_, _) => Fill();
        kindBox.SelectionChanged += (_, _) => Fill();
        var reload = Ui.Button(Lang.T("Завантажити список", "Load the list"), async () =>
        {
            Say(Lang.T("Питаю GitHub…", "Asking GitHub…"));
            try
            {
                items = slovo ? await ResourceStore.SlovoCatalog(_closing.Token) : await ResourceStore.BibleQuoteCatalog(_closing.Token);
                MarkInstalled();
                Fill();
                Say(Lang.F("У каталозі {0} ресурсів. Виберіть потрібні й натисніть «Установити».", "The catalog has {0} resources. Choose the ones you need and press Install.", items.Count));
            }
            catch (Exception error) { Say(Lang.T("GitHub не відповів: ", "GitHub did not answer: ") + error.Message); }
        }, accent: true);
        void MarkInstalled()
        {
            installed.Clear();
            foreach (var module in _state.AllModules.Concat(_state.SongBooks))
            {
                var stem = module.Id.Contains(':') ? module.Id[(module.Id.IndexOf(':') + 1)..] : module.Id;
                foreach (var item in items)
                    if (item.FileName.Length > 0 && (stem.Equals(item.FileName, StringComparison.OrdinalIgnoreCase) || stem.Equals(System.IO.Path.GetFileNameWithoutExtension(item.FileName), StringComparison.OrdinalIgnoreCase)
                        || System.IO.Path.GetFileNameWithoutExtension(stem).Equals(System.IO.Path.GetFileNameWithoutExtension(item.FileName), StringComparison.OrdinalIgnoreCase)))
                        installed.Add(item.Id);
            }
        }
        var install = Ui.Button(Lang.T("Установити вибране", "Install the chosen"), async () =>
        {
            var chosen = list.SelectedItems?.OfType<ListBoxItem>().Select(i => i.Tag as ResourceItem).Where(i => i != null).Select(i => i!).ToList() ?? new List<ResourceItem>();
            if (chosen.Count == 0) { Say(Lang.T("Нічого не вибрано.", "Nothing is chosen.")); return; }
            var total = new ImportResult();
            foreach (var item in chosen)
            {
                var one = await ResourceStore.Install(_state.Library, item, Say, _closing.Token);
                total.Modules.AddRange(one.Modules); total.Names.AddRange(one.Names); total.Failures.AddRange(one.Failures);
                total.Templates += one.Templates; total.Backgrounds += one.Backgrounds; total.Fonts += one.Fonts;
            }
            Adopt(total);
            MarkInstalled();
            Fill();
        }, accent: true);
        var all = Ui.Button(Lang.T("Вибрати все показане", "Select all shown"), () => { list.SelectAll(); });
        var head = Ui.Row(reload, filter, kindBox, all, install);
        var panel = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        panel.Children.Add(head);
        var hint = Ui.Hint(slovo
            ? Lang.T("Каталог roman885-85/slovo-resources: переклади й пісенники з пакета «Слова», фони, шаблони .sch і шрифти. Установлене позначено ✓.", "Catalog roman885-85/slovo-resources: translations and songbooks from Slovo's package, backgrounds, .sch templates and fonts. Installed ones are marked ✓.")
            : Lang.T("Модулі «Цитата з Біблії» (BibleQuote/BibleQuote-Modules на GitHub) — лише переклади Біблії.", "Bible Quote modules (BibleQuote/BibleQuote-Modules on GitHub) — Bible translations only."));
        DockPanel.SetDock(hint, Dock.Top);
        panel.Children.Add(hint);
        panel.Children.Add(list);
        return panel;
    }

    static string KindMark(string kind) => kind switch { "bible" => "📖", "songbook" => "🎵", "backgrounds" => "🖼", "templates" => "🎨", "fonts" => "🔤", _ => "•" };

    // MARK: «Слово» в мережі

    Control BuildFromSlovo()
    {
        var host = new TextBox { Width = 180, Watermark = Lang.T("адреса", "address") };
        var port = new TextBox { Width = 70, Text = "8103" };
        var pin = new TextBox { Width = 90, Watermark = "PIN" };
        var found = new ComboBox { Width = 260 };
        var list = new ListBox { SelectionMode = SelectionMode.Multiple };
        var offers = new List<ResourceStore.SlovoOffer>();
        found.SelectionChanged += (_, _) =>
        {
            if (found.SelectedItem is ComboBoxItem item && item.Tag is FoundSlovo f) { host.Text = f.Host; port.Text = f.Port.ToString(); }
        };
        var search = Ui.Button(Lang.T("Шукати в мережі", "Search the network"), async () =>
        {
            Say(Lang.T("Шукаю «Слово» в мережі…", "Looking for Slovo on the network…"));
            var list2 = await Discovery.Search(_closing.Token);
            found.Items.Clear();
            foreach (var f in list2) found.Items.Add(new ComboBoxItem { Content = f.Name + " — " + f.Host + ":" + f.Port, Tag = f });
            if (found.Items.Count > 0) found.SelectedIndex = 0;
            Say(list2.Count == 0 ? Lang.T("Не знайшлося — введіть адресу вручну (видно в «Слові»: Параметри → Remote API).", "Nothing found — enter the address by hand (shown in Slovo: Settings → Remote API).") : Lang.F("Знайдено: {0}", "Found: {0}", list2.Count));
        });
        var ask = Ui.Button(Lang.T("Що є у «Слові»", "What Slovo has"), async () =>
        {
            try
            {
                Say(Lang.T("Питаю «Слово»…", "Asking Slovo…"));
                offers = await ResourceStore.FromSlovo(host.Text?.Trim() ?? "", int.TryParse(port.Text, out var p) ? p : 8103, pin.Text ?? "", _closing.Token);
                var mine = _state.AllModules.Select(m => m.Name).Concat(_state.SongBooks.Select(b => b.Name)).ToHashSet(StringComparer.OrdinalIgnoreCase);
                list.ItemsSource = offers.Select(o => new ListBoxItem { Content = (mine.Contains(o.Name) ? "✓ " : "") + (o.Kind == "bible" ? "📖 " : "🎵 ") + o.Name + "  (" + o.Count + ")", Tag = o }).ToList();
                Say(Lang.F("У «Слові» {0} перекладів і пісенників; ✓ — такі вже є тут.", "Slovo has {0} translations and songbooks; ✓ — already here.", offers.Count));
            }
            catch (Exception error) { Say(Lang.T("Не вдалося: ", "Failed: ") + error.Message); }
        }, accent: true);
        var take = Ui.Button(Lang.T("Забрати вибране", "Take the chosen"), async () =>
        {
            var chosen = list.SelectedItems?.OfType<ListBoxItem>().Select(i => i.Tag as ResourceStore.SlovoOffer).Where(o => o != null).Select(o => o!).ToList() ?? new List<ResourceStore.SlovoOffer>();
            if (chosen.Count == 0) { Say(Lang.T("Нічого не вибрано.", "Nothing is chosen.")); return; }
            var result = new ImportResult();
            foreach (var offer in chosen)
            {
                try
                {
                    Say(Lang.F("Забираю «{0}»…", "Taking “{0}”…", offer.Name));
                    var id = await ResourceStore.TakeFromSlovo(_state.Library, host.Text?.Trim() ?? "", int.TryParse(port.Text, out var p) ? p : 8103, pin.Text ?? "", offer, _closing.Token);
                    result.Modules.Add(id); result.Names.Add(offer.Name);
                }
                catch (Exception error) { result.Failures.Add(offer.Name + ": " + error.Message); }
            }
            Adopt(result);
        }, accent: true);
        var panel = new DockPanel();
        var head = Column(
            Ui.Hint(Lang.T("Інший комп'ютер зі «Словом» (Mac чи Windows) віддає свої переклади й пісенники по мережі — так бібліотека церкви переїжджає за хвилину. У «Слові» має бути ввімкнено пульт (Параметри → Remote API).",
                           "Another computer with Slovo (Mac or Windows) gives away its translations and songbooks over the network — the church library moves in a minute. The remote must be on in Slovo (Settings → Remote API).")),
            Ui.Row(search, found),
            Ui.Row(Ui.Label(Lang.T("Адреса", "Address")), host, Ui.Label(Lang.T("порт", "port")), port, pin, ask),
            take);
        DockPanel.SetDock(head, Dock.Top);
        panel.Children.Add(head);
        panel.Children.Add(list);
        return panel;
    }

    // MARK: З диска

    Control BuildFromDisk()
    {
        var file = Ui.Button(Lang.T("Файл…", "File…"), async () =>
        {
            var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = Lang.T("Модуль (zip, .SQLite3), пісенник (.vbm, .songbook), шаблон (.sch) чи картинка", "A module (zip, .SQLite3), songbook (.vbm, .songbook), template (.sch) or picture") });
            var total = new ImportResult();
            foreach (var f in files)
            {
                var path = f.TryGetLocalPath();
                if (path == null) continue;
                Say(System.IO.Path.GetFileName(path));
                var one = await Task.Run(() => ResourceStore.ImportFile(_state.Library, path));
                total.Modules.AddRange(one.Modules); total.Names.AddRange(one.Names); total.Failures.AddRange(one.Failures);
                total.Templates += one.Templates; total.Backgrounds += one.Backgrounds; total.Fonts += one.Fonts;
            }
            Adopt(total);
        }, accent: true);
        var folder = Ui.Button(Lang.T("Тека VisioBible або тека з модулями…", "A VisioBible folder or a folder with modules…"), async () =>
        {
            var folders = await StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = Lang.T("Тека", "Folder") });
            var path = folders.FirstOrDefault()?.TryGetLocalPath();
            if (path == null) return;
            var result = await Task.Run(() => ResourceStore.ImportFolder(_state.Library, path, "folder", Say));
            Adopt(result);
        }, accent: true);
        return Column(
            Ui.Hint(Lang.T("З файла: zip-модуль «Цитати з Біблії», модуль MyBible .SQLite3, пісенник VisioBible .vbm чи пісенник «Слова» .songbook, шаблон .sch (разом із текою картинок поруч), картинка для фону.",
                           "From a file: a Bible Quote zip module, a MyBible .SQLite3 module, a VisioBible .vbm songbook or a Slovo .songbook, a .sch template (with its picture folder next to it), a picture for a background.")),
            file,
            Ui.Hint(Lang.T("З теки: встановлений VisioBible (теки Modules, Templates, BackGrounds, Fonts) або будь-яка тека з модулями й пісенниками — усе береться разом. Файли копіюються в теку даних програми; VisioBible не чіпається.",
                           "From a folder: an installed VisioBible (Modules, Templates, BackGrounds, Fonts) or any folder with modules and songbooks — everything is taken together. Files are copied into the program's data folder; VisioBible is not touched.")),
            folder);
    }

    static StackPanel Column(params Control[] children)
    {
        var stack = new StackPanel { Spacing = 8 };
        foreach (var child in children) stack.Children.Add(child);
        return stack;
    }
}
