// =============================================================================
//  CoreCheck.Web.cs — перевірка ядра: веб-слайди (`--section web`)
// =============================================================================
//  Дзеркало еталона на Mac (slovo-ref, Web.swift): заготовки обома мовами (і
//  побайтно проти сторінок, які записала Mac-програма, — тека WebSlides даних),
//  розбір/запис/зняття блоків на кожній сторінці теки (LF і CRLF), прив'язка,
//  переклад чужого CSS у змінні, перенесення налаштувань, каталог параметрів,
//  підстановки стартової сторінки, розкладка шаблону для браузера.
// =============================================================================

using System.Text;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static string Kind(WebSlideBlock block) => block.Kind switch
    {
        WebSlideBlock.Kinds.Present => $"present/{block.Version}/{block.Extras}",
        WebSlideBlock.Kinds.Missing => "missing",
        _ => "damaged/" + block.Reason,
    };

    private static string Outcome(WebSlideWriteOutcome outcome) => outcome.Html is { } html ? Fnv(html) : "refused: " + outcome.Reason;

    private static string Order(WebSlideSettings settings) => Join(settings.WritingOrder.Select(pair => $"{pair.Name}={pair.Value}"), ";");

    private static string FirstDifference(string a, string b)
    {
        var length = Math.Min(a.Length, b.Length);
        for (var i = 0; i < length; i++) if (a[i] != b[i]) return $"diff@{i}";
        return a.Length == b.Length ? "same" : $"diff@{length}";
    }

    private static void WebPage(string label, string html)
    {
        var document = WebSlideParameters.Parse(html);
        P($"parse {label} block {Kind(document.Block)} head {B(document.HasHead)} bind {B(document.HasBinding)} n {document.Settings.Count} adj {B(document.IsAdjustable)} nl {(document.Newline == "\r\n" ? "crlf" : "lf")} outside {Join(document.OutsideNames)} note {document.Note ?? "-"}");
        P($"  roles {Join(WebSlideParameters.RoleSelectors.Standard.Present(html).Select(role => role.ToString().ToLowerInvariant()).OrderBy(name => name, StringComparer.Ordinal))}");
        P($"  declared {Order(WebSlideParameters.Declared(html))}");
        P($"  inferred {Order(WebSlideParameters.Inferred(html))}");
        var changed = document.Settings.Copy();
        changed.Choose(WebSlideParameters.Parameter("--sl-anchor")!, "bottom-right");
        changed.Set("--sl-color", "#123456");
        var written = WebSlideParameters.Write(html, changed);
        P($"  write {Outcome(written)}");
        if (written.Html is { } result)
        {
            var again = WebSlideParameters.Parse(result);
            P($"  again {Kind(again.Block)} same {B(again.Settings.Equals(changed))} strip {FirstDifference(WebSlideParameters.StripBlocks(result), WebSlideParameters.StripBlocks(html))} structure {Fnv(WebSlideParameters.Structure(result))} carry {Fnv(WebSlideParameters.CarryOverSettings(result, html))}");
            var twice = WebSlideParameters.Write(result, again.Settings);
            P($"  rewrite {Outcome(twice)} stable {B(twice.Html == result)}");
        }
        P($"  empty {Outcome(WebSlideParameters.Write(html, new WebSlideSettings()))}");
        P($"  defaults {Outcome(WebSlideParameters.Write(html, WebSlideParameters.Inferred(html).ApplyingDefaults()))}");
        P($"  repair {Outcome(WebSlideParameters.Repair(html, WebSlideParameters.Defaults))}");
        P($"  strip {Fnv(WebSlideParameters.StripBlocks(html))} structure {Fnv(WebSlideParameters.Structure(html))}");
    }

    private static void Web(string dataPath)
    {
        P("# web");
        var was = OurWords.Language;
        try
        {
            // Мова — одна на прогін (на Mac заготовки збираються раз за життя програми):
            // SLOVO_WEB_LANG=ru|uk, за умовчанням uk.
            var language = Environment.GetEnvironmentVariable("SLOVO_WEB_LANG") is { Length: > 0 } chosen ? chosen : "uk";
            OurWords.Language = language;
            P($"lang {language}");
            foreach (var template in WebSlideTemplates.All)
                P($"tpl {template.Id} {Fnv(template.Html)} names {template.ParameterNames.Count} params {template.Parameters.Count} «{template.Title}»");
            // Сторінки, які записала сама Mac-програма (сівалка): заготовка мусить збігтися побайтно.
            var seeded = Path.Combine(dataPath, "WebSlides");
            foreach (var template in WebSlideTemplates.All)
            {
                var file = Path.Combine(seeded, template.Id + ".html");
                if (Environment.GetEnvironmentVariable("SLOVO_WEB_DUMP") is { Length: > 0 } dump)
                    File.WriteAllText(Path.Combine(dump, template.Id + ".html"), template.Html, new UTF8Encoding(false));
                if (!File.Exists(file)) continue;
                var onDisk = File.ReadAllText(file, Encoding.UTF8);
                // Сівалка на Mac переносить налаштування власника у свіжу заготовку: те саме
                // перенесення тут мусить дати рівно той файл, що лежить на диску.
                P($"file {template.Id} {FirstDifference(template.Html, onDisk)} carry {FirstDifference(WebSlideParameters.CarryOverSettings(onDisk, template.Html), onDisk)}");
            }

            P($"bind all {Fnv(WebSlideParameters.BindingCSS())}");
            P($"bind only {Fnv(WebSlideParameters.BindingCSS(only: new HashSet<string> { "--sl-color", "--sl-h", "--sl-plate-full" }))}");
            P($"bind none {WebSlideParameters.BindingCSS(only: new HashSet<string>())}");
            P($"vars {Fnv(WebSlideParameters.VarsElement(WebSlideParameters.Defaults))} live {Fnv(WebSlideParameters.LiveElement())} bindel {Fnv(WebSlideParameters.BindElement())}");
            P($"root {Fnv(WebSlideParameters.RootCSS(WebSlideParameters.Defaults))} defaults {WebSlideParameters.Defaults.Count}");
            P($"preview {Fnv(WebSlideParameters.PreviewScript(new Dictionary<string, string> { ["--sl-b"] = "1", ["--sl-a"] = "x'y", ["--sl-c"] = "a;b" }))}");

            foreach (var parameter in WebSlideParameters.All)
            {
                var number = parameter.NumberFrom(parameter.DefaultValue);
                P($"param {parameter.Name} {parameter.Section.Key()} {parameter.ValueKind.Tag.ToString().ToLowerInvariant()} valid {B(parameter.IsValid(parameter.DefaultValue))} panel {B(parameter.ShowsInPanel)} css {B(parameter.IsBoundToCSS)} role {parameter.PageRole.ToString().ToLowerInvariant()} num {(number is { } n ? D(n) : "-")} text {(number is { } m ? parameter.TextFrom(m + 0.123456) : "-")} clamp {parameter.TextFrom(-1000)}/{parameter.TextFrom(1000)}");
            }
            foreach (var value in new[] { "", "#fff", "#12345", "a;b", "url(x)", "1 2 3", "1 2 256", "--x", new string('a', 201), "/* x", "ok" })
                P($"writable «{value[..Math.Min(value.Length, 12)]}» {B(WebSlideParameters.IsWritable(value))} name {B(WebSlideParameters.IsVariableName(value))}");

            var computed = new Dictionary<string, Dictionary<string, string>>
            {
                ["page"] = new() { ["background-color"] = "rgba(10, 20, 30, 0.5)", ["background-image"] = "none", ["font-size"] = "32px", ["color"] = "rgb(255, 255, 255)" },
                ["stage"] = new() { ["display"] = "flex", ["align-items"] = "flex-end", ["justify-content"] = "center", ["padding-top"] = "21.6px", ["padding-left"] = "96px", ["background-color"] = "rgba(0, 0, 0, 0.3)", ["border-radius"] = "16px" },
                ["text"] = new() { ["font-family"] = "Arial", ["font-weight"] = "bold", ["font-style"] = "italic", ["letter-spacing"] = "1.6px", ["line-height"] = "40px", ["text-align"] = "justify", ["width"] = "1728px", ["-webkit-text-stroke-width"] = "2px", ["-webkit-text-stroke-color"] = "#abc", ["text-shadow"] = "rgb(0,0,0) 1px 1px 2px", ["transition-duration"] = "0.5s, 1s", ["font-stretch"] = "87.5%", ["padding-top"] = "10px", ["padding-left"] = "1vw" },
                ["reference"] = new() { ["color"] = "#ffd98a", ["font-style"] = "normal", ["display"] = "none", ["font-size"] = "12px" },
                ["место"] = new() { ["x"] = "0.8", ["y"] = "0.2" },
            };
            P($"computed {Order(WebSlideParameters.SettingsFromComputed(computed))}");

            // Сторінки теки (свої й авторські): LF і та сама сторінка з переносами CRLF.
            var pages = new List<string>();
            foreach (var folder in new[] { Path.Combine(dataPath, "WebSlides"), Path.Combine(dataPath, "RemoteAPI") })
                if (Directory.Exists(folder))
                    pages.AddRange(Directory.GetFiles(folder, "*.html").OrderBy(name => Path.GetFileName(name), StringComparer.Ordinal));
            foreach (var file in pages)
            {
                var html = File.ReadAllText(file, Encoding.UTF8);
                var name = Path.GetFileName(file);
                WebPage(name, html);
                // Сторінка без наших блоків — так виглядає чужа сторінка, на яку блок ще не надягали.
                var bare = WebSlideParameters.StripBlocks(html);
                WebPage(name + "#bare", bare);
                WebPage(name + "#crlf", bare.Replace("\n", "\r\n"));
            }
            var broken = "<html><head><style data-slovo=\"vars\">\n:root {\n  --sl-color: #fff;\n}\n</head><body></body></html>";
            WebPage("broken", broken);
            WebPage("nohead", "<html><body><div id=\"content\">x</div></body></html>");

            var index = "<html lang=\"{{LANG}}\"><title>{{TITLE}}</title><th>{{PAGE}}</th><th>{{DESCRIPTION}}</th><th>{{QRCODE}}</th>{{#each WebSlides as WebSlide}}<a href=\"{{WebSlide->Name}}\" data-href=\"{{WebSlide->Name}}\">{{WebSlide->Name}}</a> {{WebSlide->Address}} {{WebSlide->Description}};{{/each}} ws://{{SERVER_ADDR}}:8100/ws</html>";
            var model = new WebIndexModel(new[] { WebOutputSettings.WebPage.Make("VBWebSlideCF.html", "x"), WebOutputSettings.WebPage.Make("Моя сторінка <1>.html", "Опис & «лапки»") }, "Заголовок", "uk");
            P($"index {WebTemplate.RenderIndex(index, model, "192.168.1.5")}");
            P($"page {WebTemplate.RenderPage("{{SERVER_ADDR}} {{LANG}} {{TITLE}}", model, "h'x")}");
            P($"retarget {WebTemplate.RetargetWebSocket("ws://localhost:8100/ws ws://x:8100/ws", "10.0.0.2", 9000)} | {WebTemplate.RetargetWebSocket("ws://localhost:8100/ws", "localhost", 8100)}");
            P($"phrases {WebTemplate.ReplaceAuthorPhrases("a('Connect to VisioBible WS-Server...'); <title>VisioBible Web Slide</title> Connection lost. Trying to reconnect to VisioBible WS-Server...")}");
            P($"escape {WebTemplate.Escape("<a href=\"x\">'&'</a>")}");
            P($"host {HTTPStaticServer.SanitizedHost("192.168.1.5:82")} {HTTPStaticServer.SanitizedHost("[::1]:82")} {HTTPStaticServer.SanitizedHost("evil\"host")} {HTTPStaticServer.SanitizedHost(null)} {HTTPStaticServer.SanitizedHost("slovo.local")}");
            P($"slidepage {Fnv(WebSlovoSlidePage.Html(18100, "10.0.0.2"))}");
            P($"shim {B(WebSlideTemplates.PreviewShim("Текст", "", "Ів 3:16", "Далі", "Song", "Пісня", true, 1, 3).Length > 0)}");

            // Розкладка шаблону для браузера — зі стандартного шаблону програми.
            var style = new SlideStyle();
            foreach (var preset in new[] { SlidePreset.Standard("Стандарт", style), SlidePreset.Song("Пісня", style), SlidePreset.Stage("Служитель", style) })
            {
                var layout = WebSlideLayout.Make(preset, false, item => item.Kind.RawValue() + " текст", path => "img:" + path, family => "font:" + family);
                P($"layout {preset.Name} {D(layout.CanvasWidth)}x{D(layout.CanvasHeight)} bg {WebSlideLayout.Rgba(layout.Background.Color)} {layout.Background.ImageID ?? "-"} {layout.Background.FillMode} fonts {Join(layout.Fonts.OrderBy(pair => pair.Key, StringComparer.Ordinal).Select(pair => pair.Key + "=" + pair.Value))} empty {B(layout.IsEmpty)}");
                foreach (var item in layout.Objects)
                    P($"  obj {item.Kind} {D(item.X)} {D(item.Y)} {D(item.Width)} {D(item.Height)} «{item.Text}» {item.FontFamily} {D(item.FontSize)} {B(item.IsBold)}{B(item.IsItalic)}{B(item.IsUnderlined)} {WebSlideLayout.Rgba(item.Color)} {item.Alignment} {item.VerticalAlignment} {D(item.LineSpacing)} {D(item.MinimumScale)} {D(item.Opacity)} {WebSlideLayout.Rgba(item.BackgroundColor)} {D(item.CornerRadius)} {D(item.BlurRadius)} {WebSlideLayout.Rgba(item.OutlineColor)} {D(item.OutlineWidth)} {WebSlideLayout.Rgba(item.ShadowColor)} {D(item.ShadowOffset)} {D(item.ShadowBlur)} {D(item.ShadowAngle)}");
            }
        }
        finally { OurWords.Language = was; }
    }
}
