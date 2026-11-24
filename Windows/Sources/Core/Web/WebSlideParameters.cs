// =============================================================================
//  WebSlideParameters.cs — оформлення веб-слайда повзунками
//  (з SlovoCore/Web/WebSlideParameters.swift)
// =============================================================================
//  Текстового поля з розміткою мало: людина, яка ніколи не писала HTML, не
//  стане шукати в чужому файлі рядок `padding: 20px`. Тому оформлення винесено
//  в набір змінних CSS з людськими підписами — їх рухають повзунками, а
//  сторінка лишається сторінкою.
//
//  Будова одна на всі сторінки, і наші, і авторські. У файл дописуються два
//  блоки `<style>` перед `</head>` (і скрипт живих налаштувань) і більше нічого:
//  `vars` — лише значення, `bind` — правила, які ці значення прикладають до
//  ролей. Розмітку не чіпаємо зовсім: ролі дістаються селекторами за тим, що в
//  сторінці вже є (`#content`, `#content1`, `.contentTitle`, наші
//  `.quote/.reference`). У чужому файлі не міняється жодного байта, крім наших блоків.
//
//  Головне правило: значення має лягати на **значення змінної**, а не на
//  наявність правила. Логічне — готовим словом CSS (`none`/`block`), вимикач —
//  множником `1|0`. Щойно параметр вимагатиме іншого набору правил, передпоказ
//  почне перезавантажувати сторінку на кожен рух повзунка і заблимає.
// =============================================================================

using System.Globalization;
using System.Text;
using Group = Slovo.Core.WebSlideParameter.Group;
using Kind = Slovo.Core.WebSlideParameter.Kind;

namespace Slovo.Core;

// ── Один параметр ─────────────────────────────────────────────────────────────

public sealed class WebSlideParameter
{
    /// Розділ панелі. Порядок розділів — порядок у списку.
    public enum Group { Text, Stroke, Reference, Second, Next, Numbers, Layout, Plate, Background, Appear }

    /// Один пункт вибору.
    public sealed class Option
    {
        /// Що ляже в змінну — уже готове значення CSS.
        public string Value { get; }
        /// Що прочитає людина. Зберігається російською, а назовні виходить мовою інтерфейсу.
        public string TitleSource { get; }
        public string Title => OurWords.T(TitleSource);
        /// Що редактор дописує разом із цим вибором: зрозумілий людині вибір («адреса
        /// в правому нижньому куті») у CSS — це дві різні властивості, і писати обидві
        /// змінні разом чесніше, ніж городити набір правил під кожен випадок.
        public IReadOnlyList<(string Name, string Value)> Implies { get; }

        public Option(string value, string title, (string, string)[]? implies = null)
        {
            Value = value;
            TitleSource = title;
            Implies = (implies ?? Array.Empty<(string, string)>()).Select(pair => (pair.Item1, pair.Item2)).ToList();
        }
    }

    public enum KindTag { Color, ColorRGB, Number, Fraction, Choice, Toggle, Link }

    /// Вид значення — ним панель вибирає, що показати: повзунок, піпетку чи список.
    public sealed class Kind
    {
        public KindTag Tag { get; private init; }
        public double Min { get; private init; }
        public double Max { get; private init; }
        public double Step { get; private init; }
        /// Порожня — число без одиниці, інакше довжина («5vw»).
        public string Unit { get; private init; } = "";
        public IReadOnlyList<Option> Options { get; private init; } = Array.Empty<Option>();
        /// Обидва значення вимикача — готові слова CSS, а не `true`/`false`.
        public string On { get; private init; } = "";
        public string Off { get; private init; } = "";
        public string OnTitle { get; private init; } = "";
        public string OffTitle { get; private init; } = "";

        /// Колір `#rrggbb`.
        public static readonly Kind Color = new() { Tag = KindTag.Color };
        /// Колір трійкою «R G B» — коли прозорість окремим параметром.
        public static readonly Kind ColorRGB = new() { Tag = KindTag.ColorRGB };
        /// `none` або `url("…")` — картинка або градієнт.
        public static readonly Kind Link = new() { Tag = KindTag.Link };
        public static Kind Number(double min, double max, double step, string unit) =>
            new() { Tag = KindTag.Number, Min = min, Max = max, Step = step, Unit = unit };
        /// Частка 0…1 — показується відсотками.
        public static Kind Fraction(double min, double max) => new() { Tag = KindTag.Fraction, Min = min, Max = max };
        public static Kind Choice(Option[] options) => new() { Tag = KindTag.Choice, Options = options };
        public static Kind Toggle(string on, string off, string onTitle, string offTitle) =>
            new() { Tag = KindTag.Toggle, On = on, Off = off, OnTitle = onTitle, OffTitle = offTitle };
    }

    /// Місце в сторінці, яким розпоряджається ручка.
    public enum Role { Page, Stage, Quote, Reference, Second, Next, NextOwn, Number, Script }

    public string Name { get; }
    public string TitleSource { get; }
    public string Title => OurWords.T(TitleSource);
    public Group Section { get; }
    public Kind ValueKind { get; }
    public string DefaultValue { get; }
    public string HintSource { get; }
    public string Hint => OurWords.T(HintSource);
    /// Чи показувати в панелі. Хибність стоїть у змінних-супутників: їх пише не
    /// людина, а вибір із сусіднього списку (див. `Option.Implies`). У файлі вони
    /// живуть нарівні з усіма — інакше круговий прогін губив би їх при записі.
    public bool ShowsInPanel { get; }
    public string Id => Name;

    public WebSlideParameter(string name, string title, Group group, Kind kind, string @default, string hint,
                             bool showsInPanel = true)
    {
        Name = name;
        TitleSource = title;
        Section = group;
        ValueKind = kind;
        DefaultValue = @default;
        HintSource = hint;
        ShowsInPanel = showsInPanel;
    }

    // ── Розбір і перевірка значення ──────────────────────────────────────────

    /// Чи годиться рядок як значення цього параметра.
    ///
    /// Негодний рядок не привід відкидати файл: людина могла вписати в блок щось
    /// своє руками. Панель гасить такий повзунок і показує сирий текст — але
    /// значення лишається у файлі неторканим.
    public bool IsValid(string raw)
    {
        var value = raw.TrimWhitespaces();
        if (!WebSlideParameters.IsWritable(value)) return false;
        var kind = ValueKind;
        return kind.Tag switch
        {
            KindTag.Color => WebSlideParameters.IsHexColor(value),
            KindTag.ColorRGB => WebSlideParameters.IsColorTriple(value),
            KindTag.Number => WebSlideParameters.Number(value, kind.Unit) != null,
            KindTag.Fraction => WebSlideParameters.Number(value, "") != null,
            KindTag.Choice => kind.Options.Any(option => option.Value == value),
            KindTag.Toggle => value == kind.On || value == kind.Off,
            _ => value == "none" || value.StartsWith("url(", StringComparison.Ordinal) || value.Contains("gradient(", StringComparison.Ordinal),
        };
    }

    /// Число зі значення — для повзунка.
    public double? NumberFrom(string raw)
    {
        var value = raw.TrimWhitespaces();
        return ValueKind.Tag switch
        {
            KindTag.Number => WebSlideParameters.Number(value, ValueKind.Unit),
            KindTag.Fraction => WebSlideParameters.Number(value, ""),
            _ => null,
        };
    }

    /// Число назад у значення — з тією самою одиницею, що в параметра. Ціле — без
    /// хвоста: `6`, а не `6.0` (зайві нулі людина читає як «програма насмітила»).
    public string TextFrom(double value) => ValueKind.Tag switch
    {
        KindTag.Number => WebSlideParameters.Digits(Clamped(value)) + ValueKind.Unit,
        KindTag.Fraction => WebSlideParameters.Digits(Clamped(value)),
        _ => DefaultValue,
    };

    /// Загнати число в межі параметра.
    public double Clamped(double value) => ValueKind.Tag is KindTag.Number or KindTag.Fraction
        ? Math.Min(Math.Max(value, ValueKind.Min), ValueKind.Max)
        : value;

    /// Чи лягає параметр прямо на CSS. П'ять не лягають: добір кегля і перехід
    /// робить скрипт прив'язки; точка прив'язки, режим фону і місце адреси — це
    /// запис людського вибору, а роботу за них роблять супутники.
    public bool IsBoundToCSS =>
        !new[] { "--sl-fit", "--sl-transition", "--sl-anchor", "--sl-bg-mode", "--sl-ref-place" }.Contains(Name);

    /// До якого місця сторінки ручку прикладено — щоб панель могла сказати
    /// правду: «у ЦІЙ сторінці прикласти нікуди».
    public Role PageRole
    {
        get
        {
            switch (Name)
            {
                // Добір кегля і перехід робить скрипт, якого в чужій сторінці немає.
                case "--sl-fit": case "--sl-transition": return Role.Script;
                // Напрямок другого перекладу і просвіт — властивості зовнішнього блоку.
                case "--sl-second-place": case "--sl-ref-gap": return Role.Stage;
                // Видимість і кегль наступного вірша — лише своїй розмітці.
                case "--sl-next-display": case "--sl-next-size": return Role.NextOwn;
            }
            return Section switch
            {
                Group.Text or Group.Stroke or Group.Plate or Group.Appear => Role.Quote,
                Group.Reference => Role.Reference,
                Group.Second => Role.Second,
                Group.Next => Role.Next,
                Group.Numbers => Role.Number,
                Group.Layout => Role.Stage,
                _ => Role.Page,
            };
        }
    }
}

public static class WebSlideParameterGroups
{
    public static readonly IReadOnlyList<Group> All =
        [Group.Text, Group.Stroke, Group.Reference, Group.Second, Group.Next, Group.Numbers,
         Group.Layout, Group.Plate, Group.Background, Group.Appear];

    /// Незмінний підпис — за ним розділ знаходять у панелі. Переклад показують
    /// людині, а звіряють за цим: перекладений підпис роз'їжджається з мовою.
    public static string Key(this Group group) => group switch
    {
        Group.Text => "Текст",
        Group.Stroke => "Обводка и тень",
        Group.Reference => "Адрес",
        Group.Second => "Второй перевод",
        Group.Next => "Следующий стих",
        Group.Numbers => "Номера стихов",
        Group.Layout => "Расположение",
        Group.Plate => "Подложка под текстом",
        Group.Background => "Фон страницы",
        _ => "Появление слайда",
    };

    public static string Title(this Group group) => OurWords.T(group.Key());

    /// Як пояснити людині, чого в сторінці бракує.
    public static string Missing(this WebSlideParameter.Role role) => role switch
    {
        WebSlideParameter.Role.Page => OurWords.T("в странице нет тела <body> — это не целая страница"),
        WebSlideParameter.Role.Stage => OurWords.T("в странице не нашлось блока, который держит текст"),
        WebSlideParameter.Role.Quote => OurWords.T("в странице не нашлось блока с текстом стиха"),
        WebSlideParameter.Role.Reference => OurWords.T("в этой странице адрес не отдельным блоком, а строкой внутри текста"),
        WebSlideParameter.Role.Second => OurWords.T("в этой странице второй перевод идёт тем же блоком, что и первый"),
        WebSlideParameter.Role.Next => OurWords.T("в этой странице нет блока для следующего стиха"),
        WebSlideParameter.Role.NextOwn => OurWords.T("следующий стих здесь — блок автора: цвет и черту мы ему поменяем, "
                                                     + "а кегль он подбирает сам, и прятать его мы не станем"),
        WebSlideParameter.Role.Number => OurWords.T("номера стихов выделяет скрипт, а в этой странице его нет"),
        _ => OurWords.T("это делает скрипт, а мы дописываем в страницу только оформление"),
    };
}

// ── Набір значень однієї сторінки ─────────────────────────────────────────────

/// Що записано в блоці налаштувань однієї сторінки.
///
/// Зберігається сирими рядками, а не розібраними числами, і це навмисно:
/// значення, яке ми не зрозуміли, зобов'язане повернутися у файл рівно таким,
/// яким прийшло. (У Swift — значення-структура; тут клас, тому копію беремо явно — `Copy()`.)
public sealed class WebSlideSettings : IEquatable<WebSlideSettings>
{
    readonly Dictionary<string, string> _stored = new(StringComparer.Ordinal);
    /// Порядок появи — за ним дописуються незнайомі змінні.
    readonly List<string> _appearance = new();

    public WebSlideSettings() { }

    public WebSlideSettings(IEnumerable<(string Name, string Value)> pairs)
    {
        foreach (var (name, value) in pairs) Set(name, value);
    }

    public WebSlideSettings Copy()
    {
        var copy = new WebSlideSettings();
        foreach (var name in _appearance) { copy._appearance.Add(name); copy._stored[name] = _stored[name]; }
        return copy;
    }

    /// Рівність рахується за значеннями, порядок до уваги не береться: круговий
    /// прогін «розібрати → записати → розібрати» переставляє знайомі змінні в
    /// порядок каталогу, і це не розбіжність.
    public bool Equals(WebSlideSettings? other) =>
        other != null && _stored.Count == other._stored.Count
        && _stored.All(pair => other._stored.TryGetValue(pair.Key, out var value) && value == pair.Value);

    public override bool Equals(object? obj) => obj is WebSlideSettings other && Equals(other);

    public override int GetHashCode()
    {
        var hash = 0;
        foreach (var (name, value) in _stored) hash ^= HashCode.Combine(name, value);
        return hash;
    }

    public string? this[string name] => _stored.TryGetValue(name, out var value) ? value : null;

    public void Set(string name, string value)
    {
        if (!_stored.ContainsKey(name)) _appearance.Add(name);
        _stored[name] = value;
    }

    public void Remove(string name)
    {
        _stored.Remove(name);
        _appearance.RemoveAll(item => item == name);
    }

    /// Значення параметра: своє, а якщо не задано — за умовчанням.
    public string Value(WebSlideParameter parameter) => this[parameter.Name] ?? parameter.DefaultValue;

    /// Чи задано значення руками так, що повзунок його не розуміє.
    public bool IsManual(WebSlideParameter parameter) => this[parameter.Name] is { } raw && !parameter.IsValid(raw);

    /// Поставити значення параметра разом з його супутниками.
    public void Choose(WebSlideParameter parameter, string value)
    {
        Set(parameter.Name, value);
        if (parameter.ValueKind.Tag == WebSlideParameter.KindTag.Choice
            && parameter.ValueKind.Options.FirstOrDefault(option => option.Value == value) is { } option)
        {
            foreach (var (name, companion) in option.Implies.OrderBy(pair => pair.Name, StringComparer.Ordinal))
                Set(name, companion);
        }
    }

    /// Змінні, яких немає в каталозі, — з новішої версії програми.
    public IReadOnlyList<string> UnknownNames =>
        _appearance.Where(name => WebSlideParameters.Parameter(name) == null).ToList();

    public IReadOnlyList<string> Names => _appearance.ToList();
    public bool IsEmpty => _stored.Count == 0;
    public int Count => _stored.Count;

    /// Дописати все, чого в наборі немає, значеннями за умовчанням — рівно один раз,
    /// коли блок налаштувань заводиться в сторінці, де його не було.
    public WebSlideSettings ApplyingDefaults()
    {
        var copy = Copy();
        foreach (var parameter in WebSlideParameters.All)
            if (copy[parameter.Name] == null) copy.Set(parameter.Name, parameter.DefaultValue);
        return copy;
    }

    /// Що змінилося проти колишнього набору — цим живиться передпоказ.
    public Dictionary<string, string> Changes(WebSlideSettings old)
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, value) in _stored)
            if (old[name] != value) result[name] = value;
        // Прибране повертаємо до значення за умовчанням: у живій сторінці змінну вже
        // виставлено, і просто забути про неї не можна.
        foreach (var (name, _) in old._stored)
            if (!_stored.ContainsKey(name))
                result[name] = WebSlideParameters.Parameter(name)?.DefaultValue ?? "initial";
        return result;
    }

    /// Порядок запису: спершу каталог, потім незнайоме — як прийшло.
    public IReadOnlyList<(string Name, string Value)> WritingOrder
    {
        get
        {
            var result = new List<(string, string)>();
            var written = new HashSet<string>(StringComparer.Ordinal);
            foreach (var parameter in WebSlideParameters.All)
            {
                if (this[parameter.Name] is not { } value) continue;
                result.Add((parameter.Name, value));
                written.Add(parameter.Name);
            }
            foreach (var name in _appearance)
            {
                if (written.Contains(name) || this[name] is not { } value) continue;
                result.Add((name, value));
                written.Add(name);
            }
            return result;
        }
    }
}

// ── Розбір сторінки ───────────────────────────────────────────────────────────

/// Стан блоку налаштувань у сторінці.
public sealed record WebSlideBlock
{
    public enum Kinds { Present, Missing, Damaged }
    public Kinds Kind { get; init; }
    public int Version { get; init; }
    public int Extras { get; init; }
    public string Reason { get; init; } = "";

    /// Блок знайдено і він цілий.
    public static WebSlideBlock Present(int version, int extras) => new() { Kind = Kinds.Present, Version = version, Extras = extras };
    /// Блоку в сторінці немає — його можна завести.
    public static readonly WebSlideBlock Missing = new() { Kind = Kinds.Missing };
    /// Мітки переплутано або блок розірвано; записувати не можна.
    public static WebSlideBlock Damaged(string reason) => new() { Kind = Kinds.Damaged, Reason = reason };
}

/// Що вдалося вичитати зі сторінки.
public sealed class WebSlideDocument
{
    public WebSlideBlock Block { get; init; } = WebSlideBlock.Missing;
    public WebSlideSettings Settings { get; init; } = new();
    /// Чи є куди вставляти блок.
    public bool HasHead { get; init; }
    /// Чи є блок прив'язки.
    public bool HasBinding { get; init; }
    /// Оголошення `--sl-*`, знайдені поза блоком: людина правила руками.
    public IReadOnlyList<string> OutsideNames { get; init; } = Array.Empty<string>();
    /// Перенос рядка цього файла — в авторських сторінок CRLF.
    public string Newline { get; init; } = "\n";

    /// Чи можна рухати повзунки.
    public bool IsAdjustable => Block.Kind switch
    {
        WebSlideBlock.Kinds.Damaged => false,
        WebSlideBlock.Kinds.Present => Block.Version <= WebSlideParameters.Version,
        _ => HasHead,
    };

    /// Рядок стану для людини — чому повзунки такі, які є.
    public string? Note
    {
        get
        {
            switch (Block.Kind)
            {
                case WebSlideBlock.Kinds.Damaged:
                    return OurWords.T("Блок настроек повреждён: %s. Ползунки выключены, чтобы не испортить остальное.", Block.Reason);
                case WebSlideBlock.Kinds.Missing:
                    return HasHead
                        ? OurWords.T("В этой странице ещё нет настроек: первое движение ползунка заведёт их.")
                        : OurWords.T("Это не целая страница: в ней нет </head>, вставлять настройки некуда.");
            }
            if (Block.Version > WebSlideParameters.Version)
                return OurWords.T("Эту страницу настраивала более новая версия программы. "
                                  + "Чтобы не испортить настройки, ползунки выключены; текст правится как обычно.");
            var parts = new List<string>();
            if (Block.Extras > 0)
                parts.Add(OurWords.T("блоков настроек в файле %s, работает последний", (Block.Extras + 1).ToString(CultureInfo.InvariantCulture)));
            if (OutsideNames.Count > 0)
                parts.Add(OurWords.T("вне блока правлено руками: ") + string.Join(", ", OutsideNames));
            var unknown = Settings.UnknownNames;
            if (unknown.Count > 0)
                parts.Add(OurWords.T("настроек от другой версии: %s", unknown.Count.ToString(CultureInfo.InvariantCulture)));
            return parts.Count == 0 ? null : string.Join("; ", parts);
        }
    }
}

/// Чим скінчився запис: готовий текст або причина словами (її показують людині).
public sealed record WebSlideWriteOutcome(string? Html, string Reason)
{
    public static WebSlideWriteOutcome Written(string text) => new(text, "");
    public static WebSlideWriteOutcome Refused(string reason) => new(null, reason);
    public bool IsWritten => Html != null;
}

// ── Каталог, розбір, запис, готовий CSS ───────────────────────────────────────

public static partial class WebSlideParameters
{
    /// Версія блоку. Росте, коли міняється набір змінних або прив'язка.
    public const int Version = 6;

    // ── Мітки ─────────────────────────────────────────────────────────────────

    /// Не приватний: за ним і самоперевірка відрізняє сторінку з блоком.
    public const string VarsAttribute = "data-slovo=\"vars\"";
    internal const string BindAttribute = "data-slovo=\"bind\"";
    internal const string LiveAttribute = "data-slovo=\"live\"";
    internal const string StyleClose = "</style>";

    /// Узяти блок налаштувань з колишньої сторінки і покласти його у свіжу
    /// заготовку: каркас оновиться, а вибрані власником значення лишаться.
    /// Немає блоку — віддаємо свіжу як є.
    public static string CarryOverSettings(string old, string fresh)
    {
        if (SettingsBlockRange(old) is not { } oldBlock || SettingsBlockRange(fresh) is not { } freshBlock) return fresh;
        // Значення власника головніші, але ручки, яких у його сторінці ще не було
        // (нові ефекти, наприклад), мають приїхати зі свіжими умовчаннями.
        var mine = Values(old[oldBlock.Start..oldBlock.End]);
        var merged = new StringBuilder();
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var text in SplitOnLineFeed(fresh[freshBlock.Start..freshBlock.End]))
        {
            if (VariableName(text) is { } name && mine.TryGetValue(name, out var value))
            {
                merged.Append("  ").Append(name).Append(": ").Append(value).Append(";\n");
                seen.Add(name);
            }
            else merged.Append(text).Append('\n');
        }
        // Ручки, які власник завів сам, а в заготовці їх немає.
        var extra = mine.Keys.Where(key => !seen.Contains(key)).OrderBy(key => key, StringComparer.Ordinal).ToList();
        var mergedText = merged.ToString();
        if (extra.Count > 0 && WebText.Find(mergedText, "}", backwards: true) is { } close)
        {
            var added = string.Join("\n", extra.Select(key => $"  {key}: {mine[key]};")) + "\n";
            mergedText = mergedText.Insert(close.Start, added);
        }
        return fresh[..freshBlock.Start] + mergedText.TrimWhere(SwiftText.IsNewline) + fresh[freshBlock.End..];
    }

    /// `split(separator: "\n", omittingEmptySubsequences: false)` Swift: «\r\n» для
    /// Swift — один знак, не «\n», тож там рядок не ріжеться.
    static List<string> SplitOnLineFeed(string text, bool omitEmpty = false)
    {
        var parts = new List<string>();
        var start = 0;
        for (var index = 0; index < text.Length; index++)
        {
            if (text[index] != '\n' || (index > 0 && text[index - 1] == '\r')) continue;
            if (!omitEmpty || index > start) parts.Add(text[start..index]);
            start = index + 1;
        }
        if (!omitEmpty || text.Length > start) parts.Add(text[start..]);
        return parts;
    }

    /// Пари «ім'я: значення» з тексту блоку налаштувань.
    static Dictionary<string, string> Values(string block)
    {
        var table = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var text in SplitOnLineFeed(block, omitEmpty: true))
        {
            if (VariableName(text) is not { } name) continue;
            var after = WebText.Find(text, name) is { } at ? at.End : 0;
            if (WebText.Find(text, ":", after) is not { } colon) continue;
            var value = text[colon.End..].TrimWhitespaces();
            if (value.EndsWith(';')) value = value[..^1];
            table[name] = value.TrimWhitespaces();
        }
        return table;
    }

    /// Ім'я змінної в рядку виду «  --sl-щось: значення;».
    /// Лише рядок-оголошення, що починається з `--sl-` (як на Mac після виправлення): рядок
    /// `@keyframes vhod-svechenie { … var(--sl-accent, …) … opacity: 1 }` давав «ім'я» від
    /// `--sl-accent` до двокрапки в `opacity:`, і перенесення налаштувань його переписувало.
    static string? VariableName(string line)
    {
        var trimmed = line.TrimStart(' ', '\t');
        if (!trimmed.StartsWith("--sl-", StringComparison.Ordinal)) return null;
        var colon = trimmed.IndexOf(':');
        return colon < 0 ? null : trimmed[..colon].TrimWhitespaces();
    }

    /// Межі блоку налаштувань — від маркера початку до маркера кінця.
    static TextSpan? SettingsBlockRange(string page)
    {
        if (MarkerRange(VarsMarkers, page) is not { } start) return null;
        if (MarkerRange(VarsEndMarkers, page, from: start.End) is not { } end) return null;
        var head = WebText.Find(page, ":root", 0, start.Start, backwards: true)
                   ?? WebText.Find(page, "/*", 0, start.Start, backwards: true);
        if (head is not { } h) return null;
        if (WebText.Find(page, "}", end.End) is not { } tail) return null;
        return new TextSpan(h.Start, tail.End);
    }

    public const string VarsMarker = "── Слово: налаштування ──";
    public const string VarsEndMarker = "── кінець налаштувань ──";
    public const string BindMarker = "── Слово: прив'язка ──";
    public const string BindEndMarker = "── кінець прив'язки ──";
    public const string LiveMarker = "── Слово: живі налаштування ──";
    public const string LiveEndMarker = "── кінець живих налаштувань ──";

    /// Дужки, за якими панель упізнає наш блок. Їх не перекладають ніколи: колись
    /// панель шукала російські слова підпису, підпис переклали — і блок «пропав».
    public const string VarsToken = "[slovo-vars]";
    public const string VarsEndToken = "[/slovo-vars]";

    /// Як мітка писалася в попередніх випусках — шукати треба будь-яку з них.
    public static readonly IReadOnlyList<string> VarsMarkers = [VarsMarker, "── Слово: настройки ──"];
    public static readonly IReadOnlyList<string> VarsEndMarkers = [VarsEndMarker, "── конец настроек ──"];

    /// Перше входження будь-якої з міток (по черзі міток, а не найраніше).
    public static TextSpan? MarkerRange(IEnumerable<string> needles, string text, int from = 0, int to = -1,
                                        bool backwards = false)
    {
        foreach (var needle in needles)
            if (WebText.Find(text, needle, from, to, backwards: backwards) is { } found) return found;
        return null;
    }

    // ── Каталог ───────────────────────────────────────────────────────────────

    static WebSlideParameter[]? _all;
    public static IReadOnlyList<WebSlideParameter> All => _all ??=
        [.. TextParameters, .. StrokeParameters, .. ReferenceParameters, .. SecondParameters,
         .. NextParameters, .. NumberParameters, .. LayoutParameters, .. PlateParameters,
         .. BackgroundParameters, .. AppearParameters, .. AnimationParameters];

    static Dictionary<string, WebSlideParameter>? _index;

    public static WebSlideParameter? Parameter(string name)
    {
        if (_index == null)
        {
            var map = new Dictionary<string, WebSlideParameter>(StringComparer.Ordinal);
            foreach (var parameter in All) map[parameter.Name] = parameter;
            _index = map;
        }
        return _index.TryGetValue(name, out var found) ? found : null;
    }

    /// Усе за умовчанням — з цього починається нова сторінка.
    public static WebSlideSettings Defaults => new WebSlideSettings().ApplyingDefaults();

    public static IReadOnlyList<WebSlideParameter> Parameters(Group group) =>
        All.Where(parameter => parameter.Section == group && parameter.ShowsInPanel).ToList();

    // ── Текст

    static readonly WebSlideParameter[] TextParameters =
    [
        new("--sl-font", "Шрифт", group: Group.Text,
              kind: Kind.Choice([
                  new("\"Helvetica Neue\", Arial, sans-serif", "Без засечек"),
                  new("Georgia, \"Times New Roman\", serif", "С засечками"),
                  new("\"Arial Narrow\", \"Helvetica Neue Condensed\", sans-serif", "Узкий"),
                  new("Menlo, \"SF Mono\", monospace", "Моноширинный"),
                  new("-apple-system, system-ui, sans-serif", "Системный"),
                  new("\"Snell Roundhand\", cursive", "Рукописный"),
              ]),
              @default: "\"Helvetica Neue\", Arial, sans-serif",
              hint: "Шрифт берётся из тех, что есть в браузере, а не из папки Fonts."),

        new("--sl-unit", "От чего мерить кегль", group: Group.Text,
              kind: Kind.Choice([
                  new("1vw", "От ширины экрана"),
                  new("1vh", "От высоты экрана"),
              ]),
              @default: "1vw",
              hint: "От ширины — как в наших заготовках. От высоты — как в оформлении слайда программы."),

        new("--sl-size", "Размер текста", group: Group.Text,
              kind: Kind.Number(min: 1.5, max: 20, step: 0.1, unit: ""),
              @default: "6",
              hint: "Доли той стороны экрана, что выбрана выше."),

        new("--sl-weight", "Насыщенность", group: Group.Text,
              kind: Kind.Number(min: 100, max: 900, step: 10, unit: ""),
              @default: "700",
              hint: "400 — обычный, 700 — полужирный. Тонкие начертания есть не у всякого шрифта."),

        new("--sl-stretch", "Ширина букв", group: Group.Text,
              kind: Kind.Choice([
                  new("condensed", "Сжатые"),
                  new("semi-condensed", "Слегка сжатые"),
                  new("normal", "Обычные"),
                  new("semi-expanded", "Слегка широкие"),
                  new("expanded", "Широкие"),
                  new("ultra-expanded", "Самые широкие"),
              ]),
              @default: "normal",
              hint: "Работает только у шрифтов, где такие начертания есть."),

        new("--sl-italic", "Курсив", group: Group.Text,
              kind: Kind.Toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              @default: "normal",
              hint: "Длинный текст курсивом читается с дальнего ряда хуже."),

        new("--sl-caps", "Прописными", group: Group.Text,
              kind: Kind.Toggle(on: "uppercase", off: "none", onTitle: "ВСЕ ПРОПИСНЫЕ", offTitle: "Как есть"),
              @default: "none",
              hint: "Меняет только вид, сам текст остаётся прежним."),

        new("--sl-tracking", "Разрядка", group: Group.Text,
              kind: Kind.Number(min: -0.05, max: 0.2, step: 0.01, unit: "em"),
              @default: "0em",
              hint: "Расстояние между буквами. Отрицательное сжимает."),

        new("--sl-line", "Междустрочие", group: Group.Text,
              kind: Kind.Number(min: 0.9, max: 2.2, step: 0.05, unit: ""),
              @default: "1.25",
              hint: "Во сколько раз строка выше кегля."),

        new("--sl-color", "Цвет текста", group: Group.Text,
              kind: Kind.Color, @default: "#ffffff",
              hint: "На проекторе чистый белый часто засвечивает — попробуйте чуть темнее."),

        new("--sl-text-opacity", "Непрозрачность текста", group: Group.Text,
              kind: Kind.Fraction(min: 0, max: 1), @default: "1",
              hint: "1 — текст как есть, 0 — совсем прозрачный."),

        new("--sl-align", "Выравнивание", group: Group.Text,
              kind: Kind.Choice([
                  new("left", "По левому краю"),
                  new("center", "По центру"),
                  new("right", "По правому краю"),
                  new("justify", "По ширине"),
              ]),
              @default: "center",
              hint: "«По ширине» — как в книге, у автора так сделана страница для Библии."),

        new("--sl-width", "Ширина колонки", group: Group.Text,
              kind: Kind.Number(min: 20, max: 100, step: 1, unit: "%"),
              @default: "90%",
              hint: "Узкая колонка читается легче: глаз не бегает через весь экран."),

        new("--sl-fit", "Подбирать кегль под длину", group: Group.Text,
              kind: Kind.Toggle(on: "1", off: "0", onTitle: "Подбирать", offTitle: "Не подбирать"),
              @default: "0",
              hint: "Делает скрипт самой страницы. В чужую страницу мы дописываем только оформление, поэтому на ней ручка погашена."),
    ];

    // ── Обведення і тінь

    static readonly WebSlideParameter[] StrokeParameters =
    [
        new("--sl-stroke-on", "Обводка", group: Group.Stroke,
              kind: Kind.Toggle(on: "1", off: "0", onTitle: "Есть", offTitle: "Нет"),
              @default: "0",
              hint: "Выключатель отдельный от толщины: снятая галочка не стирает подобранное."),

        new("--sl-stroke", "Толщина обводки", group: Group.Stroke,
              kind: Kind.Number(min: 0, max: 1.5, step: 0.05, unit: ""),
              @default: "0.4",
              hint: "В сотых долях высоты экрана. Толстая обводка съедает тонкие буквы."),

        new("--sl-stroke-color", "Цвет обводки", group: Group.Stroke,
              kind: Kind.Color, @default: "#000000",
              hint: "Обводка нужна там, где под текстом светлая картинка."),

        new("--sl-shadow-on", "Тень", group: Group.Stroke,
              kind: Kind.Toggle(on: "1", off: "0", onTitle: "Есть", offTitle: "Нет"),
              @default: "1",
              hint: "Тень отделяет текст от фона надёжнее обводки и меньше портит буквы."),

        new("--sl-shadow-offset", "Смещение тени", group: Group.Stroke,
              kind: Kind.Number(min: 0, max: 8, step: 0.1, unit: ""),
              @default: "2.7",
              hint: "Проценты от кегля — те же числа, что в оформлении слайда программы."),

        new("--sl-shadow-blur", "Сглаживание тени", group: Group.Stroke,
              kind: Kind.Number(min: 0, max: 25, step: 0.5, unit: ""),
              @default: "7",
              hint: "Проценты от кегля."),

        new("--sl-shadow-opacity", "Прозрачность тени", group: Group.Stroke,
              kind: Kind.Fraction(min: 0, max: 1), @default: "0.55",
              hint: "0 — тени не видно, 1 — совсем плотная."),

        new("--sl-shadow-rgb", "Цвет тени", group: Group.Stroke,
              kind: Kind.ColorRGB, @default: "0 0 0",
              hint: "Прозрачность у тени своя, поэтому цвет хранится тройкой чисел."),
    ];

    // ── Адреса

    static readonly WebSlideParameter[] ReferenceParameters =
    [
        new("--sl-ref-display", "Показывать адрес", group: Group.Reference,
              kind: Kind.Toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              @default: "block",
              hint: "На песнях адрес обычно скрывают."),

        new("--sl-ref-size", "Размер адреса", group: Group.Reference,
              kind: Kind.Fraction(min: 0.2, max: 1), @default: "0.45",
              hint: "Доля от размера основного текста."),

        new("--sl-ref-color", "Цвет адреса", group: Group.Reference,
              kind: Kind.Color, @default: "#ffd98a",
              hint: "Отличный от текста цвет помогает не путать адрес со стихом."),

        new("--sl-ref-italic", "Курсив у адреса", group: Group.Reference,
              kind: Kind.Toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              @default: "italic",
              hint: ""),

        new("--sl-ref-place", "Где адрес", group: Group.Reference,
              kind: Kind.Choice([
                  new("under", "Под текстом",
                        implies: [("--sl-ref-order", "2"), ("--sl-ref-self", "center")]),
                  new("above", "Над текстом",
                        implies: [("--sl-ref-order", "-1"), ("--sl-ref-self", "center")]),
                  new("bottom-right", "Справа внизу",
                        implies: [("--sl-ref-order", "2"), ("--sl-ref-self", "flex-end")]),
                  new("bottom-left", "Слева внизу",
                        implies: [("--sl-ref-order", "2"), ("--sl-ref-self", "flex-start")]),
              ]),
              @default: "under",
              hint: "Углы считаются от колонки с текстом, а не от края экрана."),

        new("--sl-ref-order", "Порядок адреса", group: Group.Reference,
              kind: Kind.Choice([new("-1", "Перед текстом"), new("2", "После текста")]),
              @default: "2",
              hint: "Пишется вместе с выбором «где адрес».",
              showsInPanel: false),

        new("--sl-ref-self", "Прижим адреса", group: Group.Reference,
              kind: Kind.Choice([
                  new("flex-start", "К левому краю"),
                  new("center", "По центру"),
                  new("flex-end", "К правому краю"),
              ]),
              @default: "center",
              hint: "Пишется вместе с выбором «где адрес».",
              showsInPanel: false),

        new("--sl-ref-gap", "Отступ адреса", group: Group.Reference,
              kind: Kind.Number(min: 0, max: 8, step: 0.1, unit: "vh"),
              @default: "1.5vh",
              hint: "Просвет между текстом и адресом."),
    ];

    // ── Другий переклад

    static readonly WebSlideParameter[] SecondParameters =
    [
        new("--sl-second-display", "Показывать второй перевод", group: Group.Second,
              kind: Kind.Toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              // Теж не ховаємо за умовчанням — з тієї самої причини. Порожній блок
              // і так схлопується правилом `.empty { display: none }`.
              @default: "block",
              hint: "Второй перевод приходит из программы в Var1; если он выключен, блок пуст."),

        new("--sl-second-size", "Размер второго", group: Group.Second,
              kind: Kind.Fraction(min: 0.4, max: 1), @default: "0.8",
              hint: "Доля от основного текста."),

        new("--sl-second-color", "Цвет второго", group: Group.Second,
              kind: Kind.Color, @default: "#cfe0ff",
              hint: ""),

        new("--sl-second-italic", "Курсив у второго", group: Group.Second,
              kind: Kind.Toggle(on: "italic", off: "normal", onTitle: "Курсивом", offTitle: "Прямой"),
              @default: "italic",
              hint: ""),

        new("--sl-second-place", "Как ставить второй", group: Group.Second,
              kind: Kind.Choice([
                  new("column", "Под основным"),
                  new("row", "Рядом, двумя колонками"),
              ]),
              @default: "column",
              hint: "В два столбца адрес встаёт в тот же ряд — проверьте его на предпросмотре."),
    ];

    // ── Наступний вірш

    static readonly WebSlideParameter[] NextParameters =
    [
        new("--sl-next-display", "Показывать следующий", group: Group.Next,
              kind: Kind.Toggle(on: "block", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              // За умовчанням НЕ ховаємо: сторінка, якій ми надягли блок
              // налаштувань, зобов'язана виглядати рівно як до цього. Заготовки,
              // яким наступний вірш не потрібен, вимикають його в себе самі.
              @default: "block",
              hint: "Это для экрана служителя, а не для зала."),

        new("--sl-next-size", "Размер следующего", group: Group.Next,
              kind: Kind.Fraction(min: 0.2, max: 0.8), @default: "0.35",
              hint: "Доля от основного текста."),

        new("--sl-next-color", "Цвет следующего", group: Group.Next,
              kind: Kind.Color, @default: "#7f8fa6",
              hint: "Приглушённый цвет, чтобы не спорил с текущим стихом."),

        new("--sl-next-rule", "Разделитель", group: Group.Next,
              kind: Kind.Number(min: 0, max: 0.5, step: 0.05, unit: "vh"),
              @default: "0.1vh",
              hint: "Толщина черты над следующим стихом. Ноль — черты нет."),
    ];

    // ── Номери віршів

    static readonly WebSlideParameter[] NumberParameters =
    [
        new("--sl-num-display", "Показывать номера стихов", group: Group.Numbers,
              kind: Kind.Toggle(on: "inline", off: "none", onTitle: "Показывать", offTitle: "Скрыть"),
              @default: "none",
              hint: "Номера выделяет из текста скрипт страницы. Там, где его нет, ручка погашена."),

        new("--sl-num-size", "Размер номера", group: Group.Numbers,
              kind: Kind.Fraction(min: 0.4, max: 0.9), @default: "0.6",
              hint: "Доля от размера того текста, где номер стоит."),

        new("--sl-num-color", "Цвет номера", group: Group.Numbers,
              kind: Kind.Color, @default: "#ffd98a",
              hint: ""),
    ];

    // ── Розташування

    static readonly WebSlideParameter[] LayoutParameters =
    [
        new("--sl-anchor", "Где текст на экране", group: Group.Layout,
              kind: Kind.Choice([
                  new("top-left", "Сверху слева",
                        implies: [("--sl-h", "flex-start"), ("--sl-v", "flex-start")]),
                  new("top-center", "Сверху по центру",
                        implies: [("--sl-h", "center"), ("--sl-v", "flex-start")]),
                  new("top-right", "Сверху справа",
                        implies: [("--sl-h", "flex-end"), ("--sl-v", "flex-start")]),
                  new("center-left", "Посередине слева",
                        implies: [("--sl-h", "flex-start"), ("--sl-v", "center")]),
                  new("center-center", "По центру",
                        implies: [("--sl-h", "center"), ("--sl-v", "center")]),
                  new("center-right", "Посередине справа",
                        implies: [("--sl-h", "flex-end"), ("--sl-v", "center")]),
                  new("bottom-left", "Снизу слева",
                        implies: [("--sl-h", "flex-start"), ("--sl-v", "flex-end")]),
                  new("bottom-center", "Снизу по центру",
                        implies: [("--sl-h", "center"), ("--sl-v", "flex-end")]),
                  new("bottom-right", "Снизу справа",
                        implies: [("--sl-h", "flex-end"), ("--sl-v", "flex-end")]),
              ]),
              @default: "center-center",
              hint: "Девять точек привязки. Перетаскивание мышью встаёт на ближайшую."),

        new("--sl-h", "Прижим по горизонтали", group: Group.Layout,
              kind: Kind.Choice([
                  new("flex-start", "К левому краю"),
                  new("center", "По центру"),
                  new("flex-end", "К правому краю"),
              ]),
              @default: "center",
              hint: "Обычно ставится выбором точки привязки."),

        new("--sl-v", "Прижим по вертикали", group: Group.Layout,
              kind: Kind.Choice([
                  new("flex-start", "К верху"),
                  new("center", "По середине"),
                  new("flex-end", "К низу"),
                  new("space-between", "Растянуть по высоте"),
              ]),
              @default: "center",
              hint: "«Растянуть» разводит текст и адрес по краям — так сделан экран служителя."),

        new("--sl-offset-x", "Сдвиг вправо", group: Group.Layout,
              kind: Kind.Number(min: -40, max: 40, step: 0.5, unit: ""),
              @default: "0",
              hint: "Сотые доли ширины экрана. Отрицательное двигает влево."),

        new("--sl-offset-y", "Сдвиг вниз", group: Group.Layout,
              kind: Kind.Number(min: -40, max: 40, step: 0.5, unit: ""),
              @default: "0",
              hint: "Сотые доли высоты экрана. Отрицательное двигает вверх."),

        new("--sl-pad-x", "Поля по бокам", group: Group.Layout,
              kind: Kind.Number(min: 0, max: 20, step: 0.5, unit: "vw"),
              @default: "5vw",
              hint: ""),

        new("--sl-pad-y", "Поля сверху и снизу", group: Group.Layout,
              kind: Kind.Number(min: 0, max: 20, step: 0.5, unit: "vh"),
              @default: "4vh",
              hint: ""),

        new("--sl-safe", "Запас на телевизор", group: Group.Layout,
              kind: Kind.Number(min: 0, max: 10, step: 0.5, unit: "%"),
              @default: "0%",
              hint: "Старые телевизоры срезают края кадра. Запас отодвигает текст от края."),
    ];


    // ── Поява і зникнення

    /// Двадцять ефектів; текст і підкладка вибирають їх незалежно —
    /// власник просив, щоб підкладка жила своїм життям.
    static readonly WebSlideParameter[] AnimationParameters =
    [
        new("--sl-anim-in", "Как появляется текст", group: Group.Appear,
              kind: Kind.Choice([
                  new("none", "без эффекта"),
                  new("vhod-rastvorenie", "растворение"),
                  new("vhod-snizu", "выезд снизу"),
                  new("vhod-sverhu", "выезд сверху"),
                  new("vhod-sleva", "выезд слева"),
                  new("vhod-sprava", "выезд справа"),
                  new("vhod-naplyv", "наплыв"),
                  new("vhod-otdalenie", "отдаление"),
                  new("vhod-razmytie", "размытие"),
                  new("vhod-perevorot", "переворот"),
                  new("vhod-povorot", "поворот"),
                  new("vhod-otskok", "отскок"),
                  new("vhod-pruzhina", "пружина"),
                  new("vhod-shtorka-vpravo", "шторка вправо"),
                  new("vhod-shtorka-vlevo", "шторка влево"),
                  new("vhod-shtorka-vniz", "шторка вниз"),
                  new("vhod-shtorka-vverh", "шторка вверх"),
                  new("vhod-zanaves", "занавес"),
                  new("vhod-lupa", "лупа"),
                  new("vhod-kachaniye", "качание"),
                  new("vhod-svechenie", "свечение"),
                  new("vhod-padenie", "падение"),
                  new("vhod-vypolzanie", "выползание"),
                  new("vhod-szhatie", "сжатие"),
                  new("vhod-razvorot", "разворот"),
                  new("vhod-mercanie", "мерцание"),
                  new("vhod-volna", "волна"),
              ]),
              @default: "vhod-rastvorenie",
              hint: "Играет при выводе нового текста; длительность — «Длительность перехода»."),

        new("--sl-anim-out", "Как исчезает текст", group: Group.Appear,
              kind: Kind.Choice([
                  new("none", "без эффекта"),
                  new("vyhod-rastvorenie", "растворение"),
                  new("vyhod-snizu", "выезд снизу"),
                  new("vyhod-sverhu", "выезд сверху"),
                  new("vyhod-sleva", "выезд слева"),
                  new("vyhod-sprava", "выезд справа"),
                  new("vyhod-naplyv", "наплыв"),
                  new("vyhod-otdalenie", "отдаление"),
                  new("vyhod-razmytie", "размытие"),
                  new("vyhod-perevorot", "переворот"),
                  new("vyhod-povorot", "поворот"),
                  new("vyhod-otskok", "отскок"),
                  new("vyhod-pruzhina", "пружина"),
                  new("vyhod-shtorka-vpravo", "шторка вправо"),
                  new("vyhod-shtorka-vlevo", "шторка влево"),
                  new("vyhod-shtorka-vniz", "шторка вниз"),
                  new("vyhod-shtorka-vverh", "шторка вверх"),
                  new("vyhod-zanaves", "занавес"),
                  new("vyhod-lupa", "лупа"),
                  new("vyhod-kachaniye", "качание"),
                  new("vyhod-svechenie", "свечение"),
                  new("vyhod-padenie", "падение"),
                  new("vyhod-vypolzanie", "выползание"),
                  new("vyhod-szhatie", "сжатие"),
                  new("vyhod-razvorot", "разворот"),
                  new("vyhod-mercanie", "мерцание"),
                  new("vyhod-volna", "волна"),
              ]),
              @default: "vyhod-rastvorenie",
              hint: "Играет, когда текст уходит: перед следующим или при пустом экране."),

        new("--sl-plate-in", "Как появляется подложка", group: Group.Appear,
              kind: Kind.Choice([
                  new("none", "без эффекта"),
                  new("vhod-rastvorenie", "растворение"),
                  new("vhod-snizu", "выезд снизу"),
                  new("vhod-sverhu", "выезд сверху"),
                  new("vhod-sleva", "выезд слева"),
                  new("vhod-sprava", "выезд справа"),
                  new("vhod-naplyv", "наплыв"),
                  new("vhod-otdalenie", "отдаление"),
                  new("vhod-razmytie", "размытие"),
                  new("vhod-perevorot", "переворот"),
                  new("vhod-povorot", "поворот"),
                  new("vhod-otskok", "отскок"),
                  new("vhod-pruzhina", "пружина"),
                  new("vhod-shtorka-vpravo", "шторка вправо"),
                  new("vhod-shtorka-vlevo", "шторка влево"),
                  new("vhod-shtorka-vniz", "шторка вниз"),
                  new("vhod-shtorka-vverh", "шторка вверх"),
                  new("vhod-zanaves", "занавес"),
                  new("vhod-lupa", "лупа"),
                  new("vhod-kachaniye", "качание"),
                  new("vhod-svechenie", "свечение"),
                  new("vhod-padenie", "падение"),
                  new("vhod-vypolzanie", "выползание"),
                  new("vhod-szhatie", "сжатие"),
                  new("vhod-razvorot", "разворот"),
                  new("vhod-mercanie", "мерцание"),
                  new("vhod-volna", "волна"),
              ]),
              @default: "none",
              hint: "Подложка может выезжать иначе, чем текст, — или стоять неподвижно."),

        new("--sl-plate-out", "Как исчезает подложка", group: Group.Appear,
              kind: Kind.Choice([
                  new("none", "без эффекта"),
                  new("vyhod-rastvorenie", "растворение"),
                  new("vyhod-snizu", "выезд снизу"),
                  new("vyhod-sverhu", "выезд сверху"),
                  new("vyhod-sleva", "выезд слева"),
                  new("vyhod-sprava", "выезд справа"),
                  new("vyhod-naplyv", "наплыв"),
                  new("vyhod-otdalenie", "отдаление"),
                  new("vyhod-razmytie", "размытие"),
                  new("vyhod-perevorot", "переворот"),
                  new("vyhod-povorot", "поворот"),
                  new("vyhod-otskok", "отскок"),
                  new("vyhod-pruzhina", "пружина"),
                  new("vyhod-shtorka-vpravo", "шторка вправо"),
                  new("vyhod-shtorka-vlevo", "шторка влево"),
                  new("vyhod-shtorka-vniz", "шторка вниз"),
                  new("vyhod-shtorka-vverh", "шторка вверх"),
                  new("vyhod-zanaves", "занавес"),
                  new("vyhod-lupa", "лупа"),
                  new("vyhod-kachaniye", "качание"),
                  new("vyhod-svechenie", "свечение"),
                  new("vyhod-padenie", "падение"),
                  new("vyhod-vypolzanie", "выползание"),
                  new("vyhod-szhatie", "сжатие"),
                  new("vyhod-razvorot", "разворот"),
                  new("vyhod-mercanie", "мерцание"),
                  new("vyhod-volna", "волна"),
              ]),
              @default: "none",
              hint: "Играет, когда в зале пустой экран."),
    ];

    // ── Підкладка

    static readonly WebSlideParameter[] PlateParameters =
    [
        new("--sl-plate-rgb", "Цвет подложки", group: Group.Plate,
              kind: Kind.ColorRGB, @default: "0 0 0",
              hint: "Прозрачность у подложки отдельная, поэтому цвет хранится тройкой чисел."),

        new("--sl-plate-opacity", "Прозрачность подложки", group: Group.Plate,
              kind: Kind.Fraction(min: 0, max: 1), @default: "0.3",
              hint: "0,3 — как на страницах автора. 0 — подложки нет вовсе."),

        new("--sl-plate-full", "Ширина подложки", group: Group.Plate,
              kind: Kind.Choice([
                  new("1", "Полосой во всю ширину"),
                  new("0", "По размеру текста"),
              ]),
              @default: "0",
              hint: "Ровно то, чем страницы автора CF и CF1 отличаются друг от друга."),

        new("--sl-plate-pad-x", "Поля подложки по бокам", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 10, step: 0.25, unit: "vw"),
              @default: "2vw",
              hint: ""),

        new("--sl-plate-pad-y", "Поля подложки сверху и снизу", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 10, step: 0.25, unit: "vh"),
              @default: "2vh",
              hint: ""),

        new("--sl-plate-radius", "Скругление углов", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 6, step: 0.1, unit: "vh"),
              @default: "1.6vh",
              hint: "У автора это 16 точек; в долях высоты скругление не меняется от разрешения."),

        new("--sl-plate-blur", "Размытие под подложкой", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 4, step: 0.1, unit: "vh"),
              @default: "0vh",
              hint: "Размывает то, что видно сквозь подложку. В видеомикшере может не сработать."),

        new("--sl-plate-border", "Рамка подложки", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 0.8, step: 0.05, unit: "vh"),
              @default: "0vh",
              hint: ""),

        new("--sl-plate-border-color", "Цвет рамки", group: Group.Plate,
              kind: Kind.Color, @default: "#ffffff",
              hint: ""),

        new("--sl-plate-shadow", "Тень подложки", group: Group.Plate,
              kind: Kind.Number(min: 0, max: 5, step: 0.1, unit: "vh"),
              @default: "0vh",
              hint: ""),
    ];

    // ── Фон

    static readonly WebSlideParameter[] BackgroundParameters =
    [
        new("--sl-bg-mode", "Чем залит фон", group: Group.Background,
              kind: Kind.Choice([
                  new("transparent", "Прозрачный, для видеомикшера",
                        implies: [("--sl-page-opacity", "0"), ("--sl-bg-image", "none")]),
                  new("solid", "Однотонный",
                        implies: [("--sl-page-opacity", "1"), ("--sl-bg-image", "none")]),
                  new("image", "Картинкой",
                        implies: [("--sl-page-opacity", "1")]),
                  new("gradient", "Переходом цвета",
                        implies: [("--sl-page-opacity", "1"), ("--sl-bg-image", "linear-gradient(180deg, rgb(var(--sl-page-rgb)), rgb(0 0 0))")]),
              ]),
              @default: "solid",
              hint: "Прозрачный в браузере выглядит белым, а в OBS или vMix — прозрачным."),

        new("--sl-page-rgb", "Цвет фона", group: Group.Background,
              kind: Kind.ColorRGB, @default: "11 26 51",
              hint: "Тройкой чисел, потому что прозрачность фона отдельная."),

        new("--sl-page-opacity", "Плотность фона", group: Group.Background,
              kind: Kind.Fraction(min: 0, max: 1), @default: "1",
              hint: "0 — фон прозрачный, для наложения поверх картинки камеры."),

        new("--sl-bg-image", "Картинка фона", group: Group.Background,
              kind: Kind.Link, @default: "none",
              hint: "Ссылка вида url(\"…\"). Слово none — картинки нет."),

        new("--sl-bg-fit", "Как вписать картинку", group: Group.Background,
              kind: Kind.Choice([
                  new("cover", "Заполнить экран", implies: [("--sl-bg-repeat", "no-repeat")]),
                  new("contain", "Вписать целиком", implies: [("--sl-bg-repeat", "no-repeat")]),
                  new("auto", "Замостить", implies: [("--sl-bg-repeat", "repeat")]),
              ]),
              @default: "cover",
              hint: "«Заполнить» обрезает края, «вписать» оставляет поля."),

        new("--sl-bg-repeat", "Повтор картинки", group: Group.Background,
              kind: Kind.Choice([new("no-repeat", "Без повтора"), new("repeat", "Повторять")]),
              @default: "no-repeat",
              hint: "Пишется вместе с выбором «как вписать картинку».",
              showsInPanel: false),

        new("--sl-bg-pos", "Куда двинуть картинку", group: Group.Background,
              kind: Kind.Choice([
                  new("left top", "Влево вверх"),
                  new("center top", "По центру вверх"),
                  new("right top", "Вправо вверх"),
                  new("left center", "Влево"),
                  new("center center", "По центру"),
                  new("right center", "Вправо"),
                  new("left bottom", "Влево вниз"),
                  new("center bottom", "По центру вниз"),
                  new("right bottom", "Вправо вниз"),
              ]),
              @default: "center center",
              hint: ""),

        new("--sl-bg-blur", "Размытие фона", group: Group.Background,
              kind: Kind.Number(min: 0, max: 5, step: 0.1, unit: "vh"),
              @default: "0vh",
              hint: "Размытая фотография не спорит с текстом."),

        new("--sl-dim", "Затемнение фона", group: Group.Background,
              kind: Kind.Fraction(min: 0, max: 1), @default: "0.45",
              hint: "Слой поверх картинки. 0 — картинка как есть."),

        new("--sl-dim-rgb", "Цвет затемнения", group: Group.Background,
              kind: Kind.ColorRGB, @default: "0 0 0",
              hint: "Белый цвет даёт не затемнение, а осветление."),
    ];

    // ── Поява

    static readonly WebSlideParameter[] AppearParameters =
    [
        new("--sl-transition", "Как сменяется слайд", group: Group.Appear,
              kind: Kind.Choice([
                  new("none", "Без перехода"),
                  new("fade", "Растворение"),
                  new("slideLeft", "Сдвиг влево"),
                  new("slideUp", "Сдвиг вверх"),
                  new("zoom", "Наплыв"),
              ]),
              @default: "fade",
              hint: "Делает скрипт самой страницы. В чужую страницу мы дописываем только оформление, поэтому на ней ручка погашена."),

        new("--sl-fade", "Длительность перехода", group: Group.Appear,
              kind: Kind.Number(min: 0, max: 1.5, step: 0.05, unit: "s"),
              @default: "0.35s",
              hint: "Резкая подмена текста на большом экране читается как рывок."),
    ];

    // ── Готовий CSS ───────────────────────────────────────────────────────────

    /// Одне оголошення — ним користується і запис у файл, і перенесення значення.
    public static string Declaration(string name, string value) => $"{name}: {value};";

    /// Увесь набір одним правилом `:root` — тіло блоку налаштувань.
    public static string RootCSS(WebSlideSettings settings, string indent = "  ")
    {
        var lines = new List<string> { ":root {" };
        foreach (var (name, value) in settings.WritingOrder) lines.Add(indent + Declaration(name, value));
        lines.Add("}");
        return string.Join("\n", lines);
    }

    /// Скрипт для живого передпоказу: та сама пачка значень, але в сторінку без
    /// перезавантаження. Інлайновий стиль на `documentElement` б'є будь-яке правило
    /// `:root`, тому живе значення завжди головніше за файл.
    public static string PreviewScript(IReadOnlyDictionary<string, string> changes)
    {
        if (changes.Count == 0) return "";
        var lines = new List<string> { "var s = document.documentElement.style;" };
        foreach (var name in changes.Keys.OrderBy(key => key, StringComparer.Ordinal))
        {
            var value = changes[name];
            if (!IsWritable(value)) continue;
            lines.Add($"s.setProperty('{EscapeForScript(name)}','{EscapeForScript(value)}');");
        }
        // Частина ручок рахується не з CSS: добір кегля, лапки, переноси рядків.
        // Просимо сторінку перерахуватися — якщо вона вміє.
        lines.Add("if (window.slovoRefresh) { try { window.slovoRefresh(); } catch (e) {} }");
        return string.Join("\n", lines);
    }

    static string EscapeForScript(string value) => value.Replace("\\", "\\\\").Replace("'", "\\'");

    // ── Селектори ролей ───────────────────────────────────────────────────────

    /// Чим у сторінці дістаються ролі — накриває і наші заготовки, і всі шість
    /// сторінок автора.
    public sealed record RoleSelectors(string Page, string Stage, string Quote, string Reference,
                                       string Second, string Next, string Number,
                                       string StageFallback = "", string NextForeign = "")
    {
        /// З чого зібрано запасний селектор сцени — він же список справжніх сцен.
        public const string StageNames = ".slide, .strip, .stage, .background, #text-container, [data-slovo=\"stage\"]";

        public static readonly RoleSelectors Standard = new(
            Page: "body",
            Stage: StageNames,
            Quote: ".quote, .content, #content, #content1, #content2, #text-content, [data-slovo=\"quote\"]",
            Reference: ".reference, .contentTitle, [data-slovo=\"reference\"]",
            Second: ".second, [data-slovo=\"second\"]",
            // Своїми вимикачами розпоряджаємося лише своєю розміткою; чужий блок із
            // наступним віршем — у NextForeign, і видимість йому не міняється ніколи.
            Next: ".next, [data-slovo=\"next\"]",
            Number: ".sl-num",
            // Два запасні селектори для сторінок без сцени: `:has()` старий WebKit не
            // знає і викидає правило цілком, тому поруч — мітка, яку ставить наш скрипт.
            StageFallback: "body:not(:has(" + StageNames + ")), body[data-slovo-nostage]",
            NextForeign: "#bottom-container");

        /// Що з переліченого в цій розмітці і справді є. Дивимося в текст сторінки
        /// цілком, разом зі скриптами: в автора `.contentTitle` народжується рядком у
        /// `contentText +=`, і до першого слайда такого елемента в розмітці немає.
        public HashSet<WebSlideParameter.Role> Present(string source)
        {
            // Свої блоки знімаємо: інакше сторінка «знаходила» б у собі всі ролі за нашим же текстом.
            var html = StripBlocks(source);
            var found = new HashSet<WebSlideParameter.Role>();
            var pairs = new (WebSlideParameter.Role, string)[]
            {
                (WebSlideParameter.Role.Page, Page),
                (WebSlideParameter.Role.Stage, Stage + ", " + Page),   // тіла досить: сцена підставиться запасним правилом
                (WebSlideParameter.Role.Quote, Quote),
                (WebSlideParameter.Role.Reference, Reference),
                (WebSlideParameter.Role.Second, Second),
                (WebSlideParameter.Role.Next, Next + (NextForeign.Length == 0 ? "" : ", " + NextForeign)),
                (WebSlideParameter.Role.NextOwn, Next),
                (WebSlideParameter.Role.Number, Number),
            };
            foreach (var (role, selectors) in pairs)
                if (Markup(html, selectors)) found.Add(role);
            return found;
        }
    }

    /// Чи є в розмітці хоч один елемент під цей список селекторів: `#ім'я`,
    /// `.ім'я`, `[ім'я="значення"]` і голе ім'я тега — рівно те, з чого списки складено.
    public static bool Markup(string html, string selectors) => MarkupRaw(LiveText(html), selectors);

    /// Сторінка без закоментованих рядків: в автора половина варіантів оформлення
    /// лежить закоментованою, і вважати такий рядок розміткою — обіцяти живий повзунок там, де нічого немає.
    static string LiveText(string html)
    {
        var kept = new List<string>();
        foreach (var line in WebText.Lines(html, omitEmpty: false))
        {
            var head = line.TrimStart(' ', '\t');
            if (head.StartsWith("//", StringComparison.Ordinal) || head.StartsWith("/*", StringComparison.Ordinal)
                || head.StartsWith('*')) continue;
            kept.Add(line);
        }
        return string.Join("\n", kept);
    }

    static bool MarkupRaw(string html, string selectors)
    {
        foreach (var piece in selectors.Split(','))
        {
            var one = piece.Trim();
            if (one.Length == 0 || one.Contains(':')) continue;
            if (one.StartsWith('#'))
            {
                var name = one[1..];
                if (WebText.Find(html, $"id=\"{name}\"", ignoreCase: true) != null) return true;
                if (WebText.Find(html, $"id='{name}'", ignoreCase: true) != null) return true;
            }
            else if (one.StartsWith('.'))
            {
                if (HasClass(one[1..], html)) return true;
            }
            else if (one.StartsWith('['))
            {
                if (WebText.Find(html, one, ignoreCase: true) != null) return true;
            }
            else if (WebText.Find(html, "<" + one, ignoreCase: true) != null) return true;
        }
        return false;
    }

    /// Чи стоїть таке ім'я класу хоч в одному `class="…"` — цілим словом, а не
    /// шматком: інакше `.content` знаходилося б усередині `contentTitle`.
    static bool HasClass(string name, string html)
    {
        var from = 0;
        while (WebText.Find(html, "class=", from, ignoreCase: true) is { } hit)
        {
            from = hit.End;
            var cursor = hit.End;
            while (cursor < html.Length && html[cursor] == ' ') cursor++;
            if (cursor >= html.Length || (html[cursor] != '"' && html[cursor] != '\'')) continue;
            var quote = html[cursor];
            var start = cursor + 1;
            var end = html.IndexOf(quote, start);
            if (end < 0) continue;
            if (html[start..end].Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries).Contains(name)) return true;
        }
        return false;
    }

    /// Один зв'язок: які змінні його живлять, до чого прикладається і що пише.
    /// Правило пишеться лише під ту ручку, яку і справді торкнули: не торкали —
    /// сторінка лишається рівно такою, якою була.
    internal readonly record struct Bond(string[] Names, string Selector, string Declaration);

    internal static List<Bond> Bonds(RoleSelectors roles)
    {
        const string size = "calc(var(--sl-size, 6) * var(--sl-unit, 1vw))";
        const string shadow = "calc(var(--sl-shadow-offset, 2.7) * 0.01em) calc(var(--sl-shadow-offset, 2.7) * 0.01em)"
            + " calc(var(--sl-shadow-blur, 7) * 0.01em)"
            + " rgb(var(--sl-shadow-rgb, 0 0 0) / calc(var(--sl-shadow-opacity, .55) * var(--sl-shadow-on, 1)))";
        // Зсув лише через translate і лише у vw/vh: відсотки в translate рахуються від
        // розміру самого блоку, і тоді вузький блок відстає від миші.
        const string move = "translate(calc(var(--sl-offset-x, 0) * 1vw), calc(var(--sl-offset-y, 0) * 1vh))";
        // Розкладка сцени тримається на кількох ручках разом: торкнули будь-яку —
        // сцені потрібен флекс і висота.
        string[] layout = ["--sl-h", "--sl-v", "--sl-second-place", "--sl-pad-x", "--sl-pad-y",
                           "--sl-safe", "--sl-ref-gap", "--sl-offset-x", "--sl-offset-y"];
        var stage = roles.Stage;
        var fallback = roles.StageFallback;

        var bonds = new List<Bond>();
        void bond(string[] names, string selector, string declaration) => bonds.Add(new Bond(names, selector, declaration));

        // Псевдоніми старих коротких імен: шість наших заготовок написано проти них.
        bond(["--sl-color"], ":root", "--text: var(--sl-color);");
        bond(["--sl-ref-color"], ":root", "--accent: var(--sl-ref-color);");
        bond(["--sl-size", "--sl-unit"], ":root", $"--size: {size};");
        bond(["--sl-bg-image"], ":root", "--background: var(--sl-bg-image);");
        bond(["--sl-dim"], ":root", "--dim: var(--sl-dim);");

        // Фон сторінки
        bond(["--sl-page-rgb", "--sl-page-opacity"], roles.Page,
             "background-color: rgb(var(--sl-page-rgb, 11 26 51) / var(--sl-page-opacity, 1)) !important;");
        bond(["--sl-bg-image"], roles.Page, "background-image: var(--sl-bg-image) !important;");
        bond(["--sl-bg-fit"], roles.Page, "background-size: var(--sl-bg-fit) !important;");
        bond(["--sl-bg-pos"], roles.Page, "background-position: var(--sl-bg-pos) !important;");
        bond(["--sl-bg-repeat"], roles.Page, "background-repeat: var(--sl-bg-repeat) !important;");

        // Пелена і розмиття — окремим шаром під текстом. Чотири сторони окремо, а не
        // лише `inset`: Safari 14.0 короткого запису не знає.
        string[] veil = ["--sl-dim", "--sl-dim-rgb", "--sl-bg-blur"];
        foreach (var declaration in new[] { "content: \"\" !important;", "position: fixed !important;",
                                            "top: 0 !important;", "right: 0 !important;",
                                            "bottom: 0 !important;", "left: 0 !important;",
                                            "inset: 0 !important;", "z-index: -1 !important;",
                                            "pointer-events: none !important;" })
            bond(veil, roles.Page + "::before", declaration);
        bond(veil, roles.Page + "::before",
             "background: rgb(var(--sl-dim-rgb, 0 0 0) / var(--sl-dim, 0)) !important;");
        // Розмиття — з приставкою -webkit- і без.
        bond(["--sl-bg-blur"], roles.Page + "::before",
             "-webkit-backdrop-filter: blur(var(--sl-bg-blur, 0px)) !important;");
        bond(["--sl-bg-blur"], roles.Page + "::before",
             "backdrop-filter: blur(var(--sl-bg-blur, 0px)) !important;");

        // Сцена і її запасні види — тіла сторінки. Кожен запасний селектор — своїм
        // правилом: список з незрозумілим браузеру селектором він викинув би весь.
        var fallbacks = fallback.Split(", ").Where(part => part.Length > 0);
        foreach (var selector in new[] { stage }.Concat(fallbacks))
        {
            bond(layout, selector, "display: flex !important;");
            bond(layout, selector, "min-height: 100vh !important;");
            bond(layout, selector, "flex-direction: var(--sl-second-place, column) !important;");
            bond(layout, selector, "flex-wrap: wrap !important;");
            bond(["--sl-h"], selector, "align-items: var(--sl-h, center) !important;");
            bond(["--sl-v"], selector, "justify-content: var(--sl-v, center) !important;");
            bond(["--sl-ref-gap"], selector, "gap: var(--sl-ref-gap, 1.5vh) !important;");
            bond(["--sl-pad-x", "--sl-pad-y", "--sl-safe"], selector,
                 "padding: calc(var(--sl-pad-y, 0vh) + var(--sl-safe, 0%)) calc(var(--sl-pad-x, 0vw) + var(--sl-safe, 0%)) !important;");
            bond(["--sl-offset-x", "--sl-offset-y"], selector, $"transform: {move} !important;");
        }
        bond(["--sl-text-opacity"], stage, "opacity: var(--sl-text-opacity, 1) !important;");
        bond(["--sl-plate-rgb", "--sl-plate-opacity", "--sl-plate-full"], stage,
             "background-color: rgb(var(--sl-plate-rgb, 0 0 0) / calc(var(--sl-plate-opacity, .3) * var(--sl-plate-full, 0))) !important;");

        // Текст вірша
        var quote = roles.Quote;
        bond(["--sl-second-display", "--sl-ref-order", "--sl-next-display"], quote, "order: 0 !important;");
        bond(["--sl-font"], quote, "font-family: var(--sl-font) !important;");
        bond(["--sl-size", "--sl-unit"], quote, $"font-size: {size} !important;");
        bond(["--sl-weight"], quote, "font-weight: var(--sl-weight) !important;");
        bond(["--sl-stretch"], quote, "font-stretch: var(--sl-stretch) !important;");
        bond(["--sl-italic"], quote, "font-style: var(--sl-italic) !important;");
        bond(["--sl-caps"], quote, "text-transform: var(--sl-caps) !important;");
        bond(["--sl-tracking"], quote, "letter-spacing: var(--sl-tracking) !important;");
        bond(["--sl-line"], quote, "line-height: var(--sl-line) !important;");
        bond(["--sl-color"], quote, "color: var(--sl-color) !important;");
        bond(["--sl-align"], quote, "text-align: var(--sl-align) !important;");
        bond(["--sl-width"], quote, "max-width: var(--sl-width) !important;");
        bond(["--sl-shadow-on", "--sl-shadow-offset", "--sl-shadow-blur",
              "--sl-shadow-opacity", "--sl-shadow-rgb"], quote, $"text-shadow: {shadow} !important;");
        bond(["--sl-stroke-on", "--sl-stroke"], quote,
             "-webkit-text-stroke-width: calc(var(--sl-stroke, .4) * var(--sl-stroke-on, 0) * 1vh) !important;");
        bond(["--sl-stroke-color", "--sl-stroke-on"], quote,
             "-webkit-text-stroke-color: var(--sl-stroke-color, #000000) !important;");
        bond(["--sl-plate-rgb", "--sl-plate-opacity", "--sl-plate-full"], quote,
             "background-color: rgb(var(--sl-plate-rgb, 0 0 0) / calc(var(--sl-plate-opacity, .3) * (1 - var(--sl-plate-full, 0)))) !important;");
        bond(["--sl-plate-pad-x", "--sl-plate-pad-y"], quote,
             "padding: var(--sl-plate-pad-y, 2vh) var(--sl-plate-pad-x, 2vw) !important;");
        // «За розміром тексту» — блок стискається до рядків; «смугою» — не вужче за всю ширину.
        bond(["--sl-plate-full"], quote, "width: fit-content !important;");
        bond(["--sl-plate-full"], quote, "box-sizing: border-box !important;");
        bond(["--sl-plate-full"], quote,
             "min-width: calc(var(--sl-plate-full, 0) * 100%) !important;");
        bond(["--sl-plate-radius"], quote, "border-radius: var(--sl-plate-radius) !important;");
        bond(["--sl-plate-border", "--sl-plate-border-color"], quote,
             "border: var(--sl-plate-border, 0) solid var(--sl-plate-border-color, #ffffff) !important;");
        bond(["--sl-plate-shadow"], quote,
             "box-shadow: 0 var(--sl-plate-shadow) calc(var(--sl-plate-shadow) * 2) rgb(0 0 0 / .45) !important;");
        bond(["--sl-plate-blur"], quote, "-webkit-backdrop-filter: blur(var(--sl-plate-blur)) !important;");
        bond(["--sl-plate-blur"], quote, "backdrop-filter: blur(var(--sl-plate-blur)) !important;");
        // Тривалість переходу — лише коли її торкнули: наша третина секунди поверх
        // чужого скрипту зміни слайда давала «накладання слайдів».
        bond(["--sl-fade"], quote, "transition-duration: var(--sl-fade) !important;");
        // Поява і зникнення: у тексту і в підкладки свої ефекти.
        bond(["--sl-anim-in", "--sl-fade"], quote,
             "animation: var(--sl-anim-in, none) var(--sl-fade, .35s) ease both !important;");
        bond(["--sl-anim-out"], quote + ".uhodit",
             "animation: var(--sl-anim-out, none) var(--sl-fade, .35s) ease both !important;");
        bond(["--sl-plate-in", "--sl-fade"], stage,
             "animation: var(--sl-plate-in, none) var(--sl-fade, .35s) ease both !important;");
        bond(["--sl-plate-out"], stage + ".uhodit",
             "animation: var(--sl-plate-out, none) var(--sl-fade, .35s) ease both !important;");

        // Другий переклад
        var second = roles.Second;
        bond(["--sl-second-display"], second, "order: 1 !important;");
        bond(["--sl-second-display"], second, "display: var(--sl-second-display) !important;");
        bond(["--sl-second-size"], second, $"font-size: calc({size} * var(--sl-second-size)) !important;");
        bond(["--sl-second-color"], second, "color: var(--sl-second-color) !important;");
        bond(["--sl-second-italic"], second, "font-style: var(--sl-second-italic) !important;");
        bond(["--sl-line"], second, "line-height: var(--sl-line) !important;");
        bond(["--sl-width"], second, "max-width: var(--sl-width) !important;");

        // Адреса
        var reference = roles.Reference;
        bond(["--sl-ref-order"], reference, "order: var(--sl-ref-order) !important;");
        bond(["--sl-ref-self"], reference, "align-self: var(--sl-ref-self) !important;");
        bond(["--sl-ref-display"], reference, "display: var(--sl-ref-display) !important;");
        bond(["--sl-ref-size"], reference, $"font-size: calc({size} * var(--sl-ref-size)) !important;");
        bond(["--sl-ref-color"], reference, "color: var(--sl-ref-color) !important;");
        bond(["--sl-ref-italic"], reference, "font-style: var(--sl-ref-italic) !important;");
        bond(["--sl-ref-gap"], reference, "margin-top: var(--sl-ref-gap) !important;");

        // Наступний вірш — свій і чужий
        var next = roles.Next;
        bond(["--sl-next-display"], next, "order: 3 !important;");
        bond(["--sl-next-display"], next, "display: var(--sl-next-display) !important;");
        bond(["--sl-next-size"], next, $"font-size: calc({size} * var(--sl-next-size)) !important;");
        bond(["--sl-next-color"], next, "color: var(--sl-next-color) !important;");
        bond(["--sl-next-rule", "--sl-next-color"], next,
             "border-top: var(--sl-next-rule, 0) solid var(--sl-next-color, #7f8fa6) !important;");
        if (roles.NextForeign.Length > 0)
        {
            // Чужому блоку — лише колір і риска: кегль автор добирає сам.
            bond(["--sl-next-color"], roles.NextForeign, "color: var(--sl-next-color) !important;");
            bond(["--sl-next-rule", "--sl-next-color"], roles.NextForeign,
                 "border-top: var(--sl-next-rule, 0) solid var(--sl-next-color, #7f8fa6) !important;");
        }

        // Номери віршів
        var number = roles.Number;
        bond(["--sl-num-display"], number, "display: var(--sl-num-display) !important;");
        bond(["--sl-num-size"], number, "font-size: calc(1em * var(--sl-num-size)) !important;");
        bond(["--sl-num-color"], number, "color: var(--sl-num-color) !important;");
        bond(["--sl-num-display", "--sl-num-size"], number, "vertical-align: super !important;");
        return bonds;
    }

    /// Правила, які прикладають значення до ролей. `only` — ті змінні, що й справді
    /// записані в сторінці; усе інше не пишеться зовсім. `null` — писати все.
    public static string BindingCSS(RoleSelectors? roles = null, IReadOnlySet<string>? only = null)
    {
        var order = new List<string>();
        var rules = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var bond in Bonds(roles ?? RoleSelectors.Standard))
        {
            if (only != null && !bond.Names.Any(only.Contains)) continue;
            if (!rules.ContainsKey(bond.Selector)) { order.Add(bond.Selector); rules[bond.Selector] = new List<string>(); }
            rules[bond.Selector].Add(bond.Declaration);
        }
        if (order.Count == 0) return OurWords.T("/* Ничего не правили — страница осталась собой. */");
        return string.Join("\n", order.Select(selector => selector + " {\n  " + string.Join("\n  ", rules[selector]) + "\n}"));
    }

    // ── Блоки цілком ──────────────────────────────────────────────────────────

    /// Блок значень — те, що переписується на кожен рух повзунка.
    public static string VarsElement(WebSlideSettings settings) =>
        $$"""
        <style {{VarsAttribute}}>
        /* {{VarsMarker}} v{{Version}} ────────────────────────────────────
           {{OurWords.T("Эти строки пишет редактор, когда двигают ползунки.")}}
           {{OurWords.T("Править руками можно, но пишите строго по одной «--имя: значение;».")}}
           {{OurWords.T("Всё прочее внутри блока редактор сотрёт при следующей правке.")}} */
        {{RootCSS(settings)}}
        /* {{VarsEndMarker}} */
        </style>
        """;

    /// Живі налаштування: сторінка слухає ті самі кадри, що й текст слайда, і
    /// застосовує надіслані змінні тут же — правка повзунка доходить до OBS без
    /// перезавантаження сторінки. Порт пишемо той самий, що й автор: сервер
    /// підміняє його на справжній при віддачі файла.
    public static string LiveElement() =>
        $$"""
        <script {{LiveAttribute}}>
        /* {{LiveMarker}} v{{Version}} ── {{OurWords.T("редактор переписывает блок целиком")}} ── */
        (function () {
          /* У вікні передпоказу з'єднання підмінено: там свій WebSocket,
             и он отдаёт слайд ТОМУ, кто подключился последним. Наш второй
             сокет перехватывал этот слайд у самой страницы, и предпросмотр
             оставался пустым. В предпросмотре живые настройки не нужны —
             редактор кладёт их напрямую, — поэтому там мы молчим. */
          /* Сторінка без сцени: позначаємо тіло, і правила сцени лягають на
             него. Старый WebKit не понимает :has(), а метку понимает любой. */
          try {
            if (!document.querySelector({{JsQuoted(RoleSelectors.StageNames)}})) {
              document.body.setAttribute("data-slovo-nostage", "");
            }
          } catch (e) {}
          if (window.slovoPreview) return;
          function connect() {
            var socket;
            try { socket = new WebSocket("ws://" + location.hostname + ":8100/ws"); }
            catch (e) { return; }
            socket.onmessage = function (event) {
              var data;
              try { data = JSON.parse(event.data); } catch (e) { return; }
              var vars = data && data.SlovoVars;
              if (!vars) return;
              for (var name in vars) {
                if (name.indexOf("--sl-") === 0) {
                  document.documentElement.style.setProperty(name, vars[name]);
                }
              }
            };
            socket.onclose = function () { setTimeout(connect, 2000); };
          }
          /* Підключаємося після самої сторінки: хай її з'єднання буде
             первым, а наше — вторым. */
          if (document.readyState === "complete") { setTimeout(connect, 300); }
          else { window.addEventListener("load", function () { setTimeout(connect, 300); }); }
        })();
        /* {{LiveEndMarker}} */
        </script>
        """;

    /// Рядок у лапках для JavaScript.
    static string JsQuoted(string text) => "\"" + text.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    /// Блок прив'язки — переписується лише при зміні версії програми, але ніколи
    /// при русі повзунка.
    public static string BindElement(RoleSelectors? roles = null, IReadOnlySet<string>? only = null) =>
        $$"""
        <style {{BindAttribute}}>
        /* {{BindMarker}} v{{Version}} ── {{OurWords.T("редактор переписывает блок целиком")}} ── */
        {{BindingCSS(roles, only)}}
        /* {{BindEndMarker}} */
        </style>
        """;

    // ── Придатність значення до запису ────────────────────────────────────────

    /// Що у значенні означає біду: крапка з комою і фігурна дужка обривають
    /// оголошення, кутові дужки закривають `<style>`, пара `/*` уміє закоментувати
    /// решту блоку. Усе інше — включно з двокрапкою, без якої не буває адреси
    /// `https://`, — дозволено.
    public static bool IsWritable(string value)
    {
        if (value.Length == 0 || SwiftText.CharacterCount(value) > 200) return false;
        foreach (var character in value)
        {
            if (SwiftText.IsNewline(character)) return false;
            if (";{}<>\\".Contains(character)) return false;
        }
        if (value.Contains("/*", StringComparison.Ordinal) || value.Contains("*/", StringComparison.Ordinal)) return false;
        return true;
    }

    /// Ім'я змінної: `--` і далі літери, цифри, дефіс, підкреслення (ASCII).
    public static bool IsVariableName(string name)
    {
        if (!name.StartsWith("--", StringComparison.Ordinal) || name.Length <= 2 || SwiftText.CharacterCount(name) > 80) return false;
        return name[2..].All(c => c < 128 && (char.IsLetterOrDigit(c) || c == '-' || c == '_'));
    }

    // ── Розбір ────────────────────────────────────────────────────────────────

    public static WebSlideDocument Parse(string html)
    {
        var ends = Newline(html);
        var head = WebText.Find(html, "</head>", ignoreCase: true) != null;
        var bindFound = Elements(html, BindAttribute).Count > 0;

        var varsElements = Elements(html, VarsAttribute);
        TextSpan? inner = null, whole = null;
        var extras = 0;
        string? damage = null;

        if (varsElements.Count > 0)
        {
            // Кілька блоків — працює останній: він перемагає за порядком у каскаді.
            var last = varsElements[^1];
            inner = last.Inner;
            whole = last.Element;
            extras = varsElements.Count - 1;
        }
        else if (WebText.Find(html, VarsAttribute) != null)
        {
            damage = OurWords.T("открывающая метка есть, а закрывающего </style> нет");
        }
        else if (MarkerRange(VarsMarkers, html, backwards: true) is { } markerStart)
        {
            // Людина могла винести блок зі <style> — шукаємо за самою міткою.
            if (MarkerRange(VarsEndMarkers, html, from: markerStart.End) is { } markerEnd)
            {
                inner = new TextSpan(markerStart.End, markerEnd.Start);
                whole = new TextSpan(LineStart(html, markerStart.Start), markerEnd.End);
            }
            else damage = OurWords.T("нет метки «%s»", VarsEndMarker);
        }

        if (damage != null)
            return new WebSlideDocument
            {
                Block = WebSlideBlock.Damaged(damage), Settings = new WebSlideSettings(), HasHead = head,
                HasBinding = bindFound, OutsideNames = Array.Empty<string>(), Newline = ends,
            };

        if (inner is not { } innerRange || whole is not { } wholeRange)
            return new WebSlideDocument
            {
                Block = WebSlideBlock.Missing, Settings = new WebSlideSettings(), HasHead = head,
                HasBinding = bindFound, OutsideNames = OutsideNamesIn(html, Array.Empty<TextSpan>()), Newline = ends,
            };

        var innerText = html[innerRange.Start..innerRange.End];
        var settings = Declarations(innerText);
        var version = ReadVersion(innerText) ?? Version;
        var skip = Elements(html, BindAttribute).Select(e => e.Element).Append(wholeRange).ToList();
        return new WebSlideDocument
        {
            Block = WebSlideBlock.Present(version, extras), Settings = settings, HasHead = head,
            HasBinding = bindFound, OutsideNames = OutsideNamesIn(html, skip), Newline = ends,
        };
    }

    /// Що сторінка задає сама — хоч би де оголошення в ній лежали. Брати замість
    /// них заводські — значить міняти вигляд сторінки в ту мить, коли людина
    /// всього лише зробила копію або торкнула перший повзунок.
    public static WebSlideSettings Declared(string html) => Declarations(html);

    /// Рядки-налаштування: визнається лише «--ім'я: значення;» цілим рядком.
    static WebSlideSettings Declarations(string text)
    {
        var settings = new WebSlideSettings();
        foreach (var line in WebText.Lines(text, omitEmpty: false))
        {
            var trimmed = line.TrimWhitespaces();
            if (!trimmed.StartsWith("--", StringComparison.Ordinal) || !trimmed.EndsWith(';')) continue;
            var body = trimmed[..^1];
            var colon = body.IndexOf(':');
            if (colon < 0) continue;
            var name = body[..colon].TrimWhitespaces();
            var value = body[(colon + 1)..].TrimWhitespaces();
            if (!IsVariableName(name) || !IsWritable(value)) continue;
            settings.Set(name, value);
        }
        return settings;
    }

    static int? ReadVersion(string text)
    {
        if (MarkerRange(VarsMarkers, text) is not { } marker) return null;
        var index = marker.End;
        while (index < text.Length && text[index] == ' ') index++;
        if (index >= text.Length || text[index] != 'v') return null;
        index++;
        var start = index;
        while (index < text.Length && SwiftText.IsNumber(text[index])) index++;
        return index == start ? null : SwiftText.ParseInt(text[start..index]);
    }

    /// Наші змінні, знайдені поза блоком: людина правила файл руками.
    static IReadOnlyList<string> OutsideNamesIn(string html, IReadOnlyList<TextSpan> skipping)
    {
        var found = new List<string>();
        var from = 0;
        while (WebText.Find(html, "--sl-", from) is { } hit)
        {
            from = hit.End;
            if (skipping.Any(range => range.Contains(hit.Start))) continue;
            // `var(--sl-…)` у блоці прив'язки — не правка, а його робота.
            var end = hit.End;
            while (end < html.Length && html[end] < 128 && (char.IsLetterOrDigit(html[end]) || html[end] is '-' or '_')) end++;
            var after = end;
            while (after < html.Length && html[after] == ' ') after++;
            if (after >= html.Length || html[after] != ':') continue;
            var name = "--sl-" + html[hit.End..end];
            if (!found.Contains(name)) found.Add(name);
        }
        return found;
    }

    // ── Запис ─────────────────────────────────────────────────────────────────

    /// Записати налаштування в сторінку. Замінюється рівно відрізок між мітками;
    /// усе за його межами навіть не читається — файл збирається як «початок +
    /// новий блок + кінець».
    public static WebSlideWriteOutcome Write(string html, WebSlideSettings settings, RoleSelectors? roles = null)
    {
        roles ??= RoleSelectors.Standard;
        foreach (var (name, value) in settings.WritingOrder)
        {
            if (IsWritable(value)) continue;
            var title = Parameter(name)?.Title ?? name;
            return WebSlideWriteOutcome.Refused(OurWords.T("Значение «%s» записать нельзя: в нём есть знак, "
                                                           + "который оборвал бы правило и сломал страницу.", title));
        }

        var document = Parse(html);
        if (document.Block.Kind == WebSlideBlock.Kinds.Damaged)
            return WebSlideWriteOutcome.Refused(OurWords.T("Блок настроек повреждён (%s). Нажмите «Переписать блок заново», если готовы потерять его нынешнее содержимое.", document.Block.Reason));

        var ends = document.Newline;
        var result = html;
        var only = new HashSet<string>(settings.Names, StringComparer.Ordinal);

        // Кожен блок шукається заново за вже зміненим рядком: діапазони, отримані до
        // правки, після першої ж заміни вказують не туди.
        if (Elements(result, BindAttribute) is { Count: > 0 } binds)
        {
            var bind = binds[^1];
            var indent = Indentation(result, bind.Element.Start);
            result = Replace(result, bind.Element, Reindent(BindElement(roles, only), indent, ends));
        }

        // Зайві копії живого блоку прибираємо з кінця: їх міг наплодити попередній випуск.
        while (Elements(result, LiveAttribute, "script") is { Count: > 1 } lives)
            result = Replace(result, lives[0].Element, "");
        if (Elements(result, LiveAttribute, "script") is { Count: > 0 } live)
        {
            var element = live[^1].Element;
            var indent = Indentation(result, element.Start);
            result = Replace(result, element, Reindent(LiveElement(), indent, ends));
        }
        else if (Elements(result, BindAttribute) is { Count: > 0 } binds2)
        {
            var bind = binds2[^1];
            var indent = Indentation(result, bind.Element.Start);
            result = result.Insert(bind.Element.End, ends + indent + Reindent(LiveElement(), indent, ends));
        }

        if (Elements(result, VarsAttribute) is { Count: > 0 } varsList)
        {
            var vars = varsList[^1];
            var indent = Indentation(result, vars.Element.Start);
            result = Replace(result, vars.Element, Reindent(VarsElement(settings), indent, ends));
            if (Elements(result, BindAttribute).Count == 0 && Elements(result, VarsAttribute) is { Count: > 0 } again)
            {
                var text = ends + indent + Reindent(BindElement(roles, only), indent, ends)
                           + ends + indent + Reindent(LiveElement(), indent, ends);
                result = result.Insert(again[^1].Element.End, text);
            }
            return WebSlideWriteOutcome.Written(result);
        }

        // Блоку немає — заводимо обидва перед </head>, нічого не чіпаючи.
        if (WebText.Find(result, "</head>", ignoreCase: true) is not { } headEnd)
            return WebSlideWriteOutcome.Refused(OurWords.T("Это не целая страница: в ней нет </head>, вставлять настройки некуда."));
        var point = LineStart(result, headEnd.Start);
        var headIndent = Indentation(result, headEnd.Start);
        var inserted = headIndent + Reindent(VarsElement(settings), headIndent, ends) + ends
                       + headIndent + Reindent(BindElement(roles, only), headIndent, ends) + ends
                       + headIndent + Reindent(LiveElement(), headIndent, ends) + ends;
        return WebSlideWriteOutcome.Written(result.Insert(point, inserted));
    }

    static string Replace(string text, TextSpan range, string with) => text[..range.Start] + with + text[range.End..];

    /// Переписати пошкоджений блок заново — лише по кнопці. Замінюється від
    /// відкривального тега до найближчого `</style>`; немає його — до `</head>` або
    /// `<body`: далі вже розмітка, і вирізати її не можна.
    public static WebSlideWriteOutcome Repair(string html, WebSlideSettings settings, RoleSelectors? roles = null)
    {
        var start = WebText.Find(html, VarsAttribute) ?? MarkerRange(VarsMarkers, html);
        if (start is not { } marker) return Write(html, settings, roles);
        if (WebText.Find(html, "<style", 0, marker.Start, ignoreCase: true, backwards: true) is not { } open)
            return WebSlideWriteOutcome.Refused(OurWords.T("Метка настроек лежит вне <style> — перепишите блок вручную."));

        TextSpan? cut = null;
        if (WebText.Find(html, StyleClose, marker.End, ignoreCase: true) is { } close)
            cut = new TextSpan(open.Start, close.End);
        else
        {
            var stops = new[] { WebText.Find(html, "</head>", marker.End, ignoreCase: true),
                                WebText.Find(html, "<body", marker.End, ignoreCase: true) }
                .Where(stop => stop != null).Select(stop => stop!.Value).ToList();
            if (stops.Count > 0) cut = new TextSpan(open.Start, stops.Min(stop => stop.Start));
        }
        if (cut is not { } range)
            return WebSlideWriteOutcome.Refused(OurWords.T("Блок настроек не закрыт, а конца головы страницы в файле нет — вырезать наугад нельзя."));

        var ends = Newline(html);
        var indent = Indentation(html, open.Start);
        var result = Replace(html, range, Reindent(VarsElement(settings), indent, ends) + ends);
        return Write(result, settings, roles);
    }

    /// Прибрати наші блоки — тим самим слідом, яким вони вставлялися. Сторінка
    /// автора після запису і зняття блоків зобов'язана збігтися з вихідною побайтно.
    public static string StripBlocks(string html)
    {
        var result = html;
        foreach (var (attribute, tag) in new[] { (BindAttribute, "style"), (VarsAttribute, "style"), (LiveAttribute, "script") })
        {
            while (Elements(result, attribute, tag) is { Count: > 0 } found)
            {
                var element = found[^1];
                var from = element.Element.Start;
                var to = element.Element.End;
                var start = LineStart(result, from);
                if (result[start..from].All(c => c is ' ' or '\t')) from = start;
                to += WebText.NewlineLength(result, to);
                result = result[..from] + result[to..];
            }
        }
        return result;
    }

    /// Розмітка без значень — за нею передпоказ вирішує, перезавантажуватися чи
    /// обійтися підстановкою змінних.
    public static string Structure(string html)
    {
        var places = Elements(html, VarsAttribute).Select(e => e.Inner).ToList();
        var result = html;
        for (var i = places.Count - 1; i >= 0; i--)
        {
            var place = places[i];
            if (place.End > place.Start) result = result[..place.Start] + result[place.End..];
        }
        return result;
    }

    // ── Дрібна робота з рядком ────────────────────────────────────────────────

    /// Перенос рядка цього файла: у сторінок автора CRLF, у наших LF.
    public static string Newline(string text)
    {
        var crlf = 0;
        var lf = 0;
        for (var index = 0; index < text.Length; index++)
        {
            var length = WebText.NewlineLength(text, index);
            if (length == 0) continue;
            if (length == 2) { crlf++; index++; } else lf++;
        }
        return crlf > lf ? "\r\n" : "\n";
    }

    static int LineStart(string text, int index)
    {
        var current = index;
        while (current > 0)
        {
            if (SwiftText.IsNewline(text[current - 1])) return current;
            current--;
        }
        return 0;
    }

    static string Indentation(string text, int index)
    {
        var start = LineStart(text, index);
        var prefix = text[start..index];
        return prefix.All(c => c is ' ' or '\t') ? prefix : "";
    }

    /// Блок написано з переносами LF і без відступу — приводимо до файла. Перший
    /// рядок відступу не отримує: він стає туди, де відступ уже є.
    static string Reindent(string block, string indent, string ends)
    {
        var lines = WebText.Lines(block, omitEmpty: false);
        return string.Join(ends, lines.Select((line, offset) => offset == 0 || line.Length == 0 ? line : indent + line));
    }

    internal readonly record struct Found(TextSpan Element, TextSpan Inner);

    /// Наші блоки в сторінці: `<tag …атрибут…>…</tag>` по порядку.
    internal static List<Found> Elements(string html, string attribute, string tag = "style")
    {
        var opening = "<" + tag;
        var closing = "</" + tag + ">";
        var result = new List<Found>();
        var from = 0;
        while (WebText.Find(html, attribute, from, ignoreCase: true) is { } hit)
        {
            from = hit.End;
            if (WebText.Find(html, opening, 0, hit.Start, ignoreCase: true, backwards: true) is not { } open) continue;
            // Між початком тега і атрибутом не має бути кінця тега.
            if (WebText.Find(html, closing, open.End, hit.Start, ignoreCase: true) != null) continue;
            if (WebText.Find(html, ">", hit.End) is not { } close) continue;
            // Від атрибута до кінця тега не має починатися нового тега.
            if (close.Start > hit.End && WebText.Find(html, "<", hit.End, close.Start) != null) continue;
            if (WebText.Find(html, closing, close.End, ignoreCase: true) is not { } end) continue;
            result.Add(new Found(new TextSpan(open.Start, end.End), new TextSpan(close.End, end.Start)));
            from = end.End;
        }
        return result;
    }

    // ── Розбір значень ────────────────────────────────────────────────────────

    internal static bool IsHexColor(string value)
    {
        if (!value.StartsWith('#')) return false;
        var digits = value[1..];
        if (digits.Length is not (3 or 4 or 6 or 8)) return false;
        return digits.All(Uri.IsHexDigit);
    }

    internal static bool IsColorTriple(string value)
    {
        var parts = value.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length != 3) return false;
        return parts.All(part => SwiftText.ParseDouble(part) is { } number && number >= 0 && number <= 255);
    }

    internal static double? Number(string value, string unit)
    {
        if (unit.Length == 0) return SwiftText.ParseDouble(value);
        if (!value.EndsWith(unit, StringComparison.Ordinal)) return null;
        return SwiftText.ParseDouble(value[..^unit.Length]);
    }

    /// Число в текст без хвостових нулів.
    internal static string Digits(double value)
    {
        if (value == Math.Round(value, MidpointRounding.AwayFromZero) && Math.Abs(value) < 1e9)
            return ((long)Math.Round(value, MidpointRounding.AwayFromZero)).ToString(CultureInfo.InvariantCulture);
        return WebText.G(value);
    }
}
