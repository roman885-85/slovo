import Foundation
import SlovoCore

/// Список плеєра з посиланнями (ролики YouTube, потоки) поруч із файлами.
///
/// Власник: «добавить … возможность проигрывания видео с ютуба не по одной ссылке,
/// а добавляя несколько в свой плейлист (как в минусовках) и проигрывая их по
/// своему усмотрению в своей очередности». Перевіряємо на окремому плеєрі — список
/// людини не чіпаємо, нічого не відкриваємо (yt-dlp і мережа тут ні до чого).
extension Diagnostics {

    static func mediaLinksSection(state: AppState) -> [Check] {
        let area = "Медіа"
        var checks: [Check] = []
        func check(_ name: String, _ passed: Bool, _ detail: String) {
            checks.append(Check(area: area, name: name, status: passed ? .ok : .failed, detail: detail))
        }
        let media = MediaPlayerModel()
        let text = """
        https://www.youtube.com/watch?v=jNQXAC9IVRw
        https://youtu.be/jNQXAC9IVRw
        https://www.youtube.com/@church
        не посилання
        https://example.com/live/stream.m3u8, https://youtu.be/dQw4w9WgXcQ
        """
        let added = media.addLinks(text: text, opensFirst: false)
        let captions = media.playlist.map { media.playlistCaption($0) }
        check("Кілька посилань — у список", added == 3 && media.playlist.count == 3,
              "додано \(added): " + captions.joined(separator: " | ") + " (повтор ролика іншим записом, канал і не-посилання відкинуто)")
        check("Підпис ролика без назви — номер", captions.first == "YouTube · jNQXAC9IVRw",
              captions.first ?? "—")
        check("Підпис потоку — адреса", captions.count > 1 && captions[1] == "example.com/live/stream.m3u8",
              captions.count > 1 ? captions[1] : "—")
        media.movePlaylistItem(at: 2, by: -1)
        check("↑ міняє порядок", media.playlist.count == 3 && YouTubeLink.videoID(from: media.playlist[1]) == "dQw4w9WgXcQ",
              media.playlist.map { media.playlistCaption($0) }.joined(separator: " | "))
        let file = URL(fileURLWithPath: "/Applications")
        check("Пам'ять: посилання — як є, файл — шляхом",
              MediaPlayerModel.savedEntry("https://youtu.be/dQw4w9WgXcQ") != nil
                && MediaPlayerModel.savedEntry("/немає/такого/файла.mp4") == nil
                && MediaPlayerModel.savedEntry(file.path) != nil,
              "посилання зберігається без перевірки диска, зниклий файл пропускається")
        media.removeFromPlaylist(at: 0)
        check("Прибрати з початку", media.playlist.count == 2, "лишилось \(media.playlist.count)")
        media.clearPlaylist()
        check("Очистити", media.playlist.isEmpty && media.linkTitles.isEmpty, "порожньо")
        return checks
    }
}
