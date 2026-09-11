import AppKit
import CoreAudio
import SlovoCore

// Служебная механика окна «Параметры»: координаты мониторов как их пишет
// оригинал, вспышка «Показать позицию», списки звуковых устройств и
// сетевых адресов. Видов здесь нет — только то, что окну нужно знать.

// MARK: - Координаты оригинала

/// Перевод координат между записью VisioBible и AppKit.
///
/// Руководство 6.1.1 (8): «Параметр X задает горизонтальное смещение верхней
/// левой точки выбранного монитора относительно верхней левой точки основного
/// монитора… а Y — вертикальное смещение». То есть у оригинала ось Y идёт
/// сверху вниз, а кадр `NSWindow`/`NSScreen` — снизу вверх от левого нижнего
/// угла главного экрана. Без переворота любое ненулевое Y уводит окно тем
/// дальше, чем больше значение, и «Показать позицию» показывает не то место,
/// куда потом уйдёт слайд.
@MainActor
enum SettingsCoordinates {

    /// Высота главного монитора — начало отсчёта обеих систем координат.
    /// Главный это `NSScreen.screens.first`: именно у него в AppKit начало
    /// кадра (0, 0), а не у `NSScreen.main` (тот — «где сейчас окно»).
    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? NSScreen.main?.frame.height ?? 0
    }

    /// Запись оригинала → кадр AppKit.
    static func frame(left: Int, top: Int, width: Int, height: Int) -> NSRect {
        NSRect(x: CGFloat(left),
               y: primaryHeight - CGFloat(top) - CGFloat(height),
               width: CGFloat(max(1, width)),
               height: CGFloat(max(1, height)))
    }

    /// Кадр AppKit → запись оригинала. Нужен, чтобы список мониторов и поля
    /// «Координаты монитора» показывали те же числа, что и оригинал.
    static func original(_ frame: NSRect) -> (left: Int, top: Int, width: Int, height: Int) {
        (left: Int(frame.origin.x.rounded()),
         top: Int((primaryHeight - frame.maxY).rounded()),
         width: Int(frame.width.rounded()),
         height: Int(frame.height.rounded()))
    }
}

// MARK: - Показать положение монитора

/// Кнопки (8) и (12.5): «Показать позицию дисплея». Открывает на выбранном
/// мониторе безрамочное окно на полторы секунды — так видно, куда именно
/// уйдёт слайд, ещё до того, как его включат в зале.
@MainActor
enum SettingsMonitorFlash {
    private static var window: NSWindow?

    /// Вспышка по координатам оригинала: X и Y считаются сверху вниз.
    static func show(left: Int, top: Int, width: Int, height: Int) {
        show(on: SettingsCoordinates.frame(left: left, top: top, width: width, height: height),
             caption: "\(width) x \(height)")
    }

    static func show(on frame: NSRect, caption: String) {
        window?.orderOut(nil)

        let panel = NSWindow(contentRect: frame,
                             styleMask: [.borderless],
                             backing: .buffered,
                             defer: false)
        panel.isOpaque = false
        panel.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.55)
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let label = NSTextField(labelWithString: caption)
        label.font = .systemFont(ofSize: 64, weight: .bold)
        label.textColor = .white
        label.alignment = .center
        label.frame = NSRect(x: 0, y: frame.height / 2 - 50, width: frame.width, height: 100)
        label.autoresizingMask = [.width]

        let content = NSView(frame: NSRect(origin: .zero, size: frame.size))
        content.addSubview(label)
        panel.contentView = content
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        window = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            panel.orderOut(nil)
            if window === panel { window = nil }
        }
    }
}

// MARK: - Звуковые устройства

/// Список звуковых выходов для вкладки «Медиа». В оригинале это выпадающий
/// список `GBAudio` со «Встроенным выходом» по умолчанию.
enum SettingsAudioDevices {

    struct Device: Identifiable, Hashable {
        let id: Int
        let name: String
    }

    /// Первым идёт «по умолчанию» — так же, как `MediaDefaultAudioDevice=0`
    /// в настройках оригинала.
    static func list() -> [Device] {
        var result: [Device] = [Device(id: 0, name: OurWords.t("По умолчанию"))]
        for id in identifiers() where hasOutput(id) {
            result.append(Device(id: Int(id), name: name(of: id) ?? OurWords.t("Устройство %s", "\(id)")))
        }
        return result
    }

    private static func identifiers() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ id: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioObjectPropertyScopeOutput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }

        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return false }

        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private static func name(of id: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}

// MARK: - Сетевые интерфейсы

/// «Сетевой интерфейс» на вкладке Remote API: адреса, по которым страницы
/// слайдов видны из зала. Пустая строка — «все интерфейсы», как в оригинале.
enum SettingsNetworkInterfaces {

    static func addresses() -> [String] {
        var result: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return result }
        defer { freeifaddrs(head) }

        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(cString: host)
            if text != "127.0.0.1", !result.contains(text) { result.append(text) }
        }
        return result
    }
}
