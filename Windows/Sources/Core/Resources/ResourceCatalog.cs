// =============================================================================
//  ResourceCatalog.cs — каталоги ресурсів «Слова» в мережі
//  (з Resources/ResourceCatalog.swift)
// =============================================================================
//  Перейменування: `ResourceItem.Kind` → ResourceKind (у C# вкладений тип не
//  може зватися як властивість `Kind`); статичне `ResourceCatalog.format` →
//  `FormatName` (поруч із властивістю `Format`).
// =============================================================================

using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Slovo.Core;

/// Рід ресурсу (`ResourceItem.Kind`).
[JsonConverter(typeof(SwiftStringEnumConverter<ResourceKind>))]
public enum ResourceKind
{
    [JsonStringEnumMemberName("bible")] Bible,
    [JsonStringEnumMemberName("songbook")] Songbook,
    [JsonStringEnumMemberName("backgrounds")] Backgrounds,
    [JsonStringEnumMemberName("templates")] Templates,
    [JsonStringEnumMemberName("fonts")] Fonts,
    [JsonStringEnumMemberName("web")] Web,
}

public static class ResourceKinds
{
    public static readonly IReadOnlyList<ResourceKind> All =
        [ResourceKind.Bible, ResourceKind.Songbook, ResourceKind.Backgrounds, ResourceKind.Templates, ResourceKind.Fonts, ResourceKind.Web];

    public static string RawValue(this ResourceKind kind) => kind switch
    {
        ResourceKind.Bible => "bible",
        ResourceKind.Songbook => "songbook",
        ResourceKind.Backgrounds => "backgrounds",
        ResourceKind.Templates => "templates",
        ResourceKind.Fonts => "fonts",
        _ => "web",
    };
}

/// Ресурси «Слова» в мережі: переклади, пісенники, фони, шаблони — окремо
/// від програми. Власник: «все пакеты и переводы, картинки и другие ресурсы
/// выложить отдельно на гитхаб и создать отдельную сборку без данных —
/// только программа; при запуске предложить выполнить импорт или скачать
/// из гитхаба ресурсы (с выбором); впоследствии они будут обновляться…
/// плюс выбор откуда качать: наш ресурс или переводы с гитхаба BibleQuote».
///
/// Джерела:
///  • свій каталог `roman885-85/slovo-resources` — `catalog.json` у гілці
///    `main`, файли — assets релізу; у каталозі рід, назва, розмір, версія
///    (дата) і адреса;
///  • модулі «Цитата з Біблії» — `BibleQuote/BibleQuote-Modules` на GitHub:
///    `modules.ini` зі списком і `modules/<ім'я>.zip`, як бере планшет;
///  • реєстр MyBible (`mybible.zone`): `registry.zip` → `registry.json`,
///    переклади — `<ім'я>.zip` з одним `.SQLite3` усередині.
public sealed record ResourceItem
{
    [JsonRequired, JsonPropertyName("id")] public string Id { get; init; } = "";
    [JsonRequired, JsonPropertyName("kind")] public ResourceKind Kind { get; init; }
    [JsonRequired, JsonPropertyName("title")] public string Title { get; init; } = "";
    [JsonRequired, JsonPropertyName("subtitle")] public string Subtitle { get; init; } = "";
    /// Розмір файла в байтах; 0 — невідомий (каталог BibleQuote його не каже).
    [JsonRequired, JsonPropertyName("size")] public long Size { get; init; }
    /// Версія — дата чи будь-який рядок; змінилася — є оновлення.
    [JsonRequired, JsonPropertyName("version")] public string Version { get; init; } = "";
    [JsonRequired, JsonPropertyName("url")] public string Url { get; init; } = "";
    /// Ім'я, під яким ресурс ляже на диск (тека модуля, файл пісенника…).
    [JsonRequired, JsonPropertyName("fileName")] public string FileName { get; init; } = "";
    /// Мова ресурсу (`ru`, `uk`, `en`…), коли джерело її каже — за нею
    /// групується довгий список MyBible.
    [JsonPropertyName("language")] public string? Language { get; init; }

    public ResourceItem() { }

    public ResourceItem(string id, ResourceKind kind, string title, string subtitle = "", long size = 0,
                        string version = "", string url = "", string fileName = "", string? language = null)
    {
        Language = language;
        Id = id;
        Kind = kind;
        Title = title;
        Subtitle = subtitle;
        Size = size;
        Version = version;
        Url = url;
        FileName = fileName;
    }
}

public sealed record ResourceCatalog
{
    [JsonRequired, JsonPropertyName("format")] public string Format { get; init; } = FormatName;
    [JsonRequired, JsonPropertyName("updated")] public string Updated { get; init; } = "";
    [JsonRequired, JsonPropertyName("items")] public ValueList<ResourceItem> Items { get; init; } = new();

    /// Мітка свого каталогу (`ResourceCatalog.format` у Swift).
    public const string FormatName = "slovo-resources";

    public ResourceCatalog() { }

    public ResourceCatalog(string updated, IEnumerable<ResourceItem> items)
    {
        Format = FormatName;
        Updated = updated;
        Items = new ValueList<ResourceItem>(items);
    }

    /// `ResourceCatalog.decode(_:)`: суворий JSON, чужа мітка — `BadCatalog`.
    public static ResourceCatalog Decode(byte[] data)
    {
        var catalog = SwiftJson.Decode<ResourceCatalog>(data);
        if (catalog.Items.Any(item => item == null)) throw new JsonException("items: null");
        if (catalog.Format != FormatName) throw ResourceError.BadCatalog();
        return catalog;
    }

    public byte[] Encoded() => SwiftJson.EncodeBytes(this, pretty: true, sortedKeys: true, escapeSlashes: false);

    /// Каталог модулів «Цитата з Біблії»: `modules.ini` — секції
    /// `[Bible_…]` з `ModuleName=` і `ModuleAuthor=`; файл —
    /// `modules/<секція>.zip`. Беремо лише Біблії, як планшет.
    public static ResourceCatalog BibleQuote(string ini, string baseUrl)
    {
        var items = new List<ResourceItem>();
        string? id = null;
        string name = "", author = "";
        void Flush()
        {
            if (id is not { } section || !section.StartsWith("Bible_", StringComparison.Ordinal))
            {
                id = null;
                return;
            }
            var escaped = SwiftUrl.AddingPercentEncodingForPath(section);
            items.Add(new ResourceItem("bq:" + section, ResourceKind.Bible, name.Length == 0 ? section : name, author,
                                       version: "", url: baseUrl + "modules/" + escaped + ".zip", fileName: section));
            id = null;
        }
        foreach (var raw in ini.ComponentsSeparatedByNewlines())
        {
            var line = raw.TrimWhitespaces().Replace("\uFEFF", "");
            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                Flush();
                id = SwiftText.DropFirstCharacters(line, 1);
                id = id.Length > 0 ? SwiftText.PrefixCharacters(id, SwiftText.CharacterCount(id) - 1) : id;
                name = "";
                author = "";
            }
            else if (line.StartsWith("ModuleName=", StringComparison.Ordinal))
            {
                name = line["ModuleName=".Length..].TrimWhitespaces();
            }
            else if (line.StartsWith("ModuleAuthor=", StringComparison.Ordinal))
            {
                author = line["ModuleAuthor=".Length..].TrimWhitespaces();
            }
        }
        Flush();
        return new ResourceCatalog("", items);
    }

    /// Реєстр MyBible: `downloads` — усі модулі; Біблії — ті, в кого ім'я
    /// файла без суфікса (`AGP`, а не `Brux.dictionary`). Адреса — перший
    /// хост із `hosts`, у якого `path` має `%s`.
    public static ResourceCatalog? MyBible(byte[] data)
    {
        var bytes = data.AsMemory();
        if (data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF) bytes = bytes[3..];
        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(bytes, new JsonDocumentOptions { AllowTrailingCommas = true });
        }
        catch (JsonException)
        {
            return null;
        }
        using (document)
        {
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return null;
            var top = new LenientJson.Object(root);
            if (top["downloads"] is not { ValueKind: JsonValueKind.Array } downloadsNode) return null;
            var downloads = downloadsNode.EnumerateArray().ToList();
            // `[[String: Any]]`: кожен елемент — об'єкт, інакше весь список не той.
            if (downloads.Any(entry => entry.ValueKind != JsonValueKind.Object)) return null;

            var hosts = new List<LenientJson.Object>();
            if (top["hosts"] is { ValueKind: JsonValueKind.Array } hostsNode
                && hostsNode.EnumerateArray().All(host => host.ValueKind == JsonValueKind.Object))
                hosts = hostsNode.EnumerateArray().Select(host => new LenientJson.Object(host)).ToList();
            hosts = hosts.OrderBy(host => AnyInt(host["priority"]) ?? 9).ToList();
            var hostPaths = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var host in hosts)
            {
                if (AnyString(host["alias"]) is { } alias && AnyString(host["path"]) is { } path
                    && path.StartsWith("https", StringComparison.Ordinal))
                    hostPaths[alias] = path;
            }

            var items = new List<ResourceItem>();
            foreach (var element in downloads)
            {
                var entry = new LenientJson.Object(element);
                if (AnyString(entry["fil"]) is not { } file || file.Contains('.')
                    || AnyString(entry["abr"]) is not { } abbreviation) continue;
                // Перший https-хост зі списку модуля: `{mz}AGP` → mybible.zone.
                string? link = null;
                foreach (var raw in AnyStrings(entry["url"]))
                {
                    var close = raw.IndexOf('}');
                    if (!raw.StartsWith('{') || close < 0) continue;
                    var alias = raw[1..close];
                    var name = raw[(close + 1)..];
                    if (hostPaths.TryGetValue(alias, out var path))
                    {
                        // Імена в реєстрі вже закодовані («UBIO%2762», кирилиця —
                        // «%D0%A4%D0%86%D0%9B»); кодувати вдруге не можна — виходило
                        // «%2527» і 404. Кодуємо лише те, що прийшло сирим.
                        var plain = SwiftUrl.RemovingPercentEncoding(name) ?? name;
                        var escaped = SwiftUrl.AddingPercentEncodingForPath(plain, except: "'");
                        link = path.Replace("%s", escaped);
                        break;
                    }
                }
                if (link == null) continue;
                var language = AnyString(entry["lng"]);
                var updated = AnyString(entry["upd"]) ?? "";
                // Опис у реєстрі буває в кілька рядків («…Турконяка (1997-2007)\n76
                // книг»): рядок списку ресурсів розраховано на один — назва лізла
                // на сусідній рядок. Складаємо в один.
                var title = string.Join(" ", (AnyString(entry["des"]) ?? abbreviation).ComponentsSeparatedByNewlines()
                    .Select(line => line.TrimWhitespaces()).Where(line => line.Length > 0));
                items.Add(new ResourceItem("mb:" + abbreviation, ResourceKind.Bible,
                                           title.Length == 0 ? abbreviation : title,
                                           string.Join(" · ", new[] { abbreviation, updated }.Where(part => part.Length > 0)),
                                           Size(AnyString(entry["siz"])), updated, link, abbreviation + ".SQLite3", language));
            }
            return new ResourceCatalog(top["version"] is { } version ? Describe(version) : "", items);
        }
    }

    /// `as? String` над значенням JSONSerialization.
    private static string? AnyString(JsonElement? element) =>
        element is { ValueKind: JsonValueKind.String } value ? value.GetString() : null;

    /// `as? [String]` — масив, у якому кожен елемент рядок.
    private static List<string> AnyStrings(JsonElement? element)
    {
        if (element is not { ValueKind: JsonValueKind.Array } array) return new List<string>();
        var result = new List<string>();
        foreach (var item in array.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.String) return new List<string>();
            result.Add(item.GetString()!);
        }
        return result;
    }

    /// `as? Int` над NSNumber: ціле (і дробове без дробової частини), true — 1.
    private static long? AnyInt(JsonElement? element)
    {
        switch (element?.ValueKind)
        {
            case JsonValueKind.True: return 1;
            case JsonValueKind.False: return 0;
            case JsonValueKind.Number:
                var value = element.Value;
                if (value.TryGetInt64(out var exact)) return exact;
                if (value.TryGetDouble(out var real) && Math.Floor(real) == real && real >= -9.2233720368547758e18 && real < 9.2233720368547758e18)
                    return (long)real;
                return null;
            default: return null;
        }
    }

    /// `"\(Any)"` для значення JSONSerialization: число — як NSNumber
    /// («1.0» → «1»), true/false — «1»/«0», null — «<null>».
    private static string Describe(JsonElement element) => element.ValueKind switch
    {
        JsonValueKind.String => element.GetString()!,
        JsonValueKind.True => "1",
        JsonValueKind.False => "0",
        JsonValueKind.Null => "<null>",
        JsonValueKind.Number => element.TryGetInt64(out var exact)
            ? exact.ToString(CultureInfo.InvariantCulture)
            : element.TryGetDouble(out var real) && Math.Floor(real) == real && Math.Abs(real) < 1e15
                ? ((long)real).ToString(CultureInfo.InvariantCulture)
                : element.GetRawText(),
        _ => element.GetRawText(),
    };

    /// Каталог eBible.org: `translations.csv`, рядок на переклад.
    ///
    /// Беремо лише те, що дозволено поширювати й можна завантажити. Файл —
    /// `<id>_vpl.zip`; при установці він перекладається в модуль MyBible
    /// (`EBibleVPL`). Мова в каталозі — трилітерна (ISO 639-3); для пошуку
    /// «uk», «ru», «en» знайомі мови перекладаємо у дволітерні.
    public static ResourceCatalog EBible(string csv)
    {
        var rows = CsvRows(csv);
        if (rows.Count == 0) return new ResourceCatalog("", Array.Empty<ResourceItem>());
        var head = rows[0];
        int? Column(string name)
        {
            var index = head.FindIndex(cell => cell.TrimWhere(c => c is '\uFEFF' or ' ') == name);
            return index >= 0 ? index : null;
        }
        if (Column("translationId") is not { } id || Column("title") is not { } title)
            return new ResourceCatalog("", Array.Empty<ResourceItem>());
        int? language = Column("languageCode"), english = Column("languageNameInEnglish");
        int? free = Column("Redistributable"), downloadable = Column("downloadable"), date = Column("UpdateDate");
        var shortTitle = Column("shortTitle");
        var counts = new[] { "OTverses", "NTverses", "DCverses" }.Select(Column).Where(index => index != null).Select(index => index!.Value).ToList();
        var items = new List<ResourceItem>();
        var newest = "";
        foreach (var row in rows.Skip(1))
        {
            string Value(int? index) => index is { } at && at >= 0 && at < row.Count ? row[at].TrimWhitespaces() : "";
            if (Value(id).Length == 0 || Value(free).ToLowerInvariant() != "true" || Value(downloadable).ToLowerInvariant() == "false") continue;
            var verses = counts.Aggregate(0L, (sum, index) => sum + (ParseLong(Value(index)) ?? 0));
            if (verses <= 0) continue;
            var code = Value(language);
            var updated = Value(date);
            if (string.CompareOrdinal(updated, newest) > 0) newest = updated;
            var name = Value(title).Length == 0 ? Value(shortTitle) : Value(title);
            items.Add(new ResourceItem("eb:" + Value(id), ResourceKind.Bible, name,
                                       string.Join(" · ", new[] { Value(id), Value(english), updated }.Where(part => part.Length > 0)),
                                       // Приблизно: VPL-архів — близько 140 байтів на вірш.
                                       verses * 140, updated,
                                       $"https://ebible.org/Scriptures/{Value(id)}_vpl.zip",
                                       Value(id) + ".SQLite3",
                                       TwoLetter.TryGetValue(code, out var two) ? two : code.Length == 0 ? null : code));
        }
        return new ResourceCatalog(newest, items);
    }

    private static long? ParseLong(string text) =>
        text.Length > 0 && long.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var value) ? value : null;

    private static readonly Regex SoftProjectorLinks =
        new("<h3>([^<]+)</h3>|<a\\s+href=\"(songbooks/[^\"]+\\.(?:sps|zip))\"\\s*>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// Пісенники SoftProjector: сторінка `download_mod_songbooks.html` —
    /// заголовки мов `<h3>` і посилання `songbooks/<файл>.sps|zip`, перед
    /// кожним — назва пісенника. Ставляться через розбір `.sps` у свій формат.
    public static ResourceCatalog SoftProjector(string html, string baseUrl)
    {
        var languages = new Dictionary<string, string>
        {
            ["czech"] = "cs", ["english"] = "en", ["german"] = "de", ["russian"] = "ru", ["slovak"] = "sk",
            ["ukrainian"] = "uk", ["polish"] = "pl", ["romanian"] = "ro", ["spanish"] = "es",
        };
        var items = new List<ResourceItem>();
        string? language = null;
        var cursor = 0;
        foreach (Match match in SoftProjectorLinks.Matches(html))
        {
            if (match.Groups[1].Success)
            {
                language = languages.GetValueOrDefault(match.Groups[1].Value.TrimWhitespaces().ToLowerInvariant());
                cursor = match.Index + match.Length;
                continue;
            }
            if (!match.Groups[2].Success) continue;
            // Назва — текст між попереднім посиланням чи заголовком і цим.
            var before = cursor <= match.Index ? html[cursor..match.Index] : "";
            var end = match.Index + match.Length;
            var close = html.IndexOf("</a>", end, StringComparison.Ordinal);
            cursor = close >= 0 ? close + 4 : end;
            var title = Regex.Replace(before, "<[^>]+>", " ").Replace("&quot;", "\"").Replace("&nbsp;", " ");
            var lastDash = title.LastIndexOf(" - ", StringComparison.Ordinal);
            if (lastDash >= 0) title = title[..lastDash];
            var lastStar = title.LastIndexOf('*');
            if (lastStar >= 0) title = title[(lastStar + 1)..];
            title = Regex.Replace(title, "\\s+", " ").TrimWhere(c => c is ' ' or '-' or '\n' or '\t');
            var path = match.Groups[2].Value;
            var file = (SwiftUrl.RemovingPercentEncoding(path) ?? path).Split('/').Last();
            var stem = SwiftPath.DeletingExtension(file);
            if (title.Length == 0 || SwiftText.CharacterCount(title) > 80) title = stem;
            var escaped = SwiftUrl.AddingPercentEncodingForPath(path, except: "%");
            var tail = path.Contains('%') ? path : escaped;
            var url = baseUrl.EndsWith('/') ? baseUrl + tail : baseUrl + "/" + tail;
            if (items.Any(item => item.Id == "sp:" + stem)) continue;
            items.Add(new ResourceItem("sp:" + stem, ResourceKind.Songbook, title,
                                       string.Join(" · ", new[] { file, language ?? "" }.Where(part => part.Length > 0)),
                                       0, "", url, stem + ".songbook", language));
        }
        return new ResourceCatalog("", items);
    }

    /// ISO 639-3 → 639-1 для мов, які шукають найчастіше.
    internal static readonly IReadOnlyDictionary<string, string> TwoLetter = new Dictionary<string, string>
    {
        ["eng"] = "en", ["ukr"] = "uk", ["rus"] = "ru", ["bel"] = "be", ["deu"] = "de", ["fra"] = "fr", ["spa"] = "es", ["por"] = "pt",
        ["ita"] = "it", ["pol"] = "pl", ["ron"] = "ro", ["ces"] = "cs", ["slk"] = "sk", ["hun"] = "hu", ["bul"] = "bg", ["srp"] = "sr",
        ["hrv"] = "hr", ["slv"] = "sl", ["lit"] = "lt", ["lav"] = "lv", ["est"] = "et", ["fin"] = "fi", ["swe"] = "sv", ["nor"] = "no",
        ["nob"] = "nb", ["dan"] = "da", ["nld"] = "nl", ["ell"] = "el", ["grc"] = "el", ["heb"] = "he", ["hbo"] = "he", ["arb"] = "ar",
        ["arz"] = "ar", ["tur"] = "tr", ["kaz"] = "kk", ["kir"] = "ky", ["uzb"] = "uz", ["uzn"] = "uz", ["aze"] = "az", ["hye"] = "hy",
        ["kat"] = "ka", ["fas"] = "fa", ["pes"] = "fa", ["hin"] = "hi", ["urd"] = "ur", ["ben"] = "bn", ["tam"] = "ta", ["tel"] = "te",
        ["zho"] = "zh", ["cmn"] = "zh", ["jpn"] = "ja", ["kor"] = "ko", ["vie"] = "vi", ["tha"] = "th", ["ind"] = "id", ["msa"] = "ms",
        ["zlm"] = "ms", ["tgl"] = "tl", ["swh"] = "sw", ["swa"] = "sw", ["amh"] = "am", ["afr"] = "af", ["lat"] = "la", ["epo"] = "eo",
        ["mkd"] = "mk", ["sqi"] = "sq", ["als"] = "sq", ["isl"] = "is", ["gle"] = "ga", ["cym"] = "cy", ["mlt"] = "mt", ["tgk"] = "tg",
        ["tuk"] = "tk", ["mon"] = "mn", ["khm"] = "km", ["mya"] = "my", ["npi"] = "ne", ["sin"] = "si", ["yor"] = "yo", ["hau"] = "ha",
        ["ibo"] = "ig", ["zul"] = "zu", ["xho"] = "xh", ["som"] = "so", ["mlg"] = "mg", ["plt"] = "mg",
    };

    /// Рядки CSV: коми, лапки, лапки всередині подвоєні, переноси в лапках.
    /// Розбір за «знаками» Swift: «\r\n» — один знак.
    internal static List<List<string>> CsvRows(string text)
    {
        var rows = new List<List<string>>();
        var row = new List<string>();
        var field = new StringBuilder();
        var quoted = false;
        var characters = SwiftText.Characters(text);
        var position = 0;
        string? pending = null;
        while (true)
        {
            string character;
            if (pending != null)
            {
                character = pending;
                pending = null;
            }
            else if (position < characters.Length)
            {
                character = characters[position++];
            }
            else break;

            if (quoted)
            {
                if (character == "\"")
                {
                    if (position < characters.Length)
                    {
                        var next = characters[position++];
                        if (next == "\"") field.Append('"');
                        else
                        {
                            quoted = false;
                            pending = next;
                        }
                    }
                    else quoted = false;
                }
                else field.Append(character);
                continue;
            }
            switch (character)
            {
                case "\"":
                    quoted = true;
                    break;
                case ",":
                    row.Add(field.ToString());
                    field.Clear();
                    break;
                case "\n": case "\r\n": case "\r":
                    row.Add(field.ToString());
                    field.Clear();
                    if (!(row.Count == 1 && row[0].Length == 0)) rows.Add(row);
                    row = new List<string>();
                    break;
                default:
                    field.Append(character);
                    break;
            }
        }
        if (field.Length > 0 || row.Count > 0)
        {
            row.Add(field.ToString());
            rows.Add(row);
        }
        return rows;
    }

    /// «589K», «2.6M» → байти.
    internal static long Size(string? text)
    {
        if (text == null) return 0;
        var value = text.TrimWhitespaces().ToUpperInvariant();
        if (value.Length == 0) return 0;
        double factor = 1;
        if (value.EndsWith('K')) { factor = 1024; value = value[..^1]; }
        else if (value.EndsWith('M')) { factor = 1_048_576; value = value[..^1]; }
        else if (value.EndsWith('G')) { factor = 1_073_741_824; value = value[..^1]; }
        var number = (SwiftText.ParseDouble(value) ?? 0) * factor;
        return double.IsFinite(number) ? (long)number : 0;
    }
}

public sealed class ResourceError : Exception
{
    public enum Kind { BadCatalog, Network, Unpack, Place }

    public Kind ErrorKind { get; }
    public string Detail { get; }

    private ResourceError(Kind kind, string detail, string message) : base(message)
    {
        ErrorKind = kind;
        Detail = detail;
    }

    public static ResourceError BadCatalog() => new(Kind.BadCatalog, "", OurWords.T("это не каталог ресурсов «Слова»"));
    public static ResourceError Network(string text) => new(Kind.Network, text, OurWords.T("нет связи: %s", text));
    public static ResourceError Unpack(string text) => new(Kind.Unpack, text, OurWords.T("не распаковалось: %s", text));
    public static ResourceError Place(string text) => new(Kind.Place, text, OurWords.T("не удалось положить на место: %s", text));

    public override string ToString() => Message;
}

/// Де які ресурси лежать на диску й що з них уже стоїть.
public readonly record struct ResourceLayout
{
    /// Корінь даних: тека, у якій `Modules`, `BackGrounds`, `Templates`…
    public string DataRoot { get; init; }
    public string Modules { get; init; }

    public ResourceLayout(string modulesFolder)
    {
        Modules = modulesFolder;
        DataRoot = SwiftPath.Parent(modulesFolder);
    }

    public string Destination(ResourceItem item) => item.Kind switch
    {
        ResourceKind.Bible or ResourceKind.Songbook => Path.Combine(Modules, item.FileName),
        ResourceKind.Backgrounds => Path.Combine(DataRoot, "BackGrounds"),
        ResourceKind.Templates => Path.Combine(DataRoot, "Templates"),
        ResourceKind.Fonts => Path.Combine(DataRoot, "Fonts"),
        _ => Path.Combine(DataRoot, "RemoteAPI"),
    };

    /// Чи є ресурс на диску (не питаючи журнал версій). Пісенник — у будь-
    /// якому з двох форматів: `.vbm` на диску перетворюється у `.songbook`.
    public bool IsPresent(ResourceItem item)
    {
        var target = Destination(item);
        if (item.Kind != ResourceKind.Songbook) return SwiftPath.Exists(target);
        var stem = SwiftPath.DeletingExtension(target);
        return new[] { SongBookJSON.PathExtension, "vbm" }.Any(extension => SwiftPath.Exists(stem + "." + extension));
    }
}

/// Журнал установлених ресурсів: `id` → версія, з якої ставили. Лежить у
/// своєму домі даних; за ним видно, що оновилося в каталозі.
public sealed class ResourceLedger
{
    [JsonRequired, JsonPropertyName("installed")] public Dictionary<string, string> Installed { get; set; } = new();

    public static string Url => Path.Combine(DataHome.Folder, "resources.json");

    public static ResourceLedger Load()
    {
        try
        {
            var ledger = SwiftJson.Decode<ResourceLedger>(File.ReadAllBytes(Url));
            if (ledger.Installed == null || ledger.Installed.Values.Any(value => value == null)) return new ResourceLedger();
            return ledger;
        }
        catch (Exception)
        {
            return new ResourceLedger();
        }
    }

    public void Save()
    {
        try { Directory.CreateDirectory(DataHome.Folder); } catch { }
        try { SwiftPath.WriteAtomically(Url, SwiftJson.EncodeBytes(this)); } catch { }
    }
}
