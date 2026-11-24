// =============================================================================
//  ResourcesWindow.cs — вікно «Ресурси з GitHub»: що завантажити й що оновити
//  (як NativeResourcesWindow.swift)
// =============================================================================
//  Власник: «при запуске предложить выполнить импорт или скачать из гитхаба
//  ресурсы (с выбором ресурсов)… плюс выбор откуда качать: наш ресурс или
//  переводы с гитхаба BibleQuote». Згори — що шукаємо (переклади, пісенники чи
//  фони й шаблони; «не делай путаницу — переводы выбираются отдельно, песенники
//  отдельно»), звідки (лише джерела цього роду) і пошук. Список із галочками,
//  згрупований за родом (довгі списки MyBible — за мовою); у рядку — назва,
//  розмір і стан: «є», «оновлення» або порожньо. Унизу — позначити всі нові, всі
//  оновлення, зняти позначки, «Завантажити позначене»; хід — смужкою над
//  кнопками; після — бібліотека перечитується.
//
//  760×560 (найменше 620×420), розкладка — числами з layout() на Mac.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class ResourcesWindow : Window, ISnapshotWork
{
    static ResourcesWindow? _shown;
    public readonly ResourcesView View;

    public static ResourcesWindow? Current => _shown;

    /// Кнопки вкладки «Оновлення» в «Параметрах» — сюди (на Mac вони кличуть вікно прямо).
    public static void Install()
    {
        UpdateTab.OpenResources = () => Open();
        UpdateTab.OpenResourceUpdates = () => Open(updatesOnly: true);
    }

    /// Відкрити; `updatesOnly` — одразу позначити те, що має оновлення.
    public static ResourcesWindow Open(bool updatesOnly = false)
    {
        if (_shown is { } open)
        {
            open.View.WantsUpdatesOnly = updatesOnly;
            open.View.Reload();
            open.Activate();
            return open;
        }
        var window = _shown = new ResourcesWindow(updatesOnly);
        window.Closed += (_, _) => { if (_shown == window) _shown = null; };
        // Власник — головне вікно, як в інших вікон: закриті «Параметри», з яких його
        // відкрили, не забирають «Ресурси» з собою посеред завантаження.
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    ResourcesWindow(bool updatesOnly)
    {
        Title = Captions.T("Ресурсы с GitHub");
        Width = 760;
        Height = 560;
        MinWidth = 620;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        View = new ResourcesView(AppState.Shared) { WantsUpdatesOnly = updatesOnly };
        Content = View;
        void Recolour() => Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += Recolour;
        Closed += (_, _) => Palette.Changed -= Recolour;
        // «Завантажити позначене» — кнопка за умовчанням (keyEquivalent "\r").
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { Close(); e.Handled = true; }
            else if (e.Key == Key.Enter) { View.Take(); e.Handled = true; }
        };
        View.Reload();
    }

    // --- Перевірка без екрана (--snapshot): вкладка, джерело, пошук, установлення ----------

    string? _searchStep;
    string[]? _takeStep;
    bool _taken, _reported;

    public void Begin(string[] args)
    {
        string? Arg(string name) => Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
        if (int.TryParse(Arg("--resources-kind"), out var kind)) View.SelectKind(kind);
        if (int.TryParse(Arg("--resources-source"), out var source)) View.SelectSource(source);
        _searchStep = Arg("--resources-search");
        _takeStep = Arg("--resources-take")?.Split(',', StringSplitOptions.RemoveEmptyEntries);
    }

    public bool IsWorking
    {
        get
        {
            if (View.IsBusy || AppState.Shared.IsLoadingLibrary) return true;
            if (!View.HasCatalog && !View.CatalogFailed) return true;
            if (View.HasCatalog && _searchStep != null) { View.Search(_searchStep); _searchStep = null; return true; }
            if (View.HasCatalog && _takeStep != null && !_taken) { _taken = true; View.Choose(_takeStep); View.Take(); return true; }
            if (!_reported)
            {
                _reported = true;
                Console.WriteLine($"  ресурси: рядків {View.RowCount} — {View.StatusText}");
                if (View.LastOutcome is { } outcome)
                    foreach (var item in outcome.Installed) Console.WriteLine($"    поставлено: {item.Id} → {new ResourceLayout(AppState.Shared.ModulesFolder).Destination(item)}");
            }
            return false;
        }
    }
}

public sealed class ResourcesView : LayoutPanel, IRowSource
{
    /// Рядок таблиці: заголовок роду (мови) або сам ресурс.
    readonly record struct Line(string? Header, ResourceItem? Item);

    /// Стан ресурсу: стоїть, є оновлення чи нема.
    enum Standing { Absent, Installed, Outdated }

    const double Gap = 12;
    readonly AppState _state;
    readonly Segmented _kind;
    readonly PopupButton _source = new(Array.Empty<string>()) { FontSize = 13 };
    readonly SearchBox _search = new(13);
    readonly RowList _list;
    readonly PaintLayer _listFrame;
    readonly BottomCaption _status = new() { FontSize = 11 };
    readonly ProgressLine _bar = new() { IsVisible = false };
    readonly PushButton _take, _new, _updates, _none;
    /// Джерела, що стоять у списку зараз (залежать від вибраного роду).
    List<ResourceHub.Source> _shownSources = new();
    /// Джерело, з якого прочитано каталог.
    ResourceHub.Source? _loadedSource;
    ResourceHub _hub;
    ResourceCatalog? _catalog;
    ResourceLedger _ledger = ResourceLedger.Load();
    readonly HashSet<string> _chosen = new();
    readonly Dictionary<string, Standing> _standing = new();
    List<Line> _lines = new();
    bool _busy;
    int _generation;
    public bool WantsUpdatesOnly { get; set; }

    static readonly string[] KindTitles = { "Переводы Библии", "Песенники", "Фоны и шаблоны" };

    public ResourcesView(AppState state)
    {
        _state = state;
        _hub = new ResourceHub(new ResourceLayout(state.ModulesFolder));
        _kind = new Segmented(KindTitles.Select(t => Captions.T(t)), 13);
        ToolTip.SetTip(_kind, Captions.T("Что загружать: переводы, песенники или фоны и шаблоны — у каждого свои источники"));
        _kind.Selected += _ => KindChosen();
        ToolTip.SetTip(_source, Captions.T("Откуда загружать"));
        _source.Selected += _ => Reload();
        _search.Placeholder = Captions.T("Поиск: название, сокращение или язык (uk, ru, en…)");
        _search.OnChange = _ => RebuildLines();
        // Таблиця NativeTable (.plain): галочка 28, назва, приписка 150, рядок 24 + 2.
        _list = new RowList(new ListMetrics
        {
            LeadWidth = 35, DetailWidth = 148, Padding = new Thickness(0, 5, 5, 5),
            TextFontDelta = 0, DetailFontDelta = -2,
        }, 13)
        { ContentInset = new Thickness(0), HandlesArrowKeys = true, Source = this };
        _list.SetUniformHeight(26);
        _list.OnLeadClick = Toggle;
        _list.OnActivate = Toggle;
        _listFrame = new PaintLayer((g, b) =>
            g.DrawRectangle(Palette.Brush(Palette.TextBackground), new Pen(Palette.Brush(ImportTable.Border), 1), b.Deflate(0.5)));
        _take = new PushButton(Captions.T("Загрузить отмеченное")) { Prominent = true, Pressed = Take };
        _new = new PushButton(Captions.T("Отметить все новые")) { Pressed = MarkNew };
        _updates = new PushButton(Captions.T("Отметить обновления")) { Pressed = MarkUpdates };
        _none = new PushButton(Captions.T("Снять отметки")) { Pressed = MarkNone };
        ToolTip.SetTip(_new, Captions.T("Отметить всё, чего ещё нет на этом компьютере"));
        ToolTip.SetTip(_updates, Captions.T("Отметить установленное, у чего вышла новая версия"));
        ToolTip.SetTip(_none, Captions.T("Снять все отметки"));
        // Куди все лягає — пишемо прямо в підказці (власник: «только в программе в
        // настройках и подсказках писать, где все хранится»).
        ToolTip.SetTip(_take, DataHome.Hint(Captions.T("Загрузить и установить отмеченное")));
        foreach (Control c in new Control[] { _kind, _source, _search, _listFrame, _list, _status, _bar, _new, _updates, _none, _take })
            Children.Add(c);
        FillSources();
    }

    /// Роди ресурсів вибраної вкладки.
    IReadOnlySet<ResourceKind> ChosenKinds => _kind.SelectedIndex switch
    {
        1 => new HashSet<ResourceKind> { ResourceKind.Songbook },
        2 => new HashSet<ResourceKind> { ResourceKind.Backgrounds, ResourceKind.Templates, ResourceKind.Fonts, ResourceKind.Web },
        _ => new HashSet<ResourceKind> { ResourceKind.Bible },
    };

    ResourceHub.Source ChosenSource =>
        _source.SelectedIndex >= 0 && _source.SelectedIndex < _shownSources.Count ? _shownSources[_source.SelectedIndex] : ResourceHub.Source.Slovo;

    /// Підпис джерела у списку вікна.
    static string SourceTitle(ResourceHub.Source source) => Captions.T(source switch
    {
        ResourceHub.Source.Slovo => "Ресурсы «Слова» (GitHub)",
        ResourceHub.Source.BibleQuote => "Модули «Цитата из Библии» на GitHub",
        ResourceHub.Source.MyBible => "Реестр MyBible (переводы на многих языках)",
        ResourceHub.Source.EBible => "eBible.org — свободные переводы на 1000+ языках (ставятся модулем MyBible)",
        _ => "Песенники SoftProjector (softprojector.org)",
    });

    /// Джерела вкладки — лише ті, що дають цей рід.
    void FillSources()
    {
        var kinds = ChosenKinds;
        _shownSources = ResourceSources.All.Where(source => source.Kinds().Overlaps(kinds)).ToList();
        _source.SetItems(_shownSources.Select(SourceTitle));
        _source.SelectedIndex = 0;
    }

    // --- Розкладка ----------------------------------------------------------------------

    protected override void Arrangement(Size size)
    {
        var w = size.Width;
        var searchWidth = Math.Min(300, w * 0.38);
        // NSSegmentedControl.sizeToFit: підпис + по 10 з боків на сегмент.
        var fit = KindTitles.Sum(t => Math.Ceiling(UiFont.Width(Captions.T(t), 13)) + 20) + 4;
        Place(_kind, new Rect(Gap, Gap, Math.Min(w - Gap * 2, Math.Max(fit, 420)), 26));
        var row = Gap + 26 + 8;
        var source = new Rect(Gap, row, Math.Max(0, w - Gap * 3 - searchWidth), 26);
        Place(_source, source);
        Place(_search, new Rect(source.Right + Gap, row + 1, searchWidth, 24));

        // Кнопки AppKit у рамці 28: сама кнопка 21 точка згори — тут рамка 22.
        var buttonsY = size.Height - Gap - 28;
        var takeWidth = MacButton.Intrinsic(_take) + 16;
        Place(_take, new Rect(w - Gap - takeWidth, buttonsY, takeWidth, 22));
        // Три кнопки зліва — за своєю шириною; у найвужчому вікні українські підписи
        // не влазять поруч із «Завантажити позначене» — тоді стискаються порівну
        // (на Mac вони б наповзли одна на одну).
        var lefts = new[] { _new, _updates, _none };
        var widths = lefts.Select(b => MacButton.Intrinsic(b) + 12).ToArray();
        var room = w - Gap - takeWidth - 8 - Gap - 8 * (lefts.Length - 1);
        var scale = widths.Sum() > room && room > 0 ? room / widths.Sum() : 1;
        var x = Gap;
        for (var i = 0; i < lefts.Length; i++)
        {
            var width = Math.Floor(widths[i] * scale);
            Place(lefts[i], new Rect(x, buttonsY, width, 22));
            x += width + 8;
        }
        Place(_bar, new Rect(Gap, buttonsY - 10, Math.Max(0, w - Gap * 2), 6));
        var statusY = buttonsY - 30;
        Place(_status, MacLabel.Inset(new Rect(Gap, statusY, Math.Max(0, w - Gap * 2), 16)));
        var list = new Rect(Gap, source.Bottom + Gap, Math.Max(0, w - Gap * 2), Math.Max(0, statusY - Gap - source.Bottom - Gap));
        Place(_listFrame, list);
        Place(_list, list.Deflate(1));
    }

    // --- Каталог ------------------------------------------------------------------------

    public void Reload()
    {
        _hub = new ResourceHub(new ResourceLayout(_state.ModulesFolder));
        _ledger = ResourceLedger.Load();
        _standing.Clear();
        _catalog = null;
        _lines = new List<Line>();
        _chosen.Clear();
        _list.Reload();
        _status.Text = Captions.T("Читаю каталог…");
        CatalogFailed = false;
        var picked = ChosenSource;
        _loadedSource = null;
        var generation = ++_generation;
        _hub.FetchCatalog(picked, (catalog, error) => Dispatcher.UIThread.Post(() =>
        {
            if (generation != _generation || ChosenSource != picked) return;
            if (catalog == null)
            {
                _status.Text = Captions.T("Каталог не прочитался: %s", error?.Message ?? "");
                CatalogFailed = true;
                return;
            }
            _catalog = catalog;
            _loadedSource = picked;
            // «Перевірити оновлення ресурсів»: відкриваємо ту вкладку, де оновлення
            // справді є (часто це пісенники).
            if (WantsUpdatesOnly && picked == ResourceHub.Source.Slovo)
            {
                var outdated = catalog.Items.Where(item => StandingOf(item) == Standing.Outdated).ToList();
                var tabs = new[]
                {
                    new HashSet<ResourceKind> { ResourceKind.Bible }, new HashSet<ResourceKind> { ResourceKind.Songbook },
                    new HashSet<ResourceKind> { ResourceKind.Backgrounds, ResourceKind.Templates, ResourceKind.Fonts, ResourceKind.Web },
                };
                var kinds = ChosenKinds;
                var tab = Array.FindIndex(tabs, set => outdated.Any(item => set.Contains(item.Kind)));
                if (!outdated.Any(item => kinds.Contains(item.Kind)) && tab >= 0)
                {
                    _kind.SelectedIndex = tab;
                    // Список джерел — уже нової вкладки; «Слово» в ньому завжди перше.
                    FillSources();
                }
            }
            RebuildLines();
            if (WantsUpdatesOnly) MarkUpdates(); else Summarize();
        }));
    }

    void KindChosen()
    {
        FillSources();
        _search.Text = "";
        _chosen.Clear();
        // Свій каталог уже прочитано — для іншої вкладки перечитувати нема чого.
        if (_loadedSource == ResourceHub.Source.Slovo && ChosenSource == ResourceHub.Source.Slovo && _catalog != null)
        {
            RebuildLines();
            Summarize();
        }
        else Reload();
    }

    void RebuildLines()
    {
        if (_catalog is not { } catalog) { _lines = new List<Line>(); _list.Reload(); return; }
        var order = new[] { ResourceKind.Bible, ResourceKind.Songbook, ResourceKind.Backgrounds, ResourceKind.Templates, ResourceKind.Fonts, ResourceKind.Web };
        var titles = new Dictionary<ResourceKind, string>
        {
            [ResourceKind.Bible] = Captions.T("Переводы Библии"), [ResourceKind.Songbook] = Captions.T("Песенники"),
            [ResourceKind.Backgrounds] = Captions.T("Фоны"), [ResourceKind.Templates] = Captions.T("Шаблоны слайдов"),
            [ResourceKind.Fonts] = Captions.T("Шрифты"), [ResourceKind.Web] = Captions.T("Страницы веб-слайдов"),
        };
        var query = _search.Text.Trim().ToLowerInvariant();
        var kindsShown = ChosenKinds;
        // Код мови («uk», «ru», «en») — лише ця мова: інакше «uk» знаходило й «Luke»,
        // «UKJV» — сотню чужих перекладів.
        var isLanguage = query.Length > 0 && catalog.Items.Any(item => item.Language?.ToLowerInvariant() == query);
        var visible = catalog.Items.Where(item =>
        {
            if (!kindsShown.Contains(item.Kind)) return false;
            if (query.Length == 0) return true;
            if (isLanguage) return item.Language?.ToLowerInvariant() == query;
            return item.Title.ToLowerInvariant().Contains(query, StringComparison.Ordinal)
                   || item.Subtitle.ToLowerInvariant().Contains(query, StringComparison.Ordinal);
        }).ToList();
        var byTitle = Comparer<ResourceItem>.Create((a, b) => SwiftText.LocalizedStandardCompare(a.Title, b.Title));
        var built = new List<Line>();
        if (kindsShown.IsSubsetOf(new[] { ResourceKind.Bible, ResourceKind.Songbook }) && visible.Any(item => item.Language != null))
        {
            // Список із мовами (MyBible) — за мовами: спершу мова інтерфейсу, далі
            // українська, російська, англійська, решта за абеткою.
            var preferred = new[] { OurWords.Language, "uk", "ru", "en" };
            int Rank(string key) { var i = Array.IndexOf(preferred, key); return i < 0 ? int.MaxValue : i; }
            var groups = visible.GroupBy(item => item.Language ?? "—").ToList();
            groups.Sort((a, b) => Rank(a.Key) != Rank(b.Key) ? Rank(a.Key).CompareTo(Rank(b.Key)) : string.CompareOrdinal(a.Key, b.Key));
            foreach (var group in groups)
            {
                var items = group.ToList();
                items.Sort(byTitle);
                built.Add(new Line($"{Captions.T("Язык")} {group.Key}  ·  {items.Count}", null));
                built.AddRange(items.Select(item => new Line(null, item)));
            }
        }
        else
        {
            foreach (var kind in order)
            {
                var items = visible.Where(item => item.Kind == kind).ToList();
                if (items.Count == 0) continue;
                items.Sort(byTitle);
                built.Add(new Line($"{titles[kind]}  ·  {items.Count}", null));
                built.AddRange(items.Select(item => new Line(null, item)));
            }
        }
        _lines = built;
        _list.Reload();
    }

    Standing StandingOf(ResourceItem item)
    {
        if (_standing.TryGetValue(item.Id, out var known)) return known;
        Standing result;
        if (!_hub.Layout.IsPresent(item)) result = Standing.Absent;
        else if (_ledger.Installed.TryGetValue(item.Id, out var version) && item.Version.Length > 0 && version != item.Version) result = Standing.Outdated;
        else result = Standing.Installed;
        _standing[item.Id] = result;
        return result;
    }

    void Summarize()
    {
        if (_catalog is not { } catalog) return;
        var kinds = ChosenKinds;
        var items = catalog.Items.Where(item => kinds.Contains(item.Kind)).ToList();
        var absent = items.Count(item => StandingOf(item) == Standing.Absent);
        var outdated = items.Count(item => StandingOf(item) == Standing.Outdated);
        var size = catalog.Items.Where(item => _chosen.Contains(item.Id)).Sum(item => item.Size);
        _status.Text = Captions.T("Ресурсов %s; ещё не установлено %s, обновлений %s; отмечено %s (%s)",
                                  items.Count.ToString(), absent.ToString(), outdated.ToString(), _chosen.Count.ToString(), Megabytes(size));
    }

    static string Megabytes(long bytes) =>
        bytes <= 0 ? "—" : (bytes / 1_048_576.0).ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + " МБ";

    // --- Позначки -----------------------------------------------------------------------

    void Toggle(int index)
    {
        if (index < 0 || index >= _lines.Count || _lines[index].Item is not { } item) return;
        if (!_chosen.Remove(item.Id)) _chosen.Add(item.Id);
        _list.ReloadRow(index);
        Summarize();
    }

    /// Те, що видно в списку після пошуку: позначки діють на нього, а не на весь
    /// каталог — у MyBible тисячі перекладів, і «Позначити всі нові» без пошуку
    /// поставило б їх усі.
    IEnumerable<ResourceItem> VisibleItems => _lines.Where(line => line.Item != null).Select(line => line.Item!);

    void MarkNew() => Choose(VisibleItems.Where(item => StandingOf(item) == Standing.Absent).Select(item => item.Id));

    void MarkUpdates() => Choose(VisibleItems.Where(item => StandingOf(item) == Standing.Outdated).Select(item => item.Id));

    void MarkNone() => Choose(Array.Empty<string>());

    /// Позначити за ідентифікаторами (і перевіркам).
    public void Choose(IEnumerable<string> ids)
    {
        _chosen.Clear();
        _chosen.UnionWith(ids);
        _list.Reload();
        Summarize();
    }

    // --- Завантаження -------------------------------------------------------------------

    public bool IsBusy => _busy;
    public bool HasCatalog => _catalog != null;
    public bool CatalogFailed { get; private set; }

    /// Те саме, що клацання по вкладці роду / вибір джерела / набір у пошуку (перевіркам).
    public void SelectKind(int index) { _kind.SelectedIndex = Math.Clamp(index, 0, 2); KindChosen(); }
    public void SelectSource(int index) { _source.SelectedIndex = Math.Clamp(index, 0, Math.Max(0, _shownSources.Count - 1)); Reload(); }
    public void Search(string text) { _search.Text = text; RebuildLines(); Summarize(); }
    public int RowCount => _lines.Count;
    public string StatusText => _status.Text;
    /// Останнє, що поставилося (перевіркам).
    public ResourceHub.Outcome? LastOutcome { get; private set; }

    public void Take()
    {
        if (_busy || _catalog is not { } catalog) return;
        var items = catalog.Items.Where(item => _chosen.Contains(item.Id)).ToList();
        if (items.Count == 0) { _status.Text = Captions.T("Ничего не отмечено"); return; }
        _busy = true;
        _take.IsEnabled = false;
        _source.IsEnabled = false;
        _kind.IsEnabled = false;
        _bar.IsVisible = true;
        _bar.Value = 0;
        Install(items);
    }

    void Install(IReadOnlyList<ResourceItem> items)
    {
        var layout = _hub.Layout;
        _hub.Install(items, progress => Dispatcher.UIThread.Post(() =>
        {
            var step = 1.0 / Math.Max(progress.Total, 1);
            _bar.Value = progress.Index * step + (progress.Fraction ?? 0) * step;
            _status.Text = Captions.T("Загружаю %s из %s: %s", (progress.Index + 1).ToString(), progress.Total.ToString(), progress.Item.Title);
        }), outcome => Dispatcher.UIThread.Post(() =>
        {
            _busy = false;
            _take.IsEnabled = true;
            _source.IsEnabled = true;
            _kind.IsEnabled = true;
            _bar.IsVisible = false;
            _ledger = ResourceLedger.Load();
            _standing.Clear();
            _chosen.Clear();
            _list.Reload();
            var text = Captions.T("Установлено: %s", outcome.Installed.Count.ToString());
            if (outcome.Failures.Count > 0)
                text += "; " + Captions.T("не удалось: %s", string.Join("; ", outcome.Failures.Select(f => $"{f.Item.Title} — {f.Reason}")));
            _status.Text = text;
            LastOutcome = outcome;
            Journal.Say("ресурси: " + text);
            if (outcome.Installed.Count > 0) _state.AdoptImported(InstalledModules(layout, outcome.Installed));
        }));
    }

    /// Куди лягли поставлені переклади й пісенники (пісенник старої програми —
    /// уже у форматі «Слова») — щоб підключити їх до списку модулів поіменно.
    public static List<string> InstalledModules(ResourceLayout layout, IEnumerable<ResourceItem> installed)
    {
        var paths = new List<string>();
        foreach (var item in installed.Where(i => i.Kind is ResourceKind.Bible or ResourceKind.Songbook))
        {
            var target = layout.Destination(item);
            if (File.Exists(target) || Directory.Exists(target)) { paths.Add(target); continue; }
            var own = SwiftPath.DeletingExtension(target) + "." + SongBookJSON.PathExtension;
            if (File.Exists(own)) paths.Add(own);
        }
        return paths;
    }

    // --- Рядки списку -----------------------------------------------------------------------

    public Row RowAt(int index)
    {
        if (index < 0 || index >= _lines.Count) return new Row();
        var line = _lines[index];
        if (line.Item is not { } item)
            // Заголовок — у колонці назв, як на Mac (у колонці галочок порожньо).
            return new Row((line.Header ?? "").ToUpperInvariant(), " ") { TextColor = Palette.SecondaryLabel, SingleLine = true };
        var mark = StandingOf(item) switch
        {
            Standing.Installed => Captions.T("есть"),
            Standing.Outdated => Captions.T("обновление"),
            _ => "",
        };
        var detail = string.Join(" · ", new[] { Megabytes(item.Size), mark }.Where(part => part != "—" && part.Length > 0));
        return new Row(item.Title + (item.Subtitle.Length == 0 ? "" : "  (" + item.Subtitle + ")"), _chosen.Contains(item.Id) ? "☑" : "☐", detail)
        {
            SingleLine = true, Tooltip = item.Subtitle.Length > 0 ? item.Title + "\n" + item.Subtitle : "",
        };
    }
}

/// Пропозиція на старті, коли перекладів і пісенників нема зовсім (збірка «лише
/// програма»): завантажити з GitHub або імпортувати (ResourceOffer на Mac). Питаємо,
/// коли бібліотеку вже прочитано — доти не видно, порожня тека чи ще читається.
public static class ResourceOffer
{
    static bool _shown;
    static Signals.Token? _watch;

    public static void Watch(AppState state)
    {
        if (_watch != null || _shown) return;
        _watch = Signals.Shared.Subscribe(Signals.Kind.Library, () =>
        {
            _watch?.Dispose();
            _watch = null;
            // Таймером — як на Mac: вікно-питання не посеред читання бібліотеки.
            DispatcherTimer.RunOnce(() => OfferIfEmpty(state), TimeSpan.FromSeconds(1.5));
        });
    }

    public static void OfferIfEmpty(AppState state)
    {
        if (_shown || state.AllModules.Count > 0 || state.AllSongBooks.Count > 0 || state.IsLoadingLibrary) return;
        _shown = true;
        Alert.Ask(Captions.T("В папке модулей пусто"),
                  Captions.T("Переводов и песенников у программы ещё нет. Загрузить их с GitHub (ресурсы «Слова» или модули «Цитата из Библии») или импортировать с этого компьютера (папка с данными прежней программы, папка с модулями, архив)?"),
                  new[] { Captions.T("Загрузить с GitHub…"), Captions.T("Импортировать…"), Captions.T("Позже") },
                  answer =>
                  {
                      if (answer == 0) ResourcesWindow.Open();
                      else if (answer == 1) ImportWizardWindow.Open();
                  });
    }
}
