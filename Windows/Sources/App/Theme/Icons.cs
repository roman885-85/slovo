// =============================================================================
//  Icons.cs — значки: імена як у Mac-версії (SF Symbols), малюнок — Lucide
// =============================================================================
//  SF Symbols на Windows поширювати не можна (ліцензія Apple), тому кожному
//  імені з Mac-коду відповідає найближчий відкритий значок Lucide (ISC) —
//  див. tools/icon-map.txt. Малюються вектором будь-якого розміру й кольору.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public static partial class Icons
{
    static readonly Dictionary<string, Geometry?> Geometries = new();

    public static bool Has(string name) => Data.ContainsKey(name);

    static Geometry? Shape(string name)
    {
        if (Geometries.TryGetValue(name, out var ready)) return ready;
        Geometry? geometry = null;
        if (Data.TryGetValue(name, out var entry))
        {
            try { geometry = StreamGeometry.Parse(entry.Path); } catch { geometry = null; }
        }
        Geometries[name] = geometry;
        return geometry;
    }

    /// Намалювати значок у квадраті `box` (по центру), заданим кольором.
    /// `weight` — товщина лінії: 1 — звичайна, 1.3 — напівжирна (як у SF).
    /// Поправка розміру Lucide → SF Symbols (виміряно на знімках Mac 1.3.9).
    public const double SfScale = 1.2;

    public static void Draw(DrawingContext g, string name, Rect box, Color color, double weight = 1)
    {
        var shape = Shape(name);
        if (shape == null) return;
        // Розмір як у SF Symbol того самого кегля: значок Lucide займає ~20 з 24
        // клітинок сітки, а SF Symbol у N пт — близько 1,15·N. Без поправки всі
        // значки виходили на чверть дрібнішими за Mac (вкладки, кнопки колонок).
        var side = Math.Min(box.Width, box.Height) * SfScale;
        var scale = side / 24.0;
        var x = box.X + (box.Width - side) / 2;
        var y = box.Y + (box.Height - side) / 2;
        var brush = Palette.Brush(color);
        var fill = Data[name].Fill;
        // Лінія в 24-клітинковій сітці: 2 — це ~1 точка на значку 12 пт, як SF Regular.
        var pen = new Pen(brush, (fill ? 1.2 : 2.0) * weight * Math.Max(0.85, 12 / Math.Max(8, side)),
                          lineCap: PenLineCap.Round, lineJoin: PenLineJoin.Round);
        using (g.PushTransform(Matrix.CreateScale(scale, scale) * Matrix.CreateTranslation(x, y)))
            g.DrawGeometry(fill ? brush : null, pen, shape);
    }
}

/// Значок як елемент вікна.
public sealed class IconView : Control
{
    public string Symbol { get; set; }
    public Func<Color> Tint { get; set; } = () => Palette.SecondaryLabel;
    public double Weight { get; set; } = 1;

    public IconView(string symbol, double side = 16)
    {
        Symbol = symbol;
        Width = side;
        Height = side;
        Palette.Changed += InvalidateVisual;
    }

    public override void Render(DrawingContext context) =>
        Icons.Draw(context, Symbol, new Rect(Bounds.Size), Tint(), Weight);
}
