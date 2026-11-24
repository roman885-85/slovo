// =============================================================================
//  MediaWorkspace.cs — вкладка «Медіа»: список файлів і плеєр (16)
// =============================================================================
//  За NativeMediaWorkspace і NativeMediaPanel Mac 1.3.9. Ліворуч — список файлів
//  (+ − ×, «Медіафайли: заставки, відео»): на служінні файлів кілька — заставка,
//  ролик до проповіді, гімн, — і ходити по кожен у вікно вибору не можна.
//  Праворуч — плеєр: відкрити файл чи адресу, автозапуск, «відео на екран»,
//  звукова доріжка; кадр 16:9 (файл можна перетягнути сюди), повзунок місця,
//  кнопки «на початок / назад 5 с / грати / зупинити / вперед 5 с / у кінець»,
//  повтор, «без звуку», гучність і рядок стану.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Platform;
using Avalonia.Platform.Storage;
using Avalonia.Skia;
using Slovo.Core;

namespace Slovo.App;

public sealed class MediaWorkspace : LayoutPanel, IRowSource
{
    static MediaWorkspace? _shared;
    public static MediaWorkspace Shared => _shared ??= new MediaWorkspace(AppState.Shared);

    static string T(string text, params object[] args) => Captions.T(text, args);
    static string Message(string key, string fallback) => Captions.FormCaption(key, "MainForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "MainForm") ?? Captions.T(fallback);

    readonly AppState _state;
    readonly MediaPlayerModel _media;
    readonly RowList _list;
    readonly List<PushButton> _tools = new();
    readonly BottomCaption _listCaption = new() { FontSize = 11, Weight = FontWeight.SemiBold };
    readonly WidthGrip _grip = new();
    readonly MediaPanel _panel;
    int? _selected;
    const string ListWidthKey = "mediaListWidth";
    const double MinimumListWidth = 250;

    MediaWorkspace(AppState state)
    {
        _state = state;
        _media = state.Media;
        _list = new RowList(new ListMetrics { LeadWidth = 30 }, 13) { Source = this };
        _list.SetUniformHeight(26);
        // Одиночне клацання лише виділяє: файл на служінні відкривають навмисно.
        _list.OnSelect = (_, active, cause) => { if (cause != SelectCause.Code) _selected = active; };
        _list.OnActivate = position => _media.OpenFromPlaylist(position);
        PushButton Tool(string symbol, Action action)
        {
            var b = new PushButton("", symbol) { Margin = 0.5, Pressed = action, SymbolSize = 14 };
            _tools.Add(b);
            return b;
        }
        // Посилання (ролики YouTube, потоки) — у той самий список, що й файли; ↑/↓ — свій
        // порядок показу (власник: «как в минусовках»).
        Tool("plus", () => _ = AddFiles());
        Tool("link.badge.plus", AddLinks);
        Tool("arrow.up", () => Move(-1));
        Tool("arrow.down", () => Move(1));
        Tool("minus", RemoveSelected);
        Tool("xmark", () => { _media.ClearPlaylist(); _selected = null; Reload(); });
        _panel = new MediaPanel(state);
        foreach (Control c in _tools.Cast<Control>().Concat(new Control[] { _listCaption, _list, _grip, _panel })) Children.Add(c);
        _grip.OnDrag = delta => { Widths.Set(ListWidthKey, _list.Bounds.Width + delta, MinimumListWidth, Math.Max(MinimumListWidth, Bounds.Width * 0.6)); InvalidateArrange(); };
        _grip.OnReset = () => { Widths.Reset(ListWidthKey); InvalidateArrange(); };
        // Список міняється й повз нас: перетягування у вікно, Ctrl+M, пульт.
        _media.Changed += Reload;
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        ApplyCaptions();
        Reload();
    }

    void ApplyCaptions()
    {
        _listCaption.Text = T("Медиафайлы: заставки, видео");
        ToolTip.SetTip(_grip, T("Потяните — ширина списка; двойной щелчок — как было"));
        ToolTip.SetTip(_tools[0], Captions.Caption("PSBOpenVideo", T("Открыть медиа-файл")));
        ToolTip.SetTip(_tools[1], T("Добавить ссылки: ролики YouTube или потоки — по одной в строке"));
        ToolTip.SetTip(_tools[2], T("Поднять выше в списке"));
        ToolTip.SetTip(_tools[3], T("Опустить ниже в списке"));
        ToolTip.SetTip(_tools[4], T("Убрать из списка"));
        ToolTip.SetTip(_tools[5], T("Очистить список"));
    }

    void Reload()
    {
        _list.Reload();
        // Вибране людиною (щойно пересунуте ↑/↓) не перескакує назад на відкрите.
        var active = _selected is { } chosen && chosen < _media.Playlist.Count ? chosen : _media.PlaylistIndex;
        _list.SetSelection(active is { } a ? new[] { a } : Array.Empty<int>(), active);
    }

    void AddLinks()
    {
        Prompt.AskLines(T("Добавить ссылки"), T("Ролики YouTube или адреса потоков — по одной ссылке в строке. Они встанут в список, как файлы."),
                        text => { _media.AddLinks(text); Reload(); });
    }

    /// Пересунути вибраний (чи відкритий) пункт на одну позицію — виділення їде з ним.
    void Move(int offset)
    {
        if ((_selected ?? _media.PlaylistIndex) is not { } position) return;
        var target = position + offset;
        if (target < 0 || target >= _media.Playlist.Count) return;
        _selected = target;
        _media.MovePlaylistItem(position, offset);
        Reload();
    }

    async Task AddFiles()
    {
        if (await MediaPanel.ChooseFiles(this) is not { Count: > 0 } files) return;
        _media.AddToPlaylist(files);
        Reload();
    }

    void RemoveSelected()
    {
        if ((_selected ?? _media.PlaylistIndex) is not { } position) return;
        _media.RemoveFromPlaylist(position);
        _selected = null;
        Reload();
    }

    protected override void Arrangement(Size size)
    {
        const double gap = 8;
        var listWidth = Widths.Value(ListWidthKey, Math.Max(MinimumListWidth, Math.Min(340, size.Width * 0.26)), MinimumListWidth, Math.Max(MinimumListWidth, size.Width * 0.6));
        // Смуга кнопок списку 28 заввишки; кнопки — рамки 20 з 4.
        var x = gap;
        foreach (var tool in _tools) { Place(tool, new Rect(x + 1, gap + 4, 29, 21)); x += 35.5; }
        Place(_listCaption, new Rect(x + 1, gap + 7, Math.Max(0, gap + listWidth - x - 1), 16));
        var top = gap + 28 + gap;
        Place(_list, new Rect(gap, top, listWidth, Math.Max(0, size.Height - top - gap)));
        Place(_grip, new Rect(gap + listWidth, gap, 6, Math.Max(0, size.Height - gap * 2)));
        var hostX = gap + listWidth + 6 + gap;
        Place(_panel, new Rect(hostX, gap, Math.Max(0, size.Width - hostX - gap), Math.Max(0, size.Height - gap * 2)));
    }

    // --- Список ---------------------------------------------------------------------

    public int RowCount => _media.Playlist.Count;
    public Row RowAt(int index) => new(_media.PlaylistCaption(_media.Playlist[index]), (index + 1).ToString()) { SingleLine = true };
}

/// Панель плеєра (NativeMediaPanel).
public sealed class MediaPanel : LayoutPanel
{
    static string T(string text, params object[] args) => Captions.T(text, args);
    static string Message(string key, string fallback) => Captions.FormCaption(key, "MainForm", fallback);
    static string Hint(string key, string fallback) => Captions.FormHint(key, "MainForm") ?? Captions.T(fallback);

    readonly AppState _state;
    readonly MediaPlayerModel _media;
    readonly PaintLayer _backdrop;
    readonly PushButton _open, _url, _autoPlay, _toScreen, _tracks, _play, _repeat, _next, _mute;
    readonly PushButton[] _transport;
    readonly BottomCaption _title = new() { FontSize = 10 };
    readonly BottomCaption _elapsed = new() { FontSize = 10 }, _total = new() { FontSize = 10, Align = TextAlignment.Right };
    readonly BottomCaption _volumeLabel = new() { FontSize = 10 }, _status = new() { FontSize = 10 };
    readonly MacSlider _position = new() { KnobSize = 20, Step = 5 }, _volume = new() { KnobSize = 14, Step = 0.05 };
    readonly VideoBox _box;
    /// Шеврон списку доріжок (кнопка, що випадає, — значок і стрілка, як pullsDown на Mac).
    readonly PaintLayer _tracksChevron;

    public MediaPanel(AppState state)
    {
        _state = state;
        _media = state.Media;
        _backdrop = new PaintLayer((g, b) => g.DrawRectangle(Palette.Brush(Palette.ControlBackground), null, b, 4, 4));
        PushButton Command(string symbol, Action action) => new("", symbol) { Margin = 0.5, Pressed = action, SymbolSize = 14 };
        _open = Command("folder", () => _ = OpenFiles());
        _url = Command("link", OpenUrl);
        _autoPlay = Command("play.circle", () => { _media.AutoPlay = !_media.AutoPlay; Refresh(); });
        _toScreen = Command("tv", () => { _media.VideoToScreen = !_media.VideoToScreen; Refresh(); });
        _tracks = Command("waveform", ChooseTrack);
        _tracks.ContentOffset = -5;
        _transport = new[]
        {
            Command("backward.end.fill", _media.ToBegin),
            Command("gobackward.5", () => _media.Shuttle(-1)),
            _play = Command("play.fill", _media.PlayPause),
            Command("stop.fill", _media.Stop),
            Command("goforward.5", () => _media.Shuttle(1)),
            Command("forward.end.fill", _media.ToEnd),
        };
        _repeat = Command("repeat", () => { _media.Repeats = !_media.Repeats; Refresh(); });
        // «Після кінця — наступний зі списку», як у фонограм.
        _next = Command("text.line.first.and.arrowtriangle.forward", () => { _media.PlaysNext = !_media.PlaysNext; Refresh(); });
        _mute = Command("speaker.wave.2.fill", () => { _media.IsMuted = !_media.IsMuted; Refresh(); });
        _box = new VideoBox(_media);
        _tracksChevron = new PaintLayer((g, b) => Icons.Draw(g, "chevron.down", new Rect(b.Width - 13, b.Height / 2 - 3.5, 7, 7),
                                                               _tracks.IsEffectivelyEnabled ? Palette.Label : Palette.DisabledText));
        _title.Color = () => Palette.SecondaryLabel;
        _elapsed.Color = _total.Color = _volumeLabel.Color = () => Palette.SecondaryLabel;
        _position.Minimum = 0;
        _position.DragStarted += _media.BeginScrub;
        _position.ValueChanged += value => _media.Scrub(value);
        _position.DragEnded += _media.EndScrub;
        _volume.Minimum = 0; _volume.Maximum = 1;
        // Ширина повзунка гучності — своя: у широкому вікні він тягнувся на пів метра.
        _volume.ValueChanged += value => _media.Volume = value;
        foreach (Control c in new Control[] { _backdrop, _open, _url, _autoPlay, _toScreen, _tracks, _tracksChevron, _title, _box, _elapsed, _position, _total }
                     .Concat(_transport).Concat(new Control[] { _repeat, _next, _mute, _volumeLabel, _volume, _status }))
            Children.Add(c);
        _media.Changed += Refresh;
        Signals.Shared.Subscribe(Signals.Kind.Language, () => { ApplyHints(); Refresh(); });
        ApplyHints();
        Refresh();
    }

    void ApplyHints()
    {
        ToolTip.SetTip(_open, Hint("PSBOpenVideo", "Открыть медиа-файл"));
        ToolTip.SetTip(_url, Hint("PSBOpenVideoUrl", "Открыть URL с медиа контентом"));
        ToolTip.SetTip(_autoPlay, Hint("PngSBAutoPlay", "Воспроизвести после открытия (Вкл/Выкл)"));
        ToolTip.SetTip(_toScreen, Hint("PngSBVideoToScreen", "Отображать видео на экране проектора (Вкл/Выкл)"));
        ToolTip.SetTip(_tracks, Hint("PSBSelectAudioStreams", "Выбрать звуковую дорожку"));
        var keys = new[] { ("PSBVideoToBegin", "В начало"), ("PSBVideoSmallShuttleLeft", "Перемотать назад"), ("PSBVideoPlayPause", "Воспроизвести/пауза"),
                           ("PSBVideoStop", "Остановить"), ("PSBVideoSmallShuttleRight", "Перемотать вперед"), ("PSBVideoToEnd", "В конец") };
        for (var i = 0; i < _transport.Length; i++) ToolTip.SetTip(_transport[i], Hint(keys[i].Item1, keys[i].Item2));
        ToolTip.SetTip(_repeat, Hint("PSBVideoRepeate", "Повтор"));
        ToolTip.SetTip(_next, T("После окончания играть следующий файл или ролик из списка"));
        ToolTip.SetTip(_mute, Hint("PngSBAudioMute", "Без звука"));
        ToolTip.SetTip(_position, T("Место воспроизведения: потяните, чтобы перемотать"));
        ToolTip.SetTip(_volume, T("Громкость"));
    }

    void Refresh()
    {
        var hasFile = _media.MediaUrl != null;
        _title.Text = _media.Title.Length == 0 ? Message("TextMessages61", "Файл не выбран") : _media.Title;
        _elapsed.Text = MediaPlayerModel.TimeText(_media.Position);
        _total.Text = MediaPlayerModel.TimeText(_media.Duration);
        _position.IsEnabled = _media.Duration > 0;
        _position.Maximum = Math.Max(_media.Duration, 0.1);
        _position.Value = _media.Position;
        _volume.Value = _media.Volume;
        _volumeLabel.Text = Message("LMEdiaVolume", "Громкость:");
        _play.Symbol = _media.IsPlaying ? "pause.fill" : "play.fill";
        foreach (var button in _transport) button.IsEnabled = hasFile;
        Mark(_autoPlay, _media.AutoPlay);
        Mark(_toScreen, _media.VideoToScreen);
        Mark(_repeat, _media.Repeats);
        Mark(_next, _media.PlaysNext);
        _mute.Symbol = _media.IsMuted ? "speaker.slash.fill" : "speaker.wave.2.fill";
        Mark(_mute, _media.IsMuted);
        _tracks.IsEnabled = _media.AudioTracks.Count > 1;
        _tracksChevron.InvalidateVisual();
        if (_media.CurrentFailure is { } failure)
        {
            _status.Text = FailureText(failure);
            _status.Color = () => Palette.SystemRed;
        }
        else
        {
            _status.Text = ActivityText(_media.CurrentActivity) ?? "";
            _status.Color = () => Palette.SecondaryLabel;
        }
        foreach (var b in _transport) b.InvalidateVisual();
        _play.InvalidateVisual();
        _mute.InvalidateVisual();
        _box.InvalidateVisual();
    }

    /// Утоплена кнопка — так перемикачі намальовані в автора; увімкнена — ще й кольору акценту
    /// (власник на Mac: «кнопка повтору спрацьовує, але не міняє колір»).
    static void Mark(PushButton button, bool on)
    {
        button.IsOn = on;
        button.TitleTint = on ? () => Palette.Accent : null;
        button.InvalidateVisual();
    }

    void ChooseTrack()
    {
        var entries = new List<MenuEntry>();
        if (_media.AudioTracks.Count == 0) entries.Add(new MenuEntry(Message("TextMessages64", "Аудио дорожка")));
        foreach (var track in _media.AudioTracks)
            entries.Add(new MenuEntry(track.Title, () => _media.SelectAudioTrack(track.Id), track.Id == _media.SelectedAudioTrackId));
        var menu = MenuStrip.Build(entries);
        menu.PlacementTarget = _tracks;
        menu.Open(_tracks);
    }

    async Task OpenFiles()
    {
        if (await ChooseFiles(this) is not { Count: > 0 } files) return;
        var before = _media.Playlist.Count;
        _media.AddToPlaylist(files);
        // Відкриваємо перший ДОДАНИЙ за порядком списку, а не перший клацнутий у вікні.
        if (_media.Playlist.Count > before) _media.OpenFromPlaylist(before);
    }

    /// Вікно «Відкриття медіафайлів» із чотирма наборами автора (медіа, відео, аудіо, усі).
    public static async Task<List<string>?> ChooseFiles(Visual anchor)
    {
        if (TopLevel.GetTopLevel(anchor)?.StorageProvider is not { } storage) return null;
        var filters = AppState.Shared.Media.Filters;
        var types = Enum.GetValues<MediaFileFilters.FilterGroup>().Select(group =>
        {
            var extensions = filters.Extensions(group);
            return new FilePickerFileType(Message(MediaFileFilters.CaptionKey(group), T(MediaFileFilters.FallbackCaption(group))))
            {
                Patterns = extensions.Count == 0 ? new[] { "*.*" } : extensions.Select(e => "*." + e).ToList(),
            };
        }).ToList();
        var picked = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = Message("TextMessages58", "Открытие медиафайлов"),
            AllowMultiple = true,
            FileTypeFilter = types,
        });
        return picked.Select(f => f.TryGetLocalPath()).OfType<string>().ToList();
    }

    /// «Відкрити URL»: кілька посилань за раз — усі лягають у список плеєра, перше додане грає
    /// одразу (власник: ролики YouTube «добавляя несколько в свой плейлист»).
    void OpenUrl()
    {
        Prompt.AskLines(Message("TextMessages52", "Открытие медиапотока"), Message("TextMessages53", "Введите URL медиапотока"), text =>
        {
            var before = _media.Playlist.Count;
            _media.AddLinks(text);
            if (_media.Playlist.Count > before) _media.OpenFromPlaylist(before);
        });
    }

    string? ActivityText(MediaPlayerModel.Activity activity) => activity.Kind switch
    {
        MediaPlayerModel.ActivityKind.OpeningFile => Message("TextMessages50", "Открываем медиафайл..."),
        MediaPlayerModel.ActivityKind.OpeningStream => Message("TextMessages59", "Открываем медиапоток..."),
        MediaPlayerModel.ActivityKind.Closing => activity.Stream ? Message("TextMessages60", "Закрываем медиапоток...") : Message("TextMessages51", "Закрываем медиафайл..."),
        _ => null,
    };

    string FailureText(MediaPlayerModel.Failure failure) => failure.Kind switch
    {
        MediaPlayerModel.FailureKind.CannotOpen => Message("ErrorMessages18", "Ошибка при открытии медиа-файла"),
        MediaPlayerModel.FailureKind.BadUrl => Message("ErrorMessages20", "Ошибка в URL"),
        MediaPlayerModel.FailureKind.PageLink => T("%s даёт по такой ссылке страницу, а не поток. Нужен прямой адрес файла или трансляции (.m3u8).", failure.Detail),
        MediaPlayerModel.FailureKind.UnsupportedScheme => Message("ErrorMessages20", "Ошибка в URL") + ": " + failure.Detail + "://",
        MediaPlayerModel.FailureKind.YouTube => failure.Detail,
        _ => T("этой функции в Windows-версии ещё нет") + (failure.Detail.Length > 0 ? " (" + failure.Detail + ")" : ""),
    };

    protected override void Arrangement(Size size)
    {
        const double gap = 6, row = 24;
        var width = size.Width - gap * 2;
        Place(_backdrop, new Rect(size));
        // Смуга згори: кнопки — рамки 20 у рядку 24, крок 3.
        var x = gap;
        foreach (var b in new[] { _open, _url, _autoPlay, _toScreen }) { Place(b, new Rect(x, gap + 1.5, 32, 21)); x += 35; }
        Place(_tracks, new Rect(x, gap + 1.5, 44, 21));
        Place(_tracksChevron, new Rect(x, gap + 1.5, 44, 21));
        x += 47;
        Place(_title, new Rect(x + 2, gap + 6, Math.Max(0, gap + width - x - 2), 14));
        // Кадр 16:9 — і не вищий за те, що лишилося.
        var rows = row * 2 + 18 + gap * 4;
        var top = gap + row;
        var boxHeight = Math.Min(width * 9 / 16, Math.Max(60, size.Height - top - rows));
        Place(_box, new Rect(gap, top + gap, width, boxHeight));
        var positionTop = top + gap + boxHeight + gap;
        Place(_elapsed, new Rect(gap, positionTop + 3, 44, 16));
        Place(_total, new Rect(size.Width - gap - 44, positionTop + 3, 44, 16));
        Place(_position, new Rect(gap + 44 + 5, positionTop, Math.Max(0, size.Width - gap * 2 - 88 - 10), 20));
        var transportTop = positionTop + row + gap;
        x = gap;
        foreach (var b in _transport.Concat(new[] { _repeat, _next, _mute })) { Place(b, new Rect(x, transportTop + 1.5, 32, 21)); x += 35; }
        var labelWidth = Math.Ceiling(UiFont.Width(_volumeLabel.Text, 10)) + 2;
        Place(_volumeLabel, new Rect(x + 2, transportTop + 6, labelWidth, 14));
        Place(_volume, new Rect(x + 2 + labelWidth + 3, transportTop + 5, 100, 14));
        Place(_status, new Rect(gap, transportTop + row + 2, width, 14));
    }

    /// Вікно кадру: чорний прямокутник, кадр плеєра й прийом файлів мишею.
    sealed class VideoBox : Control
    {
        readonly MediaPlayerModel _media;

        public VideoBox(MediaPlayerModel media)
        {
            _media = media;
            ClipToBounds = true;
            media.Frames.FrameReady += InvalidateVisual;
            DragDrop.SetAllowDrop(this, true);
            AddHandler(DragDrop.DragOverEvent, (_, e) => { e.DragEffects = e.Data.Contains(DataFormats.Files) ? DragDropEffects.Copy : DragDropEffects.None; });
            AddHandler(DragDrop.DropEvent, (_, e) =>
            {
                var files = e.Data.GetFiles()?.Select(f => f.TryGetLocalPath()).OfType<string>().ToList();
                if (files is not { Count: > 0 }) return;
                // Кинуте в кадр іде в список, а не підміняє відкрите.
                _media.AddToPlaylist(files);
                if (_media.MediaUrl == null) _media.Open(files[0]);
                // Своє взяли — до вікна (WindowDrop) кинуте вже не йде.
                e.Handled = true;
            });
            ContextMenu = MenuStrip.Build(new[] { new MenuEntry(T("Закрыть медиафайл"), _media.Close) });
        }

        public override void Render(DrawingContext g)
        {
            var b = new Rect(Bounds.Size);
            g.DrawRectangle(Brushes.Black, new Pen(Palette.Brush(Palette.Separator), 1), b.Deflate(0.5), 3, 3);
            var frame = _media.HasVideo ? _media.Frames.Latest : null;
            if (frame != null)
            {
                g.Custom(new FrameOperation(b.Deflate(1), frame));
                return;
            }
            // Без кадру — значок: фільм (нічого не відкрито) чи нота (звуковий файл).
            var symbol = _media.MediaUrl != null ? "music.note" : "film";
            Icons.Draw(g, symbol, new Rect(b.Center.X - 16, b.Center.Y - 16, 32, 32), Palette.TertiaryLabel);
        }

        sealed class FrameOperation : Avalonia.Rendering.SceneGraph.ICustomDrawOperation
        {
            readonly SkiaSharp.SKBitmap _bitmap;
            public Rect Bounds { get; }
            public FrameOperation(Rect bounds, SkiaSharp.SKBitmap bitmap) { Bounds = bounds; _bitmap = bitmap; }
            public void Dispose() { }
            public bool HitTest(Point p) => Bounds.Contains(p);
            public bool Equals(Avalonia.Rendering.SceneGraph.ICustomDrawOperation? other) => false;
            public void Render(Avalonia.Media.ImmediateDrawingContext context)
            {
                if (context.TryGetFeature<ISkiaSharpApiLeaseFeature>() is not { } lease) return;
                using var api = lease.Lease();
                VideoFrames.DrawFitted(api.SkCanvas, _bitmap, new SkiaSharp.SKRect((float)Bounds.Left, (float)Bounds.Top, (float)Bounds.Right, (float)Bounds.Bottom));
            }
        }
    }
}
