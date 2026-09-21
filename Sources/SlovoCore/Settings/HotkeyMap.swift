import Foundation

/// Одне сполучення клавіш у записі старої програми: `Ctrl+Alt+B`, `F5`, `Esc`.
///
/// Зберігається розібраним, а не рядком, із двох причин: на вкладці
/// «Гарячі клавіші» сполучення ловиться з клавіатури і його треба порівнювати з
/// уже зайнятими (в оригіналі це повідомлення TextMessages21–23 «Комбінація …
/// зайнята в … Використати для нової функції?»), а меню застосунку потрібен
/// розкладений за модифікаторами вигляд.
public struct Hotkey: Codable, Hashable, Sendable {

    public var control: Bool
    public var alt: Bool
    public var shift: Bool
    /// Основна клавіша в записі оригіналу: `F5`, `Esc`, `B`, `Space`.
    public var key: String

    public init(control: Bool = false, alt: Bool = false, shift: Bool = false, key: String) {
        self.control = control
        self.alt = alt
        self.shift = shift
        self.key = key
    }

    /// Розбір рядка з `hotkeys.ini`. Порожній рядок — «клавішу не призначено»,
    /// і це законний стан: в оригіналі частина функцій без клавіші.
    public init?(text: String) {
        let parts = text.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }

        var control = false, alt = false, shift = false
        var key = ""
        for part in parts {
            switch part.lowercased() {
            case "ctrl", "control": control = true
            case "alt": alt = true
            case "shift": shift = true
            case "": continue
            default: key = Hotkey.canonicalKey(part)
            }
        }
        guard !key.isEmpty else { return nil }
        self.init(control: control, alt: alt, shift: shift, key: key)
    }

    /// Назад у запис оригіналу — порядок модифікаторів там завжди
    /// Ctrl, Alt, Shift, і файл має лишитися читабельним для старої програми.
    public var text: String {
        var parts: [String] = []
        if control { parts.append("Ctrl") }
        if alt { parts.append("Alt") }
        if shift { parts.append("Shift") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    /// Функціональна клавіша: `F5` → 5. Потрібна і меню, і перевірці набору.
    public var functionNumber: Int? {
        guard key.count >= 2, key.hasPrefix("F"), let number = Int(key.dropFirst()) else { return nil }
        return (1...20).contains(number) ? number : nil
    }

    /// Зводимо написання до того, в якому клавіші записані в `hotkeys.ini`:
    /// літери великі, `esc` → `Esc`, `f5` → `F5`.
    static func canonicalKey(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 1 { return trimmed.uppercased() }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("f"), Int(lower.dropFirst()) != nil { return "F" + lower.dropFirst() }
        let known = ["esc": "Esc", "escape": "Esc", "space": "Space", "enter": "Enter",
                     "return": "Enter", "tab": "Tab", "backspace": "BackSpace",
                     "ins": "Ins", "del": "Del", "home": "Home", "end": "End",
                     "pgup": "PgUp", "pgdn": "PgDn",
                     "up": "Up", "down": "Down", "left": "Left", "right": "Right"]
        return known[lower] ?? trimmed.prefix(1).uppercased() + trimmed.dropFirst()
    }
}

/// Функція, якій можна призначити клавішу.
///
/// Склад і порядок — ті самі, що на вкладці «Гарячі клавіші» оригіналу:
/// `iniKey` — ключ у `hotkeys.ini`, `captionKey` — підпис із форми
/// `SettingsForm` файла перекладу. Власних формулювань тут немає.
public struct HotkeyAction: Sendable, Hashable, Identifiable {
    public let iniKey: String
    public let captionKey: String
    public let fallback: String

    public var id: String { iniKey }

    public init(_ iniKey: String, _ captionKey: String, _ fallback: String) {
        self.iniKey = iniKey
        self.captionKey = captionKey
        self.fallback = fallback
    }

    /// Порядок — той, у якому функції стоять у двох стовпцях форми оригіналу,
    /// а не порядок номерів Label21…Label51.
    ///
    /// Перевірено за знімком працюючої програми (Docs/Окно-настроек.md) і за
    /// `hotkeys.ini` користувача: лівий стовпець іде Показати слайд, Сховати
    /// слайд, Пошук, Швидк. вибір, Фокус на План, Фокус на Вірші/Текст,
    /// Знімок екрана, Результ. пошуку, Спільний Фон. За номерами міток це 21, 22,
    /// 24, 23, 27, 25, 26, 28, 29 — тобто автор нумерував мітки не в тому
    /// порядку, в якому розставив їх на формі.
    ///
    /// Порядок важливий не лише для вкладки: за ним же `HotkeySets.serialized()`
    /// розкладає рядки в `hotkeys.ini`, який читають очима.
    public static let all: [HotkeyAction] = [
        HotkeyAction("ShowSlide",            "Label21", "Показать слайд:"),
        HotkeyAction("HideSlide",            "Label22", "Скрыть слайд:"),
        HotkeyAction("Search",               "Label24", "Поиск:"),
        HotkeyAction("FastInput",            "Label23", "Быстр. выбор:"),
        HotkeyAction("Plan",                 "Label27", "Фокус на План:"),
        HotkeyAction("MainWin",              "Label25", "Фокус на Стихи/Текст:"),
        HotkeyAction("ScreenShot",           "Label26", "Снимок экрана:"),
        HotkeyAction("FastSearchWindow",     "Label28", "Результ. поиска:"),
        HotkeyAction("ShowBackGrOnSlide",    "Label29", "Общий Фон:"),
        HotkeyAction("FastInputBook",        "Label31", "Быстрый выбор Книги/Песни:"),
        HotkeyAction("FastInputChapter",     "Label32", "Быстрый выбор Главы:"),
        HotkeyAction("FastInputVers",        "Label33", "Быстрый выбор Стиха или части Песни:"),
        HotkeyAction("ShowBlackScreen",      "Label44", "Затемнение экрана:"),
        HotkeyAction("ShowBlankSlide",       "Label45", "Показ. пустой слайд:"),
        HotkeyAction("ShowMediaPlayer",      "Label47", "Открыть Медиаплеер:"),
        HotkeyAction("MediaPlayerPlayPause", "Label48", "Медиаплеер Воспр./Пауза:"),
        HotkeyAction("OpenCommonBG",         "Label49", "Выбрать Общий фон:"),
        HotkeyAction("OpenSlideBG",          "Label50", "Выбрать фон Слайда:"),
        HotkeyAction("ReactionOnCtrlE",      "Label51", "Режим редакт./просмотр:"),
    ]
}

/// Уміст `hotkeys.ini`: кілька іменованих наборів клавіш.
///
/// Файл оригіналу — це не одна розкладка, а історія: `[VB Version 2.2]`,
/// `[VB Version 2.3]`, `[VB Version 2.4]`. Випадний список (36) на вкладці
/// «Гарячі клавіші» показує саме їх, тому читаємо всі, а не лише
/// останній.
public struct HotkeySets: Codable, Sendable, Hashable {

    /// Імена в тому порядку, в якому секції йдуть у файлі.
    public private(set) var order: [String]
    /// Ім'я набору → (ключ функції → запис сполучення).
    public private(set) var sets: [String: [String: String]]

    public init(order: [String] = [], sets: [String: [String: String]] = [:]) {
        self.order = order
        self.sets = sets
    }

    public init(text: String) {
        var order: [String] = []
        var sets: [String: [String: String]] = [:]
        var current = ""

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast())
                if sets[current] == nil { order.append(current); sets[current] = [:] }
                continue
            }
            guard !current.isEmpty, let eq = line.firstIndex(of: "=") else { continue }
            // Регістр ключів тут зберігаємо: назад у файл вони мають лягти
            // так само, як їх пише стара програма.
            let key = String(line[line.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            sets[current]?[key] = value
        }
        self.init(order: order, sets: sets)
    }

    public init(fileAt url: URL) throws {
        let data = try Data(contentsOf: url)
        let declared: String.Encoding? = String(data: data, encoding: .utf8) != nil ? .utf8 : nil
        self.init(text: CodePage.decode(data, declared: declared))
    }

    /// Набір, який треба показати при відкритті: останній у файлі — він же
    /// найновіший, і саме за ним працює свіжа версія оригіналу.
    public var preferredSetName: String? { order.last }

    public func hotkeys(inSet name: String) -> [String: Hotkey] {
        var result: [String: Hotkey] = [:]
        for (key, value) in sets[name] ?? [:] {
            guard let hotkey = Hotkey(text: value) else { continue }
            result[key] = hotkey
        }
        return result
    }

    public mutating func replace(setNamed name: String, with hotkeys: [String: Hotkey]) {
        if sets[name] == nil { order.append(name) }
        sets[name] = hotkeys.mapValues(\.text)
    }

    public mutating func remove(setNamed name: String) {
        sets.removeValue(forKey: name)
        order.removeAll { $0 == name }
    }

    /// Запис у форматі оригіналу — щоб файл лишився придатним і для нього.
    public func serialized() -> String {
        var lines: [String] = []
        for name in order {
            lines.append("[\(name)]")
            // Порядок рядків — як на вкладці налаштувань, а не як попало зі
            // словника: файл читають очима.
            for action in HotkeyAction.all {
                guard let value = sets[name]?[action.iniKey] else { continue }
                lines.append("\(action.iniKey)=\(value)")
            }
            for (key, value) in (sets[name] ?? [:]).sorted(by: { $0.key < $1.key })
            where !HotkeyAction.all.contains(where: { $0.iniKey == key }) {
                lines.append("\(key)=\(value)")
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    /// Розкладка поставки старої програми V2.5 — на випадок, коли файла поруч немає
    /// і кнопці (35) «За умовчанням» нема на що спертися.
    public static let factoryDefault = HotkeySets(
        order: ["VB Version 2.4"],
        sets: ["VB Version 2.4": [
            "ShowSlide": "F5",
            "HideSlide": "Esc",
            "Search": "F3",
            "FastInput": "F4",
            "Plan": "F2",
            "MainWin": "F6",
            "ScreenShot": "F11",
            "FastSearchWindow": "Ctrl+F3",
            "ShowBackGrOnSlide": "Ctrl+F9",
            "FastInputBook": "F7",
            "FastInputChapter": "F8",
            "FastInputVers": "F9",
            "ShowBlackScreen": "F12",
            "ShowBlankSlide": "Ctrl+F5",
            "ShowMediaPlayer": "Ctrl+M",
            "MediaPlayerPlayPause": "Ctrl+P",
            "OpenCommonBG": "Ctrl+B",
            "OpenSlideBG": "Ctrl+Alt+B",
            "ReactionOnCtrlE": "Ctrl+E",
        ]])

    /// `hotkeys.ini` лежить поруч із файлом налаштувань програми — у тій
    /// самій теці, що й `Slovo.ini`: особистій або в пакеті.
    public static func locateFile() -> URL? {
        guard let ini = IniSettings.locateConfig() else { return nil }
        let url = ini.deletingLastPathComponent().appendingPathComponent("hotkeys.ini")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Набори з файла програми, а якщо його немає — поставкова розкладка.
    public static func load() -> HotkeySets {
        guard let url = locateFile(), let loaded = try? HotkeySets(fileAt: url),
              !loaded.order.isEmpty else { return factoryDefault }
        return loaded
    }
}
