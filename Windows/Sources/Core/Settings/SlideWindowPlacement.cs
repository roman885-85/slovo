// =============================================================================
//  SlideWindowPlacement.cs — куди ставити вікно слайда
//  (з Settings/SlideWindowPlacement.swift)
// =============================================================================

namespace Slovo.Core;

/// Куди програма ставить вікно слайда — елементи (5) (7) (9) вкладки
/// «Основні» (6.1.1).
///
/// Список (5) вибирає монітор; панель ручних налаштувань (9) задає положення
/// й розмір вікна слайда; поле (7) «Розміри за умовчанням» діє, «якщо при
/// запуску програми встановленого в (5) монітора не виявиться».
public abstract record SlideWindowPlacement
{
    /// (5) вибрано монітор. Номер у нумерації оригіналу: 1 — перший у списку.
    /// Якщо такого монітора зараз немає, вікно йде на головний із розмірами (7).
    public sealed record Monitor(int Number, int FallbackWidth, int FallbackHeight) : SlideWindowPlacement
    {
        public override string Summary => $"монитор {Number}, запасной размер {FallbackWidth}×{FallbackHeight}";
    }

    /// (9) «Ручне налаштування»: вікно ставиться за цими координатами, навіть
    /// коли монітора там зараз немає. Відлік — від лівого верхнього кута
    /// головного монітора, вісь Y униз.
    public sealed record Manual(int Left, int Top, int Width, int Height) : SlideWindowPlacement
    {
        public override string Summary => $"ручная настройка {Left},{Top} {Width}×{Height}";
    }

    /// Правило за значеннями вікна «Параметри» (`init(options:)`).
    public static SlideWindowPlacement From(ProgramOptions options)
    {
        if (options.MonitorIndex <= 0)
            return new Manual(options.CustomLeft, options.CustomTop,
                              Math.Max(1, options.CustomWidth), Math.Max(1, options.CustomHeight));
        return new Monitor(options.MonitorIndex, Math.Max(1, options.DefaultWidth), Math.Max(1, options.DefaultHeight));
    }

    /// Для звіту самоперевірки й підписів — коротко і мовою посібника.
    public abstract string Summary { get; }
}
