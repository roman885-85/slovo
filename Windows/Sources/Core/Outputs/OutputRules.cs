// =============================================================================
//  OutputRules.cs — правила виводів (з Outputs/OutputRules.swift)
// =============================================================================
//  Swift-структури лишилися значеннями: OutputRules і WebOutputSettings —
//  record struct; OutputConfiguration — struct, словник правил у якому ніколи
//  не змінюється на місці (запис через індексатор кладе новий), тож копія
//  конфігурації не тягне за собою оригінал.
//
//  `WebOutputSettings.Make` і `DiscoverPages` — з Web/WebOutputSettings+Init.swift:
//  без них не зібрати OutputConfiguration. Решта теки Web — третьою частиною;
//  тоді цей шматок переїде в Web/WebOutputSettings+Init.cs.
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Куди йде слайд. Кожен вивід — самостійний канал зі своїми правилами, а не
/// копія сусіднього: на проектор — картинка з фоном, у NDI — той самий напис,
/// часто на прозорому фоні, у веб — HTML, служителю — наступний вірш.
[JsonConverter(typeof(SwiftStringEnumConverter<OutputKind>))]
public enum OutputKind
{
    [JsonStringEnumMemberName("screen")] Screen,     // проектор або другий монітор
    [JsonStringEnumMemberName("preview")] Preview,   // передпоказ у вікні керування
    [JsonStringEnumMemberName("ndi")] Ndi,           // мережева трансляція на відеомікшер
    [JsonStringEnumMemberName("web")] Web,           // веб-слайди в браузері
    [JsonStringEnumMemberName("stage")] Stage,       // екран для служителя
}

public static class OutputKinds
{
    public static readonly IReadOnlyList<OutputKind> All =
        [OutputKind.Screen, OutputKind.Preview, OutputKind.Ndi, OutputKind.Web, OutputKind.Stage];

    public static string RawValue(this OutputKind kind) => kind switch
    {
        OutputKind.Screen => "screen",
        OutputKind.Preview => "preview",
        OutputKind.Ndi => "ndi",
        OutputKind.Web => "web",
        _ => "stage",
    };

    public static OutputKind? FromRaw(string raw) => All.Cast<OutputKind?>().FirstOrDefault(kind => kind!.Value.RawValue() == raw);

    public static string Title(this OutputKind kind) => kind switch
    {
        OutputKind.Screen => OurWords.T("Монитор"),
        OutputKind.Preview => OurWords.T("Предпросмотр"),
        OutputKind.Ndi => OurWords.T("NDI трансляция"),
        OutputKind.Web => OurWords.T("Web слайды"),
        _ => OurWords.T("Экран служителя"),
    };
}

/// Правила одного виводу: що малювати і як.
public record struct OutputRules
{
    public bool IsEnabled;
    public SlideStyle Style;

    /// Фон підкладки. NDI зазвичай віддають без фону, щоб мікшер поклав напис
    /// поверх своєї картинки, — за це відповідає `NdiTransparentBackGr`.
    public bool DrawsBackground;
    public bool ShowsReference;
    public bool ShowsSecondaryTranslations;
    public bool ShowsVerseNumbers;

    /// Лише для потокових виводів.
    public int FrameRate;
    public bool SendsVideo;
    public bool SendsOnlyChanged;
    /// Звук програми — у трансляцію. Своя настройка: в оригіналу її немає.
    public bool SendsAudio;
    /// Висота кадру трансляції; 0 — як у слайда. Своя настройка: по Wi-Fi
    /// 1080p без стиснення не проходить, 720p і 540p — удвічі-вчетверо легші.
    public int FrameHeight;

    public OutputRules() : this(style: null) { }

    public OutputRules(SlideStyle? style = null,
                       bool isEnabled = false,
                       bool drawsBackground = true,
                       bool showsReference = true,
                       bool showsSecondaryTranslations = true,
                       bool showsVerseNumbers = false,
                       int frameRate = 30,
                       bool sendsVideo = false,
                       bool sendsOnlyChanged = true)
    {
        Style = style ?? new SlideStyle();
        IsEnabled = isEnabled;
        DrawsBackground = drawsBackground;
        ShowsReference = showsReference;
        ShowsSecondaryTranslations = showsSecondaryTranslations;
        ShowsVerseNumbers = showsVerseNumbers;
        FrameRate = frameRate;
        SendsVideo = sendsVideo;
        SendsOnlyChanged = sendsOnlyChanged;
        SendsAudio = true;
        FrameHeight = 0;
    }

    /// Готує вміст слайда під правила саме цього виводу.
    public readonly Slide Compose(Slide slide)
    {
        if (slide.IsBlank) return slide;
        var result = slide;
        if (!ShowsSecondaryTranslations) result.SecondaryTexts = Array.Empty<string>();
        if (!ShowsReference) result.Reference = "";
        return result;
    }

    /// Стиль з урахуванням правил виводу — наприклад, без підкладки для NDI.
    public readonly SlideStyle EffectiveStyle
    {
        get
        {
            if (DrawsBackground) return Style;
            var stripped = Style;
            stripped.BackgroundImagePath = null;
            stripped.BackgroundColor = new SlideStyle.RGBA(0, 0, 0, 0);
            stripped.DimBackground = 0;
            return stripped;
        }
    }
}

/// Мережеві параметри веб-виводу — порти й адреси з `[RemoteApi]`.
public record struct WebOutputSettings
{
    public bool HttpEnabled;
    public int HttpPort;
    public bool WebSocketEnabled;
    public int WebSocketPort;
    public bool TcpEnabled;
    public int TcpPort;
    public bool UdpEnabled;
    public int UdpPort;
    /// Шаблони сторінок з теки RemoteAPI — «свої преднастройки» веб-виводу.
    /// Список не змінюється на місці: нові сторінки — новий список.
    public ValueList<WebPage> Pages;

    public readonly record struct WebPage(string FileName, string Title)
    {
        public string Id => FileName;

        /// `WebPage.make(fileName:title:)`.
        public static WebPage Make(string fileName, string title) => new(fileName, title);
    }

    // ── З Web/WebOutputSettings+Init.swift ──────────────────────────────────

    /// Налаштування веб-виводу без ini: оператор міняє порт у налаштуваннях, а
    /// перевірочні прогони піднімають сервер на вільному порту взагалі без ini.
    public static WebOutputSettings Make(bool httpEnabled = true,
                                         int httpPort = 82,
                                         bool webSocketEnabled = true,
                                         int webSocketPort = 8100,
                                         bool tcpEnabled = false,
                                         int tcpPort = 8101,
                                         bool udpEnabled = false,
                                         int udpPort = 8100,
                                         IEnumerable<WebPage>? pages = null) => new()
    {
        HttpEnabled = httpEnabled,
        HttpPort = httpPort,
        WebSocketEnabled = webSocketEnabled,
        WebSocketPort = webSocketPort,
        TcpEnabled = tcpEnabled,
        TcpPort = tcpPort,
        UdpEnabled = udpEnabled,
        UdpPort = udpPort,
        Pages = new ValueList<WebPage>(pages ?? Array.Empty<WebPage>()),
    };

    /// Сторінки, що лежать у теці `RemoteAPI` і у своїй теці власника.
    ///
    /// Своя тека сюди потрапила не одразу, і сторінки, зроблені в майстерні,
    /// сервер віддавав, але ніде не показував: ні в списку Remote API, ні на
    /// домашній сторінці. Людина зберігала свій шаблон і не знаходила його.
    public static ValueList<WebPage> DiscoverPages(string folder)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        var pages = new ValueList<WebOutputSettings.WebPage>();
        // Своя тека — `WebOutputServer.userPagesFolder` на Mac: WebSlides у домі даних.
        foreach (var root in new[] { folder, Path.Combine(DataHome.Folder, "WebSlides") })
        {
            var files = SwiftPath.Contents(root, skipsHidden: false)
                .Where(file => SwiftPath.Extension(file).ToLowerInvariant() == "html")
                .OrderBy(SwiftPath.LastComponent, StringComparer.Ordinal);
            foreach (var file in files)
            {
                var name = SwiftPath.LastComponent(file);
                if (!seen.Add(name.ToLowerInvariant())) continue;
                pages.Add(new WebPage(name, SwiftPath.LastComponent(SwiftPath.DeletingExtension(file))));
            }
        }
        return pages;
    }
}

/// Набір правил для всіх виводів одразу.
public partial struct OutputConfiguration
{
    private Dictionary<OutputKind, OutputRules> rules;

    public readonly IReadOnlyDictionary<OutputKind, OutputRules> Rules => rules;
    public WebOutputSettings Web;

    public OutputRules this[OutputKind kind]
    {
        readonly get => rules != null && rules.TryGetValue(kind, out var found) ? found : new OutputRules();
        set => rules = new Dictionary<OutputKind, OutputRules>(rules ?? new Dictionary<OutputKind, OutputRules>()) { [kind] = value };
    }

    /// Частоти кадрів NDI в тому самому порядку, в якому їх перелічує оригінал:
    /// `NdiFpsId` — це індекс у списку, а не саме число.
    ///
    /// Список знято зі знімка розкритого списку у власника: чотирнадцять
    /// значень, і шістдесяте стоїть тринадцятим, якщо рахувати з нуля, —
    /// рівно як `NdiFpsId=13` у його налаштуваннях. Колишній наш список був
    /// вигаданий (1, 2, 3, 4, 5, 6, 8, 10, …) і давав за тим самим номером 30.
    /// Дробові частоти мовлення лишаємо дробовими: це не причіпка, 59,94 і
    /// 60 — різні речі для відеомікшера.
    public static readonly IReadOnlyList<double> NdiFrameRates =
        [10, 12, 12.5, 14.985, 15, 23.976, 24, 25, 29.97, 30, 48, 50, 59.94, 60];

    /// Підписи зі списку автора — їх і показуємо людині.
    public static readonly IReadOnlyList<string> NdiFrameRateTitles =
    [
        "10", "12 Half Film", "12.5 Half PAL",
        "14.985 Half NTSC", "15 Multimedia",
        "23.976 IVTC Film", "24 NTSC Film", "25 PAL",
        "29.97 NTSC", "30 Double Multimedia",
        "48 Double NTSC Film", "50 Double PAL",
        "59.94 Double NTSC", "60",
    ];

    public OutputConfiguration(IniSettings? config, string? dataRoot)
    {
        var baseStyle = config != null ? new SlideStyle(config, "Bible", dataRoot) : new SlideStyle();

        var screen = new OutputRules(baseStyle, isEnabled: true);
        screen.ShowsVerseNumbers = config?.Bool("ShowVersNum", "OutScreen") ?? false;

        var preview = screen;
        preview.IsEnabled = true;

        // NDI: свої прапорці, своя частота, свій фон.
        var ndi = new OutputRules(baseStyle);
        ndi.IsEnabled = config?.Bool("NdiSendSlide", "OutScreen") ?? false;
        ndi.DrawsBackground = !(config?.Bool("NdiTransparentBackGr", "OutScreen") ?? false);
        ndi.SendsVideo = config?.Bool("NdiSendVideo", "OutScreen") ?? false;
        ndi.SendsOnlyChanged = config?.Bool("NdiSendOnlyChanged", "OutScreen") ?? true;
        ndi.SendsAudio = config?.Bool("NdiSendAudio", "OutScreen") ?? true;
        ndi.FrameHeight = config?.Int("NdiFrameHeight", "OutScreen") ?? 0;
        var fpsIndex = config?.Int("NdiFpsId", "OutScreen") ?? 13;
        ndi.FrameRate = fpsIndex >= 0 && fpsIndex < NdiFrameRates.Count
            ? (int)Math.Round(NdiFrameRates[fpsIndex], MidpointRounding.AwayFromZero)
            : 30;

        // Веб малює не картинку, а HTML — оформлення задає його шаблон,
        // тому стиль тут лише для підстановки кольорів і шрифтів.
        var web = new OutputRules(baseStyle);
        web.IsEnabled = config?.Bool("WEBEnabled", "RemoteApi") ?? false;

        // Екран служителя: без фону і без другого перекладу, зате крупно.
        var stage = new OutputRules(baseStyle);
        stage.DrawsBackground = false;
        stage.ShowsSecondaryTranslations = false;

        rules = new Dictionary<OutputKind, OutputRules>
        {
            [OutputKind.Screen] = screen,
            [OutputKind.Preview] = preview,
            [OutputKind.Ndi] = ndi,
            [OutputKind.Web] = web,
            [OutputKind.Stage] = stage,
        };
        Web = new WebOutputSettings
        {
            HttpEnabled = config?.Bool("WEBEnabled", "RemoteApi") ?? false,
            HttpPort = config?.Int("WEBPort", "RemoteApi") ?? 82,
            WebSocketEnabled = config?.Bool("WSEnabled", "RemoteApi") ?? false,
            WebSocketPort = config?.Int("WSPort", "RemoteApi") ?? 8100,
            TcpEnabled = config?.Bool("TCPEnabled", "RemoteApi") ?? false,
            TcpPort = config?.Int("TCPPort", "RemoteApi") ?? 8101,
            UdpEnabled = config?.Bool("UDPEnabled", "RemoteApi") ?? false,
            UdpPort = config?.Int("UDPPort", "RemoteApi") ?? 8100,
            Pages = dataRoot == null ? new ValueList<WebOutputSettings.WebPage>() : WebOutputSettings.DiscoverPages(Path.Combine(dataRoot, "RemoteAPI")),
        };
    }
}
