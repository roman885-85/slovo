// =============================================================================
//  ImportWizard.cs — вікно майстра імпорту (як NativeImportWizard.swift і
//  ImportWizardWindow з ImportWizardModel.swift)
// =============================================================================
//  940×660 (найменше 820×560): заголовок сторінки 13 пт напівжирний і «Крок N
//  з 6» під ним, риска, сторінка, риска, унизу «Закрити» ліворуч, «Назад» і
//  «Далі»/«Імпортувати» праворуч, між ними — хід перенесення. Поки джерело
//  переглядається, посередині — табличка з крутилкою.
//
//  Майстер живе в окремому вікні, а не аркушем над головним: обхід дисків і
//  перенесення сотні модулів ідуть хвилинами, і весь цей час аркуш тримав би
//  головне вікно заблокованим. Випадково закритий майстер відкривається там,
//  де його лишили (модель переживає вікно); після перенесення — спочатку.
//  Сам собою майстер не з'являється — тільки з меню чи пропозиції на старті.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public static class ImportWizardWindow
{
    static ImportWizard? _window;
    static ImportWizardModel? _model;
    /// Підсумок, уже підключений до бібліотеки: один раз на одне перенесення.
    static ImportOutcome? _applied;

    public static ImportWizard? Current => _window;
    public static ImportWizardModel? Model => _model;

    static string Imp(string key, string fallback) => WizardPage.Imp(key, fallback);

    public static ImportWizard? Open()
    {
        var state = AppState.Shared;
        if (_window is { } open)
        {
            // Після перенесення лишати нічого: опис джерел пораховано до нього, і з меню
            // відкривалося б старе зведення з кнопкою «Імпортувати».
            if (_model?.HasFinishedImport == true) open.Close();
            else { open.Activate(); return open; }
        }
        // Поки бібліотека відкривається, майстрові нема чим працювати: опис будується
        // за нашими модулями. У автора на цей випадок своє повідомлення — ErrorMessages24.
        if (state.IsLoadingLibrary)
        {
            Alert.Ask(Imp("ErrorMessages3", "Ошибка"),
                      Captions.Caption("ErrorMessages24", "Для открытия мастера импорта настроек необходимо дождаться полной загрузки всех модулей"),
                      new[] { Imp("PBBClose", "Закрыть") });
            return null;
        }
        if (_model == null || _model.HasFinishedImport)
        {
            var model = _model = new ImportWizardModel(Destination(state));
            model.Changed += () => ApplyOutcome(state, model);
        }
        var window = _window = new ImportWizard(state, _model);
        window.Closed += (_, _) => { if (_window == window) _window = null; };
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    /// Куди майстер розкладає перенесене: тека даних, з якою програма працює зараз, —
    /// тоді модуль з'являється в списку перекладів одразу. Якщо це чужі дані
    /// (тека встановленої старої програми), писати туди не можна — у свою бібліотеку.
    public static ImportDestination Destination(AppState state)
    {
        var root = Path.GetDirectoryName(state.ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/'));
        var current = new ImportDestination(string.IsNullOrEmpty(root) ? DataHome.Folder : root);
        return current.IsSafeToWrite ? current : ImportDestination.ApplicationLibrary;
    }

    /// Після перенесення програма не перезапускається: модулі й пісенники підключаються
    /// до списку перекладів поіменно, тека з фонами — до списку тек із фонами, і
    /// бібліотека перечитується. Навіть коли вікно майстра вже закрили.
    static void ApplyOutcome(AppState state, ImportWizardModel model)
    {
        if (model.Outcome is not { } outcome || outcome.Total == 0 || ReferenceEquals(outcome, _applied)) return;
        _applied = outcome;
        Journal.Say($"імпорт: перенесено {outcome.Total} (модулів {outcome.Modules.Count}, шаблонів {outcome.Templates.Count}, фонів {outcome.Images.Count}), помилок {outcome.Failures.Count} → {model.Destination.DataRoot}");
        state.AdoptImported(outcome.ImportedModules, outcome.Images.Count == 0 ? null : model.Destination.BackgroundsFolder);
    }
}

public sealed class ImportWizard : Window, ISnapshotWork
{
    public readonly ImportWizardView View;
    readonly ImportWizardModel _model;

    public ImportWizard(AppState state, ImportWizardModel model)
    {
        _model = model;
        Title = Captions.T("Импорт модулей, шаблонов и фонов");
        Width = 940;
        Height = 660;
        MinWidth = 820;
        MinHeight = 560;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        View = new ImportWizardView(state, model, this);
        Content = View;
        void Recolour() => Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += Recolour;
        Closed += (_, _) => { Palette.Changed -= Recolour; View.Detach(); };
        // Ввід — «Далі»: сторінки майстра гортаються з клавіатури.
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { Close(); e.Handled = true; }
            else if (e.Key == Key.Enter) { View.PressNext(); e.Handled = true; }
        };
    }

    // --- Перевірка без екрана (--snapshot): джерело, сторінка, перенесення ------------------

    int _targetPage = -1;
    bool _run, _ran, _reported;

    public void Begin(string[] args)
    {
        string? Arg(string name) => Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        if (Arg("--import-source") is { } path)
        {
            // Друга сцена того самого джерела (найменший розмір) — не додавати вдруге.
            var full = Path.GetFullPath(path);
            var resolved = ModuleImporter.ResolvingSymlinks(full);
            if (_model.Sources.FirstOrDefault(s => s.Url == resolved || s.OriginUrl == resolved || s.OriginUrl == full) is { } known)
                _model.SelectedSourceID = known.Id;
            else _model.AddChosen(full, Languages.Current);
        }
        if (int.TryParse(Arg("--wizard-page"), out var page)) _targetPage = Math.Clamp(page, 1, ImportWizardModel.Pages.Length) - 1;
        _run = args.Contains("--wizard-run");
        if (_run) _targetPage = ImportWizardModel.Pages.Length - 1;
    }

    public bool IsWorking
    {
        get
        {
            var m = _model;
            if (m.IsScanning || m.IsRunning || m.IsSearching || AppState.Shared.IsLoadingLibrary) return true;
            var index = Array.IndexOf(ImportWizardModel.Pages, m.CurrentPage);
            if (index < _targetPage && m.CanGoNext) { m.GoNext(); return true; }
            // Перенесення — без вікна-підтвердження: його кнопки тут нема кому натиснути.
            if (_run && !_ran && m.PlannedCount > 0) { _ran = true; m.Run(); return true; }
            if (!_reported)
            {
                _reported = true;
                Console.WriteLine($"  майстер: сторінка {index + 1} ({m.CurrentPage}), джерело «{m.SelectedSource?.Path}», модулів {m.Modules.Count}, шаблонів {m.Templates.Count}, фонів {m.Images.Count}, позначено {m.PlannedCount}{(m.Problem is { } p ? ", біда: " + p : "")}");
                if (m.Outcome is { } o)
                {
                    Console.WriteLine($"    перенесено {o.Total}: модулі [{string.Join(", ", o.Modules)}], шаблони [{string.Join(", ", o.Templates)}], фони {o.Images.Count}");
                    foreach (var path in o.ImportedModules) Console.WriteLine($"    модуль → {path}");
                    foreach (var f in o.Failures) Console.WriteLine($"    не вдалося: {f.Title} — {f.Reason}");
                }
            }
            return false;
        }
    }
}

public sealed class ImportWizardView : LayoutPanel
{
    readonly AppState _state;
    readonly ImportWizardModel _model;
    readonly Window _window;
    readonly BottomCaption _title = new() { FontSize = 13, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
    readonly BottomCaption _step = new() { FontSize = 11 };
    readonly Rule _topRule = new(), _bottomRule = new();
    readonly LayoutPanel _content = new();
    readonly ScanningPlate _scanning = new();
    readonly PushButton _close, _back, _next;
    readonly ProgressLine _runBar = new();
    readonly PathLabel _runStatus = new("", 10, monospace: false);
    readonly Dictionary<ImportWizardModel.Page, WizardPage> _pages = new();
    WizardPage? _shown;
    /// Про одну біду кажемо один раз — інакше вікно з відмовою спливало б на кожну перемальовку.
    string? _reportedProblem;

    static string Imp(string key, string fallback) => WizardPage.Imp(key, fallback);
    static string ImpHint(string key, string fallback) => WizardPage.ImpHint(key, fallback);

    public ImportWizardView(AppState state, ImportWizardModel model, Window window)
    {
        _state = state;
        _model = model;
        _window = window;
        _close = new PushButton(Imp("PBBClose", "Закрыть")) { Pressed = window.Close };
        ToolTip.SetTip(_close, ImpHint("PBBClose", "Закрыть мастер"));
        _back = new PushButton(Imp("PBBPrev", "Назад")) { Pressed = model.GoBack };
        ToolTip.SetTip(_back, ImpHint("PBBPrev", "Предыдущая страница"));
        // «Далі» — кнопка за умовчанням (keyEquivalent "\r"), як і на Mac.
        _next = new PushButton(Imp("PBBNext", "Дальше")) { Prominent = true, Pressed = PressNext };
        _runBar.IsVisible = false;
        _content.Layout = size => { if (_shown != null) _content.Place(_shown, new Rect(size)); };

        _pages[ImportWizardModel.Page.Intro] = new ImportIntroPage(model);
        _pages[ImportWizardModel.Page.Versions] = new ImportVersionsPage(model, () => _window);
        foreach (var page in new[] { ImportWizardModel.Page.Modules, ImportWizardModel.Page.Templates, ImportWizardModel.Page.Images })
            _pages[page] = new ImportListPage(model, page);
        _pages[ImportWizardModel.Page.Summary] = new ImportSummaryPage(state, model);

        foreach (Control c in new Control[] { _title, _step, _topRule, _bottomRule, _content, _close, _back, _next, _runBar, _runStatus, _scanning })
            Children.Add(c);
        _model.Changed += Refresh;
        Refresh();
    }

    /// Вікно закрили — модель живе далі, перемальовувати нема що.
    public void Detach() => _model.Changed -= Refresh;

    // --- Розкладка ----------------------------------------------------------------------

    protected override void Arrangement(Size size)
    {
        var width = size.Width;
        Place(_title, MacLabel.Inset(new Rect(14, 10, Math.Max(0, width - 28), 18)));
        Place(_step, MacLabel.Inset(new Rect(14, 30, Math.Max(0, width - 28), 14)));
        Place(_topRule, new Rect(0, 50, width, 1));

        var footerTop = size.Height - 46;
        Place(_bottomRule, new Rect(0, footerTop, width, 1));
        var content = new Rect(14, 60, Math.Max(0, width - 28), Math.Max(0, footerTop - 74));
        Place(_content, content);
        Place(_scanning, new Rect(content.Center.X - 95, content.Center.Y - 37, 190, 74));

        // Кнопки AppKit у рамці 24: сама кнопка 21 точка згори — тут рамка 22.
        var buttonY = footerTop + 10;
        Place(_close, new Rect(12, buttonY, 110, 22));
        var nextWidth = Math.Max(110, MacButton.Intrinsic(_next) + 24);
        var next = new Rect(width - 12 - nextWidth, buttonY, nextWidth, 22);
        Place(_next, next);
        var back = new Rect(next.X - 8 - 100, buttonY, 100, 22);
        Place(_back, back);
        Place(_runBar, new Rect(132, buttonY + 6, 160, 12));
        Place(_runStatus, new Rect(300, buttonY + 4, Math.Max(0, back.X - 310), 16));
    }

    // --- Перемальовка ---------------------------------------------------------------------

    /// Відкрите для перевірок: знімок кожної сторінки (як refresh() на Mac).
    public void Refresh()
    {
        _title.Text = PageTitle;
        _step.Text = Captions.T("Шаг %s из %s", (Array.IndexOf(ImportWizardModel.Pages, _model.CurrentPage) + 1).ToString(),
                                ImportWizardModel.Pages.Length.ToString());
        var page = _pages[_model.CurrentPage];
        if (page != _shown)
        {
            if (_shown != null) _content.Children.Remove(_shown);
            _content.Children.Add(page);
            _shown = page;
            _content.InvalidateArrange();
        }
        page.RefreshPage();

        _back.IsEnabled = _model.CanGoBack;
        if (_model.CurrentPage == ImportWizardModel.Page.Summary)
        {
            _next.Title = Imp("PBBImport", "Импортировать");
            ToolTip.SetTip(_next, Captions.T("Перенести отмеченное в библиотеку программы"));
            _next.IsEnabled = !_model.IsRunning && _model.PlannedCount > 0;
        }
        else
        {
            _next.Title = Imp("PBBNext", "Дальше");
            ToolTip.SetTip(_next, ImpHint("PBBNext", "Следующая страница"));
            _next.IsEnabled = _model.CanGoNext;
        }
        _next.InvalidateVisual();

        _runBar.IsVisible = _model.IsRunning;
        _runBar.Value = _model.RunProgress;
        _runStatus.Text = _model.IsRunning ? _model.RunStatus : "";
        _scanning.IsVisible = _model.IsScanning;
        _scanning.Spinner.IsSpinning = _model.IsScanning;
        ShowProblemIfNeeded();
        InvalidateArrange();
    }

    string PageTitle => _model.CurrentPage switch
    {
        ImportWizardModel.Page.Intro => Captions.T("Импорт модулей, шаблонов и фонов"),
        ImportWizardModel.Page.Versions => Imp("Label3", "Предыдущие версии программы:"),
        ImportWizardModel.Page.Modules => Imp("Label4", "Выберите какие модули Библии/Песенников будут импортированы:"),
        ImportWizardModel.Page.Templates => Imp("Label6", "Выберите какие шаблоны слайда будут импортированы:"),
        ImportWizardModel.Page.Images => Captions.T("Выберите, какие фоновые изображения будут перенесены:"),
        _ => Captions.T("Будет перенесено:"),
    };

    // --- Дії ----------------------------------------------------------------------------

    /// «Далі» чи, на останній сторінці, «Імпортувати».
    public void PressNext()
    {
        if (!_next.IsEnabled) return;
        if (_model.CurrentPage == ImportWizardModel.Page.Summary) ConfirmAndRun();
        else _model.GoNext();
    }

    /// Підтвердження перед перенесенням.
    void ConfirmAndRun()
    {
        if (_model.IsRunning || _model.PlannedCount == 0) return;
        Alert.Ask(Captions.T("Импорт в библиотеку программы"),
                  Captions.T("Перенести отмеченные модули, шаблоны и фоны в библиотеку программы?"),
                  new[] { Imp("PBBImport", "Импортировать"), Captions.FormCaption("BBCancel", "SettingsForm", "Отмена") },
                  answer => { if (answer == 0) _model.Run(); }, _window);
    }

    void ShowProblemIfNeeded()
    {
        if (_model.Problem is not { } problem) { _reportedProblem = null; return; }
        if (_reportedProblem == problem) return;
        _reportedProblem = problem;
        Alert.Ask(Imp("ErrorMessages3", "Ошибка"), problem, new[] { Imp("PBBClose", "Закрыть") }, _ => _model.Problem = null, _window);
    }

    /// Табличка «Перегляд джерела…» з крутилкою посередині сторінки.
    sealed class ScanningPlate : LayoutPanel
    {
        public readonly Spinner Spinner = new();
        readonly BottomCaption _caption = new(Captions.T("Просмотр источника…")) { FontSize = 11, Align = TextAlignment.Center };

        readonly PaintLayer _plate = new((g, b) =>
            g.DrawRectangle(Palette.Brush(Palette.WindowBackground), new Pen(Palette.Brush(Palette.Separator), 1), b.Deflate(0.5), 8, 8));

        public ScanningPlate()
        {
            Children.Add(_plate);
            Children.Add(Spinner);
            Children.Add(_caption);
            IsVisible = false;
        }

        protected override void Arrangement(Size size)
        {
            Place(_plate, new Rect(size));
            Place(Spinner, new Rect(87, 16, 16, 16));
            Place(_caption, new Rect(8, 42, 174, 16));
        }
    }
}
