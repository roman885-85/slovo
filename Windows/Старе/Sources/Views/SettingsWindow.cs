// =============================================================================
//  SettingsWindow.cs — вікно «Параметри»
// =============================================================================
//  Вкладки — як у вікні параметрів оригіналу й «Слова» на Mac: Монітор,
//  Слайд (вигляд кожного режиму), Переклади, Пісенники, Фони й теки, Показ,
//  Адреса, Пісні, Гарячі клавіші, Пульт, Мова. Правки лягають у копію
//  налаштувань; «Ок» застосовує і зберігає, «Скасувати» нічого не чіпає,
//  «Застосувати» — одразу подивитися на проекторі, не закриваючи вікна.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;

namespace Slovo.Views;

public sealed class SettingsWindow : Window
{
    readonly AppState _state;
    readonly Settings _draft;
    readonly TabControl _tabs = new();
    HotkeySets _hotkeySets;
    /// Вкладка, з якої відкрити (перевірки без екрана).
    public int StartTab { get => _tabs.SelectedIndex; set { if (value >= 0 && value < _tabs.Items.Count) _tabs.SelectedIndex = value; } }

    public SettingsWindow(AppState state)
    {
        _state = state;
        _draft = state.Settings.Clone();
        _hotkeySets = HotkeySets.Load();
        Title = Lang.T("Параметри", "Settings");
        Width = 860;
        Height = 640;
        MinWidth = 720;
        MinHeight = 520;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;

        _tabs.Items.Add(Tab(Lang.T("Монітор", "Monitor"), BuildMonitor()));
        _tabs.Items.Add(Tab(Lang.T("Слайд", "Slide"), BuildSlide()));
        _tabs.Items.Add(Tab(Lang.T("Переклади", "Translations"), BuildTranslations()));
        _tabs.Items.Add(Tab(Lang.T("Пісенники", "Songbooks"), BuildSongBooks()));
        _tabs.Items.Add(Tab(Lang.T("Фони й теки", "Backgrounds and folders"), BuildBackgrounds()));
        _tabs.Items.Add(Tab(Lang.T("Показ", "Show"), BuildShow()));
        _tabs.Items.Add(Tab(Lang.T("Адреса й пісні", "Address and songs"), BuildAddress()));
        _tabs.Items.Add(Tab(Lang.T("Гарячі клавіші", "Hotkeys"), BuildHotkeys()));
        _tabs.Items.Add(Tab(Lang.T("Пульт", "Remote"), BuildRemote()));
        _tabs.Items.Add(Tab(Lang.T("Мова", "Language"), BuildLanguage()));

        var ok = Ui.Button(Lang.T("Ок", "OK"), () => { Apply(); Close(); }, accent: true);
        ok.IsDefault = true;
        var apply = Ui.Button(Lang.T("Застосувати", "Apply"), Apply, Lang.T("Застосувати, не закриваючи вікна", "Apply without closing the window"));
        var cancel = Ui.Button(Lang.T("Скасувати", "Cancel"), Close);
        cancel.IsCancel = true;
        var buttons = Ui.Row(cancel, apply, ok);
        buttons.HorizontalAlignment = HorizontalAlignment.Right;
        buttons.Margin = new Thickness(0, 8, 0, 0);
        var root = new DockPanel { Margin = new Thickness(12) };
        DockPanel.SetDock(buttons, Dock.Bottom);
        root.Children.Add(buttons);
        root.Children.Add(_tabs);
        Content = root;
    }

    static TabItem Tab(string title, Control content) => new() { Header = title, Content = new ScrollViewer { Content = content, Padding = new Thickness(6) } };

    void Apply()
    {
        CollectModules();
        _hotkeySets.Save();
        _state.HotkeySets.Order.Clear(); _state.HotkeySets.Order.AddRange(_hotkeySets.Order);
        _state.HotkeySets.Sets.Clear(); foreach (var (k, v) in _hotkeySets.Sets) _state.HotkeySets.Sets[k] = v;
        _state.ApplySettings(_draft.Clone());
    }

    // MARK: Будівельні блоки

    static StackPanel Column(params Control[] children)
    {
        var stack = new StackPanel { Spacing = 8 };
        foreach (var child in children) stack.Children.Add(child);
        return stack;
    }

    static CheckBox Check(string title, bool value, Action<bool> set, string? tip = null)
    {
        var box = new CheckBox { Content = title, IsChecked = value };
        box.IsCheckedChanged += (_, _) => set(box.IsChecked == true);
        if (tip != null) ToolTip.SetTip(box, tip);
        return box;
    }

    static Control NumberField(string title, double value, Action<double> set, double min, double max, double step = 1, string? tip = null)
    {
        var box = new NumericUpDown { Value = (decimal)value, Minimum = (decimal)min, Maximum = (decimal)max, Increment = (decimal)step, Width = 130, FormatString = step < 1 ? "0.##" : "0" };
        box.ValueChanged += (_, e) => { if (e.NewValue is decimal v) set((double)v); };
        var row = Ui.Row(Ui.Label(title), box);
        if (tip != null) ToolTip.SetTip(row, tip);
        return row;
    }

    static Control TextField(string title, string value, Action<string> set, double width = 240, bool password = false)
    {
        var box = new TextBox { Text = value, Width = width };
        if (password) box.PasswordChar = '•';
        box.TextChanged += (_, _) => set(box.Text ?? "");
        return Ui.Row(Ui.Label(title), box);
    }

    static Control ColorField(string title, string hex, Action<string> set)
    {
        var swatch = new Border { Width = 28, Height = 22, CornerRadius = new CornerRadius(4), BorderBrush = Ui.Line, BorderThickness = new Thickness(1) };
        void Paint(string h) { var rgba = RGBA.FromHex(h) ?? RGBA.White; swatch.Background = new SolidColorBrush(Color.FromRgb((byte)(rgba.R * 255), (byte)(rgba.G * 255), (byte)(rgba.B * 255))); }
        Paint(hex);
        var box = new TextBox { Text = hex, Width = 100 };
        box.TextChanged += (_, _) => { var text = (box.Text ?? "").Trim(); if (RGBA.FromHex(text) != null) { set(RGBA.FromHex(text)!.Value.Hex); Paint(text); } };
        var picker = new ColorPicker { Color = ToColor(hex), Width = 60 };
        picker.ColorChanged += (_, e) => { var h = new RGBA(e.NewColor.R / 255.0, e.NewColor.G / 255.0, e.NewColor.B / 255.0).Hex; box.Text = h; };
        return Ui.Row(Ui.Label(title), swatch, box, picker);
    }

    static Color ToColor(string hex) { var rgba = RGBA.FromHex(hex) ?? RGBA.White; return Color.FromRgb((byte)(rgba.R * 255), (byte)(rgba.G * 255), (byte)(rgba.B * 255)); }

    // MARK: Монітор

    Control BuildMonitor()
    {
        var screens = Screens.All;
        var list = new ComboBox { Width = 420 };
        list.Items.Add(new ComboBoxItem { Content = Lang.T("Автоматично: будь-який монітор, крім того, де вікно програми", "Automatically: any monitor but the one with the program window"), Tag = 0 });
        for (var i = 0; i < screens.Count; i++)
        {
            var s = screens[i];
            list.Items.Add(new ComboBoxItem { Content = Lang.F("Монітор {0}: {1}×{2}{3}", "Monitor {0}: {1}×{2}{3}", i + 1, s.Bounds.Width, s.Bounds.Height, s.IsPrimary ? Lang.T(" (головний)", " (primary)") : ""), Tag = i + 1 });
        }
        if (_draft.MonitorIndex > screens.Count) list.Items.Add(new ComboBoxItem { Content = Lang.F("Монітор {0} (зараз не підключено)", "Monitor {0} (not connected now)", _draft.MonitorIndex), Tag = _draft.MonitorIndex });
        list.SelectedIndex = Math.Max(0, Enumerable.Range(0, list.Items.Count).FirstOrDefault(i => (int)((ComboBoxItem)list.Items[i]!).Tag! == _draft.MonitorIndex));
        list.SelectionChanged += (_, _) => { if (list.SelectedItem is ComboBoxItem item) _draft.MonitorIndex = (int)item.Tag!; };
        var manual = Check(Lang.T("Ручна настройка: вікно слайда за координатами", "Manual placement: the slide window at coordinates"), _draft.ManualPlacement, v => _draft.ManualPlacement = v,
            Lang.T("Вікно без рамки ставиться за своїми координатами й розміром, навіть якщо монітора там зараз нема", "A borderless window is placed at its coordinates and size, even if there is no monitor there now"));
        return Column(
            Ui.Label(Lang.T("Монітор для слайда", "Monitor for the slide"), 15, true),
            list,
            Ui.Hint(Lang.T("Коли моніторів два, слайд іде на весь вибраний без рамки; коли один — звичайним вікном «Вікно слайда» (хрестик ховає його, воно повертається з наступним слайдом).",
                           "With two monitors the slide fills the chosen one without a frame; with one — as a normal “Slide window” (the close button hides it; it returns with the next slide).")),
            Check(Lang.T("Відкривати вікно слайда разом із програмою", "Open the slide window together with the program"), _draft.SlideWindowAtStart, v => _draft.SlideWindowAtStart = v,
                Lang.T("Вимкнено — вікно слайда відкривається кнопкою «Вікно слайда» вгорі головного вікна", "Off — the slide window is opened with the Slide window button at the top of the main window")),
            Ui.Label(Lang.T("Розміри за умовчанням (вікном, коли вибраного монітора нема)", "Default size (windowed, when the chosen monitor is missing)"), 13, true),
            Ui.Row(NumberField(Lang.T("Ширина", "Width"), _draft.DefaultWidth, v => _draft.DefaultWidth = (int)v, 320, 7680), NumberField(Lang.T("Висота", "Height"), _draft.DefaultHeight, v => _draft.DefaultHeight = (int)v, 180, 4320)),
            manual,
            Ui.Row(NumberField(Lang.T("Ліво", "Left"), _draft.CustomLeft, v => _draft.CustomLeft = (int)v, -20000, 20000), NumberField(Lang.T("Верх", "Top"), _draft.CustomTop, v => _draft.CustomTop = (int)v, -20000, 20000)),
            Ui.Row(NumberField(Lang.T("Ширина", "Width"), _draft.CustomWidth, v => _draft.CustomWidth = (int)v, 160, 7680), NumberField(Lang.T("Висота", "Height"), _draft.CustomHeight, v => _draft.CustomHeight = (int)v, 90, 4320)),
            NumberField(Lang.T("Висота слайда, під яку малювали шаблони .sch (px)", "Slide height the .sch templates were designed for (px)"), _draft.DesignHeight, v => _draft.DesignHeight = (int)v, 200, 4320, 1,
                Lang.T("В оригіналі — [OutScreen] height; від неї рахуються товщина контуру й тінь шаблонів", "In the original — [OutScreen] height; template outline and shadow are scaled from it")));
    }

    // MARK: Слайд

    Control BuildSlide()
    {
        var inner = new TabControl();
        foreach (var (key, title) in new[] { ("bible", Lang.T("Біблія", "Bible")), ("songs", Lang.T("Пісні", "Songs")), ("text", Lang.T("Текст", "Text")) })
            inner.Items.Add(new TabItem { Header = title, Content = BuildLook(_draft.Look(key), key) });
        return inner;
    }

    Control BuildLook(ModeLook look, string key)
    {
        var templates = new ComboBox { Width = 300 };
        templates.Items.Add(new ComboBoxItem { Content = Lang.T("Без шаблону — стиль нижче", "No template — the style below"), Tag = "" });
        foreach (var template in _state.Templates.Templates) templates.Items.Add(new ComboBoxItem { Content = template.Name, Tag = template.Name });
        templates.SelectedIndex = Math.Max(0, Enumerable.Range(0, templates.Items.Count).FirstOrDefault(i => string.Equals((string)((ComboBoxItem)templates.Items[i]!).Tag!, look.TemplateName, StringComparison.OrdinalIgnoreCase)));
        templates.SelectionChanged += (_, _) => { if (templates.SelectedItem is ComboBoxItem item) look.TemplateName = (string)item.Tag!; };

        var preview = new Image { Width = 384, Height = 216, Stretch = Stretch.Uniform };
        void Repaint()
        {
            try
            {
                var temp = _state.Settings; // стиль малюється з чернетки
                var style = StyleOf(look);
                var slide = key == "songs" ? new Slide("Великий Бог, коли на світ дивлюся,\nНа все, що Ти створив рукою Батька", new List<string>(), "Куплет 1", false)
                    : key == "text" ? new Slide("Після служіння — братське спілкування в залі внизу.", new List<string>(), "Оголошення", false)
                    : new Slide("Бо так полюбив Бог світ, що дав Сина Свого Однородженого, щоб кожен, хто вірує в Нього, не згинув, але мав життя вічне.", new List<string>(), "Ів. 3:16", false);
                var old = preview.Source as Avalonia.Media.Imaging.Bitmap;
                preview.Source = Bitmaps.Render(new RenderOrder { Slide = slide, Style = style }, 768, 432);
                old?.Dispose();
            }
            catch { /* передпоказ не обов'язковий */ }
        }
        templates.SelectionChanged += (_, _) => Repaint();

        Control LayerEditor(string title, TextLayer layer, bool sizes)
        {
            var fonts = new ComboBox { Width = 220 };
            var families = Fonts.Families();
            if (!families.Contains(layer.FontName, StringComparer.OrdinalIgnoreCase)) families.Insert(0, layer.FontName);
            foreach (var family in families) fonts.Items.Add(family);
            fonts.SelectedItem = families.FirstOrDefault(f => f.Equals(layer.FontName, StringComparison.OrdinalIgnoreCase));
            fonts.SelectionChanged += (_, _) => { if (fonts.SelectedItem is string f) { layer.FontName = f; Repaint(); } };
            var bold = Check(Lang.T("Жирний", "Bold"), layer.IsBold, v => { layer.IsBold = v; Repaint(); });
            var italic = Check(Lang.T("Курсив", "Italic"), layer.IsItalic, v => { layer.IsItalic = v; Repaint(); });
            var underline = Check(Lang.T("Підкреслений", "Underline"), layer.IsUnderline, v => { layer.IsUnderline = v; Repaint(); });
            var size = NumberField(Lang.T("Кегль, % висоти слайда", "Size, % of slide height"), layer.FontSize * 100, v => { layer.FontSize = v / 100; Repaint(); }, 1, 40, 0.5);
            var color = ColorField(Lang.T("Колір", "Colour"), layer.Color, h => { layer.Color = h; Repaint(); });
            var outline = Check(Lang.T("Контур", "Outline"), layer.IsOutlined, v => { layer.IsOutlined = v; Repaint(); });
            var outlineWidth = NumberField(Lang.T("Товщина контуру, % висоти", "Outline thickness, % of height"), layer.OutlineThickness * 100, v => { layer.OutlineThickness = v / 100; Repaint(); }, 0, 3, 0.05);
            var outlineColor = ColorField(Lang.T("Колір контуру", "Outline colour"), layer.OutlineColor, h => { layer.OutlineColor = h; Repaint(); });
            var shadow = NumberField(Lang.T("Тінь (розмиття), % висоти", "Shadow (blur), % of height"), layer.ShadowRadius * 100, v => { layer.ShadowRadius = v / 100; Repaint(); }, 0, 5, 0.1);
            var card = Ui.Card(Column(Ui.Label(title, 13, true), Ui.Row(Ui.Label(Lang.T("Шрифт", "Font")), fonts, bold, italic, underline), size, color, Ui.Row(outline, outlineWidth), outlineColor, shadow));
            return card;
        }

        var style = look.Style;
        var background = ColorField(Lang.T("Колір фону (коли нема картинки)", "Background colour (when there is no picture)"), style.BackgroundColor, h => { style.BackgroundColor = h; Repaint(); });
        var insets = Ui.Row(NumberField(Lang.T("Поля по горизонталі, %", "Horizontal margins, %"), style.HorizontalInset * 100, v => { style.HorizontalInset = v / 100; Repaint(); }, 0, 40, 0.5),
                            NumberField(Lang.T("по вертикалі, %", "vertical, %"), style.VerticalInset * 100, v => { style.VerticalInset = v / 100; Repaint(); }, 0, 40, 0.5));
        var spacing = NumberField(Lang.T("Міжрядковий відступ, частка кегля", "Line spacing, share of the size"), style.LineSpacing, v => { style.LineSpacing = v; Repaint(); }, 0, 1, 0.02);
        var valign = new ComboBox { Width = 200 };
        foreach (var (v, t) in new[] { (TextVertical.Top, Lang.T("Зверху", "Top")), (TextVertical.Center, Lang.T("По центру", "Centre")), (TextVertical.Bottom, Lang.T("Знизу", "Bottom")) })
            valign.Items.Add(new ComboBoxItem { Content = t, Tag = v });
        valign.SelectedIndex = (int)style.TextVertical;
        valign.SelectionChanged += (_, _) => { if (valign.SelectedItem is ComboBoxItem item) { style.TextVertical = (TextVertical)item.Tag!; Repaint(); } };
        var minFont = NumberField(Lang.T("Найменший кегль при стисканні, % висоти (fontminsize)", "Smallest size when shrinking, % of height (fontminsize)"), look.FontMinPercent, v => { look.FontMinPercent = v; Repaint(); }, 2, 30, 0.5);
        var pages = Check(Lang.T("Розбивати довгий текст на сторінки (PageSubDivide)", "Split long text into pages (PageSubDivide)"), look.PageSubDivide, v => look.PageSubDivide = v);
        var verses = Check(key == "songs" ? Lang.T("Ділити довгу частину пісні на кілька слайдів (VersSubDivide)", "Split a long song part into several slides (VersSubDivide)") : Lang.T("Розбивати на вірші / рядки (VersSubDivide)", "Split into verses / lines (VersSubDivide)"), look.VersSubDivide, v => look.VersSubDivide = v);
        var wrap = Check(Lang.T("Автоперенос слів (WordWrap)", "Word wrap (WordWrap)"), look.WordWrap, v => look.WordWrap = v);

        Repaint();
        return Column(
            Ui.Row(Ui.Label(Lang.T("Шаблон .sch", "Template .sch")), templates),
            Ui.Hint(Lang.T("Шаблон накладає свої кольори, контур, тінь, рамку й фон поверх стилю нижче; шрифти й кегль — зі стилю.", "The template lays its colours, outline, shadow, frame and background over the style below; fonts and size come from the style.")),
            new Border { Child = preview, Background = Brushes.Black, CornerRadius = new CornerRadius(4), HorizontalAlignment = HorizontalAlignment.Left },
            LayerEditor(Lang.T("Текст (цитата, куплет, оголошення)", "Text (quote, verse, announcement)"), style.Main, true),
            LayerEditor(Lang.T("Адреса (місце Писання, назва частини, заголовок)", "Address (reference, part name, heading)"), style.Reference, true),
            LayerEditor(Lang.T("Другий переклад", "Second translation"), style.Secondary, true),
            background, insets, spacing, Ui.Row(Ui.Label(Lang.T("Текст по вертикалі", "Vertical placement")), valign), minFont, pages, verses, wrap);
    }

    SlideStyle StyleOf(ModeLook look)
    {
        var style = look.Style.Clone();
        if (look.TemplateName.Length > 0 && _state.Templates.Named(look.TemplateName) is SlideTemplate template) style = template.Style(look.Style, _draft.DesignHeight, false);
        if (_draft.ShowCommonBackground && _draft.CommonBackground.Length > 0 && File.Exists(_draft.CommonBackground)) style.BackgroundImagePath = _draft.CommonBackground;
        style.MinimumScale = Math.Clamp(look.FontMinPercent / 100 / Math.Max(0.02, style.Main.FontSize), 0.2, 0.9);
        return style;
    }

    // MARK: Переклади

    readonly List<(Module Module, CheckBox Enabled, RadioButton Primary)> _moduleRows = new();
    readonly StackPanel _moduleList = new() { Spacing = 2 };

    Control BuildTranslations()
    {
        FillModules(_draft.ModuleOrder);
        var up = Ui.Button("↑", () => MoveModule(-1), Lang.T("Вище у смузі перекладів", "Up in the translation strip"));
        var down = Ui.Button("↓", () => MoveModule(1), Lang.T("Нижче", "Down"));
        var delete = Ui.Button(Lang.T("Видалити з бібліотеки…", "Delete from the library…"), () => _ = DeleteModule());
        var tabNames = Check(Lang.T("У смузі перекладів — повні назви, не скорочення", "Full names in the translation strip, not abbreviations"), _draft.TabNamesLong, v => _draft.TabNamesLong = v);
        return Column(
            Ui.Hint(Lang.T("Галочка — переклад у смузі перекладів; кружок — основний. Порядок — стрілками після вибору рядка (клацніть назву). Другий переклад вмикається правою кнопкою в смузі.",
                           "Tick — the translation is in the strip; the radio — the main one. Order — with the arrows after choosing a row (click the name). The second translation is toggled with the right button in the strip.")),
            Ui.Row(up, down, delete),
            _moduleList, tabNames);
    }

    int _chosenModule = -1;

    void FillModules(List<string> order)
    {
        _moduleRows.Clear();
        _moduleList.Children.Clear();
        var all = _state.AllModules;
        var ordered = order.Select(id => all.FirstOrDefault(m => m.Id == id)).Where(m => m != null).Select(m => m!).ToList();
        ordered.AddRange(all.Where(m => !order.Contains(m.Id)));
        foreach (var module in ordered)
        {
            var enabled = new CheckBox { IsChecked = order.Contains(module.Id) };
            var primary = new RadioButton { GroupName = "primary", IsChecked = module.Id == _draft.PrimaryModule, Content = "" };
            var name = new Button { Content = module.Name + "  (" + module.ShortName + ")", Background = Brushes.Transparent, Padding = new Thickness(6, 2) };
            var index = _moduleRows.Count;
            name.Click += (_, _) => { _chosenModule = index; foreach (var row in _moduleList.Children.OfType<StackPanel>()) row.Background = Brushes.Transparent; ((StackPanel)_moduleList.Children[index]).Background = Ui.AccentSoft; };
            var row = Ui.Row(enabled, primary, name);
            _moduleRows.Add((module, enabled, primary));
            _moduleList.Children.Add(row);
        }
    }

    void CollectModules()
    {
        _draft.ModuleOrder = _moduleRows.Where(r => r.Enabled.IsChecked == true).Select(r => r.Module.Id).ToList();
        var primary = _moduleRows.FirstOrDefault(r => r.Primary.IsChecked == true).Module?.Id;
        if (primary != null) { _draft.PrimaryModule = primary; if (!_draft.ModuleOrder.Contains(primary)) _draft.ModuleOrder.Insert(0, primary); }
    }

    void MoveModule(int delta)
    {
        if (_chosenModule < 0 || _chosenModule >= _moduleRows.Count) return;
        var target = _chosenModule + delta;
        if (target < 0 || target >= _moduleRows.Count) return;
        CollectModules();
        var ids = _moduleRows.Select(r => r.Module.Id).ToList();
        (ids[_chosenModule], ids[target]) = (ids[target], ids[_chosenModule]);
        var enabled = _draft.ModuleOrder;
        FillModules(ids.Where(enabled.Contains).ToList());
        // Усі рядки — у новому порядку, вимкнені теж.
        _moduleRows.Clear(); _moduleList.Children.Clear();
        var all = _state.AllModules;
        foreach (var id in ids)
        {
            var module = all.First(m => m.Id == id);
            var box = new CheckBox { IsChecked = enabled.Contains(id) };
            var primary = new RadioButton { GroupName = "primary", IsChecked = id == _draft.PrimaryModule, Content = "" };
            var name = new Button { Content = module.Name + "  (" + module.ShortName + ")", Background = Brushes.Transparent, Padding = new Thickness(6, 2) };
            var index = _moduleRows.Count;
            name.Click += (_, _) => { _chosenModule = index; foreach (var r in _moduleList.Children.OfType<StackPanel>()) r.Background = Brushes.Transparent; ((StackPanel)_moduleList.Children[index]).Background = Ui.AccentSoft; };
            var row = Ui.Row(box, primary, name);
            if (index == target) row.Background = Ui.AccentSoft;
            _moduleRows.Add((module, box, primary));
            _moduleList.Children.Add(row);
        }
        _chosenModule = target;
    }

    async System.Threading.Tasks.Task DeleteModule()
    {
        if (_chosenModule < 0 || _chosenModule >= _moduleRows.Count) { await Ui.Message(this, Lang.T("Переклади", "Translations"), Lang.T("Спершу клацніть назву перекладу в списку.", "First click a translation name in the list.")); return; }
        var module = _moduleRows[_chosenModule].Module;
        if (!await Ui.Ask(this, Lang.T("Видалити переклад", "Delete translation"), Lang.F("Видалити «{0}» з бібліотеки разом із файлами? Його можна буде поставити знову з ресурсів.", "Delete “{0}” from the library with its files? It can be installed again from the resources.", module.Name), Lang.T("Видалити", "Delete"))) return;
        _state.Library.Delete(module.Id);
        _draft.ModuleOrder.Remove(module.Id);
        _state.ReloadModules();
        _chosenModule = -1;
        FillModules(_draft.ModuleOrder);
    }

    // MARK: Пісенники

    Control BuildSongBooks()
    {
        var list = new StackPanel { Spacing = 4 };
        foreach (var book in _state.SongBooks)
        {
            var count = _state.Library.Count("songs", book.Id);
            var row = Ui.Row(Ui.Label(book.Name + "  (" + book.ShortName + ") — " + Lang.F("{0} пісень", "{0} songs", count)));
            var id = book.Id;
            row.Children.Add(Ui.Button(Lang.T("Перейменувати…", "Rename…"), async () =>
            {
                var title = await Ui.Prompt(this, Lang.T("Пісенник", "Songbook"), Lang.T("Назва:", "Title:"), book.Name);
                if (string.IsNullOrWhiteSpace(title)) return;
                var shortName = await Ui.Prompt(this, Lang.T("Пісенник", "Songbook"), Lang.T("Коротке ім'я:", "Short name:"), book.ShortName);
                if (shortName == null) return;
                _state.Library.Rename(id, title.Trim(), shortName.Trim());
                _state.SongBookChanged(id);
                _tabs.SelectedIndex = 3; ((TabItem)_tabs.Items[3]!).Content = new ScrollViewer { Content = BuildSongBooks(), Padding = new Thickness(6) };
            }));
            row.Children.Add(Ui.Button(Lang.T("Видалити…", "Delete…"), async () =>
            {
                if (!await Ui.Ask(this, Lang.T("Видалити пісенник", "Delete songbook"), Lang.F("Видалити «{0}» з бібліотеки разом із файлом?", "Delete “{0}” from the library with its file?", book.Name), Lang.T("Видалити", "Delete"))) return;
                _state.Library.Delete(id);
                _state.SongBookChanged(id);
                ((TabItem)_tabs.Items[3]!).Content = new ScrollViewer { Content = BuildSongBooks(), Padding = new Thickness(6) };
            }));
            list.Children.Add(row);
        }
        if (_state.SongBooks.Count == 0) list.Children.Add(Ui.Hint(Lang.T("Пісенників ще немає: меню «Файл» → ресурси або «Пісні» → «Новий пісенник…».", "No songbooks yet: File → resources or Songs → New songbook….")));
        return Column(Ui.Hint(Lang.T("Пісні правляться в редакторі (меню «Пісні»); тут — назви й видалення.", "Songs are edited in the editor (Songs menu); here — names and deletion.")), list);
    }

    // MARK: Фони й теки

    Control BuildBackgrounds()
    {
        var folders = new StackPanel { Spacing = 4 };
        void Fill()
        {
            folders.Children.Clear();
            foreach (var folder in _draft.PicturePaths)
            {
                var path = folder;
                folders.Children.Add(Ui.Row(Ui.Label(path), Ui.Button("×", () => { _draft.PicturePaths.Remove(path); Fill(); })));
            }
        }
        Fill();
        var add = Ui.Button("+ " + Lang.T("Додати теку…", "Add folder…"), async () =>
        {
            var picked = await StorageProvider.OpenFolderPickerAsync(new Avalonia.Platform.Storage.FolderPickerOpenOptions());
            var path = picked.FirstOrDefault()?.TryGetLocalPath();
            if (path != null && !_draft.PicturePaths.Contains(path)) { _draft.PicturePaths.Add(path); Fill(); }
        });
        var templates = new StackPanel { Spacing = 2 };
        foreach (var template in _state.Templates.Templates)
        {
            var name = template.Name;
            templates.Children.Add(Ui.Row(Ui.Label(name), Ui.Button("×", async () =>
            {
                if (!await Ui.Ask(this, Lang.T("Шаблон", "Template"), Lang.F("Видалити шаблон «{0}»?", "Delete the template “{0}”?", name), Lang.T("Видалити", "Delete"))) return;
                try { File.Delete(template.FilePath); if (Directory.Exists(template.Folder)) Directory.Delete(template.Folder, true); } catch { /* не видалилося */ }
                _state.ReloadTemplates();
                ((TabItem)_tabs.Items[4]!).Content = new ScrollViewer { Content = BuildBackgrounds(), Padding = new Thickness(6) };
            })));
        }
        foreach (var (file, reason) in _state.Templates.Failures) templates.Children.Add(Ui.Hint(file + ": " + reason));
        return Column(
            Ui.Label(Lang.T("Теки з картинками для вкладки «Зображення» і фонів", "Picture folders for the Pictures tab and backgrounds"), 13, true),
            Ui.Hint(Lang.F("Завжди читаються: {0} і {1}", "Always read: {0} and {1}", Paths.Backgrounds, Paths.Uploads)),
            folders, add,
            Ui.Label(Lang.T("Шаблони слайда (.sch) у теці даних", "Slide templates (.sch) in the data folder"), 13, true),
            Ui.Hint(Lang.F("Тека: {0}. Нові шаблони — «Файл» → ресурси (Templates.zip) або імпорт із теки VisioBible.", "Folder: {0}. New templates — File → resources (Templates.zip) or import from a VisioBible folder.", Paths.Templates)),
            templates);
    }

    // MARK: Показ

    Control BuildShow()
    {
        var transitions = new ComboBox { Width = 220 };
        foreach (var (key, title) in new[] { ("none", Lang.T("Без переходу", "No transition")), ("fade", Lang.T("Розчинення", "Fade")) })
            transitions.Items.Add(new ComboBoxItem { Content = title, Tag = key });
        transitions.SelectedIndex = _draft.ShowTransition == "none" ? 0 : 1;
        transitions.SelectionChanged += (_, _) => { if (transitions.SelectedItem is ComboBoxItem item) _draft.ShowTransition = (string)item.Tag!; };
        var easing = new ComboBox { Width = 220 };
        foreach (var (key, title) in new[] { ("linear", Lang.T("Рівномірно", "Linear")), ("easeInOut", Lang.T("Плавно", "Smooth")), ("easeOut", Lang.T("З уповільненням", "Ease out")), ("spring", Lang.T("Пружиною", "Spring")) })
            easing.Items.Add(new ComboBoxItem { Content = title, Tag = key });
        easing.SelectedIndex = Math.Max(0, new[] { "linear", "easeInOut", "easeOut", "spring" }.ToList().IndexOf(_draft.HideFadeEasing));
        easing.SelectionChanged += (_, _) => { if (easing.SelectedItem is ComboBoxItem item) _draft.HideFadeEasing = (string)item.Tag!; };
        return Column(
            Check(Lang.T("Зв'язати навігацію: стрілки гортають передпоказ і зал разом", "Link navigation: arrows page the preview and the hall together"), _draft.ArrowsLinked, v => _draft.ArrowsLinked = v),
            Check(Lang.T("«Активна»: стрілки й перегортання одразу виводять у зал", "“Active”: arrows and paging go straight to the hall"), _draft.ArrowsShowLive, v => _draft.ArrowsShowLive = v),
            Ui.Row(Ui.Label(Lang.T("Зміна слайда", "Slide change")), transitions, NumberField(Lang.T("тривалість, с", "duration, s"), _draft.ShowTransitionSeconds, v => _draft.ShowTransitionSeconds = v, 0, 3, 0.05)),
            Ui.Row(NumberField(Lang.T("Гасіння залу («Сховати», затемнення), с", "Hall fade-out (Hide, black), s"), _draft.HideFadeSeconds, v => _draft.HideFadeSeconds = v, 0, 5, 0.05), Ui.Label(Lang.T("крива", "curve")), easing),
            Check(Lang.T("Номери віршів на слайді — основний переклад", "Verse numbers on the slide — main translation"), _draft.ShowVerseNumbers, v => _draft.ShowVerseNumbers = v),
            Check(Lang.T("Номери віршів — другий переклад", "Verse numbers — second translation"), _draft.ShowSecondaryVerseNumbers, v => _draft.ShowSecondaryVerseNumbers = v),
            Check(Lang.T("Кожен вибраний вірш — зі свого рядка", "Each chosen verse starts a new line"), _draft.VersesOnOwnLines, v => _draft.VersesOnOwnLines = v),
            NumberField(Lang.T("Мінімальний відсоток заповнення для нової сторінки", "Minimum fill percent for a new page"), _draft.PercentFillingPage, v => _draft.PercentFillingPage = (int)v, 0, 100, 1,
                Lang.T("Хвіст, що заповнить слайд менше, окремою сторінкою не робиться", "A tail that would fill less of the slide does not become a separate page")));
    }

    // MARK: Адреса й пісні

    Control BuildAddress()
    {
        Control Length(string title, bool shortNow, Action<bool> set)
        {
            var box = new ComboBox { Width = 160 };
            box.Items.Add(new ComboBoxItem { Content = Lang.T("Повна назва", "Full name") });
            box.Items.Add(new ComboBoxItem { Content = Lang.T("Скорочення", "Abbreviation") });
            box.SelectedIndex = shortNow ? 1 : 0;
            box.SelectionChanged += (_, _) => set(box.SelectedIndex == 1);
            return Ui.Row(Ui.Label(title), box);
        }
        return Column(
            Ui.Label(Lang.T("Адреса місця Писання на слайді", "Scripture reference on the slide"), 13, true),
            Ui.Hint(Lang.T("Об'єднана — коли на слайді два переклади: «Буття(Gen.) 1:1». Окрема — один переклад.", "Combined — with two translations on the slide: “Буття(Gen.) 1:1”. Separate — one translation.")),
            Length(Lang.T("Об'єднана: основний переклад", "Combined: main translation"), _draft.RefAllMainShort, v => _draft.RefAllMainShort = v),
            Length(Lang.T("Об'єднана: другий переклад", "Combined: second translation"), _draft.RefAllSecShort, v => _draft.RefAllSecShort = v),
            Length(Lang.T("Окрема: основний переклад", "Separate: main translation"), _draft.RefMainShort, v => _draft.RefMainShort = v),
            Length(Lang.T("Окрема: другий переклад", "Separate: second translation"), _draft.RefSecShort, v => _draft.RefSecShort = v),
            Ui.Label(Lang.T("Назва пісні в списку", "Song title in the list"), 13, true),
            Check(Lang.T("Номер у збірнику", "Number in the collection"), _draft.SongNumberInCollection, v => _draft.SongNumberInCollection = v),
            Check(Lang.T("Крапка після номера", "Dot after the number"), _draft.SongDotAfterNumber, v => _draft.SongDotAfterNumber = v),
            Check(Lang.T("Номер у дужках", "Number in brackets"), _draft.SongNumberInBrackets, v => _draft.SongNumberInBrackets = v),
            Check(Lang.T("Номер пісні в адресі слайда", "Song number in the slide address"), _draft.SongNumberPP, v => _draft.SongNumberPP = v),
            TextField(Lang.T("Що дописати після останньої частини пісні (SongsEndChunkPostText)", "What to add after the last song part (SongsEndChunkPostText)"), _draft.SongsEndMarker, v => _draft.SongsEndMarker = v, 120));
    }

    // MARK: Гарячі клавіші

    Control BuildHotkeys()
    {
        var sets = new ComboBox { Width = 220 };
        foreach (var name in _hotkeySets.Order) sets.Items.Add(name);
        sets.SelectedItem = _hotkeySets.Order.Contains(_draft.HotkeySet) ? _draft.HotkeySet : _hotkeySets.PreferredSetName;
        var list = new StackPanel { Spacing = 4 };
        void Fill()
        {
            list.Children.Clear();
            var setName = sets.SelectedItem as string ?? "";
            if (!_hotkeySets.Sets.TryGetValue(setName, out var set)) return;
            foreach (var action in HotkeyAction.All)
            {
                var key = action.IniKey;
                var box = new TextBox { Text = set.TryGetValue(key, out var v) ? v : "", Width = 160, IsReadOnly = true, Watermark = Lang.T("натисніть клавішу", "press a key") };
                ToolTip.SetTip(box, Lang.T("Клацніть і натисніть сполучення; Backspace — прибрати", "Click and press a combination; Backspace — clear"));
                box.KeyDown += (_, e) =>
                {
                    e.Handled = true;
                    if (e.Key == Avalonia.Input.Key.Back) { set.Remove(key); box.Text = ""; return; }
                    var hotkey = Hotkey.From(e.Key, e.KeyModifiers);
                    if (hotkey == null) return;
                    var busy = set.FirstOrDefault(p => p.Key != key && p.Value == hotkey.Text);
                    if (busy.Key != null) { box.Text = hotkey.Text + " — " + Lang.T("зайнято: ", "taken: ") + (HotkeyAction.All.FirstOrDefault(a => a.IniKey == busy.Key)?.Title ?? busy.Key); return; }
                    set[key] = hotkey.Text;
                    box.Text = hotkey.Text;
                };
                list.Children.Add(Ui.Row(new TextBlock { Text = action.Title, Width = 320, VerticalAlignment = VerticalAlignment.Center }, box));
            }
        }
        sets.SelectionChanged += (_, _) => { _draft.HotkeySet = sets.SelectedItem as string ?? ""; Fill(); };
        var copy = Ui.Button(Lang.T("Новий набір із цього…", "New set from this one…"), async () =>
        {
            var name = await Ui.Prompt(this, Lang.T("Новий набір клавіш", "New key set"), Lang.T("Назва набору:", "Set name:"), "Мій набір");
            if (string.IsNullOrWhiteSpace(name) || _hotkeySets.Sets.ContainsKey(name)) return;
            var from = sets.SelectedItem as string ?? "";
            _hotkeySets.Replace(name, _hotkeySets.Hotkeys(from));
            sets.Items.Add(name);
            sets.SelectedItem = name;
        });
        var reset = Ui.Button(Lang.T("Умовчання VisioBible", "VisioBible defaults"), () =>
        {
            _hotkeySets = HotkeySets.FactoryDefault();
            sets.Items.Clear();
            foreach (var name in _hotkeySets.Order) sets.Items.Add(name);
            sets.SelectedItem = _hotkeySets.PreferredSetName;
            Fill();
        });
        Fill();
        _draft.HotkeySet = sets.SelectedItem as string ?? "";
        return Column(Ui.Row(Ui.Label(Lang.T("Набір клавіш", "Key set")), sets, copy, reset),
                      Ui.Hint(Lang.T("Ті самі набори, що в hotkeys.ini VisioBible: [VB Version 2.2], 2.3, 2.4. Файл — у теці даних.", "The same sets as in VisioBible's hotkeys.ini: [VB Version 2.2], 2.3, 2.4. The file is in the data folder.")),
                      list);
    }

    // MARK: Пульт

    Control BuildRemote()
    {
        var pult = _state.Pult;
        var status = Ui.Hint(pult == null ? "" : (pult.IsRunning ? Lang.F("Зараз: пульт слухає порт {0}; {1}", "Now: the remote listens on port {0}; {1}", pult.Port, pult.MdnsName ?? "") : Lang.T("Зараз: пульт не слухає", "Now: the remote is not listening") + (pult.Error != null ? " — " + pult.Error : "")));
        return Column(
            Ui.Label(Lang.T("Телефон, планшет, «Проповідник Слова»", "Phone, tablet, Propovidnyk Slova"), 13, true),
            Check(Lang.T("Увімкнути пульт", "Enable the remote"), _draft.RemoteEnabled, v => _draft.RemoteEnabled = v),
            Ui.Row(NumberField(Lang.T("Порт", "Port"), _draft.RemotePort, v => _draft.RemotePort = (int)v, 1, 65535), TextField(Lang.T("PIN (порожньо — без PIN)", "PIN (empty — none)"), _draft.RemotePin, v => _draft.RemotePin = v.Trim(), 120)),
            status,
            Ui.Label(Lang.T("Пульт у браузері", "Remote in a browser"), 13, true),
            Check(Lang.T("Увімкнути сторінку для браузера", "Enable the browser page"), _draft.WebEnabled, v => _draft.WebEnabled = v),
            Ui.Row(NumberField(Lang.T("Порт", "Port"), _draft.WebPort, v => _draft.WebPort = (int)v, 1, 65535), TextField(Lang.T("Пароль (порожньо — без)", "Password (empty — none)"), _draft.WebPassword, v => _draft.WebPassword = v, 140, true)),
            Ui.Row(TextField(Lang.T("Ім'я в мережі (….local)", "Network name (….local)"), _draft.WebName, v => _draft.WebName = v.Trim(), 160)),
            Check(Lang.T("Відкривати й без номера порту (ще й порт 80)", "Also open without a port number (port 80 too)"), _draft.WebNoPort, v => _draft.WebNoPort = v),
            Check(Lang.T("Лише перегляд: сторінка бачить зал, але не керує", "View only: the page sees the hall but does not control"), _draft.WebViewOnly, v => _draft.WebViewOnly = v),
            Ui.Label(Lang.T("Указка", "Pointer"), 13, true),
            Ui.Row(ColorField(Lang.T("Колір", "Colour"), _draft.PointerColour, h => _draft.PointerColour = h),
                   NumberField(Lang.T("Розмір, частка висоти", "Size, share of height"), _draft.PointerSize, v => _draft.PointerSize = v, 0.01, 0.3, 0.01),
                   NumberField(Lang.T("Яскравість", "Opacity"), _draft.PointerOpacity, v => _draft.PointerOpacity = v, 0.1, 1, 0.05)),
            Ui.Hint(Lang.T("Брандмауер Windows при першому запуску питає дозвіл на вхідні з'єднання — дозвольте для приватних мереж, інакше телефон не знайде програму.",
                           "Windows Firewall asks for permission for incoming connections at the first start — allow it for private networks, otherwise the phone will not find the program.")));
    }

    // MARK: Мова

    Control BuildLanguage()
    {
        var box = new ComboBox { Width = 260 };
        foreach (var (code, name) in new[] { ("auto", Lang.T("Авто (за мовою Windows)", "Auto (Windows language)")), ("uk", "Українська"), ("en", "English") })
            box.Items.Add(new ComboBoxItem { Content = name, Tag = code });
        box.SelectedIndex = Math.Max(0, new[] { "auto", "uk", "en" }.ToList().IndexOf(_draft.Language));
        box.SelectionChanged += (_, _) => { if (box.SelectedItem is ComboBoxItem item) _draft.Language = (string)item.Tag!; };
        return Column(Ui.Row(Ui.Label(Lang.T("Мова інтерфейсу", "Interface language")), box),
                      Ui.Hint(Lang.T("«Авто»: українська для української й російської Windows, інакше англійська.", "“Auto”: Ukrainian for Ukrainian and Russian Windows, otherwise English.")),
                      NumberField(Lang.T("Перевіряти оновлення раз на (днів)", "Check for updates every (days)"), _draft.UpdateIntervalDays, v => _draft.UpdateIntervalDays = (int)v, 1, 90),
                      Ui.Hint(Lang.F("Тека даних: {0}", "Data folder: {0}", Paths.Home)));
    }
}
