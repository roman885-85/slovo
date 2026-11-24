// =============================================================================
//  PlanPane.cs — «План:» служіння (нижній ряд, ліворуч)
// =============================================================================
//  Як NativePlanPane: рамка, зверху смужка кнопок-значків (новий, відкрити,
//  зберегти, видалити рядок, вище, нижче — 20×18 через 22), під нею список
//  (рядки 18, кегль 12, поточний пункт напівжирний). Подвійне клацання чи
//  Enter — перейти до пункту; Delete — видалити виділене; протяжкою —
//  переставити. У режимі «план проповіді» над кнопками — рядок із назвою й
//  кнопкою «Повернути план служіння».
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public sealed class PlanPane : Panel
{
    readonly FramedBox _box = new();
    readonly LayoutPanel _inside = new();
    readonly LayoutPanel _bar = new();
    readonly Border _rule = new();
    public readonly RowList List;
    public readonly IconButton ClearButton = new("doc", 11), OpenButton = new("folder", 11), SaveButton = new("square.and.arrow.down", 11),
                               DeleteButton = new("nosign", 11), UpButton = new("arrow.up", 11), DownButton = new("arrow.down", 11);
    readonly IconButton[] _buttons;
    public readonly TextBlock SermonLabel = new() { FontSize = 11, FontWeight = FontWeight.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis };
    public readonly PushButton SermonButton = new("", null, ControlSize.Small) { FontSize = 11 };
    bool _sermon;

    static ListMetrics Metrics() => new() { Padding = new Thickness(6, 1, 6, 1), TextFontDelta = 0 };

    public PlanPane()
    {
        List = new RowList(Metrics(), 12) { AllowsMultipleSelection = true, ActivatesOnReturn = true };
        List.SetUniformHeight(18);
        _buttons = new[] { ClearButton, OpenButton, SaveButton, DeleteButton, UpButton, DownButton };
        foreach (var b in _buttons) { b.Tint = () => Palette.Label; _bar.Children.Add(b); }
        _bar.Children.Add(SermonLabel);
        _bar.Children.Add(SermonButton);
        SermonLabel.Foreground = Palette.Brush(Palette.Accent);
        _inside.Children.Add(_bar);
        _inside.Children.Add(_rule);
        _inside.Children.Add(List);
        ApplyColors();
        Palette.Changed += ApplyColors;
        _inside.Layout = LayoutInside;
        _bar.Layout = LayoutBar;
        _box.Child = _inside;
        Children.Add(_box);
        SetSermon(false, "");
    }

    /// Підказки кнопок — з файла перекладу автора (TBPlanNew…).
    public void SetHints(IReadOnlyList<string> hints)
    {
        for (var i = 0; i < _buttons.Length && i < hints.Count; i++) ToolTip.SetTip(_buttons[i], hints[i]);
    }

    public void SetSermon(bool on, string title)
    {
        _sermon = on;
        SermonLabel.IsVisible = on;
        SermonButton.IsVisible = on;
        SermonLabel.Text = title;
        _inside.InvalidateArrange();
        _bar.InvalidateArrange();
    }

    public bool IsHighlighted { get => _box.IsHighlighted; set => _box.IsHighlighted = value; }

    void ApplyColors()
    {
        _bar.Background = Palette.Brush(Palette.ControlBackground);
        _rule.Background = Palette.Brush(Palette.Separator);
    }

    protected override Size ArrangeOverride(Size size)
    {
        _box.Arrange(new Rect(size));
        return size;
    }

    void LayoutInside(Size inner)
    {
        var strip = _sermon ? 24.0 : 0;
        var barHeight = 24 + strip;
        _inside.Place(_bar, new Rect(0, 0, inner.Width, barHeight));
        _inside.Place(_rule, new Rect(0, barHeight, inner.Width, 1));
        _inside.Place(List, new Rect(0, barHeight + 1, inner.Width, Math.Max(0, inner.Height - barHeight - 1)));
    }

    void LayoutBar(Size bar)
    {
        var strip = _sermon ? 24.0 : 0;
        double x = 4;
        foreach (var b in _buttons) { _bar.Place(b, new Rect(x, strip + 3, 20, 18)); x += 22; }
        if (_sermon)
        {
            var width = Math.Min(SermonButton.FittingWidth, Math.Max(0, bar.Width - 8));
            _bar.Place(SermonButton, new Rect(bar.Width - width - 4, 2, width, 20));
            _bar.Place(SermonLabel, new Rect(6, 4, Math.Max(0, bar.Width - width - 16), 16));
        }
    }
}

/// «Історія:» — останні показані місця (рядки 16, кегль 11).
public sealed class HistoryPane : Panel
{
    readonly FramedBox _box = new();
    public readonly RowList List;

    public HistoryPane()
    {
        List = new RowList(new ListMetrics { Padding = new Thickness(6, 1, 6, 1), TextFontDelta = 0 }, 11) { ActivatesOnReturn = true };
        List.SetUniformHeight(16);
        _box.Child = List;
        Children.Add(_box);
    }

    public bool IsHighlighted { get => _box.IsHighlighted; set => _box.IsHighlighted = value; }

    protected override Size ArrangeOverride(Size size) { _box.Arrange(new Rect(size)); return size; }
}
