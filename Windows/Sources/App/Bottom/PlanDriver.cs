// =============================================================================
//  PlanDriver.cs — «План:» живе (як NativePlanPane на Mac)
// =============================================================================
//  Рядки беруться з AppState.Plan за номером: «назва - підпис», поданий пункт —
//  напівжирний. Клацання лише виділяє; подвійне клацання чи Enter — подати.
//  Кнопки працюють за виділенням, а без нього — за поданим пунктом. Протяжка
//  переставляє пункт. Del і Backspace у списку — видалити; стрілки при фокусі
//  на плані (F2) гортають план. Меню: «Перейти», риска, «Видалити», «Очистити план».
// =============================================================================

using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class PlanDriver : IRowSource
{
    readonly AppState _state;
    readonly PlanPane _pane;
    /// Готові рядки — перезбираються лише зі зміною складу плану.
    List<string> _captions = new();
    int? _currentRow;
    int _planStamp;

    public PlanDriver(AppState state, PlanPane pane)
    {
        _state = state;
        _pane = pane;
        var list = pane.List;
        list.Source = this;
        list.FontSize = state.ListFontSize;
        list.OnSelect = (selection, _, cause) =>
        {
            if (cause == SelectCause.Code) return;
            state.SetPlanSelection(selection.Select(i => state.Plan[i]?.Id).OfType<Guid>());
            UpdateButtons();
        };
        // Клацання лише виділяє пункт; подвійне клацання чи Enter — подає (власник, 14.09.2026).
        list.OnActivate = index => { if (state.Plan[index] is { } item) state.ActivatePlanItem(item); };
        list.OnMove = (from, to) => state.MovePlan(new[] { from }, to);
        // Del, Backspace, стрілки й Enter при фокусі на Плані — у KeyHandling.PlanKey.
        list.GotFocus += (_, _) => SetFocused(true);
        list.LostFocus += (_, _) => SetFocused(false);

        pane.ClearButton.Pressed = AskAndClear;
        pane.OpenButton.Pressed = () => _ = OpenPlan();
        pane.SaveButton.Pressed = () => _ = SavePlan();
        pane.DeleteButton.Pressed = DeleteSelected;
        pane.UpButton.Pressed = () => state.MovePlanSelection(-1);
        pane.DownButton.Pressed = () => state.MovePlanSelection(1);
        pane.SermonButton.Pressed = state.EndSermon;

        Signals.Shared.Subscribe(Signals.Kind.Plan, () => { Reload(); UpdateSermonStrip(); });
        // Той самий повзунок кегля, що й для решти списків вікна.
        Signals.Shared.Subscribe(Signals.Kind.ListFontSize, () => { list.FontSize = state.ListFontSize; list.Reload(); });
        Signals.Shared.Subscribe(Signals.Kind.Language, () => { ApplyCaptions(); UpdateSermonStrip(); });
        // «План не прочитався» — одразу вікном з однією кнопкою, як в оригіналі.
        state.PlanWarning += text => Alert.Tell(Captions.T("Файл плана"), text);
        KeyHandling.FocusPlan = () => list.Focus();
        // Пункт плану — з усіх місць, де є «Додати в План».
        state.AddSongToPlan = state.AddSongToPlanItems;
        state.AddTextToPlan = document => state.AddToPlan(new[] { PlanItem.TextItem(document) });

        ApplyCaptions();
        state.LoadLastPlan();
        Reload();
        UpdateSermonStrip();
    }

    // --- Рядки ---------------------------------------------------------------------------

    public int RowCount => _captions.Count;

    // Поданий пункт відрізняється лише накресленням — зайвих позначок у автора немає.
    public Row RowAt(int index) => new(_captions[index]) { SingleLine = true, Bold = index == _currentRow };

    /// Рівно три пункти зі знімка посібника: «Перейти», риска, «Видалити» і «Очистити план».
    public ContextMenu? MenuAt(int index)
    {
        if (_state.Plan[index] is not { } item) return null;
        return MenuStrip.Build(new[]
        {
            new MenuEntry(Caption("MenuItem1", "Перейти"), () => _state.ActivatePlanItem(item)),
            new MenuEntry(Caption("MenuItem3", "Удалить"), () => _state.DeletePlan(new[] { index }), StartsGroup: true),
            new MenuEntry(Caption("MenuItem4", "Очистить план"), AskAndClear),
        });
    }

    /// Привід Plan приходить і на зміну складу, і на виділення, і на подачу пункту:
    /// розбираємо, що саме змінилось, і робимо рівно це.
    void Reload()
    {
        var plan = _state.Plan;
        var hash = new HashCode();
        foreach (var item in plan.Items) hash.Add(item.Id);
        var stamp = hash.ToHashCode();
        if (stamp != _planStamp || _captions.Count != plan.Count)
        {
            _planStamp = stamp;
            _captions = plan.Items.Select(item => item.Subtitle is { Length: > 0 } subtitle ? $"{item.Title} - {subtitle}" : item.Title).ToList();
            _currentRow = plan.CurrentIndex;
            _pane.List.Reload();
        }
        else if (_currentRow != plan.CurrentIndex)
        {
            // Змінився лише поданий пункт: перемалювати рівно два рядки.
            var was = _currentRow;
            _currentRow = plan.CurrentIndex;
            if (was is { } w) _pane.List.ReloadRow(w);
            if (_currentRow is { } now) _pane.List.ReloadRow(now);
        }
        var rows = _state.SelectedPlanPositions;
        _pane.List.SetSelection(rows, rows.Count > 0 ? rows[0] : null);
        UpdateButtons();
    }

    void UpdateButtons()
    {
        var empty = _state.Plan.IsEmpty;
        _pane.ClearButton.IsEnabled = !empty;
        _pane.SaveButton.IsEnabled = !empty;
        var positions = Working;
        _pane.DeleteButton.IsEnabled = positions.Count > 0;
        // «Вище» й «нижче» рухають один пункт.
        _pane.UpButton.IsEnabled = positions.Count == 1 && positions[0] > 0;
        _pane.DownButton.IsEnabled = positions.Count == 1 && positions[0] < _state.Plan.Count - 1;
    }

    /// Кнопки працюють за виділенням, а без нього — за поданим пунктом.
    List<int> Working
    {
        get
        {
            var positions = _state.SelectedPlanPositions;
            if (positions.Count > 0) return positions;
            return _state.Plan.CurrentIndex is { } current ? new List<int> { current } : new List<int>();
        }
    }

    void DeleteSelected()
    {
        var positions = Working;
        if (positions.Count == 0) return;
        _state.DeletePlan(positions);
    }

    /// Смужка проповіді — лише коли план служіння відкладено.
    void UpdateSermonStrip()
    {
        var title = _state.Plan.Title.Trim();
        _pane.SermonButton.Title = Captions.T("Вернуть план служения");
        _pane.SetSermon(_state.IsSermon, title.Length == 0 ? Captions.T("План проповеди") : Captions.T("План проповеди: %s", title));
    }

    /// Рамка списку кольорова, поки клавіатура в ньому: стрілки зараз гортають план.
    void SetFocused(bool focused)
    {
        _pane.IsHighlighted = focused;
        _state.IsPlanFocused = focused;
    }

    void AskAndClear()
    {
        if (_state.Plan.IsEmpty) return;
        // В оригіналі — питання з «Так» і «Ні».
        Alert.Ask(Captions.Caption("TextMessages27", "Очистка плана"), Captions.Caption("TextMessages28", "Все пункты плана будут удалены. Уверены?"),
                  new[] { Caption("TextMessages6", "Да"), Caption("TextMessages7", "Нет") },
                  answer => { if (answer == 0) _state.ClearPlan(); });
    }

    /// «Завантажити план»: тип файла не обмежуємо — плани оригіналу .ini, наші давні — .json.
    async Task OpenPlan()
    {
        if (MainWindow.Shared?.StorageProvider is not { } storage) return;
        var files = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Captions.T("Файл плана служения"),
            AllowMultiple = false,
            SuggestedStartLocation = await storage.TryGetFolderFromPathAsync(_state.PlanOpenFolder),
        });
        if (files.Count > 0 && files[0].TryGetLocalPath() is { } path) _state.LoadPlan(path);
    }

    /// «Зберегти план»: план з теки оригіналу поверх чужого файла не пишемо — питаємо ім'я.
    async Task SavePlan()
    {
        if (_state.PlanSaveTarget is { } target) { _state.WritePlan(target); return; }
        if (MainWindow.Shared?.StorageProvider is not { } storage) return;
        Directory.CreateDirectory(AppState.PlansFolder);
        var file = await storage.SaveFilePickerAsync(new FilePickerSaveOptions
        {
            Title = Captions.T("Куда сохранить план служения"),
            SuggestedFileName = AppState.PlanFileName(_state.Plan.Title),
            DefaultExtension = ServicePlan.JournalFileExtension,
            SuggestedStartLocation = await storage.TryGetFolderFromPathAsync(AppState.PlansFolder),
        });
        if (file?.TryGetLocalPath() is { } path) _state.WritePlan(path);
    }

    /// Підписи кнопок плану в автора — у підказках (TBPlanNew…), на кнопці лише значок.
    void ApplyCaptions()
    {
        var hints = new (string Key, string Fallback)[]
        {
            ("TBPlanNew", "Очистить план"), ("TBPlanOpen", "Загрузить план"), ("TBPlanSave", "Сохранить план"),
            ("TBPlanDel", "Удалить строку"), ("TBPlanUp", "Переместить выше"), ("TBPlanDown", "Переместить ниже"),
        };
        _pane.SetHints(hints.Select(h => Captions.MainHint(h.Key, h.Fallback)).ToList());
    }

    /// Підписи пунктів і кнопок питання в автора — з амперсандом підкреслення («&Удалить»).
    static string Caption(string key, string fallback) => Captions.Caption(key, fallback).Replace("&", "");
}
