// =============================================================================
//  WebSlideEditorModel.cs — стан редактора веб-слайдів (з Views/WebEditor/WebSlideEditorModel.swift)
// =============================================================================
//  Сторінки двох родів. Авторські лежать у теці `RemoteAPI` поруч із модулями —
//  їх не чіпаємо: це чужі файли. Свої живуть окремо (`WebSlides` у теці даних) і
//  правляться вільно; з авторської легко почати свою — «Узяти за основу».
//
//  Правка йде двома шляхами, і обидва пишуть у той самий текст `Source`, який
//  показує вкладка «Розмітка», — другого сховища значень немає ніде. Повзунок
//  міняє рівно один рядок блоку налаштувань; правка руками при наступному
//  розборі стає показом повзунка.
// =============================================================================

using System.Text;
using Avalonia;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class WebSlideEditorModel
{
    public sealed record Page(string Path, bool IsEditable)
    {
        public string Id => Path;
        public string Name => System.IO.Path.GetFileName(Path);
        /// Заголовок із `<title>` — у списку читається краще за ім'я файлу.
        public string Title => PageTitle(Path) ?? Name;
    }

    static readonly object TitleLock = new();
    static readonly Dictionary<string, (DateTime Date, string? Title)> TitleCache = new();

    public static string? PageTitle(string path)
    {
        DateTime date;
        try { date = File.GetLastWriteTimeUtc(path); } catch { date = DateTime.MinValue; }
        lock (TitleLock)
        {
            if (TitleCache.TryGetValue(path, out var cached) && cached.Date == date) return cached.Title;
            string? title = null;
            try
            {
                var data = File.ReadAllBytes(path);
                var html = CodePage.TryDecode(data, CodePage.Utf8) ?? CodePage.WindowsCP1251.GetString(data);
                var open = html.IndexOf("<title>", StringComparison.OrdinalIgnoreCase);
                var close = open < 0 ? -1 : html.IndexOf("</title>", open + 7, StringComparison.OrdinalIgnoreCase);
                if (close > open)
                {
                    var text = html[(open + 7)..close].Trim();
                    // Наші заготовки пишуть «Слайд — Біблія: ліс»: у вузькому списку видно лише
                    // «Слайд — Біб…», а слово одне на всіх.
                    foreach (var prefix in new[] { "Слайд — ", "Слово — " })
                        if (text.StartsWith(prefix, StringComparison.Ordinal)) text = text[prefix.Length..];
                    if (text.Length > 0) title = OurWords.T(text);
                }
            }
            catch { }
            TitleCache[path] = (date, title);
            return title;
        }
    }

    /// Одноразова команда передпоказу — те, що не виразити значенням змінної.
    public readonly record struct PreviewCommand(int Tick, string Script);

    public IReadOnlyList<Page> AuthorPages { get; private set; } = Array.Empty<Page>();
    public IReadOnlyList<Page> MyPages { get; private set; } = Array.Empty<Page>();
    public Page? Current { get; private set; }
    /// Повідомлення про останню дію (на Mac у вікні його не видно; тут — ще й у журнал).
    public string? Message { get; private set; }

    /// Щось змінилося — вікно перечитує себе на наступному проході циклу (склеєно).
    public event Action? Changed;
    bool _notifying;

    void Notify()
    {
        if (_notifying) return;
        _notifying = true;
        Dispatcher.UIThread.Post(() => { _notifying = false; Changed?.Invoke(); });
    }

    void Say(string? text)
    {
        Message = text;
        if (text != null) Journal.Say("веб-редактор: " + text);
        Notify();
    }

    string _source = "";
    /// Текст сторінки — єдине джерело правди.
    public string Source
    {
        get => _source;
        set
        {
            if (_source == value) return;
            _source = value;
            Sheet = WebSlideSheet.Read(value);
            IsModified = value != _savedSource;
            ScheduleSave();
            Notify();
        }
    }

    public bool IsModified { get; private set; }
    /// Розібране оформлення відкритої сторінки.
    public WebSlideSheet Sheet { get; private set; } = WebSlideSheet.Read("");
    /// Людина торкнула ручку на сторінці з комплекту — пропонуємо копію.
    public bool OffersCopy { get; set; }

    /// Куди віддати змінені значення, щоб вони лягли на трансляцію тут же.
    public Action<IReadOnlyDictionary<string, string>>? Broadcast;

    // ── Передпоказ ────────────────────────────────────────────────────────────

    WebSlideSample _sample = WebSlideSample.All[0];
    /// Чим наповнено слайд у передпоказі.
    public WebSlideSample Sample
    {
        get => _sample;
        set
        {
            if (_sample == value) return;
            _sample = value;
            ScheduleSampleApply();
            Notify();
        }
    }
    /// Та сама проба, але застосована: між натисканням і перезавантаженням сторінки —
    /// пауза, інакше передпоказ моргає на кожну літеру.
    public WebSlideSample AppliedSample { get; private set; } = WebSlideSample.All[0];

    bool _blank;
    /// Показати, що бачить зал при порожньому екрані — сторінка вміє це сама.
    public bool IsBlankScreen
    {
        get => _blank;
        set
        {
            if (_blank == value) return;
            _blank = value;
            Send($"if (window.slovoPreview) window.slovoPreview.hide({(value ? "true" : "false")});");
        }
    }
    public PreviewCommand Command { get; private set; } = new(0, "");

    /// Звідки передпоказ бере допоміжні файли сторінки (`i/jquery…`, картинки): поруч
    /// заводиться тимчасова тека з усім невидимим господарством сторінки; у теку автора не пишеться ні байта.
    public string? PreviewFolder { get; private set; }
    /// Свій jQuery у теці передпоказу, якщо він там є.
    public string? LocalJQuery { get; private set; }

    string _savedSource = "";
    string? _authorFolder;
    DispatcherTimer? _saveTimer, _applyTimer, _sampleTimer;

    /// Куди складаються свої сторінки — та сама тека, яку віддає веб-сервер.
    public static string MyFolder => WebOutputServer.UserPagesFolder;

    // ── Список сторінок ───────────────────────────────────────────────────────

    public void Reload(string dataRoot)
    {
        var folder = Path.Combine(dataRoot, "RemoteAPI");
        _authorFolder = folder;
        try { Directory.CreateDirectory(MyFolder); } catch { }
        AuthorPages = Html(folder).Select(path => new Page(path, false)).ToList();
        MyPages = Html(MyFolder).Select(path => new Page(path, true)).ToList();
        if (Current == null) Open(MyPages.FirstOrDefault() ?? AuthorPages.FirstOrDefault());
        Notify();
    }

    static List<string> Html(string folder) =>
        SwiftPath.Contents(folder, skipsHidden: true)
            .Where(path => SwiftPath.Extension(path).ToLowerInvariant() == "html" && File.Exists(path))
            .OrderBy(path => Path.GetFileName(path), SwiftText.StandardOrder)
            .ToList();

    // ── Відкрити, зберегти, створити ──────────────────────────────────────────

    public void Open(Page? page)
    {
        if (page == null) return;
        string text;
        try { text = new UTF8Encoding(false, true).GetString(File.ReadAllBytes(page.Path)); }
        catch { Say(OurWords.T("Не удалось прочитать %s", page.Name)); return; }
        // Перемикання сторінки не має тягнути відкладене збереження попередньої в новий файл.
        FlushSave();
        Current = page;
        _savedSource = text;
        Source = text;
        IsModified = false;
        Message = null;
        PrepareResources(page);
        RefreshBlocksIfOld();
        Notify();
    }

    /// Оновити наші блоки, якщо сторінку налаштовував попередній випуск: прив'язка
    /// й живий блок правляться разом із програмою, значення — не чіпаються.
    void RefreshBlocksIfOld()
    {
        if (Current?.IsEditable != true) return;
        var document = WebSlideParameters.Parse(Source);
        if (document.Block.Kind != WebSlideBlock.Kinds.Present || document.Block.Version >= WebSlideParameters.Version) return;
        var written = WebSlideParameters.Write(Source, document.Settings);
        if (written.Html is not { } text) return;
        Source = text;
        Say(OurWords.T("Страница обновлена под новый выпуск — ваши настройки остались как были."));
    }

    void PrepareResources(Page page)
    {
        var temp = Path.Combine(Path.GetTempPath(), "Слово-предпросмотр");
        try
        {
            if (Directory.Exists(temp)) Directory.Delete(temp, true);
            Directory.CreateDirectory(temp);
        }
        catch
        {
            PreviewFolder = null;
            LocalJQuery = null;
            return;
        }
        // Спершу господарство автора, потім своє: своя копія чужої сторінки лежить в
        // іншій теці, де `i/jquery` немає, а сторінка його все одно вимагає.
        var sources = new List<string>();
        if (_authorFolder != null) sources.Add(_authorFolder);
        var own = Path.GetDirectoryName(page.Path) ?? "";
        if (own != _authorFolder) sources.Add(own);
        foreach (var folder in sources)
            foreach (var item in SwiftPath.Contents(folder, skipsHidden: true))
            {
                if (SwiftPath.Extension(item).ToLowerInvariant() == "html") continue;
                var target = Path.Combine(temp, Path.GetFileName(item));
                try
                {
                    if (Directory.Exists(item)) { if (Directory.Exists(target)) Directory.Delete(target, true); CopyFolder(item, target); }
                    else File.Copy(item, target, true);
                }
                catch { }
            }
        PreviewFolder = temp;
        LocalJQuery = JQuery(temp);
    }

    static void CopyFolder(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.GetFiles(from)) File.Copy(file, Path.Combine(to, Path.GetFileName(file)), true);
        foreach (var folder in Directory.GetDirectories(from)) CopyFolder(folder, Path.Combine(to, Path.GetFileName(folder)));
    }

    /// Свій jQuery у теці передпоказу — шляхом відносно сторінки: три сторінки автора
    /// тягнуть jQuery з інтернету, а в передпоказі його немає майже ніколи.
    static string? JQuery(string folder)
    {
        var inner = Path.Combine(folder, "i");
        var file = SwiftPath.Contents(inner, skipsHidden: true).FirstOrDefault(path =>
            Path.GetFileName(path).ToLowerInvariant().StartsWith("jquery", StringComparison.Ordinal)
            && SwiftPath.Extension(path).ToLowerInvariant() == "js");
        return file == null ? null : "i/" + Path.GetFileName(file);
    }

    public bool Save()
    {
        FlushApply();
        _saveTimer?.Stop();
        if (Current is not { } page) return false;
        if (!IsModified)
        {
            // Автозбереження вже записало файл — скажемо про це, а не мовчимо.
            Say(OurWords.T("Уже сохранено: %s", page.Name));
            return true;
        }
        if (!page.IsEditable)
        {
            Say(OurWords.T("Это страница из комплекта программы, её нельзя менять. Нажмите «Взять за основу»."));
            return false;
        }
        try
        {
            SwiftPath.WriteAtomically(page.Path, new UTF8Encoding(false).GetBytes(Source));
            _savedSource = Source;
            IsModified = false;
            Say(OurWords.T("Сохранено: %s", page.Name));
            return true;
        }
        catch (Exception error)
        {
            Say(OurWords.T("Не удалось сохранить: %s", error.Message));
            return false;
        }
    }

    /// Збереження із затримкою: повзунок за один рух міняє рядок десятки разів —
    /// пишемо через паузу після того, як правки втихли.
    void ScheduleSave()
    {
        if (Current?.IsEditable != true) return;
        _saveTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(900), DispatcherPriority.Background, (_, _) => { _saveTimer!.Stop(); Save(); });
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    /// Дописати відкладене негайно — перед зміною сторінки й закриттям вікна.
    public void FlushSave()
    {
        FlushApply();
        if (_saveTimer is { IsEnabled: true }) Save();
    }

    /// Нова сторінка із заготовки.
    public void Create(WebSlideTemplates.Template template, string name)
    {
        var safe = name.TrimWhitespaces().Length == 0 ? template.Id : name.TrimWhitespaces();
        var file = Path.Combine(MyFolder, safe + ".html");
        for (var index = 2; File.Exists(file); index++) file = Path.Combine(MyFolder, $"{safe} {index}.html");
        try
        {
            SwiftPath.WriteAtomically(file, new UTF8Encoding(false).GetBytes(template.Html));
            ReloadMine();
            Open(new Page(file, true));
            Say(OurWords.T("Создана страница %s", Path.GetFileName(file)));
        }
        catch (Exception error) { Say(OurWords.T("Не удалось создать: %s", error.Message)); }
    }

    /// Скопіювати відкриту сторінку у свої й далі правити копію.
    public bool DuplicateCurrent()
    {
        if (Current is not { } page) return false;
        var name = SwiftPath.DeletingExtension(page.Name);
        // Слово «копия» тут навмисно не перекладається: це ІМ'Я ФАЙЛУ на диску, а не
        // підпис — інакше та сама сторінка звалася б по-різному залежно від мови.
        var file = Path.Combine(MyFolder, $"{name} копия.html");
        for (var index = 2; File.Exists(file); index++) file = Path.Combine(MyFolder, $"{name} копия {index}.html");
        try
        {
            SwiftPath.WriteAtomically(file, new UTF8Encoding(false).GetBytes(Source));
            ReloadMine();
            Open(new Page(file, true));
            // Ніяких блоків у копію не додаємо: копія зобов'язана бути копією.
            Say(OurWords.T("Теперь правится своя копия: %s", Path.GetFileName(file)));
            return true;
        }
        catch (Exception error)
        {
            Say(OurWords.T("Не удалось скопировать: %s", error.Message));
            return false;
        }
    }

    public void Delete(Page page)
    {
        if (!page.IsEditable) return;
        try { File.Delete(page.Path); } catch { }
        if (Current?.Id == page.Id)
        {
            _saveTimer?.Stop();
            Current = null;
            _savedSource = "";
            Source = "";
        }
        ReloadMine();
        Open(MyPages.FirstOrDefault() ?? AuthorPages.FirstOrDefault());
        Notify();
    }

    void ReloadMine() => MyPages = Html(MyFolder).Select(path => new Page(path, true)).ToList();

    // ── Повзунки ──────────────────────────────────────────────────────────────

    /// Чи можна правити відкриту сторінку; якщо ні — пропонуємо копію.
    public bool RequireEditable()
    {
        if (Current == null) return false;
        if (Current.IsEditable) return true;
        OffersCopy = true;
        Notify();
        return false;
    }

    public void Change(WebSlideKnob knob, string value) => Apply(new[] { (knob.Name, value) });

    /// Значення повзунків, ще не вписані в текст сторінки.
    readonly Dictionary<string, string> _pending = new(StringComparer.Ordinal);

    /// Записати пачку значень разом. На трансляцію значення йде одразу (дешево —
    /// кілька рядків по сокету), а важку перезапис тексту відкладаємо й склеюємо:
    /// пишемо раз, останніми значеннями, коли повзунок завмер.
    public void Apply(IEnumerable<(string Name, string Value)> changes)
    {
        var list = changes.ToList();
        if (list.Count == 0) return;
        if (!RequireEditable()) return;
        foreach (var (name, value) in list) _pending[name] = value;
        var outgoing = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (name, value) in list) outgoing[name] = value;
        Broadcast?.Invoke(outgoing);
        _applyTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(45), DispatcherPriority.Background, (_, _) => FlushApply());
        _applyTimer.Stop();
        _applyTimer.Start();
    }

    /// Вписати накопичені значення повзунків у текст сторінки одним заходом.
    public void FlushApply()
    {
        _applyTimer?.Stop();
        if (_pending.Count == 0) return;
        var changes = _pending.Select(pair => (pair.Key, pair.Value)).ToList();
        _pending.Clear();
        // Повзунок на сторінці без налаштувань заводить їх сам — але рівно те, що тронули.
        if (Sheet.State.Kind == WebSlideSheet.Block.Kinds.Missing)
        {
            var only = new WebSlideSettings();
            foreach (var (name, value) in changes) only.Set(name, value);
            var written = WebSlideParameters.Write(Source, only);
            if (written.Html is { } text) Source = text; else Say(written.Reason);
            return;
        }
        var outcome = Sheet.Writing(changes, Source);
        if (outcome.Html is { } html) Source = html; else Say(outcome.Reason);
    }

    /// Вернути ручку до того, що стоїть у заготовці.
    public void Reset(WebSlideKnob knob)
    {
        if (WebSlideParameters.Parameter(knob.Name) is not { } parameter || Sheet.Kind != WebSlideSheet.Dialect.Parameters) return;
        Apply(new[] { (knob.Name, parameter.DefaultValue) });
    }

    /// Завести в сторінці порожній блок налаштувань: рядки в ньому з'являються по одному,
    /// коли рухають ручки.
    public void AddSettingsBlock()
    {
        if (!RequireEditable()) return;
        var written = WebSlideParameters.Write(Source, new WebSlideSettings());
        if (written.Html is { } text)
        {
            Source = text;
            Say(OurWords.T("Настройки заведены. Двигайте ползунки — в страницу ляжет только то, что вы тронули."));
        }
        else Say(written.Reason);
    }

    /// Переписати пошкоджений блок заново.
    public void RepairSettingsBlock()
    {
        if (!RequireEditable()) return;
        var outcome = WebSlideSheet.Repairing(Source);
        if (outcome.Html is { } text)
        {
            Source = text;
            Say(OurWords.T("Блок настроек переписан заново."));
        }
        else Say(outcome.Reason);
    }

    // ── Перетягування ─────────────────────────────────────────────────────────

    /// Де блок стоїть зараз, у частках кадру.
    public Point PlacementPoint => Sheet.PlacementPoint;

    /// Відпустили мишу в цій точці кадру.
    public void Place(Point point)
    {
        var changes = Sheet.Placing(point);
        if (changes.Count == 0)
        {
            if (Current?.IsEditable == true) Say(OurWords.T("Эту страницу нельзя двигать мышью: в ней нет ручки расположения."));
            return;
        }
        Apply(changes);
    }

    /// Як назвати людині місце, куди стане блок.
    public string PlacementTitle(Point point)
    {
        var drop = WebSlidePlacement.Drop(point);
        var rows = new[] { "сверху", "посередине", "снизу" };
        var columns = new[] { "слева", "по центру", "справа" };
        var title = rows[drop.Row] + " " + columns[drop.Column];
        if (drop.OffsetX != 0 || drop.OffsetY != 0)
            title += ", " + OurWords.T("сдвиг %s / %s", WebSlideKnob.Digits(drop.OffsetX), WebSlideKnob.Digits(drop.OffsetY));
        return title;
    }

    // ── Передпоказ ────────────────────────────────────────────────────────────

    /// Сторінка з підміненим з'єднанням: показує вигаданий слайд одразу, без сервера.
    public string PreviewHtml
    {
        get
        {
            var shim = AppliedSample.Shim(IsBlankScreen);
            var page = WithLocalJQuery(Source, LocalJQuery);
            // Підміну вставляємо якнайраніше — до того, як сторінка створить своє з'єднання.
            var head = page.IndexOf("<head>", StringComparison.OrdinalIgnoreCase);
            return head >= 0 ? page[..head] + "<head>\n" + shim + page[(head + 6)..] : shim + page;
        }
    }

    /// Перевести посилання на jQuery з інтернету на свою копію — лише в рядку для показу.
    public static string WithLocalJQuery(string html, string? path)
    {
        if (string.IsNullOrEmpty(path)) return html;
        var result = html;
        foreach (var prefix in new[] { "https://", "http://", "//" })
        {
            var from = 0;
            while (true)
            {
                var hit = result.IndexOf(prefix + "code.jquery.com/", from, StringComparison.Ordinal);
                if (hit < 0) break;
                // Дочитуємо до кінця адреси: вона кінчається тією самою лапкою, якою відкрито атрибут.
                var stop = hit + prefix.Length + "code.jquery.com/".Length;
                while (stop < result.Length && result[stop] is not ('"' or '\'' or ' ' or '>')) stop++;
                result = result[..hit] + path + result[stop..];
                from = hit + path.Length;
            }
        }
        return result;
    }

    /// Перезавантажувати передпоказ лише тоді, коли змінилося щось, крім значень
    /// змінних: значення доїжджають скриптом, без блимання.
    public string PreviewReloadKey =>
        Sheet.StructureKey + "\u0001" + AppliedSample.Id + "\u0001" + AppliedSample.Text + "\u0001" + AppliedSample.Second + "\u0001"
        + AppliedSample.Reference + "\u0001" + AppliedSample.Next + "\u0001" + AppliedSample.SongTitle + "\u0001" + AppliedSample.Mode
        + "\u0001" + AppliedSample.PageCurrent + "/" + AppliedSample.PageCount;

    public IReadOnlyDictionary<string, string> PreviewValues => Sheet.Values;

    /// Повторити показ — видно плавну зміну слайда.
    public void Replay() => Send("if (window.slovoPreview) window.slovoPreview.replay();");

    void Send(string script)
    {
        Command = new PreviewCommand(Command.Tick + 1, script);
        Notify();
    }

    void ScheduleSampleApply()
    {
        _sampleTimer ??= new DispatcherTimer(TimeSpan.FromMilliseconds(350), DispatcherPriority.Background, (_, _) =>
        {
            _sampleTimer!.Stop();
            AppliedSample = Sample;
            Notify();
        });
        _sampleTimer.Stop();
        _sampleTimer.Start();
    }

    /// Узяти текст із живого слайда програми.
    public void TakeSample(string text, string second, string reference)
    {
        var next = WebSlideSample.FromSlide(text, second, reference) with { Next = Sample.Next };
        _sample = next;
        AppliedSample = next;
        _sampleTimer?.Stop();
        Notify();
    }

    /// Відкрити сторінку в браузері — як є, через працюючий сервер.
    public void OpenInBrowser(int port)
    {
        if (Current is not { } page) return;
        var url = WebPageAddress.Url("localhost", port, page.Name);
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception error) { Journal.Say($"посилання не відкрилось: {error.Message}"); }
    }
}
