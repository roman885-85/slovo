// =============================================================================
//  AppState.Web.cs — веб-слайди: сервер за налаштуваннями і зал на сторінках
// =============================================================================
//  Як на Mac (AppState.setWebEnabled, pushToOutputs, applyProgramOptions):
//  • «Параметри → Remote API»: Web і WebSocket-сервер, порти; сервер
//    піднімається заново лише тоді, коли щось мережеве справді змінилося
//    (перезапуск рве відкриті в залі сторінки);
//  • при вмиканні — заготовки для Біблії й пісень лягають файлами в теку
//    своїх сторінок (сівалка) і в список «Web слайди»;
//  • те, що бачить зал, іде на сторінки: текст слайда (сторінкам автора) і
//    розкладка свого шаблону (`slovo-slide.html` малює ті самі об'єкти, що й
//    проектор); картинка показу — фоном розкладки;
//  • повзунки редактора веб-слайдів доходять до сторінок одразу (PublishStyle).
//  Перевірки: ключ `--web-slides-port N [--web-socket-port M]` — свої порти,
//  без запасних і без налаштувань (див. Program.cs).
// =============================================================================

using Avalonia.Threading;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    /// Веб-вивід: HTTP віддає сторінки, WebSocket жене на них слайди.
    public WebOutputServer Web { get; } = new();

    /// Порти веб-слайдів для перевірок (`--web-slides-port`): сервер піднімається і
    /// при знімках без екрана, на цих портах, без запасних портів.
    public static int? WebPortOverride { get; set; }
    public static int? WebSocketPortOverride { get; set; }
    /// TCP- і UDP-портів Remote API для перевірок (`--remote-api-tcp`, `--remote-api-udp`).
    public static int? TcpPortOverride { get; set; }
    public static int? UdpPortOverride { get; set; }

    /// Чи ввімкнено веб-слайди (на Mac — `outputs[.web].isEnabled`).
    public bool IsWebEnabled { get; private set; }

    WebOutputSettings? _webSettings;
    OutputRules? _webRules;
    bool _webHooked, _webApplied, _webScheduled;

    /// Мережеві налаштування веб-виводу (на Mac — `outputs.web`): спершу з Slovo.ini.
    public WebOutputSettings WebSettings
    {
        get
        {
            if (_webSettings is { } ready) return ready;
            IniSettings? config = null;
            try { if (IniSettings.LocateConfig() is { } ini) config = IniSettings.FromFile(ini); } catch { }
            var configuration = new OutputConfiguration(config, WebDataRoot);
            _webSettings = configuration.Web;
            _webRules = configuration[OutputKind.Web];
            IsWebEnabled = configuration[OutputKind.Web].IsEnabled;
            return configuration.Web;
        }
    }

    /// Тека даних поруч із модулями — там лежить `RemoteAPI`.
    string WebDataRoot =>
        Path.GetDirectoryName(ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')) is { Length: > 0 } root ? root : DataHome.Folder;

    /// Що ушло на сторінки останнім — для перевірок.
    public RemoteSlidePayload? LastWebPayload { get; private set; }

    /// «Параметри» → веб-вивід (як частина applyProgramOptions на Mac).
    void ApplyWebOutput(ProgramOptions options)
    {
        if (!_webHooked)
        {
            _webHooked = true;
            LiveChanged += ScheduleWebPublish;
            // «Ок» у «Параметрах» — і сервер іде за новими портами.
            SettingsStore.Shared.Changed += () => Dispatcher.UIThread.Post(() => ApplyWebOutput(SettingsStore.Shared.Settings.Options));
        }
        // Знімки без екрана сервера не піднімають — хіба що перевірці дали свої порти.
        if (Program.Snapshotting && WebPortOverride == null) return;

        // Початкова сторінка перелічує рівно те, що стоїть у списку «Web слайди».
        var pages = SettingsStore.Shared.Settings.WebSlides
            .Select(entry => WebOutputSettings.WebPage.Make(entry.FileName, entry.Details.Length == 0 ? entry.Name : entry.Details))
            .ToList();
        var current = WebSettings;
        var wanted = current;
        if (WebPortOverride is { } port)
        {
            wanted.HttpEnabled = true;
            wanted.HttpPort = port;
            wanted.WebSocketEnabled = true;
            wanted.WebSocketPort = WebSocketPortOverride ?? port + 1;
            wanted.TcpEnabled = TcpPortOverride != null;
            wanted.TcpPort = TcpPortOverride ?? wanted.TcpPort;
            wanted.UdpEnabled = UdpPortOverride != null;
            wanted.UdpPort = UdpPortOverride ?? wanted.UdpPort;
        }
        else
        {
            wanted.HttpEnabled = options.WebEnabled;
            wanted.HttpPort = options.WebPort;
            wanted.WebSocketEnabled = options.WebSocketEnabled;
            wanted.WebSocketPort = options.WebSocketPort;
            wanted.TcpEnabled = options.TcpEnabled;
            wanted.TcpPort = options.TcpPort;
            wanted.UdpEnabled = options.UdpEnabled;
            wanted.UdpPort = options.UdpPort;
        }
        // Сервер піднімається заново лише тоді, коли щось мережеве справді змінилося.
        var changed = !_webApplied
            || current.HttpPort != wanted.HttpPort || current.WebSocketPort != wanted.WebSocketPort
            || current.HttpEnabled != wanted.HttpEnabled || current.WebSocketEnabled != wanted.WebSocketEnabled
            || current.TcpEnabled != wanted.TcpEnabled || current.TcpPort != wanted.TcpPort
            || current.UdpEnabled != wanted.UdpEnabled || current.UdpPort != wanted.UdpPort
            || (pages.Count > 0 && !current.Pages.SequenceEqual(pages));
        if (pages.Count > 0) wanted.Pages = new ValueList<WebOutputSettings.WebPage>(pages);
        _webSettings = wanted;
        _webApplied = true;
        if (!changed) return;
        SetWebEnabled(false);
        if (wanted.HttpEnabled || wanted.WebSocketEnabled || wanted.TcpEnabled || wanted.UdpEnabled) SetWebEnabled(true);
    }

    /// Застосувати налаштування веб-виводу зараз (перевірки: вікно без головного вікна й бібліотеки).
    public void ApplyWebOutputNow() => ApplyWebOutput(SettingsStore.Shared.Settings.Options);

    /// Увімкнути або вимкнути веб-слайди.
    public void SetWebEnabled(bool enabled)
    {
        IsWebEnabled = enabled;
        if (!enabled) { Web.Stop(); return; }

        Web.Mode = RemoteSlidePayload.Modes.Bible;
        Web.ModuleNames = new[] { PrimaryModuleID }.Concat(SecondaryModuleIDs)
            .Select(Module).OfType<TextModule>()
            .Select(module => new RemoteModuleName(module.Info.ShortName.Length == 0 ? module.Identifier : module.Info.ShortName, module.Info.Name))
            .ToList();
        // Заготовки для Біблії й пісень — готовими сторінками в списку.
        var settings = WebSettings;
        if (WebSlideSeeder.Seed(SettingsStore.Shared) > 0 || settings.Pages.Count == 0)
        {
            settings.Pages = new ValueList<WebOutputSettings.WebPage>(SettingsStore.Shared.Settings.WebSlides
                .Select(entry => WebOutputSettings.WebPage.Make(entry.FileName, entry.Details.Length == 0 ? entry.Name : entry.Details)));
            _webSettings = settings;
        }
        // Значок вкладки — наш: у теці авторських сторінок лежить favicon.ico старої програми.
        var options = new WebOutputServer.Options { Favicon = WebFavicon.Value, AllowsPortFallback = WebPortOverride == null };
        Web.Start(settings, WebDataRoot, options);
        var status = Web.CurrentStatus;
        Journal.Say($"веб-слайди: сторінки {(status.HttpPort is { } h ? h.ToString() : "—")}, WebSocket {(status.WebSocketPort is { } w ? w.ToString() : "—")}"
                    + (status.LastError is { } error ? $" — {error}" : "") + (status.Notices.Count > 0 ? " · " + string.Join(" · ", status.Notices) : ""));
        // На Mac тут іде підготовлений слайд; сторінка має показувати те, що в залі, —
        // це й шле наступний же прохід. Шлемо зал одразу, без проміжного кадру.
        PublishToWeb();
    }

    /// Перемальовування сторінок — на наступному проході циклу, склеєне.
    void ScheduleWebPublish()
    {
        if (!IsWebEnabled || _webScheduled) return;
        _webScheduled = true;
        Dispatcher.UIThread.Post(() => { _webScheduled = false; PublishToWeb(); }, DispatcherPriority.Background);
    }

    /// Те, що бачить зал, — на веб-сторінки (як частина pushToOutputs на Mac).
    void PublishToWeb()
    {
        if (!IsWebEnabled) return;
        var hall = HallSlide;
        var still = IsLive && !IsBlackout ? LiveStill : null;
        // Поки в залі кадр плеєра чи картинка показу, на сторінці стояв би вірш, уже знятий
        // з проектора: віддаємо сторінці те саме, що й залу, — картинкою фону розкладки,
        // а під фільм — порожнечу (кіно в браузер цим каналом не передати).
        if (still != null || _media?.IsVideoOnScreen == true)
        {
            PublishStillToWeb(still);
            return;
        }
        // Розкладку шаблону — разом зі слайдом: `slovo-slide.html` малює за нею ті самі
        // об'єкти, що й проектор. Сторінки автора цієї секції не читають.
        SlidePreset? preset = null;
        try { preset = Preset(OutputKind.Web) ?? (IsBlackout ? null : Preset(OutputKind.Screen)); } catch { }
        var texts = Texts(LiveSlide, live: true);
        Web.SetTemplate(preset, hall.SecondaryTexts.Count > 0, item => texts.Text(item), name => PresetImagePath(name), SlideFonts.FileFor);
        var outgoing = (_webRules ?? new OutputRules()).Compose(hall);
        LastWebPayload = RemoteSlidePayload.From(outgoing, Web.Mode, Web.ModuleNames);
        Web.Publish(outgoing, OutputKind.Web);
    }

    (string Still, string Id)? _webStill;
    int _webStillCounter;

    /// Картинка показу — на веб-сторінку: окремою розкладкою, а не новим полем протоколу.
    void PublishStillToWeb(string? still)
    {
        var layout = new WebSlideLayout
        {
            Background = new WebSlideLayout.BackgroundInfo(SlideStyle.RGBA.Black, still == null ? null : WebStillID(still), "contain"),
        };
        var payload = RemoteSlidePayload.From(Slide.Blank, Web.Mode, Web.ModuleNames) with { Layout = layout };
        LastWebPayload = payload;
        Web.Publish(payload);
    }

    /// Записати показану картинку файлом і віддати її коротке ім'я. Кожній новій
    /// сторінці — своє ім'я: браузер тримає картинки в пам'яті за адресою.
    string? WebStillID(string still)
    {
        var focus = SlideFocus.Shared.ShownRect;
        var key = still + "|" + focus;
        if (_webStill is { } known && known.Still == key) return known.Id;
        if (SlideImageStore.Shared.Image(still) is not { } image) return null;
        try
        {
            var folder = Path.Combine(Path.GetTempPath(), "slovo-web-still");
            Directory.CreateDirectory(folder);
            _webStillCounter++;
            var file = Path.Combine(folder, $"страница-{_webStillCounter}.jpg");
            // У веб іде те саме, що в зал: уже вирізане точкою фокуса.
            var source = SlideFocus.Crop(image, focus);
            var width = Math.Max(1, (int)Math.Round(source.Width));
            var height = Math.Max(1, (int)Math.Round(source.Height));
            using (var surface = SKSurface.Create(new SKImageInfo(width, height)))
            {
                using var paint = new SKPaint { FilterQuality = SKFilterQuality.High };
                surface.Canvas.DrawImage(image, source, SKRect.Create(0, 0, width, height), paint);
                using var snapshot = surface.Snapshot();
                using var jpeg = snapshot.Encode(SKEncodedImageFormat.Jpeg, 90);
                using var stream = File.Create(file);
                jpeg.SaveTo(stream);
            }
            var id = Web.RegisterImage($"media-still-{_webStillCounter}", file);
            _webStill = (key, id);
            return id;
        }
        catch (Exception error)
        {
            Journal.Say($"веб-слайди: картинка показу не записалась — {error.Message}");
            return null;
        }
    }

    /// Значок програми в PNG 64×64 — для вкладки браузера.
    static readonly Lazy<byte[]?> WebFavicon = new(() =>
    {
        try
        {
            using var asset = Avalonia.Platform.AssetLoader.Open(new Uri("avares://Slovo/Resources/AppIcon-256.png"));
            using var bitmap = SKBitmap.Decode(asset);
            if (bitmap == null) return null;
            using var small = bitmap.Resize(new SKImageInfo(64, 64), SKFilterQuality.High);
            using var image = SKImage.FromBitmap(small);
            using var png = image.Encode(SKEncodedImageFormat.Png, 100);
            return png.ToArray();
        }
        catch { return null; }
    });
}
