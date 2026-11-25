// =============================================================================
//  FieldLook.cs — як виглядають поля введення (TextBox) у всій програмі
// =============================================================================
//  Звичайне поле — як NSTextField на Mac: біле (у темній темі — #1E1E1E) тло і
//  тонкий обідок, однакові в спокої, під мишею і в фокусі; у фокусі обідок
//  трохи густіший. Кольори — з тих самих чисел, що рамка швидкого поля
//  (QuickField): обідок — SecondaryLabel × 0,35, у фокусі × 0,6.
//
//  Поля, що малюють рамку самі (QuickField і похідні: швидкий вибір, пошук,
//  поля «Параметрів»), мають клас «bare»: їхнє тло й обідок прозорі в кожному
//  стані — інакше тема Fluent у фокусі клала б своє тло поверх намальованого.
//
//  24.11.2026: досі прозорими були ВСІ поля програми (ресурси TextControl* на
//  рівні програми), і поля без власної рамки зливалися з вікном — власник:
//  «часть окон и меню в которых вставляется текст сливаются с фоном».
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Presenters;
using Avalonia.Media;
using Avalonia.Styling;

namespace Slovo.App;

public static class FieldLook
{
    public const string Bare = "bare";

    public static void Install(Application app)
    {
        app.Resources.ThemeDictionaries[ThemeVariant.Light] = Colors(dark: false);
        app.Resources.ThemeDictionaries[ThemeVariant.Dark] = Colors(dark: true);
        app.Resources["TextControlBorderThemeThickness"] = new Thickness(1);
        app.Resources["TextControlBorderThemeThicknessFocused"] = new Thickness(1);
        // Висоту й відступи поля ставить той, хто його будує (як на Mac — за розміром рамки).
        app.Resources["TextControlThemeMinHeight"] = 0.0;
        app.Resources["TextControlThemePadding"] = new Thickness(4, 2, 4, 2);
        app.Resources["TextControlSelectionHighlightColor"] = new SolidColorBrush(Color.FromRgb(0x39, 0x8E, 0xFF));
        app.Styles.Add(BareStyles());
    }

    static ResourceDictionary Colors(bool dark)
    {
        var back = dark ? Color.FromRgb(0x1E, 0x1E, 0x1E) : Color.FromRgb(0xFF, 0xFF, 0xFF);
        var disabled = dark ? Color.FromRgb(0x2A, 0x2A, 0x2A) : Color.FromRgb(0xF6, 0xF6, 0xF6);
        // SecondaryLabel (світла тема — чорний 50 %, темна — білий 55 %) × 0,35 і × 0,6.
        var border = dark ? Color.FromArgb(49, 255, 255, 255) : Color.FromArgb(45, 0, 0, 0);
        var focused = dark ? Color.FromArgb(84, 255, 255, 255) : Color.FromArgb(77, 0, 0, 0);
        return new ResourceDictionary
        {
            ["TextControlBackground"] = new SolidColorBrush(back),
            ["TextControlBackgroundPointerOver"] = new SolidColorBrush(back),
            ["TextControlBackgroundFocused"] = new SolidColorBrush(back),
            ["TextControlBackgroundDisabled"] = new SolidColorBrush(disabled),
            ["TextControlBorderBrush"] = new SolidColorBrush(border),
            ["TextControlBorderBrushPointerOver"] = new SolidColorBrush(border),
            ["TextControlBorderBrushFocused"] = new SolidColorBrush(focused),
            ["TextControlBorderBrushDisabled"] = new SolidColorBrush(border),
        };
    }

    /// Поля з класом «bare»: тло й обідок прозорі в спокої, під мишею, у фокусі й вимкненими.
    static Styles BareStyles()
    {
        var styles = new Styles();
        foreach (var state in new[] { "", ":pointerover", ":focus", ":disabled" })
        {
            var style = new Style(x =>
            {
                var box = x.OfType<TextBox>().Class(Bare);
                if (state.Length > 0) box = box.Class(state);
                return box.Template().OfType<Border>().Name("PART_BorderElement");
            });
            style.Setters.Add(new Setter(Border.BackgroundProperty, Brushes.Transparent));
            style.Setters.Add(new Setter(Border.BorderBrushProperty, Brushes.Transparent));
            style.Setters.Add(new Setter(Border.BorderThicknessProperty, new Thickness(0)));
            styles.Add(style);
        }
        return styles;
    }
}
