import AppKit
import SlovoCore

/// Поле тексту пісні з розфарбуванням ключових слів — на AppKit.
///
/// «Однако, если это ключевое слово, то программа его окрашивает в цвет,
/// указанный в настройках» (5.3.9.6). Набираючи текст цілком, оператор одразу
/// бачить, що програма зрозуміла як частину.
@MainActor
final class NativeSongLyricsView: NSScrollView, NSTextViewDelegate {

    private let editor = NSTextView()
    private let palette: SongChunkPalette
    /// Останній розфарбований текст: перефарбовувати той самий заново
    /// нема чого — розбір рядків іде в головному потоці.
    private var painted: String?
    var onChange: ((String) -> Void)?

    init(palette: SongChunkPalette, isEditable: Bool) {
        self.palette = palette
        super.init(frame: .zero)

        editor.delegate = self
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.allowsUndo = true
        editor.font = Self.bodyFont
        editor.textContainerInset = NSSize(width: 4, height: 4)
        editor.isEditable = isEditable
        editor.isSelectable = true
        // Перенос по ширині поля: рядки пісні довші за поле бувають рідко, а
        // горизонтальна прокрутка в цьому вікні лише заважає.
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true

        documentView = editor
        hasVerticalScroller = true
        borderType = .bezelBorder
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    var text: String {
        get { editor.string }
        set {
            guard editor.string != newValue else { return }
            let selection = editor.selectedRange()
            editor.string = newValue
            let bounded = min(selection.location, (newValue as NSString).length)
            editor.setSelectedRange(NSRange(location: bounded, length: 0))
            highlight()
        }
    }

    /// Вставити ключове слово з нового рядка — кнопка «Вставити ключ».
    func insert(_ keyword: String) {
        var value = editor.string
        if !value.isEmpty, !value.hasSuffix("\n") { value += "\n" }
        value += keyword + "\n"
        text = value
        onChange?(value)
    }

    func textDidChange(_ notification: Notification) {
        highlight()
        onChange?(editor.string)
    }

    static let bodyFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let headingFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)

    private func highlight() {
        guard let storage = editor.textStorage else { return }
        let source = editor.string
        guard painted != source else { return }
        painted = source

        let full = NSRange(location: 0, length: (source as NSString).length)
        storage.beginEditing()
        storage.setAttributes([.font: Self.bodyFont, .foregroundColor: NSColor.textColor], range: full)
        for line in SongTextMarkup.markup(of: source, palette: palette) {
            let range = NSRange(location: line.start, length: line.length)
            guard NSMaxRange(range) <= full.length else { continue }
            storage.addAttributes(attributes(for: line), range: range)
        }
        storage.endEditing()
    }

    private func attributes(for line: SongTextMarkup.Line) -> [NSAttributedString.Key: Any] {
        switch line.role {
        case .keywordHeading(let color):
            return [.font: Self.headingFont,
                    .foregroundColor: NSColor(srgbRed: color.red, green: color.green,
                                              blue: color.blue, alpha: 1)]
        case .heading:
            // «#» є, але слово незнайоме: назва частини своя, кольору для
            // неї в налаштуваннях немає — показуємо відмінністю від звичайного тексту,
            // але не кольором частини.
            return [.font: Self.headingFont, .foregroundColor: NSColor.secondaryLabelColor]
        case .parameter:
            return [.font: Self.bodyFont, .foregroundColor: NSColor.systemTeal]
        case .body:
            return [.font: Self.bodyFont, .foregroundColor: NSColor.textColor]
        }
    }
}
