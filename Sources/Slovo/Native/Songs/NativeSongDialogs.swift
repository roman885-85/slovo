import AppKit
import SlovoCore

/// Вікна правки Пісенника і клавіші списку частин.
///
/// Форми переписано на AppKit разом з усією програмою: тримати заради
/// чотирьох вікон другий рушій нема чого, а підписи в них ті самі — з тих самих
/// ключів перекладу автора.
extension NativeSongsWorkspace {

    /// Показати або прибрати вікно правки услід за `model.sheet`.
    func applySheet() {
        guard let sheet = model.sheet else {
            sheetWindow?.close()
            return
        }
        guard sheetWindow?.sheetID != sheet.id else { return }
        sheetWindow?.close()
        guard let content = sheetBody(sheet) else { return }
        content.onClose = { [weak self] in self?.sheetWindow?.close() }
        let window = NativeSongSheetWindow(id: sheet.id, content: content) { [weak self] in
            self?.model.sheet = nil
            self?.sheetWindow = nil
            self?.bridge.sync()
        }
        sheetWindow = window
        window.show(over: NativeMainWindowController.shared.window)
    }

    /// Сам вміст вікна. Закриття йде двома шляхами: «Ок» і «Скасувати»
    /// всередині форми кличуть `dismiss`, а ми закриваємо вікно ще й за своїм
    /// приймачем — вікно правки не має лишитися висіти, якщо `dismiss`
    /// в окремому вікні до нас не дійде.
    private func sheetBody(_ sheet: SongEditorModel.Sheet) -> NativeSongSheets.Sheet? {
        switch sheet {
        case .bookAttributes(let editable):
            guard let book = model.book else { return nil }
            return NativeSongSheets.BookAttributes(
                captions: captions, editable: editable, book: book) { [weak self] title, short, publisher, date, comment, charset in
                    self?.model.applyBookAttributes(title: title, shortName: short,
                                                    publisher: publisher, revisionDate: date,
                                                    comment: comment, charset: charset)
                    self?.closeSheet()
                }

        case .songAttributes(let index, let editable):
            guard let book = model.book, book.songs.indices.contains(index) else { return nil }
            return NativeSongSheets.SongAttributes(
                captions: captions, editable: editable, palette: model.palette,
                song: book.songs[index]) { [weak self] mutate in
                    self?.model.applySongAttributes(at: index, mutate)
                    self?.closeSheet()
                }

        case .newSong:
            return NativeSongSheets.SongAttributes(
                captions: captions, editable: true, palette: model.palette,
                song: Song(index: 0, title: ""),
                heading: captions.message(9, "Создание песни")) { [weak self] mutate in
                    self?.model.createSong(mutate)
                    self?.closeSheet()
                }

        case .partEditor(let songIndex, let partIndex):
            guard let book = model.book, book.songs.indices.contains(songIndex) else { return nil }
            let song = book.songs[songIndex]
            let part = partIndex.flatMap { song.parts.indices.contains($0) ? song.parts[$0] : nil }
            return NativeSongSheets.PartSheet(
                captions: captions, songTitle: song.title, part: part) { [weak self] kind, text, align in
                    self?.model.applyPart(songAt: songIndex, partAt: partIndex,
                                          kind: kind, text: text, align: align)
                    self?.closeSheet()
                }

        case .copySongs:
            guard let book = model.book, let state else { return nil }
            return NativeSongSheets.CopySongs(
                captions: captions,
                sourceName: book.title.isEmpty ? model.bookID : book.title,
                songs: book.songs,
                destinations: state.songBooks.filter { $0.id != model.bookID }) { [weak self] indices, entry in
                    self?.model.copySongs(indices, into: entry)
                    self?.closeSheet()
                }
        }
    }

    private func closeSheet() {
        sheetWindow?.close()
    }

    /// «Скорочений» або «Повний» вигляд назви на вкладках (33).
    func setLongBookNames(_ long: Bool) {
        guard longBookNames != long else { return }
        longBookNames = long
        refreshTabs()
    }
}

/// Вікно правки Пісенника: вміст на SwiftUI, рама — своя.
///
/// Своя рама, а не аркуш SwiftUI, з простої причини: головне вікно тепер на
/// AppKit, і вішати на нього аркуш нема на що. Закриття ловиться трьома шляхами —
/// кнопка форми, Esc і хрестик рами, — щоб вікно правки не лишилося висіти
/// за жодного порядку подій.
@MainActor
final class NativeSongSheetWindow: NSObject, NSWindowDelegate {

    let sheetID: String
    private var window: NSWindow?
    private let onClose: () -> Void
    private var closing = false

    init(id: String, content: NativeSongSheets.Sheet, onClose: @escaping () -> Void) {
        self.sheetID = id
        self.onClose = onClose
        super.init()

        let host = content
        host.frame = NSRect(x: 0, y: 0, width: max(host.frame.width, 520),
                            height: max(host.frame.height, 360))
        let window = NativeSongSheetFrame(
            contentRect: host.frame,
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = ""
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.onCancel = { [weak self] in self?.close() }
        self.window = window
    }

    func show(over parent: NSWindow?) {
        guard let window else { return }
        if let parent {
            // Вікно правки ходить разом із головним: згорнули головне — пішло й воно.
            parent.addChildWindow(window, ordered: .above)
            window.setFrameOrigin(NSPoint(
                x: parent.frame.midX - window.frame.width / 2,
                y: parent.frame.midY - window.frame.height / 2))
        }
        window.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !closing, let window else { return }
        closing = true
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        self.window = nil
        onClose()
    }

    func windowWillClose(_ notification: Notification) { close() }
}

/// Рама вікна правки: Esc закриває, як «Скасувати» в оригіналі.
private final class NativeSongSheetFrame: NSWindow {
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Клавіші списку частин (5.3.9.2)

/// Ins, Shift+Ins, Del і Ctrl+Enter над списком «Текст».
///
/// Підписи кнопок панелі в автора прямо обіцяють ці клавіші: `TBNewBody`
/// «Создать новую часть песни (Ins)», `TBDelBody` «(Del)», `TBCopyBody`
/// «(Shift+Ins)», `TBChangeBody` «(Ctrl+Enter)». Обіцянку треба виконувати.
///
/// Ловиться локальним спостерігачем, а не пунктом меню: пункт із голим Del
/// забрав би клавішу в усього застосунку, і видаляти знак у полі швидкого
/// вибору стало б не можна. Спостерігач спершу дивиться, чи не друкує
/// людина, і мовчить, поки клавіатуру тримає редактор поля.
/// Коди клавіш з AppKit: `NSInsertFunctionKey`, `NSDeleteFunctionKey`,
/// `NSDeleteCharacter`. Знак береться `charactersIgnoringModifiers`, а не
/// кодом клавіші: в Ins і Del своїх кодів на маку немає.
private enum NativeSongKey {
    static let insert: UInt32 = 0xF727
    static let forwardDelete: UInt32 = 0xF728
    static let backspace: UInt32 = 0x7F
    static let carriageReturn: UInt32 = 0x0D
    static let enter: UInt32 = 0x03
}

@MainActor
final class NativeSongKeys {

    private weak var workspace: NativeSongsWorkspace?
    private var monitor: Any?

    init(workspace: NativeSongsWorkspace) {
        self.workspace = workspace
        // Спостерігач тримає робочу область слабко: вона тримає його самого,
        // і пряме посилання замкнуло б коло — жоден із двох не помер би.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak workspace] event in
            guard let workspace else { return event }
            return MainActor.assumeIsolated { workspace.handleKey(event) ? nil : event }
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

extension NativeSongsWorkspace {

    /// `true` — клавіша наша і далі її пускати не треба.
    func handleKey(_ event: NSEvent) -> Bool {
        guard state?.mode == .songs else { return false }
        guard let window = NativeMainWindowController.shared.window, window.isKeyWindow else { return false }
        // Людина друкує — не заважаємо. Перевіряємо саме редактор поля:
        // виділюваний текст теж текстовий вид, і за грубою перевіркою клацання
        // по ньому вимикало б клавіші.
        guard !(window.firstResponder is NSText) else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        // ⌘S — «Зберегти Пісенник»: в автора це Ctrl+S, на маку ⌘S.
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "s" {
            model.save()
            bridge.sync()
            return true
        }
        guard model.isEditing, model.sheet == nil else { return false }
        guard let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return false }

        switch (scalar, flags) {
        case (NativeSongKey.insert, []):
            model.addPart()
        case (NativeSongKey.insert, [.shift]):
            model.duplicatePart()
        // На маку клавіші Insert немає зовсім, а «Del» на ноутбуках — це
        // Backspace. Приймаємо обидва видалення: видалення частини все одно
        // питає підтвердження, тож промах не страшний.
        case (NativeSongKey.forwardDelete, []), (NativeSongKey.backspace, []):
            model.deletePart()
        case (NativeSongKey.carriageReturn, [.control]), (NativeSongKey.enter, [.control]):
            model.openPartEditor()
        default:
            return false
        }
        bridge.sync()
        return true
    }
}
