// =============================================================================
//  ConstructorGeometry.cs — тексти для об'єктів шаблону і «авто»-розмір
// =============================================================================
//  Як ConstructorGeometry.swift на Mac: об'єкт із нульовою шириною чи висотою
//  отримує розмір за вмістом — картинка за своїми пропорціями, текст — за шириною
//  рядка в заданому кеглі плюс чверть кегля.
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

/// Що стоїть у кожному текстовому об'єкті шаблону.
public sealed record ConstructorSample
{
    public string MainText { get; init; } = "";
    public string SecondaryText { get; init; } = "";
    public string Reference { get; init; } = "";
    public string PrimaryReference { get; init; } = "";
    public string SecondaryReference { get; init; } = "";
    public string ModuleNameFirst { get; init; } = "";
    public string ModuleShortNameFirst { get; init; } = "";
    public string ModuleNameSecond { get; init; } = "";
    public string ModuleShortNameSecond { get; init; } = "";
    public string SongTitle { get; init; } = "";

    public string Text(SlideObject obj) => obj.Kind switch
    {
        SlideObjectKind.Quote => MainText,
        SlideObjectKind.SecondaryQuote => SecondaryText,
        SlideObjectKind.Reference => Reference,
        SlideObjectKind.PrimaryReference => PrimaryReference,
        SlideObjectKind.SecondaryReference => SecondaryReference,
        SlideObjectKind.ModuleNameFirst => ModuleNameFirst,
        SlideObjectKind.ModuleShortNameFirst => ModuleShortNameFirst,
        SlideObjectKind.ModuleNameSecond => ModuleNameSecond,
        SlideObjectKind.ModuleShortNameSecond => ModuleShortNameSecond,
        SlideObjectKind.SongTitle => SongTitle,
        SlideObjectKind.PreviousPage => "▲",
        SlideObjectKind.NextPage => "▼",
        SlideObjectKind.StaticText => obj.StaticText,
        _ => "",
    };
}

public static class ConstructorAutoSize
{
    public static SKSize Size(SlideObject obj, ObjectVariant values, ConstructorSample sample, SKSize canvas,
                              Func<string?, string?> imagePath)
    {
        var needsWidth = values.Frame.Width <= 0;
        var needsHeight = values.Frame.Height <= 0;
        if (!(needsWidth || needsHeight) || canvas.Width <= 0 || canvas.Height <= 0) return SKSize.Empty;
        return obj.Kind == SlideObjectKind.Image ? ImageSize(obj, values, canvas, imagePath) : TextSize(obj, sample, canvas);
    }

    static SKSize ImageSize(SlideObject obj, ObjectVariant values, SKSize canvas, Func<string?, string?> imagePath)
    {
        if (imagePath(obj.ImagePath) is not { } path || SlideImageStore.Shared.Image(path) is not { } image
            || image.Width <= 0 || image.Height <= 0)
            return new SKSize(canvas.Width * 0.1f, canvas.Height * 0.1f);
        var ratio = (float)image.Width / image.Height;
        if (values.Frame.Height > 0) { var h = (float)values.Frame.Height * canvas.Height; return new SKSize(h * ratio, h); }
        if (values.Frame.Width > 0) { var w = (float)values.Frame.Width * canvas.Width; return new SKSize(w, w / ratio); }
        return new SKSize(image.Width, image.Height);
    }

    static SKSize TextSize(SlideObject obj, ConstructorSample sample, SKSize canvas)
    {
        var content = sample.Text(obj);
        if (content.Length == 0) return new SKSize(canvas.Width * 0.06f, canvas.Height * 0.06f);
        var points = (float)Math.Max(obj.Text.FontSize * canvas.Height, 1);
        using var font = new SKFont(SlideFonts.Typeface(obj.Text.FontName, obj.Text.IsBold, obj.Text.IsItalic), points);
        using var paint = new SKPaint(font);
        var width = paint.MeasureText(content);
        var m = font.Metrics;
        var height = -m.Ascent + m.Descent + m.Leading;
        var padding = points * 0.25f;
        return new SKSize(width + padding, height + padding);
    }
}

public static class ObjectFrameExtensions
{
    /// «Авто»-розміри (нуль) замінити порахованими за вмістом.
    public static ObjectFrame Resolved(this ObjectFrame frame, SKSize auto, SKSize size)
    {
        if (size.Width <= 0 || size.Height <= 0) return frame;
        var result = frame;
        if (result.Width <= 0 && auto.Width > 0) result.Width = Math.Min(auto.Width / size.Width, 1);
        if (result.Height <= 0 && auto.Height > 0) result.Height = Math.Min(auto.Height / size.Height, 1);
        return result;
    }

    public static SKRect Rect(this ObjectFrame frame, SKSize size)
    {
        var w = frame.Width * size.Width;
        var h = frame.Height * size.Height;
        var dx = frame.X * size.Width;
        var dy = frame.Y * size.Height;
        var left = frame.AnchorX switch
        {
            HorizontalAnchor.Left => dx,
            HorizontalAnchor.Right => size.Width - w - dx,
            _ => (size.Width - w) / 2 + dx,
        };
        var top = frame.AnchorY switch
        {
            VerticalAnchor.Top => dy,
            VerticalAnchor.Bottom => size.Height - h - dy,
            _ => (size.Height - h) / 2 + dy,
        };
        return SKRect.Create((float)left, (float)top, (float)w, (float)h);
    }
}
