import Foundation

public extension SlideStyle {

    /// Перерахунок стилю з налаштувань у форматі ini.
    ///
    /// Товщина контуру, зсув і розмиття тіні записані в оригіналі в
    /// пікселях того слайда, під який їх підбирали, — його розмір лежить
    /// у `[OutScreen] height`. У нас усе в частках висоти, щоб картинка не
    /// роз'їжджалася між передпоказом, проектором і кадром NDI, тому
    /// ділимо на ту саму вихідну висоту.
    init(config: IniSettings, section: String = "Bible", dataRoot: URL?) {
        self.init(name: config.string("DefaultScheme", in: section) ?? OurWords.t("Из настроек"))

        let designHeight = max(Double(config.int("height", in: "OutScreen") ?? 600), 1)

        let outlineOn = config.bool("outlineenable", in: section) ?? true
        let shadowOn = config.bool("shadowenable", in: section) ?? true
        let outlineWidth = outlineOn ? (config.double("QuoteOutLineWidth", in: section) ?? 2) / designHeight : 0
        let shadowRadius = shadowOn ? (config.double("ShadowBlur", in: section) ?? 4) / designHeight : 0
        let outlineColor = config.color("outlinecolor", in: section) ?? .black

        main.fontName = config.string("QuoteFontName", in: section) ?? main.fontName
        main.isBold = config.bool("QuoteBold", in: section) ?? main.isBold
        main.isItalic = config.bool("QuoteItalic", in: section) ?? main.isItalic
        main.color = config.color("textcolor", in: section) ?? main.color
        main.outlineColor = outlineColor
        main.outlineWidth = outlineWidth
        main.shadowRadius = shadowRadius

        // Другий переклад оригінал малює тим самим шрифтом Цитати, відрізняючи розміром.
        secondary.fontName = main.fontName
        secondary.isBold = main.isBold
        secondary.color = main.color
        secondary.outlineColor = outlineColor
        secondary.outlineWidth = outlineWidth
        secondary.shadowRadius = shadowRadius
        secondary.fontSize = main.fontSize * 0.75

        reference.fontName = config.string("ReferFontName", in: section) ?? reference.fontName
        reference.isBold = config.bool("ReferBold", in: section) ?? reference.isBold
        reference.isItalic = config.bool("ReferItalic", in: section) ?? reference.isItalic
        reference.color = config.color("refercolor", in: section) ?? reference.color
        reference.outlineColor = outlineColor
        reference.outlineWidth = outlineWidth
        reference.shadowRadius = shadowRadius

        if let interval = config.double("QuoteLineInterval", in: section) {
            // 1 в оригіналі — звичайний інтерліньяж, а не нульовий відступ.
            lineSpacing = max(0, (interval - 1)) * 0.5 + 0.12
        }
        if let fill = config.double("percentfillingpage", in: "OutScreen"), fill > 0 {
            // Наскільки текст заповнює слайд за висотою — прямий аналог кегля.
            main.fontSize = min(0.16, max(0.04, fill / 100 * 0.28))
            secondary.fontSize = main.fontSize * 0.75
        }

        // Час плавної зміни слайдів оригінал тримає в мілісекундах.
        //
        // Нижню межу піднімаємо до чверті секунди навмисно: у Delphi
        // розчинення йшло покадрово з частотою з `AnimTimerFreq`, і сотня
        // мілісекунд давала там кілька проміжних кадрів. Тут крива
        // неперервна, і на тому самому значенні зміна читається як ривок. Точний
        // час усе одно лишається за повзунком у налаштуваннях.
        if let crossfade = config.double("CrossfadeTime", in: "OutScreen") {
            transition = crossfade > 0 ? .fade : .none
            transitionDuration = max(0.25, crossfade / 1000)
        }

        if let relative = config.string("BackgrFileName", in: section), let dataRoot {
            let path = relative.replacingOccurrences(of: "\\", with: "/")
            let url = dataRoot.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) { backgroundImagePath = url.path }
        }
    }
}

/// Налаштування виводу, спільні для всіх режимів.
public struct OutputSettings: Sendable {
    public var monitorIndex: Int
    public var showVerseNumbers: Bool
    public var showSecondaryVerseNumbers: Bool
    public var hideSlideDuration: Double
    public var slideWidth: Int
    public var slideHeight: Int

    public init(config: IniSettings) {
        monitorIndex = config.int("monitor", in: "OutScreen") ?? 1
        showVerseNumbers = config.bool("ShowVersNum", in: "OutScreen") ?? false
        showSecondaryVerseNumbers = config.bool("ShowExtraQuoteVersNum", in: "OutScreen") ?? false
        hideSlideDuration = (config.double("HideSlideTime", in: "OutScreen") ?? 0) / 1000
        slideWidth = config.int("width", in: "OutScreen") ?? 1024
        slideHeight = config.int("height", in: "OutScreen") ?? 768
    }
}
