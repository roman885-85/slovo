// =============================================================================
//  FlowBar.cs — полоса кнопок з переносом на наступний ряд (як NativeFlowBar на Mac)
// =============================================================================
//  Власник: «часть кнопок не видно… приходится вручную растягивать окно». Тут
//  не влізло — пішло на наступний ряд, а полоса стала вища: жодна кнопка не
//  пропадає, хоч як вузько. Ширина кожного — за вмістом (не менше 40 і не
//  ширше самої полоси), висота власна, коли менша за ряд, — інакше висота ряду.
// =============================================================================

using Avalonia;
using Avalonia.Controls;

namespace Slovo.App;

public sealed class FlowBar : LayoutPanel
{
    public double RowHeight { get; set; } = 24;
    public double Gap { get; set; } = 4;

    public FlowBar() => Layout = size => Place(size.Width, true);

    public void SetItems(IEnumerable<Control> items)
    {
        Children.Clear();
        foreach (var item in items) Children.Add(item);
        InvalidateMeasure();
        InvalidateArrange();
    }

    /// Висота полоси при такій ширині — рахується тією самою розкладкою.
    public double HeightFor(double width) => Place(width, false);

    /// Розмір за вмістом — як `fittingSize` елементів AppKit: рамка списку на 3 точки ширша
    /// за його обідок, прапорець займає ще 10 (квадратик відступає від краю на 3). Виміряно
    /// на знімку Mac (полоса проб під сценою редактора веб-слайдів).
    static Size Fitting(Control item) => item switch
    {
        PushButton button => new Size(button.FittingWidth, 21),
        PopupButton popup => new Size(popup.FittingWidth + 3, 26),
        MacCheckBox check => new Size(check.FittingWidth + 10, 18),
        _ => Measured(item),
    };

    /// Поля всередині місця: квадратик прапорця — на 3 від лівого краю, обідок списку — на 3 від правого.
    static (double Left, double Right) Inset(Control item) => item switch
    {
        MacCheckBox => (3, 0),
        PopupButton => (0, 3),
        _ => (0, 0),
    };

    static Size Measured(Control item)
    {
        item.Measure(Size.Infinity);
        return item.DesiredSize;
    }

    double Place(double width, bool apply)
    {
        double x = 0, y = 0;
        foreach (var item in Children)
        {
            var fitting = Fitting(item);
            // Ширший за саму полосу елемент притискаємо до її ширини: список із довгою
            // назвою краще підрізати, ніж винести за край вікна.
            var wanted = Math.Min(Math.Max(40, Math.Ceiling(fitting.Width)), Math.Max(40, width));
            if (x > 0 && x + wanted > width)
            {
                x = 0;
                y += RowHeight + Gap;
            }
            if (apply)
            {
                var own = Math.Ceiling(fitting.Height);
                var height = own > 0 && own < RowHeight ? own : RowHeight;
                var (left, right) = Inset(item);
                Place(item, new Rect(x + left, y + (RowHeight - height) / 2, Math.Max(0, wanted - left - right), height));
            }
            x += wanted + Gap;
        }
        return Children.Count == 0 ? RowHeight : y + RowHeight;
    }
}
