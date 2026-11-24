// =============================================================================
//  PresetLibrary.cs — сховище преднастройок і прив'язка до виводів
//  (з Slides/PresetLibrary.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Сховище преднастройок і прив'язка їх до виводів.
///
/// Преднастройки лежать звичайними JSON-файлами в теці даних: їх можна
/// скопіювати на інший комп'ютер або прислати листом. Формат навмисно
/// читабельний — лагодиться текстовим редактором перед служінням.
public sealed class PresetLibrary
{
    private List<SlidePreset> presets = new();
    /// Яка преднастройка призначена кожному виводу.
    private Dictionary<OutputKind, Guid> assignments = new();
    /// Те саме для пісень: у них свій шаблон, коли його призначено.
    private Dictionary<OutputKind, Guid> songAssignments = new();

    public IReadOnlyList<SlidePreset> Presets => presets;
    public IReadOnlyDictionary<OutputKind, Guid> Assignments => assignments;
    public IReadOnlyDictionary<OutputKind, Guid> SongAssignments => songAssignments;

    private readonly string folder;
    private readonly string assignmentsFile;
    private readonly string songAssignmentsFile;

    public PresetLibrary(string folder)
    {
        this.folder = folder;
        assignmentsFile = Path.Combine(folder, "assignments.json");
        songAssignmentsFile = Path.Combine(folder, "assignments-songs.json");
        try { Directory.CreateDirectory(folder); } catch { }
        Reload();
    }

    /// Тека за умовчанням — поруч з рештою даних програми.
    public static string DefaultFolder => Path.Combine(DataHome.Folder, "Presets");

    // ── Читання й запис ─────────────────────────────────────────────────────

    public void Reload()
    {
        presets = SwiftPath.Contents(folder, skipsHidden: true)
            .Where(file => SwiftPath.Extension(file).ToLowerInvariant() == "json"
                           && !SwiftPath.LastComponent(file).StartsWith("assignments", StringComparison.Ordinal))
            .Select(file =>
            {
                // Битий файл не має ронити запуск: пропускаємо і працюємо далі.
                try { return SlidePreset.Decode(File.ReadAllBytes(file)); }
                catch { return null; }
            })
            .Where(preset => preset != null)
            .Select(preset => preset!)
            .OrderBy(preset => preset.Name, SwiftText.StandardOrder)
            .ToList();

        assignments = Read(assignmentsFile);
        songAssignments = Read(songAssignmentsFile);
    }

    private static Dictionary<OutputKind, Guid> Read(string file)
    {
        var result = new Dictionary<OutputKind, Guid>();
        try
        {
            if (SwiftJson.TryDecode<Dictionary<string, Guid>>(File.ReadAllBytes(file)) is not { } raw) return result;
            foreach (var (key, value) in raw)
                if (OutputKinds.FromRaw(key) is { } kind) result[kind] = value;
        }
        catch { }
        return result;
    }

    public bool Save(SlidePreset preset)
    {
        byte[] data;
        try { data = preset.Encode(); }
        catch { return false; }

        try { SwiftPath.WriteAtomically(Path.Combine(folder, FileName(preset)), data); }
        catch { return false; }

        var index = presets.FindIndex(p => p.Id == preset.Id);
        if (index >= 0)
        {
            presets[index] = preset;
        }
        else
        {
            presets.Add(preset);
            presets = presets.OrderBy(p => p.Name, SwiftText.StandardOrder).ToList();
        }
        return true;
    }

    public bool Delete(SlidePreset preset)
    {
        try { File.Delete(Path.Combine(folder, FileName(preset))); } catch { }
        presets.RemoveAll(p => p.Id == preset.Id);
        foreach (var kind in assignments.Where(pair => pair.Value == preset.Id).Select(pair => pair.Key).ToList())
            assignments.Remove(kind);
        foreach (var kind in songAssignments.Where(pair => pair.Value == preset.Id).Select(pair => pair.Key).ToList())
            songAssignments.Remove(kind);
        PersistAssignments();
        return true;
    }

    /// Ім'я файла — з імені преднастройки, але ідентифікатор усе одно всередині:
    /// перейменування не створює дубліката, а перезапис не плутає дві різні
    /// преднастройки зі схожими назвами.
    private static string FileName(SlidePreset preset)
    {
        var safe = new StringBuilder();
        foreach (var c in preset.Name) safe.Append("/\\:*?\"<>|".Contains(c) ? '-' : c);
        var cleaned = safe.ToString().TrimWhitespaces();
        var stem = cleaned.Length == 0 ? "preset" : cleaned;
        return $"{stem}-{preset.Id.ToString("D").ToUpperInvariant()[..8]}.json";
    }

    /// Шаблони одного редактора: пісень або Біблії.
    public List<SlidePreset> PresetsFor(bool forSongs) => presets.Where(p => p.ForSongs == forSongs).ToList();

    // ── Прив'язка до виводів ────────────────────────────────────────────────

    /// Шаблон виводу; `songs` — той, що призначено пісням (або `null`).
    public SlidePreset? Preset(OutputKind kind, bool songs = false)
    {
        if (!(songs ? songAssignments : assignments).TryGetValue(kind, out var id)) return null;
        return presets.FirstOrDefault(p => p.Id == id);
    }

    public void Assign(SlidePreset preset, OutputKind kind, bool songs = false)
    {
        if (songs) songAssignments[kind] = preset.Id;
        else assignments[kind] = preset.Id;
        PersistAssignments();
    }

    /// Зняти свій шаблон з виводу: він повернеться до авторського (а пісні —
    /// до спільного шаблону).
    public void Unassign(OutputKind kind, bool songs = false)
    {
        var table = songs ? songAssignments : assignments;
        if (!table.Remove(kind)) return;
        PersistAssignments();
    }

    private void PersistAssignments()
    {
        foreach (var (table, file) in new[] { (assignments, assignmentsFile), (songAssignments, songAssignmentsFile) })
        {
            var raw = table.ToDictionary(pair => pair.Key.RawValue(), pair => pair.Value);
            try { SwiftPath.WriteAtomically(file, SwiftJson.EncodeBytes(raw, pretty: true, sortedKeys: true)); }
            catch { }
        }
    }

    // ── Перший запуск ───────────────────────────────────────────────────────

    /// Створює стартовий набір, якщо тека порожня, і роздає його виводам.
    /// Відштовхуємося від стилю, уже прочитаного з налаштувань.
    public void SeedIfEmpty(SlideStyle style)
    {
        if (presets.Count > 0) return;

        // Імена — мовою інтерфейсу при першому запуску; далі це дані власника.
        var screen = SlidePreset.Standard(OurWords.T("Проектор"), style);
        var stage = SlidePreset.Stage(OurWords.T("Экран служителя"), style);
        var web = SlidePreset.Standard(OurWords.T("Web слайды"), style);

        foreach (var preset in new[] { screen, stage, web }) Save(preset);

        assignments[OutputKind.Screen] = screen.Id;
        assignments[OutputKind.Preview] = screen.Id;
        // Трансляції — той самий шаблон, що й залу: підкладку з нього знімає
        // правило виводу (`NdiTransparentBackGr`), а не окремий шаблон.
        assignments[OutputKind.Ndi] = screen.Id;
        assignments[OutputKind.Stage] = stage.Id;
        assignments[OutputKind.Web] = web.Id;
        PersistAssignments();
    }
}
