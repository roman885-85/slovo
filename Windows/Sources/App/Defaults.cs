// =============================================================================
//  Defaults.cs — дрібні запам'ятовування вікна (висота нижнього ряду, ширини…)
// =============================================================================
//  На Mac це UserDefaults. Тут — файл `defaults.json` у теці даних «Слова»;
//  пишеться відкладено й разом, щоб тягання межі не писало диск на кожен рух.
// =============================================================================

using System.Text.Json;
using System.Text.Json.Nodes;
using Avalonia.Threading;

namespace Slovo.App;

public static class Defaults
{
    static JsonObject? _store;
    static bool _dirty;

    public static string Folder =>
        Program.DataOverride ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Slovo");

    static string FilePath => Path.Combine(Folder, "defaults.json");

    static JsonObject Store
    {
        get
        {
            if (_store != null) return _store;
            try { _store = JsonNode.Parse(File.ReadAllText(FilePath)) as JsonObject; } catch { }
            return _store ??= new JsonObject();
        }
    }

    public static bool Has(string key) => Store.ContainsKey(key);

    public static double Double(string key) =>
        Store[key] is JsonValue v && v.TryGetValue<double>(out var d) ? d : 0;
    public static bool Bool(string key) =>
        Store[key] is JsonValue v && v.TryGetValue<bool>(out var b) && b;
    public static string? String(string key) =>
        Store[key] is JsonValue v && v.TryGetValue<string>(out var s) ? s : null;
    public static int Int(string key) => (int)Math.Round(Double(key));

    public static void Set(string key, double value) { Store[key] = value; Save(); }
    public static void Set(string key, bool value) { Store[key] = value; Save(); }
    public static void Set(string key, string? value) { Store[key] = value; Save(); }
    public static void Remove(string key) { if (Store.Remove(key)) Save(); }

    static void Save()
    {
        if (_dirty) return;
        _dirty = true;
        DispatcherTimer.RunOnce(Flush, TimeSpan.FromMilliseconds(400));
    }

    public static void Flush()
    {
        if (!_dirty) return;
        _dirty = false;
        try
        {
            Directory.CreateDirectory(Folder);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, Store.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
            File.Move(temp, FilePath, true);
        }
        catch { }
    }
}
