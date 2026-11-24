// =============================================================================
//  SlideDrawing.cs — малювання слайда в кадр (зал, перегляд, живий екран, NDI)
// =============================================================================
//  Як SlideDrawing на Mac: один код на всі виводи — інакше між ними неминуче
//  заводиться різниця, помітна лише на стіні в залі.
//  • Шаблон Конструктора (SlidePreset) — тло (колір, картинка з режимом
//    розміщення) і об'єкти (текст, адреси, назви модулів, назва пісні, напис,
//    картинка з маскою), кожен зі своєю рамкою, прозорістю, тінню й появою.
//  • Без нього — стиль слайда: тло, затемнення, стовпчик «текст — другий
//    переклад — адреса» по вертикалі.
//  Фон готується підкладкою потрібного розміру й тримається в кеші (на Mac без
//  цього нажаття коштувало 48 мс замість 3).
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public static class SlideDrawing
{
    /// Замовлення на кадр — усе, що треба, зібране заздалегідь (малюється не в головному потоці).
    public sealed class Order
    {
        public Slide Slide;
        public SlideStyle Style;
        public SlidePreset? Preset;
        public ConstructorSample Texts = new();
        public bool DrawsBackground = true;
        public double? Clock;
        public string? BackgroundOverride;
        public bool WithSecondTranslation;
        public Func<string?, string?> ImagePath = _ => null;
        readonly Dictionary<string, string> _resolved = new();

        /// Розв'язати імена картинок у шляхи наперед (у головному потоці).
        public void ResolveImages()
        {
            var names = new List<string>();
            if (BackgroundOverride != null) names.Add(BackgroundOverride);
            if (Preset is { } preset)
            {
                if (preset.Back.ImagePath is { } bg) names.Add(bg);
                foreach (var o in preset.Objects)
                {
                    if (o.ImagePath is { } i) names.Add(i);
                    if (o.MaskPath is { } m) names.Add(m);
                }
            }
            foreach (var name in names)
                if (name.Length > 0 && !_resolved.ContainsKey(name) && ImagePath(name) is { } path) _resolved[name] = path;
            var table = new Dictionary<string, string>(_resolved);
            ImagePath = name => name != null && table.TryGetValue(name, out var p) ? p : null;
        }
    }

    /// Кадр заданого розміру (для черги малювання).
    public static void Draw(Order order, SKCanvas c, int width, int height)
    {
        var size = new SKSize(width, height);
        c.Save();
        c.ClipRect(new SKRect(0, 0, width, height));
        if (order.Preset is { } preset)
        {
            DrawBackground(preset, order, c, size);
            if (!order.Slide.IsBlank) DrawObjects(preset, order, c, size);
        }
        else
        {
            DrawBackground(order.Style, order, c, size);
            if (!order.Slide.IsBlank) DrawStack(order, c, size);
        }
        c.Restore();
    }

    static SKColor Color(SlideStyle.RGBA rgba) =>
        new((byte)Math.Round(Math.Clamp(rgba.Red, 0, 1) * 255), (byte)Math.Round(Math.Clamp(rgba.Green, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(rgba.Blue, 0, 1) * 255), (byte)Math.Round(Math.Clamp(rgba.Alpha, 0, 1) * 255));

    static void DrawBackground(SlideStyle style, Order order, SKCanvas c, SKSize size)
    {
        if (!order.DrawsBackground) return;
        using (var p = new SKPaint { Color = Color(style.BackgroundColor) }) c.DrawRect(new SKRect(0, 0, size.Width, size.Height), p);
        var path = order.BackgroundOverride ?? style.BackgroundImagePath;
        if (path == null || SlideImageStore.Shared.Image(DataPaths.Existing(path) ?? path) is not { } image) return;
        DrawBackdrop(image, path, SlidePreset.FillMode.Fill, new SKRect(0, 0, size.Width, size.Height), c);
        if (style.DimBackground <= 0) return;
        using var dim = new SKPaint { Color = new SKColor(0, 0, 0, (byte)Math.Round(Math.Clamp(style.DimBackground, 0, 1) * 255)) };
        c.DrawRect(new SKRect(0, 0, size.Width, size.Height), dim);
    }

    static void DrawBackground(SlidePreset preset, Order order, SKCanvas c, SKSize size)
    {
        if (!order.DrawsBackground || preset.Back.IsTransparent) return;
        using (var p = new SKPaint { Color = Color(preset.Back.Color) }) c.DrawRect(new SKRect(0, 0, size.Width, size.Height), p);
        if (order.ImagePath(order.BackgroundOverride ?? preset.Back.ImagePath) is not { } path
            || SlideImageStore.Shared.Image(path) is not { } image) return;
        DrawBackdrop(image, path, preset.Back.Fill, new SKRect(0, 0, size.Width, size.Height), c);
    }

    static void DrawStack(Order order, SKCanvas c, SKSize size)
    {
        var style = order.Style;
        var slide = order.Slide;
        var h = size.Height;
        var blocks = new List<(string Text, SlideStyle.TextLayer Layer, double Height, double GapAbove)>();
        var spacing = h * style.LineSpacing * 0.35;
        if (slide.MainText.Length > 0) blocks.Add((slide.MainText, style.Main, h * style.Main.FontSize * 3.4, 0));
        foreach (var text in slide.SecondaryTexts)
            if (text.Length > 0) blocks.Add((text, style.Secondary, h * style.Secondary.FontSize * 3.4, blocks.Count == 0 ? 0 : spacing));
        if (slide.Reference.Length > 0)
            blocks.Add((slide.Reference, style.Reference, h * style.Reference.FontSize * 3.4, (blocks.Count == 0 ? 0 : spacing) + h * 0.02));
        if (blocks.Count == 0) return;
        var box = SKRect.Create((float)(size.Width * style.HorizontalInset), (float)(h * style.VerticalInset),
                                (float)(size.Width * (1 - style.HorizontalInset * 2)), (float)(h * (1 - style.VerticalInset * 2)));
        var total = blocks.Sum(b => b.Height + b.GapAbove);
        double top = style.VerticalAlign switch
        {
            SlideStyle.VerticalAlignment.Top => box.Top,
            SlideStyle.VerticalAlignment.Bottom => box.Bottom - total,
            _ => box.MidY - total / 2,
        };
        foreach (var block in blocks)
        {
            top += block.GapAbove;
            var rect = SKRect.Create(box.Left, (float)top, box.Width, (float)block.Height);
            SlideText.Draw(c, block.Text, Look(block.Layer, null, h), style.LineSpacing, SlideTextAlign.Center,
                           SlideTextVertical.Center, 0.35, rect, h);
            top += block.Height;
        }
    }

    static SlideTextLook Look(SlideStyle.TextLayer layer, ObjectShadow? shadow, float slideHeight)
    {
        SKColor? shadowColor = null; double dx = 0, dy = 0, blur = 0;
        if (shadow is { } s && s.IsVisible)
        {
            var points = layer.FontSize * slideHeight;
            var (offset, radius) = s.Metrics(points, points);
            shadowColor = Color(s.Color with { Alpha = s.Opacity });
            dx = offset.Width; dy = offset.Height; blur = radius;
        }
        return new SlideTextLook(layer.FontName, layer.IsBold, layer.IsItalic, layer.FontSize, Color(layer.Color),
                                 Color(layer.OutlineColor), layer.OutlineWidth, shadowColor == null ? layer.ShadowRadius : 0,
                                 shadowColor, dx, dy, blur);
    }

    static void DrawObjects(SlidePreset preset, Order order, SKCanvas c, SKSize size)
    {
        foreach (var obj in preset.Objects)
        {
            var values = obj.Variant(order.WithSecondTranslation);
            if (!values.IsVisible) continue;
            var auto = ConstructorAutoSize.Size(obj, values, order.Texts, size, order.ImagePath);
            var rect = values.Frame.Resolved(auto, size).Rect(size);
            if (rect.Width <= 0.5 || rect.Height <= 0.5) continue;
            var step = Progress(values.Animation, order.Clock);
            var scale = values.Animation.AnimatesScale ? values.Animation.StartScale + (1 - values.Animation.StartScale) * step : 1;
            var fade = values.Animation.AnimatesOpacity ? values.Animation.StartOpacity + (1 - values.Animation.StartOpacity) * step : 1;
            var shift = Entrance(values.Animation, size);
            var alpha = (byte)Math.Round(Math.Clamp(values.Opacity * fade, 0, 1) * 255);
            using var layer = new SKPaint { Color = new SKColor(255, 255, 255, alpha) };
            c.SaveLayer(layer);
            c.Translate((float)(shift.X * (1 - step)), (float)(shift.Y * (1 - step)));
            if (Math.Abs(scale - 1) > 1e-6) c.Scale((float)scale, (float)scale, rect.MidX, rect.MidY);
            if (obj.Kind == SlideObjectKind.Image) DrawObjectImage(obj, values, order, rect, c);
            else
            {
                var line = order.Texts.Text(obj);
                if (line.Length > 0)
                    SlideText.Draw(c, line, Look(obj.Text, values.Shadow, size.Height), obj.LineSpacing, Align(values.Alignment),
                                   Vertical(values.VerticalAlignment), obj.MinimumScale, rect, size.Height);
            }
            c.Restore();
        }
    }

    static SlideTextAlign Align(ParagraphAlignment a) => a switch
    {
        ParagraphAlignment.Leading => SlideTextAlign.Left,
        ParagraphAlignment.Trailing => SlideTextAlign.Right,
        _ => SlideTextAlign.Center,
    };

    static SlideTextVertical Vertical(SlideStyle.VerticalAlignment v) => v switch
    {
        SlideStyle.VerticalAlignment.Top => SlideTextVertical.Top,
        SlideStyle.VerticalAlignment.Bottom => SlideTextVertical.Bottom,
        _ => SlideTextVertical.Center,
    };

    static void DrawObjectImage(SlideObject obj, ObjectVariant values, Order order, SKRect rect, SKCanvas c)
    {
        if (order.ImagePath(obj.ImagePath) is not { } path || SlideImageStore.Shared.Image(path) is not { } picture) return;
        var image = picture;
        SKImage? masked = null;
        if (order.ImagePath(obj.MaskPath) is { } maskPath && SlideImageStore.Shared.Image(maskPath) is { } mask)
            masked = image = ApplyMask(mask, picture) ?? picture;
        SKImageFilter? shadow = null;
        if (values.Shadow.IsVisible)
        {
            var (offset, blur) = values.Shadow.Metrics(0, rect.Height);
            shadow = SKImageFilter.CreateDropShadow((float)offset.Width, (float)offset.Height, (float)(blur / 2), (float)(blur / 2),
                                                   Color(values.Shadow.Color with { Alpha = values.Shadow.Opacity }));
        }
        using var paint = new SKPaint { ImageFilter = shadow, FilterQuality = SKFilterQuality.High };
        DrawPicture(image, SlidePreset.FillMode.Fill, rect, c, paint);
        masked?.Dispose();
        shadow?.Dispose();
    }

    // --- Тло-підкладка в кеші ----------------------------------------------------------

    static readonly object BackdropLock = new();
    static readonly Dictionary<(string, int, int, SlidePreset.FillMode), SKImage> Backdrops = new();

    static void DrawBackdrop(SKImage image, string path, SlidePreset.FillMode mode, SKRect rect, SKCanvas c)
    {
        var key = (path, (int)Math.Round(rect.Width), (int)Math.Round(rect.Height), mode);
        SKImage? ready;
        lock (BackdropLock) Backdrops.TryGetValue(key, out ready);
        if (ready == null)
        {
            var info = new SKImageInfo(Math.Max(1, key.Item2), Math.Max(1, key.Item3), SKColorType.Bgra8888, SKAlphaType.Premul);
            using var surface = SKSurface.Create(info);
            if (surface == null) { DrawPicture(image, mode, rect, c, null); return; }
            DrawPicture(image, mode, new SKRect(0, 0, info.Width, info.Height), surface.Canvas, null);
            ready = surface.Snapshot();
            lock (BackdropLock)
            {
                if (Backdrops.Count >= 6) { foreach (var old in Backdrops.Values) old.Dispose(); Backdrops.Clear(); }
                Backdrops[key] = ready;
            }
        }
        c.DrawImage(ready, rect);
    }

    static void DrawPicture(SKImage image, SlidePreset.FillMode mode, SKRect rect, SKCanvas c, SKPaint? paint)
    {
        float sw = image.Width, sh = image.Height;
        if (sw <= 0 || sh <= 0) return;
        SKRect place;
        switch (mode)
        {
            case SlidePreset.FillMode.Stretch: place = rect; break;
            case SlidePreset.FillMode.Center: place = SKRect.Create(rect.MidX - sw / 2, rect.MidY - sh / 2, sw, sh); break;
            case SlidePreset.FillMode.Fit:
            {
                var s = Math.Min(rect.Width / sw, rect.Height / sh);
                place = SKRect.Create(rect.MidX - sw * s / 2, rect.MidY - sh * s / 2, sw * s, sh * s);
                break;
            }
            default:
            {
                var s = Math.Max(rect.Width / sw, rect.Height / sh);
                place = SKRect.Create(rect.MidX - sw * s / 2, rect.MidY - sh * s / 2, sw * s, sh * s);
                break;
            }
        }
        c.Save();
        c.ClipRect(rect);
        using var own = paint == null ? new SKPaint { FilterQuality = SKFilterQuality.High } : null;
        c.DrawImage(image, place, paint ?? own);
        c.Restore();
    }

    /// Маска: сіре зображення як прозорість (біле — видно, чорне — прозоро), як CGImage(maskWidth:…).
    static SKImage? ApplyMask(SKImage mask, SKImage image)
    {
        var info = new SKImageInfo(image.Width, image.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var surface = SKSurface.Create(info);
        if (surface == null) return null;
        var c = surface.Canvas;
        c.DrawImage(image, 0, 0);
        // CGImage-маска: біле — ховає, чорне — показує (маска «decode» за умовчанням).
        using var paint = new SKPaint
        {
            BlendMode = SKBlendMode.DstIn,
            ColorFilter = SKColorFilter.CreateColorMatrix(new float[]
            {
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                0, 0, 0, 0, 0,
                -0.2126f, -0.7152f, -0.0722f, 0, 1,
            }),
        };
        c.DrawImage(mask, new SKRect(0, 0, image.Width, image.Height), paint);
        return surface.Snapshot();
    }

    static double Progress(ObjectAnimation animation, double? clock)
    {
        if (!animation.IsAnimated || clock is not { } t) return 1;
        var start = animation.Delay / 1000;
        var length = Math.Max(0.001, animation.Duration / 1000);
        var step = Math.Min(1, Math.Max(0, (t - start) / length));
        return 1 - Math.Pow(1 - step, 2);
    }

    static SKPoint Entrance(ObjectAnimation animation, SKSize canvas)
    {
        if (animation.Move == ObjectAnimation.Direction.None) return SKPoint.Empty;
        if (animation.Move == ObjectAnimation.Direction.Point)
            return new SKPoint((float)((animation.PointX - 0.5) * canvas.Width), (float)((animation.PointY - 0.5) * canvas.Height));
        var (x, y) = animation.Move.Offset();
        return new SKPoint((float)(x * canvas.Width), (float)(y * canvas.Height));
    }
}
