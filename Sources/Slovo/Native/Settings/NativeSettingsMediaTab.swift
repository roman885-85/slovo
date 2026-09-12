import AppKit
import Combine
import SlovoCore

/// 6.1.7 «Медиа» на AppKit: звуковое устройство для медиафайлов, видимость
/// видео в предпросмотре, плавность появления кадра и параметры NDI.
///
/// Ни один флажок здесь не применяется в момент щелчка — даже «Включить
/// трансляцию», хотя канал и приходится поднимать. Иначе «Отмена» закрывала
/// бы окно с включённым NDI и выключенным значением в настройках. Канал
/// поднимает `AppState.applyProgramOptions`, то есть кнопка «Ок».
@MainActor
final class NativeSettingsMediaTab {

    private let state: AppState
    private let store: SettingsStore
    private let channel = NativeForm.label("")
    private let sent = NativeForm.label("")
    private let toolStatus = NativeForm.label("")
    private var timer: Timer?

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
    }

    var page: NSView {
        let view = NativeForm.Page([player, ndi, ndiWiFi, wifi, youTube])
        refresh()
        refreshTool()
        // Счётчик кадров идёт часто: обновляем его раз в секунду и только
        // пока окно открыто — в главном окне на него никто не подписан.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak view] _ in
            MainActor.assumeIsolated {
                guard let self, view?.window != nil else { self?.timer?.invalidate(); return }
                self.refresh()
            }
        }
        return view
    }

    // MARK: Медиа проигрыватель

    private var player: NativeForm.Group {
        let devices = SettingsAudioDevices.list()
        return NativeForm.Group(state.vb("GBMediaPlayer", OurWords.t("Медиа проигрыватель:")), [
            NativeForm.Row(state.vb("LAudioDevice", "Аудио устройство:"), width: 200, [
                NativeForm.popup(devices.map(\.name), NativeForm.Tie(get: { [store] in
                    devices.firstIndex { $0.id == store.settings.options.audioDeviceID } ?? 0
                }, set: { [store] index in
                    guard devices.indices.contains(index) else { return }
                    store.settings.options.audioDeviceID = devices[index].id
                }), width: 300),
            ]),
            NativeForm.Row("", [
                NativeForm.check(state.vb("CBShowVideoOnPreview", "Отображать видео в окне предпросмотра"),
                                 tie(\.showVideoOnPreview)),
            ]),
            // Настройка наша: у автора кадр возникает и пропадает разом.
            // В зале резкая смена читается как сбой, поэтому плавность есть,
            // но её длину задаёт человек — вплоть до нуля, «как было».
            NativeForm.Row(OurWords.t("Плавность появления кадра"), width: 200, [
                NativeForm.slider(NativeForm.Tie(get: { Defaults.mediaFadeSeconds },
                                                 set: { Defaults.mediaFadeSeconds = $0 }),
                                  range: 0...2,
                                  format: { String(format: "%.2f ", $0) + OurWords.t("секунд; 0 — резко") }),
            ]),
        ])
    }

    // MARK: YouTube

    /// Настройка наша: у автора роликов YouTube нет. yt-dlp программа не
    /// качает — владелец кладёт его сам; здесь видно, нашёлся ли он и где.
    private var youTube: NativeForm.Group {
        toolStatus.maximumNumberOfLines = 4
        toolStatus.lineBreakMode = .byWordWrapping
        toolStatus.preferredMaxLayoutWidth = 560
        return NativeForm.Group(OurWords.t("YouTube"), [
            NativeForm.Row(OurWords.t("yt-dlp:"), width: 200, [
                NativeForm.text(NativeForm.Tie(get: { Defaults.youTubeToolPath ?? "" },
                                               set: { [weak self] value in
                    Defaults.youTubeToolPath = value.isEmpty ? nil : value
                    self?.refreshTool()
                }), width: 300),
                NativeForm.button(OurWords.t("Выбрать…"), hint: OurWords.t("Указать программу yt-dlp или папку с её исходниками")) { [weak self] in
                    self?.chooseTool()
                },
            ]),
            NativeForm.Row("", [toolStatus]),
        ])
    }

    private func refreshTool() {
        let found = YouTubeResolver.locate(fresh: true)
        var line = found.note
        if let problem = state.media.youTubeToolProblem {
            line += "\n" + OurWords.t("Последний ответ: %s", problem)
        }
        if found.tool == nil {
            line += "\n" + OurWords.t("Без yt-dlp ролик идёт встроенным проигрывателем YouTube: в зал — полный кадр, в панель и NDI — снимки.")
        }
        if found.tool != nil {
            line += "\n" + (YouTubeResolver.ffmpeg.map { OurWords.t("ffmpeg: %s — дорожки склеиваются на лету", $0.path) }
                ?? OurWords.t("ffmpeg не найден — без него ролики идут встроенным проигрывателем"))
        }
        toolStatus.stringValue = line
        toolStatus.textColor = found.tool == nil ? .secondaryLabelColor : .labelColor
    }

    private func chooseTool() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = OurWords.t("Выберите программу yt-dlp (yt-dlp_macos) или папку с её исходниками")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Defaults.youTubeToolPath = url.path
        refreshTool()
    }

    // MARK: NDI трансляция

    /// Состояние канала «Видео по Wi-Fi» — живёт, пока открыта вкладка.
    private var sinks: [AnyCancellable] = []

    /// Второй источник NDI «Слово Wi-Fi»: основной остаётся как есть, а
    /// клиент по Wi-Fi выбирает уменьшенный — размер и частота свои.
    private var ndiWiFi: NativeForm.Group {
        let status = NativeForm.label("", secondary: true)
        sinks.append(state.ndi.$wifiState.receive(on: DispatchQueue.main).sink { [weak status] text in
            status?.stringValue = text
        })
        return NativeForm.Group(OurWords.t("NDI для Wi-Fi"), [
            NativeForm.Row("", [NativeForm.check(OurWords.t("Второй источник «Слово Wi-Fi» — уменьшенный кадр"),
                                                 NativeForm.Tie(get: { [store] in store.settings.options.ndiWiFiEnabled ?? false },
                                                                set: { [store] in store.settings.options.ndiWiFiEnabled = $0 }))]),
            NativeForm.Row(OurWords.t("Размер кадра"), width: 200, [
                NativeForm.popup(["960×540", "640×360", "480×270"],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.ndiWiFiHeight ?? 360 {
                                     case 540: return 0
                                     case 270: return 2
                                     default: return 1
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.ndiWiFiHeight = [540, 360, 270][max(0, min(2, index))]
                                 }), width: 160),
            ]),
            NativeForm.Row(state.vb("LNdiFps", "Частота кадров"), width: 200, [
                NativeForm.popup(["10", "15", "25", "30"],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.ndiWiFiFrameRate ?? 15 {
                                     case 10: return 0
                                     case 25: return 2
                                     case 30: return 3
                                     default: return 1
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.ndiWiFiFrameRate = [10, 15, 25, 30][max(0, min(3, index))]
                                 }), width: 100),
            ]),
            NativeForm.Row("", [NativeForm.label(OurWords.t("В клиенте на Wi-Fi выберите источник «… (Слово Wi-Fi)». 640×360 на 15 кадрах — около 8 Мбит/с."), secondary: true)]),
            NativeForm.Row(OurWords.t("Состояние"), width: 200, [status]),
        ])
    }

    /// «Видео по Wi-Fi»: клиент владельца по Wi-Fi не тянет полную полосу
    /// NDI, а NDI|HX без лицензии работает 30 минут. Поэтому свой поток
    /// H.264/AAC (HLS) с нашего веб-сервера, задержка 2–4 с.
    private var wifi: NativeForm.Group {
        let status = NativeForm.label("", secondary: true)
        sinks.append(state.webVideo.$status.receive(on: DispatchQueue.main).sink { [weak status] text in
            status?.stringValue = text
        })
        let port = store.settings.options.webPort
        let host = state.web.status.addresses.first ?? "<IP-адрес Mac>"
        let address = NativeForm.label("http://\(host):\(port)/wifi/", secondary: false)
        address.isSelectable = true
        return NativeForm.Group(OurWords.t("Видео по Wi-Fi (HLS)"), [
            NativeForm.Row("", [NativeForm.check(OurWords.t("Раздавать кадр зала потоком H.264"),
                                                 NativeForm.Tie(get: { [store] in store.settings.options.webVideoEnabled ?? false },
                                                                set: { [store] in store.settings.options.webVideoEnabled = $0 }))]),
            NativeForm.Row(OurWords.t("Размер кадра"), width: 200, [
                NativeForm.popup(["1280×720", "960×540", "640×360"],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.webVideoHeight ?? 720 {
                                     case 540: return 1
                                     case 360: return 2
                                     default: return 0
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.webVideoHeight = [720, 540, 360][max(0, min(2, index))]
                                 }), width: 160),
            ]),
            NativeForm.Row(OurWords.t("Поток"), width: 200, [
                NativeForm.popup(["1,5 " + OurWords.t("Мбит/с"), "3 " + OurWords.t("Мбит/с"), "5 " + OurWords.t("Мбит/с")],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.webVideoKbps ?? 3000 {
                                     case 1500: return 0
                                     case 5000: return 2
                                     default: return 1
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.webVideoKbps = [1500, 3000, 5000][max(0, min(2, index))]
                                 }), width: 160),
            ]),
            NativeForm.Row(OurWords.t("Адрес"), width: 200, [address]),
            NativeForm.Row("", [NativeForm.label(OurWords.t("Нужен включённый веб-сервер (вкладка Remote API). Safari, VLC, OBS открывают адрес сразу; для Chrome положите hls.min.js в папку программы. Задержка 2–4 с."), secondary: true)]),
            NativeForm.Row(OurWords.t("Состояние"), width: 200, [status]),
        ])
    }


    private var ndi: NativeForm.Group {
        NativeForm.Group(state.vb("GBNdi", "NDI трансляция"), [
            NativeForm.Row("", [NativeForm.check(state.vb("CBNdiEnable", "Включить трансляцию"),
                                                 tie(\.ndiEnabled))]),
            NativeForm.Row("", [NativeForm.check(state.vb("CBNdiTransparentBackGr", "Прозрачный фон"),
                                                 tie(\.ndiTransparentBackground))]),
            NativeForm.Row("", [NativeForm.check(state.vb("CBNdiSendVideo", "Отображать Видео"),
                                                 tie(\.ndiSendVideo))]),
            // Настройка наша: у автора трансляция без звука. Звук снимается с
            // выхода самой программы — macOS спросит разрешение один раз.
            NativeForm.Row("", [NativeForm.check(OurWords.t("Передавать звук"),
                                                 NativeForm.Tie(get: { [store] in store.settings.options.ndiSendAudio ?? true },
                                                                set: { [store] in store.settings.options.ndiSendAudio = $0 }),
                                                 hint: OurWords.t("Звук фильмов, потоков и роликов уходит в NDI вместе с картинкой"))]),
            // Разрешение на захват звука потоков программа сама не просит —
            // иначе просила бы при каждом запуске. Просит по этой кнопке, один
            // раз, когда человек этого хочет.
            NativeForm.Row("", [
                NativeForm.button(OurWords.t("Разрешить запись звука системы…"),
                                  hint: OurWords.t("Нужно только для звука потоков и YouTube в NDI; звук файлов идёт и без этого")) {
                    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                },
                NativeForm.label(CGPreflightScreenCaptureAccess()
                                 ? OurWords.t("разрешение есть") : OurWords.t("разрешения пока нет")),
            ]),
            // Настройка наша: по Wi-Fi 1080p без сжатия не проходит — кадр
            // трансляции можно уменьшить, слайд в зале от этого не меняется.
            // Эталон уровня SDK: ±1,0 = +4 dBu, обычный звук отдаётся с +20 дБ.
            NativeForm.Row(OurWords.t("Уровень звука"), width: 200, [
                NativeForm.popup([OurWords.t("+20 дБ — эталон NDI"), "+12 " + OurWords.t("дБ"), OurWords.t("как есть (0 дБ)")],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.ndiAudioGainDb ?? 20 {
                                     case 12: return 1
                                     case 0: return 2
                                     default: return 0
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.ndiAudioGainDb = [20, 12, 0][max(0, min(2, index))]
                                 }), width: 200),
            ]),
            NativeForm.Row(OurWords.t("Размер кадра"), width: 200, [
                NativeForm.popup([OurWords.t("как слайд"), "1280×720", "960×540"],
                                 NativeForm.Tie(get: { [store] in
                                     switch store.settings.options.ndiFrameHeight ?? 0 {
                                     case 720: return 1
                                     case 540: return 2
                                     default: return 0
                                     }
                                 }, set: { [store] index in
                                     store.settings.options.ndiFrameHeight = [0, 720, 540][max(0, min(2, index))]
                                 }), width: 160),
            ]),
            // По Wi-Fi транспорт NDI по умолчанию (RUDP) на потерях пакетов
            // копит очередь: владелец видел зависания и пропажу звука.
            // Конфиг — только для нашей программы, через NDI_CONFIG_DIR.
            NativeForm.Row(OurWords.t("Транспорт"), width: 200, [
                NativeForm.popup([OurWords.t("как у NDI (RUDP) — и для Wi-Fi"), OurWords.t("только TCP — для провода")],
                                 NativeForm.Tie(get: { [store] in store.settings.options.ndiTransport == "tcp" ? 1 : 0 },
                                                set: { [store] index in
                                                    store.settings.options.ndiTransport = index == 1 ? "tcp" : "auto"
                                                }), width: 200),
            ]),
            // По документации NDI для Wi-Fi лучше UDP/RUDP: TCP при потере
            // пакета останавливает весь поток и ждёт повтора. Прежний совет
            // «TCP для Wi-Fi» был неверен.
            NativeForm.Row("", [NativeForm.label(OurWords.t("Транспорт вступает в силу после перезапуска программы. Для Wi-Fi оставьте RUDP, возьмите «Слово Wi-Fi» 480×270 или 640×360 на 15 кадрах и в клиенте — режим низкой полосы; полная полоса NDI по Wi-Fi не проходит."), secondary: true)]),
            NativeForm.Row(state.vb("LNdiFps", "Частота кадров"), width: 200, [
                // Подписи берём авторские целиком — «29.97 NTSC», а не «30»:
                // по ним человек и узнаёт свой режим вещания.
                NativeForm.popup(OutputConfiguration.ndiFrameRateTitles,
                                 NativeForm.Tie(get: { [store] in store.settings.options.ndiFrameRateIndex },
                                                set: { [store] in store.settings.options.ndiFrameRateIndex = $0 }),
                                 width: 140),
            ]),
            // Состояние канала: без него непонятно, ушла трансляция в сеть
            // или осталась предпросмотром.
            NativeForm.Row(OurWords.t("Состояние:"), width: 200, [channel]),
            NativeForm.Row("", [sent]),
        ])
    }

    private func tie(_ path: WritableKeyPath<ProgramOptions, Bool>) -> NativeForm.Tie<Bool> {
        NativeForm.Tie(get: { [store] in store.settings.options[keyPath: path] },
                       set: { [store] value in store.settings.options[keyPath: path] = value })
    }

    private func refresh() {
        let output = state.ndi
        channel.stringValue = output.mode.title
        if case let .previewOnly(reason) = output.mode {
            channel.stringValue += " — " + reason
        }
        var line = OurWords.t("кадров отправлено: %s", "\(output.sentFrameCount)")
        if let error = output.lastError { line += " · " + error }
        sent.stringValue = line
    }
}
