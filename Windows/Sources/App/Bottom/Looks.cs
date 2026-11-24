// =============================================================================
//  Looks.cs — мініатюри «Шаблон», «Фон Слайда», «Фон Загальний» і їхні меню
// =============================================================================
//  Як refresh / chooseTemplate / chooseSlideBackground / chooseCommonBackground
//  у NativeControlPanel. Шаблони — меню з мініатюрами (піднімається миттєво,
//  між двома віршами); фон слайда — картинки з BackGrounds, свій файл і
//  «прибрати»; загальний фон — вибір файла, а правою кнопкою — увімкнути,
//  вимкнути чи прибрати.
// =============================================================================

using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

/// Зменшені картинки для мініатюр і меню (як ImageCache.thumbnail на Mac).
public static class Thumbnails
{
    static readonly Dictionary<(string, int), Bitmap?> Cache = new();

    public static Bitmap? Get(string? path, int height)
    {
        if (string.IsNullOrEmpty(path)) return null;
        if (Cache.TryGetValue((path, height), out var ready)) return ready;
        Bitmap? made = null;
        try
        {
            if (File.Exists(path))
            {
                using var stream = File.OpenRead(path);
                // Кратно більше за висоту показу: на Retina/200 % мініатюра не розмита.
                made = Bitmap.DecodeToHeight(stream, height * 2, BitmapInterpolationMode.HighQuality);
            }
        }
        catch { made = null; }
        Cache[(path, height)] = made;
        return made;
    }
}

public sealed class LookChooser
{
    readonly AppState _state;
    readonly ControlPanel _panel;

    public LookChooser(AppState state, ControlPanel panel)
    {
        _state = state;
        _panel = panel;
        panel.Template.OnClick = ChooseTemplate;
        // Кнопка називається «Фон Слайда» — вона й вибирає фон.
        panel.SlideBackground.OnClick = ChooseSlideBackground;
        panel.CommonBackground.OnClick = () => _ = ChooseCommonBackground();
        panel.CommonBackground.OnMenu = CommonBackgroundMenu;
        state.ChooseCommonBackgroundRequested = () => _ = ChooseCommonBackground();
        state.ChooseSlideBackgroundRequested = ChooseSlideBackground;
        Signals.Shared.Subscribe(new[] { Signals.Kind.Slide, Signals.Kind.Language, Signals.Kind.Mode, Signals.Kind.Library }, _ => Refresh());
        Refresh();
    }

    void Refresh()
    {
        var current = _state.CurrentTemplate;
        // У свого шаблону з Конструктора немає готової мініатюри — показуємо його фон.
        var mine = _state.SlidePreset;
        var backdrop = mine != null ? _state.PresetImagePath(mine.Back.ImagePath) : null;
        var templatePicture = mine == null
            ? current?.ThumbnailUrl(_state.Slide.SecondaryTexts.Count == 0 ? SlideScheme.Variant.Single : SlideScheme.Variant.Dual)
            : backdrop;
        _panel.Template.Apply(Captions.Caption("Label3D10", "Шаблон:"), Thumbnails.Get(templatePicture, 80),
            _state.TemplateName.Length == 0 ? Captions.T("не выбран") : _state.TemplateName,
            Captions.MainHint("PngSBSelSlideTemplate", "Шаблон Слайда"), false);
        // Мініатюра показує те, що справді лежить під текстом: свій вибір, інакше фон шаблону.
        var slidePicture = _state.SlideBackgroundPath ?? (mine == null ? current?.BackgroundUrl : backdrop);
        _panel.SlideBackground.Apply(Captions.Caption("Label3D22", "Фон Слайда:"), Thumbnails.Get(slidePicture, 80),
            slidePicture != null ? Path.GetFileName(slidePicture) : Captions.T("из шаблона"),
            Captions.MainHint("PngSBSelSlideBg", "Фон Слайда"), false);
        _panel.CommonBackground.Apply(Captions.Caption("Label3D23", "Фон Общий:"), Thumbnails.Get(_state.CommonBackgroundPath, 80),
            _state.ShowsCommonBackground ? Captions.T("включён") : Captions.T("выключен"),
            Captions.MainHint("PngSBSelCommonBg", "Общий фон"), !_state.ShowsCommonBackground);
    }

    /// Шаблони — меню з мініатюрами. На вкладці пісень — шаблон пісень, і
    /// список лише свого редактора: шаблони Біблії піснями не пропонуються.
    void ChooseTemplate()
    {
        var templates = _state.Schemes?.Templates ?? Array.Empty<SchemeLibrary.Template>();
        _state.ReloadPresets();
        var songs = _state.Mode == WorkMode.Songs;
        var mine = _state.Presets.PresetsFor(songs);
        if (templates.Count == 0 && mine.Count == 0) return;
        var entries = new List<MenuEntry>
        {
            new(songs ? Captions.T("Шаблон для песен:") : Captions.Caption("Label3D10", "Шаблон:"), IsHeader: true),
        };
        if (mine.Count > 0)
        {
            entries.Add(new MenuEntry(Captions.T("Свои шаблоны"), IsHeader: true, StartsGroup: true));
            foreach (var preset in mine)
                entries.Add(new MenuEntry(preset.Name, () => _state.ApplyPreset(preset, songs), preset.Id == _state.SlidePreset?.Id));
            if (songs ? _state.Presets.Preset(OutputKind.Screen, true) != null : _state.SlidePreset != null)
                entries.Add(new MenuEntry(songs ? Captions.T("Как для Библии") : Captions.T("Вернуться к авторскому"),
                                          () => _state.ApplyPreset(null, songs)));
        }
        var first = true;
        foreach (var scheme in templates)
        {
            var name = scheme.Name;
            entries.Add(new MenuEntry(name, () => { _state.ApplyPreset(null, songs); _state.ApplyTemplate(name); },
                                      _state.SlidePreset == null && name == _state.TemplateName, StartsGroup: first,
                                      Picture: scheme.ThumbnailUrl(SlideScheme.Variant.Single)));
            first = false;
        }
        Open(MenuStrip.Build(entries), _panel.Template);
    }

    /// Фон слайда: картинки з BackGrounds, свій файл і «прибрати».
    public void ChooseSlideBackground()
    {
        var entries = new List<MenuEntry>
        {
            new(Captions.T("Убрать картинку"), () => _state.SetBackground(null), _state.SlideBackgroundPath == null),
        };
        var first = true;
        foreach (var path in _state.BackgroundImages)
        {
            var chosen = path;
            entries.Add(new MenuEntry(Path.GetFileNameWithoutExtension(path), () => _state.SetBackground(chosen),
                                      _state.SlideBackgroundPath == path, StartsGroup: first, Picture: path));
            first = false;
        }
        entries.Add(new MenuEntry(Captions.T("Выбрать файл…"), () => _ = ChooseBackgroundFile(), StartsGroup: true));
        Open(MenuStrip.Build(entries), _panel.SlideBackground);
    }

    ContextMenu CommonBackgroundMenu() => MenuStrip.Build(new List<MenuEntry>
    {
        new(_state.ShowsCommonBackground ? Captions.T("Выключить общий фон") : Captions.T("Включить общий фон"), _state.ToggleCommonBackground),
        new(Captions.T("Убрать картинку"), () => _state.SetCommonBackground(null)),
    });

    static void Open(ContextMenu menu, Control anchor)
    {
        menu.PlacementTarget = anchor;
        menu.Placement = PlacementMode.BottomEdgeAlignedLeft;
        menu.Open(anchor);
    }

    async Task<string?> PickImage(string title)
    {
        if (TopLevel.GetTopLevel(_panel)?.StorageProvider is not { } storage) return null;
        var start = _state.BackgroundImages.FirstOrDefault() is { } any ? Path.GetDirectoryName(any) : null;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = title,
            AllowMultiple = false,
            FileTypeFilter = new[] { FilePickerFileTypes.ImageAll },
            SuggestedStartLocation = start != null ? await storage.TryGetFolderFromPathAsync(start) : null,
        });
        return files.Count > 0 ? files[0].TryGetLocalPath() : null;
    }

    async Task ChooseBackgroundFile()
    {
        if (await PickImage(Captions.T("Изображение общего фона")) is { } path) _state.SetBackground(path);
    }

    /// Вибір спільного фону (і клавіша «Вибрати Спільний фон», Ctrl+B).
    async Task ChooseCommonBackground()
    {
        if (await PickImage(Captions.T("Общий фон для всех слайдов")) is { } path) _state.SetCommonBackground(path);
    }
}
