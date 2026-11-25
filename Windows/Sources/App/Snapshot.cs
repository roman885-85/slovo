// =============================================================================
//  Snapshot.cs — знімки вікон без екрана (ключ --snapshot <тека>)
// =============================================================================
//  Програма піднімається без вікон на екрані (Avalonia без платформи, той самий
//  Skia), відкриває вікна в заданому розмірі й записує, що в них намальовано, у
//  PNG. Так Windows-версію порівнюємо поруч зі знімками Mac 1.3.9 — не заважаючи
//  людині за комп'ютером і не залежачи від того, що закриває вікно на екрані.
// =============================================================================

using Avalonia;
using Slovo.Core;
using Avalonia.Controls;
using Avalonia.Headless;
using Avalonia.Styling;
using Avalonia.Threading;

namespace Slovo.App;

/// Вікно, якому перед знімком треба пройти кілька кроків і дочекатися своєї роботи у
/// фоні (каталог ресурсів, опис джерела, перенесення, установлення).
public interface ISnapshotWork
{
    /// Почати: ключі запуску кажуть, що саме зробити.
    void Begin(string[] args);
    /// Ще працює — знімок чекає (не довше 5 хвилин).
    bool IsWorking { get; }
}

public static class Snapshot
{
    /// Сцени знімків: ім'я файлу → як побудувати вікно (і що зробити перед знімком).
    public static readonly List<(string Name, Func<Window> Make, Size Size)> Scenes = new();

    public static int Run(string folder, string[] args)
    {
        Directory.CreateDirectory(folder);
        // Вивід у файл — UTF-8 (інакше Windows пише кодовою сторінкою консолі, і «✓», «і» зникають).
        if (OperatingSystem.IsWindows() && Console.IsOutputRedirected) Console.OutputEncoding = new System.Text.UTF8Encoding(false);
        AppBuilder.Configure<SlovoApplication>()
            .UseSkia()
            .UseHeadless(new AvaloniaHeadlessPlatformOptions { UseHeadlessDrawing = false })
            .WithInterFont()
            .SetupWithoutStarting();

        var dark = args.Contains("--dark");
        if (Application.Current is { } app) app.RequestedThemeVariant = dark ? ThemeVariant.Dark : ThemeVariant.Light;
        Palette.NotifyChanged();

        var only = Array.IndexOf(args, "--only") is var o and >= 0 && o + 1 < args.Length ? args[o + 1] : null;
        ShowDocuments.Install();
        ModuleImportWiring.Install();
        ResourcesWindow.Install();
        SnapshotScenes.Register();
        // Заміри відгуку вікна (NativeBench на Mac) — замість знімків.
        if (Array.IndexOf(args, "--bench") is var benchAt and >= 0 && benchAt + 1 < args.Length)
            return Bench.Run(args[benchAt + 1], folder) > 0 ? 0 : 1;
        var count = 0;
        foreach (var (name, make, size) in Scenes)
        {
            if (only != null && !name.Contains(only, StringComparison.OrdinalIgnoreCase)) continue;
            var window = make();
            window.Width = size.Width;
            window.Height = size.Height;
            // Інший розмір вікна (звірка з найменшими знімками Mac): --size 1120x748 або --size min.
            if (Array.IndexOf(args, "--size") is var zi and >= 0 && zi + 1 < args.Length)
            {
                var wanted = args[zi + 1];
                if (wanted == "min") { window.Width = Math.Max(1, window.MinWidth); window.Height = Math.Max(1, window.MinHeight); }
                else if (wanted.Split('x') is { Length: 2 } wh && double.TryParse(wh[0], out var ww) && double.TryParse(wh[1], out var hh)) { window.Width = ww; window.Height = hh; }
            }
            window.Show();
            WaitForLibrary();
            if (window is ISnapshotWork work)
            {
                work.Begin(args);
                var until = DateTime.Now.AddMinutes(5);
                do { Pump(2); Thread.Sleep(40); } while (DateTime.Now < until && work.IsWorking);
                Pump(6);
            }
            if (window is SettingsWindow settings && Array.IndexOf(args, "--tab") is var ti and >= 0 && ti + 1 < args.Length && int.TryParse(args[ti + 1], out var tab))
            {
                settings.Tabs.SelectedIndex = tab - 1;
                Pump(4);
            }
            if (Array.IndexOf(args, "--mode") is var mi and >= 0 && mi + 1 < args.Length && Enum.TryParse<WorkMode>(args[mi + 1], true, out var mode))
            {
                // Інша вкладка: «songs», «text», «pictures»… — як клацання по вкладці.
                AppState.Shared.Mode = mode;
                Signals.Shared.Send(Signals.Kind.Mode);
                WaitForLibrary();
                var until = DateTime.Now.AddSeconds(3);
                do { Pump(2); Thread.Sleep(50); } while (DateTime.Now < until);
            }
            if (Array.IndexOf(args, "--backing") is var bi and >= 0 && bi + 1 < args.Length)
            {
                // Фонограми: «файл|файл» — у список, відкрито останній (як після перетягування й подвійного клацання).
                var backing = AppState.Shared.Backing;
                var files = args[bi + 1].Split('|', StringSplitOptions.RemoveEmptyEntries);
                backing.AddToPlaylist(files);
                backing.OpenFromPlaylist(files.Length - 1);
                var until = DateTime.Now.AddSeconds(20);
                do { Pump(2); Thread.Sleep(50); } while (DateTime.Now < until && backing.Url != null && backing.Waveform == null);
                Pump(4);
                Console.WriteLine($"  фонограми: {backing.Playlist.Count}, відкрито «{backing.Title}» {backing.Duration:0.0} с, хвиля {(backing.Waveform != null ? "є" : "немає")}, помилка «{backing.Error}»");
            }
            if (Array.IndexOf(args, "--drop") is var di and >= 0 && di + 1 < args.Length)
            {
                // Файли, «кинуті» у вікно: «файл|файл» — куди їх розібрано й що відкрилось.
                var files = args[di + 1].Split('|', StringSplitOptions.RemoveEmptyEntries);
                var (kind, chosen) = WindowDrop.Route(files, AppState.Shared.Media.Filters.Accepts);
                var accepted = WindowDrop.Accept(files);
                WaitForLibrary();
                Pump(6);
                Console.WriteLine($"  кинуто {files.Length}: {kind} ({chosen.Count}), прийнято {accepted}, вкладка {AppState.Shared.Mode}, плеєр «{AppState.Shared.Media.Title}»");
            }
            if (args.Contains("--ytdlp-update"))
            {
                // Свій yt-dlp: звірити з GitHub і завантажити/оновити (у теку даних цієї перевірки).
                string result = "";
                var job = Task.Run(async () => result = await YouTubeToolUpdater.CheckAsync());
                while (!job.IsCompleted) { Pump(2); Thread.Sleep(100); }
                Console.WriteLine($"  yt-dlp: {result} — {YouTubeToolUpdater.ManagedPath} ({(File.Exists(YouTubeToolUpdater.ManagedPath) ? new FileInfo(YouTubeToolUpdater.ManagedPath).Length / 1024 / 1024 + " МБ" : "немає")})");
            }
            if (Array.IndexOf(args, "--texts-scan") is var ts and >= 0 && ts + 1 < args.Length)
            {
                // Пошук сумісних текстів («Модулі» → 🔍): що знайдено в теці й скільки тек переглянуто.
                var progress = new SettingsStore.TextScan();
                var found = SettingsStore.ScanForTexts(args[ts + 1], progress, CancellationToken.None);
                Console.WriteLine($"  пошук текстів: тек {progress.Folders}, знайдено {found.Count}");
                foreach (var entry in found) Console.WriteLine($"    {entry.Name} ← {Path.GetRelativePath(args[ts + 1], entry.Path)}");
            }
            if (Array.IndexOf(args, "--hls-ts-check") is var hi and >= 0 && hi + 3 < args.Length)
            {
                // Мультиплексор «Відео по Wi-Fi»: сирий H.264 (з AUD) і AAC (ADTS) → шматки MPEG-TS і список.
                var video = File.ReadAllBytes(args[hi + 1]);
                var audio = File.ReadAllBytes(args[hi + 2]);
                var output = args[hi + 3];
                Directory.CreateDirectory(output);
                var segmenter = new HlsTsSegmenter(hasAudio: true, targetSeconds: 1, keep: 100);
                // Одиниці доступу — між AUD (00 00 00 01 09).
                var units = new List<(int Start, int End)>();
                var last = -1;
                for (var i = 0; i + 4 < video.Length; i++)
                    if (video[i] == 0 && video[i + 1] == 0 && video[i + 2] == 0 && video[i + 3] == 1 && (video[i + 4] & 0x1F) == 9)
                    {
                        if (last >= 0) units.Add((last, i));
                        last = i;
                    }
                if (last >= 0) units.Add((last, video.Length));
                // Кадри AAC — за довжиною з заголовка ADTS.
                var frames = new List<(int Start, int Length)>();
                for (var i = 0; i + 7 <= audio.Length;)
                {
                    if (audio[i] != 0xFF || (audio[i + 1] & 0xF0) != 0xF0) { i++; continue; }
                    var length = ((audio[i + 3] & 0x03) << 11) | (audio[i + 4] << 3) | (audio[i + 5] >> 5);
                    if (length < 7 || i + length > audio.Length) break;
                    frames.Add((i, length));
                    i += length;
                }
                var a = 0;
                for (var f = 0; f < units.Count; f++)
                {
                    long pts = f * 3600L;   // 25 кадрів/с
                    while (a < frames.Count && a * 1920L <= pts) { segmenter.AddAudio(audio.AsSpan(frames[a].Start, frames[a].Length), a * 1920L); a++; }
                    segmenter.AddVideo(video.AsSpan(units[f].Start, units[f].End - units[f].Start), pts);
                }
                // Останній шматок закриває ще один ключовий кадр — для перевірки досить тих, що є.
                var list = segmenter.Playlist() ?? "";
                File.WriteAllText(Path.Combine(output, "stream.m3u8"), list);
                foreach (var line in list.Split('\n').Where(l => l.EndsWith(".ts")))
                    File.WriteAllBytes(Path.Combine(output, line), segmenter.Segment(line)!);
                Console.WriteLine($"  HLS TS: кадрів {units.Count}, порцій AAC {frames.Count}, шматків {segmenter.SegmentCount}, байтів {segmenter.BytesWritten}");
            }
            if (Array.IndexOf(args, "--webvideo-check") is var wv and >= 0 && wv + 1 < args.Length)
            {
                // «Відео по Wi-Fi»: канал іде 8 с (слайд у залі), потім список і шматки — у теку для ffprobe.
                var output = args[wv + 1];
                Directory.CreateDirectory(output);
                WebVideoOutput.ForceEnabled = true;
                AppState.Shared.ShowCurrentSlide();
                WebVideoOutput.Shared.Apply(true, 720, 3000);
                var until = DateTime.Now.AddSeconds(8);
                do { Pump(2); Thread.Sleep(50); } while (DateTime.Now < until);
                var provider = HLSStreamRegistry.Provider;
                var list = provider?.Playlist();
                if (list != null)
                {
                    File.WriteAllText(Path.Combine(output, "stream.m3u8"), list);
                    foreach (var line in list.Split('\n').Where(l => l.EndsWith(".ts")))
                        if (provider!.Segment(line) is { } piece) File.WriteAllBytes(Path.Combine(output, line), piece);
                }
                WebVideoOutput.Shared.RefreshStatus();
                Console.WriteLine($"  Відео по Wi-Fi: {WebVideoOutput.Shared.Status}; шматків {WebVideoOutput.Shared.Segments}; список {(list == null ? "немає" : list.Split('\n').Count(l => l.EndsWith(".ts")) + " шматків")}");
                WebVideoOutput.Shared.Apply(false, 720, 3000);
            }
            if (args.Contains("--show-check"))
            {
                // «Показ за вкладками» (showTabsSection Mac): кроки власника Біблія ↔ Презентація —
                // на кожному що в передпоказі (вірш / картинка) і що в залі (текст / картинка).
                Console.WriteLine("  " + ShowCheck.Run(folder));
            }
            if (args.Contains("--ndi-audio-check"))
            {
                // Звук у NDI: джерело «Слово-звук» отримує тон 440 Гц (−12 дБFS) порціями по 10 мс,
                // приймач NDI у цьому ж процесі рахує порції й рівень (sin із амплітудою 0,25 → −15 дБFS).
                NdiOutput.ForceEnabled = true;
                NdiOutput.SourceNameOverride = "Слово-звук";
                NdiOutput.Shared.Apply(SettingsStore.Shared.Settings.Options);
                Console.WriteLine($"  NDI: {NdiOutput.Shared.Status}");
                var feeding = true;
                var feeder = new Thread(() =>
                {
                    const int rate = 48000, chunk = 480;
                    var planar = new float[chunk * 2];
                    long t = 0;
                    var clock = System.Diagnostics.Stopwatch.StartNew();
                    while (feeding)
                    {
                        for (var i = 0; i < chunk; i++, t++)
                        {
                            var v = (float)(0.25 * Math.Sin(2 * Math.PI * 440 * t / rate));
                            planar[i] = v; planar[chunk + i] = v;
                        }
                        NdiOutput.Shared.SubmitAudio(planar, 2, chunk, rate);
                        var ahead = t * 1000.0 / rate - clock.Elapsed.TotalMilliseconds;
                        if (ahead > 1) Thread.Sleep((int)ahead);
                    }
                }) { IsBackground = true };
                feeder.Start();
                string received = "";
                var check = new Thread(() => received = NdiOutput.ReceiveAudioCheck("Слово-звук", 8));
                check.Start();
                while (check.IsAlive) { Pump(2); Thread.Sleep(50); }
                feeding = false;
                feeder.Join();
                Console.WriteLine($"  NDI звук прийнято: {received}; віддано порцій {NdiOutput.Shared.AudioSent} з {NdiOutput.Shared.AudioIn}, без джерела {NdiOutput.Shared.AudioNoSender}");
                NdiOutput.Shared.Stop();
            }
            if (args.Contains("--loopback-check"))
            {
                // Захват звуку свого процесу (Windows): програма грає тон 1 кГц через WASAPI, захват має
                // його почути — порції й рівень. На Mac захвату немає (там свій шлях).
                long packets = 0, samples = 0; double sum = 0;
                using var capture = new AppAudioCapture();
                string state = "";
                capture.OnState = text => state = text;
                capture.OnSamples = (planar, channels, count, rate) =>
                {
                    Interlocked.Increment(ref packets);
                    double s = 0; for (var i = 0; i < count; i++) s += planar[i] * planar[i];
                    lock (capture) { sum += s; samples += count; }
                };
                capture.Start();
                Thread.Sleep(500);
                if (OperatingSystem.IsWindows())
                {
                    using var output = new NAudio.Wave.WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, 100);
                    var tone = new NAudio.Wave.SampleProviders.SignalGenerator(48000, 2) { Frequency = 1000, Gain = 0.25 };
                    output.Init(new NAudio.Wave.SampleProviders.SampleToWaveProvider(tone));
                    output.Play();
                    Thread.Sleep(2500);
                    output.Stop();
                }
                Thread.Sleep(300);
                capture.Stop();
                var rms = Math.Sqrt(sum / Math.Max(1, samples));
                Console.WriteLine($"  захват звуку програми: {state}; порцій {packets}, відліків {samples}, рівень {(rms > 0 ? (20 * Math.Log10(rms)).ToString("0.0") + " дБFS" : "тиша")}");
            }
            if (args.Contains("--watchdog-check"))
            {
                // Сторож головного потоку: дві секунди спокою (відповіді швидкі — запису нема),
                // потім головний потік зайнятий 1,6 с — має з'явитися рівно один запис.
                MainThreadWatchdog.Shared.Start();
                var calm = DateTime.Now.AddSeconds(2.6);
                do { Pump(2); Thread.Sleep(20); } while (DateTime.Now < calm);
                var before = MainThreadWatchdog.Shared.Reported;
                Thread.Sleep(1600);
                var after = DateTime.Now.AddSeconds(1);
                do { Pump(2); Thread.Sleep(20); } while (DateTime.Now < after);
                var tail = File.Exists(Journal.FilePath) ? File.ReadLines(Journal.FilePath).LastOrDefault(l => l.Contains("головний потік")) : null;
                Console.WriteLine($"  сторож: у спокої записів {before}, після зайнятості {MainThreadWatchdog.Shared.Reported}; журнал: {tail ?? "—"}");
            }
            if (Array.IndexOf(args, "--youtube") is var yi and >= 0 && yi + 1 < args.Length)
            {
                // Розбір ролика YouTube через yt-dlp — без плеєра: що знайдено й які доріжки.
                var found = YouTubeResolver.Locate();
                Console.WriteLine($"  yt-dlp: {found.Tool ?? "немає"} — {found.Note}");
                if (found.Tool is { } tool)
                {
                    try
                    {
                        var r = YouTubeResolver.Obtain(args[yi + 1], tool, CancellationToken.None);
                        Console.WriteLine($"  ролик «{r.Title}», наживо {r.IsLive}, {r.Duration:0} с, картинка {new Uri(r.Url).Host}, звук {(r.Audio != null ? new Uri(r.Audio).Host : "разом")}, UA {(r.UserAgent != null ? "є" : "немає")}");
                        Console.WriteLine($"  рушій JavaScript: node {YouTubeResolver.Node ?? "не знайдено"}; yt-dlp каже: {YouTubeResolver.JavaScriptReport(args[yi + 1], tool)}");
                    }
                    catch (Exception error) { Console.WriteLine($"  не вийшло: {error.Message}"); }
                }
            }
            if (args.Contains("--ndi-check"))
            {
                // NDI: своє джерело «Слово-тест» — і прийняти його кадр тут же (як самоперевірка Mac).
                NdiOutput.ForceEnabled = true;
                NdiOutput.ForceWiFi = true;
                NdiOutput.SourceNameOverride = "Слово-тест";
                AppState.Shared.ShowCurrentSlide();
                NdiOutput.Shared.Apply(SettingsStore.Shared.Settings.Options);
                var until = DateTime.Now.AddSeconds(3);
                do { Pump(2); Thread.Sleep(50); } while (DateTime.Now < until);
                Console.WriteLine($"  NDI: {NdiOutput.Shared.Status} (бібліотека {NdiRuntime.LoadedFrom ?? "—"})");
                string received = "";
                var check = new Thread(() => received = NdiOutput.ReceiveCheck("Слово-тест", 8, Path.Combine(folder, "ndi-прийнято.png")));
                check.Start();
                while (check.IsAlive) { Pump(2); Thread.Sleep(50); }
                Console.WriteLine($"  NDI прийом: {received}; кадрів віддано {NdiOutput.Shared.FramesSent}");
                var wifiCheck = new Thread(() => received = NdiOutput.ReceiveCheck("Слово-тест Wi-Fi", 8));
                wifiCheck.Start();
                while (wifiCheck.IsAlive) { Pump(2); Thread.Sleep(50); }
                Console.WriteLine($"  NDI Wi-Fi ({NdiOutput.Shared.WiFiStatus}): {received}; кадрів {NdiOutput.Shared.WiFiFramesSent}");
                NdiOutput.Shared.Stop();
            }
            if (Array.IndexOf(args, "--media-links") is var li and >= 0 && li + 1 < args.Length)
            {
                // Список плеєра з посиланнями (ролики YouTube) і файлами — як після «Додати посилання».
                MediaPlayerModel.FetchesTitlesInSnapshot = true;
                var media = AppState.Shared.Media;
                var parts = args[li + 1].Split('|', StringSplitOptions.RemoveEmptyEntries);
                media.AddToPlaylist(parts.Where(p => !MediaPlayerModel.IsLink(p)));
                var added = media.AddLinks(string.Join("\n", parts.Where(MediaPlayerModel.IsLink)));
                media.PlaysNext = true;
                if (media.Playlist.Count > 2) media.MovePlaylistItem(media.Playlist.Count - 1, -1);
                var until = DateTime.Now.AddSeconds(10);
                do { Pump(2); Thread.Sleep(100); } while (DateTime.Now < until && media.LinkTitles.Count < added);
                Pump(4);
                Console.WriteLine($"  список плеєра ({added} посилань): " + string.Join(" | ", media.Playlist.Select(media.PlaylistCaption)));
            }
            if (args.Contains("--screen-demo"))
            {
                // Вкладка «Екран» з джерелами, як на знімку Mac (списку вікон Windows без Windows немає).
                var demo = new (string Title, string Subtitle)[]
                {
                    (Captions.T("Монитор %s", "1"), "1920×1200"), ("Нотатки", "Telegram"), ("out", "Finder"), ("Control Center", "Parallels Desktop"),
                    ("Dock", "Dock"), ("Claude", "Claude"), ("Міст батареї", "Google Chrome"), ("WhatsApp", "WhatsApp"), ("Wallpaper-", "Dock"), ("Desktop", ""),
                };
                AppState.Shared.ScreenCapture.SetSourcesForCheck(demo.Select((d, i) => new ScreenCaptureModel.Source(
                    $"demo-{i}", i == 0 ? ScreenCaptureModel.SourceKind.Display : ScreenCaptureModel.SourceKind.Window,
                    d.Title, d.Subtitle, 1920, 1200, IntPtr.Zero, default)).ToList());
                Pump(4);
            }
            if (Array.IndexOf(args, "--search") is var si and >= 0 && si + 1 < args.Length)
            {
                // Перевірка пошуку: набрати слово, дочекатися знайденого, стати на перший рядок.
                var state = AppState.Shared;
                state.SearchQueryChanged(args[si + 1]);
                // Таймер набору (0,25 с) без екрана не йде — запускаємо пошук, як він.
                Pump(2);
                if (state.SearchedQuery.Length == 0) state.RunSearch(args[si + 1]);
                var until = DateTime.Now.AddSeconds(20);
                do { Pump(2); Thread.Sleep(50); } while (DateTime.Now < until && (state.IsSearching || state.SearchedQuery.Length == 0));
                Pump(4);
                if (state.Hits.Count > 0) state.ShowHit(state.Hits[Math.Min(2, state.Hits.Count - 1)], false);
                WaitForLibrary();
                Console.WriteLine($"  пошук «{args[si + 1]}»: {state.Hits.Count}{(state.IsSearchTruncated ? "+" : "")} (модуль {state.PrimaryModule?.Identifier}, шукається {state.IsSearching}, запит «{state.SearchedQuery}», хід {state.IndexProgress})");
            }
            if (Array.IndexOf(args, "--pointer") is var pi and >= 0 && pi + 1 < args.Length)
            {
                // Перевірка указки: пляма в частках кадру, як від миші по живому екрану.
                var xy = args[pi + 1].Split(',');
                SlidePointer.Shared.Move(double.Parse(xy[0], System.Globalization.CultureInfo.InvariantCulture),
                                         double.Parse(xy[1], System.Globalization.CultureInfo.InvariantCulture), SlidePointer.MouseSource);
                Pump(4);
            }
            if (Array.IndexOf(args, "--keys") is var ki and >= 0 && ki + 1 < args.Length)
            {
                // Перевірка клавіатури: «Down,Down,Shift+Down,F5» — як натискання в головному вікні.
                foreach (var chord in args[ki + 1].Split(','))
                {
                    if (chord.StartsWith("text:")) { window.KeyTextInput(chord[5..]); WaitForLibrary(); continue; }
                    var parts = chord.Split('+');
                    var modifiers = Avalonia.Input.RawInputModifiers.None;
                    foreach (var m in parts[..^1])
                        modifiers |= m switch { "Ctrl" => Avalonia.Input.RawInputModifiers.Control, "Shift" => Avalonia.Input.RawInputModifiers.Shift,
                                                "Alt" => Avalonia.Input.RawInputModifiers.Alt, _ => Avalonia.Input.RawInputModifiers.None };
                    if (!Enum.TryParse<Avalonia.Input.Key>(parts[^1], out var key)) { Console.WriteLine($"  клавіша «{chord}» невідома"); continue; }
                    window.KeyPress(key, modifiers, Avalonia.Input.PhysicalKey.None, null);
                    window.KeyRelease(key, modifiers, Avalonia.Input.PhysicalKey.None, null);
                    WaitForLibrary();
                }
                var st = AppState.Shared;
                var focused = window.FocusManager?.GetFocusedElement();
                Console.WriteLine($"  після клавіш: {st.CurrentBook?.FullName} {st.SelectedChapterNumber}:{string.Join(",", st.SelectedVerseNumbers)} зал={st.IsLive} «{st.LiveSlide.Reference}» затемнення={st.IsBlackout} фокус={focused?.GetType().Name}{(focused is TextBox box ? $" «{box.Text}»" : "")}");
            }
            if (args.Contains("--plan"))
            {
                // Перевірка Плану: вірш, уся пісня, частина пісні, текст — і подати пісню в зал.
                var st = AppState.Shared;
                st.ClearPlan();
                st.AddCurrentToPlan();
                if (st.SongLibrary is { } library && st.SongBooks.FirstOrDefault() is { } entry && library.Book(entry.Id) is { Songs.Count: > 2 } book)
                {
                    var was = st.SongBookID;
                    st.SongBookID = entry.Id;
                    st.AddSongToPlanItems(book.Songs[1], null);
                    st.AddSongToPlanItems(book.Songs[2], book.Songs[2].Parts.Count > 1 ? book.Songs[2].Parts[1] : null);
                    st.SongBookID = was;
                }
                st.AddToPlan(new[] { Slovo.Core.PlanItem.TextItem(TextModuleModel.Shared.Document) });
                WaitForLibrary();
                if (st.Plan.Count > 2) st.ActivatePlanItem(st.Plan.Items[2]);
                WaitForLibrary();
                var until = DateTime.Now.AddSeconds(3);
                do { Pump(2); Thread.Sleep(30); } while (DateTime.Now < until && !SlideRenderQueue.Shared.IsIdle);
                st.FlushPlanAutosave();
                Console.WriteLine($"  план ({st.Plan.Count}): " + string.Join(" | ", st.Plan.Items.Select(i => i.Subtitle is { Length: > 0 } s ? $"{i.Title} - {s}" : i.Title)));
                Console.WriteLine($"  поданий №{st.Plan.CurrentIndex}, режим {st.Mode}, зал «{st.LiveSlide.Reference}» «{st.LiveSlide.MainText[..Math.Min(40, st.LiveSlide.MainText.Length)]}»");
            }
            if (Array.IndexOf(args, "--sheet") is var shi and >= 0 && shi + 1 < args.Length && MainWindow.Shared?.Songs is { } songs)
            {
                // Вікно правки пісенника: book, song, new, part, copy — знімок самого вікна.
                var model = songs.Model;
                if (model.Song != null && model.PartIndex == null && model.Song.Parts.Count > 0) model.PartIndex = 0;
                switch (args[shi + 1])
                {
                    case "book": model.OpenBookAttributes(true); break;
                    case "song": model.OpenSongAttributes(true); break;
                    case "new": model.AddSong(); break;
                    case "part": model.OpenPartEditor(); break;
                    case "copy": model.OpenCopySongs(); break;
                }
                Pump(8);
                if (SongSheets.Current is { } sheetWindow)
                {
                    Pump(6);
                    var sheetFrame = sheetWindow.CaptureRenderedFrame();
                    var sheetFile = Path.Combine(folder, (dark ? "dark-" : "") + "вікно-" + args[shi + 1] + ".png");
                    sheetFrame?.Save(sheetFile);
                    Console.WriteLine(sheetFrame != null ? $"✓ {sheetFile} {sheetFrame.PixelSize.Width}×{sheetFrame.PixelSize.Height}" : "✗ вікно: кадру немає");
                    sheetWindow.Close();
                }
                else Console.WriteLine("✗ вікно не відкрилося");
            }
            if (Array.IndexOf(args, "--serve") is var svi and >= 0 && svi + 1 < args.Length && double.TryParse(args[svi + 1], out var serveSeconds))
            {
                // Перевірка пульта без екрана: програма слухає й відповідає, поки йде час (або є файл «стоп»).
                var server = RemoteControlServer.Shared;
                Console.WriteLine($"  пульт: порт {server.Port}, браузер {server.WebPort}{(server.LastError is { } e ? " — " + e : "")}");
                var stop = Path.Combine(folder, "стоп");
                var until = DateTime.Now.AddSeconds(serveSeconds);
                while (DateTime.Now < until && !File.Exists(stop)) { Pump(2); Thread.Sleep(15); }
                Console.WriteLine($"  пульт: запитів {server.RequestCount}, стан №{server.Seq}");
                server.Stop();
                // Веб-слайди (якщо їх підняли ключем --web-slides-port) — теж геть з портів.
                AppState.Shared.Web.Stop();
            }
            if (args.Contains("--mirror-window"))
            {
                // Дзеркало проектора окремим вікном («⤢», NativeProjectorMirrorWindow Mac): вірш у залі —
                // той самий кадр залу у вікні 800×450, у сторонах залу, з полями.
                AppState.Shared.ShowCurrentSlide();
                var mirror = MirrorWindow.Open();
                mirror.Width = 800; mirror.Height = 450;
                var until = DateTime.Now.AddSeconds(5);
                do { Pump(2); Thread.Sleep(30); } while (DateTime.Now < until && (mirror.View.Surface.CurrentImage == null || !SlideRenderQueue.Shared.IsIdle));
                Pump(6);
                var shot = mirror.CaptureRenderedFrame();
                shot?.Save(Path.Combine(folder, "дзеркало-вікно.png"));
                var image = mirror.View.Surface.CurrentImage;
                Console.WriteLine($"  дзеркало вікном: знімок {(shot != null ? $"{shot.PixelSize.Width}×{shot.PixelSize.Height}" : "немає")}, кадр залу {(image != null ? $"{image.Width}×{image.Height}" : "немає")}, рамка кадру {mirror.View.Surface.FrameRect}, над іншими {mirror.Topmost}");
                mirror.Close();
                Pump(4);
                Console.WriteLine($"  після закриття: вікна {(MirrorWindow.Shown == null ? "немає" : "лишилось")}");
            }
            if (args.Contains("--show"))
            {
                // Перевірка показу: вибраний вірш — у зал; живий екран має показати його.
                AppState.Shared.ShowCurrentSlide();
                var until = DateTime.Now.AddSeconds(5);
                do { Pump(2); Thread.Sleep(30); } while (DateTime.Now < until && !SlideRenderQueue.Shared.IsIdle);
                Pump(4);
            }
            Pump(6);
            var frame = window.CaptureRenderedFrame();
            var file = Path.Combine(folder, (dark ? "dark-" : "") + name + ".png");
            if (frame == null) { Console.WriteLine($"✗ {name}: кадру немає"); continue; }
            frame.Save(file);
            Console.WriteLine($"✓ {file} {frame.PixelSize.Width}×{frame.PixelSize.Height}");
            window.Close();
            count++;
        }
        return count > 0 ? 0 : 1;
    }

    /// Дочекатися бібліотеки й розділів (читаються у фоні), не довше 20 с.
    internal static void WaitForLibrary()
    {
        var state = AppState.Shared;
        var until = DateTime.Now.AddSeconds(20);
        do { Pump(2); Thread.Sleep(50); }
        while (DateTime.Now < until && (state.IsLoadingLibrary || state.IsLoadingChapters || (state.AllModules.Count > 0 && state.Chapters.Count == 0)));
        // Кадри слайда малюються у фоні — дочекатися черги.
        Pump(4);
        until = DateTime.Now.AddSeconds(10);
        do { Pump(2); Thread.Sleep(30); } while (DateTime.Now < until && !SlideRenderQueue.Shared.IsIdle);
        Pump(4);
    }

    /// Прогнати чергу і кадр кілька разів: розкладка, відкладені дії, малювання.
    public static void Pump(int times = 3)
    {
        for (var i = 0; i < times; i++)
        {
            Dispatcher.UIThread.RunJobs();
            AvaloniaHeadlessPlatform.ForceRenderTimerTick();
        }
        Dispatcher.UIThread.RunJobs();
    }
}
