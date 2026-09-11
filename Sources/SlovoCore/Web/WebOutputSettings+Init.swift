import Foundation

/// Налаштування веб-виводу вміє збирати лише `OutputConfiguration` з
/// VisioBible.ini: почленний ініціалізатор структури внутрішній, і ззовні
/// модуля її не створити.
///
/// Застосунку це потрібно — оператор міняє порт у налаштуваннях, а перевірочні
/// прогони піднімають сервер на вільному порту взагалі без ini. Даємо фабрику
/// замість ініціалізатора: однойменний `init` перекрив би синтезований
/// почленний і зламав би `OutputConfiguration`.
public extension WebOutputSettings {

    static func make(httpEnabled: Bool = true,
                     httpPort: Int = 82,
                     webSocketEnabled: Bool = true,
                     webSocketPort: Int = 8100,
                     tcpEnabled: Bool = false,
                     tcpPort: Int = 8101,
                     udpEnabled: Bool = false,
                     udpPort: Int = 8100,
                     pages: [WebPage] = []) -> WebOutputSettings {
        WebOutputSettings(httpEnabled: httpEnabled,
                          httpPort: httpPort,
                          webSocketEnabled: webSocketEnabled,
                          webSocketPort: webSocketPort,
                          tcpEnabled: tcpEnabled,
                          tcpPort: tcpPort,
                          udpEnabled: udpEnabled,
                          udpPort: udpPort,
                          pages: pages)
    }

    /// Сторінки, що лежать у теці `RemoteAPI` і у своїй теці власника.
    ///
    /// Своя тека сюди потрапила не одразу, і сторінки, зроблені в майстерні,
    /// сервер віддавав, але ніде не показував: ні в списку Remote API, ні на
    /// домашній сторінці. Людина зберігала свій шаблон і не знаходила його.
    static func discoverPages(in folder: URL) -> [WebPage] {
        var seen: Set<String> = []
        var pages: [WebPage] = []
        for base in [folder, WebOutputServer.userPagesFolder] {
            let files = (try? FileManager.default.contentsOfDirectory(at: base,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for file in files.filter({ $0.pathExtension.lowercased() == "html" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = file.lastPathComponent
                guard seen.insert(name.lowercased()).inserted else { continue }
                pages.append(WebPage(fileName: name,
                                     title: file.deletingPathExtension().lastPathComponent))
            }
        }
        return pages
    }
}

public extension WebOutputSettings.WebPage {
    static func make(fileName: String, title: String) -> Self {
        Self(fileName: fileName, title: title)
    }
}
