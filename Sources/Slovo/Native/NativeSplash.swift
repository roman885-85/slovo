import AppKit
import SlovoCore

/// Заставка при запуске — как у автора: пока читается библиотека, человек
/// видит имя программы и то, чем она сейчас занята, а не пустой экран.
///
/// Окно без рамки, поверх всех, гаснет само, когда главное окно готово.
@MainActor
enum NativeSplash {
    private static var window: NSWindow?
    /// Когда заставка появилась: раньше этого срока не гасим — владелец
    /// просил, чтобы её было видно, даже если библиотека прочиталась мигом.
    private static var shownAt: CFTimeInterval = 0
    private static let leastSeconds: CFTimeInterval = 4
    private static var caption: NSTextField?
    private static var bar: NSProgressIndicator?

    static func show() {
        guard window == nil, let screen = NSScreen.main else { return }
        let size = NSSize(width: 460, height: 260)
        let origin = NSPoint(x: screen.frame.midX - size.width / 2,
                             y: screen.frame.midY - size.height / 2)
        let window = NSWindow(contentRect: NSRect(origin: origin, size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.hasShadow = true
        window.ignoresMouseEvents = true

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = 18
        root.layer?.masksToBounds = true
        // Тёмная подложка — на ней имя читается и днём, и вечером.
        root.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.10, blue: 0.18, alpha: 1).cgColor

        let icon = NSImageView(frame: NSRect(x: size.width / 2 - 36, y: 158, width: 72, height: 72))
        // Значок беремо з самого пакета, а не тільки в системи. Після
        // перескладання програми система якийсь час віддає порожній значок
        // зі свого кешу — і на заставці не було логотипа зовсім.
        icon.image = Bundle.main.url(forResource: "Slovo", withExtension: "icns")
            .flatMap { NSImage(contentsOf: $0) } ?? NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        root.addSubview(icon)

        let name = NSTextField(labelWithString: OurWords.t("Слово"))
        name.font = .systemFont(ofSize: 34, weight: .semibold)
        name.textColor = .white
        name.alignment = .center
        name.frame = NSRect(x: 0, y: 112, width: size.width, height: 42)
        root.addSubview(name)

        let about = NSTextField(labelWithString:
            OurWords.t("Показ Библии, песен, медиа и презентаций на служении"))
        about.font = .systemFont(ofSize: 12)
        about.textColor = NSColor.white.withAlphaComponent(0.62)
        about.alignment = .center
        about.frame = NSRect(x: 16, y: 88, width: size.width - 32, height: 18)
        root.addSubview(about)

        let bar = NSProgressIndicator(frame: NSRect(x: 60, y: 62, width: size.width - 120, height: 6))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.controlSize = .small
        bar.startAnimation(nil)
        root.addSubview(bar)

        let caption = NSTextField(labelWithString: OurWords.t("Запускаю…"))
        caption.lineBreakMode = .byTruncatingTail
        caption.font = .systemFont(ofSize: 11)
        caption.textColor = NSColor.white.withAlphaComponent(0.75)
        caption.alignment = .center
        caption.frame = NSRect(x: 16, y: 34, width: size.width - 32, height: 16)
        root.addSubview(caption)

        let version = NSTextField(labelWithString:
            (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).map { "v" + $0 } ?? "")
        version.font = .systemFont(ofSize: 10)
        version.textColor = NSColor.white.withAlphaComponent(0.35)
        version.alignment = .center
        version.frame = NSRect(x: 16, y: 14, width: size.width - 32, height: 14)
        root.addSubview(version)

        window.contentView = root
        window.orderFrontRegardless()
        Self.window = window
        Self.caption = caption
        Self.bar = bar
        Self.shownAt = CACurrentMediaTime()
    }

    /// Что программа делает сейчас — та же надпись, что и в главном окне.
    static func say(_ text: String) {
        caption?.stringValue = OurWords.t(text)
    }

    static func hide() {
        guard let window else { return }
        // Ещё рано — досидим оставшееся и уйдём сами.
        let passed = CACurrentMediaTime() - shownAt
        if passed < leastSeconds {
            let wait = leastSeconds - passed
            shownAt = 0                     // второй раз откладывать незачем
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { hide() }
            return
        }
        bar?.stopAnimation(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            window.orderOut(nil)
            Self.window = nil
            Self.caption = nil
            Self.bar = nil
        }
    }

    /// Для самопроверки: показана ли заставка.
    static var isShown: Bool { window?.isVisible ?? false }
}
