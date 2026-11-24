// =============================================================================
//  SlideFocus.cs — наближення до точки фокуса (як Projection/SlideFocus.swift)
// =============================================================================
//  Клацання по живому екрану — цей шматок сторінки стає на весь екран; колесо
//  — ближче/далі навколо курсора; середня кнопка — назад. Діє на сторінки
//  показу, фотографії й захоплений екран (не на текст слайда). Показане вікно
//  їде до цілі плавно (0,28 с), і сторінка в залі пливе разом із ним.
// =============================================================================

using Avalonia;
using Avalonia.Threading;
using SkiaSharp;

namespace Slovo.App;

public sealed class SlideFocus
{
    public static readonly SlideFocus Shared = new();

    public readonly record struct Look(double Zoom, double X, double Y)
    {
        /// Без цього `new Look()` структури дає нулі, а не 2 · центр.
        public Look() : this(2, 0.5, 0.5) { }
    }

    public const double MinZoom = 1, MaxZoom = 6;
    // Властивістю, а не полем: статичні поля ініціалізуються за порядком тексту, і Shared
    // (оголошене вище) брало Whole ще нульовим — початковий ShownRect був 0×0, і захоплення
    // екрана у Windows показувало розтягнутий шматок 8×8 (знайдено у ВМ).
    static Rect Whole => new(0, 0, 1, 1);

    public bool IsOn { get; private set; }
    public Look Current { get; private set; } = new();
    /// Що видно зараз (їде до `Rect` плавно).
    public Rect ShownRect { get; private set; } = Whole;
    public event Action? Changed;
    public event Action? ShownChanged;
    public static double AnimationDuration = Program.Snapshotting ? 0 : 0.28;

    DispatcherTimer? _ride;
    Rect _rideFrom = Whole;
    DateTime _rideStart;

    SlideFocus() { }

    /// Ціль — частина сторінки, що має стати на весь екран.
    public Rect Rect
    {
        get
        {
            if (!IsOn) return Whole;
            var side = 1 / Math.Min(MaxZoom, Math.Max(MinZoom, Current.Zoom));
            var x = Math.Min(1 - side, Math.Max(0, Current.X - side / 2));
            var y = Math.Min(1 - side, Math.Max(0, Current.Y - side / 2));
            return new Rect(x, y, side, side);
        }
    }

    public void SetOn(bool on) { if (on == IsOn) return; IsOn = on; Announce(); }

    public void SetZoom(double zoom)
    {
        var value = Math.Min(MaxZoom, Math.Max(MinZoom, zoom));
        if (value == Current.Zoom) return;
        Current = Current with { Zoom = value };
        Announce();
    }

    /// Клацання в показаному кадрі (частки 0…1) — туди й дивимося.
    public void MoveToShown(double x, double y)
    {
        var window = Rect;
        var fresh = new Look(Current.Zoom, window.X + Math.Min(1, Math.Max(0, x)) * window.Width,
                             window.Y + Math.Min(1, Math.Max(0, y)) * window.Height);
        if (fresh == Current) return;
        Current = fresh;
        Announce();
    }

    /// Колесо: наблизити до `value` так, щоб точка під курсором стояла на місці.
    public void ZoomTo(double value, double x, double y)
    {
        var target = Math.Min(MaxZoom, Math.Max(MinZoom, value));
        var window = Rect;
        var shownX = Math.Min(1, Math.Max(0, x));
        var shownY = Math.Min(1, Math.Max(0, y));
        var pointX = window.X + shownX * window.Width;
        var pointY = window.Y + shownY * window.Height;
        var side = 1 / target;
        var half = side / 2;
        var fresh = new Look(target, Math.Min(1 - half, Math.Max(half, pointX + side * (0.5 - shownX))),
                             Math.Min(1 - half, Math.Max(half, pointY + side * (0.5 - shownY))));
        if (fresh == Current) return;
        Current = fresh;
        Announce();
    }

    public void Reset()
    {
        var fresh = new Look();
        if (!IsOn && fresh == Current) return;
        IsOn = false;
        Current = fresh;
        Announce();
    }

    /// Нова сторінка — наближення скидається одразу, без їзди.
    public void DropForNewPage()
    {
        if (!IsOn && Current == new Look() && ShownRect == Whole) return;
        _ride?.Stop();
        _ride = null;
        IsOn = false;
        Current = new Look();
        ShownRect = Whole;
        Changed?.Invoke();
    }

    public void Center()
    {
        if (Current.X == 0.5 && Current.Y == 0.5) return;
        Current = Current with { X = 0.5, Y = 0.5 };
        Announce();
    }

    void Announce()
    {
        Changed?.Invoke();
        Ride(Rect);
    }

    void Ride(Rect target)
    {
        _ride?.Stop();
        _ride = null;
        if (target == ShownRect) return;
        if (AnimationDuration <= 0) { ShownRect = target; ShownChanged?.Invoke(); return; }
        _rideFrom = ShownRect;
        _rideStart = DateTime.Now;
        _ride = new DispatcherTimer(TimeSpan.FromSeconds(1.0 / 60), DispatcherPriority.Render, (_, _) => Step());
        _ride.Start();
    }

    void Step()
    {
        var part = Math.Min(1, (DateTime.Now - _rideStart).TotalSeconds / Math.Max(0.001, AnimationDuration));
        var eased = part < 0.5 ? 2 * part * part : 1 - Math.Pow(-2 * part + 2, 2) / 2;
        var to = Rect;
        double Mix(double a, double b) => a + (b - a) * eased;
        ShownRect = part >= 1 ? to : new Rect(Mix(_rideFrom.X, to.X), Mix(_rideFrom.Y, to.Y),
                                               Mix(_rideFrom.Width, to.Width), Mix(_rideFrom.Height, to.Height));
        if (part >= 1) { _ride?.Stop(); _ride = null; }
        ShownChanged?.Invoke();
    }

    public bool IsRiding => _ride != null;

    /// Вирізати з картинки показаний шматок (частки 0…1).
    public static SKRect Crop(SKImage image, Rect rect)
    {
        var whole = new SKRect(0, 0, image.Width, image.Height);
        if (rect.Width >= 0.999 && rect.Height >= 0.999) return whole;
        var box = SKRect.Create((float)Math.Round(rect.X * image.Width), (float)Math.Round(rect.Y * image.Height),
                                (float)Math.Max(2, Math.Round(rect.Width * image.Width)), (float)Math.Max(2, Math.Round(rect.Height * image.Height)));
        box.Intersect(whole);
        return box.Width >= 2 && box.Height >= 2 ? box : whole;
    }
}
