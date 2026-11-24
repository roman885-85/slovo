// =============================================================================
//  SlideConstructorModel.cs — модель «Конструктора слайда» (як SlideConstructorModel на Mac)
// =============================================================================
//  Шаблон (свій, з теки Presets) і вибраний об'єкт; сцена 1 (один переклад) і
//  сцена 2 (два переклади): у об'єкта можуть бути свої значення для другої
//  сцени («Дозволити сцену 2»), видимість — окремо для кожної. Список об'єктів
//  показується зверху вниз (верхній шар — перший). Авторські .sch беруться лише
//  за основу — зберігається своїм файлом.
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed class SlideConstructorModel
{
    SlidePreset _preset;
    public SlidePreset Preset { get => _preset; private set => _preset = value; }
    public Guid? Selection;
    public SlideScheme.Variant Scene = SlideScheme.Variant.Single;
    public bool IsDirty { get; private set; }
    public double TestDelay;
    public int AnimationRun { get; private set; }
    public event Action? Changed;

    public readonly PresetLibrary Library;
    public SchemeLibrary? Schemes { get; private set; }
    public SlideStyle BaseStyle { get; private set; } = new();
    /// Тека авторського шаблону, з якого зроблено свій: у ній картинки об'єктів і мініатюри сцен.
    public string? SourceFolder { get; private set; }
    readonly Dictionary<Guid, string> _sourceFolders = new();
    /// Об'єкти, яким людина ввімкнула «Дозволити сцену 2», хоч значення ще однакові.
    HashSet<Guid> _forcedIndependent = new();
    bool _attached;

    public SlideConstructorModel(PresetLibrary library)
    {
        Library = library;
        _preset = SlidePreset.Standard(Captions.T("Новый шаблон"), new SlideStyle());
    }

    public void Touch() { IsDirty = true; Changed?.Invoke(); }
    void Notify() => Changed?.Invoke();

    public void Attach(SchemeLibrary? schemes, SlideStyle baseStyle)
    {
        if (_attached) return;
        _attached = true;
        Schemes = schemes;
        BaseStyle = baseStyle;
        // Порожня тека означала б порожній список шаблонів — заповнюємо стартовим набором.
        Library.SeedIfEmpty(baseStyle);
        if (Library.PresetsFor(false).FirstOrDefault() is { } first) Load(first);
    }

    public void OpenScope(bool forSongs, SlidePreset? assigned)
    {
        if (assigned != null && assigned.ForSongs == forSongs && Library.Presets.Any(p => p.Id == assigned.Id)) Load(assigned);
        else if (Library.PresetsFor(forSongs).FirstOrDefault() is { } first) Load(first);
        else
        {
            // Шаблон, який редактор створив сам, бо список порожній, — ще не правка.
            MakeNew(Captions.T(forSongs ? "Песня" : "Новый шаблон"), forSongs);
            IsDirty = false;
            Notify();
        }
    }

    // --- Вибраний об'єкт -------------------------------------------------------------------

    public int? SelectedIndex => Selection is { } id && _preset.Objects.FindIndex(o => o.Id == id) is var i and >= 0 ? i : null;
    public SlideObject? SelectedObject => SelectedIndex is { } i ? _preset.Objects[i] : null;
    public ObjectVariant? SelectedValues => SelectedObject is { } o ? Values(o, Scene) : null;

    public static ObjectVariant Values(SlideObject obj, SlideScheme.Variant scene) => obj.Variant(scene == SlideScheme.Variant.Dual);

    public void Update(SlideObject obj)
    {
        var index = _preset.Objects.FindIndex(o => o.Id == obj.Id);
        if (index < 0) return;
        _preset.Objects[index] = obj;
        Touch();
    }

    /// Змінити вибраний об'єкт цілком (ім'я, текст, шрифт…).
    public void Edit(Func<SlideObject, SlideObject> change)
    {
        if (SelectedObject is { } obj) Update(change(obj));
    }

    /// Змінити значення сцени (рамка, прозорість, вирівнювання, тінь, анімація).
    public void EditScene(Func<ObjectVariant, ObjectVariant> change)
    {
        if (SelectedObject is not { } obj) return;
        SetSelectedValues(change(Values(obj, Scene)));
    }

    public void SetSelectedValues(ObjectVariant values)
    {
        if (SelectedObject is not { } obj) return;
        obj = SceneEdits.SetValues(obj, values, Scene, HasIndependentSecondScene(obj));
        Update(obj);
    }

    public bool HasIndependentSecondScene(SlideObject obj) =>
        obj.SecondVariant != null && (_forcedIndependent.Contains(obj.Id) || SceneEdits.SecondDiffersBeyondVisibility(obj));

    public bool SecondSceneEnabled
    {
        get => SelectedObject is { } o && HasIndependentSecondScene(o);
        set
        {
            if (SelectedObject is not { } obj) return;
            obj = SceneEdits.SetSecondSceneEnabled(obj, value);
            if (value) _forcedIndependent.Add(obj.Id); else _forcedIndependent.Remove(obj.Id);
            Update(obj);
        }
    }

    // --- Видимість за сценами ----------------------------------------------------------------

    public enum Personalization { AllScenes = 0, FirstOnly = 1, SecondOnly = 2 }

    public static string PersonalizationKey(Personalization p) => $"PersonalizeText{(int)p}";
    public static string PersonalizationTitle(Personalization p) => Captions.T(p switch
    {
        Personalization.FirstOnly => "В 1 сцене",
        Personalization.SecondOnly => "Во 2 сцене",
        _ => "Во всех сценах",
    });

    public Personalization Visibility
    {
        get
        {
            if (SelectedObject is not { } obj) return Personalization.AllScenes;
            var first = obj.IsVisible;
            var second = SceneEdits.SecondSceneIsVisible(obj);
            if (first && !second) return Personalization.FirstOnly;
            if (!first && second) return Personalization.SecondOnly;
            return Personalization.AllScenes;
        }
        set
        {
            switch (value)
            {
                case Personalization.FirstOnly: SetVisibility(true, false); break;
                case Personalization.SecondOnly: SetVisibility(false, true); break;
                default: SetVisibility(true, true); break;
            }
        }
    }

    void SetVisibility(bool first, bool second)
    {
        if (SelectedObject is not { } obj) return;
        obj = SceneEdits.SetVisibility(obj, first, second);
        obj = TidySecondScene(obj);
        Update(obj);
    }

    public bool IsEnabled(SlideObject obj) => Values(obj, Scene).IsVisible;

    public void SetEnabled(bool enabled, Guid id)
    {
        var index = _preset.Objects.FindIndex(o => o.Id == id);
        if (index < 0) return;
        var obj = _preset.Objects[index];
        obj = Scene == SlideScheme.Variant.Dual
            ? SceneEdits.SetVisibility(obj, obj.IsVisible, enabled)
            : SceneEdits.SetVisibility(obj, enabled, SceneEdits.SecondSceneIsVisible(obj));
        Update(TidySecondScene(obj));
    }

    /// Двійник сцени 2, заведений лише заради видимості, прибираємо, коли видимість зрівнялась.
    SlideObject TidySecondScene(SlideObject obj)
    {
        if (_forcedIndependent.Contains(obj.Id) || obj.SecondVariant is not { } second) return obj;
        if (!SceneEdits.SecondDiffersBeyondVisibility(obj) && second.IsVisible == obj.IsVisible) obj.SecondVariant = null;
        return obj;
    }

    // --- Список об'єктів ---------------------------------------------------------------------

    public void Add(SlideObjectKind kind)
    {
        var obj = new SlideObject(kind, text: TextLayer(kind)) { Name = UniqueName(kind.ShortTitle()) };
        // Новий об'єкт — на всю ширину й по центру; прив'язка по Y — «Верх», середина — відступом.
        var height = kind == SlideObjectKind.Image ? 0.2 : 0.3;
        obj.Frame = new ObjectFrame(0, (1 - height) / 2, 0.9, height, HorizontalAnchor.Center, VerticalAnchor.Top);
        if (kind == SlideObjectKind.StaticText) obj.StaticText = "Текст";
        _preset.Objects.Add(obj);
        Selection = obj.Id;
        Touch();
    }

    public void DuplicateSelected()
    {
        if (SelectedObject is not { } obj) return;
        var copy = obj;
        copy.Id = Guid.NewGuid();
        copy.Name = UniqueName(obj.Name);
        var index = (SelectedIndex ?? _preset.Objects.Count - 1) + 1;
        _preset.Objects.Insert(Math.Min(index, _preset.Objects.Count), copy);
        Selection = copy.Id;
        Touch();
    }

    public void DeleteSelected()
    {
        if (SelectedIndex is not { } index) return;
        _preset.Objects.RemoveAt(index);
        Selection = index < _preset.Objects.Count ? _preset.Objects[index].Id : _preset.Objects.Count > 0 ? _preset.Objects[^1].Id : null;
        Touch();
    }

    public void MoveSelected(int delta)
    {
        if (SelectedIndex is not { } index) return;
        var target = index + delta;
        if (target < 0 || target >= _preset.Objects.Count) return;
        (_preset.Objects[index], _preset.Objects[target]) = (_preset.Objects[target], _preset.Objects[index]);
        Touch();
    }

    /// Список — верхній шар першим; «вище» в списку — це «далі» в шаблоні.
    public List<SlideObject> ListedObjects => Enumerable.Reverse(_preset.Objects).ToList();
    public int? ListedIndex => SelectedIndex is { } i ? _preset.Objects.Count - 1 - i : null;
    public void MoveSelectedInList(int delta) => MoveSelected(-delta);

    string UniqueName(string name)
    {
        var taken = _preset.Objects.Select(o => o.Name).ToHashSet();
        if (!taken.Contains(name)) return name;
        var number = 2;
        while (taken.Contains($"{name} {number}")) number++;
        return $"{name} {number}";
    }

    SlideStyle.TextLayer TextLayer(SlideObjectKind kind) => kind switch
    {
        SlideObjectKind.Quote => BaseStyle.Main,
        SlideObjectKind.SecondaryQuote => BaseStyle.Secondary,
        _ => BaseStyle.Reference,
    };

    // --- Шаблони -----------------------------------------------------------------------------

    public void Load(SlidePreset preset)
    {
        _preset = WithOriginalAnchors(preset.Copy());
        // Теку шаблону пам'ятаємо за преднастройкою: у ній картинки об'єктів.
        SourceFolder = _sourceFolders.TryGetValue(preset.Id, out var folder) ? folder : null;
        Selection = _preset.Objects.Count > 0 ? _preset.Objects[0].Id : null;
        _forcedIndependent = new();
        IsDirty = false;
        Notify();
    }

    public void MakeNew(string name, bool forSongs = false)
    {
        var fresh = WithOriginalAnchors(forSongs ? SlidePreset.Song(name, BaseStyle) : SlidePreset.Standard(name, BaseStyle));
        var back = fresh.Back;
        back.ImagePath = null;
        fresh.Back = back;
        _preset = fresh;
        SourceFolder = null;
        Selection = fresh.Objects.Count > 0 ? fresh.Objects[0].Id : null;
        _forcedIndependent = new();
        Touch();
    }

    public void ImportScheme(SchemeLibrary.Template template)
    {
        var height = Schemes?.DesignHeight ?? SchemeLibrary.DefaultDesignHeight;
        _preset = new SlidePreset(template, BaseStyle, height);
        SourceFolder = template.FolderUrl;
        _sourceFolders[_preset.Id] = template.FolderUrl;
        Selection = _preset.Objects.Count > 0 ? _preset.Objects[0].Id : null;
        _forcedIndependent = new();
        // Ім'я — авторське, але збереження піде у свою теку: авторських .sch не переписуємо.
        Touch();
    }

    public bool Save()
    {
        var ok = Library.Save(_preset);
        if (ok)
        {
            IsDirty = false;
            if (SourceFolder != null) _sourceFolders[_preset.Id] = SourceFolder;
        }
        Notify();
        return ok;
    }

    public bool SaveAs(string name)
    {
        var copy = _preset.Copy();
        copy.Id = Guid.NewGuid();   // інакше переписався б колишній файл
        copy.Name = name;
        var ok = Library.Save(copy);
        if (ok)
        {
            _preset = copy;
            if (SourceFolder != null) _sourceFolders[copy.Id] = SourceFolder;
            IsDirty = false;
        }
        Notify();
        return ok;
    }

    public bool NameIsTaken(string name) => Library.Presets.Any(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase));

    public void DeleteCurrent()
    {
        var songs = _preset.ForSongs;
        Library.Delete(_preset);
        // Наступний — з того самого редактора.
        if (Library.PresetsFor(songs).FirstOrDefault() is { } next) Load(next);
        else MakeNew(Captions.T(songs ? "Песня" : "Новый шаблон"), songs);
        Notify();
    }

    /// Вертикальна прив'язка в шаблоні автора — один біт: «середину» переводимо у «верх» з відступом.
    static SlidePreset WithOriginalAnchors(SlidePreset preset)
    {
        for (var i = 0; i < preset.Objects.Count; i++)
        {
            var obj = preset.Objects[i];
            obj.Frame = TopAnchored(obj.Frame);
            if (obj.SecondVariant is { } second)
            {
                second.Frame = TopAnchored(second.Frame);
                obj.SecondVariant = second;
            }
            preset.Objects[i] = obj;
        }
        return preset;
    }

    static ObjectFrame TopAnchored(ObjectFrame frame)
    {
        if (frame.AnchorY != VerticalAnchor.Middle) return frame;
        var fixedFrame = frame;
        fixedFrame.AnchorY = VerticalAnchor.Top;
        fixedFrame.Y = (1 - frame.Height) / 2 + frame.Y;
        return fixedFrame;
    }

    public void RunAnimationTest() { AnimationRun++; Notify(); }

    // --- Файли -------------------------------------------------------------------------------

    public string? ImagePath(string? name)
    {
        if (string.IsNullOrEmpty(name)) return null;
        var cleaned = name.Replace('\\', '/');
        if (File.Exists(cleaned)) return cleaned;
        if (AppState.Shared.PresetImagePath(name) is { } known) return known;
        if (SourceFolder is not { } folder) return null;
        var leaf = cleaned.Split('/').Last();
        var path = Path.Combine(folder, leaf);
        return File.Exists(path) ? path : null;
    }

    /// Теки фонів: тека шаблону, потім шляхи фонів із «Параметрів» (з підтеками, якщо так задано).
    public List<string> BackgroundFolders
    {
        get
        {
            var folders = new List<string>();
            if (SourceFolder != null) folders.Add(SourceFolder);
            folders.AddRange(SettingsPictureFolders);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            return folders.Where(f => Directory.Exists(f) && seen.Add(Path.GetFullPath(f))).ToList();
        }
    }

    List<string>? _pictureFolders;
    List<string> SettingsPictureFolders
    {
        get
        {
            if (_pictureFolders != null) return _pictureFolders;
            var store = SettingsStore.Shared;
            var folders = new List<string>();
            foreach (var entry in store.Settings.PicturePaths)
            {
                var cleaned = entry.Path.Replace('\\', Path.DirectorySeparatorChar);
                var folder = Path.IsPathRooted(cleaned) ? cleaned : Path.Combine(DataHome.Folder, cleaned);
                folders.Add(folder);
                if (entry.ScansSubfolders && Directory.Exists(folder))
                    try { folders.AddRange(Directory.EnumerateDirectories(folder, "*", SearchOption.AllDirectories).Take(200)); } catch { /* немає доступу */ }
            }
            // Порожній список шляхів не лишає людину без фонів.
            if (folders.Count == 0 && Schemes?.Root is { } root && Path.GetDirectoryName(root) is { } parent)
                folders.Add(Path.Combine(parent, "BackGrounds"));
            return _pictureFolders = folders;
        }
    }

    readonly Dictionary<string, List<string>> _listings = new();

    public List<string> Images(string folder)
    {
        if (_listings.TryGetValue(folder, out var cached)) return cached;
        string[] allowed = { ".jpg", ".jpeg", ".png", ".bmp", ".tif", ".tiff", ".gif" };
        List<string> files;
        try { files = Directory.EnumerateFiles(folder).Where(f => allowed.Contains(Path.GetExtension(f).ToLowerInvariant())).ToList(); }
        catch { files = new(); }
        files.Sort((a, b) => SwiftText.LocalizedStandardCompare(Path.GetFileName(a), Path.GetFileName(b)));
        return _listings[folder] = files;
    }

    public List<string> BackgroundFiles => BackgroundFolders.SelectMany(Images).ToList();
}

/// Сцени об'єкта (розширення SlideObject на Mac): значення другої сцени, видимість.
public static class SceneEdits
{
    public static bool SecondSceneIsVisible(SlideObject obj) => obj.SecondVariant?.IsVisible ?? obj.IsVisible;

    /// Друга сцена відрізняється від першої чимось, крім видимості.
    public static bool SecondDiffersBeyondVisibility(SlideObject obj)
    {
        if (obj.SecondVariant is not { } probe) return false;
        probe.IsVisible = obj.IsVisible;
        return probe != obj.Variant(false);
    }

    static ObjectVariant Copy(SlideObject obj, bool isVisible) =>
        new(obj.Frame, obj.Opacity, isVisible, obj.Alignment, obj.VerticalAlignment, obj.Shadow, obj.Animation);

    public static SlideObject SetValues(SlideObject obj, ObjectVariant values, SlideScheme.Variant scene, bool independent)
    {
        if (scene == SlideScheme.Variant.Dual && independent)
        {
            var updated = values;
            // Видимість сцени 2 править «Видимість», а не ці поля.
            updated.IsVisible = obj.SecondVariant?.IsVisible ?? values.IsVisible;
            obj.SecondVariant = updated;
            return obj;
        }
        // Поки незалежної сцени 2 немає, правка йде в спільний набір — і друга сцена міняється з першою.
        obj.Frame = values.Frame;
        obj.Opacity = values.Opacity;
        obj.Alignment = values.Alignment;
        obj.VerticalAlignment = values.VerticalAlignment;
        obj.Shadow = values.Shadow;
        obj.Animation = values.Animation;
        if (scene == SlideScheme.Variant.Single) obj.IsVisible = values.IsVisible;
        // Двійник, заведений заради іншої видимості, тримаємо в згоді з першим набором.
        if (obj.SecondVariant is { } second) obj.SecondVariant = Copy(obj, second.IsVisible);
        return obj;
    }

    public static SlideObject SetSecondSceneEnabled(SlideObject obj, bool enabled)
    {
        var secondVisible = SecondSceneIsVisible(obj);
        // Окремий набір починається з копії першого; копію лишаємо й тоді, коли видимість сцен різна.
        obj.SecondVariant = enabled || secondVisible != obj.IsVisible ? Copy(obj, secondVisible) : null;
        return obj;
    }

    public static SlideObject SetVisibility(SlideObject obj, bool first, bool second)
    {
        obj.IsVisible = first;
        if (obj.SecondVariant is { } existing)
        {
            existing.IsVisible = second;
            obj.SecondVariant = existing;
        }
        else if (second != first) obj.SecondVariant = Copy(obj, second);
        return obj;
    }
}
