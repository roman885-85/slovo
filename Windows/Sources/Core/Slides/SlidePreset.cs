// =============================================================================
//  SlidePreset.cs — преднастройка виводу (з Slides/SlidePreset.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Преднастройка виводу: полотно, підкладка і розкладені по ньому об'єкти.
///
/// У кожного виводу — монітора, NDI, вебу, екрана служителя — своя
/// преднастройка: на проекторі потрібен фон і великий текст, у NDI фон
/// частіше заважає, а служителю корисні наступна сторінка і нотатки.
///
/// JSON — як у Swift: обов'язкові id, name, canvasWidth, canvasHeight,
/// background, objects, transition, transitionDuration; transitionEasing і
/// forSongs — необов'язкові (старі файли без forSongs — Біблії).
public sealed partial class SlidePreset
{
    /// Як уписувати фонове зображення в полотно.
    [JsonConverter(typeof(SwiftStringEnumConverter<FillMode>))]
    public enum FillMode
    {
        [JsonStringEnumMemberName("fill")] Fill,         // заповнити, обрізавши зайве
        [JsonStringEnumMemberName("fit")] Fit,           // уписати цілком
        [JsonStringEnumMemberName("stretch")] Stretch,   // розтягнути, спотворюючи пропорції
        [JsonStringEnumMemberName("center")] Center,     // як є, по центру
        [JsonStringEnumMemberName("tile")] Tile,         // замостити
    }

    public static string Title(FillMode mode) => mode switch
    {
        FillMode.Fill => OurWords.T("Заполнить"),
        FillMode.Fit => OurWords.T("Вписать"),
        FillMode.Stretch => OurWords.T("Растянуть"),
        FillMode.Center => OurWords.T("По центру"),
        _ => OurWords.T("Замостить"),
    };

    public record struct Background
    {
        [JsonInclude, JsonRequired, JsonPropertyName("color")] public SlideStyle.RGBA Color;
        [JsonInclude, JsonPropertyName("imagePath")] public string? ImagePath;
        [JsonInclude, JsonRequired, JsonPropertyName("fillMode")] public FillMode Fill;
        /// Затемнення поверх картинки. Більше не малюється ніде (власник побачив
        /// його як «накладено темний світлофільтр»); поле лишилося, щоб читалися
        /// вже збережені шаблони.
        [JsonInclude, JsonRequired, JsonPropertyName("dim")] public double Dim;
        /// Розмиття підкладки: фотографія з деталями «шумить» під літерами.
        [JsonInclude, JsonRequired, JsonPropertyName("blurRadius")] public double BlurRadius;
        /// Повністю прозорий фон — режим для NDI, коли картинку підкладає мікшер.
        [JsonInclude, JsonRequired, JsonPropertyName("isTransparent")] public bool IsTransparent;

        public Background() : this(null) { }

        public Background(SlideStyle.RGBA? color = null, string? imagePath = null, FillMode fillMode = FillMode.Fill,
                          double dim = 0, double blurRadius = 0, bool isTransparent = false)
        {
            Color = color ?? new SlideStyle.RGBA(0.04, 0.07, 0.13);
            ImagePath = imagePath;
            Fill = fillMode;
            Dim = dim;
            BlurRadius = blurRadius;
            IsTransparent = isTransparent;
        }
    }

    [JsonRequired, JsonPropertyName("id")] public Guid Id { get; set; }
    [JsonRequired, JsonPropertyName("name")] public string Name { get; set; } = "";
    /// Розмір полотна, під який добирали розмітку (самі об'єкти — у частках).
    [JsonRequired, JsonPropertyName("canvasWidth")] public int CanvasWidth { get; set; }
    [JsonRequired, JsonPropertyName("canvasHeight")] public int CanvasHeight { get; set; }
    [JsonRequired, JsonPropertyName("background")] public Background Back { get; set; }
    [JsonRequired, JsonPropertyName("objects")] public List<SlideObject> Objects { get; set; } = new();
    [JsonRequired, JsonPropertyName("transition")] public SlideStyle.Transition Transition { get; set; }
    [JsonRequired, JsonPropertyName("transitionDuration")] public double TransitionDuration { get; set; }
    [JsonPropertyName("transitionEasing")] public SlideStyle.Easing? TransitionEasing { get; set; }
    /// Шаблон пісень, а не Біблії: кожен шаблон належить одному з двох
    /// редакторів, і списки в них не перетинаються.
    [JsonPropertyName("forSongs")] public bool ForSongs { get; set; }

    [JsonConstructor]
    public SlidePreset() { }

    public SlidePreset(string name, int canvasWidth = 1920, int canvasHeight = 1080, Background? background = null,
                       List<SlideObject>? objects = null, SlideStyle.Transition transition = SlideStyle.Transition.Fade,
                       double transitionDuration = 0.35)
    {
        Id = Guid.NewGuid();
        Name = name;
        CanvasWidth = canvasWidth;
        CanvasHeight = canvasHeight;
        Back = background ?? new Background();
        Objects = objects ?? new List<SlideObject>();
        Transition = transition;
        TransitionDuration = transitionDuration;
    }

    [JsonIgnore]
    public double AspectRatio => CanvasHeight > 0 ? (double)CanvasWidth / CanvasHeight : 16.0 / 9.0;

    /// `object(withID:)`.
    public SlideObject? Object(Guid id)
    {
        foreach (var item in Objects)
            if (item.Id == id) return item;
        return null;
    }

    public void Replace(SlideObject item)
    {
        var index = Objects.FindIndex(o => o.Id == item.Id);
        if (index < 0) return;
        Objects[index] = item;
    }

    public void Move(int source, int destination)
    {
        if (source < 0 || source >= Objects.Count || destination < 0 || destination > Objects.Count) return;
        var item = Objects[source];
        Objects.RemoveAt(source);
        Objects.Insert(destination > source ? destination - 1 : destination, item);
    }

    /// Глибока копія (у Swift — присвоєння значення).
    public SlidePreset Copy() => new()
    {
        Id = Id, Name = Name, CanvasWidth = CanvasWidth, CanvasHeight = CanvasHeight, Back = Back,
        Objects = new List<SlideObject>(Objects), Transition = Transition, TransitionDuration = TransitionDuration,
        TransitionEasing = TransitionEasing, ForSongs = ForSongs,
    };

    // ── Готові розкладки ────────────────────────────────────────────────────

    /// Звична розкладка: текст по центру, під ним другий переклад, унизу адреса.
    public static SlidePreset Standard(string name, SlideStyle style)
    {
        var quote = new SlideObject(SlideObjectKind.Quote, text: style.Main)
        {
            Frame = new ObjectFrame(0, -0.06, 0.88, 0.46, HorizontalAnchor.Center, VerticalAnchor.Middle),
        };
        var second = new SlideObject(SlideObjectKind.SecondaryQuote, text: style.Secondary)
        {
            Frame = new ObjectFrame(0, 0.22, 0.88, 0.26, HorizontalAnchor.Center, VerticalAnchor.Middle),
        };
        var reference = new SlideObject(SlideObjectKind.Reference, text: style.Reference)
        {
            Frame = new ObjectFrame(0, 0.06, 0.88, 0.1, HorizontalAnchor.Center, VerticalAnchor.Bottom),
        };
        var background = new Background(style.BackgroundColor, style.BackgroundImagePath, dim: style.DimBackground)
        {
            BlurRadius = 0,
        };
        return new SlidePreset(name, background: background, objects: [quote, second, reference],
                               transition: style.TransitionKind, transitionDuration: style.TransitionDuration);
    }

    /// Розкладка пісні: куплет на все полотно, під ним підпис частини —
    /// «Куплет», «Приспів» — той самий об'єкт адреси, що на слайді пісні.
    public static SlidePreset Song(string name, SlideStyle style)
    {
        var quote = new SlideObject(SlideObjectKind.Quote, text: style.Main)
        {
            Frame = new ObjectFrame(0, -0.04, 0.9, 0.7, HorizontalAnchor.Center, VerticalAnchor.Middle),
        };
        var title = new SlideObject(SlideObjectKind.Reference, OurWords.T("Часть песни"), text: style.Reference)
        {
            Frame = new ObjectFrame(0, 0.05, 0.9, 0.1, HorizontalAnchor.Center, VerticalAnchor.Bottom),
        };
        var background = new Background(style.BackgroundColor, style.BackgroundImagePath, dim: style.DimBackground)
        {
            BlurRadius = 0,
        };
        return new SlidePreset(name, background: background, objects: [quote, title],
                               transition: style.TransitionKind, transitionDuration: style.TransitionDuration)
        {
            ForSongs = true,
        };
    }

    /// Розкладка для NDI: те саме, але без підкладки.
    public static SlidePreset Transparent(string name, SlideStyle style)
    {
        var preset = Standard(name, style);
        var background = preset.Back;
        background.IsTransparent = true;
        background.ImagePath = null;
        background.Dim = 0;
        preset.Back = background;
        return preset;
    }

    /// Розкладка екрана служителя: великий поточний текст, зверху адреса,
    /// знизу наступна сторінка — щоб бачити, що буде далі.
    public static SlidePreset Stage(string name, SlideStyle style)
    {
        var reference = new SlideObject(SlideObjectKind.Reference, text: style.Reference)
        {
            Frame = new ObjectFrame(0, 0.04, 0.9, 0.09, HorizontalAnchor.Center, VerticalAnchor.Top),
        };
        var quote = new SlideObject(SlideObjectKind.Quote, text: style.Main)
        {
            Frame = new ObjectFrame(0, -0.04, 0.92, 0.5, HorizontalAnchor.Center, VerticalAnchor.Middle),
        };
        var next = new SlideObject(SlideObjectKind.NextPage, text: style.Secondary)
        {
            Name = "Следующая",
            Opacity = 0.55,
            Frame = new ObjectFrame(0, 0.05, 0.92, 0.24, HorizontalAnchor.Center, VerticalAnchor.Bottom),
        };
        var background = new Background(new SlideStyle.RGBA(0, 0, 0), dim: 0) { ImagePath = null };
        return new SlidePreset(name, background: background, objects: [reference, quote, next],
                               transition: SlideStyle.Transition.None, transitionDuration: 0);
    }

    // ── JSON ────────────────────────────────────────────────────────────────

    /// `try? JSONDecoder().decode(SlidePreset.self, from: data)`.
    public static SlidePreset? Decode(byte[] data) => SwiftJson.TryDecode<SlidePreset>(data);

    /// Як пише бібліотека преднастройок: `.prettyPrinted, .sortedKeys, .withoutEscapingSlashes`.
    public byte[] Encode() => SwiftJson.EncodeBytes(this, pretty: true, sortedKeys: true, escapeSlashes: false);
}
