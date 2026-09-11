import AppKit
import UniformTypeIdentifiers
import SlovoCore

// MARK: - Наборы фильтров диалога открытия

/// Выпадающий список наборов фильтров для «Открытие медиафайлов» (16.1).
///
/// `NSOpenPanel` своего списка типов не показывает, поэтому кладём его в
/// `accessoryView`. Сам вид и есть приёмник действия: `NSControl.target`
/// хранится слабой ссылкой, и отдельный объект-посредник система успела бы
/// освободить прямо во время работы диалога.
final class MediaFilterChooser: NSView {

    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private weak var panel: NSOpenPanel?
    private let filters: MediaFileFilters

    init(panel: NSOpenPanel, filters: MediaFileFilters, captions: [String]) {
        self.panel = panel
        self.filters = filters
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 34))

        popup.addItems(withTitles: captions)
        popup.target = self
        popup.action = #selector(changed(_:))
        popup.translatesAutoresizingMaskIntoConstraints = false

        addSubview(popup)
        NSLayoutConstraint.activate([
            popup.centerXAnchor.constraint(equalTo: centerXAnchor),
            popup.centerYAnchor.constraint(equalTo: centerYAnchor),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    @objc private func changed(_ sender: NSPopUpButton) {
        apply(MediaFileFilters.FilterGroup(rawValue: sender.indexOfSelectedItem) ?? .media)
    }

    func apply(_ group: MediaFileFilters.FilterGroup) {
        popup.selectItem(at: group.rawValue)

        let extensions = filters.extensions(in: group)
        // «Все файлы» — пустой список типов: диалог перестаёт что-либо
        // отсеивать, и открыть можно файл с любым расширением. Именно этого
        // варианта в панели и не хватало.
        let types = extensions.compactMap { UTType(filenameExtension: $0) }
        panel?.allowedContentTypes = group == .any ? [] : types
        // Часть расширений оригинала macOS не знает по имени; флаг оставляем,
        // чтобы такие файлы не оказались недоступными.
        panel?.allowsOtherFileTypes = true
        panel?.validateVisibleColumns()
    }
}
