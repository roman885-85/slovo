import AppKit
import SlovoCore

/// Окно «Стиль интерфейса программы» — раздел 7.2, на AppKit.
///
/// Оригинал предлагает здесь файлы `Styles/*.vsf`. Это темы Delphi VCL Styles:
/// упакованный набор растровых деталей окна Windows — рамок, полос прокрутки,
/// галочек, заголовков — плюс таблица цветов, которой VCL подменяет свою
/// отрисовку контролов. На macOS контролы рисует AppKit: другой набор частей,
/// другая геометрия, другие правила. Подставить туда картинки из `.vsf`
/// некуда, а нарисовать «похоже» значило бы получить не ту же тему, а её
/// подделку с чужими пропорциями и нечитаемым текстом. Поэтому здесь честный
/// набор оформлений системы, а имена стилей оригинала показаны отдельным
/// списком — чтобы было видно, что именно не переносится.
@MainActor
final class NativeInterfaceStyleView: NSView {

    private let state: AppState
    private let onClose: () -> Void
    private let interface = InterfaceSettings.shared

    private let heading = NSTextField(labelWithString: "")
    private let choice = NSStackView()
    private let originalsHeading = NSTextField(labelWithString: "")
    private let explanation = NSTextField(labelWithString: "")
    private let list = NSTextView()
    private let scroll = NSScrollView()
    private var closeButton: NSButton!

    init(state: AppState, onClose: @escaping () -> Void) {
        self.state = state
        self.onClose = onClose
        super.init(frame: NSRect(x: 0, y: 0, width: 460, height: 430))
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) не використовується") }

    override var isFlipped: Bool { true }

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        heading.stringValue = OurWords.t("Оформление программы")
        heading.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(heading)

        choice.orientation = .vertical
        choice.alignment = .leading
        choice.spacing = 4
        for option in InterfaceSettings.Appearance.allCases {
            let button = NSButton(radioButtonWithTitle: option.title,
                                  target: NativeForm.Trampoline.shared,
                                  action: #selector(NativeForm.Trampoline.fire(_:)))
            button.font = .systemFont(ofSize: 13)
            button.state = interface.appearance == option ? .on : .off
            NativeForm.Trampoline.shared.bind(button) { [weak self] in
                self?.interface.appearance = option
            }
            choice.addArrangedSubview(button)
        }
        addSubview(choice)

        originalsHeading.stringValue = OurWords.t("Стили оригинала")
        originalsHeading.font = .systemFont(ofSize: 12, weight: .semibold)
        addSubview(originalsHeading)

        explanation.stringValue = OurWords.t("Файлы Styles/*.vsf — темы Delphi VCL для Windows. Они состоят из "
            + "картинок деталей окон Windows, которых в macOS нет, поэтому применить их здесь нельзя.")
        explanation.font = .systemFont(ofSize: 11)
        explanation.textColor = .secondaryLabelColor
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 3
        addSubview(explanation)

        let names = InterfaceSettings.originalStyleNames(
            dataRoot: state.modulesFolder.deletingLastPathComponent())
        list.string = names.isEmpty ? OurWords.t("Папка Styles не найдена")
                                    : names.map { "🚫  " + $0 }.joined(separator: "\n")
        list.isEditable = false
        list.font = .systemFont(ofSize: 12)
        list.textColor = .secondaryLabelColor
        list.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        addSubview(scroll)

        closeButton = NativeForm.button(OurWords.t("Закрыть")) { [weak self] in self?.onClose() }
        closeButton.keyEquivalent = "\r"
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 14
        let width = bounds.width - gap * 2
        heading.frame = NSRect(x: gap, y: gap, width: width, height: 18)
        choice.frame = NSRect(x: gap, y: heading.frame.maxY + 6, width: width,
                              height: CGFloat(InterfaceSettings.Appearance.allCases.count) * 24)
        originalsHeading.frame = NSRect(x: gap, y: choice.frame.maxY + 12, width: width, height: 18)
        explanation.frame = NSRect(x: gap, y: originalsHeading.frame.maxY + 4, width: width, height: 44)
        scroll.frame = NSRect(x: gap, y: explanation.frame.maxY + 6, width: width,
                              height: max(0, bounds.height - explanation.frame.maxY - 54))
        closeButton.frame = NSRect(x: bounds.width - gap - 100, y: bounds.height - 36, width: 100, height: 24)
    }
}
