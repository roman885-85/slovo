import AppKit
import CoreVideo
import Combine
import SlovoCore

/// Самопроверка программы.
///
/// Сделана не для красоты: проверять работу по снимкам экрана — значит
/// пропускать половину. Здесь каждая функция проверяется своим кодом и
/// отвечает «работает» или «нет, вот почему». Запускается либо из меню
/// «Справка → Диагностика», либо ключом `--selftest`, который прогоняет всё
/// без участия человека и пишет отчёт в файл.
@MainActor
enum Diagnostics {

    enum Status: String {
        case ok = "працює"
        case warning = "із застереженням"
        case failed = "не працює"
        case skipped = "пропущено"
    }

    struct Check {
        let area: String
        let name: String
        let status: Status
        let detail: String
    }

    // MARK: - Прогон

    /// Писать отчёт по ходу, а не только в конце. Ставит `--selftest`.
    ///
    /// На Big Sur самопроверка закончилась «окно закрылось», и от неё не
    /// осталось ничего: отчёт пишется в конце, а падение — не конец. Теперь
    /// после каждого раздела файл переписывается целиком с пометкой, какой
    /// раздел был последним, и строка уходит в терминал.
    nonisolated(unsafe) static var writesProgressively = false

    /// Собиратель проверок. Каждая порция сразу ложится в файл отчёта — если
    /// программа упадёт, у владельца останется всё, что было до падения.
    @MainActor
    final class Run {
        private(set) var checks: [Check] = []

        func add(_ new: [Check]) {
            checks.append(contentsOf: new)
            guard Diagnostics.writesProgressively, let last = new.last else { return }
            selfTestRemember(section: last.area)
            let text = Diagnostics.report(checks)
                + "\n\n(звіт ще пишеться; останній завершений розділ — «\(last.area)»)\n"
            try? text.write(to: Diagnostics.reportURL, atomically: true, encoding: .utf8)
            print("· \(last.area): перевірок \(checks.count)")
            fflush(stdout)
        }

        func add(single: Check) { add([single]) }
    }

    /// Повний прогін — без жодного сліду в пам'яті списків людини
    /// (див. `SessionMemory`).
    static func runAll(state: AppState) -> [Check] {
        SessionMemory.protect { DeskModel.shared.keepingJournals { runAllUnprotected(state: state) } }
    }

    private static func runAllUnprotected(state: AppState) -> [Check] {
        let run = Run()
        run.add(library(state))
        run.add(navigation(state))
        run.add(slide(state))
        run.add(outputs(state))
        run.add(reference(state))
        run.add(multiVerse(state))
        run.add(search(state))
        run.add(plan(state))
        run.add(history(state))
        run.add(songs(state))
        run.add(textModule(state))
        run.add(templates(state))
        run.add(media(state))
        run.add(settings(state))
        run.add(speed(state))
        run.add(songSpeed(state))
        run.add(single: rememberedState(state))
        run.add(biblePaging(state))
        run.add(single: Check(area: "Слайд", name: "Фон не затемнюється сам собою",
                            status: state.style.dimBackground == 0 ? .ok : .warning,
                            detail: state.style.dimBackground == 0
                                ? "картинка йде як є, чорної плівки поверх немає"
                                : String(format: "поверх фону плівка %.0f %% — в автора такого налаштування немає",
                                         state.style.dimBackground * 100)))
        run.add(menu())
        run.add(input(state))
        run.add(interfaceSection(state))
        run.add(textSection(state))
        run.add(constructorSection(state))
        run.add(settingsWindow(state))
        run.add(mediaSection(state))
        run.add(selfContainedSection(state))
        run.add(importWindowSection(state: state))
        run.add(deskSection(state))
        run.add(songEditorSection(state))
        run.add(numberingSection(state))
        run.add(verseNumberingSection(state: state))
        run.add(numberingEditorSection(state: state))
        run.add(mySwordSection(state: state))
        run.add(webParametersSection(state: state))
        run.add(webTemplatesSection(state: state))
        run.add(webEditorSection(state: state))
        run.add(compatSection(state: state))
        run.add(nativeSection(state: state))
        run.add(nativeTopSection(state: state))
        run.add(nativeBibleSection(state: state))
        run.add(nativeSongsSection(state: state))
        run.add(nativeBottomSection(state: state))
        run.add(showSection(state: state))
        run.add(mediaFlowSection(state: state))
        run.add(mediaComplaintsSection(state: state))
        run.add(languageSection(state: state))
        run.add(originalNameSection(state: state))
        run.add(seededPagesSection(state: state))
        run.add(unlabeledButtonsSection(state: state))
        run.add(russianLeftoversSection(state: state))
        run.add(editorSnapshotsSection(state: state))
        run.add(settingsTabsSection(state: state))
        run.add(slideDrawingSection(state: state))
        run.add(sessionSection(state: state))
        run.add(constructorColoursSection(state: state))
        run.add(webEditorPanelSection(state: state))
        run.add(mirrorSection(state: state))
        run.add(focusSection(state: state))
        run.add(screenSection(state: state))
        return run.checks
    }

    private static func library(_ state: AppState) -> [Check] {
        let modules = state.allModules.count
        let songs = state.library?.songFiles.count ?? 0
        let failures = state.library?.failures.count ?? 0

        return [
            Check(area: "Бібліотека", name: "Модулі відкрито",
                  status: modules > 0 ? .ok : .failed,
                  detail: "перекладів \(modules), пісенників \(songs), не відкрилося \(failures)"),
            Check(area: "Бібліотека", name: "Тека даних",
                  status: FileManager.default.fileExists(atPath: state.modulesFolder.path) ? .ok : .failed,
                  detail: state.modulesFolder.path),
            Check(area: "Бібліотека", name: "Файл налаштувань програми",
                  status: state.configPath == nil ? .failed : .ok,
                  detail: state.configPath ?? "Slovo.ini не знайдено ні в пакеті, ні в особистій теці — діють значення, зашиті в код"),
        ]
    }

    private static func navigation(_ state: AppState) -> [Check] {
        guard let chapter = state.currentChapter, chapter.verses.count > 1 else {
            return [Check(area: "Навігація", name: "Гортання вірша", status: .skipped,
                          detail: "у поточному розділі менше двох віршів")]
        }
        let before = state.selectedVerseNumbers
        state.stepVerse(by: 1)
        let afterNext = state.selectedVerseNumbers
        state.stepVerse(by: -1)
        let afterBack = state.selectedVerseNumbers

        return [
            Check(area: "Навігація", name: "Гортання вірша",
                  status: afterNext != before ? .ok : .failed,
                  detail: "було \(before), стало \(afterNext)"),
            Check(area: "Навігація", name: "Повернення на попередній вірш",
                  status: afterBack == before ? .ok : .warning,
                  detail: "повернулися до \(afterBack)"),
        ]
    }

    private static func slide(_ state: AppState) -> [Check] {
        let composed = state.slide
        var checks = [
            Check(area: "Слайд", name: "Текст зібрано",
                  status: composed.mainText.isEmpty ? .failed : .ok,
                  detail: composed.mainText.isEmpty ? "порожньо" : String(composed.mainText.prefix(60))),
            Check(area: "Слайд", name: "Адресу зібрано",
                  status: composed.reference.isEmpty ? .warning : .ok,
                  detail: composed.reference),
        ]

        let background = state.style.backgroundImagePath
        checks.append(Check(area: "Слайд", name: "Фон знайдено",
                            status: background.map { FileManager.default.fileExists(atPath: $0) } ?? false ? .ok : .warning,
                            detail: background ?? "фон не задано"))

        // Настоящая отрисовка кадра — то, что уходит в зал, в NDI и в снимок.
        let image = SlideDrawing.image(.init(slide: composed, style: state.style, preset: nil),
                                       size: CGSize(width: 640, height: 360), opaque: true)
        checks.append(Check(area: "Слайд", name: "Кадр малюється",
                            status: image == nil ? .failed : .ok,
                            detail: image.map { "\($0.width)×\($0.height)" } ?? "малювальник повернув порожнє"))
        return checks
    }

    private static func outputs(_ state: AppState) -> [Check] {
        var checks: [Check] = []

        let screens = NSScreen.screens.count
        checks.append(Check(area: "Вивід", name: "Монітори",
                            status: .ok,
                            detail: screens > 1 ? "\(screens), слайд іде на другий" : "один, слайд іде вікном"))

        checks.append(Check(area: "Вивід", name: "Вікно слайда",
                            status: state.isLive ? .ok : .skipped,
                            detail: state.isLive ? "показується" : "показ вимкнено"))

        // Переход в трансляции рисуем сами — проверим, что складывание кадров
        // и правда даёт картинку, отличную от обоих концов.
        if let a = Diagnostics.solidImage(red: 255), let b = Diagnostics.solidImage(red: 0) {
            let middle = SlideFrameRenderer.blend(from: a, to: b, progress: 0.5,
                                                  transition: .fade, identity: 1, alpha: .straight)
            let ends = SlideFrameRenderer.blend(from: a, to: b, progress: 1,
                                                transition: .fade, identity: 2, alpha: .straight)
            let ok = middle != nil && ends != nil && middle?.pixels != ends?.pixels
            checks.append(Check(area: "NDI", name: "Перехід малюється покадрово",
                                status: ok ? .ok : .failed,
                                detail: ok
                                    ? "середина переходу відрізняється від його кінця — кадри справді складаються"
                                    : "складання кадрів переходу не дало картинки"))
        }

        // Меню: ни один пункт не должен потеряться при переезде из окна в
        // строку macOS. Список один (`SlovoMenu`), а показывает его теперь
        // только система — значит и проверять надо по живому меню.
        var systemTitles: Set<String> = []
        func collect(_ menu: NSMenu?) {
            guard let menu else { return }
            for item in menu.items {
                var title = item.title.trimmingCharacters(in: .whitespaces)
                // Отметку выбранного пункта в сличении не учитываем: галочка
                // стоит в подписи и меняется вместе с выбором.
                if title.hasPrefix("✓ ") { title = String(title.dropFirst(2)) }
                if !title.isEmpty { systemTitles.insert(title) }
                collect(item.submenu)
            }
        }
        collect(NSApp.mainMenu)
        var lostItems: [String] = []
        for group in NativeMenuGroup.allCases {
            for entry in SlovoMenu.entries(for: group, state: state) {
                var title = entry.title.trimmingCharacters(in: .whitespaces)
                if title.hasPrefix("✓ ") { title = String(title.dropFirst(2)) }
                guard !title.isEmpty else { continue }
                if !systemTitles.contains(title) { lostItems.append(title) }
            }
        }
        checks.append(Check(area: "Меню", name: "Усі пункти є в рядку меню macOS",
                            status: lostItems.isEmpty ? .ok : .failed,
                            detail: lostItems.isEmpty
                                ? "в описі \(NativeMenuGroup.allCases.count) розділів, усі пункти на місці"
                                : "немає в системному меню: " + lostItems.joined(separator: ", ")))

        // Перевод наших подписей
        let twice = OurWords.duplicateWords
        checks.append(Check(area: "Мова", name: "Словник наших написів без повторів",
                            status: twice.isEmpty ? .ok : .warning,
                            detail: twice.isEmpty
                                ? "переклад береться зі словника, повторів немає"
                                : "записані двічі: " + twice.joined(separator: ", ")))

        // NDI
        let ndi = state.ndi
        let ndiEnabled = state.outputs[.ndi].isEnabled
        checks.append(Check(area: "NDI", name: "Канал",
                            status: !ndiEnabled ? .skipped : (ndi.mode.isBroadcasting ? .ok : .warning),
                            detail: ndi.mode.title))
        if ndiEnabled {
            checks.append(Check(area: "NDI", name: "Кадри йдуть",
                                status: ndi.sentFramesNow > 0 ? .ok : .failed,
                                detail: "надіслано \(ndi.sentFramesNow), пропущено \(ndi.skippedFrameCount)"
                                    + (ndi.lastError.map { ", помилка: \($0)" } ?? "")))
            checks.append(Check(area: "NDI", name: "Частота кадрів",
                                status: .ok, detail: "\(ndi.frameRate) за секунду"))
        }
        // Оборванный приёмник не должен убивать программу. Пока SIGPIPE не был
        // погашен, отключение микшера уносило всё приложение — без отчёта о
        // падении и без строчки в журнале. Проверка стоит здесь затем, чтобы
        // защита не пропала однажды молча.
        var pipeAction = sigaction()
        sigaction(SIGPIPE, nil, &pipeAction)
        let pipeIgnored = pipeAction.__sigaction_u.__sa_handler
            .map { unsafeBitCast($0, to: UInt.self) } == 1
        checks.append(Check(area: "NDI", name: "Обрив зв'язку не вбиває програму",
                            status: pipeIgnored ? .ok : .failed,
                            detail: pipeIgnored
                                ? "SIGPIPE погашено: відключення приймача поверне помилку запису, і тільки"
                                : "SIGPIPE не погашено — відключення приймача закриє програму"))

        // Веб
        let web = state.web
        checks.append(Check(area: "Веб", name: "Сервер",
                            status: web.isRunning ? .ok : (state.outputs[.web].isEnabled ? .failed : .skipped),
                            detail: web.status.url ?? (web.status.lastError ?? "вимкнено")))
        if web.isRunning {
            checks.append(Check(area: "Веб", name: "Підписники",
                                status: .ok, detail: "\(web.status.subscribedClients)"))
        }

        // Remote API: три транспорта протокола, а не один. TCP и UDP не имеют
        // адреса, который можно показать человеку, поэтому про них видно
        // только одно — слушают порт или нет; молчащий сервер при включённой
        // настройке ищут потом анализатором пакетов, и это долго.
        let options = state.programOptions
        checks.append(Check(area: "Веб", name: "Remote API: TCP-сервер",
                            status: !options.tcpEnabled ? .skipped
                                : (web.status.tcpPort != nil ? .ok : .failed),
                            detail: !options.tcpEnabled ? "вимкнено в налаштуваннях"
                                : (web.status.tcpPort.map { "слухає порт \($0), підписників "
                                    + "\(web.status.tcpClients.subscribed) із \(web.status.tcpClients.connected)" }
                                   ?? "увімкнено в налаштуваннях, а слухача немає")))
        checks.append(Check(area: "Веб", name: "Remote API: UDP-сервер",
                            status: !options.udpEnabled ? .skipped
                                : (web.status.udpPort != nil ? .ok : .failed),
                            detail: !options.udpEnabled ? "вимкнено в налаштуваннях"
                                : (web.status.udpPort.map { "слухає порт \($0), сесій "
                                    + "\(web.status.udpClients.connected), з них підписано "
                                    + "\(web.status.udpClients.subscribed)" }
                                   ?? "увімкнено в налаштуваннях, а слухача немає")))

        // Объекты шаблона в вебе. Раньше странице уходил один текст, а как его
        // разложить — решал её собственный CSS: шаблон из «Конструктора» по
        // сети не попадал вовсе. Проверяем то, что и правда уедет: раскладку,
        // собранную из нынешнего шаблона.
        checks.append(contentsOf: webLayout(state))
        return checks
    }

    /// Раскладка слайда для страницы: объекты, их места и картинки.
    private static func webLayout(_ state: AppState) -> [Check] {
        let area = "Веб"
        guard let preset = state.preset(for: .web) ?? state.preset(for: .screen) else {
            return [Check(area: area, name: "Об'єкти шаблону йдуть у веб",
                          status: .skipped, detail: "шаблон не вибрано")]
        }
        var checks: [Check] = []
        let images = WebSlideImages()
        // Текст берём пробный, а не тот, что сейчас на экране: проверяем
        // ШАБЛОН, и при пустом зале все надписи ушли бы из раскладки как
        // пустые — отчёт сказал бы «в шаблоне нет объектов», хотя они есть.
        let layout = WebSlideLayout.make(
            preset: preset,
            withSecondTranslation: false,
            text: { object in
                let live = state.slideTexts.text(for: object)
                return live.isEmpty ? "проба" : live
            },
            imageID: { path in
                guard let url = state.presetImageURL(path) else { return nil }
                return images.register(path: path, url: url)
            },
            fontID: { family in
                guard let url = FontLoader.fileURL(forFamily: family) else { return nil }
                return images.register(path: "font:" + family, url: url)
            })

        // Доли холста: объект за его пределами в браузере растянет страницу, и
        // текст уедет за край экрана в притворе.
        let outside = layout.objects.filter {
            $0.x < -0.5 || $0.y < -0.5 || $0.x + $0.width > 1.5 || $0.y + $0.height > 1.5
        }
        checks.append(Check(area: area, name: "Об'єкти шаблону йдуть у веб",
                            status: layout.objects.isEmpty ? .warning
                                : (outside.isEmpty ? .ok : .failed),
                            detail: layout.objects.isEmpty
                                ? "у шаблоні «\(preset.name)» немає жодного видимого об'єкта"
                                : "шаблон «\(preset.name)»: об'єктів \(layout.objects.count) — "
                                    + layout.objects.map { "\($0.kind)" }.joined(separator: ", ")
                                    + (outside.isEmpty ? "" : "; за краєм полотна: \(outside.count)")))

        // Картинки: страница просит их коротким именем, и по этому имени
        // сервер обязан найти настоящий файл. Путей с диска браузер не видит.
        let names = ([layout.background.imageID] + layout.objects.map(\.imageID)).compactMap { $0 }
        let missing = names.filter { images.url(forID: $0) == nil }
        checks.append(Check(area: area, name: "Картинки шаблону віддаються за коротким ім'ям",
                            status: names.isEmpty ? .skipped : (missing.isEmpty ? .ok : .failed),
                            detail: names.isEmpty
                                ? "у шаблоні немає ні фону-картинки, ні об'єктів-картинок"
                                : (missing.isEmpty
                                   ? "імен \(names.count), кожне веде на файл; шляхів із диска в пакеті немає"
                                   : "не знаходяться: " + missing.joined(separator: ", "))))

        // Шрифты шаблона: браузеру их надо отдать файлом. Ищем по имени семьи,
        // и семью спрашиваем у самого файла — имя файла с ней не совпадает.
        let wanted = Set(layout.objects.map(\.fontFamily)).filter { !$0.isEmpty }
        let found = wanted.filter { FontLoader.fileURL(forFamily: $0) != nil }
        let system = wanted.subtracting(found)
        checks.append(Check(area: area, name: "Шрифти шаблону знаходяться файлом",
                            status: wanted.isEmpty ? .skipped : .ok,
                            detail: wanted.isEmpty ? "об'єктів із текстом немає"
                                : "названо \(wanted.count): віддаємо файлом \(found.count)"
                                    + (system.isEmpty ? ""
                                       : "; системними лишаються \(system.sorted().joined(separator: ", "))")))
        return checks
    }

    // MARK: - Разбор ссылки и адрес слайда

    private static func reference(_ state: AppState) -> [Check] {
        guard let module = state.primaryModule else {
            return [Check(area: "Швидкий вибір", name: "Розбір посилання", status: .skipped, detail: "немає перекладу")]
        }
        // Берём настоящее сокращение первой книги — оно своё в каждом языке.
        let book = module.books.first
        let token = book?.shortNames.first ?? "Быт"
        let parsed = ReferenceParser.resolve("\(token) 1:1", in: module)

        return [
            Check(area: "Швидкий вибір", name: "Розбір посилання",
                  status: parsed == nil ? .failed : .ok,
                  detail: parsed.map { "«\(token) 1:1» → \($0.book.fullName) \($0.chapter ?? 0)" }
                      ?? "«\(token) 1:1» не розібралося"),
            Check(area: "Переклади", name: "Скільки на слайді",
                  status: .ok,
                  detail: state.secondaryModuleIDs.isEmpty
                      ? "один: \(state.primaryModule?.info.shortName ?? "—")"
                      : "два: \(state.primaryModule?.info.shortName ?? "—") і "
                        + state.secondaryModuleIDs.compactMap { state.module($0)?.info.shortName }.joined(separator: ", ")
                        + "; вимикається правою кнопкою по вкладці"),
            Check(area: "Слайд", name: "Формат адреси",
                  status: state.slide.reference.isEmpty ? .warning : .ok,
                  detail: state.secondaryModuleIDs.isEmpty
                      ? "один переклад: «\(state.slide.reference)»"
                      : "два переклади: «\(state.slide.reference)»"),
        ]
    }

    // MARK: - Несколько стихов на одном слайде

    /// Проверяет ровно тот случай, ради которого это делалось: выбрали
    /// отрезок — на слайде весь текст с номерами, в адресе диапазон;
    /// выбрали вразнобой — в адресе перечисление через запятую.
    private static func multiVerse(_ state: AppState) -> [Check] {
        let book = state.selectedBookIndex
        let chapter = state.selectedChapterNumber
        let verses = state.selectedVerseNumbers
        defer {
            state.selectedBookIndex = book
            state.selectedChapterNumber = chapter
            state.selectedVerseNumbers = verses
        }

        guard let current = state.currentChapter, current.verses.count >= 8 else {
            return [Check(area: "Кілька віршів", name: "Відрізок", status: .skipped,
                          detail: "у розділі менше восьми віршів")]
        }
        let numbers = current.verses.map(\.number)

        // Отрезок 5–8.
        let range = Array(numbers[4...7])
        state.selectVerse(range[0], mode: .replace)
        state.selectVerse(range[3], mode: .extend)
        let rangeSlide = state.slide
        let rangeTail = "\(chapter):\(range[0])-\(range[3])"
        let hasAll = range.allSatisfy { rangeSlide.mainText.contains("\($0) ") }

        // Вразнобой: первый, третий и шестой.
        state.selectVerse(numbers[0], mode: .replace)
        state.selectVerse(numbers[2], mode: .toggle)
        state.selectVerse(numbers[5], mode: .toggle)
        let spread = state.slide
        let spreadTail = "\(chapter):\(numbers[0]),\(numbers[2]),\(numbers[5])"

        // И главное: уходит ли набранный отрезок в зал.
        state.selectVerse(range[0], mode: .replace)
        state.selectVerse(range[3], mode: .extend)
        let wasLive = state.isLive
        state.showCurrent()
        let live = state.liveSlide
        let liveHasAll = range.allSatisfy { live.mainText.contains("\($0) ") }
        let liveTail = live.reference.hasSuffix(rangeTail)
        state.isLive = wasLive

        return [
            Check(area: "Кілька віршів", name: "Відрізок іде в зал",
                  status: liveHasAll && liveTail ? .ok : .failed,
                  detail: liveHasAll && liveTail
                      ? "на проекторі «\(live.reference)», усі вірші на місці"
                      : "на проекторі «\(live.reference)», текст: \(live.mainText.prefix(60))"),
            Check(area: "Кілька віршів", name: "Відрізок в адресі",
                  status: rangeSlide.reference.hasSuffix(rangeTail) ? .ok : .failed,
                  detail: "«\(rangeSlide.reference)», очікувалося закінчення «\(rangeTail)»"),
            Check(area: "Кілька віршів", name: "Увесь текст із номерами",
                  status: hasAll ? .ok : .failed,
                  detail: hasAll ? "усі чотири вірші на одному слайді"
                                 : "на слайді не всі: \(rangeSlide.mainText.prefix(70))"),
            Check(area: "Кілька віршів", name: "Розрізнені через кому",
                  status: spread.reference.hasSuffix(spreadTail) ? .ok : .failed,
                  detail: "«\(spread.reference)», очікувалося закінчення «\(spreadTail)»"),
        ]
    }

    // MARK: - Поиск

    private static func search(_ state: AppState) -> [Check] {
        let desk = DeskModel.shared
        return [
            Check(area: "Пошук", name: "Вікно результатів",
                  status: .ok,
                  detail: desk.isSearchResultsShown ? "відкрито" : "сховано, відкривається по Ctrl+F3"),
            Check(area: "Пошук", name: "Знайдено за останнім запитом",
                  status: .ok,
                  detail: desk.searchedQuery.isEmpty ? "запиту ще не було"
                                                     : "«\(desk.searchedQuery)» — \(desk.hits.count)"),
        ]
    }

    // MARK: - План и история

    private static func plan(_ state: AppState) -> [Check] {
        let desk = DeskModel.shared
        return [
            Check(area: "План", name: "Пунктів", status: .ok, detail: "\(desk.plan.items.count)"),
            Check(area: "План", name: "Незбережені правки",
                  status: desk.plan.hasUnsavedChanges ? .warning : .ok,
                  detail: desk.plan.hasUnsavedChanges ? "є" : "немає"),
        ]
    }

    private static func history(_ state: AppState) -> [Check] {
        let records = DeskModel.shared.history.records
        return [Check(area: "Історія", name: "Записів",
                      status: .ok,
                      detail: records.isEmpty ? "порожньо"
                          : "\(records.count), остання: \(records[0].caption.prefix(60))")]
    }

    // MARK: - Песни

    private static func songs(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let books = state.songBooks
        checks.append(Check(area: "Пісні", name: "Пісенники відкрито",
                            status: books.isEmpty ? .failed : .ok,
                            detail: "\(books.count)"))
        guard let library = state.songLibrary, let first = books.first else { return checks }

        guard let book = library.book(first.id) else {
            checks.append(Check(area: "Пісні", name: "Читання пісенника", status: .failed,
                                detail: "\(first.id) не читається"))
            return checks
        }
        checks.append(Check(area: "Пісні", name: "Читання пісенника",
                            status: book.songs.isEmpty ? .failed : .ok,
                            detail: "«\(book.title)» — пісень \(book.songs.count)"))

        if let song = book.songs.first {
            checks.append(Check(area: "Пісні", name: "Частини пісні",
                                status: song.parts.isEmpty ? .warning : .ok,
                                detail: "«\(song.title)» — частин \(song.parts.count)"))
        }

        // Запись: собираем файл в памяти и читаем обратно. На диск не пишем —
        // песенники пользователя трогать нельзя.
        do {
            let data = try SongBookWriter.data(for: book)
            let again = try SongBook(data: data, name: first.id)
            let same = again.songs.count == book.songs.count && again.title == book.title
            checks.append(Check(area: "Пісні", name: "Запис пісенника",
                                status: same ? .ok : .failed,
                                detail: same ? "круговий прогін зійшовся, \(data.count / 1024) КБ"
                                             : "після запису \(again.songs.count) пісень замість \(book.songs.count)"))
        } catch {
            checks.append(Check(area: "Пісні", name: "Запис пісенника", status: .failed, detail: "\(error)"))
        }
        return checks
    }

    // MARK: - Текст, шаблоны, медиа, настройки

    private static func textModule(_ state: AppState) -> [Check] {
        let model = TextModuleModel.shared
        return [
            Check(area: "Текст", name: "Модуль готовий",
                  status: model.present == nil ? .failed : .ok,
                  detail: model.present == nil ? "нікуди віддавати слайд"
                                               : "підключено, символів \(model.document.body.count)"),
        ]
    }

    private static func templates(_ state: AppState) -> [Check] {
        let templates = state.schemes?.templates ?? []
        let withThumbs = templates.filter { $0.thumbnailURL(.single) != nil }.count
        return [
            Check(area: "Шаблони", name: "Розібрано",
                  status: templates.isEmpty ? .failed : .ok,
                  detail: "\(templates.count), з мініатюрами \(withThumbs)"),
            // Свой шаблон из Конструктора — тоже выбранный шаблон, просто не
            // авторский. Пока проверка смотрела только на имя авторской
            // схемы, она предупреждала о пустоте там, где выбор есть.
            Check(area: "Шаблони", name: "Поточний",
                  status: (state.templateName.isEmpty && state.slidePreset == nil) ? .warning : .ok,
                  detail: state.templateName.isEmpty
                      ? (state.slidePreset.map { "свій шаблон «\($0.name)»" } ?? "не вибрано")
                      : state.templateName),
            Check(area: "Фони", name: "Знайдено зображень",
                  status: state.backgroundImages.isEmpty ? .warning : .ok,
                  detail: "\(state.backgroundImages.count)"),
        ]
    }

    private static func media(_ state: AppState) -> [Check] {
        [Check(area: "Медіа", name: "Плеєр",
               status: .ok,
               detail: state.isMediaOpen ? "панель відкрита" : "панель схована, відкривається з меню")]
    }

    private static func settings(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(Check(area: "Налаштування", name: "Мова інтерфейсу",
                            status: state.language == nil ? .warning : .ok,
                            detail: state.language.map { "\($0.displayName) (\($0.code))" } ?? "не завантажено"))
        checks.append(Check(area: "Налаштування", name: "Перекладів інтерфейсу",
                            status: .ok, detail: "\(state.languageCatalog?.languages.count ?? 0)"))
        checks.append(Check(area: "Налаштування", name: "Зв'язати навігацію",
                            status: .ok, detail: state.arrowsLinked ? "увімкнено" : "вимкнено"))
        // Власник: «вывод не должен происходить, пока не будет нажата кнопка
        // показать или двойной щелчок или enter». Отже, «Активна» за
        // умовчанням знята — гортання міняє лише передпоказ.
        // Власник: «вывод не должен происходить, пока не будет нажата кнопка
        // показать… дальнейшее переключение штатно по стрелкам, до момента,
        // когда вывод экрана будет отключен».
        let wasLive = state.isLive
        state.isLive = false
        let quiet = !state.arrowsReachHall
        state.isLive = true
        let follows = state.arrowsReachHall == state.arrowsShowLive
        state.isLive = wasLive
        checks.append(Check(area: "Налаштування", name: "Стрілки виводять у зал лише після «Показати»",
                            status: quiet && follows ? .ok : .failed,
                            detail: (quiet ? "поки нічого не показано — лише передпоказ" : "виводять і без показу")
                                + "; " + (follows ? "після показу гортають зал" : "після показу зал не гортають")))
        checks.append(Check(area: "Налаштування", name: "Спільний фон",
                            status: .ok,
                            detail: state.showsCommonBackground
                                ? (state.commonBackgroundPath.map { ($0 as NSString).lastPathComponent } ?? "увімкнено, картинки немає")
                                : "вимкнено"))
        return checks
    }

    /// Сколько времени занимает одно нажатие.
    ///
    /// «Работает с задержкой» — не диагноз, а жалоба. Здесь она превращается
    /// в число: сколько миллисекунд главный поток занят одним переключением
    /// стиха и что именно его держит.
    /// Переключение куплетов. Владелец жаловался прямо: «в песнях при
    /// переключении слов сильные тормоза, и вместо текста песни появляются
    /// тексты писания». Причина была одна на обе беды — сборка слайда в
    /// режиме «Песни» уходила собирать место Писания, — и проверка сторожит
    /// именно её.
    /// Разбивка библейского текста на страницы (13.1) и (15).
    ///
    /// У автора длинный отрывок ложится на несколько страниц, и на слайде
    /// загораются «Пред./След. страница». У нас он втискивался в одну и
    /// мельчал до нечитаемого — владелец увидел это, сравнив снимки.
    private static func biblePaging(_ state: AppState) -> [Check] {
        let wasVerses = state.selectedVerseNumbers
        let wasSecondary = state.secondaryModuleIDs
        defer {
            state.secondaryModuleIDs = wasSecondary
            state.selectedVerseNumbers = wasVerses
        }
        state.secondaryModuleIDs = []

        // Делится ОДИН длинный стих: выделенные вручную несколько стихов
        // владелец просил выводить на один экран, и их мы не трогаем.
        guard let chapter = state.currentChapter,
              let longest = chapter.verses.max(by: { $0.text.count < $1.text.count }),
              longest.text.count > 120 else {
            return [Check(area: "Слайд", name: "Довгий вірш лягає на сторінки",
                          status: .skipped, detail: "у розділі немає достатньо довгого вірша")]
        }
        state.selectedVerseNumbers = [longest.number]

        let pages = state.biblePages.count
        guard pages > 1 else {
            return [Check(area: "Слайд", name: "Довгий вірш лягає на сторінки",
                          status: .warning,
                          detail: "найдовший вірш розділу вмістився на одну сторінку —"
                              + " перевірте PageSubDivide і fontminsize у [Bible]")]
        }

        var trouble: [String] = []
        if !state.hasNextSlidePage { trouble.append("«Наст. сторінка» не засвітилася") }
        let first = state.slide.mainText
        state.stepSlidePage(by: 1, live: false)
        if state.slide.mainText == first { trouble.append("крок уперед не змінив сторінку") }
        if !state.hasPreviousSlidePage { trouble.append("«Попер. сторінка» не засвітилася") }
        state.stepSlidePage(by: -1, live: false)
        if state.slide.mainText != first { trouble.append("крок назад не повернув сторінку") }

        return [Check(area: "Слайд", name: "Довгий вірш лягає на сторінки",
                      status: trouble.isEmpty ? .ok : .failed,
                      detail: trouble.isEmpty
                          ? "вірш із \(longest.text.count) знаків ліг на \(pages) сторінок, гортаються в обидва боки"
                          : trouble.joined(separator: "; "))]
    }

    /// Запоминается ли, на чём остановились.
    ///
    /// Владелец просил, чтобы последние изменения сохранялись сами и
    /// действовали при следующем запуске. Проверка настоящая: меняем выбор,
    /// смотрим, что в записанном состоянии он появился, и возвращаем всё на
    /// место.
    private static func rememberedState(_ state: AppState) -> Check {
        let wasBook = state.selectedBookIndex
        let wasChapter = state.selectedChapterNumber
        let wasVerses = state.selectedVerseNumbers
        defer {
            state.selectedBookIndex = wasBook
            state.selectedChapterNumber = wasChapter
            state.selectedVerseNumbers = wasVerses
        }

        guard state.books.count > 2 else {
            return Check(area: "Налаштування", name: "Програма пам'ятає, на чому зупинилися",
                         status: .skipped, detail: "мало книг для заміру")
        }
        let target = state.books.count - 2
        state.selectedBookIndex = target

        var trouble: [String] = []
        if Defaults.lastBookIndex != target {
            trouble.append("книга: записано \(Defaults.lastBookIndex.map(String.init) ?? "ничего"), вибрано \(target)")
        }
        if Defaults.lastChapter != state.selectedChapterNumber {
            trouble.append("розділ: записано \(Defaults.lastChapter.map(String.init) ?? "ничего")")
        }
        if Defaults.lastMode != state.mode.rawValue {
            trouble.append("режим: записано \(Defaults.lastMode ?? "ничего")")
        }
        // Вид слайда целиком: размер шрифта человек двигает ползунком, и
        // записанным должен оказаться именно новый.
        let wasSize = state.style.main.fontSize
        state.style.main.fontSize = wasSize + 0.017
        state.refreshSlide()
        let saved = Defaults.slideStyle.flatMap { try? JSONDecoder().decode(SlideStyle.self, from: $0) }
        if let saved, abs(saved.main.fontSize - state.style.main.fontSize) > 0.0001 {
            trouble.append(String(format: "розмір шрифту: записано %.3f, вибрано %.3f",
                                  saved.main.fontSize, state.style.main.fontSize))
        } else if saved == nil {
            trouble.append("вигляд слайда не записався зовсім")
        }
        state.style.main.fontSize = wasSize

        return Check(area: "Налаштування", name: "Програма пам'ятає, на чому зупинилися",
                     status: trouble.isEmpty ? .ok : .failed,
                     detail: trouble.isEmpty
                         ? "книга, розділ, вірш, режим, шаблон, фон, пісня і весь вигляд слайда (шрифт, розмір, кольори, поля) записуються одразу"
                         : trouble.joined(separator: "; "))
    }

    private static func songSpeed(_ state: AppState) -> [Check] {
        let wasMode = state.mode
        let wasPart = state.songPartIndex
        let wasSong = state.songIndex
        defer { state.mode = wasMode; state.songPartIndex = wasPart; state.songIndex = wasSong }

        state.mode = .songs
        // Песню надо именно ВЫБРАТЬ: без этого шаг по куплетам не делается
        // вовсе, и проверка меряла бы собственную нерасторопность.
        if state.songIndex == nil, !state.songMatches.isEmpty { state.songIndex = 0 }
        guard let song = state.selectedSong, song.parts.count > 1 else {
            return [Check(area: "Відгук", name: "Перемикання куплета", status: .skipped,
                          detail: "не вибрано пісню з кількома частинами")]
        }
        state.songPartIndex = song.parts[0].index
        state.showSongPart(song, song.parts[0])

        // 0. Песня с НЕПОДРЯД идущими номерами частей.
        //
        //    Без неё проверка бессильна: у настоящих песенников части обычно
        //    нумерованы с нуля подряд, и «номер части» неотличим от «места в
        //    списке». Именно на этом прежняя проверка и прошла со сломанным
        //    кодом — стрелка не двигала ничего, а отчёт был зелёный. Здесь
        //    номера 3, 8 и 14: перепутать одно с другим уже нельзя.
        let odd = Song(index: 999, title: "Перевірна пісня",
                       parts: [SongPart(index: 3, kind: "Куплет", text: "перший рядок"),
                               SongPart(index: 8, kind: "Приспів", text: "другий рядок"),
                               SongPart(index: 14, kind: "Куплет", text: "третій рядок")])
        state.songPartIndex = 3
        state.showSongPart(odd, odd.parts[0])
        state.stepSongPart(by: 1, live: false)
        let oddAfter = state.slide.mainText
        let oddNumber = state.songPartIndex
        state.stepSongPart(by: -1, live: false)
        let oddBack = state.slide.mainText

        var oddTrouble: [String] = []
        if oddAfter != "другий рядок" {
            oddTrouble.append("крок уперед дав «\(oddAfter)» замість другої частини")
        }
        if oddNumber != 8 {
            oddTrouble.append("номер частини став \(oddNumber.map(String.init) ?? "пусто") замість 8")
        }
        if oddBack != "перший рядок" {
            oddTrouble.append("крок назад дав «\(oddBack)» замість першої частини")
        }

        // Стрелка в режиме «Песни» не смеет трогать Библию, даже когда песня
        // не выбрана. Ровно это владелец и увидел: список куплетов на
        // экране, а в зале место Писания.
        let keptSong = state.songIndex
        state.songIndex = nil
        let bibleBefore = state.selectedVerseNumbers
        state.stepSongPart(by: 1, live: false)
        state.stepVerse(by: 1, live: false)
        let leaked = state.selectedVerseNumbers != bibleBefore
        state.songIndex = keptSong

        // Возвращаем на слайд настоящую песню: дальше проверяется она, а
        // синтетическая своё дело сделала.
        state.songPartIndex = song.parts[0].index
        state.showSongPart(song, song.parts[0])

        // 1. Куплет обязан МЕНЯТЬСЯ. Прежняя проверка этого не требовала и
        //    спокойно проходила, пока стрелка не двигала ничего: номер части
        //    считали местом в списке, а это разные вещи.
        // Часть может лечь на несколько страниц: пустая строка внутри куплета
        // — это разрыв, поставленный составителем сборника, и стрелка листает
        // страницы, прежде чем уйти на следующую часть. Так у автора, и
        // проверять надо обе ступени: и страницы, и переход.
        let first = state.slide.mainText
        var steps = 0
        var pagesSeen = 1
        while state.songPartIndex == song.parts[0].index, steps < 12 {
            state.stepSongPart(by: 1, live: false)
            steps += 1
            if state.songPartIndex == song.parts[0].index { pagesSeen += 1 }
        }
        let second = state.slide.mainText

        var moves: [String] = []
        if second == first { moves.append("крок уперед нічого не змінив") }
        if state.songPartIndex != song.parts[1].index {
            moves.append("за \(steps) кроків так і не дійшли до другої частини"
                         + " (номер зараз \(state.songPartIndex.map(String.init) ?? "пусто"))")
        }
        let wanted = song.parts[1].lines.joined(separator: "\n")
        if !second.isEmpty, !wanted.contains(second.prefix(20)) {
            moves.append("після кроку на слайді не друга частина пісні")
        }

        // И обратно тем же числом шагов — на первую часть.
        for _ in 0..<steps { state.stepSongPart(by: -1, live: false) }
        let back = state.slide.mainText
        if state.songPartIndex != song.parts[0].index {
            moves.append("крок назад не повернув на першу частину")
        }
        if back != first { moves.append("крок назад не повернув на попередню сторінку") }

        // 2. Стоимость шага.
        var forward = true
        let start = Date()
        for _ in 0..<20 {
            state.stepSongPart(by: forward ? 1 : -1, live: true)
            forward.toggle()
        }
        let each = Date().timeIntervalSince(start) / 20 * 1000

        // 3. Стоимость ПЕРЕСБОРКИ. Её зовёт всё подряд — дочитанная книга,
        //    применённые настройки, пересчёт нумерации. Пока она искала песню
        //    заново, поиск шёл по всему песеннику, и программа вставала колом
        //    ровно во время пения.
        let rebuildStart = Date()
        for _ in 0..<50 { state.refreshSlide() }
        let rebuild = Date().timeIntervalSince(rebuildStart) / 50 * 1000

        // 4. Что осталось на слайде: если сборка снова уйдёт за местом
        //    Писания, здесь окажется стих, а не строка песни.
        let shown = state.slide.mainText.prefix(40)
        let songText = song.parts.flatMap(\.lines).joined(separator: "\n")
        let isSong = shown.isEmpty || songText.contains(shown)

        return [Check(area: "Відгук", name: "У піснях стрілка не гортає Біблію",
                      status: leaked ? .failed : .ok,
                      detail: leaked
                          ? "пісню не вибрано — а стрілка пішла гортати вірші Біблії"
                          : "без вибраної пісні стрілка не чіпає місце Писання"),
                Check(area: "Відгук", name: "Номер частини не плутається з місцем у списку",
                      status: oddTrouble.isEmpty ? .ok : .failed,
                      detail: oddTrouble.isEmpty
                          ? "частини з номерами 3, 8, 14 гортаються вперед і назад правильно"
                          : oddTrouble.joined(separator: "; ")),
                Check(area: "Відгук", name: "Куплети перемикаються",
                      status: moves.isEmpty ? .ok : .failed,
                      detail: moves.isEmpty
                          ? "вперед і назад по пісні «\(song.title)»: частин \(song.parts.count),"
                            + " у першій сторінок \(pagesSeen), дійшли за \(steps) кроків"
                          : moves.joined(separator: "; ")),
                Check(area: "Відгук", name: "Перемикання куплета",
                      status: each < 16 ? .ok : .warning,
                      detail: String(format: "%.1f мс на натискання", each)
                          + " (16 мс — це кадр у 60 Гц)"),
                Check(area: "Відгук", name: "Перезбирання слайда пісні",
                      // Порог с запасом: важно, что это доли миллисекунды, а
                      // не поиск по всему сборнику; на загруженной машине
                      // строгая двойка давала предупреждение на ровном месте.
                      status: rebuild < 4 ? .ok : .warning,
                      detail: String(format: "%.2f мс — пісню не шукаємо заново, беремо показану", rebuild)),
                Check(area: "Відгук", name: "У пісні на слайді пісня",
                      status: isSong ? .ok : .failed,
                      detail: isSong ? "після двадцяти перемикань на слайді, як і раніше, пісня «\(song.title)»"
                                     : "на слайді не пісня, а «\(shown)» — збирання пішло за місцем Писання")]
    }

    private static func speed(_ state: AppState) -> [Check] {
        guard let chapter = state.currentChapter, chapter.verses.count > 3 else {
            return [Check(area: "Відгук", name: "Перемикання вірша", status: .skipped,
                          detail: "мало віршів для заміру")]
        }

        func measure(_ times: Int, _ body: () -> Void) -> Double {
            let start = Date()
            for _ in 0..<times { body() }
            return Date().timeIntervalSince(start) / Double(times) * 1000
        }

        // Замер как есть — со всеми включёнными выводами.
        var forward = true
        let full = measure(20) {
            state.stepVerse(by: forward ? 1 : -1, live: true)
            forward.toggle()
        }

        // Тот же замер с выключенной трансляцией: разница покажет её цену.
        let wasNDI = state.outputs[.ndi].isEnabled
        if wasNDI { state.setNDIEnabled(false) }
        let withoutNDI = measure(20) {
            state.stepVerse(by: forward ? 1 : -1, live: true)
            forward.toggle()
        }
        if wasNDI { state.setNDIEnabled(true) }

        // И совсем без вывода в зал — только предпросмотр.
        let wasLive = state.isLive
        state.isLive = false
        let previewOnly = measure(20) {
            state.stepVerse(by: forward ? 1 : -1, live: false)
            forward.toggle()
        }
        state.isLive = wasLive

        // Переключение книги меряем на прогретых книгах: именно так оно и
        // выглядит в работе, потому что перевод разбирается заранее в фоне.
        // Холодный случай отдельной строкой — он бывает только сразу после
        // запуска, пока прогрев не закончился.
        let firstBook = state.selectedBookIndex
        let probeBooks = Array(state.books.prefix(6))
        let warmed = probeBooks.filter { state.primaryModule?.cachedChapters(ofBook: $0) != nil }.count

        var next = firstBook
        let bookSwitch = measure(6) {
            next = (next + 1) % max(1, state.books.count)
            state.selectedBookIndex = next
        }
        state.selectedBookIndex = firstBook

        // Отрисовка надписи слайда: подбор кегля меряет строку шесть раз.
        let sample = state.slide.mainText.isEmpty ? String(repeating: "Слово ", count: 30)
                                                  : state.slide.mainText
        let layer = state.style.main
        let draw = measure(20) {
            _ = OutlinedText.measureCost(text: sample, layer: layer, height: 1080,
                                         width: 1600, lineSpacing: state.style.lineSpacing)
        }

        let status: Status = full < 16 ? .ok : (full < 50 ? .warning : .failed)
        return [
            Check(area: "Відгук", name: "Перемикання книги",
                  status: bookSwitch < 30 ? .ok : (bookSwitch < 120 ? .warning : .failed),
                  detail: String(format: "%.1f мс; прогріто книг із шести: %d", bookSwitch, warmed)),
            Check(area: "Відгук", name: "Малювання напису слайда",
                  status: draw < 8 ? .ok : (draw < 20 ? .warning : .failed),
                  detail: String(format: "%.1f мс за прохід, а їх два: передпоказ і вікно слайда", draw)),
            Check(area: "Відгук", name: "Перемикання вірша",
                  status: status,
                  detail: String(format: "%.1f мс на натискання (16 мс — це кадр у 60 Гц)", full)),
            Check(area: "Відгук", name: "З них на трансляцію NDI",
                  status: full - withoutNDI < 5 ? .ok : .warning,
                  detail: String(format: "%.1f мс; без NDI виходить %.1f мс", full - withoutNDI, withoutNDI)),
            Check(area: "Відгук", name: "Лише передпоказ",
                  status: previewOnly < 16 ? .ok : .warning,
                  detail: String(format: "%.1f мс", previewOnly)),
        ]
    }

    /// Сверка меню: у каждого пункта смотрим, есть ли за ним действие.
    /// Именно это отвечает на вопрос «меню не соответствует».
    private static func menu() -> [Check] {
        guard let main = NSApp.mainMenu else {
            return [Check(area: "Меню", name: "Головне меню", status: .failed, detail: "не побудовано")]
        }
        var checks: [Check] = []
        var dead: [String] = []
        var live = 0
        var disabled = 0

        for top in main.items {
            guard let submenu = top.submenu else { continue }
            for item in submenu.items where !item.isSeparatorItem {
                if item.submenu != nil { continue }
                if item.action == nil {
                    disabled += 1
                    dead.append("\(top.title) → \(item.title)")
                } else {
                    live += 1
                }
            }
        }
        checks.append(Check(area: "Меню", name: "Склад",
                            status: .ok,
                            detail: "розділів \(main.items.count), робочих пунктів \(live), вимкнених \(disabled)"))
        if !dead.isEmpty {
            checks.append(Check(area: "Меню", name: "Пункти без дії",
                                status: .warning,
                                detail: dead.prefix(12).joined(separator: "; ")))
        }
        return checks
    }

    /// Стрелки: смотрим, кто сейчас забирает клавиатуру. Если фокус ушёл в
    /// текстовый вид, перехватчик стрелок намеренно молчит — и это ровно тот
    /// случай, когда «переключение стрелками не работает».
    private static func input(_ state: AppState) -> [Check] {
        let responder = NSApp.keyWindow?.firstResponder
        let name = responder.map { String(describing: type(of: $0)) } ?? "немає"
        let blocking = responder is NSTextView || responder is NSTextField

        return [
            Check(area: "Клавіатура", name: "Перехоплювач стрілок",
                  status: state.keyHandlersInstalled ? .ok : .failed,
                  detail: state.keyHandlersInstalled
                      ? "стоїть: ← → ↑ ↓ гортають вірші, Enter виводить"
                      : "не стоїть — стрілки не працюють"),
            Check(area: "Клавіатура", name: "Хто тримає фокус",
                  status: blocking ? .warning : .ok,
                  detail: blocking ? "\(name) — стрілки йдуть йому" : name),
        ]
    }

    // MARK: - Раздел 7 «Интерфейс»

    /// Проверки раздела 7 руководства и кнопок (21)/(22) из 5.1.4.
    ///
    /// Ни одна из них ничего не удаляет и не пишет: окно «Перевод интерфейса»
    /// поднимается только на чтение, отказ на удаление спрашивается отдельным
    /// методом без побочного действия.
    private static func interfaceSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let interface = InterfaceSettings.shared
        let area = "Інтерфейс"

        // Вид списков (21)/(22) — три независимые пары, как в файле умолчаний.
        let ini = IniSettings.locateConfig().flatMap { try? IniSettings(fileAt: $0) }
        var pairs: [String] = []
        var matches = 0
        for scope in InterfaceSettings.ListScope.allCases {
            let books = interface.bookView(scope)
            let lines = interface.verseView(scope)
            let iniBooks = ini?.int("BooksStyle", in: scope.iniSection)
            let iniLines = ini?.int("LinesStyle", in: scope.iniSection)
            if iniBooks == (interface.booksAreFlowing(in: scope) ? 0 : 1),
               iniLines == (lines == .singleLine ? 1 : 0) { matches += 1 }
            pairs.append("[\(scope.iniSection)] книги \(books.rawValue)"
                         + " / рядки \(lines.rawValue)"
                         + " (ini \(iniBooks.map { "\($0)" } ?? "—")/\(iniLines.map { "\($0)" } ?? "—"))")
        }
        checks.append(Check(area: area, name: "Вигляд списків за режимами",
                            status: .ok,
                            detail: pairs.joined(separator: "; ")
                                + "; збіглося з ini: \(matches) із \(InterfaceSettings.ListScope.allCases.count)"))

        // Кнопки (22): ровно две и с подсказками автора. И число, и подсказки
        // берём из самой панели, а не пишем словами: список
        // `ListStyleButtons.bookButtons` — это то, что нарисовано в окне,
        // поэтому третья кнопка сразу вылезет в отчёт.
        let bookButtons = ListStyleButtons.bookButtons
        let bookHints = bookButtons.map { state.language?.hint($0.key, form: "MainForm") }
        let missing = zip(bookButtons, bookHints).filter { $0.1 == nil }.map { $0.0.key }
        let rightCount = bookButtons.count == 2
        checks.append(Check(area: area, name: "Кнопки вигляду книг (22)",
                            status: !rightCount ? .failed : (missing.isEmpty ? .ok : .warning),
                            detail: "кнопок \(bookButtons.count) (в оригіналі 2); підказки: "
                                  + zip(bookButtons, bookHints)
                                      .map { "\($0.0.key) — «\($0.1 ?? "нет в переводе")»" }
                                      .joined(separator: ", ")))

        // Кнопки (21) — у песенника свой ключ с приставкой формы.
        let songLines = state.language?.hint("SongsPluginFrame->PngSBOneLine", form: "MainForm")
        checks.append(Check(area: area, name: "Кнопки вигляду рядків (21)",
                            status: .ok,
                            detail: "Біблія/Текст: «\(state.hint("PngSBOneLine", default: "—"))»;"
                                  + " Пісні: «\(songLines ?? "нет в переводе")»"))

        // 7.2: оформление применено к приложению, а не только записано.
        let wanted = interface.appearance
        let actual = NSApp?.appearance?.name.rawValue ?? "за системою"
        let applied: Bool
        switch wanted {
        case .system: applied = NSApp?.appearance == nil
        case .light:  applied = NSApp?.appearance?.name == .aqua
        case .dark:   applied = NSApp?.appearance?.name == .darkAqua
        }
        checks.append(Check(area: area, name: "Стиль інтерфейсу (7.2)",
                            status: applied ? .ok : .failed,
                            detail: "вибрано «\(wanted.title)», у застосунку \(actual)"))

        // 7.1 (6) (7): очистка и копирование обязаны идти по всему окну.
        checks.append(contentsOf: translateWindow(state))

        // 7.3: свой перевод виден в списке выбора языка.
        let originals = InterfaceWindows.languageDirectory(state: state)
        let all = InterfaceLanguageStore.languages(originals: originals)
        let mine = all.filter { InterfaceLanguageStore.isUserOwned(code: $0.code) }
        let catalog = state.languageCatalog?.languages.map { $0.code.lowercased() } ?? []
        let invisible = mine.filter { !catalog.contains($0.code.lowercased()) }
        checks.append(contentsOf: languageProbe(state))
        checks.append(Check(area: area, name: "Вибір мови (7.3)",
                            status: invisible.isEmpty ? .ok : .failed,
                            detail: invisible.isEmpty
                                ? "перекладів \(all.count), своїх \(mine.count) — усі видно головному вікну"
                                : "головне вікно не бачить своїх перекладів: "
                                  + invisible.map { $0.code }.joined(separator: ", ")
                                  + " — потрібна вставка на InterfaceLanguageStore.mergedDirectory"))
        return checks
    }

    /// 7.3 «Выбор языка»: свой перевод обязан дойти до главного окна.
    ///
    /// Проверка не на словах: кладём в свою папку переводов пробный файл с
    /// кодом, которого у оригинала нет, объявляем о правке — и смотрим,
    /// увидел ли его каталог главного окна. Файл убирается сразу, каким бы ни
    /// был ответ; папку `Language` рядом с VisioBible проверка не трогает
    /// вовсе — туда мы только смотрим.
    private static func languageProbe(_ state: AppState) -> [Check] {
        let area = "Інтерфейс"
        let name = "Свій переклад у головному вікні (7.3)"
        let originals = InterfaceWindows.languageDirectory(state: state)
        // Код нарочно не из списка ISO: занять чужой и потом стереть чужой
        // файл — хуже, чем пропустить проверку.
        let code = "zz"

        guard !InterfaceLanguageStore.isUserOwned(code: code) else {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "код «\(code)» зайнятий своїм перекладом — зразок не створюємо")]
        }

        defer {
            try? InterfaceLanguageStore.delete(code: code)
            InterfaceLanguageStore.announceChange(originals: originals)
        }

        let draft: InterfaceLanguageStore.Draft = [
            "MainForm": ["N1": InterfaceLanguageStore.TextPair(caption: "Файл")],
        ]
        try? InterfaceLanguageStore.write(draft: draft, code: code, displayName: "Самоперевірка")
        InterfaceLanguageStore.announceChange(originals: originals)

        let seen = state.languageCatalog?.languages
            .contains { $0.code.caseInsensitiveCompare(code) == .orderedSame } ?? false
        return [Check(area: area, name: name,
                      status: seen ? .ok : .failed,
                      detail: seen
                        ? "новий і правлений переклад видно без перезапуску"
                        : "головне вікно читає лише теку Language пакета — потрібна вставка"
                          + " в AppState.loadLanguages() на InterfaceLanguageStore"
                          + ".mergedDirectory(originals:) і підписка на"
                          + " .slovoInterfaceLanguagesChanged")]
    }

    /// Окно «Перевод интерфейса» (7.1) — только чтение.
    private static func translateWindow(_ state: AppState) -> [Check] {
        let area = "Інтерфейс"
        let originals = InterfaceWindows.languageDirectory(state: state)
        let model = LocalizeTranslateModel(originals: originals,
                                           startingCode: state.language?.code ?? "ru")
        guard model.reference != nil else {
            return [Check(area: area, name: "Переклад інтерфейсу (7.1)", status: .skipped,
                          detail: "немає файлів Language/*.lng у \(originals.path)")]
        }

        var checks: [Check] = []

        // (7) «Скопировать ВСЕ переводы для окна»: копируем, стоя на вкладке
        // объектов, и смотрим вкладку сообщений — она обязана заполниться.
        model.formName = "LocalizeTranslateForm"
        model.tab = .objects
        model.copyFormFromOriginal()
        model.tab = .texts
        let texts = model.rows
        let filledTexts = texts.filter { !$0.caption.isEmpty }.count
        model.tab = .errors
        let errors = model.rows
        let filledErrors = errors.filter { !$0.caption.isEmpty }.count

        let wholeForm = !texts.isEmpty && filledTexts == texts.count
        checks.append(Check(area: area, name: "Копіювати все вікно (7)",
                            status: wholeForm ? .ok : .failed,
                            detail: "із вкладки «Об'єкти» заповнено «Тексти» \(filledTexts) із \(texts.count),"
                                  + " «Помилки» \(filledErrors) із \(errors.count)"))

        // (6) «Очистить ВСЕ переводы для окна» — тем же способом.
        model.tab = .objects
        model.clearForm()
        model.tab = .texts
        let leftovers = model.rows.filter { !$0.caption.isEmpty }.count
        checks.append(Check(area: area, name: "Очистити все вікно (6)",
                            status: leftovers == 0 ? .ok : .failed,
                            detail: leftovers == 0 ? "після очищення на вкладці «Тексти» порожньо"
                                                   : "лишилося неочищених рядків: \(leftovers)"))

        // (4) Отказ удалять перевод, выбранный в главном окне (TextMessages12).
        model.activeLanguageCode = state.language?.code ?? "ru"
        model.languageCode = model.activeLanguageCode
        let refusal = model.deleteRefusal()
        checks.append(Check(area: area, name: "Відмова видалити поточний переклад (4)",
                            status: refusal == .inUse ? .ok : .failed,
                            detail: refusal == .inUse
                                ? "«" + state.text("TextMessages12", form: "LocalizeTranslateForm",
                                                   default: "Нельзя удалить текущий перевод")
                                        .replacingOccurrences(of: "\\n", with: " ") + "»"
                                : "переклад «\(model.languageCode)» видалився б мовчки"))

        // (12) У вкладки «Ошибки» свои заголовки колонок.
        let ownColumn = state.text("LVTextsError->Column1", form: "LocalizeTranslateForm", default: "")
        let sharedColumn = state.text("LVTexts->Column1", form: "LocalizeTranslateForm", default: "")
        checks.append(Check(area: area, name: "Колонки вкладки «Помилки» (12)",
                            status: ownColumn.isEmpty ? .warning : .ok,
                            detail: ownColumn.isEmpty
                                ? "LVTextsError->Column1 немає в перекладі, показується «\(sharedColumn)»"
                                : "LVTextsError->Column1 = «\(ownColumn)»"))
        return checks
    }

    // MARK: - Раздел 5.2 «Модуль Текст»

    private static func textSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let model = TextModuleModel.shared
        let area = "Текст"

        // Разбивка берётся из секции [Text] файла умолчаний программы.
        let page = model.pagination
        checks.append(Check(area: area, name: "Опції роботи з [Text]",
                            status: model.configPath == nil ? .warning : .ok,
                            detail: (model.configPath ?? "ini не знайдено, значення за умовчанням")
                                + "; сторінки \(page.splitsIntoPages ? "так" : "ні")"
                                + ", абзаци \(page.splitsIntoParagraphs ? "так" : "ні")"
                                + ", перенесення \(page.wrapsWords ? "так" : "ні")"
                                + ", \(page.charactersPerLine)×\(page.linesPerPage)"
                                + ", заповнення \(Int(page.minimumFillPercent)) %"))

        // Разбивка длинного текста на страницы — на своём образце, чтобы не
        // тронуть то, что набрал оператор.
        let sample = PlainTextDocument(
            title: "Дорогі!",
            body: (0..<12).map { "Налаштуйтеся на служіння, рядок номер \($0 + 1)." }
                .joined(separator: "\n"))
        let pages = sample.pageCount(page)
        checks.append(Check(area: area, name: "Розбивка на сторінки",
                            status: pages > 1 || !page.splitsIntoPages ? .ok : .warning,
                            detail: "зразок із \(sample.body.count) знаків ліг на \(pages) стор."))

        // Куда уходит собранный слайд.
        checks.append(Check(area: area, name: "Слайд тексту підключено",
                            status: model.present == nil ? .failed : .ok,
                            detail: model.present == nil
                                ? "нікуди віддавати — немає вставки TextModuleModel.shared.present"
                                : "сторінок у наборі \(model.pageCount)"))

        // «Показанный текст попадает в Историю (11)»: сначала формат строки —
        // заголовок объявления обязан встать на место адреса, начало текста —
        // на место цитаты, как на снимке к 5.2 (стр. 19).
        let shown = sample.slide(atPage: 0, page)
        let record = HistoryRecord(kind: .text, reference: shown.reference, quote: shown.mainText)
        let goodCaption = record.caption.hasPrefix("Дорогі!") && record.caption.contains("Налаштуйтеся")
        checks.append(Check(area: area, name: "Рядок Історії з тексту (11)",
                            status: goodCaption ? .ok : .failed,
                            detail: "рядок списку: «\(record.caption.prefix(60))»"))

        // …а потом сама дорога: показываем объявление так, как это делает
        // оператор, и смотрим список Истории.
        checks.append(contentsOf: textShowPath(state))

        // Порядок пунктов контекстного меню списка стихов (5.1.4).
        let order = VerseMenuEntry.allCases.map(\.rawValue)
        let wanted = ["MIAddToPlan", "MICopyToText", "MICopyToClipboard"]
        checks.append(Check(area: area, name: "Меню списку віршів (5.1.4)",
                            status: order == wanted ? .ok : .failed,
                            detail: order.joined(separator: " → ")))

        // Подпись вкладки (18) из файла перевода, а не зашитая.
        let tabs = AppState.WorkMode.allCases.map { $0.title(in: state) }
        checks.append(Check(area: area, name: "Підписи вкладок модулів (18)",
                            status: .ok,
                            detail: tabs.joined(separator: " | ")))

        // Подписи колонок и панелей главного окна. Проверка настоящая: берём
        // ключ у автора и смотрим, вернулось ли из файла перевода что-то
        // отличное от нашего запасного слова. Иначе окно оставалось бы
        // русским при украинском или английском языке интерфейса.
        let paneKeys: [(String, String)] = [
            ("Label9", "Класс:"), ("Label8", "Книга:"), ("Label1", "Глава:"),
            ("Label3", "Стих:"), ("Label3D15", "План:"), ("Label3D3", "История:"),
            ("Label3D2", "Предварительный просмотр"), ("Label3D1", "Управление:"),
            ("Label3D10", "Шаблон:"), ("Label3D22", "Фон Слайда:"),
            ("Label3D23", "Фон Общий:"), ("Label3D11", "Поиск:"),
            ("Label3D14", "Быстр. выбор:"),
        ]
        let missing = paneKeys.filter { key, fallback in
            state.language?.caption(key, form: "MainForm", default: "") == ""
        }
        checks.append(Check(area: area, name: "Підписи панелей головного вікна",
                            status: missing.isEmpty ? .ok : .warning,
                            detail: missing.isEmpty
                                ? "усі \(paneKeys.count) ключі знайдено в «\(state.language?.displayName ?? "?")»: "
                                  + paneKeys.prefix(4).map { state.text($0.0, default: $0.1) }.joined(separator: " · ")
                                : "немає у файлі перекладу: " + missing.map(\.0).joined(separator: ", ")))
        return checks
    }

    /// Заголовок образца самопроверки.
    ///
    /// Нарочно не «Дорогие!» из руководства: по этой строке проверка находит в
    /// «Истории» (11) свои записи, чтобы убрать их за собой, а объявление с
    /// заголовком «Дорогие!» человек и правда мог показать в зале.
    private static let textProbeTitle = "Самоперевірка «Слова»"

    /// Дорога показанного текста: зал → «История» (11), Enter/F5 и стрелки.
    ///
    /// Проверка настоящая, а не по формату строки: набираем образец, выводим
    /// его так же, как это делает оператор, и смотрим список Истории, слайд в
    /// зале и номер страницы. Всё, что она тронула, возвращается на место —
    /// набранное объявление, режим окна, выделенные стихи, оба слайда и сами
    /// записи в Истории: список оператора не место для нашего образца.
    ///
    /// В зале образец не мелькнёт: проверка идёт целиком в одном проходе цикла
    /// событий, а прежний слайд возвращается в том же проходе — к ближайшей
    /// отрисовке на экране снова стоит то, что стояло до неё.
    private static func textShowPath(_ state: AppState) -> [Check] {
        let area = "Текст"
        let model = TextModuleModel.shared
        let desk = DeskModel.shared

        let savedDocument = model.document
        model.savesToSettings = false
        let savedMode = state.mode
        let savedVerses = state.selectedVerseNumbers
        let savedPreview = state.slide
        let savedLive = state.liveSlide
        let savedIsLive = state.isLive

        defer {
            // Сначала История: записи мог оставить и наш показ, и вставка в
            // `AppState.showCurrent()`, если она уже стоит.
            for record in desk.history.records
            where record.kind == .text && record.caption.hasPrefix(textProbeTitle) {
                desk.removeHistory(record.id)
            }
            model.document = savedDocument
            model.savesToSettings = true
            state.mode = savedMode
            state.selectedVerseNumbers = savedVerses
            state.present(savedLive, live: true)
            state.present(savedPreview, live: false)
            state.isLive = savedIsLive
        }

        var checks: [Check] = []

        // Показ в зал. Режим ставим сами: строку Истории собирают по режиму
        // окна, и в чужом режиме объявление записалось бы местом Писания.
        model.attach(state)
        state.mode = .text
        model.document = PlainTextDocument(title: textProbeTitle,
                                           body: "Налаштуйтеся на служіння.")

        checks.append(Check(area: area, name: "Модуль знає своє вікно",
                            status: model.isConnectedToHistory ? .ok : .failed,
                            detail: model.isConnectedToHistory
                                ? "показ іде і в зал, і в Історію (11)"
                                : "модуль ні до чого не підключено"))

        let shown = model.showIfReady()
        let top = desk.history.records.first
        let landed = shown && top?.kind == .text
            && top?.caption.hasPrefix(textProbeTitle) == true
        checks.append(Check(area: area, name: "Показаний текст в Історію (11)",
                            status: landed ? .ok : .failed,
                            detail: landed
                                ? "перший рядок списку: «\(top?.caption ?? "")»"
                                : (shown ? "зверху в Історії: «\(top?.caption ?? "список пуст")»"
                                         : "модулю не було чого показувати")))

        // Enter и F5 — это `AppState.showCurrent()`: в зал уходит то, что
        // стоит в предпросмотре. В режиме «Текст» там обязана быть страница
        // набора, а не библейский слайд.
        model.refreshPreview()
        let preview = state.slide.reference
        state.showCurrent()
        let enter = preview == textProbeTitle && state.liveSlide.reference == preview
        checks.append(Check(area: area, name: "Enter/F5 виводить сторінку тексту",
                            status: enter ? .ok : .failed,
                            detail: "у передпоказі «\(preview)», у залі «\(state.liveSlide.reference)»"))

        // Стрелки (13.1/13.2) в режиме «Текст» листают страницы набора. Здесь
        // же видно, дошла ли до `AppState` ветка `mode == .text`: без неё
        // стрелка переведёт стих, а страница останется первой.
        model.document = PlainTextDocument(
            title: textProbeTitle,
            body: (1...40).map { "Рядок номер \($0), достатньо довгий для перенесення." }
                .joined(separator: "\n"))
        let pages = model.pageCount
        let before = model.pageIndex
        state.stepVerse(by: 1, live: false)
        let turned = model.pageIndex == before + 1
        checks.append(Check(area: area, name: "Стрілки гортають сторінки тексту (13.1)",
                            status: pages < 2 ? .skipped : (turned ? .ok : .failed),
                            detail: pages < 2
                                ? "зразок ліг на одну сторінку — гортати нічого"
                                : (turned
                                    ? "сторінок \(pages), стрілка перевела на \(model.pageIndex + 1)-шу"
                                    : "сторінок \(pages), стрілка сторінку не перевела —"
                                      + " потрібна гілка mode == .text в AppState.stepVerse")))

        // След проверки в чужих данных. Смотрим само хранилище, а не память
        // модуля: владелец находил во вкладке «Текст» наш образец, потому что
        // отложенная запись уносила его в настройки прежде, чем текст успевал
        // вернуться на место.
        let stored = UserDefaults.standard.data(forKey: TextModuleModel.storageKey)
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let leaked = stored.contains(textProbeTitle) || stored.contains("Налаштуйтеся на служіння")
        checks.append(Check(area: area, name: "Перевірка не лишає свого тексту",
                            status: leaked ? .failed : .ok,
                            detail: leaked
                                ? "зразок перевірки ліг у налаштування — вкладка «Текст» відкриється з ним"
                                : "у налаштуваннях текст власника, зразок не зберігався"))
        return checks
    }

    // MARK: - Окно настроек (раздел 6)

    /// Проверки окна «Параметры»: применяются ли значения по «Ок», доходят ли
    /// они до работающих частей программы и совпадает ли состав вкладок с
    /// оригиналом. Каждая отвечает за свой пункт списка расхождений.
    private static func settingsWindow(_ state: AppState) -> [Check] {
        let area = "Вікно налаштувань"
        let store = SettingsStore.shared
        let settings = store.settings
        let options = settings.options
        var checks: [Check] = []

        // 6.1.5 (31) (32) (33) — фоны берутся из списка путей, а не из одной
        // зашитой папки.
        let root = state.modulesFolder.deletingLastPathComponent()
        let fromPaths = BackgroundLibrary.images(paths: settings.picturePaths, dataRoot: root)
        let listed = settings.picturePaths.map { $0.path + ($0.scansSubfolders ? " (+вкладені)" : "") }
        checks.append(Check(area: area, name: "Шляхи до фонових малюнків (31)",
                            status: state.backgroundImages.count == fromPaths.count ? .ok : .warning,
                            detail: "тек \(settings.picturePaths.count) "
                                + "[\(listed.joined(separator: ", "))], картинок \(fromPaths.count), "
                                + "у програмі \(state.backgroundImages.count)"))

        // 6.1.5 (34) — папка снимков экрана слайда (F11).
        //
        // Мало сверить настройку саму с собой: F11 пишет снимок в `AppState`,
        // и пока там стоит зашитая `ScreenShots`, поле вкладки ни на что не
        // влияет. Отличить одно от другого можно ровно в том случае, когда
        // настроена не зашитая папка, — тогда расхождение видно наверняка.
        let shots = state.screenshotFolder
        let expected = BackgroundLibrary.resolve(settings.screenshotFolder, dataRoot: root)
        let builtIn = root.appendingPathComponent("ScreenShots").standardizedFileURL
        let isDefaultFolder = expected.standardizedFileURL == builtIn
        checks.append(Check(area: area, name: "Тека знімків екрана (34)",
                            status: shots.standardizedFileURL != expected.standardizedFileURL ? .failed
                                : (isDefaultFolder ? .ok : .warning),
                            detail: "\(settings.screenshotFolder) → \(shots.path)"
                                + (isDefaultFolder
                                   ? " (збігається із зашитою ScreenShots — F11 потрапить туди в будь-якому разі)"
                                   : " (перевірте, що AppState.saveScreenshot бере screenshotFolder)")))

        // 6.1.1 (5) (7) (9) — куда ставится окно слайда.
        let wanted = SlideWindowPlacement(options: options)
        checks.append(Check(area: area, name: "Монітор слайда (5) (7) (9)",
                            status: state.projection.placement == wanted ? .ok : .warning,
                            detail: state.projection.placement.map { "застосовано: \($0.summary)" }
                                ?? "не застосовано, у налаштуваннях \(wanted.summary)"))

        // 6.1.1 (8) — переворот оси Y для «Показать позицию».
        let flipped = SettingsCoordinates.frame(left: 0, top: 0, width: 100, height: 100)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        checks.append(Check(area: area, name: "Вісь Y кнопок «Показати позицію» (8) (12.5)",
                            status: abs(flipped.origin.y - (mainHeight - 100)) < 0.5 ? .ok : .failed,
                            detail: "0,0 100×100 → кадр AppKit y=\(Int(flipped.origin.y)) "
                                + "при висоті головного монітора \(Int(mainHeight))"))

        // 6.1 — «Ок» и «Отмена». Проверяем на деле: правим значение, зовём
        // «Отмена» и смотрим, вернулось ли. Файл при этом не трогаем.
        let before = store.settings.options.percentFillingPage
        store.beginEditing()
        store.settings.options.percentFillingPage = before == 41 ? 42 : 41
        store.cancel()
        let restored = store.settings.options.percentFillingPage
        checks.append(Check(area: area, name: "«Скасувати» відкочує правки (BBCancel)",
                            status: restored == before ? .ok : .failed,
                            detail: restored == before
                                ? "знімок повертається цілком, вкладені вікна — своїми знімками"
                                : "значення лишилося \(restored) замість \(before)"))

        // 6.1 — значения доезжают до программы и переживают перезапуск.
        checks.append(Check(area: area, name: "Налаштування застосовуються при запуску",
                            status: SettingsBridge.isInstalled ? .ok : .failed,
                            detail: SettingsBridge.isInstalled
                                ? "слухач .slovoSettingsChanged стоїть, applySavedSettings() викликано"
                                : "applySavedSettings() не викликано — вставку в AppState.applyLoaded не зроблено"))

        // 6.1.6 — порядок функций в двух столбцах.
        let leftColumn = HotkeyAction.all.prefix(9).map(\.iniKey)
        let wantedColumn = ["ShowSlide", "HideSlide", "Search", "FastInput", "Plan",
                            "MainWin", "ScreenShot", "FastSearchWindow", "ShowBackGrOnSlide"]
        checks.append(Check(area: area, name: "Порядок гарячих клавіш (6.1.6)",
                            status: Array(leftColumn) == wantedColumn ? .ok : .failed,
                            detail: leftColumn.joined(separator: " → ")))

        // 6.1.8 — начальная страница строится по списку «Web слайды».
        let pages = state.outputs.web.pages.map(\.fileName)
        let listedSlides = settings.webSlides.map(\.fileName)
        checks.append(Check(area: area, name: "Список «Web слайди» (6.1.8)",
                            status: listedSlides.isEmpty || pages == listedSlides ? .ok : .warning,
                            detail: "у списку \(listedSlides.count), на початковій сторінці \(pages.count)"
                                + (pages.isEmpty ? "" : ": " + pages.joined(separator: ", "))))

        // 6.1.4 (26) — добавление модуля проверяет папку.
        let bogus = FileManager.default.temporaryDirectory
        checks.append(Check(area: area, name: "Перевірка теки модуля (26)",
                            status: SettingsStore.problem(with: bogus) == .notBibleQuote ? .ok : .failed,
                            detail: "тека без bibleqt.ini відхиляється повідомленням TextMessages6"))

        // 6.4 — в списке альтернативных названий нет основного.
        let chunk = settings.songChunks.first
        checks.append(Check(area: area, name: "Альтернативні назви частин пісень (6.4)",
                            status: .ok,
                            detail: chunk.map { "\($0.names.first ?? $0.key): "
                                + "альтернативних \(max(0, $0.names.count - 1))" } ?? "легенда порожня"))

        // 6.2 и 6.4 — пункты меню, а не кнопки окна «Параметры».
        checks.append(Check(area: area, name: "6.2 і 6.4 у меню «Налаштування»",
                            status: .ok,
                            detail: "\(state.text("NOpenSettingsFolder", form: "MainForm", default: "Открыть папку с настройками"))"
                                + " · \(state.text("NSongColorSet", form: "MainForm", default: "Цветовая легенда частей песен"))"))

        checks.append(contentsOf: settingsApplyRules(state))
        return checks
    }

    /// Продолжение проверок окна «Параметры»: что применяется только по «Ок»,
    /// что доезжает до работающих частей программы и чем подписаны вопросы.
    ///
    /// Вынесено отдельной функцией не ради порядка: проверки здесь трогают
    /// живое состояние — флажок NDI, монитор слайда, раскладку клавиш — и
    /// каждая обязана вернуть всё как было. Рядом друг с другом за этим легче
    /// уследить, чем когда они разбросаны среди чтения настроек.
    private static func settingsApplyRules(_ state: AppState) -> [Check] {
        let area = "Вікно налаштувань"
        let store = SettingsStore.shared
        let settings = store.settings
        let options = settings.options
        var checks: [Check] = []

        // 6.1 — выбор монитора (5) и «Включить трансляцию» NDI применяются
        // только по «Ок». Проверяем делом: правим значения в открытом окне и
        // смотрим, что живое состояние не шелохнулось. Ничего не включаем —
        // ставим значения, противоположные текущим, и тут же отменяем.
        let liveNDI = state.outputs[.ndi].isEnabled
        let livePlacement = state.projection.placement
        store.beginEditing()
        store.settings.options.ndiEnabled = !liveNDI
        store.settings.options.monitorIndex = options.monitorIndex == 0 ? 1 : 0
        let ndiUntouched = state.outputs[.ndi].isEnabled == liveNDI
        let screenUntouched = state.projection.placement == livePlacement
        store.cancel()
        checks.append(Check(area: area, name: "Монітор і NDI чекають на «Ок» (6.1, BBOk/BBCancel)",
                            status: ndiUntouched && screenUntouched ? .ok : .failed,
                            detail: ndiUntouched && screenUntouched
                                ? "правка списку моніторів і прапорця трансляції живого стану не міняє"
                                : "одразу змінилося: "
                                    + [ndiUntouched ? nil : "NDI", screenUntouched ? nil : "монітор"]
                                        .compactMap { $0 }.joined(separator: ", ")))

        // 6.1 и 6.4 — окна правки не мешают друг другу. «Ок» в «Цветовой
        // легенде» не должен снимать слой открытых рядом «Параметров», иначе
        // закрытие следом откатывало бы и их правки. На диск здесь ничего не
        // уходит: внешний слой остаётся на месте, а он и решает про запись.
        let baseline = store.settings.options.percentFillingPage
        let outer = store.beginEditing()
        store.settings.options.percentFillingPage = baseline == 41 ? 42 : 41
        let edited = store.settings.options.percentFillingPage
        let inner = store.beginEditing()
        store.save(inner)
        let afterInnerOk = store.settings.options.percentFillingPage
        store.cancel(outer)
        let afterOuterCancel = store.settings.options.percentFillingPage
        let layersOK = afterInnerOk == edited && afterOuterCancel == baseline
        checks.append(Check(area: area, name: "Два вікна правки не заважають одне одному (6.1 і 6.4)",
                            status: layersOK ? .ok : .failed,
                            detail: layersOK
                                ? "«Ок» у вкладеному вікні знімає лише свій шар, «Скасувати» зовнішнього повертає все"
                                : "було \(baseline), після вкладеного «Ок» \(afterInnerOk), "
                                    + "після зовнішнього «Скасувати» \(afterOuterCancel)"))

        // 6.1.1 (7) — «Размеры по умолчанию» участвуют в правиле размещения:
        // «если установленного монитора не окажется, окно слайда отобразится
        // на главном мониторе с размерами, указанными в этом поле».
        var missing = options
        missing.monitorIndex = 99
        let fallback = SlideWindowPlacement(options: missing)
        var sizeOK = false
        if case let .monitor(_, width, height) = fallback {
            sizeOK = width == max(1, options.defaultWidth) && height == max(1, options.defaultHeight)
        }
        checks.append(Check(area: area, name: "Розміри за умовчанням (7)",
                            status: sizeOK ? .ok : .failed,
                            detail: "монітора немає → \(fallback.summary)"))

        // 6.1.1 (9) — «Ручная настройка» это свои координаты, а не «любой
        // экран, кроме главного», как получалось, когда список писал
        // targetScreenID = nil прямо в момент щелчка.
        var manual = options
        manual.monitorIndex = 0
        let manualRule = SlideWindowPlacement(options: manual)
        var manualOK = false
        if case let .manual(left, top, width, height) = manualRule {
            manualOK = left == options.customLeft && top == options.customTop
                && width == max(1, options.customWidth) && height == max(1, options.customHeight)
        }
        checks.append(Check(area: area, name: "Ручне налаштування монітора (9)",
                            status: manualOK ? .ok : .failed,
                            detail: manualRule.summary))

        // 6.1.5 (33) — «Искать во вложенных папках» действительно меняет счёт.
        if let first = settings.picturePaths.first {
            let dataRoot = state.modulesFolder.deletingLastPathComponent()
            let folder = BackgroundLibrary.resolve(first.path, dataRoot: dataRoot)
            let flat = BackgroundLibrary.images(in: folder, deep: false).count
            let deep = BackgroundLibrary.images(in: folder, deep: true).count
            checks.append(Check(area: area, name: "Вкладені теки фонів (33)",
                                status: deep >= flat ? .ok : .failed,
                                detail: "\(first.path): у самій теці \(flat), із вкладеними \(deep); "
                                    + "у рядка позначено «\(first.scansSubfolders ? "так" : "ні")»"))
        }

        // 6.1.6 — раскладка из окна доходит до тех, кто ловит клавиши.
        let wantedKeys = settings.hotkeys
        let effective = EffectiveHotkeys.layout
        let sameAsSettings = HotkeyAction.all.allSatisfy { effective[$0.iniKey] == wantedKeys[$0.iniKey] }
        checks.append(Check(area: area, name: "Розкладка клавіш застосовується (6.1.6)",
                            status: sameAsSettings ? .ok : .warning,
                            detail: "набір «\(settings.hotkeySetName)», джерело: \(EffectiveHotkeys.source)"))

        // Та же раскладка, но со стороны перехватчиков: если они по-прежнему
        // читают `hotkeys.ini` оригинала сами, разойдётся именно здесь —
        // переназначенная в окне клавиша тогда не работает вовсе.
        let deskKey = DeskModel.shared.hotkeyReport().first { $0.action == "Search" }?.key ?? ""
        let deskWanted = effective["Search"]?.text ?? "не призначена"
        let playerKey = MediaHotkeys.shared.showPlayerHotkeyText ?? ""
        let playerWanted = effective["ShowMediaPlayer"]?.text ?? ""
        checks.append(Check(area: area, name: "Перехоплювачі беруть розкладку з вікна",
                            status: deskKey == deskWanted && playerKey == playerWanted ? .ok : .warning,
                            detail: "Пошук: у вікні \(deskWanted), у перехоплювача \(deskKey); "
                                + "Медіаплеєр: у вікні \(playerWanted), у перехоплювача \(playerKey)"))

        // 6.1.6 — «Ок» действительно доносит новую клавишу до перехватчиков.
        // Проверяем на живой раскладке: подменяем одну клавишу заведомо
        // свободным сочетанием, смотрим, видит ли её тот, кто ловит нажатия,
        // и возвращаем всё как было. Настройки при этом не трогаем — подмена
        // идёт мимо них, только в общую раскладку.
        let setName = settings.hotkeySetName.isEmpty
            ? (settings.hotkeySets.preferredSetName ?? "")
            : settings.hotkeySetName
        let keyBefore = EffectiveHotkeys.hotkey("ShowSlide")
        var probeSets = settings.hotkeySets
        var probe = wantedKeys
        probe["ShowSlide"] = Hotkey(control: true, alt: true, shift: true, key: "F19")
        probeSets.replace(setNamed: setName, with: probe)
        EffectiveHotkeys.adopt(sets: probeSets, setName: setName)
        let picked = EffectiveHotkeys.hotkey("ShowSlide")?.text ?? "не призначена"
        EffectiveHotkeys.adopt(sets: settings.hotkeySets, setName: setName)
        let keyAfter = EffectiveHotkeys.hotkey("ShowSlide")
        let adoptWorks = picked == "Ctrl+Alt+Shift+F19" && keyAfter == keyBefore
        checks.append(Check(area: area, name: "Нова клавіша доходить до перехоплювачів (6.1.6)",
                            status: adoptWorks ? .ok : .failed,
                            detail: adoptWorks
                                ? "підмінили «Показати слайд» на Ctrl+Alt+Shift+F19 і повернули "
                                    + (keyBefore?.text ?? "не призначена")
                                : "після підміни \(picked), після повернення "
                                    + (keyAfter?.text ?? "не призначена")))

        // 6.1.4 — порядок и включённость модулей доходят до полосы переводов.
        let wantedTabs = settings.modules.filter { $0.isEnabled && !$0.isSongBook }.map { $0.name.lowercased() }
        let shownTabs = state.orderedModules.map { $0.identifier.lowercased() }
        let tabsMatch = wantedTabs.isEmpty || wantedTabs == shownTabs
        checks.append(Check(area: area, name: "Список і порядок модулів (6.1.4)",
                            status: tabsMatch ? .ok : .warning,
                            detail: "у вікні \(wantedTabs.count), на смузі \(shownTabs.count)"
                                + (tabsMatch ? "" : " — смуга будується за файлом умовчань, а не за списком вікна")))

        // 6.4 — цвета частей песен доходят до списка «Текст» в песнях.
        let palette = state.songPalette
        let stock = SongChunkPalette.factoryDefault
        let isDefaultPalette = palette.chunks.map(\.key) == stock.chunks.map(\.key)
            && zip(palette.chunks, stock.chunks).allSatisfy { $0.color == $1.color }
        checks.append(Check(area: area, name: "Колірна легенда частин пісень (6.4) у головному вікні",
                            status: isDefaultPalette ? .ok : .warning,
                            detail: isDefaultPalette
                                ? "легенда збігається з поставковою — за кольорами одне від одного не відрізнити"
                                : "легенда своя (частин \(palette.chunks.count)): "
                                    + "частини списку «Текст» фарбує NativeSongRows за state.songPalette"))

        // 6.1.4 (29), 6.1.6 (38), 6.1.8 — кнопки согласия подписаны своими
        // словами, а не ключами «Есть»/«Нет» колонки «Индекс».
        let indexYes = state.vb("TextMessages7", "Есть")
        checks.append(Check(area: area, name: "Кнопки «Так»/«Ні» у запитаннях",
                            status: state.yesCaption != indexYes ? .ok : .failed,
                            detail: "згода «\(state.yesCaption)», відмова «\(state.noCaption)»; "
                                + "колонка «Індекс» — «\(indexYes)»"))

        // 6.1.4 (30) — модуль MySword больше не отклоняется: читатель формата
        // написан, и мастер настроек обязан принимать «…bbl.mybible» наравне
        // с MyBible. Раньше здесь проверялось обратное — что файл отвергнут
        // словами автора; проверку перевернули вместе с самой возможностью.
        let sample = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-selftest-\(UUID().uuidString).bbl.mybible")
        FileManager.default.createFile(atPath: sample.path, contents: Data())
        let mySwordProblem = SettingsStore.problem(with: sample)
        try? FileManager.default.removeItem(at: sample)
        checks.append(Check(area: area, name: "Модуль MySword (30)",
                            status: mySwordProblem == nil ? .ok : .failed,
                            detail: mySwordProblem == nil
                                ? "«…bbl.mybible» приймається — читач формату є"
                                : "файл MySword відхилено налаштуваннями: \(mySwordProblem!)"))

        // 6.1.2 (12.4) — панель координат активна для любого выделенного
        // монитора, а не только для ручной настройки.
        checks.append(Check(area: area, name: "Панель «Координати монітора» (12.4)",
                            status: .ok,
                            detail: "вмикається за виділенням рядка; у системного монітора значення "
                                + "показуються, але не правляться — їх задає система"))

        // 6.1.7 — частота кадров NDI. Список у оригинала строится в коде: ни в
        // его файлах, ни в справке его нет. Известна одна пара со снимка окна
        // владельца — NdiFpsId=13 показывается как 60, и с нашим списком это
        // не сходится. Пока таблица не сверена целиком, проверка обязана
        // говорить об этом, а не молчать.
        let index = options.ndiFrameRateIndex
        let ours = options.ndiFrameRate
        let fromOriginal = index == 13 ? 60 : nil
        checks.append(Check(area: area, name: "Частота кадрів NDI (6.1.7)",
                            status: fromOriginal == nil || fromOriginal == ours ? .ok : .warning,
                            detail: "NdiFpsId=\(index) → у нас \(ours) кадр/с"
                                + (fromOriginal.map { ", на знімку оригіналу \($0)" } ?? "")
                                + "; список: "
                                + OutputConfiguration.ndiFrameRateTitles.joined(separator: ", ")))

        // 6.1.3 (20) — запасная подпись CBNumPP это формулировка автора.
        checks.append(Check(area: area, name: "Підпис CBNumPP (20)",
                            status: .ok,
                            detail: "«\(state.vb("CBNumPP", "Номер по порядку"))»"))

        return checks
    }


    // MARK: - 5.1.16 Медиа-плеер (16)

    /// Проверки медиа-плеера. Ничего не открывают и не проигрывают: схемы
    /// ссылок гоняются на отдельном, ненастоящем проигрывателе, правило
    /// гашения экрана считается формулой, а живой плеер только опрашивается.
    private static func mediaSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Медіаплеєр"
        let media = state.media
        let hotkeys = MediaHotkeys.shared

        // Ctrl+M «Открыть Медиаплеер» и Ctrl+P «Медиаплеер Воспр./Пауза».
        let showKey = hotkeys.showPlayerHotkeyText ?? "—"
        let playKey = hotkeys.playPauseHotkeyText ?? "—"
        checks.append(Check(area: area, name: "Клавіші Ctrl+M і Ctrl+P",
                            status: hotkeys.isInstalled ? .ok : .failed,
                            detail: hotkeys.isInstalled
                                ? "перехоплювач стоїть: \(showKey) відкриває панель, \(playKey) — відтворення"
                                : "перехоплювач не стоїть — немає виклику MediaHotkeys.shared.install(state:)"
                                    + " (клавіші з hotkeys.ini: \(showKey), \(playKey))"))

        // Буквенные клавиши: раньше распознавались только F1…F20, и любая
        // ветка для Ctrl+M всё равно не сработала бы.
        let letters: [String: UInt16] = ["M": 46, "P": 35, "B": 11, "E": 14]
        let wrong = letters.filter { HotkeyKeyNames.name(for: $0.value) != $0.key }
        checks.append(Check(area: area, name: "Розбір літерних сполучень",
                            status: wrong.isEmpty ? .ok : .failed,
                            detail: wrong.isEmpty
                                ? "код клавіші → ім'я: 46→M, 35→P, 11→B, 14→E"
                                : "не розпізнано: \(wrong.keys.sorted().joined(separator: ", "))"))

        // Затемнение (13.3), «Скрыть» (13.2) и «пустой слайд» гасят видео.
        let cases: [(String, MediaPlayerModel.ScreenSuppression, Bool)] = [
            ("звичайна робота", [], true),
            ("затемнення (F12)", .blackout, false),
            ("слайд сховано (Esc)", .hiddenSlide, false),
            ("порожній слайд (Ctrl+F5)", .blankSlide, false),
        ]
        let broken = cases.filter {
            MediaPlayerModel.showsVideoOnScreen(videoToScreen: true, hasVideo: true,
                                                hasMedia: true, suppression: $0.1) != $0.2
        }
        checks.append(Check(area: area, name: "Затемнення гасить відео в залі",
                            status: broken.isEmpty ? .ok : .failed,
                            detail: broken.isEmpty
                                ? "перевірено 4 стани: відео лишається лише при показаному слайді"
                                : "не гасне: \(broken.map(\.0).joined(separator: ", "))"))

        // Что происходит с видео прямо сейчас — по этой строке видно, почему
        // на проекторе пусто при включённой кнопке (16.5).
        var why: [String] = []
        if !media.videoToScreen { why.append("кнопка (16.5) вимкнена") }
        if media.mediaURL == nil { why.append("файл не відкрито") }
        if media.mediaURL != nil, !media.hasVideo { why.append("у файлі немає відео") }
        if media.screenSuppression.contains(.hiddenSlide) { why.append("слайд сховано") }
        if media.screenSuppression.contains(.blackout) { why.append("затемнення") }
        if media.screenSuppression.contains(.blankSlide) { why.append("порожній слайд") }
        checks.append(Check(area: area, name: "Відео на проекторі зараз",
                            status: .ok,
                            detail: media.isVideoOnScreen ? "показується" : why.joined(separator: ", ")))

        // Сообщения о закрытии — TextMessages51 и TextMessages60. Раньше
        // ветка потока была недостижима: `isStream` сбрасывался раньше.
        let closingFile = MediaPlayerModel.Activity.closing(stream: false)
        let closingStream = MediaPlayerModel.Activity.closing(stream: true)
        checks.append(Check(area: area, name: "Повідомлення про закриття (TextMessages51/60)",
                            status: closingFile != closingStream ? .ok : .failed,
                            detail: "«\(state.text("TextMessages51", default: "Закрываем медиафайл..."))»"
                                + " / «\(state.text("TextMessages60", default: "Закрываем медиапоток..."))»"
                                + ", тримаються \(MediaPlayerModel.closingMessageDuration) с"))

        // Наборы фильтров диалога «Открытие медиафайлов» (16.1).
        let groups = MediaFileFilters.FilterGroup.allCases.map { group -> String in
            let caption = state.text(group.captionKey, default: group.fallbackCaption)
            let count = media.filters.extensions(in: group).count
            return "\(caption): \(count == 0 ? "все" : "\(count)")"
        }
        checks.append(Check(area: area, name: "Набори фільтрів (TextMessages54–57)",
                            status: groups.count == 4 ? .ok : .failed,
                            detail: groups.joined(separator: ", ")))

        // Схемы потоков: rtp/rtsp у AVFoundation нет, и об этом надо говорить
        // отдельно, а не общей «Ошибка при открытии медиа-файла».
        let probe = MediaPlayerModel(autoConfigure: false)
        let rtpRejected = !probe.openStream(text: "rtp://239.0.0.1:5004")
            && probe.failure == .unsupportedScheme("rtp")
        let rtspRejected = !probe.openStream(text: "rtsp://camera.local/stream")
            && probe.failure == .unsupportedScheme("rtsp")
        let junkRejected = !probe.openStream(text: "не посилання") && probe.failure == .badURL
        let httpAllowed = MediaPlayerModel.playableSchemes.contains("http")
            && MediaPlayerModel.playableSchemes.contains("https")
        let schemesOK = rtpRejected && rtspRejected && junkRejected && httpAllowed
        checks.append(Check(area: area, name: "Непідтриманий потік названо на ім'я",
                            status: schemesOK ? .ok : .failed,
                            detail: schemesOK
                                ? "rtp:// і rtsp:// відхиляються своїм повідомленням, http(s) і HLS грають"
                                : "rtp \(rtpRejected), rtsp \(rtspRejected), сміття \(junkRejected), http \(httpAllowed)"))

        // Настройки [mediaplayer] оригинала: подхвачены или нет.
        checks.append(Check(area: area, name: "Налаштування [mediaplayer]",
                            status: .ok,
                            detail: "гучність \(Int(media.volume * 100)) %"
                                + ", повтор \(media.repeats ? "увімк" : "вимк")"
                                + ", автозапуск \(media.autoPlay ? "увімк" : "вимк")"
                                + ", відео в зал \(media.videoToScreen ? "увімк" : "вимк")"
                                + ", розширень у списку \(media.filters.all.count)"
                                + ", виходів звуку \(media.audioDevices.count)"))

        // Откуда плеер их взял. Раньше `configure(dataRoot:config:)` не звали
        // ниоткуда, и здесь всегда стояли зашитые значения: списки расширений
        // из встроенной копии, а не из `settings.json` оператора.
        checks.append(Check(area: area, name: "Налаштування плеєра прочитано з диска",
                            status: media.settingsPath == nil ? .warning : .ok,
                            detail: media.settingsPath.map { "[mediaplayer] із \($0)" }
                                ?? "файл налаштувань не знайдено, діють значення за умовчанням"))
        checks.append(Check(area: area, name: "Списки розширень із settings.json",
                            status: media.filtersAreFromDisk ? .ok : .warning,
                            detail: media.filtersAreFromDisk
                                ? "відео \(media.filters.video.count), звук \(media.filters.audio.count)"
                                    + " із \(media.filters.sourceURL?.path ?? "")"
                                : "settings.json не знайдено — вбудована копія"
                                    + " (\(MediaFileFilters.builtIn.all.count) розширень)"))

        // Кадр поверх «Просмотра слайда» (12) — настройка CBShowVideoOnPreview.
        // Слой плеера кладёт сам предпросмотр окна (`NativeSlidePreview`),
        // и спрашиваем мы его же: прежняя накладка SwiftUI удалена вместе с
        // окном, которому принадлежала, и «отметился ли вид» больше не ответ.
        let preview = NativeBottom.row?.preview
        let playing = media.hasVideo && media.mediaURL != nil
        checks.append(Check(area: area, name: "Відео в передпоказі (12)",
                            status: preview == nil ? .skipped
                                : (!media.videoToPreview || !playing ? .ok
                                   : (preview?.isVideoMounted == true ? .ok : .failed)),
                            detail: preview == nil ? "нижній ряд вікна ще не піднято"
                                : !media.videoToPreview ? "налаштування вимкнено"
                                : !playing ? "налаштування ввімкнено, відеофайл не відкрито"
                                : (preview?.isVideoMounted == true
                                   ? "шар плеєра стоїть над передпоказом"
                                   : "відео відкрито, а шар плеєра не заведено")))

        // Видео в трансляцию (`NdiSendVideo`). Настройка была, дела за ней не
        // было: признак читался, ложился в правила вывода и не использовался
        // ни одной строкой. Проверяем и правило, и сам пересчёт кадра.
        checks.append(contentsOf: ndiVideo(state))

        checks.append(contentsOf: screenSuppressionWiring(state))
        return checks
    }

    /// Видео на канале трансляции: правило и пересчёт кадра.
    ///
    /// Кадр собираем сами, а не ждём открытого файла: у самопроверки нет ни
    /// видео под рукой, ни права его открыть, а ошибиться тут проще всего в
    /// шаге строки и в порядке байтов — это и проверяем на известной картинке.
    private static func ndiVideo(_ state: AppState) -> [Check] {
        let area = "Медіаплеєр"
        var checks: [Check] = []
        let network = state.outputs[.ndi]
        let media = state.media

        checks.append(Check(area: area, name: "Відео йде в трансляцію (NdiSendVideo)",
                            status: !network.isEnabled ? .skipped
                                : (!network.sendsVideo ? .ok
                                   : (media.isVideoOnScreen == media.sendsToNetwork ? .ok : .failed)),
                            detail: !network.isEnabled ? "трансляцію вимкнено"
                                : (!network.sendsVideo
                                   ? "налаштування вимкнено — на мікшер іде слайд"
                                   : "відео в залі \(media.isVideoOnScreen ? "так" : "ні"), "
                                       + "кадри в мережу \(media.sendsToNetwork ? "идут" : "не идут")")))

        // Пересчёт кадра: красный КВАДРАТ 640×640 в холст 1920×1080.
        //
        // Квадрат нарочно: у кадра 16:9 в холсте 16:9 полей не бывает вовсе, и
        // такая проба хвалила бы даже растяжение. Ждём: поля по бокам чёрные,
        // середина красная, размер холста.
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                           kCVPixelBufferCGImageCompatibilityKey: true]
        CVPixelBufferCreate(nil, 640, 640, kCVPixelFormatType_32BGRA,
                            attributes as CFDictionary, &buffer)
        guard let probe = buffer else {
            return checks + [Check(area: area, name: "Перерахунок кадру відео для трансляції",
                                   status: .failed, detail: "не вдалося зібрати пробний кадр")]
        }
        CVPixelBufferLockBaseAddress(probe, [])
        if let base = CVPixelBufferGetBaseAddress(probe) {
            let stride = CVPixelBufferGetBytesPerRow(probe)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<640 {
                for x in 0..<640 {
                    let at = y * stride + x * 4
                    bytes[at] = 0            // B
                    bytes[at + 1] = 0        // G
                    bytes[at + 2] = 255      // R
                    bytes[at + 3] = 255      // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(probe, [])

        let canvas = CGSize(width: 1920, height: 1080)
        guard let frame = NDIOutput.videoFrame(from: probe, canvas: canvas,
                                               opaque: true, identity: 1) else {
            return checks + [Check(area: area, name: "Перерахунок кадру відео для трансляції",
                                   status: .failed, detail: "кадр не перерахувався")]
        }
        let corner = frame.topLeftPixel
        let at = (frame.height / 2) * frame.bytesPerRow + (frame.width / 2) * 4
        let bytes = [UInt8](frame.pixels[at..<(at + 3)])
        let middleBlue = bytes[0], middleGreen = bytes[1], middleRed = bytes[2]

        let sized = frame.width == 1920 && frame.height == 1080
        let letterboxed = corner.r < 16 && corner.g < 16 && corner.b < 16
        let red = middleRed > 200 && middleGreen < 32 && middleBlue < 32
        let ok = sized && letterboxed && red
        let seen = "кадр \(frame.width)×\(frame.height); кут R\(corner.r) G\(corner.g) "
            + "B\(corner.b); середина R\(middleRed) G\(middleGreen) B\(middleBlue)"
        checks.append(Check(area: area, name: "Перерахунок кадру відео для трансляції",
                            status: ok ? .ok : .failed,
                            detail: ok
                                ? "640×640 вписано в 1920×1080: поля з боків чорні, "
                                    + "середина червона, порядок байтів BGRA збережено"
                                : seen))
        return checks
    }

    /// Гасят ли затемнение (13.3) и «пустой слайд» видео в зале.
    ///
    /// Признаки `.blackout` и `.blankSlide` ставит сам `AppState` — проверить
    /// это можно только на живом состоянии. Поэтому пробуем по-настоящему, но
    /// лишь при `--selftest`: если диагностику открыли из меню на служении,
    /// гасить оператору экран ради проверки нельзя.
    private static func screenSuppressionWiring(_ state: AppState) -> [Check] {
        let area = "Медіаплеєр"
        let name = "Затемнення й порожній слайд гасять відео"
        guard CommandLine.arguments.contains("--selftest") else {
            return [Check(area: area, name: name, status: .skipped,
                          detail: "перевіряється лише при запуску з --selftest:"
                              + " пробний прогін гасить екран у залі")]
        }

        let media = state.media
        let before = media.screenSuppression
        let verse = state.selectedVerseNumbers.first ?? 1
        let wasLive = state.isLive

        state.showBlackScreen()
        let blackoutWired = media.screenSuppression.contains(.blackout)
        state.showBlankSlide()
        let blankWired = media.screenSuppression.contains(.blankSlide)

        // Возврат: выбор стиха снимает затемнение внутри `AppState` — там это
        // единственный доступный снаружи способ, `resumeFromHiddenStates()`
        // закрыт.
        state.isLive = wasLive
        state.selectVerse(verse, mode: .replace)
        media.screenSuppression = before

        var missing: [String] = []
        if !blackoutWired { missing.append("затемнення (13.3)") }
        if !blankWired { missing.append("порожній слайд (Ctrl+F5)") }
        return [Check(area: area, name: name,
                      status: missing.isEmpty ? .ok : .failed,
                      detail: missing.isEmpty
                          ? "showBlackScreen() і showBlankSlide() ставлять ознаку — кадр у залі гасне"
                          : "не ставить ознаку: \(missing.joined(separator: ", "))"
                              + " — потрібні вставки в AppState.showBlackScreen/showBlankSlide/"
                              + "resumeFromHiddenStates")]
    }

    // MARK: - Автономність: програма не залежить від VisioBible

    /// Програма стартує на новому комп'ютері з тим, що привезла в пакеті, і
    /// нічого не читає з установленого VisioBible: ні його ini, ні модулів,
    /// ні бази нумерації. Майстер імпорту лишився ручним інструментом і
    /// переносить лише дані. Перевірки не копіюють і не пишуть нічого.
    private static func selfContainedSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Автономність"
        let foreign = ["VisioBible", "CrossOver", "drive_c"]
        func isOwn(_ path: String) -> Bool { !foreign.contains { path.contains($0) } }

        // Усі робочі шляхи — свої: пакет або особиста тека.
        var paths: [(String, String?)] = [
            ("файл налаштувань", IniSettings.locateConfig()?.path),
            ("hotkeys.ini", HotkeySets.locateFile()?.path),
            ("тека модулів", state.modulesFolder.path),
            ("база нумерації", VerseNumbering.locateDatabase()?.path),
            ("налаштування плеєра", state.media.settingsPath),
            ("розбивка «Тексту»", TextModuleModel.shared.configPath),
        ]
        paths = paths.filter { $0.1 != nil }
        let strayPaths = paths.filter { !isOwn($0.1 ?? "") }
        checks.append(Check(area: area, name: "Робочі шляхи не ведуть у VisioBible",
                            status: strayPaths.isEmpty ? .ok : .failed,
                            detail: strayPaths.isEmpty
                                ? paths.map { "\($0.0): \($0.1 ?? "")" }.joined(separator: "; ")
                                : strayPaths.map { "\($0.0): \($0.1 ?? "")" }.joined(separator: "; ")))

        // Кандидати на файл налаштувань — теж тільки свої, і поставковий є.
        let candidates = IniSettings.configCandidates.map(\.path)
        let shipped = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/app/\(IniSettings.configFileName)").path
        let shippedExists = FileManager.default.fileExists(atPath: shipped)
        checks.append(Check(area: area, name: "Поставковий Slovo.ini у пакеті",
                            status: shippedExists ? .ok : .failed,
                            detail: shippedExists
                                ? "\(shipped); кандидати: " + candidates.joined(separator: ", ")
                                : "немає \(shipped) — на новому комп'ютері програма стартувала б без умовчань"))
        checks.append(Check(area: area, name: "Кандидати шляху налаштувань — свої",
                            status: candidates.allSatisfy(isOwn) ? .ok : .failed,
                            detail: candidates.joined(separator: ", ")))

        // Мова за умовчанням — українська: без вікна вибору при першому запуску.
        let defaultsLanguage = Defaults.languageCode
        let current = state.language?.code ?? OurWords.language
        checks.append(Check(area: area, name: "Мова за умовчанням — українська",
                            status: (defaultsLanguage != nil || current == "uk") ? .ok : .failed,
                            detail: defaultsLanguage.map { "людина обрала «\($0)», зараз «\(current)»" }
                                ?? "вибору не було, зараз «\(current)»"))

        // Майстер імпорту переносить лише дані: сторінки налаштувань немає.
        let pages = ImportWizardModel.Page.allCases.map { "\($0)" }
        checks.append(Check(area: area, name: "Майстер імпорту без сторінки налаштувань",
                            status: pages.contains("settings") ? .failed : .ok,
                            detail: "сторінки: " + pages.joined(separator: ", ")
                                + "; категорії: " + ImportItem.Category.allCases.map(\.rawValue).joined(separator: ", ")))

        // 4.2.1: тексти відмов — словами автора, а не своїми.
        let sample = "/Volumes/Архів/VisioBible"
        let problem = ImportProblem.nothingToImport(sample)
        let localized = problem.localized(state.language)
        let fromAuthor = localized != problem.description && localized.contains(sample)
        checks.append(Check(area: area, name: "Тексти помилок майстра з перекладу",
                            status: state.language == nil ? .skipped : (fromAuthor ? .ok : .failed),
                            detail: state.language == nil ? "файл перекладу не завантажено" : "«\(localized)»"))

        // 4.2.4: на сторінці фонів автоматично позначаються лише відсутні,
        // а на 4.2.2/4.2.3 — ще й застарілі.
        func autoSelected(_ category: ImportItem.Category, _ condition: ImportItem.Condition) -> Bool {
            ImportItem(id: "x", category: category, title: "x", subtitle: "",
                       sourceURL: URL(fileURLWithPath: "/"), destinationURL: URL(fileURLWithPath: "/"),
                       condition: condition).isSelected
        }
        let selectionOK = !autoSelected(.image, .outdated) && autoSelected(.image, .missing)
            && autoSelected(.module, .outdated) && !autoSelected(.template, .upToDate)
        checks.append(Check(area: area, name: "Автопозначка на сторінці фонів (4.2.4)",
                            status: selectionOK ? .ok : .failed,
                            detail: selectionOK
                                ? "фон «Застар.» не позначається, «Немає» позначається; модуль «Застар.» позначається"
                                : "правило відбору не те: зображення «Застар.» позначено "
                                    + "\(autoSelected(.image, .outdated))"))
        return checks
    }

    // MARK: - Отчёт

    static func report(_ checks: [Check]) -> String {
        var lines: [String] = ["Діагностика «Слово» — \(Date())", ""]
        var area = ""
        for check in checks {
            if check.area != area {
                area = check.area
                lines.append("[\(area)]")
            }
            let mark: String
            switch check.status {
            case .ok:      mark = "  ок     "
            case .warning: mark = "  увага   "
            case .failed:  mark = "  ПОМИЛКА"
            case .skipped: mark = "  —      "
            }
            lines.append("\(mark) \(check.name): \(check.detail)")
        }
        let failed = checks.filter { $0.status == .failed }.count
        lines.append("")
        lines.append(failed == 0 ? "Помилок немає." : "Помилок: \(failed).")
        return lines.joined(separator: "\n")
    }

    /// Путь, куда пишется отчёт при запуске с `--selftest`. Переменная, а не
    /// константа: прогон отдельных разделов (`--check=`) пишет в свой файл,
    /// чтобы не затирать отчёт полной проверки.
    static var reportURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/slovo-selftest.txt")

    // MARK: - Отдельные разделы

    /// Разделы, которые можно прогнать поодиночке: `--check=тур,показ`.
    ///
    /// Полная самопроверка идёт пять минут, а при разборе одной поломки нужен
    /// один её раздел — и сразу. Имена короткие и русские, как в отчёте.
    static let namedSections: [(name: String, run: @MainActor (AppState) -> [Check])] = [
        ("тур", { tourSection(state: $0) }),
        ("підказки", { hintsSection(state: $0) }),
        ("дозволи", { permissionsSection(state: $0) }),
        ("показ", { showTabsSection(state: $0) + projectorScreenNoticeSection(state: $0) }),
        ("мова", { languageSection(state: $0) + russianLeftoversSection(state: $0)
                    + unlabeledButtonsSection(state: $0) }),
        ("параметри", { settingsTabsSection(state: $0) }),
        ("медіа", { mediaFlowSection(state: $0) + mediaComplaintsSection(state: $0) }),
        ("пісні", { nativeSongsSection(state: $0) }),
        ("список", { nativeSection(state: $0) }),
        ("біблія", { nativeBibleSection(state: $0) }),
        ("дім", { dataHomeSection(state: $0) }),
        ("ресурси", { resourcesSection(state: $0) }),
        ("ресурси-мережа", { resourcesNetworkSection(state: $0) }),
        ("пошук", { search($0) + deskSection($0) }),
        ("вкладки", { showSection(state: $0) }),
        ("низ", { nativeBottomSection(state: $0) }),
        ("модулі", { modulesRosterSection(state: $0) }),
        ("модулі-вікно", { modulesWindowSection(state: $0) }),
        ("налаштування-служба", { settingsServiceSection(state: $0) }),
        ("вигляд-списків", { listStylesSection(state: $0) }),
        ("введення", { typingSection(state: $0) }),
        ("журнал", { journalSection(state: $0) }),
        ("презентація-знімки", { slideShotsSection(state: $0) }),
        ("курсор-дослід", { caretExperimentSection(state: $0) }),
        ("повзунки", { webKnobSection(state: $0) }),
        ("веб-слайди", { webSlidesSection(state: $0) }),
        ("проектор-тип", { projectorTypeSwitchSection(state: $0) }),
        ("кольори-конструктора", { constructorColoursSection(state: $0) }),
        ("пам'ять", { sessionSection(state: $0) }),
        ("веб-панель", { webEditorPanelSection(state: $0) }),
        ("ndi-розміри", { ndiSizesSection(state: $0) }),
        ("дзеркало", { mirrorSection(state: $0) }),
        ("фокус", { focusSection(state: $0) }),
        ("екран", { screenSection(state: $0) }),
        ("сумісність", { compatSection(state: $0) }),
        ("автономність", { selfContainedSection($0) + library($0) + importWindowSection(state: $0) }),
        ("переклади", { translationsSection(state: $0) }),
        ("фонограма", { backingTrackSection(state: $0) }),
        ("передпоказ", { previewTextSection(state: $0) }),
        ("пошук-пісні", { songSearchSection(state: $0) }),
        ("швидкість", { speedSection(state: $0) }),
        ("профіль", { profileSection(state: $0) }),
        ("пульт", { remoteSection(state: $0) }),
        ("пульт-біблія", { remoteBibleSection(state: $0) }),
        ("планшет", { tabletSection(state: $0) }),
    ]

    static func runNamed(_ names: [String], state: AppState) -> [Check] {
        SessionMemory.protect { DeskModel.shared.keepingJournals { runNamedUnprotected(names, state: state) } }
    }

    private static func runNamedUnprotected(_ names: [String], state: AppState) -> [Check] {
        let run = Run()
        for name in names {
            if name == "усе" || name == "все" { run.add(runAll(state: state)); continue }
            guard let section = namedSections.first(where: { $0.name == name }) else {
                run.add(single: Check(area: "Перевірка", name: "Розділ «\(name)»", status: .failed,
                                      detail: "немає такого розділу; є: "
                                          + namedSections.map(\.name).joined(separator: ", ")))
                continue
            }
            run.add(section.run(state))
        }
        return run.checks
    }
}

// MARK: - Конструктор слайда (6.3)

extension Diagnostics {

    /// Однотонный кадр для проверок перехода.
    static func solidImage(red: Int) -> CGImage? {
        let width = 8, height = 8, bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 255, count: bytesPerRow * height)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            pixels[index] = 0                       // синий
            pixels[index + 1] = 0                   // зелёный
            pixels[index + 2] = UInt8(red)          // красный
            pixels[index + 3] = 255
        }
        let data = Data(pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }


    /// Проверки раздела «Конструктор слайда».
    ///
    /// Всё, что здесь сделано, проверяется на настоящих шаблонах пользователя
    /// из папки `Templates`: видимость по сценам, полный набор видов объекта,
    /// раскрытие нулевой ширины, привязка по вертикали и выключатель контура.
    /// Ничего пользовательского на запись не трогаем — преднастройки для
    /// проверки заводятся во временной папке.
    static func constructorSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        checks.append(entryPoint(state))
        checks.append(contentsOf: sceneVisibility(state))
        checks.append(personalizationScenes(state))
        checks.append(objectKinds())
        checks.append(contentsOf: autoWidth(state))
        checks.append(handleZones(state))
        checks.append(verticalAnchors(state))
        checks.append(outlineSwitch())
        checks.append(contentsOf: constructorFolders(state))
        checks.append(saveQuestion())
        checks.append(buttonOrder())
        checks.append(springFadeList(state))
        checks.append(constructorCaptions(state))
        return checks
    }

    /// Ищет пункт меню по подписи, а не по русским словам.
    ///
    /// Раньше проверки узнавали пункт по строке вроде «конструктор слайда»,
    /// и на любом другом языке интерфейса выдавали красную строку на вполне
    /// исправном месте. Подпись берём оттуда же, откуда её берёт само меню.
    /// Наполнены ли подменю.
    ///
    /// SwiftUI заводит их содержимое лениво — пока меню ни разу не открывали,
    /// у разделов пусто. Под `--selftest` меню никто не открывает, и проверки
    /// «пункт на месте» превращались в гадание: то ок, то ошибка на ровном
    /// месте. Лучше честно сказать «проверить нечего».
    static var mainMenuIsBuilt: Bool {
        guard let menu = NSApp.mainMenu else { return false }
        return menu.items.contains { ($0.submenu?.items.count ?? 0) > 0 }
    }

    static func menuItem(startingWith caption: String) -> String? {
        let needle = caption.lowercased().prefix(12)
        guard !needle.isEmpty else { return nil }

        func search(_ menu: NSMenu?) -> String? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.title.lowercased().hasPrefix(needle) { return item.title }
                if let found = search(item.submenu) { return found }
            }
            return nil
        }
        return search(NSApp.mainMenu)
    }

    /// Есть ли откуда открыть окно (6.3): у автора это пункт меню «Настройка».
    private static func entryPoint(_ state: AppState) -> Check {
        // При `--selftest` главное меню может ещё не собраться — не поломка.
        guard NSApp.mainMenu != nil else {
            return Check(area: "Конструктор", name: "Як відкрити",
                         status: .skipped, detail: "головне меню ще не зібрано")
        }
        let found = menuItem(startingWith: state.text("N42", default: "Конструктор слайда"))
        return Check(area: "Конструктор", name: "Як відкрити",
                     status: found != nil ? .ok : (mainMenuIsBuilt ? .failed : .skipped),
                     detail: found.map { "меню «Налаштування» → «\($0)»" }
                         ?? "пункту меню немає — вікно недосяжне")
    }

    /// `Enabled` и `Enabled_2` — самостоятельные атрибуты (6.3.4, 6.3.7).
    ///
    /// Сверяем «взять за основу» с самим `.sch`: в «Beautiful Gold» и родне
    /// линия `DownLine` записана скрытой в сцене 1 и видимой в сцене 2 при
    /// `EnableParamsVariant="false"` — раньше она пропадала в обеих.
    private static func sceneVisibility(_ state: AppState) -> [Check] {
        guard let schemes = state.schemes, !schemes.templates.isEmpty else {
            return [Check(area: "Конструктор", name: "Видимість за сценами",
                          status: .skipped, detail: "теку Templates не прочитано")]
        }

        var compared = 0
        var differing = 0
        var mismatches: [String] = []
        var falseIndependent: [String] = []

        for template in schemes.templates {
            let preset = SlidePreset(template: template, base: state.style,
                                     designHeight: schemes.designHeight)
            guard preset.objects.count == template.scheme.elements.count else {
                mismatches.append("\(template.name): об'єктів \(preset.objects.count) замість \(template.scheme.elements.count)")
                continue
            }
            for (object, element) in zip(preset.objects, template.scheme.elements) {
                compared += 1
                let first = element.placement(.single).isEnabled
                let second = element.placement(.dual).isEnabled
                if first != second { differing += 1 }
                if object.isVisible != first || object.secondSceneIsVisible != second {
                    mismatches.append("\(template.name)/\(element.name)")
                }
                // Своя разметка сцены 2 — только там, где EnableParamsVariant.
                if object.secondSceneDiffersBeyondVisibility != element.hasVariantParameters {
                    falseIndependent.append("\(template.name)/\(element.name)")
                }
            }
        }

        var checks: [Check] = [
            Check(area: "Конструктор", name: "Видимість за сценами",
                  status: mismatches.isEmpty ? .ok : .failed,
                  detail: mismatches.isEmpty
                      ? "звірено об'єктів \(compared), з них із різною видимістю \(differing) — усі перенесено"
                      : "розійшлися: " + mismatches.prefix(6).joined(separator: ", ")),
        ]
        checks.append(Check(area: "Конструктор", name: "Колонка «Сцена 2»",
                            status: falseIndependent.isEmpty ? .ok : .warning,
                            detail: falseIndependent.isEmpty
                                ? "своя розмітка рівно в тих, де EnableParamsVariant=\"true\""
                                : "зайві: " + falseIndependent.prefix(6).joined(separator: ", ")))
        return checks
    }

    /// Все четырнадцать видов объекта читаются обратно из `.sch` (6.3.4).
    private static func objectKinds() -> Check {
        var seen: [SlideObjectKind] = []
        var unknown: [Int] = []
        for raw in 0...13 {
            guard SlideScheme.ElementKind(rawValue: raw) != nil else {
                unknown.append(raw)
                continue
            }
            let element = SlideScheme.Element(name: "проба", rawType: raw)
            seen.append(SlidePreset.kind(of: element))
        }
        let distinct = Set(seen).count
        let ok = unknown.isEmpty && distinct == 14
        return Check(area: "Конструктор", name: "Види об'єктів",
                     status: ok ? .ok : .failed,
                     detail: ok
                         ? "Type 0…13 читаються в 14 різних видів"
                         : "не розібрано номери \(unknown), різних видів \(distinct) із 14")
    }

    /// Ширина «0» в шаблоне значит «по содержимому» (6.3.6).
    private static func autoWidth(_ state: AppState) -> [Check] {
        guard let schemes = state.schemes, !schemes.templates.isEmpty else {
            return [Check(area: "Конструктор", name: "Ширина за вмістом",
                          status: .skipped, detail: "теку Templates не прочитано")]
        }

        let canvas = CGSize(width: 960, height: 540)
        let sample = ConstructorSample()
        var zeroSided = 0
        var collapsed: [String] = []

        for template in schemes.templates {
            let preset = SlidePreset(template: template, base: state.style,
                                     designHeight: schemes.designHeight)
            for object in preset.objects {
                for scene in [SlideScheme.Variant.single, .dual] {
                    let values = object.values(in: scene)
                    guard values.frame.width <= 0 || values.frame.height <= 0 else { continue }
                    zeroSided += 1
                    let auto = ConstructorAutoSize.size(of: object, values: values, sample: sample,
                                                        canvas: canvas, imageURL: { path in
                        path.map { URL(fileURLWithPath: $0) }
                    })
                    let rect = values.frame.resolved(auto: auto, in: canvas).rect(in: canvas)
                    // Три активные зоны по горизонтали не должны сходиться
                    // в одну точку — иначе объект нечем взять мышью.
                    if rect.width < 8 || rect.height < 8 {
                        collapsed.append("\(template.name)/\(object.name)")
                    }
                }
            }
        }

        return [Check(area: "Конструктор", name: "Ширина за вмістом",
                      status: collapsed.isEmpty ? .ok : .failed,
                      detail: collapsed.isEmpty
                          ? "нульових сторін \(zeroSided), усі розкрилися за вмістом"
                          : "схлопнулися: " + collapsed.prefix(6).joined(separator: ", "))]
    }

    /// «Привязка по Y» — только «Верх» и «Низ» (6.3.7).
    private static func verticalAnchors(_ state: AppState) -> Check {
        let before = SlidePreset.standard(name: "проба", style: state.style)
        let after = SlideConstructorModel.withOriginalAnchors(before)
        let canvas = CGSize(width: 1920, height: 1080)

        var middles = 0
        var moved: [String] = []
        for (old, new) in zip(before.objects, after.objects) {
            if new.frame.anchorY == .middle { middles += 1 }
            let a = old.frame.rect(in: canvas)
            let b = new.frame.rect(in: canvas)
            if abs(a.minY - b.minY) > 0.5 || abs(a.height - b.height) > 0.5 {
                moved.append(new.name)
            }
        }

        let ok = middles == 0 && moved.isEmpty
        return Check(area: "Конструктор", name: "Прив'язка по Y",
                     status: ok ? .ok : .failed,
                     detail: ok
                         ? "«середини» не лишилося, об'єкти стоять на попередніх місцях"
                         : "із «серединою» \(middles), зсунулися: \(moved.joined(separator: ", "))")
    }

    /// «Толщина контура» и «Контур» — два разных значения (6.3.7).
    private static func outlineSwitch() -> Check {
        var layer = SlideStyle.TextLayer(outlineWidth: 0.0225)
        layer.isOutlined = false
        let hiddenWidth = layer.outlineWidth
        let keptThickness = layer.outlineThickness
        layer.isOutlined = true
        let restored = layer.outlineWidth

        // Круговой прогон через JSON: подобранная толщина обязана пережить
        // и сохранение шаблона.
        var afterFile = layer
        afterFile.isOutlined = false
        let data = try? JSONEncoder().encode(afterFile)
        let decoded = data.flatMap { try? JSONDecoder().decode(SlideStyle.TextLayer.self, from: $0) }

        let ok = hiddenWidth == 0
            && abs(keptThickness - 0.0225) < 1e-9
            && abs(restored - 0.0225) < 1e-9
            && decoded?.isOutlined == false
            && abs((decoded?.outlineThickness ?? 0) - 0.0225) < 1e-9

        return Check(area: "Конструктор", name: "Вимикач контуру",
                     status: ok ? .ok : .failed,
                     detail: ok
                         ? "знята галочка дає нульову товщину при малюванні і зберігає 2,25 %"
                         : "товщина губиться: схована \(hiddenWidth), збережена \(keptThickness), повернута \(restored)")
    }

    /// Список фонов и предустановленных картинок объекта (6.3.5, 6.3.7).
    private static func constructorFolders(_ state: AppState) -> [Check] {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-selftest-presets-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let model = SlideConstructorModel(library: PresetLibrary(folder: temp))
        model.attach(schemes: state.schemes, baseStyle: state.style)
        if let template = state.schemes?.templates.first { model.importScheme(template) }

        let folders = model.backgroundFolders
        let images = folders.reduce(0) { $0 + model.images(in: $1).count }
        let objectImages = model.objectImageFolders.reduce(0) { $0 + model.images(in: $1).count }
        let configured = SettingsStore.shared.settings.picturePaths.map(\.path)

        var checks: [Check] = [
            Check(area: "Конструктор", name: "Теки фонів",
                  status: folders.isEmpty ? .failed : .ok,
                  detail: "тек \(folders.count), зображень \(images); "
                      + "у налаштуваннях прописано: \(configured.isEmpty ? "ничего" : configured.joined(separator: ", "))"),
            // 6.3.7: у графического объекта должны быть «предустановленные»
            // файлы изображения и маски, а не одна лишь кнопка обзора.
            Check(area: "Конструктор", name: "Готові картинки об'єкта",
                  status: objectImages > 0 ? .ok : .warning,
                  detail: objectImages > 0
                      ? "у списках «Ім'я файлу зображення» та «Ім'я файлу маски» по \(objectImages) файлів із \(model.objectImageFolders.count) тек"
                      : "готових картинок не знайшлося — лишиться тільки кнопка огляду"),
        ]

        // «Шаблон изменен. Сохранить?» задаётся по признаку незаписанных
        // правок — в том числе перед созданием нового шаблона.
        model.add(.staticText)
        checks.append(Check(area: "Конструктор", name: "Незаписані правки",
                            status: model.isDirty ? .ok : .failed,
                            detail: model.isDirty
                                ? "правку позначено — «Шаблон змінено. Зберегти?» буде поставлено"
                                : "правку не позначено, запитання не з'явиться"))

        // Папка авторского шаблона должна пережить «Сохранить как».
        let folderBefore = model.sourceFolder
        model.saveAs("Проба самоперевірки")
        let kept = model.sourceFolder != nil && model.sourceFolder == folderBefore
        checks.append(Check(area: "Конструктор", name: "Тека шаблону",
                            status: folderBefore == nil ? .skipped : (kept ? .ok : .failed),
                            detail: folderBefore == nil
                                ? "шаблони не прочитано"
                                : (kept ? "переживає «Зберегти з новим ім'ям»"
                                        : "губиться при збереженні — картинки об'єктів пропадуть")))
        return checks
    }

    /// «Видимость» (Label46) не включает «Разрешить сцену 2» (6.3.4, 6.3.7).
    ///
    /// `Enabled`, `Enabled_2` и `EnableParamsVariant` у автора самостоятельны:
    /// объект, видимый только при двух переводах, живёт с общей разметкой.
    /// Раньше выбор «Во 2 сцене» насильно заводил объекту свой набор, и в
    /// колонке «Сцена 2» появлялось «Да» там, где у автора «Нет».
    private static func personalizationScenes(_ state: AppState) -> Check {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-selftest-scenes-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let model = SlideConstructorModel(library: PresetLibrary(folder: temp))
        model.attach(schemes: state.schemes, baseStyle: state.style)
        model.add(.staticText)
        guard let id = model.selection else {
            return Check(area: "Конструктор", name: "Видимість і «Дозволити сцену 2»",
                         status: .failed, detail: "об'єкт не створився")
        }
        func object() -> SlideObject? { model.preset.objects.first { $0.id == id } }

        var faults: [String] = []

        // «Во 2 сцене»: видно только при двух переводах, разметка общая.
        model.personalization.set(.secondOnly)
        if let object = object() {
            if object.isVisible { faults.append("«У 2 сцені» лишила показ у сцені 1") }
            if !object.secondSceneIsVisible { faults.append("«У 2 сцені» не ввімкнула показ у сцені 2") }
            if model.hasIndependentSecondScene(object) {
                faults.append("«У 2 сцені» силоміць увімкнула «Дозволити сцену 2»")
            }
        }

        // «Во всех сценах» возвращает объект к одному набору без двойника.
        model.personalization.set(.allScenes)
        if let object = object() {
            if !object.isVisible || !object.secondSceneIsVisible {
                faults.append("«В усіх сценах» не повернула показ")
            }
            if object.secondVariant != nil {
                faults.append("двійник лишився, хоча видимість сцен зрівнялася")
            }
        }

        // А вот руками включённый флажок обязан держаться сам по себе.
        model.secondSceneEnabled.set(true)
        let forced = object().map { model.hasIndependentSecondScene($0) } ?? false
        if !forced { faults.append("«Дозволити сцену 2» руками не вмикається") }

        return Check(area: "Конструктор", name: "Видимість і «Дозволити сцену 2»",
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "Enabled, Enabled_2 і EnableParamsVariant не заважають одне одному"
                         : faults.joined(separator: "; "))
    }

    /// Активные зоны рамки у объекта нулевой ширины (6.3.6).
    ///
    /// Мало раскрыть ширину «по содержимому» — указатели страниц всё равно
    /// узкие. Считаем именно те точки, куда лягут маркеры, и смотрим, что
    /// левый, средний и правый не наезжают друг на друга: иначе размер и
    /// положение таким объектам мышью не поменять.
    private static func handleZones(_ state: AppState) -> Check {
        guard let schemes = state.schemes, !schemes.templates.isEmpty else {
            return Check(area: "Конструктор", name: "Активні зони рамки",
                         status: .skipped, detail: "теку Templates не прочитано")
        }

        let canvas = CGSize(width: 960, height: 540)
        let sample = ConstructorSample()
        var narrow = 0
        var tight: [String] = []
        var thinnest = CGFloat.greatestFiniteMagnitude

        for template in schemes.templates {
            let preset = SlidePreset(template: template, base: state.style,
                                     designHeight: schemes.designHeight)
            for object in preset.objects {
                for scene in [SlideScheme.Variant.single, .dual] {
                    let values = object.values(in: scene)
                    guard values.frame.width <= 0 || values.frame.height <= 0 else { continue }
                    narrow += 1
                    let auto = ConstructorAutoSize.size(of: object, values: values, sample: sample,
                                                        canvas: canvas, imageURL: { path in
                        path.map { URL(fileURLWithPath: $0) }
                    })
                    let rect = values.frame.resolved(auto: auto, in: canvas).rect(in: canvas)
                    thinnest = min(thinnest, rect.width)

                    let zones = ConstructorHandles.zones(around: rect)
                    // Расстояние между соседними маркерами по горизонтали и
                    // по вертикали — половина раздутой рамки.
                    let gapX = zones.width / 2
                    let gapY = zones.height / 2
                    if gapX < ConstructorHandles.size || gapY < ConstructorHandles.size {
                        tight.append("\(template.name)/\(object.name)")
                    }
                }
            }
        }

        let measured = narrow == 0 ? 0 : thinnest
        return Check(area: "Конструктор", name: "Активні зони рамки",
                     status: tight.isEmpty ? .ok : .failed,
                     detail: tight.isEmpty
                         ? "нульових сторін \(narrow), найвужча рамка \(String(format: "%.1f", measured)) тчк — "
                           + "маркери рознесено на \(Int(ConstructorHandles.minimumSpan / 2)) тчк при стороні \(Int(ConstructorHandles.size))"
                         : "маркери сходяться: " + tight.prefix(6).joined(separator: ", "))
    }

    /// «Шаблон изменен. Сохранить?» — один вопрос на все четыре ухода (6.3.1).
    ///
    /// Раньше создание нового шаблона обходило вопрос стороной и незаписанные
    /// правки пропадали молча.
    private static func saveQuestion() -> Check {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-selftest-ask-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let model = SlideConstructorModel(library: PresetLibrary(folder: temp))
        model.add(.staticText)          // появились незаписанные правки

        let asking = SlideConstructorModel.Departure.allCases
            .filter { model.asksToSave(before: $0) }
        model.save()
        let stillAsking = SlideConstructorModel.Departure.allCases
            .filter { model.asksToSave(before: $0) }

        let ok = asking.count == SlideConstructorModel.Departure.allCases.count
            && stillAsking.isEmpty
        return Check(area: "Конструктор", name: "«Шаблон змінено. Зберегти?»",
                     status: ok ? .ok : .failed,
                     detail: ok
                         ? "питається перед усіма чотирма виходами: зміна шаблону, «взяти за основу», створення, закриття"
                         : "питають \(asking.count) із 4 виходів, після збереження — ще \(stillAsking.count)")
    }

    /// Порядок кнопок в окне (6.3.1, 6.3.4).
    ///
    /// Кнопки рисуются перебором этих же списков, так что проверка сверяет
    /// именно то, что человек увидит в окне.
    private static func buttonOrder() -> Check {
        let objects = ObjectListButton.allCases.map(\.rawValue)
        let before = TemplateButton.beforeList.map(\.rawValue)
        let after = TemplateButton.afterList.map(\.rawValue)

        var faults: [String] = []
        // Руководство 6.3.4: «добавлять, удалять, копировать и менять позицию».
        if objects != ["SBObjAdd", "SBObjDel", "SBObjCopy", "SBObjUp", "SBObjDown"] {
            faults.append("список об'єктів: " + objects.joined(separator: " → "))
        }
        // Снимок окна: кнопка создания слева от подписи «Шаблон:», остальные
        // три — справа от выпадающего списка.
        if before != ["SBNewSheme"] || after != ["SBSaveSheme", "SBAddSheme", "SBDelSheme"] {
            faults.append("шаблон: " + (before + ["«Шаблон:»"] + after).joined(separator: " → "))
        }

        return Check(area: "Конструктор", name: "Порядок кнопок",
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "додати → видалити → копіювати → вгору → вниз; створити | «Шаблон:» список | зберегти → як → видалити"
                         : faults.joined(separator: "; "))
    }

    /// Список «Объекты слайда» для SpringFade — построчно, как на снимке.
    ///
    /// `Docs/Окно-настроек.md` хранит таблицу, снятую с работающей программы:
    /// десять строк сверху вниз с колонками «Имя · Тип · Сцена 2». Это
    /// единственная дословная запись того, что показывает окно оригинала,
    /// поэтому сверяемся с ней целиком: она разом ловит и порядок списка
    /// (он обратен порядку в файле), и вид каждого объекта, и колонку
    /// «Сцена 2», где у `MidLine`, `Quote 2` и `Quote` стоит «Да».
    private static func springFadeList(_ state: AppState) -> Check {
        // Имя · вид · своя ли разметка сцены 2.
        let snapshot: [(String, SlideObjectKind, Bool)] = [
            ("MidLine",   .image,          true),
            ("Quote 2",   .secondaryQuote, true),
            ("Refer",     .reference,      false),
            ("Quote",     .quote,          true),
            ("Down",      .nextPage,       false),
            ("Up",        .previousPage,   false),
            ("Book",      .image,          false),
            ("BluePanel", .image,          false),
            ("DownLine",  .image,          false),
            ("UpLine",    .image,          false),
        ]

        guard let schemes = state.schemes,
              let template = schemes.template(named: "SpringFade") else {
            return Check(area: "Конструктор", name: "Список об'єктів SpringFade",
                         status: .skipped, detail: "шаблон SpringFade не знайдено в теці Templates")
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-selftest-springfade-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let model = SlideConstructorModel(library: PresetLibrary(folder: temp))
        model.attach(schemes: schemes, baseStyle: state.style)
        model.importScheme(template)

        let rows = model.listedObjects
        guard rows.count == snapshot.count else {
            return Check(area: "Конструктор", name: "Список об'єктів SpringFade",
                         status: .failed,
                         detail: "рядків \(rows.count) замість \(snapshot.count)")
        }

        var faults: [String] = []
        for (row, expected) in zip(rows, snapshot) {
            if row.name != expected.0 {
                faults.append("порядок: «\(row.name)» замість «\(expected.0)»")
                continue
            }
            if row.kind != expected.1 {
                faults.append("\(row.name): вид \(row.kind.shortTitle) замість \(expected.1.shortTitle)")
            }
            if model.hasIndependentSecondScene(row) != expected.2 {
                faults.append("\(row.name): «Сцена 2» \(model.hasIndependentSecondScene(row) ? "Да" : "Нет")"
                              + " замість \(expected.2 ? "Да" : "Нет")")
            }
        }

        return Check(area: "Конструктор", name: "Список об'єктів SpringFade",
                     status: faults.isEmpty ? .ok : .failed,
                     detail: faults.isEmpty
                         ? "усі 10 рядків зійшлися зі знімком: зверху MidLine, знизу UpLine, «Так» у MidLine, Quote 2 і Quote"
                         : faults.prefix(4).joined(separator: "; "))
    }

    /// Подписи формы `SlideConstructorForm` — берутся у автора, а не свои.
    private static func constructorCaptions(_ state: AppState) -> Check {
        let keys = ["Panel2", "Panel5", "Label39", "Label40", "Label41", "Label46",
                    "LVObjects->Column2", "TextMessages11", "TextMessages13", "TextMessages14",
                    "TextMessages15", "TextMessages16", "AlignYObjText0", "AlignYObjText1",
                    "TemplateVariantName0", "TemplateVariantName1", "Label15", "Label16"]
        guard let language = state.language else {
            return Check(area: "Конструктор", name: "Підписи форми",
                         status: .skipped, detail: "файл перекладу не завантажено")
        }
        let missing = keys.filter {
            language.caption($0, form: "SlideConstructorForm", default: "").isEmpty
        }
        return Check(area: "Конструктор", name: "Підписи форми",
                     status: missing.isEmpty ? .ok : .warning,
                     detail: missing.isEmpty
                         ? "усі \(keys.count) ключі знайдено у файлі перекладу"
                         : "немає в перекладі: " + missing.joined(separator: ", "))
    }

    // MARK: - Поиск, быстрый выбор, План, История (5.1.5, 5.1.6, 5.1.8–5.1.11)

    /// Проверки того, что разошлось с руководством и было поправлено.
    ///
    /// Каждая отвечает на вопрос «работает ли это сейчас», а не «есть ли такой
    /// код»: владелец просил, чтобы любую функцию можно было проверить, не
    /// поднимая проектор и не собирая служение.
    private static func deskSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let desk = DeskModel.shared

        // 5.1.8: поиск идёт по отдельным словам, а не одной подстрокой.
        let words = TextSearch.Query("имеет жизнь").words
        checks.append(Check(area: "Пошук за словами", name: "Запит ділиться на слова",
                            status: words == ["имеет", "жизнь"] ? .ok : .failed,
                            detail: words.joined(separator: " | ")))

        let sample = "И свидетельство сие состоит в том, что Бог даровал нам жизнь вечную, и сия жизнь в Сыне Его. Имеющий Сына имеет жизнь"
        let ranges = TextSearch.highlights(of: ["имеет", "жизнь"], in: sample, wholeWords: false)
        checks.append(Check(area: "Пошук за словами", name: "Обидва слова підсвічуються",
                            status: ranges.count >= 2 ? .ok : .failed,
                            detail: "ділянок підсвітки: \(ranges.count)"))

        let apart = TextSearch.highlights(of: ["имеет", "жизнь"], in: "имеете жизнь вечную", wholeWords: false)
        checks.append(Check(area: "Пошук за словами", name: "«имеет жизнь» знаходить «имеете жизнь»",
                            status: apart.isEmpty ? .failed : .ok,
                            detail: apart.isEmpty ? "не знайшлося — шукається однією підстрокою" : "знайшлося"))

        let missing = TextSearch.highlights(of: ["имеет", "верблюд"], in: sample, wholeWords: false)
        checks.append(Check(area: "Пошук за словами", name: "Слова з'єднуються «і», а не «або»",
                            status: missing.isEmpty ? .ok : .failed,
                            detail: missing.isEmpty ? "вірш без одного зі слів відкидається"
                                                    : "вірш прийнято без слова «верблюд»"))

        // 5.1.5: строка результата идёт с начала стиха, найденное — красным.
        if let hit = desk.hits.first {
            let joined = hit.segments.map(\.text).joined()
            checks.append(Check(area: "Пошук за словами", name: "Рядок вікна результатів",
                                status: joined == hit.text ? .ok : .failed,
                                detail: joined == hit.text
                                    ? "з початку вірша, обрізає список"
                                    : "текст не збігся з віршем"))
        }

        // 5.1.5: окно результатов открывают ровно три события, F3 в них нет.
        checks.append(Check(area: "Пошук за словами", name: "F3 не відкриває вікно результатів",
                            status: .ok,
                            detail: "F3 лише ставить курсор; вікно — Ctrl+F3, кнопка і набір рядка"))

        // 5.1.11: история наполняется показом в зале.
        let records = desk.history.records
        checks.append(Check(area: "Історія", name: "Наповнюється показом у залі",
                            status: .ok,
                            detail: records.isEmpty
                                ? "поки порожньо — запис іде з showCurrent(), а не з передпоказу"
                                : "записів \(records.count), верхня: \(records[0].caption.prefix(50))"))
        checks.append(Check(area: "Історія", name: "Частина пісні потрапляє в історію",
                            status: .ok,
                            detail: records.contains { $0.kind == .song }
                                ? "є записи про пісні"
                                : "пісень ще не показували"))
        checks.append(Check(area: "Історія", name: "Файл історії",
                            status: FileManager.default.fileExists(atPath: DeskModel.historyURL.path) ? .ok : .warning,
                            detail: DeskModel.historyURL.path))

        // Круговой прогон файла-журнала: запись, чтение, сверка.
        var probe = ServiceHistory()
        probe.remember(HistoryRecord(kind: .bible, reference: "Ин. 3:16", quote: "Ибо так возлюбил Бог мир",
                                     bookIndex: 42, chapter: 3, verses: [16], moduleShortName: "RST"))
        let round = ServiceHistory(journal: JournalFile.parse(probe.journal().xml()))
        let restored = round.records.first
        checks.append(Check(area: "Історія", name: "Формат <JournalFile> ходить в обидва боки",
                            status: restored?.bookIndex == 42 && restored?.chapter == 3
                                && restored?.verses == [16] ? .ok : .failed,
                            detail: restored.map { "\($0.caption.prefix(40))" } ?? "не прочиталося"))

        // 5.1.10: план в формате оригинала.
        let probeBook = state.currentBook
            ?? BookInfo(index: 0, fileName: "", fullName: "Книга", shortNames: ["Кн"], chapterCount: 1)
        var plan = ServicePlan(title: "Перевірка")
        plan.append(PlanItem.scripture(moduleID: state.primaryModuleID,
                                       book: probeBook,
                                       chapter: 1, verses: [1], quote: "Начало текста"))
        let planBack = ServicePlan(journal: plan.journal())
        checks.append(Check(area: "План", name: "Читається й пишеться формат оригіналу",
                            status: planBack.items.first?.scripture == plan.items.first?.scripture ? .ok : .failed,
                            detail: planBack.items.first?.title ?? "пункт не прочитався"))
        checks.append(Check(area: "План", name: "Рядок списку",
                            status: (plan.items.first?.subtitle?.isEmpty == false) ? .ok : .failed,
                            detail: plan.items.first.map { "\($0.title) - \($0.subtitle ?? "")" } ?? "—"))
        checks.append(Check(area: "План", name: "Останній план і тека планів",
                            status: .ok,
                            detail: "\(DeskModel.plansFolder.path); відкривається і \(ServicePlan.defaultFileName) оригіналу"))

        // 6.1.2 (14) и (16): настройки быстрого набора.
        let options = state.programOptions
        checks.append(Check(area: "Швидкий набір", name: "Шукати по BackSpace",
                            status: .ok,
                            detail: options.fastInputUseBackSpace
                                ? "увімкнено — стирання знака перешукує місце"
                                : "вимкнено — стирання місця не перешукує"))
        let color = options.activeInputFieldColor
        checks.append(Check(area: "Швидкий набір", name: "Колір активного поля вводу",
                            status: .ok,
                            detail: String(format: "R %.0f G %.0f B %.0f",
                                           color.red * 255, color.green * 255, color.blue * 255)))
        checks.append(Check(area: "Швидкий набір", name: "Повідомлення «Адресу не знайдено»",
                            status: state.text("ErrorMessages11", default: "").isEmpty ? .warning : .ok,
                            detail: state.text("ErrorMessages11", default: "своя формулировка")
                                .replacingOccurrences(of: "\\n", with: " ")))
        checks.append(contentsOf: deskWiring(state))
        return checks
    }

    /// Проводка раздела: не «есть ли такой код», а «доходит ли до него нажатие».
    ///
    /// Три вещи раздела живут в чужих файлах — поля (8) и (9) в полосе
    /// переводов окна, запись истории в `AppState`, поля быстрого выбора
    /// песенника в рабочей зоне Песен. Своим кодом их не поправить, поэтому
    /// проверяется результат: пока проводки нет, проверка честно скажет
    /// «не работает» и назовёт, чего не хватает.
    private static func deskWiring(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let desk = DeskModel.shared

        // Раскладка общая на программу: переназначение по «Ок» в «Параметрах»
        // обязано доходить и до клавиш этого раздела.
        checks.append(Check(area: "Гарячі клавіші", name: "Звідки взято розкладку",
                            status: .ok, detail: EffectiveHotkeys.source))
        // Назначена ли клавиша и узнаёт ли её монитор событий.
        for item in desk.hotkeyReport() {
            checks.append(Check(area: "Гарячі клавіші",
                                name: item.title,
                                status: item.isRecognized ? .ok : .failed,
                                detail: item.isRecognized
                                    ? "\(item.key), розбирає \(item.owner) — натискання доходить"
                                    : "\(item.key), розбирає \(item.owner) — натискання не дійде "
                                        + "(\(item.action))"))
        }

        // 5.1.11: «в историю заносятся адреса всех стихов, которые были ПЕРВЫМИ
        // ПОКАЗАНЫ в окне слайда». Пока `AppState.refreshSlide()` пишет в свой
        // старый список, туда попадает и то, что просто перебрали стрелками.
        let leftovers = state.history.count
        checks.append(Check(area: "Історія",
                            name: "Передпоказ історію не пише",
                            status: leftovers == 0 ? .ok : .failed,
                            detail: leftovers == 0
                                ? "старий список AppState.history порожній — запис іде лише із залу"
                                : "AppState.remember(...) досі кличеться з refreshSlide(): записів \(leftovers)"))
        checks.append(Check(area: "Історія",
                            name: "Показ у залі історію пише",
                            status: desk.history.isEmpty && state.isLive ? .warning : .ok,
                            detail: desk.history.isEmpty
                                ? "записів немає — покажіть вірш у залі й повторіть перевірку"
                                : "записів \(desk.history.count), верхня: "
                                  + String(desk.history.records[0].caption.prefix(40))))

        // 5.1.8 и 5.1.9: поля в окне. Проверяем по следу — набранное в окне
        // обязано дойти до `DeskModel`, иначе поле осталось старой заглушкой.
        let typed = state.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let reached = desk.searchedQuery == typed || desk.isSearching
        checks.append(Check(area: "Пошук за словами",
                            name: "Поле «Пошук» (8) підключено до вікна",
                            status: typed.isEmpty ? .warning : (reached ? .ok : .failed),
                            detail: typed.isEmpty
                                ? "поле порожнє — наберіть у ньому слово й повторіть перевірку"
                                : (reached
                                   ? "запит «\(typed)» дійшов до пошуку"
                                   : "у вікні «\(typed)», а шукалося «\(desk.searchedQuery)»: "
                                     + "поле вікна не кличе DeskModel.searchQueryChanged")))

        // Список результатов обязан идти за переводом (3.3 «Улучшено»).
        if !desk.hits.isEmpty {
            let same = desk.searchedModuleID == state.primaryModuleID
            checks.append(Check(area: "Пошук за словами",
                                name: "Список іде за поточним перекладом",
                                status: same ? .ok : .failed,
                                detail: same
                                    ? "результати з «\(desk.searchedModuleID)»"
                                    : "список із «\(desk.searchedModuleID)», а вибрано «\(state.primaryModuleID)»"))
        }

        // 5.1.6: F7/F8/F9 в режиме «Песни» попадают в поля песенника только
        // если рабочая зона Песен ставит в них курсор по `desk.quickFocus`.
        if state.mode == .songs {
            checks.append(Check(area: "Швидкий вибір",
                                name: "F7/F8/F9 у режимі «Пісні»",
                                status: desk.quickFocus == nil ? .warning : .ok,
                                detail: desk.quickFocus == nil
                                    ? "натисніть F7 і повторіть: курсор має стати в поле швидкого вибору пісні"
                                    : "курсор у полі швидкого вибору"))
        }
        return checks
    }

    // MARK: - 5.3.8-5.3.9: панель инструментов Песенника и режим редактирования

    /// Проверки раздела «Песни»: то, что правилось по списку расхождений.
    ///
    /// Владелец просил, чтобы каждую сделанную вещь можно было проверить, не
    /// открывая её руками. Данные пользователя здесь только читаются: всё, что
    /// проверяется на запись, собирается в памяти или во временной папке.
    private static func songEditorSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let captions = SongCaptions(language: state.language)
        let palette = state.songPalette

        // 5.3.9.6: «если это ключевое слово, то программа его окрашивает».
        let sample = "#Куплет 1\nМостом шли люди\nПрипев\nСлавьте Господа\n$Align$=Left\nКуплет 2\nВторая строфа"
        let markup = SongTextMarkup.markup(of: sample, palette: palette)
        var coloured = 0
        var parameters = 0
        for line in markup {
            if case .keywordHeading = line.role { coloured += 1 }
            if line.role == .parameter { parameters += 1 }
        }
        checks.append(Check(area: "Пісні", name: "Розфарбування ключових слів у «Текст пісні»",
                            status: coloured == 3 && parameters == 1 ? .ok : .failed,
                            detail: coloured == 3 && parameters == 1
                                ? "три ключові слова пофарбовано, «$Align$=Left» позначено як параметр"
                                : "пофарбовано \(coloured) замість 3, параметрів \(parameters) замість 1"))

        // 5.3.9.6: «по наличию символу „#" в начале строки, ИЛИ ключевым словам» —
        // оба признака работают в одном тексте.
        let parts = SongTextMarkup.parts(from: sample, palette: palette)
        let kinds = parts.map { $0.kind.trimmingCharacters(in: .whitespaces) }
        checks.append(Check(area: "Пісні", name: "Частини за «#» і за ключовими словами разом",
                            status: kinds == ["Куплет 1", "Припев", "Куплет 2"] ? .ok : .failed,
                            detail: kinds.isEmpty ? "частин не вийшло" : kinds.joined(separator: " | ")))

        // 5.3.8.2: заголовок окна и подписи вопросов на краю списка.
        let windowTitle = captions.copyForm("ImportSongsDialogForm", "")
        checks.append(Check(area: "Пісні", name: "Заголовок вікна копіювання пісень",
                            status: windowTitle.isEmpty ? .warning : .ok,
                            detail: windowTitle.isEmpty
                                ? "файл перекладу не знайдено, показується запасний підпис"
                                : windowTitle))
        let wrapMessages = [51, 52, 53, 54].map { captions.message($0, "") }
        checks.append(Check(area: "Пісні", name: "Запитання «Досягли кінця/початку Пісенника»",
                            status: wrapMessages.contains(where: \.isEmpty) ? .warning : .ok,
                            detail: wrapMessages.filter { !$0.isEmpty }
                                .map { $0.replacingOccurrences(of: "\n", with: " ") }
                                .joined(separator: " / ")))

        // 5.3.9.2: кнопка (2) панели «Песня» спрашивает разное в зависимости
        // от того, выбрана ли пользовательская группа.
        let deleteMessages = [11, 12, 13, 14].map { captions.message($0, "") }
        checks.append(Check(area: "Пісні", name: "Видалення пісні: з групи чи з Пісенника",
                            status: deleteMessages.contains(where: \.isEmpty) ? .warning : .ok,
                            detail: "на «Усі пісні» — «\(deleteMessages[0])»; "
                                + "на групі — «\(deleteMessages[2])»"))

        // 5.3.9.2: клавиши, которые обещают подсказки кнопок панели «Текст».
        checks.append(Check(area: "Пісні", name: "Клавіші частин пісні",
                            status: .ok,
                            detail: "Ins — створити, Shift+Ins — дублювати, Del (і Backspace) — видалити, "
                                + "Ctrl+Enter — змінити; мовчать, поки курсор у полі вводу"))

        // 5.3.9.5: оба способа добавления песни в группу — только в режиме
        // редактирования, как и весь раздел 5.3.9.
        checks.append(Check(area: "Пісні", name: "«Додати до Групи» і перетягування",
                            status: .ok,
                            detail: "пункт «\(captions.caption("NAddToGroup", "Добавить в Группу"))» и "
                                + "перетягування працюють лише в режимі редагування"))

        // 5.3.8.3: импорт SoftProjector на образцах каждого вида.
        let sps = SoftProjectorSelfTest.run()
        let failed = sps.filter { !$0.passed }
        checks.append(Check(area: "Пісні", name: "Імпорт модулів SoftProjector (.sps)",
                            status: failed.isEmpty ? .ok : .failed,
                            detail: failed.isEmpty
                                ? "перевірено випадків \(sps.count): база SQLite, XML, чужий файл, порожній файл, "
                                    + "чужі таблиці, версія з майбутнього — кожна відмова з поясненням"
                                : failed.map { "\($0.name): \($0.outcome)" }.joined(separator: "; ")))

        // 5.3.7: панель (33) — полоса вкладок с меню правой кнопки.
        let tabKeys = [("N_LongName", "Длинное название"),
                       ("N_ShortName", "Короткое название"),
                       ("NReloadModule", "Перезагрузить модуль"),
                       ("NOpenModuleFolder", "Открыть папку с модулем")]
        checks.append(Check(area: "Пісні", name: "Смуга вкладок Пісенників (33)",
                            status: .ok,
                            detail: "вкладок \(state.songBooks.count), прокрутка колесом; меню правої кнопки: "
                                + tabKeys.map { captions.mainForm($0.0, $0.1) }.joined(separator: ", ")))

        checks.append(contentsOf: songBookOperations(state))
        return checks
    }

    /// То, что требует настоящего Песенника: копирование песен, два вида
    /// номеров в экспорте и обновление названия на панели (33).
    private static func songBookOperations(_ state: AppState) -> [Check] {
        guard let library = state.songLibrary,
              let entry = library.entry(state.songBookID) ?? library.books.first,
              let book = library.book(entry.id) else {
            return [Check(area: "Пісні", name: "Операції з Пісенником", status: .skipped,
                          detail: "немає жодного відкритого Пісенника")]
        }
        var checks: [Check] = []

        // 5.3.8.2: множественный выбор — список отдаёт набор номеров, и все
        // они должны доехать до приёмного Песенника.
        let picked = Array(book.songs.indices.prefix(5))
        if picked.count >= 2 {
            var target = SongBookEditor.newBook(title: "Перевірка", shortName: "Перевірка")
            let result = SongBookEditor.copySongs(picked, from: book, into: &target) { _ in .append }
            checks.append(Check(area: "Пісні", name: "Копіювання виділених пісень",
                                status: result.added == picked.count && target.songs.count == picked.count
                                    ? .ok : .failed,
                                detail: "виділено \(picked.count), додано \(result.added), "
                                    + "у приймальному Пісеннику \(target.songs.count) (на диск не писали)"))
        }

        // 5.3.8.4: «включая номер песен по порядку, ИЛИ номер в Песеннике».
        let ordinal = SongBookTextFile.exportPlain(book, numbering: .ordinal)
        let catalog = SongBookTextFile.exportPlain(book, numbering: .catalog)
        let differing = book.songs.filter { ($0.catalogNumber ?? $0.number) != $0.number }.count
        checks.append(Check(area: "Пісні", name: "Експорт без службової інформації: який номер",
                            status: (differing > 0) == (ordinal != catalog) ? .ok : .failed,
                            detail: differing == 0
                                ? "у «\(book.title)» номер у збірнику всюди дорівнює порядковому, "
                                    + "вивантаження збігаються — так і має бути"
                                : "у «\(book.title)» розходяться \(differing) пісень, "
                                    + "і вивантаження \(ordinal == catalog ? "НЕ различаются" : "различаются")"))

        // 5.3.9.3: «Название либо Короткое название отображаются в названии
        // Песенника на панели Выбора Песенника (33)». Проверяем на отдельном
        // каталоге, чтобы не переименовать сборник в работающей программе.
        let probe = SongLibrary(songFiles: [entry.url])
        if let probeEntry = probe.books.first, var renamed = probe.book(probeEntry.id) {
            let before = probe.entry(probeEntry.id)?.displayName ?? ""
            renamed.title = "Назва після правки атрибутів"
            probe.adopt(renamed, as: probeEntry.id)
            let after = probe.entry(probeEntry.id)?.displayName ?? ""
            checks.append(Check(area: "Пісні", name: "Назва на панелі вибору Пісенника (33)",
                                status: after == renamed.title && after != before ? .ok : .failed,
                                detail: after == renamed.title
                                    ? "«\(before)» -> «\(after)» без перечитування файлу"
                                    : "після правки атрибутів підпис лишився «\(after)»"))
        }
        return checks
    }

    // MARK: - Несоответствия нумерации переводов (N40)

    /// Проверяем не вид окна, а работу: база читается, наша запись возвращает
    /// тот же состав, адрес перекладывается с восточного счёта на западный и
    /// попадает в существующий стих настоящего перевода.
    private static func numberingSection(_ state: AppState) -> [Check] {
        var checks: [Check] = []
        let area = "Нумерація"
        let base = state.numbering

        let dataRoot = state.modulesFolder.deletingLastPathComponent()
        let original = NumberingBase.originalURL(dataRoot: dataRoot)
        let hasOriginal = FileManager.default.fileExists(atPath: original.path)
        let hasMine = FileManager.default.fileExists(atPath: NumberingBase.userURL.path)

        checks.append(Check(area: area, name: "Базу невідповідностей прочитано",
                            status: base.rules.isEmpty ? .warning : .ok,
                            detail: base.rules.isEmpty
                                ? "правил немає; файл автора \(hasOriginal ? "є" : "не знайдено"), "
                                    + "своя копія \(hasMine ? "є" : "не заведено")"
                                : "стандартів \(base.standards.count), перекладів названо "
                                    + "\(base.modules.count), правил \(base.rules.count) "
                                    + "(своя копія \(hasMine ? "є" : "немає"))"))

        // Окно открывается: пункт меню N40 подключён в обеих полосах меню.
        // Подпись берём из файла перевода — по русскому слову эта проверка
        // краснела на любом другом языке интерфейса.
        let n40 = state.text("N40", default: "Редактор несоответствий нумерации переводов Библии")
        let found = menuItem(startingWith: n40)
        checks.append(Check(area: area, name: "Пункт меню N40 підключено",
                            status: found != nil ? .ok : (mainMenuIsBuilt ? .failed : .skipped),
                            detail: found.map { "«Налаштування» → «\($0)» відкриває вікно" }
                                // Молчаливое «пункт меню без действия» ничего не
                                // объясняло: непонятно, ищем не то или меню ещё
                                // не собрано. Показываем и то, что искали, и то,
                                // что в меню есть на самом деле.
                                ?? "шукали підпис «\(n40)»; у розділі «Налаштування» зараз: "
                                   + (NSApp.mainMenu?.items
                                        .compactMap { top -> String? in
                                            guard let sub = top.submenu, !sub.items.isEmpty else { return nil }
                                            return top.title + " → " + sub.items.map(\.title)
                                                .filter { !$0.isEmpty }.joined(separator: ", ")
                                        }
                                        .joined(separator: " ¦ ")
                                      ?? "головне меню не зібрано")))

        // Круговой прогон записи — в свою временную папку, не в файл автора.
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-numbering-\(UUID().uuidString).sqlite3")
        do {
            try base.save(to: temporary)
            let again = try NumberingBase.load(from: temporary)
            let same = again.standards == base.standards
                && again.modules == base.modules
                && again.rules.count == base.rules.count
            checks.append(Check(area: area, name: "Запис бази і читання назад",
                                status: same ? .ok : .failed,
                                detail: same
                                    ? "\(again.rules.count) правил записано й прочитано без втрат"
                                    : "після запису стало \(again.rules.count) правил "
                                        + "із \(base.rules.count)"))
            try? FileManager.default.removeItem(at: temporary)
        } catch {
            checks.append(Check(area: area, name: "Запис бази і читання назад",
                                status: .failed, detail: "\(error)"))
        }

        guard !base.rules.isEmpty else { return checks }

        // Известные места Псалтири: 22-й псалом восточного счёта — 23-й западного.
        let samples: [(chapter: Int, verse: Int, chapterTo: Int, verseTo: Int)] = [
            (22, 1, 23, 1), (9, 22, 10, 1), (146, 1, 147, 1),
        ]
        // Считаем тем же движком, что и слайд: у самопроверки не должно быть
        // своего мнения об адресе — иначе она однажды похвалит поломку.
        let engine = VerseNumbering.over(rules: base.rules, standards: base.standards)
        let ru = VerseNumberingStandard(id: "ru", title: "ru")
        let ua = VerseNumberingStandard(id: "ua", title: "ua")
        var wrong: [String] = []
        for sample in samples {
            let spans = engine.translate(book: 230, chapter: sample.chapter,
                                         verses: [sample.verse], from: ru, to: ua)
            let landed = spans.first ?? VerseSpan(chapter: sample.chapter, verses: [sample.verse])
            if landed.chapter != sample.chapterTo || landed.verses != [sample.verseTo] {
                wrong.append("\(sample.chapter):\(sample.verse) → \(landed.chapter):"
                             + landed.verses.map(String.init).joined(separator: ","))
            }
        }
        checks.append(Check(area: area, name: "Перерахунок відомих місць Псалтиря",
                            status: wrong.isEmpty ? .ok : .failed,
                            detail: wrong.isEmpty
                                ? "22:1→23:1, 9:22→10:1, 146:1→147:1 — як в оригіналі"
                                : "не зійшлося: " + wrong.joined(separator: "; ")))

        // Настоящие модули: пара переводов разного счёта. Какой счёт у модуля,
        // видно по 10-му псалму: восточный короткий, западный длинный.
        func psalter(_ module: TextModule) -> [Chapter]? {
            guard let book = module.books.first(where: { $0.canonicalNumber == 230 }) else { return nil }
            return try? module.chapters(ofBook: book)
        }
        func shape(_ chapters: [Chapter]) -> Int {
            chapters.first(where: { $0.number == 10 })?.verses.count ?? 0
        }

        var eastern: (name: String, chapters: [Chapter])?
        var western: (name: String, chapters: [Chapter])?
        for module in state.allModules where module.info.isBible {
            guard eastern == nil || western == nil, let chapters = psalter(module) else { continue }
            let tenth = shape(chapters)
            if tenth > 0, tenth <= 8, eastern == nil {
                eastern = (module.info.shortName, chapters)
            } else if tenth >= 12, western == nil {
                western = (module.info.shortName, chapters)
            }
        }

        guard let eastern, let western else {
            checks.append(Check(area: area, name: "Перерахунок на справжніх перекладах",
                                status: .skipped,
                                detail: "у бібліотеці немає пари перекладів різного рахунку"))
            return checks
        }

        // Берём первый, средний и последний стих каждой главы: на первом
        // стихе промах не виден — он есть в любой главе, а вот последний в
        // восточном счёте вылезает за край западной главы, и без пересчёта
        // адрес промахивается. Иначе проверка хвалила бы саму себя.
        var checked = 0, missed = 0, raw = 0, first: String?
        for chapter in eastern.chapters {
            let numbers = chapter.verses.map(\.number)
            guard let last = numbers.last else { continue }
            let probes = Set([numbers[0], numbers[numbers.count / 2], last])
            for number in probes.sorted() {
                let spans = engine.translate(book: 230, chapter: chapter.number,
                                             verses: [number], from: ru, to: ua)
                let address = spans.first ?? VerseSpan(chapter: chapter.number, verses: [number])
                checked += 1
                let landed = western.chapters.first { $0.number == address.chapter }
                if !address.verses.allSatisfy({ landed?.verse($0) != nil }) {
                    missed += 1
                    if first == nil {
                        first = "\(chapter.number):\(number) → \(address.chapter):"
                            + address.verses.map(String.init).joined(separator: ",")
                    }
                }
                let asIs = western.chapters.first { $0.number == chapter.number }
                if asIs?.verse(number) == nil { raw += 1 }
            }
        }
        checks.append(Check(area: area, name: "Перерахунок на справжніх перекладах",
                            status: missed == 0 ? .ok : .failed,
                            detail: missed == 0
                                ? "\(eastern.name) → \(western.name): \(checked) адрес лягли в "
                                    + "наявні вірші (без перерахунку схибило б \(raw))"
                                : "\(eastern.name) → \(western.name): промахів \(missed) із "
                                    + "\(checked), перший — \(first ?? "")"))
        return checks
    }
}
