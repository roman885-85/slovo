// =============================================================================
//  YouTubeLink.cs — посилання на ролик YouTube → номер ролика
//  (з Media/YouTubeLink.swift)
// =============================================================================
//  `URL` Swift тут — System.Uri; рядок посилання розбирається, як `URL(string:)`:
//  відносне чи зламане посилання — не посилання.
// =============================================================================

namespace Slovo.Core;

/// Посилання на ролик YouTube — розбір у номер ролика.
///
/// Прямий потік з YouTube на macOS не взяти: сайт віддає його лише своєму
/// програвачу. Перевірено 2026-09-03 на прохання власника: внутрішній API
/// YouTube відповідає відмовою всім відомим клієнтам (iOS, Android — «Precondition
/// check failed», телевізор — «no longer supported», браузер — «Video
/// unavailable» без ключа справжності), і всякий обхідний шлях живе до
/// найближчої правки на їхньому боці. Тому ролик показується офіційним
/// вбудовуваним програвачем YouTube (IFrame Player API), а йому потрібен лише
/// номер ролика — його і виймаємо.
public static class YouTubeLink
{
    /// Вузли, за якими посилання вважають посиланням на YouTube.
    public static readonly IReadOnlySet<string> Hosts = new HashSet<string>(StringComparer.Ordinal)
    {
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com",
    };

    public static bool IsYouTube(Uri url) => Host(url) is { } host && Hosts.Contains(host);

    public static bool IsYouTube(string url) => Parse(url) is { } parsed && IsYouTube(parsed);

    /// Номер ролика з посилання будь-якого виду: `watch?v=`, `youtu.be/`, `/live/`,
    /// `/shorts/`, `/embed/`, `/v/`. Не YouTube або ролика в посиланні немає —
    /// `null`: сторінка каналу, головна, список відтворення.
    public static string? VideoID(Uri url)
    {
        if (Host(url) is not { } host || !Hosts.Contains(host)) return null;
        var parts = PathComponents(url);      // без початкового «/»
        if (host.EndsWith("youtu.be", StringComparison.Ordinal))
            return Validated(parts.Count > 0 ? parts[0] : null);
        if (QueryItems(url) is { } query && query.FirstOrDefault(item => item.Name == "v") is { Value: { } candidate })
            return Validated(candidate);
        if (parts.Count == 0 || !new[] { "live", "shorts", "embed", "v" }.Contains(parts[0].ToLowerInvariant())) return null;
        return Validated(parts.Count > 1 ? parts[1] : null);
    }

    public static string? VideoID(string url) => Parse(url) is { } parsed ? VideoID(parsed) : null;

    /// Посилання на перегляд за номером — для запиту назви (oEmbed).
    public static Uri? WatchURL(string id) => Parse($"https://www.youtube.com/watch?v={id}");

    /// Номер ролика — рівно 11 знаків з літер, цифр, «-» і «_». Усе інше в
    /// полі `v` — сміття, відкривати його нічим.
    private static string? Validated(string? candidate)
    {
        if (candidate == null || SwiftText.CharacterCount(candidate) != 11) return null;
        foreach (var c in candidate)
            if (!(char.IsAsciiLetterOrDigit(c) || c == '-' || c == '_')) return null;
        return candidate;
    }

    // ── URL так, як його бачить Foundation ──────────────────────────────────

    private static Uri? Parse(string text) =>
        Uri.TryCreate(text, UriKind.Absolute, out var url) && !text.Any(char.IsWhiteSpace) ? url : null;

    /// `url.host` — без квадратних дужок IPv6, нижнім регістром (`lowercased()`).
    private static string? Host(Uri url)
    {
        if (!url.IsAbsoluteUri) return null;
        var host = url.Host;
        return host.Length == 0 ? null : host.ToLowerInvariant();
    }

    /// `url.pathComponents.dropFirst()`: шматки шляху без порожніх, розкодовані.
    private static List<string> PathComponents(Uri url) =>
        url.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Select(Uri.UnescapeDataString).ToList();

    /// `URLComponents.queryItems`: «ім'я=значення» через «&»; без «=» — значення немає.
    private static List<(string Name, string? Value)>? QueryItems(Uri url)
    {
        var query = url.Query;
        if (query.Length == 0) return null;
        var items = new List<(string Name, string? Value)>();
        foreach (var piece in query[1..].Split('&'))
        {
            var eq = piece.IndexOf('=');
            items.Add(eq < 0
                ? (Uri.UnescapeDataString(piece), null)
                : (Uri.UnescapeDataString(piece[..eq]), Uri.UnescapeDataString(piece[(eq + 1)..])));
        }
        return items;
    }
}
