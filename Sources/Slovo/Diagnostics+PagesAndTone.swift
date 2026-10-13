import AppKit
import SlovoCore

/// Зауваження власника від 13.10.2026: вигляд сторінок презентації,
/// наближення лише для своєї сторінки і тон лише для вибраної фонограми.
extension Diagnostics {

    static func pagesAndToneSection(state: AppState) -> [Check] {
        presentationLookCheck(state: state) + zoomPerPageCheck(state: state) + toneOfSelectedCheck(state: state)
    }

    /// Презентацію для перевірки називає змінна `SLOVO_CHECK_PPTX`: вигляд
    /// слайда звіряють із тим файлом, на якому помітили ваду, а не з пробним.
    private static var ownerDeck: URL? {
        guard let path = ProcessInfo.processInfo.environment["SLOVO_CHECK_PPTX"], !path.isEmpty,
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Кегль успадковано зі стилю напису, а рамку «пергаменту» намальовано.
    private static func presentationLookCheck(state: AppState) -> [Check] {
        let area = "Презентація"
        let name = "Успадкований кегль і перехід кольору зразка"
        guard let deck = ownerDeck else {
            return [Check(area: area, name: name, status: .skipped, detail: "не названо SLOVO_CHECK_PPTX")]
        }
        guard let document = try? PPTXDocument(fileAt: deck) else {
            return [Check(area: area, name: name, status: .failed, detail: "презентація не відкрилася")]
        }
        // Найдрібніший кегль тексту на кожному слайді і чи є фігура з переходом.
        var lines: [String] = []
        var smallest = Double.greatestFiniteMagnitude
        var gradients = 0
        for (index, slide) in document.slides.enumerated() {
            let sizes = slide.shapes.flatMap(\.paragraphs).flatMap(\.runs)
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.map(\.size)
            let hasGradient = slide.shapes.contains { if case .gradient = $0.fill { return true }; return false }
            if hasGradient { gradients += 1 }
            if let least = sizes.min() { smallest = min(smallest, least) }
            lines.append("слайд \(index + 1): кегль від \(Int(sizes.min() ?? 0)) до \(Int(sizes.max() ?? 0)), перехід: \(hasGradient ? "є" : "немає")")
        }
        let ok = gradients == document.count && smallest > 18
        return [Check(area: area, name: name, status: ok ? .ok : .failed,
                      detail: lines.joined(separator: "; "))]
    }

    /// Наближення тримається лише на тій сторінці, де його зробили, і лише
    /// доки вона стоїть у залі.
    private static func zoomPerPageCheck(state: AppState) -> [Check] {
        let area = "Презентація"
        let name = "Наближення лише для своєї сторінки"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-сторінки-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        // Перший файл списку — пробний PDF; другий — презентація власника,
        // а без неї ще один PDF. Два файли потрібні, щоб прибрати перший і
        // побачити, що той самий номер у списку — вже інша сторінка.
        let firstFile = folder.appendingPathComponent("перша.pdf")
        var secondFile = ownerDeck
        if secondFile == nil {
            let spare = folder.appendingPathComponent("друга.pdf")
            if makePDF(at: spare, pages: 4) { secondFile = spare }
        }
        let pictureFile = folder.appendingPathComponent("картинка.png")
        if let picture = makePicture(width: 800, height: 600),
           let png = NSBitmapImageRep(cgImage: picture).representation(using: .png, properties: [:]) {
            try? png.write(to: pictureFile)
        }
        guard makePDF(at: firstFile, pages: 3), let secondFile,
              FileManager.default.fileExists(atPath: pictureFile.path) else {
            return [Check(area: area, name: name, status: .skipped, detail: "пробні файли не зібралися")]
        }

        let workspace = NativeShowWorkspace.presentation
        let pictures = NativeShowWorkspace.pictures
        let focus = SlideFocus.shared
        let wasMode = state.mode, wasLive = state.isLive
        // Списки людини повертаємо такими, як були: перевірка відкриває свої файли.
        let wasDecks = workspace.model.decks.map(\.url), wasPictures = pictures.model.decks.map(\.url)
        workspace.model.close()
        pictures.model.close()
        defer {
            focus.reset()
            state.media.showStill(nil)
            workspace.model.close()
            workspace.open(wasDecks)
            pictures.model.close()
            pictures.open(wasPictures)
            state.isLive = wasLive
            state.mode = wasMode
            Signals.shared.send(.mode)
        }
        func settle(_ seconds: Double = 0.5) { wait(untilTrue: { false }, seconds: seconds) }
        func go(_ mode: AppState.WorkMode) {
            state.mode = mode
            Signals.shared.send(.mode)
            settle(0.3)
        }
        /// Чи в зал іде вирізаний шматок: показане вужче за саму сторінку.
        func hallIsZoomed() -> Bool {
            guard let whole = state.media.still, let shown = state.media.shownStill else { return false }
            return shown.width < whole.width - 2
        }
        func zoomIn() {
            focus.zoom(to: 2.5, aroundShown: 0.3, 0.6)
            focus.setOn(true)
            settle()
        }
        /// Сторінка в залі ціла, наближення вимкнено і вікно показу — вся сторінка.
        func isWhole() -> Bool {
            state.media.still != nil && !focus.isOn && !hallIsZoomed() && focus.shownRect.width > 0.999
        }
        func shot(_ label: String) {
            guard let image = state.media.shownStill else { return }
            let path = NSString(string: "~/Library/Logs/slovo-сторінки-\(label).png").expandingTildeInPath
            if let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
        var faults: [String] = []
        var lines: [String] = []
        func expect(_ good: Bool, _ what: String, fault: String) {
            lines.append("\(what): \(good ? "так" : "НІ")")
            if !good { faults.append(fault) }
        }

        go(.presentation)
        workspace.open([firstFile])
        workspace.open([secondFile])
        let base = 3                                   // перша сторінка другого файла
        guard workspace.model.count >= base + 4 else {
            return [Check(area: area, name: name, status: .skipped, detail: "у другому файлі менше чотирьох сторінок")]
        }

        // 1. Сторінку показано й наближено.
        workspace.selectPage(base + 2)
        workspace.showCurrentPage()
        settle()
        shot("3-ціла")
        zoomIn()
        shot("3-наближена")
        expect(focus.isOn && hallIsZoomed(), "сторінку 3 наближено ×2,5", fault: "наближення не ввімкнулося")

        // 2. «Показати» вдруге, поки вона в залі, наближення не знімає.
        workspace.showCurrentPage()
        settle()
        expect(focus.isOn && hallIsZoomed(), "повторний показ тієї самої — наближення на місці",
               fault: "повторний показ тієї самої сторінки зняв наближення")

        // 3. Інша сторінка приходить цілою; повернення наближення не вмикає.
        workspace.step(by: 1)
        settle()
        shot("4-після-переходу")
        expect(isWhole(), "перейшли на 4 — сторінка ціла", fault: "на наступній сторінці наближення лишилося")
        workspace.step(by: -1)
        settle()
        shot("3-після-повернення")
        expect(isWhole(), "повернулися на 3 — наближення не ввімкнулося", fault: "після повернення наближення ввімкнулося само")

        // 4. Сховали наближену сторінку й показали знову — ціла.
        zoomIn()
        workspace.hideCurrentPage()
        settle(0.3)
        workspace.showCurrentPage()
        settle()
        expect(isWhole(), "сховали наближену й показали знову — ціла", fault: "після «Сховати» сторінка повернулася наближеною")

        // 5. Наближену сторінку перекрив вірш; повернули сторінку — ціла.
        zoomIn()
        go(.bible)
        if state.slide.mainText.isEmpty {
            lines.append("вірша для показу немає — крок із текстом поверх сторінки пропущено")
            go(.presentation)
        } else {
            state.showCurrent()
            settle(0.8)
            let textOver = state.media.screenSuppression.contains(.slideTookOver)
            go(.presentation)
            workspace.showCurrentPage()
            settle(0.8)
            expect(textOver && isWhole(), "вірш поверх наближеної, потім знову сторінка — ціла",
                   fault: textOver ? "після вірша сторінка повернулася наближеною" : "вірш не зайняв зал — крок не відбувся")
        }

        // 6. Наближення, зроблене на картинці, не переходить на сторінку
        //    презентації (у вкладок була окрема пам'ять «що показано»).
        workspace.showCurrentPage()
        settle()
        zoomIn()
        go(.pictures)
        pictures.open([pictureFile])
        pictures.selectPage(0)
        pictures.showCurrentPage()
        settle()
        expect(isWhole(), "після наближеної сторінки показали картинку — ціла", fault: "наближення перейшло зі сторінки на картинку")
        zoomIn()
        let pictureZoomed = focus.isOn && hallIsZoomed()
        go(.presentation)
        workspace.showCurrentPage()
        settle()
        expect(pictureZoomed && isWhole(), "наблизили картинку, повернули ту саму сторінку — ціла",
               fault: pictureZoomed ? "наближення перейшло з картинки на сторінку" : "картинка не наблизилася — крок не відбувся")

        // 7. Прибрали файл: той самий номер у списку — вже інша сторінка.
        workspace.selectPage(1)
        workspace.showCurrentPage()
        settle()
        zoomIn()
        workspace.model.removeDeck(at: 0)
        workspace.open([])
        workspace.selectPage(1)
        workspace.showCurrentPage()
        settle()
        expect(isWhole(), "прибрали перший файл, показали сторінку з тим самим номером у списку — ціла",
               fault: "наближення лишилося на іншій сторінці з тим самим номером")

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: ", ")))]
    }

    /// Кнопки тону правлять виділену в списку фонограму, а не ту, що грає.
    private static func toneOfSelectedCheck(state: AppState) -> [Check] {
        let area = "Фонограма"
        let name = "Тон — лише вибраній фонограмі"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("slovo-тон-\(UUID().uuidString)")
        let other = folder.appendingPathComponent("2")
        let third = folder.appendingPathComponent("3")
        for item in [folder, other, third] {
            try? FileManager.default.createDirectory(at: item, withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: folder) }
        guard let one = makeWave(seconds: 4, in: folder), let two = makeWave(seconds: 4, in: other),
              let three = makeWave(seconds: 4, in: third) else {
            return [Check(area: area, name: name, status: .skipped, detail: "пробні фонограми не зібралися")]
        }
        let backing = state.backing
        let wasList = backing.playlist, wasVolume = backing.volume
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 260),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let bar = NativeBackingTrackBar(player: backing)
        bar.frame = NSRect(x: 0, y: 0, width: 1000, height: 260)
        window.contentView = bar
        defer {
            for item in [one, two, three] { backing.setPitch(0, of: item) }
            backing.close()
            backing.putBackPlaylist(wasList)
            backing.volume = wasVolume
            window.contentView = nil
        }
        backing.close()
        backing.putBackPlaylist([])
        backing.addToPlaylist([one, two, three])
        backing.volume = 0.05
        backing.openFromPlaylist(at: 0)
        backing.play()
        wait(untilTrue: { backing.isPlaying }, seconds: 2)

        var faults: [String] = []
        var lines: [String] = []

        // Грає перша; виділили другу й двічі опустили їй тон.
        bar.selectForCheck(1)
        bar.toneDown.performClick(nil)
        bar.toneDown.performClick(nil)
        let playingUntouched = backing.pitchTones == 0 && backing.appliedPitchCents == 0
        let secondLowered = backing.pitch(of: two) == -1
        let labelShowsSecond = bar.toneLabel.title.contains("1")
        lines.append("грає перша, другій −1: звук першої не змінився — \(playingUntouched ? "так" : "НІ") "
                     + "(\(Int(backing.appliedPitchCents)) центів); за другою записано \(backing.pitch(of: two)); напис «\(bar.toneLabel.title)»")
        if !playingUntouched { faults.append("змінився тон тієї, що грає") }
        if !secondLowered { faults.append("тон не записався за вибраною") }
        if !labelShowsSecond { faults.append("напис не показує тон вибраної") }

        // Третьої не чіпали.
        let thirdClean = backing.pitch(of: three) == 0
        if !thirdClean { faults.append("зачепило третю") }

        // Відкрили другу — її тон став у звук; третю — рівний; першу — рівний.
        backing.openFromPlaylist(at: 1)
        let secondSounds = backing.pitchTones == -1 && backing.appliedPitchCents == -200
        backing.openFromPlaylist(at: 2)
        let thirdSounds = backing.pitchTones == 0 && backing.appliedPitchCents == 0
        backing.openFromPlaylist(at: 0)
        let firstSounds = backing.pitchTones == 0 && backing.appliedPitchCents == 0
        lines.append("відкрили другу — −200 центів: \(secondSounds ? "так" : "НІ"); третя й перша рівні: \(thirdSounds && firstSounds ? "так" : "НІ")")
        if !secondSounds { faults.append("тон другої не став у звук") }
        if !(thirdSounds && firstSounds) { faults.append("тон другої перейшов на інші") }

        // Нічого не виділено — кнопки правлять відкриту, як і раніше.
        bar.selectForCheck(nil)
        bar.toneUp.performClick(nil)
        let openRaised = backing.pitchTones == 0.5 && backing.appliedPitchCents == 100 && backing.pitch(of: two) == -1
        lines.append("без виділення кнопка править відкриту (+0,5), друга лишилась −1: \(openRaised ? "так" : "НІ")")
        if !openRaised { faults.append("без виділення кнопка не править відкриту") }
        backing.stop()

        // Фонограма, яку macOS сама не грає: програвач відкриває її
        // перетворену копію, а тон має триматися за файлом зі списку.
        lines.append(convertedToneSteps(backing: backing, bar: bar, wave: one, plain: three, folder: folder, faults: &faults))

        return [Check(area: area, name: name, status: faults.isEmpty ? .ok : .failed,
                      detail: lines.joined(separator: "; ") + (faults.isEmpty ? "" : " — НЕ ТАК: " + faults.joined(separator: ", ")))]
    }

    /// Кроки з перетвореною фонограмою. Повертає рядок для звіту.
    private static func convertedToneSteps(backing: BackingTrackPlayer, bar: NativeBackingTrackBar,
                                           wave: URL, plain: URL, folder: URL, faults: inout [String]) -> String {
        guard let ffmpeg = YouTubeResolver.ffmpeg else { return "перетворена фонограма: ffmpeg немає — кроки пропущено" }
        let odd = folder.appendingPathComponent("чужий формат.wma")
        let task = Process()
        task.executableURL = ffmpeg
        task.arguments = ["-nostdin", "-y", "-i", wave.path, "-c:a", "wmav2", odd.path]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run(); task.waitUntilExit() } catch { return "перетворена фонограма: ffmpeg не запустився — кроки пропущено" }
        guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: odd.path) else {
            return "перетворена фонограма: пробний WMA не зібрався — кроки пропущено"
        }
        var copy: URL?
        defer {
            backing.setPitch(0, of: odd)
            if let copy, copy != odd { try? FileManager.default.removeItem(at: copy) }
        }
        var notes: [String] = []
        func expect(_ good: Bool, _ what: String, fault: String) {
            notes.append("\(what): \(good ? "так" : "НІ")")
            if !good { faults.append(fault) }
        }

        backing.close()
        backing.putBackPlaylist([])
        backing.addToPlaylist([plain, odd])
        backing.openFromPlaylist(at: 0)

        // Тон ставимо ще не відкритій і ще не перетвореній.
        bar.selectForCheck(1)
        bar.toneDown.performClick(nil)
        bar.toneDown.performClick(nil)
        expect(backing.pitch(of: odd) == -1 && backing.appliedPitchCents == 0,
               "чужому формату до відкриття −1, звук відкритої не змінився", fault: "тон не записався за ще не відкритим чужим форматом")

        // Відкрили: грає копія, тон — той, що ставили файлові зі списку.
        backing.openFromPlaylist(at: 1)
        copy = backing.url
        let playsCopy = backing.url != nil && backing.url != odd
        expect(playsCopy && backing.pitchTones == -1 && backing.appliedPitchCents == -200,
               "відкрили — грає перетворена копія з тоном −200 центів",
               fault: playsCopy ? "тон, поставлений до відкриття, не став у звук перетвореної" : "чужий формат не відкрився копією")
        let rows = backing.playlist.map(\.lastPathComponent).joined(separator: " | ")
        notes.append("рядки списку після відкриття: \(backing.playlist.count) [\(rows)], відкрито пункт \(backing.playlistIndex.map { String($0 + 1) } ?? "—")")

        // Змінили тон відкритій — запис той самий і в файла зі списку, і в копії.
        bar.selectForCheck(nil)
        bar.toneUp.performClick(nil)
        let liveOK = backing.pitchTones == -0.5 && backing.appliedPitchCents == -100
        backing.openFromPlaylist(at: 0)
        let plainClean = backing.pitchTones == 0 && backing.appliedPitchCents == 0
        let bothAgree = backing.pitch(of: odd) == -0.5 && (copy.map { backing.pitch(of: $0) == -0.5 } ?? false)
        expect(liveOK && plainClean && bothAgree,
               "підняли відкритій на 0,5 — за файлом і за копією −0,5, сусідня рівна",
               fault: "тон перетвореної розійшовся між файлом зі списку і копією")

        // Копію відкрили напряму (її рядок теж буває у списку) — той самий тон.
        if let copy {
            backing.open(copy)
            expect(backing.pitchTones == -0.5 && backing.appliedPitchCents == -100,
                   "копію відкрили напряму — той самий тон", fault: "у копії, відкритої напряму, інший тон")
            backing.open(plain)
        }

        // Повернули на нуль невідкритій — і вона відкривається рівною.
        if let row = backing.playlist.firstIndex(of: odd) {
            bar.selectForCheck(row)
            bar.toneLabel.performClick(nil)
            backing.openFromPlaylist(at: row)
            expect(backing.pitchTones == 0 && backing.appliedPitchCents == 0,
                   "повернули на нуль невідкритій — відкрилася рівною", fault: "скинутий тон перетвореної ожив при відкритті")
        }
        backing.stop()
        return "перетворена фонограма — " + notes.joined(separator: "; ")
    }
}
