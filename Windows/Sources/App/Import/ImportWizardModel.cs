// =============================================================================
//  ImportWizardModel.cs — майстер імпорту, розділ 4.2 посібника в частині даних
//  (як ImportWizardModel.swift)
// =============================================================================
//  В оригіналі це «Перший запуск»: вибір мови (4.1) і майстер перенесення
//  налаштувань із попередньої версії (4.2). У «Слові» окремого першого
//  запуску немає: мова за умовчанням — українська, налаштування — з файла
//  умовчань. Майстер залишився як інструмент і кличеться з меню: джерелом може
//  бути тека з даними старої програми, будь-яка тека з даними або архів .zip, а
//  переносяться тільки дані — модулі й пісенники, шаблони слайда, фонові
//  зображення. Сторінки йдуть у порядку автора: 4.2.1 вибір джерела, 4.2.2
//  модулі, 4.2.3 шаблони, 4.2.4 фони, 4.2.6 завершення; сторінки налаштувань
//  (4.2.5) немає навмисно.
//
//  Довге (обхід дисків, опис джерела, перенесення) — у фоні; зміни моделі
//  збираються в одне сповіщення на оберт черги головного потоку.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class ImportWizardModel
{
    /// Сторінки за підрозділами 4.2 — без 4.2.5 «налаштування».
    public enum Page { Intro, Versions, Modules, Templates, Images, Summary }

    public static readonly Page[] Pages = Enum.GetValues<Page>();

    /// Щось змінилося — майстер перемальовується (objectWillChange на Mac).
    public event Action? Changed;
    bool _notifying;

    void Notify()
    {
        if (_notifying) return;
        _notifying = true;
        Dispatcher.UIThread.Post(() => { _notifying = false; Changed?.Invoke(); });
    }

    Page _page = Page.Intro;
    public Page CurrentPage { get => _page; set { if (_page == value) return; _page = value; Notify(); } }

    // 4.2.1
    public List<ImportSource> Sources { get; } = new();
    string? _selected;
    public string? SelectedSourceID { get => _selected; set { if (_selected == value) return; _selected = value; Notify(); } }
    public bool IsSearching { get; private set; }
    public string SearchStatus { get; private set; } = "";
    string? _problem;
    public string? Problem { get => _problem; set { if (_problem == value) return; _problem = value; Notify(); } }

    // 4.2.2–4.2.4
    public bool IsScanning { get; private set; }
    public List<ImportItem> Modules { get; private set; } = new();
    public List<ImportItem> Templates { get; private set; } = new();
    public List<ImportItem> Images { get; private set; } = new();

    // 4.2.6
    public bool IsRunning { get; private set; }
    public double RunProgress { get; private set; }
    public string RunStatus { get; private set; } = "";
    public ImportOutcome? Outcome { get; private set; }

    /// Куди розкладаємо.
    public ImportDestination Destination { get; }

    /// Кнопка «Зупинити» (PBBStopSearch) має доходити до обходу дисків у фоні.
    volatile bool _stop;
    string? _scannedSourceID;

    public ImportWizardModel(ImportDestination destination)
    {
        Destination = destination;
        try { Sources.AddRange(ModuleImporter.InstalledVersions()); }
        catch (Exception error) { Journal.Say("імпорт: пошук установлених версій — " + error.Message); }
        _selected = Sources.FirstOrDefault()?.Id;
    }

    public ImportSource? SelectedSource => Sources.FirstOrDefault(source => source.Id == _selected);

    // --- Переходи -------------------------------------------------------------------

    public bool CanGoBack => _page != Page.Intro && !IsRunning;

    public bool CanGoNext
    {
        get
        {
            if (IsRunning || IsScanning) return false;
            return _page switch
            {
                Page.Intro => true,
                Page.Versions => SelectedSource != null,
                Page.Summary => false,
                _ => true,
            };
        }
    }

    public void GoNext()
    {
        var index = Array.IndexOf(Pages, _page);
        if (!CanGoNext || index < 0 || index + 1 >= Pages.Length) return;
        CurrentPage = Pages[index + 1];
        // Опис будується раз на джерело і лише тоді, коли до нього дійшли: на сторінці
        // вибору версії його викинуло б перше ж перемикання рядка списку.
        if (_page == Page.Modules) LoadInventory();
    }

    public void GoBack()
    {
        var index = Array.IndexOf(Pages, _page);
        if (!CanGoBack || index <= 0) return;
        CurrentPage = Pages[index - 1];
    }

    // --- 4.2.1 Джерела -----------------------------------------------------------------

    /// «Вибрати теку з попередньою версією» (PBBSelectFolderPortableVers) — і те саме
    /// приймає архів .zip чи файл модуля. Текст відмови — словами автора
    /// (ErrorMessages0/1/2 форми ImportFromOldVersForm) мовою інтерфейсу.
    public void AddChosen(string path, LanguageFile? language)
    {
        try
        {
            var source = ModuleImporter.SourceAt(path, Sources);
            Sources.Add(source);
            _selected = source.Id;
            _problem = null;
        }
        catch (Exception error)
        {
            _problem = ImportProblem.Text(error, language);
        }
        Notify();
    }

    /// «Знайти інші версії автоматично» (PBBFindPortableVers).
    public void SearchAllDisks()
    {
        if (IsSearching) return;
        IsSearching = true;
        SearchStatus = "";
        _stop = false;
        Notify();
        Task.Run(() =>
        {
            // Обхід кличе `progress` на кожній теці — тисячі разів за секунду. Без
            // проріджування головний потік захлинається самою перемальовкою рядка стану.
            var last = DateTime.MinValue;
            try
            {
                ModuleImporter.SearchAllDisks(
                    shouldStop: () => _stop,
                    progress: path =>
                    {
                        if ((DateTime.UtcNow - last).TotalSeconds <= 0.1) return;
                        last = DateTime.UtcNow;
                        Dispatcher.UIThread.Post(() => { SearchStatus = path; Notify(); });
                    },
                    found: source => Dispatcher.UIThread.Post(() => Merge(source)));
            }
            catch (Exception error) { Journal.Say("імпорт: обхід дисків — " + error.Message); }
            Dispatcher.UIThread.Post(() => { IsSearching = false; SearchStatus = ""; Notify(); });
        });
    }

    /// «Зупинити» (PBBStopSearch).
    public void StopSearch() => _stop = true;

    void Merge(ImportSource source)
    {
        if (Sources.Any(existing => existing.Id == source.Id)) return;
        Sources.Add(source);
        _selected ??= source.Id;
        Notify();
    }

    // --- 4.2.2–4.2.4 Опис -----------------------------------------------------------------

    public void LoadInventory()
    {
        if (SelectedSource is not { } source || _scannedSourceID == source.Id) return;
        IsScanning = true;
        Notify();
        var destination = Destination;
        Task.Run(() =>
        {
            ImportInventory? inventory = null;
            string? problem = null;
            try { inventory = ModuleImporter.Inventory(source, destination); }
            catch (Exception error) { problem = ImportProblem.Text(error, Languages.Current); }
            Dispatcher.UIThread.Post(() =>
            {
                if (inventory != null)
                {
                    Modules = inventory.Modules;
                    Templates = inventory.Templates;
                    Images = inventory.Images;
                    _scannedSourceID = source.Id;
                }
                else _problem = problem;
                IsScanning = false;
                Notify();
            });
        });
    }

    public List<ImportItem> Items(Page page) => page switch
    {
        Page.Modules => Modules,
        Page.Templates => Templates,
        Page.Images => Images,
        _ => new List<ImportItem>(),
    };

    /// Галочка рядка.
    public void SetSelected(string id, Page page, bool value)
    {
        var list = Items(page);
        var index = list.FindIndex(item => item.Id == id);
        if (index < 0) return;
        list[index] = list[index] with { IsSelected = value };
        Notify();
    }

    /// PSBSel* / PSBUnSel* — «Виділити всі …» і «Зняти виділення з усіх …».
    public void SetAll(Page page, bool value)
    {
        var list = Items(page);
        for (var i = 0; i < list.Count; i++) list[i] = list[i] with { IsSelected = value };
        Notify();
    }

    // --- 4.2.6 Імпорт -------------------------------------------------------------------

    public ImportInventory? PlannedInventory =>
        SelectedSource is { } source ? new ImportInventory(source, Modules, Templates, Images) : null;

    public int PlannedCount => PlannedInventory?.Selected.Count ?? 0;

    /// Перенесення вже відбулося: повторне відкриття з меню починає майстер спочатку.
    public bool HasFinishedImport => Outcome != null && !IsRunning;

    /// «Імпортувати» (PBBImport).
    public void Run()
    {
        if (PlannedInventory is not { } inventory || IsRunning) return;
        IsRunning = true;
        RunProgress = 0;
        RunStatus = "";
        Outcome = null;
        Notify();
        var destination = Destination;
        Task.Run(() =>
        {
            ImportOutcome result;
            try
            {
                result = ModuleImporter.Run(inventory, destination, (title, value) =>
                    Dispatcher.UIThread.Post(() => { RunStatus = title; RunProgress = value; Notify(); }));
            }
            catch (Exception error)
            {
                result = new ImportOutcome();
                result.Failures.Add(new ImportOutcome.Failure(destination.DataRoot, error.Message));
            }
            Dispatcher.UIThread.Post(() =>
            {
                RunStatus = "";
                RunProgress = 1;
                Outcome = result;
                IsRunning = false;
                Notify();
            });
        });
    }
}
