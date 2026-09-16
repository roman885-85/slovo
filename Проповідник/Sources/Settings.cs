// =============================================================================
//  Settings.cs — підключення й вибір людини
// =============================================================================

using System;
using System.IO;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Propovidnyk;

public sealed class Settings
{
    public string Host { get; set; } = "";
    public int Port { get; set; } = 8103;
    public string Pin { get; set; } = "";
    public string Name { get; set; } = "";
    public string Language { get; set; } = "auto";
    /// Останній відкритий план — щоб наступного разу почати з нього.
    public string LastPlan { get; set; } = "";

    public bool HasHost => !string.IsNullOrWhiteSpace(Host);

    public static Settings Load()
    {
        var settings = new Settings();
        try
        {
            if (!File.Exists(Paths.SettingsFile)) return settings;
            var json = JsonNode.Parse(File.ReadAllText(Paths.SettingsFile)) as JsonObject;
            if (json == null) return settings;
            settings.Host = (string?)json["host"] ?? "";
            settings.Port = (int?)json["port"] ?? 8103;
            settings.Pin = (string?)json["pin"] ?? "";
            settings.Name = (string?)json["name"] ?? "";
            settings.Language = (string?)json["language"] ?? "auto";
            settings.LastPlan = (string?)json["lastPlan"] ?? "";
        }
        catch (Exception error)
        {
            Paths.Say("налаштування не прочиталися: " + error.Message);
        }
        return settings;
    }

    public void Save()
    {
        var json = new JsonObject
        {
            ["host"] = Host,
            ["port"] = Port,
            ["pin"] = Pin,
            ["name"] = Name,
            ["language"] = Language,
            ["lastPlan"] = LastPlan,
        };
        var temp = Paths.SettingsFile + ".tmp";
        File.WriteAllText(temp, json.ToJsonString(new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temp, Paths.SettingsFile, true);
    }
}
