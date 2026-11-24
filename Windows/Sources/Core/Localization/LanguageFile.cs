// =============================================================================
//  LanguageFile.cs — файли перекладу інтерфейсу старої програми
//  (з Localization/LanguageFile.swift)
// =============================================================================

using System.Text;

namespace Slovo.Core;

/// Розбір файла перекладу інтерфейсу старої програми (`Language/*.lng`).
///
/// Формат: секція на форму, рядок на елемент керування.
///     N24=~&amp;Показать слайд~
///     BBOk=&amp;Ок,~Применить настройки~
///     CTSTuning->Item0=,~Настройки шрифтов~
/// Значення — це «підпис,підказка»; будь-яка з частин може бути порожньою і
/// може бути обгорнута в `~…~`, щоб зберегти крайові пробіли та коми.
/// `&amp;` перед літерою — акселератор Windows, тут він знімається (як на Mac).
public sealed class LanguageFile
{
    public readonly record struct Entry(string Caption, string? Hint);

    public string Code { get; }            // ru, uk, en…
    public string DisplayName { get; }     // «Русский», «Українська»
    public IReadOnlyDictionary<string, Dictionary<string, Entry>> Forms { get; }

    /// Читає файл; кидає виняток, якщо файла не прочитати (як `throws` у Swift).
    public LanguageFile(string path)
    {
        var data = File.ReadAllBytes(path);
        var declared = CodePage.IsValidUtf8(data) ? CodePage.Utf8 : null;
        var text = CodePage.Decode(data, declared);

        Code = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));
        var forms = new Dictionary<string, Dictionary<string, Entry>>(StringComparer.Ordinal);
        var current = "";

        foreach (var rawLine in text.SplitLines())
        {
            var line = rawLine.TrimWhitespaces();
            if (line.Length == 0 || line.StartsWith(';') || line.StartsWith("//", StringComparison.Ordinal)) continue;

            if (line.StartsWith('[') && line.EndsWith(']'))
            {
                current = line[1..^1];
                if (!forms.ContainsKey(current)) forms[current] = new Dictionary<string, Entry>(StringComparer.Ordinal);
                continue;
            }
            var eq = line.IndexOf('=');
            if (eq < 0) continue;
            var key = line[..eq].TrimWhitespaces();
            var parts = SplitValue(line[(eq + 1)..]);
            if (!forms.TryGetValue(current, out var form))
            {
                form = new Dictionary<string, Entry>(StringComparer.Ordinal);
                forms[current] = form;
            }
            form[key] = new Entry(parts.Caption, parts.Hint);
        }

        Forms = forms;
        DisplayName = forms.TryGetValue("_info_", out var info) && info.TryGetValue("lang", out var lang)
            ? lang.Caption
            : Code;
    }

    public Entry? EntryFor(string key, string form) =>
        Forms.TryGetValue(form, out var entries) && entries.TryGetValue(key, out var entry) ? entry : null;

    public string Caption(string key, string form, string fallback = "")
    {
        var text = EntryFor(key, form)?.Caption ?? fallback;
        return text.Length == 0 ? fallback : text;
    }

    public string? Hint(string key, string form) => EntryFor(key, form)?.Hint;

    // ── Розбір значення ─────────────────────────────────────────────────────

    /// Ділить «підпис,підказка», поважаючи обгортку `~…~`: усередині неї кома —
    /// частина тексту, а не роздільник.
    internal static (string Caption, string? Hint) SplitValue(string raw)
    {
        var fields = new List<string>();
        var buffer = new StringBuilder();
        var inTilde = false;

        foreach (var character in raw)
        {
            switch (character)
            {
                case '~':
                    inTilde = !inTilde;
                    break;
                case ',' when !inTilde:
                    fields.Add(buffer.ToString());
                    buffer.Clear();
                    break;
                default:
                    buffer.Append(character);
                    break;
            }
        }
        fields.Add(buffer.ToString());

        var caption = Clean(fields.Count > 0 ? fields[0] : "");
        var hint = fields.Count > 1 ? Clean(fields[1]) : "";
        return (caption, hint.Length == 0 ? null : hint);
    }

    private static string Clean(string text)
    {
        // Акселератори Windows: «&Файл» -> «Файл», «&&» -> «&».
        var output = new StringBuilder(text.Length);
        for (var index = 0; index < text.Length; index++)
        {
            var character = text[index];
            if (character != '&')
            {
                output.Append(character);
                continue;
            }
            if (index + 1 < text.Length)
            {
                index++;
                output.Append(text[index]);
            }
        }
        // Перенос рядка автор записує двома знаками — «Показать\\nслайд».
        // Без цієї заміни зворотна скісна з літерою «n» доїжджала до підказки.
        return output.ToString().Replace("\\n", "\n").TrimWhitespacesAndNewlines();
    }
}

/// Усі переклади інтерфейсу, що лежать у теці `Language`.
public sealed class LanguageCatalog
{
    public IReadOnlyList<LanguageFile> Languages { get; }

    public LanguageCatalog(string directory)
    {
        var files = SwiftPath.Contents(directory, skipsHidden: true);
        var languages = new List<LanguageFile>();
        foreach (var file in files)
        {
            if (!string.Equals(SwiftPath.Extension(file), "lng", StringComparison.OrdinalIgnoreCase)) continue;
            try { languages.Add(new LanguageFile(file)); }
            catch { /* try? — нечитаний файл просто пропускається */ }
        }
        languages.Sort((a, b) => SwiftText.LocalizedStandardCompare(a.DisplayName, b.DisplayName));
        Languages = languages;
    }

    public LanguageFile? Language(string code) =>
        Languages.FirstOrDefault(language => SwiftText.SameIgnoringCase(language.Code, code));
}
