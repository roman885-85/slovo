// =============================================================================
//  ModulesTab.cs — вкладка «Модулі» (як NativeSettingsModulesTab на Mac)
// =============================================================================
//  Перемикач «Переклади Біблії · N | Пісенники · N», «Позначити всі / Зняти
//  позначку з усіх», «увімкнено X з Y»; список із галочками (клацання по галочці
//  чи подвійне — увімкнути/вимкнути), «+ − ↑ ↓ ⤓»; завантаження в пам'ять.
//  Галочка діє одразу (переклад стає на смугу), «Гаразд» лише запам'ятовує.
// =============================================================================

using Avalonia.Controls;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class ModulesTab : IRowSource
{
    readonly SettingsStore _store;
    readonly RowList _list = new(ListMetrics.Settings(220), 13) { Height = 420, Width = 560 };
    readonly Segmented _kinds = new(new[] { "", "" }, 12) { Width = 360, Height = 24 };
    readonly TextBlock _status = Form.Label("");
    bool _songBooks;
    int? _selected;
    public static Action? RosterChanged;

    public ModulesTab(SettingsStore store)
    {
        _store = store;
        _list.SetUniformHeight(24);
        _list.Source = this;
        _list.OnSelect = (_, i, _) => _selected = i;
        _list.OnActivate = Toggle;
        _list.OnLeadClick = Toggle;
        _kinds.Selected += i => { _songBooks = i == 1; _selected = null; Refresh(); };
        ToolTip.SetTip(_kinds, Captions.T("Какой список показать: переводы Библии или песенники"));
        Refresh();
    }

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "SettingsForm") ?? Captions.T(fallback);
    List<ModuleRosterEntry> Shown => _store.Settings.Modules.Where(m => m.IsSongBook == _songBooks).ToList();

    public Control Page() => new Form.Page(new[] { Modules(), Loading() });

    Form.Group Modules()
    {
        var buttons = new StackPanel { Spacing = 4 };
        buttons.Children.Add(Form.Button("+", Hint("SBAddBiblePath", "Добавить путь... (Ins)"), Add));
        buttons.Children.Add(Form.Button("−", Hint("SBDelBiblePath", "Удалить путь... (Del)"), Remove));
        buttons.Children.Add(Form.Button("↑", Hint("SBUpBiblePath", "Переместить выше"), () => Move(-1)));
        buttons.Children.Add(Form.Button("↓", Hint("SBDownBiblePath", "Переместить ниже"), () => Move(1)));
        buttons.Children.Add(Form.Button("⤓", Hint("SBImportModules", "Импорт модулей..."), Add));
        buttons.Children.Add(Form.Button("🔍", Hint("SBSearchTexts", "Найти совместимые тексты"), () => _ = SearchTexts()));
        return new Form.Group(Vb("Label1", Captions.T("Текстовые модули:")), new Control[]
        {
            new Form.Row("", new Control[] { _kinds }),
            new Form.Row("", new Control[]
            {
                Form.Button(Captions.FormHint("SBCheckAll", "SettingsForm") ?? Captions.T("Пометить все"), Captions.T("Включить все модули открытого списка"), () => SetAll(true)),
                Form.Button(Captions.FormHint("SBUnCheckAll", "SettingsForm") ?? Captions.T("Снять пометку со всех"), Captions.T("Выключить все модули открытого списка"), () => SetAll(false)),
                _status,
            }),
            new Form.Row("", new Control[] { _list, buttons }, stretch: true),
            new Form.Row("", new Control[] { Form.Label(Captions.T("Галочка слева включает модуль: перевод встаёт на полосу переводов, песенник — в список песенников.")) }, stretch: true),
            new Form.Row("", new Control[] { Form.Label(Captions.T("Видно сразу, «Ок» только запоминает. «Пометить все» и «Снять пометку» действуют на открытый список.")) }, stretch: true),
            new Form.Row("", new Control[] { Form.Note(Captions.T("Модули лежат в папке: %s", DataHome.Modules)) }, stretch: true),
        });
    }

    Form.Group Loading() => new("", new Control[]
    {
        new Form.Row("", new Control[]
        {
            Form.Check(Vb("CBLoadAllBooks", Captions.T("Загружать Тексты в память")), new Tie<bool>(() => _store.Settings.Options.LoadAllBooks, v => _store.Settings.Options.LoadAllBooks = v),
                       Captions.T("Держать тексты модулей в памяти целиком: переходы быстрее, памяти нужно больше")),
            Form.Check(Vb("CBLazyLoad", Captions.T("Отложенная загрузка модулей")), new Tie<bool>(() => _store.Settings.Options.LazyLoadModules, v => _store.Settings.Options.LazyLoadModules = v),
                       Captions.T("Читать модуль только тогда, когда его открыли: быстрее запуск")),
        }),
    });

    CancellationTokenSource? _search;

    /// (29) Автоматичний пошук сумісних модулів на комп'ютері (search() у NativeSettingsModulesTab):
    /// тека → обхід у фоні з лічильниками → «Замінити список?» (Так — замінити, Ні — додати).
    async Task SearchTexts()
    {
        if (TopLevel.GetTopLevel(_list)?.StorageProvider is not { } storage) return;
        var folders = await storage.OpenFolderPickerAsync(new Avalonia.Platform.Storage.FolderPickerOpenOptions
        {
            Title = Vb("TextMessages10", "Произвести поиск текстов формата \"Цитата из Библии\"?"),
        });
        if (folders.Count == 0 || folders[0].TryGetLocalPath() is not { } root) return;
        _search?.Cancel();
        var cancel = _search = new CancellationTokenSource();
        var progress = new SettingsStore.TextScan();
        _status.Text = Vb("Label13", "Папка:") + " " + root;
        var scan = Task.Run(() => SettingsStore.ScanForTexts(root, progress, cancel.Token));
        while (!scan.IsCompleted)
        {
            _status.Text = $"{Vb("Label14", "Просмотрено папок:")} {progress.Folders}  {Vb("Label15", "Найдено текстов:")} {progress.Found}";
            await Task.Delay(200);
        }
        var found = await scan;
        if (cancel.IsCancellationRequested) return;
        _status.Text = $"{Vb("Label15", "Найдено текстов:")} {found.Count}";
        if (found.Count == 0) return;
        var question = $"{Vb("TextMessages12", "Найдено")} {found.Count}\n" + Vb("TextMessages13", "текстов формата \"Цитата из Библии\".\nЗаменить список?");
        var answer = await SongPrompt.ThreeWay(Vb("TextMessages11", "Поиск"), question.Replace("\\n", "\n"), "Да", "Нет");
        if (answer == SongPrompt.Answer.Cancel) return;
        _store.ApplyFoundTexts(found, replacing: answer == SongPrompt.Answer.Yes);
        Changed();
    }

    void Refresh()
    {
        var all = _store.Settings.Modules;
        var bibles = all.Count(m => !m.IsSongBook); var songs = all.Count(m => m.IsSongBook);
        _kinds.SetLabel(0, Captions.T("Переводы Библии") + " · " + bibles);
        _kinds.SetLabel(1, Captions.T("Песенники") + " · " + songs);
        var shown = Shown;
        _status.Text = $"{Captions.T("включено")} {shown.Count(m => m.IsEnabled)} {Captions.T("из")} {shown.Count}";
        _list.Reload();
    }

    void Changed() { Refresh(); RosterChanged?.Invoke(); }

    void Toggle(int index)
    {
        var shown = Shown;
        if (index < 0 || index >= shown.Count) return;
        _store.SetModule(shown[index].Id, !shown[index].IsEnabled);
        Changed();
    }

    void SetAll(bool enabled)
    {
        foreach (var m in Shown) _store.SetModule(m.Id, enabled);
        Changed();
    }

    void Remove()
    {
        var shown = Shown;
        if (_selected is not { } i || i >= shown.Count) return;
        _store.RemoveModule(shown[i].Id);
        _selected = null;
        Changed();
    }

    void Move(int delta)
    {
        var shown = Shown;
        if (_selected is not { } i || i + delta < 0 || i + delta >= shown.Count) return;
        var a = _store.Settings.Modules.IndexOf(shown[i]); var b = _store.Settings.Modules.IndexOf(shown[i + delta]);
        (_store.Settings.Modules[a], _store.Settings.Modules[b]) = (_store.Settings.Modules[b], _store.Settings.Modules[a]);
        _selected = i + delta;
        Changed();
        _list.SetSelection(new[] { i + delta }, i + delta);
    }

    async void Add()
    {
        var top = TopLevel.GetTopLevel(SettingsWindow.Shared);
        if (top == null) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions { AllowMultiple = true, Title = Vb("TextMessages5", "Выберите каталог текстов Библии") });
        SettingsStore.ModuleProblem? problem = null;
        foreach (var f in files)
        {
            if (f.TryGetLocalPath() is not { } path) continue;
            // Модуль «Цитати з Біблії» — це тека з bibleqt.ini: беремо теку файла.
            var target = Path.GetFileName(path).Equals("bibleqt.ini", StringComparison.OrdinalIgnoreCase) ? Path.GetDirectoryName(path)! : path;
            if (_store.AddModule(target) is { } reason && reason != SettingsStore.ModuleProblem.AlreadyListed) problem ??= reason;
        }
        Changed();
        if (problem is { } p)
            Alert.Tell(Vb("TextMessages24", "Внимание"), p switch
            {
                SettingsStore.ModuleProblem.NotBibleQuote => Vb("TextMessages6", "В выбранном каталоге не найдены тексты формата \"Цитаты из Библии\""),
                SettingsStore.ModuleProblem.MySword => Vb("TextMessages38", "Не поддерживается"),
                _ => Vb("TextMessages38", "Не поддерживается"),
            });
    }

    public int RowCount => Shown.Count;
    public Row RowAt(int index)
    {
        var m = Shown[index];
        return new Row(m.Name, m.IsEnabled ? "☑" : "☐", m.Path) { SingleLine = true };
    }
}
