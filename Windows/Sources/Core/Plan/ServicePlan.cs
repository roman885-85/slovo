// =============================================================================
//  ServicePlan.cs — план служіння, F2 (з Plan/ServicePlan.swift)
// =============================================================================
//  У Swift план — значення (struct) з `mutating`-методами; тут клас із
//  глибокою копією `Copy()`.
// =============================================================================

using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Slovo.Core;

/// План служіння (F2) — порядок того, що піде на екран: уривки і частини
/// пісень підряд, як їх розставив ведучий перед зібранням.
///
/// Формат зберігання свій: тека `Plans` у старій програмі порожня, розбирати нічого,
/// тому пишемо звичайний JSON, який читається і правиться в будь-якому редакторі.
///
///     {
///       "format": "slovo.plan",
///       "version": 1,
///       "title": "Воскресное служение",
///       "savedAt": "2026-08-23T09:15:00Z",
///       "items": [
///         { "type": "scripture", "title": "Ин 3:16-18",
///           "module": "RST", "book": 42, "chapter": 3, "verses": [16, 17, 18] },
///         { "type": "song", "title": "Великий Бог — Куплет 1",
///           "songBook": "Песнь возрождения.vbm", "song": 11, "part": 0 }
///       ]
///     }
///
/// Читання стійке до псування: незрозумілий пункт пропускається і рахується, а не
/// ронить весь план. Перед служінням важливіше відкрити дев'ять пунктів із десяти,
/// ніж отримати повідомлення про помилку і порожній список.
public sealed partial class ServicePlan : IEquatable<ServicePlan>
{
    /// Мітка формату у файлі — за нею відрізняємо свій план від чужого JSON.
    public const string FormatMarker = "slovo.plan";
    public const int FormatVersion = 1;
    /// Розширення навмисно `json`, а не своє: файл має відкриватися подвійним
    /// клацанням у будь-якому редакторі, читабельність тут важливіша за власний значок.
    public const string FileExtension = "json";
    /// Тека з планами всередині даних програми — та сама, що в оригіналу.
    public const string FolderName = "Plans";

    private string title;
    private List<PlanItem> items;

    public string Title
    {
        get => title;
        set
        {
            if (!SwiftText.Same(value, title)) HasUnsavedChanges = true;
            title = value;
        }
    }

    public IReadOnlyList<PlanItem> Items => items;

    /// Де стоїть подача. Не зберігається: план — це порядок, а не закладка.
    public int? CurrentIndex { get; private set; }

    /// Файл, з якого план відкрили або в який зберегли.
    public string? FileUrl { get; private set; }

    public bool HasUnsavedChanges { get; private set; }

    public ServicePlan(string title = "План служения", IEnumerable<PlanItem>? items = null)
    {
        this.title = title;
        this.items = items?.ToList() ?? new List<PlanItem>();
        CurrentIndex = this.items.Count == 0 ? null : 0;
        FileUrl = null;
        HasUnsavedChanges = false;
    }

    /// Копія-значення: у Swift план — структура.
    public ServicePlan Copy() => new(title, items)
    {
        CurrentIndex = CurrentIndex,
        FileUrl = FileUrl,
        HasUnsavedChanges = HasUnsavedChanges,
    };

    public bool Equals(ServicePlan? other) =>
        other is not null && title == other.title && items.SequenceEqual(other.items) && CurrentIndex == other.CurrentIndex
        && FileUrl == other.FileUrl && HasUnsavedChanges == other.HasUnsavedChanges;

    public override bool Equals(object? obj) => obj is ServicePlan other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(title, items.Count);

    // ── Читання списку ──────────────────────────────────────────────────────

    public bool IsEmpty => items.Count == 0;
    public int Count => items.Count;

    public PlanItem? this[int index] => index >= 0 && index < items.Count ? items[index] : null;

    public PlanItem? Current => CurrentIndex is { } index && index >= 0 && index < items.Count ? items[index] : null;

    public Guid? CurrentItemID => Current?.Id;

    public int? IndexOf(Guid id)
    {
        var index = items.FindIndex(item => item.Id == id);
        return index >= 0 ? index : null;
    }

    // ── Правка ──────────────────────────────────────────────────────────────

    public void Append(PlanItem item)
    {
        items.Add(item);
        CurrentIndex ??= items.Count - 1;
        HasUnsavedChanges = true;
    }

    public void Append(IEnumerable<PlanItem> newItems)
    {
        var list = newItems.ToList();
        if (list.Count == 0) return;
        items.AddRange(list);
        CurrentIndex ??= 0;
        HasUnsavedChanges = true;
    }

    public void Insert(PlanItem item, int index)
    {
        var position = Math.Min(Math.Max(index, 0), items.Count);
        items.Insert(position, item);
        if (CurrentIndex is { } current && position <= current) CurrentIndex = current + 1;
        CurrentIndex ??= position;
        HasUnsavedChanges = true;
    }

    public PlanItem? RemoveAt(int index)
    {
        if (index < 0 || index >= items.Count) return null;
        var removed = items[index];
        items.RemoveAt(index);
        CurrentIndex = IndexAfterRemoval(CurrentIndex, [index], items.Count);
        HasUnsavedChanges = true;
        return removed;
    }

    /// Видалення за набором позицій (`remove(atOffsets:)`) — так його віддає список.
    public void RemoveAt(IEnumerable<int> offsets)
    {
        var valid = new SortedSet<int>(offsets.Where(index => index >= 0 && index < items.Count));
        if (valid.Count == 0) return;
        foreach (var index in valid.Reverse()) items.RemoveAt(index);
        CurrentIndex = IndexAfterRemoval(CurrentIndex, valid, items.Count);
        HasUnsavedChanges = true;
    }

    public void Remove(Guid id)
    {
        if (IndexOf(id) is not { } index) return;
        RemoveAt(index);
    }

    public void RemoveAll()
    {
        if (items.Count == 0) return;
        items.Clear();
        CurrentIndex = null;
        HasUnsavedChanges = true;
    }

    /// Перестановка перетягуванням (`move(fromOffsets:toOffset:)`). Поточний пункт
    /// тримаємо за самим пунктом, а не за номером: оператор тягне сусіда, а подача
    /// зобов'язана лишитися на місці.
    public void Move(IEnumerable<int> offsets, int destination)
    {
        var anchor = CurrentItemID;
        var valid = new SortedSet<int>(offsets.Where(index => index >= 0 && index < items.Count));
        if (valid.Count == 0 || destination < 0 || destination > items.Count) return;

        // Той самий договір, що в списку SwiftUI: destination — місце вставки в
        // ще неторканому списку, тому його зсуваємо на вийняті пункти самі.
        var moved = valid.Select(index => items[index]).ToList();
        var insertion = destination - valid.Count(index => index < destination);
        var rest = items.ToList();
        foreach (var index in valid.Reverse()) rest.RemoveAt(index);
        rest.InsertRange(Math.Min(Math.Max(insertion, 0), rest.Count), moved);
        items = rest;

        if (anchor is { } id) CurrentIndex = IndexOf(id) ?? CurrentIndex;
        HasUnsavedChanges = true;
    }

    public void Move(int source, int destination)
    {
        if (source < 0 || source >= items.Count) return;
        Move([source], destination > source ? destination + 1 : destination);
    }

    public void Replace(int index, PlanItem item)
    {
        if (index < 0 || index >= items.Count) return;
        items[index] = item;
        HasUnsavedChanges = true;
    }

    // ── Подача ──────────────────────────────────────────────────────────────

    public void Select(int? index)
    {
        if (index is not { } chosen || chosen < 0 || chosen >= items.Count)
        {
            CurrentIndex = null;
            return;
        }
        CurrentIndex = chosen;
    }

    public void Select(Guid id)
    {
        if (IndexOf(id) is { } index) CurrentIndex = index;
    }

    /// Наступний пункт. По колу навмисно не ходимо: на служінні «далі» після
    /// останнього пункту має нічого не робити, а не стрибати на початок.
    public PlanItem? GoToNext()
    {
        if (items.Count == 0)
        {
            CurrentIndex = null;
            return null;
        }
        var next = CurrentIndex is { } current ? current + 1 : 0;
        if (next < 0 || next >= items.Count) return null;
        CurrentIndex = next;
        return items[next];
    }

    public PlanItem? GoToPrevious()
    {
        if (items.Count == 0)
        {
            CurrentIndex = null;
            return null;
        }
        var previous = CurrentIndex is { } current ? current - 1 : items.Count - 1;
        if (previous < 0 || previous >= items.Count) return null;
        CurrentIndex = previous;
        return items[previous];
    }

    public bool CanGoToNext
    {
        get
        {
            if (items.Count == 0) return false;
            var next = CurrentIndex is { } current ? current + 1 : 0;
            return next >= 0 && next < items.Count;
        }
    }

    public bool CanGoToPrevious =>
        CurrentIndex is not { } current ? items.Count > 0 : current - 1 >= 0 && current - 1 < items.Count;

    /// Куди стає подача після видалення: тримаємося за те саме місце в списку,
    /// а не за номер, який зсунувся разом із видаленими пунктами.
    private static int? IndexAfterRemoval(int? previous, IEnumerable<int> removed, int count)
    {
        if (count <= 0) return null;
        if (previous is not { } value) return null;
        var shifted = value - removed.Count(index => index < value);
        return Math.Min(Math.Max(shifted, 0), count - 1);
    }

    // ── Файли ───────────────────────────────────────────────────────────────

    public static string PlansDirectory(string dataRoot) => Path.Combine(dataRoot, FolderName);

    /// Плани в теці, свіжі зверху — відкривати зазвичай хочуть учорашній.
    public static List<string> SavedPlans(string directory)
    {
        var files = SwiftPath.Contents(directory, skipsHidden: true)
            .Where(path => SwiftPath.Extension(path).ToLowerInvariant() == FileExtension)
            .Select(path => (Path: path, Modified: Modified(path)))
            .ToList();
        // Стабільне сортування за правилом Swift: обидві дати є — новіша вище,
        // інакше — за іменем «як у Finder».
        return files.OrderBy(file => file, Comparer<(string Path, DateTime? Modified)>.Create((left, right) =>
        {
            if (left.Modified is not { } l || right.Modified is not { } r)
                return SwiftText.LocalizedStandardCompare(SwiftPath.LastComponent(left.Path), SwiftPath.LastComponent(right.Path));
            return r.CompareTo(l);
        })).Select(file => file.Path).ToList();
    }

    private static DateTime? Modified(string path)
    {
        try { return File.GetLastWriteTimeUtc(path); }
        catch (Exception) { return null; }
    }

    /// Ім'я файлу з назви плану: в імені не має бути того, що зламає
    /// шлях, а все інше хай лишається як написав користувач.
    public static string FileName(string title)
    {
        static bool Forbidden(char c) =>
            "/\\:*?\"<>|".Contains(c)
            || CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.Control or UnicodeCategory.Format;
        var pieces = new List<string>();
        var start = 0;
        for (var index = 0; index <= title.Length; index++)
        {
            if (index < title.Length && !Forbidden(title[index])) continue;
            pieces.Add(title[start..index]);
            start = index + 1;
        }
        var cleaned = string.Join(" ", pieces).TrimWhitespacesAndNewlines();
        var name = cleaned.Length == 0 ? "План" : cleaned;
        return $"{name}.{FileExtension}";
    }

    /// Мітка часу запису — `ISO8601DateFormatter` (UTC, до секунди). Для
    /// перевірок її можна підмінити.
    internal static Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;

    public JsonObject ToJson() => new()
    {
        ["format"] = FormatMarker,
        ["version"] = FormatVersion,
        ["title"] = title,
        // Позначка часу лише для людини: при читанні вона не потрібна, але за
        // нею видно, який зі схожих файлів свіжіший, не відкриваючи програму.
        ["savedAt"] = Clock().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture),
        ["items"] = new JsonArray(items.Select(item => (JsonNode?)item.ToJson()).ToArray()),
    };

    public byte[] JsonData()
    {
        // Кирилиця лишається кирилицею, ключі в сталому порядку — файл
        // має читатися очима і не шуміти в системі контролю версій.
        var text = SwiftJson.Write(ToJson(), pretty: true, sortedKeys: true, escapeSlashes: false);
        return new System.Text.UTF8Encoding(false).GetBytes(text);
    }

    public void Save(string path)
    {
        Directory.CreateDirectory(SwiftPath.Parent(path));
        SwiftPath.WriteAtomically(path, JsonData());
        FileUrl = path;
        HasUnsavedChanges = false;
    }

    /// Збереження поверх відкритого файла.
    public void Save()
    {
        if (FileUrl == null) throw PlanError.NoFile();
        Save(FileUrl);
    }

    /// План прив'язаний до файла і з ним збігається.
    ///
    /// Потрібно запису у форматі оригіналу (`ServicePlan+Journal`): `FileUrl` і
    /// `HasUnsavedChanges` закриті на запис — і правильно, що закриті: їх
    /// міняє лише збереження.
    public void MarkSaved(string path)
    {
        FileUrl = path;
        HasUnsavedChanges = false;
    }

    /// Що вдалося прочитати і скільки пунктів довелося пропустити.
    public readonly record struct LoadResult(ServicePlan Plan, int SkippedItems)
    {
        public bool HasSkippedItems => SkippedItems > 0;

        /// Готове попередження для вікна — або null, якщо все прочиталося.
        public string? Warning => SkippedItems > 0
            ? OurWords.T("Пропущено пунктов, которые не удалось прочитать: %s.", SkippedItems.ToString(CultureInfo.InvariantCulture))
            : null;
    }

    public static LoadResult Read(string path)
    {
        byte[] data;
        try
        {
            data = File.ReadAllBytes(path);
        }
        catch (Exception error)
        {
            throw PlanError.Unreadable(SwiftPath.LastComponent(path), error.Message);
        }

        ServicePlan plan;
        int skipped;
        try
        {
            (plan, skipped) = Decode(data);
        }
        catch (PlanError)
        {
            throw;
        }
        catch (Exception)
        {
            throw PlanError.Unreadable(SwiftPath.LastComponent(path), OurWords.T("файл не разбирается как JSON"));
        }

        // Назва плану у файлі може бути відсутня — тоді її заміняє ім'я
        // файлу: у списку планів порожній рядок виглядає як загублений план.
        if (plan.title.TrimWhitespacesAndNewlines().Length == 0)
            plan.Title = SwiftPath.LastComponent(SwiftPath.DeletingExtension(path));
        plan.FileUrl = path;
        plan.HasUnsavedChanges = false;
        return new LoadResult(plan, skipped);
    }

    /// Короткий шлях, коли лічильник пропущених пунктів не потрібен.
    public static ServicePlan Load(string path) => Read(path).Plan;

    /// `init(from:)`: план зі змісту файла і число пропущених пунктів.
    internal static (ServicePlan Plan, int Skipped) Decode(byte[] data)
    {
        using var document = LenientJson.Parse(data);
        var root = document.RootElement;
        var title = "";
        List<JsonElement>? raw = null;

        if (root.ValueKind == JsonValueKind.Object)
        {
            var container = new LenientJson.Object(root);
            if (container.Contains("items") || container.Contains("format") || container.Contains("title"))
            {
                title = LenientJson.StringOnly(container, "title") ?? "";
                raw = container["items"] is { ValueKind: JsonValueKind.Array } list ? list.EnumerateArray().ToList() : new List<JsonElement>();
            }
        }
        else if (root.ValueKind == JsonValueKind.Array)
        {
            // Файл може бути просто списком пунктів — так коротше писати руками.
            raw = root.EnumerateArray().ToList();
        }
        if (raw == null) throw PlanError.NotAPlan();

        var items = raw.Select(Lenient).Where(item => item != null).Select(item => item!).ToList();
        return (new ServicePlan(title, items), raw.Count - items.Count);
    }

    /// Обгортка, яка гасить помилку розбору одного пункту: масив читається
    /// цілком, і один невдалий елемент інакше потягнув би за собою весь план.
    private static PlanItem? Lenient(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) return null;
        try
        {
            return PlanItem.FromJson(new LenientJson.Object(element));
        }
        catch (PlanError)
        {
            return null;
        }
    }
}

public sealed class PlanError : Exception, IEquatable<PlanError>
{
    public enum Kind { NotAPlan, Unreadable, UnsupportedItem, NoFile }

    public Kind ErrorKind { get; }
    public string Name { get; }
    public string Reason { get; }

    private PlanError(Kind kind, string name, string reason, string message) : base(message)
    {
        ErrorKind = kind;
        Name = name;
        Reason = reason;
    }

    public static PlanError NotAPlan() => new(Kind.NotAPlan, "", "", OurWords.T("Это не файл плана служения"));
    public static PlanError Unreadable(string name, string reason) => new(Kind.Unreadable, name, reason, $"{name}: {reason}");
    public static PlanError UnsupportedItem(string reason) => new(Kind.UnsupportedItem, "", reason, $"Пункт плана пропущен: {reason}");
    public static PlanError NoFile() => new(Kind.NoFile, "", "", OurWords.T("План ещё ни разу не сохраняли — нужно выбрать файл"));

    public bool Equals(PlanError? other) =>
        other is not null && ErrorKind == other.ErrorKind && Name == other.Name && Reason == other.Reason;

    public override bool Equals(object? obj) => obj is PlanError other && Equals(other);
    public override int GetHashCode() => HashCode.Combine(ErrorKind, Name, Reason);
    public override string ToString() => Message;
}
