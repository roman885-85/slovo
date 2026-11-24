// =============================================================================
//  SlidePointer.cs — указка (як Projection/SlidePointer.swift)
// =============================================================================
//  Пляма поверх кадру: її ведуть мишею по живому екрану в нижньому ряду або
//  пальцем по слайду на телефоні. Координати — частки кадру (0…1, y згори).
//  Вигляд (колір, розмір — частка висоти кадру, яскравість, куди виводити)
//  живе в «Параметрах»; телефон може на час свого ведення мати свій вигляд.
// =============================================================================

using SkiaSharp;
using Slovo.Core;

namespace Slovo.App;

public sealed class SlidePointer
{
    public static readonly SlidePointer Shared = new();

    public record struct Look(SlideStyle.RGBA Colour, double Size, double Opacity, bool ToProjector, bool ToNDI)
    {
        public static Look Default => new(new SlideStyle.RGBA(1, 0.85, 0.1), 0.14, 0.45, true, true);

        public static Look From(ProgramOptions options)
        {
            var look = Default;
            if (options.PointerColour is { } hex && ParseColour(hex) is { } parsed) look.Colour = parsed;
            if (options.PointerSize is { } size) look.Size = Math.Min(0.6, Math.Max(0.03, size));
            if (options.PointerOpacity is { } opacity) look.Opacity = Math.Min(1, Math.Max(0.05, opacity));
            look.ToProjector = options.PointerProjector ?? true;
            look.ToNDI = options.PointerNDI ?? true;
            return look;
        }

        public static SlideStyle.RGBA? ParseColour(string text)
        {
            var hex = text.Trim().TrimStart('#');
            if (hex.Length != 6 || !uint.TryParse(hex, System.Globalization.NumberStyles.HexNumber, null, out var value)) return null;
            return new SlideStyle.RGBA(((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0);
        }

        public static string Hex(SlideStyle.RGBA c) =>
            $"#{(int)Math.Round(c.Red * 255):X2}{(int)Math.Round(c.Green * 255):X2}{(int)Math.Round(c.Blue * 255):X2}";
    }

    public readonly record struct Mark(double X, double Y);

    /// Вигляд, що телефон передає разом із точкою (null — як у «Параметрах»).
    public readonly record struct PhoneLook(SlideStyle.RGBA? Colour, double? Size, double? Opacity);

    public const string PhoneSource = "телефон", MouseSource = "мышь";

    public Look BaseLook { get; private set; } = Look.Default;
    public PhoneLook? Phone { get; private set; }
    public Mark? Point { get; private set; }
    public string Source { get; private set; } = "";
    public event Action? Changed;

    SlidePointer() { }

    /// Вигляд зараз: телефон, що веде, може мати свій колір і розмір.
    public Look Current
    {
        get
        {
            if (Source != PhoneSource || Phone is not { } phone) return BaseLook;
            var merged = BaseLook;
            if (phone.Colour is { } colour) merged.Colour = colour;
            if (phone.Size is { } size) merged.Size = Math.Min(0.6, Math.Max(0.03, size));
            if (phone.Opacity is { } opacity) merged.Opacity = Math.Min(1, Math.Max(0.05, opacity));
            return merged;
        }
    }

    public void Apply(Look fresh)
    {
        if (fresh == BaseLook) return;
        BaseLook = fresh;
        Changed?.Invoke();
    }

    public void Move(double x, double y, string who, PhoneLook? phone = null)
    {
        var clamped = new Mark(Math.Min(1, Math.Max(0, x)), Math.Min(1, Math.Max(0, y)));
        var over = who == PhoneSource ? phone : null;
        if (clamped == Point && who == Source && Nullable.Equals(over, Phone)) return;
        Point = clamped;
        Source = who;
        Phone = over;
        Changed?.Invoke();
    }

    /// Сховати пляму; `who` — лише якщо веде саме він (миша не гасить телефон).
    public void Hide(string? who = null)
    {
        if (Point == null) return;
        if (who != null && Source.Length > 0 && who != Source) return;
        Point = null;
        Phone = null;
        Changed?.Invoke();
    }

    /// Намалювати пляму в кадрі `width`×`height` (y згори).
    public static void Draw(SKCanvas c, Mark mark, Look look, float width, float height, float left = 0, float top = 0)
    {
        var radius = (float)Math.Max(2, look.Size * height / 2);
        var cx = left + (float)mark.X * width;
        var cy = top + (float)mark.Y * height;
        byte A(double a) => (byte)Math.Round(Math.Clamp(a, 0, 1) * 255);
        byte V(double v) => (byte)Math.Round(Math.Clamp(v, 0, 1) * 255);
        using var fill = new SKPaint { IsAntialias = true, Color = new SKColor(V(look.Colour.Red), V(look.Colour.Green), V(look.Colour.Blue), A(look.Opacity)) };
        c.DrawCircle(cx, cy, radius, fill);
        // Тонкий обідок: заливку з малою яскравістю на світлому слайді інакше не видно.
        using var rim = new SKPaint
        {
            IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = Math.Max(1.5f, radius * 0.08f),
            Color = new SKColor(V(look.Colour.Red), V(look.Colour.Green), V(look.Colour.Blue), A(Math.Min(1, look.Opacity + 0.4))),
        };
        c.DrawCircle(cx, cy, Math.Max(0.5f, radius - 1), rim);
    }
}
