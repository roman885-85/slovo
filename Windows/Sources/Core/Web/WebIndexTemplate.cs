// =============================================================================
//  WebIndexTemplate.cs — стартова сторінка веб-виводу й підстановки в сторінки автора
//  (з SlovoCore/Web/WebIndexTemplate.swift)
// =============================================================================
//  Шаблон `RemoteAPI/index.tpl` авторський, правити його не можна, тому підписи
//  колонок приходять звідси. Свого рушія шаблонів у старій програмі немає — є
//  кілька міток і один цикл `{{#each WebSlides as WebSlide}}`; рівно їх і
//  підтримуємо: чужі фігурні дужки чіпати не можна, інакше поїде JavaScript.
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Дані для стартової сторінки веб-виводу.
public sealed record WebIndexModel
{
    public sealed record Entry(string Name, string Description);

    public string Title { get; init; } = OurWords.T("Слово — веб-слайды");
    public string LanguageCode { get; init; } = "ru";
    /// На Mac підпис колонки лишився російським («Страница»); тут — мовою інтерфейсу.
    public string PageColumn { get; init; } = OurWords.T("Страница");
    public string DescriptionColumn { get; init; } = OurWords.T("Описание");
    public string QrColumn { get; init; } = "QR-код";
    public IReadOnlyList<Entry> Entries { get; init; } = Array.Empty<Entry>();

    public WebIndexModel() { }

    public WebIndexModel(IEnumerable<WebOutputSettings.WebPage> pages, string? title = null, string languageCode = "ru")
    {
        Title = title ?? OurWords.T("Слово — веб-слайды");
        LanguageCode = languageCode;
        Entries = pages.Select(page => new Entry(page.FileName,
            KnownDescriptions.TryGetValue(page.FileName.ToLowerInvariant(), out var known) ? OurWords.T(known) : page.Title)).ToList();
    }

    /// Імена файлів авторських сторінок нічого не кажуть операторові, а колонка
    /// «Опис» — єдине місце, де можна пояснити різницю між ними.
    internal static readonly IReadOnlyDictionary<string, string> KnownDescriptions = new Dictionary<string, string>(StringComparer.Ordinal)
    {
        ["vbwebslide.html"] = "Титры внизу экрана поверх прозрачного фона",
        ["vbwebslidecf.html"] = "Титры с плавной сменой, подложка под текстом",
        ["vbwebslidecf1.html"] = "Титры с плавной сменой, без подложки",
        ["vbwebslidestage.html"] = "Экран служителя: текущий слайд крупно и следующий внизу",
        ["visiobiblewebslidecf-bible.html"] = "Стихи Писания с плавной сменой",
        ["visiobiblewebslidecf-song.html"] = "Куплеты песни с плавной сменой",
    };
}

public static class WebTemplate
{
    /// Мітка адреси сервера: сторінки підставляють її в `ws://…` і без неї ідуть на
    /// localhost, тобто з телефона не працюють.
    internal const string ServerAddress = "{{SERVER_ADDR}}";

    /// Сторінки автора — його файли, ми їх не правимо; але коли сервер мовчить, на
    /// екрані спливає «Connect to … WS-Server…». Підміняємо фрази на видачі — нашою мовою.
    public static string ReplaceAuthorPhrases(string page)
    {
        var result = page;
        foreach (var (theirs, ours) in AuthorPhrases)
            if (result.Contains(theirs, StringComparison.Ordinal))
                result = result.Replace(theirs, SafeForScript(OurWords.T(ours)), StringComparison.Ordinal);
        return result;
    }

    /// Що і на що підміняється — окремо, щоб самоперевірка могла пройтися тими самими парами.
    internal static readonly (string Theirs, string Ours)[] AuthorPhrases =
    [
        ("Connection lost. Trying to reconnect to VisioBible WS-Server...", "Связь потеряна. Подключаюсь к «Слову» снова…"),
        ("Connect to VisioBible WS-Server...", "Подключение к «Слову»…"),
        ("VisioBible Web Slide", "Слово — веб-слайд"),
    ];

    /// Автор вписує ці фрази й у рядки свого JavaScript в одинарних лапках:
    /// апостроф українського тексту закривав рядок завчасно, і скрипт сторінки
    /// не розбирався. Апостроф — типографський, зворотна скісна й переноси — геть.
    internal static string SafeForScript(string text) =>
        text.Replace("'", "’").Replace("\\", "").Replace("\n", " ").Replace("\r", " ");

    public static string RenderIndex(string template, WebIndexModel model, string serverAddress)
    {
        var result = ExpandEachBlock(template, model.Entries);
        return result
            .Replace("{{TITLE}}", Escape(model.Title))
            .Replace("{{LANG}}", Escape(model.LanguageCode))
            .Replace("{{PAGE}}", Escape(model.PageColumn))
            .Replace("{{DESCRIPTION}}", Escape(model.DescriptionColumn))
            .Replace("{{QRCODE}}", Escape(model.QrColumn))
            .Replace(ServerAddress, Escape(serverAddress));
    }

    /// Звичайна сторінка слайда: міток мало, але `SERVER_ADDR` обов'язковий.
    public static string RenderPage(string page, WebIndexModel model, string serverAddress) =>
        page.Replace(ServerAddress, Escape(serverAddress))
            .Replace("{{LANG}}", Escape(model.LanguageCode))
            .Replace("{{TITLE}}", Escape(model.Title));

    /// Порт WebSocket в автора вшито в сторінки числом 8100; адреса підміняється на
    /// льоту, у відповіді. Заразом відводимо з `localhost` сторінки, де він прописаний намертво.
    public static string RetargetWebSocket(string page, string host, int port)
    {
        var result = page;
        if (host != "localhost" && host != "127.0.0.1") result = result.Replace("ws://localhost:", $"ws://{host}:");
        if (port != 8100) result = result.Replace(":8100/ws", $":{port}/ws");
        return result;
    }

    /// `{{#each WebSlides as WebSlide}} … {{/each}}` — єдиний цикл шаблону.
    static string ExpandEachBlock(string template, IReadOnlyList<WebIndexModel.Entry> entries)
    {
        const string opening = "{{#each WebSlides as WebSlide}}";
        const string closing = "{{/each}}";
        var start = template.IndexOf(opening, StringComparison.Ordinal);
        if (start < 0) return template;
        var end = template.IndexOf(closing, start + opening.Length, StringComparison.Ordinal);
        if (end < 0) return template;
        var body = template[(start + opening.Length)..end];
        var rows = entries.Select(entry =>
        {
            // У посиланні — коротке ім'я, у підписі — ім'я файлу: з імені файлу виходить
            // адреса з відсотками замість кирилиці — таку ні продиктувати, ні в OBS вписати.
            var address = Escape(WebPageAddress.Slug(entry.Name));
            return body
                .Replace("data-href=\"{{WebSlide->Name}}\"", $"data-href=\"{address}\"")
                .Replace("href=\"{{WebSlide->Name}}\"", $"href=\"{address}\"")
                .Replace("{{WebSlide->Address}}", address)
                .Replace("{{WebSlide->Name}}", Escape(entry.Name))
                .Replace("{{WebSlide->Description}}", Escape(entry.Description));
        });
        return template[..start] + string.Concat(rows) + template[(end + closing.Length)..];
    }

    /// Усе підставлюване екрануємо: в імена сторінок і в заголовок потрапляють дані з
    /// диска і з перекладу, а адреса сервера — взагалі із заголовка запиту.
    public static string Escape(string text)
    {
        var result = new StringBuilder(text.Length);
        foreach (var character in text)
        {
            switch (character)
            {
                case '&': result.Append("&amp;"); break;
                case '<': result.Append("&lt;"); break;
                case '>': result.Append("&gt;"); break;
                case '"': result.Append("&quot;"); break;
                case '\'': result.Append("&#39;"); break;
                default: result.Append(character); break;
            }
        }
        return result.ToString();
    }
}
