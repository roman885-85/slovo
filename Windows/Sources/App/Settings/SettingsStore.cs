// =============================================================================
//  SettingsStore.cs — налаштування «Слова» (як SettingsStore на Mac)
// =============================================================================
//  Знімок усіх налаштувань (settings.json у теці даних, той самий файл, що на
//  Mac). Вікно «Параметри» правило в знімок, а на диск пише «Гаразд»; «Скасувати»
//  повертає знімок, узятий при відкритті (сесії правки вкладені). Перше читання
//  без settings.json — з Slovo.ini старої програми й hotkeys.ini.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed class SettingsStore
{
    public static readonly SettingsStore Shared = new();

    public SlovoSettings Settings { get; set; }
    readonly List<SlovoSettings> _snapshots = new();
    public string DataRoot { get; private set; }
    public string? ConfigPath { get; private set; }
    /// Налаштування записано на диск — частини програми підхоплюють зміни.
    public event Action? Changed;

    SettingsStore()
    {
        DataRoot = DataHome.Folder;
        Settings = Read(DataRoot);
        ConfigPath = IniSettings.LocateConfig();
    }

    public static string StoragePath => Path.Combine(DataHome.Folder, "settings.json");

    static SlovoSettings Read(string dataRoot)
    {
        try
        {
            if (File.Exists(StoragePath) && SlovoSettings.Decode(File.ReadAllBytes(StoragePath)) is { } saved)
            {
                if (saved.WebSlides.Count == 0) saved.WebSlides = SlovoSettings.ReadWebSlides(dataRoot);
                if (saved.WebSlides.Count == 0) saved.WebSlides = SlovoSettings.BuiltInWebSlides;
                return saved;
            }
        }
        catch (Exception error) { Journal.Say($"налаштування: settings.json не прочитався — {error.Message}"); }
        return Factory(dataRoot);
    }

    static SlovoSettings Factory(string dataRoot)
    {
        IniSettings? config = null;
        try { if (IniSettings.LocateConfig() is { } ini) config = IniSettings.FromFile(ini); } catch { }
        var fresh = new SlovoSettings(config, HotkeySets.Load(), dataRoot);
        if (fresh.WebSlides.Count == 0) fresh.WebSlides = SlovoSettings.BuiltInWebSlides;
        return fresh;
    }

    public void Reload(string dataRoot)
    {
        if (dataRoot == DataRoot && Settings.Modules.Count > 0) return;
        DataRoot = dataRoot;
        Settings = Read(dataRoot);
        _snapshots.Clear();
        ConfigPath = IniSettings.LocateConfig();
    }

    // --- Сесії правки ---------------------------------------------------------------

    public bool IsEditing => _snapshots.Count > 0;
    public readonly record struct EditSession(int Depth);

    public EditSession BeginEditing()
    {
        _snapshots.Add(Settings.Copy());
        return new EditSession(_snapshots.Count);
    }

    public void Cancel(EditSession? session = null)
    {
        if (Pop(session) is { } previous) Settings = previous;
    }

    public void CancelIfEditing(EditSession? session = null)
    {
        if (session is { } s ? _snapshots.Count >= s.Depth : _snapshots.Count > 0) Cancel(session);
    }

    SlovoSettings? Pop(EditSession? session)
    {
        if (session is not { } s)
        {
            if (_snapshots.Count == 0) return null;
            var last = _snapshots[^1];
            _snapshots.RemoveAt(_snapshots.Count - 1);
            return last;
        }
        if (_snapshots.Count < s.Depth) return null;
        while (_snapshots.Count > s.Depth) _snapshots.RemoveAt(_snapshots.Count - 1);
        var top = _snapshots[^1];
        _snapshots.RemoveAt(_snapshots.Count - 1);
        return top;
    }

    /// Записати на диск (якщо це остання відкрита сесія) і сповістити програму.
    public void Save(EditSession? session = null)
    {
        Pop(session);
        if (_snapshots.Count > 0) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(StoragePath)!);
            var temp = StoragePath + ".tmp";
            File.WriteAllBytes(temp, Settings.Encode());
            File.Move(temp, StoragePath, true);
        }
        catch (Exception error) { Journal.Say($"налаштування не записались: {error.Message}"); }
        EffectiveHotkeys.Adopt(Settings.HotkeySets, Settings.HotkeySetName);
        Changed?.Invoke();
    }

    /// Записати зміну, зроблену поза вікном «Параметри» (указка, ширини…), якщо вікно не відкрите.
    public void SaveOutsideEditing()
    {
        if (_snapshots.Count == 0) Save();
    }

    // --- Скидання, файл налаштувань ------------------------------------------------------

    public enum Area { Slide, Media, Paths, Update, Remote, Basic, Advanced, Modules, Hotkeys }

    public static string Title(Area area) => area switch
    {
        Area.Slide => OurWords.T("Слайд"), Area.Media => OurWords.T("Медиа"), Area.Paths => OurWords.T("Пути"),
        Area.Update => OurWords.T("Обновление"), Area.Remote => OurWords.T("Remote API"), Area.Basic => OurWords.T("Основные"),
        Area.Advanced => OurWords.T("Дополнительные"), Area.Modules => OurWords.T("Модули"), _ => OurWords.T("Горячие клавиши"),
    };

    /// Які поля ProgramOptions належать вкладці (імена — як у settings.json).
    public static string[] OptionKeys(Area area) => area switch
    {
        Area.Slide => new[] { "crossfadeTime", "hideFadeEasing", "hideFadeTime", "pointerColour", "pointerNDI", "pointerOpacity",
                              "pointerProjector", "pointerSize", "refAllMain", "refAllSec", "refMain", "refSec", "refsSeparated",
                              "showTransition", "showTransitionEasing", "showTransitionTime", "slideTransition", "slideTransitionEasing",
                              "songDotAfterNumber", "songNumberInBrackets", "songNumberInCollection", "songNumberPP" },
        Area.Media => new[] { "audioDeviceID", "ndiAudioGainDb", "ndiEnabled", "ndiFrameHeight", "ndiFrameRate", "ndiFrameRateIndex",
                              "ndiSendAudio", "ndiSendVideo", "ndiTransparentBackground", "ndiTransport", "ndiWiFiEnabled",
                              "ndiWiFiFrameRate", "ndiWiFiHeight", "showVideoOnPreview", "webVideoEnabled", "webVideoHeight", "webVideoKbps" },
        Area.Paths => new[] { "thumbsMode" },
        Area.Update => new[] { "updateInterval" },
        Area.Remote => new[] { "remoteEnabled", "remotePin", "remotePort", "remoteWebEnabled", "remoteWebName", "remoteWebNoPort",
                               "remoteWebPassword", "remoteWebPort", "remoteWebViewOnly", "tcpEnabled", "tcpPort", "udpEnabled",
                               "udpPort", "webEnabled", "webNetInterface", "webPort", "webSocketEnabled", "webSocketPort" },
        Area.Basic => new[] { "animationFrequency", "buttonAction", "customHeight", "customLeft", "customTop", "customWidth",
                              "defaultHeight", "defaultWidth", "foreground", "monitorIndex", "percentFillingPage", "slovoTitle" },
        Area.Advanced => new[] { "activeInputFieldColor", "doubleMonitors", "fastInputUseBackSpace", "hideSlideTime",
                                 "separatorTenVerses", "showSecondaryVerseNumbers", "showVerseNumbers", "songsEndMarker", "versesOnOwnLines" },
        Area.Modules => new[] { "lazyLoadModules", "loadAllBooks" },
        _ => new[] { "useRCPointer" },
    };

    public SlovoSettings FactorySettings() => Factory(DataRoot);

    public void ResetAll() => Settings = FactorySettings();

    public void Reset(Area area)
    {
        var fresh = FactorySettings();
        Settings.Options = Merge(Settings.Options, OptionKeys(area), fresh.Options);
        switch (area)
        {
            case Area.Modules: Settings.Modules = fresh.Modules; break;
            case Area.Paths: Settings.PicturePaths = fresh.PicturePaths; Settings.ScreenshotFolder = fresh.ScreenshotFolder; break;
            case Area.Remote: Settings.WebSlides = fresh.WebSlides; break;
            case Area.Hotkeys: Settings.HotkeySets = fresh.HotkeySets; Settings.HotkeySetName = fresh.HotkeySetName; break;
        }
    }

    /// Узяти з `fresh` лише поля вкладки — через JSON, як на Mac.
    static ProgramOptions Merge(ProgramOptions current, string[] keys, ProgramOptions fresh)
    {
        try
        {
            var mine = System.Text.Json.Nodes.JsonNode.Parse(SwiftJson.EncodeBytes(current))!.AsObject();
            var theirs = System.Text.Json.Nodes.JsonNode.Parse(SwiftJson.EncodeBytes(fresh))!.AsObject();
            foreach (var key in keys)
            {
                if (theirs.TryGetPropertyValue(key, out var value)) mine[key] = value?.DeepClone();
                else mine.Remove(key);
            }
            return SwiftJson.TryDecode<ProgramOptions>(System.Text.Encoding.UTF8.GetBytes(mine.ToJsonString())) ?? current;
        }
        catch { return current; }
    }

    public void Export(string path) => File.WriteAllBytes(path, Settings.Encode());

    public void Import(string path)
    {
        Settings = SlovoSettings.Decode(File.ReadAllBytes(path))
                   ?? throw new InvalidDataException(OurWords.T("Это не файл настроек «Слова» или он испорчен"));
    }

    // --- Модулі ---------------------------------------------------------------------------

    /// Звести список модулів із тим, що справді лежить у теці (як syncModuleRoster на Mac).
    public bool SyncModuleRoster(ISet<string> libraryIdentifiers, ISet<string> songBookStems, string modulesFolder, string dataRoot)
    {
        var roster = Settings.Modules.Select(e => e with { }).ToList();
        var before = string.Join("\n", roster.Select(e => $"{e.Path}|{e.Name}|{e.IsEnabled}"));
        foreach (var entry in roster.Where(e => e.Name.EndsWith(".vbm", StringComparison.OrdinalIgnoreCase)))
        {
            var url = entry.ResolvedUrl(dataRoot);
            var own = Path.ChangeExtension(url, "songbook");
            if (!File.Exists(url) && File.Exists(own))
            {
                entry.Path = entry.Path[..^3] + "songbook";
                entry.Name = Path.GetFileName(own);
            }
        }
        roster.RemoveAll(e => !Path.IsPathRooted(e.Path) && !File.Exists(e.ResolvedUrl(dataRoot)) && !Directory.Exists(e.ResolvedUrl(dataRoot)));
        var known = new HashSet<string>(roster.Select(e => e.LibraryIdentifier.ToLowerInvariant()));
        foreach (var e in roster.Where(e => e.IsSongBook)) known.Add(Path.GetFileNameWithoutExtension(e.Name).ToLowerInvariant());
        var prefix = Path.GetFileName(modulesFolder.TrimEnd(Path.DirectorySeparatorChar));
        if (Directory.Exists(modulesFolder))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(modulesFolder).Where(p => !Path.GetFileName(p).StartsWith('.'))
                                          .OrderBy(p => Path.GetFileName(p), Comparer<string>.Create(SwiftText.LocalizedStandardCompare)))
            {
                var name = Path.GetFileName(path);
                var isDirectory = Directory.Exists(path);
                var candidate = new ModuleRosterEntry(prefix + "\\" + name + (isDirectory ? "\\" : ""), name, true);
                var key = candidate.IsSongBook ? Path.GetFileNameWithoutExtension(name).ToLowerInvariant() : candidate.LibraryIdentifier.ToLowerInvariant();
                if (known.Contains(key)) continue;
                var belongs = candidate.IsSongBook ? songBookStems.Contains(key) : libraryIdentifiers.Contains(key);
                if (!belongs) continue;
                roster.Add(candidate);
                known.Add(key);
            }
        }
        var after = string.Join("\n", roster.Select(e => $"{e.Path}|{e.Name}|{e.IsEnabled}"));
        if (after == before) return false;
        Settings.Modules = roster;
        return true;
    }

    public void SetModule(string id, bool enabled)
    {
        if (Settings.Modules.FirstOrDefault(m => m.Id == id) is { } entry) entry.IsEnabled = enabled;
    }

    public void SetAllModules(bool enabled) { foreach (var m in Settings.Modules) m.IsEnabled = enabled; }

    public string? MoveModule(string id, int delta)
    {
        var index = Settings.Modules.FindIndex(m => m.Id == id);
        var target = index + delta;
        if (index < 0 || target < 0 || target >= Settings.Modules.Count) return null;
        (Settings.Modules[index], Settings.Modules[target]) = (Settings.Modules[target], Settings.Modules[index]);
        return id;
    }

    public enum ModuleProblem { NotBibleQuote, MySword, UnknownFormat, AlreadyListed }

    /// Лічильники пошуку сумісних текстів — (Label14) і (Label15) оригіналу; читаються з
    /// головного потоку, поки обхід іде у фоні.
    public sealed class TextScan
    {
        public volatile int Folders, Found;
    }

    /// (29) Пошук сумісних модулів на диску (scanForTexts Mac): теки з bibleqt.ini (усередину не
    /// заходимо — там сотні html-файлів однієї книги), файли .vbm, .sqlite3 і лише *.bbl.mybible
    /// (у MySword в одному розширенні лежать і переклади, і коментарі). Приховані — пропускаються.
    public static List<ModuleRosterEntry> ScanForTexts(string root, TextScan progress, CancellationToken cancel)
    {
        var entries = new List<ModuleRosterEntry>();
        var options = new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System, RecurseSubdirectories = false };
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0 && !cancel.IsCancellationRequested)
        {
            var folder = pending.Pop();
            IEnumerable<string> children;
            try { children = Directory.EnumerateFileSystemEntries(folder, "*", options).OrderBy(p => p, StringComparer.OrdinalIgnoreCase).ToList(); }
            catch { continue; }
            var subfolders = new List<string>();
            foreach (var path in children)
            {
                if (Directory.Exists(path))
                {
                    progress.Folders++;
                    if (File.Exists(Path.Combine(path, "bibleqt.ini")))
                    {
                        entries.Add(new ModuleRosterEntry(path, Path.GetFileName(path), true));
                        progress.Found = entries.Count;
                    }
                    else subfolders.Add(path);
                    continue;
                }
                var name = Path.GetFileName(path);
                var ext = Path.GetExtension(name).TrimStart('.').ToLowerInvariant();
                if (ext == "mybible" && !name.EndsWith(".bbl.mybible", StringComparison.OrdinalIgnoreCase)) continue;
                if (ext is "vbm" or "sqlite3" or "mybible")
                {
                    entries.Add(new ModuleRosterEntry(path, name, true));
                    progress.Found = entries.Count;
                }
            }
            // Стек — тож щоб обхід ішов у тому ж порядку, що на Mac (зверху вниз), кладемо навпаки.
            for (var i = subfolders.Count - 1; i >= 0; i--) pending.Push(subfolders[i]);
        }
        return entries;
    }

    /// TextMessages13: «Так» — замінити список, «Ні» — додати до наявного (applyFoundTexts Mac).
    public void ApplyFoundTexts(IReadOnlyList<ModuleRosterEntry> found, bool replacing)
    {
        var entries = found.Select(e => new ModuleRosterEntry(RelativePath(e.Path), e.Name, true)).ToList();
        if (replacing) { Settings.Modules = entries; return; }
        foreach (var entry in entries)
            if (!Settings.Modules.Any(m => m.Path == entry.Path)) Settings.Modules.Add(entry);
    }

    public ModuleProblem? AddModule(string path)
    {
        if (Problem(path) is { } problem) return problem;
        var entry = new ModuleRosterEntry(RelativePath(path), Path.GetFileName(path.TrimEnd(Path.DirectorySeparatorChar)), true);
        if (Settings.Modules.Any(m => m.Path == entry.Path)) return ModuleProblem.AlreadyListed;
        Settings.Modules.Add(entry);
        return null;
    }

    public static ModuleProblem? Problem(string path)
    {
        if (Directory.Exists(path))
            return Directory.EnumerateFiles(path).Any(f => Path.GetFileName(f).Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase))
                ? null : ModuleProblem.NotBibleQuote;
        if (!File.Exists(path)) return ModuleProblem.UnknownFormat;
        var name = Path.GetFileName(path).ToLowerInvariant();
        if (name.EndsWith(".bbl.mybible")) return null;
        if (name.EndsWith(".mybible") || name.EndsWith(".bbl")) return ModuleProblem.MySword;
        return Path.GetExtension(name) is ".vbm" or ".sqlite3" or ".sqlite" or ".songbook" ? null : ModuleProblem.UnknownFormat;
    }

    public void RemoveModule(string id) => Settings.Modules.RemoveAll(m => m.Id == id);

    /// Тека з фонами — у «Шляхи для фонових малюнків», якщо її там ще немає (addPicturePath на Mac).
    public bool AddPicturePath(string folder)
    {
        var entry = new PicturePathEntry(RelativePath(folder), false);
        if (Settings.PicturePaths.Any(p => p.Path == entry.Path)) return false;
        Settings.PicturePaths.Add(entry);
        return true;
    }

    /// Шлях відносно теки даних — так, як його пише стара програма («Modules\UBT\»).
    public string RelativePath(string path)
    {
        var root = Path.GetFullPath(DataRoot).TrimEnd(Path.DirectorySeparatorChar);
        var full = Path.GetFullPath(path);
        if (!full.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) return full;
        var tail = full[(root.Length + 1)..].Replace('/', '\\');
        if (Directory.Exists(full) && !tail.EndsWith('\\')) tail += "\\";
        return tail;
    }

    public string Resolve(string path) =>
        Path.IsPathRooted(path) ? path : Path.Combine(DataRoot, path.Replace('\\', Path.DirectorySeparatorChar));

    // --- Гарячі клавіші --------------------------------------------------------------------

    public Dictionary<string, Hotkey> Hotkeys => Settings.Hotkeys;

    public void SetHotkey(Hotkey? hotkey, string action, string? clearing = null)
    {
        var current = new Dictionary<string, Hotkey>(Hotkeys);
        if (clearing != null) current.Remove(clearing);
        if (hotkey is { } h) current[action] = h; else current.Remove(action);
        Settings.HotkeySets.Replace(Settings.HotkeySetName, current);
    }
}
