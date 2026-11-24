// =============================================================================
//  Palette.cs — кольори «Слова»: світла й темна тема
// =============================================================================
//  Знято зі знімків Mac 1.3.9 (Windows/Службові/mac-1.3.9 і mac-1.3.9-dark),
//  переведених у sRGB — як їх показує монітор Windows. Тема — як вибрано в
//  «Інтерфейс → Стиль» (за системою / світла / темна).
// =============================================================================

using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using Avalonia.Styling;

namespace Slovo.App;

public static class Palette
{
    /// Темна тема зараз — вирішує вибір у «Стилі» або сама Windows.
    public static bool IsDark =>
        Application.Current?.ActualThemeVariant == ThemeVariant.Dark;

    /// Тема змінилася — свої намальовані частини перемальовуються.
    public static event Action? Changed;
    public static void NotifyChanged() { Brushes.Clear(); Changed?.Invoke(); }

    static Color C(uint rgb, byte a = 255) => Color.FromArgb(a, (byte)(rgb >> 16), (byte)(rgb >> 8), (byte)rgb);
    static Color Pick(Color light, Color dark) => IsDark ? dark : light;

    // --- Поверхні ---------------------------------------------------------------
    /// Тло вікна (між панелями, рядок вкладок, смуга перекладів).
    public static Color WindowBackground => Pick(C(0xECECEC), C(0x323232));
    /// Тло списків і полів тексту.
    public static Color TextBackground => Pick(C(0xFFFFFF), C(0x1E1E1E));
    /// Тло кнопок, плиток і клітинок.
    public static Color ControlBackground => Pick(C(0xFFFFFF), C(0x1E1E1E));
    /// Розділові лінії між частинами вікна.
    public static Color Separator => Pick(C(0xD4D4D4), C(0x464646));

    // --- Текст ------------------------------------------------------------------
    public static Color Label => Pick(C(0x000000, 217), C(0xFFFFFF, 217));
    public static Color SecondaryLabel => Pick(C(0x000000, 128), C(0xFFFFFF, 140));
    public static Color TertiaryLabel => Pick(C(0x000000, 66), C(0xFFFFFF, 64));
    public static Color QuaternaryLabel => Pick(C(0x000000, 26), C(0xFFFFFF, 26));
    public static Color DisabledText => Pick(C(0x000000, 64), C(0xFFFFFF, 64));

    // --- Акцент і виділення -----------------------------------------------------
    /// Колір акценту (системний синій).
    public static Color Accent => Pick(C(0x007AFF), C(0x0A7AFF));
    /// Заливка виділеного рядка: акцент у 85 % сили — як у автора.
    public static Color Selection => Pick(C(0x398EFF), C(0x0C6CDD));
    /// Виділена плитка книги.
    public static Color TileSelection => Pick(C(0x4291FF), C(0x1971DD));
    public static Color SelectedText => C(0xFFFFFF);

    // --- Особливі ---------------------------------------------------------------
    /// Номер вірша — темно-червоний, як у автора (0.72, 0.16, 0.16).
    public static Color VerseNumber => C(0xB82929);
    public static Color SystemRed => Pick(C(0xFF3B30), C(0xFF453A));
    public static Color SystemGreen => Pick(C(0x28CD41), C(0x32D74B));
    public static Color SystemOrange => Pick(C(0xFF9500), C(0xFF9F0A));
    public static Color SystemYellow => Pick(C(0xFFCC00), C(0xFFD60A));
    public static Color SystemBlue => Pick(C(0x007AFF), C(0x0A84FF));
    public static Color SystemGray => Pick(C(0x8E8E93), C(0x98989D));

    // --- Пензлі (кешовані на тему) ----------------------------------------------
    static readonly Dictionary<Color, IImmutableSolidColorBrush> Brushes = new();
    public static IImmutableSolidColorBrush Brush(Color color)
    {
        if (!Brushes.TryGetValue(color, out var brush))
            Brushes[color] = brush = new ImmutableSolidColorBrush(color);
        return brush;
    }

    public static Color WithAlpha(this Color c, double alpha) =>
        Color.FromArgb((byte)Math.Round(Math.Clamp(alpha, 0, 1) * c.A), c.R, c.G, c.B);
}
