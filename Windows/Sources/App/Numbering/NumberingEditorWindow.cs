// =============================================================================
//  NumberingEditorWindow.cs — «Редактор невідповідностей нумерації перекладів Біблії» (N40)
// =============================================================================
//  За NumberingEditorWindow.swift і NativeNumberingEditor.swift Mac 1.3.9.
//  Окреме вікно, не аркуш: поки правлять нумерацію, у головному вікні далі гортають
//  вірші. Три вкладки: «Модулі» — якому перекладу який стандарт нумерації,
//  «Правила» — самі правила перерахунку, «Перевірка» — жива звірка вірша у двох
//  перекладах. Правки йдуть у свою копію бази, файл програми лише читається.
//  Хрестик — те саме, що «Скасувати». Розміри — зі знімка Mac (1060×720, найменше 1000×660).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class NumberingEditorWindow : Window, ISnapshotWork
{
    static NumberingEditorWindow? _shown;

    public static NumberingEditorWindow Open(AppState state)
    {
        if (_shown is { } open)
        {
            // Відкрили знову — база на диску могла змінитися (і нашою ж кнопкою «Повернути все як в автора»).
            open._model.Reopen();
            open.Activate();
            return open;
        }
        var window = _shown = new NumberingEditorWindow(state);
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    static string T(string text, params object[] args) => Captions.T(text, args);
    static string Main(string key, string fallback) => Captions.FormCaption(key, "MainForm", fallback).Replace("&", "");
    static string Settings(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback).Replace("&", "");
    static string Song(string key, string fallback) => Captions.FormCaption(key, "SongColorsetForm", fallback).Replace("&", "");
    static string SongHint(string key, string fallback) => Captions.FormHint(key, "SongColorsetForm") ?? Captions.T(fallback);

    readonly AppState _state;
    NumberingEditorModel _model;
    readonly LayoutPanel _panel = new();
    readonly DispatcherTimer _timer;
    bool _finishing;

    // Панель і вкладки.
    readonly PushButton _saveNow, _reset, _reveal;
    readonly BottomCaption _status, _counter, _bottomNote;
    readonly Segmented _tabs;
    // «Модулі».
    readonly PushButton _detectAll, _detectOne, _restoreStandard;
    readonly MacCheckBox _onlyUnassigned;
    readonly BottomCaption _assigned;
    // «Правила».
    readonly BottomCaption _fromLabel, _toLabel, _pairNote;
    readonly PopupButton _pairFrom, _pairTo;
    readonly PushButton _swapPair, _addRule, _editRule, _removeRule, _mirrorRule, _restoreRule;
    readonly MacCheckBox _onlyMine;
    // «Перевірка».
    readonly BottomCaption _moduleLabel, _bookLabel, _chapterLabel, _verseLabel, _explanation, _reportLine;
    readonly PopupButton _primary, _secondary, _book;
    readonly PushButton _swapModules, _verify;
    readonly FormField _address = new(12), _chapter = new(11, rightAligned: true), _verse = new(11, rightAligned: true);
    readonly VerseColumn _left = new(), _right = new();
    // Таблиця й кнопки.
    readonly GridTable _table = new();
    readonly Rows _rows;
    readonly PushButton _cancel, _ok;

    NumberingEditorWindow(AppState state)
    {
        _state = state;
        _model = new NumberingEditorModel(state);
        _rows = new Rows(this);

        Title = Captions.Caption("N40", "Редактор несоответствий нумерации переводов Библии");
        Width = 1060; Height = 720;
        MinWidth = 1000; MinHeight = 660;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += () => Background = Palette.Brush(Palette.WindowBackground);

        // Панель: зберегти зараз, повернути як в автора, показати свою копію, стан.
        _saveNow = Tool("square.and.arrow.down", T("Сохранить сейчас"), () =>
        {
            if (_model.Save() is { } failure) _model.Status = T("не записалось: %s", failure);
            Refresh();
        });
        _reset = Tool("arrow.counterclockwise", T("Вернуть всё как у автора"), AskReset);
        _reveal = Tool("folder.fill", T("Показать свою копию в Проводнике"), () => _model.RevealOwnCopy(), () => Color.FromRgb(0x5A, 0xAA, 0xE8));
        _status = Caption("");

        _tabs = new Segmented(new[] { Settings("TSModules", "Модули"), T("Правила"), T("Проверка") });
        _tabs.Selected += index =>
        {
            _model.CurrentTab = (NumberingEditorModel.Tab)Math.Clamp(index, 0, 2);
            RebuildColumns();
            Refresh();
        };
        _counter = Caption("");

        // «Модулі».
        _detectAll = Tool("sparkles", T("Определить стандарт для всех модулей"), () => _model.DetectAll(), () => Color.FromRgb(0xE8, 0xB4, 0x1C));
        _detectOne = Tool("sparkle", T("Определить для выбранного"), () => _model.DetectSelected());
        _restoreStandard = Tool("arrow.counterclockwise", T("Вернуть авторское назначение"), () =>
        {
            if (_model.SelectedModule is { } id) { _model.RestoreAuthorStandard(id); Refresh(); }
        });
        _onlyUnassigned = new MacCheckBox(T("Показывать только неназначенные"), 11);
        _onlyUnassigned.Toggled += on => { _model.OnlyUnassigned = on; Refresh(); };
        _assigned = Caption("");

        // «Правила».
        _fromLabel = Caption(T("Из:"));
        _toLabel = Caption(T("В:"));
        _pairFrom = StandardPopup(code => { _model.PairFrom = code; Refresh(); });
        _pairTo = StandardPopup(code => { _model.PairTo = code; Refresh(); });
        _swapPair = Tool("arrow.left.arrow.right", T("Поменять местами"), () =>
        {
            (_model.PairFrom, _model.PairTo) = (_model.PairTo, _model.PairFrom);
            Refresh();
        });
        _addRule = Tool("plus", SongHint("PngSBAdd", "Добавить правило"), () => EditRule(_model.NewDraft()));
        _editRule = Tool("pencil", SongHint("PngSBEdit", "Изменить правило"), () =>
        {
            if (_model.Rule(_model.SelectedRule) is { } rule) EditRule(NumberingEditorModel.DraftFrom(rule));
        });
        _removeRule = Tool("minus", SongHint("PngSBRem", "Удалить правило"), () =>
        {
            if (_model.SelectedRule is { } id) { _model.RemoveRule(id); Refresh(); }
        });
        _mirrorRule = Tool("doc.on.doc", T("Создать зеркальное правило в обратной паре"), () =>
        {
            if (_model.Rule(_model.SelectedRule) is { } rule) EditRule(NumberingEditorModel.MirrorDraft(rule));
        });
        _restoreRule = Tool("arrow.counterclockwise", T("Вернуть авторскую строку"), () =>
        {
            if (_model.SelectedRule is { } id) { _model.RestoreAuthorRule(id); Refresh(); }
        });
        _onlyMine = new MacCheckBox(T("Только свои строки"), 11);
        _onlyMine.Toggled += on => { _model.OnlyMine = on; Refresh(); };
        _pairNote = Caption("");

        // «Перевірка».
        _moduleLabel = Caption(Main("Label3D4", "Модуль:"));
        _primary = ModulePopup(id => { _model.CheckPrimary = id; Refresh(); });
        _secondary = ModulePopup(id => { _model.CheckSecondary = id; Refresh(); });
        _swapModules = Tool("arrow.left.arrow.right", T("Поменять переводы местами"), () =>
        {
            (_model.CheckPrimary, _model.CheckSecondary) = (_model.CheckSecondary, _model.CheckPrimary);
            Refresh();
        });
        ToolTip.SetTip(_address, Captions.FormHint("EFastInput", "MainForm") ?? T("Быстрый выбор вводом в формате: [номер Книги] Книга Глава Стих [Стих_по]"));
        _address.OnSubmit = text => { _model.AddressInput = text; _model.ApplyAddressInput(); Refresh(); };
        _bookLabel = Caption(Main("Label8", "Книга:"));
        _book = new PopupButton(_model.Books.Select(b => b.Name)) { FontSize = 13, ArrowInset = 10 };
        _book.Selected += index =>
        {
            if (index < 0 || index >= _model.Books.Count) return;
            _model.CheckBook = _model.Books[index].Number;
            _model.RefreshAddressInput();
            Refresh();
        };
        _chapterLabel = Caption(Main("Label1", "Глава:"));
        _verseLabel = Caption(Main("Label3", "Стих:"));
        _chapter.OnSubmit = text => SetNumber(text, value => _model.CheckChapter = value);
        _chapter.OnFocus = focused => { if (!focused) SetNumber(_chapter.Text, value => _model.CheckChapter = value); };
        _verse.OnSubmit = text => SetNumber(text, value => _model.CheckVerse = value);
        _verse.OnFocus = focused => { if (!focused) SetNumber(_verse.Text, value => _model.CheckVerse = value); };
        _verify = new PushButton(T("Сверить книгу целиком")) { FontSize = 11, Margin = 0.5, Pressed = () => { _model.VerifyBook(); Refresh(); } };
        _explanation = Caption("");
        _reportLine = Caption("");

        // Таблиця.
        _table.Source = _rows;
        _table.RowHeight = 22;
        _table.CellTop = 0.5;
        _table.ClipCells = true;
        _table.OnSelect = row =>
        {
            if (_model.CurrentTab == NumberingEditorModel.Tab.Modules)
            {
                var list = _model.VisibleModuleRows;
                if (row >= 0 && row < list.Count) _model.SelectedModule = list[row].Id;
            }
            else if (_model.CurrentTab == NumberingEditorModel.Tab.Rules)
            {
                var list = _model.RuleRows;
                if (row >= 0 && row < list.Count) _model.SelectedRule = list[row].Id;
            }
        };
        _table.OnActivate = row =>
        {
            if (_model.CurrentTab == NumberingEditorModel.Tab.Rules && _model.Rule(_model.SelectedRule) is { } rule)
                EditRule(NumberingEditorModel.DraftFrom(rule));
        };
        _table.OnChoice = (row, column, index) =>
        {
            var list = _model.VisibleModuleRows;
            if (row < 0 || row >= list.Count) return;
            var codes = new[] { "" }.Concat(_model.StandardCodes).ToList();
            _model.SetStandard(index >= 0 && index < codes.Count ? codes[index] : "", list[row].Id);
            Refresh();
        };

        _bottomNote = Caption("");
        _cancel = new PushButton(Song("BBCancel", "Отменить")) { FontSize = 11, Pressed = () => Finish(false) };
        ToolTip.SetTip(_cancel, SongHint("BBCancel", "Не сохранять"));
        _ok = new PushButton(Song("BBOk", "Ок")) { FontSize = 11, Prominent = true, Pressed = () => Finish(true) };
        ToolTip.SetTip(_ok, SongHint("BBOk", "Сохранить"));

        foreach (Control c in new Control[]
                 {
                     _saveNow, _reset, _reveal, _status, _tabs, _counter,
                     _detectAll, _detectOne, _restoreStandard, _onlyUnassigned, _assigned,
                     _fromLabel, _pairFrom, _toLabel, _pairTo, _swapPair, _addRule, _editRule, _removeRule, _mirrorRule, _restoreRule, _onlyMine, _pairNote,
                     _moduleLabel, _primary, _secondary, _swapModules, _address, _bookLabel, _book, _chapterLabel, _chapter, _verseLabel, _verse, _verify,
                     _table, _left, _right, _explanation, _reportLine, _bottomNote, _cancel, _ok,
                 })
            _panel.Children.Add(c);
        _panel.Layout = Arrange;
        Content = _panel;

        RebuildColumns();
        _model.Changed += Refresh;
        Refresh();
        // Частину роботи модель робить осторонь (визначення, звірка, читання розділів) —
        // як на Mac, раз на пів секунди перепитуємо.
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(500), DispatcherPriority.Background, (_, _) => Refresh());
        _timer.Start();

        KeyDown += (_, e) =>
        {
            if (e.Key == Key.Escape) { Finish(false); e.Handled = true; }
            else if (e.Key == Key.Enter && !_address.IsFocusedField && !_chapter.IsFocusedField && !_verse.IsFocusedField) { Finish(true); e.Handled = true; }
        };
        // Хрестик — те саме, що «Скасувати»: знімок повертається цілком.
        Closing += (_, _) => { if (!_finishing) _model.Revert(); };
        // Бібліотеку перечитали (інша тека модулів, імпорт), поки вікно відкрите, — переклади
        // й книги в списках беремо наново (на Mac вікно лишалося зі старими до повторного відкриття).
        var library = Signals.Shared.Subscribe(Signals.Kind.Library, () => { if (!_model.IsDirty) ResetModel(); });
        Closed += (_, _) => { _timer.Stop(); _model.Changed -= Refresh; library.Dispose(); };
    }

    /// Модель наново — за поточною бібліотекою.
    void ResetModel()
    {
        _model.Changed -= Refresh;
        _model = new NumberingEditorModel(_state);
        _model.Changed += Refresh;
        _book.SetItems(_model.Books.Select(b => b.Name));
        _primary.SetItems(_model.Modules.Select(m => m.Name));
        _secondary.SetItems(_model.Modules.Select(m => m.Name));
        _tabs.SelectedIndex = 0;
        RebuildColumns();
        Refresh();
    }

    // ── Перевірка без екрана: `--numbering "крок;крок…"` перед знімком ──────
    //  tab=0..2 · row=N · standard=рядок|пункт · detect · detectone · restore · only ·
    //  pair=ru>en · swap · add=OV|книга|розділ|вірш|зсув · remove · restorerule · mine ·
    //  address=Пс 9:21 · chapter=N · verse=N · verify · save · reset · cancel.
    //  Кожен крок чекає, доки фонова робота попереднього скінчиться.

    Queue<string>? _steps;
    bool Busy => !_model.IsLoaded || _model.IsDetecting || _model.IsMatching || _model.IsVerifying;

    /// Знімок питає це раз на кілька десятків мілісекунд — тут же й іде наступний
    /// крок, коли фонова робота попереднього скінчилась (таймери без екрана ненадійні).
    public bool IsWorking
    {
        get
        {
            if (_steps is { Count: > 0 } && !Busy) RunStep(_steps.Dequeue());
            return Busy || (_steps?.Count ?? 0) > 0;
        }
    }

    public void Begin(string[] args)
    {
        // Знімок будує вікно до того, як дочиталася бібліотека, — модель наново.
        ResetModel();
        var at = Array.IndexOf(args, "--numbering");
        _steps = new Queue<string>(at >= 0 && at + 1 < args.Length ? args[at + 1].Split(';', StringSplitOptions.RemoveEmptyEntries) : Array.Empty<string>());
    }

    void RunStep(string step)
    {
        var eq = step.IndexOf('=');
        var verb = eq < 0 ? step : step[..eq];
        var arg = eq < 0 ? "" : step[(eq + 1)..];
        switch (verb)
        {
            case "tab": _tabs.SelectedIndex = int.Parse(arg); _model.CurrentTab = (NumberingEditorModel.Tab)int.Parse(arg); RebuildColumns(); break;
            case "row": _table.Select(int.Parse(arg)); _table.OnSelect?.Invoke(int.Parse(arg)); break;
            case "standard":
                var parts = arg.Split('|');
                _table.OnChoice?.Invoke(int.Parse(parts[0]), 2, int.Parse(parts[1]));
                break;
            case "detect": _detectAll.Pressed?.Invoke(); break;
            case "detectone": _detectOne.Pressed?.Invoke(); break;
            case "restore": _restoreStandard.Pressed?.Invoke(); break;
            case "only": _onlyUnassigned.IsChecked = !_onlyUnassigned.IsChecked; _model.OnlyUnassigned = _onlyUnassigned.IsChecked; break;
            case "pair":
                var pair = arg.Split('>');
                _model.PairFrom = pair[0]; _model.PairTo = pair[1];
                break;
            case "swap": _swapPair.Pressed?.Invoke(); break;
            case "add":
            {
                var a = arg.Split('|');
                var draft = _model.NewDraft();
                draft.Kind = NumberingRuleKinds.FromRaw(a[0]) ?? NumberingRuleKind.OffsetVerse;
                draft.Book = int.Parse(a[1]); draft.ChapterBegin = int.Parse(a[2]); draft.VerseBegin = int.Parse(a[3]); draft.VerseTo = int.Parse(a[4]);
                if (_model.Commit(draft) is { } complaint) Console.WriteLine($"  правило не прийнято: {complaint}");
                break;
            }
            case "remove": _removeRule.Pressed?.Invoke(); break;
            case "restorerule": _restoreRule.Pressed?.Invoke(); break;
            case "mine": _onlyMine.IsChecked = !_onlyMine.IsChecked; _model.OnlyMine = _onlyMine.IsChecked; break;
            case "address": _model.AddressInput = arg; _model.ApplyAddressInput(); break;
            case "chapter": _model.CheckChapter = int.Parse(arg); _model.RefreshAddressInput(); break;
            case "verse": _model.CheckVerse = int.Parse(arg); _model.RefreshAddressInput(); break;
            case "verify": _verify.Pressed?.Invoke(); break;
            case "save": _saveNow.Pressed?.Invoke(); break;
            case "reset": _model.DropOwnCopy(); break;
            case "cancel": _model.Revert(); break;
            default: Console.WriteLine($"  крок «{step}» невідомий"); break;
        }
        Refresh();
        Describe(step);
    }

    void Describe(string step)
    {
        Console.WriteLine($"  нумерація [{step}]: вкладка {_model.CurrentTab}, модулів {_model.ModuleRows.Count} (призначено {_model.AssignedCount}), " +
                          $"пара {_model.PairFrom}>{_model.PairTo} правил {_model.RuleRows.Count}, своїх {_model.OwnRowCount}, змінено {_model.IsDirty}, " +
                          $"стан «{_model.Status}», джерело «{_model.SourceNote}»");
        if (_model.CurrentTab == NumberingEditorModel.Tab.Check)
            Console.WriteLine($"    звірка: {_explanation.Text} | {_reportLine.Text}");
        if (_model.CurrentTab == NumberingEditorModel.Tab.Modules)
            foreach (var row in _model.VisibleModuleRows.Take(8))
                Console.WriteLine($"    {row.Id}: «{row.Standard}» {NumberingEditorModel.Title(row.Origin)}, {row.Match.Kind} {row.Match.Hits}/{row.Match.Total} {row.Match.Text}");
    }

    // ── Збирання ────────────────────────────────────────────────────────────

    static BottomCaption Caption(string text) => new(text) { FontSize = 11, Color = () => Palette.SecondaryLabel };

    static PushButton Tool(string symbol, string hint, Action? action, Func<Color>? tint = null)
    {
        var button = new PushButton("", symbol) { Margin = 0.5, TitleTint = tint, TintsWhenDisabled = tint != null };
        if (action != null) button.Pressed = action; else button.IsEnabled = false;
        ToolTip.SetTip(button, hint);
        return button;
    }

    PopupButton StandardPopup(Action<string> apply)
    {
        var popup = new PopupButton(_model.StandardCodes.Select(NumberingEditorModel.StandardTitle)) { FontSize = 13, ArrowInset = 10 };
        popup.Selected += index =>
        {
            var codes = _model.StandardCodes;
            apply(index >= 0 && index < codes.Count ? codes[index] : "");
        };
        return popup;
    }

    PopupButton ModulePopup(Action<string> apply)
    {
        var popup = new PopupButton(_model.Modules.Select(m => m.Name)) { FontSize = 13, ArrowInset = 10 };
        popup.Selected += index => { if (index >= 0 && index < _model.Modules.Count) apply(_model.Modules[index].Id); };
        return popup;
    }

    void SetNumber(string text, Action<int> set)
    {
        if (!int.TryParse(text.Trim(), out var value)) { Refresh(); return; }
        set(Math.Clamp(value, 1, 200));
        _model.RefreshAddressInput();
        Refresh();
    }

    void RebuildColumns()
    {
        switch (_model.CurrentTab)
        {
            case NumberingEditorModel.Tab.Modules:
                _table.SetColumns(new GridTable.Column[]
                {
                    new(Settings("LVBiblesPath->Column0", "Название"), 230),
                    new(Settings("LVBiblesPath->Column1", "Сокращ."), 110),
                    new(T("Стандарт"), 220),
                    new(T("Откуда"), 110),
                    new(T("Сходится"), 190),
                });
                break;
            case NumberingEditorModel.Tab.Rules:
                _table.SetColumns(new GridTable.Column[]
                {
                    new(T("Тип"), 170), new(T("Книга"), 160), new(T("Откуда"), 150), new(T("Куда"), 150), new(T("Источник"), 120),
                });
                break;
            default:
                _table.SetColumns(Array.Empty<GridTable.Column>());
                break;
        }
        _table.Select(null, scroll: false);
        _table.Reload();
    }

    // ── Дії ─────────────────────────────────────────────────────────────────

    void AskReset()
    {
        if (!_model.HasOwnCopy) return;
        Alert.Ask(Settings("TextMessages24", "Внимание"), T("Все ваши правки нумерации будут удалены. Продолжить?"),
                  new[] { T("Да"), T("Нет") }, answer =>
                  {
                      if (answer != 0) return;
                      _model.DropOwnCopy();
                      Refresh();
                  }, owner: this);
    }

    /// Правка одного правила окремим вікном. Правимо копію: поки вікно відкрите, у
    /// таблиці лишається попередній рядок, а «Скасувати» його береже.
    void EditRule(NumberingEditorModel.RuleDraft draft)
    {
        NumberingRuleSheet.Ask(this, _model, draft, Refresh);
    }

    /// «Ок» або «Скасувати». Не записалося — вікно не закриваємо: інакше правки пропали б
    /// мовчки, а людина вважала б їх збереженими.
    void Finish(bool saved)
    {
        if (saved)
        {
            if (_model.Save() is { } failure)
            {
                _model.Status = T("не записалось: %s", failure);
                Refresh();
                return;
            }
        }
        else _model.Revert();
        _finishing = true;
        Close();
    }

    // ── Оновлення ───────────────────────────────────────────────────────────

    void Refresh()
    {
        _status.Text = _model.Status + (_model.IsDirty ? "  " + T("не сохранено") : "") + "  " + T("своих строк: %s", _model.OwnRowCount.ToString());
        _status.Text = _status.Text.TrimStart();
        _assigned.Text = T("назначено %s из %s", _model.AssignedCount.ToString(), _model.ModuleRows.Count.ToString());
        _pairNote.Text = _model.PairNote;
        _counter.Text = _model.CurrentTab switch
        {
            NumberingEditorModel.Tab.Modules => _model.VisibleModuleRows.Count.ToString(),
            NumberingEditorModel.Tab.Rules => _model.RuleRows.Count.ToString(),
            _ => _model.ReportSummary,
        };

        var codes = _model.StandardCodes;
        var titles = codes.Select(NumberingEditorModel.StandardTitle).ToList();
        if (!_pairFrom.Items.SequenceEqual(titles)) { _pairFrom.SetItems(titles); _pairTo.SetItems(titles); }
        if (codes.IndexOf(_model.PairFrom) is var from and >= 0) _pairFrom.SelectedIndex = from;
        if (codes.IndexOf(_model.PairTo) is var to and >= 0) _pairTo.SelectedIndex = to;
        if (_model.Books.FindIndex(b => b.Number == _model.CheckBook) is var book and >= 0) _book.SelectedIndex = book;
        if (_model.Modules.FindIndex(m => m.Id == _model.CheckPrimary) is var primary and >= 0) _primary.SelectedIndex = primary;
        if (_model.Modules.FindIndex(m => m.Id == _model.CheckSecondary) is var secondary and >= 0) _secondary.SelectedIndex = secondary;
        if (_address.Text != _model.AddressInput && !_address.IsFocusedField) _address.Text = _model.AddressInput;
        if (!_chapter.IsFocusedField) _chapter.Text = _model.CheckChapter.ToString();
        if (!_verse.IsFocusedField) _verse.Text = _model.CheckVerse.ToString();
        _verify.Title = T("Сверить книгу целиком");

        var tab = _model.CurrentTab;
        foreach (Control c in new Control[] { _detectAll, _detectOne, _restoreStandard, _onlyUnassigned, _assigned })
            c.IsVisible = tab == NumberingEditorModel.Tab.Modules;
        foreach (Control c in new Control[] { _fromLabel, _pairFrom, _toLabel, _pairTo, _swapPair, _addRule, _editRule, _removeRule, _mirrorRule, _restoreRule, _onlyMine, _pairNote })
            c.IsVisible = tab == NumberingEditorModel.Tab.Rules;
        foreach (Control c in new Control[] { _moduleLabel, _primary, _secondary, _swapModules, _address, _bookLabel, _book, _chapterLabel, _chapter, _verseLabel, _verse, _verify, _left, _right, _explanation, _reportLine })
            c.IsVisible = tab == NumberingEditorModel.Tab.Check;
        _table.IsVisible = tab != NumberingEditorModel.Tab.Check;

        if (tab == NumberingEditorModel.Tab.Check) RefreshCheck();
        _rows.Snapshot();
        _table.Reload();
        _panel.InvalidateArrange();
    }

    /// Жива звірка: зліва вірш у своїй нумерації, справа — куди він потрапляє.
    void RefreshCheck()
    {
        var from = _model.StandardCode(_model.CheckPrimary);
        var to = _model.StandardCode(_model.CheckSecondary);
        var answer = from.Length == 0 || to.Length == 0
            ? (Spans: new List<VerseSpan>(), Reason: T("стандарт не назначен одному из переводов"), Rule: (NumberingRule?)null)
            : _model.Translate(_model.CheckBook, _model.CheckChapter, new[] { _model.CheckVerse }, from, to);
        Fill(_left, _model.CheckPrimary, _model.CheckChapter, new[] { _model.CheckVerse }, false);
        var chapter = answer.Spans.Count > 0 ? answer.Spans[0].Chapter : _model.CheckChapter;
        var verses = answer.Spans.Count > 0 ? answer.Spans[0].Verses : new[] { _model.CheckVerse };
        Fill(_right, _model.CheckSecondary, chapter, verses, true);
        var head = answer.Spans.Count == 0 ? ""
            : $"{_model.BookName(_model.CheckBook)} {_model.CheckChapter}:{_model.CheckVerse} → "
              + string.Join(", ", answer.Spans.Select(s => ReferenceFormat.Position(s.Chapter, s.Verses))) + ", ";
        _explanation.Text = head + answer.Reason;
        _reportLine.Text = _model.ReportSummary + (_model.Report.Count == 0 ? "" : "  " + T("промахи: %s", _model.Report.Count.ToString()));
    }

    void Fill(VerseColumn column, string moduleId, int chapter, IReadOnlyList<int> verses, bool isTarget)
    {
        var name = _model.Modules.FirstOrDefault(m => m.Id == moduleId).Name ?? moduleId;
        var chapters = _model.Chapters(moduleId, _model.CheckBook);
        var ready = chapters?.FirstOrDefault(c => c.Number == chapter);
        // Сусідні два вірші згори й знизу — не прикраса: коли правило схибило на одиницю,
        // правильний текст видно рядком вище чи нижче.
        var low = (verses.Count > 0 ? verses.Min() : 1) - 2;
        var high = (verses.Count > 0 ? verses.Max() : 1) + 2;
        column.Set(name, $"{_model.BookName(_model.CheckBook)} {ReferenceFormat.Position(chapter, verses)}", isTarget,
                   (ready?.Verses ?? (IReadOnlyList<Verse>)Array.Empty<Verse>()).Where(v => v.Number >= low && v.Number <= high).ToList(),
                   verses.ToHashSet(), chapters == null);
    }

    // ── Розкладка (layout() NativeNumberingEditor; відступи — зі знімка Mac) ──

    void Arrange(Size size)
    {
        const double gap = 10;
        var w = size.Width;
        var h = size.Height;
        var lh = UiFont.LineHeight(11);

        // Панель 8…34: рамки кнопок 20 заввишки з 11.
        _panel.Place(_saveNow, new Rect(9, 11, 33, 21));
        _panel.Place(_reset, new Rect(44.5, 11, 33, 21));
        _panel.Place(_reveal, new Rect(80.5, 11, 39, 21));
        _panel.Place(_status, new Rect(130.5, 13, Math.Max(0, w - gap - 130.5), lh));
        _status.Text = TextDraw.MiddleTruncated(_status.Text, 11, Math.Max(0, w - gap - 130.5));

        // Вкладки (видима доріжка — від 11.5, 314 завширшки) і лічильник.
        _panel.Place(_tabs, new Rect(11.5, 40, 314, 24));
        _panel.Place(_counter, new Rect(w - 218, 44, 198, 16));

        // Смуга вкладки: 72…98, рамки кнопок з 75.
        const double barY = 75, textY = 78;
        if (_model.CurrentTab == NumberingEditorModel.Tab.Modules)
        {
            _panel.Place(_detectAll, new Rect(8.5, barY, 39, 21));
            _panel.Place(_detectOne, new Rect(50.5, barY, 32, 21));
            _panel.Place(_restoreStandard, new Rect(85.5, barY, 33, 21));
            var check = _onlyUnassigned.FittingWidth + 4;
            _panel.Place(_onlyUnassigned, new Rect(123, barY, check, 20));
            _panel.Place(_assigned, new Rect(123 + check + 6, textY, 300, lh));
        }
        else if (_model.CurrentTab == NumberingEditorModel.Tab.Rules)
        {
            // Списки стандартів стискаються, щоб лишилося місця на кнопки, галочку й
            // хоч трохи примітки про пару.
            var labels = Math.Ceiling(UiFont.Width(_fromLabel.Text, 11)) + 8 + Math.Ceiling(UiFont.Width(_toLabel.Text, 11)) + 8;
            var fixedWidth = labels + 6 * 36 + _onlyMine.FittingWidth + 12 + 160 + 12;
            var wanted = _pairFrom.FittingWidth + 2;
            var each = Math.Max(120, Math.Min(wanted, Math.Floor((w - gap * 2 - fixedWidth) / 2)));
            var x = gap + 0.5;
            x = Label(_fromLabel, x, textY, lh);
            x = Popup(_pairFrom, x, each);
            x = Label(_toLabel, x, textY, lh);
            x = Popup(_pairTo, x, each);
            foreach (var button in new[] { _swapPair, _addRule, _editRule, _removeRule, _mirrorRule, _restoreRule })
            {
                _panel.Place(button, new Rect(x, barY, 32, 21));
                x += 36;
            }
            var check = _onlyMine.FittingWidth + 4;
            _panel.Place(_onlyMine, new Rect(x + 1, barY, check, 20));
            x += check + 7;
            _panel.Place(_pairNote, new Rect(x, textY, Math.Max(0, w - gap - x), lh));
        }
        else
        {
            // Назви перекладів бувають довгими («Сучасний переклад Рафаїла Турконяка, УБТ
            // Київ 2020») — списки стискаються так, щоб уся смуга влізла у вікно: решта
            // назви видна в самому меню списку.
            double LabelWidth(BottomCaption l) => Math.Ceiling(UiFont.Width(l.Text, 11)) + 2 + 6;
            var verifyWidth = Math.Ceiling(UiFont.Width(_verify.Title, 11)) + 25.5;
            var fixedWidth = LabelWidth(_moduleLabel) + LabelWidth(_bookLabel) + LabelWidth(_chapterLabel) + LabelWidth(_verseLabel)
                             + 38 + 186 + 60 + 60 + verifyWidth + 3 * 8;
            var room = Math.Max(3 * 80, w - gap * 2 - fixedWidth - 1);
            // Книзі — до чверті місця (назви книг короткі), решта — двом перекладам навпіл.
            var bookWidth = Math.Min(_book.FittingWidth + 2, Math.Max(90, Math.Floor(room * 0.25)));
            var moduleWidth = Math.Max(80, Math.Floor((room - bookWidth) / 2));
            var x = gap + 0.5;
            x = Label(_moduleLabel, x, textY, lh);
            x = Popup(_primary, x, Math.Min(_primary.FittingWidth + 2, moduleWidth));
            x = Popup(_secondary, x, Math.Min(_secondary.FittingWidth + 2, moduleWidth));
            _panel.Place(_swapModules, new Rect(x, barY, 32, 21));
            x += 38;
            _panel.Place(_address, new Rect(x, barY - 0.5, 180, 22));
            x += 186;
            x = Label(_bookLabel, x, textY, lh);
            x = Popup(_book, x, bookWidth);
            x = Label(_chapterLabel, x, textY, lh);
            _panel.Place(_chapter, new Rect(x, barY - 0.5, 54, 22));
            x += 60;
            x = Label(_verseLabel, x, textY, lh);
            _panel.Place(_verse, new Rect(x, barY - 0.5, 54, 22));
            x += 60;
            _panel.Place(_verify, new Rect(x, barY, verifyWidth, 21));
        }

        const double contentTop = 106, bottom = 44;
        if (_model.CurrentTab == NumberingEditorModel.Tab.Check)
        {
            var half = (w - gap * 3) / 2;
            var height = Math.Max(0, h - contentTop - bottom - 46);
            _panel.Place(_left, new Rect(gap, contentTop, half, height));
            _panel.Place(_right, new Rect(gap * 2 + half, contentTop, half, height));
            _panel.Place(_explanation, new Rect(gap + 2, contentTop + height + 4, w - gap * 2 - 4, 16));
            _panel.Place(_reportLine, new Rect(gap + 2, contentTop + height + 22, w - gap * 2 - 4, 16));
            _explanation.Text = TextDraw.MiddleTruncated(_explanation.Text, 11, w - gap * 2 - 4);
        }
        else _panel.Place(_table, new Rect(gap, contentTop, w - gap * 2, Math.Max(0, h - contentTop - bottom)));

        _bottomNote.Text = TextDraw.MiddleTruncated(T("Правки пишутся в %s, файл программы только читается", _model.UserFilePath), 11, w - 240 - 4);
        _panel.Place(_bottomNote, new Rect(gap + 2, h - 34, w - 240 - 4, 16));
        var right = w - gap;
        foreach (var button in new[] { _ok, _cancel })
        {
            var width = Math.Max(90, Math.Ceiling(UiFont.Width(button.Title, 11)) + 48);
            button.Margin = 6;
            _panel.Place(button, new Rect(right - width, h - 38, width, 24));
            right -= width + 8;
        }
    }

    double Label(BottomCaption label, double x, double y, double lh)
    {
        var width = Math.Ceiling(UiFont.Width(label.Text, 11)) + 2;
        _panel.Place(label, new Rect(x, y, width, lh));
        return x + width + 6;
    }

    double Popup(PopupButton popup, double x, double? width = null)
    {
        width ??= popup.FittingWidth + 2;
        _panel.Place(popup, new Rect(x, 74.5, width.Value, 22));
        return x + width.Value + 6;
    }

    // ── Рядки таблиці ───────────────────────────────────────────────────────

    sealed class Rows : IGridSource
    {
        readonly NumberingEditorWindow _w;
        List<NumberingEditorModel.ModuleRow> _modules = new();
        List<NumberingEditorModel.RuleRow> _rules = new();
        List<string> _choices = new();
        List<string> _codes = new();
        public Rows(NumberingEditorWindow window) => _w = window;

        /// Рядки — знімком на одне оновлення: таблиця питає комірку за коміркою.
        public void Snapshot()
        {
            _modules = _w._model.VisibleModuleRows;
            _rules = _w._model.RuleRows;
            _codes = new[] { "" }.Concat(_w._model.StandardCodes).ToList();
            _choices = new[] { T("не назначен") }.Concat(_w._model.StandardCodes.Select(NumberingEditorModel.StandardTitle)).ToList();
        }

        bool IsModules => _w._model.CurrentTab == NumberingEditorModel.Tab.Modules;

        public int RowCount => _w._model.CurrentTab switch
        {
            NumberingEditorModel.Tab.Modules => _modules.Count,
            NumberingEditorModel.Tab.Rules => _rules.Count,
            _ => 0,
        };

        public string Cell(int row, int column)
        {
            if (IsModules)
            {
                var entry = _modules[row];
                return column switch
                {
                    0 => entry.Name,
                    1 => entry.Short,
                    3 => NumberingEditorModel.Title(entry.Origin),
                    4 => MatchText(entry.Match),
                    _ => "",
                };
            }
            var rule = _rules[row];
            return column switch
            {
                0 => rule.KindTitle + " (" + rule.Letter + ")",
                1 => rule.BookTitle,
                2 => rule.Source,
                3 => rule.Target,
                _ => NumberingEditorModel.Title(rule.Origin),
            };
        }

        public (IReadOnlyList<string> Items, int Selected)? Choice(int row, int column)
        {
            if (!IsModules || column != 2) return null;
            // Стандарт призначають просто в рядку — так само, як в оригіналі.
            return (_choices, Math.Max(0, _codes.IndexOf(_modules[row].Standard)));
        }

        public Color? CellColor(int row, int column)
        {
            if (!IsModules) return null;
            var entry = _modules[row];
            // Помаранчевим — ті, у кого стандарту немає: їхня адреса не перераховується зовсім.
            if (column == 3 && entry.Standard.Length == 0) return Palette.SystemOrange;
            if (column == 4) return MatchColor(entry.Match);
            return null;
        }

        public bool IsStruck(int row) => !IsModules && row < _rules.Count && _rules[row].Origin == NumberingEditorModel.RowOrigin.Removed;

        static string MatchText(NumberingEditorModel.MatchState match) => match.Kind switch
        {
            NumberingEditorModel.MatchKind.Unknown => "—",
            NumberingEditorModel.MatchKind.Working => T("считаю…"),
            NumberingEditorModel.MatchKind.Impossible => T("не проверить: %s", match.Text),
            _ => match.Text.Length == 0 ? T("%s из %s", match.Hits.ToString(), match.Total.ToString())
                                        : T("%s из %s — %s", match.Hits.ToString(), match.Total.ToString(), match.Text),
        };

        static Color MatchColor(NumberingEditorModel.MatchState match)
        {
            if (match.Kind != NumberingEditorModel.MatchKind.Score) return Palette.SecondaryLabel;
            if (match.Hits == match.Total) return Palette.Label;
            return match.Hits == 0 ? Palette.SystemRed : Palette.SystemOrange;
        }
    }

    // ── Колонка віршів вкладки «Перевірка» ─────────────────────────────────

    /// Колонка віршів: ім'я перекладу, адреса й самі вірші з підсвіткою.
    sealed class VerseColumn : Control
    {
        string _name = "", _address = "";
        bool _isTarget, _isLoading;
        List<Verse> _verses = new();
        HashSet<int> _highlighted = new();

        public VerseColumn() { ClipToBounds = true; Palette.Changed += InvalidateVisual; }

        public void Set(string name, string address, bool isTarget, List<Verse> verses, HashSet<int> highlighted, bool isLoading)
        {
            _name = name; _address = address; _isTarget = isTarget; _verses = verses; _highlighted = highlighted; _isLoading = isLoading;
            InvalidateVisual();
        }

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.FillRectangle(Palette.Brush(Palette.TextBackground), b);
            double top = 6;
            Line(g, _name, ref top, 12, FontWeight.Medium, Palette.Label, b.Width);
            Line(g, _address, ref top, _isTarget ? 14 : 12, _isTarget ? FontWeight.Bold : FontWeight.Normal, Palette.Label, b.Width);
            if (_isLoading) Line(g, T("читаю книгу…"), ref top, 11, FontWeight.Normal, Palette.SecondaryLabel, b.Width);
            top += 4;
            foreach (var verse in _verses)
            {
                var chosen = _highlighted.Contains(verse.Number);
                var width = Math.Max(1, b.Width - 40);
                var height = TextDraw.Height(verse.Text, width, 12);
                if (chosen) g.FillRectangle(Palette.Brush(Palette.Accent.WithAlpha(0.15)), new Rect(2, top - 2, b.Width - 4, Math.Max(18, height + 2)));
                TextDraw.Draw(g, verse.Number.ToString(), new Rect(6, top + 1, 26, UiFont.LineHeight(10)), 10, Palette.SecondaryLabel, wrap: false);
                TextDraw.Draw(g, verse.Text, new Rect(34, top, width, height + 2), 12, chosen ? Palette.Label : Palette.SecondaryLabel);
                top += Math.Max(18, height + 4);
                if (top > b.Height) break;
            }
        }

        static void Line(DrawingContext g, string text, ref double top, double size, FontWeight weight, Color color, double width)
        {
            TextDraw.Draw(g, text, new Rect(6, top, Math.Max(1, width - 12), UiFont.LineHeight(size, weight)), size, color, weight, wrap: false, trim: true);
            top += size + 6;
        }
    }
}

/// Правка одного правила нумерації — окремим вікном (NativeNumberingRuleSheet на Mac).
/// Склад полів «куди» залежить від виду правила: у зсуву — одне число зі знаком,
/// у переносу — розділ і перший вірш, у точної відповідності — початок і кінець.
public static class NumberingRuleSheet
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    public static Window Ask(Window owner, NumberingEditorModel model, NumberingEditorModel.RuleDraft draft, Action done)
    {
        var window = new Window
        {
            Title = T("Правило нумерации"), Width = 520, SizeToContent = SizeToContent.Height, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground),
        };
        var kinds = NumberingRuleKinds.All;
        var kind = new PopupButton(kinds.Select(NumberingEditorModel.KindTitle), Math.Max(0, kinds.ToList().IndexOf(draft.Kind))) { FontSize = 13, ArrowInset = 10 };
        var book = new PopupButton(model.Books.Select(b => $"{b.Name} ({b.Number})"), Math.Max(0, model.Books.FindIndex(b => b.Number == draft.Book))) { FontSize = 13, ArrowInset = 10 };
        var fields = new Dictionary<string, FormField>();
        FormField Field(string key, int? value)
        {
            var field = new FormField(11, rightAligned: true) { Text = value?.ToString() ?? "" };
            fields[key] = field;
            return field;
        }
        var chapterBegin = Field("chapterBegin", draft.ChapterBegin);
        var chapterEnd = Field("chapterEnd", draft.ChapterEnd);
        var verseBegin = Field("verseBegin", draft.VerseBegin);
        var verseEnd = Field("verseEnd", draft.VerseEnd);
        var chapterTo = Field("chapterTo", draft.ChapterTo);
        var verseTo = Field("verseTo", draft.VerseTo);
        var chapterToEnd = Field("chapterToEnd", draft.ChapterToEnd);
        var verseToEnd = Field("verseToEnd", draft.VerseToEnd);
        var preview = new BottomCaption { FontSize = 11, Color = () => Palette.SecondaryLabel };
        var targetTitle = Label("", true);

        static BottomCaption Label(string text, bool right) =>
            new(text) { FontSize = 11, Color = () => Palette.SecondaryLabel, Align = right ? TextAlignment.Right : TextAlignment.Center };

        string TargetTitle() => draft.Kind switch
        {
            NumberingRuleKind.OffsetChapter => T("Прибавить к главе"),
            NumberingRuleKind.OffsetVerse => T("Прибавить к стиху"),
            NumberingRuleKind.Part => T("Глава / первый стих"),
            _ => T("Начало и конец"),
        };

        int? Number(string key) => fields[key].Text.Trim() is { Length: > 0 } text && int.TryParse(text, out var n) ? n : null;

        void Collect()
        {
            if (book.SelectedIndex >= 0 && book.SelectedIndex < model.Books.Count) draft.Book = model.Books[book.SelectedIndex].Number;
            draft.ChapterBegin = Number("chapterBegin") ?? draft.ChapterBegin;
            draft.ChapterEnd = Number("chapterEnd");
            draft.VerseBegin = Number("verseBegin");
            draft.VerseEnd = Number("verseEnd");
            draft.ChapterTo = Number("chapterTo");
            draft.VerseTo = Number("verseTo");
            draft.ChapterToEnd = Number("chapterToEnd");
            draft.VerseToEnd = Number("verseToEnd");
        }

        /// Живий приклад: перший вірш, який правило захоплює, і що з нього вийде.
        void RefreshPreview()
        {
            Collect();
            targetTitle.Text = TargetTitle();
            var rule = new NumberingRule(draft.From, draft.To, draft.Kind, draft.Book, draft.ChapterBegin, draft.ChapterEnd, draft.VerseBegin, draft.VerseEnd,
                                         draft.ChapterTo, draft.ChapterToEnd, draft.VerseTo, draft.VerseToEnd);
            var verse = draft.VerseBegin ?? 1;
            var answer = NumberingEditorModel.Translate(new[] { rule }, draft.Book, draft.ChapterBegin, new[] { verse }, draft.From, draft.To);
            var name = model.BookName(draft.Book);
            var tail = string.Join(", ", answer.Spans.Select(s => ReferenceFormat.Position(s.Chapter, s.Verses)));
            preview.Text = answer.Rules.Count == 0
                ? $"{name} {draft.ChapterBegin}:{verse} — " + T("правило это место не захватывает")
                : $"{name} {draft.ChapterBegin}:{verse} → {name} {tail}";
        }

        kind.Selected += index => { draft.Kind = kinds[Math.Clamp(index, 0, kinds.Count - 1)]; RefreshPreview(); };
        book.Selected += _ => RefreshPreview();
        foreach (var field in fields.Values)
        {
            field.OnChange = _ => RefreshPreview();
        }

        // Поля — у координатах Mac (accessoryView 480×214, тут згори вниз).
        var box = new LayoutPanel { Width = 480, Height = 184 };
        var placed = new List<(Control C, Rect R)>
        {
            (Label(T("Вид"), true), new Rect(0, 9, 112, 16)), (kind, new Rect(120, 4, 240, 24)),
            (Label(T("Книга"), true), new Rect(0, 39, 112, 16)), (book, new Rect(120, 34, 240, 24)),
            (Label(T("Главы с"), true), new Rect(0, 69, 112, 16)), (chapterBegin, new Rect(120, 66, 56, 22)),
            (Label(T("по"), false), new Rect(186, 69, 28, 16)), (chapterEnd, new Rect(218, 66, 56, 22)),
            (Label(T("Стихи с"), true), new Rect(0, 99, 112, 16)), (verseBegin, new Rect(120, 96, 56, 22)),
            (Label(T("по"), false), new Rect(186, 99, 28, 16)), (verseEnd, new Rect(218, 96, 56, 22)),
            (Label(T("пустое поле — «не задано»"), true), new Rect(290, 99, 190, 16)),
            (targetTitle, new Rect(0, 129, 112, 16)), (chapterTo, new Rect(120, 126, 56, 22)), (verseTo, new Rect(186, 126, 56, 22)),
            (chapterToEnd, new Rect(252, 126, 56, 22)), (verseToEnd, new Rect(318, 126, 56, 22)),
            (preview, new Rect(0, 158, 480, 16)),
        };
        foreach (var (c, r) in placed) box.Children.Add(c);
        box.Layout = _ => { foreach (var (c, r) in placed) box.Place(c, r); };

        var committed = false;
        var ok = new PushButton(Captions.FormCaption("BBOk", "SongColorsetForm", "Ок")) { Prominent = true, MinWidth = 90, Height = 24 };
        var cancel = new PushButton(Captions.FormCaption("BBCancel", "SongColorsetForm", "Отменить")) { MinWidth = 90, Height = 24 };
        ok.Pressed = () =>
        {
            Collect();
            // Відповідь моделі — слово про помилку; null — прийнято. Правило з переплутаними
            // краями мовчки не пишемо: показуємо, що не так.
            if (model.Commit(draft) is { } complaint)
            {
                Alert.Ask(Captions.FormCaption("TextMessages24", "SettingsForm", "Внимание"), complaint, new[] { Captions.FormCaption("BBOk", "SettingsForm", "Ок") }, owner: window);
                return;
            }
            committed = true;
            window.Close();
        };
        cancel.Pressed = () => window.Close();
        window.Closed += (_, _) => { if (committed) done(); };
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) { window.Close(); e.Handled = true; } };
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 8,
            Children =
            {
                new TextBlock { Text = T("Правило нумерации"), FontWeight = FontWeight.Bold, FontSize = 13, FontFamily = UiFont.Family },
                new TextBlock { Text = NumberingEditorModel.StandardTitle(draft.From) + " → " + NumberingEditorModel.StandardTitle(draft.To),
                                FontSize = 11, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family, Foreground = Palette.Brush(Palette.Label) },
                box,
                new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right,
                                 Children = { cancel, ok } },
            },
        };
        RefreshPreview();
        if (owner.IsVisible) window.ShowDialog(owner); else window.Show();
        return window;
    }
}
