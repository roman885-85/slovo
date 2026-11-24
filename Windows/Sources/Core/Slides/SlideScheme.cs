// =============================================================================
//  SlideScheme.cs — шаблон оформлення слайда .sch (з Slides/SlideScheme.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Шаблон оформлення слайда — «розмітка» оригіналу з теки `Templates`.
///
/// У файлі `<Ім'я>.sch` лежить XML: корінь `VisioBibleScheme`, усередині один
/// `Scheme` зі спільними для слайда обведенням і тінню Цитати, а далі список
/// `Object` — рамки тексту і картинки прикрас. Шрифтів у шаблоні немає: шаблон
/// не заміняє `SlideStyle`, а накладається поверх нього (`ToSlideStyle`).
/// Числа Delphi з комою, кольори `TColor`, відсотки від розміру слайда —
/// усе приведено до нормальних величин уже тут.
public sealed class SlideScheme
{
    /// Що за елемент лежить на слайді — номери з атрибута `Type` (усі
    /// чотирнадцять видів конструктора оригіналу).
    [JsonConverter(typeof(SwiftIntEnumConverter<ElementKind>))]
    public enum ElementKind
    {
        Quote = 0,                  // Цитата — основний текст
        Reference = 1,              // об'єднана адреса
        PreviousPage = 2,           // стрілка «попередня сторінка»
        NextPage = 3,               // стрілка «наступна сторінка»
        StaticText = 4,             // довільний напис
        Decoration = 5,             // картинка: лінії, панелі, ноти, книга
        SecondQuote = 6,            // другий переклад
        SecondReference = 7,        // адреса другого перекладу
        FirstReference = 8,         // адреса основного перекладу
        ModuleShortNameFirst = 9,   // ім'я модуля 1 коротке
        ModuleShortNameSecond = 10, // ім'я модуля 2 коротке
        ModuleNameFirst = 11,       // ім'я модуля 1 повне
        ModuleNameSecond = 12,      // ім'я модуля 2 повне
        SongTitle = 13,             // назва пісні
    }

    public static string Title(ElementKind kind) => kind switch
    {
        ElementKind.Quote => OurWords.T("Цитата"),
        ElementKind.Reference => OurWords.T("Ссылка"),
        ElementKind.PreviousPage => OurWords.T("Пред. страница"),
        ElementKind.NextPage => OurWords.T("След. страница"),
        ElementKind.StaticText => OurWords.T("Статический текст"),
        ElementKind.Decoration => OurWords.T("Картинка"),
        ElementKind.SecondQuote => OurWords.T("Второй перевод"),
        ElementKind.SecondReference => OurWords.T("Ссылка второго перевода"),
        ElementKind.FirstReference => OurWords.T("Адрес основного перевода"),
        ElementKind.ModuleShortNameFirst => OurWords.T("Имя Модуля 1 короткое"),
        ElementKind.ModuleShortNameSecond => OurWords.T("Имя Модуля 2 короткое"),
        ElementKind.ModuleNameFirst => OurWords.T("Имя Модуля 1 полное"),
        ElementKind.ModuleNameSecond => OurWords.T("Имя Модуля 2 полное"),
        _ => OurWords.T("Название песни"),
    };

    /// Слайд малюється у двох варіантах: один переклад і два (`Width` / `Width_2`,
    /// `scene1.jpg` і `scene2.jpg`).
    [JsonConverter(typeof(SwiftIntEnumConverter<Variant>))]
    public enum Variant { Single = 0, Dual = 1 }

    public static string Title(Variant variant) =>
        variant == Variant.Single ? OurWords.T("Один перевод") : OurWords.T("Два перевода");

    /// Виключка рядка всередині рамки — Delphi `TAlignment`.
    [JsonConverter(typeof(SwiftIntEnumConverter<TextAlignment>))]
    public enum TextAlignment { Left = 0, Right = 1, Center = 2 }

    /// Як текст лежить у рамці по вертикалі — Delphi `TTextLayout`.
    [JsonConverter(typeof(SwiftIntEnumConverter<TextLayout>))]
    public enum TextLayout { Top = 0, Center = 1, Bottom = 2 }

    /// Від якого кута слайда відміряно відступи `IndentionX` / `IndentionY`.
    ///
    /// У файлі це одне число `Align`: молодші два біти — горизонталь (0 —
    /// зліва, 1 — справа, 2 — по центру), наступний біт — вертикаль (0 —
    /// зверху, 1 — знизу). Звірено з мініатюрами авторських шаблонів.
    public record struct Anchor
    {
        [JsonConverter(typeof(SwiftIntEnumConverter<HorizontalSide>))]
        public enum HorizontalSide { Left = 0, Right = 1, Center = 2 }

        [JsonConverter(typeof(SwiftIntEnumConverter<VerticalSide>))]
        public enum VerticalSide { Top = 0, Bottom = 1 }

        [JsonInclude, JsonRequired, JsonPropertyName("horizontal")] public HorizontalSide Horizontal;
        [JsonInclude, JsonRequired, JsonPropertyName("vertical")] public VerticalSide Vertical;
        /// Вихідне число — на випадок значень, яких ми ще не бачили.
        [JsonInclude, JsonRequired, JsonPropertyName("rawValue")] public int RawValue;

        public Anchor() : this(HorizontalSide.Center, VerticalSide.Top) { }

        public Anchor(int rawValue)
        {
            RawValue = rawValue;
            var bits = Math.Max(0, rawValue) & 0b11;
            Horizontal = Enum.IsDefined((HorizontalSide)bits) ? (HorizontalSide)bits : HorizontalSide.Center;
            Vertical = (Math.Max(0, rawValue) & 0b100) == 0 ? VerticalSide.Top : VerticalSide.Bottom;
        }

        public Anchor(HorizontalSide horizontal, VerticalSide vertical)
        {
            Horizontal = horizontal;
            Vertical = vertical;
            RawValue = (int)horizontal | ((int)vertical << 2);
        }
    }

    /// Прямокутник у частках слайда — 0…1 від лівого верхнього кута.
    public record struct Box
    {
        [JsonInclude, JsonRequired, JsonPropertyName("x")] public double X;
        [JsonInclude, JsonRequired, JsonPropertyName("y")] public double Y;
        [JsonInclude, JsonRequired, JsonPropertyName("width")] public double Width;
        [JsonInclude, JsonRequired, JsonPropertyName("height")] public double Height;

        public Box(double x, double y, double width, double height)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }

        [JsonIgnore] public readonly double MaxX => X + Width;
        [JsonIgnore] public readonly double MaxY => Y + Height;
        [JsonIgnore] public readonly double MidX => X + Width / 2;
        [JsonIgnore] public readonly double MidY => Y + Height / 2;
    }

    /// Положення елемента в одному з двох варіантів слайда: розміри й відступи
    /// — відсотки слайда, прозорість і тінь — уже частки 0…1.
    public record struct Placement
    {
        [JsonInclude, JsonRequired, JsonPropertyName("width")] public double Width;              // відсотки ширини слайда
        [JsonInclude, JsonRequired, JsonPropertyName("height")] public double Height;            // відсотки висоти слайда
        [JsonInclude, JsonRequired, JsonPropertyName("indentX")] public double IndentX;          // відсотки, від якоря
        [JsonInclude, JsonRequired, JsonPropertyName("indentY")] public double IndentY;
        [JsonInclude, JsonRequired, JsonPropertyName("anchor")] public Anchor Anchor;
        [JsonInclude, JsonRequired, JsonPropertyName("opacity")] public double Opacity;          // 0…1
        [JsonInclude, JsonRequired, JsonPropertyName("isEnabled")] public bool IsEnabled;
        [JsonInclude, JsonRequired, JsonPropertyName("shadowOffset")] public double ShadowOffset; // відсотки (у тексту — від кегля)
        [JsonInclude, JsonRequired, JsonPropertyName("shadowBlur")] public double ShadowBlur;
        [JsonInclude, JsonRequired, JsonPropertyName("shadowOpacity")] public double ShadowOpacity; // 0…1
        [JsonInclude, JsonRequired, JsonPropertyName("shadowColor")] public SlideStyle.RGBA ShadowColor;
        [JsonInclude, JsonPropertyName("textAlignment")] public TextAlignment? TextAlignment;   // лише в текстових елементів
        [JsonInclude, JsonPropertyName("textLayout")] public TextLayout? TextLayout;

        public Placement() : this(100) { }

        public Placement(double width = 100, double height = 100, double indentX = 0, double indentY = 0,
                         Anchor? anchor = null, double opacity = 1, bool isEnabled = true,
                         double shadowOffset = 0, double shadowBlur = 0, double shadowOpacity = 0,
                         SlideStyle.RGBA? shadowColor = null, TextAlignment? textAlignment = null,
                         TextLayout? textLayout = null)
        {
            Width = width;
            Height = height;
            IndentX = indentX;
            IndentY = indentY;
            Anchor = anchor ?? new Anchor(Anchor.HorizontalSide.Center, Anchor.VerticalSide.Top);
            Opacity = opacity;
            IsEnabled = isEnabled;
            ShadowOffset = shadowOffset;
            ShadowBlur = shadowBlur;
            ShadowOpacity = shadowOpacity;
            ShadowColor = shadowColor ?? SlideStyle.RGBA.Black;
            TextAlignment = textAlignment;
            TextLayout = textLayout;
        }

        /// Рамка в частках слайда. Відступ рахується зсувом від якоря, а не
        /// абсолютною координатою: у `Default` у Цитати `Align="2"` (по центру),
        /// ширина 94 % і `IndentionX="0"` — поля по 3 % з кожного боку.
        [JsonIgnore]
        public readonly Box Box
        {
            get
            {
                var w = Width / 100;
                var h = Height / 100;
                var dx = IndentX / 100;
                var dy = IndentY / 100;
                var x = Anchor.Horizontal switch
                {
                    Anchor.HorizontalSide.Left => dx,
                    Anchor.HorizontalSide.Right => 1 - w - dx,
                    _ => (1 - w) / 2 + dx,
                };
                var y = Anchor.Vertical == Anchor.VerticalSide.Top ? dy : 1 - h - dy;
                return new Box(x, y, w, h);
            }
        }
    }

    /// Поява елемента: один кадр анімації на кожен варіант слайда. `Fx` — номер
    /// ефекту оригіналу; розшифровки немає, тому характер руху — з параметрів.
    public record struct Scene
    {
        [JsonInclude, JsonRequired, JsonPropertyName("fx")] public int Fx;
        [JsonInclude, JsonRequired, JsonPropertyName("isAnimated")] public bool IsAnimated;
        [JsonInclude, JsonRequired, JsonPropertyName("fromOpacity")] public double FromOpacity;   // 0…1
        [JsonInclude, JsonRequired, JsonPropertyName("fromScale")] public double FromScale;       // 0…1, нуль — без зміни розміру
        [JsonInclude, JsonRequired, JsonPropertyName("moveFromX")] public double MoveFromX;       // відсотки слайда
        [JsonInclude, JsonRequired, JsonPropertyName("moveFromY")] public double MoveFromY;
        [JsonInclude, JsonRequired, JsonPropertyName("delay")] public double Delay;               // секунди
        [JsonInclude, JsonRequired, JsonPropertyName("duration")] public double Duration;         // секунди

        public Scene() : this(0) { }

        public Scene(int fx = 0, bool isAnimated = false, double fromOpacity = 1, double fromScale = 0,
                     double moveFromX = 0, double moveFromY = 0, double delay = 0, double duration = 0)
        {
            Fx = fx;
            IsAnimated = isAnimated;
            FromOpacity = fromOpacity;
            FromScale = fromScale;
            MoveFromX = moveFromX;
            MoveFromY = moveFromY;
            Delay = delay;
            Duration = duration;
        }

        [JsonIgnore] public readonly bool MovesHorizontally => Math.Abs(MoveFromX) >= Math.Abs(MoveFromY);
        [JsonIgnore] public readonly bool IsMoving => Math.Abs(MoveFromX) > 0.001 || Math.Abs(MoveFromY) > 0.001;
        [JsonIgnore] public readonly bool IsScaling => FromScale > 0.001;
    }

    /// Набір анімацій елемента під один іменований пресет (`Fx1`, `Fx2`…).
    public sealed class FXPreset
    {
        [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonRequired, JsonPropertyName("hasVariantParameters")] public bool HasVariantParameters { get; set; }
        [JsonRequired, JsonPropertyName("scenes")] public List<Scene> Scenes { get; set; } = new();

        public FXPreset() { }

        public FXPreset(string name = "", bool hasVariantParameters = false, List<Scene>? scenes = null)
        {
            Name = name;
            HasVariantParameters = hasVariantParameters;
            Scenes = scenes ?? new List<Scene>();
        }

        /// Кадр для варіанта (`scene(_:)`): немає свого — перший.
        public Scene? SceneFor(Variant variant)
        {
            var index = (int)variant;
            if (index >= 0 && index < Scenes.Count) return Scenes[index];
            return Scenes.Count > 0 ? Scenes[0] : null;
        }

        public FXPreset Copy() => new(Name, HasVariantParameters, new List<Scene>(Scenes));
    }

    /// Один `Object` шаблону.
    public sealed class Element
    {
        [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
        [JsonRequired, JsonPropertyName("rawType")] public int RawType { get; set; }
        [JsonPropertyName("kind")] public ElementKind? Kind { get; set; }
        [JsonPropertyName("imageName")] public string? ImageName { get; set; }          // файл у теці шаблону
        [JsonPropertyName("imageMaskName")] public string? ImageMaskName { get; set; }  // чорно-біла маска прозорості
        [JsonPropertyName("textColor")] public SlideStyle.RGBA? TextColor { get; set; }
        /// `EnableParamsVariant` — другий варіант налаштовано окремо, а не скопійовано.
        [JsonRequired, JsonPropertyName("hasVariantParameters")] public bool HasVariantParameters { get; set; }
        [JsonRequired, JsonPropertyName("placements")] public List<Placement> Placements { get; set; } = new();
        [JsonRequired, JsonPropertyName("presets")] public List<FXPreset> Presets { get; set; } = new();
        /// Усі атрибути як є — щоб незнайоме поле не пропадало.
        [JsonRequired, JsonPropertyName("attributes")] public Dictionary<string, string> Attributes { get; set; } = new();

        [JsonConstructor]
        public Element() { }

        public Element(string name, int rawType, string? imageName = null, string? imageMaskName = null,
                       SlideStyle.RGBA? textColor = null, bool hasVariantParameters = false,
                       List<Placement>? placements = null, List<FXPreset>? presets = null,
                       Dictionary<string, string>? attributes = null)
        {
            Name = name;
            RawType = rawType;
            Kind = Enum.IsDefined((ElementKind)rawType) ? (ElementKind)rawType : null;
            ImageName = imageName;
            ImageMaskName = imageMaskName;
            TextColor = textColor;
            HasVariantParameters = hasVariantParameters;
            Placements = placements ?? new List<Placement>();
            Presets = presets ?? new List<FXPreset>();
            Attributes = attributes ?? new Dictionary<string, string>();
        }

        /// Положення у вибраному варіанті (`placement(_:)`); немає другого — перший.
        public Placement PlacementFor(Variant variant = Variant.Single)
        {
            var index = (int)variant;
            if (index >= 0 && index < Placements.Count) return Placements[index];
            return Placements.Count > 0 ? Placements[0] : new Placement();
        }

        /// Кадр анімації (`scene(_:preset:)`).
        public Scene? SceneFor(Variant variant = Variant.Single, string? preset = null)
        {
            var chosen = preset == null ? null : Presets.FirstOrDefault(p => SwiftText.SameIgnoringCase(p.Name, preset));
            return (chosen ?? Presets.FirstOrDefault())?.SceneFor(variant);
        }

        public Element Copy() => new()
        {
            Name = Name, RawType = RawType, Kind = Kind, ImageName = ImageName, ImageMaskName = ImageMaskName,
            TextColor = TextColor, HasVariantParameters = HasVariantParameters,
            Placements = new List<Placement>(Placements), Presets = Presets.Select(p => p.Copy()).ToList(),
            Attributes = new Dictionary<string, string>(Attributes),
        };
    }

    [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
    /// Ім'я файлу фону всередині однойменної теки шаблону.
    [JsonRequired, JsonPropertyName("backgroundImageName")] public string BackgroundImageName { get; set; } = "";
    [JsonRequired, JsonPropertyName("outlineEnabled")] public bool OutlineEnabled { get; set; }
    [JsonRequired, JsonPropertyName("outlineWidth")] public double OutlineWidth { get; set; }             // пікселі слайда, під який малювали
    [JsonRequired, JsonPropertyName("outlineColor")] public SlideStyle.RGBA OutlineColor { get; set; } = SlideStyle.RGBA.Black;
    [JsonRequired, JsonPropertyName("shadowEnabled")] public bool ShadowEnabled { get; set; }
    [JsonRequired, JsonPropertyName("shadowOffset")] public double ShadowOffset { get; set; }             // пікселі
    [JsonRequired, JsonPropertyName("shadowBlur")] public double ShadowBlur { get; set; }                 // пікселі
    [JsonRequired, JsonPropertyName("shadowOpacity")] public double ShadowOpacity { get; set; }           // 0…1
    [JsonRequired, JsonPropertyName("shadowColor")] public SlideStyle.RGBA ShadowColor { get; set; } = SlideStyle.RGBA.Black;
    /// Імена пресетів анімації, оголошені у `FXPresetsList`.
    [JsonRequired, JsonPropertyName("presetNames")] public List<string> PresetNames { get; set; } = new();
    [JsonRequired, JsonPropertyName("elements")] public List<Element> Elements { get; set; } = new();
    [JsonRequired, JsonPropertyName("attributes")] public Dictionary<string, string> Attributes { get; set; } = new();

    [JsonConstructor]
    public SlideScheme() { }

    public SlideScheme(string name, string backgroundImageName = "", bool outlineEnabled = false, double outlineWidth = 0,
                       SlideStyle.RGBA? outlineColor = null, bool shadowEnabled = false, double shadowOffset = 0,
                       double shadowBlur = 0, double shadowOpacity = 0, SlideStyle.RGBA? shadowColor = null,
                       List<string>? presetNames = null, List<Element>? elements = null,
                       Dictionary<string, string>? attributes = null)
    {
        Name = name;
        BackgroundImageName = backgroundImageName;
        OutlineEnabled = outlineEnabled;
        OutlineWidth = outlineWidth;
        OutlineColor = outlineColor ?? SlideStyle.RGBA.Black;
        ShadowEnabled = shadowEnabled;
        ShadowOffset = shadowOffset;
        ShadowBlur = shadowBlur;
        ShadowOpacity = shadowOpacity;
        ShadowColor = shadowColor ?? SlideStyle.RGBA.Black;
        PresetNames = presetNames ?? new List<string>();
        Elements = elements ?? new List<Element>();
        Attributes = attributes ?? new Dictionary<string, string>();
    }

    // ── Пошук елементів ─────────────────────────────────────────────────────

    /// `element(_:)` — перший елемент цього виду.
    public Element? FindElement(ElementKind kind) => Elements.FirstOrDefault(element => element.Kind == kind);

    [JsonIgnore] public Element? Quote => FindElement(ElementKind.Quote);
    [JsonIgnore] public Element? SecondQuote => FindElement(ElementKind.SecondQuote);
    [JsonIgnore] public Element? Reference => FindElement(ElementKind.Reference);
    [JsonIgnore] public Element? SongTitle => FindElement(ElementKind.SongTitle);
    [JsonIgnore] public List<Element> Decorations => Elements.Where(element => element.Kind == ElementKind.Decoration).ToList();

    // ── Переведення в стиль слайда ──────────────────────────────────────────

    /// Накладає шаблон на готовий стиль (`slideStyle(base:designHeight:variant:backgroundPath:)`).
    ///
    /// Шрифти, кегль та інтерліньяж лишаються від `baseStyle` (стиль з ini).
    /// Міняються кольори, обведення, тінь, поля, виключка і характер зміни
    /// слайда. Товщину обведення і розмиття тіні ділимо на висоту слайда, під
    /// який їх добирали, — так само, як `SlideStyle(config:…)`.
    public SlideStyle ToSlideStyle(SlideStyle? baseStyle = null, double designHeight = 600,
                                   Variant variant = Variant.Single, string? backgroundPath = null)
    {
        var source = baseStyle ?? new SlideStyle();
        var style = source;
        style.Name = Name;

        var height = Math.Max(designHeight, 1);
        var outline = OutlineEnabled ? OutlineWidth / height : 0;
        var shadow = ShadowEnabled ? ShadowBlur / height : 0;

        var mainColor = Quote?.TextColor ?? source.Main.Color;
        style.Main.Color = mainColor;
        style.Main.OutlineColor = OutlineColor;
        style.Main.OutlineWidth = outline;
        style.Main.ShadowRadius = shadow;

        // Свого кольору в другого перекладу в шаблонах немає жодного — оригінал
        // малює його тим самим кольором, що й Цитату.
        style.Secondary.Color = SecondQuote?.TextColor ?? mainColor;
        style.Secondary.OutlineColor = OutlineColor;
        style.Secondary.OutlineWidth = outline;
        style.Secondary.ShadowRadius = shadow;

        style.Reference.Color = Reference?.TextColor ?? source.Reference.Color;
        style.Reference.OutlineColor = OutlineColor;
        style.Reference.OutlineWidth = outline;
        style.Reference.ShadowRadius = shadow;

        if (backgroundPath != null) style.BackgroundImagePath = backgroundPath;

        if (Quote?.PlacementFor(variant) is { } placement)
        {
            var box = placement.Box;
            // Поля по ближній стороні: рамка буває зміщена, а відступ у нас один
            // на обидві сторони — хай текст краще не вилізе.
            style.HorizontalInset = Math.Min(Math.Max(Math.Min(box.X, 1 - box.MaxX), 0), 0.45);
            style.VerticalInset = Math.Min(Math.Max(Math.Min(box.Y, 1 - box.MaxY), 0), 0.45);
            style.VerticalAlign = VerticalAlignmentOf(placement);
        }

        if (Quote?.SceneFor(variant) is { } scene)
        {
            style.TransitionKind = TransitionFor(scene);
            // Поріг той самий, що й у стилю з ini: 200 мс тут читаються ривком.
            if (style.TransitionKind != SlideStyle.Transition.None) style.TransitionDuration = Math.Max(0.25, scene.Duration);
        }
        return style;
    }

    /// Куди притиснуто текст Цитати: у високої рамки слухаємо `Layout`, а у
    /// помітно зміщеної — її власну середину.
    internal static SlideStyle.VerticalAlignment VerticalAlignmentOf(Placement placement)
    {
        var box = placement.Box;
        if (box.Height >= 0.8 && placement.TextLayout is { } layout)
        {
            return layout switch
            {
                TextLayout.Top => SlideStyle.VerticalAlignment.Top,
                TextLayout.Center => SlideStyle.VerticalAlignment.Center,
                _ => SlideStyle.VerticalAlignment.Bottom,
            };
        }
        if (Math.Abs(box.MidY - 0.5) <= 0.08) return SlideStyle.VerticalAlignment.Center;
        return box.MidY < 0.5 ? SlideStyle.VerticalAlignment.Top : SlideStyle.VerticalAlignment.Bottom;
    }

    /// Як шаблон уводить текст на слайд: масштаб — наплив, зсув — зсув,
    /// решта — розчинення.
    internal static SlideStyle.Transition TransitionFor(Scene scene)
    {
        if (!scene.IsAnimated || scene.Fx == 0) return SlideStyle.Transition.None;
        if (scene.IsScaling) return SlideStyle.Transition.Zoom;
        if (scene.IsMoving) return scene.MovesHorizontally ? SlideStyle.Transition.SlideLeft : SlideStyle.Transition.SlideUp;
        return SlideStyle.Transition.Fade;
    }

    /// Глибока копія (у Swift — присвоєння значення).
    public SlideScheme Copy() => new(Name, BackgroundImageName, OutlineEnabled, OutlineWidth, OutlineColor,
                                     ShadowEnabled, ShadowOffset, ShadowBlur, ShadowOpacity, ShadowColor,
                                     new List<string>(PresetNames), Elements.Select(e => e.Copy()).ToList(),
                                     new Dictionary<string, string>(Attributes));
}
