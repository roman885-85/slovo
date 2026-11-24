// =============================================================================
//  PlainTextDocument.cs — модуль «Текст» (з Text/PlainTextDocument.swift)
// =============================================================================

using System.Text.Json.Serialization;

namespace Slovo.Core;

/// Модуль «Текст» (розділ 5.2 посібника): довільний текст, який
/// виводиться на слайд так само, як вірш.
///
/// Полів рівно два, і обидва зайняли готові місця на слайді:
/// заголовок (23) малюється там, де в режимі «Біблія» стоїть адреса місця
/// Писання, а сам текст (25) — там, де стоїть цитата. Тому власного
/// оформлення в документа немає: він віддає готовий `Slide`, а як цей слайд
/// виглядає, вирішує стиль режиму.
///
/// Оформлення в «Тексту» своє, а не біблійне: у `VisioBible.ini` секція
/// `[Text]` — повноцінна пара до `[Bible]`. Читати її треба цілком:
/// `SlideStyle(config, section: "Text", dataRoot)` для вигляду і
/// `Pagination(config, section: "Text")` — для розбиття.
public record struct PlainTextDocument
{
    /// Заголовок тексту (23). На слайді займає місце адреси.
    [JsonInclude, JsonRequired, JsonPropertyName("title")] public string Title;
    /// Довільний текст (25). На слайді займає місце цитати.
    [JsonInclude, JsonRequired, JsonPropertyName("body")] public string Body;

    public PlainTextDocument() : this("", "") { }

    public PlainTextDocument(string title = "", string body = "")
    {
        Title = title;
        Body = body;
    }

    /// Порожній документ — це «показувати нічого», а не порожній слайд:
    /// пробіли і переноси рядків за вміст не вважаємо.
    [JsonIgnore]
    public readonly bool IsEmpty =>
        Title.TrimWhitespacesAndNewlines().Length == 0 && Body.TrimWhitespacesAndNewlines().Length == 0;

    /// Кнопка «Очистити текст» (24, `SBClearText`) — посібник вимагає
    /// очищати обидва поля одразу, і текст (25), і заголовок (23).
    public void Clear()
    {
        Title = "";
        Body = "";
    }

    // ── Приймання тексту з модуля «Біблія» ──────────────────────────────────

    /// Куди подіти те, що вже набрано, коли приходить новий текст.
    [JsonConverter(typeof(SwiftStringEnumConverter<Reception>))]
    public enum Reception
    {
        /// Пункт меню називається «Скопировать во вкладку "Текст"»: копія
        /// заміщує вміст вкладки цілком, як заміщує буфер обміну.
        [JsonStringEnumMemberName("replace")] Replace,
        /// Дописати знизу — так із кількох місць збирається одне оголошення.
        [JsonStringEnumMemberName("append")] Append,
    }

    /// Вірш (або кілька віршів) зі списку (4) через контекстне меню
    /// `MICopyToText`. Адреса йде в заголовок, а не приписується до тексту.
    public static PlainTextDocument Scripture(string reference, string text) => new(reference, text);

    public void Receive(string reference, string text, Reception mode = Reception.Replace)
    {
        switch (mode)
        {
            case Reception.Replace:
                Title = reference;
                Body = text;
                break;
            case Reception.Append:
                if (Title.TrimWhitespacesAndNewlines().Length == 0) Title = reference;
                var trimmed = Body.TrimWhitespacesAndNewlines();
                Body = trimmed.Length == 0 ? text : trimmed + "\n" + text;
                break;
        }
    }

    // ── Підписи в списках ───────────────────────────────────────────────────

    /// Рядок для «Плану» (10) та «Історії» (11): «Дорогие! - Настройтесь на …».
    public readonly string Summary(int limit = 120)
    {
        var head = Title.TrimWhitespacesAndNewlines();
        var tail = Snippet(limit);
        if (head.Length == 0) return tail;
        if (tail.Length == 0) return head;
        return head + " - " + tail;
    }

    /// Початок тексту одним рядком — переноси рядків у списку не потрібні.
    public readonly string Snippet(int limit = 120)
    {
        var flat = string.Join(" ", Body.ComponentsSeparatedByNewlines()
            .Select(line => line.TrimWhitespaces())
            .Where(line => line.Length > 0));
        return SwiftText.CharacterCount(flat) > limit ? SwiftText.PrefixCharacters(flat, limit) + "…" : flat;
    }

    // ── Розбиття довгого тексту на слайди ───────────────────────────────────

    /// Як довгий текст лягає на слайди. Це ті самі «Опції роботи» (15),
    /// що й у Біблії, лише читаються з секції `[Text]`.
    public record struct Pagination
    {
        /// `PageSubDivide` — «Розбивати на сторінки».
        [JsonInclude, JsonRequired, JsonPropertyName("splitsIntoPages")] public bool SplitsIntoPages;
        /// `VersSubDivide` — «Розбивати на вірші». У довільного тексту віршів
        /// немає, і одиницею служить рядок, набраний у полі (25).
        [JsonInclude, JsonRequired, JsonPropertyName("splitsIntoParagraphs")] public bool SplitsIntoParagraphs;
        /// `WordWrap` — «Автоперенос слів».
        [JsonInclude, JsonRequired, JsonPropertyName("wrapsWords")] public bool WrapsWords;
        /// Порожній рядок у наборі — розрив, поставлений оператором вручну.
        [JsonInclude, JsonRequired, JsonPropertyName("blankLineBreaksPage")] public bool BlankLineBreaksPage;
        /// Скільки знаків уміщається в рядок слайда за мінімального кегля.
        [JsonInclude, JsonRequired, JsonPropertyName("charactersPerLine")] public int CharactersPerLine;
        /// Скільки таких рядків уміщається на слайд.
        [JsonInclude, JsonRequired, JsonPropertyName("linesPerPage")] public int LinesPerPage;
        /// `percentfillingpage` — мінімальний відсоток заповнення для нової сторінки.
        [JsonInclude, JsonRequired, JsonPropertyName("minimumFillPercent")] public double MinimumFillPercent;
        /// Номер сторінки («2/3») у заголовку. За умовчанням вимкнено.
        [JsonInclude, JsonRequired, JsonPropertyName("showsPageNumber")] public bool ShowsPageNumber;

        public Pagination() : this(splitsIntoPages: true) { }

        public Pagination(bool splitsIntoPages = true,
                          bool splitsIntoParagraphs = false,
                          bool wrapsWords = true,
                          bool blankLineBreaksPage = true,
                          int charactersPerLine = 21,
                          int linesPerPage = 6,
                          double minimumFillPercent = 30,
                          bool showsPageNumber = false)
        {
            SplitsIntoPages = splitsIntoPages;
            SplitsIntoParagraphs = splitsIntoParagraphs;
            WrapsWords = wrapsWords;
            BlankLineBreaksPage = blankLineBreaksPage;
            CharactersPerLine = Math.Max(1, charactersPerLine);
            LinesPerPage = Math.Max(1, linesPerPage);
            MinimumFillPercent = Math.Min(Math.Max(minimumFillPercent, 0), 100);
            ShowsPageNumber = showsPageNumber;
        }

        /// Налаштування як їх виставив користувач в оригіналі. `style` не
        /// обов'язковий, але з ним оцінка чесніша: поля та інтерліньяж беруться
        /// з того самого стилю, яким слайд і буде намальовано.
        public Pagination(IniSettings config, string section = "Text", SlideStyle? style = null)
        {
            // Мінімальний кегль в оригіналі записано часткою висоти слайда у відсотках
            // (`fontminsize=11`): якби рахувати його пунктами на макеті 800×600, на слайд
            // улізло б шість тисяч знаків і розбиття не спрацьовувало б ніколи.
            var minFont = (config.Double("fontminsize", section) ?? 11) / 100;
            var capacity = Capacity(
                slideWidth: config.Int("width", "OutScreen") ?? 800,
                slideHeight: config.Int("height", "OutScreen") ?? 600,
                minFontFraction: minFont,
                lineSpacing: style?.LineSpacing ?? 0.18,
                horizontalInset: style?.HorizontalInset ?? 0.06,
                verticalInset: style?.VerticalInset ?? 0.06);

            this = new Pagination(splitsIntoPages: config.Bool("PageSubDivide", section) ?? true,
                                  splitsIntoParagraphs: config.Bool("VersSubDivide", section) ?? false,
                                  wrapsWords: config.Bool("WordWrap", section) ?? true,
                                  blankLineBreaksPage: true,
                                  charactersPerLine: capacity.CharactersPerLine,
                                  linesPerPage: capacity.LinesPerPage,
                                  minimumFillPercent: config.Double("percentfillingpage", "OutScreen") ?? 30,
                                  showsPageNumber: false);
        }

        /// Скільки знаків і рядків уміщається на слайд за мінімального кегля.
        ///
        /// Оцінка з геометрії: середня ширина знака — приблизно половина кегля,
        /// висота рядка — кегль з інтерліньяжем. На 800×600 і мінімумі 11 %
        /// виходить 21 знак у рядку і 6 рядків.
        public static (int CharactersPerLine, int LinesPerPage) Capacity(double slideWidth = 800,
                                                                         double slideHeight = 600,
                                                                         double minFontFraction = 0.11,
                                                                         double lineSpacing = 0.18,
                                                                         double horizontalInset = 0.06,
                                                                         double verticalInset = 0.06)
        {
            var font = Math.Max(slideHeight * minFontFraction, 1);
            var lineHeight = font * (1 + Math.Max(lineSpacing, 0));
            var usableHeight = slideHeight * (1 - 2 * Math.Min(Math.Max(verticalInset, 0), 0.4));
            var usableWidth = slideWidth * (1 - 2 * Math.Min(Math.Max(horizontalInset, 0), 0.4));

            return (Math.Max(8, (int)(usableWidth / (font * 0.5))),
                    Math.Max(1, (int)(usableHeight / lineHeight)));
        }
    }

    /// Текст, розкладений по сторінках. Кожна сторінка — те, що піде на один слайд.
    public readonly List<string> Pages(Pagination? pagination = null)
    {
        var settings = pagination ?? new Pagination();
        var lines = NormalizedLines(Body);
        if (lines.Count == 0)
        {
            // Заголовок без тексту — теж слайд; порожній документ не дає жодної сторінки.
            return Title.TrimWhitespacesAndNewlines().Length == 0 ? new List<string>() : new List<string> { "" };
        }

        var blocks = Blocks(lines, settings);
        if (!settings.SplitsIntoPages) return blocks.Select(block => string.Join("\n", block)).ToList();
        return blocks.SelectMany(block => Paginate(block, settings))
            .Select(page => string.Join("\n", page)).ToList();
    }

    /// Готові слайди. Збираються рівно як біблійні: текст на місці
    /// цитати, заголовок на місці адреси.
    public readonly List<Slide> Slides(Pagination? pagination = null)
    {
        var settings = pagination ?? new Pagination();
        var texts = Pages(settings);
        if (texts.Count == 0) return new List<Slide>();

        var head = Title.TrimWhitespacesAndNewlines();
        return texts.Select((text, index) => new Slide(mainText: text,
                                                       secondaryTexts: Array.Empty<string>(),
                                                       reference: ReferenceText(head, index, texts.Count, settings),
                                                       isBlank: text.Length == 0 && head.Length == 0)).ToList();
    }

    /// Один слайд за номером сторінки. Номер за межами набору притискається до краю.
    public readonly Slide SlideAtPage(int index, Pagination? pagination = null)
    {
        var all = Slides(pagination);
        if (all.Count == 0) return Slide.Blank;
        return all[Math.Min(Math.Max(index, 0), all.Count - 1)];
    }

    public readonly int PageCount(Pagination? pagination = null) => Pages(pagination).Count;

    private static string ReferenceText(string head, int page, int count, Pagination pagination)
    {
        if (!pagination.ShowsPageNumber || count <= 1) return head;
        var number = $"{page + 1}/{count}";
        return head.Length == 0 ? number : head + " · " + number;
    }

    // ── Розбір набраного тексту ─────────────────────────────────────────────

    /// Рядки без хвостових пробілів і без порожніх рядків по краях.
    /// Перенос рядка з Windows (`\r\n`) дає тут одну межу, а не дві.
    public static List<string> NormalizedLines(string text)
    {
        var lines = text.Replace("\r\n", "\n").Replace("\r", "\n")
            .Split('\n')
            .Select(line => line.TrimWhitespaces())
            .ToList();
        while (lines.Count > 0 && lines[0].Length == 0) lines.RemoveAt(0);
        while (lines.Count > 0 && lines[^1].Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines;
    }

    /// Шматки тексту, які не можна змішувати на одному слайді.
    private static List<List<string>> Blocks(List<string> lines, Pagination pagination)
    {
        if (pagination.SplitsIntoParagraphs)
            return lines.Where(line => line.Length > 0).Select(line => new List<string> { line }).ToList();
        // Порожній рядок ріже лише за ввімкненого розбиття.
        if (!pagination.BlankLineBreaksPage || !pagination.SplitsIntoPages) return new List<List<string>> { lines };

        var blocks = new List<List<string>> { new() };
        foreach (var line in lines)
        {
            if (line.Length == 0)
            {
                if (blocks[^1].Count > 0) blocks.Add(new List<string>());
            }
            else
            {
                blocks[^1].Add(line);
            }
        }
        blocks.RemoveAll(block => block.Count == 0);
        return blocks;
    }

    /// Один шматок, розкладений по сторінках.
    private static List<List<string>> Paginate(List<string> block, Pagination pagination)
    {
        var capacity = pagination.LinesPerPage;
        var budget = capacity * pagination.CharactersPerLine;

        // Спершу рядки, які самі по собі не влазять у слайд. `IsContinuation`
        // позначає шматки одного розрізаного рядка: на одному слайді між ними
        // потрібен пробіл, а не перенос рядка.
        var units = new List<(string Text, bool IsContinuation)>();
        foreach (var line in block)
        {
            if (DisplayHeight(line, pagination) <= capacity || !pagination.WrapsWords)
            {
                units.Add((line, false));
            }
            else
            {
                var pieces = Chunks(line, budget);
                for (var index = 0; index < pieces.Count; index++) units.Add((pieces[index], index > 0));
            }
        }

        var pages = new List<List<string>>();
        var current = new List<string>();
        var used = 0;

        int Height(List<string> lines) => lines.Sum(line => DisplayHeight(line, pagination));

        foreach (var unit in units)
        {
            var added = DisplayHeight(unit.Text, pagination);
            if (current.Count > 0 && used + added > capacity)
            {
                pages.Add(current);
                current = new List<string>();
                used = 0;
            }
            if (unit.IsContinuation && current.Count > 0)
                current[^1] += " " + unit.Text;
            else
                current.Add(unit.Text);
            // Склейка двох шматків могла вийти коротшою за суму: рахуємо заново.
            used = Height(current);
        }
        if (current.Count > 0) pages.Add(current);

        // Хвіст у півтора рядка окремим слайдом виглядає як збій показу —
        // це і є «мінімальний відсоток заповнення».
        if (pages.Count > 1)
        {
            var tail = pages[^1].Sum(line => DisplayHeight(line, pagination));
            var fill = (double)tail / capacity * 100;
            if (fill < pagination.MinimumFillPercent)
            {
                var last = pages[^1];
                pages.RemoveAt(pages.Count - 1);
                pages[^1].AddRange(last);
            }
        }
        return pages;
    }

    /// Скільки рядків слайда займе один набраний рядок.
    private static int DisplayHeight(string line, Pagination pagination)
    {
        if (!pagination.WrapsWords) return 1;
        var count = SwiftText.CharacterCount(line);
        if (count <= pagination.CharactersPerLine) return 1;
        return (int)Math.Ceiling((double)count / pagination.CharactersPerLine);
    }

    /// Довгий рядок, розрізаний за межами слів. Слово, довше за цілий слайд,
    /// рубаємо посередині — інакше воно заблокує розбиття.
    public static List<string> Chunks(string line, int budget)
    {
        var limit = Math.Max(1, budget);
        if (SwiftText.CharacterCount(line) <= limit) return new List<string> { line };

        var result = new List<string>();
        var current = "";

        foreach (var word in SplitOnSpaces(line))
        {
            var piece = word;
            while (SwiftText.CharacterCount(piece) > limit)
            {
                if (current.Length > 0) { result.Add(current); current = ""; }
                result.Add(SwiftText.PrefixCharacters(piece, limit));
                piece = SwiftText.DropFirstCharacters(piece, limit);
            }
            if (current.Length == 0)
                current = piece;
            else if (SwiftText.CharacterCount(current) + 1 + SwiftText.CharacterCount(piece) <= limit)
                current += " " + piece;
            else
            {
                result.Add(current);
                current = piece;
            }
        }
        if (current.Length > 0) result.Add(current);
        return result.Count == 0 ? new List<string> { line } : result;
    }

    /// `split(separator: " ")` по знаках Swift: пробіл із прилиплою позначкою — не роздільник.
    private static IEnumerable<string> SplitOnSpaces(string line)
    {
        var start = 0;
        for (var index = 0; index <= line.Length; index++)
        {
            var isSeparator = index < line.Length && line[index] == ' '
                              && (index + 1 >= line.Length || !SwiftText.IsMark(line[index + 1]));
            if (index < line.Length && !isSeparator) continue;
            if (index > start) yield return line[start..index];
            start = index + 1;
        }
    }
}
