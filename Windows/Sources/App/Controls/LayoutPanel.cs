// =============================================================================
//  LayoutPanel.cs — панель з розкладкою арифметикою
// =============================================================================
//  Розкладка Mac-«Слова» — це прямокутники, пораховані за розміром панелі.
//  Тут так само: `Layout(size)` кладе кожну дитину `Place(…)`, панель їх і
//  ставить. Без розв'язувача обмежень — швидко й передбачувано.
// =============================================================================

using Avalonia;
using Avalonia.Controls;

namespace Slovo.App;

public class LayoutPanel : Panel
{
    readonly Dictionary<Control, Rect> _rects = new();
    /// Порахувати місця дітей під розмір панелі.
    public Action<Size>? Layout;

    public void Place(Control child, Rect rect) => _rects[child] = rect;

    /// Розкладка підкласу; за замовчуванням — колбек `Layout`.
    protected virtual void Arrangement(Size size) => Layout?.Invoke(size);

    /// Скільки панель просить у батька: за замовчуванням — усе, що дали.
    protected virtual Size Desired(Size available) =>
        new(double.IsInfinity(available.Width) ? 0 : available.Width,
            double.IsInfinity(available.Height) ? 0 : available.Height);

    /// Дітей міряємо тим розміром, який вони отримають, — не нескінченністю і
    /// не розміром усієї панелі. Інакше список у Grid «Auto,*» міряє прокрутку
    /// на весь вміст (прокручувати нема чого, вибраний рядок за краєм), а
    /// плитки книг рахують колонки за шириною вікна — 22 плитки по 7 точок.
    protected override Size MeasureOverride(Size available)
    {
        var desired = Desired(available);
        var basis = new Size(
            !double.IsInfinity(available.Width) ? available.Width : desired.Width > 0 ? desired.Width : Bounds.Width,
            !double.IsInfinity(available.Height) ? available.Height : desired.Height > 0 ? desired.Height : Bounds.Height);
        Forget();
        Arrangement(basis);
        foreach (var child in Children)
            child.Measure(Sane(_rects.TryGetValue(child, out var r) ? r.Size : default));
        return desired;
    }

    protected override Size ArrangeOverride(Size size)
    {
        Arrangement(size);
        foreach (var child in Children)
        {
            var rect = _rects.TryGetValue(child, out var r) ? r : default;
            // Розмір той самий, що й при вимірі, — Avalonia вимір пропускає;
            // інший (вікно змінилося між проходами) — переміряє.
            child.Measure(Sane(rect.Size));
            child.Arrange(rect);
        }
        return size;
    }

    static Size Sane(Size s) => new(double.IsNaN(s.Width) ? 0 : Math.Max(0, s.Width),
                                    double.IsNaN(s.Height) ? 0 : Math.Max(0, s.Height));

    /// Забути місця дітей, яких уже немає (вкладки міняють вміст).
    void Forget()
    {
        if (_rects.Count <= Children.Count) return;
        foreach (var gone in _rects.Keys.Where(k => !Children.Contains(k)).ToList()) _rects.Remove(gone);
    }
}
