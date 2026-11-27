// =============================================================================
//  AppState.Plan.cs — «План:» служіння (10), як частина DeskModel на Mac
// =============================================================================
//  Пункти додають з меню віршів, пісень, «Тексту» й результатів пошуку. Кнопки
//  над планом: очистити, відкрити, зберегти, видалити рядок, вище, нижче.
//  Подвійне клацання чи Enter — подати пункт у зал (вірш, пісня, текст, файл).
//  Останній план живе в PlanDef.ini (той самий вигляд, що в оригіналу) і
//  пишеться із запізненням 1 с; план проповіді з планшета його не підміняє.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed partial class AppState
{
    ServicePlan _plan = new();
    public ServicePlan Plan => _plan;
    readonly HashSet<Guid> _planSelection = new();
    public IReadOnlySet<Guid> PlanSelection => _planSelection;
    /// План служіння, відкладений на час проповіді: поки він тут, Plan — план
    /// проповідника, і як «останній план» на диск він не пишеться.
    ServicePlan? _servicePlanAside;
    public bool IsSermon => _servicePlanAside != null;
    /// Повідомлення, що план не прочитався чи прочитався не весь (вікно з однією кнопкою).
    public event Action<string>? PlanWarning;
    /// Фокус на списку плану (F2): поки він там, стрілки гортають план, а не вірші.
    public bool IsPlanFocused { get; set; }
    DispatcherTimer? _planAutosave;
    bool _planLoaded;

    void PlanChanged() => Signals.Shared.Send(Signals.Kind.Plan);

    public void SetPlanSelection(IEnumerable<Guid> ids)
    {
        _planSelection.Clear();
        foreach (var id in ids) _planSelection.Add(id);
        PlanChanged();
    }

    public void AddToPlan(IEnumerable<PlanItem> items)
    {
        var list = items.ToList();
        if (list.Count == 0) return;
        _plan.Append(list);
        SchedulePlanAutosave();
        PlanChanged();
    }

    /// План проповіді з планшета: план служіння відкладається цілим, а план
    /// проповіді стає першим на час проповіді (не дописується й не заміняє).
    public void BeginSermon(IEnumerable<PlanItem> items, string title)
    {
        _planAutosave?.Stop();
        _servicePlanAside ??= _plan;
        _plan = new ServicePlan(title, items);
        _planSelection.Clear();
        PlanChanged();
    }

    /// Проповідь скінчилась — план служіння знову на місці.
    public void EndSermon()
    {
        if (_servicePlanAside is not { } aside) return;
        _servicePlanAside = null;
        _planSelection.Clear();
        _plan = aside;
        PlanChanged();
    }

    /// Поточне місце Писання — пункт плану: рівно той уривок, що виділено у списку віршів.
    public PlanItem? PlanItemForSelection()
    {
        if (CurrentBook is not { } book || SelectedVerseNumbers.Count == 0) return null;
        // Початок цитати беремо з готового передпоказу: він про той самий уривок.
        return PlanItem.ScriptureItem(PrimaryModuleID, book, SelectedChapterNumber, SelectedVerseNumbers, Slide.MainText);
    }

    /// Частина пісні — пункт плану. Ім'я файла пісенника — за ним план знайде
    /// пісню й тоді, коли теку з модулями перенесуть.
    public PlanItem? PlanItemForSong(Song song, SongPart part) =>
        SongLibrary?.EntryFor(SongBookID) is { } entry ? PlanItem.SongPartItem(Path.GetFileName(entry.Url), song, part) : null;

    /// Уся пісня — одним пунктом, як у автора (5.3.2): частини гортаються при показі.
    public List<PlanItem> PlanItemsForSong(Song song) =>
        SongLibrary?.EntryFor(SongBookID) is { } entry ? new List<PlanItem> { PlanItem.SongItem(Path.GetFileName(entry.Url), song) } : new();

    /// Пісню чи її частину — у план (меню пісень, результати пошуку).
    public void AddSongToPlanItems(Song song, SongPart? part)
    {
        if (part is { } chosen && PlanItemForSong(song, chosen) is { } item) AddToPlan(new[] { item });
        else AddToPlan(PlanItemsForSong(song));
    }

    /// «Додати в План» (MIAddToPlan): те, що виділено зараз, — уривок чи частину пісні.
    public void AddCurrentToPlan()
    {
        // У «Тексті» той самий пункт кладе в план набране оголошення (5.2.2).
        if (Mode == WorkMode.Text) { AddToPlan(new[] { PlanItem.TextItem(TextModuleModel.Shared.Document) }); return; }
        if (Mode == WorkMode.Songs)
        {
            if (SelectedSong is not { } song) return;
            SongPart? part = SongPartIndex is { } index && song.Parts.FirstOrDefault(p => p.Index == index) is { Text: not null } found ? found : null;
            AddSongToPlanItems(song, part);
            return;
        }
        if (PlanItemForSelection() is { } item) AddToPlan(new[] { item });
    }

    public void MovePlan(IEnumerable<int> offsets, int destination)
    {
        _plan.Move(offsets, destination);
        SchedulePlanAutosave();
        PlanChanged();
    }

    /// Кнопки «вище» і «нижче» — зсув виділеного пункту на крок.
    public void MovePlanSelection(int delta)
    {
        var positions = SelectedPlanPositions;
        if (positions.Count != 1) return;
        var position = positions[0];
        var destination = delta > 0 ? position + 2 : position - 1;
        if (destination < 0 || destination > _plan.Count) return;
        _plan.Move(new[] { position }, destination);
        SchedulePlanAutosave();
        PlanChanged();
    }

    /// Кнопка «Видалити рядок» і Del: без виділення — поданий пункт (після завантаження
    /// плану виділення ще немає, а клавіша вже мусить працювати).
    public void DeletePlanSelection()
    {
        var positions = SelectedPlanPositions.Count > 0 ? SelectedPlanPositions : (_plan.CurrentIndex is { } c ? new List<int> { c } : new List<int>());
        if (positions.Count == 0) return;
        DeletePlan(positions);
    }

    public void DeletePlan(IEnumerable<int> offsets)
    {
        _plan.RemoveAt(offsets);
        _planSelection.Clear();
        SchedulePlanAutosave();
        PlanChanged();
    }

    /// Кнопка «Очистити план».
    public void ClearPlan()
    {
        _plan.RemoveAll();
        _planSelection.Clear();
        SchedulePlanAutosave();
        PlanChanged();
    }

    public List<int> SelectedPlanPositions =>
        _plan.Items.Select((item, position) => (item, position)).Where(p => _planSelection.Contains(p.item.Id)).Select(p => p.position).OrderBy(p => p).ToList();

    /// Стрілки в плані: рухаємо виділення, показ не чіпаємо.
    public void StepPlanSelection(int delta)
    {
        if (_plan.IsEmpty) return;
        var current = SelectedPlanPositions.FirstOrDefault(-1) is var first && first >= 0 ? first : _plan.CurrentIndex ?? 0;
        var next = Math.Min(Math.Max(current + delta, 0), _plan.Count - 1);
        SetPlanSelection(new[] { _plan.Items[next].Id });
    }

    /// Виділений пункт; без виділення — поданий на екран.
    public PlanItem? FocusedPlanItem => SelectedPlanPositions is { Count: > 0 } p ? _plan[p[0]] : _plan.Current;

    /// Скільки разів відкривали пункт Плану — перевіркам.
    public int PlanActivationsForCheck { get; private set; }
    /// Пункт «файл» (презентація, картинка, відео) — віддає вкладка показу; друге — чи одразу в зал.
    public Func<string, bool, bool>? OpenPlanFile;

    /// Подати пункт плану на екран: те саме, що подвійне клацання по вірші чи частині пісні.
    /// `live: false` — лише вибрати й у передпоказ (пульт: «показ … исключительно по кнопке показа»).
    public void ActivatePlanItem(PlanItem item, bool live = true)
    {
        PlanActivationsForCheck++;
        _plan.Select(item.Id);
        PlanChanged();
        switch (item.Kind)
        {
            case PlanItemKind.Scripture when item.Scripture is { } reference:
            {
                // Режим — до показу: вид запису в «Історії» обирається за ним.
                if (Mode != WorkMode.Bible) { Mode = WorkMode.Bible; Signals.Shared.Send(Signals.Kind.Mode); }
                // Вибір з плану перемикає переклад, а не відкриває уривок у чужому (3.3).
                if (reference.ModuleID.Length > 0 && !string.Equals(reference.ModuleID, PrimaryModuleID, StringComparison.OrdinalIgnoreCase)
                    && Module(reference.ModuleID) != null)
                    PrimaryModuleID = reference.ModuleID;
                var position = Books.FindIndex(b => b.Index == reference.BookIndex);
                if (position < 0) position = reference.BookIndex >= 0 && reference.BookIndex < Books.Count ? reference.BookIndex : -1;
                if (position < 0) return;
                // Порожній список віршів — «уся глава». Показ — лише коли місце справді стало.
                var wanted = reference.Verses.ToList();
                OpenScripture(position, reference.Chapter,
                              available => wanted.Count == 0 ? available : wanted.Where(available.Contains).ToList(),
                              () => { if (live) ShowCurrentSlide(); });
                break;
            }
            case PlanItemKind.Song when item.SongPart is { } reference:
            {
                if (SongLibrary?.EntryForFileName(reference.BookFileName) is not { } entry || SongLibrary.Book(entry.Id) is not { } book
                    || reference.SongIn(book) is not { } song)
                {
                    Journal.Say($"план: пісні «{reference.BookFileName}» №{reference.SongIndex + 1} немає");
                    return;
                }
                // Пісня цілком починається з першої частини — як подвійне клацання по назві (5.3.2).
                SongPart? part = reference.PartIn(book) ?? (song.Parts.Count > 0 ? song.Parts[0] : null);
                if (part is not { } shown) return;
                if (Mode != WorkMode.Songs) { Mode = WorkMode.Songs; Signals.Shared.Send(Signals.Kind.Mode); }
                SongBookID = entry.Id;
                SongIndex = song.Index;
                SongPartIndex = shown.Index;
                Signals.Shared.Send(Signals.Kind.SongSelection);
                ShowSongPart(song, shown);
                if (live) ShowCurrentSlide();
                break;
            }
            case PlanItemKind.Text when item.PlainText is { } document:
                // Пункт «Текст» везе вміст із собою — показ віддаємо модулю «Текст».
                TextModuleModel.Shared.Activate(document, this, live);
                break;
            case PlanItemKind.File when item.File is { } file:
                if (!File.Exists(file.Path)) { Journal.Say($"план: немає файла «{file.Name}»"); return; }
                if (OpenPlanFile?.Invoke(file.Path, live) != true) Journal.Say($"план: «{file.Name}» не показ і не плеєр");
                break;
        }
    }

    // --- Файли плану -------------------------------------------------------------------

    /// Свої плани — у своїй теці даних; вигляд файла той самий, що в оригіналу.
    public static string PlansFolder => ServicePlan.PlansDirectory(DataHome.SupportFolder);
    static string PlanAutosavePath => Path.Combine(DataHome.SupportFolder, ServicePlan.DefaultFileName);
    const string LastPlanKey = "plan.lastFile";

    /// Тека планів оригіналу (поруч із текою модулів) — лише на читання. Коли
    /// вона й є своєю текою, окремої «чужої» немає.
    string? OriginalPlansFolder
    {
        get
        {
            var root = Path.GetDirectoryName(ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/'));
            if (string.IsNullOrEmpty(root)) return null;
            var folder = ServicePlan.PlansDirectory(root);
            if (!Directory.Exists(folder)) return null;
            return string.Equals(Path.GetFullPath(folder), Path.GetFullPath(PlansFolder), StringComparison.OrdinalIgnoreCase) ? null : folder;
        }
    }

    /// Куди відкривати «Завантажити план»: тека оригіналу, якщо в ній є плани, інакше своя.
    public string PlanOpenFolder => OriginalPlansFolder ?? PlansFolder;

    public void LoadPlan(string path)
    {
        try
        {
            var result = ServicePlan.ReadAny(path);
            _plan = result.Plan;
            _planSelection.Clear();
            Defaults.Set(LastPlanKey, path);
            SchedulePlanAutosave();
            PlanChanged();
            if (result.Warning is { Length: > 0 } warning) PlanWarning?.Invoke(warning);
        }
        catch (Exception error) { PlanWarning?.Invoke(error.Message); }
    }

    /// Куди писати «Зберегти план» без питання: файл плану, якщо він не з теки оригіналу.
    public string? PlanSaveTarget =>
        _plan.FileUrl is { } path && (OriginalPlansFolder is not { } original || !Path.GetFullPath(path).StartsWith(Path.GetFullPath(original), StringComparison.OrdinalIgnoreCase))
            ? path : null;

    /// «План служіння.ini» — розширення й тека як в оригіналу.
    public static string PlanFileName(string title) =>
        Path.GetFileNameWithoutExtension(ServicePlan.FileName(title)) + "." + ServicePlan.JournalFileExtension;

    public void WritePlan(string path)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            // Свій JSON — лише тим файлам, що так і заведені; нове пишеться у вигляді оригіналу.
            if (Path.GetExtension(path).TrimStart('.').Equals(ServicePlan.FileExtension, StringComparison.OrdinalIgnoreCase)) _plan.Save(path);
            else _plan.SaveAsJournal(path);
            Defaults.Set(LastPlanKey, path);
            PlanChanged();
        }
        catch (Exception error) { PlanWarning?.Invoke(error.Message); }
    }

    /// «При запуску показує останній план» (5.1.10): і сам файл, і знімок
    /// незбереженої правки — план, зібраний перед служінням, не пропадає.
    public void LoadLastPlan()
    {
        if (_planLoaded) return;
        _planLoaded = true;
        try
        {
            if (File.Exists(PlanAutosavePath) && ServicePlan.ReadAny(PlanAutosavePath) is { Plan.IsEmpty: false } snapshot)
            {
                _plan = snapshot.Plan;
                // Знімок збігся з файлом — план збережено, і «Зберегти» пише туди ж.
                if (Defaults.String(LastPlanKey) is { Length: > 0 } last && File.Exists(last)
                    && ServicePlan.ReadAny(last) is var restored && restored.Plan.Items.SequenceEqual(_plan.Items))
                    _plan = restored.Plan;
                PlanChanged();
                return;
            }
            if (Defaults.String(LastPlanKey) is { Length: > 0 } path && File.Exists(path) && ServicePlan.ReadAny(path) is { Plan.IsEmpty: false } saved)
            {
                _plan = saved.Plan;
                PlanChanged();
                return;
            }
            // Свого знімка ще немає — останній план оригіналу.
            var root = Path.GetDirectoryName(ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/'));
            if (!string.IsNullOrEmpty(root) && Path.Combine(root, ServicePlan.DefaultFileName) is var original && File.Exists(original)
                && ServicePlan.ReadAny(original) is { Plan.IsEmpty: false } old)
            {
                _plan = old.Plan;
                PlanChanged();
            }
        }
        catch (Exception error) { Journal.Say($"план не прочитався: {error.Message}"); }
    }

    /// Дописати відкладений знімок одразу (закриття вікна, перевірки).
    public void FlushPlanAutosave()
    {
        if (_planAutosave is not { IsEnabled: true } timer) return;
        timer.Stop();
        WritePlanSnapshot(_plan.Journal());
    }

    static void WritePlanSnapshot(JournalFile journal)
    {
        try { Directory.CreateDirectory(DataHome.SupportFolder); journal.Write(PlanAutosavePath); }
        catch (Exception error) { Journal.Say($"план не записався: {error.Message}"); }
    }

    /// Знімок пишемо із запізненням: перетягування пункту шле правку на кожен крок.
    void SchedulePlanAutosave()
    {
        // План проповіді — гість: як «останній план» він підмінив би план служіння.
        if (_servicePlanAside != null) return;
        _planAutosave?.Stop();
        _planAutosave = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (sender, _) =>
        {
            ((DispatcherTimer)sender!).Stop();
            var journal = _plan.Journal();
            Task.Run(() => WritePlanSnapshot(journal));
        });
        _planAutosave.Start();
    }
}
