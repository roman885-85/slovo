// =============================================================================
//  Form.cs — набір частин для вікна «Параметри» (як NativeForm на Mac)
// =============================================================================
//  Дев'ять вкладок оригіналу — щільні форми Delphi: рамка з підписом, усередині
//  ряди «підпис — поле». Тут так само: ряд сам рахує свою висоту, група складає
//  ряди згори донизу, сторінка — групи з прокруткою. Зв'язок із налаштуваннями —
//  парою «прочитати/записати» (Tie): пишуть прямо в знімок налаштувань, а коли
//  зберегти на диск, вирішує кнопка «Гаразд».
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace Slovo.App;

public readonly record struct Tie<T>(Func<T> Get, Action<T> Set);

public static class Form
{
    /// Оновити значення всіх полів сторінки (після «Скинути…» чи «Узяти з файла…»).
    static readonly System.Runtime.CompilerServices.ConditionalWeakTable<Control, Action> Refreshers = new();
    static void OnRefresh(Control c, Action refresh) => Refreshers.AddOrUpdate(c, refresh);

    public static void RefreshValues(Control root)
    {
        if (Refreshers.TryGetValue(root, out var refresh)) refresh();
        if (root is Panel panel) foreach (var child in panel.Children) RefreshValues(child);
        else if (root is ContentControl cc && cc.Content is Control content) RefreshValues(content);
        else if (root is Decorator d && d.Child is Control inner) RefreshValues(inner);
    }

    // --- Ряд і група ----------------------------------------------------------

    /// Ряд: підпис праворуч у колонці `width`, далі керування з проміжком 6.
    public sealed class Row : LayoutPanel
    {
        readonly BottomCaption _label = new() { FontSize = 11, Align = TextAlignment.Right, Color = () => Palette.Label };
        readonly StackPanel _content = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
        readonly double _labelWidth;

        public Row(string title, IEnumerable<Control> views, double width = 150, bool stretch = false)
        {
            _labelWidth = title.Length == 0 ? 0 : width;
            _label.Text = title;
            Children.Add(_label);
            Children.Add(_content);
            foreach (var v in views) { v.VerticalAlignment = VerticalAlignment.Center; _content.Children.Add(v); }
            if (stretch && _content.Children.Count > 0)
            {
                // Перший вид забирає всю ширину, що лишилась.
                var dock = new DockPanel { LastChildFill = true };
                var first = _content.Children[0];
                _content.Children.Clear();
                foreach (var v in views.Skip(1)) { DockPanel.SetDock(v, Dock.Right); dock.Children.Add(v); }
                dock.Children.Add(first);
                Children.Remove(_content);
                Children.Add(dock);
                _stretch = dock;
            }
            Layout = Arrange;
            Inherit(title, views);
        }

        readonly Control? _stretch;

        public double NeededHeight
        {
            get
            {
                var content = (Control?)_stretch ?? _content;
                content.Measure(new Size(10000, 10000));
                return Math.Max(22, content.DesiredSize.Height);
            }
        }

        void Arrange(Size size)
        {
            Place(_label, new Rect(0, (size.Height - 16) / 2, _labelWidth, 16));
            var left = _labelWidth == 0 ? 0 : _labelWidth + 8;
            Place((Control?)_stretch ?? _content, new Rect(left, 0, Math.Max(0, size.Width - left), size.Height));
        }

    }

    /// Рамка з підписом у лівому верхньому куті — TGroupBox Delphi.
    public sealed class Group : LayoutPanel
    {
        readonly BottomCaption _title = new() { FontSize = 11, Weight = FontWeight.SemiBold };
        readonly Border _frame = new() { CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1) };
        readonly List<Control> _rows;

        public Group(string caption, IEnumerable<Control> rows)
        {
            _rows = rows.ToList();
            _title.Text = caption;
            Children.Add(_frame);
            Children.Add(_title);
            foreach (var r in _rows) Children.Add(r);
            Layout = Arrange;
            Apply();
            Palette.Changed += Apply;
            Inherit(caption, _rows);
        }

        void Apply()
        {
            _frame.BorderBrush = Palette.Brush(Palette.IsDark ? Color.FromArgb(26, 255, 255, 255) : Color.FromArgb(26, 0, 0, 0));
            _frame.Background = Palette.Brush(Palette.IsDark ? Color.FromArgb(8, 255, 255, 255) : Color.FromArgb(8, 0, 0, 0));
        }

        static double RowHeight(Control row) => row is Row r ? r.NeededHeight : MeasureHeight(row);
        static double MeasureHeight(Control c) { c.Measure(new Size(900, 10000)); return Math.Max(22, c.DesiredSize.Height); }

        /// Висота — за рядами: обрізати ряд не можна, за ним стоїть налаштування.
        public double NeededHeight => 24 + _rows.Sum(r => RowHeight(r) + 6) + 6;

        void Arrange(Size size)
        {
            Place(_frame, new Rect(size));
            Place(_title, new Rect(10, 4, Math.Max(0, size.Width - 20), 16));
            double top = 24;
            foreach (var row in _rows)
            {
                var h = RowHeight(row);
                Place(row, new Rect(10, top, Math.Max(0, size.Width - 20), h));
                top += h + 6;
            }
        }
    }

    /// Сторінка вкладки: групи згори донизу з прокруткою.
    public sealed class Page : ScrollViewer
    {
        readonly LayoutPanel _body = new();
        readonly List<Group> _groups;

        public Page(IEnumerable<Group> groups)
        {
            _groups = groups.ToList();
            foreach (var g in _groups) _body.Children.Add(g);
            _body.Layout = Arrange;
            Content = new BodyHost(this, _body);
            HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled;
            VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto;
        }

        public double BodyHeight => 12 + _groups.Sum(g => g.NeededHeight + 10) + 12;

        void Arrange(Size size)
        {
            double top = 12;
            foreach (var g in _groups)
            {
                var h = g.NeededHeight;
                _body.Place(g, new Rect(12, top, Math.Max(0, size.Width - 24), h));
                top += h + 10;
            }
        }

        sealed class BodyHost : Decorator
        {
            readonly Page _page;
            public BodyHost(Page page, Control body) { _page = page; Child = body; }
            protected override Size MeasureOverride(Size available)
            {
                var w = double.IsInfinity(available.Width) ? 800 : available.Width;
                Child!.Measure(new Size(w, _page.BodyHeight));
                return new Size(w, _page.BodyHeight);
            }
            protected override Size ArrangeOverride(Size size) { Child!.Arrange(new Rect(size)); return size; }
        }
    }

    // --- Керування --------------------------------------------------------------

    public static MacCheckBox Check(string title, Tie<bool> tie, string? hint = null)
    {
        var box = new MacCheckBox(title, 11, 13) { IsChecked = tie.Get() };
        if (hint != null) ToolTip.SetTip(box, hint);
        box.Toggled += on => tie.Set(on);
        OnRefresh(box, () => box.IsChecked = tie.Get());
        return box;
    }

    public static Control Choice(IReadOnlyList<string> titles, Tie<int> tie)
    {
        var stack = new StackPanel { Spacing = 2 };
        var radios = new List<MacRadio>();
        for (var i = 0; i < titles.Count; i++)
        {
            var index = i;
            var radio = new MacRadio(titles[i], 11, 12) { IsChecked = tie.Get() == i, Height = 18 };
            radio.Chosen += () => { foreach (var other in radios) other.IsChecked = other == radio; tie.Set(index); };
            radios.Add(radio);
            stack.Children.Add(radio);
        }
        OnRefresh(stack, () => { for (var i = 0; i < radios.Count; i++) radios[i].IsChecked = tie.Get() == i; });
        return stack;
    }

    public static PopupButton Popup(IReadOnlyList<string> titles, Tie<int> tie, double width = 240)
    {
        var popup = new PopupButton(titles.Count == 0 ? new[] { "" } : titles,
                                    Math.Clamp(tie.Get(), 0, Math.Max(0, titles.Count - 1))) { Width = width, Height = 22 };
        popup.Selected += i => tie.Set(i);
        OnRefresh(popup, () => popup.SelectedIndex = Math.Clamp(tie.Get(), 0, Math.Max(0, popup.Items.Count - 1)));
        return popup;
    }

    static string Show(double value) => value == Math.Round(value) ? ((long)value).ToString() : value.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture);

    public static FormField Decimal(Tie<double> tie, double min, double max, double step = 0.25, double width = 80)
    {
        var field = new FormField(11, rightAligned: true) { Width = width, Height = 22 };
        field.Text = Show(tie.Get());
        void Commit()
        {
            var typed = double.TryParse(field.Text.Replace(',', '.'), System.Globalization.NumberStyles.Float,
                                        System.Globalization.CultureInfo.InvariantCulture, out var v) ? v : tie.Get();
            var stepped = step > 0 ? Math.Round(typed / step) * step : typed;
            var value = Math.Min(Math.Max(stepped, min), max);
            tie.Set(value);
            field.Text = Show(value);
        }
        field.OnSubmit = _ => Commit();
        field.Box.LostFocus += (_, _) => Commit();
        OnRefresh(field, () => { if (!field.IsFocusedField) field.Text = Show(tie.Get()); });
        return field;
    }

    public static FormField Number(Tie<int> tie, int min, int max, double width = 80)
    {
        var field = new FormField(11, rightAligned: true) { Width = width, Height = 22 };
        field.Text = tie.Get().ToString();
        void Commit()
        {
            var value = Math.Min(Math.Max(int.TryParse(field.Text, out var v) ? v : tie.Get(), min), max);
            tie.Set(value);
            field.Text = value.ToString();
        }
        field.OnSubmit = _ => Commit();
        field.Box.LostFocus += (_, _) => Commit();
        OnRefresh(field, () => { if (!field.IsFocusedField) field.Text = tie.Get().ToString(); });
        return field;
    }

    public static FormField Text(Tie<string> tie, double width = 260)
    {
        var field = new FormField(11) { Width = width, Height = 22 };
        field.Text = tie.Get();
        field.OnSubmit = text => tie.Set(text);
        field.Box.LostFocus += (_, _) => tie.Set(field.Text);
        OnRefresh(field, () => { if (!field.IsFocusedField) field.Text = tie.Get(); });
        return field;
    }

    public static Control Slider(Tie<double> tie, double min, double max, Func<double, string> format, double width = 200, double captionWidth = 80)
    {
        var slider = new MacSlider { Minimum = min, Maximum = max, Value = tie.Get(), Width = width, Height = 20, KnobSize = 18, Step = (max - min) / 100 };
        var caption = new BottomCaption(format(tie.Get())) { FontSize = 11, Width = captionWidth, Height = 16 };
        slider.ValueChanged += v => { tie.Set(v); caption.Text = format(v); };
        var stack = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        stack.Children.Add(slider);
        stack.Children.Add(caption);
        OnRefresh(stack, () => { var v = tie.Get(); if (Math.Abs(slider.Value - v) > 0.0001) slider.Value = v; caption.Text = format(v); });
        return stack;
    }

    /// Поле кольору: клацання — вікно «R, G, B» (як NativeColourField на Mac).
    public static ColourSwatch Colour(Tie<Color> tie)
    {
        var swatch = new ColourSwatch(tie.Get()) { Width = 44, Height = 20 };
        swatch.OnClick = () => ColourDialog.Ask(swatch.Colour, c => { swatch.Colour = c; tie.Set(c); });
        OnRefresh(swatch, () => swatch.Colour = tie.Get());
        return swatch;
    }

    public static PushButton Button(string title, string? hint, Action action)
    {
        var button = new PushButton(title) { FontSize = 11 };
        if (Symbols.TryGetValue(title, out var symbol)) { button.Symbol = symbol; button.Title = ""; button.MinWidth = 30; }
        if (hint != null) ToolTip.SetTip(button, hint);
        button.Pressed = action;
        button.Height = 22;
        return button;
    }

    public static readonly Dictionary<string, string> Symbols = new()
    {
        ["+"] = "plus", ["＋"] = "plus", ["−"] = "minus", ["-"] = "minus",
        ["↑"] = "arrow.up", ["↓"] = "arrow.down", ["↗"] = "arrow.up.right", ["↳"] = "arrow.turn.down.right",
        ["🔍"] = "magnifyingglass", ["⤓"] = "square.and.arrow.down", ["⤓…"] = "square.and.arrow.down.on.square",
        ["✎"] = "pencil", ["⧉"] = "doc.on.doc", ["🗑"] = "trash", ["☑"] = "checkmark.square", ["☐"] = "square",
    };

    public static TextBlock Note(string text) => new()
    {
        Text = text, FontSize = 11, TextWrapping = TextWrapping.Wrap, MaxWidth = 600, MaxLines = 4,
        Foreground = Palette.Brush(Palette.SecondaryLabel), FontFamily = UiFont.Family,
    };

    public static TextBlock Label(string text, bool secondary = true) => new()
    {
        Text = text, FontSize = 11, FontFamily = UiFont.Family,
        Foreground = Palette.Brush(secondary ? Palette.SecondaryLabel : Palette.Label),
    };

    /// Підказка поля — з підпису ряду, якщо своєї немає (як inheritHint на Mac).
    static void Inherit(string caption, IEnumerable<Control> views)
    {
        var text = caption.Trim(' ', ':');
        if (text.Length == 0) return;
        foreach (var v in views)
            if (v is PopupButton or MacSlider or Segmented && ToolTip.GetTip(v) == null) ToolTip.SetTip(v, text);
    }
}
