// =============================================================================
//  SlideRenderer.cs — малювання слайда на SkiaSharp
// =============================================================================
//  Одне малювання на всю програму — як SlideDrawing/OutlinedText на Mac: вікно
//  слайда, передпоказ і картинка залу для пульта беруть цей один код, тому
//  розійтися їм нема де. Кегль підбирається діленням пополам, поки текст
//  не вміститься в рамку; контур малюється обведенням, тінь — розмиттям.
//  Малювальник не прив'язаний до потоку інтерфейсу.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using SkiaSharp;

namespace Slovo;

/// Що малювати.
public sealed class RenderOrder
{
    public Slide Slide = Slide.Blank;
    public SlideStyle Style = new();
    /// Фон, вибраний людиною, — важливіший за фон стилю. Порожньо — фон стилю.
    public string? BackgroundOverride;
    public bool DrawsBackground = true;
    /// Картинка на весь зал (вкладка «Зображення») — замість тексту.
    public string? Picture;
    /// Зал погашено: лише фон (порожній слайд) або чорне.
    public bool Black;
}

public static class SlideRenderer
{
    // MARK: Кадр

    public static SKBitmap Render(RenderOrder order, int width, int height)
    {
        width = Math.Max(1, width);
        height = Math.Max(1, height);
        var bitmap = new SKBitmap(width, height, SKColorType.Bgra8888, SKAlphaType.Premul);
        using var canvas = new SKCanvas(bitmap);
        Draw(order, canvas, width, height);
        canvas.Flush();
        return bitmap;
    }

    public static void Draw(RenderOrder order, SKCanvas canvas, int width, int height)
    {
        canvas.Clear(SKColors.Black);
        if (order.Black) return;
        var style = order.Style;
        if (order.DrawsBackground) DrawBackground(style, order.BackgroundOverride, canvas, width, height);
        if (order.Picture != null)
        {
            var picture = Image(order.Picture);
            if (picture != null) DrawPicture(picture, canvas, new SKRect(0, 0, width, height), fit: true);
            return;
        }
        if (!order.Slide.IsBlank) DrawStack(order.Slide, style, canvas, width, height);
    }

    /// JPEG потрібної ширини — телефону й планшету.
    public static byte[] Jpeg(SKBitmap bitmap, int width, int quality = 80)
    {
        var source = bitmap;
        SKBitmap? scaled = null;
        if (width > 0 && width < bitmap.Width)
        {
            var h = Math.Max(1, (int)Math.Round((double)bitmap.Height * width / bitmap.Width));
            scaled = bitmap.Resize(new SKImageInfo(width, h, SKColorType.Bgra8888, SKAlphaType.Premul), SKFilterQuality.Medium);
            if (scaled != null) source = scaled;
        }
        using var image = SKImage.FromBitmap(source);
        using var data = image.Encode(SKEncodedImageFormat.Jpeg, quality);
        scaled?.Dispose();
        return data.ToArray();
    }

    public static byte[] Png(SKBitmap bitmap)
    {
        using var image = SKImage.FromBitmap(bitmap);
        using var data = image.Encode(SKEncodedImageFormat.Png, 100);
        return data.ToArray();
    }

    // MARK: Підкладка

    static readonly object CacheLock = new();
    static readonly Dictionary<string, (DateTime Stamp, SKBitmap Bitmap)> Images = new();
    static readonly Dictionary<(string Path, int W, int H), SKBitmap> Backdrops = new();

    /// Картинка з диска — з кешем; файл, змінений на диску, перечитується.
    public static SKBitmap? Image(string? path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        try
        {
            if (!File.Exists(path)) return null;
            var stamp = File.GetLastWriteTimeUtc(path);
            lock (CacheLock)
            {
                if (Images.TryGetValue(path, out var cached) && cached.Stamp == stamp) return cached.Bitmap;
            }
            var bitmap = SKBitmap.Decode(path);
            if (bitmap == null) return null;
            lock (CacheLock)
            {
                if (Images.Count > 24)
                {
                    foreach (var old in Images.Values) old.Bitmap.Dispose();
                    Images.Clear();
                    foreach (var backdrop in Backdrops.Values) backdrop.Dispose();
                    Backdrops.Clear();
                }
                Images[path] = (stamp, bitmap);
            }
            return bitmap;
        }
        catch
        {
            return null;
        }
    }

    public static void Forget(string path)
    {
        lock (CacheLock)
        {
            if (Images.Remove(path, out var cached)) cached.Bitmap.Dispose();
            foreach (var key in Backdrops.Keys.Where(k => k.Path == path).ToList()) { Backdrops[key].Dispose(); Backdrops.Remove(key); }
        }
    }

    static void DrawBackground(SlideStyle style, string? overridePath, SKCanvas canvas, int width, int height)
    {
        canvas.Clear(Color(style.BackgroundRgba));
        var path = string.IsNullOrEmpty(overridePath) ? style.BackgroundImagePath : overridePath;
        var image = Image(path);
        if (image == null) return;
        DrawBackdrop(image, path!, canvas, width, height);
        if (style.DimBackground > 0)
        {
            using var dim = new SKPaint { Color = new SKColor(0, 0, 0, (byte)Math.Round(Math.Clamp(style.DimBackground, 0, 1) * 255)) };
            canvas.DrawRect(0, 0, width, height, dim);
        }
    }

    /// Готова підкладка під розмір кадру: інакше кожен вірш заново розтягував
    /// би фотографію на весь холст.
    static void DrawBackdrop(SKBitmap image, string path, SKCanvas canvas, int width, int height)
    {
        var key = (path, width, height);
        SKBitmap? ready;
        lock (CacheLock) Backdrops.TryGetValue(key, out ready);
        if (ready == null)
        {
            ready = new SKBitmap(width, height, SKColorType.Bgra8888, SKAlphaType.Premul);
            using (var scratch = new SKCanvas(ready))
            {
                scratch.Clear(SKColors.Black);
                DrawPicture(image, scratch, new SKRect(0, 0, width, height), fit: false);
            }
            lock (CacheLock)
            {
                if (Backdrops.Count >= 6) { foreach (var b in Backdrops.Values) b.Dispose(); Backdrops.Clear(); }
                Backdrops[key] = ready;
            }
        }
        canvas.DrawBitmap(ready, 0, 0);
    }

    /// Картинка в рамку: `fit` — уписати цілком, інакше заповнити з обрізанням.
    public static void DrawPicture(SKBitmap image, SKCanvas canvas, SKRect rect, bool fit)
    {
        if (image.Width <= 0 || image.Height <= 0) return;
        var scale = fit ? Math.Min(rect.Width / image.Width, rect.Height / image.Height)
                        : Math.Max(rect.Width / image.Width, rect.Height / image.Height);
        var w = image.Width * scale;
        var h = image.Height * scale;
        var place = new SKRect(rect.MidX - w / 2, rect.MidY - h / 2, rect.MidX + w / 2, rect.MidY + h / 2);
        using var paint = new SKPaint { FilterQuality = SKFilterQuality.Medium, IsAntialias = true };
        canvas.Save();
        canvas.ClipRect(rect);
        canvas.DrawBitmap(image, place, paint);
        canvas.Restore();
    }

    // MARK: Стопка «вірш — другий переклад — адреса»

    /// Числа ті самі, що на Mac: промежуток `висота × міжрядковий × 0,35`,
    /// висота блока `висота × кегль × 3,4`, відступ адреси `висота × 0,02`.
    static void DrawStack(Slide slide, SlideStyle style, SKCanvas canvas, int width, int height)
    {
        var blocks = new List<(string Text, TextLayer Layer, double Height, double GapAbove)>();
        var spacing = height * style.LineSpacing * 0.35;
        if (slide.MainText.Length > 0) blocks.Add((slide.MainText, style.Main, height * style.Main.FontSize * 3.4, 0));
        foreach (var text in slide.SecondaryTexts.Where(t => t.Length > 0))
            blocks.Add((text, style.Secondary, height * style.Secondary.FontSize * 3.4, blocks.Count == 0 ? 0 : spacing));
        if (slide.Reference.Length > 0)
            blocks.Add((slide.Reference, style.Reference, height * style.Reference.FontSize * 3.4, (blocks.Count == 0 ? 0 : spacing) + height * 0.02));
        if (blocks.Count == 0) return;

        var box = new SKRect((float)(width * style.HorizontalInset), (float)(height * style.VerticalInset),
                             (float)(width * (1 - style.HorizontalInset)), (float)(height * (1 - style.VerticalInset)));
        // Довгий текст (куплет на шість рядків, кілька віршів) спершу займає вільну
        // висоту слайда і лише потім стискається: на Mac цю роль грають рамки
        // шаблонів Конструктора (цитата — 46–70 % висоти), яких тут немає.
        if (slide.MainText.Length > 0 && blocks.Count > 0)
        {
            var others = blocks.Skip(1).Sum(b => b.Height + b.GapAbove);
            var free = box.Height - others;
            var needed = MeasureHeight(slide.MainText, style.Main, style.LineSpacing, box.Width, height);
            var main = blocks[0];
            if (needed > main.Height && free > main.Height)
                blocks[0] = (main.Text, main.Layer, Math.Min(needed, free), main.GapAbove);
        }
        var total = blocks.Sum(b => b.Height + b.GapAbove);
        // Стопка вища за рамку — стискаємо блоки пропорційно, інакше адреса
        // вилізла б за нижній край.
        var squeeze = total > box.Height && total > 0 ? box.Height / total : 1.0;
        var top = style.TextVertical switch
        {
            TextVertical.Top => (double)box.Top,
            TextVertical.Bottom => box.Bottom - total * squeeze,
            _ => box.MidY - total * squeeze / 2,
        };
        foreach (var block in blocks)
        {
            top += block.GapAbove * squeeze;
            var rect = new SKRect(box.Left, (float)top, box.Right, (float)(top + block.Height * squeeze));
            DrawText(block.Text, block.Layer, style.LineSpacing, SKTextAlign.Center, TextVertical.Center,
                     style.MinimumScale, rect, height, canvas);
            top += block.Height * squeeze;
        }
    }

    // MARK: Надпис

    /// Висота тексту за повного кегля — скільки місця йому треба без стискання.
    static double MeasureHeight(string text, TextLayer layer, double lineSpacing, float width, double canvasHeight)
    {
        var size = (float)(canvasHeight * layer.FontSize);
        using var paint = new SKPaint { Typeface = Fonts.Typeface(layer.FontName, layer.IsBold, layer.IsItalic), TextSize = size, IsAntialias = true };
        var metrics = paint.FontMetrics;
        var lineHeight = (metrics.Descent - metrics.Ascent) + (float)(size * lineSpacing);
        return Wrap(text, paint, width).Count * lineHeight + 1;
    }

    public static void DrawText(string text, TextLayer layer, double lineSpacing, SKTextAlign align,
                                TextVertical verticalAlignment, double minimumScale, SKRect rect,
                                double canvasHeight, SKCanvas canvas)
    {
        if (rect.Width < 2 || rect.Height < 2 || text.Trim().Length == 0) return;
        var typeface = Fonts.Typeface(layer.FontName, layer.IsBold, layer.IsItalic);
        var requested = (float)(canvasHeight * layer.FontSize);
        var smallest = (float)Math.Max(6, requested * Math.Clamp(minimumScale, 0.1, 1));

        using var measure = new SKPaint { Typeface = typeface, IsAntialias = true, SubpixelText = true };
        List<string> Layout(float size, out float lineHeight)
        {
            measure.TextSize = size;
            var metrics = measure.FontMetrics;
            lineHeight = (metrics.Descent - metrics.Ascent) + (float)(size * lineSpacing);
            return Wrap(text, measure, rect.Width);
        }
        bool Fits(List<string> lines, float lineHeight) => lines.Count * lineHeight <= rect.Height + 0.5f;

        // Підбираємо кегль діленням пополам: перебір по одному пункту на
        // довгому вірші робив би двадцять замірів замість шести.
        var low = smallest;
        var high = requested;
        var best = smallest;
        var bestLines = Layout(smallest, out var bestLineHeight);
        if (Fits(bestLines, bestLineHeight))
        {
            for (var i = 0; i < 7; i++)
            {
                var middle = (low + high) / 2;
                var candidate = Layout(middle, out var candidateHeight);
                if (Fits(candidate, candidateHeight)) { best = middle; bestLines = candidate; bestLineHeight = candidateHeight; low = middle; }
                else high = middle;
            }
        }

        measure.TextSize = best;
        var fontMetrics = measure.FontMetrics;
        var blockHeight = bestLines.Count * bestLineHeight;
        var startY = verticalAlignment switch
        {
            TextVertical.Top => rect.Top,
            TextVertical.Bottom => rect.Bottom - blockHeight,
            _ => rect.MidY - blockHeight / 2,
        };
        // Стопка, що все ж не влізла за найменшого кегля, притискається
        // до верху рамки, а не вилазить за її верхній край.
        if (blockHeight > rect.Height) startY = rect.Top;

        var outline = (float)(layer.OutlineWidth * canvasHeight);
        var shadowBlur = (float)(layer.ShadowRadius * canvasHeight);
        var shadowOffset = (float)(layer.ShadowOffset * canvasHeight);

        using var fill = new SKPaint { Typeface = typeface, TextSize = best, IsAntialias = true, SubpixelText = true, Color = Color(layer.Rgba), TextAlign = align, Style = SKPaintStyle.Fill };
        using var stroke = new SKPaint { Typeface = typeface, TextSize = best, IsAntialias = true, SubpixelText = true, Color = Color(layer.OutlineRgba), TextAlign = align, Style = SKPaintStyle.Stroke, StrokeWidth = outline * 2, StrokeJoin = SKStrokeJoin.Round, StrokeCap = SKStrokeCap.Round };
        SKPaint? shadow = null;
        if (shadowBlur > 0.3 || shadowOffset > 0.3)
        {
            shadow = new SKPaint { Typeface = typeface, TextSize = best, IsAntialias = true, TextAlign = align, Style = SKPaintStyle.StrokeAndFill, StrokeWidth = (float)Math.Max(outline, best * 0.02), Color = new SKColor(0, 0, 0, (byte)Math.Round(Math.Clamp(layer.ShadowOpacity, 0, 1) * 255)) };
            if (shadowBlur > 0.3) shadow.MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, Math.Max(0.5f, shadowBlur * 0.6f));
        }

        var x = align switch { SKTextAlign.Left => rect.Left, SKTextAlign.Right => rect.Right, _ => rect.MidX };
        var y = startY - fontMetrics.Ascent;
        canvas.Save();
        canvas.ClipRect(new SKRect(rect.Left - outline * 4 - shadowBlur * 3, rect.Top - outline * 4 - shadowBlur * 3,
                                   rect.Right + outline * 4 + shadowBlur * 3, rect.Bottom + outline * 4 + shadowBlur * 3));
        foreach (var line in bestLines)
        {
            if (line.Length > 0)
            {
                if (shadow != null) canvas.DrawText(line, x + shadowOffset, y + shadowOffset, shadow);
                if (outline > 0.2) canvas.DrawText(line, x, y, stroke);
                canvas.DrawText(line, x, y, fill);
                if (layer.IsUnderline)
                {
                    var w = measure.MeasureText(line);
                    var left = align switch { SKTextAlign.Left => x, SKTextAlign.Right => x - w, _ => x - w / 2 };
                    var thickness = Math.Max(1, best / 16);
                    var underY = y + fontMetrics.Descent * 0.45f;
                    using var under = new SKPaint { Color = Color(layer.Rgba), IsAntialias = true };
                    canvas.DrawRect(left, underY, w, thickness, under);
                }
            }
            y += bestLineHeight;
        }
        canvas.Restore();
        shadow?.Dispose();
    }

    /// Перенос за словами; перенос рядка в тексті (куплет) — завжди межа.
    static List<string> Wrap(string text, SKPaint paint, float width)
    {
        var lines = new List<string>();
        foreach (var paragraph in text.Replace("\r\n", "\n").Split('\n'))
        {
            var words = paragraph.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (words.Length == 0) { lines.Add(""); continue; }
            var current = "";
            foreach (var word in words)
            {
                var candidate = current.Length == 0 ? word : current + " " + word;
                if (paint.MeasureText(candidate) <= width || current.Length == 0)
                {
                    // Слово, довше за рядок, рубаємо посередині, інакше воно
                    // вилізе за край рамки.
                    if (current.Length == 0 && paint.MeasureText(candidate) > width && candidate.Length > 1)
                    {
                        var piece = "";
                        foreach (var ch in candidate)
                        {
                            if (piece.Length > 0 && paint.MeasureText(piece + ch) > width) { lines.Add(piece); piece = ""; }
                            piece += ch;
                        }
                        current = piece;
                        continue;
                    }
                    current = candidate;
                }
                else
                {
                    lines.Add(current);
                    current = word;
                }
            }
            lines.Add(current);
        }
        return lines;
    }

    public static SKColor Color(RGBA rgba) =>
        new((byte)Math.Round(Math.Clamp(rgba.R, 0, 1) * 255), (byte)Math.Round(Math.Clamp(rgba.G, 0, 1) * 255),
            (byte)Math.Round(Math.Clamp(rgba.B, 0, 1) * 255), (byte)Math.Round(Math.Clamp(rgba.A, 0, 1) * 255));
}

/// Шрифти: системні за ім'ям сім'ї плюс привезені в теку Fonts (`.ttf`).
public static class Fonts
{
    static readonly object Lock = new();
    static readonly Dictionary<string, SKTypeface> Cache = new();
    static readonly Dictionary<string, string> Files = new(StringComparer.OrdinalIgnoreCase);
    static bool _scanned;

    /// Імена сімей для списку в налаштуваннях: системні й привезені.
    public static List<string> Families()
    {
        Scan();
        var names = new SortedSet<string>(StringComparer.CurrentCultureIgnoreCase);
        try { foreach (var family in SKFontManager.Default.FontFamilies) names.Add(family); } catch { /* без списку системних */ }
        lock (Lock) foreach (var name in Files.Keys) names.Add(name);
        return names.ToList();
    }

    public static SKTypeface Typeface(string family, bool bold, bool italic)
    {
        Scan();
        var key = family + "|" + bold + "|" + italic;
        lock (Lock)
        {
            if (Cache.TryGetValue(key, out var cached)) return cached;
        }
        SKTypeface? typeface = null;
        string? file;
        lock (Lock) Files.TryGetValue(family, out file);
        if (file != null)
        {
            try { typeface = SKTypeface.FromFile(file); } catch { typeface = null; }
        }
        if (typeface == null)
        {
            var style = new SKFontStyle(bold ? SKFontStyleWeight.Bold : SKFontStyleWeight.Normal, SKFontStyleWidth.Normal,
                                        italic ? SKFontStyleSlant.Italic : SKFontStyleSlant.Upright);
            try { typeface = SKFontManager.Default.MatchFamily(family, style); } catch { typeface = null; }
            typeface ??= SKTypeface.FromFamilyName(family, style);
            typeface ??= SKTypeface.FromFamilyName("Arial", style) ?? SKTypeface.Default;
        }
        lock (Lock) Cache[key] = typeface;
        return typeface;
    }

    /// Перечитати теку шрифтів — після встановлення ресурсів.
    public static void Rescan()
    {
        lock (Lock) { _scanned = false; Cache.Clear(); Files.Clear(); }
        Scan();
    }

    static void Scan()
    {
        lock (Lock)
        {
            if (_scanned) return;
            _scanned = true;
            try
            {
                var folder = Paths.Fonts;
                foreach (var file in Directory.GetFiles(folder).Where(f => f.EndsWith(".ttf", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".otf", StringComparison.OrdinalIgnoreCase)))
                {
                    try
                    {
                        using var face = SKTypeface.FromFile(file);
                        if (face != null && !string.IsNullOrEmpty(face.FamilyName)) Files[face.FamilyName] = file;
                        Files[Path.GetFileNameWithoutExtension(file)] = file;
                    }
                    catch { /* не шрифт */ }
                }
            }
            catch { /* теки шрифтів нема */ }
        }
    }
}
