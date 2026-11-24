// =============================================================================
//  SlideStyle+IniSettings.cs — стиль слайда з ini (з Settings/SlideStyle+IniSettings.swift)
// =============================================================================

namespace Slovo.Core;

public partial record struct SlideStyle
{
    /// Перерахунок стилю з налаштувань у форматі ini.
    ///
    /// Товщина контуру, зсув і розмиття тіні записані в оригіналі в
    /// пікселях того слайда, під який їх підбирали, — його розмір лежить
    /// у `[OutScreen] height`. У нас усе в частках висоти, щоб картинка не
    /// роз'їжджалася між передпоказом, проектором і кадром NDI, тому
    /// ділимо на ту саму вихідну висоту.
    public SlideStyle(IniSettings config, string section = "Bible", string? dataRoot = null)
    {
        this = new SlideStyle(config.String("DefaultScheme", section) ?? OurWords.T("Из настроек"));

        var designHeight = Math.Max((double)(config.Int("height", "OutScreen") ?? 600), 1);

        var outlineOn = config.Bool("outlineenable", section) ?? true;
        var shadowOn = config.Bool("shadowenable", section) ?? true;
        var outlineWidth = outlineOn ? (config.Double("QuoteOutLineWidth", section) ?? 2) / designHeight : 0;
        var shadowRadius = shadowOn ? (config.Double("ShadowBlur", section) ?? 4) / designHeight : 0;
        var outlineColor = config.Color("outlinecolor", section) ?? RGBA.Black;

        Main.FontName = config.String("QuoteFontName", section) ?? Main.FontName;
        Main.IsBold = config.Bool("QuoteBold", section) ?? Main.IsBold;
        Main.IsItalic = config.Bool("QuoteItalic", section) ?? Main.IsItalic;
        Main.Color = config.Color("textcolor", section) ?? Main.Color;
        Main.OutlineColor = outlineColor;
        Main.OutlineWidth = outlineWidth;
        Main.ShadowRadius = shadowRadius;

        // Другий переклад оригінал малює тим самим шрифтом Цитати, відрізняючи розміром.
        Secondary.FontName = Main.FontName;
        Secondary.IsBold = Main.IsBold;
        Secondary.Color = Main.Color;
        Secondary.OutlineColor = outlineColor;
        Secondary.OutlineWidth = outlineWidth;
        Secondary.ShadowRadius = shadowRadius;
        Secondary.FontSize = Main.FontSize * 0.75;

        Reference.FontName = config.String("ReferFontName", section) ?? Reference.FontName;
        Reference.IsBold = config.Bool("ReferBold", section) ?? Reference.IsBold;
        Reference.IsItalic = config.Bool("ReferItalic", section) ?? Reference.IsItalic;
        Reference.Color = config.Color("refercolor", section) ?? Reference.Color;
        Reference.OutlineColor = outlineColor;
        Reference.OutlineWidth = outlineWidth;
        Reference.ShadowRadius = shadowRadius;

        if (config.Double("QuoteLineInterval", section) is { } interval)
        {
            // 1 в оригіналі — звичайний інтерліньяж, а не нульовий відступ.
            LineSpacing = Math.Max(0, interval - 1) * 0.5 + 0.12;
        }
        if (config.Double("percentfillingpage", "OutScreen") is { } fill && fill > 0)
        {
            // Наскільки текст заповнює слайд за висотою — прямий аналог кегля.
            Main.FontSize = Math.Min(0.16, Math.Max(0.04, fill / 100 * 0.28));
            Secondary.FontSize = Main.FontSize * 0.75;
        }

        // Час плавної зміни слайдів оригінал тримає в мілісекундах. Нижню межу
        // піднімаємо до чверті секунди навмисно: у Delphi розчинення йшло
        // покадрово, і сотня мілісекунд давала кілька проміжних кадрів; тут
        // крива неперервна, і на тому самому значенні зміна читається як ривок.
        if (config.Double("CrossfadeTime", "OutScreen") is { } crossfade)
        {
            TransitionKind = crossfade > 0 ? Transition.Fade : Transition.None;
            TransitionDuration = Math.Max(0.25, crossfade / 1000);
        }

        if (config.String("BackgrFileName", section) is { } relative && dataRoot != null)
        {
            var path = relative.Replace("\\", "/");
            var url = SwiftPath.Append(dataRoot, path);
            if (SwiftPath.Exists(url)) BackgroundImagePath = url;
        }
    }
}

/// Налаштування виводу, спільні для всіх режимів.
public record struct OutputSettings
{
    public int MonitorIndex { get; set; }
    public bool ShowVerseNumbers { get; set; }
    public bool ShowSecondaryVerseNumbers { get; set; }
    public double HideSlideDuration { get; set; }
    public int SlideWidth { get; set; }
    public int SlideHeight { get; set; }

    public OutputSettings(IniSettings config)
    {
        MonitorIndex = config.Int("monitor", "OutScreen") ?? 1;
        ShowVerseNumbers = config.Bool("ShowVersNum", "OutScreen") ?? false;
        ShowSecondaryVerseNumbers = config.Bool("ShowExtraQuoteVersNum", "OutScreen") ?? false;
        HideSlideDuration = (config.Double("HideSlideTime", "OutScreen") ?? 0) / 1000;
        SlideWidth = config.Int("width", "OutScreen") ?? 1024;
        SlideHeight = config.Int("height", "OutScreen") ?? 768;
    }
}
