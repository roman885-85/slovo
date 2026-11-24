// =============================================================================
//  UpdatePathsTabs.cs — вкладки «Оновлення» і «Шляхи» (як на Mac)
// =============================================================================
//  «Оновлення»: інтервал перевірки (ніколи/тиждень/місяць/рік), версія, перевірка
//  на GitHub, ресурси з GitHub.
//  «Шляхи»: де лежать дані (показати в Провіднику, скопіювати шлях), шляхи до
//  фонових малюнків (+ − ↳ і лічильник), тека знімків слайда, режим мініатюр.
// =============================================================================

using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class UpdateTab
{
    readonly SettingsStore _store;
    readonly TextBlock _version = Form.Label("", false), _result = Form.Label("");
    public UpdateTab(SettingsStore store) { _store = store; }
    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    public static Action? OpenResources, OpenResourceUpdates;

    public Control Page()
    {
        int[] days = { 0, 7, 30, 365 };
        var interval = new Form.Group(Vb("RGUpdateIntervals", "Интервал проверки обновлений"), new Control[]
        {
            new Form.Row("", new[] { Form.Choice(new[] { Vb("RGUpdateIntervals->Item0", "Никогда (отключить проверку)"), Vb("RGUpdateIntervals->Item1", "Неделя"),
                                                       Vb("RGUpdateIntervals->Item2", "Месяц"), Vb("RGUpdateIntervals->Item3", "Год") },
                new Tie<int>(() => Math.Max(0, Array.IndexOf(days, _store.Settings.Options.UpdateInterval)), i => _store.Settings.Options.UpdateInterval = days[Math.Min(i, days.Length - 1)])) }),
            new Form.Row("", new Control[] { Form.Label(Captions.T("При запуске программа спрашивает GitHub, вышла ли новая версия, не чаще выбранного интервала.")) }),
        });
        _version.Text = Captions.T("Версия %s (%s)", AppUpdater.CurrentVersion, "Windows");
        var program = new Form.Group(Captions.T("Программа"), new Control[]
        {
            new Form.Row("", new Control[] { _version }),
            new Form.Row("", new Control[]
            {
                Form.Button(Captions.T("Проверить обновление на GitHub"), Captions.T("Спросить GitHub сейчас, вышла ли новая версия, и предложить её установить"),
                            () => _ = AppUpdater.CheckNow(text => _result.Text = text)),
                _result,
            }),
        });
        var resources = new Form.Group(Captions.T("Ресурсы"), new Control[]
        {
            new Form.Row("", new Control[]
            {
                Form.Button(Captions.T("Ресурсы с GitHub…"), Captions.T("Переводы, песенники, фоны, шаблоны: загрузить новые и обновить загруженные"), () => OpenResources?.Invoke()),
                Form.Button(Captions.T("Обновить ресурсы…"), Captions.T("Отметить всё, что обновилось в каталоге"), () => OpenResourceUpdates?.Invoke()),
            }),
            new Form.Row("", new Control[] { Form.Label(Captions.T("Каталог: github.com/roman885-85/slovo-resources; переводы также из «Цитаты из Библии» на bqt.ru.")) }),
        });
        return new Form.Page(new[] { interval, program, resources });
    }
}

public sealed class PathsTab : IRowSource
{
    readonly SettingsStore _store;
    readonly RowList _list = new(ListMetrics.Settings(120), 13) { Height = 130, Width = 420 };
    readonly TextBlock _counter = Form.Label(""), _resolved = Form.Label("");
    FormField? _folder;
    int? _selected;

    public PathsTab(SettingsStore store)
    {
        _store = store;
        _list.SetUniformHeight(24);
        _list.Source = this;
        _list.OnSelect = (_, active, _) => _selected = active;
    }

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "SettingsForm") ?? Captions.T(fallback);

    public Control Page()
    {
        var page = new Form.Page(new[] { Home(), Pictures(), Screenshots(), Thumbs() });
        Refresh();
        return page;
    }

    Form.Group Home()
    {
        var path = new SelectableTextBlock { Text = DataHome.DisplayPath, FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, FontFamily = UiFont.Family };
        ToolTip.SetTip(path, DataHome.DisplayPath);
        return new Form.Group(Captions.T("Где лежат данные программы:"), new Control[]
        {
            new Form.Row("", new Control[] { path }, stretch: true),
            new Form.Row("", new Control[]
            {
                Form.Button(Captions.T("Показать в Проводнике"), Captions.T("Открыть в Проводнике папку, куда программа кладёт данные"), () => Explorer.Show(DataHome.Folder)),
                Form.Button(Captions.T("Скопировать путь"), Captions.T("Полный адрес папки с данными — в буфер обмена"),
                            () => _ = TopLevel.GetTopLevel(MainWindow.Shared)?.Clipboard?.SetTextAsync(DataHome.DisplayPath)),
            }),
            new Form.Row("", new Control[] { Form.Note(Captions.T("Здесь переводы, песенники, фоны, шаблоны, шрифты, планы, настройки и история. Папку можно перенести на другой компьютер целиком.")) }, stretch: true),
        });
    }

    Form.Group Pictures()
    {
        var buttons = new StackPanel { Spacing = 4 };
        buttons.Children.Add(Form.Button("+", Hint("SBAddPath", "Добавить путь..."), AddPath));
        buttons.Children.Add(Form.Button("−", Hint("SBDelPath", "Удалить путь..."), RemovePath));
        buttons.Children.Add(Form.Button("↳", Hint("SBSubFolder", "Искать во вложенных папках (Вкл/Выкл)"), ToggleSubfolders));
        return new Form.Group(Vb("Label2", Captions.T("Пути для фоновых рисунков:")), new Control[]
        {
            new Form.Row("", new Control[] { _list, buttons }, stretch: true),
            new Form.Row("", new Control[] { _counter }),
        });
    }

    Form.Group Screenshots()
    {
        _folder = Form.Text(new Tie<string>(() => _store.Settings.ScreenshotFolder, v => { _store.Settings.ScreenshotFolder = v; Refresh(); }), 380);
        return new Form.Group(Vb("Label20", Captions.T("Папка для снимков экрана слайда:")), new Control[]
        {
            new Form.Row("", new Control[] { _folder, Form.Button(Captions.T("Выбрать…"), Hint("PngSBAddScreenShotPath", "Выбрать путь..."), ChooseScreenshots) }),
            new Form.Row("", new Control[] { _resolved }),
        });
    }

    Form.Group Thumbs() => new(Vb("RGThumbsMode", "Режим миникартинок"), new Control[]
    {
        new Form.Row("", new[] { Form.Choice(new[] { Vb("RGThumbsMode->Item0", "Win Thumbs"), Vb("RGThumbsMode->Item1", Captions.T("Встроенный")) },
            new Tie<int>(() => _store.Settings.Options.ThumbsMode == ThumbsMode.System ? 0 : 1,
                         v => _store.Settings.Options.ThumbsMode = v == 0 ? ThumbsMode.System : ThumbsMode.BuiltIn)) }),
    });

    async void AddPath()
    {
        var top = TopLevel.GetTopLevel(SettingsWindow.Shared);
        if (top == null) return;
        var folders = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { AllowMultiple = true, Title = Vb("TextMessages4", "Выберите каталог фоновых рисунков") });
        foreach (var folder in folders)
        {
            if (folder.TryGetLocalPath() is not { } path) continue;
            var entry = new PicturePathEntry { Path = _store.RelativePath(path), ScansSubfolders = false };
            if (!_store.Settings.PicturePaths.Any(p => p.Path == entry.Path)) _store.Settings.PicturePaths.Add(entry);
        }
        _list.Reload();
        Refresh();
    }

    void RemovePath()
    {
        if (_selected is not { } i || i >= _store.Settings.PicturePaths.Count) return;
        _store.Settings.PicturePaths.RemoveAt(i);
        _selected = null;
        _list.Reload();
        Refresh();
    }

    void ToggleSubfolders()
    {
        if (_selected is not { } i || i >= _store.Settings.PicturePaths.Count) return;
        _store.Settings.PicturePaths[i].ScansSubfolders = !_store.Settings.PicturePaths[i].ScansSubfolders;
        _list.Reload();
    }

    async void ChooseScreenshots()
    {
        var top = TopLevel.GetTopLevel(SettingsWindow.Shared);
        if (top == null) return;
        var folders = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions { Title = Vb("TextMessages16", "Выберите папку для сохранения снимков экрана слайда") });
        if (folders.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
        _store.Settings.ScreenshotFolder = _store.RelativePath(path);
        if (_folder != null) _folder.Text = _store.Settings.ScreenshotFolder;
        Refresh();
    }

    void Refresh()
    {
        _resolved.Text = _store.Resolve(_store.Settings.ScreenshotFolder);
        _counter.Text = Captions.T("Найдено изображений: ") + "…";
        var paths = _store.Settings.PicturePaths.ToList();
        var root = _store.DataRoot;
        Task.Run(() => BackgroundLibrary.Count(paths, root)).ContinueWith(t =>
            Avalonia.Threading.Dispatcher.UIThread.Post(() => _counter.Text = Captions.T("Найдено изображений: ") + t.Result));
    }

    public int RowCount => _store.Settings.PicturePaths.Count;
    public Row RowAt(int index)
    {
        var e = _store.Settings.PicturePaths[index];
        var resolved = _store.Resolve(e.Path);
        return new Row(e.Path, e.ScansSubfolders ? "↳" : "•", Directory.Exists(resolved) ? "" : Vb("TextMessages9", "Не найдено"));
    }
}

/// Відкрити теку в Провіднику (на Mac — Finder).
public static class Explorer
{
    public static void Show(string path)
    {
        try
        {
            if (OperatingSystem.IsWindows())
                Process.Start(new ProcessStartInfo("explorer.exe", Directory.Exists(path) ? $"\"{path}\"" : $"/select,\"{path}\"") { UseShellExecute = true });
            else
                Process.Start(new ProcessStartInfo("open", $"\"{path}\"") { UseShellExecute = false });
        }
        catch (Exception error) { Journal.Say($"тека не відкрилась: {error.Message}"); }
    }
}
