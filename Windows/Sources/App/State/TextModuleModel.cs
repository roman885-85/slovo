// =============================================================================
//  TextModuleModel.cs — модуль «Текст» (як TextModuleModel.swift на Mac)
// =============================================================================
//  Набраний заголовок і текст ділиться на сторінки за налаштуваннями розділу
//  [Text] (розбивати на сторінки, автоперенос, знаків у рядку за мінімального
//  кегля). Стрілки гортають сторінки; одиночний показ — передпоказ, «Показати»
//  — у зал (і в «Історію»). Набране переживає перезапуск.
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class TextModuleModel
{
    public static readonly TextModuleModel Shared = new();
    const string StorageKey = "textModule.document";

    PlainTextDocument _document = new();
    public PlainTextDocument.Pagination Pagination { get; private set; } = new();
    public int PageIndex { get; private set; }
    /// Куди віддати зібраний слайд: (слайд, у зал?).
    public Action<Slide, bool>? Present;
    public event Action? Changed;
    public string? ConfigPath { get; private set; }
    DispatcherTimer? _save;

    TextModuleModel()
    {
        try
        {
            if (Defaults.String(StorageKey) is { Length: > 0 } saved)
                _document = SwiftJson.Decode<PlainTextDocument>(System.Text.Encoding.UTF8.GetBytes(saved));
        }
        catch { _document = new PlainTextDocument(); }
        LoadSettings();
    }

    public PlainTextDocument Document
    {
        get => _document;
        set
        {
            if (value.Equals(_document)) return;
            if (value.Body != _document.Body) PageIndex = 0;
            _document = value;
            ClampPage();
            RefreshPreview();
            ScheduleSave();
            Changed?.Invoke();
        }
    }

    public string Title { get => _document.Title; set { var d = _document; d.Title = value; Document = d; } }
    public string Body { get => _document.Body; set { var d = _document; d.Body = value; Document = d; } }

    /// Розбивка — з розділу [Text] файла налаштувань, зі стилем того самого розділу.
    public string? LoadSettings()
    {
        try
        {
            if (IniSettings.LocateConfig() is not { } path) return null;
            var config = IniSettings.FromFile(path);
            Pagination = new PlainTextDocument.Pagination(config, "Text", new SlideStyle(config, "Text", null));
            ConfigPath = path;
            return path;
        }
        catch { return null; }
    }

    public List<Slide> Slides => _document.Slides(Pagination);
    public int PageCount => _document.PageCount(Pagination);
    public Slide CurrentSlide
    {
        get
        {
            var slides = Slides;
            return slides.Count == 0 ? Slide.Blank : slides[Math.Min(PageIndex, slides.Count - 1)];
        }
    }

    public bool Step(int delta, bool live)
    {
        var count = PageCount;
        if (count == 0) return false;
        var next = PageIndex + delta;
        if (next < 0 || next >= count) return false;
        PageIndex = next;
        Publish(live);
        return true;
    }

    public void SelectPage(int index, bool live)
    {
        if (PageCount == 0) return;
        PageIndex = Math.Min(Math.Max(index, 0), PageCount - 1);
        Publish(live);
    }

    /// Стрілка на вкладці «Текст»: є сторінки — гортаємо їх (навіть на краю),
    /// Біблію не чіпаємо.
    public bool HandleStep(int delta, bool live)
    {
        if (PageCount == 0) return false;
        Step(delta, live);
        return true;
    }

    public void Show() => Publish(true);

    public bool ShowIfReady()
    {
        if (PageCount == 0) return false;
        Publish(true);
        return true;
    }

    public void RefreshPreview() => Publish(false);

    void Publish(bool live) => Present?.Invoke(CurrentSlide, live);

    void ClampPage()
    {
        var count = PageCount;
        PageIndex = count > 0 ? Math.Min(PageIndex, count - 1) : 0;
    }

    public void Clear()
    {
        var d = _document;
        d.Clear();
        PageIndex = 0;
        Document = d;
    }

    /// Прийняти місце Писання з Біблії (план, пульт).
    public void Receive(string reference, string text, PlainTextDocument.Reception mode = PlainTextDocument.Reception.Replace)
    {
        var d = _document;
        d.Receive(reference, text, mode);
        PageIndex = 0;
        Document = d;
        RefreshPreview();
    }

    /// Пункт плану «текст»: на вкладку, і одразу в зал.
    public void Activate(PlainTextDocument text, AppState state)
    {
        state.Mode = WorkMode.Text;
        Signals.Shared.Send(Signals.Kind.Mode);
        _document = text;
        PageIndex = 0;
        Changed?.Invoke();
        Show();
    }

    void ScheduleSave()
    {
        _save?.Stop();
        var snapshot = _document;
        _save = new DispatcherTimer(TimeSpan.FromSeconds(1), DispatcherPriority.Background, (s, _) =>
        {
            ((DispatcherTimer)s!).Stop();
            try { Defaults.Set(StorageKey, SwiftJson.Encode(snapshot)); } catch { }
        });
        _save.Start();
    }
}
