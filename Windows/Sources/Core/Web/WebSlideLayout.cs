// =============================================================================
//  WebSlideLayout.cs — розкладка слайда для браузера (з SlovoCore/Web/WebSlideLayout.swift)
// =============================================================================
//  Те саме, що малює проектор, але числами, які розуміє сторінка: шаблон,
//  зібраний у «Конструкторі слайда», перекладено в частки полотна — сторінка
//  `slovo-slide.html` ставить об'єкти за відсотками і тягнеться під будь-який
//  екран. Перерахунок — раз на слайд, а не на кадр. Картинки мережею йдуть не
//  шляхами з диска, а короткими іменами (`/slide-image/<ім'я>`).
// =============================================================================

using System.Globalization;
using System.Text.Json.Nodes;

namespace Slovo.Core;

public sealed record WebSlideLayout
{
    public sealed record BackgroundInfo(SlideStyle.RGBA Color, string? ImageID, string FillMode);

    public sealed record ObjectInfo
    {
        public string Kind = "";
        /// Частки полотна, 0…1. Лівий верхній кут і розмір.
        public double X, Y, Width, Height;
        public string Text = "";
        public string? ImageID;
        public string FontFamily = "";
        /// Частка висоти полотна — сторінка переведе в пікселі за своєю висотою.
        public double FontSize;
        public bool IsBold, IsItalic, IsUnderlined;
        public SlideStyle.RGBA Color;
        public string Alignment = "center";
        public string VerticalAlignment = "center";
        public double LineSpacing;
        public double MinimumScale;
        public double Opacity;
        public SlideStyle.RGBA BackgroundColor;
        /// Частка висоти полотна.
        public double CornerRadius;
        public double BlurRadius;
        public SlideStyle.RGBA OutlineColor;
        public double OutlineWidth;
        public SlideStyle.RGBA ShadowColor;
        public double ShadowOffset;
        public double ShadowBlur;
        /// Куди падає тінь, у градусах (45° — управо-вниз, як було завжди).
        public double ShadowAngle;
    }

    public double CanvasWidth { get; init; } = 1920;
    public double CanvasHeight { get; init; } = 1080;
    public BackgroundInfo Background { get; init; } = new(SlideStyle.RGBA.Black, null, "cover");
    public IReadOnlyList<ObjectInfo> Objects { get; init; } = Array.Empty<ObjectInfo>();
    /// Шрифти шаблону: ім'я родини → коротке ім'я файлу на сервері. У браузера їх
    /// немає: віддаємо файл — тоді літери ті самі.
    public IReadOnlyDictionary<string, string> Fonts { get; init; } = new Dictionary<string, string>();

    public bool IsEmpty => Objects.Count == 0 && Background.ImageID == null;

    // ── У JSON ────────────────────────────────────────────────────────────────

    internal static string Rgba(SlideStyle.RGBA color)
    {
        int Channel(double value) => (int)Math.Round(value * 255, MidpointRounding.AwayFromZero);
        return $"rgba({Channel(color.Red)},{Channel(color.Green)},{Channel(color.Blue)},{color.Alpha.ToString("F3", CultureInfo.InvariantCulture)})";
    }

    public JsonObject Json()
    {
        var background = new JsonObject
        {
            ["Color"] = Rgba(Background.Color),
            ["FillMode"] = Background.FillMode,
        };
        if (Background.ImageID is { } id) background["Image"] = id;

        var fonts = new JsonObject();
        foreach (var (family, file) in Fonts) fonts[family] = file;

        var objects = new JsonArray();
        foreach (var item in Objects)
        {
            var json = new JsonObject
            {
                ["Kind"] = item.Kind,
                ["X"] = item.X, ["Y"] = item.Y,
                ["Width"] = item.Width, ["Height"] = item.Height,
                ["Text"] = item.Text,
                ["FontFamily"] = item.FontFamily,
                ["FontSize"] = item.FontSize,
                ["Bold"] = item.IsBold,
                ["Italic"] = item.IsItalic,
                ["Underline"] = item.IsUnderlined,
                ["Color"] = Rgba(item.Color),
                ["Align"] = item.Alignment,
                ["VerticalAlign"] = item.VerticalAlignment,
                ["LineSpacing"] = item.LineSpacing,
                ["MinimumScale"] = item.MinimumScale,
                ["Opacity"] = item.Opacity,
                ["Background"] = Rgba(item.BackgroundColor),
                ["CornerRadius"] = item.CornerRadius,
                ["Blur"] = item.BlurRadius,
                ["OutlineColor"] = Rgba(item.OutlineColor),
                ["OutlineWidth"] = item.OutlineWidth,
                ["ShadowColor"] = Rgba(item.ShadowColor),
                ["ShadowOffset"] = item.ShadowOffset,
                ["ShadowBlur"] = item.ShadowBlur,
                ["ShadowAngle"] = item.ShadowAngle,
            };
            if (item.ImageID is { } image) json["Image"] = image;
            objects.Add(json);
        }

        return new JsonObject
        {
            ["Width"] = CanvasWidth,
            ["Height"] = CanvasHeight,
            ["Background"] = background,
            ["Fonts"] = fonts,
            ["Objects"] = objects,
        };
    }

    // ── Збирання розкладки з шаблону ──────────────────────────────────────────

    /// Перекласти шаблон у розкладку для сторінки. `text` віддає готовий рядок
    /// об'єкта — той самий, що йде на проектор; `imageID` реєструє картинку й
    /// повертає її коротке ім'я (null — такої немає, об'єкт не малюється).
    public static WebSlideLayout Make(SlidePreset preset, bool withSecondTranslation,
                                      Func<SlideObject, string> text, Func<string, string?> imageID,
                                      Func<string, string?>? fontID = null, SizeD? canvasSize = null)
    {
        var canvas = canvasSize ?? new SizeD(1920, 1080);
        var objects = new List<ObjectInfo>();
        foreach (var item in preset.Objects)
        {
            if (!item.IsVisible) continue;
            var variant = item.Variant(withSecondTranslation);
            if (!variant.IsVisible) continue;
            var rect = variant.Frame.Rect(canvas);
            // Об'єкт за краєм полотна в браузері розтягнув би сторінку; на
            // проекторі він обрізаний, і тут має бути обрізаний теж.
            if (rect.Width <= 0 || rect.Height <= 0) continue;

            string? picture = null;
            if (item.Kind == SlideObjectKind.Image)
            {
                if (item.ImagePath is not { } path || imageID(path) is not { } id) continue;
                picture = id;
            }
            var body = item.Kind == SlideObjectKind.Image ? "" : text(item);
            // Порожній текст малювати нічим: порожня рамка в залі зайва.
            if (item.Kind != SlideObjectKind.Image && body.Length == 0 && item.BackgroundColor.Alpha <= 0) continue;

            var shadow = variant.Shadow;
            objects.Add(new ObjectInfo
            {
                Kind = item.Kind.RawValue(),
                X = rect.X / canvas.Width,
                Y = rect.Y / canvas.Height,
                Width = rect.Width / canvas.Width,
                Height = rect.Height / canvas.Height,
                Text = body,
                ImageID = picture,
                FontFamily = item.Text.FontName,
                FontSize = item.Text.FontSize,
                IsBold = item.Text.IsBold,
                IsItalic = item.Text.IsItalic,
                IsUnderlined = item.IsUnderlined,
                Color = item.Text.Color,
                Alignment = CssAlign(variant.Alignment),
                VerticalAlignment = CssVertical(variant.VerticalAlignment),
                LineSpacing = item.LineSpacing,
                MinimumScale = item.MinimumScale,
                Opacity = variant.Opacity,
                BackgroundColor = item.BackgroundColor,
                CornerRadius = item.CornerRadius,
                BlurRadius = item.BlurRadius,
                OutlineColor = item.Text.OutlineColor,
                OutlineWidth = item.Text.OutlineWidth,
                ShadowColor = shadow.IsEnabled ? shadow.Color : new SlideStyle.RGBA(0, 0, 0, 0),
                ShadowOffset = shadow.IsEnabled ? shadow.OffsetPercent / 100 : 0,
                ShadowBlur = shadow.IsEnabled ? shadow.BlurPercent / 100 : 0,
                ShadowAngle = shadow.AngleDegrees,
            });
        }

        var fonts = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var item in objects)
        {
            if (item.FontFamily.Length == 0 || fonts.ContainsKey(item.FontFamily)) continue;
            if (fontID?.Invoke(item.FontFamily) is { } id) fonts[item.FontFamily] = id;
        }

        return new WebSlideLayout
        {
            CanvasWidth = canvas.Width,
            CanvasHeight = canvas.Height,
            Background = new BackgroundInfo(preset.Back.Color,
                                            preset.Back.ImagePath is { } image ? imageID(image) : null,
                                            CssFill(preset.Back.Fill)),
            Objects = objects,
            Fonts = fonts,
        };
    }

    static string CssAlign(ParagraphAlignment value) => value switch
    {
        ParagraphAlignment.Leading => "left",
        ParagraphAlignment.Trailing => "right",
        _ => "center",
    };

    static string CssVertical(SlideStyle.VerticalAlignment value) => value switch
    {
        SlideStyle.VerticalAlignment.Top => "flex-start",
        SlideStyle.VerticalAlignment.Bottom => "flex-end",
        _ => "center",
    };

    static string CssFill(SlidePreset.FillMode value) => value switch
    {
        SlidePreset.FillMode.Fill => "cover",
        SlidePreset.FillMode.Fit => "contain",
        SlidePreset.FillMode.Stretch => "100% 100%",
        SlidePreset.FillMode.Center => "auto",
        _ => "repeat",
    };
}

/// Картинки, які сторінка має право попросити в сервера. Список закритий і живе
/// рівно один слайд: шляхів з диска браузеру не показуємо зовсім — за таким
/// шляхом він попросить що завгодно, а сервер стоїть у мережі залу.
public sealed class WebSlideImages
{
    readonly object _lock = new();
    readonly Dictionary<string, string> _byID = new(StringComparer.Ordinal);
    readonly Dictionary<string, string> _byPath = new(StringComparer.Ordinal);

    /// Записати картинку й отримати її коротке ім'я (розширення лишаємо — браузер
    /// сам зрозуміє тип, усе інше — лічильник).
    public string Register(string path, string file)
    {
        lock (_lock)
        {
            if (_byPath.TryGetValue(path, out var known)) return known;
            var extension = SwiftPath.Extension(file).ToLowerInvariant();
            var id = "i" + (_byID.Count + 1).ToString(CultureInfo.InvariantCulture) + (extension.Length == 0 ? "" : "." + extension);
            _byID[id] = file;
            _byPath[path] = id;
            return id;
        }
    }

    public string? File(string id)
    {
        lock (_lock) return _byID.TryGetValue(id, out var file) ? file : null;
    }

    public void RemoveAll()
    {
        lock (_lock) { _byID.Clear(); _byPath.Clear(); }
    }

    public int Count
    {
        get { lock (_lock) return _byID.Count; }
    }
}
