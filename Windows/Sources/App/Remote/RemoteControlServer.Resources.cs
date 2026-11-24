// =============================================================================
//  RemoteControlServer.Resources.cs — ресурси з пульта: переклади, пісенники,
//  фони, шаблони, шрифти, сторінки (як RemoteControlServer+Resources.swift)
// =============================================================================
//  Власник: «доступ к загрузке ресурсов с программы и всех источников, которые
//  есть в распоряжении программы». Той самий ResourceHub, що у вікні «Ресурси з
//  GitHub…» (свій каталог, «Цитата з Біблії», MyBible, eBible.org, SoftProjector),
//  доступний і з телефона, планшета чи «Проповідника».
//
//  Завантаження йде в програмі, а не в телефоні: там і мережа швидша, і файли
//  одразу лягають на місце. Пульт лише каже, що взяти, і бачить хід —
//  /api/resources/progress повертає, на чому програма зараз.
// =============================================================================

using System.Text.Json.Nodes;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public static class RemoteResources
{
    /// Хід завантаження — один на програму: два одночасних не буває. Живе в головному потоці.
    static class Work
    {
        public static bool Busy;
        public static string Title = "";
        public static int Done, Total;
        public static double Fraction;
        public static List<string> Installed = new(), Failures = new();
        public static DateTime? FinishedAt;
    }

    /// Джерела й що в кожного брати — рід ресурсу пульт показує окремо, щоб переклади
    /// й пісенники не змішувалися.
    public static JsonArray Sources() => new(ResourceSources.All.Select(source => (JsonNode?)new JsonObject
    {
        ["id"] = source.RawValue(),
        ["name"] = SourceName(source),
        ["kinds"] = new JsonArray(source.Kinds().Select(kind => kind.RawValue()).OrderBy(name => name, StringComparer.Ordinal)
                                        .Select(name => (JsonNode?)JsonValue.Create(name)).ToArray()),
    }).ToArray());

    public static string SourceName(ResourceHub.Source source) => source switch
    {
        ResourceHub.Source.Slovo => Captions.T("Слово: готовые ресурсы"),
        ResourceHub.Source.BibleQuote => "«Цитата з Біблії»",
        ResourceHub.Source.MyBible => "MyBible",
        ResourceHub.Source.EBible => "eBible.org",
        _ => "SoftProjector",
    };

    static ResourceHub.Source? Parse(string name) => ResourceSources.All.Cast<ResourceHub.Source?>().FirstOrDefault(source => source!.Value.RawValue() == name);

    public static JsonObject Progress() => new()
    {
        ["busy"] = Work.Busy,
        ["title"] = Work.Title,
        ["done"] = Work.Done,
        ["total"] = Work.Total,
        ["percent"] = (int)Math.Round(Work.Fraction * 100, MidpointRounding.AwayFromZero),
        ["installed"] = new JsonArray(Work.Installed.Select(t => (JsonNode?)JsonValue.Create(t)).ToArray()),
        ["failures"] = new JsonArray(Work.Failures.Select(t => (JsonNode?)JsonValue.Create(t)).ToArray()),
        ["finished"] = Work.FinishedAt != null && !Work.Busy,
    };

    /// Каталог джерела: `?source=slovo&kind=bible`. Довгі каталоги (MyBible, eBible)
    /// відсікаються пошуком `?q=`, щоб телефон не отримав півтори тисячі рядків одним куснем.
    public static void Catalog(HttpRequest request, AppState state, Action<int, JsonObject> reply)
    {
        var sourceName = request.Q("source") is { Length: > 0 } given ? given : ResourceHub.Source.Slovo.RawValue();
        if (Parse(sourceName) is not { } source)
        {
            reply(400, new JsonObject { ["error"] = Captions.T("нет такого источника") });
            return;
        }
        ResourceKind? kind = ResourceKinds.All.Cast<ResourceKind?>().FirstOrDefault(k => k!.Value.RawValue() == request.Q("kind"));
        var needle = request.Q("q").Trim().ToLowerInvariant();
        var limit = Math.Min(500, Math.Max(10, request.QInt("limit") ?? 300));
        var hub = new ResourceHub(new ResourceLayout(state.ModulesFolder));
        hub.FetchCatalog(source, (catalog, error) => Dispatcher.UIThread.Post(() =>
        {
            if (catalog == null)
            {
                reply(502, new JsonObject { ["error"] = error?.Message ?? "" });
                return;
            }
            IEnumerable<ResourceItem> items = catalog.Items;
            if (kind is { } wanted) items = items.Where(item => item.Kind == wanted);
            if (needle.Length > 0)
                items = items.Where(item => item.Title.ToLowerInvariant().Contains(needle, StringComparison.Ordinal)
                                            || item.Subtitle.ToLowerInvariant().Contains(needle, StringComparison.Ordinal));
            var all = items.ToList();
            var shown = all.Take(limit).Select(item => (JsonNode?)new JsonObject
            {
                ["id"] = item.Id,
                ["kind"] = item.Kind.RawValue(),
                ["title"] = item.Title,
                ["subtitle"] = item.Subtitle,
                ["size"] = item.Size,
                ["version"] = item.Version,
                ["language"] = item.Language ?? "",
                ["installed"] = hub.Layout.IsPresent(item),
            }).ToArray();
            reply(200, new JsonObject
            {
                ["source"] = source.RawValue(),
                ["name"] = SourceName(source),
                ["total"] = all.Count,
                ["shown"] = shown.Length,
                ["items"] = new JsonArray(shown),
            });
        }));
    }

    /// Команда `resource-install`: `{"source": "slovo", "ids": ["…", "…"]}`. Відповідає
    /// одразу — хід питають окремо, щоб телефон не тримав з'єднання.
    public static string? Install(JsonObject body, AppState state, JsonObject answer)
    {
        if (Work.Busy) return Captions.T("уже идёт загрузка");
        var sourceName = body["source"] is JsonValue value && value.TryGetValue<string>(out var given) ? given : ResourceHub.Source.Slovo.RawValue();
        if (Parse(sourceName) is not { } source) return Captions.T("нет такого источника");
        var wanted = new HashSet<string>(body["ids"] is JsonArray ids
            ? ids.Select(node => node is JsonValue v && v.TryGetValue<string>(out var id) ? id : null).OfType<string>()
            : Array.Empty<string>());
        if (wanted.Count == 0) return Captions.T("нечего загружать");
        var hub = new ResourceHub(new ResourceLayout(state.ModulesFolder));
        Work.Busy = true;
        Work.Title = Captions.T("читаю каталог");
        Work.Done = 0;
        Work.Total = wanted.Count;
        Work.Fraction = 0;
        Work.Installed = new List<string>();
        Work.Failures = new List<string>();
        Work.FinishedAt = null;
        Journal.Say($"пульт: ресурси — беру {wanted.Count} з «{sourceName}»");
        hub.FetchCatalog(source, (catalog, error) =>
        {
            if (catalog == null)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    Work.Busy = false;
                    Work.FinishedAt = DateTime.Now;
                    Work.Failures = new List<string> { error?.Message ?? "" };
                });
                return;
            }
            var items = catalog.Items.Where(item => wanted.Contains(item.Id)).ToList();
            if (items.Count == 0)
            {
                Dispatcher.UIThread.Post(() =>
                {
                    Work.Busy = false;
                    Work.FinishedAt = DateTime.Now;
                    Work.Failures = new List<string> { Captions.T("нечего загружать") };
                });
                return;
            }
            Dispatcher.UIThread.Post(() => Work.Total = items.Count);
            hub.Install(items, progress => Dispatcher.UIThread.Post(() =>
            {
                Work.Title = progress.Item.Title;
                Work.Done = progress.Index;
                Work.Fraction = (double)progress.Index / Math.Max(1, progress.Total) + (progress.Fraction ?? 0) / Math.Max(1, progress.Total);
            }), outcome => Dispatcher.UIThread.Post(() =>
            {
                Work.Busy = false;
                Work.FinishedAt = DateTime.Now;
                Work.Done = outcome.Installed.Count;
                Work.Fraction = 1;
                Work.Installed = outcome.Installed.Select(item => item.Title).ToList();
                Work.Failures = outcome.Failures.Select(f => $"{f.Item.Title}: {f.Reason}").ToList();
                Work.Title = outcome.Failures.Count == 0 ? Captions.T("готово") : Captions.T("не всё получилось");
                Journal.Say($"пульт: ресурси — поставлено {outcome.Installed.Count}, помилок {outcome.Failures.Count}");
                // Нові модулі мають з'явитися у списках програми.
                state.AdoptImported(ResourcesView.InstalledModules(hub.Layout, outcome.Installed));
            }));
        });
        answer["started"] = true;
        return null;
    }
}
