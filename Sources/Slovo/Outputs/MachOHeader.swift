import Foundation
import MachO

/// Что библиотека требует от системы — прямо из её заголовка Mach-O.
///
/// Нужно загрузчику NDI: на Big Sur наша libndi 6.x собрана для macOS 13, и
/// полагаться на то, что dyld сам её отвергнет, нельзя — старый dyld может
/// и загрузить, а библиотека потом молча не работает. Читаем минимальную
/// систему сами и сравниваем с той, что запущена.
enum MachOHeader {

    /// Минимальная macOS для слоя текущей архитектуры, или nil, если файл
    /// не Mach-O, нужного слоя нет или команды версии не нашлось.
    static func minimumOS(of path: String) -> OperatingSystemVersion? {
        guard let data = FileManager.default.contents(atPath: path), data.count >= 32 else { return nil }
        return data.withUnsafeBytes { raw -> OperatingSystemVersion? in
            guard let base = raw.baseAddress else { return nil }
            let magic = base.load(as: UInt32.self)
            var offset = 0
            var size = data.count
            // Толстый файл: ищем слой своей архитектуры. Заголовок толстого
            // файла — всегда с обратным порядком байт.
            if magic == FAT_CIGAM || magic == FAT_MAGIC {
                let count = Int(UInt32(bigEndian: base.load(fromByteOffset: 4, as: UInt32.self)))
                var found = false
                for index in 0..<count {
                    let arch = 8 + index * 20
                    guard arch + 20 <= data.count else { break }
                    let cpu = Int32(bitPattern: UInt32(bigEndian: base.load(fromByteOffset: arch, as: UInt32.self)))
                    if cpu == currentCPU {
                        offset = Int(UInt32(bigEndian: base.load(fromByteOffset: arch + 8, as: UInt32.self)))
                        size = Int(UInt32(bigEndian: base.load(fromByteOffset: arch + 12, as: UInt32.self)))
                        found = true
                        break
                    }
                }
                guard found, offset + 32 <= data.count else { return nil }
            }
            let header = base + offset
            guard header.load(as: UInt32.self) == MH_MAGIC_64 else { return nil }
            let commands = Int(header.load(fromByteOffset: 16, as: UInt32.self))
            var cursor = 32
            for _ in 0..<commands {
                guard cursor + 8 <= size else { break }
                let command = header.load(fromByteOffset: cursor, as: UInt32.self)
                let length = Int(header.load(fromByteOffset: cursor + 4, as: UInt32.self))
                guard length >= 8 else { break }
                if command == UInt32(LC_BUILD_VERSION), cursor + 16 <= size {
                    let platform = header.load(fromByteOffset: cursor + 8, as: UInt32.self)
                    if platform == UInt32(PLATFORM_MACOS) {
                        return version(header.load(fromByteOffset: cursor + 12, as: UInt32.self))
                    }
                } else if command == UInt32(LC_VERSION_MIN_MACOSX), cursor + 12 <= size {
                    return version(header.load(fromByteOffset: cursor + 8, as: UInt32.self))
                }
                cursor += length
            }
            return nil
        }
    }

    /// Запущенная система новее или равна требуемой.
    static func runningSystem(satisfies required: OperatingSystemVersion) -> Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(required)
    }

    static func text(_ version: OperatingSystemVersion) -> String {
        version.patchVersion == 0
            ? "\(version.majorVersion).\(version.minorVersion)"
            : "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// Версия в заголовке упакована как xxxx.yy.zz.
    private static func version(_ packed: UInt32) -> OperatingSystemVersion {
        OperatingSystemVersion(majorVersion: Int(packed >> 16),
                               minorVersion: Int((packed >> 8) & 0xff),
                               patchVersion: Int(packed & 0xff))
    }

    private static var currentCPU: Int32 {
        #if arch(arm64)
        return CPU_TYPE_ARM64
        #else
        return CPU_TYPE_X86_64
        #endif
    }
}
