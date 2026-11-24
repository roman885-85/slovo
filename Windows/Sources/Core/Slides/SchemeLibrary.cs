// =============================================================================
//  SchemeLibrary.cs — тека Templates: шаблони, фони, мініатюри
//  (з Slides/SchemeLibrary.swift)
// =============================================================================

using System.Globalization;
using System.Text;

namespace Slovo.Core;

/// Тека `Templates` оригіналу: список шаблонів, їхні фони й мініатюри.
///
/// Поруч із файлом `<Ім'я>.sch` лежить однойменна тека з усіма картинками
/// шаблону і підтека `thumbs` з прев'ю `scene1.jpg` (один переклад) і
/// `scene2.jpg` (два). Шлях до фону в ini — `Templates\SpringFade\spring_fon 2.jpg`.
public sealed class SchemeLibrary
{
    /// Висота слайда, під яку в оригіналі підбирали обведення й тінь.
    public const double DefaultDesignHeight = 600;

    public sealed record Template
    {
        public string Name { get; init; } = "";
        public string FileUrl { get; init; } = "";
        public string FolderUrl { get; init; } = "";
        public SlideScheme Scheme { get; init; } = new();
        public string? BackgroundUrl { get; init; }
        public string? SingleThumbnailUrl { get; init; }
        public string? DualThumbnailUrl { get; init; }
        /// Уміст теки шаблону — щоб шукати картинки без звертання до диска.
        internal IReadOnlyList<string> Files { get; init; } = Array.Empty<string>();

        public string Id => Name;

        public string? ThumbnailUrl(SlideScheme.Variant variant = SlideScheme.Variant.Single) =>
            variant == SlideScheme.Variant.Single ? SingleThumbnailUrl : DualThumbnailUrl;

        /// Шлях до картинки шаблону (`Image` / `ImageMask` будь-якого елемента).
        public string? ImageUrl(string? name) =>
            string.IsNullOrEmpty(name) ? null : Resolve(name, FolderUrl, Files);
    }

    public string Root { get; }
    public IReadOnlyList<Template> Templates { get; }
    /// Що не вдалося прочитати: ім'я файла -> причина. Один битий шаблон не
    /// має забирати із собою всю теку.
    public IReadOnlyDictionary<string, string> Failures { get; }
    public double DesignHeight { get; set; }

    public SchemeLibrary(string templatesRoot, double designHeight = DefaultDesignHeight)
    {
        Root = templatesRoot;
        DesignHeight = designHeight;

        var entries = SwiftPath.Names(templatesRoot) ?? Array.Empty<string>();
        var templates = new List<Template>();
        var failures = new Dictionary<string, string>(StringComparer.Ordinal);

        foreach (var entry in entries)
        {
            if (!entry.ToLowerInvariant().EndsWith(".sch", StringComparison.Ordinal)) continue;
            var fileUrl = Path.Combine(templatesRoot, entry);
            var name = SwiftPath.LastComponent(SwiftPath.DeletingExtension(fileUrl));
            try
            {
                var scheme = SchemeParser.Scheme(fileUrl);
                var folder = Path.Combine(templatesRoot, name);
                var files = SwiftPath.Names(folder) ?? Array.Empty<string>();
                var thumbs = Path.Combine(folder, "thumbs");
                var thumbFiles = SwiftPath.Names(thumbs) ?? Array.Empty<string>();

                templates.Add(new Template
                {
                    Name = name,
                    FileUrl = fileUrl,
                    FolderUrl = folder,
                    Scheme = scheme,
                    BackgroundUrl = Resolve(scheme.BackgroundImageName, folder, files),
                    SingleThumbnailUrl = Resolve("scene1.jpg", thumbs, thumbFiles),
                    DualThumbnailUrl = Resolve("scene2.jpg", thumbs, thumbFiles),
                    Files = files,
                });
            }
            catch (Exception error)
            {
                failures[entry] = error.Message;
            }
        }

        // `localizedCaseInsensitiveCompare`: без регістру, за мовою системи.
        Templates = templates.OrderBy(t => t.Name, Comparer<string>.Create((a, b) =>
            CultureInfo.CurrentCulture.CompareInfo.Compare(a, b, CompareOptions.IgnoreCase))).ToList();
        Failures = failures;
    }

    /// `dataRoot` — тека даних, та сама, що в `Modules`.
    public static SchemeLibrary FromDataRoot(string dataRoot, double designHeight = DefaultDesignHeight) =>
        new(Path.Combine(dataRoot, "Templates"), designHeight);

    /// Висоту слайда, під яку рахувалися пікселі обведення, беремо з ini.
    public static SchemeLibrary FromDataRoot(string dataRoot, IniSettings? config)
    {
        double? height = config?.Int("height", "OutScreen");
        return FromDataRoot(dataRoot, Math.Max(height ?? DefaultDesignHeight, 1));
    }

    // ── Пошук ───────────────────────────────────────────────────────────────

    public List<string> Names => Templates.Select(t => t.Name).ToList();

    public bool IsEmpty => Templates.Count == 0;

    /// Ім'я шаблону приходить з ini (`DefaultScheme=SpringFade`), тому
    /// порівнюємо без урахування регістру — Windows його не розрізняє.
    public Template? TemplateNamed(string name) =>
        Templates.FirstOrDefault(t => SwiftText.SameIgnoringCase(t.Name, name))
        ?? Templates.FirstOrDefault(t => SwiftText.SameIgnoringCase(t.Scheme.Name, name));

    public Template? this[string name] => TemplateNamed(name);

    // ── Переведення в стиль слайда ──────────────────────────────────────────

    public SlideStyle SlideStyleFor(Template template, SlideStyle? baseStyle = null,
                                    SlideScheme.Variant variant = SlideScheme.Variant.Single, double? designHeight = null) =>
        template.Scheme.ToSlideStyle(baseStyle, designHeight ?? DesignHeight, variant, template.BackgroundUrl);

    public SlideStyle? SlideStyleNamed(string name, SlideStyle? baseStyle = null,
                                       SlideScheme.Variant variant = SlideScheme.Variant.Single, double? designHeight = null) =>
        TemplateNamed(name) is { } template ? SlideStyleFor(template, baseStyle, variant, designHeight) : null;

    // ── Файли ───────────────────────────────────────────────────────────────

    /// Шукає файл за ім'ям із шаблону. Імена в `.sch` писалися на Windows:
    /// регістр там не важливий, роздільник — зворотна скісна риска, а кирилиця
    /// могла лягти в іншій нормалізації Unicode, ніж на диску.
    internal static string? Resolve(string name, string folder, IReadOnlyList<string> files)
    {
        if (name.Length == 0) return null;
        var cleaned = name.Replace("\\", "/");
        var pieces = cleaned.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var leaf = pieces.Length > 0 ? pieces[^1] : cleaned;

        var direct = Path.Combine(folder, leaf);
        if (SwiftPath.Exists(direct)) return direct;

        var wanted = leaf.Normalize(NormalizationForm.FormC).ToLowerInvariant();
        foreach (var file in files)
            if (file.Normalize(NormalizationForm.FormC).ToLowerInvariant() == wanted) return Path.Combine(folder, file);
        return null;
    }
}
