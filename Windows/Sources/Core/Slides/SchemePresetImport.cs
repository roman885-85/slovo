// =============================================================================
//  SchemePresetImport.cs — авторський шаблон .sch → наша преднастройка
//  (з Slides/SchemePresetImport.swift)
// =============================================================================

namespace Slovo.Core;

/// Перенесення авторського шаблону `.sch` у нашу преднастройку.
///
/// У конструкторі це «взяти за основу»: список об'єктів, їхні рамки, кольори,
/// картинки й анімація приходять із готового шаблону старої програми, а далі
/// правляться й зберігаються вже своїм файлом. Авторські `.sch` ми не переписуємо.
public sealed partial class SlidePreset
{
    public SlidePreset(SchemeLibrary.Template template, SlideStyle baseStyle,
                       double designHeight = SchemeLibrary.DefaultDesignHeight)
    {
        var scheme = template.Scheme;
        var height = Math.Max(designHeight, 1);

        // Обведення в шаблоні записано в пікселях того слайда, під який його
        // підбирали; у нас воно в частках висоти — ділимо на неї.
        var outline = scheme.OutlineEnabled ? scheme.OutlineWidth / height : 0;

        var objects = new List<SlideObject>();
        foreach (var element in scheme.Elements)
        {
            var kind = KindOf(element);
            var item = new SlideObject(kind, text: Layer(kind, baseStyle));
            item.Name = element.Name.Length == 0 ? kind.ShortTitle() : element.Name;

            if (element.TextColor is { } color) item.Text.Color = color;
            item.Text.OutlineColor = scheme.OutlineColor;
            item.Text.OutlineWidth = outline;
            // Тінь об'єкта своя у кожної сцени й приходить з його ж атрибутів
            // `Shadow…Perc`. Спільна `QuoteShadow…` у них продубльована, і якщо
            // лишити її ще й у шарі тексту, тінь намалюється двічі.
            item.Text.ShadowRadius = 0;
            item.LineSpacing = baseStyle.LineSpacing;

            if (kind == SlideObjectKind.Image)
            {
                item.ImagePath = template.ImageUrl(element.ImageName);
                item.MaskPath = template.ImageUrl(element.ImageMaskName);
            }

            var single = VariantOf(element, SlideScheme.Variant.Single);
            item.Frame = single.Frame;
            item.Opacity = single.Opacity;
            item.IsVisible = single.IsVisible;
            item.Alignment = single.Alignment;
            item.VerticalAlignment = single.VerticalAlignment;
            item.Shadow = single.Shadow;
            item.Animation = single.Animation;

            // `Enabled` і `Enabled_2` самостійні й від `EnableParamsVariant` не
            // залежать: у «Beautiful Gold/Orange/Pink/Violet» лінія `DownLine`
            // видна лише при двох перекладах. Тому другий набір заводимо й тоді,
            // коли відрізняється сама лише видимість.
            var dualVisible = element.PlacementFor(SlideScheme.Variant.Dual).IsEnabled;
            if (element.HasVariantParameters)
            {
                item.SecondVariant = VariantOf(element, SlideScheme.Variant.Dual);
            }
            else if (dualVisible != single.IsVisible)
            {
                var mirror = single;
                mirror.IsVisible = dualVisible;
                item.SecondVariant = mirror;
            }
            objects.Add(item);
        }

        var background = new Background(baseStyle.BackgroundColor, template.BackgroundUrl, FillMode.Fill, 0)
        {
            IsTransparent = false,
        };

        Id = Guid.NewGuid();
        Name = scheme.Name.Length == 0 ? template.Name : scheme.Name;
        CanvasWidth = 1920;
        CanvasHeight = 1080;
        Back = background;
        Objects = objects;
        Transition = baseStyle.TransitionKind;
        TransitionDuration = baseStyle.TransitionDuration;
    }

    // ── Розбір одного об'єкта ───────────────────────────────────────────────

    private static ObjectVariant VariantOf(SlideScheme.Element element, SlideScheme.Variant scene)
    {
        var placement = element.PlacementFor(scene);

        var frame = new ObjectFrame(placement.IndentX / 100, placement.IndentY / 100,
                                    placement.Width / 100, placement.Height / 100,
                                    Horizontal(placement.Anchor.Horizontal), Vertical(placement.Anchor.Vertical));

        // Тінь у шаблоні посценна. Окремого прапорця в файлі немає — вимкненою
        // тінню там служать нулі, їх і вважаємо вимикачем.
        var shadow = new ObjectShadow(
            isEnabled: placement.ShadowOpacity > 0 && (placement.ShadowOffset != 0 || placement.ShadowBlur > 0),
            offsetPercent: placement.ShadowOffset,
            blurPercent: placement.ShadowBlur,
            opacity: placement.ShadowOpacity,
            color: placement.ShadowColor);

        return new ObjectVariant(frame, placement.Opacity, placement.IsEnabled, Alignment(placement.TextAlignment),
                                 Layout(placement.TextLayout), shadow, AnimationOf(element.SceneFor(scene)));
    }

    /// `Layout` шаблону — Delphi `TTextLayout`: 0 верх, 1 центр, 2 низ.
    private static SlideStyle.VerticalAlignment Layout(SlideScheme.TextLayout? value) => value switch
    {
        SlideScheme.TextLayout.Top => SlideStyle.VerticalAlignment.Top,
        SlideScheme.TextLayout.Bottom => SlideStyle.VerticalAlignment.Bottom,
        _ => SlideStyle.VerticalAlignment.Center,
    };

    private static HorizontalAnchor Horizontal(SlideScheme.Anchor.HorizontalSide value) => value switch
    {
        SlideScheme.Anchor.HorizontalSide.Left => HorizontalAnchor.Left,
        SlideScheme.Anchor.HorizontalSide.Right => HorizontalAnchor.Right,
        _ => HorizontalAnchor.Center,
    };

    /// У шаблоні вертикальна прив'язка лише «зверху» або «знизу».
    private static VerticalAnchor Vertical(SlideScheme.Anchor.VerticalSide value) =>
        value == SlideScheme.Anchor.VerticalSide.Top ? VerticalAnchor.Top : VerticalAnchor.Bottom;

    private static ParagraphAlignment Alignment(SlideScheme.TextAlignment? value) => value switch
    {
        SlideScheme.TextAlignment.Left => ParagraphAlignment.Leading,
        SlideScheme.TextAlignment.Right => ParagraphAlignment.Trailing,
        _ => ParagraphAlignment.Center,
    };

    /// Номери ефектів оригіналу не розшифровано, тому напрямок відновлюємо за
    /// стартовим зсувом `MoveFromX` / `MoveFromY`.
    private static ObjectAnimation AnimationOf(SlideScheme.Scene? found)
    {
        if (found is not { IsAnimated: true } scene) return ObjectAnimation.Instant;

        const double threshold = 0.001;
        var sx = scene.MoveFromX > threshold ? 1 : scene.MoveFromX < -threshold ? -1 : 0;
        var sy = scene.MoveFromY > threshold ? 1 : scene.MoveFromY < -threshold ? -1 : 0;

        var direction = ObjectAnimation.Direction.None;
        foreach (var candidate in Enum.GetValues<ObjectAnimation.Direction>())
        {
            if (candidate == ObjectAnimation.Direction.Point) continue;
            var offset = candidate.Offset();
            if ((int)offset.X == sx && (int)offset.Y == sy)
            {
                direction = candidate;
                break;
            }
        }

        return new ObjectAnimation(direction: direction,
                                   startScale: scene.IsScaling ? scene.FromScale : 1,
                                   startOpacity: scene.FromOpacity,
                                   duration: scene.Duration * 1000,
                                   delay: scene.Delay * 1000,
                                   animatesScale: scene.IsScaling,
                                   animatesOpacity: scene.FromOpacity < 0.999);
    }

    /// Усі чотирнадцять видів об'єкта: принесений збоку шаблон (4.2.3) може
    /// містити будь-який номер, і перетворювати його на порожній напис не можна.
    internal static SlideObjectKind KindOf(SlideScheme.Element element) => element.Kind switch
    {
        SlideScheme.ElementKind.Quote => SlideObjectKind.Quote,
        SlideScheme.ElementKind.SecondQuote => SlideObjectKind.SecondaryQuote,
        SlideScheme.ElementKind.Reference => SlideObjectKind.Reference,
        SlideScheme.ElementKind.FirstReference => SlideObjectKind.PrimaryReference,
        SlideScheme.ElementKind.SecondReference => SlideObjectKind.SecondaryReference,
        SlideScheme.ElementKind.ModuleShortNameFirst => SlideObjectKind.ModuleShortNameFirst,
        SlideScheme.ElementKind.ModuleNameFirst => SlideObjectKind.ModuleNameFirst,
        SlideScheme.ElementKind.ModuleShortNameSecond => SlideObjectKind.ModuleShortNameSecond,
        SlideScheme.ElementKind.ModuleNameSecond => SlideObjectKind.ModuleNameSecond,
        SlideScheme.ElementKind.PreviousPage => SlideObjectKind.PreviousPage,
        SlideScheme.ElementKind.NextPage => SlideObjectKind.NextPage,
        SlideScheme.ElementKind.SongTitle => SlideObjectKind.SongTitle,
        SlideScheme.ElementKind.StaticText => SlideObjectKind.StaticText,
        SlideScheme.ElementKind.Decoration => SlideObjectKind.Image,
        // Незнайомий номер `Type` — скоріше прикраса з картинкою, ніж текст;
        // без картинки хай буде напис, який видно і можна поправити.
        _ => element.ImageName == null ? SlideObjectKind.StaticText : SlideObjectKind.Image,
    };

    private static SlideStyle.TextLayer Layer(SlideObjectKind kind, SlideStyle baseStyle) => kind switch
    {
        SlideObjectKind.Quote => baseStyle.Main,
        SlideObjectKind.SecondaryQuote => baseStyle.Secondary,
        _ => baseStyle.Reference,
    };
}
