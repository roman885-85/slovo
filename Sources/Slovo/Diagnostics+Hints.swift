import AppKit
import SlovoCore

/// Підказки й довідка.
///
/// Власник: «добавь подсказки и помощь в программу (на украинском и
/// английском)». Кнопка без підказки глазами не знаходиться: вона просто
/// мовчить, коли на неї наводять мишу. Тому розділ обходить головне вікно в
/// кожному режимі й перелічує елементи керування без підказки, а підказки,
/// що лишилися російськими в українському чи англійському інтерфейсі, —
/// окремо.
extension Diagnostics {

    static func hintsSection(state: AppState) -> [Check] {
        var checks: [Check] = []
        guard let root = NativeMainWindowController.shared.root else {
            return [Check(area: "Підказки", name: "Елементи керування мають підказки",
                          status: .skipped, detail: "головного вікна немає")]
        }
        let wasMode = state.mode
        let wasLanguage = state.languageCode
        for language in ["uk", "en"] {
            state.setLanguage(code: language)
            Signals.shared.send(.language)
            var bare: [String] = []
            var foreign: [String] = []
            var blank: [String] = []
            for mode in AppState.WorkMode.allCases {
                state.mode = mode
                Signals.shared.send(.mode)
                wait(untilTrue: { false }, seconds: 0.35)
                root.layoutSubtreeIfNeeded()
                for (control, label) in hintedControls(in: root) {
                    let place = "\(mode.rawValue): \(label)"
                    // Кнопка, на якій немає ні значка, ні слова: у випадного
                    // списку видно не його власний значок, а перший пункт меню.
                    if let popup = control as? NSPopUpButton {
                        let face = popup.pullsDown ? popup.itemArray.first : popup.selectedItem
                        if face?.image == nil, (face?.title ?? "").isEmpty, !blank.contains(place) { blank.append(place) }
                    } else if let button = control as? NSButton, !(control is NSSegmentedControl),
                              button.image == nil, button.title.isEmpty, button.attributedTitle.length == 0,
                              !blank.contains(place) {
                        blank.append(place)
                    }
                    guard let tip = control.toolTip, !tip.isEmpty else {
                        if !bare.contains(where: { $0.hasSuffix(": " + label) }) { bare.append(place) }
                        continue
                    }
                    if untranslated(tip, language: language),
                       !foreign.contains(where: { $0.hasSuffix("«\(tip)»") }) {
                        foreign.append("\(place) «\(tip)»")
                    }
                }
            }
            if language == "uk" {
                checks.append(Check(area: "Підказки", name: "Кнопки мають значок або підпис",
                                    status: blank.isEmpty ? .ok : .failed,
                                    detail: blank.isEmpty ? "у всіх режимах" : "порожні: " + blank.joined(separator: "; ")))
            }
            checks.append(Check(area: "Підказки", name: "Елементи керування мають підказки (\(language))",
                                status: bare.isEmpty ? .ok : .failed,
                                detail: bare.isEmpty ? "у всіх режимах" : "без підказки \(bare.count): " + bare.joined(separator: "; ")))
            checks.append(Check(area: "Підказки", name: "Підказки мовою інтерфейсу (\(language))",
                                status: foreign.isEmpty ? .ok : .failed,
                                detail: foreign.isEmpty ? "перекладено все" : "не перекладено \(foreign.count): " + foreign.joined(separator: "; ")))
        }
        state.mode = wasMode
        Signals.shared.send(.mode)
        checks.append(contentsOf: windowHints(state: state))
        state.setLanguage(code: wasLanguage)
        Signals.shared.send(.language)
        checks.append(contentsOf: helpChecks())
        return checks
    }

    /// Окремі вікна: параметри (кожна вкладка), ресурси, імпорт, пульт у
    /// браузері, програми для Android, кольори частин пісень. Мова зараз —
    /// англійська: так видно і відсутні підказки, і неперекладені.
    static func windowHints(state: AppState) -> [Check] {
        var bare: [String] = []
        var foreign: [String] = []
        func scan(_ title: String, open: () -> Void, close: (NSWindow) -> Void) {
            let before = Set(NSApp.windows.filter(\.isVisible).map { ObjectIdentifier($0) })
            open()
            wait(untilTrue: { NSApp.windows.contains { $0.isVisible && !before.contains(ObjectIdentifier($0)) } }, seconds: 3)
            guard let window = NSApp.windows.first(where: { $0.isVisible && !before.contains(ObjectIdentifier($0)) }),
                  let content = window.contentView else {
                bare.append("\(title): вікно не відкрилося")
                return
            }
            wait(untilTrue: { false }, seconds: 0.5)
            func collect(_ place: String) {
                content.layoutSubtreeIfNeeded()
                for (control, label) in hintedControls(in: content) {
                    // Кнопки «Ок», «Скасувати», «Закрити» пояснень не потребують.
                    if let button = control as? NSButton, ["\r", "\u{1b}"].contains(button.keyEquivalent) { continue }
                    let key = "\(place): \(label)"
                    guard let tip = control.toolTip, !tip.isEmpty else {
                        if !bare.contains(key) { bare.append(key) }
                        continue
                    }
                    if untranslated(tip, language: "en"), !foreign.contains(where: { $0.hasSuffix("«\(tip)»") }) {
                        foreign.append("\(key) «\(tip)»")
                    }
                }
            }
            let tabs = allSubviews(of: content).compactMap { $0 as? NSTabView }
            if let tabView = tabs.first {
                let chosen = tabView.selectedTabViewItem
                for item in tabView.tabViewItems {
                    tabView.selectTabViewItem(item)
                    wait(untilTrue: { false }, seconds: 0.2)
                    collect("\(title) → \(item.label)")
                }
                if let chosen { tabView.selectTabViewItem(chosen) }
            } else {
                collect(title)
            }
            close(window)
            wait(untilTrue: { false }, seconds: 0.25)
        }
        state.setLanguage(code: "en")
        Signals.shared.send(.language)
        scan("Параметри", open: { NativeSettingsWindow.shared.show(state: state) },
             close: { _ in NativeSettingsWindow.shared.discard() })
        scan("Ресурси", open: { NativeResourcesWindow.show(state: state) }, close: { $0.orderOut(nil) })
        scan("Імпорт", open: { ImportWizardWindow.show(state: state) }, close: { $0.orderOut(nil) })
        scan("Пульт у браузері", open: { NativeBrowserRemoteWindow.show(state: state) }, close: { $0.orderOut(nil) })
        scan("Android", open: { NativeAndroidAppsWindow.show() }, close: { $0.orderOut(nil) })
        scan("Кольори частин", open: { NativeSongColorsetWindow.show(state: state) }, close: { $0.performClose(nil) })
        return [
            Check(area: "Підказки", name: "Підказки в окремих вікнах",
                  status: bare.isEmpty ? .ok : .warning,
                  detail: bare.isEmpty ? "параметри, ресурси, імпорт, пульт, Android, кольори частин"
                      : "без підказки \(bare.count): " + bare.joined(separator: "; ")),
            Check(area: "Підказки", name: "Підказки в окремих вікнах англійською",
                  status: foreign.isEmpty ? .ok : .warning,
                  detail: foreign.isEmpty ? "перекладено все" : "не перекладено \(foreign.count): " + foreign.joined(separator: "; ")),
        ]
    }

    private static func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { allSubviews(of: $0) }
    }

    /// Вікно «Довідка»: файли в пакеті, однакові розділи обома мовами, живі
    /// посилання всередині, і сторінка справді відкривається.
    static func helpChecks() -> [Check] {
        var checks: [Check] = []
        guard let folder = NativeHelpWindow.folder else {
            return [Check(area: "Підказки", name: "Довідка в пакеті", status: .failed,
                          detail: "немає Contents/Resources/Help/index.html")]
        }
        func ids(_ code: String) -> (sections: [String], links: [String], text: String) {
            var text = (try? String(contentsOf: folder.appendingPathComponent("\(code).html"), encoding: .utf8)) ?? ""
            // Коментар на початку файла сам згадує `<section id="…">` — його не рахуємо.
            while let open = text.range(of: "<!--"), let close = text.range(of: "-->", range: open.upperBound..<text.endIndex) {
                text.removeSubrange(open.lowerBound..<close.upperBound)
            }
            func all(_ pattern: String) -> [String] {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
                return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
                    Range($0.range(at: 1), in: text).map { String(text[$0]) }
                }
            }
            return (all("<section id=\"([^\"]+)\""), all("href=\"#([^\"]+)\""), text)
        }
        let uk = ids("uk"), en = ids("en")
        let sameSections = !uk.sections.isEmpty && uk.sections == en.sections
        let deadLinks = (uk.links.filter { !uk.sections.contains($0) }.map { "uk #\($0)" })
            + (en.links.filter { !en.sections.contains($0) }.map { "en #\($0)" })
        checks.append(Check(area: "Підказки", name: "Довідка українською й англійською",
                            status: sameSections && deadLinks.isEmpty ? .ok : .failed,
                            detail: "розділів uk \(uk.sections.count), en \(en.sections.count)"
                                + (sameSections ? ", ті самі" : " — різні: \(Set(uk.sections).symmetricDifference(en.sections).sorted())")
                                + (deadLinks.isEmpty ? "; внутрішні посилання ведуть на розділи" : "; мертві посилання: " + deadLinks.joined(separator: ", "))))

        // Англійська довідка без кирилиці — крім назви програми й шляхів.
        let allowed = ["Слово", "Слова", "Язык", "Українська", "Русский", "Документація", "ЗАПУСК"]
        var english = en.text
        for word in allowed { english = english.replacingOccurrences(of: word, with: "") }
        let cyrillic = english.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        checks.append(Check(area: "Підказки", name: "Англійська довідка без кирилиці",
                            status: cyrillic ? .failed : .ok,
                            detail: cyrillic ? "у тексті лишилися українські чи російські слова" : "лише назва програми"))

        // Сторінка відкривається: зміст зібрався, розділ за запитом знайдено.
        let help = NativeHelpWindow.shared
        help.open(topic: "show")
        wait(untilTrue: { help.isLoaded }, seconds: 8)
        var info: [String: Any] = [:]
        var answered = false
        help.evaluate("JSON.stringify(Object.assign(window.slovoHelpInfo(), {top: document.querySelector('#toc a.on') ? document.querySelector('#toc a.on').dataset.id : ''}))") { value in
            if let text = value as? String, let data = text.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { info = object }
            answered = true
        }
        wait(untilTrue: { answered }, seconds: 5)
        var shot = false
        var shotDone = false
        help.snapshot(to: "slovo-довідка-uk.png") { shot = $0; shotDone = true }
        wait(untilTrue: { shotDone }, seconds: 5)
        // Розділ «Якщо щось не так» обома мовами — його знімки йдуть в
        // інструкцію із запуску на GitHub.
        for (script, file) in [("openTopic('trouble'); 1", "slovo-довідка-uk-trouble.png"),
                               ("document.querySelector('#langs button[data-l=en]').click(); openTopic('trouble'); 1",
                                "slovo-довідка-en-trouble.png")] {
            var done = false
            help.evaluate(script) { _ in done = true }
            wait(untilTrue: { done }, seconds: 5)
            wait(untilTrue: { false }, seconds: 0.3)
            shotDone = false
            help.snapshot(to: file) { _ in shotDone = true }
            wait(untilTrue: { shotDone }, seconds: 5)
        }
        help.close()
        let count = uk.sections.count
        let ok = help.isLoaded && (info["uk"] as? Int) == count && (info["en"] as? Int) == count
            && (info["toc"] as? Int) == count
        checks.append(Check(area: "Підказки", name: "Вікно «Довідка» відкривається",
                            status: ok ? .ok : .failed,
                            detail: "завантажено: \(help.isLoaded ? "так" : "ні"); мова \(info["lang"] ?? "?"), "
                                + "у змісті \(info["toc"] ?? "?") з \(count), відкрито розділ «\(info["top"] ?? "?")»"
                                + (shot ? "; знімки ~/Library/Logs/slovo-довідка-*.png" : "")))
        return checks
    }

    /// Видимі елементи, яким належить мати підказку: кнопки, перемикачі,
    /// списки вибору, повзунки. Підписи й поля з заповнювачем — ні.
    static func hintedControls(in root: NSView) -> [(NSView, String)] {
        var found: [(NSView, String)] = []
        func visible(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let item = current {
                if item.isHidden || item.alphaValue < 0.01 { return false }
                current = item.superview
            }
            return view.frame.width > 2 && view.frame.height > 2 && view.window != nil
        }
        func walk(_ view: NSView) {
            guard !view.isHidden else { return }
            if let segmented = view as? NSSegmentedControl {
                if visible(segmented) {
                    let titles = (0..<segmented.segmentCount).map { segmented.label(forSegment: $0) ?? "" }
                    found.append((segmented, "перемикач [\(titles.joined(separator: "|"))]"))
                }
            } else if let popup = view as? NSPopUpButton {
                if visible(popup) { found.append((popup, "список «\(popup.titleOfSelectedItem ?? "")»")) }
            } else if let button = view as? NSButton {
                if visible(button), button.isBordered || button.image != nil || button.title.isEmpty == false {
                    let name = button.title.isEmpty
                        ? (button.image?.accessibilityDescription ?? "значок") : button.title
                    found.append((button, "\(type(of: button)) «\(name)» у \(type(of: button.superview!))"))
                }
            } else if let slider = view as? NSSlider {
                if visible(slider) { found.append((slider, "повзунок у \(type(of: slider.superview!))")) }
            } else if let stepper = view as? NSStepper {
                if visible(stepper) { found.append((stepper, "лічильник")) }
            }
            // Вміст списків (рядки таблиць) — не елементи вікна, а дані.
            if view is NSTableView || view is NSOutlineView || view is NSCollectionView { return }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return found
    }

    /// Підказка не мовою інтерфейсу: в українському — суто російські літери,
    /// в англійському — будь-яка кирилиця.
    static func untranslated(_ text: String, language: String) -> Bool {
        switch language {
        case "en", "de": return text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        case "uk":
            // Російський рядок, для якого в словнику є український переклад, —
            // теж неперекладений, хоч суто російських літер у ньому й немає.
            if let own = OurWords.builtIn(text, language: "uk"), own != text { return true }
            return text.contains { "ыэъёЫЭЪЁ".contains($0) }
        default: return false
        }
    }
}
