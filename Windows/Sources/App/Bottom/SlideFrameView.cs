// =============================================================================
//  SlideFrameView.cs — кадр слайда в нижньому ряду (перегляд і живий екран)
// =============================================================================
//  Кадр малює черга у фоні; показує його SlideSurface (на відеокарті, з тими
//  самими переходами, що в залі). Поверх — рамка з кутом 4: у перегляді, коли
//  він збігається із залом, — червона товщиною 2 (як на Mac).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public sealed class SlideFrameView : Panel
{
    public readonly SlideSurface Surface = new();
    readonly Frame _frame;
    bool _live;
    public bool MarksLive { get; set; }

    public SlideFrameView()
    {
        _frame = new Frame(this);
        ClipToBounds = true;
        Children.Add(Surface);
        Children.Add(_frame);
        Palette.Changed += _frame.InvalidateVisual;
    }

    public bool IsLive { get => _live; set { if (_live == value) return; _live = value; _frame.InvalidateVisual(); } }

    /// Кут рамки: у нижньому ряду — як у решти частин, в окремому вікні дзеркала — 0 (як на Mac).
    public double Corner { get; init; } = BottomMetrics.Corner;

    /// Розмір кадру в пікселях для черги малювання.
    public (int Width, int Height) PixelSize()
    {
        var scale = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;
        return ((int)Math.Max(16, Math.Round(Bounds.Width * scale)), (int)Math.Max(9, Math.Round(Bounds.Height * scale)));
    }

    sealed class Frame : Control
    {
        readonly SlideFrameView _owner;
        public Frame(SlideFrameView owner) { _owner = owner; IsHitTestVisible = false; }
        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            var live = _owner.MarksLive && _owner._live;
            // Кути поза округленням закриваємо кольором тла вікна.
            var outer = new StreamGeometry();
            using (var c = outer.Open())
            {
                c.BeginFigure(b.TopLeft, true); c.LineTo(b.TopRight); c.LineTo(b.BottomRight); c.LineTo(b.BottomLeft); c.EndFigure(true);
            }
            var hole = new RectangleGeometry(b, _owner.Corner, _owner.Corner);
            g.DrawGeometry(Palette.Brush(Palette.WindowBackground), null, new CombinedGeometry(GeometryCombineMode.Exclude, outer, hole));
            g.DrawRectangle(null, new Pen(Palette.Brush(live ? Palette.SystemRed : Palette.Separator), live ? 2 : 1),
                            new RoundedRect(b.Deflate(live ? 1 : 0.5), _owner.Corner));
        }
    }
}
