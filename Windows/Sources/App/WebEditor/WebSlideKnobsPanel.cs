// =============================================================================
//  WebSlideKnobsPanel.cs — панель ручок оформлення (за NativeWebSlideKnobs.swift)
// =============================================================================
//  Розділи — смугою кнопок з переносом (п'ять назв на вузькій панелі не влазять
//  сегментами), нижче — ряди ручок з прокруткою: назва 12 пт, керування на всю
//  ширину (повзунок із числом, колір, список, вимикач, рядок), під ним підказка
//  10 пт до трьох рядків — або причина, чому ручка тут не діє (помаранчевим).
//  Ряди перебираються лише тоді, коли змінився їхній склад; на кожен крок
//  повзунка вони тільки перечитують своє значення — інакше повзунок під рукою
//  зникав би разом із рядом («ползунки не всегда следуют за мышью»).
// =============================================================================

using System.Globalization;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebSlideKnobsPanel : LayoutPanel
{
    public WebSlideEditorModel? Model;
    /// Вікно, над яким ставити питання й вибір кольору.
    public Func<Window?>? Owner;
    readonly FlowBar _sections = new();
    readonly ScrollViewer _scroll;
    readonly Body _body = new();
    WebSlideSection _section = WebSlideSection.Text;
    /// Чим був наповнений список рядів минулого разу.
    string _built = "";

    sealed class Body : LayoutPanel
    {
        public readonly List<KnobRow> Rows = new();
        public Body() => Layout = Arrange;

        double Total(double width) => 6 + Rows.Sum(row => row.HeightFor(Math.Max(0, width - 16)) + 4) + 6;

        protected override Size Desired(Size available)
        {
            var width = double.IsInfinity(available.Width) ? Bounds.Width : available.Width;
            return new Size(width, Total(width));
        }

        void Arrange(Size size)
        {
            double top = 6;
            foreach (var row in Rows)
            {
                // Висоту питаємо в самого ряду: довгий підпис займає два-три рядки,
                // а саме там сказано, чому ручка не діє.
                var height = row.HeightFor(Math.Max(0, size.Width - 16));
                Place(row, new Rect(8, top, Math.Max(0, size.Width - 16), height));
                top += height + 4;
            }
        }
    }

    public WebSlideKnobsPanel()
    {
        _scroll = new ScrollViewer
        {
            Content = _body,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        };
        Children.Add(_sections);
        Children.Add(_scroll);
        Layout = size =>
        {
            var barHeight = _sections.HeightFor(size.Width - 8);
            Place(_sections, new Rect(4, 0, Math.Max(0, size.Width - 8), barHeight));
            var top = barHeight + 4;
            Place(_scroll, new Rect(0, top, size.Width, Math.Max(0, size.Height - top)));
        };
    }

    // ── Наповнення ────────────────────────────────────────────────────────────

    public void Refresh()
    {
        if (Model is not { } model) return;
        var sheet = model.Sheet;
        var available = WebSlideSections.All.Where(part => sheet.Knobs.Any(knob => knob.Section == part)).ToList();
        if (!available.Contains(_section)) _section = available.Count > 0 ? available[0] : WebSlideSection.Text;

        // Сторінка без блоку налаштувань теж жива: перший же рух ручки заведе блок.
        var editable = sheet.State.Kind == WebSlideSheet.Block.Kinds.Missing && model.Current?.IsEditable == true
                       || sheet.CanAdjust || model.Current?.IsEditable == false;

        var mine = sheet.Knobs.Where(knob => knob.Section == _section).ToList();
        // Склад рядів: розділ, ручки, вписані руками значення і чи можна правити. Числа
        // сюди не входять — від них ряди не міняються.
        var signature = string.Join("\u0001", new[] { _section.Title(), editable ? "1" : "0" }
            .Concat(available.Select(part => part.Title()))
            .Concat(mine.Select(knob => knob.Name + (sheet.IsHandWritten(knob) ? "✋" : "") + (sheet.IdleReason(knob) ?? "") + (sheet.LimitNote(knob) ?? ""))));
        if (signature == _built)
        {
            foreach (var row in _body.Rows) row.Reread();
            return;
        }
        _built = signature;

        var buttons = new List<Control>();
        foreach (var part in available)
        {
            var current = part;
            var button = new PushButton(OurWords.T(part.Title())) { FontSize = 11 };
            button.Pressed = () => { _section = current; Refresh(); };
            // На Mac тут ставиться `contentTintColor` акценту, але AppKit кнопці з текстом
            // його не малює — на знімку поточний розділ виглядає, як усі. Так і тут.
            buttons.Add(button);
        }
        _sections.SetItems(buttons);

        foreach (var row in _body.Rows) _body.Children.Remove(row);
        _body.Rows.Clear();
        foreach (var knob in mine)
        {
            var row = new KnobRow(knob, model, editable, Owner);
            _body.Rows.Add(row);
            _body.Children.Add(row);
        }
        _body.InvalidateMeasure();
        InvalidateArrange();
    }

    /// Самоперевірці й знімкам: перейти в розділ так, як це робить натискання кнопки.
    public void Show(WebSlideSection part)
    {
        _section = part;
        _built = "";
        Refresh();
    }

    public IReadOnlyList<KnobRow> RowsForCheck => _body.Rows;

    // ── Одна ручка ────────────────────────────────────────────────────────────

    /// Одна ручка: назва, значення й саме керування.
    public sealed class KnobRow : LayoutPanel
    {
        static readonly FontFamily Mono = new("Cascadia Mono,Consolas,Menlo,monospace");

        readonly WebSlideKnob _knob;
        readonly WebSlideEditorModel _model;
        readonly BottomCaption _title = new() { FontSize = 12, Color = () => Palette.Label };
        readonly Note _note = new();
        readonly Control? _control;
        /// Показати в елементі нове значення, не перебудовуючи ряд.
        Action<string>? _apply;
        /// Що показано зараз: щоб не смикати елемент дарма.
        string _shown;

        public WebSlideKnob Knob => _knob;
        public Control? ControlForCheck => _control;

        public KnobRow(WebSlideKnob knob, WebSlideEditorModel model, bool enabled, Func<Window?>? owner)
        {
            _knob = knob;
            _model = model;
            Children.Add(_title);
            Children.Add(_note);
            var value = model.Sheet.Value(knob);
            _title.Text = OurWords.T(knob.Title);
            // Значення вписано руками — повзунок його не розуміє й не чіпає; показуємо як є.
            _control = model.Sheet.IsHandWritten(knob) ? new HandWritten(value) : Build(value, enabled, owner);
            _shown = value;
            Children.Add(_control);

            // Причина замість підказки: підказка розповідає, що ручка робить, а тут
            // важливіше, чому саме тут вона не зробить нічого.
            if (model.Sheet.IdleReason(knob) is { } idle)
            {
                _note.Text = OurWords.T("Здесь не действует: ") + idle;
                _note.Color = () => Palette.SystemOrange;
                Opacity = 0.55;
            }
            else if (model.Sheet.LimitNote(knob) is { } limit)
            {
                // Ручка жива, просто зараз вона стеля: кажемо, чому число рухається, а слайд ні.
                _note.Text = limit;
                _note.Color = () => Palette.SystemOrange;
            }
            else
            {
                _note.Text = OurWords.T(knob.Hint);
                _note.Color = () => Palette.SecondaryLabel;
            }
            Layout = size =>
            {
                Place(_title, new Rect(0, 0, size.Width, 16));
                Place(_control, new Rect(0, 18, size.Width, 22));
                Place(_note, new Rect(0, 42, size.Width, NoteHeight(size.Width)));
            };
        }

        /// Перечитати своє значення зі сторінки — лише коли воно справді інше: інакше
        /// повзунок, який зараз тягне рука, отримував би своє ж число й смикався.
        public void Reread()
        {
            var value = _model.Sheet.Value(_knob);
            if (value == _shown) return;
            _shown = value;
            _apply?.Invoke(value);
        }

        /// Скільки місця займе цей ряд при такій ширині.
        public double HeightFor(double width) => 42 + NoteHeight(width) + 2;

        double NoteHeight(double width)
        {
            if (_note.Text.Length == 0) return 0;
            var height = TextDraw.Height(_note.Text, Note.WrapWidth(Math.Max(40, width)), 10);
            return Math.Min(46, Math.Max(14, Math.Ceiling(height)));
        }

        static double ParseLoose(string text, double fallback)
        {
            var digits = new string(text.Where(c => "0123456789.-".Contains(c)).ToArray());
            return SwiftText.ParseDouble(digits) ?? fallback;
        }

        Control Build(string value, bool enabled, Func<Window?>? owner)
        {
            var kind = _knob.Kind;
            switch (kind.Tag)
            {
                case WebSlideKnob.KindTag.Number:
                {
                    var slider = new MacSlider { Minimum = kind.Min, Maximum = kind.Max, KnobSize = 20, Step = kind.Step };
                    slider.Value = ParseLoose(value, kind.Min);
                    var caption = new MonoCaption(value);
                    slider.ValueChanged += number =>
                    {
                        var stepped = Math.Round(number / kind.Step, MidpointRounding.AwayFromZero) * kind.Step;
                        var text = stepped == Math.Round(stepped, MidpointRounding.AwayFromZero)
                            ? ((long)Math.Round(stepped, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture)
                            : stepped.ToString("F2", CultureInfo.InvariantCulture);
                        caption.Text = text;
                        // На Mac число йшло у файл без одиниці («90» замість «90%»): для ручок
                        // спільного каталогу з vw/vh/%/em/s таке значення CSS не приймає. Пишемо з одиницею.
                        var written = text + kind.Unit;
                        _shown = written;
                        _model.Change(_knob, written);
                    };
                    _apply = text =>
                    {
                        caption.Text = text;
                        var number = ParseLoose(text, kind.Min);
                        if (Math.Abs(slider.Value - number) > kind.Step / 2) slider.Value = number;
                    };
                    slider.IsEnabled = enabled;
                    var stack = new LayoutPanel();
                    stack.Children.Add(slider);
                    stack.Children.Add(caption);
                    stack.Layout = size =>
                    {
                        var width = Math.Ceiling(caption.TextWidth) + 2;
                        stack.Place(caption, new Rect(size.Width - width, (size.Height - 16) / 2, width, 16));
                        stack.Place(slider, new Rect(0, 0, Math.Max(0, size.Width - width - 6), size.Height));
                    };
                    caption.WidthChanged = stack.InvalidateArrange;
                    return stack;
                }
                case WebSlideKnob.KindTag.Color:
                case WebSlideKnob.KindTag.ColorRGB:
                {
                    // Своє поле: смуга кольору; клацання — R, G, B (як NativeColourField).
                    var field = new ColourSwatch(WebSlideKnobColour.Parse(value)) { IsEnabled = enabled };
                    ToolTip.SetTip(field, OurWords.T("Цвет: нажмите, чтобы задать R, G, B"));
                    var editing = false;
                    field.OnClick = () =>
                    {
                        if (!field.IsEnabled) return;
                        editing = true;
                        ColourDialog.Ask(field.Colour, colour =>
                        {
                            editing = false;
                            field.Colour = colour;
                            var text = kind.Tag == WebSlideKnob.KindTag.ColorRGB ? WebSlideKnobColour.Triple(colour) : WebSlideKnobColour.Hex(colour);
                            _shown = text;
                            _model.Change(_knob, text);
                        }, owner?.Invoke(), () => editing = false);
                    };
                    _apply = text => { if (!editing) field.Colour = WebSlideKnobColour.Parse(text); };
                    return field;
                }
                case WebSlideKnob.KindTag.Choice:
                {
                    var choices = kind.Choices;
                    var popup = new PopupButton(choices.Select(choice => OurWords.T(choice.Title)), Math.Max(0, choices.ToList().FindIndex(choice => choice.Value == value)))
                    {
                        FontSize = 13, ArrowInset = 10, IsEnabled = enabled,
                    };
                    if (choices.All(choice => choice.Value != value)) popup.SelectedIndex = -1;
                    popup.Selected += index =>
                    {
                        if (index < 0 || index >= choices.Count) return;
                        _shown = choices[index].Value;
                        _model.Change(_knob, choices[index].Value);
                    };
                    _apply = text =>
                    {
                        var index = choices.ToList().FindIndex(choice => choice.Value == text);
                        if (index >= 0) popup.SelectedIndex = index;
                    };
                    return popup;
                }
                case WebSlideKnob.KindTag.Toggle:
                {
                    var on = value == kind.On;
                    var box = new MacCheckBox(OurWords.T(on ? kind.OnTitle : kind.OffTitle), 13, 14) { IsChecked = on, IsEnabled = enabled };
                    box.Toggled += isOn =>
                    {
                        box.Title = OurWords.T(isOn ? kind.OnTitle : kind.OffTitle);
                        _shown = isOn ? kind.On : kind.Off;
                        _model.Change(_knob, _shown);
                    };
                    _apply = text =>
                    {
                        box.IsChecked = text == kind.On;
                        box.Title = OurWords.T(text == kind.On ? kind.OnTitle : kind.OffTitle);
                    };
                    return box;
                }
                default:
                {
                    var field = new FormField(12) { Text = value, IsEnabled = enabled };
                    void Commit(string text)
                    {
                        if (text == _shown) return;
                        _shown = text;
                        _model.Change(_knob, text);
                    }
                    field.OnSubmit = Commit;
                    field.Box.LostFocus += (_, _) => Commit(field.Text);
                    // У поле, в якому зараз друкують, не ліземо.
                    _apply = text => { if (!field.IsFocusedField) field.Text = text; };
                    return field;
                }
            }
        }

        /// Підказка під ручкою: 10 пт, до трьох рядків.
        sealed class Note : Control
        {
            string _text = "";
            public Func<Color> Color = () => Palette.SecondaryLabel;
            public string Text { get => _text; set { _text = value; InvalidateVisual(); } }
            public Note() => Palette.Changed += InvalidateVisual;

            /// Де ламати рядки: підпис NSTextField відступає по 2 точки від країв, а SF Pro
            /// при 10 пт на півтора відсотка ширший за Inter (виміряно на знімку Mac) — інакше
            /// підказка тут виходила на рядок коротшою, і всі ряди нижче з'їжджали вгору.
            public static double WrapWidth(double width) => Math.Max(1, (width - 4) / 1.015);

            public override void Render(DrawingContext g) =>
                TextDraw.Draw(g, _text, new Rect(2, 0, WrapWidth(Bounds.Width), Bounds.Height), 10, Color(), wrap: true);
        }

        /// Значення, вписане руками: моноширинним сірим і знак руки. Як підпис NSTextField на
        /// Mac: рядок ламається за словами, а видно лише перший — довге значення разом зі
        /// знаком руки просто не влазить (на вузькій панелі руки не видно і там).
        sealed class HandWritten : Control
        {
            readonly string _text;
            public HandWritten(string text) { _text = text; Palette.Changed += InvalidateVisual; }
            public override void Render(DrawingContext g)
            {
                const double hand = 15, gap = 12;
                var width = Math.Max(1, Bounds.Width - 2);
                using var whole = new Avalonia.Media.TextFormatting.TextLayout(_text, new Typeface(Mono), 11, Palette.Brush(Palette.SecondaryLabel),
                    TextAlignment.Left, TextWrapping.Wrap, null, null, FlowDirection.LeftToRight, width, double.PositiveInfinity);
                var first = whole.TextLines.FirstOrDefault();
                if (first == null) return;
                using (g.PushClip(new Rect(0, 0, Bounds.Width, Math.Min(Bounds.Height, first.Height + 2))))
                    whole.Draw(g, new Point(2, 1));
                // Знак руки — лише коли весь рядок разом із ним стає в ширину.
                var used = whole.TextLines.Count == 1 ? first.WidthIncludingTrailingWhitespace : double.MaxValue;
                if (used + gap + hand <= width)
                    Icons.Draw(g, "hand.raised", new Rect(2 + used + gap, 1, hand, hand), Palette.SystemYellow, 1.2);
            }
        }

        /// Число біля повзунка: моноширинне 11 пт, сіре.
        sealed class MonoCaption : Control
        {
            string _text;
            public Action? WidthChanged;
            public MonoCaption(string text) { _text = text; Palette.Changed += InvalidateVisual; }
            public string Text
            {
                get => _text;
                set
                {
                    if (_text == value) return;
                    var before = TextWidth;
                    _text = value;
                    if (Math.Abs(before - TextWidth) > 0.5) WidthChanged?.Invoke();
                    InvalidateVisual();
                }
            }
            Avalonia.Media.TextFormatting.TextLayout Layout() =>
                new(_text, new Typeface(Mono), 11, Palette.Brush(Palette.SecondaryLabel), TextAlignment.Left, TextWrapping.NoWrap,
                    null, null, FlowDirection.LeftToRight, double.PositiveInfinity, double.PositiveInfinity);
            public double TextWidth => _text.Length == 0 ? 0 : Layout().WidthIncludingTrailingWhitespace;
            public override void Render(DrawingContext g) => Layout().Draw(g, new Point(0, 0));
        }
    }
}

/// Колір ручки в записі сторінки: «#RRGGBB» або «r g b» (на Mac — «r, g, b»; див. Triple).
public static class WebSlideKnobColour
{
    public static Color Parse(string text)
    {
        var cleaned = text.TrimWhitespaces();
        if (cleaned.StartsWith('#'))
        {
            var digits = new string(cleaned[1..].TakeWhile(Uri.IsHexDigit).ToArray());
            if (digits.Length == 0 || !ulong.TryParse(digits, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var value))
                return Colors.White;
            return Color.FromRgb((byte)((value >> 16) & 0xFF), (byte)((value >> 8) & 0xFF), (byte)(value & 0xFF));
        }
        // «r, g, b» і «r g b» — у сторінках трапляються обидва.
        var parts = cleaned.Split(new[] { ',', ' ' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(part => SwiftText.ParseDouble(part.TrimWhitespaces())).Where(part => part != null).Select(part => part!.Value).ToList();
        if (parts.Count < 3) return Colors.White;
        static byte B(double v) => (byte)Math.Clamp(Math.Round(v, MidpointRounding.AwayFromZero), 0, 255);
        return Color.FromRgb(B(parts[0]), B(parts[1]), B(parts[2]));
    }

    public static string Hex(Color colour) => $"#{colour.R:X2}{colour.G:X2}{colour.B:X2}";

    /// Трійка для `rgb(var(--…) / прозорість)`. На Mac тут писалося «r, g, b» через коми:
    /// таке значення ламало `rgb(r, g, b / a)` на сторінці (колір зникав), а сама ручка
    /// після цього ставала «вписаною руками». Пишемо так, як заготовки, — через пробіл.
    public static string Triple(Color colour) => $"{colour.R} {colour.G} {colour.B}";
}
