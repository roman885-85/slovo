// =============================================================================
//  RemoteWindows.cs — «Пульт у браузері» і «Програми для Android» (як на Mac)
// =============================================================================
//  Перше вікно — як відкрити пульт: ім'я в мережі великими літерами, адреса
//  цифрами, QR-код (цифрами — його відкриє камера будь-якого пристрою), стан.
//  Друге — QR-коди завантаження програм для Android. Обидва живі: раз на 2 с
//  звіряють, де «Слово» зараз.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Slovo.App;

/// QR-код: модулі QRCoder, намальовані квадратами (рівень корекції M, білі поля).
public sealed class QrView : Control
{
    bool[][]? _modules;
    string _text = "";
    public string Text
    {
        get => _text;
        set
        {
            if (_text == value) return;
            _text = value;
            _modules = value.Length == 0 ? null : Matrix(value);
            InvalidateVisual();
        }
    }

    static bool[][]? Matrix(string text)
    {
        try
        {
            using var generator = new QRCoder.QRCodeGenerator();
            using var data = generator.CreateQrCode(text, QRCoder.QRCodeGenerator.ECCLevel.M);
            return data.ModuleMatrix.Select(row => row.Cast<bool>().ToArray()).ToArray();
        }
        catch { return null; }
    }

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.DrawRectangle(Brushes.White, null, b, 6, 6);
        if (_modules is not { Length: > 0 } modules) return;
        var count = modules.Length;
        var scale = Math.Max(1, Math.Floor((Math.Min(b.Width, b.Height) - 16) / count));
        var side = scale * count;
        var x0 = Math.Round((b.Width - side) / 2);
        var y0 = Math.Round((b.Height - side) / 2);
        for (var y = 0; y < count; y++)
            for (var x = 0; x < modules[y].Length; x++)
                if (modules[y][x]) g.DrawRectangle(Brushes.Black, null, new Rect(x0 + x * scale, y0 + y * scale, scale, scale));
    }
}

/// Адреси сторінки пульта (RemoteWebAddress на Mac).
public static class RemoteWebAddress
{
    static int Port => RemoteControlServer.Shared.WebRunning ? RemoteControlServer.Shared.WebPort : SettingsStore.Shared.Settings.Options.RemoteWebPort ?? 8105;

    public static string Link(string host) =>
        RemoteControlServer.Shared.WebRunning && RemoteControlServer.Shared.PlainReady ? $"http://{host}/" : $"http://{host}:{Port}/";

    /// За ім'ям у мережі (slovo.local), якщо його оголошено.
    public static string? Named => RemoteControlServer.Shared.MdnsName is { } name ? Link(name) : null;

    /// Цифрами — перша адреса машини в мережі.
    public static string? Numeric => Names.Addresses().Select(a => a.Address.ToString()).FirstOrDefault() is { } host ? Link(host) : null;
}

public sealed class BrowserRemoteWindow : Window
{
    static BrowserRemoteWindow? _shown;
    readonly TextBlock _nameLink, _numberLink, _status;
    readonly QrView _code = new() { Width = 220, Height = 220 };
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };

    public static BrowserRemoteWindow Open()
    {
        if (_shown is { } open) { open.Refresh(); open.Activate(); return open; }
        var window = _shown = new BrowserRemoteWindow();
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Avalonia.Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    static TextBlock Text(string value, double size = 13, bool bold = false, bool secondary = false) => new()
    {
        Text = value, FontSize = size, FontWeight = bold ? FontWeight.Bold : FontWeight.Normal, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family,
        Foreground = Palette.Brush(secondary ? Palette.SecondaryLabel : Palette.Label),
    };

    BrowserRemoteWindow()
    {
        Title = Captions.T("Пульт в браузере");
        Width = 680; Height = 480; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        _nameLink = new TextBlock { FontSize = 26, FontWeight = FontWeight.SemiBold, Foreground = Palette.Brush(Palette.Accent), FontFamily = UiFont.Family };
        _numberLink = new TextBlock { FontSize = 15, FontFamily = new FontFamily("Cascadia Mono,Consolas,Menlo,monospace"), Foreground = Palette.Brush(Palette.Label) };
        _status = Text("", 12);
        var copy = new PushButton(Captions.T("Скопировать")) { Pressed = () => { if (MainLink is { } link) _ = Clipboard?.SetTextAsync(link); } };
        ToolTip.SetTip(copy, Captions.T("Положить адрес в буфер обмена"));
        var open = new PushButton(Captions.T("Открыть здесь")) { Pressed = () => { if (MainLink is { } link) OpenUrl(link); } };
        ToolTip.SetTip(open, Captions.T("Открыть страницу в браузере этого компьютера"));
        var qr = new PushButton(Captions.T("Установить по QR-коду…")) { Pressed = () => AndroidAppsWindow.Open(), HorizontalAlignment = HorizontalAlignment.Left };
        ToolTip.SetTip(qr, Captions.T("Показать QR-коды: камера телефона или планшета загрузит и установит программу"));
        var left = new StackPanel
        {
            Spacing = 8, Margin = new Thickness(20, 18, 20, 16),
            Children =
            {
                Text(Captions.T("«Слово» из браузера планшета, телефона или другого компьютера"), 15, true),
                Text(Captions.T("1. Устройство — в той же сети Wi-Fi, что и этот компьютер.")),
                Text(Captions.T("2. В браузере наберите:")),
                _nameLink,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { copy, open } },
                Text(Captions.T("3. Или наведите камеру планшета или телефона на код справа.")),
                Text(Captions.T("Если по имени не открывается (бывает на старых Android) — адрес цифрами:"), secondary: true),
                _numberLink,
                Text(Captions.T("Пароль — если задан в Параметры → Remote API; страница спросит его сама."), secondary: true),
                Text(Captions.T("Программы для Android — кнопка «Android» на странице или установка по QR-коду:"), secondary: true),
                qr,
                _status,
            },
        };
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        Grid.SetColumn(left, 0);
        _code.Margin = new Thickness(0, 24, 20, 0);
        _code.VerticalAlignment = VerticalAlignment.Top;
        Grid.SetColumn(_code, 1);
        grid.Children.Add(left);
        grid.Children.Add(_code);
        Content = grid;
        Refresh();
        // Ім'я оголошується за секунду-дві, мережа може змінитися — вікно показує живий стан.
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Closed += (_, _) => _timer.Stop();
        KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Escape) Close(); };
    }

    static string? MainLink => RemoteWebAddress.Named ?? RemoteWebAddress.Numeric;

    public void Refresh()
    {
        var server = RemoteControlServer.Shared;
        var named = RemoteWebAddress.Named;
        var numeric = RemoteWebAddress.Numeric;
        _nameLink.Text = named ?? numeric ?? "—";
        _numberLink.Text = numeric ?? "—";
        // QR — цифрами: камера будь-якого пристрою відкриє його без оголошених імен.
        _code.Text = numeric ?? "";
        var lines = new List<string>();
        if (numeric == null) lines.Add(Captions.T("Сети не видно — подключите компьютер к Wi-Fi или кабелю."));
        if (!server.WebRunning)
            lines.Add(server.WebError ?? Captions.T("Пульт в браузере выключен — страница не откроется. Включите его в Параметры → Remote API."));
        else
        {
            var parts = new List<string> { Captions.T("работает на порту %s", server.WebPort.ToString()) };
            parts.Add(server.MdnsName is { } name ? Captions.T("имя %s объявлено в сети", name) : Captions.T("имя пока не объявлено — пользуйтесь адресом цифрами"));
            if (server.PlainReady) parts.Add(Captions.T("адрес без номера порта"));
            else if (server.WebNoPort) parts.Add(server.PlainError ?? Captions.T("порт 80 занят — адрес с номером порта"));
            if (server.WebHasPassword) parts.Add(Captions.T("вход с паролем"));
            if (server.WebViewOnly) parts.Add(Captions.T("только просмотр"));
            lines.Add(string.Join(" · ", parts));
        }
        _status.Text = string.Join("\n", lines);
        _status.Foreground = Palette.Brush(server.WebRunning && numeric != null ? Palette.SecondaryLabel : Palette.SystemRed);
    }

    public static void OpenUrl(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { Journal.Say($"посилання не відкрилось: {error.Message}"); }
    }
}

public sealed class AndroidAppsWindow : Window
{
    static AndroidAppsWindow? _shown;
    readonly List<(RemoteControlServer.AndroidAppInfo App, TextBlock Caption, QrView Code)> _cards = new();
    readonly TextBlock _note;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromSeconds(2) };

    public static AndroidAppsWindow Open()
    {
        if (_shown is { } open) { open.Refresh(); open.Activate(); return open; }
        var window = _shown = new AndroidAppsWindow();
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Avalonia.Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    AndroidAppsWindow()
    {
        Title = Captions.T("Программы для Android");
        Width = 640; Height = 470; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 28 };
        foreach (var app in RemoteControlServer.AndroidAppsForSettings)
        {
            var caption = new TextBlock { FontSize = 13, TextAlignment = TextAlignment.Center, Width = 240, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family,
                                          Foreground = Palette.Brush(Palette.Label) };
            var code = new QrView { Width = 200, Height = 200 };
            var save = new PushButton(Captions.T("Сохранить…")) { Pressed = () => _ = RemoteTabFiles.SaveApp(app), IsEnabled = app.Path != null, HorizontalAlignment = HorizontalAlignment.Center };
            ToolTip.SetTip(save, Captions.T("Сохранить установочный файл на этот компьютер"));
            row.Children.Add(new StackPanel { Spacing = 8, Children = { caption, code, save } });
            _cards.Add((app, caption, code));
        }
        _note = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family };
        Content = new StackPanel
        {
            Spacing = 12, Margin = new Thickness(20, 18, 20, 16),
            Children =
            {
                new TextBlock { Text = Captions.T("Установить на телефон или планшет по QR-коду"), FontSize = 15, FontWeight = FontWeight.Bold, FontFamily = UiFont.Family,
                                Foreground = Palette.Brush(Palette.Label) },
                new TextBlock { Text = Captions.T("Наведите камеру устройства на код нужной программы — файл загрузится; нажмите его и разрешите установку из браузера."),
                                FontSize = 13, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family, Foreground = Palette.Brush(Palette.Label) },
                row,
                _note,
            },
        };
        Refresh();
        // Сторінку пульта могли щойно ввімкнути, мережа могла змінитися — коди ведуть туди, де «Слово» зараз.
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
        Closed += (_, _) => _timer.Stop();
        KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Escape) Close(); };
    }

    public void Refresh()
    {
        var running = RemoteControlServer.Shared.WebRunning;
        foreach (var (app, caption, code) in _cards)
        {
            caption.Text = app.Title + (app.Version.Length == 0 ? "" : " " + app.Version) + "\n" + Captions.T("Android %s и новее", app.MinAndroid);
            code.Text = running && RemoteWebAddress.Numeric is { } numeric ? numeric + $"download/{app.Id}.apk" : "";
        }
        _note.Text = running
            ? Captions.T("Телефон или планшет — в той же сети Wi-Fi. Предупреждение Android о неизвестном разработчике ожидаемо: «Всё равно установить».")
            : Captions.T("Коды работают, когда включён пульт в браузере (Параметры → Remote API).");
        _note.Foreground = Palette.Brush(running ? Palette.SecondaryLabel : Palette.SystemRed);
    }
}

/// Зберегти пакет для Android на цей комп'ютер (AndroidAppFile на Mac).
public static class RemoteTabFiles
{
    public static async Task SaveApp(RemoteControlServer.AndroidAppInfo app)
    {
        if (app.Path == null || MainWindow.Shared?.StorageProvider is not { } storage) return;
        var file = await storage.SaveFilePickerAsync(new Avalonia.Platform.Storage.FilePickerSaveOptions { SuggestedFileName = app.FileName, DefaultExtension = "apk" });
        if (file?.TryGetLocalPath() is not { } target) return;
        try { File.Copy(app.Path, target, true); Journal.Say($"програму для Android «{app.Id}» збережено: {target}"); }
        catch (Exception error) { Alert.Tell(Captions.T("Не удалось сохранить"), error.Message); }
    }
}

/// «Параметри Web слайда» (форма `WebSlideParamsForm` оригіналу) — як вікно
/// `edit(_:)` вкладки Remote API на Mac: назва сторінки, файл зі списку сторінок
/// (авторських і своїх), опис; «Ок» — кнопка за умовчанням (Enter), Esc — скасувати.
public static class WebSlideParamsDialog
{
    static string Vb(string key, string fallback) => Captions.FormCaption(key, "WebSlideParamsForm", fallback);

    public static Task<Slovo.Core.WebSlideEntry?> Ask(Slovo.Core.WebSlideEntry? entry, IReadOnlyList<string> files, Window? owner = null)
    {
        var done = new TaskCompletionSource<Slovo.Core.WebSlideEntry?>();
        var window = new Window
        {
            Title = "", Width = 420, Height = 196, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Palette.Brush(Palette.WindowBackground),
        };
        var name = new FormField(12) { Text = entry?.Name ?? "" };
        ToolTip.SetTip(name, Captions.FormHint("EName", "WebSlideParamsForm") ?? Captions.T("Допускается ввод только букв на английском языке в нижнем регистре, цифр, подчеркивания и тире"));
        // Файла може не бути в теці — лишаємо його в списку, інакше правка сторінку й зламає.
        var titles = files.Count == 0 ? new[] { "" } : files.ToArray();
        var file = new PopupButton(titles, Math.Max(0, Array.IndexOf(titles, entry?.FileName ?? ""))) { FontSize = 12 };
        var details = new FormField(12) { Text = entry?.Details ?? "" };
        Slovo.Core.WebSlideEntry? result = null;
        var ok = new PushButton(Vb("BBOk", "Ок")) { Prominent = true };
        var cancel = new PushButton(Vb("BBCancel", "Отменить")) { Pressed = window.Close };
        void Accept() { result = new Slovo.Core.WebSlideEntry(name.Text, file.SelectedTitle ?? "", details.Text); window.Close(); }
        ok.Pressed = Accept;
        name.OnSubmit = _ => Accept();
        details.OnSubmit = _ => Accept();
        var panel = new LayoutPanel();
        var heading = new BottomCaption { Text = Vb("WebSlideParamsForm", "Параметры Web слайда"), FontSize = 13, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        var labels = new[] { Vb("Label1", "Название страницы:"), Vb("Label2", "Файл:"), Vb("Label3", "Описание:") }
            .Select(t => new BottomCaption { Text = t, FontSize = 11, Align = TextAlignment.Right, Color = () => Palette.Label }).ToArray();
        foreach (Control c in new Control[] { heading, name, file, details, ok, cancel }.Concat(labels)) panel.Children.Add(c);
        panel.Layout = size =>
        {
            panel.Place(heading, new Rect(20, 16, size.Width - 40, 18));
            // Рамка допоміжного вигляду NSAlert — 380×92: підписи 122 праворуч, поля 240 з x=130, крок 28.
            var left = Math.Round((size.Width - 380) / 2);
            Control[] fields = { name, file, details };
            for (var i = 0; i < 3; i++)
            {
                var top = 48 + i * 28;
                panel.Place(labels[i], new Rect(left, top + 3, 122, 16));
                panel.Place(fields[i], new Rect(left + 130, top, 240, 22));
            }
            var w = Math.Max(90, ok.FittingWidth + 24);
            panel.Place(ok, new Rect(size.Width - 20 - w, size.Height - 44, w, 24));
            var c = Math.Max(90, cancel.FittingWidth + 24);
            panel.Place(cancel, new Rect(size.Width - 20 - w - 8 - c, size.Height - 44, c, 24));
        };
        window.Content = panel;
        window.Closed += (_, _) => done.TrySetResult(result);
        window.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Escape) window.Close();
            else if (e.Key == Avalonia.Input.Key.Enter) Accept();
        };
        var parent = owner ?? (Window?)SettingsWindow.Shared ?? MainWindow.Shared;
        if (parent is { IsVisible: true }) window.ShowDialog(parent); else window.Show();
        return done.Task;
    }
}
