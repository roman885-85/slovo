import AppKit
import SlovoCore

/// 6.1.8 «Remote API» на AppKit.
///
/// Программа выступает сервером: внешние системы — например страница в OBS
/// Studio — подключаются и получают тексты текущего слайда. Порты и
/// включённость лежат в секции `[RemoteApi]`, список веб-страниц — в
/// `visiobible.json`.
///
/// Адрес страниц показан прямо здесь и кладётся в буфер обмена: раньше
/// человек знал порт и имя файла, а собирать из них ссылку — и догадываться
/// про проценты вместо кириллицы — приходилось самому.
@MainActor
final class NativeSettingsRemoteTab: NSObject, NativeListSource {

    private let state: AppState
    private let store: SettingsStore
    private let list = NativeTable(detailWidth: 200)
    private let addressLine = NativeForm.label("", secondary: false)
    private var interfaces: [String] = []
    private var selected: Int?

    init(state: AppState, store: SettingsStore) {
        self.state = state
        self.store = store
        super.init()
        interfaces = SettingsNetworkInterfaces.addresses()
        list.source = self
        list.onSelect = { [weak self] _, active, _ in self?.selected = active }
    }

    var page: NSView {
        let view = NativeForm.Page([servers, remote, web, androidApps, network, slides])
        refreshAddress()
        return view
    }

    // MARK: Пульт на телефоне

    private let remoteLine = NativeForm.label("", secondary: false)
    /// Посилання на пульт у браузері — ту саму сторінку віддає сама програма.
    private let browserLine = NativeForm.label("", secondary: false)
    /// Відповідь на «Перевірити зв'язок»: словами, а не кодом.
    private let reachLine = NativeForm.label("", secondary: true)

    /// Свой канал для приложения «Пульт Слова»: включатель, порт, PIN и
    /// адрес — на случай, если телефон не нашёл программу сам.
    private var remote: NativeForm.Group {
        let check = NativeForm.check(OurWords.t("Принимать команды с телефона"), NativeForm.Tie(
            get: { [store] in store.settings.options.remoteEnabled ?? true },
            set: { [store] value in store.settings.options.remoteEnabled = value }),
            hint: OurWords.t("Приложение «Пульт Слова» для Android листает слайды и показывает, что в зале"))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return NativeForm.Group(OurWords.t("Пульт на телефоне"), [
            NativeForm.Row("", [
                check,
                NativeForm.label(OurWords.t("Порт:")),
                NativeForm.number(NativeForm.Tie(get: { [store] in store.settings.options.remotePort ?? 8103 },
                                                 set: { [store, weak self] value in
                                                     store.settings.options.remotePort = value
                                                     self?.refreshAddress()
                                                 }), range: 1...65535, width: 70),
            ]),
            // PIN і пароль — своїми рядками: в одному ряду з галочкою й портом
            // підказка «порожньо — без PIN» виходила за край вікна.
            NativeForm.Row(OurWords.t("PIN:"), width: 180, [
                NativeForm.text(NativeForm.Tie(get: { [store] in store.settings.options.remotePin ?? "" },
                                               set: { [store] value in
                                                   store.settings.options.remotePin = value.trimmingCharacters(in: .whitespaces)
                                               }), width: 120),
                NativeForm.label(OurWords.t("пусто — без PIN")),
            ]),
            NativeForm.Row(OurWords.t("Адрес для пульта:"), width: 180, [
                remoteLine,
                NativeForm.button(OurWords.t("Скопировать"),
                                  hint: OurWords.t("Положить адрес в буфер обмена")) { [weak self] in
                    guard let self else { return }
                    self.copy("\(self.host):\(self.store.settings.options.remotePort ?? 8103)")
                },
            ]),
            NativeForm.Row("", [
                NativeForm.note(OurWords.t("Телефон находит программу по Wi-Fi сам; адрес нужен, только если поиск не сработал. Установить приложение — «Программы для Android» ниже.")),
            ]),
            // Власник: на іншому комп'ютері телефон пише «нічого не знайдено».
            // Зсередини програми такий відмову не видно: слухач піднявся,
            // порт зайнято, все ніби гаразд. Тому програма ходить до себе
            // дорогою телефона — по своїй адресі в мережі та розсилкою — і
            // каже словами, що саме не вийшло.
            NativeForm.Row("", [
                NativeForm.button(OurWords.t("Проверить связь"),
                                  hint: OurWords.t("Пройти к себе тем же путём, каким идёт телефон")) { [weak self] in
                    self?.checkReach()
                },
                reachLine,
            ]),
        ])
    }

    /// Пройти дорогою телефона і показати висновок.
    private func checkReach() {
        reachLine.stringValue = OurWords.t("Проверяю…")
        RemoteReachability.probe(port: store.settings.options.remotePort ?? 8103,
                                 pin: store.settings.options.remotePin ?? "") { [weak self] result in
            guard let self else { return }
            self.reachLine.stringValue = result.verdict
            self.reachLine.textColor = result.beacon && result.addresses.contains { $0.answered }
                ? .secondaryLabelColor : .systemOrange
            // Довгий висновок в один рядок не влазить — даємо йому переноси.
            self.reachLine.lineBreakMode = .byWordWrapping
            self.reachLine.maximumNumberOfLines = 4
            self.reachLine.cell?.wraps = true
            self.reachLine.needsLayout = true
            self.reachLine.superview?.needsLayout = true
        }
    }

    // MARK: Пульт у браузері

    /// Свій порт, пароль і ім'я сторінки для браузера. Власник: «в настройках
    /// программы добавить настройки для этого: включение и отключение, вход с
    /// паролем или без, выбор порта и другие нужные настройки» — і порт
    /// «нестандартный, т.к. на другой машине он может быть занят».
    private let webStatus = NativeForm.label("", secondary: true)

    private var web: NativeForm.Group {
        let enable = NativeForm.check(OurWords.t("Открывать пульт в браузере"), NativeForm.Tie(
            get: { [store] in store.settings.options.remoteWebEnabled ?? true },
            set: { [store] value in store.settings.options.remoteWebEnabled = value }),
            hint: OurWords.t("Страница пульта для браузера компьютера, планшета или телефона"))
        enable.translatesAutoresizingMaskIntoConstraints = false
        enable.widthAnchor.constraint(equalToConstant: 260).isActive = true
        return NativeForm.Group(OurWords.t("Пульт в браузере"), [
            NativeForm.Row("", [
                enable,
                NativeForm.label(OurWords.t("Порт:")),
                NativeForm.number(NativeForm.Tie(get: { [store] in store.settings.options.remoteWebPort ?? 8105 },
                                                 set: { [store] value in store.settings.options.remoteWebPort = value }),
                                  range: 1024...65535, width: 70),
            ]),
            NativeForm.Row(OurWords.t("Пароль:"), width: 180, [
                NativeForm.text(NativeForm.Tie(get: { [store] in store.settings.options.remoteWebPassword ?? "" },
                                               set: { [store] value in
                                                   store.settings.options.remoteWebPassword = value.trimmingCharacters(in: .whitespaces)
                                               }), width: 160),
                NativeForm.label(OurWords.t("пусто — без пароля")),
            ]),
            NativeForm.Row(OurWords.t("Имя в сети:"), width: 180, [
                NativeForm.text(NativeForm.Tie(get: { [store] in store.settings.options.remoteWebName ?? "slovo" },
                                               set: { [store] value in store.settings.options.remoteWebName = RemoteName.clean(value) }),
                                width: 120),
                NativeForm.label(".local", secondary: false),
            ]),
            NativeForm.Row("", [
                NativeForm.note(OurWords.t("Одно и то же имя на любом компьютере со «Словом». Для второго зала в той же сети задайте своё — латиница, цифры, дефис.")),
            ]),
            NativeForm.Row("", [
                NativeForm.check(OurWords.t("Только просмотр: страница показывает зал, но не управляет"), NativeForm.Tie(
                    get: { [store] in store.settings.options.remoteWebViewOnly ?? false },
                    set: { [store] value in store.settings.options.remoteWebViewOnly = value }),
                    hint: OurWords.t("Для экрана музыкантов или проповедника: видно, что в зале, а листать и выводить нельзя")),
            ]),
            NativeForm.Row("", [
                NativeForm.check(OurWords.t("Открывать и без номера порта (порт 80, если свободен)"), NativeForm.Tie(
                    get: { [store] in store.settings.options.remoteWebNoPort ?? true },
                    set: { [store] value in store.settings.options.remoteWebNoPort = value }),
                    hint: OurWords.t("Тогда в браузере достаточно набрать slovo.local. Если порт 80 занят другой программой, пульт остаётся на своём порту.")),
            ]),
            // Власник: «веб приложение для полноценного пользования из
            // браузера компьютера или планшета». Посилання — тут, поруч з
            // адресою пульта: сховане за меню людина не знайде.
            NativeForm.Row(OurWords.t("Страница для браузера:"), width: 180, [
                browserLine,
                NativeForm.button(OurWords.t("Скопировать"),
                                  hint: OurWords.t("Положить ссылку в буфер обмена")) { [weak self] in
                    guard let self else { return }
                    self.copy(self.browserAddress)
                },
                NativeForm.button(OurWords.t("Открыть"),
                                  hint: OurWords.t("Открыть страницу в браузере этого компьютера")) { [weak self] in
                    guard let self, let url = URL(string: self.browserAddress) else { return }
                    NSWorkspace.shared.open(url)
                },
                NativeForm.button(OurWords.t("Как открыть…"),
                                  hint: OurWords.t("Показать, как открыть пульт в браузере")) { [weak self] in
                    guard let self else { return }
                    NativeBrowserRemoteWindow.show(state: self.state)
                },
            ]),
            NativeForm.Row("", [
                webStatus,
            ]),
            NativeForm.Row("", [
                NativeForm.note(OurWords.t("Порт нестандартный, чтобы не спорить с другими программами; если он занят, здесь будет написано — выберите другой. Изменения вступают в силу по «Ок».")),
            ]),
        ])
    }

    // MARK: Програми для Android

    /// Власник: «все программы apk должны быть встроены в основную программу
    /// и иметь возможность сохранить с программы на компьютер».
    private var androidApps: NativeForm.Group {
        var rows: [NSView] = RemoteControlServer.androidApps.map { app -> NSView in
            let available = RemoteControlServer.androidFile(app) != nil
            let note = (app.version.isEmpty ? "" : OurWords.t("версия %s", app.version) + " · ")
                + OurWords.t("Android %s и новее", app.minAndroid)
            let save = NativeForm.button(OurWords.t("Сохранить…"),
                                         hint: OurWords.t("Сохранить установочный файл на этот компьютер")) { [weak self] in
                self?.save(app)
            }
            save.isEnabled = available
            return NativeForm.Row(app.title + ":", width: 180, [
                NativeForm.label(available ? note : OurWords.t("нет в этой сборке"), secondary: false),
                save,
            ])
        }
        rows.append(NativeForm.Row("", [
            NativeForm.button(OurWords.t("Установить по QR-коду…"),
                              hint: OurWords.t("Показать QR-коды: камера телефона или планшета загрузит и установит программу")) {
                NativeAndroidAppsWindow.show()
            },
            NativeForm.label(OurWords.t("Или прямо со страницы в браузере: кнопка «Android» вверху страницы.")),
        ]))
        return NativeForm.Group(OurWords.t("Программы для Android"), rows)
    }

    private func save(_ app: RemoteControlServer.AndroidApp) {
        AndroidAppFile.save(app)
    }

    // MARK: Серверы и порты

    private var servers: NativeForm.Group {
        NativeForm.Group("", [
            server(state.vb("CBWEBServer", "Web Сервер"), \.webEnabled,
                   state.vb("Label55", "Web Порт:"), \.webPort),
            server(state.vb("CBWSServer", "WebSocket Сервер"), \.webSocketEnabled,
                   state.vb("Label52", "WebSocket Порт:"), \.webSocketPort),
            server(state.vb("CBTCPServer", "TCP Сервер"), \.tcpEnabled,
                   state.vb("Label54", "TCP Порт:"), \.tcpPort),
            server(state.vb("CBUDPServer", "UDP Сервер"), \.udpEnabled,
                   state.vb("Label53", "UDP Порт:"), \.udpPort),
        ])
    }

    private func server(_ title: String, _ flag: WritableKeyPath<ProgramOptions, Bool>,
                        _ portTitle: String, _ port: WritableKeyPath<ProgramOptions, Int>) -> NSView {
        let check = NativeForm.check(title, NativeForm.Tie(
            get: { [store] in store.settings.options[keyPath: flag] },
            set: { [store] value in store.settings.options[keyPath: flag] = value }))
        check.translatesAutoresizingMaskIntoConstraints = false
        check.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return NativeForm.Row("", [
            check,
            NativeForm.label(portTitle),
            NativeForm.number(NativeForm.Tie(get: { [store] in store.settings.options[keyPath: port] },
                                             set: { [store, weak self] value in
                                                 store.settings.options[keyPath: port] = value
                                                 self?.refreshAddress()
                                             }), range: 1...65535, width: 70),
        ])
    }

    // MARK: Сетевой интерфейс и адрес

    private var network: NativeForm.Group {
        let titles = ["0.0.0.0"] + interfaces
        return NativeForm.Group("", [
            NativeForm.Row(state.vb("Label56", "Сетевой интерфейс:"), width: 180, [
                NativeForm.popup(titles, NativeForm.Tie(get: { [store] in
                    let chosen = store.settings.options.webNetInterface
                    return chosen.isEmpty ? 0 : (titles.firstIndex(of: chosen) ?? 0)
                }, set: { [store, weak self] index in
                    store.settings.options.webNetInterface = index == 0 ? "" : titles[index]
                    self?.refreshAddress()
                }), width: 200),
                NativeForm.button(state.vb("PSBOpenMainPageOfWebSlides", "Открыть в браузере"),
                                  hint: state.vbHint("PSBOpenMainPageOfWebSlides",
                                                     "Открыть домашнюю страницу Web слайдов в браузере")) {
                    [weak self] in self?.openHome()
                },
            ]),
            NativeForm.Row(OurWords.t("Адрес страниц:"), width: 180, [
                addressLine,
                NativeForm.button(OurWords.t("Скопировать"),
                                  hint: OurWords.t("Положить адрес в буфер обмена")) { [weak self] in
                    guard let self else { return }
                    self.copy(WebPageAddress.home(host: self.host, port: self.store.settings.options.webPort))
                },
            ]),
        ])
    }

    // MARK: Web слайды

    private var slides: NativeForm.Group {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 130))
        list.frame = box.bounds
        list.autoresizingMask = [.width, .height]
        box.addSubview(list)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.heightAnchor.constraint(equalToConstant: 130).isActive = true

        let buttons = NSStackView()
        buttons.orientation = .vertical
        buttons.spacing = 4
        buttons.addArrangedSubview(NativeForm.button("+", hint: state.vbHint("PSBAddWebSlide", "Добавить Web слайд")) {
            [weak self] in self?.edit(nil)
        })
        buttons.addArrangedSubview(NativeForm.button("−", hint: state.vbHint("PSBDelWebSlide", "Удалить Web слайд")) {
            [weak self] in self?.remove()
        })
        buttons.addArrangedSubview(NativeForm.button("✎", hint: state.vbHint("PSBEditWebSlide",
                                                     "Редактировать параметры Web слайда")) {
            [weak self] in
            guard let self, let entry = self.current else { return }
            self.edit(entry)
        })
        buttons.addArrangedSubview(NativeForm.button("↗", hint: state.vbHint("PSBOpenWebSlide",
                                                     "Открыть Web слайд в браузере")) {
            [weak self] in
            guard let self, let entry = self.current else { return }
            self.open(page: entry.fileName)
        })
        buttons.addArrangedSubview(NativeForm.button("⧉",
            hint: OurWords.t("Скопировать адрес страницы — его вписывают в OBS и подобные программы")) {
            [weak self] in
            guard let self, let entry = self.current else { return }
            self.copy(self.address(of: entry.fileName))
        })

        return NativeForm.Group(state.vb("Label57", "Web слайды:"), [NativeForm.Row("", stretch: true, [box, buttons])])
    }

    // MARK: - Действия

    private var current: WebSlideEntry? {
        guard let index = selected, store.settings.webSlides.indices.contains(index) else { return nil }
        return store.settings.webSlides[index]
    }

    /// Адрес, по которому страницы видны из зала. Пустой «сетевой интерфейс»
    /// означает «на всех», и тогда показываем первый настоящий адрес машины —
    /// по «0.0.0.0» из браузера не зайти.
    /// Посилання на пульт у браузері: за ім'ям slovo.local, коли його вже
    /// оголошено, інакше цифрами. Правило одне з вікном «Пульт у браузері».
    private var browserAddress: String {
        RemoteWebAddress.named ?? RemoteWebAddress.link(host: host)
    }

    private var host: String {
        let chosen = store.settings.options.webNetInterface
        if !chosen.isEmpty { return chosen }
        return interfaces.first ?? "127.0.0.1"
    }

    private func address(of fileName: String) -> String {
        guard !fileName.isEmpty else { return "" }
        return WebPageAddress.url(host: host, port: store.settings.options.webPort, fileName: fileName)
    }

    private func refreshAddress() {
        addressLine.stringValue = WebPageAddress.home(host: host, port: store.settings.options.webPort)
        let remote = RemoteControlServer.shared
        remoteLine.stringValue = "\(host):\(store.settings.options.remotePort ?? 8103)"
            + (remote.isRunning ? "" : "  · " + OurWords.t("сейчас выключен"))
        browserLine.stringValue = browserAddress
        let server = RemoteControlServer.shared
        if !(store.settings.options.remoteWebEnabled ?? true) {
            webStatus.stringValue = OurWords.t("Пульт в браузере выключен")
        } else if server.webRunning {
            webStatus.stringValue = OurWords.t("работает на порту %s", "\(server.webPort)")
                + (server.plainReady ? " · " + OurWords.t("адрес без номера порта")
                    : (server.webNoPort ? " · " + (server.plainError ?? OurWords.t("порт 80 занят — адрес с номером порта")) : ""))
                + (server.webHasPassword ? " · " + OurWords.t("вход с паролем") : "")
                + (server.webViewOnly ? " · " + OurWords.t("только просмотр") : "")
        } else {
            webStatus.stringValue = server.webError ?? OurWords.t("не запущен")
        }
        list.reload()
    }

    private func openHome() {
        guard let url = URL(string: "http://\(host):\(store.settings.options.webPort)/") else { return }
        NSWorkspace.shared.open(url)
    }

    private func open(page fileName: String) {
        guard let url = URL(string: address(of: fileName)) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func remove() {
        guard let entry = current else { return }
        let alert = NSAlert()
        alert.messageText = state.vb("TextMessages24", "Внимание")
        alert.informativeText = state.vb("TextMessages46", "Действительно удалить Web страницу %s?")
            .replacingOccurrences(of: "%s", with: entry.name)
        alert.addButton(withTitle: state.yesCaption)
        alert.addButton(withTitle: state.noCaption)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeWebSlide(entry.id)
        selected = nil
        list.reload()
    }

    /// Окошко «Параметры Web слайда» — форма `WebSlideParamsForm` оригинала.
    private func edit(_ entry: WebSlideEntry?) {
        let files = store.webSlideFiles
        let alert = NSAlert()
        alert.messageText = state.vb("WebSlideParamsForm", form: "WebSlideParamsForm", "Параметры Web слайда")

        let box = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 92))
        let name = NSTextField(frame: NSRect(x: 130, y: 62, width: 240, height: 22))
        name.stringValue = entry?.name ?? ""
        name.toolTip = state.vbHint("EName", form: "WebSlideParamsForm",
                                    "Допускается ввод только букв на английском языке в нижнем регистре, "
                                    + "цифр, подчеркивания и тире")
        let file = NSPopUpButton(frame: NSRect(x: 130, y: 34, width: 240, height: 22), pullsDown: false)
        // Файла может не оказаться в папке RemoteAPI — оставляем его в списке,
        // иначе правка страницы её же и сломает.
        var titles = files
        if let known = entry?.fileName, !known.isEmpty, !files.contains(known) { titles.insert(known, at: 0) }
        file.addItems(withTitles: titles.isEmpty ? [""] : titles)
        if let known = entry?.fileName, let index = titles.firstIndex(of: known) { file.selectItem(at: index) }
        let details = NSTextField(frame: NSRect(x: 130, y: 6, width: 240, height: 22))
        details.stringValue = entry?.details ?? ""

        for (title, top) in [(state.vb("Label1", form: "WebSlideParamsForm", "Название страницы:"), 62),
                             (state.vb("Label2", form: "WebSlideParamsForm", "Файл:"), 34),
                             (state.vb("Label3", form: "WebSlideParamsForm", "Описание:"), 6)] {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11)
            label.alignment = .right
            label.frame = NSRect(x: 0, y: CGFloat(top) + 3, width: 122, height: 16)
            box.addSubview(label)
        }
        box.addSubview(name)
        box.addSubview(file)
        box.addSubview(details)
        alert.accessoryView = box
        alert.addButton(withTitle: state.vb("BBOk", form: "WebSlideParamsForm", "Ок"))
        alert.addButton(withTitle: state.vb("BBCancel", form: "WebSlideParamsForm", "Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // Ограничение автора: только строчные латинские буквы, цифры,
        // подчёркивание и тире — имя попадает в адрес страницы.
        let cleaned = name.stringValue.lowercased()
            .filter { ($0.isLetter && $0.isASCII) || $0.isNumber || $0 == "_" || $0 == "-" }
        let chosen = file.titleOfSelectedItem ?? ""
        guard !cleaned.isEmpty, !chosen.isEmpty else { return }
        let result = WebSlideEntry(name: cleaned, fileName: chosen, details: details.stringValue)
        if let entry {
            store.replaceWebSlide(entry.id, with: result)
        } else {
            store.addWebSlide(result)
        }
        list.reload()
    }

    // MARK: - Список

    var rowCount: Int { store.settings.webSlides.count }

    func row(at index: Int) -> NativeRow {
        let entry = store.settings.webSlides[index]
        var row = NativeRow()
        // Адрес — в самой строке: его вставляют в OBS и браузер, и он должен
        // быть на виду, а не мелкой припиской (владелец: «не указаны адреса»).
        row.text = entry.name + "  —  " + address(of: entry.fileName)
        row.detail = entry.fileName + (entry.details.isEmpty ? "" : "  ·  " + entry.details)
        return row
    }
}
