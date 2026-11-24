// =============================================================================
//  MediaFormats.cs — формати файлів плеєра й налаштування [mediaplayer]
// =============================================================================
//  За MediaFileFilters і MediaPlayerSettings у MediaPlayerModel.swift Mac 1.3.9.
//  Розширення — з `settings.json` оригіналу (VideoFilesFilter, AudioFilesFilter):
//  автор правит список від версії до версії, і вікно «Відкриття медіафайлів» має
//  показувати рівно те, що й стара програма; вбудована копія — запасна.
// =============================================================================

using System.Text.Json;
using Slovo.Core;

namespace Slovo.App;

public sealed class MediaFileFilters
{
    public IReadOnlyList<string> Video { get; }
    public IReadOnlyList<string> Audio { get; }
    /// Звідки прочитано списки; null — вбудована копія.
    public string? Source { get; }

    public MediaFileFilters(IReadOnlyList<string> video, IReadOnlyList<string> audio, string? source = null)
    {
        Video = video; Audio = audio; Source = source;
    }

    public IEnumerable<string> All => Video.Concat(Audio);

    /// Копія списків із поставки V2.5 — якщо `settings.json` поруч не знайшовся.
    public static readonly MediaFileFilters BuiltIn = new(
        Parse("*.3g2;*.3gp;*.3gp2;*.3gpp;*.amv;*.asf;*.avi;*.bik;*.divx;*.drc;*.dv;*.dvr-ms;*.evo;" +
              "*.f4v;*.flv;*.gvi;*.gxf;*.m1v;*.m2t;*.m2v;*.m2ts;*.m4v;*.mkv;*.mov;*.mp2v;*.mp4;" +
              "*.mp4v;*.mpa;*.mpe;*.mpeg;*.mpeg1;*.mpeg2;*.mpeg4;*.mpg;*.mpv2;*.mts;*.mtv;*.mxf;" +
              "*.nsv;*.nuv;*.ogg;*.ogm;*.ogx;*.ogv;*.rec;*.rm;*.rmvb;*.rpl;*.thp;*.tod;*.tp;*.ts;" +
              "*.tts;*.vob;*.vro;*.webm;*.wmv;*.wtv;*.xesc;"),
        Parse("*.3ga;*.669;*.a52;*.aac;*.ac3;*.adt;*.adts;*.aif;*.aifc;*.aiff;*.au;*.amr;*.aob;" +
              "*.ape;*.caf;*.cda;*.dts;*.flac;*.it;*.m4a;*.m4p;*.mid;*.mka;*.mlp;*.mod;*.mp1;" +
              "*.mp2;*.mp3;*.mpc;*.mpga;*.oga;*.oma;*.opus;*.qcp;*.ra;*.rmi;*.snd;*.s3m;*.spx;" +
              "*.tta;*.voc;*.vqf;*.w64;*.wav;*.wma;*.wv;*.xa;*.xm;"));

    /// Спершу тека, де знайшовся файл налаштувань, потім корінь даних.
    public static MediaFileFilters Load(string? dataRoot, string? configFolder = null)
    {
        foreach (var folder in new[] { configFolder, dataRoot })
            if (folder != null && Read(Path.Combine(folder, "settings.json")) is { } loaded) return loaded;
        return BuiltIn;
    }

    static MediaFileFilters? Read(string path)
    {
        try
        {
            if (!File.Exists(path)) return null;
            var data = File.ReadAllBytes(path);
            // Файл записано Delphi в UTF-8 з BOM.
            var offset = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
            using var doc = JsonDocument.Parse(data.AsMemory(offset));
            if (!doc.RootElement.TryGetProperty("settings", out var settings)) return null;
            var video = Parse(settings.TryGetProperty("VideoFilesFilter", out var v) ? v.GetString() ?? "" : "");
            var audio = Parse(settings.TryGetProperty("AudioFilesFilter", out var a) ? a.GetString() ?? "" : "");
            if (video.Count == 0 && audio.Count == 0) return null;
            return new MediaFileFilters(video.Count == 0 ? BuiltIn.Video : video, audio.Count == 0 ? BuiltIn.Audio : audio, path);
        }
        catch { return null; }
    }

    /// `*.mp4;*.mkv;` → `mp4`, `mkv`.
    public static List<string> Parse(string raw) =>
        raw.Split(';').Select(p => p.Trim().ToLowerInvariant()).Select(p => p.StartsWith("*.") ? p[2..] : p).Where(p => p.Length > 0).ToList();

    public bool Accepts(string path) => All.Contains(Path.GetExtension(path).TrimStart('.').ToLowerInvariant());

    /// Набори фільтрів вікна відкриття (у автора рівно чотири й підписані окремими ключами).
    public enum FilterGroup { Media, Video, Audio, Any }

    public static string CaptionKey(FilterGroup group) => group switch
    {
        FilterGroup.Media => "TextMessages54",
        FilterGroup.Video => "TextMessages55",
        FilterGroup.Audio => "TextMessages56",
        _ => "TextMessages57",
    };

    public static string FallbackCaption(FilterGroup group) => group switch
    {
        FilterGroup.Media => "Медиафайлы",
        FilterGroup.Video => "Видеофайлы",
        FilterGroup.Audio => "Аудиофайлы",
        _ => "Все файлы",
    };

    /// Розширення набору; «Усі файли» — порожньо (без обмежень).
    public IReadOnlyList<string> Extensions(FilterGroup group) => group switch
    {
        FilterGroup.Media => All.ToList(),
        FilterGroup.Video => Video,
        FilterGroup.Audio => Audio,
        _ => Array.Empty<string>(),
    };
}

/// Секція `[mediaplayer]` файла налаштувань оригіналу.
public sealed class MediaPlayerSettings
{
    public bool Repeats;
    /// `VideoDefVolume` там у відсотках 0…100.
    public double Volume = 1;
    public bool IsMuted;
    public bool VideoToScreen = true;
    public bool VideoToPreview = true;
    public bool AutoPlay = true;
    /// `MediaDefaultAudioDevice`: 0 — системний вихід.
    public int AudioDevice;

    public MediaPlayerSettings() { }

    public MediaPlayerSettings(IniSettings? config)
    {
        if (config == null) return;
        const string section = "mediaplayer";
        Repeats = config.Bool("VideoRepeate", section) ?? Repeats;
        if (config.Int("VideoDefVolume", section) is { } percent) Volume = Math.Clamp(percent / 100.0, 0, 1);
        IsMuted = config.Bool("AudioMute", section) ?? IsMuted;
        VideoToScreen = config.Bool("VideoToScreen", section) ?? VideoToScreen;
        VideoToPreview = config.Bool("VideoToPreview", section) ?? VideoToPreview;
        AutoPlay = config.Bool("VideoAutoPlay", section) ?? AutoPlay;
        AudioDevice = config.Int("MediaDefaultAudioDevice", section) ?? AudioDevice;
    }
}
