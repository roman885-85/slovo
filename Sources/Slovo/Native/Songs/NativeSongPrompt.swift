import AppKit
import UniformTypeIdentifiers
import SlovoCore

// MARK: - Запити і діалоги

/// Короткі модальні питання Пісенника.
///
/// В оригіналі це `MessageDlg` та `InputQuery` — маленькі вікна поверх
/// головного. SwiftUI такого не вміє, а `.alert` не дає трьох кнопок із полем
/// вводу, тому беремо `NSAlert`: він і виглядає як системний, і відповідає
/// одразу, а не через замикання, — так код операцій читається згори вниз.
@MainActor
enum SongPrompt {

    enum Answer { case yes, no, cancel }

    static func confirm(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: OurWords.t("Да"))
        alert.addButton(withTitle: OurWords.t("Нет"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Питання з трьома відповідями: «Так», «Ні» і «Скасувати». Такими в оригіналі
    /// задано і запит на збереження, і вибір варіанта експорту.
    static func threeWay(title: String, message: String, yes: String, no: String) -> Answer {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: yes)
        alert.addButton(withTitle: no)
        alert.addButton(withTitle: OurWords.t("Отменить"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:  return .yes
        case .alertSecondButtonReturn: return .no
        default:                       return .cancel
        }
    }

    static func input(title: String, message: String, value: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: OurWords.t("Ок"))
        alert.addButton(withTitle: OurWords.t("Отменить"))

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.stringValue = value
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return field.stringValue.trimmingCharacters(in: .whitespaces)
    }

    static func warn(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
    }

    static func info(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: OurWords.t("Закрыть"))
        alert.runModal()
    }

    static func saveFile(title: String, name: String, extensions: [String], directory: URL?) -> URL? {
        let panel = NSSavePanel()
        panel.title = title
        panel.nameFieldStringValue = name
        panel.canCreateDirectories = true
        panel.allowedContentTypes = types(extensions)
        if let directory { panel.directoryURL = directory }
        guard panel.runModal() == .OK, var url = panel.url else { return nil }
        // Користувач міг стерти розширення — без нього оригінал файл не
        // знайде, тому дописуємо самі.
        if let ext = extensions.first, url.pathExtension.lowercased() != ext {
            url = url.appendingPathExtension(ext)
        }
        return url
    }

    static func openFile(title: String, message: String, extensions: [String], allowsDirectories: Bool) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = message
        panel.canChooseFiles = true
        panel.canChooseDirectories = allowsDirectories
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = types(extensions)
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func types(_ extensions: [String]) -> [UTType] {
        extensions.compactMap { UTType(filenameExtension: $0) }
    }
}
