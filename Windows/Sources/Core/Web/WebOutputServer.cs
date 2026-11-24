// =============================================================================
//  WebOutputServer.cs — веб-вивід цілком (з SlovoCore/Web/WebOutputServer.swift)
// =============================================================================
//  HTTP віддає сторінки, WebSocket жене на них слайди. Один об'єкт на всю
//  програму і джерело стану для інтерфейсу: адреса, яку можна набрати на
//  телефоні, число підключених екранів і зрозуміла причина, якщо не піднялося.
//
//  WebSocket піднімається першим: HTTP має знати його справжній порт, щоб
//  підставити в сторінки правильну адресу. Зайнятий порт — запасний (8082 для
//  сторінок, 18100 для WebSocket), і про підміну сказано в `Notices`.
//  TCP і UDP Remote API у Windows-версії ще не перенесено — увімкнені в
//  налаштуваннях, вони дають чесне повідомлення замість мовчання.
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

public sealed class WebOutputServer
{
    /// Що показати в налаштуваннях виводу.
    public sealed record Status
    {
        public bool IsRunning { get; init; }
        public int? HttpPort { get; init; }
        public int? WebSocketPort { get; init; }
        /// Порти решти двох транспортів Remote API — TCP і UDP.
        public int? TcpPort { get; init; }
        public int? UdpPort { get; init; }
        public (int Connected, int Subscribed) TcpClients { get; init; }
        public (int Connected, int Subscribed) UdpClients { get; init; }
        /// Скільки сторінок підписано на слайди.
        public int SubscribedClients { get; init; }
        /// Скільки з'єднань відкрито взагалі (сторінка могла ще не підписатися).
        public int ConnectedClients { get; init; }
        public string? LastError { get; init; }
        /// Дрібниці, про які варто сказати вголос: підмінений порт тощо.
        public IReadOnlyList<string> Notices { get; init; } = Array.Empty<string>();
        /// Адреси цього комп'ютера в локальній мережі.
        public IReadOnlyList<string> Addresses { get; init; } = Array.Empty<string>();

        /// Посилання, яке можна продиктувати або показати QR-кодом.
        public string? Url => HttpPort is { } port ? $"http://{Addresses.FirstOrDefault() ?? "localhost"}:{port}/" : null;
    }

    public sealed record Options
    {
        /// Підписи стартової сторінки; список сторінок береться з налаштувань.
        public WebIndexModel Index { get; init; } = new();
        /// Куди йти, якщо основний порт зайнятий або заборонений.
        public int HttpFallbackPort { get; init; } = 8082;
        public int WebSocketFallbackPort { get; init; } = 18100;
        public bool AllowsPortFallback { get; init; } = true;
        public bool LoopbackOnly { get; init; }
        /// Чи підміняти у сторінках, що віддаються, вшиту адресу WebSocket.
        public bool RetargetsWebSocket { get; init; } = true;
        /// Значок вкладки (PNG) — свій, програмний.
        public byte[]? Favicon { get; init; }
    }

    readonly object _lock = new();
    Status _status = new();

    /// Стан змінився — приходить з будь-якого потоку (інтерфейс переносить у свій).
    public event Action? StatusChanged;

    public Status CurrentStatus { get { lock (_lock) return _status; } }

    void Update(Func<Status, Status> change)
    {
        lock (_lock) _status = change(_status);
        StatusChanged?.Invoke();
    }

    /// Режим головного вікна: від нього залежить, чи візьме сторінка текст у лапки.
    public RemoteSlidePayload.Modes Mode { get; set; } = RemoteSlidePayload.Modes.Bible;
    /// Назви перекладів по порядку — основний, потім паралельні.
    public IReadOnlyList<RemoteModuleName> ModuleNames { get; set; } = Array.Empty<RemoteModuleName>();

    /// Розкладка об'єктів шаблону: міняється зі зміною шаблону, а не вірша.
    public WebSlideLayout? Layout { get; private set; }

    readonly string _instanceGUID = RemoteAPIIdentity.MakeGUID();
    readonly string _installGUID = RemoteAPIIdentity.MakeGUID();
    HTTPStaticServer? _http;
    WebSlideSocketServer? _socket;
    RemoteAPITCPServer? _tcp;
    RemoteAPIUDPServer? _udp;
    /// Картинки й шрифти нинішнього шаблону — їх просить наша сторінка слайда.
    readonly WebSlideImages _images = new();
    readonly WebSlideImages _fonts = new();
    Options _options = new();
    IReadOnlyList<RemoteSlideVariant> _nextVariants = Array.Empty<RemoteSlideVariant>();
    RemoteSlidePayload? _lastPayload;

    /// Куди майстерня кладе сторінки власника — окремо від авторської теки.
    public static string UserPagesFolder => Path.Combine(DataHome.Folder, "WebSlides");

    /// Прийняти шаблон: перерахувати розкладку і переписати список картинок
    /// (попередній шаблон міг називати файли, яких у новому немає).
    public void SetTemplate(SlidePreset? preset, bool withSecondTranslation, Func<SlideObject, string> text,
                            Func<string, string?> imageFile, Func<string, string?>? fontFile = null)
    {
        _images.RemoveAll();
        _fonts.RemoveAll();
        if (preset == null) { Layout = null; return; }
        Layout = WebSlideLayout.Make(preset, withSecondTranslation, text,
            path => imageFile(path) is { } file ? _images.Register(path, file) : null,
            family => fontFile?.Invoke(family) is { } file ? _fonts.Register(family, file) : null);
    }

    /// Записати картинку показу й отримати її коротке ім'я.
    public string RegisterImage(string path, string file) => _images.Register(path, file);

    public void SetLayout(WebSlideLayout? layout) => Layout = layout;

    // ── Запуск і зупинка ──────────────────────────────────────────────────────

    /// Піднімає те, що ввімкнено в налаштуваннях.
    public void Start(WebOutputSettings settings, string dataRoot, Options? options = null)
    {
        Stop();
        var resolved = options ?? _options;
        if (resolved.Index.Entries.Count == 0)
            resolved = resolved with { Index = new WebIndexModel(settings.Pages, resolved.Index.Title, resolved.Index.LanguageCode) };
        _options = resolved;

        var notices = new List<string>();
        if (!settings.WebSocketEnabled && settings.HttpEnabled)
            notices.Add(OurWords.T("WebSocket выключен в настройках — страницы откроются, но текст на них не пойдёт."));
        var fresh = new Status { Addresses = LocalNetwork.Addresses(), Notices = notices };
        Update(_ => fresh);

        if (!(settings.HttpEnabled || settings.WebSocketEnabled || settings.TcpEnabled || settings.UdpEnabled))
        {
            Update(status => status with { LastError = OurWords.T("Веб-вывод и Remote API выключены в настройках.") });
            return;
        }

        var root = Path.Combine(dataRoot, "RemoteAPI");
        // TCP і UDP Remote API: запасний порт — на 10 000 далі, як на Mac.
        if (settings.TcpEnabled)
            LaunchTCP(new WebListenerOptions(settings.TcpPort, settings.TcpPort + 10_000, _options.AllowsPortFallback, _options.LoopbackOnly));
        if (settings.UdpEnabled)
            LaunchUDP(new WebListenerOptions(settings.UdpPort, settings.UdpPort + 10_000, _options.AllowsPortFallback, _options.LoopbackOnly));

        var webSocketPort = settings.WebSocketPort;
        if (settings.WebSocketEnabled)
        {
            var listener = new WebListenerOptions(settings.WebSocketPort, _options.WebSocketFallbackPort,
                                                  _options.AllowsPortFallback, _options.LoopbackOnly);
            // Не піднявся — сторінки все одно віддаємо (з адресою з налаштувань), як на Mac.
            if (LaunchSocket(listener) is { } port) webSocketPort = port;
        }
        if (settings.HttpEnabled)
        {
            var listener = new WebListenerOptions(settings.HttpPort, _options.HttpFallbackPort,
                                                  _options.AllowsPortFallback, _options.LoopbackOnly);
            LaunchHTTP(listener, root, webSocketPort);
        }
    }

    void Notice(string text) => Update(status => status with { Notices = status.Notices.Append(text).ToList() });

    void LaunchTCP(WebListenerOptions listener, bool isRetry = false)
    {
        var server = new RemoteAPITCPServer(new RemoteAPITCPServer.Configuration(listener, _instanceGUID, _installGUID));
        server.ClientsChanged += (connected, subscribed) =>
        {
            if (!ReferenceEquals(_tcp, server)) return;
            Update(status => status with { TcpClients = (connected, subscribed) });
        };
        var (port, error) = server.Start();
        if (port is { } bound)
        {
            _tcp = server;
            Update(status => status with { TcpPort = bound, IsRunning = true });
            if (bound != listener.Port) Notice($"TCP слушает порт {bound} вместо {listener.Port}.");
            if (_lastPayload is { } payload) server.Broadcast(payload);
            return;
        }
        if (!isRetry && error!.AllowsPortFallback && listener.AllowsFallback && listener.FallbackPort != listener.Port)
        {
            Notice(error.Description);
            LaunchTCP(listener with { Port = listener.FallbackPort }, true);
            return;
        }
        _tcp = null;
        Notice(OurWords.T("TCP-сервер не поднялся: %s", error!.Description));
    }

    void LaunchUDP(WebListenerOptions listener, bool isRetry = false)
    {
        var server = new RemoteAPIUDPServer(new RemoteAPIUDPServer.Configuration(listener, _instanceGUID, _installGUID));
        server.ClientsChanged += (connected, subscribed) =>
        {
            if (!ReferenceEquals(_udp, server)) return;
            Update(status => status with { UdpClients = (connected, subscribed) });
        };
        var (port, error) = server.Start();
        if (port is { } bound)
        {
            _udp = server;
            Update(status => status with { UdpPort = bound, IsRunning = true });
            if (bound != listener.Port) Notice($"UDP слушает порт {bound} вместо {listener.Port}.");
            return;
        }
        if (!isRetry && error!.AllowsPortFallback && listener.AllowsFallback && listener.FallbackPort != listener.Port)
        {
            Notice(error.Description);
            LaunchUDP(listener with { Port = listener.FallbackPort }, true);
            return;
        }
        _udp = null;
        Notice(OurWords.T("UDP-сервер не поднялся: %s", error!.Description));
    }

    int? LaunchSocket(WebListenerOptions listener, bool isRetry = false)
    {
        var server = new WebSlideSocketServer(new WebSlideSocketServer.Configuration(listener, _instanceGUID, _installGUID));
        server.ClientsChanged += (connected, subscribed) =>
        {
            if (!ReferenceEquals(_socket, server)) return;
            Update(status => status with { ConnectedClients = connected, SubscribedClients = subscribed });
        };
        var (port, error) = server.Start();
        if (port is { } bound)
        {
            _socket = server;
            Update(status => status with { WebSocketPort = bound, IsRunning = true });
            if (bound != listener.Port)
                Notice($"WebSocket слушает порт {bound} вместо {listener.Port}.");
            // Сторінка, що підключилася до перезапуску, має отримати те, що зараз на екрані.
            if (_lastPayload is { } payload) server.Broadcast(payload);
            return bound;
        }
        if (!isRetry && error!.AllowsPortFallback && listener.AllowsFallback && listener.FallbackPort != listener.Port)
        {
            Notice(error.Description);
            return LaunchSocket(listener with { Port = listener.FallbackPort }, true);
        }
        _socket = null;
        Update(status => status with { LastError = error!.Description });
        return null;
    }

    void LaunchHTTP(WebListenerOptions listener, string root, int webSocketPort, bool isRetry = false)
    {
        var server = new HTTPStaticServer(new HTTPStaticServer.Configuration
        {
            Root = root,
            ExtraRoots = [UserPagesFolder],
            Listener = listener,
            Index = _options.Index,
            WebSocketPort = webSocketPort,
            RetargetsWebSocket = _options.RetargetsWebSocket,
            Images = _images,
            Fonts = _fonts,
            Favicon = _options.Favicon,
        });
        var (port, error) = server.Start();
        if (port is { } bound)
        {
            _http = server;
            Update(status => status with { HttpPort = bound, IsRunning = true });
            if (bound != listener.Port)
                Notice(OurWords.T("Страницы отдаются на порту %s вместо %s.", bound.ToString(CultureInfo.InvariantCulture),
                                  listener.Port.ToString(CultureInfo.InvariantCulture)));
            return;
        }
        if (!isRetry && error!.AllowsPortFallback && listener.AllowsFallback && listener.FallbackPort != listener.Port)
        {
            Notice(error.Description);
            LaunchHTTP(listener with { Port = listener.FallbackPort }, root, webSocketPort, true);
            return;
        }
        _http = null;
        Update(status => status with { LastError = error!.Description });
    }

    public void Stop()
    {
        var http = _http;
        var socket = _socket;
        var tcp = _tcp;
        var udp = _udp;
        _http = null;
        _socket = null;
        _tcp = null;
        _udp = null;
        http?.Stop();
        socket?.Stop();
        tcp?.Stop();
        udp?.Stop();
        _lastPayload = null;
        Update(_ => new Status());
    }

    public bool IsRunning => CurrentStatus.IsRunning;

    // ── Видача слайдів ────────────────────────────────────────────────────────

    /// Відправляє слайд на веб-сторінки. Осмислені лише `Web` і `Stage` — щоб
    /// проектор випадково не почав дублюватися в мережу.
    public void Publish(Slide slide, OutputKind kind = OutputKind.Web)
    {
        if (kind is not (OutputKind.Web or OutputKind.Stage)) return;
        Publish(RemoteSlidePayload.From(slide, Mode, ModuleNames, _nextVariants));
    }

    /// Розіслати сторінкам змінені налаштування — вони застосуються на льоту.
    public void PublishStyle(IReadOnlyDictionary<string, string> values) => _socket?.BroadcastStyle(values);

    public void Publish(RemoteSlidePayload payload)
    {
        var outgoing = payload with
        {
            Next = payload.Next.Count == 0 ? _nextVariants : payload.Next,
            Layout = payload.Layout ?? Layout,
        };
        _lastPayload = outgoing;
        _socket?.Broadcast(outgoing);
        _tcp?.Broadcast(outgoing);
        _udp?.Broadcast(outgoing);
    }

    /// Сховати слайд, лишивши вміст: `HideSlide` протоколу.
    public void Hide()
    {
        if (_lastPayload != null) _lastPayload = _lastPayload with { IsVisible = false };
        _socket?.BroadcastHidden();
        _tcp?.BroadcastHidden();
        _udp?.BroadcastHidden();
    }

    /// Наступний слайд для екрана служителя (секція `NextSlide`).
    public void SetNextSlide(Slide? slide)
    {
        if (slide is not { IsBlank: false } next) { _nextVariants = Array.Empty<RemoteSlideVariant>(); return; }
        var texts = new[] { next.MainText }.Concat(next.SecondaryTexts ?? Array.Empty<string>()).ToList();
        _nextVariants = texts.Select((text, index) =>
        {
            var name = index < ModuleNames.Count ? ModuleNames[index] : new RemoteModuleName("");
            return RemoteSlideVariant.Make(name.Short, name.Full, next.Reference, text);
        }).ToList();
    }
}
