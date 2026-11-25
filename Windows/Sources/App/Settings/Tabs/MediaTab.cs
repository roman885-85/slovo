// =============================================================================
//  MediaTab.cs — вкладка «Медіа» (6.1.7, як NativeSettingsMediaTab на Mac)
// =============================================================================
//  Медіапрогравач: звуковий вихід для медіафайлів (як MediaDefaultAudioDevice
//  оригіналу: 0 — за умовчанням), відео у вікні передпоказу, плавність появи
//  кадру. NDI, «NDI для Wi-Fi», «Відео по Wi-Fi (HLS)» і YouTube — ті самі
//  групи й ключі налаштувань, що на Mac (файл налаштувань спільний), але цих
//  виводів у Windows-версії ще немає — рядок «Стан» каже про це прямо.
//  Ніщо тут не діє в мить клацання: усе застосовує «Ок» (ApplyProgramOptions).
// =============================================================================

using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Slovo.Core;

namespace Slovo.App;

public sealed class MediaTab
{
    readonly SettingsStore _store;
    public MediaTab(SettingsStore store) { _store = store; }
    static string Vb(string key, string fallback) => Captions.FormCaption(key, "SettingsForm", fallback);
    static string T(string text, params object[] args) => Captions.T(text, args);
    ProgramOptions O => _store.Settings.Options;
    static string Missing => T("этой функции в Windows-версии ещё нет");

    public Control Page() => new Form.Page(new[] { Player(), Ndi(), NdiWiFi(), WiFi(), YouTube() });

    // --- Медіапрогравач ---------------------------------------------------------------

    Form.Group Player()
    {
        // Першим — «за умовчанням», як MediaDefaultAudioDevice=0 оригіналу.
        var devices = new[] { T("По умолчанию") }.Concat(AppState.Shared.Media.ListAudioDevices().Select(d => d.Name)).ToList();
        return new Form.Group(Vb("GBMediaPlayer", T("Медиа проигрыватель:")), new Control[]
        {
            new Form.Row(Vb("LAudioDevice", "Аудио устройство:"), new Control[]
            {
                Form.Popup(devices, new Tie<int>(() => Math.Clamp(O.AudioDeviceID, 0, devices.Count - 1), v => O.AudioDeviceID = v), 300),
            }, 200),
            new Form.Row("", new Control[]
            {
                Form.Check(Vb("CBShowVideoOnPreview", "Отображать видео в окне предпросмотра"),
                           new Tie<bool>(() => O.ShowVideoOnPreview, v => O.ShowVideoOnPreview = v),
                           T("Видео видно и в предпросмотре, а не только в зале")),
            }),
            // Наше: у автора кадр з'являється й зникає разом; у залі різка зміна читається
            // як збій — плавність є, а її довжину задає людина, аж до нуля.
            new Form.Row(T("Плавность появления кадра"), new[]
            {
                Form.Slider(new Tie<double>(() => AppState.MediaFadeSeconds, v => Defaults.Set("mediaFade", Math.Round(v, 2))), 0, 2,
                            v => v.ToString("0.00") + " " + T("секунд; 0 — резко"), 200, 260),
            }, 200),
        });
    }

    // --- NDI ----------------------------------------------------------------------------

    Form.Group Ndi() => new(Vb("GBNdi", "NDI трансляция"), new Control[]
    {
        new Form.Row("", new Control[] { Form.Check(Vb("CBNdiEnable", "Включить трансляцию"), new Tie<bool>(() => O.NdiEnabled, v => O.NdiEnabled = v),
                                                    T("Слайд уходит в сеть источником NDI — для OBS, vMix и других программ трансляции")) }),
        new Form.Row("", new Control[] { Form.Check(Vb("CBNdiTransparentBackGr", "Прозрачный фон"), new Tie<bool>(() => O.NdiTransparentBackground, v => O.NdiTransparentBackground = v),
                                                    T("Текст без фона — титры поверх картинки трансляции")) }),
        new Form.Row("", new Control[] { Form.Check(Vb("CBNdiSendVideo", "Отображать Видео"), new Tie<bool>(() => O.NdiSendVideo, v => O.NdiSendVideo = v),
                                                    T("Передавать в NDI и видео из медиаплеера")) }),
        new Form.Row("", new Control[] { Form.Check(T("Передавать звук"), new Tie<bool>(() => O.NdiSendAudio ?? true, v => O.NdiSendAudio = v),
                                                    T("Звук фильмов, потоков и роликов уходит в NDI вместе с картинкой")) }),
        new Form.Row(T("Уровень звука"), new Control[]
        {
            Form.Popup(new[] { T("+20 дБ — эталон NDI"), "+12 " + T("дБ"), T("как есть (0 дБ)") },
                       new Tie<int>(() => (O.NdiAudioGainDb ?? 20) switch { 12 => 1, 0 => 2, _ => 0 }, v => O.NdiAudioGainDb = new[] { 20, 12, 0 }[Math.Clamp(v, 0, 2)]), 200),
        }, 200),
        new Form.Row(T("Размер кадра"), new Control[]
        {
            Form.Popup(new[] { T("как слайд"), "1280×720", "960×540" },
                       new Tie<int>(() => (O.NdiFrameHeight ?? 0) switch { 720 => 1, 540 => 2, _ => 0 }, v => O.NdiFrameHeight = new[] { 0, 720, 540 }[Math.Clamp(v, 0, 2)]), 160),
        }, 200),
        new Form.Row(T("Транспорт"), new Control[]
        {
            Form.Popup(new[] { T("как у NDI (RUDP) — и для Wi-Fi"), T("только TCP — для провода") },
                       new Tie<int>(() => O.NdiTransport == "tcp" ? 1 : 0, v => O.NdiTransport = v == 1 ? "tcp" : "auto"), 200),
        }, 200),
        new Form.Row("", new Control[] { Form.Note(T("Транспорт вступает в силу после перезапуска программы. Для Wi-Fi оставьте RUDP, возьмите «Слово Wi-Fi» 480×270 или 640×360 на 15 кадрах и в клиенте — режим низкой полосы; полная полоса NDI по Wi-Fi не проходит.")) }),
        new Form.Row(Vb("LNdiFps", "Частота кадров"), new Control[]
        {
            Form.Popup(OutputConfiguration.NdiFrameRateTitles, new Tie<int>(() => O.NdiFrameRateIndex, v => O.NdiFrameRateIndex = v), 140),
        }, 200),
        new Form.Row(T("Состояние:"), new Control[] { NdiStatus() }, 200),
        new Form.Row(T("Библиотека NDI:"), new Control[] { NdiLibrary() }, 200),
        new Form.Row("", new Control[] { NdiCheck() }),
        new Form.Row("", new Control[] { FirewallRow() }),
    });

    /// Яка бібліотека NDI взялась (шлях і версія) — або чому її немає й кнопка поставити.
    static Control NdiLibrary()
    {
        var label = Form.Label("", false);
        label.TextWrapping = TextWrapping.Wrap;
        label.MaxWidth = 560;
        // Бібліотеку NDI (якщо трансляцію ще не вмикали) піднімати не в головному потоці: секунди.
        void Update() => label.Text = NdiRuntime.IsAvailable
            ? $"{NdiRuntime.LoadedFrom} · {NdiRuntime.LoadedVersion ?? "?"}"
            : NdiRuntime.Problem ?? T("NDI не установлен");
        if (!NdiRuntime.WasTried)
        {
            label.Text = T("ищу библиотеку NDI…");
            System.Threading.Tasks.Task.Run(() => NdiRuntime.IsAvailable).ContinueWith(_ => Avalonia.Threading.Dispatcher.UIThread.Post(Update));
            return label;
        }
        Update();
        if (NdiRuntime.IsAvailable) return label;
        var install = Form.Button(T("Скачать NDI Runtime…"), T("Официальная страница NDI: установщик NDI Runtime для Windows"), () =>
        {
            try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo("https://ndi.link/NDIRedistV6") { UseShellExecute = true }); }
            catch (Exception error) { Journal.Say("NDI: сторінка не відкрилась — " + error.Message); }
        });
        var again = Form.Button(T("Найти снова"), T("После установки NDI Runtime — подхватить без перезапуска"), () =>
        {
            NdiRuntime.Retry();
            NdiOutput.Shared.Apply(SettingsStore.Shared.Settings.Options);
            Update();
        });
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { label, install, again } };
    }

    /// «Перевірити NDI»: які джерела видно з цього комп'ютера за 5 с (своє — серед них, якщо в ефірі).
    static Control NdiCheck()
    {
        var result = Form.Label("", true);
        result.TextWrapping = TextWrapping.Wrap;
        result.MaxWidth = 560;
        var button = Form.Button(T("Проверить NDI"), T("Найти источники NDI в сети отсюда — как их видит OBS или vMix"), () => { });
        button.Pressed = () =>
        {
            result.Text = T("Ищу источники NDI…");
            System.Threading.Tasks.Task.Run(() => NdiOutput.ListSources(5)).ContinueWith(t =>
                Avalonia.Threading.Dispatcher.UIThread.Post(() =>
                {
                    var mine = NdiOutput.Shared.NetworkName;
                    var text = t.IsCompletedSuccessfully ? t.Result : t.Exception?.GetBaseException().Message ?? "";
                    result.Text = T("Видно отсюда: %s", text)
                        + (mine != null ? "\n" + (text.Contains(mine) ? T("«%s» в сети виден.", mine) : T("«%s» среди них нет.", mine)) : "");
                    Journal.Say("NDI: перевірка — " + result.Text.Replace("\n", " "));
                }));
        };
        return new StackPanel { Spacing = 4, Children = { button, result } };
    }

    /// Брандмауер Windows для «Слова» — словами й кнопкою (той самий рядок, що в Remote API).
    internal static Control FirewallRow()
    {
        var line = Form.Label("", false);
        line.TextWrapping = TextWrapping.Wrap;
        line.MaxWidth = 560;
        var allow = Form.Button(T("Разрешить в брандмауэре…"), T("Одно правило для «Слова» во всех сетях; Windows попросит подтверждение"), () => { });
        void Show(Firewall.State state)
        {
            line.Text = state.Text;
            line.Foreground = Palette.Brush(state.Blocked ? Palette.SystemOrange : Palette.SecondaryLabel);
            allow.IsVisible = state.Blocked;
        }
        void Refresh() => System.Threading.Tasks.Task.Run(Firewall.Check).ContinueWith(t => Avalonia.Threading.Dispatcher.UIThread.Post(() => Show(t.Result)));
        allow.Pressed = async () =>
        {
            line.Text = T("Жду подтверждения Windows…");
            await Firewall.AllowAsync();
            Refresh();
        };
        allow.IsVisible = false;
        if (OperatingSystem.IsWindows()) Refresh(); else line.IsVisible = false;
        return new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = { line, allow } };
    }

    /// Стан трансляції NDI наживо: «В ефірі: Слово · приймачів: 2», «Зупинена», чому NDI немає.
    static Control NdiStatus()
    {
        // Поруч зі станом трансляції — стан звуку («звук: іде», «вимкнено налаштуванням»…).
        static string Text()
        {
            var ndi = NdiOutput.Shared;
            var main = ndi.Status.Length > 0 ? ndi.Status : T("Остановлена");
            if (!ndi.IsRunning) return main;
            // Повне ім'я — як його бачать OBS і vMix; і скільки приймачів зараз під'єднано.
            if (ndi.NetworkName is { } full) main += " · " + T("в сети: %s", full);
            main += " · " + T("приёмников: %s", ndi.Connections.ToString());
            return ndi.AudioState.Length > 0 ? main + " · " + ndi.AudioState : main;
        }
        var label = Form.Label(Text());
        label.TextWrapping = TextWrapping.Wrap;
        label.MaxWidth = 560;
        void Update() => Avalonia.Threading.Dispatcher.UIThread.Post(() => label.Text = Text());
        NdiOutput.Shared.StatusChanged += Update;
        // Приймачі під'єднуються без жодної події — перечитувати раз на 2 с, поки вкладка відкрита.
        var timer = new Avalonia.Threading.DispatcherTimer(TimeSpan.FromSeconds(2), Avalonia.Threading.DispatcherPriority.Background, (_, _) => label.Text = Text());
        label.AttachedToVisualTree += (_, _) => timer.Start();
        label.DetachedFromVisualTree += (_, _) => { NdiOutput.Shared.StatusChanged -= Update; timer.Stop(); };
        return label;
    }

    static Control NdiWiFiStatus()
    {
        string Text() => NdiOutput.Shared.WiFiStatus.Length > 0 ? NdiOutput.Shared.WiFiStatus : T("Остановлена");
        var label = Form.Label(Text());
        void Update() => Avalonia.Threading.Dispatcher.UIThread.Post(() => label.Text = Text());
        NdiOutput.Shared.StatusChanged += Update;
        label.DetachedFromVisualTree += (_, _) => NdiOutput.Shared.StatusChanged -= Update;
        return label;
    }

    Form.Group NdiWiFi() => new(T("NDI для Wi-Fi"), new Control[]
    {
        new Form.Row("", new Control[] { Form.Check(T("Второй источник «Слово Wi-Fi» — уменьшенный кадр"), new Tie<bool>(() => O.NdiWiFiEnabled ?? false, v => O.NdiWiFiEnabled = v),
                                                    T("Ещё один источник NDI с меньшим кадром и частотой — для приёмников по Wi-Fi")) }),
        new Form.Row(T("Размер кадра"), new Control[]
        {
            Form.Popup(new[] { "960×540", "640×360", "480×270" },
                       new Tie<int>(() => (O.NdiWiFiHeight ?? 360) switch { 540 => 0, 270 => 2, _ => 1 }, v => O.NdiWiFiHeight = new[] { 540, 360, 270 }[Math.Clamp(v, 0, 2)]), 160),
        }, 200),
        new Form.Row(Vb("LNdiFps", "Частота кадров"), new Control[]
        {
            Form.Popup(new[] { "10", "15", "25", "30" },
                       new Tie<int>(() => (O.NdiWiFiFrameRate ?? 15) switch { 10 => 0, 25 => 2, 30 => 3, _ => 1 }, v => O.NdiWiFiFrameRate = new[] { 10, 15, 25, 30 }[Math.Clamp(v, 0, 3)]), 100),
        }, 200),
        new Form.Row(T("Состояние"), new Control[] { NdiWiFiStatus() }, 200),
    });

    Form.Group WiFi()
    {
        var host = Names.Addresses().Select(a => a.Address.ToString()).FirstOrDefault() ?? "<IP>";
        // Сторінку /wifi/ віддає сервер веб-слайдів (порт «Web» вкладки Remote API), як на Mac.
        var address = Form.Label($"http://{host}:{O.WebPort}/wifi/", false);
        return new Form.Group(T("Видео по Wi-Fi (HLS)"), new Control[]
        {
            new Form.Row("", new Control[] { Form.Check(T("Раздавать кадр зала потоком H.264"), new Tie<bool>(() => O.WebVideoEnabled ?? false, v => O.WebVideoEnabled = v),
                                                        T("Поток HLS по адресу ниже: Safari, VLC, OBS открывают его по Wi-Fi, задержка 2–4 с")) }),
            new Form.Row(T("Размер кадра"), new Control[]
            {
                Form.Popup(new[] { "1280×720", "960×540", "640×360" },
                           new Tie<int>(() => (O.WebVideoHeight ?? 720) switch { 540 => 1, 360 => 2, _ => 0 }, v => O.WebVideoHeight = new[] { 720, 540, 360 }[Math.Clamp(v, 0, 2)]), 160),
            }, 200),
            new Form.Row(T("Поток"), new Control[]
            {
                Form.Popup(new[] { "1,5 " + T("Мбит/с"), "3 " + T("Мбит/с"), "5 " + T("Мбит/с") },
                           new Tie<int>(() => (O.WebVideoKbps ?? 3000) switch { 1500 => 0, 5000 => 2, _ => 1 }, v => O.WebVideoKbps = new[] { 1500, 3000, 5000 }[Math.Clamp(v, 0, 2)]), 160),
            }, 200),
            new Form.Row(T("Адрес"), new Control[] { address }, 200),
            new Form.Row(T("Состояние"), new Control[] { WebVideoStatus() }, 200),
        });
    }

    /// Стан каналу «Відео по Wi-Fi» наживо: «іде: шматків 6, 1280×720, 2,9 Мбіт/с», «потік запускається…».
    static Control WebVideoStatus()
    {
        static string Text() => WebVideoOutput.Shared.Status.Length > 0 ? WebVideoOutput.Shared.Status : T("Остановлена");
        var label = Form.Label(Text());
        void Update() => Avalonia.Threading.Dispatcher.UIThread.Post(() => label.Text = Text());
        WebVideoOutput.Shared.StatusChanged += Update;
        label.DetachedFromVisualTree += (_, _) => WebVideoOutput.Shared.StatusChanged -= Update;
        return label;
    }

    Form.Group YouTube()
    {
        // Рядок стану: що знайдено, що відповів yt-dlp востаннє, чим без нього.
        var status = Form.Note("");
        void Refresh()
        {
            var found = YouTubeResolver.Locate();
            var line = found.Note;
            if (AppState.Shared.Media.YouTubeToolProblem is { } problem) line += "\n" + T("Последний ответ: %s", problem);
            if (found.Tool == null) line += "\n" + T("Без yt-dlp ролик YouTube всё равно идёт — встроенным проигрывателем YouTube (Microsoft Edge WebView2), но без перемотки по кадрам и выбора качества.");
            status.Text = line;
            // Як на Mac: знайдено — звичайним кольором, ні — блідим.
            status.Foreground = Palette.Brush(found.Tool == null ? Palette.SecondaryLabel : Palette.Label);
        }
        var field = Form.Text(new Tie<string>(() => Defaults.String("youTubeToolPath") ?? "", v =>
        {
            if (v.Length == 0) Defaults.Remove("youTubeToolPath"); else Defaults.Set("youTubeToolPath", v);
            Refresh();
        }), 300);
        async Task Choose()
        {
            if (Avalonia.Controls.TopLevel.GetTopLevel(field)?.StorageProvider is not { } storage) return;
            var picked = await storage.OpenFilePickerAsync(new Avalonia.Platform.Storage.FilePickerOpenOptions
            {
                Title = T("Выберите программу yt-dlp"),
                AllowMultiple = false,
                FileTypeFilter = new[] { new Avalonia.Platform.Storage.FilePickerFileType("yt-dlp") { Patterns = new[] { "yt-dlp*.exe", "*.exe" } } },
            });
            if (picked.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
            Defaults.Set("youTubeToolPath", path);
            field.Text = path;
            Refresh();
        }
        var choose = Form.Button(T("Выбрать…"), T("Указать программу yt-dlp или папку с её исходниками"), () => _ = Choose());
        // Свій yt-dlp оновлюється сам (власник: «чтобы он автоматически обновлялся») — з вимикачем.
        var update = Form.Note(YouTubeToolUpdater.Status);
        update.Foreground = Palette.Brush(Palette.Label);
        var auto = Form.Check(T("Обновлять yt-dlp автоматически"), new Tie<bool>(() => YouTubeToolUpdater.AutoUpdate, v => YouTubeToolUpdater.AutoUpdate = v),
                              T("Раз в сутки программа сверяет свою копию yt-dlp с последним выпуском на GitHub и при новой версии скачивает её (сумма SHA-256 проверяется)"));
        var checkNow = Form.Button(T("Проверить сейчас"), T("Сверить yt-dlp с последним выпуском и обновить, если вышла новая версия"), async () =>
        {
            update.Text = T("Проверяю…");
            update.Text = await YouTubeToolUpdater.CheckAsync();
            Refresh();
        });
        void StatusUpdated() => Avalonia.Threading.Dispatcher.UIThread.Post(() => { update.Text = YouTubeToolUpdater.Status; Refresh(); });
        YouTubeToolUpdater.StatusChanged += StatusUpdated;
        update.DetachedFromVisualTree += (_, _) => YouTubeToolUpdater.StatusChanged -= StatusUpdated;
        Refresh();
        return new(T("YouTube"), new Control[]
        {
            new Form.Row(T("yt-dlp:"), new Control[] { field, choose }, 200),
            new Form.Row("", new Control[] { status }),
            new Form.Row("", new Control[] { auto, checkNow }),
            new Form.Row("", new Control[] { update }),
        });
    }
}
