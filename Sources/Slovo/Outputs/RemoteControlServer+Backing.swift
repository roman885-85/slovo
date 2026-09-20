import AppKit
import Network
import SlovoCore

/// Фонограма з пульта: список, відтворення, гучність і тон.
///
/// Власник: «в windows приложении… в песнях нет функции минусовок». Панель
/// фонограм жила лише у вікні програми: пульт про неї не знав нічого. Тепер
/// той самий програвач (`AppState.backing`) доступний по мережі — і
/// «Проповіднику», і планшетові, і телефону.
///
/// Плеєр і фонограма — різні речі: плеєр веде ролики й заставки (`media-*`),
/// фонограма супроводжує спів. Тому і канал окремий, зі своїм списком.
extension RemoteControlServer {

    // MARK: - Читання

    /// `GET /api/backing` — усе, що треба показати на пульті.
    func backingGET(_ request: Request, state: AppState, on connection: NWConnection) -> Bool {
        guard request.path == "/api/backing" else { return false }
        respond(connection, 200, backingJSON(state: state))
        return true
    }

    func backingJSON(state: AppState) -> [String: Any] {
        let player = state.backing
        return [
            "title": player.title,
            "playing": player.isPlaying,
            "position": player.livePosition,
            "duration": player.duration,
            "volume": Double(player.volume),
            "tone": player.pitchTones,
            "loops": player.loops,
            "index": player.playlistIndex ?? -1,
            "error": player.error ?? "",
            "playlist": player.playlist.enumerated().map {
                ["index": $0.offset, "name": $0.element.deletingPathExtension().lastPathComponent]
            },
        ]
    }

    // MARK: - Команди

    /// Команди `backing-*`. `nil` — команда не наша.
    @MainActor
    func backingCommand(_ command: String, body: [String: Any], index: Int?, text: String,
                        state: AppState, answer: inout [String: Any]) -> String? {
        let player = state.backing
        switch command {
        case "backing-open":
            guard let index, player.playlist.indices.contains(index) else { return OurWords.t("нет такой фонограммы") }
            player.openFromPlaylist(at: index)
        case "backing-play":
            // Без відкритої фонограми грати нічого: беремо першу зі списку.
            if player.url == nil, !player.playlist.isEmpty { player.openFromPlaylist(at: 0) }
            player.play()
        case "backing-pause": player.pause()
        case "backing-toggle": player.toggle()
        case "backing-stop": player.stop()
        case "backing-seek":
            guard let seconds = (body["position"] as? NSNumber)?.doubleValue else { return OurWords.t("нужна позиция") }
            player.seek(to: seconds)
        case "backing-volume":
            guard let value = (body["volume"] as? NSNumber)?.doubleValue else { return OurWords.t("нужна громкость") }
            player.volume = Float(min(1, max(0, value)))
        case "backing-tone":
            guard let value = (body["tone"] as? NSNumber)?.doubleValue else { return OurWords.t("нужен тон") }
            player.setPitch(min(6, max(-6, value)))
        case "backing-loop":
            player.loops = (body["loops"] as? NSNumber)?.boolValue ?? !player.loops
        case "backing-remove":
            guard let index, player.playlist.indices.contains(index) else { return OurWords.t("нет такой фонограммы") }
            player.removeFromPlaylist(at: index)
        default:
            return nil
        }
        answer["backing"] = backingJSON(state: state)
        noteChange()
        return ""
    }
}
