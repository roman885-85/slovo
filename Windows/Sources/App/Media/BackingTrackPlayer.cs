// =============================================================================
//  BackingTrackPlayer.cs — фонограми (мінусовки) на вкладці «Пісні»
// =============================================================================
//  За BackingTrackPlayer.swift Mac 1.3.9: свій список (окремо від плеєра),
//  хвиля треку, пік-метр, «грати / пауза / стоп», «по колу», «після кінця —
//  наступна», гучність і тон ±3 тони кроком 0,5 без зміни темпу (запам'ятовується
//  для кожного файла). Ні одна кнопка показу її не чіпає.
//  Звук: Windows Media Foundation (mp3, m4a/aac, wav, wma, flac…) → SoundTouch
//  (тон, на льоту) → гучність → пік-метр → WASAPI. «По колу» — без зупинки
//  виводу: файл перемотується в тому самому читанні, щілини на стику немає.
// =============================================================================

using Avalonia.Threading;
using NAudio.Wave;
using SoundTouch;
using Slovo.Core;

namespace Slovo.App;

/// Хвиля треку: найменше й найбільше значення відліків на кожен із рівних відрізків.
public sealed class BackingWaveform
{
    public string Path { get; }
    public float[] Mins { get; }
    public float[] Maxs { get; }
    public BackingWaveform(string path, float[] mins, float[] maxs) { Path = path; Mins = mins; Maxs = maxs; }

    /// Найгучніший відлік — для масштабу малювання.
    public float Peak => Math.Max(Maxs.DefaultIfEmpty(0).Max(), -Mins.DefaultIfEmpty(0).Min());

    /// Прочитати файл цілком і зібрати хвилю (секунда на пісню — лише поза головним потоком).
    public static BackingWaveform? Build(string path, int buckets = 2048)
    {
        try
        {
            using var reader = BackingEngine.OpenReader(path);
            var provider = reader.ToSampleProvider();
            var channels = provider.WaveFormat.Channels;
            var totalFrames = reader.Length / Math.Max(1, reader.WaveFormat.BlockAlign);
            if (totalFrames <= 0) return null;
            var perBucket = Math.Max(1, (long)Math.Ceiling(totalFrames / (double)buckets));
            var mins = new float[buckets];
            var maxs = new float[buckets];
            var buffer = new float[65536 * channels];
            long frame = 0;
            int read;
            while ((read = provider.Read(buffer, 0, buffer.Length)) > 0)
            {
                for (var i = 0; i + channels <= read; i += channels, frame++)
                {
                    var bucket = (int)Math.Min(buckets - 1, frame / perBucket);
                    for (var c = 0; c < channels; c++)
                    {
                        var v = buffer[i + c];
                        if (v < mins[bucket]) mins[bucket] = v;
                        if (v > maxs[bucket]) maxs[bucket] = v;
                    }
                }
            }
            return new BackingWaveform(path, mins, maxs);
        }
        catch { return null; }
    }
}

/// Пікові рівні виходу фонограми для індикатора: пише звуковий потік, забирає головний.
public sealed class BackingLevels
{
    readonly object _gate = new();
    float _left, _right;
    bool _fresh;

    public void Push(float left, float right)
    {
        lock (_gate)
        {
            _left = Math.Max(_left, left);
            _right = Math.Max(_right, right);
            _fresh = true;
        }
    }

    public (float Left, float Right)? Take()
    {
        lock (_gate)
        {
            if (!_fresh) return null;
            var answer = (_left, _right);
            _left = _right = 0;
            _fresh = false;
            return answer;
        }
    }
}

public sealed class BackingTrackPlayer
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    public string? Url { get; private set; }
    public string Title { get; private set; } = "";
    public bool IsPlaying { get; private set; }
    public double Duration { get; private set; }
    public string? Error { get; private set; }
    public BackingWaveform? Waveform { get; private set; }
    public readonly BackingLevels Levels = new();

    /// Щось змінилося — вигляду перемалюватися.
    public event Action? Changed;
    void Notify() => Changed?.Invoke();

    /// «По колу»: мінусовку під довгий спів часто пускають по колу.
    public bool Loops { get => _loops; set { _loops = value; if (_engine != null) _engine.Loops = value; Notify(); } }
    bool _loops;

    /// «Після кінця — наступна» зі списку («по колу» старше).
    public bool PlaysNext
    {
        get => _playsNext;
        set { _playsNext = value; if (Remembers) Defaults.Set(PlaysNextKey, value); Notify(); }
    }
    bool _playsNext;
    const string PlaysNextKey = "backingPlaysNext";

    // ── Тон ─────────────────────────────────────────────────────────────────

    public const double PitchStep = 0.5, PitchLimit = 3.0;
    const string PitchKey = "backingPitch";
    public double PitchTones { get; private set; }
    /// Тон, названий у цьому запуску (і «повернули на нуль»).
    readonly Dictionary<string, double> _sessionPitch = new(StringComparer.OrdinalIgnoreCase);

    static double Stepped(double tones) => Math.Clamp(Math.Round(tones / PitchStep) * PitchStep, -PitchLimit, PitchLimit);

    /// Тон відкритої фонограми.
    public void SetPitch(double tones)
    {
        PitchTones = Stepped(tones);
        if (_engine != null) _engine.PitchSemiTones = PitchTones * 2;
        if (Url != null) RememberPitch(PitchTones, Url);
        Notify();
    }

    /// Тон фонограми зі списку: відкрита — у звук одразу, інша — лише записується за нею.
    public void SetPitch(double tones, string track)
    {
        if (Url != null && SamePath(track, Url)) { SetPitch(tones); return; }
        RememberPitch(Stepped(tones), track);
        Notify();
    }

    public double Pitch(string track) => Url != null && SamePath(track, Url) ? PitchTones : RecordedPitch(track);

    void RememberPitch(double tones, string track)
    {
        _sessionPitch[track] = tones;
        if (!Remembers) return;
        var saved = SavedPitches();
        if (tones == 0) saved.Remove(track); else saved[track] = tones;
        Defaults.Set(PitchKey, string.Join("\n", saved.Select(p => p.Value.ToString(System.Globalization.CultureInfo.InvariantCulture) + "\t" + p.Key)));
    }

    Dictionary<string, double> SavedPitches()
    {
        var result = new Dictionary<string, double>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in (Defaults.String(PitchKey) ?? "").Split('\n'))
        {
            var tab = line.IndexOf('\t');
            if (tab > 0 && double.TryParse(line[..tab], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var v))
                result[line[(tab + 1)..]] = v;
        }
        return result;
    }

    double RecordedPitch(string track)
    {
        if (_sessionPitch.TryGetValue(track, out var fresh)) return fresh;
        return Remembers && SavedPitches().TryGetValue(track, out var old) ? old : 0;
    }

    // ── Гучність ────────────────────────────────────────────────────────────

    const string VolumeKey = "backingVolume";
    float _volume = 0.8f;
    public float Volume
    {
        get => _volume;
        set
        {
            _volume = Math.Clamp(value, 0, 1);
            if (_engine != null) _engine.Gain = MediaPlayerModel.Gain(_volume);
            if (Remembers) Defaults.Set(VolumeKey, (double)_volume);
            Notify();
        }
    }

    // ── Позиція ─────────────────────────────────────────────────────────────

    double _position;
    /// Позиція (секунди): на паузі — запам'ятована, під час гри — жива.
    public double Position => IsPlaying && _engine != null ? _engine.Position : _position;
    public double LivePosition => Position;

    // ── Список ──────────────────────────────────────────────────────────────

    public List<string> Playlist { get; private set; } = new();
    public int? PlaylistIndex { get; private set; }
    public bool Remembers;
    const string PlaylistKey = "backingPlaylist", MemoryKey = "backingTrackFile";

    /// Звукові розширення фонограми (відео — справа плеєра, навіть зі звуком).
    public static readonly IReadOnlySet<string> AudioExtensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "mp3", "m4a", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac", "m4b",
        "ogg", "oga", "opus", "wma", "ape", "wv", "mpc", "amr", "ra", "tta", "dsf", "m4r",
    };

    public static bool IsAudio(string path) => AudioExtensions.Contains(Path.GetExtension(path).TrimStart('.'));

    /// Додати файли до списку; незвукові пропускаються. Нічого не відкрито — відкривається
    /// перший доданий (але не грає: мінусовку пускають тоді, коли почали співати).
    public int AddToPlaylist(IEnumerable<string> paths)
    {
        var wanted = paths.Where(IsAudio).ToList();
        if (wanted.Count == 0) return 0;
        foreach (var item in wanted) if (!Playlist.Any(p => SamePath(p, item))) Playlist.Add(item);
        RememberPlaylist();
        if (Url == null) OpenFromPlaylist(Playlist.FindIndex(p => SamePath(p, wanted[0])));
        Notify();
        return wanted.Count;
    }

    public void OpenFromPlaylist(int index)
    {
        if (index < 0 || index >= Playlist.Count) return;
        Open(Playlist[index]);
    }

    /// Пересунути фонограму в списку (↑/↓): свій порядок, у якому їх пускають.
    public void MovePlaylistItem(int index, int offset)
    {
        var target = index + offset;
        if (index < 0 || index >= Playlist.Count || target < 0 || target >= Playlist.Count) return;
        (Playlist[index], Playlist[target]) = (Playlist[target], Playlist[index]);
        if (PlaylistIndex == index) PlaylistIndex = target;
        else if (PlaylistIndex == target) PlaylistIndex = index;
        RememberPlaylist();
        Notify();
    }

    public void RemoveFromPlaylist(int index)
    {
        if (index < 0 || index >= Playlist.Count) return;
        var removed = Playlist[index];
        Playlist.RemoveAt(index);
        if (Url != null && SamePath(removed, Url)) { PlaylistIndex = null; Close(); }
        else if (PlaylistIndex is { } current && current > index) PlaylistIndex = current - 1;
        RememberPlaylist();
        Notify();
    }

    /// Очистити список. Те, що грає, не зупиняється: список чистять між частинами служіння.
    public void ClearPlaylist()
    {
        Playlist = Url != null ? new List<string> { Url } : new List<string>();
        PlaylistIndex = Url == null ? null : 0;
        RememberPlaylist();
        Notify();
    }

    void RememberPlaylist()
    {
        if (Remembers) Defaults.Set(PlaylistKey, string.Join("\n", Playlist));
    }

    void RememberOpen()
    {
        if (!Remembers) return;
        if (Url != null) Defaults.Set(MemoryKey, Url); else Defaults.Remove(MemoryKey);
    }

    /// Відкрити те, що стояло минулого разу, — але не грати.
    public void Restore()
    {
        if (!Remembers || Url != null) return;
        if (Defaults.Has(PlaysNextKey)) _playsNext = Defaults.Bool(PlaysNextKey);
        if (Defaults.Has(VolumeKey)) _volume = (float)Math.Clamp(Defaults.Double(VolumeKey), 0, 1);
        var saved = (Defaults.String(PlaylistKey) ?? "").Split('\n').Where(p => p.Length > 0 && File.Exists(p)).ToList();
        if (Playlist.Count == 0 && saved.Count > 0) Playlist = saved;
        if (Defaults.String(MemoryKey) is { } path && File.Exists(path)) Open(path);
        Notify();
    }

    // ── Файл і керування ────────────────────────────────────────────────────

    BackingEngine? _engine;
    readonly Dictionary<string, BackingWaveform> _waveforms = new(StringComparer.OrdinalIgnoreCase);
    int _openToken;

    /// Йде перетворення чужого формату (.ogg, .opus, .ape…) — хвиля «будується», грати рано.
    public bool IsConverting { get; private set; }
    bool _playWhenReady;
    int _conversion;

    public void Open(string path)
    {
        StopEngine();
        Error = null;
        _position = 0;
        _playWhenReady = false;
        IsConverting = false;
        var conversion = ++_conversion;
        try
        {
            Install(new BackingEngine(path, Levels), path, path);
        }
        catch (Exception error) when (BackingConversion.Available && File.Exists(path))
        {
            // Формат, якого Windows сама не грає: перетворює LibVLC (на Mac — ffmpeg) у фоні,
            // щоб вікно не завмирало на довгій мінусовці. Назва й тон — від вихідного файла.
            Url = path;
            Title = Path.GetFileNameWithoutExtension(path);
            Duration = 0;
            Waveform = null;
            PitchTones = RecordedPitch(path);
            IsConverting = true;
            KeepInPlaylist(path);
            Task.Run(() => BackingConversion.Converted(path)).ContinueWith(task => Dispatcher.UIThread.Post(() =>
            {
                if (conversion != _conversion || Url == null || !SamePath(Url, path)) return;
                IsConverting = false;
                if (task.Result is { } ready)
                {
                    try
                    {
                        Install(new BackingEngine(ready, Levels), path, ready);
                        if (_playWhenReady) Play();
                    }
                    catch (Exception again) { Fail(path, again); }
                }
                else Fail(path, error);
                _playWhenReady = false;
                RememberOpen();
                Notify();
            }));
        }
        catch (Exception error) { Fail(path, error); }
        RememberOpen();
        Notify();
    }

    /// Звук готовий: рушій на файлі readable (сам файл або його перетворена копія).
    void Install(BackingEngine engine, string path, string readable)
    {
        engine.Gain = MediaPlayerModel.Gain(_volume);
        engine.Loops = _loops;
        engine.Finished += () => Dispatcher.UIThread.Post(() => Finished(engine));
        _engine = engine;
        Duration = engine.Duration;
        Url = path;
        Title = Path.GetFileNameWithoutExtension(path);
        PitchTones = RecordedPitch(path);
        engine.PitchSemiTones = PitchTones * 2;
        LoadWaveform(path, readable);
        KeepInPlaylist(path);
    }

    /// Відкрита фонограма завжди стоїть у своєму списку й видна виділеною.
    void KeepInPlaylist(string path)
    {
        var known = Playlist.FindIndex(p => SamePath(p, path));
        if (known >= 0) PlaylistIndex = known;
        else { Playlist.Add(path); PlaylistIndex = Playlist.Count - 1; RememberPlaylist(); }
    }

    void Fail(string path, Exception error)
    {
        _engine?.Dispose();
        _engine = null;
        Url = null;
        Title = "";
        Duration = 0;
        IsConverting = false;
        Error = Explain(error, path);
    }

    /// Чому не відкрилося — словами, з якими можна щось зробити.
    static string Explain(Exception error, string path)
    {
        var kind = Path.GetExtension(path).TrimStart('.').ToUpperInvariant();
        return T("Не вдалося відкрити %s: %s", kind.Length == 0 ? "?" : kind, error.Message);
    }

    public void Close()
    {
        StopEngine();
        _conversion++;
        _playWhenReady = false;
        IsConverting = false;
        Url = null;
        Waveform = null;
        PlaylistIndex = null;
        Title = "";
        Duration = 0;
        _position = 0;
        Error = null;
        RememberOpen();
        Notify();
    }

    public void Play()
    {
        // Ще перетворюється — заграє, щойно буде готово.
        if (IsConverting) { _playWhenReady = true; Notify(); return; }
        if (_engine == null || IsPlaying) return;
        // Дійшли до кінця й тиснуть «грати» — з початку.
        if (_position >= Duration - 0.05) _position = 0;
        try
        {
            _engine.Seek(_position);
            _engine.Play();
            IsPlaying = true;
        }
        catch (Exception error) { Error = error.Message; }
        Notify();
    }

    public void Pause()
    {
        _playWhenReady = false;
        if (!IsPlaying || _engine == null) return;
        _position = _engine.Position;
        _engine.Pause();
        IsPlaying = false;
        Notify();
    }

    public void Toggle() { if (IsPlaying) Pause(); else Play(); }

    /// «Стоп»: пауза й на початок.
    public void Stop()
    {
        _playWhenReady = false;
        _engine?.Pause();
        IsPlaying = false;
        _position = 0;
        _engine?.Seek(0);
        Notify();
    }

    public void Seek(double seconds)
    {
        if (_engine == null) return;
        _position = Math.Clamp(seconds, 0, Duration);
        _engine.Seek(_position);
        Notify();
    }

    void Finished(BackingEngine engine)
    {
        if (!ReferenceEquals(engine, _engine) || !IsPlaying) return;
        if (_playsNext && PlaylistIndex is { } current && current + 1 < Playlist.Count)
        {
            OpenFromPlaylist(current + 1);
            // Наступна могла піти на перетворення (чужий формат): Play() тоді запам'ятає прохання
            // й заграє, щойно буде готово (у Windows так і грало мовчки — знайдено у ВМ).
            Play();
            return;
        }
        _engine?.Pause();
        IsPlaying = false;
        _position = Duration;
        Notify();
    }

    void StopEngine()
    {
        IsPlaying = false;
        _engine?.Dispose();
        _engine = null;
    }

    /// Хвиля — з кешу або у фоні (з того, що справді читається: копії, якщо формат чужий);
    /// запізніла відповідь (відкрили інше) відкидається.
    void LoadWaveform(string path, string readable)
    {
        if (_waveforms.TryGetValue(path, out var cached)) { Waveform = cached; return; }
        Waveform = null;
        var token = ++_openToken;
        Task.Run(() =>
        {
            var built = BackingWaveform.Build(readable);
            Dispatcher.UIThread.Post(() =>
            {
                if (built == null) return;
                if (_waveforms.Count > 30) _waveforms.Clear();
                _waveforms[path] = built;
                if (token == _openToken && Url != null && SamePath(Url, path)) { Waveform = built; Notify(); }
            });
        });
    }

    static bool SamePath(string one, string two) =>
        string.Equals(one, two, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);
}

/// Звуковий тракт фонограми: читач Media Foundation → тон (SoundTouch) → гучність → пік-метр → WASAPI.
sealed class BackingEngine : ISampleProvider, IDisposable
{
    readonly object _gate = new();
    readonly WaveStream _reader;
    readonly ISampleProvider _source;
    readonly SoundTouchProcessor _touch;
    readonly BackingLevels _levels;
    WasapiOut? _output;
    float[] _input = new float[8192];
    bool _ended, _finishedRaised;
    double _pitch;

    public WaveFormat WaveFormat => _source.WaveFormat;
    public float Gain = 0.64f;
    public bool Loops;
    public event Action? Finished;

    public double Duration { get; }

    public BackingEngine(string path, BackingLevels levels)
    {
        _levels = levels;
        _reader = OpenReader(path);
        _source = _reader.ToSampleProvider();
        Duration = _reader.TotalTime.TotalSeconds;
        _touch = new SoundTouchProcessor { SampleRate = _source.WaveFormat.SampleRate, Channels = _source.WaveFormat.Channels };
        _touch.SetSetting(SettingId.UseQuickSeek, 1);
    }

    /// Читач файла: у Windows — Media Foundation (MP3, AAC/M4A, WMA, FLAC, WAV…);
    /// деінде (знімки на Mac) — лише WAV і AIFF, яких вистачає для перевірки вигляду.
    public static WaveStream OpenReader(string path)
    {
        if (OperatingSystem.IsWindows()) return new MediaFoundationReader(path);
        return Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".wav" or ".wave" => new WaveFileReader(path),
            ".aif" or ".aiff" or ".aifc" => new AiffFileReader(path),
            _ => throw new PlatformNotSupportedException(Captions.T("этой функции в Windows-версии ещё нет")),
        };
    }

    /// Тон у півтонах; 0 — звук іде повз SoundTouch (без затримки й без жодних слідів обробки).
    public double PitchSemiTones
    {
        get => _pitch;
        set { lock (_gate) { _pitch = value; _touch.PitchSemiTones = value; _touch.Clear(); } }
    }

    /// Де зараз звук (без того, що ще сидить у буфері тону).
    public double Position
    {
        get
        {
            lock (_gate)
            {
                var pending = _pitch != 0 ? _touch.UnprocessedSampleCount / (double)WaveFormat.SampleRate : 0;
                return Math.Max(0, _reader.CurrentTime.TotalSeconds - pending - 0.1);
            }
        }
    }

    public void Seek(double seconds)
    {
        lock (_gate)
        {
            _reader.CurrentTime = TimeSpan.FromSeconds(Math.Clamp(seconds, 0, Duration));
            _touch.Clear();
            _ended = false;
            _finishedRaised = false;
        }
    }

    public void Play()
    {
        if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException(Captions.T("этой функции в Windows-версии ещё нет"));
        if (_output == null)
        {
            _output = new WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, true, 100);
            _output.Init(this);
        }
        _output.Play();
    }

    public void Pause() => _output?.Pause();

    public int Read(float[] buffer, int offset, int count)
    {
        lock (_gate)
        {
            var channels = WaveFormat.Channels;
            var filled = 0;
            if (_pitch == 0)
            {
                while (filled < count)
                {
                    var read = _source.Read(buffer, offset + filled, count - filled);
                    if (read > 0) { filled += read; continue; }
                    if (!Rewind()) break;
                }
            }
            else
            {
                while (filled < count)
                {
                    var frames = _touch.ReceiveSamples(buffer.AsSpan(offset + filled, count - filled), (count - filled) / channels);
                    if (frames > 0) { filled += frames * channels; continue; }
                    if (_ended) break;
                    if (_input.Length < 4096 * channels) _input = new float[4096 * channels];
                    var read = _source.Read(_input, 0, 4096 * channels);
                    if (read > 0) { _touch.PutSamples(_input.AsSpan(0, read), read / channels); continue; }
                    if (Rewind()) continue;
                    _touch.Flush();
                    _ended = true;
                }
            }
            // Гучність і пік-метр — з того, що справді йде на вихід (уже зі зміненим тоном).
            float left = 0, right = 0;
            for (var i = 0; i < filled; i++)
            {
                var v = buffer[offset + i] * Gain;
                buffer[offset + i] = v;
                var a = Math.Abs(v);
                if (channels < 2 || i % channels == 0) { if (a > left) left = a; }
                else if (a > right) right = a;
            }
            if (channels < 2) right = left;
            if (filled > 0) _levels.Push(left, right);
            if (filled < count)
            {
                // Кінець файла: дотягнути тишею цей буфер і сказати про кінець один раз.
                Array.Clear(buffer, offset + filled, count - filled);
                if (!_finishedRaised) { _finishedRaised = true; Finished?.Invoke(); }
                return count;
            }
            return count;
        }
    }

    /// Кінець файла: «по колу» — на початок у тому самому читанні (щілини немає).
    bool Rewind()
    {
        if (!Loops) return false;
        _reader.Position = 0;
        return _reader.Length > 0;
    }

    public void Dispose()
    {
        try { _output?.Stop(); } catch { }
        _output?.Dispose();
        _output = null;
        _reader.Dispose();
    }
}
