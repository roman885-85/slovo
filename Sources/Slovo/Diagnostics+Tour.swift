import AppKit
import SlovoCore

/// Два раздела для разбора жалоб владельца на живой программе.
///
/// «Тур» открывает каждое окно программы так, как его открывает человек, и
/// снимает в картинку — в том размере, в каком оно открылось, и в наименьшем
/// допустимом. Обрезанные кнопки и подписи видны только глазами: по коду
/// окно всегда «помещается».
///
/// «Показ по вкладкам» повторяет шаги владельца: презентация — в зал, скрыть,
/// Библия — в зал, снова презентация. После каждого шага в отчёт ложится, что
/// стоит в предпросмотре и что в зале. Так поломка «предпросмотр отстаёт на
/// один слайд» находится по цепочке, а не по догадке.
extension Diagnostics {

    // MARK: - Тур по окнам

    static func tourSection(state: AppState) -> [Check] {
        var lines: [String] = []
        var faults: [String] = []
        let screen = NSScreen.main?.visibleFrame ?? .zero
        lines.append("екран \(Int(screen.width))×\(Int(screen.height))")

        // Главное окно — во всех режимах: рабочая область у каждого своя.
        if let root = NativeMainWindowController.shared.root {
            let wasMode = state.mode
            for mode in AppState.WorkMode.allCases {
                state.mode = mode
                Signals.shared.send(.mode)
                wait(untilTrue: { false }, seconds: 0.35)
                root.layoutSubtreeIfNeeded()
                root.window?.displayIfNeeded()
                if !snapshot(root, to: "slovo-тур-\(mode.rawValue).png") {
                    faults.append("режим \(mode.rawValue) не знявся")
                }
            }
            lines.append("головне вікно \(Int(root.bounds.width))×\(Int(root.bounds.height)), режимів знято \(AppState.WorkMode.allCases.count)")
            // И в наименьшем размере: «если окна уменьшать, кнопки теряются».
            if let window = root.window {
                let opened = window.frame
                window.setContentSize(window.minSize)
                for mode in [AppState.WorkMode.bible, .songs, .media] {
                    state.mode = mode
                    Signals.shared.send(.mode)
                    wait(untilTrue: { false }, seconds: 0.35)
                    root.layoutSubtreeIfNeeded()
                    window.displayIfNeeded()
                    if !screenSnapshot(of: window, to: "slovo-тур-\(mode.rawValue)-мин.png") {
                        _ = snapshot(root, to: "slovo-тур-\(mode.rawValue)-мин.png")
                    }
                }
                lines.append("головне вікно в найменшому розмірі \(Int(root.bounds.width))×\(Int(root.bounds.height)) знято")
                window.setFrame(opened, display: true)
            }
            state.mode = wasMode
            Signals.shared.send(.mode)
        } else {
            faults.append("головного вікна немає")
        }

        /// Открыть окно, снять его как есть и в наименьшем размере, закрыть.
        func tour(_ title: String, file: String, open: () -> Void, close: (NSWindow) -> Void) {
            let before = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            open()
            wait(untilTrue: {
                NSApp.windows.contains { $0.isVisible && !before.contains(ObjectIdentifier($0)) }
            }, seconds: 3)
            guard let window = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) }),
                  let content = window.contentView else {
                faults.append("\(title): вікно не відкрилося")
                return
            }
            // Первый кадр — таким окно встречает человека. Потом ждём, пока
            // оно дорисуется, и снимаем ещё раз: разница между ними и есть
            // «открылось без подписей».
            wait(untilTrue: { false }, seconds: 0.15)
            _ = screenSnapshot(of: window, to: file.replacingOccurrences(of: ".png", with: "-сразу.png"))
            wait(untilTrue: { false }, seconds: 0.7)
            content.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            let opened = window.frame
            let fits = opened.width <= screen.width + 1 && opened.height <= screen.height + 1
            var line = "\(title): відкрилося \(Int(content.bounds.width))×\(Int(content.bounds.height))"
            if !fits { line += " — НЕ ВМІЩАЄТЬСЯ на екран"; faults.append("\(title) не вміщається на екран") }
            if !screenSnapshot(of: window, to: file) {
                line += " (знято малюванням, не з екрана)"
                if !snapshot(content, to: file) { faults.append("\(title): знімок не записався") }
            }

            // В наименьшем размере — там и теряются кнопки. Кадр возвращаем:
            // окно пишет свой размер в настройки, и оставлять ему сжатый нельзя.
            let least = window.minSize
            if least.width > 100, least.height > 100,
               least.width < opened.width - 1 || least.height < opened.height - 1 {
                window.setContentSize(NSSize(width: least.width, height: least.height))
                content.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                wait(untilTrue: { false }, seconds: 0.4)
                let smallName = file.replacingOccurrences(of: ".png", with: "-мин.png")
                if !screenSnapshot(of: window, to: smallName) { _ = snapshot(content, to: smallName) }
                line += "; найменше \(Int(content.bounds.width))×\(Int(content.bounds.height)) знято"
                window.setFrame(opened, display: false)
            }
            lines.append(line)
            close(window)
            wait(untilTrue: { false }, seconds: 0.25)
        }

        tour("Параметри", file: "slovo-тур-параметры.png",
             open: { NativeSettingsWindow.shared.show(state: state) },
             close: { _ in NativeSettingsWindow.shared.discard() })
        tour("Конструктор", file: "slovo-тур-конструктор.png",
             open: { SlideConstructorWindow.show(state: state) },
             close: { $0.orderOut(nil) })
        tour("Веб-редактор", file: "slovo-тур-веб-редактор.png",
             open: { WebSlideEditorWindow.show(state: state) },
             close: { $0.orderOut(nil) })
        tour("Нумерація", file: "slovo-тур-нумерация.png",
             open: { NumberingEditorWindow.show(state: state) },
             close: { $0.orderOut(nil) })
        tour("Переклад інтерфейсу", file: "slovo-тур-перевод.png",
             open: { InterfaceWindows.showTranslate(state: state) },
             close: { $0.orderOut(nil) })
        tour("Стиль інтерфейсу", file: "slovo-тур-стиль.png",
             open: { InterfaceWindows.showStyle(state: state) },
             close: { $0.orderOut(nil) })
        tour("Вибір мови", file: "slovo-тур-язык.png",
             open: { InterfaceWindows.showLanguagePicker(state: state) },
             close: { $0.orderOut(nil) })
        tour("Майстер імпорту", file: "slovo-тур-мастер.png",
             open: { ImportWizardWindow.show(state: state) },
             close: { $0.orderOut(nil) })
        tour("Кольори частин пісень", file: "slovo-тур-цвета.png",
             open: { NativeSongColorsetWindow.show(state: state) },
             close: { $0.performClose(nil) })

        return [Check(area: "Тур", name: "Вікна знято як є і в найменшому розмірі",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ")
                          + lines.joined(separator: "; ") + " — знімки slovo-тур-*.png у ~/Library/Logs/")]
    }

    /// Снимок окна теми пикселями, что видит человек, — через систему, а не
    /// через `cacheDisplay`: тот рисует вид заново и может показать иное, чем
    /// стоит на экране. Свои окна система отдаёт без разрешения на запись
    /// экрана. Возвращает, записался ли файл.
    static func screenSnapshot(of window: NSWindow, to name: String) -> Bool {
        guard window.windowNumber > 0 else { return false }
        let id = CGWindowID(window.windowNumber)
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow, id,
                                                  [.boundsIgnoreFraming, .bestResolution]),
              image.width > 1 else { return false }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { return false }
        let path = NSString(string: "~/Library/Logs/\(name)").expandingTildeInPath
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }

    // MARK: - Модули с другого пути

    /// «Переводы Библии не добавляются при включении их в модулях»: копия
    /// маленького модуля кладётся вне папки `Modules`, добавляется в список
    /// «Параметров» кнопкой «+», настройки записываются — и модуль обязан
    /// появиться на полосе переводов. Файл настроек возвращается как был.
    static func modulesRosterSection(state: AppState) -> [Check] {
        let area = "Модулі"
        let store = SettingsStore.shared
        let manager = FileManager.default
        let modulesFolder = state.modulesFolder
        // Самая маленькая папка «Цитаты из Библии» — копировать гигабайт незачем.
        let folders = ((try? manager.contentsOfDirectory(at: modulesFolder, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .filter { manager.fileExists(atPath: $0.appendingPathComponent("bibleqt.ini").path) }
        func size(of folder: URL) -> Int {
            let files = (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        }
        guard let smallest = folders.min(by: { size(of: $0) < size(of: $1) }) else {
            return [Check(area: area, name: "Модуль з іншого шляху стає на смугу", status: .skipped,
                          detail: "у теці модулів немає жодної теки «Цитата з Біблії»")]
        }
        let temp = manager.temporaryDirectory.appendingPathComponent("slovo-модули-\(UUID().uuidString)")
        let copy = temp.appendingPathComponent("проба-" + smallest.lastPathComponent)
        do {
            try manager.createDirectory(at: temp, withIntermediateDirectories: true)
            try manager.copyItem(at: smallest, to: copy)
        } catch {
            return [Check(area: area, name: "Модуль з іншого шляху стає на смугу", status: .skipped,
                          detail: "не скопіювався пробний модуль: \(error)")]
        }
        let identifier = copy.lastPathComponent
        let original = try? Data(contentsOf: SettingsStore.storageURL)
        let tabsBefore = NativeBibleWorkspace.shared.strip?.translationTabCount ?? -1
        var faults: [String] = []
        var lines: [String] = []

        defer {
            // Возвращаем всё: строку из списка, файл настроек и библиотеку.
            store.removeModule(store.settings.modules.first { $0.name == identifier }?.id ?? "")
            if let original { try? original.write(to: SettingsStore.storageURL, options: .atomic) }
            store.reload(dataRoot: modulesFolder.deletingLastPathComponent())
            state.applyModuleRoster(store.settings.modules)
            state.reloadLibrary()
            wait(untilTrue: { !state.isLoadingLibrary }, seconds: 30)
            try? manager.removeItem(at: temp)
        }

        // Как человек: «+» в «Параметрах», потом «Ок».
        if let problem = store.addModule(at: copy) { faults.append("«+» не прийняв теку: \(problem)") }
        store.save()
        lines.append("додали \(identifier), налаштування записано")
        wait(untilTrue: { !state.isLoadingLibrary && state.allModules.contains { $0.identifier == identifier } }, seconds: 30)
        let opened = state.allModules.contains { $0.identifier == identifier }
        let onStrip = state.orderedModules.contains { $0.identifier == identifier }
        let tabsAfter = NativeBibleWorkspace.shared.strip?.translationTabCount ?? -1
        lines.append("бібліотека відкрила: \(opened ? "так" : "ні"); на смузі перекладів: \(onStrip ? "так" : "ні"); вкладок було \(tabsBefore), стало \(tabsAfter)")
        if !opened { faults.append("бібліотека не відкрила модуль із чужого шляху") }
        if !onStrip { faults.append("модуля немає в списку смуги перекладів") }
        if tabsAfter != tabsBefore + 1 { faults.append("вкладок на смузі не додалося") }
        // И открывается ли он как основной — иначе вкладка пустая.
        if opened {
            let was = state.primaryModuleID
            state.primaryModuleID = identifier
            wait(untilTrue: { !state.books.isEmpty && state.primaryModuleID == identifier }, seconds: 5)
            lines.append("книг у пробного модуля: \(state.books.count)")
            if state.books.isEmpty { faults.append("пробний модуль вибрано основним, а книг немає") }
            state.primaryModuleID = was
        }
        return [Check(area: area, name: "Модуль з іншого шляху стає на смугу",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }

    // MARK: - Поиск по песням

    /// Поле поиска на вкладке «Песни» ищет по Песеннику и подсвечивает
    /// найденное; строка результата открывает песню и часть.
    static func songSearchSection(state: AppState) -> [Check] {
        let area = "Пошук за піснями"
        let workspace = NativeSongsWorkspace.shared
        let wasMode = state.mode
        let wasQuery = state.searchQuery
        defer {
            DeskModel.shared.runSearch("", state: state)
            state.searchQuery = wasQuery
            DeskModel.shared.isSearchResultsShown = false
            state.mode = wasMode
            Signals.shared.send(.mode)
        }
        state.mode = .songs
        Signals.shared.send(.mode)
        wait(untilTrue: { workspace.model.book != nil }, seconds: 5)
        guard let songs = workspace.model.book?.songs,
              let song = songs.first(where: { $0.parts.contains { $0.text.count > 30 } }),
              let part = song.parts.firstIndex(where: { $0.text.count > 30 }) else {
            return [Check(area: area, name: "Пошук на вкладці «Пісні» шукає за піснями", status: .skipped,
                          detail: "немає відкритого Пісенника з текстом")]
        }
        // Слово из середины части: не первое (оно может быть заглавным
        // «Куплет») и подлиннее, чтобы находок было не три тысячи.
        let words = song.parts[part].text.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard let word = words.dropFirst().first(where: { $0.count >= 6 }) ?? words.first(where: { $0.count >= 4 }) else {
            return [Check(area: area, name: "Пошук на вкладці «Пісні» шукає за піснями", status: .skipped,
                          detail: "у частині пісні немає слова, довшого за чотири літери")]
        }
        var faults: [String] = []
        var lines: [String] = []

        state.searchQuery = word
        DeskModel.shared.searchQueryChanged(word, state: state)
        NativeBibleBridge.shared.sync()
        let started = Date()
        wait(untilTrue: { !DeskModel.shared.isSearching && !DeskModel.shared.songHits.isEmpty }, seconds: 10)
        wait(untilTrue: { false }, seconds: 0.3)
        let hits = DeskModel.shared.songHits
        lines.append("слово «\(word)» із пісні \(song.index + 1): знахідок \(hits.count), віршів Біблії \(DeskModel.shared.hits.count),"
            + " чекали \(String(format: "%.1f", Date().timeIntervalSince(started))) с, чи йде ще пошук: \(DeskModel.shared.isSearching),"
            + " запит у стані «\(state.searchQuery)», режим \(state.mode.rawValue)")
        if let trace = try? String(contentsOfFile: NativeTrace.path, encoding: .utf8) {
            let own = trace.split(separator: "\n").filter { $0.contains("пошук за піснями") }.suffix(4)
            if !own.isEmpty { lines.append("щоденник: " + own.joined(separator: " | ")) }
        }
        guard let mine = hits.first(where: { $0.songIndex == song.index && $0.partIndex == part }) else {
            faults.append("своя частина пісні серед знахідок не знайшлася")
            return [Check(area: area, name: "Пошук на вкладці «Пісні» шукає за піснями", status: .failed,
                          detail: faults.joined(separator: "; ") + ". " + lines.joined(separator: "; "))]
        }
        if !DeskModel.shared.hits.isEmpty { faults.append("на вкладці пісень шукалося і за Біблією") }
        if mine.highlights.isEmpty { faults.append("у знахідки немає підсвітки") }
        if !mine.segments.contains(where: \.isMatch) { faults.append("у шматках рядка немає жодного поміченого") }
        if !DeskModel.shared.isSearchResultsShown { faults.append("вікно результатів не відкрилося само") }
        let paneLines = NativeBibleWorkspace.shared.results?.lineCount ?? -1
        lines.append("рядків у вікні результатів: \(paneLines)")
        if paneLines != hits.count { faults.append("у вікні результатів \(paneLines) рядків, а знахідок \(hits.count)") }

        // Строка результата открывает песню и часть.
        workspace.reveal(song: mine.songIndex, part: mine.partIndex, live: false)
        wait(untilTrue: { false }, seconds: 0.3)
        lines.append("після клацання: пісня \(workspace.model.songIndex.map { "\($0 + 1)" } ?? "немає"), частина \(workspace.model.partIndex.map { "\($0 + 1)" } ?? "немає")")
        if workspace.model.songIndex != song.index || workspace.model.partIndex != part {
            faults.append("клацання по знахідці не відкрило пісню й частину")
        }
        // Часть может быть разбита на страницы — сверяем начало, а не слово.
        func head(_ text: String) -> String {
            String(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces).prefix(10))
        }
        let shown = state.slide.mainText
        if head(shown) != head(song.parts[part].text) {
            faults.append("у передпоказі не та частина: «\(shown.prefix(40))»")
        }

        // Обратно на Библию с тем же словом: результаты пересчитываются по ней.
        state.mode = .bible
        Signals.shared.send(.mode)
        wait(untilTrue: { !DeskModel.shared.isSearching && DeskModel.shared.songHits.isEmpty }, seconds: 10)
        lines.append("на Біблії: пісенних знахідок \(DeskModel.shared.songHits.count), віршів \(DeskModel.shared.hits.count)")
        if !DeskModel.shared.songHits.isEmpty { faults.append("на вкладці Біблії лишилися пісенні знахідки") }

        return [Check(area: area, name: "Пошук на вкладці «Пісні» шукає за піснями",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "" : faults.joined(separator: "; ") + ". ") + lines.joined(separator: "; "))]
    }

    // MARK: - Показ по вкладкам

    static func showTabsSection(state: AppState) -> [Check] {
        let area = "Показ за вкладками"
        guard let bottom = NativeBottom.row else {
            return [Check(area: area, name: "Кроки власника", status: .skipped, detail: "нижнього ряду немає")]
        }
        let preview = bottom.preview
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("slovo-показ-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = folder.appendingPathComponent("проба.pdf")
        guard makePDF(at: pdf, pages: 2) else {
            return [Check(area: area, name: "Кроки власника", status: .skipped, detail: "не зібрався пробний PDF")]
        }

        let workspace = NativeShowWorkspace.presentation
        let wasMode = state.mode
        let wasLive = state.isLive
        workspace.model.close()
        defer {
            workspace.model.close()
            workspace.open([])
            state.media.showStill(nil)
            state.isLive = wasLive
            state.mode = wasMode
            Signals.shared.send(.mode)
        }

        var steps: [String] = []
        var faults: [String] = []

        func settle(_ seconds: Double = 0.4) { wait(untilTrue: { false }, seconds: seconds) }
        func hall() -> (video: Bool, text: String) {
            (state.projection.isVideoShown && state.media.isVideoOnScreen && state.isLive,
             state.lastScreenSlide.mainText)
        }
        func go(_ mode: AppState.WorkMode) {
            state.mode = mode
            Signals.shared.send(.mode)
            settle()
        }
        /// Записать шаг и сверить ожидания. `previewText` — что должно быть в
        /// предпросмотре: «картинка», «слайд» с таким текстом или «пусто».
        func check(_ step: String, previewIs: (NativeSlidePreview.Showing) -> Bool, previewWant: String,
                   hallVideo: Bool?, hallText: String?) {
            let shown = preview.showing
            let seen = hall()
            var line = "\(step): передпоказ — \(shown.described); зал — кадр \(seen.video ? "є" : "немає"), текст «\(seen.text.prefix(20))»"
            var wrong: [String] = []
            if !previewIs(shown) { wrong.append("у передпоказі чекали \(previewWant)") }
            if let hallVideo, seen.video != hallVideo { wrong.append("у залі кадр \(hallVideo ? "має бути" : "не має бути")") }
            if let hallText {
                if hallText.isEmpty, !seen.text.isEmpty { wrong.append("у залі не має бути тексту") }
                if !hallText.isEmpty, seen.text != hallText { wrong.append("у залі чекали текст «\(hallText.prefix(20))»") }
            }
            if !wrong.isEmpty { line += " — НЕ ТАК: " + wrong.joined(separator: ", "); faults.append(step) }
            steps.append(line)
        }
        func isStill(_ showing: NativeSlidePreview.Showing) -> Bool {
            if case .still = showing { return true }
            return false
        }
        func isSlide(_ text: String) -> (NativeSlidePreview.Showing) -> Bool {
            { showing in
                if case .slide(let slide) = showing { return slide.mainText == text }
                return false
            }
        }

        // 1. Библия, показ выключен: в предпросмотре — подготовленный стих.
        state.isLive = false
        state.media.showStill(nil)
        go(.bible)
        let verse = state.slide.mainText
        guard !verse.isEmpty else {
            return [Check(area: area, name: "Кроки власника", status: .skipped, detail: "у передпоказі немає вірша — немає з чим порівнювати")]
        }
        check("1. Біблія, вірш підготовлено", previewIs: isSlide(verse), previewWant: "вірш", hallVideo: false, hallText: "")

        // 2. Презентация открыта, страница выбрана: предпросмотр — картинка.
        go(.presentation)
        workspace.open([pdf])
        workspace.selectPage(0)
        settle()
        check("2. Презентація, сторінку 1 вибрано", previewIs: isStill, previewWant: "картинку", hallVideo: false, hallText: "")

        // 3. «Показать»: картинка в зале, текста под ней нет.
        workspace.showCurrentPage()
        settle()
        check("3. Презентація в залі", previewIs: isStill, previewWant: "картинку", hallVideo: true, hallText: "")

        // 4. «Скрыть» картинку.
        workspace.hideCurrentPage()
        settle()
        check("4. Презентацію сховано", previewIs: { _ in true }, previewWant: "будь-що", hallVideo: false, hallText: "")

        // 5. Обратно в Библию: предпросмотр обязан показать стих, а не
        // закрытую картинку. Здесь и жила поломка «отстаёт на один».
        go(.bible)
        check("5. Знову Біблія", previewIs: isSlide(verse), previewWant: "вірш", hallVideo: false, hallText: "")

        // 6. «Показать» стих: в зале текст, картинки нет.
        state.showCurrent()
        settle()
        check("6. Вірш у залі", previewIs: isSlide(verse), previewWant: "вірш", hallVideo: false, hallText: verse)

        // 7. «Скрыть» стих, презентация, вторая страница, «Показать».
        state.isLive = false
        settle(0.2)
        go(.presentation)
        workspace.selectPage(1)
        settle()
        check("7. Презентація, сторінку 2 вибрано", previewIs: isStill, previewWant: "картинку", hallVideo: false, hallText: "")
        workspace.showCurrentPage()
        settle()
        check("8. Сторінка 2 в залі", previewIs: isStill, previewWant: "картинку", hallVideo: true, hallText: "")

        // 9. В Библию, не скрывая картинки, и «Показать»: текст сменяет картинку.
        go(.bible)
        check("9. Біблія при картинці в залі", previewIs: isSlide(verse), previewWant: "вірш", hallVideo: true, hallText: "")
        state.showCurrent()
        settle(0.8)
        check("10. Вірш поверх картинки", previewIs: isSlide(verse), previewWant: "вірш", hallVideo: false, hallText: verse)

        // 11. И снова презентация без скрытия: картинка сменяет текст.
        go(.presentation)
        workspace.showCurrentPage()
        settle(0.8)
        check("11. Презентація поверх вірша", previewIs: isStill, previewWant: "картинку", hallVideo: true, hallText: "")

        return [Check(area: area, name: "Кроки власника: презентація ↔ Біблія",
                      status: faults.isEmpty ? .ok : .failed,
                      detail: (faults.isEmpty ? "усі кроки зійшлися. " : "розійшлися кроки: " + faults.joined(separator: "; ") + ". ")
                          + steps.joined(separator: " | "))]
    }
}
