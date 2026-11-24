// =============================================================================
//  BackingTrackBar.cs — панель фонограм на вкладці «Пісні»
// =============================================================================
//  За NativeBackingTrackBar, NativeWaveformView і NativeLevelMeter Mac 1.3.9.
//  Свій список (кинуті сюди звукові файли лягають у нього), темна картка треку
//  (назва, час, хвиля — клацання чи протяжка грає з того місця, — пік-метр),
//  кнопки «грати / пауза / стоп / по колу / наступна», тон «♭ −0,5 · Тон · ♯ +0,5»
//  (для виділеної в списку фонограми, а без виділення — відкритої) і гучність.
//  Широка раскладка (від 620): список ліворуч, картка праворуч; вузька — стовпчиком;
//  стиснута (нижче 154) — один ряд: кнопки, назва, смуга й гучність.
// =============================================================================

using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;

namespace Slovo.App;

public sealed class BackingTrackBar : LayoutPanel, IRowSource
{
    public const double CollapsedHeight = 34, MinimumHeight = 170, WideWidth = 620, FullHeight = MinimumHeight, VolumeWidth = 160;
    const string ListWidthKey = "backingListWidth";
    static string T(string text, params object[] args) => Captions.T(text, args);

    readonly BackingTrackPlayer _player;
    readonly PaintLayer _frame, _deck;
    // Мітки NSTextField на Mac відступають 2 точки від рамки — те саме й тут.
    readonly BottomCaption _caption = new() { FontSize = 11, Weight = FontWeight.SemiBold, Inset = 2 }, _count = new() { FontSize = 10, Inset = 2 };
    readonly PaintLayer _icon;
    readonly PushButton _add, _remove, _clear, _up, _down, _play, _pause, _stop, _loop, _next, _toneDown, _toneLabel, _toneUp;
    readonly RowList _list;
    readonly BottomCaption _name = new() { FontSize = 12, Weight = FontWeight.SemiBold, Inset = 2 }, _time = new() { FontSize = 11, Align = TextAlignment.Right, Inset = 2 };
    readonly WaveformView _waveform = new();
    readonly LevelMeter _meter = new();
    readonly PaintLayer _quiet, _loud;
    readonly MacSlider _volume = new() { KnobSize = 18, TrackInset = 2, Step = 0.05, Maximum = 1 };
    readonly WidthGrip _grip = new();
    readonly DispatcherTimer _animation;
    int? _selected;
    bool _dropHighlighted;
    List<string> _shownList = new();
    int? _shownIndex;

    public BackingTrackBar(BackingTrackPlayer player)
    {
        _player = player;
        _frame = new PaintLayer((g, b) => g.DrawRectangle(Palette.Brush(Palette.ControlBackground),
            new Pen(Palette.Brush(_dropHighlighted ? Palette.Accent : Palette.Separator), _dropHighlighted ? 2 : 1), b.Deflate(0.5), 6, 6));
        // Темна картка — як передпоказ і живий екран: там, де «зал», завжди темно.
        _deck = new PaintLayer((g, b) => g.DrawRectangle(new SolidColorBrush(Color.FromRgb(18, 18, 18)), null, b, 6, 6));
        _icon = new PaintLayer((g, b) => Icons.Draw(g, "music.note.list", new Rect(0, 0, 14, 14), Palette.Accent));
        _quiet = new PaintLayer((g, b) => Icons.Draw(g, "speaker.fill", new Rect(0, 0, 13, 13), Palette.TertiaryLabel));
        _loud = new PaintLayer((g, b) => Icons.Draw(g, "speaker.wave.3.fill", new Rect(0, 0, 15, 13), Palette.TertiaryLabel));
        PushButton Small(string symbol, Action action) => new("", symbol) { Bordered = false, Margin = 0, Pressed = action, SymbolSize = 11, TitleTint = () => Palette.SecondaryLabel };
        _add = Small("plus", () => _ = AddFiles());
        _remove = Small("minus", RemoveSelected);
        _clear = Small("trash", () => { _player.ClearPlaylist(); _selected = null; });
        // ↑/↓ — свій порядок фонограм (як і в списку плеєра).
        _up = Small("arrow.up", () => Move(-1));
        _down = Small("arrow.down", () => Move(1));
        // Рамка «круглої» кнопки AppKit у кадрі 34×26 — 20×20 (виміряно на знімку Mac).
        PushButton Transport(string symbol, Action action) => new("", symbol) { Margin = 7, Pressed = action, SymbolSize = 12 };
        _play = Transport("play.fill", Play);
        // «Грати» — кольором, як «Показати»: її натискають наосліп.
        _play.Prominent = true;
        _pause = Transport("pause.fill", () => _player.Pause());
        _stop = Transport("stop.fill", () => _player.Stop());
        _loop = Transport("repeat", () => _player.Loops = !_player.Loops);
        _next = Transport("text.line.first.and.arrowtriangle.forward", () => _player.PlaysNext = !_player.PlaysNext);
        _toneDown = new PushButton("♭ −0,5") { FontSize = 11, Weight = FontWeight.Medium, Size = ControlSize.Small, Pressed = () => SetTone(ShownTone - BackingTrackPlayer.PitchStep) };
        _toneUp = new PushButton("♯ +0,5") { FontSize = 11, Weight = FontWeight.Medium, Size = ControlSize.Small, Pressed = () => SetTone(ShownTone + BackingTrackPlayer.PitchStep) };
        _toneLabel = new PushButton("") { FontSize = 12, Weight = FontWeight.SemiBold, Bordered = false, Margin = 0, Pressed = () => SetTone(0) };
        _list = new RowList(new ListMetrics { LeadWidth = 26 }, 12) { Source = this };
        _list.SetUniformHeight(22);
        // Виділили іншу фонограму — напис і кнопки тону показують уже її тон.
        _list.OnSelect = (_, active, cause) => { if (cause == SelectCause.Code) return; _selected = active; Refresh(); };
        // Подвійне клацання чи Enter — відкрити й одразу грати.
        _list.OnActivate = index => { _player.OpenFromPlaylist(index); _player.Play(); };
        _waveform.OnSeek = fraction =>
        {
            if (_player.Duration <= 0) return;
            _player.Seek(fraction * _player.Duration);
            if (!_player.IsPlaying) _player.Play();
        };
        _volume.ValueChanged += value => _player.Volume = (float)value;
        _name.Color = () => _player.Url != null ? (_player.Error is { Length: > 0 } ? Palette.SystemRed : Colors.White) : Color.FromArgb(115, 255, 255, 255);
        _time.Color = () => Color.FromArgb(178, 255, 255, 255);
        _caption.Color = () => Palette.SecondaryLabel;
        _count.Color = () => Palette.TertiaryLabel;
        _grip.OnDrag = delta => { Widths.Set(ListWidthKey, _list.Bounds.Right + delta, 150, Math.Max(200, Bounds.Width - 320)); InvalidateArrange(); };
        _grip.OnReset = () => { Widths.Reset(ListWidthKey); InvalidateArrange(); };
        foreach (Control c in new Control[] { _frame, _icon, _caption, _count, _add, _remove, _clear, _up, _down, _list, _deck, _name, _time, _waveform, _meter,
                                              _play, _pause, _stop, _loop, _next, _toneDown, _toneLabel, _toneUp, _quiet, _volume, _loud, _grip })
            Children.Add(c);
        DragDrop.SetAllowDrop(this, true);
        AddHandler(DragDrop.DragOverEvent, (_, e) =>
        {
            var audio = Files(e).Any(BackingTrackPlayer.IsAudio);
            e.DragEffects = audio ? DragDropEffects.Copy : DragDropEffects.None;
            if (_dropHighlighted != audio) { _dropHighlighted = audio; _frame.InvalidateVisual(); }
        });
        AddHandler(DragDrop.DragLeaveEvent, (_, _) => { _dropHighlighted = false; _frame.InvalidateVisual(); });
        AddHandler(DragDrop.DropEvent, (_, e) =>
        {
            _dropHighlighted = false;
            _frame.InvalidateVisual();
            if (_player.AddToPlaylist(Files(e)) > 0) e.Handled = true;
        });
        // 60 кадрів на секунду, поки грає або поки рівень ще не опустився.
        _animation = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => Tick());
        _player.Changed += Refresh;
        Signals.Shared.Subscribe(Signals.Kind.Language, ApplyCaptions);
        ApplyCaptions();
    }

#pragma warning disable CS0618
    static List<string> Files(DragEventArgs e) => e.Data.GetFiles()?.Select(f => f.TryGetLocalPath()).OfType<string>().ToList() ?? new();
#pragma warning restore CS0618

    void ApplyCaptions()
    {
        _caption.Text = T("Фонограммы");
        ToolTip.SetTip(_add, T("Добавить фонограммы в список…"));
        ToolTip.SetTip(_remove, T("Убрать фонограмму из списка"));
        ToolTip.SetTip(_clear, T("Очистить список фонограмм"));
        ToolTip.SetTip(_up, T("Поднять выше в списке"));
        ToolTip.SetTip(_down, T("Опустить ниже в списке"));
        ToolTip.SetTip(_list, T("Свой список фонограмм: перетащите сюда музыку. Двойной щелчок — играть"));
        ToolTip.SetTip(_waveform, T("Весь трек: щелчок или перетаскивание — играть с этого места"));
        ToolTip.SetTip(_meter, T("Уровень фонограммы: левый и правый каналы, красное — перегрузка"));
        ToolTip.SetTip(_play, T("Играть"));
        ToolTip.SetTip(_pause, T("Пауза"));
        ToolTip.SetTip(_stop, T("Стоп"));
        ToolTip.SetTip(_loop, T("Повторять по кругу"));
        ToolTip.SetTip(_next, T("После окончания играть следующую фонограмму из списка"));
        ToolTip.SetTip(_volume, T("Громкость фонограммы"));
        ToolTip.SetTip(_toneDown, T("Понизить тон на 0,5 (полтона); темп не меняется"));
        ToolTip.SetTip(_toneUp, T("Повысить тон на 0,5 (полтона); темп не меняется"));
        ToolTip.SetTip(_toneLabel, T("Тон фонограммы, выделенной в списке (без выделения — открытой); щелчок — вернуть исходный. Запоминается для каждого файла"));
        ToolTip.SetTip(_grip, T("Потяните влево или вправо — ширина списка фонограмм; двойной щелчок — как было"));
        Refresh();
    }

    // --- Стан ---------------------------------------------------------------------------

    void Refresh()
    {
        var hasFile = _player.Url != null;
        _name.Text = _player.Error is { Length: > 0 } error ? T("Не удалось открыть фонограмму: %s", error)
                   : hasFile ? _player.Title : T("Фонограмма не выбрана");
        _play.IsEnabled = (hasFile || _player.Playlist.Count > 0) && !_player.IsPlaying;
        _pause.IsEnabled = _player.IsPlaying;
        _stop.IsEnabled = hasFile;
        Mark(_loop, _player.Loops);
        Mark(_next, _player.PlaysNext);
        if (Math.Abs(_volume.Value - _player.Volume) > 0.001) _volume.Value = _player.Volume;
        _remove.IsEnabled = _clear.IsEnabled = _player.Playlist.Count > 0;
        _up.IsEnabled = _down.IsEnabled = _player.Playlist.Count > 1;
        _count.Text = _player.Playlist.Count == 0 ? "" : "· " + _player.Playlist.Count;
        if (!ReferenceEquals(_waveform.Waveform, _player.Waveform)) _waveform.Waveform = _player.Waveform;
        _waveform.IsLoading = hasFile && _player.Waveform == null && _player.Error == null;
        _waveform.Duration = _player.Duration;
        ShowPosition(_player.Position);
        // Список перечитуємо лише коли він справді змінився.
        if (!_player.Playlist.SequenceEqual(_shownList) || _player.PlaylistIndex != _shownIndex)
        {
            _shownList = _player.Playlist.ToList();
            _shownIndex = _player.PlaylistIndex;
            _list.Reload();
            var active = _player.PlaylistIndex;
            _list.SetSelection(active is { } a ? new[] { a } : Array.Empty<int>(), active);
            _selected = null;
        }
        var tone = ShownTone;
        _toneLabel.Title = T("Тон: %s", ToneText(tone));
        _toneLabel.TitleTint = tone == 0 ? () => Palette.SecondaryLabel : () => Palette.Accent;
        _toneDown.IsEnabled = tone > -BackingTrackPlayer.PitchLimit;
        _toneUp.IsEnabled = tone < BackingTrackPlayer.PitchLimit;
        foreach (var b in new[] { _play, _pause, _stop, _loop, _next, _toneDown, _toneUp, _toneLabel }) b.InvalidateVisual();
        if (_player.IsPlaying && !_animation.IsEnabled) _animation.Start();
        InvalidateArrange();
    }

    static void Mark(PushButton button, bool on)
    {
        button.IsOn = on;
        button.TitleTint = on ? () => Palette.Accent : null;
    }

    void ShowPosition(double seconds)
    {
        _waveform.Progress = _player.Duration > 0 ? Math.Clamp(seconds / _player.Duration, 0, 1) : 0;
        _time.Text = MediaPlayerModel.TimeText(seconds) + " / " + MediaPlayerModel.TimeText(_player.Duration);
    }

    void Tick()
    {
        if (!_player.IsPlaying) { _player.Levels.Take(); _meter.Update(0, 0); }
        else if (_player.Levels.Take() is { } peaks) _meter.Update(peaks.Left, peaks.Right);
        else _meter.Advance();
        if (_player.IsPlaying) ShowPosition(_player.LivePosition);
        if (!_player.IsPlaying && _meter.IsQuiet) _animation.Stop();
    }

    /// Фонограма, якої стосуються кнопки тону: виділена в списку, а без виділення — відкрита.
    string? ToneTarget => _selected is { } s && s >= 0 && s < _player.Playlist.Count ? _player.Playlist[s] : _player.Url;
    double ShownTone => ToneTarget is { } target ? _player.Pitch(target) : _player.PitchTones;

    void SetTone(double tones)
    {
        if (ToneTarget is { } target) _player.SetPitch(tones, target); else _player.SetPitch(tones);
    }

    /// «0», «+0,5», «−1» — з комою там, де пишуть комою.
    public static string ToneText(double tones)
    {
        if (tones == 0) return "0";
        var text = Math.Abs(tones).ToString("0.#", System.Globalization.CultureInfo.InvariantCulture);
        if (Slovo.Core.OurWords.Language != "en") text = text.Replace('.', ',');
        return (tones > 0 ? "+" : "−") + text;
    }

    void Play()
    {
        // Нічого не відкрито, але список є — грати виділене чи перше.
        if (_player.Url == null && _player.Playlist.Count > 0) _player.OpenFromPlaylist(_selected ?? 0);
        _player.Play();
    }

    async Task AddFiles()
    {
        if (TopLevel.GetTopLevel(this)?.StorageProvider is not { } storage) return;
        var picked = await storage.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = T("Добавить фонограммы в список…"),
            AllowMultiple = true,
            FileTypeFilter = new[] { new FilePickerFileType(T("Аудиофайлы")) { Patterns = BackingTrackPlayer.AudioExtensions.Select(e => "*." + e).ToList() } },
        });
        _player.AddToPlaylist(picked.Select(f => f.TryGetLocalPath()).OfType<string>());
    }

    /// Пересунути виділену (чи відкриту) фонограму — виділення їде разом із нею.
    void Move(int offset)
    {
        if ((_selected ?? _player.PlaylistIndex) is not { } index) return;
        var target = index + offset;
        if (target < 0 || target >= _player.Playlist.Count) return;
        _player.MovePlaylistItem(index, offset);
        _shownList = _player.Playlist.ToList();
        _shownIndex = _player.PlaylistIndex;
        _list.Reload();
        _list.SetSelection(new[] { target }, target);
        _selected = target;
        Refresh();
    }

    void RemoveSelected()
    {
        if ((_selected ?? _player.PlaylistIndex) is not { } index) return;
        _player.RemoveFromPlaylist(index);
        _selected = null;
    }

    // --- Список ---------------------------------------------------------------------------

    public int RowCount => _player.Playlist.Count;
    public Row RowAt(int index) => new(Path.GetFileNameWithoutExtension(_player.Playlist[index]), (index + 1).ToString());

    // --- Розкладка ----------------------------------------------------------------------

    protected override void Arrangement(Size size)
    {
        Place(_frame, new Rect(size));
        var compact = size.Height < FullHeight - 16;
        foreach (Control c in new Control[] { _icon, _caption, _count, _add, _remove, _clear, _up, _down, _list }) c.IsVisible = !compact;
        foreach (Control c in new Control[] { _waveform, _meter, _toneDown, _toneUp, _toneLabel, _loop, _quiet, _loud }) c.IsVisible = true;
        if (compact) LayoutCompact(size);
        else if (size.Width >= WideWidth) LayoutWide(size);
        else LayoutNarrow(size);
    }

    void LayoutCompact(Size size)
    {
        _grip.IsVisible = false;
        const double pad = 6;
        var row = Math.Max(0, (size.Height - 22) / 2);
        var x = pad;
        foreach (var b in new[] { _play, _pause, _stop, _next }) { Place(b, new Rect(x, row, 30, 22)); x += 32; }
        const double volumeWidth = 110;
        var volumeX = Math.Max(x, size.Width - pad - volumeWidth);
        Place(_volume, new Rect(volumeX, row, volumeWidth, 22));
        var deckX = x + 4;
        var deckWidth = Math.Max(80, volumeX - deckX - 8);
        var deck = new Rect(deckX, 2, deckWidth, Math.Max(18, size.Height - 4));
        Place(_deck, deck);
        const double timeWidth = 86;
        var nameWidth = Math.Min(160, Math.Max(60, deckWidth * 0.3));
        var middle = deck.Y + Math.Max(0, (deck.Height - 16) / 2);
        Place(_name, new Rect(deck.X + 6, middle, nameWidth, 16));
        Place(_time, new Rect(deck.Right - timeWidth - 6, middle + 1, timeWidth, 14));
        var barX = deck.X + 6 + nameWidth + 8;
        Place(_waveform, new Rect(barX, middle, Math.Max(30, deck.Right - timeWidth - 6 - barX - 8), 16));
        // Решта в один ряд не вміщається.
        foreach (Control c in new Control[] { _meter, _toneDown, _toneUp, _toneLabel, _loop, _quiet, _loud }) c.IsVisible = false;
    }

    void LayoutWide(Size size)
    {
        const double pad = 8;
        var width = size.Width;
        var listWidth = Widths.Value(ListWidthKey, Math.Min(Math.Max(260, width * 0.26), 460), 150, Math.Max(200, width - 320));
        Place(_icon, new Rect(pad, 6, 16, 16));
        var right = listWidth;
        foreach (var b in new[] { _clear, _remove, _down, _up, _add }) { right -= 22; Place(b, new Rect(right, 4, 22, 20)); }
        var captionWidth = Math.Min(Math.Ceiling(UiFont.Width(_caption.Text, 11, FontWeight.SemiBold)) + 4, Math.Max(20, right - pad - 50));
        Place(_caption, new Rect(pad + 20, 7, captionWidth, 16));
        Place(_count, new Rect(pad + 20 + captionWidth + 4, 8, Math.Max(0, right - pad - 20 - captionWidth - 8), 14));
        Place(_list, new Rect(pad, 28, Math.Max(60, listWidth - pad), Math.Max(0, size.Height - 28 - pad)));
        _grip.IsVisible = true;
        Place(_grip, new Rect(listWidth, 24, 6, Math.Max(0, size.Height - 24 - pad)));
        var deckX = listWidth + pad + 4;
        var deckWidth = Math.Max(120, width - deckX - pad);
        const double rowHeight = 26;
        var deckHeight = Math.Max(80, size.Height - pad - rowHeight - 8 - pad);
        PlaceDeck(new Rect(deckX, pad, deckWidth, deckHeight), deckHeight - 18);
        var row = pad + deckHeight + 8;
        var x = deckX;
        foreach (var b in new[] { _play, _pause, _stop, _loop, _next }) { Place(b, new Rect(x, row, 34, rowHeight)); x += 38; }
        const double toneButton = 62;
        Place(_toneDown, new Rect(x + 6, row + 2, toneButton, 22));
        Place(_toneLabel, new Rect(x + 6 + toneButton + 4, row + 2, 96, 22));
        Place(_toneUp, new Rect(x + 6 + toneButton + 4 + 96 + 4, row + 2, toneButton, 22));
        var volumeLeft = x + 6 + toneButton + 4 + 96 + 4 + toneButton + 16;
        Place(_quiet, new Rect(volumeLeft, row + 5, 14, 14));
        var room = Math.Max(30, width - pad - 18 - 4 - (volumeLeft + 18));
        Place(_volume, new Rect(volumeLeft + 18, row + 2, Math.Min(VolumeWidth, room), 20));
        Place(_loud, new Rect(volumeLeft + 18 + Math.Min(VolumeWidth, room) + 4, row + 5, 18, 14));
    }

    /// Картка треку: назва й час згори, хвиля, пік-метр унизу.
    void PlaceDeck(Rect deck, double meterTop)
    {
        Place(_deck, deck);
        var inner = Math.Max(20, deck.Width - 16);
        const double timeWidth = 86;
        Place(_name, new Rect(deck.X + 8, deck.Y + 7, Math.Max(20, inner - timeWidth - 4), 16));
        Place(_time, new Rect(deck.X + 8 + inner - timeWidth, deck.Y + 8, timeWidth, 14));
        Place(_meter, new Rect(deck.X + 8, deck.Y + meterTop, inner, 10));
        Place(_waveform, new Rect(deck.X + 8, deck.Y + 30, inner, Math.Max(20, meterTop - 36)));
    }

    void LayoutNarrow(Size size)
    {
        _grip.IsVisible = false;
        const double pad = 8;
        var width = size.Width;
        var inner = Math.Max(20, width - pad * 2);
        Place(_icon, new Rect(pad, 6, 16, 16));
        var right = width - pad;
        foreach (var b in new[] { _clear, _remove, _down, _up, _add }) { right -= 22; Place(b, new Rect(right, 4, 22, 20)); }
        var captionWidth = Math.Min(Math.Ceiling(UiFont.Width(_caption.Text, 11, FontWeight.SemiBold)) + 4, Math.Max(20, right - pad - 58));
        Place(_caption, new Rect(pad + 20, 7, captionWidth, 16));
        Place(_count, new Rect(pad + 20 + captionWidth + 4, 8, Math.Max(0, right - pad - 20 - captionWidth - 8), 14));
        var rowVolume = size.Height - 26;
        var rowTone = rowVolume - 30;
        var rowButtons = rowTone - 32;
        const double deckHeight = 116;
        var deckY = rowButtons - 8 - deckHeight;
        Place(_list, new Rect(pad, 28, inner, Math.Max(0, deckY - 6 - 28)));
        PlaceDeck(new Rect(pad, deckY, inner, deckHeight), 98);
        var x = pad;
        var buttons = new[] { _play, _pause, _stop, _loop, _next };
        var buttonWidth = Math.Min(40, Math.Max(28, (inner - (buttons.Length - 1) * 4) / buttons.Length));
        foreach (var b in buttons) { Place(b, new Rect(x, rowButtons, buttonWidth, 26)); x += buttonWidth + 4; }
        const double toneButton = 62;
        Place(_toneDown, new Rect(pad, rowTone, toneButton, 22));
        Place(_toneUp, new Rect(width - pad - toneButton, rowTone, toneButton, 22));
        Place(_toneLabel, new Rect(pad + toneButton + 4, rowTone, Math.Max(20, width - pad * 2 - toneButton * 2 - 8), 22));
        Place(_quiet, new Rect(pad, rowVolume + 3, 14, 14));
        Place(_loud, new Rect(width - pad - 18, rowVolume + 3, 18, 14));
        Place(_volume, new Rect(pad + 20, rowVolume, Math.Max(40, inner - 20 - 24), 20));
    }
}

/// Хвиля треку на темній картці: зігране — кольором акценту, решта — блідим білим;
/// курсор — біла риска з трикутничком; клацання чи протяжка — грати з того місця.
public sealed class WaveformView : Control
{
    BackingWaveform? _waveform;
    double _progress;
    double? _drag;
    public BackingWaveform? Waveform { get => _waveform; set { _waveform = value; InvalidateVisual(); } }
    public double Progress { get => _progress; set { if (Math.Abs(value - _progress) > 0.0005) { _progress = value; InvalidateVisual(); } } }
    public double Duration { get; set; }
    bool _loading;
    public bool IsLoading { get => _loading; set { if (_loading == value) return; _loading = value; InvalidateVisual(); } }
    public Action<double>? OnSeek;

    // Без обрізання по краю: головка курсора на початку треку виходить за хвилю, як на Mac.
    public WaveformView() { Cursor = new Cursor(StandardCursorType.Hand); }

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        var middle = b.Height / 2;
        var half = b.Height / 2 - 2;
        if (_waveform is not { Maxs.Length: > 0 } wave)
        {
            g.FillRectangle(new SolidColorBrush(Color.FromArgb(31, 255, 255, 255)), new Rect(0, middle - 0.5, b.Width, 1));
            var text = Captions.T(_loading ? "Строю волну…" : "Перетащите сюда музыку");
            var width = UiFont.Width(text, 10) + 12;
            var box = new Rect(b.Width / 2 - width / 2, middle - 8, width, 16);
            g.DrawRectangle(new SolidColorBrush(Color.FromRgb(20, 20, 20)), null, box, 4, 4);
            TextDraw.Draw(g, text, new Rect(box.X + 6, box.Y + 1, width - 12, 14), 10, Color.FromArgb(115, 255, 255, 255), wrap: false);
            return;
        }
        // Тихий трек не має виглядати рискою: масштаб від найгучнішого місця, але не більш як учетверо.
        var scale = 1 / Math.Max(0.25, Math.Min(1, wave.Peak));
        var shown = _drag ?? _progress;
        var cursorX = shown * b.Width;
        var count = wave.Maxs.Length;
        const double step = 2;
        var columns = Math.Max(1, (int)(b.Width / step));
        var played = new SolidColorBrush(Palette.Accent);
        var rest = new SolidColorBrush(Color.FromArgb(82, 255, 255, 255));
        for (var column = 0; column < columns; column++)
        {
            var from = column * count / columns;
            var to = Math.Max(from + 1, (column + 1) * count / columns);
            float low = 0, high = 0;
            for (var bucket = from; bucket < Math.Min(to, count); bucket++)
            {
                low = Math.Min(low, wave.Mins[bucket]);
                high = Math.Max(high, wave.Maxs[bucket]);
            }
            var top = middle - Math.Min(half, Math.Max(0.75, high * scale * half));
            var bottom = middle - Math.Max(-half, Math.Min(-0.75, low * scale * half));
            var x = column * step;
            g.DrawRectangle(x < cursorX ? played : rest, null, new Rect(x, top, step - 0.6, Math.Max(1.5, bottom - top)), 0.6, 0.6);
        }
        var cx = Math.Clamp(cursorX, 1, b.Width - 1);
        g.FillRectangle(Brushes.White, new Rect(cx - 0.75, 0, 1.5, b.Height));
        var head = new StreamGeometry();
        using (var c = head.Open())
        {
            c.BeginFigure(new Point(cx - 4, 0), true);
            c.LineTo(new Point(cx + 4, 0));
            c.LineTo(new Point(cx, 5));
            c.EndFigure(true);
        }
        g.DrawGeometry(Brushes.White, null, head);
        if (_drag is { } drag && Duration > 0)
        {
            var text = MediaPlayerModel.TimeText(drag * Duration);
            var width = UiFont.Width(text, 10, FontWeight.SemiBold);
            var labelX = Math.Min(b.Width - width - 8, Math.Max(2, cursorX + 5));
            var box = new Rect(labelX - 3, b.Height - 16, width + 6, 15);
            g.DrawRectangle(new SolidColorBrush(Palette.Accent), null, box, 3, 3);
            TextDraw.Draw(g, text, new Rect(labelX, box.Y + 1, width + 2, 13), 10, Colors.White, FontWeight.SemiBold, wrap: false);
        }
    }

    double Fraction(PointerEventArgs e) => Bounds.Width <= 0 ? 0 : Math.Clamp(e.GetPosition(this).X / Bounds.Width, 0, 1);

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (_waveform == null && Duration <= 0) return;
        _drag = Fraction(e);
        e.Pointer.Capture(this);
        InvalidateVisual();
        e.Handled = true;
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        if (_drag == null) return;
        _drag = Fraction(e);
        InvalidateVisual();
    }

    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (_drag == null) return;
        var target = Fraction(e);
        _drag = null;
        e.Pointer.Capture(null);
        _progress = target;
        InvalidateVisual();
        OnSeek?.Invoke(target);
    }
}

/// Пік-метр фонограми: два канали, плавний підйом і спад, риска найвищого піку
/// тримається секунду й гасне (NativeLevelMeter).
public sealed class LevelMeter : Control
{
    const float Floor = -48, Attack = 0.07f, Release = 0.4f;
    const double HoldTime = 1.0, FadeTime = 0.6;
    readonly float[] _target = { Floor, Floor }, _shown = { Floor, Floor }, _held = { Floor, Floor };
    readonly double[] _heldAt = { 0, 0 };
    double _last = Now;
    static double Now => Environment.TickCount64 / 1000.0;

    public bool IsQuiet
    {
        get
        {
            var now = Now;
            var dark = _heldAt.All(at => now - at > HoldTime + FadeTime);
            return _shown.All(v => v <= Floor + 0.5f) && (dark || _held.All(v => v <= Floor + 0.5f));
        }
    }

    public void Update(float left, float right)
    {
        var now = Now;
        var values = new[] { left, right };
        for (var i = 0; i < 2; i++)
        {
            var db = values[i] > 0 ? Math.Max(Floor, 20 * MathF.Log10(values[i])) : Floor;
            _target[i] = db;
            if ((db >= _held[i] || now - _heldAt[i] > HoldTime + FadeTime) && db > Floor + 0.5f)
            {
                _held[i] = db;
                _heldAt[i] = now;
            }
        }
        Advance();
    }

    public void Advance()
    {
        var now = Now;
        var elapsed = (float)Math.Min(0.25, Math.Max(0, now - _last));
        _last = now;
        for (var i = 0; i < 2; i++)
        {
            var goal = _target[i];
            var constant = goal > _shown[i] ? Attack : Release;
            var step = 1 - MathF.Exp(-elapsed / constant);
            _shown[i] += (goal - _shown[i]) * step;
            if (Math.Abs(_shown[i] - goal) < 0.05f) _shown[i] = goal;
            _target[i] = Math.Max(Floor, _target[i] - 6 * elapsed);
        }
        InvalidateVisual();
    }

    static double Fraction(float db) => Math.Clamp((db - Floor) / -Floor, 0, 1);

    public override void Render(DrawingContext g)
    {
        var b = new Rect(Bounds.Size);
        const double gap = 2;
        var rowHeight = Math.Max(2, (b.Height - gap) / 2);
        var radius = Math.Min(rowHeight / 2, 3);
        var gradient = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative), EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromRgb(77, 199, 115), 0),
                new GradientStop(Color.FromRgb(92, 209, 117), Fraction(-18)),
                new GradientStop(Color.FromRgb(237, 204, 77), Fraction(-9)),
                new GradientStop(Color.FromRgb(242, 107, 82), Fraction(-2)),
                new GradientStop(Color.FromRgb(242, 82, 77), 1),
            },
        };
        var now = Now;
        for (var channel = 0; channel < 2; channel++)
        {
            var y = channel * (rowHeight + gap);
            var track = new Rect(0, y, b.Width, rowHeight);
            g.DrawRectangle(new SolidColorBrush(Color.FromArgb(18, 255, 255, 255)), null, track, radius, radius);
            var width = b.Width * Fraction(_shown[channel]);
            if (width > 0.5)
            {
                // Градієнт на всю шкалу, а видно лише пройдене: колір залежить від рівня.
                using (g.PushClip(new RoundedRect(new Rect(0, y, Math.Max(width, radius * 2), rowHeight), radius)))
                    g.FillRectangle(gradient, track);
            }
            var age = now - _heldAt[channel];
            if (_held[channel] > Floor + 0.5f && age < HoldTime + FadeTime)
            {
                var alpha = age <= HoldTime ? 1 : 1 - (age - HoldTime) / FadeTime;
                var x = b.Width * Fraction(_held[channel]);
                g.FillRectangle(new SolidColorBrush(Color.FromArgb((byte)(255 * alpha), 255, 255, 255)), new Rect(Math.Max(0, x - 1.5), y, 1.5, rowHeight));
            }
        }
    }
}
