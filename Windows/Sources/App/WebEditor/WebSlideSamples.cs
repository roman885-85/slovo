// =============================================================================
//  WebSlideSamples.cs — чим наповнити слайд у передпоказі (з Views/WebEditor/WebSlideSamples.swift)
// =============================================================================
//  Повзунки без тексту обманюють: на «Буття 1:1» влазить що завгодно, а на
//  довгому вірші той самий кегль виїжджає за край екрана. Проби — спосіб
//  побачити біду до зібрання: найкоротший вірш, найдовший, два переклади поруч,
//  куплет пісні з переносами рядків і оголошення у фойє.
// =============================================================================

using Slovo.Core;

namespace Slovo.App;

public sealed record WebSlideSample
{
    public string Id { get; init; } = "";
    public string TitleSource { get; init; } = "";
    public string Title => OurWords.T(TitleSource);
    /// Чим ця проба небезпечна для оформлення.
    public string PurposeSource { get; init; } = "";
    public string Purpose => OurWords.T(PurposeSource);
    public string Text { get; init; } = "";
    public string Second { get; init; } = "";
    public string Reference { get; init; } = "";
    public string Next { get; init; } = "";
    public string SongTitle { get; init; } = "";
    /// «Bible», «Text» або «Song» — за цим сторінки вирішують, чи брати вірш у лапки.
    public string Mode { get; init; } = "Bible";
    public int PageCurrent { get; init; }
    public int PageCount { get; init; } = 1;

    public static readonly IReadOnlyList<WebSlideSample> All =
    [
        new()
        {
            Id = "short", TitleSource = "Короткий стих",
            PurposeSource = "Одна строка. Видно, не теряется ли текст посреди пустого экрана.",
            Text = "На початку Бог створив Небо та землю.", Reference = "Буття 1:1",
            Next = "А земля була пуста та порожня…",
        },
        new()
        {
            Id = "long", TitleSource = "Длинный стих",
            PurposeSource = "Самая длинная проба. Если текст не влезает — уменьшайте кегль или включайте подбор.",
            Text = "Тож благаю вас, браття, через Боже милосердя, повіддавайте ваші тіла на жертву "
                   + "живу, святу, приємну Богові, як розумну службу вашу, і не стосуйтесь до віку цього, "
                   + "але перемініться відновою вашого розуму, щоб пізнати вам, що то є воля Божа, "
                   + "добро, приємність та досконалість.",
            Reference = "Римлян 12:1-2", Next = "Через дану мені благодать кажу кожному з вас…",
        },
        new()
        {
            Id = "two", TitleSource = "Два перевода",
            PurposeSource = "Второй перевод под текстом или рядом колонкой. Видно, хватает ли ширины.",
            Text = "Так бо Бог полюбив світ, що дав Сина Свого Однородженого, "
                   + "щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне.",
            Second = "For God so loved the world, that he gave his only begotten Son, "
                     + "that whosoever believeth in him should not perish, but have everlasting life.",
            Reference = "Івана 3:16", Next = "Бо Бог не послав Свого Сина на світ, щоб Він світ засудив…",
        },
        new()
        {
            Id = "song", TitleSource = "Куплет песни",
            PurposeSource = "Переносы строк, название песни, без адреса и без кавычек.",
            Text = "Який Ти великий, Боже,\nсповнений величі,\nі гідний хвали Ти!\nУся земля співає Тобі.",
            Reference = "Куплет 2", Next = "Приспів: Господь мій Бог!",
            SongTitle = "№ 128 · Який Ти великий, Боже", Mode = "Song",
        },
        new()
        {
            Id = "pages", TitleSource = "Длинный текст по страницам",
            PurposeSource = "«2 из 3» — проверка подписи о том, что текст разбит на несколько экранов.",
            Text = "І сказав Бог: Хай станеться світло! І сталося світло. І побачив Бог світло, що добре воно, "
                   + "і Бог відділив світло від темряви.",
            Reference = "Буття 1:3-4", Next = "І Бог назвав світло: День, а темряву назвав: Ніч.",
            PageCurrent = 1, PageCount = 3,
        },
        new()
        {
            Id = "notice", TitleSource = "Объявление",
            PurposeSource = "Простой текст без адреса — так выглядит объявление или заставка в фойе.",
            Text = "Молитовне зібрання — у середу о 18:30", Mode = "Text",
        },
    ];

    /// Взяти те, що програма показує прямо зараз.
    public static WebSlideSample FromSlide(string text, string second, string reference) => new()
    {
        Id = "live", TitleSource = "Со слайда программы", PurposeSource = "То, что сейчас на экране в зале.",
        Text = text, Second = second, Reference = reference,
    };

    /// Підміна з'єднання для цієї проби.
    public string Shim(bool hidden) =>
        WebSlideTemplates.PreviewShim(Text, Second, Reference, Next, Mode, SongTitle, hidden, PageCurrent, Math.Max(1, PageCount));
}
