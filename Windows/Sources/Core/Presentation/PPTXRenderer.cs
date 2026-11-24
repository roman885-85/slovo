// =============================================================================
//  PPTXRenderer.cs — малювання слайда презентації в картинку
//  (з Presentation/PPTXRenderer.swift)
// =============================================================================
//  CoreGraphics + CoreText → SkiaSharp 2.88. Полотно Skia вже «згори вниз»,
//  тож перевертання, яке на Mac робиться заради CG, тут не потрібне — крім
//  текстур теми: CG кладе їх догори дриґом, і тут так само.
//  Верстку тексту CoreText (перенесення за словами, відступи, табуляції,
//  вирівнювання, «\n» як кінець абзацу, обрізання рядків, що не влізли в
//  рамку) повторено своїм кодом; шрифт, якого бракує для знака, добирається
//  системою (як каскад CoreText). Кернінгу й лігатур немає — Skia без HarfBuzz.
// =============================================================================

using SkiaSharp;

namespace Slovo.Core;

/// Малювання слайда презентації в картинку.
///
/// Картинкою, а не своїм видом на екрані, — навмисно: готовий кадр іде тією
/// ж дорогою, що відео і фото, і тому одразу опиняється скрізь, де потрібен:
/// у вікні слайда, у передпоказі і в трансляції. Жодного нового вікна, жодного
/// нового шару.
///
/// Усе, що прийшло з файла, лежить у частках полотна, тому малювати можна в
/// будь-якому розмірі: мініатюру в список і повний кадр у зал рахує один і той
/// самий код.
public static class PPTXRenderer
{
    public static SKBitmap? Image(PPTXDocument.Slide slide, PPTXDocument document, SizeD size)
    {
        var width = (int)Math.Round(size.Width, MidpointRounding.AwayFromZero);
        var height = (int)Math.Round(size.Height, MidpointRounding.AwayFromZero);
        if (width <= 0 || height <= 0) return null;

        var bitmap = new SKBitmap(new SKImageInfo(width, height, SKColorType.Bgra8888, SKAlphaType.Premul));
        using var canvas = new SKCanvas(bitmap);
        // Білий за умовчанням: у PowerPoint порожній слайд білий, і чорний
        // прямокутник замість нього читався б як поломка.
        canvas.Clear(SKColors.White);
        var full = new SKRect(0, 0, (float)size.Width, (float)size.Height);
        DrawFill(slide.Background, full, document, canvas, size);

        foreach (var shape in slide.Shapes)
        {
            var rect = SKRect.Create((float)(shape.Frame.X * size.Width), (float)(shape.Frame.Y * size.Height),
                                     (float)(shape.Frame.Width * size.Width), (float)(shape.Frame.Height * size.Height));
            canvas.Save();
            if (shape.Rotation != 0 || shape.FlipH || shape.FlipV)
            {
                canvas.Translate(rect.MidX, rect.MidY);
                if (shape.Rotation != 0) canvas.RotateDegrees((float)shape.Rotation);
                if (shape.FlipH || shape.FlipV) canvas.Scale(shape.FlipH ? -1 : 1, shape.FlipV ? -1 : 1);
                canvas.Translate(-rect.MidX, -rect.MidY);
            }
            DrawShape(shape, rect, document, canvas, size);
            DrawParagraphs(shape.Paragraphs, rect, canvas, size, shape.Anchor, shape.FontScale, shape.Autofit, shape.TextShadow);
            canvas.Restore();
        }
        canvas.Flush();
        return bitmap;
    }

    private static SKColor Color(SlideStyle.RGBA color) => new(
        (byte)Math.Round(Math.Clamp(color.Red, 0, 1) * 255), (byte)Math.Round(Math.Clamp(color.Green, 0, 1) * 255),
        (byte)Math.Round(Math.Clamp(color.Blue, 0, 1) * 255), (byte)Math.Round(Math.Clamp(color.Alpha, 0, 1) * 255));

    /// Тінь CG задається в просторі пристрою (не крутиться разом із фігурою),
    /// а тінь Skia — у поточних координатах: зсув повертаємо назад.
    private static SKImageFilter ShadowFilter(SKCanvas canvas, PPTXDocument.Shadow shadow, SizeD size)
    {
        var dx = (float)(shadow.Offset.Width * size.Height);
        var dy = (float)(shadow.Offset.Height * size.Height);
        var matrix = canvas.TotalMatrix;
        if (matrix.TryInvert(out var inverse))
        {
            var local = inverse.MapVector(dx, dy);
            dx = local.X;
            dy = local.Y;
        }
        // Розмиття CG ≈ два сигми гаусового розмиття.
        var sigma = (float)(shadow.Blur * size.Height / 2);
        return SKImageFilter.CreateDropShadow(dx, dy, sigma, sigma, Color(shadow.Color));
    }

    /// Фігура: заливка своєю формою і обведення поверх неї.
    ///
    /// Форма важлива: кружечком у презентаціях обводять слово в рядку, і залитий
    /// прямокутник на його місці закриває собою те, заради чого його й малювали.
    private static void DrawShape(PPTXDocument.Shape shape, SKRect rect, PPTXDocument document, SKCanvas canvas, SizeD size)
    {
        using var path = new SKPath();
        switch (shape.Outline)
        {
            case PPTXDocument.Outline.Ellipse:
                path.AddOval(rect);
                break;
            case PPTXDocument.Outline.RoundedRectangle:
                var radius = Math.Min(rect.Width, rect.Height) * 0.12f;
                path.AddRoundRect(rect, radius, radius);
                break;
            case PPTXDocument.Outline.Line:
                path.MoveTo(rect.Left, rect.Top);
                path.LineTo(rect.Right, rect.Bottom);
                break;
            default:
                path.AddRect(rect);
                break;
        }

        // Тінь під фігурою чи картинкою.
        var hasContent = shape.Fill is PPTXDocument.Fill.Picture or PPTXDocument.Fill.Solid or PPTXDocument.Fill.GradientCase;
        if (hasContent)
        {
            canvas.Save();
            if (shape.Fill is PPTXDocument.Fill.GradientCase) canvas.ClipPath(path, antialias: true);
            if (shape.Shadow is { } shadow)
            {
                using var layer = new SKPaint { ImageFilter = ShadowFilter(canvas, shadow, size) };
                canvas.SaveLayer(layer);
            }
            switch (shape.Fill)
            {
                case PPTXDocument.Fill.Picture picture:
                    DrawPicture(picture.Part, shape.Crop, rect, document, canvas);
                    break;
                case PPTXDocument.Fill.Solid solid:
                    using (var paint = new SKPaint { Color = Color(solid.Color), IsAntialias = true, Style = SKPaintStyle.Fill })
                        canvas.DrawPath(path, paint);
                    break;
                case PPTXDocument.Fill.GradientCase gradient:
                    DrawGradient(gradient.Gradient, rect, canvas);
                    break;
            }
            if (shape.Shadow != null) canvas.Restore();
            canvas.Restore();
        }

        if (shape.StrokeColor is { } stroke && shape.StrokeWidth > 0)
        {
            using var paint = new SKPaint
            {
                Color = Color(stroke),
                IsAntialias = true,
                Style = SKPaintStyle.Stroke,
                StrokeWidth = (float)Math.Max(1, shape.StrokeWidth * size.Height),
            };
            canvas.DrawPath(path, paint);
        }
    }

    // ── Заливка ─────────────────────────────────────────────────────────────

    private static void DrawFill(PPTXDocument.Fill fill, SKRect rect, PPTXDocument document, SKCanvas canvas, SizeD size)
    {
        switch (fill)
        {
            case PPTXDocument.Fill.Solid solid:
                using (var paint = new SKPaint { Color = Color(solid.Color), Style = SKPaintStyle.Fill })
                    canvas.DrawRect(rect, paint);
                break;
            case PPTXDocument.Fill.Picture picture:
                DrawPicture(picture.Part, new PPTXDocument.Crop(0, 0, 0, 0), rect, document, canvas);
                break;
            case PPTXDocument.Fill.Texture texture:
                DrawTexture(texture.Part, texture.TileScale, texture.Duotone, rect, document, canvas);
                break;
            case PPTXDocument.Fill.GradientCase gradient:
                canvas.Save();
                canvas.ClipRect(rect);
                DrawGradient(gradient.Gradient, rect, canvas);
                canvas.Restore();
                break;
        }
    }

    /// Перехід кольору в рамці. Обрізку формою фігури ставить той, хто кличе.
    ///
    /// Зупинки рахуються від осердя (чи від початку прямого переходу) до
    /// краю: у темі «Твердий переплет» прозоре біле стоїть на 83 %, а
    /// кремове — на 100 %, тобто по самому краю слайда.
    private static void DrawGradient(PPTXDocument.Gradient gradient, SKRect rect, SKCanvas canvas)
    {
        var colors = gradient.Stops.Select(stop => Color(stop.Color)).ToArray();
        var places = gradient.Stops.Select(stop => (float)stop.Position).ToArray();
        SKRect Absolute(RectD focus) => SKRect.Create(rect.Left + (float)focus.X * rect.Width, rect.Top + (float)focus.Y * rect.Height,
                                                      (float)focus.Width * rect.Width, (float)focus.Height * rect.Height);
        switch (gradient.Kind)
        {
            case PPTXDocument.GradientKind.Linear linear:
            {
                var radians = linear.Angle * Math.PI / 180;
                var dx = (float)Math.Cos(radians);
                var dy = (float)Math.Sin(radians);
                var half = (Math.Abs(dx) * rect.Width + Math.Abs(dy) * rect.Height) / 2;
                using var shader = SKShader.CreateLinearGradient(new SKPoint(rect.MidX - dx * half, rect.MidY - dy * half),
                                                                 new SKPoint(rect.MidX + dx * half, rect.MidY + dy * half),
                                                                 colors, places, SKShaderTileMode.Clamp);
                using var paint = new SKPaint { Shader = shader };
                canvas.DrawRect(rect, paint);
                break;
            }
            case PPTXDocument.GradientKind.Radial radial:
            {
                var core = Absolute(radial.Focus);
                var center = new SKPoint(core.MidX, core.MidY);
                var reach = new[] { new SKPoint(rect.Left, rect.Top), new SKPoint(rect.Right, rect.Top), new SKPoint(rect.Left, rect.Bottom), new SKPoint(rect.Right, rect.Bottom) }
                    .Max(point => (float)Math.Sqrt((point.X - center.X) * (point.X - center.X) + (point.Y - center.Y) * (point.Y - center.Y)));
                using var shader = SKShader.CreateRadialGradient(center, Math.Max(reach, 0.001f), colors, places, SKShaderTileMode.Clamp);
                using var paint = new SKPaint { Shader = shader };
                canvas.DrawRect(rect, paint);
                break;
            }
            case PPTXDocument.GradientKind.Rectangular rectangular:
            {
                // Рамка картини: чотири трапеції від осердя до країв, у кожній
                // свій прямий перехід. Згладжування на цей час вимикаємо: інакше
                // по діагоналях, де трапеції сходяться, напівпрозорі краї
                // накладалися б і давали видимі промені з кутів.
                var core = Absolute(rectangular.Focus);
                (SKPoint[] Points, SKPoint From, SKPoint To)[] sides =
                [
                    ([new(rect.Left, rect.Top), new(rect.Right, rect.Top), new(core.Right, core.Top), new(core.Left, core.Top)],
                     new(rect.MidX, core.Top), new(rect.MidX, rect.Top)),
                    ([new(rect.Left, rect.Bottom), new(rect.Right, rect.Bottom), new(core.Right, core.Bottom), new(core.Left, core.Bottom)],
                     new(rect.MidX, core.Bottom), new(rect.MidX, rect.Bottom)),
                    ([new(rect.Left, rect.Top), new(rect.Left, rect.Bottom), new(core.Left, core.Bottom), new(core.Left, core.Top)],
                     new(core.Left, rect.MidY), new(rect.Left, rect.MidY)),
                    ([new(rect.Right, rect.Top), new(rect.Right, rect.Bottom), new(core.Right, core.Bottom), new(core.Right, core.Top)],
                     new(core.Right, rect.MidY), new(rect.Right, rect.MidY)),
                ];
                foreach (var side in sides)
                {
                    canvas.Save();
                    using var clip = new SKPath();
                    clip.AddPoly(side.Points, close: true);
                    canvas.ClipPath(clip, antialias: false);
                    var from = side.From;
                    var to = side.To;
                    if (from == to) to = new SKPoint(to.X + 0.001f, to.Y + 0.001f);
                    using var shader = SKShader.CreateLinearGradient(from, to, colors, places, SKShaderTileMode.Clamp);
                    using var paint = new SKPaint { Shader = shader, IsAntialias = false };
                    canvas.DrawRect(rect, paint);
                    canvas.Restore();
                }
                if (core.Width > 0 && core.Height > 0 && gradient.Stops.Count > 0)
                {
                    using var paint = new SKPaint { Color = colors[0], IsAntialias = false };
                    canvas.DrawRect(core, paint);
                }
                break;
            }
        }
    }

    /// Текстура фону теми: з дуотоном у колір фону, замощена чи розтягнута.
    ///
    /// Дуотон (на Mac `CIFalseColor`): яскравість пікселя → колір між темним і
    /// світлим. Розмір плитки PowerPoint рахує від розміру картинки в дюймах
    /// (72 dpi) помножено на масштаб плитки; слайд — 10 дюймів завширшки, тож
    /// текстура 1440 точок при 60 % — це 12 дюймів, трохи ширша за слайд.
    private static void DrawTexture(string part, double? tileScale, PPTXDocument.Duotone? duotone, SKRect rect,
                                    PPTXDocument document, SKCanvas canvas)
    {
        using var source = document.Image(part);
        if (source == null) return;
        var image = source;
        SKBitmap? toned = null;
        if (duotone is { } tone)
        {
            toned = new SKBitmap(source.Width, source.Height, SKColorType.Bgra8888, SKAlphaType.Premul);
            var dark = tone.Dark;
            var light = tone.Light;
            for (var y = 0; y < source.Height; y++)
            {
                for (var x = 0; x < source.Width; x++)
                {
                    var pixel = source.GetPixel(x, y);
                    var luminance = (0.2126 * pixel.Red + 0.7152 * pixel.Green + 0.0722 * pixel.Blue) / 255.0;
                    var mixed = new SlideStyle.RGBA(dark.Red + (light.Red - dark.Red) * luminance,
                                                    dark.Green + (light.Green - dark.Green) * luminance,
                                                    dark.Blue + (light.Blue - dark.Blue) * luminance,
                                                    (dark.Alpha + (light.Alpha - dark.Alpha) * luminance) * pixel.Alpha / 255.0);
                    toned.SetPixel(x, y, Color(mixed));
                }
            }
            image = toned;
        }
        try
        {
            canvas.Save();
            canvas.ClipRect(rect);
            using var paint = new SKPaint { FilterQuality = SKFilterQuality.None };
            // Як на Mac: CG кладе картинку низом догори, і текстура лягає
            // віддзеркаленою — у ній низ від верху не відрізнити.
            void DrawMirrored(SKRect place)
            {
                canvas.Save();
                canvas.Translate(0, place.Top + place.Bottom);
                canvas.Scale(1, -1);
                canvas.DrawBitmap(image, place, paint);
                canvas.Restore();
            }
            if (tileScale is { } scale)
            {
                const double slideInches = 10.0;
                var tileWidth = (float)(image.Width / 72.0 * scale / slideInches * rect.Width);
                var tileHeight = tileWidth * image.Height / Math.Max(image.Width, 1);
                if (tileWidth > 0.5f && tileHeight > 0.5f)
                {
                    for (var y = rect.Top; y < rect.Bottom; y += tileHeight)
                        for (var x = rect.Left; x < rect.Right; x += tileWidth)
                            DrawMirrored(SKRect.Create(x, y, tileWidth, tileHeight));
                }
            }
            else
            {
                DrawMirrored(rect);
            }
            canvas.Restore();
        }
        finally
        {
            toned?.Dispose();
        }
    }

    /// Картинка в рамку, з обрізкою, якщо її задано.
    ///
    /// Обрізка — не прикраса: нею в презентаціях беруть шматок фотографії, і
    /// без неї на слайд потрапляє вся картинка цілком, а потрібен був куток.
    private static void DrawPicture(string part, PPTXDocument.Crop crop, SKRect rect, PPTXDocument document, SKCanvas canvas)
    {
        using var image = document.Image(part);
        if (image == null) return;
        var source = SKRect.Create(0, 0, image.Width, image.Height);
        if (!crop.IsEmpty)
        {
            double width = image.Width, height = image.Height;
            var box = SKRect.Create((float)(width * crop.Left), (float)(height * crop.Top),
                                    (float)(width * (1 - crop.Left - crop.Right)), (float)(height * (1 - crop.Top - crop.Bottom)));
            // `CGImage.cropping(to:)`: рамка округлюється до цілих пікселів і
            // обрізається межами картинки.
            var integral = SKRect.Create((float)Math.Floor(box.Left), (float)Math.Floor(box.Top), 0, 0);
            integral.Right = (float)Math.Ceiling(box.Right);
            integral.Bottom = (float)Math.Ceiling(box.Bottom);
            integral.Intersect(SKRect.Create(0, 0, image.Width, image.Height));
            if (box.Width > 1 && box.Height > 1 && !integral.IsEmpty) source = integral;
        }
        // Розтягуємо в рамку, як PowerPoint: рамка — це те, що людина бачила,
        // коли ставила картинку, і саме такою вона хоче її на стіні.
        // Раніше картинка вписувалася цілком, і з боків лишалися білі поля з
        // чорною обвідкою — власник: «частини інформації немає, елементи
        // спотворені».
        using var paint = new SKPaint { FilterQuality = Quality(source, rect, canvas), IsAntialias = true };
        canvas.DrawBitmap(image, source, rect, paint);
    }

    /// Згладжування картинки так, як його бачимо в CGBitmapContext на Mac:
    /// збільшена — чіткими пікселями, зменшена — з фільтром.
    private static SKFilterQuality Quality(SKRect source, SKRect place, SKCanvas canvas)
    {
        var scale = canvas.TotalMatrix.MapVector(place.Width, place.Height);
        var upscale = Math.Abs(scale.X) >= source.Width && Math.Abs(scale.Y) >= source.Height;
        return upscale ? SKFilterQuality.None : SKFilterQuality.Medium;
    }

    // ── Текст ───────────────────────────────────────────────────────────────

    private static void DrawParagraphs(List<PPTXDocument.Paragraph> paragraphs, SKRect rect, SKCanvas canvas, SizeD size,
                                       string anchor, double fontScale, string autofit = "none", PPTXDocument.Shadow? shadow = null)
    {
        if (paragraphs.Count == 0) return;
        var text = Attributed(paragraphs, size.Height, fontScale);
        TextLayout? layout = null;
        try
        {
            // Довжина рядка з атрибутами: знаки шматків і «\n» між абзацами.
            if (text.Sum(paragraph => paragraph.Runs.Sum(run => run.Text.Length)) + text.Count - 1 <= 0) return;

            // Внутрішні поля напису в PowerPoint за умовчанням 0,1 і 0,05 дюйма;
            // у частках полотна це приблизно один відсоток — так текст не липне до
            // краю рамки, як і в самому PowerPoint.
            var padded = rect;
            padded.Inflate(-(float)(size.Width * 0.006), -(float)(size.Height * 0.006));
            if (!(padded.Width > 1) || !(padded.Height > 1)) return;

            // Текст у рамку не вміщається — стискаємо лише тоді, коли так робить
            // сам PowerPoint (`normAutofit`), і починаємо з його числа. При
            // `noAutofit` і `spAutoFit` PowerPoint не стискає: текст виходить за
            // рамку, і слайд саме такий люди й бачили. Доти ми стискали завжди,
            // і текст виходив дрібнішим, а рядки переносилися інакше.
            var shrinks = autofit == "normal";
            var scale = fontScale;
            layout = TextLayout.Make(text, padded.Width);
            var guardCount = 0;
            while (shrinks && layout.Height > padded.Height && scale > 0.3 && guardCount < 12)
            {
                scale -= 0.08;
                guardCount += 1;
                layout.Dispose();
                foreach (var paragraph in text) paragraph.Dispose();
                text = Attributed(paragraphs, size.Height, scale);
                layout = TextLayout.Make(text, padded.Width);
            }

            // Куди притиснуто текст. У PowerPoint за умовчанням — верх; притискати все
            // до середини означало б рухати заголовки вниз на кожному слайді.
            var visible = shrinks ? Math.Min(layout.Height, padded.Height) : layout.Height;
            var top = anchor switch
            {
                "center" => padded.MidY - visible / 2,
                "bottom" => padded.Bottom - visible,
                _ => padded.Top,
            };
            var box = SKRect.Create(padded.Left, top, padded.Width, visible);

            canvas.Save();
            if (shadow is { } textShadow)
            {
                using var layer = new SKPaint { ImageFilter = ShadowFilter(canvas, textShadow, size) };
                canvas.SaveLayer(layer);
            }
            layout.Draw(canvas, box);
            if (shadow != null) canvas.Restore();
            canvas.Restore();
        }
        finally
        {
            layout?.Dispose();
            foreach (var paragraph in text) paragraph.Dispose();
        }
    }

    /// Абзац для верстки: стиль абзацу і шматки тексту зі своїм шрифтом.
    private sealed class StyledParagraph : IDisposable
    {
        public string Alignment = "left";
        public float HeadIndent;
        public float FirstLineHeadIndent;
        public List<float> TabStops = new();
        public float DefaultTab;
        public readonly List<StyledRun> Runs = new();
        /// Абзац без жодного знака: рядок тримає лише кінець абзацу (шрифт
        /// за умовчанням), як у CoreText.
        public bool IsEmpty => Runs.Count == 0;

        public void Dispose()
        {
            foreach (var run in Runs) run.Paint.Dispose();
        }
    }

    private sealed record StyledRun(string Text, SKPaint Paint, bool Underline);

    private static List<StyledParagraph> Attributed(List<PPTXDocument.Paragraph> paragraphs, double canvasHeight, double scale = 1)
    {
        // Кегль записано в пунктах для слайда його власного розміру. Полотно
        // буває будь-яким, тому переводимо через висоту: слайд PowerPoint —
        // це 7,5 дюйма, тобто 540 пунктів.
        var pointsPerCanvas = canvasHeight / 540;
        var result = new List<StyledParagraph>();
        foreach (var paragraph in paragraphs)
        {
            var style = new StyledParagraph { Alignment = paragraph.Alignment };
            // Відступи з `marL`/`indent`; коли їх нема — за рівнем списку.
            var head = paragraph.MarginLeft * pointsPerCanvas;
            var first = (paragraph.MarginLeft + paragraph.FirstIndent) * pointsPerCanvas;
            if (paragraph.MarginLeft == 0 && paragraph.FirstIndent == 0)
            {
                head = paragraph.Indent * canvasHeight;
                first = head;
                // Маркер без відступів: висячий на чверть дюйма, як у PowerPoint.
                if (paragraph.Bullet != null) head += 18 * pointsPerCanvas;
            }
            style.HeadIndent = (float)head;
            style.FirstLineHeadIndent = (float)first;
            // Табуляція в PowerPoint — дюйм (`defTabSz` 914400 EMU); CoreText за
            // умовчанням ставить її куди дрібніше, і адреса, яку автор відсунув
            // табуляціями до правого краю, у нас стояла посеред рядка.
            style.DefaultTab = (float)(72 * pointsPerCanvas);

            if (paragraph.Bullet is { } bullet && paragraph.Runs.FirstOrDefault(run => run.Text.Length > 0) is { } lead)
            {
                // Маркер: кегль і колір тексту (чи свої), шрифт свій — Wingdings
                // «ü» це галочка, і малювати її треба саме нею, а не системним
                // шрифтом у 12 пунктів, як виходило доти (крапка замість галочки).
                var points = lead.Size * pointsPerCanvas * scale * (paragraph.BulletSize ?? 1);
                var mark = BulletText(bullet, paragraph.BulletFont);
                var paint = MakePaint(mark.Font ?? lead.FontName, Math.Max(4, points), false, false, paragraph.BulletColor ?? lead.Color);
                // Після маркера — табуляція до лівого відступу тексту.
                style.TabStops = [(float)head];
                // Великий маркер буває ширший за свій відступ (стрілка кеглем
                // 54 при відступі 45 пунктів). Табуляція тоді стрибає аж до
                // наступної зупинки, і текст від'їжджає на пів слайда; у
                // PowerPoint він стає одразу за маркером.
                var width = TextLayout.Measure(mark.Text, paint);
                var gap = width >= head - first ? "" : "\t";
                style.Runs.Add(new StyledRun(mark.Text + gap, paint, false));
            }
            foreach (var run in paragraph.Runs)
            {
                var points = run.Size * pointsPerCanvas * scale;
                style.Runs.Add(new StyledRun(run.Text, MakePaint(run.FontName, Math.Max(4, points), run.IsBold, run.IsItalic, run.Color), run.IsUnderlined));
            }
            result.Add(style);
        }
        return result;
    }

    private static SKPaint MakePaint(string? fontName, double size, bool bold, bool italic, SlideStyle.RGBA color) => new()
    {
        Typeface = Font(fontName, bold, italic),
        TextSize = (float)size,
        Color = Color(color),
        IsAntialias = true,
        SubpixelText = true,
        LcdRenderText = false,
    };

    /// Знак маркера для малювання. Символьні шрифти (Wingdings, Symbol,
    /// Webdings) у системі бувають не ті чи не ті кодові точки, тож найчастіші
    /// знаки переводимо в Unicode і малюємо шрифтом тексту.
    private static (string Text, string? Font) BulletText(string character, string? font)
    {
        var face = (font ?? "").ToLowerInvariant();
        if (!(face.StartsWith("wingdings", StringComparison.Ordinal) || face == "symbol" || face.StartsWith("webdings", StringComparison.Ordinal)))
            return (character, font);
        var wingdings = new Dictionary<string, string>
        {
            ["ü"] = "✓", ["þ"] = "☑", ["ý"] = "✗", ["l"] = "●", ["n"] = "■", ["u"] = "◆", ["w"] = "◆", ["q"] = "❑",
            ["v"] = "❖", ["Ø"] = "➢", ["§"] = "▪", ["ð"] = "☞", ["J"] = "☺", ["o"] = "○", ["p"] = "□", ["r"] = "❍",
            ["s"] = "▲", ["t"] = "▼", ["à"] = "→", ["è"] = "⇒", ["ä"] = "★", ["«"] = "◉", ["¨"] = "▫", ["·"] = "•",
            ["-"] = "–", ["•"] = "•", ["Ú"] = "✧", ["¤"] = "✦",
        };
        if (face == "symbol")
        {
            var symbol = new Dictionary<string, string> { ["·"] = "•", ["-"] = "–", ["¾"] = "—", ["Ø"] = "➢", ["Þ"] = "✓" };
            return (symbol.TryGetValue(character, out var mapped) ? mapped : "•", null);
        }
        return (wingdings.TryGetValue(character, out var found) ? found : "•", null);
    }

    private static readonly object FontLock = new();
    private static readonly Dictionary<(string, bool, bool), SKTypeface> Fonts = new();

    /// Шрифту презентації може не бути в системі — тоді беремо системний
    /// того самого накреслення. Підставити «що-небудь» мовчки не можна: літери
    /// розповзуться, і текст не влізе в рамку.
    private static SKTypeface Font(string? name, bool bold, bool italic)
    {
        var key = (name ?? "", bold, italic);
        lock (FontLock)
        {
            if (Fonts.TryGetValue(key, out var ready)) return ready;
            var style = new SKFontStyle(bold ? SKFontStyleWeight.Bold : SKFontStyleWeight.Normal, SKFontStyleWidth.Normal,
                                        italic ? SKFontStyleSlant.Italic : SKFontStyleSlant.Upright);
            SKTypeface? face = null;
            if (!string.IsNullOrEmpty(name)) face = SKTypeface.FromFamilyName(name, style);
            if (face == null || string.IsNullOrEmpty(name))
            {
                // Системний шрифт інтерфейсу (на Mac — CTFontCreateUIFontForLanguage).
                var system = OperatingSystem.IsWindows() ? "Segoe UI" : OperatingSystem.IsMacOS() ? ".AppleSystemUIFont" : null;
                face = (system != null ? SKTypeface.FromFamilyName(system, style) : null) ?? SKTypeface.FromFamilyName(null, style) ?? SKTypeface.Default;
            }
            Fonts[key] = face;
            return face;
        }
    }

    /// Верстка тексту в рамку заданої ширини — те, що на Mac робить CTFramesetter.
    private sealed class TextLayout : IDisposable
    {
        private sealed record Piece(string Text, SKPaint Paint, bool Underline, float X, float Width);

        private sealed class Line
        {
            public readonly List<Piece> Pieces = new();
            public float Ascent;
            public float Descent;
            public float Leading;
            public float Height => Ascent + Descent + Leading;
        }

        private readonly List<Line> lines = new();
        private readonly List<SKPaint> owned = new();
        public float Height { get; private set; }

        /// Кінець абзацу без своїх властивостей — Helvetica 12 у CoreText.
        private static readonly SKPaint ParagraphEnd = new()
        {
            Typeface = SKTypeface.FromFamilyName(OperatingSystem.IsMacOS() ? "Helvetica" : "Arial") ?? SKTypeface.Default,
            TextSize = 12,
        };

        public static float Measure(string text, SKPaint paint)
        {
            float width = 0;
            foreach (var (segment, segmentPaint, dispose) in Segments(text, paint))
            {
                width += segmentPaint.MeasureText(segment);
                if (dispose) segmentPaint.Dispose();
            }
            return width;
        }

        /// Шматки тексту зі шрифтом, у якому є їхні знаки (каскад шрифтів).
        private static IEnumerable<(string Text, SKPaint Paint, bool Dispose)> Segments(string text, SKPaint paint)
        {
            var start = 0;
            SKTypeface? current = null;
            var index = 0;
            while (index < text.Length)
            {
                var rune = System.Text.Rune.GetRuneAt(text, index);
                var length = rune.Utf16SequenceLength;
                var face = paint.Typeface ?? SKTypeface.Default;
                if (rune.Value >= 32 && !face.ContainsGlyph(rune.Value))
                {
                    face = SKFontManager.Default.MatchCharacter(face.FamilyName, face.FontStyle, null, rune.Value) ?? face;
                }
                if (current != null && face.FamilyName != current.FamilyName)
                {
                    yield return Clone(text[start..index], paint, current);
                    start = index;
                }
                current = face;
                index += length;
            }
            if (start < text.Length) yield return Clone(text[start..], paint, current ?? paint.Typeface ?? SKTypeface.Default);
        }

        private static (string, SKPaint, bool) Clone(string text, SKPaint paint, SKTypeface face)
        {
            if (face == paint.Typeface || (paint.Typeface != null && face.FamilyName == paint.Typeface.FamilyName)) return (text, paint, false);
            var copy = paint.Clone();
            copy.Typeface = face;
            return (text, copy, true);
        }

        public static TextLayout Make(List<StyledParagraph> paragraphs, float width)
        {
            var layout = new TextLayout();
            for (var index = 0; index < paragraphs.Count; index++)
            {
                var paragraph = paragraphs[index];
                var endsWithBreak = index < paragraphs.Count - 1;
                layout.LayOut(paragraph, width, endsWithBreak);
            }
            layout.Height = layout.lines.Sum(line => line.Height);
            return layout;
        }

        private readonly record struct Glyphs(string Text, SKPaint Paint, bool Underline, bool IsSpace, bool IsTab, bool IsBreak, bool BreakAfter);

        /// Один абзац («\n» усередині — теж кінець абзацу, як у CoreText).
        private void LayOut(StyledParagraph paragraph, float width, bool endsWithBreak)
        {
            if (paragraph.IsEmpty)
            {
                var line = new Line();
                Metrics(line, ParagraphEnd);
                lines.Add(line);
                return;
            }
            // Слова: межа після пробілу, табуляції й дефіса; «\n» — кінець абзацу.
            var items = new List<Glyphs>();
            foreach (var run in paragraph.Runs)
            {
                foreach (var (segment, paint, dispose) in Segments(run.Text, run.Paint))
                {
                    if (dispose) owned.Add(paint);
                    var builder = new System.Text.StringBuilder();
                    void Flush(bool breakAfter)
                    {
                        if (builder.Length == 0) return;
                        items.Add(new Glyphs(builder.ToString(), paint, run.Underline, false, false, false, breakAfter));
                        builder.Clear();
                    }
                    foreach (var character in SwiftText.Characters(segment))
                    {
                        if (character is "\n" or "\r\n" or "\r" or "\u2029")
                        {
                            Flush(true);
                            items.Add(new Glyphs("", paint, run.Underline, false, false, true, true));
                        }
                        else if (character == "\u2028")
                        {
                            Flush(true);
                            items.Add(new Glyphs("", paint, run.Underline, false, false, true, true) with { Text = "\u2028" });
                        }
                        else if (character == "\t")
                        {
                            Flush(true);
                            items.Add(new Glyphs("\t", paint, run.Underline, false, true, false, true));
                        }
                        else if (character == " ")
                        {
                            Flush(false);
                            items.Add(new Glyphs(" ", paint, run.Underline, true, false, false, true));
                        }
                        else
                        {
                            builder.Append(character);
                            if (character is "-" or "–" or "—") Flush(true);
                        }
                    }
                    Flush(false);
                }
            }

            var firstLine = true;
            var position = 0;
            while (position <= items.Count)
            {
                var indent = firstLine ? paragraph.FirstLineHeadIndent : paragraph.HeadIndent;
                var line = new Line();
                var x = indent;
                var lineItems = new List<(Glyphs Item, float X, float Width)>();
                var lastBreak = -1;
                var forced = false;
                var newParagraph = false;
                var start = position;
                while (position < items.Count)
                {
                    var item = items[position];
                    if (item.IsBreak)
                    {
                        Metrics(line, item.Paint);
                        position++;
                        forced = true;
                        newParagraph = item.Text != "\u2028";
                        break;
                    }
                    float advance;
                    if (item.IsTab)
                    {
                        var next = paragraph.TabStops.Where(stop => stop > x + 0.01f).Cast<float?>().FirstOrDefault();
                        var tab = paragraph.DefaultTab > 0 ? paragraph.DefaultTab : 36;
                        advance = (next ?? (float)(Math.Floor(x / tab + 1e-6) + 1) * tab) - x;
                    }
                    else advance = item.Paint.MeasureText(item.Text);
                    var fits = item.IsSpace || x + advance <= width + 0.01f || lineItems.Count == 0 && !item.IsTab && x + advance > width && advance <= width - indent;
                    if (!fits && lineItems.Count > 0)
                    {
                        if (lastBreak >= 0)
                        {
                            // Перенесення на останній межі слова в цьому рядку.
                            var keep = lastBreak - start + 1;
                            position = lastBreak + 1;
                            lineItems.RemoveRange(keep, lineItems.Count - keep);
                        }
                        break;
                    }
                    if (!fits && lineItems.Count == 0 && !item.IsTab && advance > width - indent)
                    {
                        // Слово довше за рядок — ділимо за знаками.
                        var characters = SwiftText.Characters(item.Text);
                        var taken = new System.Text.StringBuilder();
                        var count = 0;
                        foreach (var character in characters)
                        {
                            var trial = taken + character;
                            if (count > 0 && x + item.Paint.MeasureText(trial) > width) break;
                            taken.Append(character);
                            count++;
                        }
                        var head = taken.ToString();
                        var headWidth = item.Paint.MeasureText(head);
                        lineItems.Add((item with { Text = head }, x, headWidth));
                        Metrics(line, item.Paint);
                        var rest = string.Concat(characters.Skip(count));
                        if (rest.Length > 0) items[position] = item with { Text = rest };
                        else position++;
                        break;
                    }
                    lineItems.Add((item, x, advance));
                    Metrics(line, item.Paint);
                    x += advance;
                    if (item.BreakAfter) lastBreak = position;
                    position++;
                }
                // Кінець абзацу без своїх властивостей тримає висоту рядка, як у CoreText.
                if (position >= items.Count && !forced && endsWithBreak) Metrics(line, ParagraphEnd);
                if (line.Ascent == 0 && line.Descent == 0 && lineItems.Count == 0 && !forced) break;

                // Пробіли в кінці рядка «висять» — у ширину не йдуть.
                var visible = lineItems.ToList();
                while (visible.Count > 0 && visible[^1].Item.IsSpace) visible.RemoveAt(visible.Count - 1);
                var used = visible.Count > 0 ? visible[^1].X + visible[^1].Width - indent : 0;
                var room = width - indent;
                var lastOfParagraph = forced || position >= items.Count;
                float shift = paragraph.Alignment switch
                {
                    "center" => (room - used) / 2,
                    "right" => room - used,
                    _ => 0,
                };
                var spaces = visible.Count(entry => entry.Item.IsSpace);
                var extra = paragraph.Alignment == "justify" && !lastOfParagraph && spaces > 0 ? (room - used) / spaces : 0;
                var added = 0f;
                foreach (var (item, itemX, itemWidth) in visible)
                {
                    if (!item.IsTab && item.Text.Length > 0)
                        line.Pieces.Add(new Piece(item.Text, item.Paint, item.Underline, itemX + shift + added, itemWidth));
                    if (item.IsSpace) added += extra;
                }
                lines.Add(line);
                firstLine = newParagraph;
                if (forced && position >= items.Count)
                {
                    // «\n» у самому кінці — ще один порожній рядок абзацу.
                    var tail = new Line();
                    Metrics(tail, items[^1].Paint);
                    if (endsWithBreak) Metrics(tail, ParagraphEnd);
                    lines.Add(tail);
                    break;
                }
                if (position >= items.Count) break;
            }
        }

        private static void Metrics(Line line, SKPaint paint)
        {
            paint.GetFontMetrics(out var metrics);
            line.Ascent = Math.Max(line.Ascent, -metrics.Ascent);
            line.Descent = Math.Max(line.Descent, metrics.Descent);
            line.Leading = Math.Max(line.Leading, metrics.Leading);
        }

        /// Малювання в рамці: рядки, що не влізли за висотою, не малюються (як CTFrame).
        public void Draw(SKCanvas canvas, SKRect box)
        {
            var y = box.Top;
            foreach (var line in lines)
            {
                if (y + line.Height > box.Bottom + 0.5f) break;
                var baseline = y + line.Ascent;
                foreach (var piece in line.Pieces)
                {
                    canvas.DrawText(piece.Text, box.Left + piece.X, baseline, piece.Paint);
                    if (piece.Underline)
                    {
                        piece.Paint.GetFontMetrics(out var metrics);
                        var offset = metrics.UnderlinePosition ?? piece.Paint.TextSize * 0.1f;
                        var thickness = Math.Max(metrics.UnderlineThickness ?? piece.Paint.TextSize * 0.05f, 1);
                        using var underline = new SKPaint { Color = piece.Paint.Color, IsAntialias = true };
                        canvas.DrawRect(SKRect.Create(box.Left + piece.X, baseline + offset, piece.Width, thickness), underline);
                    }
                }
                y += line.Height;
            }
        }

        public void Dispose()
        {
            foreach (var paint in owned) paint.Dispose();
            owned.Clear();
        }
    }
}
