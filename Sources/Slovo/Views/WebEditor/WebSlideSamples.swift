import Foundation
import SlovoCore

/// Чем наполнить слайд в предпросмотре.
///
/// Ползунки без текста обманывают: на «Бытие 1:1» влезает что угодно, а на
/// 118-м псалме тот же кегль уезжает за край экрана. Поэтому образцы —
/// не украшение, а способ увидеть беду до собрания: самый короткий стих,
/// самый длинный, два перевода рядом, куплет песни с переносами строк и
/// объявление в фойе.
struct WebSlideSample: Identifiable, Hashable {

    let id: String
    let titleSource: String
    var title: String { OurWords.t(titleSource) }
    /// Чем эта проба опасна для оформления.
    let purposeSource: String
    var purpose: String { OurWords.t(purposeSource) }
    var text: String
    var second: String
    var reference: String
    var next: String
    var songTitle: String
    /// «Bible», «Text» или «Song» — по этому страницы решают, брать ли стих
    /// в кавычки и чистить ли текст песни.
    var mode: String
    var pageCurrent: Int
    var pageCount: Int

    static let all: [WebSlideSample] = [
        .init(id: "short",
              titleSource: "Короткий стих",
              purposeSource: "Одна строка. Видно, не теряется ли текст посреди пустого экрана.",
              text: "На початку Бог створив Небо та землю.",
              second: "",
              reference: "Буття 1:1",
              next: "А земля була пуста та порожня…",
              songTitle: "",
              mode: "Bible",
              pageCurrent: 0, pageCount: 1),

        .init(id: "long",
              titleSource: "Длинный стих",
              purposeSource: "Самая длинная проба. Если текст не влезает — уменьшайте кегль или включайте подбор.",
              text: "Тож благаю вас, браття, через Боже милосердя, повіддавайте ваші тіла на жертву "
                  + "живу, святу, приємну Богові, як розумну службу вашу, і не стосуйтесь до віку цього, "
                  + "але перемініться відновою вашого розуму, щоб пізнати вам, що то є воля Божа, "
                  + "добро, приємність та досконалість.",
              second: "",
              reference: "Римлян 12:1-2",
              next: "Через дану мені благодать кажу кожному з вас…",
              songTitle: "",
              mode: "Bible",
              pageCurrent: 0, pageCount: 1),

        .init(id: "two",
              titleSource: "Два перевода",
              purposeSource: "Второй перевод под текстом или рядом колонкой. Видно, хватает ли ширины.",
              text: "Так бо Бог полюбив світ, що дав Сина Свого Однородженого, "
                  + "щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне.",
              second: "For God so loved the world, that he gave his only begotten Son, "
                  + "that whosoever believeth in him should not perish, but have everlasting life.",
              reference: "Івана 3:16",
              next: "Бо Бог не послав Свого Сина на світ, щоб Він світ засудив…",
              songTitle: "",
              mode: "Bible",
              pageCurrent: 0, pageCount: 1),

        .init(id: "song",
              titleSource: "Куплет песни",
              purposeSource: "Переносы строк, название песни, без адреса и без кавычек.",
              text: "Який Ти великий, Боже,\nсповнений величі,\nі гідний хвали Ти!\nУся земля співає Тобі.",
              second: "",
              reference: "Куплет 2",
              next: "Приспів: Господь мій Бог!",
              songTitle: "№ 128 · Який Ти великий, Боже",
              mode: "Song",
              pageCurrent: 0, pageCount: 1),

        .init(id: "pages",
              titleSource: "Длинный текст по страницам",
              purposeSource: "«2 из 3» — проверка подписи о том, что текст разбит на несколько экранов.",
              text: "І сказав Бог: Хай станеться світло! І сталося світло. І побачив Бог світло, що добре воно, "
                  + "і Бог відділив світло від темряви.",
              second: "",
              reference: "Буття 1:3-4",
              next: "І Бог назвав світло: День, а темряву назвав: Ніч.",
              songTitle: "",
              mode: "Bible",
              pageCurrent: 1, pageCount: 3),

        .init(id: "notice",
              titleSource: "Объявление",
              purposeSource: "Простой текст без адреса — так выглядит объявление или заставка в фойе.",
              text: "Молитовне зібрання — у середу о 18:30",
              second: "",
              reference: "",
              next: "",
              songTitle: "",
              mode: "Text",
              pageCurrent: 0, pageCount: 1),
    ]

    /// Взять то, что программа показывает прямо сейчас.
    static func fromSlide(text: String, second: String, reference: String) -> WebSlideSample {
        .init(id: "live",
              titleSource: "Со слайда программы",
              purposeSource: "То, что сейчас на экране в зале.",
              text: text,
              second: second,
              reference: reference,
              next: "",
              songTitle: "",
              mode: "Bible",
              pageCurrent: 0, pageCount: 1)
    }

    /// Подмена соединения для этой пробы.
    func shim(hidden: Bool) -> String {
        WebSlideTemplates.previewShim(text: text,
                                      second: second,
                                      reference: reference,
                                      next: next,
                                      mode: mode,
                                      songTitle: songTitle,
                                      hidden: hidden,
                                      pageCurrent: pageCurrent,
                                      pageCount: max(1, pageCount))
    }
}
