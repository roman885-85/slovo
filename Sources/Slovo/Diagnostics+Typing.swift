import AppKit
import SlovoCore

/// Замечания владельца: «поиск по песням не работает, вводится только один
/// первый символ», «в песнях поиск по тексту также вводится только первый
/// символ», «в строке поиска не видно положение для ввода и редактирования
/// текста (вертикальная полоска положения)».
///
/// Печатаем в каждое поле ввода по букве тем же путём, каким идёт клавиатура:
/// через редактор поля. После каждой буквы поле обязано остаться в фокусе, а
/// текст — дорасти; курсор обязан быть виден на заливке поля.
extension Diagnostics {

    static func typingSection(state: AppState) -> [Check] {
        let area = "Введення"
        let wasMode = state.mode
        defer { state.mode = wasMode; settleTyping() }

        var checks: [Check] = []
        state.mode = .bible
        // Відкриті результати пошуку ховають стовпці книг, розділів і віршів
        // разом із їхніми полями — а після інших розділів перевірки пошук
        // буває відкритий.
        state.searchQuery = ""
        settleTyping()
        let bible = NativeBibleWorkspace.shared
        var bibleFields: [(String, NativeQuickField?)] = [
            ("Біблія · пошук", bible.strip?.searchField),
            ("Біблія · адреса", bible.strip?.addressField),
            ("Біблія · книга", bible.bookColumn?.quick),
            ("Біблія · розділ", bible.chapterColumn?.quick),
            ("Біблія · вірш", bible.verseColumn?.quick),
        ]
        for (name, field) in bibleFields {
            checks.append(typeCheck(area: area, name: name, field: field, text: "Івн"))
        }
        bibleFields.removeAll()

        checks.append(caretCheck(area: area, field: bible.strip?.searchField))

        state.mode = .songs
        settleTyping()
        let songs = NativeSongsWorkspace.shared
        checks.append(typeCheck(area: area, name: "Пісні · швидкий вибір пісні", field: songs.songQuickField, text: "слав"))
        checks.append(typeCheck(area: area, name: "Пісні · пошук частини за текстом", field: songs.partQuickField, text: "бог"))
        return checks
    }

    private static func settleTyping() {
        for _ in 0..<4 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    }

    private static func typeCheck(area: String, name: String, field: NativeQuickField?, text: String) -> Check {
        let title = "\(name): набирається все слово, курсор видно"
        guard let field, let window = field.window else {
            return Check(area: area, name: title, status: .skipped, detail: "поля немає у вікні")
        }
        guard !field.isHiddenOrHasHiddenAncestor else {
            return Check(area: area, name: title, status: .skipped, detail: "поле зараз сховане (не на екрані)")
        }
        field.text = ""
        field.focus()
        settleTyping()
        var steps: [String] = []
        var faults: [String] = []
        var typed = ""
        for letter in text {
            guard let editor = window.firstResponder as? NSTextView, field.isFocused else {
                faults.append("перед «\(letter)» поле вже без фокуса (фокус у \(type(of: window.firstResponder as Any)))")
                break
            }
            editor.insertText(String(letter), replacementRange: NSRange(location: NSNotFound, length: 0))
            typed.append(letter)
            settleTyping()
            steps.append("«\(field.text)»")
            if field.text != typed {
                faults.append("після «\(letter)» у полі «\(field.text)», а набрано «\(typed)»")
                break
            }
        }

        // Курсор: колір проти заливки поля й місце під нього.
        var caret = ""
        if let editor = window.firstResponder as? NSTextView, field.isFocused {
            let fill = field.activeFill.usingColorSpace(.sRGB) ?? .white
            let point = editor.insertionPointColor.usingColorSpace(.sRGB) ?? .black
            let contrast = luminanceContrast(fill, point)
            let line = ceil((field.editorField.font?.ascender ?? 9) - (field.editorField.font?.descender ?? -3))
            let height = field.editorField.frame.height
            caret = String(format: "контраст курсора %.1f:1, висота поля %.0f при рядку %.0f", contrast, height, line)
            if contrast < 3 { faults.append("курсор зливається з заливкою поля (\(caret))") }
            if height + 0.5 < line { faults.append("поле нижче за рядок тексту — курсор обрізано (\(caret))") }
        }
        field.text = ""
        window.makeFirstResponder(nil)
        let detail = steps.joined(separator: " → ") + (caret.isEmpty ? "" : "; " + caret)
        guard faults.isEmpty else {
            return Check(area: area, name: title, status: .failed, detail: faults.joined(separator: "; ") + ". " + detail)
        }
        return Check(area: area, name: title, status: .ok, detail: detail)
    }

    /// Курсор ввода: где он живёт и виден ли.
    ///
    /// На macOS 14+ мигающую палочку рисует отдельный вид
    /// `NSTextInsertionIndicator` внутри редактора поля. Сравниваем с обычным
    /// полем в чистом окне: если там палочка есть, а у нас нет — дело в наших
    /// видах, а не в системе.
    private static func caretCheck(area: String, field: NativeQuickField?) -> Check {
        let name = "Курсор уводу видно в полі"
        guard let field, let window = field.window else {
            return Check(area: area, name: name, status: .skipped, detail: "поля немає")
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<6 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        // Курсор блимає лише в ключовому вікні активної програми. Поки прогін
        // іде, фокус може забрати термінал — тоді міряти нічого.
        guard NSApp.isActive, window.isKeyWindow else {
            return Check(area: area, name: name, status: .skipped,
                         detail: "вікно не ключове (фокус в іншій програмі) — курсор не міряли")
        }
        field.text = ""
        field.focus()
        if let editor = window.firstResponder as? NSTextView {
            editor.selectAll(nil)
            editor.deleteBackward(nil)
            editor.insertText("Ів", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        for _ in 0..<12 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        var ours = describeCaret(in: window)
        // Точки, відмінні від заливки, по вісьмох кадрах: текст сталий, курсор
        // блимає — і число «дихає». Не дихає — курсора немає.
        var counts: [Int] = []
        let drawsBefore = field.drawCount
        for _ in 0..<8 {
            for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            counts.append(darkPixels(in: field.editorField, of: window))
        }
        let blinks = Set(counts).count > 1
        ours = (blinks, ours.text + "; точок по кадрах \(counts)" + (blinks ? " — блимає" : " — не блимає")
                + "; перемальовувань поля за цей час: \(field.drawCount - drawsBefore)")
        // Для знімка ззовні: де поле на екрані (верхній лівий кут, як у
        // `screencapture -R`), і кілька секунд тримаємо в ньому курсор.
        if ProcessInfo.processInfo.environment["SLOVO_CARET_SHOT"] != nil, let screen = window.screen ?? NSScreen.main {
            let inWindow = field.convert(field.bounds, to: nil)
            let onScreen = window.convertToScreen(inWindow)
            let top = (NSScreen.screens.first?.frame.height ?? screen.frame.height) - onScreen.maxY
            print(String(format: "КУРСОР-ОБЛАСТЬ %.0f,%.0f,%.0f,%.0f", onScreen.minX - 20, top - 10,
                         onScreen.width + 40, onScreen.height + 20))
            fflush(stdout)
            for _ in 0..<80 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        }

        // Для сравнения — чистое окно с обычным полем.
        let probe = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 240, height: 60),
                             styleMask: [.titled], backing: .buffered, defer: false)
        let plain = NSTextField(frame: NSRect(x: 10, y: 20, width: 200, height: 22))
        probe.contentView?.addSubview(plain)
        probe.makeKeyAndOrderFront(nil)
        probe.makeFirstResponder(plain)
        for _ in 0..<12 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        let control = describeCaret(in: probe)
        probe.orderOut(nil)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(nil)

        let detail = "у нас: \(ours.text); у звичайному полі: \(control.text)"
        // Мірило одне — точки в полі «дихають». Порівняння зі звичайним полем
        // лишається в звіті довідкою.
        guard ours.visible else {
            return Check(area: area, name: name, status: .failed, detail: "курсор не блимає; " + detail)
        }
        return Check(area: area, name: name, status: .ok, detail: detail)
    }

    private static func describeCaret(in window: NSWindow) -> (visible: Bool, text: String) {
        let active = NSApp.isActive
        let key = window.isKeyWindow
        guard let editor = window.firstResponder as? NSTextView else {
            return (false, "активна \(active), ключове \(key), курсора немає (фокус у \(type(of: window.firstResponder as Any)))")
        }
        func indicators(in view: NSView) -> [NSView] {
            var found: [NSView] = []
            for child in view.subviews {
                if String(describing: type(of: child)).contains("Insertion") { found.append(child) }
                found += indicators(in: child)
            }
            return found
        }
        let marks = indicators(in: editor)
        let shown = marks.filter { !$0.isHiddenOrHasHiddenAncestor && $0.alphaValue > 0.01 && $0.frame.width > 0 }
        let parts = marks.map { mark -> String in
            let layer = mark.layer
            return String(format: "%@ прихований=%@ alpha=%.2f рамка=%.0f×%.0f шар=%@ opacity=%.2f",
                          String(describing: type(of: mark)),
                          mark.isHiddenOrHasHiddenAncestor ? "так" : "ні", mark.alphaValue,
                          mark.frame.width, mark.frame.height,
                          layer == nil ? "немає" : "є", Double(layer?.opacity ?? 0))
        }
        let text = "активна \(active), ключове \(key), редактор \(Int(editor.frame.width))×\(Int(editor.frame.height)), "
            + (marks.isEmpty ? "видів курсора 0" : parts.joined(separator: " | "))
        return (!shown.isEmpty && active && key, text)
    }

    private static func luminanceContrast(_ a: NSColor, _ b: NSColor) -> Double {
        func lum(_ c: NSColor) -> Double {
            func ch(_ v: CGFloat) -> Double {
                let x = Double(v)
                return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * ch(c.redComponent) + 0.7152 * ch(c.greenComponent) + 0.0722 * ch(c.blueComponent)
        }
        let l1 = lum(a), l2 = lum(b)
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }
}

/// Опыт: какое свойство поля прячет курсор. Только по запросу
/// (`SLOVO_CARET_SHOT`), в отчёт не входит.
///
/// Окно опыта стоит выше окна проектора: то поднимается при активации
/// программы и накрывало снимки чёрным. Текст — «ов», без букв, похожих
/// на палочку курсора.
extension Diagnostics {

    static func caretExperimentSection(state: AppState) -> [Check] {
        guard ProcessInfo.processInfo.environment["SLOVO_CARET_SHOT"] != nil else { return [] }
        let window = NSWindow(contentRect: NSRect(x: 300, y: 300, width: 320, height: 440),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "курсор"
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        let content = window.contentView!
        var variants: [(String, NSTextField)] = []

        func plain() -> NSTextField {
            NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        }
        func place(_ view: NSView, row: Int) {
            view.frame.origin = NSPoint(x: 20, y: 400 - CGFloat(row) * 50)
            content.addSubview(view)
        }
        let a = plain(); place(a, row: 0); variants.append(("A_звичайне", a))
        let b1 = plain(); b1.isBordered = false; place(b1, row: 1); variants.append(("B1_без_рамки", b1))
        let b2 = plain(); b2.drawsBackground = false; place(b2, row: 2); variants.append(("B2_без_фону", b2))
        let b3 = plain(); b3.focusRingType = .none; place(b3, row: 3); variants.append(("B3_без_кільця", b3))
        let b4 = plain(); b4.font = .systemFont(ofSize: 11); place(b4, row: 4); variants.append(("B4_кегль_11", b4))
        let b5 = plain(); b5.isBordered = false; b5.drawsBackground = false
        place(b5, row: 5); variants.append(("B5_без_рамки_і_фону", b5))
        let quick = NativeQuickField(frame: NSRect(x: 0, y: 0, width: 268, height: NativeQuickField.height))
        place(quick, row: 6); variants.append(("E_NativeQuickField", quick.editorField))
        let b6 = plain(); b6.isBordered = false; b6.drawsBackground = false
        b6.font = .systemFont(ofSize: 11); b6.cell?.usesSingleLineMode = true; b6.cell?.isScrollable = true
        place(b6, row: 7); variants.append(("B6_без_рамки_фону_кегль11", b6))

        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)
        for _ in 0..<20 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        for (name, field) in variants {
            window.makeFirstResponder(field)
            if let editor = window.firstResponder as? NSTextView {
                editor.insertText("ов", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            for _ in 0..<6 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
            // Знімаємо саме вікно (не екран) вісім разів і рахуємо темні точки в
            // полі: текст дає сталу кількість, курсор — додає й забирає. Різниця
            // між кадрами і є курсор, що блимає.
            let key = window.isKeyWindow && NSApp.isActive ? "так" : "ні"
            var counts: [Int] = []
            for _ in 0..<8 {
                for _ in 0..<3 { RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
                counts.append(darkPixels(in: field, of: window))
            }
            print("ДОСЛІД \(name) ключове=\(key) темних точок по кадрах: \(counts) — "
                  + (Set(counts).count > 1 ? "КУРСОР БЛИМАЄ" : "курсора не видно"))
            fflush(stdout)
        }
        window.orderOut(nil)
        return []
    }

    /// Скільки темних точок у прямокутнику поля на знімку вікна.
    static func darkPixels(in field: NSView, of window: NSWindow) -> Int {
        guard let image = CGWindowListCreateImage(.null, .optionIncludingWindow,
                                                  CGWindowID(window.windowNumber),
                                                  [.boundsIgnoreFraming, .bestResolution]),
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return -1 }
        let scale = Double(image.width) / Double(window.frame.width)
        let inWindow = field.convert(field.bounds, to: nil)   // від низу вікна
        let height = Double(window.frame.height)
        let x0 = Int((Double(inWindow.minX) + 2) * scale), x1 = Int((Double(inWindow.maxX) - 2) * scale)
        let y0 = Int((height - Double(inWindow.maxY)) * scale), y1 = Int((height - Double(inWindow.minY)) * scale)
        let row = image.bytesPerRow, bpp = image.bitsPerPixel / 8
        var dark = 0
        for y in max(0, y0)..<min(image.height, y1) {
            for x in max(0, x0)..<min(image.width, x1) {
                let p = y * row + x * bpp
                let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
                // Усе, що не біле й не світло-сіре: текст, курсор будь-якого кольору.
                if max(abs(r - g), abs(g - b), abs(r - b)) > 40 || r + g + b < 3 * 200 { dark += 1 }
            }
        }
        return dark
    }
}
