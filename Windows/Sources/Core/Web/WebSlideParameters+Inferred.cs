// =============================================================================
//  WebSlideParameters+Inferred.cs — що сторінка задає сама
//  (з SlovoCore/Web/WebSlideParameters+Inferred.swift)
// =============================================================================
//  У ту мить, коли на чужу сторінку вперше надягають блок налаштувань, її
//  власне оформлення перекладається в наші змінні: правила прив'язки написано
//  через `!important`, і з заводськими значеннями сторінка разом перестала б
//  бути схожою на себе. Чого не зрозуміли — того й не чіпаємо.
// =============================================================================

using System.Globalization;

namespace Slovo.Core;

public static partial class WebSlideParameters
{
    /// Перевести власне оформлення сторінки в наші змінні.
    public static WebSlideSettings Inferred(string html, RoleSelectors? roles = null)
    {
        roles ??= RoleSelectors.Standard;
        var rules = CssRules(StripBlocks(html));

        Dictionary<string, string> DeclarationsMatching(string selectors)
        {
            var found = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var rule in rules)
                if (SelectorMatches(rule.Selector, selectors))
                    foreach (var (name, value) in rule.Declarations) found[name] = value;
            return found;
        }

        var page = DeclarationsMatching(roles.Page);
        // Фон в автора стоїть просто в атрибуті `style` тіла сторінки.
        foreach (var (name, value) in BodyStyleAttribute(html)) page[name] = value;
        return SettingsFromComputed(new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal)
        {
            ["page"] = page,
            ["stage"] = DeclarationsMatching(roles.Stage),
            ["text"] = DeclarationsMatching(roles.Quote),
            ["reference"] = DeclarationsMatching(roles.Reference),
        });
    }

    /// Перевести готові значення властивостей у наші змінні — з розбору листа
    /// стилів або з відповіді самого браузера (`getComputedStyle`).
    public static WebSlideSettings SettingsFromComputed(IReadOnlyDictionary<string, Dictionary<string, string>> roles)
    {
        var settings = new WebSlideSettings();
        var page = roles.TryGetValue("page", out var p) ? p : new Dictionary<string, string>();
        var stage = roles.TryGetValue("stage", out var s) ? s : new Dictionary<string, string>();
        var text = roles.TryGetValue("text", out var t) ? t : new Dictionary<string, string>();
        var reference = roles.TryGetValue("reference", out var r) ? r : new Dictionary<string, string>();
        string? Get(Dictionary<string, string> table, string key) => table.TryGetValue(key, out var value) ? value : null;

        // Фон сторінки
        if (Get(page, "background-color") is { } raw && Colour(raw) is { } back)
        {
            settings.Set("--sl-page-rgb", $"{back.R} {back.G} {back.B}");
            settings.Set("--sl-page-opacity", Trim(back.A));
        }
        if (Get(page, "background-image") is { Length: > 0 } image) settings.Set("--sl-bg-image", image);
        if (Get(page, "background-size") is { Length: > 0 } fit) settings.Set("--sl-bg-fit", fit);
        if (Get(page, "background-position") is { Length: > 0 } pos) settings.Set("--sl-bg-pos", pos);
        if (Get(page, "background-repeat") is { Length: > 0 } repeated) settings.Set("--sl-bg-repeat", repeated);
        // Пелена й розмиття наші власні — заводські значення були б чужою правкою.
        settings.Set("--sl-dim", "0");
        settings.Set("--sl-bg-blur", "0px");
        settings.Set("--sl-safe", "0%");
        settings.Set("--sl-offset-x", "0");
        settings.Set("--sl-offset-y", "0");

        // Текст. Не знайшовши свого в блоці тексту, дивимося в тіло сторінки.
        string? TextValue(string property)
        {
            if (Get(text, property) is { Length: > 0 } own) return own;
            var inherited = Get(page, property);
            return string.IsNullOrEmpty(inherited) ? null : inherited;
        }
        var fontPixels = TextValue("font-size") is { } fontSize ? Pixels(fontSize) : null;

        if (TextValue("color") is { } colorRaw && Colour(colorRaw) is { } color)
        {
            settings.Set("--sl-color", Hex(color));
            settings.Set("--sl-text-opacity", Trim(color.A));
        }
        if (TextValue("font-family") is { } font) settings.Set("--sl-font", font);
        if (TextValue("font-weight") is { } weight) settings.Set("--sl-weight", CssWeight(weight));
        if (TextValue("font-stretch") is { } stretch) settings.Set("--sl-stretch", CssStretch(stretch));
        if (TextValue("font-style") is { } style)
            settings.Set("--sl-italic", style.StartsWith("italic", StringComparison.Ordinal) || style.StartsWith("oblique", StringComparison.Ordinal) ? "italic" : "normal");
        if (TextValue("text-transform") is { } caps) settings.Set("--sl-caps", caps == "uppercase" ? "uppercase" : "none");
        if (TextValue("text-align") is { } align && new[] { "left", "center", "right", "justify" }.Contains(align))
            settings.Set("--sl-align", align);
        if (TextValue("font-size") is { } size && FontSize(size) is { } pair)
        {
            settings.Set("--sl-unit", pair.Unit);
            settings.Set("--sl-size", pair.Size);
        }
        if (TextValue("letter-spacing") is { } spacing)
        {
            if (spacing == "normal") settings.Set("--sl-tracking", "0em");
            else if (Pixels(spacing) is { } px && fontPixels is { } basis && basis > 0) settings.Set("--sl-tracking", Trim(px / basis) + "em");
        }
        if (TextValue("line-height") is { } height)
        {
            if (height == "normal") settings.Set("--sl-line", "1.25");
            else if (Pixels(height) is { } px && fontPixels is { } basis && basis > 0) settings.Set("--sl-line", Trim(px / basis));
        }
        if (TextValue("width") is { } width && Pixels(width) is { } widthPx && widthPx > 0)
            settings.Set("--sl-width", Trim(Math.Min(100, widthPx / 19.2)) + "%");
        // Обведення і тінь: у чужої сторінки їх зазвичай немає, а наші заводські
        // значення обвели б увесь текст разом.
        if (TextValue("-webkit-text-stroke-width") is { } stroke && Pixels(stroke) is { } strokePx && strokePx > 0)
        {
            settings.Set("--sl-stroke-on", "1");
            settings.Set("--sl-stroke", Trim(strokePx / 10.8));
            if (TextValue("-webkit-text-stroke-color") is { } strokeColorRaw && Colour(strokeColorRaw) is { } strokeColor)
                settings.Set("--sl-stroke-color", Hex(strokeColor));
        }
        else settings.Set("--sl-stroke-on", "0");
        settings.Set("--sl-shadow-on", (TextValue("text-shadow") ?? "none") == "none" ? "0" : "1");
        // Тривалість переходу — теж зі сторінки; немає своєї — нуль, а не наші третина секунди.
        if (TextValue("transition-duration") is { } transition)
        {
            var first = transition.Split(',', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? transition;
            settings.Set("--sl-fade", first.TrimWhitespaces());
        }
        else settings.Set("--sl-fade", "0s");

        // Розташування і підкладка під текстом.
        var box = stage.Count == 0 ? text : stage;
        // Притиски беремо за місцем, де текст насправді опинився.
        if (roles.TryGetValue("место", out var place) && Get(place, "x") is { } xRaw && SwiftText.ParseDouble(xRaw) is { } x
            && Get(place, "y") is { } yRaw && SwiftText.ParseDouble(yRaw) is { } y)
        {
            settings.Set("--sl-h", Edge(x));
            settings.Set("--sl-v", Edge(y));
        }
        else if ((Get(box, "display") ?? "").Contains("flex", StringComparison.Ordinal))
        {
            if (Get(box, "align-items") is { } h && FlexValues.Contains(h)) settings.Set("--sl-h", h);
            if (Get(box, "justify-content") is { } v && FlexValues.Contains(v)) settings.Set("--sl-v", v);
        }
        // Напрямок розкладки зі сторінки не беремо зовсім: при `row` «по горизонталі»
        // почало б рухати по вертикалі.
        settings.Set("--sl-second-place", "column");
        // Поля приходять то одним рядком (лист стилів), то за сторонами (браузер).
        if (Get(box, "padding") is { } padRaw && Padding(padRaw) is { } pad)
        {
            settings.Set("--sl-pad-x", pad.X);
            settings.Set("--sl-pad-y", pad.Y);
        }
        else if (Get(box, "padding-top") is { } top && Get(box, "padding-left") is { } left
                 && Length(top, vertical: true) is { } padY && Length(left, vertical: false) is { } padX)
        {
            settings.Set("--sl-pad-x", padX);
            settings.Set("--sl-pad-y", padY);
        }
        if (Get(box, "background-color") is { } plateRaw && Colour(plateRaw) is { } plate)
        {
            settings.Set("--sl-plate-rgb", $"{plate.R} {plate.G} {plate.B}");
            settings.Set("--sl-plate-opacity", Trim(plate.A));
        }
        if (Get(box, "border-radius") is { } radius && Pixels(radius) is { } radiusPx)
            settings.Set("--sl-plate-radius", Trim(radiusPx / 10.8) + "vh");
        settings.Set("--sl-plate-blur", "0px");
        // Поля підкладки — це поля самого блоку з текстом.
        if (Get(text, "padding-top") is { } textTop && Get(text, "padding-left") is { } textLeft
            && Length(textTop, vertical: true) is { } plateY && Length(textLeft, vertical: false) is { } plateX)
        {
            settings.Set("--sl-plate-pad-x", plateX);
            settings.Set("--sl-plate-pad-y", plateY);
        }
        // Рамки і тіні в чужої сторінки немає — не малюємо і ми.
        settings.Set("--sl-plate-border", "0vh");
        settings.Set("--sl-plate-shadow", "0vh");

        // Адреса
        if (Get(reference, "color") is { } refColorRaw && Colour(refColorRaw) is { } refColor) settings.Set("--sl-ref-color", Hex(refColor));
        if (Get(reference, "font-style") is { } refStyle)
            settings.Set("--sl-ref-italic", refStyle.StartsWith("italic", StringComparison.Ordinal) ? "italic" : "normal");
        if (Get(reference, "display") is { Length: > 0 } display)
            settings.Set("--sl-ref-display", display == "none" ? "none" : "block");
        if (Get(reference, "font-size") is { } refSize && Pixels(refSize) is { } refPx && fontPixels is { } refBase && refBase > 0)
            settings.Set("--sl-ref-size", Trim(Math.Min(1, Math.Max(0.2, refPx / refBase))));
        return settings;
    }

    /// Довжина в пікселях — так браузер відповідає майже завжди.
    internal static double? Pixels(string raw)
    {
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        if (value.EndsWith("px", StringComparison.Ordinal)) return SwiftText.ParseDouble(value[..^2]);
        if (value.EndsWith("vw", StringComparison.Ordinal)) return SwiftText.ParseDouble(value[..^2]) * 19.2;
        if (value.EndsWith("vh", StringComparison.Ordinal)) return SwiftText.ParseDouble(value[..^2]) * 10.8;
        return SwiftText.ParseDouble(value);
    }

    /// Ширина літер: браузер відповідає відсотками, у нас — словами.
    internal static string CssStretch(string raw)
    {
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        if (!value.EndsWith('%') || SwiftText.ParseDouble(value[..^1]) is not { } percent)
            return value.Length == 0 ? "normal" : value;
        if (percent < 93) return "condensed";
        if (percent < 100) return "semi-condensed";
        if (percent == 100) return "normal";
        if (percent < 113) return "semi-expanded";
        if (percent < 126) return "expanded";
        return "ultra-expanded";
    }

    /// До якого краю притиснуто текст, судячи з того, де він стоїть.
    internal static string Edge(double fraction) => fraction < 0.34 ? "flex-start" : fraction >= 0.66 ? "flex-end" : "center";

    static readonly HashSet<string> FlexValues = new(StringComparer.Ordinal) { "flex-start", "center", "flex-end", "space-between" };

    // ── Розбір CSS ────────────────────────────────────────────────────────────

    internal sealed record CssRule(string Selector, List<(string Name, string Value)> Declarations);

    /// Правила з усіх `<style>` сторінки. Усе, всередині чого є вкладені дужки
    /// (`@media`, `@keyframes`), пропускаємо цілком — правила звідти застосовуються
    /// не завжди, і брати з них значення було б брехнею.
    internal static List<CssRule> CssRules(string html)
    {
        var rules = new List<CssRule>();
        foreach (var sheet in StyleBodies(html))
        {
            var rest = WithoutComments(sheet);
            var position = 0;
            while (true)
            {
                var open = rest.IndexOf('{', position);
                if (open < 0) break;
                var selector = rest[position..open].Trim();
                var close = rest.IndexOf('}', open + 1);
                if (close < 0) break;
                var body = rest[(open + 1)..close];
                if (!body.Contains('{') && !selector.StartsWith('@')) rules.Add(new CssRule(selector, Pairs(body)));
                position = close + 1;
            }
        }
        return rules;
    }

    static List<string> StyleBodies(string html)
    {
        var found = new List<string>();
        var from = 0;
        while (WebText.Find(html, "<style", from, ignoreCase: true) is { } open
               && WebText.Find(html, ">", open.End) is { } headEnd
               && WebText.Find(html, "</style>", headEnd.End, ignoreCase: true) is { } close)
        {
            found.Add(html[headEnd.End..close.Start]);
            from = close.End;
        }
        return found;
    }

    /// Оголошення з атрибута `style` у `<body>`.
    static Dictionary<string, string> BodyStyleAttribute(string html)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (WebText.Find(html, "<body", ignoreCase: true) is not { } tag || WebText.Find(html, ">", tag.End) is not { } end) return result;
        var head = html[tag.End..end.Start];
        if (WebText.Find(head, "style", ignoreCase: true) is not { } mark) return result;
        var quote = -1;
        for (var i = mark.End; i < head.Length; i++) if (head[i] is '"' or '\'') { quote = i; break; }
        if (quote < 0) return result;
        var closing = head.IndexOf(head[quote], quote + 1);
        if (closing < 0) return result;
        foreach (var (name, value) in Pairs(head[(quote + 1)..closing])) result[name] = value;
        return result;
    }

    static string WithoutComments(string text)
    {
        var result = new System.Text.StringBuilder();
        var position = 0;
        while (true)
        {
            var open = text.IndexOf("/*", position, StringComparison.Ordinal);
            if (open < 0) break;
            result.Append(text, position, open - position);
            var close = text.IndexOf("*/", open + 2, StringComparison.Ordinal);
            if (close < 0) return result.ToString();
            position = close + 2;
        }
        return result.Append(text, position, text.Length - position).ToString();
    }

    static List<(string Name, string Value)> Pairs(string body)
    {
        var list = new List<(string, string)>();
        foreach (var piece in body.Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var colon = piece.IndexOf(':');
            if (colon < 0) continue;
            var name = piece[..colon].Trim().ToLowerInvariant();
            var value = piece[(colon + 1)..].Trim();
            if (value.EndsWith("!important", StringComparison.Ordinal)) value = value[..^"!important".Length].TrimWhitespaces();
            if (name.Length == 0 || value.Length == 0 || name.StartsWith("--", StringComparison.Ordinal)) continue;
            list.Add((name, value));
        }
        return list;
    }

    /// Чи збігається селектор правила хоч з одним із наших — за шматками через кому
    /// і без псевдоелементів: `#content:first-line` — це все той самий `#content`.
    internal static bool SelectorMatches(string selector, string list)
    {
        var wanted = new HashSet<string>(list.Split(',', StringSplitOptions.RemoveEmptyEntries).Select(part => part.TrimWhitespaces()), StringComparer.Ordinal);
        foreach (var piece in selector.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var name = piece.TrimWhitespaces();
            var colon = name.IndexOf(':');
            if (colon >= 0) name = name[..colon];
            if (wanted.Contains(name)) return true;
        }
        return false;
    }

    // ── Значення ──────────────────────────────────────────────────────────────

    internal readonly record struct Rgba(int R, int G, int B, double A);

    internal static Rgba? Colour(string raw)
    {
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        switch (value)
        {
            case "white": return new Rgba(255, 255, 255, 1);
            case "black": return new Rgba(0, 0, 0, 1);
            case "transparent": return new Rgba(0, 0, 0, 0);
        }
        if (value.StartsWith('#'))
        {
            var digits = value[1..];
            int Byte(string pair) => int.TryParse(pair, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var n) ? n : 0;
            if (digits.Length == 6) return new Rgba(Byte(digits[0..2]), Byte(digits[2..4]), Byte(digits[4..6]), 1);
            if (digits.Length == 3)
            {
                int Twice(char c) => Byte(new string(c, 2));
                return new Rgba(Twice(digits[0]), Twice(digits[1]), Twice(digits[2]), 1);
            }
            return null;
        }
        var open = value.IndexOf('(');
        var close = value.IndexOf(')');
        if (!value.StartsWith("rgb", StringComparison.Ordinal) || open < 0 || close < 0) return null;
        if (close < open + 1) return null;
        var parts = value[(open + 1)..close].Split(new[] { ',', '/', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => part.TrimWhitespaces()).ToList();
        if (parts.Count < 3 || SwiftText.ParseDouble(parts[0]) is not { } r || SwiftText.ParseDouble(parts[1]) is not { } g
            || SwiftText.ParseDouble(parts[2]) is not { } b) return null;
        var a = parts.Count > 3 ? SwiftText.ParseDouble(parts[3]) ?? 1 : 1;
        return new Rgba((int)r, (int)g, (int)b, a);
    }

    internal static string Hex(Rgba rgba) =>
        $"#{Math.Clamp(rgba.R, 0, 255):x2}{Math.Clamp(rgba.G, 0, 255):x2}{Math.Clamp(rgba.B, 0, 255):x2}";

    /// Кегль у наших одиницях. Пікселі переводимо за кадром 1920×1080: сторінка
    /// слайда завжди на весь екран, і іншої опори в пікселя тут немає.
    internal static (string Size, string Unit)? FontSize(string raw)
    {
        var value = raw.TrimWhitespaces().ToLowerInvariant();
        double? N(string suffix) => value.EndsWith(suffix, StringComparison.Ordinal)
            ? SwiftText.ParseDouble(value[..^suffix.Length].TrimWhitespaces()) : null;
        if (N("vw") is { } vw) return (Trim(vw), "1vw");
        if (N("vh") is { } vh) return (Trim(vh), "1vh");
        if (N("px") is { } px) return (Trim(px / 19.2), "1vw");
        if (N("em") is { } em) return (Trim(em * 16 / 19.2), "1vw");
        if (N("%") is { } percent) return (Trim(percent * 16 / 100 / 19.2), "1vw");
        return null;
    }

    /// Довжина в частках екрана. Пікселі рахуємо за кадром 1920×1080.
    internal static string? Length(string text, bool vertical)
    {
        var value = text.TrimWhitespaces().ToLowerInvariant();
        double? N(string suffix) => value.EndsWith(suffix, StringComparison.Ordinal) ? SwiftText.ParseDouble(value[..^suffix.Length]) : null;
        if (N("vw") is { } vw) return Trim(vw) + "vw";
        if (N("vh") is { } vh) return Trim(vh) + "vh";
        if (N("px") is { } px) return vertical ? Trim(px / 10.8) + "vh" : Trim(px / 19.2) + "vw";
        return null;
    }

    internal static (string X, string Y)? Padding(string raw)
    {
        var parts = raw.TrimWhitespaces().Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return null;
        var vertical = Length(parts[0], vertical: true);
        var horizontal = Length(parts.Length > 1 ? parts[1] : parts[0], vertical: false);
        if (vertical == null || horizontal == null) return null;
        return (horizontal, vertical);
    }

    /// `bold` і `normal` — ті самі числа, лише словами.
    internal static string CssWeight(string raw) => raw.TrimWhitespaces().ToLowerInvariant() switch
    {
        "bold" => "700",
        "normal" => "400",
        "bolder" => "800",
        "lighter" => "300",
        _ => raw.TrimWhitespaces(),
    };

    internal static string Trim(double value)
    {
        var rounded = Math.Round(value * 100, MidpointRounding.AwayFromZero) / 100;
        return rounded == Math.Round(rounded, MidpointRounding.AwayFromZero)
            ? ((long)rounded).ToString(CultureInfo.InvariantCulture)
            : rounded.ToString("R", CultureInfo.InvariantCulture);
    }
}
