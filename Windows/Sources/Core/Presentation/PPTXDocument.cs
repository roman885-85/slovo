// =============================================================================
//  PPTXDocument.cs — розбір презентації PowerPoint (з Presentation/PPTXDocument.swift)
// =============================================================================
//  XMLDocument + XPath Foundation → System.Xml (XmlDocument + XPath, ті самі
//  вирази `local-name()`); CGColor → SlideStyle.RGBA; CGRect/CGSize → RectD/SizeD;
//  перелік Swift `Fill` з прив'язаними значеннями → записи Fill.None/Solid/
//  Texture/Picture/GradientCase; `Gradient.Kind` → GradientKind.
//  Чи встановлено шрифт теми — питаємо SkiaSharp (на Mac — CoreText).
// =============================================================================

using System.Globalization;
using System.Xml;
using SkiaSharp;

namespace Slovo.Core;

/// Розбір презентації PowerPoint (`.pptx`) — свій, без чужих бібліотек.
///
/// Формат відкритий: ECMA-376 OOXML. Файл — це архів ZIP, усередині XML на
/// кожен слайд, на кожну розмітку і на зразок, плюс тека `ppt/media` з
/// картинками. Ми читаємо рівно те, з чого складається вигляд слайда на екрані:
/// розмір полотна, фон, картинки і написи з їхнім місцем, кеглем і кольором.
///
/// Чого тут немає — і це сказано чесно: переходу кольору у фоні слайда й
/// в обведенні (у заливці фігур він є), таблиць, діаграм, тіні й об'єму, анімації всередині слайда. Для проповіді з
/// текстом на картинці цього не потрібно; якщо знадобиться — доберемо по одному,
/// а не будемо обіцяти «повну сумісність», якої не буває.
///
/// Одиниця довжини в OOXML — EMU: 914 400 на дюйм, 12 700 на пункт. Усе, що
/// приходить із файла, переводиться в частки полотна, і далі слайд малюється в
/// будь-якому розмірі: і в передпоказ, і на проектор, і в трансляцію.
public sealed class PPTXDocument
{
    public sealed class Failure : Exception
    {
        internal Failure(string text) : base(text) { }
        public override string ToString() => Message;
    }

    /// Один слайд: фон і те, що на ньому стоїть.
    public sealed record Slide(Fill Background, IReadOnlyList<Shape> Shapes);

    /// Дуотон текстури: темні пікселі → перший колір, світлі → другий.
    public readonly record struct Duotone(SlideStyle.RGBA Dark, SlideStyle.RGBA Light);

    public abstract record Fill
    {
        private Fill() { }

        public static readonly Fill None = new NoneCase();

        public sealed record NoneCase : Fill;
        public sealed record Solid(SlideStyle.RGBA Color) : Fill;
        /// Текстура зі стилю фону теми (`bgFillStyleLst`): замощена (`tile`
        /// з масштабом у частках) або розтягнута, часто з дуотоном у колір
        /// фону. Так зроблено фон у темах «Твердий переплет», «Пергамент».
        public sealed record Texture(string Part, double? TileScale, Duotone? Duotone) : Fill;
        /// Ім'я частини архіву з картинкою — її дістає сам документ.
        public sealed record Picture(string Part) : Fill;
        /// Перехід кольору (`gradFill`). Ним у темах роблять «пергамент»:
        /// прямокутник зразка на весь слайд, прозорий посередині й кремовий
        /// по краях. Без нього слайд лишався рівним сірим аркушем — власник:
        /// «сторінка має вигляд пергаменту, а в програмі просто білий лист».
        public sealed record GradientCase(Gradient Gradient) : Fill;
    }

    public abstract record GradientKind
    {
        private GradientKind() { }

        /// Прямий перехід; кут у градусах за стрілкою годинника від «вправо».
        public sealed record Linear(double Angle) : GradientKind;
        /// Від прямокутника-осердя (у частках фігури) до її країв —
        /// `path="rect"`; рамка картини.
        public sealed record Rectangular(RectD Focus) : GradientKind;
        /// Колами від осердя — `path="circle"`.
        public sealed record Radial(RectD Focus) : GradientKind;
    }

    /// Місце зупинки (0…1, від осердя чи початку) і її колір із прозорістю.
    public readonly record struct GradientStop(double Position, SlideStyle.RGBA Color);

    public sealed record Gradient(IReadOnlyList<GradientStop> Stops, GradientKind Kind);

    /// Форма фігури. У презентаціях проповідей трапляються рівно ці:
    /// прямокутник, заокруглений прямокутник, овал і лінія.
    public enum Outline { Rectangle, RoundedRectangle, Ellipse, Line }

    /// Тінь — `<a:outerShdw>`: зсув і розмиття в частках висоти полотна,
    /// колір із прозорістю. Буває у фігури й картинки (своя або зі стилю
    /// теми через `effectRef`) і в тексту (своя в `rPr` або успадкована зі
    /// стилів заповнювача в розмітці чи зразку). Власник: «відсутні ефекти
    /// (немає тіней)».
    public readonly record struct Shadow(SizeD Offset, double Blur, SlideStyle.RGBA Color);

    /// Обрізка картинки частками її власного розміру — `<a:srcRect>`.
    /// У презентаціях так вставляють шматок фотографії, і без обрізки на слайд
    /// потрапляє вся картинка цілком, а потрібен був куток.
    public readonly record struct Crop(double Left, double Top, double Right, double Bottom)
    {
        public bool IsEmpty => Left == 0 && Top == 0 && Right == 0 && Bottom == 0;
    }

    public sealed class Shape
    {
        /// Місце і розмір у частках полотна, 0…1.
        public RectD Frame;
        public Fill Fill = Fill.None;
        /// Обведення: колір і товщина в частках висоти полотна. Ним у презентаціях
        /// обводять слово в тексті — без нього кружечок перетворювався на залитий
        /// прямокутник поверх рядка.
        public SlideStyle.RGBA? StrokeColor;
        public double StrokeWidth;
        public Outline Outline;
        public List<Paragraph> Paragraphs = new();
        /// Поворот у градусах — у написів на фотографіях він трапляється.
        public double Rotation;
        /// Віддзеркалення по горизонталі і по вертикалі.
        public bool FlipH;
        public bool FlipV;
        /// Обрізка картинки.
        public Crop Crop;
        /// Куди притиснуто текст: `top`, `center`, `bottom`. У PowerPoint за
        /// умовчанням верх — притискати все до середини означало б рухати
        /// заголовки вниз на кожному слайді.
        public string Anchor = "top";
        /// У скільки PowerPoint сам стиснув текст (`normAutofit fontScale`).
        /// Він уже порахував це при верстці — рахувати заново означає розійтися
        /// з тим, що людина бачила, коли робила слайд.
        public double FontScale = 1;
        /// `normal` — PowerPoint стискає текст під рамку (`normAutofit`);
        /// `shape` — росте рамка (`spAutoFit`); `none` — текст виходить за
        /// рамку як є (`noAutofit` або нічого не сказано). Стискати самим
        /// можна лише в першому випадку: у решті PowerPoint не стискає.
        public string Autofit = "none";
        /// Тінь самої фігури або картинки.
        public Shadow? Shadow;
        /// Тінь тексту в ній.
        public Shadow? TextShadow;
    }

    public sealed class Paragraph
    {
        public List<Run> Runs = new();
        /// `left`, `center`, `right`, `justify`.
        public string Alignment = "left";
        /// Відступ рівня списку, в частках ширини полотна.
        public double Indent;
        /// Маркер списку, якщо він є.
        public string? Bullet;
        /// Лівий відступ тексту (`marL`) і відступ першого рядка від нього
        /// (`indent`, у маркованому списку від'ємний) — у пунктах слайда.
        public double MarginLeft;
        public double FirstIndent;
        /// Шрифт маркера (`buFont`; `null` — шрифт тексту), його колір і
        /// кегль у частках кеглю тексту (`buSzPct`).
        public string? BulletFont;
        public SlideStyle.RGBA? BulletColor;
        public double? BulletSize;
    }

    public sealed record Run(string Text, double Size, bool IsBold, bool IsItalic, bool IsUnderlined,
                             SlideStyle.RGBA Color, string? FontName);
    // Size — кегль у пунктах при полотні в його власний розмір.

    // ── Стан ────────────────────────────────────────────────────────────────

    private readonly ZipParts.Reader archive;
    /// Розмір полотна в EMU — за ним усе переводиться в частки.
    public SizeD CanvasSize { get; }
    /// Слайди в тому порядку, в якому вони йдуть у презентації.
    public IReadOnlyList<Slide> Slides { get; }
    /// Імена частин зі слайдами — потрібні для повідомлень і перевірки.
    public IReadOnlyList<string> SlideParts { get; }

    public int Count => Slides.Count;

    /// Кольори теми: `schemeClr` посилається на них за іменем.
    private readonly Dictionary<string, SlideStyle.RGBA> theme;
    /// Шрифти теми: «+mj-lt» (заголовки) і «+mn-lt» (текст) — це не імена
    /// шрифтів, а посилання сюди.
    private readonly (string? Major, string? Minor) themeFonts;
    /// Стилі тексту презентації за умовчанням (`defaultTextStyle`) — останнє,
    /// звідки напис бере кегль і колір, якщо ніхто ближчий їх не назвав.
    private readonly XmlElement? defaultTextStyle;
    /// Стилі фону теми (`bgFillStyleLst`), частина теми і її зв'язки — щоб
    /// `<p:bgRef idx="1002">` дійшов до текстури.
    private readonly List<XmlElement> themeBackgroundStyles;
    private readonly string themePart;
    private readonly Dictionary<string, string> themeRelations;
    /// Стилі ефектів теми — на них фігура посилається через `effectRef idx`
    /// (1…3; 0 — без ефекту).
    private readonly List<Shadow?> themeEffects;

    // ── Відкриття ───────────────────────────────────────────────────────────

    /// `PPTXDocument(fileAt:)`.
    public PPTXDocument(string path)
    {
        try
        {
            archive = ZipParts.Open(path);
        }
        catch (Exception error)
        {
            throw new Failure(OurWords.T("не открылся архив презентации: %s", error.Message));
        }
        if (!archive.Contains("ppt/presentation.xml"))
            throw new Failure(OurWords.T("это не презентация PowerPoint — внутри нет ppt/presentation.xml"));

        if (Text("ppt/presentation.xml") is not { } presentationXML || ParseXml(presentationXML) is not { } presentation)
            throw new Failure(OurWords.T("не разобрать ppt/presentation.xml"));

        // Розмір полотна. За умовчанням 4:3 — так робить і сам PowerPoint,
        // коли розмір не записано.
        double width = 9_144_000.0, height = 6_858_000.0;
        if (First(presentation, "//*[local-name()='sldSz']") is { } size)
        {
            width = SwiftText.ParseDouble(Attr(size, "cx") ?? "") ?? width;
            height = SwiftText.ParseDouble(Attr(size, "cy") ?? "") ?? height;
        }
        CanvasSize = new SizeD(width, height);

        var relations = Relations("ppt/presentation.xml", archive);
        var parts = new List<string>();
        foreach (var element in All(presentation, "//*[local-name()='sldId']"))
        {
            var id = element.GetAttributeNode("id", RelationshipNamespace)?.Value
                     ?? element.Attributes.Cast<XmlAttribute>().FirstOrDefault(a => a.Name.EndsWith("id", StringComparison.Ordinal) && a.Name != "id")?.Value;
            if (id == null || !relations.TryGetValue(id, out var target)) continue;
            parts.Add(Resolve(target, "ppt/presentation.xml"));
        }
        // Порядку немає — беремо всі слайди за іменами: краще показати в порядку
        // імен, ніж не показати зовсім.
        if (parts.Count == 0)
        {
            parts = archive.Names
                .Where(name => name.StartsWith("ppt/slides/slide", StringComparison.Ordinal) && name.EndsWith(".xml", StringComparison.Ordinal))
                .OrderBy(SlideNumber)
                .ToList();
        }
        SlideParts = parts;
        if (parts.Count == 0) throw new Failure(OurWords.T("в презентации нет ни одного слайда"));

        theme = ReadTheme(archive);
        themeFonts = ReadThemeFonts(archive);
        defaultTextStyle = First(presentation, "//*[local-name()='defaultTextStyle']");
        themeEffects = ReadThemeEffects(archive, theme);
        (themePart, themeBackgroundStyles, themeRelations) = ReadThemeBackgrounds(archive);
        Slides = parts.Select(ReadSlide).ToList();
    }

    private string? Text(string part)
    {
        try { return archive.Text(part); }
        catch (ZipParts.Failure) { return null; }
    }

    /// Картинка частини архіву — її просить малювання.
    public SKBitmap? Image(string part)
    {
        byte[]? bytes;
        try { bytes = archive.Part(part); }
        catch (ZipParts.Failure) { return null; }
        if (bytes == null) return null;
        try { return SKBitmap.Decode(bytes); }
        catch (Exception) { return null; }
    }

    // ── Розбір одного слайда ────────────────────────────────────────────────

    private Slide ReadSlide(string part)
    {
        if (Text(part) is not { } xml || ParseXml(xml)?.DocumentElement is not { } root) return new Slide(Fill.None, Array.Empty<Shape>());
        var relations = Relations(part, archive);

        // Розмітка і зразок: із них беруться і фон, і місце заповнювачів.
        var layoutPart = relations.Values.FirstOrDefault(target => target.Contains("slideLayout", StringComparison.Ordinal)) is { } layoutTarget
            ? Resolve(layoutTarget, part) : null;
        (XmlElement Root, Dictionary<string, string> Relations, string Part)? layout = null;
        if (layoutPart != null && Text(layoutPart) is { } layoutText && ParseXml(layoutText)?.DocumentElement is { } layoutRoot)
            layout = (layoutRoot, Relations(layoutPart, archive), layoutPart);
        string? masterPart = null;
        if (layout is { } foundLayout && foundLayout.Relations.Values.FirstOrDefault(target => target.Contains("slideMaster", StringComparison.Ordinal)) is { } masterTarget)
            masterPart = Resolve(masterTarget, foundLayout.Part);
        (XmlElement Root, Dictionary<string, string> Relations, string Part)? master = null;
        if (masterPart != null && Text(masterPart) is { } masterText && ParseXml(masterText)?.DocumentElement is { } masterRoot)
            master = (masterRoot, Relations(masterPart, archive), masterPart);

        // Фон: свій у слайда, інакше розмітки, інакше зразка.
        var background = BackgroundFill(root, relations, part)
                         ?? (layout is { } l ? BackgroundFill(l.Root, l.Relations, l.Part) : null)
                         ?? (master is { } m ? BackgroundFill(m.Root, m.Relations, m.Part) : null)
                         ?? Fill.None;

        var shapes = new List<Shape>();
        // Прикраси зразка й розмітки — лінії, орнаменти, емблеми — стоять під
        // усім, що на слайді. Заповнювачі звідти не малюються: це лише місця
        // для тексту слайда. Слайд може вимкнути їх (`showMasterSp="0"`).
        var showsMaster = Attr(root, "showMasterSp") != "0";
        if (showsMaster)
        {
            foreach (var source in new[] { master, layout })
            {
                if (source is not { } found || First(found.Root, ".//*[local-name()='spTree']") is not { } tree) continue;
                Collect(tree, shapes, found.Relations, found.Part, null, null, null, decorationsOnly: true);
            }
        }
        if (First(root, ".//*[local-name()='spTree']") is { } slideTree)
            Collect(slideTree, shapes, relations, part, layout?.Root, master?.Root, null);
        return new Slide(background, shapes);
    }

    /// Перерахунок місця всередині групи.
    ///
    /// У групи своя система координат: `<a:chOff>` і `<a:chExt>` кажуть, у
    /// яких числах записано дітей, а `<a:off>` і `<a:ext>` — куди цю групу
    /// поставлено на слайді. Без перерахунку фігури з групи їдуть за край:
    /// їхні числа стосуються іншої сітки.
    private readonly record struct GroupTransform(double ChildX, double ChildY, double ChildWidth, double ChildHeight,
                                                  double PlacedX, double PlacedY, double PlacedWidth, double PlacedHeight)
    {
        public RectD Apply(RectD box)
        {
            var scaleX = ChildWidth > 0 ? PlacedWidth / ChildWidth : 1;
            var scaleY = ChildHeight > 0 ? PlacedHeight / ChildHeight : 1;
            return new RectD(PlacedX + (box.X - ChildX) * scaleX, PlacedY + (box.Y - ChildY) * scaleY,
                             box.Width * scaleX, box.Height * scaleY);
        }
    }

    /// `decorationsOnly` — зі зразка чи розмітки: беремо лише те, що не є
    /// заповнювачем.
    private void Collect(XmlElement tree, List<Shape> shapes, Dictionary<string, string> relations, string part,
                         XmlElement? layout, XmlElement? master, GroupTransform? transform, bool decorationsOnly = false)
    {
        foreach (var element in tree.ChildNodes.OfType<XmlElement>())
        {
            var local = element.LocalName;
            // Схована фігура (`<p:cNvPr hidden="1"/>`) у PowerPoint не показується.
            if (Attribute(element, ".//*[local-name()='cNvPr']", "hidden") == "1") continue;
            if (decorationsOnly && local != "grpSp" && Placeholder(element) != null) continue;
            switch (local)
            {
                case "sp":
                case "pic":
                case "cxnSp":
                    if (ReadShape(element, relations, part, layout, master) is { } shape)
                    {
                        if (transform is { } group)
                        {
                            // Місце фігури вже переведено в частки полотна — повернемо
                            // його в EMU, перерахуємо і переведемо назад.
                            var emu = new RectD(shape.Frame.X * CanvasSize.Width, shape.Frame.Y * CanvasSize.Height,
                                                shape.Frame.Width * CanvasSize.Width, shape.Frame.Height * CanvasSize.Height);
                            var moved = group.Apply(emu);
                            shape.Frame = new RectD(moved.X / CanvasSize.Width, moved.Y / CanvasSize.Height,
                                                    moved.Width / CanvasSize.Width, moved.Height / CanvasSize.Height);
                        }
                        shapes.Add(shape);
                    }
                    break;
                case "grpSp":
                {
                    var inner = transform;
                    if (First(element, "./*[local-name()='grpSpPr']/*[local-name()='xfrm']") is { } xfrm
                        && First(xfrm, "./*[local-name()='off']") is { } off
                        && First(xfrm, "./*[local-name()='ext']") is { } ext
                        && First(xfrm, "./*[local-name()='chOff']") is { } chOff
                        && First(xfrm, "./*[local-name()='chExt']") is { } chExt)
                    {
                        static double Value(XmlElement node, string key) => SwiftText.ParseDouble(Attr(node, key) ?? "") ?? 0;
                        var placed = new RectD(Value(off, "x"), Value(off, "y"), Value(ext, "cx"), Value(ext, "cy"));
                        if (transform is { } outer) placed = outer.Apply(placed);
                        inner = new GroupTransform(Value(chOff, "x"), Value(chOff, "y"), Value(chExt, "cx"), Value(chExt, "cy"),
                                                   placed.X, placed.Y, placed.Width, placed.Height);
                    }
                    Collect(element, shapes, relations, part, layout, master, inner, decorationsOnly);
                    break;
                }
            }
        }
    }

    private Shape? ReadShape(XmlElement element, Dictionary<string, string> relations, string part,
                             XmlElement? layout, XmlElement? master)
    {
        // Місце: своє, а в заповнювача — з розмітки або зразка.
        var box = FrameIn(element);
        if (box == null && Placeholder(element) is { } placeholder)
            box = PlaceholderFrame(placeholder, layout) ?? PlaceholderFrame(placeholder, master);
        if (box is not { } found) return null;

        var rect = new RectD(found.X / CanvasSize.Width, found.Y / CanvasSize.Height,
                             found.Width / CanvasSize.Width, found.Height / CanvasSize.Height);
        if (!(rect.Width > 0) || !(rect.Height > 0)) return null;

        // Властивості фігури. Заливку і обведення беремо ЛИШЕ звідси і лише
        // прямими дітьми: колір обведення лежить усередині `<a:ln>`, і пошук «десь
        // усередині» фарбував ним усю фігуру — кружечок навколо слова перетворювався на
        // залитий прямокутник поверх рядка.
        var properties = First(element, "./*[local-name()='spPr']");

        var shapeFill = Fill.None;
        if (First(element, ".//*[local-name()='blipFill']/*[local-name()='blip']") is { } blip
            && EmbedID(blip) is { } blipId && relations.TryGetValue(blipId, out var blipTarget))
            shapeFill = new Fill.Picture(Resolve(blipTarget, part));
        else if (properties != null && HasDirect(properties, "noFill"))
            shapeFill = Fill.None;
        else if (properties != null && DirectColor(properties, theme) is { } solid)
            shapeFill = new Fill.Solid(solid);
        else if (properties != null && GradientIn(properties, theme) is { } gradient)
            shapeFill = new Fill.GradientCase(gradient);

        SlideStyle.RGBA? strokeColor = null;
        var strokeWidth = 0.0;
        if (properties != null && First(properties, "./*[local-name()='ln']") is { } line && !HasDirect(line, "noFill"))
        {
            strokeColor = DirectColor(line, theme);
            // Товщина в EMU; нуль означає «тонка лінія», а не «немає лінії».
            var emu = SwiftText.ParseDouble(Attr(line, "w") ?? "") ?? 9525;
            strokeWidth = emu / CanvasSize.Height;
            if (strokeColor == null) strokeWidth = 0;
        }

        var outline = (Attribute(element, "./*[local-name()='spPr']/*[local-name()='prstGeom']", "prst") ?? "rect") switch
        {
            "ellipse" or "circle" => Outline.Ellipse,
            "roundRect" => Outline.RoundedRectangle,
            "line" or "straightConnector1" => Outline.Line,
            _ => Outline.Rectangle,
        };

        var xfrm = First(element, ".//*[local-name()='xfrm']");
        var rotation = SwiftText.ParseDouble(Attr(xfrm, "rot") ?? "0") is { } rot ? rot / 60_000 : 0;
        var flipH = Attr(xfrm, "flipH") == "1";
        var flipV = Attr(xfrm, "flipV") == "1";

        var crop = new Crop(0, 0, 0, 0);
        if (First(element, ".//*[local-name()='srcRect']") is { } source)
        {
            double Part(string name) => (SwiftText.ParseDouble(Attr(source, name) ?? "") ?? 0) / 100_000;
            crop = new Crop(Part("l"), Part("t"), Part("r"), Part("b"));
        }

        var body = First(element, ".//*[local-name()='bodyPr']");
        // Куди притиснуто текст, заповнювач успадковує: у слайді `bodyPr`
        // здебільшого порожній, а «посередині» сказано в розмітці чи зразку.
        // Без цього заголовок сідав на верх рамки, вище, ніж у PowerPoint.
        var anchorValue = Attr(body, "anchor");
        if (anchorValue == null && Placeholder(element) is { } wanted)
        {
            foreach (var root in new[] { layout, master })
            {
                if (root == null || PlaceholderElement(wanted, root) is not { } twin) continue;
                if (Attribute(twin, ".//*[local-name()='bodyPr']", "anchor") is { } anchorFound)
                {
                    anchorValue = anchorFound;
                    break;
                }
            }
        }
        var anchor = anchorValue switch
        {
            "ctr" => "center",
            "b" => "bottom",
            _ => "top",
        };
        // PowerPoint уже порахував, у скільки стиснути текст, щоб він уліз, —
        // беремо його число, а не своє: людина бачила саме такий слайд.
        var autofit = body != null ? First(body, "./*[local-name()='normAutofit']") : null;
        var scale = SwiftText.ParseDouble(Attr(autofit, "fontScale") ?? "") is { } fontScale ? fontScale / 100_000 : 1;
        string autofitMode;
        if (autofit != null) autofitMode = "normal";
        else if (body != null && Has(body, "spAutoFit")) autofitMode = "shape";
        else autofitMode = "none";

        // Тінь фігури: своя в `spPr/effectLst`, інакше зі стилю теми.
        Shadow? shadow = null;
        if (properties != null && First(properties, "./*[local-name()='effectLst']") is { } own)
            shadow = ShadowIn(own, theme);
        else if (SwiftText.ParseInt(Attribute(element, "./*[local-name()='style']/*[local-name()='effectRef']", "idx")) is { } index
                 && index >= 1 && index - 1 < themeEffects.Count)
            shadow = themeEffects[index - 1];

        return new Shape
        {
            Frame = rect,
            Fill = shapeFill,
            StrokeColor = strokeColor,
            StrokeWidth = strokeWidth,
            Outline = outline,
            Paragraphs = ParagraphsIn(element, layout, master),
            Rotation = rotation,
            FlipH = flipH,
            FlipV = flipV,
            Crop = crop,
            Anchor = anchor,
            FontScale = Math.Max(0.1, Math.Min(1, scale)),
            Autofit = autofitMode,
            Shadow = shadow,
            TextShadow = TextShadowOf(element, layout, master),
        };
    }

    // ── Тіні ────────────────────────────────────────────────────────────────

    /// Тінь тексту фігури.
    ///
    /// Своя — у `rPr` будь-якого шматка або в `defRPr` абзацу чи `lstStyle`
    /// напису. Далі — успадкована: заповнювач розмітки з тим самим типом чи
    /// номером, заповнювач зразка, і нарешті загальні стилі тексту зразка
    /// (`titleStyle`, `bodyStyle`). Саме там у більшості шаблонів і лежить
    /// тінь заголовка.
    private Shadow? TextShadowOf(XmlElement element, XmlElement? layout, XmlElement? master)
    {
        if (First(element, "./*[local-name()='txBody']") is { } body && FirstShadow(body, theme) is { } found) return found;
        if (Placeholder(element) is not { } wanted) return null;
        foreach (var root in new[] { layout, master })
        {
            if (root == null || PlaceholderElement(wanted, root) is not { } twin
                || First(twin, "./*[local-name()='txBody']") is not { } twinBody) continue;
            if (FirstShadow(twinBody, theme) is { } inherited) return inherited;
        }
        if (master == null) return null;
        var styleName = StyleName(wanted.Type);
        if (First(master, $".//*[local-name()='txStyles']/*[local-name()='{styleName}']") is { } styles)
            return FirstShadow(styles, theme);
        return null;
    }

    private static string StyleName(string type) => type switch
    {
        "title" or "ctrTitle" => "titleStyle",
        "body" or "subTitle" or "obj" => "bodyStyle",
        _ => "otherStyle",
    };

    /// Звідки абзаци фігури успадковують властивості рівнів (`lvlNpPr`):
    /// свій `lstStyle`, заповнювач-двійник у розмітці й зразку, стиль зразка.
    private static List<XmlElement> LevelStyles(XmlElement element, XmlElement? layout, XmlElement? master)
    {
        var roots = new List<XmlElement>();
        if (First(element, "./*[local-name()='txBody']/*[local-name()='lstStyle']") is { } own) roots.Add(own);
        if (Placeholder(element) is not { } wanted) return roots;
        foreach (var root in new[] { layout, master })
        {
            if (root == null || PlaceholderElement(wanted, root) is not { } twin
                || First(twin, "./*[local-name()='txBody']/*[local-name()='lstStyle']") is not { } list) continue;
            roots.Add(list);
        }
        if (master != null && First(master, $".//*[local-name()='txStyles']/*[local-name()='{StyleName(wanted.Type)}']") is { } styles)
            roots.Add(styles);
        return roots;
    }

    /// Номер автонумерації в тому вигляді, який просить `buAutoNum type`.
    private static string Numbered(int number, string type)
    {
        var alpha = ((char)(96 + Math.Max(1, Math.Min(26, number)))).ToString();
        (int Value, string Mark)[] table =
            [(1000, "m"), (900, "cm"), (500, "d"), (400, "cd"), (100, "c"), (90, "xc"), (50, "l"), (40, "xl"), (10, "x"), (9, "ix"), (5, "v"), (4, "iv"), (1, "i")];
        var left = Math.Max(1, number);
        var roman = new System.Text.StringBuilder();
        foreach (var (value, mark) in table)
            while (left >= value)
            {
                roman.Append(mark);
                left -= value;
            }
        var digits = number.ToString(CultureInfo.InvariantCulture);
        return type switch
        {
            "arabicParenR" => digits + ")",
            "arabicParenBoth" => "(" + digits + ")",
            "arabicPlain" => digits,
            "alphaLcPeriod" => alpha + ".",
            "alphaUcPeriod" => alpha.ToUpperInvariant() + ".",
            "alphaLcParenR" => alpha + ")",
            "alphaUcParenR" => alpha.ToUpperInvariant() + ")",
            "romanLcPeriod" => roman + ".",
            "romanUcPeriod" => roman.ToString().ToUpperInvariant() + ".",
            _ => digits + ".",
        };
    }

    /// Чи є в елемента прямий нащадок із таким іменем (без простору імен).
    private static bool Has(XmlElement element, string name) => First(element, $"./*[local-name()='{name}']") != null;

    private static Shadow? FirstShadow(XmlElement root, Dictionary<string, SlideStyle.RGBA> theme) =>
        First(root, ".//*[local-name()='effectLst']") is { } list ? ShadowIn(list, theme) : null;

    /// Заповнювач розмітки або зразка з тим самим номером чи типом.
    private static XmlElement? PlaceholderElement((string Type, string Index) wanted, XmlElement root)
    {
        XmlElement? byType = null;
        foreach (var shape in All(root, ".//*[local-name()='sp']"))
        {
            if (Placeholder(shape) is not { } found) continue;
            if (wanted.Index.Length > 0 && found.Index == wanted.Index) return shape;
            if (byType == null && found.Type == wanted.Type) byType = shape;
        }
        return byType;
    }

    /// `<a:effectLst>` → тінь, якщо в ньому є `<a:outerShdw>`.
    private static Shadow? ShadowIn(XmlElement list, Dictionary<string, SlideStyle.RGBA> theme)
    {
        if (First(list, "./*[local-name()='outerShdw']") is not { } outer) return null;
        double Number(string name, double fallback) => SwiftText.ParseDouble(Attr(outer, name) ?? "") ?? fallback;
        // Відстань і розмиття — в EMU; кут — у 60 000-х градуса, за стрілкою
        // годинника від напрямку «вправо» (90° — униз).
        var distance = Number("dist", 0);
        var blur = Number("blurRad", 0);
        var angle = Number("dir", 5_400_000) / 60_000 * Math.PI / 180;
        // Висота полотна в EMU: слайд PowerPoint — 6 858 000 EMU (7,5 дюйма).
        const double unit = 6_858_000.0;
        var color = new SlideStyle.RGBA(0, 0, 0, 0.5);
        if (ColorOf(outer, theme) is { } baseColor)
        {
            var alpha = 1.0;
            if (First(outer, ".//*[local-name()='alpha']") is { } node && SwiftText.ParseDouble(Attr(node, "val") ?? "") is { } value)
                alpha = value / 100_000;
            color = baseColor with { Alpha = alpha };
        }
        return new Shadow(new SizeD(Math.Cos(angle) * distance / unit, Math.Sin(angle) * distance / unit), blur / unit, color);
    }

    private static List<Shadow?> ReadThemeEffects(ZipParts.Reader archive, Dictionary<string, SlideStyle.RGBA> theme)
    {
        if (ThemePartName(archive) is not { } part || TextOf(archive, part) is not { } xml || ParseXml(xml)?.DocumentElement is not { } root
            || First(root, ".//*[local-name()='effectStyleLst']") is not { } list) return new List<Shadow?>();
        return All(list, "./*[local-name()='effectStyle']")
            .Select(style => First(style, "./*[local-name()='effectLst']") is { } effects ? ShadowIn(effects, theme) : null)
            .ToList();
    }

    private List<Paragraph> ParagraphsIn(XmlElement element, XmlElement? layout = null, XmlElement? master = null)
    {
        var result = new List<Paragraph>();
        // Властивості рівнів списку, звідки абзац успадковує маркер і відступи:
        // свій `lstStyle`, той самий заповнювач у розмітці й зразку, стилі
        // зразка. Доти брався лише `pPr` самого абзацу, і маркери, задані
        // рівнем, пропадали.
        var inherited = LevelStyles(element, layout, master);
        if (defaultTextStyle != null) inherited.Add(defaultTextStyle);
        var numbering = new Dictionary<int, int>();
        foreach (var paragraph in All(element, ".//*[local-name()='txBody']/*[local-name()='p']"))
        {
            var properties = First(paragraph, "./*[local-name()='pPr']");
            var levelNumber = SwiftText.ParseInt(Attr(properties, "lvl") ?? "0") ?? 0;
            var level = (double)levelNumber;
            // Ланцюжок: свій pPr, далі lvlNpPr звідусіль, де він є.
            var chain = new List<XmlElement>();
            if (properties != null) chain.Add(properties);
            foreach (var root in inherited)
                if (First(root, $"./*[local-name()='lvl{levelNumber + 1}pPr']") is { } found) chain.Add(found);
            double? Attribute(string name)
            {
                foreach (var item in chain)
                    if (Attr(item, name) is { } value && SwiftText.ParseDouble(value) is { } number) return number;
                return null;
            }
            // Вирівнювання — теж за ланцюжком: заголовок «посередині» сказано
            // в стилі зразка, а не в кожному абзаці.
            var alignment = chain.Select(item => Attr(item, "algn")).FirstOrDefault(value => value != null) switch
            {
                "ctr" => "center",
                "r" => "right",
                "just" => "justify",
                _ => "left",
            };
            // Властивості літер за умовчанням (`defRPr`) з того ж ланцюжка.
            // Доти кегль брався лише з самого шматка тексту, а коли його там
            // не було — ставало 18 пунктів. У презентаціях же кегль часто
            // названо один раз, у стилі напису (54 пункти), і весь текст
            // виходив утричі дрібнішим — власник: «сторінка має великий
            // шрифт, а на виході дрібні літери, які важко прочитати».
            var defaults = chain.Select(item => First(item, "./*[local-name()='defRPr']")).Where(item => item != null).Select(item => item!).ToList();
            string? InheritedText(string name) => defaults.Select(item => Attr(item, name)).FirstOrDefault(value => value != null);
            // Маркер: перший у ланцюжку, хто щось про нього каже — `buNone`,
            // `buChar` чи `buAutoNum`; шрифт і колір маркера — так само.
            string? bullet = null;
            string? bulletFont = null;
            SlideStyle.RGBA? bulletColor = null;
            double? bulletSize = null;
            foreach (var item in chain)
            {
                if (Has(item, "buNone")) break;
                if (First(item, "./*[local-name()='buChar']") is { } mark && Attr(mark, "char") is { } character)
                {
                    bullet = character;
                    break;
                }
                if (First(item, "./*[local-name()='buAutoNum']") is { } auto)
                {
                    var start = SwiftText.ParseInt(Attr(auto, "startAt") ?? "") ?? 1;
                    var number = numbering.TryGetValue(levelNumber, out var current) ? current : start;
                    numbering[levelNumber] = number + 1;
                    bullet = Numbered(number, Attr(auto, "type") ?? "arabicPeriod");
                    break;
                }
            }
            if (bullet != null)
            {
                foreach (var item in chain)
                {
                    if (bulletFont == null && First(item, "./*[local-name()='buFont']") is { } font && Attr(font, "typeface") is { } face)
                        bulletFont = face;
                    if (bulletFont == null && Has(item, "buFontTx")) bulletFont = "";
                    if (bulletColor == null && First(item, "./*[local-name()='buClr']") is { } colour)
                        bulletColor = ColorOf(colour, theme);
                    if (bulletSize == null && First(item, "./*[local-name()='buSzPct']") is { } size
                        && SwiftText.ParseDouble(Attr(size, "val") ?? "") is { } value)
                        bulletSize = value / 100_000;
                }
                if (bulletFont == "") bulletFont = null;
            }
            // Відступи в EMU → пункти (12700 EMU в пункті).
            var marginLeft = (Attribute("marL") ?? 0) / 12700;
            var firstIndent = (Attribute("indent") ?? 0) / 12700;

            var runs = new List<Run>();
            // Діти абзацу по порядку: шматки тексту `r`, поля `fld` (номер слайда,
            // дата) і розриви рядка `br`. Доти бралися лише `r`: поле пропадало,
            // а текст після розриву приклеювався до попереднього рядка.
            foreach (var run in All(paragraph, "./*[local-name()='r' or local-name()='fld' or local-name()='br']"))
            {
                string text;
                if (run.LocalName == "br")
                {
                    text = "\n";
                }
                else
                {
                    if (First(run, "./*[local-name()='t']") is not { } node) continue;
                    text = TextOf(node);
                }
                var style = First(run, "./*[local-name()='rPr']");
                string? Own(string name) => Attr(style, name) ?? InheritedText(name);
                var size = SwiftText.ParseDouble(Own("sz") ?? "") ?? 1800;
                var color = (style != null ? SolidColor(style, theme) : null)
                            ?? defaults.Select(item => DirectColor(item, theme)).FirstOrDefault(value => value != null)
                            ?? new SlideStyle.RGBA(0, 0, 0, 1);
                var fontName = FontName(style) ?? defaults.Select(FontName).FirstOrDefault(value => value != null);
                runs.Add(new Run(text, size / 100, Own("b") == "1", Own("i") == "1", (Own("u") ?? "none") != "none",
                                 color, ResolvedFont(fontName)));
            }
            // Порожній абзац — це порожній рядок між блоками тексту, і він
            // тримає вигляд слайда: викидати його не можна.
            result.Add(new Paragraph
            {
                Runs = runs,
                Alignment = alignment,
                Indent = level * 0.03,
                Bullet = bullet,
                MarginLeft = marginLeft,
                FirstIndent = firstIndent,
                BulletFont = bulletFont,
                BulletColor = bulletColor,
                BulletSize = bulletSize,
            });
        }
        // Абзаци в кінці без жодного слова нічого не тримають — вони лише
        // розтягують блок і збивають добір кегля.
        while (result.Count > 0 && result[^1].Runs.Count == 0) result.RemoveAt(result.Count - 1);
        return result;
    }

    // ── Дрібниці розбору ────────────────────────────────────────────────────

    private const string RelationshipNamespace = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

    /// Текст шматка рядка — із сирого XML, а не з готового значення вузла.
    ///
    /// У Foundation `XMLDocument` для `<a:t> </a:t>` віддає порожній рядок:
    /// одиночний пробіл він вважає «незначущим» і викидає. А в презентації
    /// пробіл між словами часто стоїть окремим шматком, бо в нього інше
    /// накреслення. Через це виходило «розсіялисяпо околицях». Тут так само:
    /// внутрішня розмітка вузла і розгортання сутностей.
    private static string TextOf(XmlElement node) => HTMLText.DecodeEntities(node.InnerXml);

    /// Розбір XML: пробіли зберігаємо (без цього сусідні шматки рядка
    /// злипаються), зовнішніх сутностей не вантажимо.
    private static XmlDocument? ParseXml(string text)
    {
        try
        {
            var document = new XmlDocument { PreserveWhitespace = true, XmlResolver = null };
            using var reader = XmlReader.Create(new StringReader(text), new XmlReaderSettings
            {
                DtdProcessing = DtdProcessing.Ignore,
                XmlResolver = null,
            });
            document.Load(reader);
            return document;
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static XmlElement? First(XmlNode node, string xpath)
    {
        try { return node.SelectSingleNode(xpath) as XmlElement; }
        catch (Exception) { return null; }
    }

    private static List<XmlElement> All(XmlNode node, string xpath)
    {
        try { return node.SelectNodes(xpath)?.OfType<XmlElement>().ToList() ?? new List<XmlElement>(); }
        catch (Exception) { return new List<XmlElement>(); }
    }

    /// `attribute(forName:)` — за повним іменем; немає — `null`.
    private static string? Attr(XmlElement? element, string name) => element?.GetAttributeNode(name)?.Value;

    private static string? TextOf(ZipParts.Reader archive, string part)
    {
        try { return archive.Text(part); }
        catch (ZipParts.Failure) { return null; }
    }

    /// Зв'язки частини: `rId7` → куди він веде.
    private static Dictionary<string, string> Relations(string part, ZipParts.Reader archive)
    {
        var folder = Folder(part);
        var name = part.Contains('/') ? part[(part.LastIndexOf('/') + 1)..] : part;
        var path = folder.Length == 0 ? $"_rels/{name}.rels" : $"{folder}/_rels/{name}.rels";
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        if (TextOf(archive, path) is not { } text || ParseXml(text) is not { } document) return result;
        foreach (var element in All(document, "//*[local-name()='Relationship']"))
        {
            if (Attr(element, "Id") is not { } id || Attr(element, "Target") is not { } target) continue;
            result[id] = target;
        }
        return result;
    }

    /// `(part as NSString).deletingLastPathComponent`.
    private static string Folder(string part)
    {
        var trimmed = part.TrimEnd('/');
        var slash = trimmed.LastIndexOf('/');
        return slash < 0 ? "" : slash == 0 ? "/" : trimmed[..slash];
    }

    /// Шлях зв'язку — відносний. Зводимо його до імені частини архіву.
    private static string Resolve(string target, string part)
    {
        if (target.StartsWith('/')) return target[1..];
        var pieces = Folder(part).Split('/', StringSplitOptions.RemoveEmptyEntries).ToList();
        foreach (var piece in target.Split('/', StringSplitOptions.RemoveEmptyEntries))
        {
            if (piece == "..")
            {
                if (pieces.Count > 0) pieces.RemoveAt(pieces.Count - 1);
            }
            else if (piece != ".") pieces.Add(piece);
        }
        return string.Join("/", pieces);
    }

    private static int SlideNumber(string name)
    {
        var characters = SwiftText.Characters(name);
        var digits = string.Concat(characters.SkipWhile(c => !SwiftText.IsNumber(c)).TakeWhile(SwiftText.IsNumber));
        return SwiftText.ParseInt(digits) ?? 0;
    }

    private static string? EmbedID(XmlElement blip) =>
        blip.GetAttributeNode("embed", RelationshipNamespace)?.Value
        ?? blip.Attributes.Cast<XmlAttribute>().FirstOrDefault(a => a.Name.EndsWith(":embed", StringComparison.Ordinal))?.Value;

    private static string? Attribute(XmlElement element, string path, string name) => Attr(First(element, path), name);

    /// Місце фігури: `<a:off>` і `<a:ext>` в EMU.
    private static RectD? FrameIn(XmlElement element)
    {
        if (First(element, ".//*[local-name()='xfrm']") is not { } xfrm
            || First(xfrm, "./*[local-name()='off']") is not { } off
            || First(xfrm, "./*[local-name()='ext']") is not { } ext
            || SwiftText.ParseDouble(Attr(off, "x") ?? "") is not { } x
            || SwiftText.ParseDouble(Attr(off, "y") ?? "") is not { } y
            || SwiftText.ParseDouble(Attr(ext, "cx") ?? "") is not { } cx
            || SwiftText.ParseDouble(Attr(ext, "cy") ?? "") is not { } cy) return null;
        return new RectD(x, y, cx, cy);
    }

    /// Заповнювач: його місце записано не в слайді, а в розмітці або зразку.
    private static (string Type, string Index)? Placeholder(XmlElement element) =>
        First(element, ".//*[local-name()='ph']") is { } ph ? (Attr(ph, "type") ?? "body", Attr(ph, "idx") ?? "") : null;

    private static RectD? PlaceholderFrame((string Type, string Index) wanted, XmlElement? root)
    {
        if (root == null) return null;
        foreach (var shape in All(root, ".//*[local-name()='sp']"))
        {
            if (Placeholder(shape) is not { } found) continue;
            var sameIndex = wanted.Index.Length > 0 && found.Index == wanted.Index;
            var sameType = found.Type == wanted.Type;
            if (!sameIndex && !sameType) continue;
            if (FrameIn(shape) is { } box) return box;
        }
        return null;
    }

    private static string? FontName(XmlElement? style)
    {
        if (style == null) return null;
        foreach (var path in new[] { "./*[local-name()='latin']", "./*[local-name()='cs']" })
            if (First(style, path) is { } font && Attr(font, "typeface") is { Length: > 0 } name) return name;
        return null;
    }

    /// Ім'я шрифту з посилання на шрифт теми: «+mj-lt» — заголовний,
    /// «+mn-lt» — основний. Звичайне ім'я повертається як є.
    private string? ResolvedFont(string? name)
    {
        if (name == null || !name.StartsWith('+')) return name;
        return name.StartsWith("+mj", StringComparison.Ordinal) ? themeFonts.Major : themeFonts.Minor;
    }

    private static string? ThemePartName(ZipParts.Reader archive) =>
        archive.Names.FirstOrDefault(name => name.StartsWith("ppt/theme/", StringComparison.Ordinal) && name.EndsWith(".xml", StringComparison.Ordinal));

    /// Шрифти теми. Латинського шрифту теми на цьому комп'ютері може не
    /// бути (Book Antiqua ставить лише Office) — тоді беремо той, що тема
    /// сама називає для кирилиці: ним PowerPoint і малює український текст,
    /// а системний шрифт без зарубок на його місці міняв би вигляд слайда.
    private static (string? Major, string? Minor) ReadThemeFonts(ZipParts.Reader archive)
    {
        if (ThemePartName(archive) is not { } part || TextOf(archive, part) is not { } text || ParseXml(text) is not { } document)
            return (null, null);
        string? Face(string group)
        {
            var basePath = $"//*[local-name()='fontScheme']/*[local-name()='{group}']";
            var latin = Attr(First(document, basePath + "/*[local-name()='latin']"), "typeface");
            var cyrillic = Attr(First(document, basePath + "/*[local-name()='font'][@script='Cyrl']"), "typeface");
            foreach (var candidate in new[] { latin, cyrillic })
                if (candidate is { Length: > 0 } name && IsInstalled(name)) return name;
            return new[] { latin, cyrillic }.FirstOrDefault(name => name is { Length: > 0 });
        }
        return (Face("majorFont"), Face("minorFont"));
    }

    /// Чи є в системі шрифт цієї родини (на Mac — `CTFontDescriptorCreateMatchingFontDescriptor`).
    internal static bool IsInstalled(string family)
    {
        try { return SKFontManager.Default.GetFontFamilies().Any(name => string.Equals(name, family, StringComparison.OrdinalIgnoreCase)); }
        catch (Exception) { return false; }
    }

    /// Перехід кольору ПРЯМОГО нащадка `<a:gradFill>`.
    private static Gradient? GradientIn(XmlElement element, Dictionary<string, SlideStyle.RGBA> theme)
    {
        if (First(element, "./*[local-name()='gradFill']") is not { } fill) return null;
        var stops = new List<GradientStop>();
        foreach (var stop in All(fill, "./*[local-name()='gsLst']/*[local-name()='gs']"))
        {
            if (ColorOf(stop, theme) is not { } colour) continue;
            var position = (SwiftText.ParseDouble(Attr(stop, "pos") ?? "") ?? 0) / 100_000;
            stops.Add(new GradientStop(Math.Min(1, Math.Max(0, position)), colour));
        }
        if (stops.Count == 0) return null;
        stops = stops.OrderBy(stop => stop.Position).ToList();
        if (First(fill, "./*[local-name()='path']") is { } path)
        {
            var focus = new RectD(0.5, 0.5, 0, 0);
            if (First(path, "./*[local-name()='fillToRect']") is { } to)
            {
                double Part(string name) => (SwiftText.ParseDouble(Attr(to, name) ?? "") ?? 0) / 100_000;
                focus = new RectD(Part("l"), Part("t"), Math.Max(0, 1 - Part("l") - Part("r")), Math.Max(0, 1 - Part("t") - Part("b")));
            }
            GradientKind kind = Attr(path, "path") == "circle" ? new GradientKind.Radial(focus) : new GradientKind.Rectangular(focus);
            return new Gradient(stops, kind);
        }
        var angle = SwiftText.ParseDouble(Attr(First(fill, "./*[local-name()='lin']"), "ang") ?? "") is { } ang ? ang / 60_000 : 0;
        return new Gradient(stops, new GradientKind.Linear(angle));
    }

    /// Чи є в елемента такий прямий нащадок — наприклад `<a:noFill/>`.
    private static bool HasDirect(XmlElement element, string name) => First(element, $"./*[local-name()='{name}']") != null;

    /// Суцільний колір ПРЯМОГО нащадка — заливка самого елемента, а не того,
    /// що лежить у нього всередині.
    private static SlideStyle.RGBA? DirectColor(XmlElement element, Dictionary<string, SlideStyle.RGBA> theme) =>
        First(element, "./*[local-name()='solidFill']") is { } solid ? ColorOf(solid, theme) : null;

    /// Суцільний колір: свій шістнадцятковий або посилання на колір теми.
    private static SlideStyle.RGBA? SolidColor(XmlElement element, Dictionary<string, SlideStyle.RGBA> theme) =>
        First(element, ".//*[local-name()='solidFill']") is { } solid ? ColorOf(solid, theme) : null;

    /// `phClr` — колір-підстановка стилю теми (той, що в `bgRef`/`fillRef`).
    private static SlideStyle.RGBA? ColorOf(XmlElement solid, Dictionary<string, SlideStyle.RGBA> theme, SlideStyle.RGBA? phClr = null)
    {
        if (First(solid, "./*[local-name()='srgbClr']") is { } own && Attr(own, "val") is { } hex)
            return ColorHex(hex) is { } value ? Transformed(value, own) : null;
        if (First(solid, "./*[local-name()='schemeClr']") is { } scheme && Attr(scheme, "val") is { } name)
        {
            var baseColor = name == "phClr" ? phClr : theme.TryGetValue(name, out var known) ? known : DefaultScheme(name);
            return baseColor is { } value ? Transformed(value, scheme) : null;
        }
        return null;
    }

    /// Дочірні перетворення кольору: `tint`, `shade`, `lumMod`, `lumOff`,
    /// `satMod`. PowerPoint рахує tint/shade у лінійному світлі, а не в sRGB:
    /// «shade 85 %» білого — це 238, а не 217. Без цього фон теми виходив
    /// сірішим і темнішим, ніж у PowerPoint.
    private static SlideStyle.RGBA Transformed(SlideStyle.RGBA color, XmlElement element)
    {
        var children = element.ChildNodes.OfType<XmlElement>().ToList();
        if (children.Count == 0) return color;
        static double Value(XmlElement node) => (SwiftText.ParseDouble(Attr(node, "val") ?? "") ?? 100_000) / 100_000;
        static double Linear(double c) => c <= 0.04045 ? c / 12.92 : Math.Pow((c + 0.055) / 1.055, 2.4);
        static double Gamma(double c) => c <= 0.0031308 ? c * 12.92 : 1.055 * Math.Pow(c, 1 / 2.4) - 0.055;
        double r = color.Red, g = color.Green, b = color.Blue;
        var alpha = color.Alpha;
        foreach (var node in children)
        {
            var local = node.LocalName;
            switch (local)
            {
                case "tint":
                {
                    var t = Value(node);
                    (r, g, b) = (Gamma(Linear(r) * t + (1 - t)), Gamma(Linear(g) * t + (1 - t)), Gamma(Linear(b) * t + (1 - t)));
                    break;
                }
                case "shade":
                {
                    var t = Value(node);
                    (r, g, b) = (Gamma(Linear(r) * t), Gamma(Linear(g) * t), Gamma(Linear(b) * t));
                    break;
                }
                case "lumMod":
                case "lumOff":
                case "satMod":
                {
                    var (h, sat, l) = Hsl(r, g, b);
                    if (local == "lumMod") l = Math.Min(1, Math.Max(0, l * Value(node)));
                    if (local == "lumOff") l = Math.Min(1, Math.Max(0, l + Value(node)));
                    if (local == "satMod") sat = Math.Min(1, Math.Max(0, sat * Value(node)));
                    (r, g, b) = Rgb(h, sat, l);
                    break;
                }
                case "alpha":
                    alpha = Math.Min(1, Math.Max(0, Value(node)));
                    break;
            }
        }
        return new SlideStyle.RGBA(r, g, b, alpha);
    }

    private static (double H, double S, double L) Hsl(double r, double g, double b)
    {
        var hi = Math.Max(r, Math.Max(g, b));
        var lo = Math.Min(r, Math.Min(g, b));
        var l = (hi + lo) / 2;
        if (!(hi > lo)) return (0, 0, l);
        var d = hi - lo;
        var s = l > 0.5 ? d / (2 - hi - lo) : d / (hi + lo);
        double h;
        if (hi == r) h = (g - b) / d + (g < b ? 6 : 0);
        else if (hi == g) h = (b - r) / d + 2;
        else h = (r - g) / d + 4;
        h /= 6;
        return (h, s, l);
    }

    private static (double R, double G, double B) Rgb(double h, double s, double l)
    {
        if (!(s > 0)) return (l, l, l);
        static double Channel(double p, double q, double t0)
        {
            var t = t0;
            if (t < 0) t += 1;
            if (t > 1) t -= 1;
            if (t < 1.0 / 6) return p + (q - p) * 6 * t;
            if (t < 1.0 / 2) return q;
            if (t < 2.0 / 3) return p + (q - p) * (2.0 / 3 - t) * 6;
            return p;
        }
        var q = l < 0.5 ? l * (1 + s) : l + s - l * s;
        var p = 2 * l - q;
        return (Channel(p, q, h + 1.0 / 3), Channel(p, q, h), Channel(p, q, h - 1.0 / 3));
    }

    /// Стилі фону теми та зв'язки її частини (картинки текстур).
    private static (string Part, List<XmlElement> Styles, Dictionary<string, string> Relations) ReadThemeBackgrounds(ZipParts.Reader archive)
    {
        if (ThemePartName(archive) is not { } part || TextOf(archive, part) is not { } text || ParseXml(text) is not { } document)
            return ("", new List<XmlElement>(), new Dictionary<string, string>());
        var styles = All(document, "//*[local-name()='bgFillStyleLst']/*");
        var relations = new Dictionary<string, string>(StringComparer.Ordinal);
        var relsPart = part.Replace("theme/", "theme/_rels/") + ".rels";
        if (TextOf(archive, relsPart) is { } relsText && ParseXml(relsText) is { } rels)
        {
            foreach (var element in All(rels, "//*[local-name()='Relationship']"))
            {
                if (Attr(element, "Id") is not { } id || Attr(element, "Target") is not { } target) continue;
                relations[id] = target;
            }
        }
        return (part, styles, relations);
    }

    /// `color(hex:)`: `Scanner.scanHexInt64` — пробіли спереду, «0x» за бажанням,
    /// далі шістнадцяткові цифри; рядок не коротший за шість знаків.
    private static SlideStyle.RGBA? ColorHex(string hex)
    {
        var index = 0;
        while (index < hex.Length && char.IsWhiteSpace(hex[index])) index++;
        if (index + 1 < hex.Length && hex[index] == '0' && (hex[index + 1] == 'x' || hex[index + 1] == 'X')
            && index + 2 < hex.Length && Uri.IsHexDigit(hex[index + 2])) index += 2;
        ulong value = 0;
        var any = false;
        while (index < hex.Length && Uri.IsHexDigit(hex[index]))
        {
            var digit = (ulong)Convert.ToInt32(hex[index].ToString(), 16);
            value = value > (ulong.MaxValue >> 4) ? ulong.MaxValue : value << 4 | digit;
            any = true;
            index++;
        }
        if (!any || SwiftText.CharacterCount(hex) < 6) return null;
        return new SlideStyle.RGBA(((value >> 16) & 0xFF) / 255.0, ((value >> 8) & 0xFF) / 255.0, (value & 0xFF) / 255.0, 1);
    }

    /// Якщо теми немає, кольори все одно мають бути осмисленими: текст темний,
    /// фон світлий. Порожній слайд краще показати чорним по білому, ніж ніяк.
    private static SlideStyle.RGBA? DefaultScheme(string name) => name switch
    {
        "bg1" or "lt1" or "background1" => new SlideStyle.RGBA(1, 1, 1, 1),
        "tx1" or "dk1" or "text1" => new SlideStyle.RGBA(0, 0, 0, 1),
        "bg2" or "lt2" => new SlideStyle.RGBA(0.93, 0.93, 0.93, 1),
        "tx2" or "dk2" => new SlideStyle.RGBA(0.16, 0.16, 0.16, 1),
        _ => null,
    };

    private static Dictionary<string, SlideStyle.RGBA> ReadTheme(ZipParts.Reader archive)
    {
        var result = new Dictionary<string, SlideStyle.RGBA>(StringComparer.Ordinal);
        if (ThemePartName(archive) is not { } part || TextOf(archive, part) is not { } text || ParseXml(text) is not { } document)
            return result;
        foreach (var element in All(document, "//*[local-name()='clrScheme']/*"))
        {
            var key = element.LocalName;
            if (First(element, "./*[local-name()='srgbClr']") is { } own && Attr(own, "val") is { } hex && ColorHex(hex) is { } value)
                result[key] = value;
            else if (First(element, "./*[local-name()='sysClr']") is { } system && Attr(system, "lastClr") is { } last && ColorHex(last) is { } sysValue)
                result[key] = sysValue;
        }
        // Імена кольорів теми та імена в посиланнях розходяться: у темі «lt1», у
        // посиланні «bg1». Розводимо їх тут, а не в кожному місці розбору.
        foreach (var (from, to) in new[] { ("lt1", "bg1"), ("dk1", "tx1"), ("lt2", "bg2"), ("dk2", "tx2") })
            if (!result.ContainsKey(to) && result.TryGetValue(from, out var value)) result[to] = value;
        return result;
    }

    /// Фон частини: слайда, розмітки або зразка.
    private Fill? BackgroundFill(XmlElement root, Dictionary<string, string> relations, string part)
    {
        if (First(root, ".//*[local-name()='bg']") is not { } background) return null;
        if (First(background, ".//*[local-name()='blip']") is { } blip && EmbedID(blip) is { } id && relations.TryGetValue(id, out var target))
            return new Fill.Picture(Resolve(target, part));
        if (SolidColor(background, theme) is { } solid) return new Fill.Solid(solid);
        // `<p:bgRef idx="1002"><a:schemeClr val="bg2"/>` — посилання на стиль фону
        // теми з кольором, який у той стиль підставляється. Стилі теми — це
        // здебільшого той самий колір із ледь помітним відтінком, тому беремо
        // колір як є. Доти такий фон лишався білим, хоч у PowerPoint слайд
        // кремовий.
        if (First(background, "./*[local-name()='bgRef']") is { } reference && ColorOf(reference, theme) is { } referenced)
        {
            // Сам стиль: 1001–1003 → перший–третій у `bgFillStyleLst`. Суцільний —
            // колір із перетвореннями; текстура — картинка теми з дуотоном
            // (так зроблено «Твердий переплет»: слайд світло-сірий, зернистий,
            // а не білий). Градієнт — середнім із кінців.
            if (SwiftText.ParseInt(Attr(reference, "idx") ?? "") is { } index && index >= 1001 && index - 1001 < themeBackgroundStyles.Count)
            {
                var style = themeBackgroundStyles[index - 1001];
                switch (style.LocalName)
                {
                    case "solidFill":
                        return new Fill.Solid(ColorOf(style, theme, referenced) ?? referenced);
                    case "blipFill":
                        if (First(style, "./*[local-name()='blip']") is { } styleBlip && EmbedID(styleBlip) is { } styleId
                            && themeRelations.TryGetValue(styleId, out var styleTarget))
                        {
                            Duotone? duotone = null;
                            if (First(styleBlip, "./*[local-name()='duotone']") is { } tone)
                            {
                                var colours = tone.ChildNodes.OfType<XmlElement>().ToList();
                                if (colours.Count >= 2 && ColorOfColour(colours[0], theme, referenced) is { } dark
                                    && ColorOfColour(colours[1], theme, referenced) is { } light)
                                    duotone = new Duotone(dark, light);
                            }
                            double? tileScale = null;
                            if (First(style, "./*[local-name()='tile']") is { } tile)
                                tileScale = (SwiftText.ParseDouble(Attr(tile, "sx") ?? "") ?? 100_000) / 100_000;
                            return new Fill.Texture(Resolve(styleTarget, themePart), tileScale, duotone);
                        }
                        break;
                    case "gradFill":
                    {
                        var stops = All(style, ".//*[local-name()='gs']").Select(stop => ColorOf(stop, theme, referenced))
                            .Where(value => value != null).Select(value => value!.Value).ToList();
                        if (stops.Count > 0)
                        {
                            var a = stops[0];
                            var b = stops[^1];
                            return new Fill.Solid(new SlideStyle.RGBA((a.Red + b.Red) / 2, (a.Green + b.Green) / 2, (a.Blue + b.Blue) / 2, 1));
                        }
                        break;
                    }
                }
            }
            return new Fill.Solid(referenced);
        }
        return null;
    }

    /// Колір із самого елемента кольору (`srgbClr`/`schemeClr`), а не з
    /// обгортки `solidFill`.
    private static SlideStyle.RGBA? ColorOfColour(XmlElement element, Dictionary<string, SlideStyle.RGBA> theme, SlideStyle.RGBA? phClr)
    {
        switch (element.LocalName)
        {
            case "srgbClr":
                return Attr(element, "val") is { } hex && ColorHex(hex) is { } value ? Transformed(value, element) : null;
            case "schemeClr":
                if (Attr(element, "val") is not { } name) return null;
                var baseColor = name == "phClr" ? phClr : theme.TryGetValue(name, out var known) ? known : DefaultScheme(name);
                return baseColor is { } found ? Transformed(found, element) : null;
            default:
                return null;
        }
    }
}
