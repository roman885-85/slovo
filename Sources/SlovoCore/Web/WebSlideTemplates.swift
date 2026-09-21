import Foundation

/// Заготовки веб-слайдів.
///
/// В оригіналі такого немає: там сторінки пишуть руками, а в налаштуваннях лише
/// перелічують готові файли. Операторові без досвіду це непідйомно, тому
/// тут зібрано робочі сторінки під часті задачі — їх можна взяти і
/// правити, бачачи результат.
///
/// Кожна заготовка цілком самостійна: підключається до того самого
/// WebSocket, що й сторінки автора, і розбирає той самий пакет. Отже її
/// можна відкрити на телефоні або підкласти в OBS без жодних доробок.
///
/// Головна відмінність від колишніх шести: усе оформлення винесено у змінні
/// одного блоку нагорі сторінки. Повзунок у вікні редактора міняє значення
/// змінної — і вигляд міняється цілком, а не впирається в зашите число.
/// Тому в кожної заготовки є ще й список імен змінних, які
/// для неї осмислені: за ним вікно показує лише потрібні ручки, а не
/// всі п'ятдесят.
public enum WebSlideTemplates {

    // MARK: - Ручки оформлення

    /// Одна ручка: ім'я змінної, як її назвати людині і чим її крутити.
    ///
    /// Значення тут не зберігається навмисно. Значення живе в самій сторінці,
    /// у блоці «Налаштування сторінки», — інакше після ручної правки файла вікно
    /// показувало б одне, а браузер малював інше.
    public struct Parameter: Sendable, Hashable, Identifiable {

        public struct Option: Sendable, Hashable {
            public let value: String
            public let label: String
            public init(_ value: String, _ label: String) {
                self.value = value
                self.label = label
            }
        }

        public enum Kind: Sendable, Hashable {
            /// Повзунок. Значення — голе число, без одиниць: одиницю
            /// підставляє CSS, інакше повзунок довелося б учити писати «vw».
            case number(min: Double, max: Double, step: Double)
            /// Колір звичайним записом «#rrggbb».
            case color
            /// Колір трійкою «R G B» — щоб поруч працювала окрема прозорість.
            case colorRGB
            case choice([Option])
            case toggle(on: String, off: String)
            /// Рядок: посилання на картинку, роздільник рядків, напис заставки.
            case text
        }

        public let id: String
        public let group: String
        public let label: String
        public let kind: Kind
        /// Що людина побачить на екрані, якщо покрутить цю ручку.
        public let hint: String

        public init(_ id: String, _ group: String, _ label: String,
                    _ kind: Kind, _ hint: String) {
            self.id = id
            self.group = group
            self.label = label
            self.kind = kind
            self.hint = hint
        }
    }

    private static func opt(_ pairs: [(String, String)]) -> Parameter.Kind {
        .choice(pairs.map { Parameter.Option($0.0, $0.1) })
    }

    /// Усі ручки, які взагалі бувають. Заготовка бере з цього списку свої.
    public static let parameters: [Parameter] = [

        // ── Вміст ─────────────────────────────────────────────────────
        .init("--sl-ref", "Содержимое", "Показывать адрес",
              .toggle(on: "block", off: "none"),
              "Строка вроде «Бытие 1:1» рядом с текстом."),
        .init("--sl-ref-each", "Содержимое", "Свой адрес у каждого перевода",
              .toggle(on: "block", off: "none"),
              "У разных переводов разбивка стихов расходится, поэтому адрес бывает разный."),
        .init("--sl-second", "Содержимое", "Показывать второй перевод",
              .toggle(on: "block", off: "none"),
              "Второй перевод включается в главном окне; здесь только показ."),
        .init("--sl-next", "Содержимое", "Показывать следующий стих",
              .toggle(on: "block", off: "none"),
              "Нижняя полоса с тем, что пойдёт дальше."),
        .init("--sl-song-title", "Содержимое", "Показывать название песни",
              .toggle(on: "block", off: "none"),
              "Название и номер куплета над текстом."),
        .init("--sl-page", "Содержимое", "Показывать «2 из 3»",
              .toggle(on: "block", off: "none"),
              "Когда длинный текст разбит на несколько экранов."),
        .init("--sl-clock", "Содержимое", "Показывать часы",
              .toggle(on: "block", off: "none"),
              "Время по часам того устройства, где открыта страница."),
        .init("--sl-quotes", "Содержимое", "Брать стих в кавычки",
              .toggle(on: "1", off: "0"),
              "Только в режиме Библии; куплет песни в кавычки не берут."),
        .init("--sl-breaks", "Содержимое", "Сохранять переносы строк",
              .toggle(on: "1", off: "0"),
              "Выключите — строки куплета склеятся в одну через разделитель."),
        .init("--sl-joiner", "Содержимое", "Чем склеивать строки",
              .text,
              "Работает, когда переносы строк выключены. У автора это « * »."),
        .init("--sl-idle", "Содержимое", "Надпись между слайдами",
              .text,
              "Показывается вместо текста, когда в зале пустой экран."),

        // ── Розташування ──────────────────────────────────────────────
        .init("--sl-anchor-x", "Расположение", "Блок по горизонтали",
              opt([("flex-start", "слева"), ("center", "по центру"), ("flex-end", "справа")]),
              "К какому краю кадра прижат текст."),
        .init("--sl-anchor-y", "Расположение", "Блок по вертикали",
              opt([("flex-start", "вверху"), ("center", "по центру"), ("flex-end", "внизу")]),
              "Вместе с горизонталью даёт девять положений."),
        .init("--sl-width", "Расположение", "Ширина блока, %",
              .number(min: 20, max: 100, step: 1),
              "Узкая колонка читается легче широкой строки во весь экран."),
        .init("--sl-safe", "Расположение", "Поля от краёв",
              .number(min: 0, max: 20, step: 0.5),
              "Запас, чтобы текст не срезал край экрана или кадра."),
        .init("--sl-align", "Расположение", "Выравнивание текста",
              opt([("left", "слева"), ("center", "по центру"),
                   ("right", "справа"), ("justify", "по ширине")]),
              "«По ширине» ровняет правый край, но рвёт просветы между словами."),
        .init("--sl-gap", "Расположение", "Просвет между блоками",
              .number(min: 0, max: 8, step: 0.25),
              "Расстояние между адресом, текстом и остальными строками."),
        .init("--sl-columns", "Расположение", "Переводы: столбиком или рядом",
              opt([("column", "друг под другом"), ("row", "рядом, в две колонки")]),
              "Рядом помещается меньше букв, зато видно соответствие строк."),
        .init("--sl-ref-order", "Расположение", "Адрес над текстом или под ним",
              opt([("-1", "над текстом"), ("1", "под текстом")]),
              "Порядок строк внутри блока."),
        .init("--sl-next-share", "Расположение", "Доля высоты под следующий, %",
              .number(min: 10, max: 50, step: 1),
              "Сколько экрана отдано нижней полосе со следующим текстом."),

        // ── Шрифт ─────────────────────────────────────────────────────
        .init("--sl-font", "Шрифт", "Шрифт",
              opt([("\"Helvetica Neue\", Arial, sans-serif", "без засечек"),
                   ("Georgia, \"Times New Roman\", serif", "с засечками"),
                   ("\"Avenir Next Condensed\", \"Arial Narrow\", sans-serif", "узкий"),
                   ("\"SF Mono\", Menlo, monospace", "равноширинный"),
                   ("-apple-system, system-ui, sans-serif", "как в системе")]),
              "Берётся тот шрифт, что стоит на устройстве, где открыта страница."),
        .init("--sl-unit", "Шрифт", "Размер мерить от",
              opt([("1vw", "ширины экрана"), ("1vh", "высоты экрана")]),
              "На вертикальном экране телефона удобнее мерить от высоты."),
        .init("--sl-size", "Шрифт", "Размер текста",
              .number(min: 1.5, max: 20, step: 0.1),
              "При включённом подборе это верхний предел, а не сам размер."),
        .init("--sl-weight", "Шрифт", "Насыщенность",
              .number(min: 100, max: 900, step: 10),
              "700 — полужирный, 900 — самый жирный."),
        .init("--sl-stretch", "Шрифт", "Ширина букв",
              opt([("condensed", "узкие"), ("normal", "обычные"), ("expanded", "широкие")]),
              "Действует только на шрифты, у которых есть такие начертания."),
        .init("--sl-italic", "Шрифт", "Наклонный",
              .toggle(on: "italic", off: "normal"),
              "Наклонный текст на дальнем экране читается хуже прямого."),
        .init("--sl-caps", "Шрифт", "Прописными",
              .toggle(on: "uppercase", off: "none"),
              "СПЛОШЬ ПРОПИСНЫЕ читаются медленнее — годятся для коротких строк."),
        .init("--sl-tracking", "Шрифт", "Разрядка",
              .number(min: -0.05, max: 0.2, step: 0.005),
              "Просвет между буквами, в долях размера шрифта."),
        .init("--sl-line", "Шрифт", "Межстрочный просвет",
              .number(min: 0.9, max: 2.2, step: 0.05),
              "Для слабовидящих ставят 1,4-1,5, для титров хватает 1,15."),
        .init("--sl-color", "Шрифт", "Цвет текста", .color,
              "Светлое на тёмном в зале читается лучше, чем наоборот."),
        .init("--sl-accent", "Шрифт", "Цвет адреса и подписей", .color,
              "Адрес, название песни, часы и подпись «Следующий»."),
        .init("--sl-second-color", "Шрифт", "Цвет второго перевода", .color,
              "Обычно приглушённее основного, чтобы не спорил с ним."),
        .init("--sl-second-scale", "Шрифт", "Размер второго перевода",
              .number(min: 0.4, max: 1.2, step: 0.05),
              "Доля от основного: 0,8 — заметно мельче, 1 — вровень."),
        .init("--sl-next-color", "Шрифт", "Цвет следующего", .color,
              "Нижняя полоса не должна перетягивать взгляд с текущего текста."),
        .init("--sl-next-scale", "Шрифт", "Размер следующего",
              .number(min: 0.3, max: 1, step: 0.05),
              "Доля от основного размера."),
        .init("--sl-ref-scale", "Шрифт", "Размер адреса",
              .number(min: 0.2, max: 1, step: 0.05),
              "Доля от основного размера."),
        .init("--sl-title-scale", "Шрифт", "Размер названия песни",
              .number(min: 0.2, max: 1.2, step: 0.05),
              "Доля от основного размера."),
        .init("--sl-clock-scale", "Шрифт", "Размер часов",
              .number(min: 0.2, max: 1, step: 0.05),
              "Доля от основного размера."),
        .init("--sl-text-opacity", "Шрифт", "Непрозрачность текста",
              .number(min: 0, max: 1, step: 0.05),
              "1 — плотный текст, 0,6 — притушенный."),
        .init("--sl-fit", "Шрифт", "Подбирать размер под длину текста",
              .toggle(on: "1", off: "0"),
              "Длинный стих уменьшится сам, чтобы влезть целиком."),
        .init("--sl-fit-min", "Шрифт", "Наименьший размер при подборе, px",
              .number(min: 8, max: 120, step: 1),
              "Ниже этого страница не опустится, даже если текст не влезает."),

        // ── Обведення і тінь ──────────────────────────────────────────
        .init("--sl-stroke", "Обводка и тень", "Толщина обводки",
              .number(min: 0, max: 1, step: 0.05),
              "Обводка спасает текст на пёстром фоне и на засвеченном экране."),
        .init("--sl-stroke-color", "Обводка и тень", "Цвет обводки", .color,
              "Обычно берут цвет, противоположный цвету текста."),
        .init("--sl-shadow", "Обводка и тень", "Сила тени",
              .number(min: 0, max: 1, step: 0.05),
              "Мягкая тень отделяет текст от фона, но размывает края букв."),
        .init("--sl-shadow-rgb", "Обводка и тень", "Цвет тени", .colorRGB,
              "Почти всегда чёрный."),

        // ── Фон ───────────────────────────────────────────────────────
        .init("--sl-bg-rgb", "Фон", "Цвет фона", .colorRGB,
              "Виден и сам по себе, и пока грузится картинка."),
        .init("--sl-bg-opacity", "Фон", "Непрозрачность фона",
              .number(min: 0, max: 1, step: 0.05),
              "0 — фон полностью прозрачный, как для видеомикшера."),
        .init("--sl-image", "Фон", "Картинка фоном", .text,
              "Ссылка вида url(\"file:///…/фон.jpg\"). Берите не меньше 1920×1080."),
        .init("--sl-dim", "Фон", "Затемнение картинки",
              .number(min: 0, max: 1, step: 0.05),
              "На пёстрой фотографии текст теряется — поднимите до 0,5-0,6."),
        .init("--sl-plate-rgb", "Фон", "Цвет подложки под текстом", .colorRGB,
              "Подложка — прямоугольник под самим текстом, а не весь фон."),
        .init("--sl-plate-opacity", "Фон", "Непрозрачность подложки",
              .number(min: 0, max: 1, step: 0.05),
              "0 — подложки нет вовсе."),
        .init("--sl-plate-radius", "Фон", "Скругление подложки",
              .number(min: 0, max: 6, step: 0.25),
              "0 — прямые углы."),
        .init("--sl-plate-pad", "Фон", "Отступы внутри подложки",
              .number(min: 0, max: 8, step: 0.25),
              "Воздух между краем подложки и буквами."),
        .init("--sl-plate-fit", "Фон", "Подложка",
              opt([("stretch", "во всю ширину блока"), ("center", "по размеру текста")]),
              "«По размеру текста» — как на титрах у автора."),

        // ── Поведінка ─────────────────────────────────────────────────
        .init("--sl-fade", "Поведение", "Плавность смены, мс",
              .number(min: 0, max: 1000, step: 25),
              "0 — мгновенно. Текст меняется перекладкой двух слоёв, без мигания."),
        .init("--sl-hide", "Поведение", "Когда в зале пустой экран",
              opt([("all", "спрятать всё"),
                   ("text", "убрать текст, оставить оформление"),
                   ("mark", "оставить текст и предупредить"),
                   ("idle", "показать заставку")]),
              "Экран служителя не должен слепнуть вместе с залом."),
    ]

    public static func parameter(id: String) -> Parameter? {
        parameters.first { $0.id == id }
    }

    // MARK: - Заготовка

    public struct Template: Sendable, Identifiable, Hashable {
        public let id: String
        public let title: String
        /// Для чого ця сторінка — показується поруч зі списком.
        public let purpose: String
        /// На що дивитися, якщо захочеться поправити.
        public let hint: String
        /// Імена змінних, осмислених для цієї сторінки: за ними вікно
        /// показує лише потрібні ручки.
        public let parameterNames: [String]
        public let html: String

        /// Ті самі ручки, але з описами — у порядку, в якому вони стоять у файлі.
        public var parameters: [Parameter] {
            parameterNames.compactMap { WebSlideTemplates.parameter(id: $0) }
        }
    }

    public static let all: [Template] = presets.map { $0.template }

    public static func template(id: String) -> Template? {
        all.first { $0.id == id }
    }

    // MARK: - Склад заготовок

    /// Заготовка до збирання: значення ручок і добавка до оформлення.
    ///
    /// Список значень — єдине джерело і для сторінки, і для
    /// `parameterNames`. Розійтися вони не можуть за побудовою: вікно ніколи
    /// не покаже ручку, якої немає у файлі, і не сховає ту, що є.
    private struct Preset {
        let id: String
        let title: String
        let purpose: String
        let hint: String
        let values: [(String, String)]
        /// Правила, які для цієї сторінки жорсткі: повзунка їм не дають.
        var fixed: String = ""

        var template: Template {
            Template(id: id, title: title, purpose: purpose, hint: hint,
                     parameterNames: values.map { $0.0 },
                     html: WebSlideTemplates.page(title: title, values: values, fixed: fixed))
        }
    }

    /// Порядок тут — порядок вибору у вікні «Нова сторінка»: від найпростішої
    /// до найособливішої.
    private static let presets: [Preset] = [
        plainPreset, picturePreset, twoPreset, songPreset, contrastPreset,
        lowerPreset, overlayPreset, stagePreset, phonePreset, foyerPreset,
    ] + biblePresets + subtitlePresets + songPresets

    // 1 ─────────────────────────────────────────────────────────────────
    private static let plainPreset = Preset(
        id: "plain",
        title: "Стих на цвете",
        purpose: "Обычный слайд на второй экран в зале: текст по центру на однотонном фоне. С него проще всего начать.",
        hint: "Смотрите цвет фона и цвет текста в самом верху: тёмный фон и светлый текст в зале читаются лучше, чем наоборот. Длинный стих не влезает — уменьшите размер.",
        values: [
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", "center"),
            ("--sl-width", "90"),
            ("--sl-safe", "5"),
            ("--sl-align", "center"),
            ("--sl-gap", "2"),
            ("--sl-columns", "column"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "6"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "700"),
            ("--sl-stretch", "normal"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.25"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-second-color", "#cfe0ff"),
            ("--sl-second-scale", "0.8"),
            ("--sl-ref-scale", "0.45"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", "0.5"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-bg-rgb", "11 26 51"),
            ("--sl-bg-opacity", "1"),
            ("--sl-fade", "200"),
            ("--sl-hide", "all"),
        ])

    // 2 ─────────────────────────────────────────────────────────────────
    private static let picturePreset = Preset(
        id: "picture",
        title: "Стих на картинке",
        purpose: "То же, но поверх фотографии: подходит для тихого чтения и для заставки перед служением.",
        hint: "Смотрите ссылку на картинку и затемнение: на пёстрой фотографии текст теряется, поднимите затемнение до 0,5-0,6 или включите подложку.",
        values: [
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", "center"),
            ("--sl-width", "82"),
            ("--sl-safe", "6"),
            ("--sl-align", "center"),
            ("--sl-gap", "2"),
            ("--sl-columns", "column"),
            ("--sl-font", "Georgia, \"Times New Roman\", serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "5.4"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "600"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.3"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffe6b0"),
            ("--sl-second-color", "#e6eeff"),
            ("--sl-second-scale", "0.8"),
            ("--sl-ref-scale", "0.45"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", "0.7"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-bg-rgb", "10 18 30"),
            ("--sl-bg-opacity", "1"),
            ("--sl-image", "linear-gradient(160deg, #1d3f63 0%, #0a1420 100%)"),
            ("--sl-dim", "0.45"),
            ("--sl-plate-rgb", "0 0 0"),
            ("--sl-plate-opacity", "0.2"),
            ("--sl-plate-radius", "2"),
            ("--sl-plate-pad", "2.5"),
            ("--sl-plate-fit", "stretch"),
            ("--sl-fade", "300"),
            ("--sl-hide", "all"),
        ])

    // 3 ─────────────────────────────────────────────────────────────────
    private static let twoPreset = Preset(
        id: "two",
        title: "Два перевода",
        purpose: "Оба перевода сразу: основной крупно, второй помельче — для собраний, где читают на двух языках.",
        hint: "Смотрите переключатель «столбиком или рядом» и размер второго перевода: два перевода — это вдвое больше букв, размер обычно приходится уменьшать.",
        values: [
            ("--sl-second", "block"),
            ("--sl-ref", "none"),
            ("--sl-ref-each", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-columns", "column"),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", "center"),
            ("--sl-width", "92"),
            ("--sl-safe", "4"),
            ("--sl-align", "center"),
            ("--sl-gap", "2"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "4.2"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "700"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.2"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-second-color", "#bcd2f5"),
            ("--sl-second-scale", "0.85"),
            ("--sl-ref-scale", "0.4"),
            ("--sl-text-opacity", "1"),
            ("--sl-shadow", "0.45"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-bg-rgb", "16 35 63"),
            ("--sl-bg-opacity", "1"),
            ("--sl-image", "none"),
            ("--sl-dim", "0"),
            ("--sl-fade", "200"),
            ("--sl-hide", "all"),
        ])

    // 4 ─────────────────────────────────────────────────────────────────
    private static let songPreset = Preset(
        id: "song",
        title: "Экран песни",
        purpose: "Куплет песни на большом экране: сверху название, ниже сам куплет. Адреса здесь нет.",
        hint: "Смотрите «сохранять переносы строк»: в куплете строки стоят там, где их поставил автор. Выключите — и куплет склеится в одну строку через разделитель, как на прежних страницах.",
        values: [
            ("--sl-song-title", "block"),
            ("--sl-title-scale", "0.5"),
            ("--sl-page", "block"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-joiner", "\" * \""),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", "center"),
            ("--sl-width", "88"),
            ("--sl-safe", "5"),
            ("--sl-align", "center"),
            ("--sl-gap", "2.5"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "5.4"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "700"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.35"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-ref-scale", "0.4"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", "0.5"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-bg-rgb", "12 30 26"),
            ("--sl-bg-opacity", "1"),
            ("--sl-image", "none"),
            ("--sl-dim", "0"),
            ("--sl-plate-rgb", "0 0 0"),
            ("--sl-plate-opacity", "0"),
            ("--sl-plate-radius", "2"),
            ("--sl-plate-pad", "0"),
            ("--sl-plate-fit", "stretch"),
            ("--sl-fade", "250"),
            ("--sl-hide", "all"),
        ],
        fixed: """
            /* Жорстко для цієї сторінки: у куплета немає адреси, а в режимі
               Библии та же страница прячет название и возвращает адрес — её
               можно держать открытой всё служение и не переключать.

               Кавычки правилом здесь больше не выключаются: скрипт берёт в
               кавычки только режим Библии, а куплет не тронет и при
               включённых кавычках. Значит ручке место в блоке настроек, а не в
               объявлении вне его: любое «--sl-…: …» за пределами блока
               редактор по праву считает правкой руками. */
            .reference { display: none; }
            body.mode-bible .reference, body.mode-text .reference { display: block; }
            body.mode-bible .song, body.mode-text .song { display: none; }
            """)

    // 5 ─────────────────────────────────────────────────────────────────
    private static let contrastPreset = Preset(
        id: "contrast",
        title: "Крупно и контрастно",
        purpose: "Для дальнего ряда и для тех, кто плохо видит: максимально крупно, толстая обводка, никаких украшений.",
        hint: "Смотрите пару цветов и толщину обводки. Размер подбирается сам: не гонитесь за верхним пределом, лучше поднимите нижний. Фотографию фоном здесь не берут — контраст важнее красоты.",
        values: [
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-anchor-x", "center"),
            ("--sl-width", "94"),
            ("--sl-safe", "3"),
            ("--sl-align", "center"),
            ("--sl-gap", "1.5"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "11"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "34"),
            ("--sl-weight", "900"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0.01"),
            ("--sl-line", "1.45"),
            ("--sl-color", "#ffe74a"),
            ("--sl-accent", "#f2f2f2"),
            ("--sl-ref-scale", "0.3"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0.35"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-bg-rgb", "0 0 0"),
            ("--sl-bg-opacity", "1"),
            ("--sl-fade", "0"),
            ("--sl-hide", "all"),
        ],
        fixed: fitLayout + """
            /* Ні тіні, ні підкладки: розмиті краї заважають тим, заради кого ця
               страница и сделана. Объявлять их нулями здесь незачем — без
               строки в блоке настроек каркас и так берёт ноль запасным
               значением, а лишнее «--sl-…: …» вне блока редактор считал бы
               правкой руками и предупреждал бы о ней человека. */
            """)

    // 6 ─────────────────────────────────────────────────────────────────
    private static let lowerPreset = Preset(
        id: "lower",
        title: "Титры внизу экрана",
        purpose: "Узкая полоса с текстом внизу кадра — чтобы положить поверх картинки в OBS или vMix.",
        hint: "Смотрите подложку и поля от краёв: титры не должны лезть в самый низ кадра. В браузере прозрачный фон выглядит белым — так и должно быть, в видеомикшере будет видна камера.",
        values: [
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-second", "none"),
            ("--sl-quotes", "0"),
            ("--sl-breaks", "1"),
            ("--sl-width", "100"),
            ("--sl-safe", "6"),
            ("--sl-align", "center"),
            ("--sl-gap", "1"),
            ("--sl-columns", "column"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "3.4"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "700"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.15"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-second-color", "#cfe0ff"),
            ("--sl-second-scale", "0.8"),
            ("--sl-ref-scale", "0.5"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", "0.6"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-plate-rgb", "0 0 0"),
            ("--sl-plate-opacity", "0.55"),
            ("--sl-plate-radius", "1.5"),
            ("--sl-plate-pad", "2"),
            ("--sl-plate-fit", "stretch"),
            ("--sl-fade", "250"),
            ("--sl-hide", "all"),
        ],
        fixed: """
            /* Жорстко: фон прозорий — картинку під титрами дає відеомікшер,
               а сама полоса всегда прижата к низу кадра. */
            body { background: transparent; }
            .slide { justify-content: flex-end; align-items: center; }
            """)

    // 7 ─────────────────────────────────────────────────────────────────
    private static let overlayPreset = Preset(
        id: "overlay",
        title: "Прозрачный слой в полный кадр",
        purpose: "Текст в любом углу кадра поверх трансляции — когда нужна не полоса внизу, а стих сбоку, вверху или по центру.",
        hint: "Смотрите положение блока и его ширину. В OBS снимите у источника «Браузер» галочку «Отключать источник, когда не виден», иначе после переключения сцены страница придёт пустой, и ставьте размер источника ровно в размер канвы.",
        values: [
            ("--sl-anchor-x", "flex-start"),
            ("--sl-anchor-y", "flex-start"),
            ("--sl-width", "46"),
            ("--sl-safe", "6"),
            ("--sl-align", "left"),
            ("--sl-gap", "1.2"),
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-second", "none"),
            ("--sl-page", "none"),
            ("--sl-quotes", "0"),
            ("--sl-breaks", "1"),
            ("--sl-columns", "column"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "2.8"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", "700"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.2"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-second-color", "#cfe0ff"),
            ("--sl-second-scale", "0.8"),
            ("--sl-ref-scale", "0.5"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", "0"),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", "0.6"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-plate-rgb", "0 0 0"),
            ("--sl-plate-opacity", "0.45"),
            ("--sl-plate-radius", "1.5"),
            ("--sl-plate-pad", "2"),
            ("--sl-plate-fit", "center"),
            ("--sl-fade", "250"),
            ("--sl-hide", "all"),
        ],
        fixed: """
            /* Жорстко: фон прозорий — що під текстом, вирішує відеомікшер. */
            body { background: transparent; }
            """)

    // 8 ─────────────────────────────────────────────────────────────────
    private static let stagePreset = Preset(
        id: "stage",
        title: "Экран служителя",
        purpose: "Монитор на кафедре: текущий стих крупно, следующий помельче внизу — проповедник видит, что будет дальше.",
        hint: "Смотрите долю высоты под следующий текст и размер часов. Внизу пусто — значит очередь не задана, подставлять нечего. Пустой экран в зале этой странице намеренно не указ.",
        values: [
            ("--sl-next", "block"),
            ("--sl-next-share", "30"),
            ("--sl-next-color", "#93a6bd"),
            ("--sl-next-scale", "0.5"),
            ("--sl-ref", "block"),
            ("--sl-ref-order", "-1"),
            ("--sl-second", "none"),
            ("--sl-page", "block"),
            ("--sl-clock", "block"),
            ("--sl-clock-scale", "0.4"),
            ("--sl-breaks", "1"),
            ("--sl-width", "100"),
            ("--sl-safe", "3"),
            ("--sl-align", "center"),
            ("--sl-gap", "1.5"),
            ("--sl-columns", "column"),
            ("--sl-font", "\"Helvetica Neue\", Arial, sans-serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "7"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "16"),
            ("--sl-weight", "700"),
            ("--sl-caps", "none"),
            ("--sl-line", "1.2"),
            ("--sl-color", "#ffffff"),
            ("--sl-accent", "#ffd98a"),
            ("--sl-second-color", "#bcd2f5"),
            ("--sl-second-scale", "0.8"),
            ("--sl-ref-scale", "0.32"),
            ("--sl-text-opacity", "1"),
            ("--sl-bg-rgb", "0 0 0"),
            ("--sl-bg-opacity", "1"),
            ("--sl-fade", "0"),
            ("--sl-hide", "mark"),
        ],
        fixed: fitLayout + """
            /* Розкладка службова — три смуги згори вниз. Ні картинки, ні
               подложки, ни кавычек: этих строк нет в блоке настроек, а без
               них каркас берёт запасные значения, и они как раз пустые.
               Объявлять их здесь нулями нельзя — «--sl-…: …» вне блока
               настроек редактор по праву считает правкой руками. */
            .slide { justify-content: flex-start; }
            """)

    // 9 ─────────────────────────────────────────────────────────────────
    private static let phonePreset = Preset(
        id: "phone",
        title: "Телефон помощника",
        purpose: "Вертикальная страница на телефон регенту или помощнику: крупно текущий текст, под ним следующий, и больше ничего.",
        hint: "Смотрите размер текущего и следующего. Открывается по QR-коду со стартовой страницы веб-слайдов. Телефон гасит экран сам — запретите автоблокировку в его настройках, страница этого сделать не может.",
        values: [
            ("--sl-next", "block"),
            ("--sl-next-share", "32"),
            ("--sl-next-color", "#8e9aab"),
            ("--sl-next-scale", "0.55"),
            ("--sl-ref", "block"),
            ("--sl-ref-order", "-1"),
            ("--sl-song-title", "block"),
            ("--sl-title-scale", "0.4"),
            ("--sl-page", "block"),
            ("--sl-second", "none"),
            ("--sl-breaks", "1"),
            ("--sl-width", "100"),
            ("--sl-safe", "3"),
            ("--sl-align", "center"),
            ("--sl-gap", "1.5"),
            ("--sl-font", "-apple-system, system-ui, sans-serif"),
            ("--sl-unit", "1vh"),
            ("--sl-size", "4.6"),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "15"),
            ("--sl-weight", "600"),
            ("--sl-line", "1.3"),
            ("--sl-color", "#f2f5fa"),
            ("--sl-accent", "#e0b25f"),
            ("--sl-ref-scale", "0.45"),
            ("--sl-text-opacity", "1"),
            ("--sl-bg-rgb", "12 14 18"),
            ("--sl-bg-opacity", "1"),
            ("--sl-fade", "0"),
            ("--sl-hide", "mark"),
        ],
        fixed: fitLayout + """
            /* Вертикальна розкладка під великий палець. Тіней, обведень і
               подложек нет — на маленьком экране они только мешают, а без
               строки в блоке настроек каркас и так берёт пустое запасное
               значение. Объявления «--sl-…: …» вне блока здесь не место:
               редактор считает такое правкой руками. */
            .slide { justify-content: flex-start; }
            """)

    // 10 ────────────────────────────────────────────────────────────────
    private static let foyerPreset = Preset(
        id: "foyer",
        title: "Монитор в фойе",
        purpose: "Спокойный экран в фойе или в детской: что сейчас читают в зале, время, а между слайдами — приветственная надпись вместо чёрного экрана.",
        hint: "Смотрите надпись заставки и часы. Экран в фойе смотрят с трёх метров, а не с двадцати: не делайте буквы во весь экран, и меняйте текст медленно.",
        values: [
            ("--sl-clock", "block"),
            ("--sl-clock-scale", "0.45"),
            ("--sl-ref", "block"),
            ("--sl-ref-order", "1"),
            ("--sl-song-title", "block"),
            ("--sl-title-scale", "0.45"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-idle", "\"Раді вас бачити\""),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", "center"),
            ("--sl-width", "80"),
            ("--sl-safe", "8"),
            ("--sl-align", "center"),
            ("--sl-gap", "2.5"),
            ("--sl-columns", "column"),
            ("--sl-font", "Georgia, \"Times New Roman\", serif"),
            ("--sl-unit", "1vw"),
            ("--sl-size", "3.6"),
            ("--sl-weight", "600"),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", "1.4"),
            ("--sl-color", "#f4efe6"),
            ("--sl-accent", "#d8b478"),
            ("--sl-ref-scale", "0.5"),
            ("--sl-text-opacity", "1"),
            ("--sl-shadow", "0.4"),
            ("--sl-shadow-rgb", "0 0 0"),
            ("--sl-bg-rgb", "24 22 20"),
            ("--sl-bg-opacity", "1"),
            ("--sl-image", "linear-gradient(200deg, #2c2622 0%, #14110f 100%)"),
            ("--sl-dim", "0.2"),
            ("--sl-plate-rgb", "0 0 0"),
            ("--sl-plate-opacity", "0.25"),
            ("--sl-plate-radius", "2"),
            ("--sl-plate-pad", "3"),
            ("--sl-plate-fit", "stretch"),
            ("--sl-fade", "700"),
            ("--sl-hide", "idle"),
        ],
        fixed: """
            /* Текст не зіщулюється до нечитабельного, а обрізається — у фойє
               лучше половина стиха крупно, чем весь стих мелко. Подбор кегля
               для этого просто не включают: строки «--sl-fit» в блоке
               настроек нет, а без неё скрипт подбор не заводит. Объявлять
               нули вне блока нельзя — редактор считает их правкой руками. */
            .stack { max-height: 70vh; }
            """)

    /// Розкладка для сторінок з добором кегля: щоб добирати розмір під
    /// висоту, ця висота має бути визначеною, а не «скільки тексту».

    // MARK: - Десять сторінок для Біблії і десять для пісень
    //
    // Власник: «добавь 10 шаблонов в веб для показа Библии и 10 для песен».
    // Кожна — ті самі ручки, що й у перших десяти, але своя пара «фон —
    // текст», свій шрифт і своє місце адреси, щоб вибирати за залом, а не
    // перефарбовувати одну й ту саму.

    /// Спільні для всіх біблійних сторінок значення: адреса одним рядком,
    /// другого перекладу немає, лапки і переноси — як в автора.
    private static func bibleValues(font: String, size: String, weight: String, line: String,
                                    color: String, accent: String, background: String,
                                    align: String = "center", anchorY: String = "center",
                                    refOrder: String = "1", refScale: String = "0.45",
                                    stroke: String = "0", shadow: String = "0.5",
                                    width: String = "90", extra: [(String, String)] = []) -> [(String, String)] {
        [
            ("--sl-ref", "block"),
            ("--sl-ref-order", refOrder),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", anchorY),
            ("--sl-width", width),
            ("--sl-safe", "5"),
            ("--sl-align", align),
            ("--sl-gap", "2"),
            ("--sl-columns", "column"),
            ("--sl-font", font),
            ("--sl-unit", "1vw"),
            ("--sl-size", size),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", weight),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", line),
            ("--sl-color", color),
            ("--sl-accent", accent),
            ("--sl-ref-scale", refScale),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", stroke),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", shadow),
            ("--sl-shadow-rgb", "0 0 0"),
            // Накладання, як у сторінок автора: сторінка прозора, а колір —
            // це плашка рівно під текстом. Власник: «весь смысл — наложить
            // текст поверх картинки, опционально с фоном под ним».
            ("--sl-bg-rgb", background),
            ("--sl-bg-opacity", "0"),
            ("--sl-image", "none"),
            ("--sl-dim", "0"),
            ("--sl-plate-rgb", background),
            ("--sl-plate-opacity", "0.55"),
            ("--sl-plate-radius", "1.2"),
            ("--sl-plate-pad", "1.5"),
            ("--sl-plate-fit", "center"),
            ("--sl-fade", "200"),
            ("--sl-hide", "all"),
        ].overriding(extra)
    }

    /// Спільні для пісенних сторінок: назва зверху, адреси немає, переноси
    /// куплета зберігаються.
    private static func songValues(font: String, size: String, weight: String, line: String,
                                   color: String, accent: String, background: String,
                                   align: String = "center", anchorY: String = "center",
                                   titleScale: String = "0.5", stroke: String = "0",
                                   shadow: String = "0.5", width: String = "88",
                                   extra: [(String, String)] = []) -> [(String, String)] {
        [
            ("--sl-song-title", "block"),
            ("--sl-title-scale", titleScale),
            ("--sl-page", "block"),
            ("--sl-second", "none"),
            ("--sl-quotes", "1"),
            ("--sl-breaks", "1"),
            ("--sl-joiner", "\" * \""),
            ("--sl-anchor-x", "center"),
            ("--sl-anchor-y", anchorY),
            ("--sl-width", width),
            ("--sl-safe", "5"),
            ("--sl-align", align),
            ("--sl-gap", "2.5"),
            ("--sl-font", font),
            ("--sl-unit", "1vw"),
            ("--sl-size", size),
            ("--sl-fit", "1"),
            ("--sl-fit-min", "18"),
            ("--sl-weight", weight),
            ("--sl-italic", "normal"),
            ("--sl-caps", "none"),
            ("--sl-tracking", "0"),
            ("--sl-line", line),
            ("--sl-color", color),
            ("--sl-accent", accent),
            ("--sl-ref-scale", "0.4"),
            ("--sl-text-opacity", "1"),
            ("--sl-stroke", stroke),
            ("--sl-stroke-color", "#000000"),
            ("--sl-shadow", shadow),
            ("--sl-shadow-rgb", "0 0 0"),
            // Накладання: сторінка прозора, колір — плашка під куплетом.
            ("--sl-bg-rgb", background),
            ("--sl-bg-opacity", "0"),
            ("--sl-image", "none"),
            ("--sl-dim", "0"),
            ("--sl-plate-rgb", background),
            ("--sl-plate-opacity", "0.55"),
            ("--sl-plate-radius", "1.2"),
            ("--sl-plate-pad", "1.5"),
            ("--sl-plate-fit", "center"),
            ("--sl-fade", "250"),
            ("--sl-hide", "all"),
        ].overriding(extra)
    }


    /// Правила пісенної сторінки: без адреси; у режимі Біблії та сама
    /// сторінка ховає назву і повертає адресу.
    private static let songFixed = """
        .reference { display: none; }
        body.mode-bible .reference, body.mode-text .reference { display: block; }
        body.mode-bible .song, body.mode-text .song { display: none; }
        """

    private static let serif = "Georgia, \"Times New Roman\", serif"
    private static let sans = "\"Helvetica Neue\", Arial, sans-serif"
    private static let rounded = "\"Avenir Next\", \"Helvetica Neue\", Arial, sans-serif"
    private static let narrow = "\"Arial Narrow\", \"Helvetica Neue\", Arial, sans-serif"

    private static let biblePresets: [Preset] = [
        Preset(id: "bible-night", title: "Библия: ночное небо",
               purpose: "Тёмно-синяя плашка под стихом с засечками, адрес золотом снизу; страница прозрачна — для наложения на картинку или видео.",
               hint: "Шрифт с засечками читается издалека хуже рубленого: если зал длинный, поменяйте шрифт.",
               values: bibleValues(font: serif, size: "5.6", weight: "600", line: "1.3",
                                   color: "#f6f1e4", accent: "#e8c56a", background: "8 16 40")),
        Preset(id: "bible-parchment", title: "Библия: пергамент",
               purpose: "Светлая тёплая плашка и тёмный текст — для светлых залов; страница прозрачна.",
               hint: "Тень тут выключена: на светлом фоне она грязнит буквы.",
               values: bibleValues(font: serif, size: "5.4", weight: "600", line: "1.3",
                                   color: "#2b2117", accent: "#8a5a1e", background: "243 233 210",
                                   shadow: "0")),
        Preset(id: "bible-teal", title: "Библия: бирюза",
               purpose: "Бирюзовый фон, белый рубленый текст, адрес сверху — как заголовок.",
               hint: "Адрес сверху: смотрите «порядок адреса».",
               values: bibleValues(font: sans, size: "6", weight: "700", line: "1.25",
                                   color: "#ffffff", accent: "#ffe9a8", background: "10 84 92",
                                   refOrder: "-1")),
        Preset(id: "bible-paper", title: "Библия: чёрным по белому",
               purpose: "Белый фон и чёрный жирный текст — самый контрастный вариант для яркого помещения.",
               hint: "Если экран телевизор, а не проектор, уменьшите размер: белое поле слепит.",
               values: bibleValues(font: sans, size: "5.8", weight: "800", line: "1.25",
                                   color: "#111111", accent: "#a11d1d", background: "255 255 255",
                                   shadow: "0")),
        Preset(id: "bible-wine", title: "Библия: бордо",
               purpose: "Винный фон, кремовый текст с засечками, адрес по левому краю.",
               hint: "Выключка влево: длинные стихи так читаются ровнее.",
               values: bibleValues(font: serif, size: "5.4", weight: "600", line: "1.32",
                                   color: "#f3e6d3", accent: "#f0c987", background: "74 16 28",
                                   align: "left")),
        Preset(id: "bible-forest", title: "Библия: лес",
               purpose: "Тёмно-зелёный фон, светлый текст, адрес снизу мелко — спокойный вариант для вечерних служений.",
               hint: "Адрес мелкий: «доля адреса» 0,35 — увеличьте, если его читают с задних рядов.",
               values: bibleValues(font: rounded, size: "5.6", weight: "600", line: "1.3",
                                   color: "#eef5ea", accent: "#bfe3a6", background: "18 44 30",
                                   refScale: "0.35")),
        Preset(id: "bible-graphite", title: "Библия: графит крупно",
               purpose: "Графитовый фон и очень крупный рубленый текст: для больших залов и коротких стихов.",
               hint: "Автоподбор кегля ужмёт длинный стих; нижний предел — 18.",
               values: bibleValues(font: sans, size: "7", weight: "800", line: "1.18",
                                   color: "#ffffff", accent: "#ffd98a", background: "34 34 38",
                                   width: "94")),
        Preset(id: "bible-plate", title: "Библия: синий с плашкой",
               purpose: "Синий фон, а под стихом полупрозрачная плашка по размеру текста — текст не спорит с фоном-картинкой, если её подложить.",
               hint: "Плашка: цвет, прозрачность и поля — в разделе «Подложка под текстом».",
               values: bibleValues(font: sans, size: "5.6", weight: "700", line: "1.25",
                                   color: "#ffffff", accent: "#ffe08a", background: "20 48 96",
                                   extra: [("--sl-plate-rgb", "0 0 0"), ("--sl-plate-opacity", "0.45"),
                                           ("--sl-plate-radius", "2"), ("--sl-plate-pad", "2"),
                                           ("--sl-plate-fit", "center")])),
        Preset(id: "bible-outline", title: "Библия: с обводкой",
               purpose: "Белый текст с чёрной обводкой на нейтральном фоне — читается и поверх картинки, и поверх видео.",
               hint: "Толщина обводки — «Обводка» в разделе текста; для мелкого текста ставьте 0,2–0,3.",
               values: bibleValues(font: sans, size: "6", weight: "800", line: "1.25",
                                   color: "#ffffff", accent: "#ffd98a", background: "60 60 70",
                                   stroke: "0.35", shadow: "0.3")),
        Preset(id: "bible-lower", title: "Библия: титр внизу",
               purpose: "Прозрачная страница: стих полосой в нижней трети — для наложения на видео в микшере.",
               hint: "Фон прозрачный: «прозрачность фона» 0. Полоса — «Подложка под текстом» во всю ширину.",
               values: bibleValues(font: sans, size: "4.2", weight: "700", line: "1.2",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.5", width: "100",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "0 0 0"),
                                           ("--sl-plate-opacity", "0.6"), ("--sl-plate-radius", "0"),
                                           ("--sl-plate-pad", "1.5"), ("--sl-plate-fit", "stretch")])),
    ]

    /// Десять сторінок «текст Біблії внизу екрана, як субтитри» — власник
    /// просив окремо: смуга в нижній третині, решта прозора (для
    /// накладання на відео в мікшері) або на своєму фоні.
    private static let subtitlePresets: [Preset] = [
        Preset(id: "bible-sub-plain", title: "Субтитры: белым на чёрной полосе",
               purpose: "Классические субтитры: белый рубленый текст на полупрозрачной чёрной полосе во всю ширину, страница прозрачная.",
               hint: "Прозрачность полосы — «Подложка под текстом»; для телевизора в зале поднимите до 0,8.",
               values: bibleValues(font: sans, size: "3.6", weight: "700", line: "1.2",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.55", width: "100",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "0 0 0"),
                                           ("--sl-plate-opacity", "0.65"), ("--sl-plate-radius", "0"),
                                           ("--sl-plate-pad", "1.2"), ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-outline", title: "Субтитры: с обводкой, без полосы",
               purpose: "Белый текст с чёрной обводкой внизу кадра, полосы нет — так подписывают фильмы.",
               hint: "Обводка 0,4 в сотых высоты; для мелкого кегля возьмите 0,25.",
               values: bibleValues(font: sans, size: "3.8", weight: "800", line: "1.2",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.55", stroke: "0.4", shadow: "0.2", width: "94",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-opacity", "0")])),
        Preset(id: "bible-sub-yellow", title: "Субтитры: жёлтым, как в кино",
               purpose: "Жёлтый текст с тёмной обводкой внизу — самые читаемые субтитры на пёстром видео.",
               hint: "Цвет текста — «Цвет текста»; адрес тем же цветом, но мельче.",
               values: bibleValues(font: sans, size: "3.8", weight: "700", line: "1.2",
                                   color: "#ffe14d", accent: "#ffe14d", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.5", stroke: "0.35", shadow: "0.3", width: "94",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-opacity", "0")])),
        Preset(id: "bible-sub-serif", title: "Субтитры: с засечками на тёмной полосе",
               purpose: "Кремовый текст с засечками на тёмно-синей полосе — спокойный вариант для чтения длинных стихов.",
               hint: "Межстрочный просвет 1,3 — две строки не слипаются.",
               values: bibleValues(font: serif, size: "3.6", weight: "600", line: "1.3",
                                   color: "#f6f1e4", accent: "#e8c56a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.55", width: "100",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "8 16 40"),
                                           ("--sl-plate-opacity", "0.85"), ("--sl-plate-radius", "0"),
                                           ("--sl-plate-pad", "1.2"), ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-box", title: "Субтитры: плашка по размеру текста",
               purpose: "Тёмная плашка ровно под строками, со скруглением — не полоса во всю ширину.",
               hint: "«Подложка» → «по размеру текста»; скругление и поля там же.",
               values: bibleValues(font: sans, size: "3.6", weight: "700", line: "1.2",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.55", width: "90",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "0 0 0"),
                                           ("--sl-plate-opacity", "0.7"), ("--sl-plate-radius", "1.2"),
                                           ("--sl-plate-pad", "1.5"), ("--sl-plate-fit", "center")])),
        Preset(id: "bible-sub-left", title: "Субтитры: слева, адрес сверху",
               purpose: "Текст прижат к левому краю нижней трети, адрес над ним — как бегущая подпись в новостях.",
               hint: "Выключка и положение — «Расположение».",
               values: bibleValues(font: rounded, size: "3.4", weight: "700", line: "1.2",
                                   color: "#ffffff", accent: "#9fd3ff", background: "0 0 0",
                                   align: "left", anchorY: "flex-end", refOrder: "-1", refScale: "0.5", width: "100",
                                   extra: [("--sl-anchor-x", "flex-start"), ("--sl-bg-opacity", "0"),
                                           ("--sl-plate-rgb", "0 0 0"), ("--sl-plate-opacity", "0.6"),
                                           ("--sl-plate-radius", "0"), ("--sl-plate-pad", "1.2"),
                                           ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-light", title: "Субтитры: тёмным на светлой полосе",
               purpose: "Для светлого видео и проектора в светлом зале: тёмный текст на полупрозрачной белой полосе.",
               hint: "Тень выключена — на светлом она грязнит буквы.",
               values: bibleValues(font: sans, size: "3.6", weight: "700", line: "1.2",
                                   color: "#111111", accent: "#8a1d1d", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.55", shadow: "0", width: "100",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "255 255 255"),
                                           ("--sl-plate-opacity", "0.8"), ("--sl-plate-radius", "0"),
                                           ("--sl-plate-pad", "1.2"), ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-big", title: "Субтитры: крупно для большого зала",
               purpose: "Крупнее обычных субтитров, полоса выше — с задних рядов читается.",
               hint: "Размер 4,6 от ширины; автоподбор ужмёт длинный стих.",
               values: bibleValues(font: sans, size: "4.6", weight: "800", line: "1.18",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.5", stroke: "0.2", width: "100",
                                   extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "0 0 0"),
                                           ("--sl-plate-opacity", "0.6"), ("--sl-plate-radius", "0"),
                                           ("--sl-plate-pad", "1.4"), ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-two", title: "Субтитры: два перевода строками",
               purpose: "Основной перевод и второй под ним, мельче — для двуязычного собрания.",
               hint: "Второй перевод включается в главном окне; здесь его размер и цвет.",
               values: bibleValues(font: sans, size: "3.4", weight: "700", line: "1.2",
                                   color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                   anchorY: "flex-end", refScale: "0.5", width: "100",
                                   extra: [("--sl-second", "block"), ("--sl-second-color", "#bcd2f5"),
                                           ("--sl-second-scale", "0.85"), ("--sl-bg-opacity", "0"),
                                           ("--sl-plate-rgb", "0 0 0"), ("--sl-plate-opacity", "0.65"),
                                           ("--sl-plate-radius", "0"), ("--sl-plate-pad", "1.2"),
                                           ("--sl-plate-fit", "stretch")])),
        Preset(id: "bible-sub-dark", title: "Субтитры: на своём тёмном фоне",
               purpose: "Не прозрачная страница, а свой тёмный фон с текстом внизу — для второго экрана, где видео нет.",
               hint: "Фон — «Фон страницы»; цвет и картинку меняйте там.",
               values: bibleValues(font: rounded, size: "3.8", weight: "700", line: "1.22",
                                   color: "#ffffff", accent: "#ffd98a", background: "18 18 24",
                                   anchorY: "flex-end", refScale: "0.55", width: "94",
                                   extra: [("--sl-plate-opacity", "0")])),
    ]

    private static let songPresets: [Preset] = [
        Preset(id: "song-night", title: "Песня: ночь",
               purpose: "Тёмный фон, крупный белый куплет, название сверху золотом.",
               hint: "Межстрочный интервал 1,4: куплет дышит, строки не слипаются.",
               values: songValues(font: sans, size: "5.6", weight: "700", line: "1.4",
                                  color: "#ffffff", accent: "#e8c56a", background: "10 14 32"),
               fixed: songFixed),
        Preset(id: "song-parchment", title: "Песня: пергамент",
               purpose: "Светлый тёплый фон, тёмный куплет с засечками — для светлого зала.",
               hint: "Тень выключена: на светлом фоне она лишняя.",
               values: songValues(font: serif, size: "5.2", weight: "600", line: "1.4",
                                  color: "#2b2117", accent: "#8a5a1e", background: "243 233 210",
                                  shadow: "0"),
               fixed: songFixed),
        Preset(id: "song-teal", title: "Песня: бирюза",
               purpose: "Бирюзовый фон, белый куплет, название крупнее обычного.",
               hint: "Размер названия — «доля названия»; здесь 0,6.",
               values: songValues(font: rounded, size: "5.4", weight: "700", line: "1.4",
                                  color: "#ffffff", accent: "#ffe9a8", background: "10 84 92",
                                  titleScale: "0.6"),
               fixed: songFixed),
        Preset(id: "song-paper", title: "Песня: белая",
               purpose: "Белый фон и чёрный жирный куплет — самый контрастный для яркого помещения.",
               hint: "На телевизоре белое поле слепит — уменьшите размер или возьмите «пергамент».",
               values: songValues(font: sans, size: "5.4", weight: "800", line: "1.38",
                                  color: "#111111", accent: "#a11d1d", background: "255 255 255",
                                  shadow: "0"),
               fixed: songFixed),
        Preset(id: "song-wine", title: "Песня: бордо",
               purpose: "Винный фон, кремовый куплет с засечками, выключка влево.",
               hint: "Влево удобно для длинных строк куплета.",
               values: songValues(font: serif, size: "5.2", weight: "600", line: "1.42",
                                  color: "#f3e6d3", accent: "#f0c987", background: "74 16 28",
                                  align: "left"),
               fixed: songFixed),
        Preset(id: "song-forest", title: "Песня: лес",
               purpose: "Тёмно-зелёный фон, светлый куплет, спокойный вечерний вариант.",
               hint: "Название мелкое: «доля названия» 0,4.",
               values: songValues(font: rounded, size: "5.4", weight: "600", line: "1.4",
                                  color: "#eef5ea", accent: "#bfe3a6", background: "18 44 30",
                                  titleScale: "0.4"),
               fixed: songFixed),
        Preset(id: "song-graphite", title: "Песня: графит крупно",
               purpose: "Графитовый фон и очень крупный куплет для большого зала.",
               hint: "Длинный куплет ужмётся автоподбором; следите за нижним пределом кегля.",
               values: songValues(font: sans, size: "6.4", weight: "800", line: "1.3",
                                  color: "#ffffff", accent: "#ffd98a", background: "34 34 38",
                                  width: "94"),
               fixed: songFixed),
        Preset(id: "song-plate", title: "Песня: с плашкой",
               purpose: "Синий фон, куплет на полупрозрачной плашке по размеру текста — под картинку или видео.",
               hint: "Плашка настраивается в «Подложке под текстом».",
               values: songValues(font: sans, size: "5.4", weight: "700", line: "1.38",
                                  color: "#ffffff", accent: "#ffe08a", background: "20 48 96",
                                  extra: [("--sl-plate-rgb", "0 0 0"), ("--sl-plate-opacity", "0.45"),
                                          ("--sl-plate-radius", "2"), ("--sl-plate-pad", "2"),
                                          ("--sl-plate-fit", "center")]),
               fixed: songFixed),
        Preset(id: "song-outline", title: "Песня: с обводкой",
               purpose: "Белый куплет с чёрной обводкой — читается поверх любой картинки и видео.",
               hint: "Обводка 0,35; для мелкого текста ставьте меньше.",
               values: songValues(font: sans, size: "5.6", weight: "800", line: "1.36",
                                  color: "#ffffff", accent: "#ffd98a", background: "60 60 70",
                                  stroke: "0.35", shadow: "0.3"),
               fixed: songFixed),
        Preset(id: "song-lower", title: "Песня: титр внизу",
               purpose: "Прозрачная страница: куплет полосой в нижней трети — для наложения на видео в микшере.",
               hint: "Фон прозрачный, полоса — подложка во всю ширину.",
               values: songValues(font: sans, size: "4", weight: "700", line: "1.3",
                                  color: "#ffffff", accent: "#ffe08a", background: "0 0 0",
                                  anchorY: "flex-end", titleScale: "0.45", width: "100",
                                  extra: [("--sl-bg-opacity", "0"), ("--sl-plate-rgb", "0 0 0"),
                                          ("--sl-plate-opacity", "0.6"), ("--sl-plate-radius", "0"),
                                          ("--sl-plate-pad", "1.5"), ("--sl-plate-fit", "stretch")]),
               fixed: songFixed),
    ]

    private static let fitLayout = """
        .box { flex: 1 1 auto; min-height: 0; }
        .plate { flex: 1 1 auto; min-height: 0; justify-content: center; }
        .stack { flex: 1 1 auto; min-height: 0; }

        """

    // MARK: - Збирання сторінки

    /// Блок налаштувань — у тому самому вигляді, який читає і переписує
    /// `WebSlideParameters`.
    ///
    /// Мітка `data-slovo="vars"` і обидві риски-маркери тут не прикраса: за
    /// ними модель параметрів упізнає свій блок. Поки їх не було, вона вважала
    /// власні значення заготовки правкою руками, а на перший рух
    /// повзунка дописувала перед `</head>` ще один `:root` — і у файлі
    /// виявлялося два набори налаштувань, з яких працює невідомо який.
    ///
    /// Підписів у рядків більше немає, і це плата за спільний вигляд. Розбір моделі
    /// визнає рядок лише цілком — «--ім'я: значення;», — а підпис у
    /// кінці рядка цю крапку з комою відводить. Заголовки розділів лишилися:
    /// коментар окремим рядком розбір пропускає мовчки.
    ///
    /// Своя позначка «Настройки страницы» стоїть поруч зі спільною міткою навмисно:
    /// за нею панель майстерні впізнає заготовку і показує її власні
    /// три-чотири десятки ручок, а не всі сімдесят дві спільного каталогу.
    private static func settingsBlock(_ values: [(String, String)]) -> String {
        var lines: [String] = []
        var group = ""
        for (name, value) in values {
            let parameter = parameters.first { $0.id == name }
            if let parameter, parameter.group != group {
                group = parameter.group
                lines.append("")
                lines.append("  /* \(OurWords.t(group)) */")
            }
            // Рядок збирається тим самим кодом, що й у спільному блоці: розійтися
            // в пробілі навколо двокрапки — значить розійтися в розборі.
            lines.append("  " + WebSlideParameters.declaration(name, value))
        }
        // Порядок рядків — свій, а не каталожний: він же стає порядком
        // ручок у панелі, і людина чекає їх розділами, як у файлі.
        return """
        <style \(WebSlideParameters.varsAttribute)>
        /* \(WebSlideParameters.varsMarker) \(WebSlideParameters.varsToken) v\(WebSlideParameters.version) ──────
           \(OurWords.t("Настройки страницы: их и двигают ползунки мастерской."))
           \(OurWords.t("Править руками можно, но пишите строго по одной «--имя: значение;»."))
           \(OurWords.t("Всё прочее внутри блока редактор сотрёт при следующей правке.")) */
        :root {
        \(lines.joined(separator: "\n").trimmingCharacters(in: .newlines))
        }
        /* \(WebSlideParameters.varsEndMarker) \(WebSlideParameters.varsEndToken) ── \(OurWords.t("Конец настроек страницы")) ── */
        </style>
        """
    }

    /// Порядок тегів у голові сторінки вибрано, а не склався сам.
    ///
    /// Каркас іде першим, блок значень — останнім, упритул до `</head>`.
    /// Тому дві причини, і обидві про те, щоб файл не мінявся в людини за
    /// спиною.
    ///
    /// Перша: правила каркаса лише читають значення через `var(--sl-…)` і
    /// самі не оголошують жодного `--sl-…`. Поки це так, забити значення з
    /// блоку каркасу нічим. Але варто комусь дописати в каркас `:root` —
    /// і, стій блок раніше, каркас мовчки переміг би його за каскадом. Блок
    /// останній, отже останнє слово за ним.
    ///
    /// Друга: рівно перед `</head>` кладе свій блок і сама
    /// `WebSlideParameters.write` — у сторінку, де блоку ще немає. Друкуючи
    /// заготовку в тому самому порядку, ми отримуємо файл, який після першого ж
    /// запису виглядає так само, як виглядав до нього.
    private static func page(title: String,
                             values: [(String, String)],
                             fixed: String) -> String {
        // Пояснення в розмітці — для того, хто править сторінку; у готовий
        // файл вони йшли російською, і власник бачив їх у редакторі. Лишаємо
        // лише маркери блоку налаштувань і назви груп, решту прибираємо:
        // пояснення живуть у коді програми, а не в сторінці залу.
        stripNotes("""
        <!DOCTYPE html>
        <html lang="\(OurWords.language)">
        <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(OurWords.t("Слайд")) — \(OurWords.t(title))</title>
        <style>
        \(frame)
        \(fixed)
        </style>
        \(settingsBlock(values))
        </head>
        <body>
        \(markup)
        <script>
        \(script)
        </script>
        </body>
        </html>
        """)
    }

    /// Прибирає з готової сторінки пояснювальні коментарі російською,
    /// не чіпаючи маркерів блоку налаштувань і назв груп.
    private static func stripNotes(_ page: String) -> String {
        var result = ""
        var rest = Substring(page)
        while let open = rest.range(of: "/*") {
            let head = rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "*/", range: open.upperBound..<rest.endIndex) else {
                result += head + rest[open.lowerBound...]
                return result
            }
            let body = rest[open.upperBound..<close.lowerBound]
            let keep = WebSlideParameters.markerRange(varsNeedles, in: body) != nil
                || body.count < 40
            result += head
            if keep { result += "/*" + body + "*/" }
            else {
                // Лишаємо перенос рядка, щоб розмітка не з'їжджала.
                result += body.contains("\n") ? "" : ""
            }
            rest = rest[close.upperBound...]
        }
        return result + rest
    }

    /// Що не можна вирізати зі сторінки разом із поясненнями: мітки блоку
    /// налаштувань, включно з мітками попередніх випусків.
    private static let varsNeedles = WebSlideParameters.varsMarkers
        + WebSlideParameters.varsEndMarkers
        + [WebSlideParameters.varsToken, WebSlideParameters.varsEndToken]

    // MARK: - Розмітка

    /// Розмітка одна на всі десять: сторінки різняться лише значеннями
    /// змінних. Що не потрібно цій сторінці — ховається змінною, а не
    /// вирізається з файла, інакше повзунок не було б чим увімкнути назад.
    private static let markup = """
        <div class="slide" data-slovo="stage">
          <div class="box">
            <div class="plate">
              <div class="song empty"></div>
              <div class="reference empty" data-slovo="reference"></div>
              <div class="stack">
                <div class="layer" id="layerA"></div>
                <div class="layer" id="layerB"></div>
              </div>
              <div class="page empty"></div>
              <div class="clock empty"></div>
            </div>
          </div>
          <div class="idle"></div>
          <div class="nextbar empty">
            <span class="label">\(OurWords.t("Следующий"))</span>
            <div class="next" data-slovo="next"></div>
          </div>
        </div>
        <div class="status">\(OurWords.t("Нет связи с программой. Пробуем соединиться…"))</div>
        <div class="mark">\(OurWords.t("В зале сейчас пустой экран"))</div>
        """

    // MARK: - Каркас оформлення

    /// Правила, які читають змінні з блоку налаштувань.
    ///
    /// У кожної змінної тут стоїть запасне значення: сторінка оголошує
    /// лише свої ручки, а решта має поводитися розумно сама.
    private static let frame = """
        /* ── Каркас. Усе береться з налаштувань вище ───────────────── */
        * { box-sizing: border-box; margin: 0; padding: 0; }
        html, body { height: 100%; overflow: hidden; -webkit-text-size-adjust: none; }
        body {
          font-family: var(--sl-font, "Helvetica Neue", Arial, sans-serif);
          background: rgb(var(--sl-bg-rgb, 8 16 32) / var(--sl-bg-opacity, 1));
        }

        /* Короткі імена з перших заготовок: сторінки, зібрані
           копированием, продолжают работать без правок. */
        :root {
          --text: var(--sl-color, #ffffff);
          --accent: var(--sl-accent, #ffd98a);
          --size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))));
        }

        .slide {
          position: relative; z-index: 0; height: 100%;
          display: flex; flex-direction: column;
          align-items: var(--sl-anchor-x, center);
          justify-content: var(--sl-anchor-y, center);
          gap: calc(var(--sl-gap, 2) * 1vh);
          padding: calc(var(--sl-safe, 5) * 1vh) calc(var(--sl-safe, 5) * 1vw);
        }
        .slide::before, .slide::after { content: ""; position: fixed; top: 0; right: 0; bottom: 0; left: 0; inset: 0; z-index: -1; }
        .slide::before { background-image: var(--sl-image, none);
                         background-size: cover; background-position: center; }
        .slide::after { background: rgb(0 0 0 / var(--sl-dim, 0)); }

        .box { position: relative; width: calc(var(--sl-width, 90) * 1%);
               max-width: 100%; min-height: 0; display: flex; flex-direction: column; }
        .plate {
          display: flex; flex-direction: column; min-height: 0;
          gap: calc(var(--sl-gap, 2) * 1vh);
          align-self: var(--sl-plate-fit, stretch);
          background: rgb(var(--sl-plate-rgb, 0 0 0) / var(--sl-plate-opacity, 0));
          border-radius: calc(var(--sl-plate-radius, 0) * 1vh);
          padding: calc(var(--sl-plate-pad, 0) * 1vh) calc(var(--sl-plate-pad, 0) * 1.4vh);
          animation: var(--sl-plate-in, none) calc(var(--sl-fade, 200) * 1ms) ease both;
        }
        /* Підкладка йде своїм ефектом, коли в залі порожньо. */
        body.hide-all .plate { animation: var(--sl-plate-out, none) calc(var(--sl-fade, 200) * 1ms) ease both; }


        /* ── Двадцять ефектів появи і зникнення ─────────────────────
           Текст и подложка выбирают их независимо: --sl-anim-in/out для
           текста, --sl-plate-in/out для подложки. Владелец просил набор
           готовых эффектов, где текст и его подложка живут своей жизнью. */
        @keyframes vhod-rastvorenie { from { opacity: 0 } to { opacity: 1 } }
        @keyframes vyhod-rastvorenie { from { opacity: 1 } to { opacity: 0 } }
        @keyframes vhod-snizu { from { opacity: 0; transform: translateY(8vh) } to { opacity: 1; transform: none } }
        @keyframes vyhod-vverh { from { opacity: 1; transform: none } to { opacity: 0; transform: translateY(-8vh) } }
        @keyframes vhod-sverhu { from { opacity: 0; transform: translateY(-8vh) } to { opacity: 1; transform: none } }
        @keyframes vyhod-vniz { from { opacity: 1; transform: none } to { opacity: 0; transform: translateY(8vh) } }
        @keyframes vhod-sleva { from { opacity: 0; transform: translateX(-10vw) } to { opacity: 1; transform: none } }
        @keyframes vyhod-vpravo { from { opacity: 1; transform: none } to { opacity: 0; transform: translateX(10vw) } }
        @keyframes vhod-sprava { from { opacity: 0; transform: translateX(10vw) } to { opacity: 1; transform: none } }
        @keyframes vyhod-vlevo { from { opacity: 1; transform: none } to { opacity: 0; transform: translateX(-10vw) } }
        @keyframes vhod-naplyv { from { opacity: 0; transform: scale(.88) } to { opacity: 1; transform: none } }
        @keyframes vyhod-naplyv { from { opacity: 1; transform: none } to { opacity: 0; transform: scale(1.12) } }
        @keyframes vhod-otdalenie { from { opacity: 0; transform: scale(1.14) } to { opacity: 1; transform: none } }
        @keyframes vyhod-otdalenie { from { opacity: 1; transform: none } to { opacity: 0; transform: scale(.86) } }
        @keyframes vhod-razmytie { from { opacity: 0; filter: blur(1.2vh) } to { opacity: 1; filter: none } }
        @keyframes vyhod-razmytie { from { opacity: 1; filter: none } to { opacity: 0; filter: blur(1.2vh) } }
        @keyframes vhod-perevorot { from { opacity: 0; transform: perspective(80vh) rotateX(70deg) } to { opacity: 1; transform: none } }
        @keyframes vyhod-perevorot { from { opacity: 1; transform: none } to { opacity: 0; transform: perspective(80vh) rotateX(-70deg) } }
        @keyframes vhod-povorot { from { opacity: 0; transform: rotate(-6deg) scale(.9) } to { opacity: 1; transform: none } }
        @keyframes vyhod-povorot { from { opacity: 1; transform: none } to { opacity: 0; transform: rotate(6deg) scale(.9) } }
        @keyframes vhod-otskok { 0% { opacity: 0; transform: translateY(-12vh) } 60% { opacity: 1; transform: translateY(1.5vh) } 100% { transform: none } }
        @keyframes vyhod-otskok { 0% { transform: none } 30% { transform: translateY(-1.5vh) } 100% { opacity: 0; transform: translateY(12vh) } }
        @keyframes vhod-pruzhina { 0% { opacity: 0; transform: scale(.7) } 60% { opacity: 1; transform: scale(1.06) } 100% { transform: none } }
        @keyframes vyhod-pruzhina { 0% { transform: none } 40% { transform: scale(1.06) } 100% { opacity: 0; transform: scale(.7) } }
        @keyframes vhod-shtorka-vpravo { from { clip-path: inset(0 100% 0 0) } to { clip-path: inset(0 0 0 0) } }
        @keyframes vyhod-shtorka-vpravo { from { clip-path: inset(0 0 0 0) } to { clip-path: inset(0 0 0 100%) } }
        @keyframes vhod-shtorka-vlevo { from { clip-path: inset(0 0 0 100%) } to { clip-path: inset(0 0 0 0) } }
        @keyframes vyhod-shtorka-vlevo { from { clip-path: inset(0 0 0 0) } to { clip-path: inset(0 100% 0 0) } }
        @keyframes vhod-shtorka-vniz { from { clip-path: inset(0 0 100% 0) } to { clip-path: inset(0 0 0 0) } }
        @keyframes vyhod-shtorka-vniz { from { clip-path: inset(0 0 0 0) } to { clip-path: inset(100% 0 0 0) } }
        @keyframes vhod-shtorka-vverh { from { clip-path: inset(100% 0 0 0) } to { clip-path: inset(0 0 0 0) } }
        @keyframes vyhod-shtorka-vverh { from { clip-path: inset(0 0 0 0) } to { clip-path: inset(0 0 100% 0) } }
        @keyframes vhod-zanaves { from { clip-path: inset(0 50% 0 50%) } to { clip-path: inset(0 0 0 0) } }
        @keyframes vyhod-zanaves { from { clip-path: inset(0 0 0 0) } to { clip-path: inset(0 50% 0 50%) } }
        @keyframes vhod-lupa { from { opacity: 0; transform: scale(.4); filter: blur(.8vh) } to { opacity: 1; transform: none; filter: none } }
        @keyframes vyhod-lupa { from { opacity: 1 } to { opacity: 0; transform: scale(.4); filter: blur(.8vh) } }
        @keyframes vhod-kachaniye { 0% { opacity: 0; transform: rotate(-4deg) } 50% { opacity: 1; transform: rotate(2deg) } 100% { transform: none } }
        @keyframes vyhod-kachaniye { 0% { transform: none } 50% { transform: rotate(-2deg) } 100% { opacity: 0; transform: rotate(4deg) } }
        @keyframes vhod-svechenie { from { opacity: 0; text-shadow: 0 0 3vh var(--sl-accent, #ffd98a) } to { opacity: 1 } }
        @keyframes vyhod-svechenie { from { opacity: 1 } to { opacity: 0; text-shadow: 0 0 3vh var(--sl-accent, #ffd98a) } }
        @keyframes vhod-padenie { 0% { opacity: 0; transform: translateY(-20vh) scale(1.1) } 100% { opacity: 1; transform: none } }
        @keyframes vyhod-padenie { 0% { transform: none } 100% { opacity: 0; transform: translateY(20vh) scale(.9) } }
        @keyframes vhod-vypolzanie { from { opacity: 0; transform: translateX(-6vw) skewX(8deg) } to { opacity: 1; transform: none } }
        @keyframes vyhod-vypolzanie { from { opacity: 1; transform: none } to { opacity: 0; transform: translateX(6vw) skewX(-8deg) } }
        @keyframes vhod-szhatie { from { opacity: 0; transform: scaleY(.2) } to { opacity: 1; transform: none } }
        @keyframes vyhod-szhatie { from { opacity: 1; transform: none } to { opacity: 0; transform: scaleY(.2) } }
        @keyframes vhod-razvorot { from { opacity: 0; transform: perspective(80vh) rotateY(80deg) } to { opacity: 1; transform: none } }
        @keyframes vyhod-razvorot { from { opacity: 1; transform: none } to { opacity: 0; transform: perspective(80vh) rotateY(-80deg) } }
        @keyframes vhod-mercanie { 0% { opacity: 0 } 40% { opacity: .8 } 55% { opacity: .25 } 100% { opacity: 1 } }
        @keyframes vyhod-mercanie { 0% { opacity: 1 } 45% { opacity: .3 } 60% { opacity: .75 } 100% { opacity: 0 } }
        @keyframes vhod-volna { 0% { opacity: 0; transform: translateY(6vh) skewY(3deg) } 60% { opacity: 1; transform: translateY(-1vh) skewY(-1deg) } 100% { transform: none } }
        @keyframes vyhod-volna { 0% { transform: none } 100% { opacity: 0; transform: translateY(-6vh) skewY(3deg) } }

        .stack { order: 0; display: grid; min-height: 0; overflow: hidden; }
        .layer {
          grid-area: 1 / 1; min-width: 0;
          display: flex; flex-direction: var(--sl-columns, column);
          gap: calc(var(--sl-gap, 2) * 1vh);
          opacity: 0;
          transition: opacity calc(var(--sl-fade, 200) * 1ms) linear;
        }
        .layer.on {
          opacity: var(--sl-text-opacity, 1);
          animation: var(--sl-anim-in, none) calc(var(--sl-fade, 200) * 1ms) ease both;
        }
        .layer:not(.on) { animation: var(--sl-anim-out, none) calc(var(--sl-fade, 200) * 1ms) ease both; }
        .col { flex: 1 1 0; min-width: 0; }
        .col-second { display: var(--sl-second, block); }

        .quote {
          color: var(--sl-color, #ffffff);
          font-size: var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw)));
          font-weight: var(--sl-weight, 700);
          font-style: var(--sl-italic, normal);
          font-stretch: var(--sl-stretch, normal);
          text-transform: var(--sl-caps, none);
          letter-spacing: calc(var(--sl-tracking, 0) * 1em);
          line-height: var(--sl-line, 1.25);
          text-align: var(--sl-align, center);
          text-shadow: 0 0.35vh calc(var(--sl-shadow, 0) * 1.6vh)
                       rgb(var(--sl-shadow-rgb, 0 0 0) / var(--sl-shadow, 0));
          -webkit-text-stroke: calc(var(--sl-stroke, 0) * 0.6vh) var(--sl-stroke-color, #000000);
          white-space: pre-wrap; word-wrap: break-word;
        }
        .second {
          color: var(--sl-second-color, #cfe0ff);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw)))
                          * var(--sl-second-scale, 0.8));
          font-style: italic;
          line-height: var(--sl-line, 1.25);
          text-align: var(--sl-align, center);
          white-space: pre-wrap; word-wrap: break-word;
        }
        .coltitle {
          display: var(--sl-ref-each, none);
          color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-ref-scale, 0.45));
          font-style: italic; text-align: var(--sl-align, center);
          margin-bottom: 0.6vh; opacity: 0.85;
        }

        .song {
          order: -2; display: var(--sl-song-title, none);
          color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-title-scale, 0.55));
          text-align: var(--sl-align, center);
        }
        .reference {
          order: var(--sl-ref-order, 1); display: var(--sl-ref, block);
          color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-ref-scale, 0.45));
          font-style: italic; text-align: var(--sl-align, center);
        }
        .page {
          order: 2; display: var(--sl-page, none);
          color: var(--sl-accent, #ffd98a); opacity: 0.7;
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw)))
                          * var(--sl-ref-scale, 0.45) * 0.8);
          text-align: var(--sl-align, center);
        }
        .clock {
          order: 3; display: var(--sl-clock, none);
          color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-clock-scale, 0.5));
          text-align: var(--sl-align, center);
        }

        .nextbar {
          display: var(--sl-next, none); position: relative; width: 100%;
          flex: 0 0 calc(var(--sl-next-share, 30) * 1%);
          min-height: 0; overflow: hidden;
          border-top: 1px solid rgb(255 255 255 / 0.25);
        }
        .nextbar .label {
          display: block; color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw)))
                          * var(--sl-ref-scale, 0.45) * 0.8);
          padding: 0.8vh 0 0.4vh; text-align: var(--sl-align, center);
        }
        .next {
          color: var(--sl-next-color, #9fb0c6);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-next-scale, 0.5));
          line-height: var(--sl-line, 1.25); text-align: var(--sl-align, center);
          white-space: pre-wrap; word-wrap: break-word;
          max-height: 100%; overflow: hidden;
        }

        .idle {
          display: none; position: relative; text-align: center;
          color: var(--sl-accent, #ffd98a);
          font-size: calc(var(--sl-auto, calc(var(--sl-size, 6) * var(--sl-unit, 1vw))) * var(--sl-title-scale, 0.6));
        }
        .idle::after { content: var(--sl-idle, ""); }

        .empty { display: none !important; }
        body.hide-all .box, body.hide-all .nextbar { visibility: hidden; }
        body.hide-idle .box, body.hide-idle .nextbar { display: none; }
        body.hide-idle .idle { display: block; }

        .mark, .status {
          display: none; position: fixed; left: 0; right: 0; z-index: 5;
          background: rgb(150 40 40 / 0.9); color: #ffffff;
          font-family: "Helvetica Neue", Arial, sans-serif;
          font-size: 2.2vh; text-align: center; padding: 0.6vh;
        }
        .status { top: 0; }
        .mark { bottom: 0; }
        body.offline .status { display: block; }
        body.hide-mark .mark { display: block; }
        """

    // MARK: - Зв'язок і розбір пакета

    /// Один і той самий скрипт в усіх десяти заготовках.
    ///
    /// В автора зв'язок переписано в кожній сторінці заново і в кожній зі
    /// своїми недоробками; тут він один: перепідключення, відбракування
    /// пакетів не по порядку, переведення «\\r\\n» у перенос рядка, перекладання
    /// двох шарів замість блимання і добір кегля за справжньою висотою.
    private static let script = """
        /* ── Зв'язок із програмою. Зазвичай міняти не треба ──────────
           Текст лежит в data.Slide.Var0.Text, адрес — в TitleCommon
           (а если его нет — в Var0.Title), второй перевод — в Var1,
           следующий слайд — в data.NextSlide. Событие HideSlide
           означает «в зале пустой экран».                             */
        (function () {
          var root = document.documentElement;
          var body = document.body;
          var stack = document.querySelector(".stack");
          var layers = [document.getElementById("layerA"), document.getElementById("layerB")];
          var front = 1;
          var lastKey = null;
          /* Останній показаний пакет. Потрібен майстерні: частина ручок
             считается не из CSS — подбор кегля, кавычки, переносы, — и без
             повторного показа они не оживают. */
          var lastData = null;
          var session = null;
          var seq = -1;
          var socket = null;
          var retryTimer = null;
          var resizeTimer = null;

          /* Значення читаємо з body, а не з кореня: тоді спрацює і правило,
             которое переопределяет ручку под режимом — «body.mode-bible …».
             Писать пример с настоящим именем ручки здесь нельзя: разбор
             настроек ищет объявления по всему файлу и счёл бы пример в
             комментарии правкой руками. */
          function css(name, fallback) {
            var value = getComputedStyle(body).getPropertyValue(name).trim();
            return value === "" ? fallback : value;
          }
          function number(name, fallback) {
            var value = parseFloat(css(name, ""));
            return isNaN(value) ? fallback : value;
          }
          function line(name, fallback) {
            var value = css(name, "");
            if (value === "") return fallback;
            return value.replace(/^["']/, "").replace(/["']$/, "");
          }
          function esc(value) {
            return String(value === undefined || value === null ? "" : value)
              .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
          }

          /* Переноси приходять послідовністю «\\r\\n». Без цієї заміни
             браузер склеит куплет в одну строку, и песню читать нельзя. */
          function shape(raw, mode) {
            var text = String(raw || "").replace(/\\*\\*\\*/g, "");
            text = text.replace(/[ \\t]+$/, "");
            var html = esc(text).replace(/\\r\\n|\\r|\\n/g, "\\u0000");
            if (number("--sl-breaks", 1) >= 1) {
              html = html.split("\\u0000").join("<br>");
            } else {
              html = html.split("\\u0000").filter(function (part) {
                return part.replace(/\\s+/g, "") !== "";
              }).join(esc(line("--sl-joiner", " * ")));
            }
            if (mode === "Bible" && number("--sl-quotes", 0) >= 1 && html !== "") {
              html = "\\u00ab" + html + "\\u00bb";
            }
            return html;
          }

          function column(kind, title, html) {
            var wrap = document.createElement("div");
            wrap.className = "col " + kind;
            var head = document.createElement("div");
            head.className = "coltitle";
            head.setAttribute("data-slovo", "reference");
            head.textContent = title || "";
            var text = document.createElement("div");
            text.className = kind === "col-main" ? "quote" : "second";
            /* Роль ставиться атрибутом: за ним сторінку знаходить розбір
               настроек, и он же стоит на страницах автора. */
            text.setAttribute("data-slovo", kind === "col-main" ? "quote" : "second");
            text.innerHTML = html;
            wrap.appendChild(head);
            wrap.appendChild(text);
            return wrap;
          }

          function fill(node, data) {
            var slide = data.Slide || {};
            var mode = data.Mode || "Bible";
            var first = slide.Var0 || {};
            var other = slide.Var1 || {};
            var hasSecond = (slide.VarsNum || 0) > 1 && !!other.Text;
            node.textContent = "";
            node.appendChild(column("col-main", first.Title, shape(first.Text, mode)));
            var second = column("col-second", other.Title, hasSecond ? shape(other.Text, mode) : "");
            if (!hasSecond) second.className += " empty";
            node.appendChild(second);
          }

          function setText(selector, value) {
            var node = document.querySelector(selector);
            if (!node) return;
            node.textContent = value || "";
            if (value) node.classList.remove("empty");
            else node.classList.add("empty");
          }

          /* Добір кегля двійковим пошуком за справжньою висотою — сходинки
             «по длине строки» врут и на широком экране, и на узком.
             Мерок две, потому что раскладки две: у служебных страниц блок
             текста жёсткой высоты, и следить надо за ним, а у обычных он
             растёт вместе с текстом — там за край вылезает весь слайд. */
          function crowded(layer) {
            if (layer.scrollHeight > stack.clientHeight + 1) return true;
            if (layer.scrollWidth > stack.clientWidth + 1) return true;
            var slide = document.querySelector(".slide");
            return !!slide && slide.scrollHeight > slide.clientHeight + 1;
          }

          function fit() {
            var layer = layers[front];
            var main = layer ? layer.querySelector(".quote") : null;
            root.style.removeProperty("--sl-auto");
            if (!stack || !main || number("--sl-fit", 0) < 1) return;
            var high = Math.round(parseFloat(getComputedStyle(main).fontSize)) || 40;
            var low = Math.round(number("--sl-fit-min", 12));
            if (high < low) high = low;
            var best = low;
            while (low <= high) {
              var middle = Math.floor((low + high) / 2);
              root.style.setProperty("--sl-auto", middle + "px");
              if (crowded(layer)) { high = middle - 1; }
              else { best = middle; low = middle + 1; }
            }
            root.style.setProperty("--sl-auto", best + "px");
          }

          /* Наступний вірш обрізається за місцем, а не зіщулюється: на
             служебном экране важнее начало, чем весь текст целиком. */
          function clamp(node, text) {
            node.textContent = text;
            if (!text || node.scrollHeight <= node.clientHeight + 1) return;
            var low = 0, high = text.length, best = 0;
            while (low <= high) {
              var middle = Math.floor((low + high) / 2);
              node.textContent = text.slice(0, middle) + "\\u2026";
              if (node.scrollHeight <= node.clientHeight + 1) { best = middle; low = middle + 1; }
              else { high = middle - 1; }
            }
            node.textContent = text.slice(0, best) + "\\u2026";
          }

          function show(data, blank) {
            var key = blank ? "\\u0000blank" : JSON.stringify([
              data.Mode, (data.Slide || {}).TitleCommon,
              ((data.Slide || {}).Var0 || {}).Text,
              ((data.Slide || {}).Var1 || {}).Text,
              css("--sl-breaks", ""), css("--sl-quotes", ""), css("--sl-joiner", "")
            ]);
            if (key === lastKey) return;
            lastKey = key;
            var back = layers[1 - front];
            if (blank) back.textContent = "";
            else fill(back, data);
            back.classList.add("on");
            layers[front].classList.remove("on");
            front = 1 - front;
            fit();
          }

          function render(data) {
            lastData = data;
            var slide = data.Slide || {};
            var first = slide.Var0 || {};
            var mode = data.Mode || "Bible";
            var hidden = !!(data.Event && data.Event.Name === "HideSlide");
            body.classList.toggle("mode-song", mode === "Song");
            body.classList.toggle("mode-text", mode === "Text");
            body.classList.toggle("mode-bible", mode !== "Song" && mode !== "Text");
            var rule = css("--sl-hide", "all");
            body.classList.toggle("hide-all", hidden && rule === "all");
            body.classList.toggle("hide-idle", hidden && rule === "idle");
            body.classList.toggle("hide-mark", hidden && rule === "mark");
            var blank = hidden && rule === "text";

            setText(".reference", blank ? "" : (slide.TitleCommon || first.Title || ""));

            /* Назви пісні в пакеті немає: програма кладе її або
               отдельной секцией Song, либо в заголовок первого перевода. */
            var song = "";
            if (data.Song && data.Song.Title) song = data.Song.Title;
            else if (mode === "Song") song = first.Title || "";
            setText(".song", blank ? "" : song);

            var out = first.Out0 || {};
            var pages = (out.Pages || []).length;
            setText(".page", pages > 1 ? ((out.PageCurrent | 0) + 1) + " з " + pages : "");

            var next = ((data.NextSlide || {}).Var0 || {}).Text || "";
            next = String(next).replace(/\\*\\*\\*/g, "").replace(/\\r\\n|\\r|\\n/g, " ");
            var bar = document.querySelector(".nextbar");
            var nextNode = document.querySelector(".next");
            if (bar && nextNode) {
              if (next && !blank) { bar.classList.remove("empty"); clamp(nextNode, next); }
              else { bar.classList.add("empty"); nextNode.textContent = ""; }
            }

            show(data, blank);
          }

          function clock() {
            var node = document.querySelector(".clock");
            if (!node) return;
            var now = new Date();
            node.textContent = ("0" + now.getHours()).slice(-2) + ":"
                             + ("0" + now.getMinutes()).slice(-2);
            node.classList.remove("empty");
          }

          /* Пакет не по порядку — це старий пакет, що наздогнав нас після
             нового: показывать его значит откатить экран назад. */
          function accept(data) {
            var id = data.SessionGUID || "";
            var counter = typeof data.CSeq === "number" ? data.CSeq : null;
            if (id !== session) { session = id; seq = counter === null ? -1 : counter; return true; }
            if (counter === null) return true;
            if (counter <= seq) return false;
            seq = counter;
            return true;
          }

          function connect() {
            /* Ручка для вікна майстерні: параметр змінився — перерахувати те,
           что не считается из CSS само. У страниц автора её нет, и это
           правильно: там пересчитывать нечего, и трогать их мы не вправе. */
        window.slovoRefresh = function () {
          lastKey = null;
          if (lastData) { render(lastData); } else if (typeof fit === "function") { fit(); }
        };

        var host = location.hostname || "localhost";
            try { socket = new WebSocket("ws://" + host + ":8100/ws"); }
            catch (error) { later(); return; }

            socket.onopen = function () {
              body.classList.remove("offline");
              /* Ключ команди саме Cmd: під цим ім'ям її шукає програма. */
              socket.send(JSON.stringify({ Cmd: "SubscribeToSlideChanges",
                                           Params: "Out0,NextSlide" }));
            };
            socket.onmessage = function (message) {
              var data;
              try { data = JSON.parse(message.data); } catch (error) { return; }
              if (!data || !data.Slide) return;
              if (!accept(data)) return;
              render(data);
            };
            socket.onclose = function () { body.classList.add("offline"); later(); };
            socket.onerror = function () { try { socket.close(); } catch (error) {} };
          }

          function later() {
            if (retryTimer) return;
            retryTimer = setTimeout(function () { retryTimer = null; connect(); }, 5000);
          }

          window.addEventListener("resize", function () {
            clearTimeout(resizeTimer);
            resizeTimer = setTimeout(fit, 100);
          });

          /* Перерахувати кегль на вимогу. Потрібне редактору: ползунок
             міняє змінну, а підібраний кегль лишався від попереднього
             показу — і сторінка не ворушилася зовсім. Власник: «размер
             текста в редакторе веб страниц не меняется, даже после снятия
             галочки добирати розмір під довжину». */
          window.slovoRefit = function () { fit(); };

          clock();
          setInterval(clock, 1000);
          connect();
        })();
        """

    // MARK: - Передпоказ

    /// Скрипт, який підміняє з'єднання і одразу віддає сторінці
    /// вигаданий слайд.
    ///
    /// Потрібен для передпоказу в редакторі: інакше сторінку можна побачити
    /// лише з робочим сервером і живим слайдом на проекторі, а хочеться
    /// бачити результат одразу, ще під час правки. Підміняємо `WebSocket`
    /// цілком — тоді передпоказ працює і для сторінок автора, які
    /// написані проти того самого протоколу.
    ///
    /// Режим і назва пісні потрібні заготовці «Екран пісні»: у неї замість
    /// адреси назва, а куплет не береться в лапки, і без режиму це не
    /// перевірити. Номери сторінок — для «2 з 3», `hidden` — щоб побачити,
    /// що сторінка робить при порожньому екрані в залі.
    public static func previewShim(text: String,
                                   second: String,
                                   reference: String,
                                   next: String,
                                   mode: String = "Bible",
                                   songTitle: String = "",
                                   hidden: Bool = false,
                                   pageCurrent: Int = 0,
                                   pageCount: Int = 1) -> String {

        let count = max(1, pageCount)
        let current = min(max(0, pageCurrent), count - 1)
        let pages = (0..<count).map { $0 == current ? text : "" }
        // Назву пісні програма кладе в заголовок першого перекладу, а
        // окрема секція — заділ на майбутнє: зайві ключі нікому не заважають.
        let firstTitle = mode == "Song" && !songTitle.isEmpty ? songTitle : reference

        var slide: [String: Any] = [
            "TitleCommon": reference,
            "VarsNum": second.isEmpty ? 1 : 2,
            "Var0": ["ModuleShortName": "RST+", "ModuleName": "Синодальный",
                     "Title": firstTitle, "Text": text,
                     "Out0": ["PageCurrent": current, "Pages": pages]],
        ]
        if !second.isEmpty {
            slide["Var1"] = ["ModuleShortName": "KJV", "ModuleName": "King James",
                             "Title": reference, "Text": second,
                             "Out0": ["PageCurrent": current, "Pages": pages]]
        }

        var nextSection: [String: Any] = ["VarsNum": next.isEmpty ? 0 : 1]
        if !next.isEmpty {
            nextSection["Var0"] = ["ModuleShortName": "RST+", "ModuleName": "Синодальный",
                                   "Title": "", "Text": next]
        }

        var packet: [String: Any] = [
            "InstanceGUID": "preview",
            "SessionGUID": "preview",
            "CSeq": 1,
            "Mode": mode,
            "Event": ["Name": hidden ? "HideSlide" : "ShowSlide"],
            "Slide": slide,
            "NextSlide": nextSection,
        ]
        if !songTitle.isEmpty {
            packet["Song"] = ["Title": songTitle]
        }

        let json = (try? JSONSerialization.data(withJSONObject: packet))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        <script>
        (function () {
          var sample = \(json);
          var live = null;
          function send() {
            if (!live || !live.onmessage) return;
            sample.CSeq = sample.CSeq + 1;
            live.onmessage({ data: JSON.stringify(sample) });
          }
          function Fake(url) {
            var self = this;
            live = this;
            this.url = url;
            this.readyState = 1;
            setTimeout(function () {
              if (self.onopen) self.onopen({});
              send();
            }, 30);
          }
          Fake.prototype.send = function () {};
          Fake.prototype.close = function () { this.readyState = 3; };
          window.WebSocket = Fake;
          /* Ручки для вікна передпоказу: повторити показ, щоб побачити
             плавную смену, и спрятать слайд, чтобы увидеть пустой экран. */
          window.slovoPreview = {
            replay: function (text) {
              if (typeof text === "string") sample.Slide.Var0.Text = text;
              send();
            },
            hide: function (flag) {
              sample.Event.Name = flag ? "HideSlide" : "ShowSlide";
              send();
            }
          };
        })();
        </script>
        """
    }
}


private extension Array where Element == (String, String) {
    /// Значення-добавки заміняють однойменні рядки, а не дублюють їх:
    /// два рядки з одним ключем у блоці налаштувань — це дві ручки на одну
    /// змінну, і розбір блоку їх не прощає.
    func overriding(_ extra: [(String, String)]) -> [(String, String)] {
        var result = self
        for (key, value) in extra {
            if let index = result.firstIndex(where: { $0.0 == key }) {
                result[index] = (key, value)
            } else {
                result.append((key, value))
            }
        }
        return result
    }
}
