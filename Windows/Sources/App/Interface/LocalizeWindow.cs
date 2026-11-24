// =============================================================================
//  LocalizeWindow.cs — вікно «Переклад інтерфейсу» (7.1, LocalizeTranslateForm)
// =============================================================================
//  За NativeLocalizeView.swift і InterfaceWindows.showTranslate Mac 1.3.9:
//  панель (зберегти, мова перекладу, + −, «не збережено», Закрити), вибір вікна
//  програми з кнопками «очистити / скопіювати все» і вимкненими кнопками
//  онлайн-перекладу (чужа служба visiobible.org.ua, ключів до неї немає),
//  «лише неперекладені»; вкладки «Об'єкти / Тексти / Помилки» з лічильником,
//  таблиця (зелений рядок — перекладено, червоний — ні), а внизу оригінал і
//  поля перекладу з кнопками. Розміри й відступи — зі знімка Mac (1180×820,
//  найменше 1060×700).
// =============================================================================

using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class LocalizeWindow : Window, ISnapshotWork
{
    const string FormKey = "LocalizeTranslateForm";
    static LocalizeWindow? _shown;

    public static LocalizeWindow Open(AppState state)
    {
        if (_shown is { } open) { open.Activate(); return open; }
        var window = _shown = new LocalizeWindow(state);
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    static string C(string key, string fallback) => Captions.FormCaption(key, FormKey, fallback);
    static string H(string key, string fallback) => Captions.FormHint(key, FormKey) ?? Captions.T(fallback);
    static string T(string text) => Captions.T(text);

    /// «Зелений рядок — переклад завершено, червоний — ні» (кольори Mac у sRGB).
    static readonly Color Done = Color.FromRgb(0x0D, 0x73, 0x1F), NotDone = Color.FromRgb(0xB8, 0x1F, 0x1F);

    readonly LocalizeModel _model;
    readonly LayoutPanel _panel = new();
    readonly RowsSource _source = new();
    readonly GridTable _table = new();
    readonly PushButton _save, _add, _remove, _close, _clearAll, _copyAll, _webAll, _webStop, _webKey;
    readonly PushButton[] _editorButtons, _stepButtons;
    readonly BottomCaption _languageLabel, _dirty, _formLabel, _counter;
    readonly BottomCaption _objectLine, _typeLine, _originalTitle, _translationTitle, _originalCaption, _originalHint;
    readonly PopupButton _languages, _forms;
    readonly MacCheckBox _onlyUntranslated;
    readonly Segmented _tabs;
    readonly FormField _captionField = new(12), _hintField = new(12);
    List<string> _formNames = new();
    bool _closingConfirmed;

    LocalizeWindow(AppState state)
    {
        _model = new LocalizeModel(InterfaceLanguageStore.Originals(state), Languages.Current?.Code ?? "ru");
        // Який переклад стоїть у головному вікні — від цього залежить відмова видалення.
        _model.ActiveLanguageCode = Languages.Current?.Code ?? "";

        Title = C("LocalizeTranslateForm", "Перевод языка интерфейса");
        Width = 1180; Height = 820;
        MinWidth = 1060; MinHeight = 700;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        Palette.Changed += () => Background = Palette.Brush(Palette.WindowBackground);

        // (1) Зберегти переклад.
        _save = Tool("square.and.arrow.down", H("TBSave", "Сохранить перевод интерфейса"), () => { SaveNow(); Reload(); });
        // (2) Мова перекладу для правки.
        _languageLabel = Caption(H("CBLangList", "Язык перевода интерфейса") + ":");
        _languages = new PopupButton(Array.Empty<string>()) { FontSize = 13, ArrowInset = 10 };
        _languages.Selected += SelectLanguage;
        // (3) (4) Додати й видалити переклад.
        _add = Tool("plus", H("TBAddLocal", "Добавить новый перевод интерфейса"), AddTranslation);
        _remove = Tool("minus", H("TBDelLocal", "Удалить выбранный перевод интерфейса"), DeleteTranslation);
        _dirty = new BottomCaption { FontSize = 11, Color = () => Palette.SystemOrange };
        _close = new PushButton(T("Закрыть")) { FontSize = 11, Margin = 0.5, Pressed = Close };

        // (5) Вікно (форма) програми.
        _formLabel = Caption(H("CBFormsSelect", "Выбор окна (формы) программы для перевода") + ":");
        _forms = new PopupButton(Array.Empty<string>()) { FontSize = 13, ArrowInset = 10 };
        _forms.Selected += SelectForm;
        // (6) (7) Очистити й скопіювати все для вікна.
        _clearAll = Tool("delete.left", H("TBClearAll", "Очистить ВСЕ переводы для окна"), () => { _model.ClearForm(); Reload(); });
        _copyAll = Tool("doc.on.doc", H("TBCopyAll", "Скопировать ВСЕ переводы для окна из оригинальных текстов"), () => { _model.CopyFormFromOriginal(); Reload(); });
        // (8) (9) Онлайн-переклад — служба visiobible.org.ua з обліковим записом, ключів
        // до неї в програми немає. Кнопки на своїх місцях і вимкнені, як на Mac.
        _webAll = Tool("globe", H("TBWebTranslateAll", "Онлайн перевод ВСЕХ текстов для окна"), null, () => Palette.SystemBlue);
        _webStop = Tool("stop.fill", H("TBWebTranslateStop", "Остановить перевод ВСЕХ текстов"), null, symbolSize: 9);
        _webKey = Tool("key", H("TWebTranslateSettings", "Авторизация для онлайн перевода"), null, () => Color.FromRgb(0xD9, 0xA0, 0x1E));
        // (10) Лише неперекладені.
        _onlyUntranslated = new MacCheckBox(H("TBOnlyNotTranslated", "Показывать только непереведенные (Вкл/Выкл)"), 11);
        _onlyUntranslated.Toggled += on => { _model.OnlyUntranslated = on; Reload(); };

        // (11) Вкладки типів текстів і лічильник.
        _tabs = new Segmented(new[] { C("TSObjects", "Объекты"), C("TSTexts", "Тексты"), C("TSErrors", "Ошибки") });
        _tabs.Selected += SelectTab;
        _counter = Caption("");

        // (12) Список елементів.
        _table.Source = _source;
        _table.PlainText = true;
        _table.OnSelect = row =>
        {
            if (row < 0 || row >= _source.Rows.Count) return;
            _model.SelectedKey = _source.Rows[row].Key;
            SyncSelection();
        };
        _table.OnContextMenu = _ => MenuStrip.Build(new[] { new MenuEntry(C("NCopyText", "Скопировать текст в буфер обмена"), CopyRow) });

        // (13)…(17) Оригінал і переклад.
        _objectLine = Caption("");
        _objectLine.Plain = true;
        _typeLine = Caption("");
        _originalTitle = Caption("");
        _translationTitle = Caption("");
        _originalCaption = new BottomCaption { FontSize = 12, Color = () => Palette.Label };
        _originalHint = new BottomCaption { FontSize = 12, Color = () => Palette.Label };
        // Тексти перекладу — «як є», без лігатур шрифту (і в полях, і в мітках оригіналу).
        _originalCaption.Plain = _originalHint.Plain = true;
        _captionField.Box.FontFeatures = _hintField.Box.FontFeatures = TextDraw.Literal;
        _captionField.OnChange = text => { if (_model.SelectedKey is { } key) { _model.SetCaption(text, key); Edited(); } };
        _hintField.OnChange = text => { if (_model.SelectedKey is { } key) { _model.SetHint(text, key); Edited(); } };
        _editorButtons = new[]
        {
            Tool("delete.left", H("PngSBClearObjText", "Очистить перевод для объекта"), () => { _model.ClearSelected(); Reload(); }, margin: 6),
            Tool("doc.on.doc", H("PngSBCopyObjText", "Скопировать из оригинальных текстов"), () => { _model.CopySelectedFromOriginal(); Reload(); }, margin: 6),
            Tool("globe", H("PngSBWebTranslate", "Онлайн перевод текста"), null, () => Palette.SystemBlue, margin: 6),
        };
        // Пара «шукати попередній / наступний» — як в автора поруч із полем.
        _stepButtons = new[]
        {
            Tool("arrow.up", H("PngSpeedButton1", "Искать предыдущий объект"), () => Step(false), margin: 6, symbolSize: 8),
            Tool("arrow.down", H("PngSpeedButton2", "Искать следующий объект"), () => Step(true), margin: 6, symbolSize: 8),
        };

        foreach (Control c in new Control[]
                 {
                     _save, _languageLabel, _languages, _add, _remove, _dirty, _close,
                     _formLabel, _forms, _clearAll, _copyAll, _webAll, _webStop, _webKey, _onlyUntranslated,
                     _tabs, _counter, _table,
                     _objectLine, _typeLine, _originalTitle, _translationTitle, _originalCaption, _originalHint, _captionField, _hintField,
                 }.Concat(_editorButtons).Concat(_stepButtons))
            _panel.Children.Add(c);
        _panel.Layout = Arrange;
        Content = _panel;

        RebuildColumns();
        FillLanguages();
        FillForms();
        Reload();

        KeyDown += (_, e) => { if (e.Key == Key.Escape) { Close(); e.Handled = true; } };
        Closing += (_, e) =>
        {
            if (_closingConfirmed || !_model.IsDirty) return;
            e.Cancel = true;
            Alert.Ask(C("TextMessages4", "Сохранение переводов"), C("TextMessages3", "Тексты перевода изменены. Сохранить?"),
                      new[] { T("Да"), T("Нет"), T("Отмена") }, answer =>
                      {
                          if (answer == 2) return;
                          if (answer == 0 && !SaveNow()) return;
                          _closingConfirmed = true;
                          Close();
                      }, owner: this);
        };
    }

    void SelectLanguage(int index)
    {
        if (index < 0 || index >= _model.AvailableLanguages.Count) return;
        _model.LanguageCode = _model.AvailableLanguages[index].Code;
        Reload();
    }

    void SelectForm(int index)
    {
        if (index < 0 || index >= _formNames.Count) return;
        _model.FormName = _formNames[index];
        Reload();
    }

    void SelectTab(int index)
    {
        _model.Tab = (LocalizeModel.TextTab)Math.Clamp(index, 0, 2);
        RebuildColumns();
        Reload();
    }

    // ── Перевірка без екрана: `--localize "крок;крок…"` перед знімком ───────
    //  add=Назва|код[|empty] · lang=код · form=Ім'я · tab=0..2 · only · row=N · key=Ключ ·
    //  caption=текст · hint=текст · clear · copy · clearall · copyall · next · prev ·
    //  save · delete — ті самі дії, що й кнопки (питання «Так/Ні» — одразу «Так»).

    public bool IsWorking => false;

    public void Begin(string[] args)
    {
        var at = Array.IndexOf(args, "--localize");
        if (at < 0 || at + 1 >= args.Length) return;
        foreach (var step in args[at + 1].Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = step.IndexOf('=');
            var verb = eq < 0 ? step : step[..eq];
            var arg = eq < 0 ? "" : step[(eq + 1)..];
            switch (verb)
            {
                case "add":
                    var parts = arg.Split('|');
                    AddNow(parts[0], parts.Length > 1 ? parts[1] : "", parts.Length < 3 || parts[2] != "empty");
                    break;
                case "lang": SelectLanguage(_model.AvailableLanguages.FindIndex(l => l.Code == arg)); break;
                case "form": SelectForm(_formNames.IndexOf(arg)); break;
                case "tab": _tabs.SelectedIndex = int.Parse(arg); SelectTab(int.Parse(arg)); break;
                case "only": _onlyUntranslated.IsChecked = !_onlyUntranslated.IsChecked; _model.OnlyUntranslated = _onlyUntranslated.IsChecked; Reload(); break;
                case "row": _table.Select(int.Parse(arg)); _table.OnSelect?.Invoke(int.Parse(arg)); break;
                case "key":
                    var found = _source.Rows.FindIndex(r => r.Key == arg);
                    if (found < 0) Console.WriteLine($"  ключа «{arg}» немає");
                    else { _table.Select(found); _table.OnSelect?.Invoke(found); }
                    break;
                case "caption": if (_captionField.IsEffectivelyEnabled) _captionField.Box.Text = arg; else Console.WriteLine("  поле заголовка вимкнене"); break;
                case "hint": if (_hintField.IsEffectivelyEnabled) _hintField.Box.Text = arg; else Console.WriteLine("  поле підказки вимкнене"); break;
                case "clear": _editorButtons[0].Pressed?.Invoke(); break;
                case "copy": _editorButtons[1].Pressed?.Invoke(); break;
                case "clearall": _clearAll.Pressed?.Invoke(); break;
                case "copyall": _copyAll.Pressed?.Invoke(); break;
                case "next": Step(true); break;
                case "prev": Step(false); break;
                case "save": _save.Pressed?.Invoke(); break;
                case "delete":
                    _model.ActiveLanguageCode = Languages.Current?.Code ?? "";
                    if (_model.Refusal() is { } refusal) Console.WriteLine($"  видалення: відмова {refusal}"); else DeleteNow();
                    break;
                default: Console.WriteLine($"  крок «{step}» невідомий"); break;
            }
            // Подія зміни тексту поля приходить через чергу — дати їй дійти до моделі.
            Avalonia.Threading.Dispatcher.UIThread.RunJobs();
            Console.WriteLine($"  переклад [{step}]: мова {_model.LanguageCode} «{_model.DisplayName}» (мов {_model.AvailableLanguages.Count}), " +
                              $"оригінал «{_model.ReferenceName}», вікно {_model.FormName}, вкладка {_model.Tab}, рядків {_source.Rows.Count}, " +
                              $"вибрано {_model.SelectedKey ?? "—"}, змінено {_model.IsDirty}, поля «{_captionField.Text}» / «{_hintField.Text}», " +
                              $"файл {(InterfaceLanguageStore.IsUserOwned(_model.LanguageCode) ? "свій" : "—")}, інтерфейс {Languages.Code}");
        }
    }

    // ── Збирання ────────────────────────────────────────────────────────────

    static BottomCaption Caption(string text) => new(text) { FontSize = 11, Color = () => Palette.SecondaryLabel };

    static PushButton Tool(string symbol, string hint, Action? action, Func<Color>? tint = null, double margin = 0.5, double symbolSize = 0)
    {
        var button = new PushButton("", symbol) { Margin = margin, TitleTint = tint, TintsWhenDisabled = tint != null };
        if (symbolSize > 0) button.SymbolSize = symbolSize;
        if (action != null) button.Pressed = action; else button.IsEnabled = false;
        ToolTip.SetTip(button, hint);
        return button;
    }

    void RebuildColumns()
    {
        if (_model.Tab == LocalizeModel.TextTab.Objects)
        {
            _source.Objects = true;
            _table.SetColumns(new GridTable.Column[]
            {
                new(C("LVObjects->Column0", "Объект"), 170),
                new(C("LVObjects->Column1", "Тип"), 130),
                new(C("LVObjects->Column2", "Оригин. заголовок"), 200),
                new(C("LVObjects->Column3", "Оригин. подсказка"), 200),
                new(C("LVObjects->Column4", "Перевод заголовка"), 200),
                new(C("LVObjects->Column5", "Перевод подсказки"), 200),
            });
        }
        else
        {
            // Своє для кожної текстової вкладки: «Тексти» — LVTexts, «Помилки» — LVTextsError.
            var list = _model.Tab == LocalizeModel.TextTab.Errors ? "LVTextsError" : "LVTexts";
            _source.Objects = false;
            _table.SetColumns(new GridTable.Column[]
            {
                new(C(list + "->Column0", "№"), 130),
                new(C(list + "->Column1", "Текст на языке оригинала"), 380),
                new(C(list + "->Column2", "Текст перевода"), 380),
            });
        }
    }

    void FillLanguages()
    {
        _languages.SetItems(_model.AvailableLanguages.Select(l => l.DisplayName + "  (" + l.Code + ")"));
        var index = _model.AvailableLanguages.FindIndex(l => l.Code == _model.LanguageCode);
        if (index >= 0) _languages.SelectedIndex = index;
        _panel.InvalidateArrange();
    }

    void FillForms()
    {
        _formNames = _model.FormNames;
        _forms.SetItems(_formNames);
        var index = _formNames.IndexOf(_model.FormName);
        // На Mac список показував перший пункт, а модель лишалася на «MainForm», якої
        // немає (немає файлів перекладу автора) — таблиця була порожня. Тут — те, що видно.
        if (index < 0 && _formNames.Count > 0) { index = 0; _model.FormName = _formNames[0]; }
        if (index >= 0) _forms.SelectedIndex = index;
        _panel.InvalidateArrange();
    }

    // ── Оновлення ───────────────────────────────────────────────────────────

    void Reload()
    {
        _source.Rows = _model.Rows();
        _table.Reload();
        _counter.Text = _source.Rows.Count.ToString();
        _dirty.Text = _model.IsDirty ? T("не сохранено") : "";
        _save.IsEnabled = _model.IsDirty;
        _originalTitle.Text = C("GroupBox1", "Тексты на языке оригинала:") + "  " + _model.ReferenceName;
        _translationTitle.Text = C("GroupBox2", "Тексты перевода:") + "  " + _model.DisplayName;
        SyncSelection();
        _panel.InvalidateArrange();
    }

    void SyncSelection()
    {
        var index = _model.SelectedKey is { } key ? _source.Rows.FindIndex(r => r.Key == key) : -1;
        if (index >= 0 && _table.Selected != index) _table.Select(index);
        if (index < 0 && _table.Selected != null) _table.Select(null, scroll: false);
        var row = index >= 0 ? _source.Rows[index] : null;
        _objectLine.Text = C("Label1", "Объект:") + "  " + (row?.Key ?? C("LObjName", "Не выбран"));
        _typeLine.Text = C("Label2", "Тип объекта:") + "  " + (row?.Type ?? C("LObjType", "Не выбран"));
        _originalCaption.Text = C("Label3", "Заголовок:") + "  " + (row?.OriginalCaption ?? "");
        _originalHint.Text = C("Label4", "Подсказка:") + "  " + (row?.OriginalHint ?? "");
        _captionField.Text = row?.Caption ?? "";
        _hintField.Text = row?.Hint ?? "";
        // «Якщо поле не активне, переклад для нього недоступний»: в оригіналі тексту немає.
        // Уже введений переклад поле не замикає — інакше його не стерти.
        _captionField.IsEnabled = row != null && (row.OriginalCaption.Length > 0 || row.Caption.Length > 0);
        _hintField.IsEnabled = _model.Tab == LocalizeModel.TextTab.Objects && row != null && (row.OriginalHint.Length > 0 || row.Hint.Length > 0);
        _editorButtons[0].IsEnabled = _editorButtons[1].IsEnabled = row != null;
    }

    void Edited()
    {
        _dirty.Text = _model.IsDirty ? T("не сохранено") : "";
        _save.IsEnabled = _model.IsDirty;
        _source.Rows = _model.Rows();
        _table.Reload();
        _panel.InvalidateArrange();
    }

    void Step(bool forward)
    {
        if (!_model.Step(LocalizeModel.Column.Object, forward)) SystemSound.Beep();
        SyncSelection();
    }

    async void CopyRow()
    {
        if (_model.SelectedRow(_source.Rows) is not { } row) return;
        if (Clipboard is { } board) await board.SetTextAsync(row.Caption.Length == 0 ? row.OriginalCaption : row.Caption);
    }

    bool SaveNow()
    {
        if (_model.Save() is { } error)
        {
            Alert.Ask(T("Не удалось сохранить перевод"), error.Message, new[] { T("Ок") }, owner: this);
            return false;
        }
        InterfaceLanguageStore.AnnounceChange();
        return true;
    }

    // ── (3) (4) Переклади ───────────────────────────────────────────────────

    void AddTranslation()
    {
        NewTranslation.Ask(this, C("TextMessages5", "Создание нового перевода"),
                           C("TextMessages6", "Введите язык перевода:"),
                           C("TextMessages7", "Введите короткое название перевода (напр. ru/en/de):"),
                           T("Скопировать тексты языка оригинала"),
                           Captions.FormCaption("PBBOk", "SelectLangForm", "Ок"),
                           Captions.FormCaption("PBBCancel", "SelectLangForm", "Отмена"),
                           answer =>
                           {
                               var code = answer.Code.Trim().ToLowerInvariant();
                               var name = answer.Name.Trim();
                               if (code.Length == 0 || name.Length == 0) return;
                               if (!InterfaceLanguageStore.IsUserOwned(code)) { AddNow(name, code, answer.Copy); return; }
                               Alert.Ask(C("TextMessages8", "Перевод"), C("TextMessages9", "Существует.\\nПереписать?").Replace("\\n", "\n"),
                                         new[] { T("Да"), T("Нет") }, yes => { if (yes == 0) AddNow(name, code, answer.Copy); }, owner: this);
                           });
    }

    void AddNow(string name, string code, bool copy)
    {
        _model.AddTranslation(name, code, copy);
        InterfaceLanguageStore.AnnounceChange();
        FillLanguages();
        Reload();
    }

    void DeleteTranslation()
    {
        // Відмову — до питання: питати «Видалити?», щоб потім сказати «не можна», не годиться.
        _model.ActiveLanguageCode = Languages.Current?.Code ?? "";
        if (_model.Refusal() is { } refusal) { Warn(refusal); return; }
        Alert.Ask(C("TextMessages11", "Удаление переводов"), C("TextMessages10", "Удалить перевод?"), new[] { T("Да"), T("Нет") }, answer =>
        {
            if (answer == 0) DeleteNow();
        }, owner: this);
    }

    void DeleteNow()
    {
        if (_model.DeleteTranslation() is { } refused) { Warn(refused); return; }
        InterfaceLanguageStore.AnnounceChange();
        FillLanguages();
        Reload();
    }

    void Warn(LocalizeModel.DeleteRefusal refusal)
    {
        var text = refusal == LocalizeModel.DeleteRefusal.InUse
            ? C("TextMessages12", "Нельзя удалить текущий перевод\\nСначала измените язык в главном окне программы").Replace("\\n", "\n")
            : T("Это перевод из комплекта программы — он только читается.") + "\n" + T("Удалить можно лишь свой перевод, сохранённый в «Слове».");
        Alert.Ask(C("TextMessages13", "Внимание"), text, new[] { T("Закрыть") }, owner: this);
    }

    // ── Розкладка (layout() NativeLocalizeView; відступи — зі знімка Mac) ─────

    void Arrange(Size size)
    {
        const double gap = 8;
        var w = size.Width;
        var h = size.Height;
        var lh = UiFont.LineHeight(11);

        // Панель: рядок 8…34, рамки кнопок 20 заввишки з 11.
        var x = 7.5;
        _panel.Place(_save, new Rect(x, 11, 31, 21));
        x = 44.5;
        var labelWidth = Math.Ceiling(UiFont.Width(_languageLabel.Text, 11));
        _panel.Place(_languageLabel, new Rect(x, 13, labelWidth + 2, lh));
        x += labelWidth + 6.5;
        var popupWidth = _languages.FittingWidth + 2;
        _panel.Place(_languages, new Rect(x, 10.5, popupWidth, 22));
        x += popupWidth + 4.5;
        _panel.Place(_add, new Rect(x, 11, 32, 21));
        x += 36;
        _panel.Place(_remove, new Rect(x, 11, 32, 21));
        x += 32 + 5.5;
        var dirtyWidth = _dirty.Text.Length == 0 ? 0 : Math.Ceiling(UiFont.Width(_dirty.Text, 11)) + 2;
        _panel.Place(_dirty, new Rect(x + 0.5, 13, dirtyWidth, lh));
        x += dirtyWidth > 0 ? dirtyWidth + 6 : 5;
        var closeWidth = Math.Ceiling(UiFont.Width(_close.Title, 11)) + 25.5;
        _panel.Place(_close, new Rect(x, 11, closeWidth, 21));

        // Вибір вікна: рядок 38…64.
        x = 8.5;
        labelWidth = Math.Ceiling(UiFont.Width(_formLabel.Text, 11));
        _panel.Place(_formLabel, new Rect(x, 44, labelWidth + 2, lh));
        x += labelWidth + 7;
        popupWidth = _forms.FittingWidth + 2;
        _panel.Place(_forms, new Rect(x, 40, popupWidth, 22));
        x += popupWidth + 6;
        foreach (var (button, width) in new[] { (_clearAll, 32.0), (_copyAll, 30.0), (_webAll, 36.0), (_webStop, 31.0), (_webKey, 36.0) })
        {
            _panel.Place(button, new Rect(x, 41, width, 21));
            x += width + 6;
        }
        _panel.Place(_onlyUntranslated, new Rect(x + 1.5, 41, _onlyUntranslated.FittingWidth + 4, 20));

        // Вкладки (видима доріжка 9.5…323.5) і лічильник.
        _panel.Place(_tabs, new Rect(9.5, 70, 314, 24));
        _panel.Place(_counter, new Rect(w - 78, 74, 58, 16));

        // Таблиця й редактор (210 заввишки) під нею.
        const double editorHeight = 210;
        var tableBottom = 100 + Math.Max(0, h - 94 - editorHeight - 18);
        _panel.Place(_table, new Rect(gap, 100, w - gap * 2, tableBottom - 100));

        var top = tableBottom + 8;
        _panel.Place(_objectLine, new Rect(gap + 2, top, w / 2 - gap - 4, 18));
        _panel.Place(_typeLine, new Rect(w / 2 + 2, top, w / 2 - gap - 4, 18));
        for (var i = 0; i < _stepButtons.Length; i++) _panel.Place(_stepButtons[i], new Rect(w - 70 + i * 32, top - 2, 30, 21));
        top += 24;
        var half = (w - gap * 3) / 2;
        _panel.Place(_originalTitle, new Rect(gap + 2, top, half - 4, 16));
        _panel.Place(_translationTitle, new Rect(gap * 2 + half + 2, top, half - 4, 16));
        top += 20;
        _panel.Place(_originalCaption, new Rect(gap + 2, top, half - 4, 20));
        _panel.Place(_captionField, new Rect(gap * 2 + half, top, half, 22));
        top += 26;
        _panel.Place(_originalHint, new Rect(gap + 2, top, half - 4, 20));
        _panel.Place(_hintField, new Rect(gap * 2 + half, top, half, 22));
        top += 28;
        for (var i = 0; i < _editorButtons.Length; i++) _panel.Place(_editorButtons[i], new Rect(gap * 2 + half + i * 34, top, 30, 21));
    }

    // ── Рядки таблиці ───────────────────────────────────────────────────────

    sealed class RowsSource : IGridSource
    {
        public List<LocalizeModel.Row> Rows = new();
        public bool Objects = true;
        public int RowCount => Rows.Count;

        public string Cell(int row, int column)
        {
            var r = Rows[row];
            var text = Objects
                ? column switch { 0 => r.Key, 1 => r.Type, 2 => r.OriginalCaption, 3 => r.OriginalHint, 4 => r.Caption, _ => r.Hint }
                : column switch { 0 => r.Key, 1 => r.OriginalCaption, _ => r.Caption };
            // Рядок таблиці — один: що за переносом, ховається, як у мітки NSTextField.
            var cut = text.IndexOf('\n');
            return cut < 0 ? text : text[..cut].TrimEnd() + "…";
        }

        public Color? RowColor(int row) => Rows[row].IsDone ? Done : NotDone;
    }
}

/// «Створення нового перекладу»: назва мови, короткий код і галочка «скопіювати
/// тексти мови оригіналу» (NSAlert з accessoryView на Mac).
public static class NewTranslation
{
    public readonly record struct Answer(string Name, string Code, bool Copy);

    public static void Ask(Window owner, string title, string namePlaceholder, string codePlaceholder, string copyTitle,
                           string ok, string cancel, Action<Answer> done)
    {
        var window = new Window
        {
            Title = title, Width = 460, SizeToContent = SizeToContent.Height, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground),
        };
        var name = new FormField(13) { Height = 22, Placeholder = namePlaceholder };
        var code = new FormField(13) { Height = 22, Placeholder = codePlaceholder };
        // Порожній переклад в оригіналі починають з копії текстів мови оригіналу —
        // інакше вікно відкривається суцільно червоним.
        var copy = new MacCheckBox(copyTitle, 13) { IsChecked = true };
        Answer? result = null;
        var okButton = new PushButton(ok) { Prominent = true, MinWidth = 90, Height = 24 };
        var cancelButton = new PushButton(cancel) { MinWidth = 90, Height = 24 };
        okButton.Pressed = () => { result = new Answer(name.Text, code.Text, copy.IsChecked); window.Close(); };
        cancelButton.Pressed = () => window.Close();
        code.OnSubmit = _ => okButton.Pressed?.Invoke();
        window.Closed += (_, _) => { if (result is { } answer) done(answer); };
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 8,
            Children =
            {
                new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 13, TextWrapping = TextWrapping.Wrap, FontFamily = UiFont.Family },
                name, code, copy,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 6, 0, 0), Children = { cancelButton, okButton } },
            },
        };
        window.Opened += (_, _) => name.FocusField();
        window.KeyDown += (_, e) => { if (e.Key == Key.Escape) { window.Close(); e.Handled = true; } };
        if (owner.IsVisible) window.ShowDialog(owner); else window.Show();
    }
}

/// Системний звук «не вийшло» (NSSound.beep на Mac).
public static class SystemSound
{
    [DllImport("user32.dll")] static extern bool MessageBeep(uint type);

    public static void Beep()
    {
        if (!OperatingSystem.IsWindows()) return;
        try { MessageBeep(0xFFFFFFFF); } catch { /* без звуку — не біда */ }
    }
}
