// =============================================================================
//  Slide.cs — вигляд слайда: стиль, шаблони `.sch`, тека шаблонів
// =============================================================================
//  Перенесено з SlideStyle.swift, SlideScheme.swift, SchemeParser.swift і
//  SchemeLibrary.swift. Стиль — шрифти, кольори, контур і тінь трьох шарів
//  (цитата, другий переклад, адреса), поля, фон і зміна слайда; розміри — у
//  частках висоти слайда, щоб картинка не роз'їжджалася між передпоказом,
//  проектором і картинкою залу для пульта. Шаблон `.sch` оригіналу (XML)
//  накладається поверх стилю: кольори, обведення, тінь, рамка Цитати, фон.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Text;
using System.Text.Json.Serialization;
using System.Xml.Linq;

namespace Slovo;

/// Колір у частках 0…1.
public readonly record struct RGBA(double R, double G, double B, double A = 1)
{
    public static readonly RGBA White = new(1, 1, 1);
    public static readonly RGBA Black = new(0, 0, 0);
    public static readonly RGBA Gold = new(1, 0.85, 0.4);

    /// Delphi `TColor` — `0x00BBGGRR`.
    public static RGBA FromTColor(int value) =>
        new((value & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, ((value >> 16) & 0xFF) / 255.0);

    public int ToTColor() => Clamp(R) | (Clamp(G) << 8) | (Clamp(B) << 16);

    static int Clamp(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);

    /// «#RRGGBB» або «#RRGGBBAA».
    public string Hex => A >= 0.999
        ? $"#{Clamp(R):X2}{Clamp(G):X2}{Clamp(B):X2}"
        : $"#{Clamp(R):X2}{Clamp(G):X2}{Clamp(B):X2}{Clamp(A):X2}";

    public static RGBA? FromHex(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var hex = text.Trim().TrimStart('#');
        if (hex.Length is not (6 or 8)) return null;
        try
        {
            var r = int.Parse(hex[..2], NumberStyles.HexNumber) / 255.0;
            var g = int.Parse(hex[2..4], NumberStyles.HexNumber) / 255.0;
            var b = int.Parse(hex[4..6], NumberStyles.HexNumber) / 255.0;
            var a = hex.Length == 8 ? int.Parse(hex[6..8], NumberStyles.HexNumber) / 255.0 : 1;
            return new RGBA(r, g, b, a);
        }
        catch { return null; }
    }

    public RGBA WithAlpha(double alpha) => new(R, G, B, alpha);
    public override string ToString() => Hex;
}

/// Один шар тексту слайда: шрифт, колір, контур, тінь.
public sealed class TextLayer
{
    public string FontName { get; set; } = "Arial";
    /// Кегль — у частках висоти слайда.
    public double FontSize { get; set; } = 0.085;
    public bool IsBold { get; set; } = true;
    public bool IsItalic { get; set; }
    public bool IsUnderline { get; set; }
    public string Color { get; set; } = "#FFFFFF";
    public string OutlineColor { get; set; } = "#000000";
    public bool IsOutlined { get; set; } = true;
    /// Товщина контуру — у частках висоти слайда.
    public double OutlineThickness { get; set; } = 0.004;
    /// Розмиття тіні — у частках висоти слайда; нуль — без тіні.
    public double ShadowRadius { get; set; } = 0.008;
    public double ShadowOffset { get; set; }
    public double ShadowOpacity { get; set; } = 0.55;

    [JsonIgnore] public RGBA Rgba => RGBA.FromHex(Color) ?? RGBA.White;
    [JsonIgnore] public RGBA OutlineRgba => RGBA.FromHex(OutlineColor) ?? RGBA.Black;
    [JsonIgnore] public double OutlineWidth => IsOutlined ? OutlineThickness : 0;

    public TextLayer Clone() => (TextLayer)MemberwiseClone();
}

public enum TextVertical { Top, Center, Bottom }

/// Як виглядає слайд: три шари тексту, поля, фон, зміна слайда.
public sealed class SlideStyle
{
    public string Name { get; set; } = "";
    public TextLayer Main { get; set; } = new();
    public TextLayer Secondary { get; set; } = new() { FontSize = 0.062, IsBold = false, IsItalic = true, Color = "#EBF2FF" };
    public TextLayer Reference { get; set; } = new() { FontSize = 0.045, IsBold = false, IsItalic = true, Color = "#FFD966", ShadowRadius = 0.006 };
    public TextVertical TextVertical { get; set; } = TextVertical.Center;
    /// Поля в частках ширини й висоти.
    public double HorizontalInset { get; set; } = 0.06;
    public double VerticalInset { get; set; } = 0.06;
    public double LineSpacing { get; set; } = 0.12;
    /// Фон слайда: шлях до картинки (порожньо — лише колір).
    public string BackgroundImagePath { get; set; } = "";
    public string BackgroundColor { get; set; } = "#0A1221";
    public double DimBackground { get; set; }
    /// Зміна слайда: none, fade, slideLeft, slideUp, zoom…
    public string Transition { get; set; } = "fade";
    public double TransitionDuration { get; set; } = 0.35;
    /// Мінімальний кегль, до якого стискається текст, що не влазить, —
    /// частка від заданого (в оригіналі `fontminsize` / `fontmaxsize`).
    public double MinimumScale { get; set; } = 0.55;

    [JsonIgnore] public RGBA BackgroundRgba => RGBA.FromHex(BackgroundColor) ?? new RGBA(0.04, 0.07, 0.13);

    public SlideStyle Clone()
    {
        var copy = (SlideStyle)MemberwiseClone();
        copy.Main = Main.Clone();
        copy.Secondary = Secondary.Clone();
        copy.Reference = Reference.Clone();
        return copy;
    }

    /// Умовчання режиму — ті, що в `Slovo.ini` пакета для Mac: Arial жирний,
    /// білий текст, зелений контур 2,25 px на слайді 600 px, тінь 7 px.
    public static SlideStyle Default(string section)
    {
        var style = new SlideStyle { Name = "" };
        var designHeight = 600.0;
        style.Main.FontName = "Arial";
        style.Main.IsBold = true;
        style.Main.Color = RGBA.FromTColor(16249342).Hex;
        style.Main.OutlineColor = RGBA.FromTColor(section == "Text" ? 4472830 : section == "Songs" ? 0 : 90377).Hex;
        style.Main.IsOutlined = true;
        style.Main.OutlineThickness = (section == "Text" ? 1.5 : section == "Songs" ? 2.75 : 2.25) / designHeight;
        style.Main.ShadowRadius = (section == "Text" ? 2.0 : section == "Songs" ? 6.4 : 7.0) / designHeight;
        style.Main.FontSize = 0.085;
        style.Secondary.FontName = "Arial";
        style.Secondary.IsBold = true;
        style.Secondary.IsItalic = false;
        style.Secondary.Color = style.Main.Color;
        style.Secondary.OutlineColor = style.Main.OutlineColor;
        style.Secondary.OutlineThickness = style.Main.OutlineThickness;
        style.Secondary.ShadowRadius = style.Main.ShadowRadius;
        style.Secondary.FontSize = style.Main.FontSize * 0.75;
        style.Reference.FontName = "Arial";
        style.Reference.IsBold = false;
        style.Reference.IsItalic = false;
        style.Reference.IsUnderline = true;
        style.Reference.Color = RGBA.FromTColor(16768994).Hex;
        style.Reference.OutlineColor = style.Main.OutlineColor;
        style.Reference.OutlineThickness = style.Main.OutlineThickness;
        style.Reference.ShadowRadius = style.Main.ShadowRadius;
        style.Reference.FontSize = 0.05;
        style.BackgroundColor = section == "Songs" ? "#0B2A14" : section == "Text" ? "#1A1A2E" : "#0A1221";
        return style;
    }
}

/// Шаблон оформлення слайда `.sch` — розмітка оригіналу з теки `Templates`.
public sealed class SlideScheme
{
    public sealed class Placement
    {
        public double Width = 100, Height = 100, IndentX, IndentY;
        public int Align;
        public double Opacity = 1;
        public bool IsEnabled = true;
        public double ShadowOffset, ShadowBlur, ShadowOpacity;
        public RGBA ShadowColor = RGBA.Black;
        public int? TextAlignment;   // 0 — ліворуч, 1 — праворуч, 2 — по центру
        public int? TextLayout;      // 0 — зверху, 1 — по центру, 2 — знизу

        /// Рамка в частках слайда; відступ — зсув від якоря (`Align`: молодші два
        /// біти — горизонталь 0 зліва / 1 справа / 2 по центру, третій біт — знизу).
        public (double X, double Y, double W, double H) Box
        {
            get
            {
                double w = Width / 100, h = Height / 100, dx = IndentX / 100, dy = IndentY / 100;
                var horizontal = Math.Max(0, Align) & 0b11;
                var bottom = (Math.Max(0, Align) & 0b100) != 0;
                var x = horizontal switch { 0 => dx, 1 => 1 - w - dx, _ => (1 - w) / 2 + dx };
                var y = bottom ? 1 - h - dy : dy;
                return (x, y, w, h);
            }
        }
    }

    public sealed class Scene
    {
        public int Fx;
        public bool IsAnimated;
        public double FromOpacity = 1, FromScale, MoveFromX, MoveFromY, Delay, Duration;
        public bool IsMoving => Math.Abs(MoveFromX) > 0.001 || Math.Abs(MoveFromY) > 0.001;
        public bool IsScaling => FromScale > 0.001;
        public bool MovesHorizontally => Math.Abs(MoveFromX) >= Math.Abs(MoveFromY);
    }

    public sealed class Element
    {
        public string Name = "";
        public int RawType = -1;
        public string? ImageName, ImageMaskName;
        public RGBA? TextColor;
        public List<Placement> Placements = new();
        public List<Scene> Scenes = new();   // перша — варіант «один переклад», друга — «два»

        public Placement Placement(bool dual) => Placements.Count == 0 ? new Placement()
            : dual && Placements.Count > 1 ? Placements[1] : Placements[0];
        public Scene? SceneFor(bool dual) => Scenes.Count == 0 ? null : dual && Scenes.Count > 1 ? Scenes[1] : Scenes[0];
    }

    public const int Quote = 0, Reference = 1, SecondQuote = 6, Decoration = 5, SongTitle = 13;

    public string Name = "";
    public string BackgroundImageName = "";
    public bool OutlineEnabled;
    public double OutlineWidth;
    public RGBA OutlineColor = RGBA.Black;
    public bool ShadowEnabled;
    public double ShadowOffset, ShadowBlur, ShadowOpacity;
    public RGBA ShadowColor = RGBA.Black;
    public List<Element> Elements = new();

    public Element? ElementOf(int kind) => Elements.FirstOrDefault(e => e.RawType == kind);

    /// Накладає шаблон на готовий стиль: шрифти лишаються від `base`, міняються
    /// кольори, обведення, тінь, поля, виключка і характер зміни слайда.
    public SlideStyle ApplyTo(SlideStyle baseStyle, double designHeight, bool dual, string? backgroundPath)
    {
        var style = baseStyle.Clone();
        style.Name = Name;
        var height = Math.Max(designHeight, 1);
        var outline = OutlineEnabled ? OutlineWidth / height : 0;
        var shadow = ShadowEnabled ? ShadowBlur / height : 0;
        var quote = ElementOf(Quote);
        var mainColor = quote?.TextColor ?? baseStyle.Main.Rgba;

        void Paint(TextLayer layer, RGBA color)
        {
            layer.Color = color.Hex;
            layer.OutlineColor = OutlineColor.Hex;
            layer.IsOutlined = outline > 0;
            if (outline > 0) layer.OutlineThickness = outline;
            layer.ShadowRadius = shadow;
            layer.ShadowOffset = ShadowEnabled ? ShadowOffset / height : 0;
            layer.ShadowOpacity = ShadowEnabled ? Math.Max(0.2, ShadowOpacity) : 0;
        }
        Paint(style.Main, mainColor);
        Paint(style.Secondary, ElementOf(SecondQuote)?.TextColor ?? mainColor);
        Paint(style.Reference, ElementOf(Reference)?.TextColor ?? baseStyle.Reference.Rgba);

        if (backgroundPath != null) style.BackgroundImagePath = backgroundPath;

        if (quote != null)
        {
            var placement = quote.Placement(dual);
            var (x, y, w, h) = placement.Box;
            style.HorizontalInset = Math.Clamp(Math.Min(x, 1 - (x + w)), 0, 0.45);
            style.VerticalInset = Math.Clamp(Math.Min(y, 1 - (y + h)), 0, 0.45);
            style.TextVertical = VerticalAlignmentOf(placement);
            var scene = quote.SceneFor(dual);
            if (scene != null)
            {
                style.Transition = TransitionFor(scene);
                if (style.Transition != "none") style.TransitionDuration = Math.Max(0.25, scene.Duration);
            }
        }
        return style;
    }

    static TextVertical VerticalAlignmentOf(Placement placement)
    {
        var (_, y, _, h) = placement.Box;
        if (h >= 0.8 && placement.TextLayout != null)
            return placement.TextLayout switch { 0 => TextVertical.Top, 2 => TextVertical.Bottom, _ => TextVertical.Center };
        var mid = y + h / 2;
        if (Math.Abs(mid - 0.5) <= 0.08) return TextVertical.Center;
        return mid < 0.5 ? TextVertical.Top : TextVertical.Bottom;
    }

    static string TransitionFor(Scene scene)
    {
        if (!scene.IsAnimated || scene.Fx == 0) return "none";
        if (scene.IsScaling) return "zoom";
        if (scene.IsMoving) return scene.MovesHorizontally ? "slideLeft" : "slideUp";
        return "fade";
    }

    // MARK: Розбір .sch

    public static SlideScheme Parse(byte[] data, string fallbackName)
    {
        var text = ModuleReaders.Decode(data, null);
        XDocument document;
        try { document = XDocument.Parse(text); }
        catch (Exception error) { throw new RefusedException(Lang.F("Шаблон розібрати не вдалося: {0}", "The template could not be parsed: {0}", error.Message)); }
        var schemeNode = document.Descendants().FirstOrDefault(e => e.Name.LocalName.Equals("Scheme", StringComparison.OrdinalIgnoreCase))
            ?? throw new RefusedException(Lang.T("У файлі нет вузла Scheme", "The file has no Scheme node"));

        string? Attr(XElement e, string name) => e.Attributes().FirstOrDefault(a => a.Name.LocalName.Equals(name, StringComparison.OrdinalIgnoreCase))?.Value;
        double? Num(XElement e, string name) => Number(Attr(e, name));
        bool? Flag(XElement e, string name) => Attr(e, name) is string raw ? raw.Trim().ToLowerInvariant() switch { "true" or "1" or "yes" => true, "false" or "0" or "no" => false, _ => null } : null;
        RGBA? Color(XElement e, string name) => TColor(Attr(e, name));

        var scheme = new SlideScheme
        {
            Name = Attr(schemeNode, "Name") ?? fallbackName,
            BackgroundImageName = Attr(schemeNode, "BackImg") ?? "",
            OutlineEnabled = Flag(schemeNode, "QuoteOutLineEnable") ?? false,
            OutlineWidth = Num(schemeNode, "QuoteOutLineWidth") ?? 0,
            OutlineColor = Color(schemeNode, "QuoteOutLineColor") ?? RGBA.Black,
            ShadowEnabled = Flag(schemeNode, "QuoteShadowEnabled") ?? false,
            ShadowOffset = Num(schemeNode, "QuoteShadowOffset") ?? 0,
            ShadowBlur = Num(schemeNode, "QuoteShadowBlur") ?? 0,
            ShadowOpacity = (Num(schemeNode, "QuoteShadowOpacity") ?? 0) / 255,
            ShadowColor = Color(schemeNode, "QuoteShadowColor") ?? RGBA.Black,
        };

        foreach (var node in schemeNode.Descendants().Where(e => e.Name.LocalName.Equals("Object", StringComparison.OrdinalIgnoreCase)))
        {
            Placement PlacementOf(string suffix) => new()
            {
                Width = Num(node, "Width" + suffix) ?? 100, Height = Num(node, "Height" + suffix) ?? 100,
                IndentX = Num(node, "IndentionX" + suffix) ?? 0, IndentY = Num(node, "IndentionY" + suffix) ?? 0,
                Align = (int)(Num(node, "Align" + suffix) ?? 0), Opacity = (Num(node, "Opacity" + suffix) ?? 255) / 255,
                IsEnabled = Flag(node, "Enabled" + suffix) ?? true,
                ShadowOffset = Num(node, "ShadowOffsetPerc" + suffix) ?? 0, ShadowBlur = Num(node, "ShadowBlurPerc" + suffix) ?? 0,
                ShadowOpacity = (Num(node, "ShadowOpacity" + suffix) ?? 0) / 255, ShadowColor = Color(node, "ShadowColor" + suffix) ?? RGBA.Black,
                TextAlignment = Num(node, "Alignment" + suffix) is double a ? (int)a : null,
                TextLayout = Num(node, "Layout" + suffix) is double l ? (int)l : null,
            };
            var element = new Element
            {
                Name = Attr(node, "Name") ?? "",
                RawType = int.TryParse(Attr(node, "Type"), out var type) ? type : -1,
                ImageName = string.IsNullOrEmpty(Attr(node, "Image")) ? null : Attr(node, "Image"),
                ImageMaskName = string.IsNullOrEmpty(Attr(node, "ImageMask")) ? null : Attr(node, "ImageMask"),
                TextColor = Color(node, "TextColor"),
            };
            element.Placements.Add(PlacementOf(""));
            element.Placements.Add(Attr(node, "Width_2") == null ? element.Placements[0] : PlacementOf("_2"));
            // Перший пресет анімації: по кадру на варіант слайда.
            var preset = node.Elements().FirstOrDefault(e => e.Name.LocalName.Equals("FXPreset", StringComparison.OrdinalIgnoreCase));
            if (preset != null)
                foreach (var sceneNode in preset.Elements().Where(e => e.Name.LocalName.Equals("Scene", StringComparison.OrdinalIgnoreCase)))
                    element.Scenes.Add(new Scene
                    {
                        Fx = int.TryParse(Attr(sceneNode, "FX"), out var fx) ? fx : 0,
                        IsAnimated = Flag(sceneNode, "Animation") ?? false,
                        FromOpacity = (Num(sceneNode, "FromOpacity") ?? 255) / 255,
                        FromScale = (Num(sceneNode, "FromScale") ?? 0) / 100,
                        MoveFromX = Num(sceneNode, "MoveFromX") ?? 0, MoveFromY = Num(sceneNode, "MoveFromY") ?? 0,
                        Delay = (Num(sceneNode, "Delay") ?? 0) / 1000, Duration = (Num(sceneNode, "TimeLength") ?? 0) / 1000,
                    });
            scheme.Elements.Add(element);
        }
        return scheme;
    }

    /// Delphi пише дробові з комою й іноді в науковому записі.
    static double? Number(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return null;
        return double.TryParse(raw.Replace(',', '.'), NumberStyles.Float, CultureInfo.InvariantCulture, out var value) ? value : null;
    }

    static RGBA? TColor(string? raw)
    {
        if (raw == null || !long.TryParse(raw.Trim(), out var value) || value < 0) return null;
        return RGBA.FromTColor((int)(value & 0xFFFFFF));
    }
}

/// Шаблон із теки `Templates`: файл `<Ім'я>.sch` і тека `<Ім'я>/` з картинками.
public sealed class SlideTemplate
{
    public string Name = "";
    public string FilePath = "";
    public string Folder = "";
    public SlideScheme Scheme = new();
    public string? BackgroundPath;
    public string? ThumbnailPath;

    public SlideStyle Style(SlideStyle baseStyle, double designHeight = 600, bool dual = false) =>
        Scheme.ApplyTo(baseStyle, designHeight, dual, BackgroundPath);
}

/// Тека шаблонів: один битий файл не забирає з собою всю теку.
public sealed class TemplateLibrary
{
    public List<SlideTemplate> Templates { get; } = new();
    public Dictionary<string, string> Failures { get; } = new();

    public static TemplateLibrary Scan(string root)
    {
        var library = new TemplateLibrary();
        if (!Directory.Exists(root)) return library;
        foreach (var file in Directory.GetFiles(root, "*.sch").OrderBy(f => f, StringComparer.CurrentCultureIgnoreCase))
        {
            var name = Path.GetFileNameWithoutExtension(file);
            try
            {
                var scheme = SlideScheme.Parse(File.ReadAllBytes(file), name);
                var folder = Path.Combine(root, name);
                var template = new SlideTemplate { Name = name, FilePath = file, Folder = folder, Scheme = scheme };
                template.BackgroundPath = Resolve(folder, scheme.BackgroundImageName);
                template.ThumbnailPath = Resolve(Path.Combine(folder, "thumbs"), "scene1.jpg") ?? template.BackgroundPath;
                library.Templates.Add(template);
            }
            catch (Exception error)
            {
                library.Failures[Path.GetFileName(file)] = error.Message;
            }
        }
        return library;
    }

    /// Ім'я приходить з налаштувань — порівнюємо без урахування регістру.
    public SlideTemplate? Named(string name) =>
        Templates.FirstOrDefault(t => t.Name.Equals(name, StringComparison.OrdinalIgnoreCase))
        ?? Templates.FirstOrDefault(t => t.Scheme.Name.Equals(name, StringComparison.OrdinalIgnoreCase));

    static string? Resolve(string folder, string fileName)
    {
        if (fileName.Length == 0 || !Directory.Exists(folder)) return null;
        var direct = Path.Combine(folder, fileName);
        if (File.Exists(direct)) return direct;
        return Directory.GetFiles(folder).FirstOrDefault(f => Path.GetFileName(f).Equals(fileName, StringComparison.OrdinalIgnoreCase));
    }
}
