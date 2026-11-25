// =============================================================================
//  MediaPlayerModel.cs — медіаплеєр (16) головного вікна
// =============================================================================
//  За MediaPlayerModel.swift Mac 1.3.9: файл з диска й потік за адресою, кадр у
//  передпоказ і в зал, звукова доріжка, гучність, повтор, автозапуск, список
//  файлів (пам'ятається між запусками). Екран у залі один: текст, що пішов у зал,
//  ставить кадру «поступку» (slideTookOver), «Показати»/«грати» її знімає;
//  затемнення, «Сховати» й порожній слайд гасять і відео.
//  Відмінність від Mac: грає LibVLC, тому rtsp/rtmp/udp/mms відкриваються
//  (на Mac — «на macOS не відтворюється»).
// =============================================================================

using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public sealed class MediaPlayerModel
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    public enum ActivityKind { Idle, OpeningFile, OpeningStream, Closing }
    public readonly record struct Activity(ActivityKind Kind, bool Stream = false);

    public enum FailureKind { CannotOpen, BadUrl, UnsupportedScheme, PageLink, Unavailable, YouTube }
    public readonly record struct Failure(FailureKind Kind, string Detail = "");

    /// Що гасить кадр у залі.
    [Flags]
    public enum ScreenSuppression
    {
        None = 0,
        /// F12 — затемнення: «чорний екран» без застережень.
        Blackout = 1 << 0,
        /// Esc — «Сховати слайд»: вікна слайда не показано.
        HiddenSlide = 1 << 1,
        /// Ctrl+F5 — порожній слайд.
        BlankSlide = 1 << 2,
        /// У зал пішов текст: екран один, два джерела разом не живуть.
        SlideTookOver = 1 << 3,
        /// «Зупинити»: фільм відмотано на початок і знято з екрана.
        Stopped = 1 << 4,
    }

    /// Сайти, що за посиланням на сторінку потоку не віддають.
    public static readonly IReadOnlySet<string> PageOnlyHosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "vimeo.com", "www.vimeo.com", "rutube.ru", "www.rutube.ru",
        "facebook.com", "www.facebook.com", "fb.watch", "ok.ru", "www.ok.ru",
    };

    /// Схеми, які відкриває LibVLC.
    public static readonly IReadOnlySet<string> PlayableSchemes = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
    {
        "file", "http", "https", "rtsp", "rtmp", "rtp", "udp", "mms", "mmsh", "srt",
    };

    // ── Стан для вигляду ────────────────────────────────────────────────────

    public string? MediaUrl { get; private set; }
    public string Title { get; private set; } = "";
    public bool IsStream { get; private set; }
    public bool IsPlaying { get; private set; }
    public bool HasVideo { get; private set; }
    public double Duration { get; private set; }
    public double Position { get; private set; }
    public List<MediaEngine.Track> AudioTracks { get; private set; } = new();
    public string? SelectedAudioTrackId { get; private set; }
    public Activity CurrentActivity { get; private set; }
    public Failure? CurrentFailure { get; private set; }
    public List<MediaEngine.Device> AudioDevices { get; private set; } = new();

    /// Щось змінилося — вигляду перемалюватися.
    public event Action? Changed;
    /// Кадр у залі показати чи прибрати (ставить AppState).
    public Action? OnScreenChanged;
    /// «Показати це в залі»: файл відкрили чи він пішов.
    public Action? OnWantsHall;

    // ── Налаштування — [mediaplayer] оригіналу ──────────────────────────────

    bool _repeats, _autoPlay = true, _videoToPreview = true, _videoToScreen = true, _isMuted;
    double _volume = 1;
    string? _audioDeviceId;
    ScreenSuppression _suppression;

    /// «Повтор» (PSBVideoRepeate).
    public bool Repeats { get => _repeats; set { _repeats = value; Notify(); } }
    /// «Відтворити після відкриття» (PngSBAutoPlay).
    public bool AutoPlay { get => _autoPlay; set { _autoPlay = value; Notify(); } }
    /// «Відображати відео у вікні передпоказу» (CBShowVideoOnPreview).
    public bool VideoToPreview { get => _videoToPreview; set { _videoToPreview = value; SyncScreen(); } }

    /// «Відображати відео на екрані проектора» (PngSBVideoToScreen). Увімкнули —
    /// людина просить кадр у зал: знімаємо поступку й просимо зал (на Mac кнопка
    /// колись працювала лише з другого натискання).
    public bool VideoToScreen
    {
        get => _videoToScreen;
        set
        {
            var was = _videoToScreen;
            _videoToScreen = value;
            if (value && !was)
            {
                _suppression &= ~(ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped);
                SyncScreen();
                OnWantsHall?.Invoke();
                return;
            }
            SyncScreen();
        }
    }

    /// «Без звуку» (PngSBAudioMute).
    public bool IsMuted { get => _isMuted; set { _isMuted = value; _engine?.SetMute(value); _embed?.SetMuted(value); Notify(); } }

    /// «Гучність:» (LMEdiaVolume), 0…1 — положення повзунка.
    public double Volume { get => _volume; set { _volume = Math.Clamp(value, 0, 1); _engine?.SetVolume(Gain(_volume)); _embed?.SetVolume(Gain(_volume)); Notify(); } }

    /// Положення повзунка → підсилення: квадрат (половина повзунка — −12 дБ, а не −6),
    /// щоб повзунок був корисним на всій довжині.
    public static float Gain(double position)
    {
        var clamped = Math.Clamp(position, 0, 1);
        return (float)(clamped * clamped);
    }

    /// Вибраний звуковий вихід (null — системний).
    public string? AudioDeviceId { get => _audioDeviceId; set { _audioDeviceId = value; _engine?.SetAudioDevice(value); Notify(); } }

    public ScreenSuppression Suppression
    {
        get => _suppression;
        set { if (_suppression == value) return; _suppression = value; SyncScreen(); }
    }

    public void Suppress(ScreenSuppression flags) => Suppression = _suppression | flags;
    public void Allow(ScreenSuppression flags) => Suppression = _suppression & ~flags;

    /// Чи видно кадр у залі зараз.
    public bool IsVideoOnScreen => ShowsVideoOnScreen(VideoToScreen, HasVideo, HasMedia, _suppression);

    /// Чи є що показувати: відкритий файл або захоплений екран.
    public bool HasMedia => MediaUrl != null || IsCapturing;

    // ── Захоплення екрана (як isCapturing на Mac) ────────────────────────────

    /// Іде захоплення екрана: кадри приходять ззовні, а не з файла. Для решти програми
    /// це такий самий кадр, як у фільму: зал, живий екран і указка різниці не знають.
    public bool IsCapturing { get; private set; }

    /// Зупинити сам потік захоплення (ставить AppState: модель плеєра про GDI не знає).
    public Action? StopCaptureStream;

    /// Почати показ захопленого екрана. Відкритий файл закривається: екран у залі один.
    public void BeginCapture(string title)
    {
        if (MediaUrl != null) Close(quiet: true);
        IsCapturing = true;
        HasVideo = true;
        Title = title;
        _suppression &= ~(ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped);
        SyncScreen();
    }

    /// Зупинити показ захопленого екрана.
    public void EndCapture()
    {
        if (!IsCapturing) return;
        IsCapturing = false;
        HasVideo = MediaUrl != null && _fileHasVideo;
        if (MediaUrl == null) Title = "";
        VideoFrames.Shared.Clear();
        SyncScreen();
    }

    /// Захоплення поступається тому, що показали замість нього (фільм, картинка, сторінка
    /// показу): інакше його кадри затирали б щойно показане (власник на Mac: «презентации
    /// и изображения вместо показа своих слайдов выдают захват экрана»).
    public void YieldCapture()
    {
        if (!IsCapturing) return;
        EndCapture();
        StopCaptureStream?.Invoke();
    }

    public static bool ShowsVideoOnScreen(bool videoToScreen, bool hasVideo, bool hasMedia, ScreenSuppression suppression) =>
        videoToScreen && hasVideo && hasMedia && suppression == ScreenSuppression.None;

    /// Чи йде кадр у передпоказ (як applyVideo NativeSlidePreview).
    public bool ShowsVideoInPreview => VideoToPreview && HasVideo && MediaUrl != null
                                       && (_suppression & (ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped)) == 0;

    /// Крок кнопок «Перемотати назад/вперед».
    public const double ShuttleStep = 5;

    public MediaFileFilters Filters { get; private set; } = MediaFileFilters.BuiltIn;

    // ── Внутрішнє ───────────────────────────────────────────────────────────

    MediaEngine? _engine;
    bool _isScrubbing, _fileHasVideo, _pauseOnStart, _configured;
    int _activityToken;

    public readonly VideoFrames Frames = VideoFrames.Shared;

    MediaEngine? Engine()
    {
        if (_engine != null) return _engine;
        if (!MediaEngine.EnsureLoaded()) return null;
        var engine = _engine = new MediaEngine(Frames);
        engine.Playing += () =>
        {
            if (_pauseOnStart)
            {
                // Автозапуск вимкнено: перший кадр показано — стоїмо на ньому, звук назад.
                _pauseOnStart = false;
                engine.Pause();
                engine.SetMute(_isMuted);
                IsPlaying = false;
            }
            else IsPlaying = true;
            SetActivity(new Activity(ActivityKind.Idle));
            CurrentFailure = null;
            ReloadTracks();
            Notify();
        };
        engine.Paused += () => { IsPlaying = false; Notify(); };
        engine.Stopped += () => { IsPlaying = false; Notify(); };
        engine.EndReached += HandleEnd;
        engine.Failed += () =>
        {
            CurrentFailure = new Failure(FailureKind.CannotOpen);
            IsPlaying = false;
            SetActivity(new Activity(ActivityKind.Idle));
            Notify();
        };
        engine.TimeChanged += seconds => { if (_isScrubbing) return; Position = seconds; Notify(); };
        engine.LengthChanged += seconds => { if (seconds > 0) { Duration = seconds; Notify(); } };
        engine.VideoStarted += () =>
        {
            if (_fileHasVideo) return;
            _fileHasVideo = true;
            HasVideo = true;
            SyncScreen();
        };
        engine.TracksChanged += () => { ReloadTracks(); Notify(); };
        engine.SetVolume(Gain(_volume));
        engine.SetMute(_isMuted);
        ReloadAudioDevices();
        if (_audioDeviceId != null) engine.SetAudioDevice(_audioDeviceId);
        return engine;
    }

    void Notify() => Changed?.Invoke();

    void SyncScreen()
    {
        // Своїм вікном плеєр не живе: слайд і відео приходять у зал одним екраном.
        OnScreenChanged?.Invoke();
        Notify();
    }

    // ── Налаштування ────────────────────────────────────────────────────────

    /// Прочитати налаштування з диска (у фоні): списки розширень і [mediaplayer].
    /// `force` — перечитати й після першого разу (майстер імпорту, «Параметри»).
    public void ReloadSettingsFromDisk(string? dataRoot, bool force = false)
    {
        if (!force && _configured) return;
        Task.Run(() =>
        {
            var ini = IniSettings.LocateConfig();
            var filters = MediaFileFilters.Load(dataRoot, ini != null ? Path.GetDirectoryName(ini) : null);
            IniSettings? config = null;
            try { if (ini != null) config = IniSettings.FromFile(ini); } catch { }
            var settings = new MediaPlayerSettings(config);
            Dispatcher.UIThread.Post(() =>
            {
                if (!force && _configured) return;
                _configured = true;
                Filters = filters;
                Apply(settings);
            });
        });
    }

    public void Apply(MediaPlayerSettings settings)
    {
        _repeats = settings.Repeats;
        _autoPlay = settings.AutoPlay;
        _videoToPreview = settings.VideoToPreview;
        _videoToScreen = settings.VideoToScreen;
        Volume = settings.Volume;
        IsMuted = settings.IsMuted;
        SelectAudioDevice(settings.AudioDevice);
        SyncScreen();
    }

    /// Вихід за номером, як його пише `MediaDefaultAudioDevice`: 0 — системний,
    /// далі — порядковий номер у списку виходів.
    public void SelectAudioDevice(int number)
    {
        if (number <= 0) { AudioDeviceId = null; return; }
        ReloadAudioDevices();
        AudioDeviceId = number <= AudioDevices.Count ? AudioDevices[number - 1].Id : null;
    }

    public int AudioDeviceNumber
    {
        get { var i = AudioDevices.FindIndex(d => d.Id == _audioDeviceId); return i < 0 ? 0 : i + 1; }
        set => SelectAudioDevice(value);
    }

    /// Звукові виходи для «Параметрів» (програвач піднімається, якщо його ще не було).
    public List<MediaEngine.Device> ListAudioDevices()
    {
        Engine();
        ReloadAudioDevices();
        return AudioDevices;
    }

    public void ReloadAudioDevices()
    {
        AudioDevices = _engine?.AudioDevices() ?? new List<MediaEngine.Device>();
        // Перший у списку LibVLC — «Default»: системний вихід у нас окремо (0).
        AudioDevices = AudioDevices.Where(d => d.Id.Length > 0).ToList();
        if (_audioDeviceId != null && AudioDevices.All(d => d.Id != _audioDeviceId)) _audioDeviceId = null;
    }

    public MediaPlayerSettings CurrentSettings => new()
    {
        Repeats = Repeats, AutoPlay = AutoPlay, VideoToPreview = VideoToPreview, VideoToScreen = VideoToScreen,
        Volume = Volume, IsMuted = IsMuted, AudioDevice = AudioDeviceNumber,
    };

    // ── Відкриття ───────────────────────────────────────────────────────────

    /// «Відкрити медіафайл» (16.1) і перетягування файла у вікно плеєра.
    public void Open(string path)
    {
        // Пункт списку може бути посиланням (ролик YouTube, потік) — тоді як «Відкрити URL».
        if (IsLink(path) && Uri.TryCreate(path, UriKind.Absolute, out var link)) { OpenLink(link); return; }
        Load(path, false);
    }

    /// Посилання, а не файл: адреса зі схемою (крім file) і вузлом.
    public static bool IsLink(string entry) =>
        Uri.TryCreate(entry, UriKind.Absolute, out var url) && !url.IsFile && url.Scheme != "file" && !string.IsNullOrEmpty(url.Host);

    void OpenLink(Uri url)
    {
        if (YouTubeLink.IsYouTube(url)) { OpenYouTube(url); return; }
        Load(url.AbsoluteUri, true);
    }

    /// «Відкрити URL з медіаконтентом» (16.2): розбір рядка з вікна «Введіть URL медіапотоку».
    public bool OpenStream(string text)
    {
        var trimmed = text.Trim();
        if (!Uri.TryCreate(trimmed, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host) && !url.IsFile)
        {
            CurrentFailure = new Failure(FailureKind.BadUrl);
            Notify();
            return false;
        }
        if (!PlayableSchemes.Contains(url.Scheme))
        {
            CurrentFailure = new Failure(FailureKind.UnsupportedScheme, url.Scheme);
            Notify();
            return false;
        }
        if (YouTubeLink.IsYouTube(url)) return OpenYouTube(url);
        if (PageOnlyHosts.Contains(url.Host))
        {
            CurrentFailure = new Failure(FailureKind.PageLink, url.Host.ToLowerInvariant());
            Notify();
            return false;
        }
        Load(url.IsFile ? url.LocalPath : url.AbsoluteUri, !url.IsFile);
        return true;
    }

    // ── Вбудований програвач YouTube (openYouTube на Mac) ───────────────────

    YouTubeEmbedPlayer? _embed;
    /// Ролик іде вбудованим програвачем (без yt-dlp).
    public bool IsYouTubeEmbed => _embed != null;
    /// Вбудований програвач (перевірці звуку).
    public YouTubeEmbedPlayer? Embed => _embed;

    void OpenEmbed(string id, string link)
    {
        YieldCapture();
        Close(quiet: true);
        _suppression &= ~ScreenSuppression.Stopped;
        SetActivity(new Activity(ActivityKind.OpeningStream, true));
        CurrentFailure = null;
        MediaUrl = link;
        IsStream = true;
        Title = "YouTube · " + (LinkTitles.TryGetValue(link, out var known) ? known : id);
        var autoplay = AutoPlay || _playOnReady;
        var engine = _embed = new YouTubeEmbedPlayer(id, autoplay);
        engine.OnReady = () =>
        {
            if (_embed != engine) return;
            engine.SetVolume(Gain(_volume));
            engine.SetMuted(_isMuted);
            // У ролика YouTube картинка є завжди — це не звуковий потік.
            _fileHasVideo = true;
            HasVideo = true;
            SetActivity(new Activity(ActivityKind.Idle));
            SyncScreen();
            if (AutoPlay || _playOnReady) { _playOnReady = false; Play(); }
            else _ = engine.Snapshot();
        };
        engine.OnState = state =>
        {
            if (_embed != engine) return;
            switch (state)
            {
                case YouTubeEmbedPlayer.State.Playing: IsPlaying = true; engine.StartSnapshots(); Notify(); break;
                case YouTubeEmbedPlayer.State.Paused or YouTubeEmbedPlayer.State.Cued or YouTubeEmbedPlayer.State.Unstarted:
                    IsPlaying = false; engine.StopSnapshots(); _ = engine.Snapshot(); Notify(); break;
                case YouTubeEmbedPlayer.State.Ended: HandleEnd(); break;
            }
        };
        engine.OnError = code =>
        {
            if (_embed != engine) return;
            Journal.Say($"плеєр: вбудований YouTube {id} — помилка {code}");
            CurrentFailure = new Failure(FailureKind.YouTube, Captions.T("YouTube не отдал ролик (код %s)", code.ToString()));
            SetActivity(new Activity(ActivityKind.Idle));
            Notify();
        };
        engine.OnTime = (current, total) =>
        {
            if (_embed != engine || _isScrubbing) return;
            Position = current;
            if (total > 0) Duration = total;
            Notify();
        };
        FetchTitle(id, link);
        SyncScreen();
        Notify();
    }

    // ── YouTube (через yt-dlp, як resolveYouTube на Mac) ─────────────────────

    /// Що відповів yt-dlp останнього разу, коли не вийшло, — «Параметрам».
    public string? YouTubeToolProblem { get; private set; }
    CancellationTokenSource? _youTubeJob;
    int _resolveToken;

    bool OpenYouTube(Uri url)
    {
        var id = YouTubeLink.VideoID(url) ?? url.Host;
        var found = YouTubeResolver.Locate();
        if (found.Tool is not { } tool)
        {
            // Без yt-dlp ролик однаково йде — вбудованим програвачем (як на Mac).
            YouTubeToolProblem = found.Note;
            OpenEmbed(id, url.AbsoluteUri);
            return true;
        }
        YieldCapture();
        Close(quiet: true);
        _suppression &= ~ScreenSuppression.Stopped;
        SetActivity(new Activity(ActivityKind.OpeningStream, true));
        CurrentFailure = null;
        MediaUrl = url.AbsoluteUri;
        IsStream = true;
        Title = "YouTube · " + id;
        var token = ++_resolveToken;
        _youTubeJob?.Cancel();
        var job = _youTubeJob = new CancellationTokenSource();
        var link = url.AbsoluteUri;
        Task.Run(() => YouTubeResolver.Obtain(link, tool, job.Token)).ContinueWith(task => Dispatcher.UIThread.Post(() =>
        {
            if (token != _resolveToken || job.IsCancellationRequested) return;
            if (task.Exception?.GetBaseException() is { } error)
            {
                YouTubeToolProblem = error.Message;
                Journal.Say($"плеєр: YouTube {id} — {error.Message}; граю вбудованим програвачем");
                // Не вийшло — ролик однаково йде, вбудованим програвачем (як на Mac).
                OpenEmbed(id, link);
                return;
            }
            var found = task.Result;
            YouTubeToolProblem = null;
            Load(found.Url, true, found.Audio, found.UserAgent, found.Referer);
            Title = "YouTube · " + (found.Title.Length > 0 ? found.Title : id);
            if (found.Title.Length > 0 && Playlist.Contains(link)) { LinkTitles[link] = found.Title; RememberPlaylist(); }
            if (found.Duration > 0 && Duration <= 0) Duration = found.Duration;
            Notify();
        }));
        Notify();
        return true;
    }

    void Load(string target, bool stream, string? audio = null, string? userAgent = null, string? referer = null)
    {
        _suppression &= ~ScreenSuppression.Stopped;
        // Відкрили файл — захоплення екрана більше не показане.
        YieldCapture();
        Close(quiet: true);
        // Відкрите будь-яким шляхом стає в список — інакше він брехав би про відкрите.
        if (!stream)
        {
            var known = Playlist.FindIndex(p => SamePath(p, target));
            if (known >= 0) PlaylistIndex = known;
            else { Playlist.Add(target); PlaylistIndex = Playlist.Count - 1; RememberPlaylist(); }
        }
        SetActivity(new Activity(stream ? ActivityKind.OpeningStream : ActivityKind.OpeningFile));
        CurrentFailure = null;
        MediaUrl = target;
        IsStream = stream;
        Title = stream ? target : Path.GetFileName(target);
        if (Engine() is not { } engine)
        {
            CurrentFailure = new Failure(FailureKind.Unavailable, MediaEngine.Unavailable ?? "");
            SetActivity(new Activity(ActivityKind.Idle));
            Notify();
            return;
        }
        // Наступний «після кінця» грає й без автозапуску: людина просила йти далі сама.
        var playNow = AutoPlay || _playOnReady;
        _playOnReady = false;
        _pauseOnStart = !playNow;
        engine.SetMute(_pauseOnStart || _isMuted);
        engine.SetVolume(Gain(_volume));
        try { engine.Open(target, stream, audio, userAgent, referer); }
        catch (Exception error)
        {
            Journal.Say($"плеєр: {target} — {error.Message}");
            CurrentFailure = new Failure(FailureKind.CannotOpen);
            SetActivity(new Activity(ActivityKind.Idle));
        }
        if (playNow)
        {
            // Пішов фільм — його й показують: поступку тексту знімаємо одразу.
            _suppression &= ~(ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped);
            OnWantsHall?.Invoke();
        }
        SyncScreen();
    }

    /// Закрити файл («Закриваємо медіафайл…» — заметний час, як в оригіналі).
    public void Close() => Close(quiet: false);

    void Close(bool quiet)
    {
        _youTubeJob?.Cancel();
        _youTubeJob = null;
        _resolveToken++;
        var wasOpen = MediaUrl != null;
        var wasStream = IsStream;
        _engine?.Close();
        if (_embed is { } embed)
        {
            _embed = null;
            embed.Dispose();
            VideoFrames.Shared.Clear();
        }
        MediaUrl = null;
        Title = "";
        IsStream = false;
        IsPlaying = false;
        _fileHasVideo = false;
        HasVideo = false;
        Duration = 0;
        Position = 0;
        AudioTracks = new();
        SelectedAudioTrackId = null;
        _pauseOnStart = false;
        SyncScreen();
        if (quiet || !wasOpen) { SetActivity(new Activity(ActivityKind.Idle)); return; }
        SetActivity(new Activity(ActivityKind.Closing, wasStream), 0.6);
    }

    void SetActivity(Activity value, double? idleAfter = null)
    {
        var token = ++_activityToken;
        CurrentActivity = value;
        Notify();
        if (idleAfter is not { } seconds) return;
        DispatcherTimer.RunOnce(() =>
        {
            if (_activityToken != token) return;
            CurrentActivity = new Activity(ActivityKind.Idle);
            Notify();
        }, TimeSpan.FromSeconds(seconds));
    }

    // ── Керування ───────────────────────────────────────────────────────────

    /// «Відтворити/пауза» (16.3) — вона ж Ctrl+P.
    public void PlayPause()
    {
        if (MediaUrl == null) return;
        if (IsPlaying) Pause(); else Play();
    }

    public void Play()
    {
        if (_embed is { } embed && MediaUrl != null)
        {
            if (Duration > 0 && Position >= Duration - 0.25) embed.Seek(0);
            embed.Play();
            IsPlaying = true;
            _suppression &= ~(ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped);
            OnWantsHall?.Invoke();
            SyncScreen();
            return;
        }
        if (MediaUrl == null || _engine == null) return;
        // Дійшли до кінця й тиснуть «грати» — з початку.
        if (Duration > 0 && Position >= Duration - 0.25) { _engine.Restart(); }
        else _engine.Play();
        IsPlaying = true;
        // Пішов фільм — значить його показують.
        _suppression &= ~(ScreenSuppression.SlideTookOver | ScreenSuppression.Stopped);
        OnWantsHall?.Invoke();
        SyncScreen();
    }

    public void Pause()
    {
        _engine?.Pause();
        _embed?.Pause();
        IsPlaying = false;
        Notify();
    }

    /// «Зупинити»: пауза, на початок і з екрана.
    public void Stop()
    {
        Pause();
        Seek(0);
        Suppress(ScreenSuppression.Stopped);
    }

    public void ToBegin() => Seek(0);

    public void ToEnd()
    {
        if (Duration > 0) Seek(Math.Max(0, Duration - 0.1));
    }

    public void Shuttle(int direction) => Seek(Position + direction * ShuttleStep);

    public void Seek(double seconds)
    {
        if (MediaUrl == null || (_engine == null && _embed == null)) return;
        var clamped = Duration > 0 ? Math.Clamp(seconds, 0, Duration) : Math.Max(0, seconds);
        Position = clamped;
        if (_embed is { } embed) embed.Seek(clamped); else _engine!.Seek(clamped);
        Notify();
    }

    public void BeginScrub() => _isScrubbing = true;
    public void Scrub(double seconds) { Position = seconds; Notify(); }
    public void EndScrub() { _isScrubbing = false; Seek(Position); }

    void HandleEnd()
    {
        if (!Repeats)
        {
            // «Наступний» — як у фонограм: кінець пункту відкриває наступний у списку.
            if (PlaysNext && PlaylistIndex is { } current && current + 1 < Playlist.Count)
            {
                _playOnReady = true;
                OpenFromPlaylist(current + 1);
                return;
            }
            IsPlaying = false;
            Position = Duration;
            Notify();
            return;
        }
        // «Повтор»: без зупинки, щоб заставка крутилася все зібрання.
        if (_embed is { } embed) { embed.Seek(0); embed.Play(); }
        else _engine?.Restart();
    }

    // ── Звукові доріжки ─────────────────────────────────────────────────────

    void ReloadTracks()
    {
        if (_engine == null) return;
        AudioTracks = _engine.AudioTracks();
        SelectedAudioTrackId = _engine.SelectedAudioTrack;
    }

    /// «Вибрати звукову доріжку» (16.6).
    public void SelectAudioTrack(string id)
    {
        SelectedAudioTrackId = id;
        _engine?.SelectAudioTrack(id);
        Notify();
    }

    // ── Список файлів ───────────────────────────────────────────────────────

    public List<string> Playlist { get; private set; } = new();
    public int? PlaylistIndex { get; private set; }
    /// Пам'ятати список між запусками (вмикає лише плеєр людини, не перевірки).
    public bool RemembersPlaylist;
    const string PlaylistKey = "mediaPlaylist", TitlesKey = "mediaPlaylistTitles", PlaysNextKey = "mediaPlaysNext";

    /// «Після кінця — наступний зі списку», як у фонограм (власник: ролики YouTube і
    /// відео «добавляя несколько в свой плейлист… в своей очередности»). «Повтор» старший.
    public bool PlaysNext
    {
        get => _playsNext;
        set { _playsNext = value; if (RemembersPlaylist) Defaults.Set(PlaysNextKey, value); Notify(); }
    }
    bool _playsNext, _playOnReady;

    /// Назви посилань у списку (ролик YouTube — його назва), пам'ятаються разом зі списком.
    public Dictionary<string, string> LinkTitles { get; private set; } = new();

    void RememberPlaylist()
    {
        if (!RemembersPlaylist) return;
        Defaults.Set(PlaylistKey, string.Join("\n", Playlist));
        Defaults.Set(TitlesKey, string.Join("\n", LinkTitles.Where(p => Playlist.Contains(p.Key)).Select(p => p.Key + "\t" + p.Value.Replace('\n', ' ').Replace('\t', ' '))));
    }

    /// Повернути список, зібраний минулого разу (зниклі файли — мовчки пропустити; посилання — як є).
    public void RestorePlaylist()
    {
        if (!RemembersPlaylist || Playlist.Count > 0) return;
        if (Defaults.Has(PlaysNextKey)) _playsNext = Defaults.Bool(PlaysNextKey);
        foreach (var line in (Defaults.String(TitlesKey) ?? "").Split('\n'))
            if (line.Split('\t', 2) is [var link, var title] && link.Length > 0) LinkTitles[link] = title;
        var saved = Defaults.String(PlaylistKey);
        if (string.IsNullOrEmpty(saved)) return;
        Playlist = saved.Split('\n').Where(p => p.Length > 0 && (IsLink(p) || File.Exists(p))).ToList();
        Notify();
    }

    /// Що написати в рядку списку: ім'я файла, «YouTube · назва» чи адреса потоку.
    public string PlaylistCaption(string entry)
    {
        if (!IsLink(entry)) return Path.GetFileName(entry);
        var url = new Uri(entry);
        if (LinkTitles.TryGetValue(entry, out var title) && title.Length > 0) return YouTubeLink.IsYouTube(url) ? "YouTube · " + title : title;
        if (YouTubeLink.VideoID(url) is { } id) return "YouTube · " + id;
        return url.Host + url.AbsolutePath;
    }

    /// Картинки й презентації в список плеєра не беремо: у них свої вкладки.
    public static bool BelongsToShow(string path) =>
        new[] { "jpg", "jpeg", "png", "bmp", "tif", "tiff", "heic", "gif", "webp", "pptx", "ppsx", "potx", "pptm", "ppsm", "pdf" }
            .Contains(Path.GetExtension(path).TrimStart('.').ToLowerInvariant());

    /// Додати файли в список (за іменами); відкривається перший доданий — якщо нічого не грало.
    public void AddToPlaylist(IEnumerable<string> paths)
    {
        var wanted = paths.Where(p => (Filters.Accepts(p) || File.Exists(p)) && !BelongsToShow(p))
            .OrderBy(p => Path.GetFileName(p), Comparer<string>.Create(SwiftText.LocalizedStandardCompare)).ToList();
        string? first = null;
        foreach (var path in wanted)
        {
            if (Playlist.Any(p => SamePath(p, path))) continue;
            Playlist.Add(path);
            first ??= path;
        }
        RememberPlaylist();
        if (first != null && MediaUrl == null) OpenFromPlaylist(Playlist.FindIndex(p => SamePath(p, first)));
        Notify();
    }

    /// Додати в список посилання: ролики YouTube і потоки — кілька за раз, кожне з нового
    /// рядка чи через пробіл. Скільки додано; нічого не відкрито — відкривається перше додане.
    public int AddLinks(string text)
    {
        var pieces = text.Split(new[] { ' ', '\n', '\r', '\t', ',', ';' }, StringSplitOptions.RemoveEmptyEntries)
            .Select(p => p.Trim('<', '>', '"', '\'')).Where(p => p.Length > 0);
        var added = new List<string>();
        Failure? problem = null;
        foreach (var piece in pieces)
        {
            if (!Uri.TryCreate(piece, UriKind.Absolute, out var url) || string.IsNullOrEmpty(url.Host)) { problem = new Failure(FailureKind.BadUrl); continue; }
            if (!PlayableSchemes.Contains(url.Scheme) || url.IsFile) { problem = new Failure(FailureKind.UnsupportedScheme, url.Scheme); continue; }
            if (PageOnlyHosts.Contains(url.Host)) { problem = new Failure(FailureKind.PageLink, url.Host.ToLowerInvariant()); continue; }
            if (YouTubeLink.IsYouTube(url) && YouTubeLink.VideoID(url) == null) { problem = new Failure(FailureKind.PageLink, url.Host.ToLowerInvariant()); continue; }
            // Той самий ролик іншим записом (youtu.be і watch?v=) — уже в списку.
            if (YouTubeLink.VideoID(url) is { } id && Playlist.Any(p => IsLink(p) && YouTubeLink.VideoID(p) == id)) continue;
            var entry = url.AbsoluteUri;
            if (Playlist.Contains(entry)) continue;
            Playlist.Add(entry);
            added.Add(entry);
            if (YouTubeLink.VideoID(url) is { } video) FetchTitle(video, entry);
        }
        if (added.Count == 0)
        {
            if (problem != null) { CurrentFailure = problem; Notify(); }
            return 0;
        }
        CurrentFailure = null;
        RememberPlaylist();
        if (MediaUrl == null) OpenFromPlaylist(Playlist.IndexOf(added[0]));
        Notify();
        return added.Count;
    }

    static readonly System.Net.Http.HttpClient Web = new() { Timeout = TimeSpan.FromSeconds(8) };

    /// Назва ролика для рядка списку — відкритим oEmbed YouTube, без ключів і входу.
    void FetchTitle(string id, string entry)
    {
        if (LinkTitles.ContainsKey(entry) || Program.Snapshotting && !FetchesTitlesInSnapshot) return;
        var address = "https://www.youtube.com/oembed?format=json&url=" + Uri.EscapeDataString("https://www.youtube.com/watch?v=" + id);
        Task.Run(async () =>
        {
            try
            {
                var json = System.Text.Json.Nodes.JsonNode.Parse(await Web.GetStringAsync(address));
                if (json?["title"]?.GetValue<string>() is { Length: > 0 } title)
                    Dispatcher.UIThread.Post(() => { LinkTitles[entry] = title; RememberPlaylist(); Notify(); });
            }
            catch { }
        });
    }

    /// Знімкам перевірки — підтягувати назви з мережі (за замовчанням у знімках ні).
    public static bool FetchesTitlesInSnapshot { get; set; }

    /// Пересунути пункт списку (↑/↓): порядок показу — свій, як у фонограм.
    public void MovePlaylistItem(int position, int offset)
    {
        var target = position + offset;
        if (position < 0 || position >= Playlist.Count || target < 0 || target >= Playlist.Count) return;
        (Playlist[position], Playlist[target]) = (Playlist[target], Playlist[position]);
        if (PlaylistIndex == position) PlaylistIndex = target;
        else if (PlaylistIndex == target) PlaylistIndex = position;
        RememberPlaylist();
        Notify();
    }

    public void OpenFromPlaylist(int position)
    {
        if (position < 0 || position >= Playlist.Count) return;
        PlaylistIndex = position;
        Open(Playlist[position]);
        // Посилання відкривається як потік — номер у списку лишаємо (Load потоку його не ставить).
        PlaylistIndex = position;
    }

    public void RemoveFromPlaylist(int position)
    {
        if (position < 0 || position >= Playlist.Count) return;
        var removed = Playlist[position];
        Playlist.RemoveAt(position);
        // Посилання YouTube грає з розібраної адреси — тож і за номером, не лише за адресою.
        if ((MediaUrl != null && SamePath(removed, MediaUrl)) || position == PlaylistIndex) { Close(); PlaylistIndex = null; }
        else if (PlaylistIndex is { } current && current > position) PlaylistIndex = current - 1;
        LinkTitles.Remove(removed);
        RememberPlaylist();
        Notify();
    }

    public void ClearPlaylist()
    {
        Playlist.Clear();
        PlaylistIndex = null;
        LinkTitles.Clear();
        RememberPlaylist();
        Close();
    }

    static bool SamePath(string one, string two) =>
        string.Equals(one, two, OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal);

    // ── Допоміжне ───────────────────────────────────────────────────────────

    /// Час у підписі плеєра: «1:23» і «1:02:03».
    public static string TimeText(double seconds)
    {
        if (!double.IsFinite(seconds) || seconds < 0) return "0:00";
        var total = (int)Math.Floor(seconds);
        int s = total % 60, m = total / 60 % 60, h = total / 3600;
        return h > 0 ? $"{h}:{m:00}:{s:00}" : $"{m}:{s:00}";
    }
}
