// =============================================================================
//  BottomMetrics.cs — розміри нижнього ряду (План, Історія, перегляд, Керування)
// =============================================================================
//  Числа — ті самі, що на Mac (NativeBottomMetrics).
// =============================================================================

namespace Slovo.App;

public static class BottomMetrics
{
    public const double RowDefaultHeight = 218;
    public const double RowMinHeight = 190;
    public const double RowMaxHeight = 640;
    const string RowHeightKey = "bottomRowHeight";

    public static double RowHeight
    {
        get
        {
            var saved = Defaults.Double(RowHeightKey);
            return saved > 0 ? Math.Min(RowMaxHeight, Math.Max(RowMinHeight, saved)) : RowDefaultHeight;
        }
        set => Defaults.Set(RowHeightKey, Math.Min(RowMaxHeight, Math.Max(RowMinHeight, value)));
    }

    const string LiveWidthKey = "bottomLiveWidth";
    public const double LiveDefaultWidth = 300;
    public const double LiveMinWidth = 180;
    public const double LiveMaxWidth = 900;

    /// Ширина живого екрана; 0 — живий екран сховано.
    public static double LiveWidth
    {
        get
        {
            if (!Defaults.Has(LiveWidthKey)) return LiveDefaultWidth;
            var saved = Defaults.Double(LiveWidthKey);
            return saved <= 0 ? 0 : Math.Min(LiveMaxWidth, Math.Max(LiveMinWidth, saved));
        }
        set => Defaults.Set(LiveWidthKey, value <= LiveMinWidth / 2 ? 0 : Math.Min(LiveMaxWidth, Math.Max(LiveMinWidth, value)));
    }

    public const double PointerBarHeight = 22;
    public const double DividerWidth = 7;
    public const double Padding = 6;
    public const double Gap = 6;
    public const double CaptionHeight = 14;
    public const double CaptionGap = 2;
    public const double Corner = 4;

    public const double PlanMinWidth = 150, PlanAutoWidth = 190, PlanMaxWidth = 240;
    public const double HistoryMinWidth = 160, HistoryAutoWidth = 210, HistoryMaxWidth = 280;
    public const double PlanDragMaxWidth = 700, HistoryDragMaxWidth = 800;
    public const double PreviewMinWidth = 280;
    public const double ControlMinWidth = 340;
    public const string PlanWidthKey = "bottomPlanWidth";
    public const string HistoryWidthKey = "bottomHistoryWidth";

    public static double PlanWidth
    {
        get => Widths.Value(PlanWidthKey, PlanAutoWidth, PlanMinWidth, PlanDragMaxWidth);
        set => Widths.Set(PlanWidthKey, value, PlanMinWidth, PlanDragMaxWidth);
    }
    public static double HistoryWidth
    {
        get => Widths.Value(HistoryWidthKey, HistoryAutoWidth, HistoryMinWidth, HistoryDragMaxWidth);
        set => Widths.Set(HistoryWidthKey, value, HistoryMinWidth, HistoryDragMaxWidth);
    }
    public static bool PlanWidthIsCustom => Widths.IsCustom(PlanWidthKey);
    public static bool HistoryWidthIsCustom => Widths.IsCustom(HistoryWidthKey);
    public static void ResetPlanWidth() => Widths.Reset(PlanWidthKey);
    public static void ResetHistoryWidth() => Widths.Reset(HistoryWidthKey);
}

/// Запам'ятовані ширини колонок, які тягне людина (як NativeWidths на Mac).
public static class Widths
{
    public static double Value(string key, double auto, double min, double max)
    {
        if (!Defaults.Has(key)) return auto;
        return Math.Min(Math.Max(max, min), Math.Max(min, Defaults.Double(key)));
    }
    public static void Set(string key, double value, double min, double max) =>
        Defaults.Set(key, Math.Min(Math.Max(max, min), Math.Max(min, value)));
    public static bool IsCustom(string key) => Defaults.Has(key);
    public static void Reset(string key) => Defaults.Remove(key);
}
