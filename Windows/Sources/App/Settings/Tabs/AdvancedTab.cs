// =============================================================================
//  AdvancedTab.cs — вкладка «Додаткові» (як NativeSettingsAdvancedTab на Mac)
// =============================================================================
//  Час плавної зміни й переходу · Дублювання слайда на монітори (список із
//  позначками, «+ − ✎ ☀») · Координати монітора · Що виводити в кінці пісні ·
//  Пошук по BackSpace, лінія через 10 віршів, колір активного поля · Номери віршів.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

/// Монітор для дублювання слайда — рядок «назва|x|y|ширина|висота|увімк|свій» (як на Mac).
public record struct DuplicateMonitor(string Name, int X, int Y, int Width, int Height, bool IsEnabled, bool IsCustom)
{
    public string Id => Name;

    public static DuplicateMonitor? FromRaw(string raw)
    {
        var f = raw.Split('|');
        if (f.Length < 6 || f[0].Length == 0) return null;
        static int I(string s, int d) => int.TryParse(s, out var v) ? v : d;
        return new DuplicateMonitor(f[0], I(f[1], 0), I(f[2], 0), I(f[3], 800), I(f[4], 600), f[5] != "0", f.Length > 6 && f[6] != "0");
    }

    public string Raw => $"{Name}|{X}|{Y}|{Width}|{Height}|{(IsEnabled ? 1 : 0)}|{(IsCustom ? 1 : 0)}";
}

public sealed class AdvancedTab : IRowSource
{
    readonly SettingsStore _store;
    readonly RowList _list = new(ListMetrics.Settings(120), 13) { Height = 96, Width = 460 };
    readonly List<FormField> _fields = new();
    int? _selected;

    public AdvancedTab(SettingsStore store)
    {
        _store = store;
        _list.SetUniformHeight(24);
        _list.Source = this;
        _list.OnSelect = (_, active, _) => { _selected = active; ShowCoordinates(); };
        _list.OnActivate = Toggle;
        _list.OnLeadClick = Toggle;
    }

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string? Hint(string key) => Captions.FormHint(key, "SettingsForm");
    ProgramOptions O => _store.Settings.Options;

    public Control Page() => new Form.Page(new[] { Timings(), Duplication(), Coordinates(), Marker(), Switches(), VerseNumbers() });

    static readonly IReadOnlyList<SlideStyle.TransitionPreset> Presets = SlideStyle.TransitionPreset.All;
    static readonly SlideStyle.Easing[] Easings = Enum.GetValues<SlideStyle.Easing>();

    Form.Group Timings() => new("", new Control[]
    {
        new Form.Row(Vb("Label16", Captions.T("Время плавной смены слайдов:")), new Control[]
        {
            Form.Number(new Tie<int>(() => O.CrossfadeTime, v => O.CrossfadeTime = v), 0, 10000), Form.Label(Vb("Label17", "мс")),
        }, 280),
        new Form.Row(Captions.T("Переход слайда:"), new Control[]
        {
            Form.Popup(Presets.Select(p => Captions.T(p.Title)).ToList(), new Tie<int>(
                () => { var raw = O.SlideTransition ?? "fade"; for (var i = 0; i < Presets.Count; i++) if (Presets[i].Kind.RawValue() == raw) return i; return 1; },
                i => { if (i < 0 || i >= Presets.Count) return; var p = Presets[i];
                       O.SlideTransition = p.Kind.RawValue(); O.SlideTransitionEasing = p.Easing.RawValue(); O.CrossfadeTime = (int)(p.Duration * 1000); }), 220),
        }, 280),
        new Form.Row(Captions.T("Кривая перехода:"), new Control[]
        {
            Form.Popup(Easings.Select(e => Captions.T(e.Title())).ToList(), new Tie<int>(
                () => { var raw = O.SlideTransitionEasing ?? "easeInOut"; for (var i = 0; i < Easings.Length; i++) if (Easings[i].RawValue() == raw) return i; return 1; },
                i => { if (i >= 0 && i < Easings.Length) O.SlideTransitionEasing = Easings[i].RawValue(); }), 160),
        }, 280),
        new Form.Row(Vb("Label18", Captions.T("Время скрытия слайда:")), new Control[]
        {
            Form.Number(new Tie<int>(() => O.HideSlideTime, v => O.HideSlideTime = v), 0, 10000), Form.Label(Vb("Label19", "мс")),
        }, 280),
    });

    Form.Group Duplication()
    {
        PushButton B(string title, string key, string fallback, Action action) => Form.Button(title, Hint(key) ?? Captions.T(fallback), action);
        var buttons = new StackPanel { Spacing = 4 };
        buttons.Children.Add(B("+", "PSBAddCustomMonitor", "Добавить монитор с ручной настройкой", AddCustom));
        buttons.Children.Add(B("−", "PSBDelCustomMonitor", "Удалить монитор с ручной настройкой", RemoveCustom));
        buttons.Children.Add(B("✎", "PSBChangeNameCustomMonitor", "Изменить название монитора с ручной настройкой", Rename));
        var flash = B("☀", "PSBShowDoubleSlideWin", "Показать позицию монитора", () => { if (Current is { } m) MonitorFlash.Show(m.X, m.Y, m.Width, m.Height); });
        flash.Symbol = "sun.max"; flash.Title = "";
        buttons.Children.Add(flash);
        return new Form.Group(Vb("Label30", Captions.T("Дублирование слайда на мониторы:")), new Control[]
        {
            new Form.Row("", new Control[] { _list, buttons }, stretch: true),
        });
    }

    Form.Group Coordinates()
    {
        _fields.Clear();
        _fields.Add(Form.Number(Coordinate(m => m.X, (m, v) => m with { X = v }), -20000, 20000));
        _fields.Add(Form.Number(Coordinate(m => m.Y, (m, v) => m with { Y = v }), -20000, 20000));
        _fields.Add(Form.Number(Coordinate(m => m.Width, (m, v) => m with { Width = v }), 1, 20000));
        _fields.Add(Form.Number(Coordinate(m => m.Height, (m, v) => m with { Height = v }), 1, 20000));
        ShowCoordinates();
        return new Form.Group(Vb("GB1", Captions.T("Координаты монитора:")), new Control[]
        {
            new Form.Row("", new Control[]
            {
                Form.Label(Vb("Label36", "X =")), _fields[0], Form.Label(Vb("Label37", "Y =")), _fields[1],
                Form.Label(Vb("Label38", "Ширина:")), _fields[2], Form.Label(Vb("Label39", "Высота:")), _fields[3],
            }),
        });
    }

    Tie<int> Coordinate(Func<DuplicateMonitor, int> get, Func<DuplicateMonitor, int, DuplicateMonitor> set) =>
        new(() => Current is { } m ? get(m) : 0, v => { if (Current is { IsCustom: true } m) Write(set(m, v)); });

    Form.Group Marker() => new("", new Control[]
    {
        new Form.Row(Vb("Label46", Captions.T("Выводить в конце последней части Песни:")), new Control[]
        {
            Form.Text(new Tie<string>(() => O.SongsEndMarker, v => O.SongsEndMarker = v), 90),
        }, 300),
    });

    Form.Group Switches() => new("", new Control[]
    {
        new Form.Row("", new Control[] { Form.Check(Vb("CBFastInputUseBackSpace", "Искать по BackSpace в \"Быстр. выборе\""),
            new Tie<bool>(() => O.FastInputUseBackSpace, v => O.FastInputUseBackSpace = v), Captions.T("Стирание символа в поле быстрого выбора сразу повторяет поиск")) }),
        new Form.Row("", new Control[] { Form.Check(Vb("CBSeparatorTenVerses", "Раздел. линией по 10 стихов"),
            new Tie<bool>(() => O.SeparatorTenVerses, v => O.SeparatorTenVerses = v), Hint("CBSeparatorTenVerses") ?? Captions.T("Отображает линию после каждого 10-го стиха Библии")) }),
        new Form.Row(Vb("Label34", "Цвет активного поля ввода:"), new Control[]
        {
            Form.Colour(new Tie<Color>(() => ToColor(O.ActiveInputFieldColor), c => O.ActiveInputFieldColor = new SlideStyle.RGBA(c.R / 255.0, c.G / 255.0, c.B / 255.0))),
        }, 280),
    });

    static Color ToColor(SlideStyle.RGBA c) => Color.FromRgb((byte)Math.Round(c.Red * 255), (byte)Math.Round(c.Green * 255), (byte)Math.Round(c.Blue * 255));

    Form.Group VerseNumbers() => new(Vb("GroupBox6", "Показывать номера стихов"), new Control[]
    {
        new Form.Row("", new Control[] { Form.Check(Vb("CBShowVersNum", "Основной перевод"), new Tie<bool>(() => O.ShowVerseNumbers, v => O.ShowVerseNumbers = v),
            Hint("CBShowVersNum") ?? Captions.T("Показывать на слайде номера стихов в Библейском тексте основного перевода")) }),
        new Form.Row("", new Control[] { Form.Check(Vb("CBShowExtQuoteVersNum", "Второй перевод"), new Tie<bool>(() => O.ShowSecondaryVerseNumbers, v => O.ShowSecondaryVerseNumbers = v),
            Hint("CBShowExtQuoteVersNum") ?? Captions.T("Показывать на слайде номера стихов в Библейском тексте второго перевода")) }),
        new Form.Row("", new Control[] { Form.Check(Captions.T("Несколько стихов — каждый с новой строки и с номером"),
            new Tie<bool>(() => O.VersesOnOwnLines ?? true, v => O.VersesOnOwnLines = v), Captions.T("Иначе стихи слипаются в один абзац через пробел")) }),
    });

    // --- Монітори для дублювання ---------------------------------------------------------

    List<DuplicateMonitor> Monitors
    {
        get
        {
            var stored = O.DoubleMonitors.Select(DuplicateMonitor.FromRaw).Where(m => m != null).Select(m => m!.Value).ToList();
            var result = new List<DuplicateMonitor>();
            var screens = MainWindow.Shared?.Screens.All ?? Array.Empty<Avalonia.Platform.Screen>();
            for (var i = 0; i < screens.Count; i++)
            {
                var s = screens[i];
                var name = s.DisplayName is { Length: > 0 } n ? n : $"{Captions.T("Монитор")} {i + 1}";
                var saved = stored.FirstOrDefault(m => m.Name == name && !m.IsCustom);
                result.Add(new DuplicateMonitor(name, s.Bounds.X, s.Bounds.Y, s.Bounds.Width, s.Bounds.Height, saved.IsEnabled, false));
            }
            result.AddRange(stored.Where(m => m.IsCustom));
            return result;
        }
    }

    DuplicateMonitor? Current => _selected is { } i && i >= 0 && i < Monitors.Count ? Monitors[i] : null;

    void Write(DuplicateMonitor monitor)
    {
        var stored = O.DoubleMonitors.Select(DuplicateMonitor.FromRaw).Where(m => m != null).Select(m => m!.Value).ToList();
        var index = stored.FindIndex(m => m.Id == monitor.Id);
        if (index >= 0) stored[index] = monitor; else stored.Add(monitor);
        O.DoubleMonitors = new ValueList<string>(stored.Select(m => m.Raw));
        _list.Reload();
    }

    void Toggle(int index)
    {
        var all = Monitors;
        if (index < 0 || index >= all.Count) return;
        Write(all[index] with { IsEnabled = !all[index].IsEnabled });
    }

    void AddCustom()
    {
        var baseName = Vb("TextMessages25", "Ручная настройка");
        var name = baseName;
        var taken = Monitors.Select(m => m.Name).ToHashSet();
        for (var i = 2; taken.Contains(name); i++) name = $"{baseName} {i}";
        Write(new DuplicateMonitor(name, 0, 0, O.DefaultWidth, O.DefaultHeight, false, true));
        _selected = Monitors.Count - 1;
        _list.SetSelection(new[] { _selected.Value }, _selected);
        ShowCoordinates();
    }

    void RemoveCustom()
    {
        if (Current is not { IsCustom: true } m) return;
        O.DoubleMonitors = new ValueList<string>(O.DoubleMonitors.Where(r => DuplicateMonitor.FromRaw(r)?.Id != m.Id));
        _selected = null;
        _list.Reload();
        ShowCoordinates();
    }

    void Rename()
    {
        if (Current is not { IsCustom: true } m) return;
        Prompt.Ask(Vb("TextMessages36", "Название монитора."), Vb("TextMessages37", "Введите новое название монитора."), m.Name, name =>
        {
            O.DoubleMonitors = new ValueList<string>(O.DoubleMonitors.Where(r => DuplicateMonitor.FromRaw(r)?.Id != m.Id));
            Write(m with { Name = string.IsNullOrEmpty(name) ? m.Name : name });
        });
    }

    void ShowCoordinates()
    {
        var m = Current;
        var values = new[] { m?.X ?? 0, m?.Y ?? 0, m?.Width ?? 0, m?.Height ?? 0 };
        for (var i = 0; i < _fields.Count; i++) { _fields[i].Text = values[i].ToString(); _fields[i].IsEnabled = m?.IsCustom ?? false; }
    }

    public int RowCount => Monitors.Count;
    public Row RowAt(int index)
    {
        var m = Monitors[index];
        return new Row(m.Name, m.IsEnabled ? "☑" : "☐", $"{m.Width} x {m.Height}");
    }
}

/// Питання з полем вводу (як NSAlert з accessoryView на Mac).
public static class Prompt
{
    /// Останнє відкрите вікно запиту — закрити його службовою командою `window-open close`.
    public static Window? Open { get; private set; }

    /// Кілька рядків (посилання — по одному в рядку): Enter переносить рядок, «Ок» — готово.
    public static void AskLines(string title, string message, Action<string> done)
    {
        var box = new TextBox
        {
            AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, Height = 96, FontSize = 12, FontFamily = UiFont.Family,
            Background = Palette.Brush(Palette.TextBackground), Foreground = Palette.Brush(Palette.Label),
            BorderBrush = Palette.Brush(Palette.Separator), BorderThickness = new Thickness(1), Padding = new Thickness(4),
        };
        var window = new Window { Title = title, Width = 460, SizeToContent = SizeToContent.Height, CanResize = false,
                                  WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground) };
        var ok = new PushButton(Captions.FormCaption("BBOk", "SettingsForm", "Ок")) { Prominent = true, Width = 90, Height = 24 };
        var cancel = new PushButton(Captions.FormCaption("BBCancel", "SettingsForm", "Отмена")) { Width = 90, Height = 24 };
        ok.Pressed = () => { done(box.Text ?? ""); window.Close(); };
        cancel.Pressed = () => window.Close();
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
        buttons.Children.Add(cancel); buttons.Children.Add(ok);
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 10,
            Children = { new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 13 }, Form.Note(message), box, buttons },
        };
        window.Opened += (_, _) => box.Focus();
        Open = window;
        window.Closed += (_, _) => { if (Open == window) Open = null; };
        var owner = (Window?)SettingsWindow.Shared ?? MainWindow.Shared;
        if (owner is { IsVisible: true }) window.ShowDialog(owner); else window.Show();
    }

    public static void Ask(string title, string message, string initial, Action<string> done)
    {
        var field = new FormField(13) { Height = 24, Text = initial };
        var window = new Window { Title = title, Width = 380, SizeToContent = SizeToContent.Height, CanResize = false,
                                  WindowStartupLocation = WindowStartupLocation.CenterOwner, Background = Palette.Brush(Palette.WindowBackground) };
        var ok = new PushButton(Captions.FormCaption("BBOk", "SettingsForm", "Ок")) { Prominent = true, Width = 90, Height = 24 };
        var cancel = new PushButton(Captions.FormCaption("BBCancel", "SettingsForm", "Отмена")) { Width = 90, Height = 24 };
        ok.Pressed = () => { done(field.Text); window.Close(); };
        cancel.Pressed = () => window.Close();
        field.OnSubmit = _ => { done(field.Text); window.Close(); };
        var buttons = new StackPanel { Orientation = Avalonia.Layout.Orientation.Horizontal, Spacing = 8, HorizontalAlignment = Avalonia.Layout.HorizontalAlignment.Right };
        buttons.Children.Add(cancel); buttons.Children.Add(ok);
        window.Content = new StackPanel
        {
            Margin = new Thickness(20), Spacing = 10,
            Children = { new TextBlock { Text = title, FontWeight = FontWeight.Bold, FontSize = 13 }, Form.Note(message), field, buttons },
        };
        Open = window;
        window.Closed += (_, _) => { if (Open == window) Open = null; };
        var owner = (Window?)SettingsWindow.Shared ?? MainWindow.Shared;
        if (owner is { IsVisible: true }) window.ShowDialog(owner); else window.Show();
    }
}
