// =============================================================================
//  BottomRow.cs — нижній ряд: План | Історія | Попередній перегляд | Живий
//  екран | Керування
// =============================================================================
//  Як NativeBottomRow на Mac. Ширини Плану й Історії — від запам'ятованих (або
//  своїх «авто»), перегляд — 4:3 і не вужчий за 280; бракує місця — спершу
//  віддає План, потім Історія, потім живий екран. Межі між панелями тягнуться.
// =============================================================================

using Avalonia;
using Avalonia.Controls;

namespace Slovo.App;

public sealed class BottomRow : LayoutPanel
{
    public readonly PlanPane Plan = new();
    public readonly HistoryPane History = new();
    public readonly SlideFrameView Preview = new() { MarksLive = true };
    public readonly SlideFrameView Mirror = new();
    public readonly PointerBar PointerBar = new();
    public readonly FocusBar FocusBar = new();
    public readonly ControlPanel Control = new();
    readonly PushButton _mirrorWindowButton = new("⤢", null, ControlSize.Mini) { Bordered = false, FontSize = 11 };
    readonly WidthGrip _liveDivider = new();
    public readonly WidthGrip PlanDivider = new(), HistoryDivider = new();
    readonly BottomCaption _planCaption = new(), _historyCaption = new(), _previewCaption = new(), _liveCaption = new(), _controlCaption = new();
    public double LastPreviewWidth { get; private set; }
    public Action? OpenMirrorWindow;

    public BottomRow()
    {
        foreach (Control c in new Control[] { _planCaption, _historyCaption, _previewCaption, _liveCaption, _controlCaption,
                                              Plan, History, Preview, Mirror, PointerBar, FocusBar, Control.ActiveBox, Control,
                                              _liveDivider, PlanDivider, HistoryDivider, _mirrorWindowButton })
            Children.Add(c);
        Layout = Arrange;
        _liveDivider.OnDrag = delta => { BottomMetrics.LiveWidth -= delta; InvalidateArrange(); };
        PlanDivider.OnDrag = delta =>
        {
            var room = Math.Max(0, LastPreviewWidth - BottomMetrics.PreviewMinWidth);
            BottomMetrics.PlanWidth = Plan.Bounds.Width + Math.Min(delta, room);
            InvalidateArrange();
        };
        PlanDivider.OnReset = () => { BottomMetrics.ResetPlanWidth(); InvalidateArrange(); };
        HistoryDivider.OnDrag = delta =>
        {
            var room = Math.Max(0, LastPreviewWidth - BottomMetrics.PreviewMinWidth);
            BottomMetrics.HistoryWidth = History.Bounds.Width + Math.Min(delta, room);
            InvalidateArrange();
        };
        HistoryDivider.OnReset = () => { BottomMetrics.ResetHistoryWidth(); InvalidateArrange(); };
        _mirrorWindowButton.Pressed = () => OpenMirrorWindow?.Invoke();
        ApplyCaptions();
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
    }

    public bool ShowsMirror => BottomMetrics.LiveWidth > 0;

    public void ApplyCaptions()
    {
        _planCaption.Text = Captions.Caption("Label3D15", "План:");
        _historyCaption.Text = Captions.Caption("Label3D3", "История:");
        _previewCaption.Text = Captions.Caption("Label3D2", "Предварительный просмотр");
        _liveCaption.Text = Captions.T("Живой экран (то, что в зале)");
        _controlCaption.Text = Captions.Caption("Label3D1", "Управление:");
        ToolTip.SetTip(_mirrorWindowButton, Captions.T("Открыть живой экран отдельным окном"));
        Control.ApplyCaptions();
        InvalidateArrange();
    }

    public void SetShowsMirror(bool shows)
    {
        BottomMetrics.LiveWidth = shows ? BottomMetrics.LiveDefaultWidth : 0;
        InvalidateArrange();
    }

    void Arrange(Size size)
    {
        const double padding = BottomMetrics.Padding, gap = BottomMetrics.Gap, captionHeight = BottomMetrics.CaptionHeight;
        var top = padding;
        var contentY = top + captionHeight + BottomMetrics.CaptionGap;
        var contentHeight = Math.Max(0, size.Height - contentY - padding);

        var planWidth = BottomMetrics.PlanWidth;
        var historyWidth = BottomMetrics.HistoryWidth;
        var planFixed = BottomMetrics.PlanWidthIsCustom;
        var historyFixed = BottomMetrics.HistoryWidthIsCustom;
        var controlWidth = Control.PreferredWidth;
        var liveWidth = BottomMetrics.LiveWidth;
        var dividerWidth = liveWidth > 0 ? BottomMetrics.DividerWidth : 0;
        var listDividers = BottomMetrics.DividerWidth * 2;
        var previewWidth = size.Width - planWidth - historyWidth - controlWidth - liveWidth - dividerWidth - listDividers - gap;

        if (previewWidth < BottomMetrics.PreviewMinWidth)
        {
            var lack = BottomMetrics.PreviewMinWidth - previewWidth;
            var fromPlan = Math.Min(lack, planWidth - BottomMetrics.PlanMinWidth);
            planWidth -= fromPlan; lack -= fromPlan;
            var fromHistory = Math.Min(lack, historyWidth - BottomMetrics.HistoryMinWidth);
            historyWidth -= fromHistory; lack -= fromHistory;
            if (lack > 0 && liveWidth > 0)
            {
                var fromLive = Math.Min(lack, liveWidth - BottomMetrics.LiveMinWidth);
                liveWidth -= fromLive; lack -= fromLive;
                if (lack > 0) { liveWidth = 0; dividerWidth = 0; }
            }
        }
        else if (previewWidth > BottomMetrics.PreviewMinWidth)
        {
            var spare = previewWidth - BottomMetrics.PreviewMinWidth;
            if (!historyFixed)
            {
                var toHistory = Math.Min(spare, Math.Max(0, BottomMetrics.HistoryMaxWidth - historyWidth));
                historyWidth += toHistory; spare -= toHistory;
            }
            if (!planFixed) planWidth += Math.Min(spare, Math.Max(0, BottomMetrics.PlanMaxWidth - planWidth));
        }
        previewWidth = Math.Max(0, size.Width - planWidth - historyWidth - controlWidth - liveWidth - dividerWidth - listDividers - gap);
        LastPreviewWidth = previewWidth;

        double x = 0;
        void PlaceWith(Control caption, Control content, double width, double trailing)
        {
            Place(caption, new Rect(x + 6, top, Math.Max(0, width - 6), captionHeight));
            Place(content, new Rect(x, contentY, width, contentHeight));
            x += width + trailing;
        }
        void Grip(WidthGrip divider)
        {
            Place(divider, new Rect(x, contentY, BottomMetrics.DividerWidth, contentHeight));
            x += BottomMetrics.DividerWidth;
        }

        PlaceWith(_planCaption, Plan, planWidth, 0);
        Grip(PlanDivider);
        PlaceWith(_historyCaption, History, historyWidth, 0);
        Grip(HistoryDivider);

        Place(_previewCaption, new Rect(x + 6, top, Math.Max(0, previewWidth - 6), captionHeight));
        var slideHeight = Math.Min(contentHeight, previewWidth * 3 / 4);
        Place(Preview, new Rect(x, contentY, slideHeight * 4 / 3, slideHeight));
        x += previewWidth;

        _liveDivider.IsVisible = dividerWidth > 0;
        if (dividerWidth > 0) { Place(_liveDivider, new Rect(x, contentY, dividerWidth, contentHeight)); x += dividerWidth; }
        else x += gap;

        var hasLive = liveWidth > 0;
        Mirror.IsVisible = PointerBar.IsVisible = FocusBar.IsVisible = _liveCaption.IsVisible = _mirrorWindowButton.IsVisible = hasLive;
        if (hasLive)
        {
            const double buttonWidth = 18;
            Place(_liveCaption, new Rect(x + 6, top, Math.Max(0, liveWidth - 6 - buttonWidth - 4), captionHeight));
            Place(_mirrorWindowButton, new Rect(x + liveWidth - buttonWidth, top - 2, buttonWidth, captionHeight + 4));
            const double barHeight = BottomMetrics.PointerBarHeight;
            var screenHeight = Math.Max(0, contentHeight - barHeight * 2 - 4);
            Place(Mirror, new Rect(x, contentY, liveWidth, screenHeight));
            Place(PointerBar, new Rect(x, contentY + screenHeight + 2, liveWidth, barHeight));
            Place(FocusBar, new Rect(x, contentY + screenHeight + barHeight + 4, liveWidth, barHeight));
            x += liveWidth + gap;
        }

        var controlRect = new Rect(x, contentY, controlWidth, contentHeight);
        Place(_controlCaption, new Rect(x + 6, top, Math.Max(0, controlWidth - 6), captionHeight));
        Place(Control, controlRect);
        var boxWidth = Control.ActiveBox.FittingWidth;
        Place(Control.ActiveBox, new Rect(controlRect.Right - boxWidth - 2, top - 1, boxWidth, captionHeight + 2));
        Place(_controlCaption, new Rect(x + 6, top, Math.Max(0, controlWidth - 6 - boxWidth - 6), captionHeight));
    }
}
