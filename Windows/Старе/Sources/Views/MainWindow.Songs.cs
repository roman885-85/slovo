// =============================================================================
//  MainWindow.Songs.cs — робочі області «Пісні», «Текст», «Зображення»
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Slovo.Views;

public sealed partial class MainWindow
{
    // Пісні
    readonly ComboBox _songBooks = new() { HorizontalAlignment = HorizontalAlignment.Stretch };
    readonly TextBox _songFilter = new();
    readonly ListBox _songsList = new();
    readonly ListBox _partsList = new();
    readonly TextBlock _songTitle = new() { FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4, 4) };
    readonly TextBlock _songText = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(4) };
    bool _fillingSongs;
    List<SongSlide> _shownSlides = new();

    Control BuildSongs()
    {
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("2*,4,2*,4,3*") };

        var left = new DockPanel();
        _songBooks.SelectionChanged += (_, _) =>
        {
            if (_fillingSongs || _songBooks.SelectedItem is not ComboBoxItem item || item.Tag is not string id) return;
            _state.SelectSongBook(id);
        };
        DockPanel.SetDock(_songBooks, Dock.Top);
        left.Children.Add(_songBooks);
        _songFilter.Watermark = Lang.T("Номер, слова назви чи тексту", "Number, words of the title or text");
        _songFilter.Margin = new Thickness(0, 4);
        _songFilter.TextChanged += (_, _) => { if (!_fillingSongs) _state.FilterSongs(_songFilter.Text ?? ""); };
        _songFilter.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter && _state.SongList.Count > 0) { _state.SelectSong(_state.SongList[0].Index, e.KeyModifiers.HasFlag(KeyModifiers.Control)); e.Handled = true; }
        };
        DockPanel.SetDock(_songFilter, Dock.Top);
        left.Children.Add(_songFilter);
        var songButtons = Ui.Row(
            Ui.Button("+ " + Lang.T("Пісню в План", "Song to Plan"), () => { var item = _state.PlanItemForWholeSong(); if (item != null) _state.AddToPlan(item); }, Lang.T("Додати пісню цілком у План", "Add the whole song to the Plan")),
            Ui.Button(Lang.T("Редагувати…", "Edit…"), () => _ = OpenSongEditor(false), Lang.T("Редагувати пісню", "Edit song")));
        songButtons.Margin = new Thickness(0, 0, 0, 4);
        DockPanel.SetDock(songButtons, Dock.Bottom);
        left.Children.Add(songButtons);
        _songsList.ItemTemplate = new FuncDataTemplate<Song>((song, _) => new TextBlock { Text = song == null ? "" : _state.SongListTitle(song), Margin = new Thickness(4, 1), TextTrimming = TextTrimming.CharacterEllipsis });
        _songsList.SelectionChanged += (_, _) =>
        {
            if (_fillingSongs || _songsList.SelectedItem is not Song song) return;
            _state.SelectSong(song.Index, false);
        };
        _songsList.DoubleTapped += (_, _) => { if (_songsList.SelectedItem is Song) _state.ShowCurrent(); };
        _fontLists.Add(_songsList);
        left.Children.Add(_songsList);
        grid.Children.Add(left);
        grid.Children.Add(SplitterAll(1));

        // Частини: кожен слайд пісні — рядок із назвою частини й сторінкою.
        var middle = new DockPanel();
        var partsTitle = Ui.Label(Lang.T("Частини пісні", "Song parts"), 13, true);
        partsTitle.Margin = new Thickness(4, 4);
        DockPanel.SetDock(partsTitle, Dock.Top);
        middle.Children.Add(partsTitle);
        _partsList.ItemTemplate = new FuncDataTemplate<SongSlide>((slide, _) =>
        {
            if (slide == null) return new TextBlock();
            var row = new DockPanel { Margin = new Thickness(2, 1) };
            var head = slide.Slide.Reference.Length > 0 ? slide.Slide.Reference : Lang.T("Частина", "Part") + " " + (slide.PartIndex + 1);
            var label = new Border
            {
                Background = slide.Color is RGBA c ? new SolidColorBrush(Color.FromRgb((byte)(c.R * 255), (byte)(c.G * 255), (byte)(c.B * 255))) : Ui.Line,
                CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 2), Margin = new Thickness(0, 0, 6, 0),
                Child = new TextBlock { Text = head, FontSize = 11, FontWeight = FontWeight.SemiBold, Foreground = Brushes.Black },
            };
            DockPanel.SetDock(label, Dock.Left);
            row.Children.Add(label);
            row.Children.Add(new TextBlock { Text = slide.Slide.MainText.Replace("\n", " / "), TextTrimming = TextTrimming.CharacterEllipsis, Foreground = Ui.Muted });
            return row;
        });
        _partsList.SelectionChanged += (_, _) =>
        {
            if (_fillingSongs || _partsList.SelectedIndex < 0) return;
            _state.SelectSongSlide(_partsList.SelectedIndex, false);
        };
        _partsList.DoubleTapped += (_, _) => { if (_partsList.SelectedIndex >= 0) _state.SelectSongSlide(_partsList.SelectedIndex, true); };
        _partsList.KeyDown += (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) { _state.ShowCurrent(); e.Handled = true; } };
        _fontLists.Add(_partsList);
        middle.Children.Add(_partsList);
        Grid.SetColumn(middle, 2);
        grid.Children.Add(middle);
        grid.Children.Add(SplitterAll(3));

        // Текст пісні цілком.
        var right = new DockPanel();
        DockPanel.SetDock(_songTitle, Dock.Top);
        right.Children.Add(_songTitle);
        right.Children.Add(new ScrollViewer { Content = _songText });
        _fontLists.Add(_songText);
        Grid.SetColumn(right, 4);
        grid.Children.Add(right);
        return grid;
    }

    static GridSplitter SplitterAll(int column)
    {
        var splitter = new GridSplitter { Background = Brushes.Transparent, Width = 4 };
        Grid.SetColumn(splitter, column);
        return splitter;
    }

    void RefreshSongBooks()
    {
        _fillingSongs = true;
        try
        {
            _songBooks.Items.Clear();
            var selected = -1;
            foreach (var book in _state.SongBooks)
            {
                _songBooks.Items.Add(new ComboBoxItem { Content = book.Name, Tag = book.Id });
                if (book.Id == _state.SongBookId) selected = _songBooks.Items.Count - 1;
            }
            _songBooks.SelectedIndex = selected;
            if (_songFilter.Text != _state.SongQuery) _songFilter.Text = _state.SongQuery;
        }
        finally { _fillingSongs = false; }
    }

    void RefreshSongList()
    {
        _fillingSongs = true;
        try
        {
            _songsList.ItemsSource = _state.SongList.ToList();
            var at = _state.SongIndex is int index ? _state.SongList.FindIndex(s => s.Index == index) : -1;
            _songsList.SelectedIndex = at;
            if (at >= 0) _songsList.ScrollIntoView(at);
        }
        finally { _fillingSongs = false; }
    }

    void RefreshParts()
    {
        _fillingSongs = true;
        try
        {
            _shownSlides = _state.SongSlides.ToList();
            _partsList.ItemsSource = _shownSlides;
            _partsList.SelectedIndex = _state.SongSlideIndex;
            if (_state.SongSlideIndex >= 0) _partsList.ScrollIntoView(_state.SongSlideIndex);
            var song = _state.CurrentSong;
            _songTitle.Text = song == null ? "" : _state.SongListTitle(song);
            _songText.Text = string.Join("\n\n", _state.Parts.Select(p => (p.Kind.Trim().Length > 0 ? p.Kind.Trim() + "\n" : "") + p.Text.Trim()));
        }
        finally { _fillingSongs = false; }
    }

    // MARK: Текст

    readonly TextBox _textTitle = new();
    readonly TextBox _textBody = new() { AcceptsReturn = true, TextWrapping = TextWrapping.Wrap, VerticalContentAlignment = VerticalAlignment.Top };
    readonly TextBlock _textPages = new() { Foreground = Ui.Muted, VerticalAlignment = VerticalAlignment.Center };
    bool _fillingText;

    Control BuildText()
    {
        var panel = new DockPanel { Margin = new Thickness(0, 4) };
        _textTitle.Watermark = Lang.T("Заголовок (на місці адреси)", "Heading (in place of the address)");
        _textTitle.TextChanged += (_, _) => { if (!_fillingText) _state.SetText(_textTitle.Text ?? "", _textBody.Text ?? ""); };
        DockPanel.SetDock(_textTitle, Dock.Top);
        panel.Children.Add(_textTitle);
        var buttons = Ui.Row(
            Ui.Button(Lang.T("Показати в залі", "Show in the hall"), _state.ShowText, Lang.T("Текст — на проектор (F5)", "Text — to the projector (F5)"), accent: true),
            Ui.Button("◀", () => _state.StepTextPage(-1, _state.IsLive), Lang.T("Попередня сторінка", "Previous page")),
            Ui.Button("▶", () => _state.StepTextPage(1, _state.IsLive), Lang.T("Наступна сторінка", "Next page")),
            _textPages,
            Ui.Button("+ " + Lang.T("У План", "To Plan"), _state.AddCurrentToPlan, Lang.T("Додати текст у План", "Add the text to the Plan")),
            Ui.Button(Lang.T("Очистити", "Clear"), () => { _state.ClearText(); }, Lang.T("Очистити заголовок і текст", "Clear the heading and the text")));
        buttons.Margin = new Thickness(0, 6, 0, 0);
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(buttons);
        _textBody.Watermark = Lang.T("Текст оголошення. Порожній рядок — межа сторінки; довгий текст ділиться на сторінки сам.", "Announcement text. A blank line is a page break; a long text is split into pages by itself.");
        _textBody.Margin = new Thickness(0, 6, 0, 0);
        _textBody.TextChanged += (_, _) => { if (!_fillingText) _state.SetText(_textTitle.Text ?? "", _textBody.Text ?? ""); };
        _fontLists.Add(_textBody);
        panel.Children.Add(_textBody);
        return panel;
    }

    void RefreshText()
    {
        _fillingText = true;
        try
        {
            if (_textTitle.Text != _state.Text.Title) _textTitle.Text = _state.Text.Title;
            if (_textBody.Text != _state.Text.Body) _textBody.Text = _state.Text.Body;
            _textPages.Text = _state.TextPages.Count > 1 ? Lang.F("сторінка {0} з {1}", "page {0} of {1}", _state.TextPageIndex + 1, _state.TextPages.Count) : "";
        }
        finally { _fillingText = false; }
    }

    // MARK: Зображення

    readonly ListBox _picturesList = new();
    readonly Dictionary<string, Bitmap> _thumbnails = new();
    bool _fillingPictures;

    Control BuildPictures()
    {
        var panel = new DockPanel { Margin = new Thickness(0, 4) };
        var buttons = Ui.Row(
            Ui.Button(Lang.T("Показати в залі", "Show in the hall"), () => { if (_state.PictureIndex is int i) _state.ShowPicture(i); }, accent: true),
            Ui.Button("+ " + Lang.T("Додати картинку…", "Add picture…"), () => _ = AddPictures()),
            Ui.Button(Lang.T("Теки з картинками…", "Picture folders…"), () => _ = OpenSettings(), Lang.T("Теки задаються в Параметрах → Фони й теки", "Folders are set in Settings → Backgrounds and folders")),
            Ui.Button("+ " + Lang.T("У План", "To Plan"), _state.AddCurrentToPlan),
            Ui.Hint(Lang.T("Клацання — у передпоказ, подвійне — у зал. Теки: BackGrounds і Пульт у теці даних плюс свої з Параметрів.", "Click — preview, double-click — hall. Folders: BackGrounds and Пульт in the data folder plus your own from Settings.")));
        DockPanel.SetDock(buttons, Dock.Top);
        panel.Children.Add(buttons);
        _picturesList.ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel { Orientation = Orientation.Horizontal });
        _picturesList.ItemTemplate = new FuncDataTemplate<string>((path, _) =>
        {
            if (path == null) return new TextBlock();
            var card = new StackPanel { Width = 170, Margin = new Thickness(4) };
            var image = new Image { Width = 160, Height = 90, Stretch = Stretch.Uniform };
            image.Source = Thumbnail(path);
            card.Children.Add(new Border { Child = image, Background = Brushes.Black, CornerRadius = new CornerRadius(4) });
            card.Children.Add(new TextBlock { Text = Path.GetFileNameWithoutExtension(path), FontSize = 11, TextTrimming = TextTrimming.CharacterEllipsis, HorizontalAlignment = HorizontalAlignment.Center });
            return card;
        });
        _picturesList.SelectionChanged += (_, _) => { if (!_fillingPictures && _picturesList.SelectedIndex >= 0) _state.SelectPicture(_picturesList.SelectedIndex); };
        _picturesList.DoubleTapped += (_, _) => { if (_picturesList.SelectedIndex >= 0) _state.ShowPicture(_picturesList.SelectedIndex); };
        panel.Children.Add(new ScrollViewer { Content = _picturesList });
        return panel;
    }

    Bitmap? Thumbnail(string path)
    {
        if (_thumbnails.TryGetValue(path, out var cached)) return cached;
        try
        {
            var skia = SlideRenderer.Image(path);
            if (skia == null) return null;
            using var small = skia.Resize(new SkiaSharp.SKImageInfo(320, Math.Max(1, 320 * skia.Height / Math.Max(1, skia.Width))), SkiaSharp.SKFilterQuality.Medium);
            if (small == null) return null;
            var bitmap = Bitmaps.ToAvalonia(small);
            if (_thumbnails.Count > 200) { foreach (var b in _thumbnails.Values) b.Dispose(); _thumbnails.Clear(); }
            _thumbnails[path] = bitmap;
            return bitmap;
        }
        catch { return null; }
    }

    void RefreshPictures()
    {
        _fillingPictures = true;
        try
        {
            var current = _picturesList.ItemsSource as List<string>;
            if (current == null || !current.SequenceEqual(_state.Pictures)) _picturesList.ItemsSource = _state.Pictures.ToList();
            _picturesList.SelectedIndex = _state.PictureIndex ?? -1;
        }
        finally { _fillingPictures = false; }
    }

    async System.Threading.Tasks.Task AddPictures()
    {
        var files = await StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Lang.T("Картинки", "Pictures"), AllowMultiple = true,
            FileTypeFilter = new[] { new FilePickerFileType(Lang.T("Картинки", "Pictures")) { Patterns = new[] { "*.jpg", "*.jpeg", "*.png", "*.bmp", "*.gif", "*.webp" } } },
        });
        string? last = null;
        foreach (var file in files)
        {
            var path = file.TryGetLocalPath();
            if (path != null) last = _state.AddPicture(path, false) ?? last;
        }
        if (last != null) _state.Mode = "pictures";
    }
}
