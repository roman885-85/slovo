// =============================================================================
//  WebSlideProbe.cs — спитати в самої сторінки, як вона виглядає
//  (з SlovoCore/Web/WebSlideProbe.swift)
// =============================================================================
//  Браузер знає точну відповідь: `getComputedStyle` повертає рівно те, що видно
//  на екрані. На Mac сторінку вантажать у невидимий WKWebView 1920×1080 і
//  питають цим скриптом. У самій програмі Mac проба не вживається (редактор
//  заводить порожній блок і пише лише те, що тронули), — нею користується
//  службовий `slovo-scan`. Тут — той самий скрипт і розбір відповіді; виконує
//  скрипт той, хто має браузер (WebView2 у вікні редактора).
// =============================================================================

using System.Text.Json.Nodes;

namespace Slovo.Core;

public static class WebSlideProbe
{
    /// Скрипт, що повертає JSON з обчисленими властивостями ролей і місцем тексту.
    public static string Script()
    {
        var roles = WebSlideParameters.RoleSelectors.Standard;
        return $$"""
        (function () {
          function pick(selector) {
            var el = null;
            try { el = document.querySelector(selector); } catch (e) { return null; }
            if (!el) return null;
            var s = getComputedStyle(el);
            return {
              "color": s.color,
              "background-color": s.backgroundColor,
              "background-image": s.backgroundImage,
              "background-size": s.backgroundSize,
              "background-position": s.backgroundPosition,
              "background-repeat": s.backgroundRepeat,
              "font-family": s.fontFamily,
              "font-size": s.fontSize,
              "font-weight": s.fontWeight,
              "font-style": s.fontStyle,
              "font-stretch": s.fontStretch,
              "text-transform": s.textTransform,
              "letter-spacing": s.letterSpacing,
              "line-height": s.lineHeight,
              "text-align": s.textAlign,
              "text-shadow": s.textShadow,
              "-webkit-text-stroke-width": s.webkitTextStrokeWidth,
              "-webkit-text-stroke-color": s.webkitTextStrokeColor,
              "display": s.display,
              "width": s.width,
              "border-radius": s.borderTopLeftRadius,
              "flex-direction": s.flexDirection,
              "align-items": s.alignItems,
              "justify-content": s.justifyContent,
              "padding-top": s.paddingTop,
              "padding-left": s.paddingLeft,
              "transition-duration": s.transitionDuration
            };
          }
          // Де текст стоїть насправді. Властивості розкладки про положення
          // мовчать: в автора шар із текстом лежить абсолютно, і `align-items`
          // батька нічого про нього не каже. А місце на екрані — каже.
          function place(selector) {
            var el = null;
            try { el = document.querySelector(selector); } catch (e) { return null; }
            if (!el) return null;
            var display = el.style.display, text = el.innerHTML;
            if (getComputedStyle(el).display === "none") { el.style.display = "block"; }
            if (!el.textContent.trim()) { el.innerHTML = "Проба положения текста"; }
            var r = el.getBoundingClientRect();
            el.style.display = display; el.innerHTML = text;
            if (!r.width && !r.height) return null;
            return {
              "x": String((r.left + r.width / 2) / Math.max(1, window.innerWidth)),
              "y": String((r.top + r.height / 2) / Math.max(1, window.innerHeight))
            };
          }
          return JSON.stringify({
            "page": pick({{Quoted(roles.Page)}}),
            "stage": pick({{Quoted(roles.Stage)}}),
            "text": pick({{Quoted(roles.Quote)}}),
            "reference": pick({{Quoted(roles.Reference)}}),
            "место": place({{Quoted(roles.Quote)}})
          });
        })()
        """;
    }

    static string Quoted(string text) => "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    /// Відповідь браузера (рядок JSON) → наші змінні; null — відповіді немає, і той,
    /// хто кличе, обходиться розбором CSS (`WebSlideParameters.Inferred`).
    public static WebSlideSettings? Settings(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        JsonObject? raw;
        try { raw = JsonNode.Parse(json) as JsonObject; } catch { return null; }
        if (raw == null) return null;
        var found = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        foreach (var (role, value) in raw)
        {
            if (value is not JsonObject table) continue;
            var map = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var (name, item) in table)
                if (item is JsonValue text && text.TryGetValue<string>(out var s)) map[name] = s;
            found[role] = map;
        }
        return WebSlideParameters.SettingsFromComputed(found);
    }
}
