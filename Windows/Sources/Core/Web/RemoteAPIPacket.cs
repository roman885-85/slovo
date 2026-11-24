// =============================================================================
//  RemoteAPIPacket.cs — пакети Remote API (з SlovoCore/Web/RemoteAPIPacket.swift)
// =============================================================================
//  Рівно в тому вигляді, в якому їх чекають авторські сторінки з теки
//  `RemoteAPI` і наші заготовки. Розбіжність документації і реальності:
//  `Help/RemoteAPI_ru.txt` малює секцію `Slide` вкладеною в `Event`, а весь
//  JavaScript автора читає `data.Slide` і `data.NextSlide` з верхнього рівня;
//  тому `Slide` лежить і поруч з `Event`, і всередині нього.
//
//  Тут — лише пакети; самі TCP- і UDP-сервери Remote API — окремою частиною
//  (ПАРИТЕТ.md), а WebSocket-сервер веб-слайдів говорить уже цими пакетами.
// =============================================================================

using System.Text.Json;
using System.Text.Json.Nodes;

namespace Slovo.Core;

/// Назва перекладу для секції `Var[X]`.
public sealed record RemoteModuleName
{
    public string Short { get; }
    public string Full { get; }

    public RemoteModuleName(string @short, string full = "")
    {
        Short = @short;
        Full = full.Length == 0 ? @short : full;
    }
}

/// Один переклад у пакеті події — секція `Var[X]` разом з `Out0`.
public sealed record RemoteSlideVariant
{
    public string ModuleShortName { get; init; } = "";
    public string ModuleName { get; init; } = "";
    /// Посилання на місце Писання саме цього перекладу.
    public string Title { get; init; } = "";
    /// Вибраний текст цілком; рядки розділяються переносом рядка.
    public string Text { get; init; } = "";
    /// Сторінки слайда так, як його розкладено на проекторі.
    public IReadOnlyList<string> Pages { get; init; } = Array.Empty<string>();
    public int PageCurrent { get; init; }

    /// `pages: null` — «слайд уміщається цілком»: єдиною сторінкою стає сам текст.
    public static RemoteSlideVariant Make(string moduleShortName = "", string moduleName = "", string title = "",
                                          string text = "", IReadOnlyList<string>? pages = null, int pageCurrent = 0) => new()
    {
        ModuleShortName = moduleShortName,
        ModuleName = moduleName.Length == 0 ? moduleShortName : moduleName,
        Title = title,
        Text = text,
        Pages = pages ?? (text.Length == 0 ? Array.Empty<string>() : new[] { text }),
        PageCurrent = pageCurrent,
    };

    /// `includeOut0` — підписник просив параметр `Out0`; без нього секцію не шлемо.
    internal JsonObject Json(bool includeOut0)
    {
        var result = new JsonObject
        {
            ["ModuleShortName"] = ModuleShortName,
            ["ModuleName"] = ModuleName,
            ["Title"] = RemoteText.WireText(Title),
            ["Text"] = RemoteText.WireText(Text),
        };
        if (includeOut0)
            result["Out0"] = new JsonObject
            {
                ["PageCurrent"] = Math.Max(0, PageCurrent),
                ["Pages"] = new JsonArray(Pages.Select(page => (JsonNode?)JsonValue.Create(RemoteText.WireText(page))).ToArray()),
            };
        return result;
    }
}

/// Подія зміни слайда.
public enum RemoteSlideEvent { Show, Hide }

/// Увесь стан слайда, який іде підписникам за один пакет.
public sealed record RemoteSlidePayload
{
    /// Режим головного вікна: сторінки автора за ним вирішують, чи брати текст у лапки.
    public enum Modes { Bible, Text, Song }

    public Modes Mode { get; init; } = Modes.Bible;
    /// Спільне посилання для всіх перекладів.
    public string TitleCommon { get; init; } = "";
    /// Переклади по порядку: `Variants[0]` → `Var0`, і так далі.
    public IReadOnlyList<RemoteSlideVariant> Variants { get; init; } = Array.Empty<RemoteSlideVariant>();
    /// Наступний слайд для екрана служителя (секція `NextSlide`).
    public IReadOnlyList<RemoteSlideVariant> Next { get; init; } = Array.Empty<RemoteSlideVariant>();
    /// Порожній слайд — це не «немає тексту», а подія `HideSlide`.
    public bool IsVisible { get; init; } = true;
    /// Розкладка об'єктів шаблону — для нашої сторінки `slovo-slide.html`; сторінки автора її не читають.
    public WebSlideLayout? Layout { get; init; }

    public static string ModeName(Modes mode) => mode switch { Modes.Text => "Text", Modes.Song => "Song", _ => "Bible" };

    /// Збирання з готового слайда. Назви перекладів — окремим списком у тому самому
    /// порядку: основний, потім паралельні. Чого забракло — порожній рядок.
    public static RemoteSlidePayload From(Slide slide, Modes mode = Modes.Bible,
                                          IReadOnlyList<RemoteModuleName>? moduleNames = null,
                                          IReadOnlyList<RemoteSlideVariant>? next = null)
    {
        var names = moduleNames ?? Array.Empty<RemoteModuleName>();
        var texts = new[] { slide.MainText }.Concat(slide.SecondaryTexts ?? Array.Empty<string>()).ToList();
        var variants = texts.Select((text, index) =>
        {
            var name = index < names.Count ? names[index] : new RemoteModuleName("");
            return RemoteSlideVariant.Make(name.Short, name.Full, slide.Reference, text);
        }).ToList();
        return new RemoteSlidePayload
        {
            Mode = mode,
            TitleCommon = slide.Reference,
            Variants = slide.IsBlank ? Array.Empty<RemoteSlideVariant>() : variants,
            Next = next ?? Array.Empty<RemoteSlideVariant>(),
            IsVisible = !slide.IsBlank,
        };
    }

    public RemoteSlideEvent Event => IsVisible ? RemoteSlideEvent.Show : RemoteSlideEvent.Hide;

    internal JsonObject SlideJson(bool includeOut0)
    {
        var result = new JsonObject
        {
            ["TitleCommon"] = RemoteText.WireText(TitleCommon),
            ["VarsNum"] = Variants.Count,
        };
        for (var index = 0; index < Variants.Count; index++) result["Var" + index] = Variants[index].Json(includeOut0);
        return result;
    }

    internal JsonObject NextJson(bool includeOut0)
    {
        var result = new JsonObject { ["VarsNum"] = Next.Count };
        for (var index = 0; index < Next.Count; index++) result["Var" + index] = Next[index].Json(includeOut0);
        return result;
    }
}

/// Запит клієнта: `{"Cmd": "...", "Params": "..."}` плюс поля UDP-транспорту.
public sealed record RemoteAPIRequest
{
    public string Command { get; init; } = "";
    public IReadOnlyList<string> Params { get; init; } = Array.Empty<string>();
    public string? SessionGUID { get; init; }
    public int? Sequence { get; init; }
    public int? UdpPort { get; init; }

    public static RemoteAPIRequest? Parse(byte[] data)
    {
        JsonObject? root;
        try { root = JsonNode.Parse(data) as JsonObject; } catch { return null; }
        if (root == null) return null;

        // Регістр ключів у прикладах автора плаває, тому шукаємо без урахування регістру.
        JsonNode? Value(string key)
        {
            if (root.TryGetPropertyValue(key, out var exact)) return exact;
            return root.FirstOrDefault(pair => string.Equals(pair.Key, key, StringComparison.OrdinalIgnoreCase)).Value;
        }
        static string? Text(JsonNode? node) => node is JsonValue value && value.TryGetValue<string>(out var text) ? text : null;
        static int? Number(JsonNode? node)
        {
            if (node is not JsonValue value) return null;
            if (value.TryGetValue<int>(out var i)) return i;
            if (value.TryGetValue<double>(out var d)) return (int)d;
            if (value.TryGetValue<long>(out var l)) return (int)l;
            return null;
        }

        if (Text(Value("Cmd")) is not { } command) return null;
        return new RemoteAPIRequest
        {
            Command = command.TrimWhitespaces(),
            Params = (Text(Value("Params")) ?? "").Split(',').Select(part => part.TrimWhitespaces()).Where(part => part.Length > 0).ToList(),
            SessionGUID = Text(Value("SessionGUID")),
            Sequence = Number(Value("CSeq")),
            UdpPort = Number(Value("UDPPort")),
        };
    }

    public bool HasParam(string name) => Params.Any(param => string.Equals(param, name, StringComparison.OrdinalIgnoreCase));
    /// Підписник просить вміст слайда з проектора №0.
    public bool WantsProjectorContent => HasParam("Out0");
    /// Екран служителя додатково просить наступний слайд.
    public bool WantsNextSlide => HasParam("NextSlide");
}

/// Коди результату з документації протоколу.
public static class RemoteAPICode
{
    public static readonly (int Code, string Text) Ok = (200, "OK");
    public static readonly (int Code, string Text) BadRequest = (400, "Bad Request");
    public static readonly (int Code, string Text) NotFound = (404, "Not Found");
    public static readonly (int Code, string Text) NotAllowed = (405, "Method Not Allowed");
    /// 410 — сесію UDP закрито за тайм-аутом.
    public static readonly (int Code, string Text) Gone = (410, "Gone");
}

internal static class RemoteAPIPacket
{
    static readonly JsonSerializerOptions Options = new() { Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    /// Спільна частина будь-якого пакета сервера.
    static JsonObject Envelope(string instance, string session, int sequence, (int Code, string Text) code) => new()
    {
        ["InstanceGUID"] = instance,
        ["SessionGUID"] = session,
        ["CSeq"] = sequence,
        ["Sender"] = new JsonObject { ["Name"] = RemoteAPIIdentity.SenderName },
        ["Code"] = code.Code,
        ["CodeText"] = code.Text,
    };

    /// Відповідь на команду. `extra` — додаткові секції конкретної команди.
    public static byte[] Answer(string command, string instance, string session, int sequence,
                                (int Code, string Text)? code = null, IReadOnlyDictionary<string, JsonNode>? extra = null)
    {
        var packet = Envelope(instance, session, sequence, code ?? RemoteAPICode.Ok);
        packet["Answer"] = new JsonObject { ["Cmd"] = command };
        if (extra != null) foreach (var (key, value) in extra) packet[key] = value.DeepClone();
        return Encode(packet);
    }

    /// Подія зміни слайда. `NextSlide` кладеться завжди: сторінка екрана служителя
    /// звертається до `data.NextSlide.Var0` без перевірки.
    public static byte[] SlideEvent(RemoteSlidePayload payload, string instance, string session, int sequence, bool includeOut0)
    {
        var packet = Envelope(instance, session, sequence, RemoteAPICode.Ok);
        packet["Mode"] = RemoteSlidePayload.ModeName(payload.Mode);
        packet["Event"] = new JsonObject
        {
            ["Name"] = payload.Event == RemoteSlideEvent.Show ? "ShowSlide" : "HideSlide",
            ["Slide"] = payload.SlideJson(includeOut0),
        };
        packet["Slide"] = payload.SlideJson(includeOut0);
        packet["NextSlide"] = payload.NextJson(includeOut0);
        if (payload.Layout is { IsEmpty: false } layout) packet["Layout"] = layout.Json();
        return Encode(packet);
    }

    /// Подія «сесію закрито за тайм-аутом» — лише для UDP.
    public static byte[] SessionClosed(string instance, string session, int sequence)
    {
        var packet = Envelope(instance, session, sequence, RemoteAPICode.Gone);
        packet["Event"] = new JsonObject { ["Name"] = "CloseSession" };
        packet["MsgID"] = RemoteAPICode.Gone.Code;
        return Encode(packet);
    }

    /// В один рядок: специфікація забороняє сирі 0x0D/0x0A у пакеті, а перенос
    /// усередині тексту приїжджає послідовністю «\r\n» — це робить екранування JSON.
    static byte[] Encode(JsonObject packet)
    {
        try { return JsonSerializer.SerializeToUtf8Bytes(packet, Options); }
        catch { return "{\"Code\":500,\"CodeText\":\"Internal Error\"}"u8.ToArray(); }
    }
}

/// Хто ми для клієнтів протоколу.
public static class RemoteAPIIdentity
{
    /// Підписуємося своїм іменем: власник просив прибрати чуже ім'я звідусіль.
    public const string SenderName = "Slovo";
    public const string ImplementationName = "Slovo";
    public static readonly (int MajorHi, int MajorLo, int MinorHi, int Build) Version = (2, 5, 0, 1);

    internal static JsonObject SenderInfo(string installGUID) => new()
    {
        ["Name"] = SenderName,
        ["Implementation"] = ImplementationName,
        ["InstallGUID"] = installGUID,
        ["Version"] = new JsonObject
        {
            ["MajorHi"] = Version.MajorHi,
            ["MajorLo"] = Version.MajorLo,
            ["MinorHi"] = Version.MinorHi,
            ["Build"] = Version.Build,
        },
    };

    /// GUID у фігурних дужках, як в усіх прикладах протоколу.
    public static string MakeGUID() => "{" + Guid.NewGuid().ToString().ToUpperInvariant() + "}";
}

/// Текст для дроту.
internal static class RemoteText
{
    const char LineSeparator = (char)0x2028, ParagraphSeparator = (char)0x2029;

    /// Усі варіанти переносу рядка зводимо до «\r\n»: так вимагає протокол, і так їх
    /// ріже JavaScript авторських сторінок (`replace(/\r\n/g, '<br>')`).
    public static string WireText(string text)
    {
        if (text.IndexOfAny(new[] { '\r', '\n', LineSeparator, ParagraphSeparator }) < 0) return text;
        var result = new System.Text.StringBuilder(text.Length + 8);
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character == '\r' && index + 1 < text.Length && text[index + 1] == '\n') { result.Append("\r\n"); index++; }
            else if (character is '\n' or '\r' or LineSeparator or ParagraphSeparator) result.Append("\r\n");
            else result.Append(character);
        }
        return result.ToString();
    }
}
