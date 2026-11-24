// =============================================================================
//  RemoteControlServer.Android.cs — програми для Android зі сторінки пульта
// =============================================================================
//  Як +Android на Mac: «Планшет Слова» і «Пульт Слова» лежать у теці Android
//  поруч із програмою (apps.json — версії й найменший Android). Немає теки —
//  список порожній, і сторінка про це скаже.
// =============================================================================

using System.Text.Json;
using System.Text.Json.Nodes;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class RemoteControlServer
{
    sealed record AndroidApp(string Id, string File, string Title, string Download, string Version, int MinSdk)
    {
        public string MinAndroid => MinSdk switch
        {
            21 => "5", 22 => "5.1", 23 => "6", 24 => "7", 25 => "7.1", 26 => "8", 27 => "8.1", 28 => "9", 29 => "10",
            30 => "11", 31 => "12", 32 => "12L", 33 => "13", 34 => "14", 35 => "15", 36 => "16", _ => $"API {MinSdk}",
        };
    }

    static string? AndroidFolder
    {
        get
        {
            // Тека поруч із самим Слово.exe — не AppContext.BaseDirectory: однофайлова збірка
            // розпаковує вміст (модулі плеєра) у тимчасову теку, і BaseDirectory показує туди.
            var exeFolder = Path.GetDirectoryName(Environment.ProcessPath ?? "") ?? "";
            foreach (var root in new[] { exeFolder, AppContext.BaseDirectory, DataHome.Folder }.Where(r => r.Length > 0).Distinct())
            {
                var folder = Path.Combine(root, "Android");
                if (Directory.Exists(folder)) return folder;
            }
            return null;
        }
    }

    static IReadOnlyList<AndroidApp> AndroidApps
    {
        get
        {
            var info = new Dictionary<string, JsonElement>();
            try
            {
                if (AndroidFolder is { } folder && File.Exists(Path.Combine(folder, "apps.json")))
                    info = JsonSerializer.Deserialize<Dictionary<string, JsonElement>>(File.ReadAllText(Path.Combine(folder, "apps.json"))) ?? new();
            }
            catch { info = new(); }
            AndroidApp App(string id, string file, string title, string download, int minSdk)
            {
                var version = "";
                var sdk = 0;
                if (info.TryGetValue(id, out var entry) && entry.ValueKind == JsonValueKind.Object)
                {
                    if (entry.TryGetProperty("version", out var v) && v.ValueKind == JsonValueKind.String) version = v.GetString() ?? "";
                    if (entry.TryGetProperty("minSdk", out var s) && s.ValueKind == JsonValueKind.Number) sdk = s.GetInt32();
                }
                return new AndroidApp(id, file, title, download, version, sdk > 0 ? sdk : minSdk);
            }
            return new[]
            {
                App("tablet", "Планшет Слова.apk", "Планшет Слова", "Slovo-Tablet.apk", 21),
                App("phone", "Пульт Слова.apk", "Пульт Слова", "Slovo-Remote.apk", 23),
            };
        }
    }

    /// Програма для Android — для вкладки «Remote API» і вікна QR-кодів.
    public sealed record AndroidAppInfo(string Id, string Title, string FileName, string Download, string Version, string MinAndroid, string? Path);

    public static IReadOnlyList<AndroidAppInfo> AndroidAppsForSettings =>
        AndroidApps.Select(a => new AndroidAppInfo(a.Id, a.Title, a.File, a.Download, a.Version, a.MinAndroid, AndroidFile(a))).ToList();

    static string? AndroidFile(AndroidApp app) =>
        AndroidFolder is { } folder && File.Exists(Path.Combine(folder, app.File)) ? Path.Combine(folder, app.File) : null;

    static JsonObject AndroidAppsJson() => new()
    {
        ["apps"] = new JsonArray(AndroidApps.Select(app => AndroidFile(app) is { } path
            ? (JsonNode?)new JsonObject
            {
                ["id"] = app.Id, ["title"] = app.Title, ["version"] = app.Version, ["minSdk"] = app.MinSdk, ["minAndroid"] = app.MinAndroid,
                ["size"] = new FileInfo(path).Length, ["url"] = $"/download/{app.Id}.apk",
            }
            : null).Where(n => n != null).ToArray()),
    };

    static void ServeAndroidApp(string path, HttpConnection connection)
    {
        var id = path["/download/".Length..].Replace(".apk", "");
        if (AndroidApps.FirstOrDefault(a => a.Id == id) is not { } app || AndroidFile(app) is not { } file)
        {
            Fail(connection, 404, Captions.T("нет такого файла"));
            return;
        }
        RespondData(connection, 200, File.ReadAllBytes(file), "application/vnd.android.package-archive",
                    new Dictionary<string, string> { ["Content-Disposition"] = $"attachment; filename=\"{app.Download}\"" });
    }

    // --- Ресурси (RemoteControlServer.Resources.cs) -----------------------------------

    bool ResourcesGet(HttpRequest request, AppState state, HttpConnection connection)
    {
        switch (request.Path)
        {
            case "/api/resources/sources": Respond(connection, 200, new JsonObject { ["sources"] = RemoteResources.Sources() }); return true;
            case "/api/resources/progress": Respond(connection, 200, RemoteResources.Progress()); return true;
            case "/api/resources": RemoteResources.Catalog(request, state, (status, json) => Respond(connection, status, json)); return true;
            default: return false;
        }
    }

    static string? StartResourceInstall(JsonObject body, AppState state, JsonObject answer) => RemoteResources.Install(body, state, answer);
}
