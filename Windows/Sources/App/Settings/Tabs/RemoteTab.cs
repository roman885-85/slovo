// =============================================================================
//  RemoteTab.cs — вкладка «Remote API» (як NativeSettingsRemoteTab на Mac)
// =============================================================================
//  Сервери автора (Web, WebSocket, TCP, UDP — галочка й порт), пульт на телефоні
//  (увімкнення, порт, PIN, адреса, «Перевірити зв'язок»), пульт у браузері
//  (порт, пароль, ім'я в мережі, лише перегляд, без номера порту, посилання й
//  стан), програми для Android, мережевий інтерфейс і адреса сторінок, список
//  веб-слайдів (+ − ✎ ↗ ⧉). Зміни набирають сили по «Ок».
// =============================================================================

using System.Diagnostics;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class RemoteTab : IRowSource
{
    readonly SettingsStore _store;
    readonly RowList _slides;
    readonly TextBlock _addressLine = Form.Label("", false), _remoteLine = Form.Label("", false), _browserLine = Form.Label("", false);
    /// IP цього комп'ютера в мережі й посилання цифрами — щоб підключитися швидко, без пошуку й імені.
    readonly TextBlock _ipLine = Form.Label("", false), _numericLine = Form.Label("", false);
    readonly TextBlock _reachLine = Form.Label(""), _webStatus = Form.Label("");
    readonly List<string> _interfaces;
    int? _selected;

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string VbHint(string key, string fallback) => Captions.FormHint(key, "SettingsForm") ?? Captions.T(fallback);
    ProgramOptions Options => _store.Settings.Options;

    public RemoteTab(SettingsStore store)
    {
        _store = store;
        _interfaces = Names.Addresses().Select(a => a.Address.ToString()).Distinct().ToList();
        _slides = new RowList(new ListMetrics { DetailWidth = 200, Padding = new Avalonia.Thickness(6, 3, 6, 3) }, 11) { Source = this };
        _slides.SetUniformHeight(20);
        _slides.OnSelect = (_, active, _) => _selected = active;
        _reachLine.TextWrapping = TextWrapping.Wrap;
        _reachLine.MaxWidth = 520;
        RemoteControlServer.Shared.StatusChanged += RefreshAddress;
    }

    public Control Page()
    {
        var page = new Form.Page(new[] { Servers(), Remote(), Web(), AndroidApps(), Network(), Slides() });
        RefreshAddress();
        return page;
    }

    // --- Пульт на телефоні ----------------------------------------------------------------

    Form.Group Remote()
    {
        var check = Form.Check(Captions.T("Принимать команды с телефона"), new Tie<bool>(() => Options.RemoteEnabled ?? true, v => Options.RemoteEnabled = v),
                               Captions.T("Приложение «Пульт Слова» для Android листает слайды и показывает, что в зале"));
        check.Width = 260;
        return new Form.Group(Captions.T("Пульт на телефоне"), new Control[]
        {
            // Адреса комп'ютера в мережі — зверху, щоб її було видно одразу (власник, Windows 1.4.2).
            new Form.Row(Captions.T("IP-адрес в сети:"), new Control[]
            {
                _ipLine,
                Form.Button(Captions.T("Скопировать"), Captions.T("Положить адрес в буфер обмена"), () => Copy(Host)),
            }, 180),
            new Form.Row("", new Control[] { MediaTab.FirewallRow() }),
            new Form.Row("", new Control[]
            {
                check, Form.Label(Captions.T("Порт:"), false),
                Form.Number(new Tie<int>(() => Options.RemotePort ?? 8103, v => { Options.RemotePort = v; RefreshAddress(); }), 1, 65535, 70),
            }),
            // PIN і пароль — своїми рядками: поруч із галочкою підказка не вміщається.
            new Form.Row(Captions.T("PIN:"), new Control[]
            {
                Form.Text(new Tie<string>(() => Options.RemotePin ?? "", v => Options.RemotePin = v.Trim()), 120),
                Form.Label(Captions.T("пусто — без PIN"), false),
            }, 180),
            new Form.Row(Captions.T("Адрес для пульта:"), new Control[]
            {
                _remoteLine,
                Form.Button(Captions.T("Скопировать"), Captions.T("Положить адрес в буфер обмена"), () => Copy($"{Host}:{Options.RemotePort ?? 8103}")),
            }, 180),
            new Form.Row("", new Control[] { Form.Note(Captions.T("Телефон находит программу по Wi-Fi сам; адрес нужен, только если поиск не сработал. Установить приложение — «Программы для Android» ниже.")) }),
            // Програма йде до себе дорогою телефона й каже словами, що не вийшло.
            new Form.Row("", new Control[]
            {
                Form.Button(Captions.T("Проверить связь"), Captions.T("Пройти к себе тем же путём, каким идёт телефон"), CheckReach),
                _reachLine,
            }),
        });
    }

    void CheckReach()
    {
        _reachLine.Text = Captions.T("Проверяю…");
        _reachLine.Foreground = Palette.Brush(Palette.SecondaryLabel);
        RemoteReachability.Probe(Options.RemotePort ?? 8103, Options.RemotePin ?? "", result =>
        {
            _reachLine.Text = result.Verdict;
            _reachLine.Foreground = Palette.Brush(result.IsFine ? Palette.SecondaryLabel : Palette.SystemOrange);
            Journal.Say($"пульт: перевірка зв'язку — {result.Verdict}");
        });
    }

    // --- Пульт у браузері -------------------------------------------------------------------

    Form.Group Web()
    {
        var enable = Form.Check(Captions.T("Открывать пульт в браузере"), new Tie<bool>(() => Options.RemoteWebEnabled ?? true, v => Options.RemoteWebEnabled = v),
                                Captions.T("Страница пульта для браузера компьютера, планшета или телефона"));
        enable.Width = 260;
        return new Form.Group(Captions.T("Пульт в браузере"), new Control[]
        {
            new Form.Row("", new Control[]
            {
                enable, Form.Label(Captions.T("Порт:"), false),
                Form.Number(new Tie<int>(() => Options.RemoteWebPort ?? 8105, v => Options.RemoteWebPort = v), 1024, 65535, 70),
            }),
            new Form.Row(Captions.T("Пароль:"), new Control[]
            {
                Form.Text(new Tie<string>(() => Options.RemoteWebPassword ?? "", v => Options.RemoteWebPassword = v.Trim()), 160),
                Form.Label(Captions.T("пусто — без пароля"), false),
            }, 180),
            new Form.Row(Captions.T("Имя в сети:"), new Control[]
            {
                Form.Text(new Tie<string>(() => Options.RemoteWebName ?? "slovo", v => Options.RemoteWebName = Names.Clean(v)), 120),
                Form.Label(".local", false),
            }, 180),
            new Form.Row("", new Control[] { Form.Note(Captions.T("Одно и то же имя на любом компьютере со «Словом». Для второго зала в той же сети задайте своё — латиница, цифры, дефис.")) }),
            new Form.Row("", new Control[]
            {
                Form.Check(Captions.T("Только просмотр: страница показывает зал, но не управляет"),
                           new Tie<bool>(() => Options.RemoteWebViewOnly ?? false, v => Options.RemoteWebViewOnly = v),
                           Captions.T("Для экрана музыкантов или проповедника: видно, что в зале, а листать и выводить нельзя")),
            }),
            new Form.Row("", new Control[]
            {
                Form.Check(Captions.T("Открывать и без номера порта (порт 80, если свободен)"),
                           new Tie<bool>(() => Options.RemoteWebNoPort ?? true, v => Options.RemoteWebNoPort = v),
                           Captions.T("Тогда в браузере достаточно набрать slovo.local. Если порт 80 занят другой программой, пульт остаётся на своём порту.")),
            }),
            // Посилання — тут, поруч з адресою пульта: сховане за меню людина не знайде.
            new Form.Row(Captions.T("Цифрами:"), new Control[]
            {
                _numericLine,
                Form.Button(Captions.T("Скопировать"), Captions.T("Положить ссылку в буфер обмена"), () => Copy(NumericAddress)),
                Form.Button(Captions.T("Открыть"), Captions.T("Открыть страницу в браузере этого компьютера"), () => OpenUrl(NumericAddress)),
            }, 180),
            new Form.Row(Captions.T("Страница для браузера:"), new Control[]
            {
                _browserLine,
                Form.Button(Captions.T("Скопировать"), Captions.T("Положить ссылку в буфер обмена"), () => Copy(BrowserAddress)),
                Form.Button(Captions.T("Открыть"), Captions.T("Открыть страницу в браузере этого компьютера"), () => OpenUrl(BrowserAddress)),
                Form.Button(Captions.T("Как открыть…"), Captions.T("Показать, как открыть пульт в браузере"), () => { BrowserRemoteWindow.Open(); }),
            }, 180),
            new Form.Row("", new Control[] { _webStatus }),
            new Form.Row("", new Control[] { Form.Note(Captions.T("Порт нестандартный, чтобы не спорить с другими программами; если он занят, здесь будет написано — выберите другой. Изменения вступают в силу по «Ок».")) }),
        });
    }

    // --- Програми для Android ---------------------------------------------------------------

    Form.Group AndroidApps()
    {
        var rows = new List<Control>();
        foreach (var app in RemoteControlServer.AndroidAppsForSettings)
        {
            var note = (app.Version.Length == 0 ? "" : Captions.T("версия %s", app.Version) + " · ") + Captions.T("Android %s и новее", app.MinAndroid);
            var save = Form.Button(Captions.T("Сохранить…"), Captions.T("Сохранить установочный файл на этот компьютер"), () => _ = RemoteTabFiles.SaveApp(app));
            save.IsEnabled = app.Path != null;
            rows.Add(new Form.Row(app.Title + ":", new Control[] { Form.Label(app.Path != null ? note : Captions.T("нет в этой сборке"), false), save }, 180));
        }
        rows.Add(new Form.Row("", new Control[]
        {
            Form.Button(Captions.T("Установить по QR-коду…"), Captions.T("Показать QR-коды: камера телефона или планшета загрузит и установит программу"), () => { AndroidAppsWindow.Open(); }),
            Form.Label(Captions.T("Или прямо со страницы в браузере: кнопка «Android» вверху страницы.")),
        }));
        return new Form.Group(Captions.T("Программы для Android"), rows);
    }

    // --- Сервери й порти автора -------------------------------------------------------------

    Form.Group Servers() => new("", new Control[]
    {
        Server(Vb("CBWEBServer", "Web Сервер"), () => Options.WebEnabled, v => Options.WebEnabled = v, Vb("Label55", "Web Порт:"), () => Options.WebPort, v => Options.WebPort = v,
               Captions.T("Страница пульта в браузере, веб-слайды для OBS и файлы программ для Android")),
        Server(Vb("CBWSServer", "WebSocket Сервер"), () => Options.WebSocketEnabled, v => Options.WebSocketEnabled = v, Vb("Label52", "WebSocket Порт:"),
               () => Options.WebSocketPort, v => Options.WebSocketPort = v, Captions.T("Управление «Словом» из других программ по WebSocket")),
        Server(Vb("CBTCPServer", "TCP Сервер"), () => Options.TcpEnabled, v => Options.TcpEnabled = v, Vb("Label54", "TCP Порт:"), () => Options.TcpPort, v => Options.TcpPort = v,
               Captions.T("Управление «Словом» из других программ по TCP")),
        Server(Vb("CBUDPServer", "UDP Сервер"), () => Options.UdpEnabled, v => Options.UdpEnabled = v, Vb("Label53", "UDP Порт:"), () => Options.UdpPort, v => Options.UdpPort = v,
               Captions.T("Управление «Словом» из других программ по UDP")),
    });

    Control Server(string title, Func<bool> get, Action<bool> set, string portTitle, Func<int> getPort, Action<int> setPort, string hint)
    {
        var check = Form.Check(title, new Tie<bool>(get, set), hint);
        check.Width = 180;
        return new Form.Row("", new Control[]
        {
            check, Form.Label(portTitle, false),
            Form.Number(new Tie<int>(getPort, v => { setPort(v); RefreshAddress(); }), 1, 65535, 70),
        });
    }

    // --- Мережевий інтерфейс і адреса -------------------------------------------------------

    Form.Group Network()
    {
        var titles = new List<string> { "0.0.0.0" };
        titles.AddRange(_interfaces);
        return new Form.Group("", new Control[]
        {
            new Form.Row(Vb("Label56", "Сетевой интерфейс:"), new Control[]
            {
                Form.Popup(titles, new Tie<int>(() =>
                {
                    var chosen = Options.WebNetInterface;
                    return chosen.Length == 0 ? 0 : Math.Max(0, titles.IndexOf(chosen));
                }, index => { Options.WebNetInterface = index == 0 ? "" : titles[index]; RefreshAddress(); }), 200),
                Form.Button(Vb("PSBOpenMainPageOfWebSlides", "Открыть в браузере"), VbHint("PSBOpenMainPageOfWebSlides", "Открыть домашнюю страницу Web слайдов в браузере"),
                            () => OpenUrl(WebPageAddress.Home(Host, Options.WebPort))),
            }, 180),
            new Form.Row(Captions.T("Адрес страниц:"), new Control[]
            {
                _addressLine,
                Form.Button(Captions.T("Скопировать"), Captions.T("Положить адрес в буфер обмена"), () => Copy(WebPageAddress.Home(Host, Options.WebPort))),
            }, 180),
        });
    }

    // --- Веб-слайди -------------------------------------------------------------------------

    Form.Group Slides()
    {
        var box = new Border { Height = 130, Width = 520, Child = _slides, BorderThickness = new Avalonia.Thickness(1), BorderBrush = Palette.Brush(Palette.Separator) };
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Vertical, Spacing = 4 };
        buttons.Children.Add(Form.Button("+", VbHint("PSBAddWebSlide", "Добавить Web слайд"), () => _ = Edit(null)));
        buttons.Children.Add(Form.Button("−", VbHint("PSBDelWebSlide", "Удалить Web слайд"), Remove));
        buttons.Children.Add(Form.Button("✎", VbHint("PSBEditWebSlide", "Редактировать параметры Web слайда"), () => { if (Current is { } entry) _ = Edit(entry); }));
        buttons.Children.Add(Form.Button("↗", VbHint("PSBOpenWebSlide", "Открыть Web слайд в браузере"), () => { if (Current is { } entry) OpenUrl(AddressOf(entry.FileName)); }));
        buttons.Children.Add(Form.Button("⧉", Captions.T("Скопировать адрес страницы — его вписывают в OBS и подобные программы"),
                                         () => { if (Current is { } entry) Copy(AddressOf(entry.FileName)); }));
        return new Form.Group(Vb("Label57", "Web слайды:"), new Control[] { new Form.Row("", new Control[] { box, buttons }) });
    }

    WebSlideEntry? Current => _selected is { } i && i >= 0 && i < _store.Settings.WebSlides.Count ? _store.Settings.WebSlides[i] : null;

    void Remove()
    {
        if (Current is not { } entry) return;
        Alert.Ask(Vb("TextMessages24", "Внимание"), Vb("TextMessages46", "Действительно удалить Web страницу %s?").Replace("%s", entry.Name),
                  new[] { Captions.Caption("TextMessages6", "Да").Replace("&", ""), Captions.Caption("TextMessages7", "Нет").Replace("&", "") }, answer =>
        {
            if (answer != 0) return;
            _store.Settings.WebSlides.RemoveAll(e => e.Id == entry.Id);
            _selected = null;
            _slides.Reload();
        });
    }

    /// Файли сторінок — у теці RemoteAPI поруч із даними і в теці своїх сторінок.
    List<string> WebSlideFiles
    {
        get
        {
            var names = new List<string>();
            foreach (var folder in new[] { Path.Combine(DataHome.Folder, "RemoteAPI"), Path.Combine(DataHome.Folder, "WebSlides") })
            {
                if (!Directory.Exists(folder)) continue;
                foreach (var file in Directory.EnumerateFiles(folder, "*.html"))
                {
                    var name = Path.GetFileName(file);
                    if (!names.Any(n => string.Equals(n, name, StringComparison.OrdinalIgnoreCase))) names.Add(name);
                }
            }
            names.Sort(StringComparer.Ordinal);
            return names;
        }
    }

    async Task Edit(WebSlideEntry? entry)
    {
        var files = WebSlideFiles;
        // Файла може не бути в теці — лишаємо його в списку, інакше правка зламає сторінку.
        if (entry?.FileName is { Length: > 0 } known && !files.Contains(known)) files.Insert(0, known);
        var result = await WebSlideParamsDialog.Ask(entry, files);
        if (result == null) return;
        // Обмеження автора: малі латинські літери, цифри, підкреслення й дефіс — ім'я йде в адресу.
        var cleaned = new string(result.Name.ToLowerInvariant().Where(c => (c < 128 && char.IsLetter(c)) || char.IsDigit(c) || c is '_' or '-').ToArray());
        if (cleaned.Length == 0 || result.FileName.Length == 0) return;
        var fresh = new WebSlideEntry(cleaned, result.FileName, result.Details);
        var list = _store.Settings.WebSlides;
        if (entry != null && list.FindIndex(e => e.Id == entry.Id) is var at and >= 0) list[at] = fresh; else list.Add(fresh);
        _slides.Reload();
    }

    public int RowCount => _store.Settings.WebSlides.Count;

    /// Адреса — у самому рядку: її вставляють в OBS і браузер.
    public Row RowAt(int index)
    {
        var entry = _store.Settings.WebSlides[index];
        return new Row(entry.Name + "  —  " + AddressOf(entry.FileName), "", entry.FileName + (entry.Details.Length == 0 ? "" : "  ·  " + entry.Details)) { SingleLine = true };
    }

    // --- Адреси -----------------------------------------------------------------------------

    string Host => Options.WebNetInterface is { Length: > 0 } chosen ? chosen : _interfaces.FirstOrDefault() ?? "127.0.0.1";

    string AddressOf(string fileName) => fileName.Length == 0 ? "" : WebPageAddress.Url(Host, Options.WebPort, fileName);

    static string Link(string host, int fallbackPort)
    {
        var server = RemoteControlServer.Shared;
        var port = server.WebRunning ? server.WebPort : fallbackPort;
        return server.WebRunning && server.PlainReady ? $"http://{host}/" : $"http://{host}:{port}/";
    }

    string BrowserAddress => Link(RemoteControlServer.Shared.MdnsName ?? Host, Options.RemoteWebPort ?? 8105);
    /// Те саме цифрами: відкривається на будь-якому пристрої, навіть де імена .local не працюють.
    string NumericAddress => Link(Host, Options.RemoteWebPort ?? 8105);

    void RefreshAddress()
    {
        _addressLine.Text = WebPageAddress.Home(Host, Options.WebPort);
        var server = RemoteControlServer.Shared;
        _remoteLine.Text = $"{Host}:{Options.RemotePort ?? 8103}" + (server.IsRunning ? "" : "  · " + Captions.T("сейчас выключен"));
        _browserLine.Text = BrowserAddress;
        _numericLine.Text = NumericAddress;
        var adapter = Names.Interfaces().FirstOrDefault(i => i.Address.ToString() == Host);
        _ipLine.Text = _interfaces.Count == 0 && Options.WebNetInterface is not { Length: > 0 }
            ? Captions.T("нет сети — подключите Wi-Fi или кабель")
            : Host + (adapter != null ? $"  ({adapter.Name})" : "")
              + (_interfaces.Count > 1 ? "  · " + Captions.T("ещё: %s", string.Join(", ", _interfaces.Where(a => a != Host))) : "");
        if (!(Options.RemoteWebEnabled ?? true)) _webStatus.Text = Captions.T("Пульт в браузере выключен");
        else if (server.WebRunning)
            _webStatus.Text = Captions.T("работает на порту %s", server.WebPort.ToString())
                + (server.PlainReady ? " · " + Captions.T("адрес без номера порта")
                    : server.WebNoPort ? " · " + (server.PlainError ?? Captions.T("порт 80 занят — адрес с номером порта")) : "")
                + (server.WebHasPassword ? " · " + Captions.T("вход с паролем") : "")
                + (server.WebViewOnly ? " · " + Captions.T("только просмотр") : "");
        else _webStatus.Text = server.WebError ?? Captions.T("не запущен");
        _slides.Reload();
    }

    static void Copy(string text)
    {
        if (MainWindow.Shared?.Clipboard is { } board) _ = board.SetTextAsync(text);
    }

    static void OpenUrl(string url)
    {
        if (url.Length == 0) return;
        try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { Journal.Say($"посилання не відкрилось: {error.Message}"); }
    }
}
