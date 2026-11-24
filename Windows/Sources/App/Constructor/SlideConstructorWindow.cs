// =============================================================================
//  SlideConstructorWindow.cs — «Конструктор слайда» (як NativeSlideConstructor на Mac)
// =============================================================================
//  Згори: «Новий», «Редактор:» (Біблія / Пісні — свої списки шаблонів),
//  «Шаблон:» (свої, далі авторські з Templates «за основу»), «Зберегти»,
//  «Зберегти як…», «Вилучити», «Тест анімації», «Затримка:», «Показати для:»
//  (сцена 1 / сцена 2). Ліворуч — об'єкти (+ − ⧉ ↑ ↓), фон і перехід; посередині —
//  полотно; праворуч — панелі властивостей. Правка йде в зал одразу (через 80
//  мс); закриття без збереження повертає зал до збереженого шаблону.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class SlideConstructorWindow : Window, IRowSource
{
    static SlideConstructorWindow? _shown;
    readonly AppState _state;
    readonly SlideConstructorModel _model;
    readonly ConstructorCanvas _canvas;
    readonly ConstructorPanels _panels;
    readonly RowList _objects;
    readonly LayoutPanel _root = new();
    readonly List<Control> _topBar = new();
    readonly PopupButton _scope, _template, _background, _transition;
    readonly MacSlider _delay = new() { Minimum = 0, Maximum = 3000, Width = 110, Height = 20, KnobSize = 18, Step = 30 };
    readonly BottomCaption _delayLabel = new() { FontSize = 11, Color = () => Palette.Label };
    readonly Segmented _sceneTabs;
    readonly List<PushButton> _listButtons = new();
    readonly BottomCaption _bottomNote = new() { FontSize = 10 };
    readonly BottomCaption _backgroundCaption = new() { FontSize = 11 }, _transitionCaption = new() { FontSize = 11 };
    readonly PushButton _save, _close;
    readonly WidthGrip _leftGrip = new(), _rightGrip = new();
    const string ScopeKey = "constructorForSongs", LeftWidthKey = "constructorLeftWidth", RightWidthKey = "constructorRightWidth";
    bool _unsavedShown, _closing;
    string _structure = "";
    IDisposable? _liveTimer;
    List<string> _backgroundFiles = new();

    static string T(string key, string fallback) => Captions.FormCaption(key, "SlideConstructorForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "SlideConstructorForm") is { Length: > 0 } hint ? hint : Captions.T(fallback);

    public static SlideConstructorWindow Open(AppState state)
    {
        if (_shown is { } open) { open.Activate(); return open; }
        var window = _shown = new SlideConstructorWindow(state);
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    bool ForSongs => _scope.SelectedIndex == 1;
    List<SlidePreset> ScopedPresets => _model.Library.PresetsFor(ForSongs);

    SlideConstructorWindow(AppState state)
    {
        _state = state;
        Title = Captions.FormCaption("SlideConstructorForm", "SlideConstructorForm", "Конструктор слайда");
        Width = 1240; Height = 780; MinWidth = 1120; MinHeight = 700;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        _model = new SlideConstructorModel(state.Presets);
        _canvas = new ConstructorCanvas(_model);
        _panels = new ConstructorPanels(_model, T, Hint);

        // Кнопки й підписи форми — 11 пт (NativeForm), списки й сегменти — 13.
        PushButton Button(string title, string hint, Action action)
        {
            var b = new PushButton(title) { Margin = 0.5, Pressed = action, FontSize = 11 };
            if (hint.Length > 0) ToolTip.SetTip(b, hint);
            return b;
        }
        BottomCaption Label(string text) => new() { Text = text, FontSize = 11, Color = () => Palette.Label };

        _topBar.Add(Button(Captions.T("Новый"), Hint("SBNewSheme", "Новый шаблон слайда"), () => _ = NewTemplate()));
        _topBar.Add(Label(Captions.T("Редактор:")));
        // Два редактори: Біблії й пісень, у кожного свій список шаблонів. Вибір пам'ятається.
        var remembered = Defaults.Has(ScopeKey) ? Defaults.Bool(ScopeKey) : state.Mode == WorkMode.Songs;
        _scope = new PopupButton(new[] { Captions.T("Библия"), Captions.T("Песни") }, remembered ? 1 : 0);
        ToolTip.SetTip(_scope, Captions.T("Два редактора: шаблоны для Библии и шаблоны для песен. В списке — только шаблоны открытого редактора; сохранённый уходит в зал для своего раздела"));
        _scope.Selected += index => { _ = ScopeChosen(); };
        _topBar.Add(_scope);
        _topBar.Add(Label(T("Label14", "Шаблон:")));
        _template = new PopupButton(new[] { "" });
        _template.Selected += index => { _ = TemplateChosen(); };
        _topBar.Add(_template);
        _topBar.Add(Button(Captions.T("Сохранить"), Hint("SBSaveSheme", "Сохранить шаблон"), SaveAndApply));
        _topBar.Add(Button(Captions.T("Сохранить как…"), Hint("SBAddSheme", "Сохранить шаблон с новым именем"), () => _ = SaveAs()));
        _topBar.Add(Button(Captions.T("Удалить"), Hint("SBDelSheme", "Удалить шаблон"), DeleteTemplate));
        _topBar.Add(Button(T("BBAnimation", "Тест анимации"), "", () => { _model.RunAnimationTest(); _canvas.Redraw(); }));
        _topBar.Add(Label(T("Label13", "Задержка:")));
        _delay.ValueChanged += v => { _model.TestDelay = v; _delayLabel.Text = DelayText; };
        _topBar.Add(_delay);
        _topBar.Add(_delayLabel);
        _topBar.Add(Label(T("RGVariantShow", "Отобразить для:")));
        _sceneTabs = new Segmented(new[] { T("RGVariantShow->Item0", "Сцена 1 (одного перевода)"), T("RGVariantShow->Item1", "Сцена 2 (двух переводов)") }, 13);
        _sceneTabs.Selected += i =>
        {
            _model.Scene = i == 1 ? SlideScheme.Variant.Dual : SlideScheme.Variant.Single;
            _canvas.Redraw();
            _panels.Rebuild();
            _objects?.Reload();
        };
        _topBar.Add(_sceneTabs);

        _objects = new RowList(new ListMetrics { LeadWidth = 28, Padding = new Thickness(4, 2, 6, 2), TextFontDelta = 0 }, 13) { Source = this, ContentInset = new Thickness(0) };
        _objects.SetUniformHeight(26);
        _objects.OnSelect = (_, active, cause) =>
        {
            if (cause == SelectCause.Code || active < 0 || active >= _model.Preset.Objects.Count) return;
            _model.Selection = _model.Preset.Objects[active].Id;
            _panels.Rebuild();
            _canvas.InvalidateVisual();
        };
        foreach (var (key, mark, hint, action) in new (string, string, string, Action)[]
        {
            ("SBObjAdd", "+", "Добавить объект", () => _ = AddObject()),
            ("SBObjDel", "−", "Удалить объект", () => { _model.DeleteSelected(); Refresh(); }),
            ("SBObjCopy", "⧉", "Скопировать объект", () => { _model.DuplicateSelected(); Refresh(); }),
            ("SBObjUp", "↑", "Переместить объект выше", () => { _model.MoveSelectedInList(-1); Refresh(); }),
            ("SBObjDown", "↓", "Переместить объект ниже", () => { _model.MoveSelectedInList(1); Refresh(); }),
        })
        {
            var b = Button(mark, Hint(key, hint), action);
            if (Form.Symbols.TryGetValue(mark, out var symbol)) { b.Symbol = symbol; b.Title = ""; }
            _listButtons.Add(b);
        }

        _backgroundCaption.Text = Captions.T("Фон:");
        _transitionCaption.Text = Captions.T("Переход:");
        _background = new PopupButton(new[] { T("TextMessages10", "Нет") });
        _background.Selected += index => { _ = BackgroundChosen(); };
        _transition = new PopupButton(Enum.GetValues<SlideStyle.Transition>().Select(t => Captions.T(t.Title())).ToList());
        _transition.Selected += i =>
        {
            var all = Enum.GetValues<SlideStyle.Transition>();
            if (i < 0 || i >= all.Length) return;
            _model.Preset.Transition = all[i];
            _model.Touch();
        };

        _leftGrip.OnDrag = delta => { Widths.Set(LeftWidthKey, _objects.Bounds.Width + delta, 220, 520); _root.InvalidateArrange(); };
        _leftGrip.OnReset = () => { Widths.Reset(LeftWidthKey); _root.InvalidateArrange(); };
        // Вправо — панелі вужчають.
        _rightGrip.OnDrag = delta => { Widths.Set(RightWidthKey, _panels.Bounds.Width - delta, 260, 560); _root.InvalidateArrange(); };
        _rightGrip.OnReset = () => { Widths.Reset(RightWidthKey); _root.InvalidateArrange(); };
        _panels.OnChange = () => { _canvas.Redraw(); _objects.Reload(); };
        _canvas.Edited += () => { _panels.Rebuild(); _objects.Reload(); RefreshCheap(); };

        _save = Button(Captions.T("Сохранить"), Hint("SBSaveSheme", "Сохранить шаблон"), SaveAndApply);
        _close = Button(T("BBOk", "Закрыть"), Hint("BBOk", "Закрыть редактирование анимации"), () => _ = RequestClose());

        foreach (Control c in _topBar.Concat(_listButtons).Concat(new Control[]
                 { _objects, _backgroundCaption, _background, _transitionCaption, _transition, _canvas, _panels, _leftGrip, _rightGrip, _bottomNote, _save, _close }))
            _root.Children.Add(c);
        _root.Layout = Arrange;
        Content = _root;

        _model.Attach(state.Schemes, state.Style);
        // Редактор відкривається на тому, що зараз у залі для свого розділу.
        _model.OpenScope(ForSongs, state.Presets.Preset(OutputKind.Screen, ForSongs));
        // Правка йде на проектор одразу — після 80 мс тиші.
        _model.Changed += () =>
        {
            _liveTimer?.Dispose();
            _liveTimer = DispatcherTimer.RunOnce(() => _state.PreviewPreset(_model.Preset.Copy()), TimeSpan.FromMilliseconds(80));
            Dispatcher.UIThread.Post(Refresh);
        };
        Closing += (_, e) =>
        {
            if (_closing) return;
            e.Cancel = true;
            _ = RequestClose();
        };
        KeyDown += (_, e) =>
        {
            if (e.Key == Key.S && e.KeyModifiers == KeyModifiers.Control) { SaveAndApply(); e.Handled = true; }
        };
        Refresh();
    }

    string DelayText => $"{(int)_model.TestDelay} {T("Label10", "мс")}";

    // --- Розкладка (за NativeSlideConstructor.layout) ------------------------------------------

    void Arrange(Size size)
    {
        const double gap = 8;
        // Верхня смуга: рамки підряд через 6; ужимається лише список шаблонів (не менше 150).
        double Width(Control c) => c switch
        {
            PushButton b => Math.Ceiling(UiFont.Width(b.Title, 11) + (b.Symbol != null ? 18 : 0) + 22),
            BottomCaption l => Math.Ceiling(UiFont.Width(l.Text, 11) + 2),
            PopupButton p when p == _scope => 70,
            PopupButton => 0,
            MacSlider s => s.Width,
            Segmented => 0,
            _ => 60,
        };
        // Список шаблонів займає, що лишилось (не менше 150); тісно — ужимаються підписи сегментів.
        var fixedWidth = _topBar.Sum(Width) + 6 * (_topBar.Count - 1);
        var room = size.Width - gap * 2 - fixedWidth;
        var segmentWidth = Math.Max(160, Math.Min(330, room - 150));
        var templateWidth = Math.Max(150, room - segmentWidth);
        var x = gap;
        foreach (var c in _topBar)
        {
            var w = c == _template ? templateWidth : c == _sceneTabs ? segmentWidth : Width(c);
            var h = c is BottomCaption ? 16 : 22;
            _root.Place(c, new Rect(x, gap + (28 - h) / 2, w, h));
            x += w + 6;
        }
        var top = gap + 28 + gap;
        var bottom = size.Height - 44;
        var leftWidth = Widths.Value(LeftWidthKey, 300, 220, 520);
        var bx = gap;
        foreach (var b in _listButtons) { _root.Place(b, new Rect(bx, top + 2, 30, 22)); bx += 36; }
        var listTop = top + 26 + 4;
        var listHeight = Math.Max(0, bottom - (top + 26) - 72);
        _root.Place(_objects, new Rect(gap, listTop, leftWidth, listHeight));
        // Підписи списків унизу: без них «Ні» й «Розчинення» ні про що не кажуть.
        const double captionWidth = 78;
        var y = listTop + listHeight + 6;
        _root.Place(_backgroundCaption, new Rect(gap, y + 4, captionWidth, 16));
        _root.Place(_background, new Rect(gap + captionWidth, y, leftWidth - captionWidth, 24));
        y += 24 + 6;
        _root.Place(_transitionCaption, new Rect(gap, y + 4, captionWidth, 16));
        _root.Place(_transition, new Rect(gap + captionWidth, y, leftWidth - captionWidth, 24));

        var rightWidth = Widths.Value(RightWidthKey, 330, 260, 560);
        var panelsLeft = size.Width - rightWidth - gap;
        _root.Place(_panels, new Rect(panelsLeft, top, rightWidth, Math.Max(0, bottom - top)));
        const double grip = 7;
        _root.Place(_leftGrip, new Rect(gap + leftWidth, top, grip, Math.Max(0, bottom - top)));
        _root.Place(_rightGrip, new Rect(panelsLeft - gap - grip, top, grip, Math.Max(0, bottom - top)));
        var centreLeft = gap + leftWidth + grip + gap;
        _root.Place(_canvas, new Rect(centreLeft, top, Math.Max(0, panelsLeft - gap - grip - gap - centreLeft), Math.Max(0, bottom - top)));

        _root.Place(_bottomNote, new Rect(gap, size.Height - 34, size.Width - 160 - 230, 16));
        _root.Place(_close, new Rect(size.Width - gap - 110, size.Height - 38, 110, 24));
        _root.Place(_save, new Rect(size.Width - gap - 110 - 8 - 120, size.Height - 38, 120, 24));
    }

    // --- Список об'єктів ---------------------------------------------------------------------

    public int RowCount => _model.Preset.Objects.Count;

    public Row RowAt(int index)
    {
        var obj = _model.Preset.Objects[index];
        var visible = SlideConstructorModel.Values(obj, _model.Scene).IsVisible;
        return new Row(obj.Name.Length == 0 ? obj.Kind.Title() : obj.Name, visible ? "●" : "○")
        {
            SingleLine = true, TextColor = visible ? null : Palette.SecondaryLabel,
        };
    }

    // --- Дії ----------------------------------------------------------------------------------

    async Task AddObject()
    {
        var kinds = Enum.GetValues<SlideObjectKind>();
        var chosen = await ChoiceSheet.Ask(this, Hint("SBAddObj", "Добавить объект"), kinds.Select(k => k.Title()).ToList());
        if (chosen is not { } index || index < 0 || index >= kinds.Length) return;
        _model.Add(kinds[index]);
        Refresh();
    }

    async Task ScopeChosen()
    {
        Defaults.Set(ScopeKey, ForSongs);
        // Перехід в інший редактор — як зміна шаблону: спершу питання про незбережене.
        if (_model.IsDirty)
        {
            switch (await AskAboutChanges())
            {
                case Answer.Save: SaveAndApply(!ForSongs); break;
                case Answer.Cancel:
                    _scope.SelectedIndex = ForSongs ? 0 : 1;
                    Defaults.Set(ScopeKey, ForSongs);
                    return;
            }
        }
        _model.OpenScope(ForSongs, _state.Presets.Preset(OutputKind.Screen, ForSongs));
        Refresh();
    }

    void SaveAndApply() => SaveAndApply(null);

    void SaveAndApply(bool? wasScope)
    {
        var songs = wasScope ?? ForSongs;
        _model.Preset.ForSongs = songs;
        _model.Save();
        _state.ReloadPresets();
        _state.ApplyPreset(_model.Preset, songs);
        Refresh();
    }

    async Task TemplateChosen()
    {
        // Перший пункт — незбережений шаблон, він і так відкритий.
        if (_unsavedShown && _template.SelectedIndex == 0) return;
        var index = _template.SelectedIndex - (_unsavedShown ? 1 : 0);
        var presets = ScopedPresets;
        var schemes = _model.Schemes?.Templates ?? (IReadOnlyList<SchemeLibrary.Template>)Array.Empty<SchemeLibrary.Template>();
        if (index < 0) return;
        // Той самий шаблон, що відкритий, — міняти нічого й питати нема про що.
        if (index < presets.Count && presets[index].Id == _model.Preset.Id) return;
        if (_model.IsDirty)
        {
            switch (await AskAboutChanges())
            {
                case Answer.Save: SaveAndApply(); break;
                case Answer.Cancel: _structure = ""; Refresh(); return;
            }
        }
        if (index < presets.Count) _model.Load(presets[index]);
        else
        {
            var position = index - presets.Count;
            if (position < 0 || position >= schemes.Count) return;
            _model.ImportScheme(schemes[position]);
            _model.Preset.ForSongs = ForSongs;
        }
        Refresh();
    }

    async Task BackgroundChosen()
    {
        var files = _backgroundFiles;
        var index = _background.SelectedIndex;
        var back = _model.Preset.Back;
        if (index == 0) back.ImagePath = null;
        else if (index == files.Count + 1)
        {
            // Останній пункт — «Вибрати файл…».
            if (StorageProvider is not { } storage) return;
            var picked = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = T("Label38", "Имя файла фона:"), AllowMultiple = false, FileTypeFilter = new[] { FilePickerFileTypes.ImageAll },
                SuggestedStartLocation = _model.SourceFolder is { } folder ? await storage.TryGetFolderFromPathAsync(folder) : null,
            });
            if (picked.Count == 0 || picked[0].TryGetLocalPath() is not { } path) { _structure = ""; Refresh(); return; }
            back.ImagePath = path;
        }
        else if (index - 1 >= 0 && index - 1 < files.Count) back.ImagePath = files[index - 1];
        _model.Preset.Back = back;
        _model.Touch();
        _canvas.Redraw();
    }

    async Task NewTemplate()
    {
        if (_model.IsDirty)
        {
            switch (await AskAboutChanges())
            {
                case Answer.Save: SaveAndApply(); break;
                case Answer.Cancel: return;
            }
        }
        if (await AskName(T("TextMessages12", "Создание шаблона"), "") is not { } name) return;
        _model.MakeNew(name, ForSongs);
        Refresh();
    }

    async Task SaveAs()
    {
        if (await AskName(T("TextMessages0", "Сохранение шаблона"), _model.Preset.Name) is not { } name) return;
        // Збіг імен — не помилка, але переписати шаблон мовчки не можна.
        if (_model.NameIsTaken(name))
        {
            var done = new TaskCompletionSource<int>();
            Alert.Ask(T("TextMessages0", "Сохранение шаблона"), Captions.T("Шаблон с таким именем уже есть. Переписать?"),
                      new[] { Captions.T("Да"), Captions.T("Нет") }, answer => done.TrySetResult(answer));
            if (await done.Task != 0) return;
        }
        _model.Preset.ForSongs = ForSongs;
        _model.SaveAs(name);
        _state.ReloadPresets();
        _state.ApplyPreset(_model.Preset, ForSongs);
        Refresh();
    }

    void DeleteTemplate()
    {
        Alert.Ask(T("TextMessages14", "Удаление шаблона слайда"), T("TextMessages13", "Действительно удалить шаблон слайда:") + " " + _model.Preset.Name,
                  new[] { Captions.T("Да"), Captions.T("Нет") }, answer =>
                  {
                      if (answer != 0) return;
                      _model.DeleteCurrent();
                      Refresh();
                  });
    }

    enum Answer { Save, Discard, Cancel }

    Task<Answer> AskAboutChanges()
    {
        var done = new TaskCompletionSource<Answer>();
        Alert.Ask(T("TextMessages11", "Шаблон изменен. Сохранить?"), "",
                  new[] { Captions.T("Сохранить"), Captions.T("Не сохранять"), Captions.T("Отмена") },
                  answer => done.TrySetResult(answer switch { 0 => Answer.Save, 1 => Answer.Discard, _ => Answer.Cancel }));
        return done.Task;
    }

    async Task<string?> AskName(string title, string value)
    {
        var name = (await SongPrompt.Input(title, T("TextMessages1", "Введите имя нового шаблона"), value))?.Trim();
        return string.IsNullOrEmpty(name) ? null : name;
    }

    /// Закрити: незбережене — питання; зал повертається до збереженого шаблону.
    async Task RequestClose()
    {
        if (_model.IsDirty)
        {
            switch (await AskAboutChanges())
            {
                case Answer.Save: SaveAndApply(); break;
                case Answer.Cancel: return;
            }
        }
        _liveTimer?.Dispose();
        _state.PreviewPreset(null);
        _closing = true;
        Close();
    }

    // --- Оновлення ----------------------------------------------------------------------------

    void RefreshCheap()
    {
        _delayLabel.Text = DelayText;
        _canvas.Sample = Sample;
        var folder = PresetLibrary.DefaultFolder;
        _bottomNote.Text = _model.IsDirty ? Captions.T("Есть несохранённые правки. Шаблоны лежат в %s", folder) : Captions.T("Шаблоны лежат в %s", folder);
    }

    void Refresh()
    {
        var o = _model.SelectedObject;
        var fingerprint = string.Join("|", _model.Preset.Id, string.Join(",", _model.Preset.Objects.Select(x => x.Id)), o?.Id, o?.Kind, _model.Scene,
                                      string.Join(",", _model.Library.Presets.Select(p => p.Id)), _model.Preset.Back.ImagePath, _model.Preset.Transition,
                                      o?.ImagePath, o?.MaskPath, ForSongs);
        RefreshCheap();
        _canvas.Redraw();
        // Змінилось лише значення: поля стоять, оновлюємо числа в них.
        if (fingerprint == _structure)
        {
            _panels.RefreshValues();
            _objects.Reload();
            return;
        }
        _structure = fingerprint;
        // Шаблони: свої, далі авторські (лише за основу).
        var scoped = ScopedPresets;
        var titles = scoped.Select(p => Captions.T(p.Name)).ToList();
        titles.AddRange((_model.Schemes?.Templates ?? (IReadOnlyList<SchemeLibrary.Template>)Array.Empty<SchemeLibrary.Template>())
                        .Select(t => Captions.T("Из папки Templates: ") + t.Name));
        var at = scoped.FindIndex(p => p.Id == _model.Preset.Id);
        _unsavedShown = at < 0;
        // Новий, ще не збережений шаблон показуємо самого, а не перший зі списку.
        if (_unsavedShown) titles.Insert(0, Captions.T(_model.Preset.Name) + " " + Captions.T("(не сохранён)"));
        _template.SetItems(titles.Count == 0 ? new List<string> { "" } : titles);
        _template.SelectedIndex = _unsavedShown ? 0 : at;

        _backgroundFiles = _model.BackgroundFiles;
        var backgrounds = new List<string> { T("TextMessages10", "Нет") };
        backgrounds.AddRange(_backgroundFiles.Select(Path.GetFileName).OfType<string>());
        backgrounds.Add(Captions.T("Выбрать файл…"));
        var chosen = _model.Preset.Back.ImagePath is { } path ? _backgroundFiles.FindIndex(f => string.Equals(f, path, StringComparison.OrdinalIgnoreCase)) + 1 : 0;
        _background.SetItems(backgrounds);
        _background.SelectedIndex = Math.Max(0, chosen);
        _transition.SelectedIndex = Math.Max(0, Array.IndexOf(Enum.GetValues<SlideStyle.Transition>(), _model.Preset.Transition));

        _panels.Rebuild();
        _objects.Reload();
        _root.InvalidateArrange();
    }

    /// Зразок тексту: що зараз на вкладці (Біблія чи пісня) або приклад.
    ConstructorSample Sample
    {
        get
        {
            var slide = _state.Slide;
            if (ForSongs)
            {
                var live = _state.Mode == WorkMode.Songs && slide.MainText.Length > 0;
                var reference = live && slide.Reference.Length > 0 ? slide.Reference : Captions.T("Куплет");
                return new ConstructorSample
                {
                    MainText = live ? slide.MainText : "Хвали, душе моя, Господа!\nХвалитиму Господа, поки живу,\nспіватиму Богові моєму, поки я є.",
                    SecondaryText = "", Reference = reference, PrimaryReference = reference, SecondaryReference = "",
                    SongTitle = _state.SelectedSong?.Title ?? Captions.T("Название песни"),
                };
            }
            var bibleLive = _state.Mode == WorkMode.Bible && slide.MainText.Length > 0;
            var bibleReference = bibleLive && slide.Reference.Length > 0 ? slide.Reference : "Пс. 118:105";
            var second = _state.SecondaryModuleIDs.Count > 0 ? _state.Module(_state.SecondaryModuleIDs[0]) : null;
            return new ConstructorSample
            {
                MainText = bibleLive ? slide.MainText : "Для моєї ноги Твоє слово світильник, то світло для стежки моєї.",
                SecondaryText = (bibleLive ? slide.SecondaryTexts.FirstOrDefault() : null) ?? "Thy word is a lamp unto my feet, and a light unto my path.",
                Reference = bibleReference, PrimaryReference = bibleReference, SecondaryReference = bibleReference,
                ModuleNameFirst = _state.PrimaryModule?.Info.Name ?? "", ModuleShortNameFirst = _state.PrimaryModule?.Info.ShortName ?? "",
                ModuleNameSecond = second?.Info.Name ?? "", ModuleShortNameSecond = second?.Info.ShortName ?? "",
                SongTitle = Captions.T("Название песни"),
            };
        }
    }
}

/// Вибір одного з переліку у вікні з «Ок» і «Відміна» (NSAlert зі списком на Mac).
public static class ChoiceSheet
{
    public static Task<int?> Ask(Window owner, string title, IReadOnlyList<string> items)
    {
        var done = new TaskCompletionSource<int?>();
        var window = new Window
        {
            Title = "", Width = 360, Height = 150, CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Background = Palette.Brush(Palette.WindowBackground),
        };
        var heading = new BottomCaption { Text = title, FontSize = 13, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        var popup = new PopupButton(items.Count == 0 ? new[] { "" } : items);
        int? result = null;
        var ok = new PushButton(Captions.T("Ок")) { Prominent = true, Pressed = () => { result = popup.SelectedIndex; window.Close(); } };
        var cancel = new PushButton(Captions.T("Отмена")) { Pressed = window.Close };
        var panel = new LayoutPanel();
        foreach (Control c in new Control[] { heading, popup, ok, cancel }) panel.Children.Add(c);
        panel.Layout = size =>
        {
            panel.Place(heading, new Rect(20, 16, size.Width - 40, 18));
            panel.Place(popup, new Rect(20, 46, 260, 24));
            var w = Math.Max(90, ok.FittingWidth + 24);
            panel.Place(ok, new Rect(size.Width - 16 - w, size.Height - 40, w, 24));
            var c = Math.Max(90, cancel.FittingWidth + 24);
            panel.Place(cancel, new Rect(size.Width - 16 - w - 8 - c, size.Height - 40, c, 24));
        };
        window.Content = panel;
        window.Closed += (_, _) => done.TrySetResult(result);
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) window.Close(); else if (e.Key == Key.Enter) { result = popup.SelectedIndex; window.Close(); } };
        window.ShowDialog(owner);
        return done.Task;
    }
}
