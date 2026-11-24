// =============================================================================
//  AppState.Templates.cs — шаблон слайда, свої шаблони, фони (як AppState.swift)
// =============================================================================
//  Шаблон (.sch автора з теки Templates) задає шрифти, кольори й фон; вибір
//  запам'ятовується. Свій шаблон із Конструктора (PresetLibrary) — главніший:
//  зал, передпоказ і трансляція йдуть одним. Фони: «Фон загальний» — підкладка,
//  що стоїть, поки тексту немає; «Фон слайда» — під текстом; без вибору —
//  фон шаблону. Порядок як в автора: загальний, свій фон слайда, фон шаблону.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    /// Авторські шаблони (.sch) з теки Templates.
    public SchemeLibrary? Schemes { get; private set; }
    /// Свої шаблони — ті, що зібрали в Конструкторі (лежать окремо, авторські не переписуємо).
    public PresetLibrary Presets { get; private set; } = new(PresetLibrary.DefaultFolder);
    public string TemplateName { get; private set; } = "";
    /// «Фон Загальний» — підкладка для всіх слайдів.
    public string? CommonBackgroundPath { get; private set; }
    /// Фон слайда, вибраний людиною (важливіший за фон шаблону).
    public string? SlideBackgroundPath { get; private set; }
    public bool ShowsCommonBackground { get; private set; } = true;
    /// Картинки з теки BackGrounds — для меню «Фон Слайда».
    public IReadOnlyList<string> BackgroundImages { get; private set; } = Array.Empty<string>();
    /// Шаблон, який зараз правлять у Конструкторі: зал показує його, не чекаючи збереження.
    public SlidePreset? LivePreset { get; private set; }
    string? _hiddenBackgroundPath;
    bool _liveIsSong;
    readonly Dictionary<string, string?> _presetImages = new();

    /// Клавіші «Вибрати Спільний фон» / «Вибрати фон Слайда» — меню живуть у нижньому ряду.
    public Action? ChooseCommonBackgroundRequested, ChooseSlideBackgroundRequested;

    public SchemeLibrary.Template? CurrentTemplate =>
        Schemes != null && TemplateName.Length > 0 ? Schemes.TemplateNamed(TemplateName) : null;

    /// Область налаштувань вигляду списків за вкладкою (Біблія, Текст, Пісні).
    public InterfaceSettings.ListScope ListScope => Mode switch
    {
        WorkMode.Text => InterfaceSettings.ListScope.Text,
        WorkMode.Songs => InterfaceSettings.ListScope.Songs,
        _ => InterfaceSettings.ListScope.Bible,
    };

    /// Чи слайд зараз — пісня (за вкладкою): тоді береться шаблон пісень, якщо є.
    public bool ShowsSongSlide => Mode == WorkMode.Songs;

    /// Свій шаблон, застосований до залу; null — слайд за авторським шаблоном.
    public SlidePreset? SlidePreset => LivePreset ?? OwnPreset(OutputKind.Screen);

    /// Свій шаблон виводу з урахуванням того, що на слайді: пісням — їхній, якщо призначено.
    public SlidePreset? OwnPreset(OutputKind kind, bool? songs = null)
    {
        if ((songs ?? ShowsSongSlide) && Presets.Preset(kind, true) is { } own) return own;
        return Presets.Preset(kind);
    }

    /// Свій шаблон для виводу: зал і трансляція — шаблоном тієї вкладки, з якої
    /// вивели; передпоказ — тим, що відкрито. Перехід із «Параметрів» главніший
    /// за перехід шаблону («половина ефектів не працює»).
    public SlidePreset? Preset(OutputKind kind)
    {
        var target = kind == OutputKind.Ndi ? OutputKind.Screen : kind;
        var songs = target == OutputKind.Preview ? ShowsSongSlide : _liveIsSong;
        var chosen = target is OutputKind.Screen or OutputKind.Preview
            ? LivePreset ?? OwnPreset(target, songs)
            : OwnPreset(target, songs);
        if (chosen != null && SettingsStore.Shared.Settings.Options.SlideTransition != null)
        {
            chosen = chosen.Copy();
            chosen.Transition = Style.TransitionKind;
            chosen.TransitionDuration = Style.TransitionDuration;
            chosen.TransitionEasing = Style.EffectiveEasing;
        }
        return chosen;
    }

    /// Прочитати шаблони, фони й те, що вибирали минулого разу (після бібліотеки).
    void LoadTemplates()
    {
        IniSettings? config = null;
        try { if (IniSettings.LocateConfig() is { } ini) config = IniSettings.FromFile(ini); } catch { }
        try { Schemes = SchemeLibrary.FromDataRoot(DataHome.Folder, config); }
        catch (Exception error) { Journal.Say($"шаблони: {error.Message}"); Schemes = null; }
        Presets = new PresetLibrary(PresetLibrary.DefaultFolder);
        LoadBackgrounds();

        // Файл налаштувань — це ПОЧАТКОВІ значення: вибір людини главніший.
        var remembered = Defaults.String("lastTemplate") ?? "";
        TemplateName = remembered.Length > 0 ? remembered : config?.String("DefaultScheme", "Bible") ?? "";
        ShowsCommonBackground = Defaults.Has("showsCommonBackground")
            ? Defaults.Bool("showsCommonBackground")
            : config?.Bool("ShowCommonBackGr", "settings") ?? true;
        CommonBackgroundPath = Remembered("commonBackground") ?? FromConfig(config, "CommonBackgrFileName");
        SlideBackgroundPath = Remembered("slideBackground") ?? FromConfig(config, "SlideBackgrFileName");

        if (remembered.Length > 0 && Schemes?.TemplateNamed(remembered) != null) ApplyTemplate(remembered, remember: false);
        // Правлений вигляд кладеться ПОВЕРХ шаблону: правки людини главніші.
        if (Defaults.String("slideStyle") is { Length: > 0 } saved)
        {
            try { Style = SwiftJson.Decode<SlideStyle>(System.Text.Encoding.UTF8.GetBytes(saved)); }
            catch { /* запис від іншої збірки — лишаємося на шаблоні */ }
        }
        if (Presets.Preset(OutputKind.Screen) is { } mine) TemplateName = mine.Name;
        ApplyBackgrounds();
    }

    static string? Remembered(string key) =>
        Defaults.String(key) is { Length: > 0 } path ? DataPaths.Existing(path) : null;

    static string? FromConfig(IniSettings? config, string key)
    {
        if (config?.String(key, "settings") is not { Length: > 0 } relative) return null;
        var path = Path.Combine(DataHome.Folder, relative.Replace('\\', Path.DirectorySeparatorChar));
        return File.Exists(path) ? path : null;
    }

    /// Фони лежать поруч із модулями, у теці BackGrounds.
    void LoadBackgrounds()
    {
        var folder = Path.Combine(DataHome.Folder, "BackGrounds");
        string[] allowed = { ".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".heic" };
        try
        {
            BackgroundImages = Directory.Exists(folder)
                ? Directory.GetFiles(folder).Where(f => allowed.Contains(Path.GetExtension(f).ToLowerInvariant()))
                    .OrderBy(f => Path.GetFileName(f), Comparer<string>.Create(SwiftText.LocalizedStandardCompare)).ToList()
                : new List<string>();
        }
        catch { BackgroundImages = Array.Empty<string>(); }
    }

    /// Вибір шаблону слайда — разом із ним міняються шрифти, кольори й фон.
    public void ApplyTemplate(string name, bool remember = true)
    {
        if (Schemes?.SlideStyleNamed(name, Style) is not { } style) return;
        TemplateName = name;
        _style = style;
        // Свій фон людина вибирала не для одного шаблону: зміна шаблону його не скасовує.
        ApplyBackgrounds();
        if (remember) RememberLook();
    }

    /// Застосувати свій шаблон із Конструктора — або зняти його (повернутися до авторського).
    public void ApplyPreset(SlidePreset? preset, bool forSongs = false)
    {
        var kinds = new[] { OutputKind.Screen, OutputKind.Preview, OutputKind.Ndi };
        foreach (var kind in kinds)
        {
            if (preset != null) Presets.Assign(preset, kind, forSongs);
            else Presets.Unassign(kind, forSongs);
        }
        if (preset != null && !forSongs) TemplateName = preset.Name;
        RememberLook();
        RefreshSlide();
        LiveChanged?.Invoke();
        Signals.Shared.Send(Signals.Kind.Slide);
    }

    /// Перечитати свої шаблони з диска: Конструктор пише їх файлами.
    public void ReloadPresets()
    {
        Presets.Reload();
        RefreshSlide();
        LiveChanged?.Invoke();
    }

    /// Шаблон, що правиться в Конструкторі, — на зал одразу.
    public void PreviewPreset(SlidePreset? preset)
    {
        LivePreset = preset;
        _presetImages.Clear();
        RefreshSlide();
        LiveChanged?.Invoke();
    }

    /// Де шукати картинку об'єкта свого шаблону: повний шлях — як є (або в
    /// поточних теках даних); одне ім'я — у теках авторських шаблонів.
    public string? PresetImagePath(string? name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        var cleaned = name.Replace('\\', '/');
        if (DataPaths.Existing(cleaned) is { } found) return found;
        var leaf = cleaned.Split('/').Last();
        if (_presetImages.TryGetValue(leaf, out var ready)) return ready;
        string? hit = null;
        foreach (var template in Schemes?.Templates ?? Array.Empty<SchemeLibrary.Template>())
        {
            var path = Path.Combine(template.FolderUrl, leaf);
            if (File.Exists(path)) { hit = path; break; }
        }
        _presetImages[leaf] = hit;
        return hit;
    }

    // --- Фони ---------------------------------------------------------------

    /// Загальний фон кладеться поверх шаблону: в автора це окремий перемикач.
    public void SetCommonBackground(string? path) { CommonBackgroundPath = path; ApplyBackgrounds(); RememberLook(); }
    public void ToggleCommonBackground() { ShowsCommonBackground = !ShowsCommonBackground; ApplyBackgrounds(); RememberLook(); }

    /// Свій фон слайда (меню «Фон Слайда», Ctrl+Alt+B); null — фон шаблону.
    public void SetBackground(string? path)
    {
        SlideBackgroundPath = path;
        _hiddenBackgroundPath = null;
        ApplyBackgrounds();
        RememberLook();
    }

    /// F9 — тимчасово прибрати картинку, не втрачаючи вибору.
    public void ToggleBackground()
    {
        var style = Style;
        if (_hiddenBackgroundPath is { } hidden) { style.BackgroundImagePath = hidden; _hiddenBackgroundPath = null; }
        else if (style.BackgroundImagePath is { } current) { _hiddenBackgroundPath = current; style.BackgroundImagePath = null; }
        else return;
        _style = style;
        RefreshSlide();
        LiveChanged?.Invoke();
    }

    /// Фон, що зараз має бути в залі: поки тексту немає — загальний; показали
    /// текст — під ним фон слайда. Зал ніколи не бачить порожнього екрана.
    public string? BackgroundOverride =>
        !IsLive || IsBlackout || IsTextHidden
            ? (ShowsCommonBackground ? CommonBackgroundPath : SlideBackgroundPath)
            : SlideBackgroundPath ?? (ShowsCommonBackground ? CommonBackgroundPath : null);

    /// Фон для передпоказу — той, що ляже під текст за «Показати».
    public string? PreviewBackgroundOverride =>
        SlideBackgroundPath ?? (ShowsCommonBackground ? CommonBackgroundPath : null);

    void ApplyBackgrounds()
    {
        var style = Style;
        if (ShowsCommonBackground && CommonBackgroundPath is { } common) style.BackgroundImagePath = common;
        else if (SlideBackgroundPath is { } own) style.BackgroundImagePath = own;
        else if (CurrentTemplate?.BackgroundUrl is { } template) style.BackgroundImagePath = template;
        _style = style;
        RefreshSlide();
        LiveChanged?.Invoke();
        // Нижній ряд перечитує мініатюри саме за цим приводом.
        Signals.Shared.Send(Signals.Kind.Slide);
    }

    /// Запам'ятати вигляд: шаблон, правлений стиль, фони.
    void RememberLook()
    {
        Defaults.Set("lastTemplate", TemplateName);
        try { Defaults.Set("slideStyle", SwiftJson.Encode(Style)); } catch { }
        Defaults.Set("commonBackground", CommonBackgroundPath);
        Defaults.Set("slideBackground", SlideBackgroundPath);
        Defaults.Set("showsCommonBackground", ShowsCommonBackground);
    }

    /// Рядки для об'єктів свого шаблону: вірш, другий переклад, адреса, назви перекладів.
    public ConstructorSample Texts(Slide shown, bool live = false) => new()
    {
        SongTitle = live ? _liveSongTitle : _shownSong?.Song.Title ?? "",
        MainText = shown.MainText,
        SecondaryText = shown.SecondaryTexts.FirstOrDefault() ?? "",
        Reference = shown.Reference,
        PrimaryReference = shown.Reference,
        SecondaryReference = shown.SecondaryTexts.Count == 0 ? "" : shown.Reference,
        ModuleNameFirst = PrimaryModule?.DisplayName ?? "",
        ModuleShortNameFirst = PrimaryModule is { } first ? TabTitle(first) : "",
        ModuleNameSecond = SecondModule?.DisplayName ?? "",
        ModuleShortNameSecond = SecondModule is { } second ? TabTitle(second) : "",
    };

    TextModule? SecondModule => SecondaryModuleIDs.Count > 0 ? Module(SecondaryModuleIDs[0]) : null;
}
