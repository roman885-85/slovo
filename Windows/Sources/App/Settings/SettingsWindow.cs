// =============================================================================
//  SettingsWindow.cs — вікно «Параметри» (як NativeSettingsWindow на Mac)
// =============================================================================
//  Дев'ять вкладок оригіналу: Слайд | Медіа | Шляхи | Оновлення | Remote API |
//  Основні | Додаткові | Модулі | Гарячі клавіші. Праворуч угорі — попередній
//  перегляд 16:9 (ширина 24 % вікна, 200…280). Унизу ліворуч — «↺ Скинути…»,
//  «Зберегти у файл…», «Узяти з файла…»; праворуч — «Скасувати» і «Гаразд».
//  Розмір 1180×720 (не більше екрана), найменше 1000×620.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace Slovo.App;

public sealed partial class SettingsWindow : Window
{
    public static SettingsWindow? Shared { get; private set; }

    public readonly MacTabView Tabs = new();
    public readonly SlideFrameView Preview = new();
    readonly BottomCaption _previewTitle = new() { FontSize = 11 };
    readonly LayoutPanel _root = new();
    readonly List<PushButton> _right = new(), _left = new();

    public Action? OnAccept, OnDiscard, OnReset, OnExport, OnImport;

    public SettingsWindow()
    {
        Shared = this;
        Title = Captions.T("Параметры");
        Width = 1180; Height = 720; MinWidth = 1000; MinHeight = 620;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        Content = _root;
        ApplyBackground();
        Palette.Changed += ApplyBackground;
        _previewTitle.Text = Captions.T("Предпросмотр");
        var ok = Form.Button(Captions.T("Ок"), Captions.T("Применить настройки"), () => OnAccept?.Invoke());
        ok.FontSize = 13; ok.Height = 24;
        var cancel = Form.Button(Captions.T("Отмена"), Captions.T("Отменить изменения и закрыть"), () => OnDiscard?.Invoke());
        cancel.FontSize = 13; cancel.Height = 24;
        var reset = Form.Button(Captions.T("↺ Сбросить…"), Captions.T("Вернуть значения к тем, с которыми программа запускается впервые"), () => OnReset?.Invoke());
        var save = Form.Button(Captions.T("Сохранить в файл…"), Captions.T("Сложить все настройки в один файл — перенести на другой компьютер"), () => OnExport?.Invoke());
        var load = Form.Button(Captions.T("Взять из файла…"), Captions.T("Прочитать настройки из файла, сохранённого раньше"), () => OnImport?.Invoke());
        foreach (var b in new[] { reset, save, load }) { b.FontSize = 13; b.Height = 24; }
        _left.AddRange(new[] { reset, save, load });
        _right.AddRange(new[] { cancel, ok });
        foreach (Control c in new Control[] { Tabs, Preview, _previewTitle }.Concat(_left).Concat(_right)) _root.Children.Add(c);
        _root.Layout = Arrange;
        KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Escape) { OnDiscard?.Invoke(); e.Handled = true; } };
    }

    /// Дев'ять вкладок — підписи з файла перекладу автора (форма SettingsForm).
    public void BuildTabs(SettingsStore store)
    {
        static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
        Title = Captions.FormCaption("SettingsForm", "SettingsForm", "Параметры");
        Tabs.Add(Vb("TSSlide", "Слайд"), new SlideTab(store).Page());
        Tabs.Add(Vb("TSMedia", "Медиа"), new MediaTab(store).Page());
        Tabs.Add(Vb("TSPath", "Пути"), new PathsTab(store).Page());
        Tabs.Add(Vb("TSUpdate", "Обновление"), new UpdateTab(store).Page());
        Tabs.Add(Vb("TSRemoteApi", "Remote API"), new RemoteTab(store).Page());
        Tabs.Add(Vb("TSBasic", "Основные"), new BasicTab(store).Page());
        Tabs.Add(Vb("TabSheet1", "Дополнительные"), new AdvancedTab(store).Page());
        Tabs.Add(Vb("TSModules", "Модули"), new ModulesTab(store).Page());
        Tabs.Add(Vb("TSHotKey", "Горячие клавиши"), new HotkeysTab(store).Page());
    }

    void ApplyBackground() =>
        Background = Palette.Brush(Palette.IsDark ? Color.FromRgb(0x2D, 0x2D, 0x2C) : Color.FromRgb(0xED, 0xEE, 0xED));

    void Arrange(Size size)
    {
        const double footer = 44;
        var previewWidth = Math.Min(280, Math.Max(200, size.Width * 0.24));
        var previewHeight = Math.Round(previewWidth / 16 * 9);
        _root.Place(Tabs, new Rect(10, 10, size.Width - 20 - (previewWidth + 10), Math.Max(0, size.Height - footer - 10)));
        _root.Place(Preview, new Rect(size.Width - 10 - previewWidth, 10, previewWidth, previewHeight));
        _root.Place(_previewTitle, new Rect(size.Width - 10 - previewWidth, 10 + previewHeight + 2, previewWidth, 16));
        var right = size.Width - 12;
        for (var i = _right.Count - 1; i >= 0; i--)
        {
            var b = _right[i];
            var width = Math.Max(90, b.FittingWidth + 24);
            _root.Place(b, new Rect(right - width, size.Height - 10 - 24, width, 24));
            right -= width + 8;
        }
        double left = 12;
        foreach (var b in _left)
        {
            var width = b.FittingWidth + 20;
            if (left + width >= right - 8) { _root.Place(b, default); continue; }
            _root.Place(b, new Rect(left, size.Height - 10 - 24, width, 24));
            left += width + 6;
        }
    }
}
