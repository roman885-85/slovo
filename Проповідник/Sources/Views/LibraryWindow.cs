// =============================================================================
//  LibraryWindow.cs — переклади й пісенники «Проповідника»
// =============================================================================
//  Як «Переклади й пісенники» на планшеті: зі «Слова» (потрібне підключення),
//  з GitHub (модулі «Цитати з Біблії», потрібен інтернет) і з файла
//  (zip «Цитати з Біблії», MyBible .SQLite3, пісенник .vbm чи .songbook).
// =============================================================================

using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Propovidnyk.Views;

public sealed class LibraryWindow : Window
{
    readonly Library _library;
    readonly Settings _settings;
    readonly ListBox _list;
    readonly TextBlock _status;
    readonly Button _fromSlovo, _fromGitHub, _fromFile, _remove;
    bool _busy;

    sealed record Row(Module Module, string Text);

    public LibraryWindow(Library library, Settings settings)
    {
        _library = library;
        _settings = settings;
        Title = Lang.T("Переклади й пісенники", "Translations and songbooks");
        Width = 760;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _list = new ListBox
        {
            ItemTemplate = new FuncDataTemplate<Row>((row, _) => new TextBlock { Text = row?.Text ?? "", TextWrapping = TextWrapping.Wrap }),
        };
        _list.SelectionChanged += (_, _) => _remove!.IsEnabled = !_busy && _list.SelectedItem != null;
        _status = new TextBlock { Foreground = Ui.Muted, TextWrapping = TextWrapping.Wrap };
        _fromSlovo = Ui.Button(Lang.T("Зі «Слова»", "From Slovo"), async () => await Take(FromSlovo),
                               Lang.T("Переклади й пісенники, які є в програмі (потрібне підключення)", "Translations and songbooks that Slovo has (a connection is needed)"), accent: true);
        _fromGitHub = Ui.Button(Lang.T("З GitHub", "From GitHub"), async () => await Take(FromGitHub),
                                Lang.T("Переклади з каталогу модулів «Цитати з Біблії» (потрібен інтернет)", "Translations from the Bible Quote module catalogue (internet is needed)"));
        _fromFile = Ui.Button(Lang.T("З файла…", "From a file…"), async () => await FromFile(),
                              Lang.T("zip «Цитати з Біблії», MyBible .SQLite3, пісенник .vbm чи .songbook", "Bible Quote .zip, MyBible .SQLite3, .vbm or .songbook songbook"));
        _remove = Ui.Button(Lang.T("Прибрати", "Remove"), async () => await Remove());
        _remove.IsEnabled = false;

        var top = new StackPanel { Spacing = 8, Margin = new Thickness(0, 0, 0, 8) };
        top.Children.Add(Ui.Hint(Lang.T(
            "З цими перекладами й пісенниками план складається без зв'язку. Чого в «Слові» на служінні не виявиться, «Проповідник» відвезе туди сам (для модулів з GitHub і з файла).",
            "Plans are built offline with these translations and songbooks. Whatever Slovo lacks during the service, the Preacher brings along itself (for modules from GitHub and from files).")));
        top.Children.Add(Ui.Row(_fromSlovo, _fromGitHub, _fromFile));
        var bottom = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(_remove, Dock.Right);
        bottom.Children.Add(_remove);
        bottom.Children.Add(_status);

        var root = new DockPanel { Margin = new Thickness(14) };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        root.Children.Add(top);
        root.Children.Add(bottom);
        root.Children.Add(new Border { Child = _list, BorderBrush = Ui.Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6) });
        Content = root;
        Reload();
    }

    void Reload()
    {
        string Source(string s) => s switch
        {
            "slovo" => Lang.T("зі «Слова»", "from Slovo"),
            "github" => Lang.T("з GitHub", "from GitHub"),
            _ => Lang.T("з файла", "from a file"),
        };
        var rows = new List<Row>();
        foreach (var module in _library.Modules(Library.Bible))
            rows.Add(new Row(module, $"📖  {module.Name}  ·  {Source(module.Source)}  ·  " + Lang.F("віршів {0}", "verses {0}", _library.Count("verses", module.Id))));
        foreach (var module in _library.Modules(Library.Songs))
            rows.Add(new Row(module, $"🎵  {module.Name}  ·  {Source(module.Source)}  ·  " + Lang.F("пісень {0}", "songs {0}", _library.Count("songs", module.Id))));
        _list.ItemsSource = rows;
        if (rows.Count == 0) _status.Text = Lang.T("Бібліотека порожня — додайте переклад чи пісенник", "The library is empty — add a translation or a songbook");
    }

    void Busy(bool busy)
    {
        _busy = busy;
        _fromSlovo.IsEnabled = _fromGitHub.IsEnabled = _fromFile.IsEnabled = !busy;
        _remove.IsEnabled = !busy && _list.SelectedItem != null;
    }

    void Status(string text) => Dispatcher.UIThread.Post(() => _status.Text = text);

    async Task<(List<Offer>, Func<Offer, Task>)?> FromSlovo()
    {
        if (!_settings.HasHost)
        {
            await Ui.Message(this, Title!, Lang.T("Спершу підключіться до «Слова»: «Підключення…» у головному вікні.", "Connect to Slovo first: “Connection…” in the main window."));
            return null;
        }
        Status(Lang.T("Питаю «Слово», що в нього є…", "Asking Slovo what it has…"));
        var api = Api.From(_settings);
        var offer = await Sources.FromSlovo(api, _library);
        return (offer, item => Sources.TakeFromSlovo(api, _library, item));
    }

    async Task<(List<Offer>, Func<Offer, Task>)?> FromGitHub()
    {
        Status(Lang.T("Читаю список модулів на GitHub…", "Reading the module list on GitHub…"));
        var offer = await Sources.FromGitHub(_library);
        return (offer, item => Sources.TakeFromGitHub(_library, item));
    }

    async Task Take(Func<Task<(List<Offer>, Func<Offer, Task>)?>> source)
    {
        if (_busy) return;
        Busy(true);
        try
        {
            var found = await source();
            if (found == null) return;
            var (offer, take) = found.Value;
            Status("");
            if (offer.Count == 0)
            {
                Status(Lang.T("Нового немає — усе вже в бібліотеці", "Nothing new — everything is already in the library"));
                return;
            }
            var chosen = await ChooseWindow.Choose(this, offer);
            var done = new List<string>();
            foreach (var item in chosen)
            {
                Status(Lang.F("Завантажую «{0}»…", "Loading “{0}”…", item.Name));
                try
                {
                    await Task.Run(() => take(item));
                    done.Add(item.Name);
                }
                catch (Exception error)
                {
                    Status(Lang.F("Не вдалося: {0}", "Failed: {0}", item.Name + ": " + Api.Describe(error)));
                    Paths.Say("бібліотека: " + item.Name + ": " + error);
                }
            }
            Reload();
            if (done.Count > 0) Status(Lang.F("Додано: {0}", "Added: {0}", string.Join(", ", done)));
        }
        catch (Exception error)
        {
            Status(Lang.F("Не вдалося: {0}", "Failed: {0}", Api.Describe(error)));
        }
        finally
        {
            Busy(false);
        }
    }

    async Task FromFile()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            AllowMultiple = true,
            Title = Lang.T("Модуль перекладу чи пісенник", "A translation module or a songbook"),
            FileTypeFilter = new[]
            {
                new FilePickerFileType(Lang.T("Модулі й пісенники", "Modules and songbooks"))
                {
                    Patterns = new[] { "*.zip", "*.sqlite3", "*.SQLite3", "*.vbm", "*.songbook" },
                },
                FilePickerFileTypes.All,
            },
        });
        if (files.Count == 0) return;
        Busy(true);
        var done = new List<string>();
        foreach (var file in files)
        {
            if (file.TryGetLocalPath() is not { } path) continue;
            Status(Lang.F("Завантажую «{0}»…", "Loading “{0}”…", file.Name));
            try
            {
                await Task.Run(() => Sources.ImportFile(_library, path));
                done.Add(file.Name);
            }
            catch (Exception error)
            {
                Status(Lang.F("Не вдалося: {0}", "Failed: {0}", file.Name + ": " + error.Message));
            }
        }
        Reload();
        if (done.Count > 0) Status(Lang.F("Додано: {0}", "Added: {0}", string.Join(", ", done)));
        Busy(false);
    }

    async Task Remove()
    {
        if (_list.SelectedItem is not Row row) return;
        if (!await Ui.Ask(this, Title!, Lang.F("Прибрати «{0}» з бібліотеки?", "Remove “{0}” from the library?", row.Module.Name), Lang.T("Прибрати", "Remove"))) return;
        _library.Delete(row.Module.Id);
        Reload();
    }
}

/// Вибір того, що взяти: пошук і галочки.
public sealed class ChooseWindow : Window
{
    readonly List<(Offer Offer, CheckBox Box)> _rows = new();
    List<Offer> _chosen = new();

    ChooseWindow(List<Offer> offer)
    {
        Title = Lang.T("Що взяти в бібліотеку", "What to take into the library");
        Width = 640;
        Height = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var search = new TextBox { Watermark = Lang.T("Пошук за назвою", "Search by name") };
        var list = new StackPanel { Spacing = 2 };
        foreach (var item in offer)
        {
            var kind = item.Kind == Library.Bible ? Lang.T("Біблія", "Bible") : Lang.T("Пісенник", "Songbook");
            var box = new CheckBox { Content = kind + " · " + item.Name };
            _rows.Add((item, box));
            list.Children.Add(box);
        }
        search.TextChanged += (_, _) =>
        {
            var wanted = Library.Fold(search.Text);
            foreach (var (item, box) in _rows) box.IsVisible = wanted.Length == 0 || Library.Fold(item.Name).Contains(wanted);
        };
        var take = Ui.Button(Lang.T("Взяти", "Take"), () =>
        {
            _chosen = _rows.Where(r => r.Box.IsChecked == true).Select(r => r.Offer).ToList();
            Close();
        }, accent: true);
        take.IsDefault = true;
        var cancel = Ui.Button(Lang.T("Скасувати", "Cancel"), Close);
        cancel.IsCancel = true;
        var buttons = Ui.Row(cancel, take);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 10, 0, 0);
        var root = new DockPanel { Margin = new Thickness(14) };
        search.Margin = new Thickness(0, 0, 0, 8);
        DockPanel.SetDock(search, Dock.Top);
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(search);
        root.Children.Add(buttons);
        root.Children.Add(new ScrollViewer { Content = list });
        Content = root;
    }

    public static async Task<List<Offer>> Choose(Window owner, List<Offer> offer)
    {
        var window = new ChooseWindow(offer);
        await window.ShowDialog(owner);
        return window._chosen;
    }
}
