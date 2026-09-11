import Foundation

/// Посилання на ролик YouTube — розбір у номер ролика.
///
/// Прямий потік з YouTube на macOS не взяти: сайт віддає його лише своєму
/// програвачу. Перевірено 2026-09-03 на прохання власника: внутрішній API
/// YouTube відповідає відмовою всім відомим клієнтам (iOS, Android — «Precondition
/// check failed», телевізор — «no longer supported», браузер — «Video
/// unavailable» без ключа справжності), і всякий обхідний шлях живе до
/// найближчої правки на їхньому боці. Тому ролик показується офіційним
/// вбудовуваним програвачем YouTube (IFrame Player API), а йому потрібен лише
/// номер ролика — його і виймаємо.
public enum YouTubeLink {

    /// Вузли, за якими посилання вважають посиланням на YouTube.
    public static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtu.be", "www.youtu.be", "youtube-nocookie.com", "www.youtube-nocookie.com",
    ]

    public static func isYouTube(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return hosts.contains(host)
    }

    /// Номер ролика з посилання будь-якого виду: `watch?v=`, `youtu.be/`, `/live/`,
    /// `/shorts/`, `/embed/`, `/v/`. Не YouTube або ролика в посиланні немає —
    /// `nil`: сторінка каналу, головна, список відтворення.
    public static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(), hosts.contains(host) else { return nil }
        let parts = Array(url.pathComponents.dropFirst())   // без початкового «/»
        if host.hasSuffix("youtu.be") {
            return validated(parts.first)
        }
        if let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let candidate = query.first(where: { $0.name == "v" })?.value {
            return validated(candidate)
        }
        guard let first = parts.first?.lowercased(),
              ["live", "shorts", "embed", "v"].contains(first) else { return nil }
        return validated(parts.dropFirst().first)
    }

    /// Посилання на перегляд за номером — для запиту назви (oEmbed).
    public static func watchURL(id: String) -> URL? {
        URL(string: "https://www.youtube.com/watch?v=\(id)")
    }

    /// Номер ролика — рівно 11 знаків з літер, цифр, «-» і «_». Усе інше в
    /// полі `v` — сміття, відкривати його нічим.
    private static func validated(_ candidate: String?) -> String? {
        guard let candidate, candidate.count == 11 else { return nil }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        guard candidate.unicodeScalars.allSatisfy({ allowed.contains($0) && $0.isASCII }) else { return nil }
        return candidate
    }
}
