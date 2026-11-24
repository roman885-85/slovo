// =============================================================================
//  InterfaceWindows.cs — «Стиль інтерфейсу програми» і «Вибір мови» (7.2, 7.3)
// =============================================================================
//  Як NativeInterfaceStyleView і NativeSelectLangView на Mac. Стиль: три
//  оформлення (за системою, світле, темне) і список стилів оригіналу (Styles/
//  *.vsf — теми Delphi VCL, застосувати їх тут не можна). Мова: файли
//  перекладу оригіналу й свої (прапорець, назва, код) плюс убудовані мови;
//  подвійне клацання — вибрати й закрити.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Slovo.Core;

namespace Slovo.App;

public sealed class InterfaceStyleWindow : Window
{
    static InterfaceStyleWindow? _shown;

    public static InterfaceStyleWindow Open(AppState state)
    {
        if (_shown is { } open) { open.Activate(); return open; }
        var window = _shown = new InterfaceStyleWindow(state);
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    InterfaceStyleWindow(AppState state)
    {
        Title = Captions.T("Стиль интерфейса программы");
        Width = 460; Height = 430;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        var settings = InterfaceSettings.Shared;
        var panel = new LayoutPanel();
        var heading = new BottomCaption { Text = Captions.T("Оформление программы"), FontSize = 12, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        var radios = new List<MacRadio>();
        foreach (var option in Enum.GetValues<InterfaceSettings.Appearance>())
        {
            var radio = new MacRadio(Captions.T(option switch { InterfaceSettings.Appearance.Light => "Светлое", InterfaceSettings.Appearance.Dark => "Тёмное", _ => "По системе" }))
            { IsChecked = settings.Look == option };
            radio.Chosen += () =>
            {
                foreach (var other in radios) other.IsChecked = other == radio;
                settings.Look = option;
            };
            radios.Add(radio);
        }
        var originalsHeading = new BottomCaption { Text = Captions.T("Стили оригинала"), FontSize = 12, Weight = FontWeight.SemiBold, Color = () => Palette.Label };
        var explanation = new TextBlock
        {
            Text = Captions.T("Файлы Styles/*.vsf — темы Delphi VCL. Новая программа рисует окна сама, без VCL, поэтому применить их здесь нельзя."),
            FontSize = 11, TextWrapping = TextWrapping.Wrap, Foreground = Palette.Brush(Palette.SecondaryLabel), FontFamily = UiFont.Family,
        };
        var names = OriginalStyleNames(Path.GetDirectoryName(state.ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')) ?? DataHome.Folder);
        var list = new TextBox
        {
            Text = names.Count == 0 ? Captions.T("Папка Styles не найдена") : string.Join("\n", names.Select(n => "🚫  " + n)),
            IsReadOnly = true, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap, FontSize = 12, Padding = new Thickness(6),
            Foreground = Palette.Brush(Palette.SecondaryLabel), Background = Palette.Brush(Palette.TextBackground),
            BorderBrush = Palette.Brush(Palette.Separator), BorderThickness = new Thickness(1), MinWidth = 0, FontFamily = UiFont.Family,
        };
        var close = new PushButton(Captions.T("Закрыть")) { Pressed = Close, Prominent = true };
        foreach (Control c in new Control[] { heading, originalsHeading, explanation, list, close }.Concat(radios)) panel.Children.Add(c);
        panel.Layout = size =>
        {
            const double gap = 14;
            var width = size.Width - gap * 2;
            panel.Place(heading, new Rect(gap, gap, width, 18));
            // Стовпчик перемикачів — рамка по 24 на рядок, усередині крок 20 (16 + 4), як NSStackView.
            var y = gap + 18 + 6;
            for (var i = 0; i < radios.Count; i++) panel.Place(radios[i], new Rect(gap, y + i * 20, width, 16));
            y += radios.Count * 24;
            panel.Place(originalsHeading, new Rect(gap, y + 12, width, 18));
            panel.Place(explanation, new Rect(gap, y + 12 + 18 + 4, width, 44));
            var top = y + 12 + 18 + 4 + 44 + 6;
            panel.Place(list, new Rect(gap, top, width, Math.Max(0, size.Height - top - 48)));
            panel.Place(close, new Rect(size.Width - gap - 100, size.Height - 36, 100, 24));
        };
        Content = panel;
        KeyDown += (_, e) => { if (e.Key is Avalonia.Input.Key.Escape or Avalonia.Input.Key.Enter) Close(); };
    }

    /// Імена стилів оригіналу — файли Styles/*.vsf поруч із модулями.
    public static List<string> OriginalStyleNames(string dataRoot)
    {
        var folder = Path.Combine(dataRoot, "Styles");
        if (!Directory.Exists(folder)) return new List<string>();
        var names = Directory.EnumerateFiles(folder).Where(f => Path.GetExtension(f).Equals(".vsf", StringComparison.OrdinalIgnoreCase))
                             .Select(Path.GetFileNameWithoutExtension).OfType<string>().ToList();
        names.Sort(SwiftText.LocalizedStandardCompare);
        return names;
    }
}

public sealed class LanguagePickerWindow : Window
{
    static LanguagePickerWindow? _shown;
    readonly List<(string Code, string Name, string? Flag)> _languages;
    readonly RowList _list;

    public static LanguagePickerWindow Open()
    {
        if (_shown is { } open) { open.Activate(); return open; }
        var window = _shown = new LanguagePickerWindow();
        window.Closed += (_, _) => _shown = null;
        if (MainWindow.Shared is { } owner && ((Visual)owner).IsVisible) window.Show(owner); else window.Show();
        return window;
    }

    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SelectLangForm", fallback);

    /// Усі переклади: оригіналу й свої — і вбудовані мови, яких серед файлів немає.
    public static List<(string Code, string Name, string? Flag)> All()
    {
        var result = new List<(string Code, string Name, string? Flag)>();
        foreach (var file in Languages.Files()) result.Add((file.Code, file.DisplayName, Languages.Flag(file.Code)));
        var known = result.Select(l => l.Code.ToLowerInvariant()).ToHashSet();
        foreach (var (code, name) in Languages.BuiltIn) if (!known.Contains(code)) result.Add((code, name, null));
        return result;
    }

    LanguagePickerWindow()
    {
        Title = Captions.Caption("N14", "Language/Язык");
        Width = 340; Height = 460; CanResize = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Background = Palette.Brush(Palette.WindowBackground);
        _languages = All();
        var caption = new BottomCaption { Text = Vb("Label1", "Выберите язык интерфейса программы"), FontSize = 12, Color = () => Palette.Label };
        // Звичайна таблиця (не .inset): рядок на всю ширину, без полів по боках.
        _list = new RowList(new ListMetrics { LeadWidth = 0, DetailWidth = 46, DetailFontDelta = -2, Padding = new Thickness(34, 2, 14, 2) }, 13)
            { Source = new Rows(this), ContentInset = new Thickness(0) };
        _list.SetUniformHeight(22);
        // Подвійне клацання — швидкий шлях: вибрати й закрити.
        _list.OnActivate = _ => Apply();
        var current = _languages.FindIndex(l => string.Equals(l.Code, Languages.Code, StringComparison.OrdinalIgnoreCase));
        if (current >= 0) _list.SetSelection(new[] { current }, current);
        var cancel = new PushButton(Vb("PBBCancel", "Отмена")) { Pressed = Close };
        var ok = new PushButton(Vb("PBBOk", "Ок")) { Pressed = Apply, Prominent = true };
        var flags = new FlagColumn(this);
        var panel = new LayoutPanel();
        foreach (Control c in new Control[] { caption, _list, flags, cancel, ok }) panel.Children.Add(c);
        panel.Layout = size =>
        {
            const double gap = 12;
            panel.Place(caption, new Rect(gap, gap, size.Width - gap * 2, 18));
            var listRect = new Rect(gap, gap + 18 + 6, size.Width - gap * 2, Math.Max(0, size.Height - (gap + 18) - 56));
            panel.Place(_list, listRect);
            panel.Place(flags, listRect);
            var right = size.Width - gap;
            foreach (var button in new[] { ok, cancel })
            {
                var width = Math.Max(80, button.FittingWidth + 24);
                panel.Place(button, new Rect(right - width, size.Height - 36, width, 24));
                right -= width + 8;
            }
        };
        Content = panel;
        KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Escape) Close();
            else if (e.Key == Avalonia.Input.Key.Enter) Apply();
        };
    }

    void Apply()
    {
        if (_list.Selection.FirstOrDefault(-1) is var row && (row < 0 || row >= _languages.Count)) return;
        Languages.Set(_languages[row].Code, DataHome.Folder);
        Close();
    }

    sealed class Rows : IRowSource
    {
        readonly LanguagePickerWindow _owner;
        public Rows(LanguagePickerWindow owner) { _owner = owner; }
        public int RowCount => _owner._languages.Count;
        public Row RowAt(int index) => new(_owner._languages[index].Name, "", _owner._languages[index].Code) { SingleLine = true };
    }

    /// Прапорці перед назвами (18×13) — місце тримаємо й тоді, коли прапорця немає.
    sealed class FlagColumn : Control
    {
        readonly LanguagePickerWindow _owner;
        readonly Dictionary<string, Bitmap?> _bitmaps = new();
        public FlagColumn(LanguagePickerWindow owner) { _owner = owner; IsHitTestVisible = false; }

        public override void Render(DrawingContext g)
        {
            var list = _owner._list;
            var (first, end) = list.VisibleItems;
            for (var row = first; row < end; row++)
            {
                if (row < 0 || row >= _owner._languages.Count || _owner._languages[row].Flag is not { } path) continue;
                if (!_bitmaps.TryGetValue(path, out var bitmap))
                {
                    try { bitmap = new Bitmap(path); } catch { bitmap = null; }
                    _bitmaps[path] = bitmap;
                }
                if (bitmap == null || list.FrameOfItem(row) is not { } rect) continue;
                g.DrawImage(bitmap, new Rect(rect.X + 10, rect.Y + (rect.Height - 13) / 2, 18, 13));
            }
        }
    }
}
