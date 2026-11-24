// =============================================================================
//  LocalizeModel.cs — стан вікна «Переклад інтерфейсу» (7.1) і запис перекладів
// =============================================================================
//  За LocalizeTranslateModel.swift і InterfaceLanguageStore.swift Mac 1.3.9.
//  Зліва — тексти мовою оригіналу, справа — поля перекладу. «Мовою оригіналу»
//  служить російський переклад автора (найповніший файл у теці Language), без
//  нього — англійський, далі перший-ліпший. Файли Language/*.lng старої програми
//  лише читаються: змінений переклад іде у свою теку (Language у теці даних
//  «Слова»), і програма читає обидві — свій файл витісняє однойменний чужий.
// =============================================================================

using System.Text;
using Slovo.Core;

namespace Slovo.App;

/// Сховище перекладів інтерфейсу (InterfaceLanguageStore на Mac).
public static class InterfaceLanguageStore
{
    /// Свої переклади — тека даних «Слова», а не теки старої програми.
    public static string UserDirectory => Path.Combine(DataHome.Folder, "Language");

    /// Тека перекладів оригіналу: `Language` поруч із текою модулів.
    public static string Originals(AppState state) =>
        Path.Combine(Path.GetDirectoryName(state.ModulesFolder.TrimEnd(Path.DirectorySeparatorChar, '/')) ?? DataHome.Folder, "Language");

    /// Усі переклади: оригінальні й свої (свій файл із тим самим кодом витісняє оригінал).
    public static List<LanguageFile> Languages(string originals)
    {
        var byCode = new Dictionary<string, LanguageFile>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in Read(originals)) byCode[file.Code.ToLowerInvariant()] = file;
        foreach (var file in Read(UserDirectory)) byCode[file.Code.ToLowerInvariant()] = file;
        var list = byCode.Values.ToList();
        list.Sort((a, b) => SwiftText.LocalizedStandardCompare(a.DisplayName, b.DisplayName));
        return list;
    }

    public static LanguageFile? Language(string code, string originals) =>
        Languages(originals).FirstOrDefault(l => string.Equals(l.Code, code, StringComparison.OrdinalIgnoreCase));

    /// Переклад, який правила людина, — лише такий можна видалити.
    public static bool IsUserOwned(string code) => File.Exists(FilePath(code));

    public static string FilePath(string code) => Path.Combine(UserDirectory, code + ".lng");

    static IEnumerable<LanguageFile> Read(string directory)
    {
        if (!Directory.Exists(directory)) yield break;
        foreach (var path in Directory.EnumerateFiles(directory))
        {
            if (!string.Equals(Path.GetExtension(path), ".lng", StringComparison.OrdinalIgnoreCase)) continue;
            if (Path.GetFileName(path).StartsWith('.')) continue;
            LanguageFile? file = null;
            try { file = new LanguageFile(path); } catch { /* битий файл — пропускаємо */ }
            if (file != null) yield return file;
        }
    }

    /// Сказати програмі, що набір перекладів змінився: перечитати мови й підписи.
    public static void AnnounceChange()
    {
        if (Slovo.App.Languages.DataRoot is { } root) Slovo.App.Languages.Load(root);
        Signals.Shared.Send(Signals.Kind.Language);
    }

    /// Пара «підпис + підказка» в правці; порожня підказка — її немає.
    public readonly record struct TextPair
    {
        public string Caption { get; }
        public string? Hint { get; }
        public TextPair(string caption, string? hint = null)
        {
            Caption = caption;
            Hint = string.IsNullOrEmpty(hint) ? null : hint;
        }
        public TextPair(LanguageFile.Entry entry) : this(entry.Caption, entry.Hint) { }
    }

    /// Чернетка: форма → ключ → пара.
    public sealed class Draft : Dictionary<string, Dictionary<string, TextPair>>
    {
        public Draft() : base(StringComparer.Ordinal) { }
        public Dictionary<string, TextPair> Form(string form)
        {
            if (!TryGetValue(form, out var entries)) this[form] = entries = new Dictionary<string, TextPair>(StringComparer.Ordinal);
            return entries;
        }
        public TextPair? Entry(string form, string key) =>
            TryGetValue(form, out var entries) && entries.TryGetValue(key, out var pair) ? pair : null;
    }

    /// Прочитаний переклад цілком — як чернетка.
    public static Draft DraftOf(LanguageFile file)
    {
        var draft = new Draft();
        foreach (var (form, entries) in file.Forms)
        {
            if (form == "_info_") continue;
            var target = draft.Form(form);
            foreach (var (key, entry) in entries) target[key] = new TextPair(entry);
        }
        return draft;
    }

    public static void Write(Draft draft, string code, string displayName)
    {
        Directory.CreateDirectory(UserDirectory);
        var text = Serialize(draft, displayName);
        // BOM і UTF-8 — як у файлах оригіналу: їх читає й сама стара програма.
        var bytes = new List<byte> { 0xEF, 0xBB, 0xBF };
        bytes.AddRange(new UTF8Encoding(false).GetBytes(text));
        var target = FilePath(code);
        var temporary = target + ".tmp";
        File.WriteAllBytes(temporary, bytes.ToArray());
        File.Move(temporary, target, overwrite: true);
    }

    public static void Delete(string code) => File.Delete(FilePath(code));

    /// Збирання `.lng`: секція `[_info_]` з назвою мови, далі по секції на форму;
    /// рядки за іменами — як у файлах автора. Рядки розділяє CRLF.
    public static string Serialize(Draft draft, string displayName)
    {
        var lines = new List<string> { "[_info_]", "lang=" + Escape(displayName), "" };
        foreach (var form in draft.Keys.OrderBy(k => k, StringComparer.Ordinal))
        {
            if (form == "_info_" || form.Length == 0) continue;
            var entries = draft[form];
            if (entries.Count == 0) continue;
            lines.Add("[" + form + "]");
            foreach (var key in entries.Keys.OrderBy(k => k, StringComparer.Ordinal)) lines.Add(key + "=" + Value(entries[key]));
            lines.Add("");
        }
        return string.Join("\r\n", lines);
    }

    /// «підпис,підказка». Обидві частини завжди в `~…~`: так не губляться крайові
    /// пробіли й коми всередині тексту.
    static string Value(TextPair entry)
    {
        var caption = entry.Caption.Length == 0 ? "" : "~" + Escape(entry.Caption) + "~";
        if (string.IsNullOrEmpty(entry.Hint)) return caption;
        return caption + ",~" + Escape(entry.Hint) + "~";
    }

    static string Escape(string text) => text
        // `&` у форматі — акселератор Windows, сам знак пишеться подвоєним.
        .Replace("&", "&&")
        // Тильда — роздільник, а екранувати її формат не дає.
        .Replace("~", "-")
        // Перенос рядка у файлах автора записано двома знаками «\n».
        .Replace("\r\n", "\\n")
        .Replace("\n", "\\n");
}

/// Стан вікна «Переклад інтерфейсу» (LocalizeTranslateModel на Mac).
public sealed class LocalizeModel
{
    /// Вкладки: перша — видимі елементи форми, решта — тексти повідомлень.
    public enum TextTab { Objects, Texts, Errors }

    /// Рядок списку; `IsDone` фарбує його зеленим або червоним.
    public sealed record Row(string Key, string Type, string OriginalCaption, string OriginalHint, string Caption, string Hint, bool IsDone);

    /// Колонки списку, якими шукають парами кнопок.
    public enum Column { Object, Type, OriginalCaption, OriginalHint, Caption, Hint }

    /// Чому переклад видалити не можна.
    public enum DeleteRefusal { InUse, NotOurs }

    public readonly string Originals;
    public LanguageFile? Reference { get; }
    public List<LanguageFile> AvailableLanguages { get; private set; } = new();
    public string DisplayName = "";
    public bool OnlyUntranslated;
    public string? SelectedKey;
    public bool IsDirty { get; private set; }
    /// Мова, вибрана в головному вікні зараз: від неї залежить відмова видалення.
    public string ActiveLanguageCode = "";

    InterfaceLanguageStore.Draft _draft = new();
    string _languageCode = "";
    string _formName = "MainForm";
    TextTab _tab = TextTab.Objects;

    public LocalizeModel(string originals, string startingCode)
    {
        Originals = originals;
        Reference = InterfaceLanguageStore.Language("ru", originals)
                 ?? InterfaceLanguageStore.Language("en", originals)
                 ?? InterfaceLanguageStore.Languages(originals).FirstOrDefault();
        ReloadLanguages();
        LanguageCode = startingCode;
        LoadDraft();
    }

    public string LanguageCode
    {
        get => _languageCode;
        set { if (value == _languageCode) return; _languageCode = value; LoadDraft(); }
    }

    public string FormName { get => _formName; set { _formName = value; SelectedKey = null; } }
    public TextTab Tab { get => _tab; set { _tab = value; SelectedKey = null; } }

    public void ReloadLanguages() => AvailableLanguages = InterfaceLanguageStore.Languages(Originals);

    /// Назва мови, взятої за оригінал.
    public string ReferenceName => Reference?.DisplayName ?? "—";

    // ── Списки ──────────────────────────────────────────────────────────────

    /// Вікна (форми) для перекладу — технічні імена, як в оригіналі, і наша секція.
    public List<string> FormNames
    {
        get
        {
            var names = new HashSet<string>(StringComparer.Ordinal);
            if (Reference != null) names.UnionWith(Reference.Forms.Keys);
            names.UnionWith(_draft.Keys);
            names.Remove("_info_");
            names.Remove("");
            // Наші підписи — окремим «вікном»: в автора такої форми немає.
            names.Add(OurWords.SectionName);
            return names.OrderBy(n => n, StringComparer.Ordinal).ToList();
        }
    }

    public bool IsOurSection => FormName == OurWords.SectionName;

    HashSet<string> KeysOfForm()
    {
        var keys = new HashSet<string>(StringComparer.Ordinal);
        if (Reference != null && Reference.Forms.TryGetValue(FormName, out var source)) keys.UnionWith(source.Keys);
        if (_draft.TryGetValue(FormName, out var mine)) keys.UnionWith(mine.Keys);
        return keys;
    }

    /// Усі ключі вибраного вікна — по всіх трьох вкладках: кнопки «Очистити ВСЕ» й
    /// «Скопіювати ВСЕ» в оригіналі — для вікна, а не вкладки.
    List<string> AllKeysOfForm()
    {
        var keys = KeysOfForm();
        if (IsOurSection) keys.UnionWith(OurWords.RussianKeys);
        return keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
    }

    List<string> KeysForCurrentTab()
    {
        var keys = KeysOfForm();
        // Наші підписи всі — «об'єкти»: ключ і є сам рядок.
        if (IsOurSection)
        {
            if (Tab != TextTab.Objects) return new List<string>();
            keys.UnionWith(OurWords.RussianKeys);
            return keys.OrderBy(k => k, StringComparer.Ordinal).ToList();
        }
        var filtered = keys.Where(key => Tab switch
        {
            TextTab.Objects => !key.StartsWith("TextMessages", StringComparison.Ordinal) && !key.StartsWith("ErrorMessages", StringComparison.Ordinal),
            TextTab.Texts => key.StartsWith("TextMessages", StringComparison.Ordinal),
            _ => key.StartsWith("ErrorMessages", StringComparison.Ordinal),
        });
        // Повідомлення нумеровані — за номером, інакше 10 стає між 1 і 2.
        return Tab == TextTab.Objects
            ? filtered.OrderBy(k => k, StringComparer.Ordinal).ToList()
            : filtered.OrderBy(Number).ThenBy(k => k, StringComparer.Ordinal).ToList();
    }

    static int Number(string key)
    {
        var digits = key.SkipWhile(c => !char.IsDigit(c)).ToArray();
        return int.TryParse(new string(digits), out var n) ? n : 0;
    }

    public List<Row> Rows()
    {
        var result = new List<Row>();
        if (IsOurSection)
        {
            // Оригінал — сам російський рядок; переклад — правка людини, а без неї
            // те, що вшито в словник для цієї мови.
            var code = LanguageCode;
            foreach (var key in KeysForCurrentTab())
            {
                var mine = _draft.Entry(FormName, key);
                var shown = mine is { Caption.Length: > 0 } m ? m.Caption : OurWords.BuiltIn(key, code) ?? "";
                var row = new Row(key, Captions.T("Подпись «Слова»"), key, "", shown, "", shown.Length > 0);
                if (OnlyUntranslated && row.IsDone) continue;
                result.Add(row);
            }
            return result;
        }
        foreach (var key in KeysForCurrentTab())
        {
            var source = Reference?.EntryFor(key, FormName);
            var mine = _draft.Entry(FormName, key);
            var row = new Row(key, ObjectType(key), source?.Caption ?? "", source?.Hint ?? "",
                              mine?.Caption ?? "", mine?.Hint ?? "", IsDone(source, mine));
            if (OnlyUntranslated && row.IsDone) continue;
            result.Add(row);
        }
        return result;
    }

    public Row? SelectedRow(IReadOnlyList<Row> rows) => rows.FirstOrDefault(r => r.Key == SelectedKey);

    /// «Зелений рядок — переклад завершено, червоний — ні»: перекладено все, що є в оригіналі.
    static bool IsDone(LanguageFile.Entry? source, InterfaceLanguageStore.TextPair? mine)
    {
        var needsCaption = !string.IsNullOrEmpty(source?.Caption);
        var needsHint = !string.IsNullOrEmpty(source?.Hint);
        if (!needsCaption && !needsHint) return true;
        if (needsCaption && string.IsNullOrEmpty(mine?.Caption)) return false;
        if (needsHint && string.IsNullOrEmpty(mine?.Hint)) return false;
        return true;
    }

    /// Колонка «Тип»: класу контрола в нас немає, але імена ключів в автора
    /// витримані в одній системі — тип відновлюється за префіксом.
    public static string ObjectType(string key)
    {
        bool Starts(string prefix) => key.StartsWith(prefix, StringComparison.Ordinal);
        bool Ends(string suffix) => key.EndsWith(suffix, StringComparison.Ordinal);
        if (key.Contains("->Column", StringComparison.Ordinal)) return Captions.T("Колонка списка");
        if (key.Contains("->Item", StringComparison.Ordinal)) return Captions.T("Пункт списка");
        if (Ends("Form") || Ends("Frame") || Ends("Box")) return Captions.T("Окно");
        if (Starts("TextMessages")) return Captions.T("Сообщение");
        if (Starts("ErrorMessages")) return Captions.T("Сообщение об ошибке");
        if (Starts("MI")) return Captions.T("Пункт меню");
        if (Starts("N") && key.Length > 1 && key.Skip(1).All(char.IsNumber)) return Captions.T("Пункт меню");
        if (Starts("GroupBox") || Starts("GB")) return Captions.T("Группа");
        if (Starts("TabSheet") || Starts("TS")) return Captions.T("Вкладка");
        if (Starts("RG")) return Captions.T("Переключатели");
        if (Starts("CB")) return Captions.T("Флажок / список");
        if (Starts("Label") || Starts("LV")) return Captions.T("Надпись");
        if (Starts("Panel")) return Captions.T("Панель");
        if (Starts("PngSpeedButton") || Starts("PngSB") || Starts("PSB") || Starts("JvgSB") || Starts("SB")
            || Starts("TB") || Starts("BB") || Starts("PBB")) return Captions.T("Кнопка");
        if (Starts("E") && key.Length > 1 && char.IsUpper(key[1])) return Captions.T("Поле ввода");
        if (Starts("L") && key.Length > 1 && char.IsUpper(key[1])) return Captions.T("Надпись");
        return Captions.T("Элемент");
    }

    // ── Правка ──────────────────────────────────────────────────────────────

    public void SetCaption(string text, string key) =>
        Put(new InterfaceLanguageStore.TextPair(text, _draft.Entry(FormName, key)?.Hint), key);

    public void SetHint(string text, string key) =>
        Put(new InterfaceLanguageStore.TextPair(_draft.Entry(FormName, key)?.Caption ?? "", text), key);

    void Put(InterfaceLanguageStore.TextPair entry, string key)
    {
        _draft.Form(FormName)[key] = entry;
        IsDirty = true;
    }

    /// Очистити переклад вибраного елемента.
    public void ClearSelected()
    {
        if (SelectedKey is not { } key) return;
        Put(new InterfaceLanguageStore.TextPair(""), key);
    }

    /// Скопіювати тексти оригіналу в поля перекладу.
    public void CopySelectedFromOriginal()
    {
        if (SelectedKey is not { } key) return;
        if (IsOurSection) { Put(new InterfaceLanguageStore.TextPair(key), key); return; }
        if (Reference?.EntryFor(key, FormName) is not { } source) return;
        Put(new InterfaceLanguageStore.TextPair(source), key);
    }

    /// Очистити ВСІ переклади вибраного вікна — по всьому вікну, не по вкладці.
    public void ClearForm()
    {
        var target = _draft.Form(FormName);
        foreach (var key in AllKeysOfForm()) target[key] = new InterfaceLanguageStore.TextPair("");
        IsDirty = true;
    }

    /// Скопіювати всі тексти мови оригіналу в поточний переклад — теж по всьому вікну.
    public void CopyFormFromOriginal()
    {
        var target = _draft.Form(FormName);
        foreach (var key in AllKeysOfForm())
        {
            if (IsOurSection) { target[key] = new InterfaceLanguageStore.TextPair(key); continue; }
            if (Reference?.EntryFor(key, FormName) is not { } source) continue;
            target[key] = new InterfaceLanguageStore.TextPair(source);
        }
        IsDirty = true;
    }

    // ── Пошук по колонках ───────────────────────────────────────────────────

    static string Value(Row row, Column column) => column switch
    {
        Column.Object => row.Key,
        Column.Type => row.Type,
        Column.OriginalCaption => row.OriginalCaption,
        Column.OriginalHint => row.OriginalHint,
        Column.Caption => row.Caption,
        _ => row.Hint,
    };

    /// «Шукати наступний / попередній»: найближчий рядок, у якого в цій колонці є
    /// непорожнє значення, інше за поточне. false — нічого не знайшлося (сигнал).
    public bool Step(Column column, bool forward)
    {
        var list = Rows();
        if (list.Count == 0) return false;
        var found = list.FindIndex(r => r.Key == SelectedKey);
        var start = found >= 0 ? found : forward ? -1 : list.Count;
        var current = start >= 0 && start < list.Count ? Value(list[start], column) : "";
        var order = forward ? Enumerable.Range(start + 1, Math.Max(0, list.Count - start - 1))
                            : Enumerable.Range(0, Math.Max(start, 0)).Reverse();
        foreach (var index in order)
        {
            var candidate = Value(list[index], column);
            if (candidate.Length == 0 || candidate == current) continue;
            SelectedKey = list[index].Key;
            return true;
        }
        return false;
    }

    // ── Файл ────────────────────────────────────────────────────────────────

    void LoadDraft()
    {
        if (LanguageCode.Length == 0) return;
        var file = InterfaceLanguageStore.Language(LanguageCode, Originals);
        _draft = file != null ? InterfaceLanguageStore.DraftOf(file) : new InterfaceLanguageStore.Draft();
        DisplayName = file?.DisplayName ?? LanguageCode;
        IsDirty = false;
        SelectedKey = null;
    }

    /// Зберегти переклад у свій файл `.lng`; помилку — віддати.
    public Exception? Save()
    {
        if (LanguageCode.Length == 0) return new InvalidOperationException("no language");
        try
        {
            InterfaceLanguageStore.Write(_draft, LanguageCode, DisplayName);
            IsDirty = false;
            ReloadLanguages();
            return null;
        }
        catch (Exception error) { return error; }
    }

    /// Додати новий переклад інтерфейсу.
    public void AddTranslation(string name, string code, bool copyOriginal)
    {
        var fresh = copyOriginal && Reference != null ? InterfaceLanguageStore.DraftOf(Reference) : new InterfaceLanguageStore.Draft();
        try { InterfaceLanguageStore.Write(fresh, code, name); } catch (Exception error) { Journal.Say($"переклад {code}: {error.Message}"); }
        ReloadLanguages();
        // Той самий код, що й був (переписали наново), — чернетку все одно перечитати.
        _languageCode = code;
        LoadDraft();
    }

    /// Чи можна видалити вибраний зараз переклад (нічого не міняє).
    public DeleteRefusal? Refusal()
    {
        if (ActiveLanguageCode.Length > 0 && string.Equals(LanguageCode, ActiveLanguageCode, StringComparison.OrdinalIgnoreCase))
            return DeleteRefusal.InUse;
        return InterfaceLanguageStore.IsUserOwned(LanguageCode) ? null : DeleteRefusal.NotOurs;
    }

    /// Видалити вибраний переклад.
    public DeleteRefusal? DeleteTranslation()
    {
        if (Refusal() is { } refusal) return refusal;
        try { InterfaceLanguageStore.Delete(LanguageCode); } catch (Exception error) { Journal.Say($"переклад {LanguageCode}: {error.Message}"); }
        ReloadLanguages();
        LanguageCode = AvailableLanguages.FirstOrDefault()?.Code ?? "";
        return null;
    }
}
