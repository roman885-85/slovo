// =============================================================================
//  ConstructorCanvas.cs — полотно «Конструктора слайда» (як NativeConstructorCanvas)
// =============================================================================
//  Слайд — тим самим малювальником, що йде в зал (у фоні, через чергу кадрів),
//  у рамці пропорцій шаблону на чорному. Вибраний об'єкт — рамка кольору
//  акценту й п'ять маркерів (середина — пересунути, боки — розтягнути); маркери
//  стоять на роздутій рамці, щоб у вузького об'єкта було за що взятися.
//  Клацання по об'єкту вибирає його; протяжка — нова рамка (розмір стає заданим).
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed class ConstructorCanvas : Control
{
    readonly SlideConstructorModel _model;
    public ConstructorSample Sample = new();
    enum Handle { Move, Left, Right, Top, Bottom }
    Handle? _dragging;
    Rect _startRect;
    Point _startPoint;
    WriteableBitmap? _rendered;
    string _requested = "";
    int _generation;
    public event Action? Edited;

    const double HandleSize = 9;
    static double MinimumSpan => HandleSize * 3 + 8;

    public ConstructorCanvas(SlideConstructorModel model) { _model = model; ClipToBounds = true; }

    Rect Stage
    {
        get
        {
            var b = new Rect(Bounds.Size);
            var ratio = _model.Preset.AspectRatio;
            if (ratio <= 0) return b;
            var size = new Size(b.Width, b.Width / ratio);
            if (size.Height > b.Height) size = new Size(b.Height * ratio, b.Height);
            return new Rect((b.Width - size.Width) / 2, (b.Height - size.Height) / 2, size.Width, size.Height);
        }
    }

    /// Перемалювати слайд (правка, інша сцена, інший зразок тексту).
    public void Redraw() { _requested = ""; InvalidateVisual(); }

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        g.FillRectangle(Brushes.Black, b);
        var stage = Stage;
        if (stage.Width <= 8 || stage.Height <= 8) return;
        var scale = TopLevel.GetTopLevel(this)?.RenderScaling ?? 1;
        var (w, h) = ((int)Math.Round(stage.Width * scale), (int)Math.Round(stage.Height * scale));
        var identity = $"{w}x{h}|{_model.Scene}|{System.Text.Json.JsonSerializer.Serialize(_model.Preset)}|{Sample}";
        if (identity != _requested)
        {
            _requested = identity;
            var order = new SlideDrawing.Order
            {
                Slide = new Slide(Sample.MainText, new[] { Sample.SecondaryText }, Sample.Reference),
                Style = _model.BaseStyle, Preset = _model.Preset.Copy(), Texts = Sample, DrawsBackground = true,
                WithSecondTranslation = _model.Scene == SlideScheme.Variant.Dual, ImagePath = _model.ImagePath,
            };
            order.ResolveImages();
            var wanted = ++_generation;
            SlideRenderQueue.Shared.Render("конструктор", wanted, w, h, true, (c, width, height) => SlideDrawing.Draw(order, c, width, height),
                (image, done) =>
                {
                    if (done != _generation || image == null) { image?.Dispose(); return; }
                    _rendered?.Dispose();
                    _rendered = ToBitmap(image);
                    image.Dispose();
                    InvalidateVisual();
                });
        }
        if (_rendered != null) g.DrawImage(_rendered, new Rect(_rendered.Size), stage);

        if (_model.SelectedObject is not { } obj) return;
        var rect = FrameOf(obj).Translate(stage.Position);
        var accent = Palette.Brush(Palette.Accent);
        g.DrawRectangle(null, new Pen(accent, 1), rect);
        // Маркери — на роздутій рамці: у вузького об'єкта вони не зливаються в точку.
        var zones = Zones(rect);
        foreach (var point in HandlePoints(zones).Select(p => p.Point))
        {
            var box = new Rect(point.X - HandleSize / 2, point.Y - HandleSize / 2, HandleSize, HandleSize);
            g.DrawRectangle(accent, new Pen(Brushes.White, 1), box);
        }
    }

    static WriteableBitmap ToBitmap(SKImage image)
    {
        var bitmap = new WriteableBitmap(new PixelSize(image.Width, image.Height), new Vector(96, 96), PixelFormat.Bgra8888, AlphaFormat.Premul);
        using var buffer = bitmap.Lock();
        var info = new SKImageInfo(image.Width, image.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        image.ReadPixels(info, buffer.Address, buffer.RowBytes, 0, 0);
        return bitmap;
    }

    static Rect Zones(Rect rect)
    {
        var width = Math.Max(rect.Width, MinimumSpan);
        var height = Math.Max(rect.Height, MinimumSpan);
        return new Rect(rect.Center.X - width / 2, rect.Center.Y - height / 2, width, height);
    }

    static (Handle Handle, Point Point)[] HandlePoints(Rect zones) => new[]
    {
        (Handle.Move, zones.Center),
        (Handle.Left, new Point(zones.Left, zones.Center.Y)),
        (Handle.Right, new Point(zones.Right, zones.Center.Y)),
        (Handle.Top, new Point(zones.Center.X, zones.Top)),
        (Handle.Bottom, new Point(zones.Center.X, zones.Bottom)),
    };

    Rect FrameOf(SlideObject obj)
    {
        var values = SlideConstructorModel.Values(obj, _model.Scene);
        var stage = Stage;
        var size = new SKSize((float)stage.Width, (float)stage.Height);
        var auto = ConstructorAutoSize.Size(obj, values, Sample, size, _model.ImagePath);
        var r = values.Frame.Resolved(auto, size).Rect(size);
        return new Rect(r.Left, r.Top, r.Width, r.Height);
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        var point = e.GetPosition(this);
        var stage = Stage;
        if (_model.SelectedObject is { } selected)
        {
            var rect = FrameOf(selected).Translate(stage.Position);
            var side = HandleSize + 4;
            foreach (var (handle, centre) in HandlePoints(Zones(rect)))
            {
                if (!new Rect(centre.X - side / 2, centre.Y - side / 2, side, side).Contains(point)) continue;
                _dragging = handle;
                _startRect = rect;
                _startPoint = point;
                e.Pointer.Capture(this);
                e.Handled = true;
                return;
            }
        }
        // Клацання по об'єкту вибирає його — верхній шар першим.
        var inStage = point - stage.Position;
        foreach (var obj in Enumerable.Reverse(_model.Preset.Objects))
        {
            if (!SlideConstructorModel.Values(obj, _model.Scene).IsVisible || !FrameOf(obj).Contains(new Point(inStage.X, inStage.Y))) continue;
            _model.Selection = obj.Id;
            Edited?.Invoke();
            InvalidateVisual();
            break;
        }
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_dragging is not { } handle) return;
        var point = e.GetPosition(this);
        var dx = point.X - _startPoint.X;
        var dy = point.Y - _startPoint.Y;
        // Мінімум 10 точок: сплющену в нитку рамку вже нема за що взяти.
        const double minimum = 10;
        var s = _startRect;
        var rect = handle switch
        {
            Handle.Move => s.Translate(new Vector(dx, dy)),
            Handle.Left => new Rect(Math.Min(s.Left + dx, s.Right - minimum), s.Top, s.Right - Math.Min(s.Left + dx, s.Right - minimum), s.Height),
            Handle.Right => new Rect(s.Left, s.Top, Math.Max(s.Width + dx, minimum), s.Height),
            Handle.Top => new Rect(s.Left, Math.Min(s.Top + dy, s.Bottom - minimum), s.Width, s.Bottom - Math.Min(s.Top + dy, s.Bottom - minimum)),
            _ => new Rect(s.Left, s.Top, s.Width, Math.Max(s.Height + dy, minimum)),
        };
        Apply(rect);
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (_dragging == null) return;
        _dragging = null;
        e.Pointer.Capture(null);
    }

    void Apply(Rect rect)
    {
        if (_model.SelectedObject is not { } obj) return;
        var stage = Stage;
        if (stage.Width <= 0 || stage.Height <= 0) return;
        var values = SlideConstructorModel.Values(obj, _model.Scene);
        // Потягли мишею — розмір став заданим: «за вмістом» тут уже не виразити.
        values.Frame = FrameFromRect(rect.Translate(-stage.Position), stage.Size, values.Frame.AnchorX, values.Frame.AnchorY);
        _model.SetSelectedValues(values);
        Edited?.Invoke();
        Redraw();
    }

    /// Рамка в частках полотна за прив'язкою (ObjectFrame(rect:in:anchorX:anchorY:) на Mac).
    static ObjectFrame FrameFromRect(Rect rect, Size size, HorizontalAnchor anchorX, VerticalAnchor anchorY)
    {
        var width = size.Width > 0 ? rect.Width / size.Width : 0;
        var height = size.Height > 0 ? rect.Height / size.Height : 0;
        var dx = anchorX switch
        {
            HorizontalAnchor.Left => rect.Left,
            HorizontalAnchor.Right => size.Width - rect.Width - rect.Left,
            _ => rect.Left - (size.Width - rect.Width) / 2,
        };
        var dy = anchorY switch
        {
            VerticalAnchor.Top => rect.Top,
            VerticalAnchor.Bottom => size.Height - rect.Height - rect.Top,
            _ => rect.Top - (size.Height - rect.Height) / 2,
        };
        return new ObjectFrame(size.Width > 0 ? dx / size.Width : 0, size.Height > 0 ? dy / size.Height : 0, width, height, anchorX, anchorY);
    }
}
