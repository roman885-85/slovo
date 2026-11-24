// =============================================================================
//  CoreCheck.Presentation.cs — перевірка ядра: презентації (`--section presentation`)
// =============================================================================
//  Розбір файла $SLOVO_PPTX друкується повністю (те саме друкує slovo-ref на
//  Mac), а кадри слайдів лягають PNG-ами в $SLOVO_CHECK_OUT/pptx-cs — їх
//  порівнюють з кадрами Mac на око.
// =============================================================================

using System.Text;
using SkiaSharp;

namespace Slovo.Core;

public static partial class CoreCheck
{
    private static string ColorText(SlideStyle.RGBA? color) =>
        color is { } c ? $"{D(c.Red)},{D(c.Green)},{D(c.Blue)},{D(c.Alpha)}" : "-";

    private static string RectText(RectD rect) => $"{D(rect.X)} {D(rect.Y)} {D(rect.Width)} {D(rect.Height)}";

    private static string FillText(PPTXDocument.Fill fill) => fill switch
    {
        PPTXDocument.Fill.Solid solid => "solid " + ColorText(solid.Color),
        PPTXDocument.Fill.Texture texture => $"texture {texture.Part} tile {(texture.TileScale is { } tile ? D(tile) : "-")} duotone {(texture.Duotone is { } tone ? ColorText(tone.Dark) + "/" + ColorText(tone.Light) : "-")}",
        PPTXDocument.Fill.Picture picture => "picture " + picture.Part,
        PPTXDocument.Fill.GradientCase gradient => "gradient " + (gradient.Gradient.Kind switch
        {
            PPTXDocument.GradientKind.Linear linear => $"linear {D(linear.Angle)}",
            PPTXDocument.GradientKind.Rectangular rectangular => "rect " + RectText(rectangular.Focus),
            PPTXDocument.GradientKind.Radial radial => "radial " + RectText(radial.Focus),
            _ => "?",
        }) + " stops " + Join(gradient.Gradient.Stops.Select(stop => $"{D(stop.Position)}:{ColorText(stop.Color)}"), ";"),
        _ => "none",
    };

    private static string ShadowText(PPTXDocument.Shadow? shadow) =>
        shadow is { } s ? $"{D(s.Offset.Width)},{D(s.Offset.Height)} blur {D(s.Blur)} {ColorText(s.Color)}" : "-";

    private static string OutlineName(PPTXDocument.Outline outline) => outline switch
    {
        PPTXDocument.Outline.RoundedRectangle => "roundedRectangle",
        PPTXDocument.Outline.Ellipse => "ellipse",
        PPTXDocument.Outline.Line => "line",
        _ => "rectangle",
    };

    private static void Presentation()
    {
        P("# presentation");
        if (Environment.GetEnvironmentVariable("SLOVO_PPTX") is not { Length: > 0 } file)
        {
            P("presentation skipped: no SLOVO_PPTX");
            return;
        }
        var reader = ZipParts.Open(file);
        P($"zip names {Join(reader.Names, " ")}");
        P($"zip contains {B(reader.Contains("ppt/presentation.xml"))} {B(reader.Contains("nope"))} part {(reader.Part("nope") == null ? "nil" : "?")} png {reader.Part("ppt/media/texture.png")?.Length ?? -1} text {Fnv(reader.Text("ppt/slides/slide1.xml") ?? "")}");

        var document = new PPTXDocument(file);
        P($"file {SwiftPath.LastComponent(file)} canvas {D(document.CanvasSize.Width)} {D(document.CanvasSize.Height)} count {document.Count} parts {Join(document.SlideParts, " ")}");
        for (var index = 0; index < document.Slides.Count; index++)
        {
            var slide = document.Slides[index];
            P($"slide {index}: bg {FillText(slide.Background)} shapes {slide.Shapes.Count}");
            for (var number = 0; number < slide.Shapes.Count; number++)
            {
                var shape = slide.Shapes[number];
                P($"  shape {number}: frame {RectText(shape.Frame)} fill {FillText(shape.Fill)} stroke {ColorText(shape.StrokeColor)} {D(shape.StrokeWidth)} outline {OutlineName(shape.Outline)} rot {D(shape.Rotation)} flip {B(shape.FlipH)} {B(shape.FlipV)} crop {D(shape.Crop.Left)} {D(shape.Crop.Top)} {D(shape.Crop.Right)} {D(shape.Crop.Bottom)} empty {B(shape.Crop.IsEmpty)} anchor {shape.Anchor} scale {D(shape.FontScale)} autofit {shape.Autofit} shadow {ShadowText(shape.Shadow)} textShadow {ShadowText(shape.TextShadow)}");
                for (var p = 0; p < shape.Paragraphs.Count; p++)
                {
                    var paragraph = shape.Paragraphs[p];
                    P($"    para {p}: align {paragraph.Alignment} indent {D(paragraph.Indent)} bullet «{paragraph.Bullet ?? "-"}» marL {D(paragraph.MarginLeft)} first {D(paragraph.FirstIndent)} buFont {paragraph.BulletFont ?? "-"} buColor {ColorText(paragraph.BulletColor)} buSize {(paragraph.BulletSize is { } size ? D(size) : "-")}");
                    foreach (var run in paragraph.Runs)
                        P($"      run «{Esc(run.Text)}» size {D(run.Size)} {B(run.IsBold)} {B(run.IsItalic)} {B(run.IsUnderlined)} color {ColorText(run.Color)} font {run.FontName ?? "-"}");
                }
            }
        }

        var output = Environment.GetEnvironmentVariable("SLOVO_CHECK_OUT") is { Length: > 0 } custom ? Path.Combine(custom, "pptx-cs") : null;
        if (output != null) Directory.CreateDirectory(output);
        var height = 1080.0;
        var width = height * (document.CanvasSize.Width / Math.Max(document.CanvasSize.Height, 1));
        for (var index = 0; index < document.Slides.Count; index++)
        {
            foreach (var target in new[] { new SizeD(width, height), new SizeD(192, 108) })
            {
                using var image = PPTXRenderer.Image(document.Slides[index], document, target);
                P($"render {index} {D(target.Width)}x{D(target.Height)}: {(image == null ? "nil" : $"{image.Width}x{image.Height}")}");
                if (image != null && output != null && target.Height == height)
                {
                    using var data = image.Encode(SKEncodedImageFormat.Png, 100);
                    File.WriteAllBytes(Path.Combine(output, $"slide-{index + 1:D2}.png"), data.ToArray());
                }
            }
        }
        P($"render zero {(PPTXRenderer.Image(document.Slides[0], document, new SizeD(0, 10)) == null ? "nil" : "?")}");

        var folder = Path.Combine(Path.GetTempPath(), "slovo-check-pptx-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        try
        {
            File.WriteAllText(Path.Combine(folder, "text.pptx"), "not a zip");
            using (var zip = System.IO.Compression.ZipFile.Open(Path.Combine(folder, "noppt.pptx"), System.IO.Compression.ZipArchiveMode.Create))
                using (var writer = new StreamWriter(zip.CreateEntry("word/document.xml").Open())) writer.Write("<x/>");
            using (var zip = System.IO.Compression.ZipFile.Open(Path.Combine(folder, "noslides.pptx"), System.IO.Compression.ZipArchiveMode.Create))
                using (var writer = new StreamWriter(zip.CreateEntry("ppt/presentation.xml").Open())) writer.Write("<p:presentation xmlns:p=\"http://schemas.openxmlformats.org/presentationml/2006/main\"/>");
            using (var zip = System.IO.Compression.ZipFile.Open(Path.Combine(folder, "badxml.pptx"), System.IO.Compression.ZipArchiveMode.Create))
                using (var writer = new StreamWriter(zip.CreateEntry("ppt/presentation.xml").Open())) writer.Write("<p:presentation");
            foreach (var name in new[] { "text.pptx", "noppt.pptx", "noslides.pptx", "badxml.pptx" })
            {
                try
                {
                    var opened = new PPTXDocument(Path.Combine(folder, name));
                    P($"open {name}: {opened.Count}");
                }
                catch (PPTXDocument.Failure failure)
                {
                    P($"open {name}: {failure.Message}");
                }
            }
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch { }
        }
    }
}
