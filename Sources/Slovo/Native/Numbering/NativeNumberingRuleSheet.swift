import AppKit
import SlovoCore

/// Правка одного правила нумерации — отдельным окном.
///
/// Правим копию: пока окно открыто, в таблице должна оставаться прежняя
/// строка, а «Отменить» обязано её сохранить.
///
/// Состав полей «куда» зависит от вида правила: у сдвига это одно число со
/// знаком, у переноса — глава и первый стих, у точного соответствия — начало
/// и необязательный конец.
@MainActor
final class NativeNumberingRuleSheet: NSObject {

    private let state: AppState
    private let model: NumberingEditorModel
    private var draft: NumberingEditorModel.RuleDraft

    private let kind = NSPopUpButton(frame: .zero, pullsDown: false)
    private let book = NSPopUpButton(frame: .zero, pullsDown: false)
    private var fields: [String: NSTextField] = [:]
    private let preview = NSTextField(labelWithString: "")
    private let complaint = NSTextField(labelWithString: "")

    init(state: AppState, model: NumberingEditorModel, draft: NumberingEditorModel.RuleDraft) {
        self.state = state
        self.model = model
        self.draft = draft
        super.init()
    }

    func run() {
        let alert = NSAlert()
        alert.messageText = OurWords.t("Правило нумерации")
        alert.informativeText = NumberingEditorModel.standardTitle(draft.from) + " → "
            + NumberingEditorModel.standardTitle(draft.to)
        alert.accessoryView = body()
        alert.addButton(withTitle: state.vb("BBOk", form: "SongColorsetForm", "Ок"))
        alert.addButton(withTitle: state.vb("BBCancel", form: "SongColorsetForm", "Отменить"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        collect()
        // Ответ модели — слово об ошибке; `nil` значит «принято». Показываем
        // его, а не глотаем: правило с перепутанными краями молча не пишем.
        if let complaint = model.commit(draft) {
            let refusal = NSAlert()
            refusal.messageText = state.vb("TextMessages24", "Внимание")
            refusal.informativeText = complaint
            refusal.addButton(withTitle: state.vb("BBOk", "Ок"))
            refusal.runModal()
        }
    }

    // MARK: - Поля

    private func body() -> NSView {
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 214))

        kind.addItems(withTitles: NumberingRuleKind.allCases.map(NumberingEditorModel.kindTitle))
        if let index = NumberingRuleKind.allCases.firstIndex(of: draft.kind) {
            kind.selectItem(at: index)
        }
        kind.target = self
        kind.action = #selector(kindChanged)
        place(kind, x: 120, y: 186, width: 240, in: box)
        label(OurWords.t("Вид"), x: 0, y: 189, width: 112, in: box)

        book.addItems(withTitles: model.books.map { "\($0.name) (\($0.number))" })
        if let index = model.books.firstIndex(where: { $0.number == draft.book }) {
            book.selectItem(at: index)
        }
        book.target = self
        book.action = #selector(anyChanged)
        place(book, x: 120, y: 156, width: 240, in: box)
        label(OurWords.t("Книга"), x: 0, y: 159, width: 112, in: box)

        // «Откуда» — главы и стихи исходной нумерации.
        label(OurWords.t("Главы с"), x: 0, y: 129, width: 112, in: box)
        add("chapterBegin", value: draft.chapterBegin, x: 120, y: 126, in: box)
        label(OurWords.t("по"), x: 186, y: 129, width: 28, in: box)
        add("chapterEnd", value: draft.chapterEnd, x: 218, y: 126, in: box)
        label(OurWords.t("Стихи с"), x: 0, y: 99, width: 112, in: box)
        add("verseBegin", value: draft.verseBegin, x: 120, y: 96, in: box)
        label(OurWords.t("по"), x: 186, y: 99, width: 28, in: box)
        add("verseEnd", value: draft.verseEnd, x: 218, y: 96, in: box)
        label(OurWords.t("пустое поле — «не задано»"), x: 290, y: 99, width: 190, in: box)

        // «Куда» — состав полей зависит от вида правила.
        label(targetTitle, x: 0, y: 69, width: 112, in: box)
        add("chapterTo", value: draft.chapterTo, x: 120, y: 66, in: box)
        add("verseTo", value: draft.verseTo, x: 186, y: 66, in: box)
        add("chapterToEnd", value: draft.chapterToEnd, x: 252, y: 66, in: box)
        add("verseToEnd", value: draft.verseToEnd, x: 318, y: 66, in: box)

        preview.font = .systemFont(ofSize: 11)
        preview.textColor = .secondaryLabelColor
        preview.frame = NSRect(x: 0, y: 34, width: 480, height: 26)
        preview.lineBreakMode = .byTruncatingTail
        box.addSubview(preview)

        complaint.font = .systemFont(ofSize: 11)
        complaint.textColor = .systemRed
        complaint.frame = NSRect(x: 0, y: 6, width: 480, height: 18)
        box.addSubview(complaint)

        refreshPreview()
        return box
    }

    private var targetTitle: String {
        switch draft.kind {
        case .offsetChapter: return OurWords.t("Прибавить к главе")
        case .offsetVerse:   return OurWords.t("Прибавить к стиху")
        case .part:          return OurWords.t("Глава / первый стих")
        case .displaced:     return OurWords.t("Начало и конец")
        }
    }

    private func label(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat, in box: NSView) {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = width > 60 ? .right : .center
        label.frame = NSRect(x: x, y: y, width: width, height: 16)
        box.addSubview(label)
    }

    private func add(_ key: String, value: Int?, x: CGFloat, y: CGFloat, in box: NSView) {
        let field = NSTextField(string: value.map(String.init) ?? "")
        field.font = .systemFont(ofSize: 11)
        field.alignment = .right
        field.frame = NSRect(x: x, y: y, width: 56, height: 22)
        field.target = self
        field.action = #selector(anyChanged)
        fields[key] = field
        box.addSubview(field)
    }

    private func place(_ view: NSView, x: CGFloat, y: CGFloat, width: CGFloat, in box: NSView) {
        view.frame = NSRect(x: x, y: y, width: width, height: 24)
        box.addSubview(view)
    }

    // MARK: - Сбор и пример

    @objc private func kindChanged() {
        let kinds = NumberingRuleKind.allCases
        let index = max(0, min(kind.indexOfSelectedItem, kinds.count - 1))
        draft.kind = kinds[index]
        refreshPreview()
    }

    @objc private func anyChanged() {
        collect()
        refreshPreview()
    }

    private func collect() {
        let index = book.indexOfSelectedItem
        if model.books.indices.contains(index) { draft.book = model.books[index].number }
        draft.chapterBegin = number("chapterBegin") ?? draft.chapterBegin
        draft.chapterEnd = number("chapterEnd")
        draft.verseBegin = number("verseBegin")
        draft.verseEnd = number("verseEnd")
        draft.chapterTo = number("chapterTo")
        draft.verseTo = number("verseTo")
        draft.chapterToEnd = number("chapterToEnd")
        draft.verseToEnd = number("verseToEnd")
    }

    private func number(_ key: String) -> Int? {
        guard let text = fields[key]?.stringValue, !text.isEmpty else { return nil }
        return Int(text)
    }

    /// Живой пример: первый стих, который правило захватывает, и что из него
    /// получится. Считается на голых числах, к диску не ходит.
    private func refreshPreview() {
        collect()
        let rule = NumberingRule(from: draft.from, to: draft.to, kind: draft.kind, book: draft.book,
                                 chapterBegin: draft.chapterBegin, chapterEnd: draft.chapterEnd,
                                 verseBegin: draft.verseBegin, verseEnd: draft.verseEnd,
                                 chapterTo: draft.chapterTo, chapterToEnd: draft.chapterToEnd,
                                 verseTo: draft.verseTo, verseToEnd: draft.verseToEnd)
        let verse = draft.verseBegin ?? 1
        let answer = NumberingEditorModel.translate(rules: [rule], book: draft.book,
                                                    chapter: draft.chapterBegin, verses: [verse],
                                                    from: draft.from, to: draft.to)
        let name = model.bookName(draft.book)
        let tail = answer.spans
            .map { ReferenceFormat.position(chapter: $0.chapter, verses: $0.verses) }
            .joined(separator: ", ")
        preview.stringValue = answer.rules.isEmpty
            ? "\(name) \(draft.chapterBegin):\(verse) — " + OurWords.t("правило это место не захватывает")
            : "\(name) \(draft.chapterBegin):\(verse) → \(name) \(tail)"
    }
}
