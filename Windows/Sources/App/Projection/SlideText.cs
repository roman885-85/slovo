// =============================================================================
//  SlideText.cs — текст слайда: перенос, вирівнювання, контур, тінь, підбір кегля
// =============================================================================
//  Як OutlinedText на Mac (Core Text), але SkiaSharp:
//  • кегль — частка висоти слайда; не влазить у рамку — зменшується до
//    `minimumScale` поділом навпіл (шість замірів замість двадцяти);
//  • контур «обвести І залити»: спершу заливка, зверху штрих товщиною
//    `outlineWidth × висота слайда` (половина назовні — як у Core Text);
//  • тінь об'єкта (зсув за кутом, розмиття, колір, прозорість) або загальна тінь
//    шару (чорна 55 %, без зсуву, радіус × висота слайда);
//  • міжрядковий інтервал — `кегль × lineSpacing` між рядками;
//  • текст по вертикалі — угорі / по центру / внизу рамки.
// =============================================================================

using SkiaSharp;

namespace Slovo.App;

public enum SlideTextAlign { Left, Center, Right }
public enum SlideTextVertical { Top, Center, Bottom }

/// Як малювати текст: шрифт, кольори, контур, тінь — уже в пікселях кадру.
public sealed record SlideTextLook(
    string FontName, bool Bold, bool Italic, double FontFraction,
    SKColor Color, SKColor OutlineColor, double OutlineFraction,
    double ShadowRadiusFraction,
    SKColor? ShadowColor = null, double ShadowDx = 0, double ShadowDy = 0, double ShadowBlur = 0);

public static class SlideText
{
    sealed record Line(string Text, float Width);

    /// Ширина рядка цим шрифтом.
    static float W(SKFont font, string text)
    {
        if (text.Length == 0) return 0;
        using var paint = new SKPaint(font);
        return paint.MeasureText(text);
    }

    static List<Line> Wrap(string text, SKFont font, float width)
    {
        var lines = new List<Line>();
        foreach (var paragraph in text.Replace("\r\n", "\n").Split('\n'))
        {
            if (paragraph.Length == 0) { lines.Add(new Line("", 0)); continue; }
            var words = paragraph.Split(' ');
            var current = "";
            foreach (var word0 in words)
            {
                var word = word0;
                var candidate = current.Length == 0 ? word : current + " " + word;
                if (W(font, candidate) <= width || current.Length == 0 && W(font, word) <= width)
                {
                    current = candidate;
                    continue;
                }
                if (current.Length > 0) { lines.Add(new Line(current, W(font, current))); current = ""; }
                // Слово довше за рядок — ламаємо по літерах, як TextKit.
                while (W(font, word) > width && word.Length > 1)
                {
                    var cut = word.Length - 1;
                    while (cut > 1 && W(font, word[..cut]) > width) cut--;
                    lines.Add(new Line(word[..cut], W(font, word[..cut])));
                    word = word[cut..];
                }
                current = word;
            }
            lines.Add(new Line(current, W(font, current)));
        }
        return lines;
    }

    static float LineHeight(SKFont font)
    {
        var m = font.Metrics;
        return -m.Ascent + m.Descent + m.Leading;
    }

    /// Висота тексту в ширині `width` за кегля `size`.
    public static float Measure(string text, SlideTextLook look, float size, float width, double lineSpacing)
    {
        using var font = new SKFont(SlideFonts.Typeface(look.FontName, look.Bold, look.Italic), size);
        var lines = Wrap(text, font, width);
        return lines.Count * LineHeight(font) + Math.Max(0, lines.Count - 1) * (float)(size * lineSpacing);
    }

    /// Намалювати текст у прямокутник `rect` кадру заввишки `slideHeight`.
    public static void Draw(SKCanvas canvas, string text, SlideTextLook look, double lineSpacing,
                            SlideTextAlign align, SlideTextVertical vertical, double minimumScale,
                            SKRect rect, float slideHeight)
    {
        if (string.IsNullOrEmpty(text) || rect.Width < 1 || rect.Height < 1) return;
        var requested = (float)(slideHeight * look.FontFraction);
        var smallest = (float)Math.Max(6, requested * minimumScale);
        // Кегль поділом навпіл між найменшим і заданим.
        float best = smallest;
        if (Measure(text, look, smallest, rect.Width, lineSpacing) <= rect.Height)
        {
            float low = smallest, high = requested;
            if (Measure(text, look, requested, rect.Width, lineSpacing) <= rect.Height) best = requested;
            else
                for (var i = 0; i < 6; i++)
                {
                    var middle = (low + high) / 2;
                    if (Measure(text, look, middle, rect.Width, lineSpacing) <= rect.Height) { best = middle; low = middle; }
                    else high = middle;
                }
        }
        using var font = new SKFont(SlideFonts.Typeface(look.FontName, look.Bold, look.Italic), best)
        { Subpixel = true, Edging = SKFontEdging.Antialias };
        var lines = Wrap(text, font, rect.Width);
        var lineHeight = LineHeight(font);
        var gap = (float)(best * lineSpacing);
        var total = lines.Count * lineHeight + Math.Max(0, lines.Count - 1) * gap;
        var top = vertical switch
        {
            SlideTextVertical.Top => rect.Top,
            SlideTextVertical.Bottom => rect.Bottom - total,
            _ => rect.Top + (rect.Height - total) / 2,
        };

        // Тінь — на весь текст разом (і заливку, і контур), як NSShadow.
        SKImageFilter? shadow = null;
        if (look.ShadowColor is { } sc && (look.ShadowBlur > 0 || look.ShadowDx != 0 || look.ShadowDy != 0))
            shadow = SKImageFilter.CreateDropShadow((float)look.ShadowDx, (float)look.ShadowDy,
                                                   (float)(look.ShadowBlur / 2), (float)(look.ShadowBlur / 2), sc);
        else if (look.ShadowRadiusFraction > 0)
        {
            var blur = (float)(look.ShadowRadiusFraction * slideHeight);
            shadow = SKImageFilter.CreateDropShadow(0, 0, blur / 2, blur / 2, new SKColor(0, 0, 0, 140));
        }
        if (shadow != null)
        {
            using var layer = new SKPaint { ImageFilter = shadow };
            canvas.SaveLayer(layer);
        }

        var outline = (float)(look.OutlineFraction * slideHeight);
        using var fill = new SKPaint { Color = look.Color, IsAntialias = true, Style = SKPaintStyle.Fill };
        using var stroke = outline > 0.2f
            ? new SKPaint { Color = look.OutlineColor, IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = outline, StrokeJoin = SKStrokeJoin.Round }
            : null;
        var y = top;
        foreach (var line in lines)
        {
            var x = align switch
            {
                SlideTextAlign.Left => rect.Left,
                SlideTextAlign.Right => rect.Right - line.Width,
                _ => rect.Left + (rect.Width - line.Width) / 2,
            };
            var baseline = y - font.Metrics.Ascent;
            if (line.Text.Length > 0)
            {
                canvas.DrawText(line.Text, x, baseline, font, fill);
                if (stroke != null) canvas.DrawText(line.Text, x, baseline, font, stroke);
            }
            y += lineHeight + gap;
        }
        if (shadow != null) { canvas.Restore(); shadow.Dispose(); }
    }
}
