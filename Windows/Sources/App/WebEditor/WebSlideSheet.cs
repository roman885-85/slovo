// =============================================================================
//  WebSlideSheet.cs — оформлення однієї відкритої сторінки (з Views/WebEditor/WebSlideSheet.swift)
// =============================================================================
//  Головне правило редактора: панель ніколи не зберігає значень. Вона щоразу
//  читає їх з тексту сторінки, а повзунок пише рівно один рядок назад у цей
//  самий текст. Правка руками і правка повзунком не можуть затерти одна одну:
//  у них один і той самий вихідний текст. У заготовки при записі міняється лише
//  відрізок між «двокрапкою» і «крапкою з комою» того єдиного рядка, що називає
//  потрібну змінну.
// =============================================================================

using Avalonia;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebSlideSheet
{
    /// Яким способом сторінка зберігає оформлення.
    public enum Dialect
    {
        /// Наша заготовка: власний блок «Налаштування сторінки».
        Template,
        /// Будь-яка інша сторінка: блоки `Слово: налаштування` і `Слово: прив'язка`.
        Parameters,
    }

    /// У якому стані блок налаштувань.
    public sealed record Block(Block.Kinds Kind, string Reason = "")
    {
        public enum Kinds { Ready, Missing, Locked }
        public static readonly Block Ready = new(Kinds.Ready);
        /// Блоку немає, але його можна завести.
        public static readonly Block Missing = new(Kinds.Missing);
        /// Блок не можна чіпати: пошкоджений або зроблений новішою версією.
        public static Block Locked(string reason) => new(Kinds.Locked, reason);
    }

    public Dialect Kind { get; private init; }
    public Block State { get; private init; } = Block.Ready;
    /// Ручки в тому порядку, в якому вони оголошені в сторінці.
    public IReadOnlyList<WebSlideKnob> Knobs { get; private init; } = Array.Empty<WebSlideKnob>();
    /// Значення для показу: своє, а чого немає — за умовчанням.
    public IReadOnlyDictionary<string, string> Values { get; private init; } = new Dictionary<string, string>();
    /// Що записано в самій сторінці, без домислених умовчань.
    public IReadOnlyDictionary<string, string> Stored { get; private init; } = new Dictionary<string, string>();
    /// Набір спільного каталогу — ним же і записується назад.
    public WebSlideSettings Settings { get; private init; } = new();
    /// Оголошення в блоці, яких немає в каталозі.
    public IReadOnlyList<string> Strangers { get; private init; } = Array.Empty<string>();
    public WebSlidePlacement Placement { get; private init; }
    /// Рядок, за яким передпоказ вирішує, чи перезавантажуватися.
    public string StructureKey { get; private init; } = "";
    public string? Note { get; private init; }
    /// Які місця сторінки в ній і правда є. У заготовок порожньо: там кожна ручка
    /// оголошена в самій сторінці.
    public IReadOnlySet<WebSlideParameter.Role> Roles { get; private init; } = new HashSet<WebSlideParameter.Role>();

    public bool CanAdjust => State.Kind == Block.Kinds.Ready;

    /// Ручка, якій у цій сторінці нема до чого прикластися. Не поломка й не привід
    /// ховати ручку: людина має бачити, що «Колір адреси» існує, — і розуміти, чому тут він нічого не дасть.
    public string? IdleReason(WebSlideKnob knob)
    {
        if (Kind != Dialect.Parameters) return null;
        if (WebSlideParameters.Parameter(knob.Name) is not { } parameter) return null;
        var role = parameter.PageRole;
        if (role == WebSlideParameter.Role.Script) return role.Missing();
        return Roles.Contains(role) ? null : role.Missing();
    }

    /// Чому ручка робить менше, ніж від неї чекають: «Розмір тексту» при увімкненому
    /// доборі — стеля, а не сам розмір.
    public string? LimitNote(WebSlideKnob knob)
    {
        if (knob.Name != "--sl-size") return null;
        var fit = (Values.TryGetValue("--sl-fit", out var raw) ? raw : "0").TrimWhitespaces().ToLowerInvariant();
        if (fit != "1" && fit != "true") return null;
        return OurWords.T("Сейчас размер подбирается под длину текста: это верхний предел, "
                          + "а не сам размер. Чтобы задавать размер самому, снимите «Подбирать размер под длину текста».");
    }

    /// Значення ручки так, як його показувати.
    public string Value(WebSlideKnob knob) => Values.TryGetValue(knob.Name, out var value) ? value : "";

    /// Чи задано значення так, що ручка його не розуміє.
    public bool IsHandWritten(WebSlideKnob knob) => Stored.TryGetValue(knob.Name, out var raw) && !knob.Understands(raw);

    // ── Розбір ────────────────────────────────────────────────────────────────

    public static WebSlideSheet Read(string html) =>
        TemplateRegion(html) is { } region ? ReadTemplate(html, region) : ReadParameters(html);

    /// Мітки блоку налаштувань заготовки: незмінні дужки, а не слова підпису
    /// (підпис перекладається); колишні російські слова — для сторінок, знятих до перекладу.
    public static readonly IReadOnlyList<string> TemplateStarts = [WebSlideParameters.VarsToken, "Настройки страницы"];
    public static readonly IReadOnlyList<string> TemplateEnds = [WebSlideParameters.VarsEndToken, "Конец настроек"];

    /// Відрізок між мітками — лише він і переписується.
    public static TextSpan? TemplateRegion(string html)
    {
        if (WebSlideParameters.MarkerRange(TemplateStarts, html) is not { } start) return null;
        if (WebSlideParameters.MarkerRange(TemplateEnds, html, from: start.End) is not { } end) return null;
        return new TextSpan(start.End, end.Start);
    }

    static WebSlideSheet ReadTemplate(string html, TextSpan region)
    {
        var declared = Declarations(html[region.Start..region.End]);
        var knobs = new List<WebSlideKnob>();
        var strangers = new List<string>();
        foreach (var (name, _) in declared)
        {
            if (WebSlideTemplates.ParameterFor(name) is { } parameter) knobs.Add(WebSlideKnob.From(parameter));
            else strangers.Add(name);
        }
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, value) in declared) values[name] = value;

        var notes = new List<string>();
        if (strangers.Count > 0) notes.Add(OurWords.T("своих переменных в блоке: ") + string.Join(", ", strangers));
        // Підказка — лише там, де блоків налаштувань ПРАВДА два.
        var markers = WebSlideParameters.VarsMarkers.Sum(marker => Count(html, marker));
        if (markers > 1) notes.Add(OurWords.T("в странице два блока настроек — ползунки правят только свой"));

        var names = declared.Select(pair => pair.Name).ToHashSet(StringComparer.Ordinal);
        return new WebSlideSheet
        {
            Kind = Dialect.Template,
            State = Block.Ready,
            Knobs = knobs,
            Values = values,
            Stored = values,
            Settings = new WebSlideSettings(declared.Select(pair => (pair.Name, pair.Value))),
            Strangers = strangers,
            Placement = new WebSlidePlacement(Horizontal: names.Contains("--sl-anchor-x") ? "--sl-anchor-x" : null,
                                              Vertical: names.Contains("--sl-anchor-y") ? "--sl-anchor-y" : null),
            StructureKey = html[..region.Start] + html[region.End..],
            Note = notes.Count == 0 ? null : string.Join("; ", notes),
            Roles = new HashSet<WebSlideParameter.Role>(),
        };
    }

    static int Count(string text, string needle)
    {
        var count = 0;
        for (var at = text.IndexOf(needle, StringComparison.Ordinal); at >= 0; at = text.IndexOf(needle, at + needle.Length, StringComparison.Ordinal)) count++;
        return count;
    }

    /// Рядки «--ім'я: значення;» по порядку (повтор імені — останнє значення на першому місці).
    static List<(string Name, string Value)> Declarations(string text)
    {
        var result = new List<(string Name, string Value)>();
        foreach (var line in WebText.Lines(text, omitEmpty: false))
        {
            var trimmed = line.TrimWhitespaces();
            if (!trimmed.StartsWith("--", StringComparison.Ordinal)) continue;
            var colon = trimmed.IndexOf(':');
            if (colon < 0) continue;
            var semicolon = trimmed.IndexOf(';', colon);
            if (semicolon < 0) continue;
            var name = trimmed[..colon].TrimWhitespaces();
            var value = trimmed[(colon + 1)..semicolon].TrimWhitespaces();
            if (!WebSlideParameters.IsVariableName(name) || value.Length == 0) continue;
            var already = result.FindIndex(pair => pair.Name == name);
            if (already >= 0) result[already] = (name, value); else result.Add((name, value));
        }
        return result;
    }

    static WebSlideSheet ReadParameters(string html)
    {
        var document = WebSlideParameters.Parse(html);
        // Блоку немає, а значення в сторінці все одно записані: показувати замість
        // них заводські нечесно. Спершу переводимо власне оформлення, потім кладемо
        // поверх явно оголошені нею змінні: явне точніше за переклад.
        var settings = document.Settings;
        if (document.Block.Kind == WebSlideBlock.Kinds.Missing)
        {
            var own = WebSlideParameters.Inferred(html);
            var explicitValues = WebSlideParameters.Declared(html);
            foreach (var name in explicitValues.Names) if (explicitValues[name] is { } value) own.Set(name, value);
            foreach (var name in settings.Names) if (settings[name] is { } value) own.Set(name, value);
            settings = own;
        }

        var knobs = WebSlideParameters.All.Where(parameter => parameter.ShowsInPanel).Select(WebSlideKnob.From).ToList();
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        var stored = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var parameter in WebSlideParameters.All)
        {
            values[parameter.Name] = settings.Value(parameter);
            if (settings[parameter.Name] is { } own) stored[parameter.Name] = own;
        }
        foreach (var name in settings.UnknownNames)
            if (settings[name] is { } own) { stored[name] = own; values[name] = own; }

        var block = document.Block.Kind switch
        {
            WebSlideBlock.Kinds.Damaged => Block.Locked(OurWords.T("блок настроек повреждён: %s", document.Block.Reason)),
            WebSlideBlock.Kinds.Missing => Block.Missing,
            _ => document.Block.Version > WebSlideParameters.Version
                ? Block.Locked(OurWords.T("страницу настраивала более новая версия программы"))
                : Block.Ready,
        };

        return new WebSlideSheet
        {
            Kind = Dialect.Parameters,
            State = block,
            Knobs = knobs,
            Values = values,
            Stored = stored,
            Settings = document.Settings,
            Strangers = document.Settings.UnknownNames,
            // Точку прив'язки даємо лише там, де наш блок прив'язки і правда працює.
            Placement = document.HasBinding ? new WebSlidePlacement(Anchor: "--sl-anchor", OffsetX: "--sl-offset-x", OffsetY: "--sl-offset-y") : WebSlidePlacement.None,
            StructureKey = WebSlideParameters.Structure(html),
            Note = document.Note,
            Roles = WebSlideParameters.RoleSelectors.Standard.Present(html),
        };
    }

    // ── Запис ─────────────────────────────────────────────────────────────────

    public sealed record Outcome(string? Html, string Reason)
    {
        public static Outcome Done(string html) => new(html, "");
        public static Outcome Refused(string reason) => new(null, reason);
    }

    /// Записати нові значення в сторінку: спершу перевіряємо всі значення, і лише
    /// потім чіпаємо рядок — половина записаної пачки була б сторінкою, якої не замовляли.
    public Outcome Writing(IReadOnlyList<(string Name, string Value)> changes, string html)
    {
        if (!CanAdjust)
            return Outcome.Refused(OurWords.T("Ползунки выключены: ") + (Note ?? OurWords.T("блок настроек не в порядке")) + ".");
        foreach (var (name, value) in changes)
        {
            if (WebSlideParameters.IsWritable(value)) continue;
            var title = Knobs.FirstOrDefault(knob => knob.Name == name)?.Title ?? name;
            return Outcome.Refused(OurWords.T("Значение «%s» записать нельзя: в нём есть знак, "
                                              + "который оборвал бы правило и сломал страницу.", title));
        }

        if (Kind == Dialect.Template)
        {
            var result = html;
            foreach (var (name, value) in changes)
            {
                if (WriteTemplate(result, name, value) is not { } next)
                    return Outcome.Refused(OurWords.T("В блоке настроек нет строки «%s», "
                                                      + "а дописать её некуда: блок повреждён.", name));
                result = next;
            }
            return Outcome.Done(result);
        }

        var settings = Settings.Copy();
        foreach (var (name, value) in changes)
        {
            if (WebSlideParameters.Parameter(name) is { } parameter) settings.Choose(parameter, value);
            else settings.Set(name, value);
        }
        var written = WebSlideParameters.Write(html, settings);
        return written.Html is { } text ? Outcome.Done(text) : Outcome.Refused(written.Reason);
    }

    /// Замінити значення однієї змінної в блоці заготовки: міняється рівно відрізок
    /// між двокрапкою і крапкою з комою; ні відступ, ні підпис у кінці рядка не чіпаються.
    public static string? WriteTemplate(string html, string name, string value)
    {
        if (TemplateRegion(html) is not { } region) return null;
        var search = region.Start;
        while (WebText.Find(html, name, search, region.End) is { } hit)
        {
            search = hit.End;
            // Ім'я має стояти на початку рядка й обриватися двокрапкою: інакше ми знайшли
            // «--sl-ref» усередині «--sl-ref-scale».
            var lineHeadOk = true;
            for (var i = hit.Start - 1; i >= region.Start; i--)
            {
                if (SwiftText.IsNewline(html[i])) break;
                if (html[i] is not (' ' or '\t')) { lineHeadOk = false; break; }
            }
            if (!lineHeadOk) continue;
            var cursor = hit.End;
            while (cursor < region.End && html[cursor] == ' ') cursor++;
            if (cursor >= region.End || html[cursor] != ':') continue;
            var valueStart = cursor + 1;
            var semicolon = html.IndexOf(';', valueStart, region.End - valueStart);
            if (semicolon < 0) continue;
            return html[..valueStart] + " " + value + html[semicolon..];
        }
        // Рядка немає — дописуємо перед закривальною дужкою правила.
        if (WebText.Find(html, "}", region.Start, region.End, backwards: true) is not { } brace) return null;
        return html[..brace.Start] + $"  {name}: {value};\n}}" + html[brace.End..];
    }

    // ── Завести блок налаштувань ──────────────────────────────────────────────

    /// Надіти на сторінку спільний блок налаштувань — починаючи з того, чим
    /// сторінка живе зараз (найкраще — відповідь браузера в `seed`).
    public static Outcome AddingParameters(string html, WebSlideSettings? seed = null)
    {
        var known = seed?.Copy() ?? WebSlideParameters.Inferred(html);
        var explicitValues = WebSlideParameters.Declared(html);
        foreach (var name in explicitValues.Names) if (explicitValues[name] is { } value) known.Set(name, value);
        var written = WebSlideParameters.Write(html, known.ApplyingDefaults());
        return written.Html is { } text ? Outcome.Done(text) : Outcome.Refused(written.Reason);
    }

    /// Переписати пошкоджений блок заново — лише по кнопці й лише з попередженням.
    public static Outcome Repairing(string html)
    {
        var document = WebSlideParameters.Parse(html);
        var settings = document.Settings.IsEmpty ? WebSlideParameters.Defaults : document.Settings;
        var written = WebSlideParameters.Repair(html, settings);
        return written.Html is { } text ? Outcome.Done(text) : Outcome.Refused(written.Reason);
    }

    // ── Перетягування ─────────────────────────────────────────────────────────

    /// Що записати, якщо блок відпустили в цій точці кадру; порожньо — тягнути нічим.
    public List<(string Name, string Value)> Placing(Point point)
    {
        var changes = new List<(string Name, string Value)>();
        if (!Placement.CanDrag) return changes;
        var drop = WebSlidePlacement.Drop(point);
        if (Placement.Horizontal is { } horizontal && Placement.Vertical is { } vertical)
        {
            changes.Add((horizontal, WebSlidePlacement.FlexValues[drop.Column]));
            changes.Add((vertical, WebSlidePlacement.FlexValues[drop.Row]));
        }
        if (Placement.Anchor is { } anchor) changes.Add((anchor, WebSlidePlacement.AnchorValue(drop.Column, drop.Row)));
        if (Placement.OffsetX is { } offsetX && Knobs.Any(knob => knob.Name == offsetX)) changes.Add((offsetX, WebSlideKnob.Digits(drop.OffsetX)));
        if (Placement.OffsetY is { } offsetY && Knobs.Any(knob => knob.Name == offsetY)) changes.Add((offsetY, WebSlideKnob.Digits(drop.OffsetY)));
        return changes;
    }

    /// Де блок стоїть зараз — від цієї точки рахується перетягування.
    public Point PlacementPoint
    {
        get
        {
            int column = 1, row = 1;
            if (Placement.Horizontal is { } horizontal && Placement.Vertical is { } vertical)
            {
                column = WebSlidePlacement.Column(Values.TryGetValue(horizontal, out var h) ? h : "center");
                row = WebSlidePlacement.Column(Values.TryGetValue(vertical, out var v) ? v : "center");
            }
            if (Placement.Anchor is { } anchor)
                (column, row) = WebSlidePlacement.Place(Values.TryGetValue(anchor, out var a) ? a : "center-center");
            var point = WebSlidePlacement.Fraction(column, row);
            var x = point.X;
            var y = point.Y;
            if (Placement.OffsetX is { } offsetX && Values.TryGetValue(offsetX, out var rawX) && SwiftText.ParseDouble(rawX) is { } dx) x += dx / 100;
            if (Placement.OffsetY is { } offsetY && Values.TryGetValue(offsetY, out var rawY) && SwiftText.ParseDouble(rawY) is { } dy) y += dy / 100;
            return new Point(x, y);
        }
    }
}
