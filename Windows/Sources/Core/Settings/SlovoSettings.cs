// =============================================================================
//  SlovoSettings.cs — усе з вікна «Параметри» (з Settings/SlovoSettings.swift)
// =============================================================================
//  Формат settings.json — той самий, що пише Mac (JSONEncoder, ключі Swift):
//  файл з Mac читається тут і навпаки. Як і в Swift, читання суворе: бракує
//  обов'язкового поля — файл не приймається, і програма бере умовчання з ini.
// =============================================================================

using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace Slovo.Core;

/// (1) «Реакція на кнопки» — по натисканню або по відпусканню
/// (у Swift — `ProgramOptions.ButtonAction`).
[JsonConverter(typeof(SwiftIntEnumConverter<ButtonAction>))]
public enum ButtonAction { OnPress = 0, OnRelease = 1 }

/// (2) «При показі слайда на передній план»: головне вікно (два монітори)
/// або вікно слайда (один монітор) (`ProgramOptions.Foreground`).
[JsonConverter(typeof(SwiftIntEnumConverter<Foreground>))]
public enum Foreground { MainWindow = 0, SlideWindow = 1 }

/// «Режим мінікартинок»: системний провідник або вбудований переглядач
/// (`ProgramOptions.ThumbsMode`).
[JsonConverter(typeof(SwiftIntEnumConverter<ThumbsMode>))]
public enum ThumbsMode { System = 0, BuiltIn = 1 }

/// (18) і (19): «Довгий» — повна назва книги, «Короткий» — скорочення
/// (`ProgramOptions.AddressStyle`). Порядок значень — як в автора.
[JsonConverter(typeof(SwiftIntEnumConverter<AddressStyle>))]
public enum AddressStyle { Long = 0, Short = 1 }

/// Усе, що налаштовується у вікні «Параметри» (розділ 6.1 посібника).
///
/// Поля названо за ключами ini, щоб при звірці з оригіналом не
/// доводилося тримати в голові ще один словник імен. Значення за умовчанням
/// — ті самі, що підставляє стара програма при першому запуску.
///
/// Перелічення винесено на рівень простору імен: у C# вкладений тип і
/// властивість з однаковим ім'ям (`ButtonAction ButtonAction`) не уживаються.
public sealed record ProgramOptions
{
    // ── Основні (6.1.1) ─────────────────────────────────────────────────────

    [JsonRequired, JsonPropertyName("buttonAction")] public ButtonAction ButtonAction { get; set; } = ButtonAction.OnPress;
    [JsonRequired, JsonPropertyName("foreground")] public Foreground Foreground { get; set; } = Foreground.MainWindow;
    [JsonRequired, JsonPropertyName("percentFillingPage")] public int PercentFillingPage { get; set; } = 30;
    [JsonRequired, JsonPropertyName("animationFrequency")] public int AnimationFrequency { get; set; } = 30;
    /// Номер монітора в нумерації оригіналу: 1 — основний, 0 — ручне налаштування.
    [JsonRequired, JsonPropertyName("monitorIndex")] public int MonitorIndex { get; set; } = 1;
    [JsonRequired, JsonPropertyName("defaultWidth")] public int DefaultWidth { get; set; } = 1024;
    [JsonRequired, JsonPropertyName("defaultHeight")] public int DefaultHeight { get; set; } = 768;
    [JsonRequired, JsonPropertyName("customLeft")] public int CustomLeft { get; set; }
    [JsonRequired, JsonPropertyName("customTop")] public int CustomTop { get; set; }
    [JsonRequired, JsonPropertyName("customWidth")] public int CustomWidth { get; set; } = 800;
    [JsonRequired, JsonPropertyName("customHeight")] public int CustomHeight { get; set; } = 600;
    [JsonRequired, JsonPropertyName("loadAllBooks")] public bool LoadAllBooks { get; set; } = true;
    [JsonRequired, JsonPropertyName("lazyLoadModules")] public bool LazyLoadModules { get; set; } = true;
    [JsonRequired, JsonPropertyName("thumbsMode")] public ThumbsMode ThumbsMode { get; set; } = ThumbsMode.System;

    // ── Додаткові (6.1.2) ───────────────────────────────────────────────────

    /// (10) і (11) — у мілісекундах, як в оригіналі.
    [JsonRequired, JsonPropertyName("crossfadeTime")] public int CrossfadeTime { get; set; }
    /// Перехід слайда (ім'я з SlideStyle.Transition) і його крива.
    [JsonPropertyName("slideTransition")] public string? SlideTransition { get; set; }
    [JsonPropertyName("slideTransitionEasing")] public string? SlideTransitionEasing { get; set; }
    /// Гасіння залу: тривалість у мілісекундах і крива.
    [JsonPropertyName("hideFadeTime")] public int? HideFadeTime { get; set; }
    [JsonPropertyName("hideFadeEasing")] public string? HideFadeEasing { get; set; }
    /// Кілька віршів на слайді — кожен з нового рядка і зі своїм номером.
    [JsonPropertyName("versesOnOwnLines")] public bool? VersesOnOwnLines { get; set; }
    /// Перехід між сторінками показу і зображеннями — окремий від слайда.
    [JsonPropertyName("showTransition")] public string? ShowTransition { get; set; }
    [JsonPropertyName("showTransitionEasing")] public string? ShowTransitionEasing { get; set; }
    /// У мілісекундах, як і `CrossfadeTime`.
    [JsonPropertyName("showTransitionTime")] public int? ShowTransitionTime { get; set; }
    [JsonRequired, JsonPropertyName("hideSlideTime")] public int HideSlideTime { get; set; }
    /// (12) «Дублювання слайда на монітори» — список описів моніторів із `DoubleMonitors`.
    [JsonRequired, JsonPropertyName("doubleMonitors")] public ValueList<string> DoubleMonitors { get; set; } = new();
    /// (13) «Маркер останньої частини пісні».
    [JsonRequired, JsonPropertyName("songsEndMarker")] public string SongsEndMarker { get; set; } = "";
    /// (14) «Шукати по BackSpace у "Швидк. виборі"».
    [JsonRequired, JsonPropertyName("fastInputUseBackSpace")] public bool FastInputUseBackSpace { get; set; } = true;
    /// (15) «Розділ. лінією по 10 віршів».
    [JsonRequired, JsonPropertyName("separatorTenVerses")] public bool SeparatorTenVerses { get; set; } = true;
    /// (16) «Колір активного поля вводу».
    [JsonRequired, JsonPropertyName("activeInputFieldColor")] public SlideStyle.RGBA ActiveInputFieldColor { get; set; } = new(1, 1, 0.94);
    /// (17) «Показувати номери віршів» — окремо для двох перекладів.
    [JsonRequired, JsonPropertyName("showVerseNumbers")] public bool ShowVerseNumbers { get; set; }
    [JsonRequired, JsonPropertyName("showSecondaryVerseNumbers")] public bool ShowSecondaryVerseNumbers { get; set; }
    [JsonRequired, JsonPropertyName("useRCPointer")] public bool UseRCPointer { get; set; }

    // ── Слайд (6.1.3) ───────────────────────────────────────────────────────

    [JsonRequired, JsonPropertyName("refAllMain")] public AddressStyle RefAllMain { get; set; } = AddressStyle.Long;
    [JsonRequired, JsonPropertyName("refAllSec")] public AddressStyle RefAllSec { get; set; } = AddressStyle.Short;
    [JsonRequired, JsonPropertyName("refMain")] public AddressStyle RefMain { get; set; } = AddressStyle.Long;
    [JsonRequired, JsonPropertyName("refSec")] public AddressStyle RefSec { get; set; } = AddressStyle.Long;
    [JsonRequired, JsonPropertyName("refsSeparated")] public bool RefsSeparated { get; set; }
    /// (20) «Режим відображення номера пісні в назві пісні».
    [JsonRequired, JsonPropertyName("songNumberPP")] public bool SongNumberPP { get; set; }
    [JsonRequired, JsonPropertyName("songNumberInCollection")] public bool SongNumberInCollection { get; set; } = true;
    [JsonRequired, JsonPropertyName("songNumberInBrackets")] public bool SongNumberInBrackets { get; set; }
    [JsonRequired, JsonPropertyName("songDotAfterNumber")] public bool SongDotAfterNumber { get; set; } = true;

    // ── Медіа (6.1.7) ───────────────────────────────────────────────────────

    /// Ідентифікатор звукового пристрою; 0 — «за умовчанням», як в оригіналі.
    [JsonRequired, JsonPropertyName("audioDeviceID")] public int AudioDeviceID { get; set; }
    [JsonRequired, JsonPropertyName("showVideoOnPreview")] public bool ShowVideoOnPreview { get; set; } = true;
    [JsonRequired, JsonPropertyName("ndiEnabled")] public bool NdiEnabled { get; set; }
    [JsonRequired, JsonPropertyName("ndiSendVideo")] public bool NdiSendVideo { get; set; }
    /// Звук програми в трансляцію. Необов'язкове поле навмисно: старий
    /// `settings.json` без нього має читатися. Порожньо — значить «так».
    [JsonPropertyName("ndiSendAudio")] public bool? NdiSendAudio { get; set; }
    /// Висота кадру NDI: 0 або порожньо — як у слайда, 720, 540.
    [JsonPropertyName("ndiFrameHeight")] public int? NdiFrameHeight { get; set; }
    /// Транспорт NDI: null/«auto» — як вирішує сам NDI (RUDP), «tcp» — лише TCP.
    [JsonPropertyName("ndiTransport")] public string? NdiTransport { get; set; }
    /// «Відео по Wi-Fi»: потік H.264/AAC (HLS) із кадром залу, `/wifi/`.
    [JsonPropertyName("webVideoEnabled")] public bool? WebVideoEnabled { get; set; }
    [JsonPropertyName("webVideoHeight")] public int? WebVideoHeight { get; set; }
    [JsonPropertyName("webVideoKbps")] public int? WebVideoKbps { get; set; }
    /// Друге джерело NDI «Слово Wi-Fi»: зменшений кадр і своя частота.
    [JsonPropertyName("ndiWiFiEnabled")] public bool? NdiWiFiEnabled { get; set; }
    [JsonPropertyName("ndiWiFiHeight")] public int? NdiWiFiHeight { get; set; }
    [JsonPropertyName("ndiWiFiFrameRate")] public int? NdiWiFiFrameRate { get; set; }
    /// Рівень звуку NDI в дБ: 20 — еталон SDK (за умовчанням), 0 — як є.
    [JsonPropertyName("ndiAudioGainDb")] public int? NdiAudioGainDb { get; set; }
    [JsonRequired, JsonPropertyName("ndiTransparentBackground")] public bool NdiTransparentBackground { get; set; }
    /// Індекс у списку частот `OutputConfiguration.NdiFrameRates`, а не сама частота.
    [JsonRequired, JsonPropertyName("ndiFrameRateIndex")] public int NdiFrameRateIndex { get; set; } = 13;

    // ── Remote API (6.1.8) ──────────────────────────────────────────────────

    [JsonRequired, JsonPropertyName("webEnabled")] public bool WebEnabled { get; set; }
    [JsonRequired, JsonPropertyName("webPort")] public int WebPort { get; set; } = 82;
    [JsonRequired, JsonPropertyName("webNetInterface")] public string WebNetInterface { get; set; } = "";
    [JsonRequired, JsonPropertyName("webSocketEnabled")] public bool WebSocketEnabled { get; set; }
    [JsonRequired, JsonPropertyName("webSocketPort")] public int WebSocketPort { get; set; } = 8100;
    [JsonRequired, JsonPropertyName("tcpEnabled")] public bool TcpEnabled { get; set; }
    [JsonRequired, JsonPropertyName("tcpPort")] public int TcpPort { get; set; } = 8101;
    [JsonRequired, JsonPropertyName("udpEnabled")] public bool UdpEnabled { get; set; }
    [JsonRequired, JsonPropertyName("udpPort")] public int UdpPort { get; set; } = 8100;

    // ── Пульт на телефоні (свій канал, в автора його немає) ─────────────────

    /// Необов'язкові: старий `settings.json` без цих ключів зобов'язаний читатися.
    [JsonPropertyName("remoteEnabled")] public bool? RemoteEnabled { get; set; }
    [JsonPropertyName("remotePort")] public int? RemotePort { get; set; }
    [JsonPropertyName("remotePin")] public string? RemotePin { get; set; }

    // ── Пульт у браузері (свій порт, свій пароль) ───────────────────────────

    [JsonPropertyName("remoteWebEnabled")] public bool? RemoteWebEnabled { get; set; }
    [JsonPropertyName("remoteWebPort")] public int? RemoteWebPort { get; set; }
    [JsonPropertyName("remoteWebPassword")] public string? RemoteWebPassword { get; set; }
    /// Ім'я в мережі без «.local»: slovo → slovo.local.
    [JsonPropertyName("remoteWebName")] public string? RemoteWebName { get; set; }
    /// Лише перегляд: сторінка показує зал, але не керує.
    [JsonPropertyName("remoteWebViewOnly")] public bool? RemoteWebViewOnly { get; set; }
    /// Відкривати й без номера порту (порт 80, якщо вільний).
    [JsonPropertyName("remoteWebNoPort")] public bool? RemoteWebNoPort { get; set; }

    // ── Указка (своя; в автора її немає) ────────────────────────────────────

    /// Колір «#RRGGBB», діаметр — частка висоти кадру, яскравість — непрозорість.
    [JsonPropertyName("pointerColour")] public string? PointerColour { get; set; }
    [JsonPropertyName("pointerSize")] public double? PointerSize { get; set; }
    [JsonPropertyName("pointerOpacity")] public double? PointerOpacity { get; set; }
    [JsonPropertyName("pointerProjector")] public bool? PointerProjector { get; set; }
    [JsonPropertyName("pointerNDI")] public bool? PointerNDI { get; set; }

    // ── Оновлення ───────────────────────────────────────────────────────────

    /// «Інтервал перевірки оновлень» у днях: 0 — ніколи, 7, 30, 365.
    [JsonRequired, JsonPropertyName("updateInterval")] public int UpdateInterval { get; set; } = 7;

    public ProgramOptions() { }

    /// Розбір ini. Усе, чого у файлі немає, лишається зі значенням за
    /// умовчанням — наполовину прочитаний конфіг гірший за порожній.
    public ProgramOptions(IniSettings config)
    {
        // Основні. `showversbypressdown` в оригіналі означає «реагувати по натисканню».
        ButtonAction = config.Bool("showversbypressdown", "settings") ?? false ? ButtonAction.OnPress : ButtonAction.OnRelease;
        Foreground = config.Bool("SetMainformForeground", "settings") ?? true ? Foreground.MainWindow : Foreground.SlideWindow;
        PercentFillingPage = config.Int("percentfillingpage", "OutScreen") ?? PercentFillingPage;
        AnimationFrequency = config.Int("AnimTimerFreq", "OutScreen") ?? AnimationFrequency;
        MonitorIndex = config.Int("monitor", "OutScreen") ?? MonitorIndex;
        DefaultWidth = config.Int("width", "OutScreen") ?? DefaultWidth;
        DefaultHeight = config.Int("height", "OutScreen") ?? DefaultHeight;
        CustomLeft = config.Int("CustomLeft", "OutScreen") ?? CustomLeft;
        CustomTop = config.Int("CustomTop", "OutScreen") ?? CustomTop;
        CustomWidth = config.Int("CustomWidth", "OutScreen") ?? CustomWidth;
        CustomHeight = config.Int("CustomHeight", "OutScreen") ?? CustomHeight;
        LoadAllBooks = config.Bool("LoadAllBooks", "settings") ?? LoadAllBooks;
        LazyLoadModules = config.Bool("LazyLoadModule", "settings") ?? LazyLoadModules;
        var thumbs = config.Int("ThumbsMode", "settings") ?? 0;
        ThumbsMode = Enum.IsDefined((ThumbsMode)thumbs) ? (ThumbsMode)thumbs : ThumbsMode.System;

        // Додаткові
        CrossfadeTime = config.Int("CrossfadeTime", "OutScreen") ?? CrossfadeTime;
        SlideTransition = config.String("SlideTransition", "OutScreen") ?? SlideTransition;
        SlideTransitionEasing = config.String("SlideTransitionEasing", "OutScreen") ?? SlideTransitionEasing;
        HideSlideTime = config.Int("HideSlideTime", "OutScreen") ?? HideSlideTime;
        DoubleMonitors = new ValueList<string>((config.String("DoubleMonitors", "OutScreen") ?? "")
            .Split(',', StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.TrimWhitespaces())
            .Where(part => part.Length > 0));
        SongsEndMarker = config.String("SongsEndChunkPostText", "settings") ?? SongsEndMarker;
        FastInputUseBackSpace = config.Bool("FastInputUseBackSpace", "settings") ?? FastInputUseBackSpace;
        SeparatorTenVerses = config.Bool("SeparatorTenLine", "Bible") ?? SeparatorTenVerses;
        ActiveInputFieldColor = config.Color("ActiveInputFieldColor", "settings") ?? ActiveInputFieldColor;
        ShowVerseNumbers = config.Bool("ShowVersNum", "OutScreen") ?? ShowVerseNumbers;
        ShowSecondaryVerseNumbers = config.Bool("ShowExtraQuoteVersNum", "OutScreen") ?? ShowSecondaryVerseNumbers;
        UseRCPointer = config.Bool("UseRCPointer", "settings") ?? UseRCPointer;

        // Слайд
        RefAllMain = Address(config.Int("RefAllMainType", "settings") ?? 0, AddressStyle.Long);
        RefAllSec = Address(config.Int("RefAllSecType", "settings") ?? 1, AddressStyle.Short);
        RefMain = Address(config.Int("RefMainType", "settings") ?? 0, AddressStyle.Long);
        RefSec = Address(config.Int("RefSecType", "settings") ?? 0, AddressStyle.Long);
        RefsSeparated = config.Bool("RefsSeparated", "settings") ?? RefsSeparated;
        SongNumberPP = config.Bool("SongNameWithNumPP", "settings") ?? SongNumberPP;
        SongNumberInCollection = config.Bool("SongNameWithNumInCollection", "settings") ?? SongNumberInCollection;
        SongNumberInBrackets = config.Bool("SongNameWithNumInCollectionInBrackets", "settings") ?? SongNumberInBrackets;
        SongDotAfterNumber = config.Bool("SongNameDotAfterNum", "settings") ?? SongDotAfterNumber;

        // Медіа
        AudioDeviceID = config.Int("MediaDefaultAudioDevice", "mediaplayer") ?? AudioDeviceID;
        ShowVideoOnPreview = config.Bool("VideoToPreview", "mediaplayer") ?? ShowVideoOnPreview;
        NdiEnabled = config.Bool("NdiSendSlide", "OutScreen") ?? NdiEnabled;
        NdiSendVideo = config.Bool("NdiSendVideo", "OutScreen") ?? NdiSendVideo;
        NdiSendAudio = config.Bool("NdiSendAudio", "OutScreen") ?? NdiSendAudio;
        NdiFrameHeight = config.Int("NdiFrameHeight", "OutScreen") ?? NdiFrameHeight;
        NdiTransport = config.String("NdiTransport", "OutScreen") ?? NdiTransport;
        WebVideoEnabled = config.Bool("WebVideo", "OutScreen") ?? WebVideoEnabled;
        WebVideoHeight = config.Int("WebVideoHeight", "OutScreen") ?? WebVideoHeight;
        WebVideoKbps = config.Int("WebVideoKbps", "OutScreen") ?? WebVideoKbps;
        NdiWiFiEnabled = config.Bool("NdiWiFi", "OutScreen") ?? NdiWiFiEnabled;
        NdiWiFiHeight = config.Int("NdiWiFiHeight", "OutScreen") ?? NdiWiFiHeight;
        NdiWiFiFrameRate = config.Int("NdiWiFiFps", "OutScreen") ?? NdiWiFiFrameRate;
        NdiAudioGainDb = config.Int("NdiAudioGainDb", "OutScreen") ?? NdiAudioGainDb;
        NdiTransparentBackground = config.Bool("NdiTransparentBackGr", "OutScreen") ?? NdiTransparentBackground;
        NdiFrameRateIndex = config.Int("NdiFpsId", "OutScreen") ?? NdiFrameRateIndex;

        // Remote API
        WebEnabled = config.Bool("WEBEnabled", "RemoteApi") ?? WebEnabled;
        WebPort = config.Int("WEBPort", "RemoteApi") ?? WebPort;
        WebNetInterface = config.String("RemoteApiWEBNetInterface", "RemoteApi") ?? WebNetInterface;
        WebSocketEnabled = config.Bool("WSEnabled", "RemoteApi") ?? WebSocketEnabled;
        WebSocketPort = config.Int("WSPort", "RemoteApi") ?? WebSocketPort;
        TcpEnabled = config.Bool("TCPEnabled", "RemoteApi") ?? TcpEnabled;
        TcpPort = config.Int("TCPPort", "RemoteApi") ?? TcpPort;
        UdpEnabled = config.Bool("UDPEnabled", "RemoteApi") ?? UdpEnabled;
        UdpPort = config.Int("UDPPort", "RemoteApi") ?? UdpPort;

        // Оновлення
        UpdateInterval = config.Int("CheckUpdatesInterval", "Update") ?? UpdateInterval;
    }

    private static AddressStyle Address(int raw, AddressStyle fallback) =>
        Enum.IsDefined((AddressStyle)raw) ? (AddressStyle)raw : fallback;

    /// Частота кадрів NDI за індексом — списком володіє `OutputConfiguration`.
    [JsonIgnore]
    public int NdiFrameRate
    {
        get
        {
            var rates = OutputConfiguration.NdiFrameRates;
            return NdiFrameRateIndex >= 0 && NdiFrameRateIndex < rates.Count
                ? (int)Math.Round(rates[NdiFrameRateIndex], MidpointRounding.AwayFromZero)
                : 30;
        }
    }

    /// Глибока копія (у Swift — звичайне присвоєння значення).
    public ProgramOptions Copy() => this with { DoubleMonitors = new ValueList<string>(DoubleMonitors) };
}

/// Рядок списку модулів на вкладці «Модулі» (6.1.4).
///
/// У `[BiblePath]` у кожного рядка два значення: шлях і ознака ввімкненості
/// (`0="Modules\rst+\"|1`). Порядок рядків — це порядок вкладок перекладів у
/// головному вікні, тому тут він і зберігається.
public sealed record ModuleRosterEntry
{
    /// Шлях у записі оригіналу, разом зі зворотними скісними.
    [JsonRequired, JsonPropertyName("path")] public string Path { get; set; } = "";
    /// Ім'я теки або файлу — ним модуль упізнається в бібліотеці.
    [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonRequired, JsonPropertyName("isEnabled")] public bool IsEnabled { get; set; }

    [JsonIgnore] public string Id => Path;

    public ModuleRosterEntry() { }

    public ModuleRosterEntry(string path, string name, bool isEnabled)
    {
        Path = path;
        Name = name;
        IsEnabled = isEnabled;
    }

    /// Модуль це чи Пісенник: у пісенників розширення `.songbook` (своє)
    /// або `.vbm` (стара програма).
    [JsonIgnore]
    public bool IsSongBook
    {
        get
        {
            var lower = Name.ToLowerInvariant();
            return lower.EndsWith(".vbm", StringComparison.Ordinal) || lower.EndsWith(".songbook", StringComparison.Ordinal);
        }
    }

    /// Де модуль лежить на диску. Запис — у дусі оригіналу: відносний шлях зі
    /// зворотними скісними від теки даних (`Modules\rst+\`) або повний шлях,
    /// якщо модуль додали з іншого місця.
    public string ResolvedUrl(string dataRoot)
    {
        var tail = Path.Replace("\\", "/");
        while (tail.EndsWith('/')) tail = tail[..^1];
        if (SwiftPath.IsAbsolute(tail))
        {
            // Повний шлях у старий дім даних (пакет, інший комп'ютер) веде в
            // нікуди — шукаємо модуль там, куди він переїхав.
            if (!SwiftPath.Exists(tail) && DataPaths.Existing(tail) is { } moved) return moved;
            return tail;
        }
        return SwiftPath.Append(dataRoot, tail);
    }

    /// Ім'я, яким модуль називає себе в бібліотеці: у теки «Цитата з
    /// Біблії» — ім'я теки, у бази MyBible — ім'я файлу без `.SQLite3`, у
    /// MySword — без `.bbl.mybible`.
    [JsonIgnore]
    public string LibraryIdentifier
    {
        get
        {
            var lower = Name.ToLowerInvariant();
            if (lower.EndsWith(".bbl.mybible", StringComparison.Ordinal)) return Name[..^".bbl.mybible".Length];
            if (lower.EndsWith(".sqlite3", StringComparison.Ordinal)) return Name[..^".sqlite3".Length];
            if (lower.EndsWith(".sqlite", StringComparison.Ordinal)) return Name[..^".sqlite".Length];
            return Name;
        }
    }

    /// Розбір рядка `"Modules\rst+\"|1` (`init?(rawValue:)`).
    public static ModuleRosterEntry? FromRawValue(string rawValue)
    {
        var parts = rawValue.Split('|', 2);
        var rawPath = parts[0];
        var enabled = parts.Length <= 1 || parts[1].TrimWhitespaces() != "0";
        var cleaned = rawPath.TrimCharacters("\" ");
        if (cleaned.Length == 0) return null;
        var trimmed = cleaned.TrimCharacters("\\");
        var pieces = trimmed.Split('\\', StringSplitOptions.RemoveEmptyEntries);
        if (pieces.Length == 0) return null;
        return new ModuleRosterEntry(cleaned, pieces[^1], enabled);
    }

    [JsonIgnore] public string RawValue => $"\"{Path}\"|{(IsEnabled ? 1 : 0)}";
}

/// Рядок списку шляхів до фонових малюнків (6.1.5). У `[PicturePath]` формат
/// той самий, але хвіст після `|` означає «сканувати вкладені теки».
public sealed record PicturePathEntry
{
    [JsonRequired, JsonPropertyName("path")] public string Path { get; set; } = "";
    [JsonRequired, JsonPropertyName("scansSubfolders")] public bool ScansSubfolders { get; set; }

    [JsonIgnore] public string Id => Path;

    public PicturePathEntry() { }

    public PicturePathEntry(string path, bool scansSubfolders)
    {
        Path = path;
        ScansSubfolders = scansSubfolders;
    }

    public static PicturePathEntry? FromRawValue(string rawValue)
    {
        var parts = rawValue.Split('|', 2);
        var rawPath = parts[0].TrimCharacters("\" ");
        if (rawPath.Length == 0) return null;
        return new PicturePathEntry(rawPath, parts.Length > 1 && parts[1].TrimWhitespaces() != "0");
    }

    [JsonIgnore] public string RawValue => $"\"{Path}\"|{(ScansSubfolders ? 1 : 0)}";
}

/// Рядок списку «Web слайди» на вкладці Remote API.
/// Оригінал тримає його не в ini, а у `visiobible.json`.
public sealed record WebSlideEntry
{
    [JsonRequired, JsonPropertyName("Name")] public string Name { get; set; } = "";
    [JsonRequired, JsonPropertyName("FileName")] public string FileName { get; set; } = "";
    [JsonRequired, JsonPropertyName("Description")] public string Details { get; set; } = "";

    [JsonIgnore] public string Id => FileName + "|" + Name;

    public WebSlideEntry() { }

    public WebSlideEntry(string name, string fileName, string details)
    {
        Name = name;
        FileName = fileName;
        Details = details;
    }
}

/// Тип частини пісні для «Колірної легенди» (6.4): колір і його альтернативні
/// назви різними мовами.
public sealed record SongChunkSetting
{
    [JsonRequired, JsonPropertyName("key")] public string Key { get; set; } = "";
    /// `TColor` Delphi — так само, як це лежить у `[SongChunksColors]`.
    [JsonRequired, JsonPropertyName("tColor")] public int TColor { get; set; }
    [JsonRequired, JsonPropertyName("names")] public ValueList<string> Names { get; set; } = new();

    [JsonIgnore] public string Id => Key;

    public SongChunkSetting() { }

    public SongChunkSetting(string key, int tColor, IEnumerable<string> names)
    {
        Key = key;
        TColor = tColor;
        Names = new ValueList<string>(names);
    }

    [JsonIgnore] public SlideStyle.RGBA Color => SongChunkPalette.Color(TColor);

    /// Рядок секції `[SongChunksColors]`: колір, далі назви через кому.
    [JsonIgnore] public string RawValue => string.Join(",", new[] { TColor.ToString() }.Concat(Names));
}

/// Повний знімок налаштувань: параметри, списки модулів і шляхів, розкладки
/// клавіш і колірна легенда частин пісень.
public sealed class SlovoSettings
{
    [JsonRequired, JsonPropertyName("options")] public ProgramOptions Options { get; set; } = new();
    [JsonRequired, JsonPropertyName("modules")] public List<ModuleRosterEntry> Modules { get; set; } = new();
    [JsonRequired, JsonPropertyName("picturePaths")] public List<PicturePathEntry> PicturePaths { get; set; } = new();
    [JsonRequired, JsonPropertyName("screenshotFolder")] public string ScreenshotFolder { get; set; } = "ScreenShots\\";
    [JsonRequired, JsonPropertyName("hotkeySets")] public HotkeySets HotkeySets { get; set; } = HotkeySets.FactoryDefault;
    [JsonRequired, JsonPropertyName("hotkeySetName")] public string HotkeySetName { get; set; } = "";
    [JsonRequired, JsonPropertyName("webSlides")] public List<WebSlideEntry> WebSlides { get; set; } = new();
    [JsonRequired, JsonPropertyName("songChunks")] public List<SongChunkSetting> SongChunks { get; set; } = new();

    /// Для читання JSON (у Swift — синтезований `init(from:)`).
    [JsonConstructor]
    public SlovoSettings() { }

    public SlovoSettings(ProgramOptions? options = null,
                         List<ModuleRosterEntry>? modules = null,
                         List<PicturePathEntry>? picturePaths = null,
                         string screenshotFolder = "ScreenShots\\",
                         HotkeySets? hotkeySets = null,
                         string hotkeySetName = "",
                         List<WebSlideEntry>? webSlides = null,
                         List<SongChunkSetting>? songChunks = null)
    {
        Options = options ?? new ProgramOptions();
        Modules = modules ?? new List<ModuleRosterEntry>();
        PicturePaths = picturePaths ?? new List<PicturePathEntry>();
        ScreenshotFolder = screenshotFolder;
        HotkeySets = hotkeySets ?? HotkeySets.FactoryDefault;
        HotkeySetName = hotkeySetName.Length == 0 ? HotkeySets.PreferredSetName ?? "" : hotkeySetName;
        WebSlides = webSlides ?? new List<WebSlideEntry>();
        SongChunks = songChunks ?? new List<SongChunkSetting>();
    }

    /// Збирання з файла умовчань — це вихідний стан вікна при першому
    /// запуску, до того як користувач щось змінив у нас.
    public SlovoSettings(IniSettings? config, HotkeySets hotkeySets, string? dataRoot)
        : this(options: config != null ? new ProgramOptions(config) : new ProgramOptions(),
               modules: Indexed(config, "BiblePath", ModuleRosterEntry.FromRawValue),
               picturePaths: Indexed(config, "PicturePath", PicturePathEntry.FromRawValue),
               screenshotFolder: config?.String("screenshotfolder", "settings") ?? "ScreenShots\\",
               hotkeySets: hotkeySets,
               hotkeySetName: hotkeySets.PreferredSetName ?? "",
               webSlides: ReadWebSlides(dataRoot),
               songChunks: ReadChunks(config))
    {
    }

    private static List<T> Indexed<T>(IniSettings? config, string sectionName, Func<string, T?> parse) where T : class
    {
        if (config == null || !config.Sections.TryGetValue(sectionName, out var section)) return new List<T>();
        var rows = new List<(int Index, T Entry)>();
        foreach (var (key, value) in section.OrderBy(pair => pair.Key, StringComparer.Ordinal))
        {
            if (SwiftText.ParseInt(key) is not { } index || parse(value) is not { } entry) continue;
            rows.Add((index, entry));
        }
        return rows.OrderBy(row => row.Index).Select(row => row.Entry).ToList();
    }

    // ── Читання частин ──────────────────────────────────────────────────────

    /// Кольори й назви частин пісень: той самий розбір, що в `SongChunkPalette`,
    /// але зі збереженням вихідного `TColor` — його треба вміти записати назад.
    private static List<SongChunkSetting> ReadChunks(IniSettings? config)
    {
        string[] known = ["Verse", "Chorus", "Pre-Chorus", "Bridge", "Tag", "Intro", "End"];
        Dictionary<string, string>? section = null;
        if (config == null || !config.Sections.TryGetValue("SongChunksColors", out section) || section.Count == 0)
        {
            return SongChunkPalette.FactoryDefault.Chunks
                .Select(chunk => new SongChunkSetting(chunk.Key, TColor(chunk.Color), chunk.Names)).ToList();
        }
        var order = new List<string>(known);
        foreach (var key in section.Keys.OrderBy(key => key, StringComparer.Ordinal))
            if (!known.Any(name => name.ToLowerInvariant() == key)) order.Add(key);
        var result = new List<SongChunkSetting>();
        foreach (var key in order)
        {
            if (!section.TryGetValue(key.ToLowerInvariant(), out var raw)) continue;
            var fields = raw.Split(',').Select(field => field.TrimWhitespaces()).ToList();
            if (fields.Count == 0 || SwiftText.ParseInt(fields[0]) is not { } value) continue;
            result.Add(new SongChunkSetting(key, value, fields.Skip(1).Where(name => name.Length > 0)));
        }
        return result;
    }

    /// Сторінки з комплекту — коли свого списку немає нізвідки: ті самі дві,
    /// що в автора, і наша сторінка шаблону.
    public static List<WebSlideEntry> BuiltInWebSlides =>
    [
        new("stage", "VBWebSlideStage.html", "Stage slide"),
        new("trans", "VBWebSlideCF1.html", "Translation slide"),
        new("slovo", "slovo-slide.html", OurWords.T("Слайд по шаблону программы")),
        new("slovo-overlay", "slovo-slide-overlay.html", OurWords.T("Слайд поверх видео: без фона, только текст")),
    ];

    public static List<WebSlideEntry> ReadWebSlides(string? dataRoot)
    {
        if (dataRoot == null) return new List<WebSlideEntry>();
        var path = Path.Combine(dataRoot, "visiobible.json");
        // Файл записано з міткою порядку байтів (BOM) — Windows так робить.
        // Розбирач JSON її не прощає, і список веб-сторінок у власника
        // виходив порожнім, хоча у файлі дві сторінки.
        byte[] data;
        try { data = File.ReadAllBytes(path); }
        catch { return new List<WebSlideEntry>(); }
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) data = data[3..];
        JsonObject? slides;
        try
        {
            var root = JsonNode.Parse(data) as JsonObject;
            var api = root?["RemoteAPI"] as JsonObject;
            slides = api?["WebSlides"] as JsonObject;
        }
        catch
        {
            return new List<WebSlideEntry>();
        }
        if (slides == null) return new List<WebSlideEntry>();

        // Наборів сторінок може бути кілька; оригінал тримає робочий під
        // ім'ям «Default», а ми беремо його ж, інакше — перший-ліпший.
        var list = slides["Default"] as JsonArray
                   ?? (slides.Count > 0 ? slides.First().Value as JsonArray : null);
        var result = new List<WebSlideEntry>();
        if (list == null) return result;
        foreach (var item in list)
        {
            if (item is not JsonObject entry) continue;
            if (!TryString(entry["FileName"], out var file)) continue;
            var name = TryString(entry["Name"], out var given) ? given : file;
            var details = TryString(entry["Description"], out var text) ? text : "";
            result.Add(new WebSlideEntry(name, file, details));
        }
        return result;
    }

    private static bool TryString(JsonNode? node, out string value)
    {
        value = "";
        if (node is JsonValue scalar && scalar.TryGetValue<string>(out var text))
        {
            value = text;
            return true;
        }
        return false;
    }

    /// Зворотне перетворення кольору в `TColor` — Delphi зберігає `0x00BBGGRR`.
    public static int TColor(SlideStyle.RGBA color)
    {
        var red = (int)Math.Round(color.Red * 255, MidpointRounding.AwayFromZero);
        var green = (int)Math.Round(color.Green * 255, MidpointRounding.AwayFromZero);
        var blue = (int)Math.Round(color.Blue * 255, MidpointRounding.AwayFromZero);
        return (blue << 16) | (green << 8) | red;
    }

    /// Палітра для списку частин пісні — з поточного стану налаштувань.
    [JsonIgnore]
    public SongChunkPalette SongPalette =>
        new(SongChunks.Select(chunk => new SongChunkPalette.Chunk(chunk.Key, chunk.Color, chunk.Names.ToList())).ToList());

    /// Розкладка клавіш вибраного набору.
    [JsonIgnore]
    public Dictionary<string, Hotkey> Hotkeys => HotkeySets.Hotkeys(HotkeySetName);

    /// Імена ввімкнених модулів у тому порядку, в якому вони стоять у списку.
    [JsonIgnore]
    public List<string> EnabledModuleNames => Modules.Where(entry => entry.IsEnabled).Select(entry => entry.Name).ToList();

    // ── Файл settings.json ──────────────────────────────────────────────────

    /// `try? JSONDecoder().decode(SlovoSettings.self, from: data)`.
    public static SlovoSettings? Decode(byte[] data) => SwiftJson.TryDecode<SlovoSettings>(data);

    /// Як пише вікно «Параметри» на Mac: читабельно, ключі за абеткою.
    public byte[] Encode() => SwiftJson.EncodeBytes(this, pretty: true, sortedKeys: true);

    /// Глибока копія — знімок для «Скасувати» (у Swift це присвоєння значення).
    public SlovoSettings Copy() => new()
    {
        Options = Options.Copy(),
        Modules = Modules.Select(entry => entry with { }).ToList(),
        PicturePaths = PicturePaths.Select(entry => entry with { }).ToList(),
        ScreenshotFolder = ScreenshotFolder,
        HotkeySets = HotkeySets.Copy(),
        HotkeySetName = HotkeySetName,
        WebSlides = WebSlides.Select(entry => entry with { }).ToList(),
        SongChunks = SongChunks.Select(chunk => chunk with { Names = new ValueList<string>(chunk.Names) }).ToList(),
    };
}
