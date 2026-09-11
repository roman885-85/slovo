import AppKit
import CoreText

/// Подключение шрифтов из папки данных.
///
/// В настройках оригинала стоят имена вроде `Jikharev_VB` — это шрифты из
/// его же папки `Fonts`, не установленные в системе. Без регистрации macOS
/// молча подставит системный, и слайд перестанет совпадать с привычным.
@MainActor
enum FontLoader {
    private static var registered = Set<String>()

    /// Где лежит файл шрифта с таким именем семьи.
    ///
    /// Нужен веб-выводу: браузеру шрифт надо ОТДАТЬ файлом, установить его в
    /// чужой системе мы не можем. Ищем среди уже прочитанных: имя семьи у
    /// файла спрашиваем у самой системы шрифтов, а не выводим из имени файла —
    /// «jikharev_vb.ttf» и «Jikharev_VB» совпадают только по случайности.
    static func fileURL(forFamily family: String) -> URL? {
        let wanted = family.lowercased()
        for path in registered {
            let url = URL(fileURLWithPath: path)
            guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL)
                    as? [CTFontDescriptor] else { continue }
            for descriptor in descriptors {
                let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String
                let full = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
                if name?.lowercased() == wanted || full?.lowercased() == wanted { return url }
            }
        }
        return nil
    }

    static func registerFonts(in folder: URL) {
        let allowed: Set<String> = ["ttf", "otf", "ttc"]
        let files = (try? FileManager.default.contentsOfDirectory(at: folder,
                                                                  includingPropertiesForKeys: nil,
                                                                  options: [.skipsHiddenFiles])) ?? []
        for file in files {
            if file.hasDirectoryPath {
                registerFonts(in: file)
                continue
            }
            guard allowed.contains(file.pathExtension.lowercased()),
                  !registered.contains(file.path) else { continue }

            var error: Unmanaged<CFError>?
            if CTFontManagerRegisterFontsForURL(file as CFURL, .process, &error) {
                registered.insert(file.path)
            }
            error?.release()
        }
    }
}
