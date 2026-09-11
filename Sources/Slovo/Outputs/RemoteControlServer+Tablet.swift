import AppKit
import Network
import SlovoCore

/// Пульт для планшета: усе, чим ведуть служіння, — з планшета.
///
/// Власник: «далее сделать пульт для планшета, где будет полный функционал
/// программы». Телефон уміє гортати, Біблію, пісні й фото. Планшету треба
/// ще плеєр, картинки, захоплення екрана, набраний текст, План, Історію,
/// пошук за словами і картинку того, що зараз у залі, — щоб ведучий бачив
/// стіну, не обертаючись.
extension RemoteControlServer {

    /// Чим закінчилася команда планшета.
    enum TabletOutcome {
        case handled
        case unknown
        case failed(Int, String)
    }

    // MARK: - Читання

    /// Маршрути читання планшета. `true` — відповідь уже пішла.
    func tabletGET(_ request: Request, state: AppState, on connection: NWConnection) -> Bool {
        switch request.path {
        case "/api/hall.jpg":
            let width = min(1920, max(160, Int(request.query["w"] ?? "") ?? 960))
            guard let image = hallImage(state: state), let jpeg = Self.jpeg(image, width: width) else {
                respond(connection, 404, ["error": OurWords.t("в зале видео")])
                return true
            }
            respondData(connection, 200, jpeg, contentType: "image/jpeg")
        case "/api/songs/books":
            respond(connection, 200, songBooksJSON(state: state))
        case "/api/songs/list":
            respond(connection, 200, songListJSON(state: state))
        case "/api/media":
            respond(connection, 200, mediaJSON(state: state))
        case "/api/pictures":
            respond(connection, 200, picturesJSON())
        case "/api/screen":
            respond(connection, 200, screenJSON(state: state))
        case "/api/history":
            respond(connection, 200, historyJSON())
        case "/api/text":
            respond(connection, 200, textJSON())
        case "/api/search":
            respond(connection, 200, searchJSON())
        default:
            return false
        }
        return true
    }

    /// Що зараз на стіні. Текст малює той самий рисувальник, що й NDI;
    /// картинку й сторінку показу беремо готовою. Кадрів фільму й
    /// захопленого екрана не передаємо — планшет пише, що в залі відео.
    func hallImage(state: AppState) -> CGImage? {
        let media = state.media
        if media.isVideoOnScreen { return media.still }
        let slide = state.isLive && !state.isBlackedOut ? state.liveSlide : Slide.blank
        return state.ndi.snapshotFrame(slide: slide)?.image
    }

    /// Що в залі — щоб планшет знав, чи перезабрати картинку і що
    /// написати, коли картинки немає.
    func hallJSON(state: AppState) -> [String: Any] {
        let media = state.media
        let kind: String
        if state.isBlackedOut {
            kind = "black"
        } else if media.isVideoOnScreen {
            kind = media.still != nil ? "still" : "video"
        } else {
            kind = state.isLive ? "text" : "empty"
        }
        return ["kind": kind, "title": media.isVideoOnScreen ? media.title : state.liveSlide.reference]
    }

    /// Пісенники для вибору. Каталог знає назву лише тих збірників, які
    /// вже читав сам, — решта до того зветься іменем файла. Відкритий збірник
    /// читає вікно пісень, не каталог, тож його назву беремо з нього: інакше
    /// планшет показував «glory» замість «Пісні хвали».
    func songBooksJSON(state: AppState) -> [String: Any] {
        let books = state.songLibrary?.books ?? []
        let open = NativeSongsWorkspace.shared.model.book?.title ?? ""
        return ["current": state.songBookID,
                "books": books.map { entry -> [String: Any] in
                    let title = entry.id == state.songBookID && !open.isEmpty ? open : entry.title
                    return ["id": entry.id, "title": title, "short": entry.shortName]
                }]
    }

    /// Пісні відкритого пісенника — усі: планшет тримає список сам і
    /// шукає в ньому без мережі.
    func songListJSON(state: AppState) -> [String: Any] {
        let model = NativeSongsWorkspace.shared.model
        let songs = model.book?.songs ?? []
        return ["book": state.songBookID,
                "selected": model.songIndex ?? -1,
                "songs": songs.map { ["index": $0.index, "number": $0.index + 1, "title": $0.title,
                                      "subtitle": $0.subtitle ?? ""] }]
    }

    func mediaJSON(state: AppState) -> [String: Any] {
        let media = state.media
        return ["title": media.title, "playing": media.isPlaying,
                "position": media.position, "duration": media.duration,
                "volume": media.volume, "muted": media.isMuted, "video": media.hasVideo,
                "toScreen": media.videoToScreen, "repeats": media.repeats,
                "index": media.playlistIndex ?? -1,
                "playlist": media.playlist.enumerated().map {
                    ["index": $0.offset, "name": $0.element.lastPathComponent]
                }]
    }

    func picturesJSON() -> [String: Any] {
        let model = NativeShowWorkspace.pictures.model
        return ["index": model.index ?? -1, "count": model.count,
                "pages": model.pages.enumerated().map { ["index": $0.offset, "title": $0.element.short] }]
    }

    /// Джерела захоплення. Список збирається асинхронно; порожній —
    /// просимо зібрати і відповідаємо тим, що є.
    func screenJSON(state: AppState) -> [String: Any] {
        let capture = state.screenCapture
        if capture.sources.isEmpty { reloadScreenSources(state: state) }
        return ["running": capture.isRunning, "current": capture.current?.id ?? "",
                "note": capture.state, "permission": !capture.needsPermission,
                "sources": capture.sources.enumerated().map {
                    ["index": $0.offset, "id": $0.element.id, "kind": $0.element.kind.rawValue,
                     "title": $0.element.title, "subtitle": $0.element.subtitle]
                }]
    }

    private func reloadScreenSources(state: AppState) {
        let capture = state.screenCapture
        Task { @MainActor [weak self] in
            await capture.reload()
            self?.noteChange()
        }
    }

    func historyJSON() -> [String: Any] {
        let desk = DeskModel.shared
        return ["records": desk.history.records.enumerated().map {
            ["index": $0.offset, "caption": $0.element.caption, "kind": "\($0.element.kind)",
             "current": desk.historySelection == $0.element.id]
        }]
    }

    func textJSON() -> [String: Any] {
        let model = TextModuleModel.shared
        return ["title": model.document.title, "body": model.document.body,
                "page": model.pageIndex, "pages": model.pageCount]
    }

    func searchJSON() -> [String: Any] {
        let desk = DeskModel.shared
        return ["query": desk.searchedQuery, "searching": desk.isSearching,
                "hits": desk.hits.prefix(300).enumerated().map {
                    ["index": $0.offset,
                     "reference": "\($0.element.bookName) \($0.element.chapter):\($0.element.verse)",
                     "text": $0.element.text]
                }]
    }

    // MARK: - Команди

    func tabletCommand(_ command: String, body: [String: Any], index: Int?, text: String,
                       state: AppState, answer: inout [String: Any]) -> TabletOutcome {
        let desk = DeskModel.shared
        let media = state.media
        func number(_ key: String) -> Double? { (body[key] as? NSNumber)?.doubleValue }
        func focus(_ mode: AppState.WorkMode) { if state.mode != mode { state.mode = mode } }

        switch command {
        case "songs-book":
            guard state.songLibrary?.entry(text) != nil else {
                return .failed(404, OurWords.t("нет такого сборника"))
            }
            focus(.songs)
            NativeSongsWorkspace.shared.selectBook(id: text)

        case "picture":
            let pictures = NativeShowWorkspace.pictures
            guard let index, pictures.model.pages.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такой страницы"))
            }
            focus(.pictures)
            pictures.selectPage(index)
            pictures.showCurrentPage()

        case "media-open":
            guard let index, media.playlist.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого файла"))
            }
            focus(.media)
            media.openFromPlaylist(at: index)
        case "media-toggle": media.playPause()
        case "media-play": media.play()
        case "media-pause": media.pause()
        case "media-stop": media.stop()
        case "media-seek":
            guard let seconds = number("x") else { return .failed(400, "x") }
            media.seek(to: seconds)
        case "media-volume":
            guard let level = number("x") else { return .failed(400, "x") }
            media.volume = min(1, max(0, level))
        case "media-mute": media.isMuted.toggle()
        case "media-screen": media.videoToScreen.toggle()
        case "media-repeat": media.repeats.toggle()

        case "screen-reload":
            reloadScreenSources(state: state)
        case "screen-start":
            let sources = state.screenCapture.sources
            guard let index, sources.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого источника"))
            }
            focus(.screen)
            state.showCapturedScreen(sources[index])
        case "screen-stop":
            state.stopCapturedScreen()

        case "text-set":
            let model = TextModuleModel.shared
            model.document = PlainTextDocument(title: (body["title"] as? String) ?? "", body: text)
            focus(.text)
            model.refreshPreview()
            answer["pages"] = model.pageCount
        case "text-show":
            focus(.text)
            TextModuleModel.shared.show()
        case "text-page":
            guard let index else { return .failed(400, "index") }
            focus(.text)
            TextModuleModel.shared.selectPage(index, live: true)

        case "history":
            let records = desk.history.records
            guard let index, records.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого пункта"))
            }
            desk.activate(records[index], state: state)
        case "history-remove":
            let records = desk.history.records
            guard let index, records.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого пункта"))
            }
            desk.removeHistory(records[index].id)

        case "plan-add":
            desk.addCurrentToPlan(state: state)
        case "plan-remove":
            guard let index, desk.plan.items.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого пункта"))
            }
            desk.deletePlan(atOffsets: IndexSet(integer: index))
        case "plan-move":
            // «Вгору» і «вниз» на один рядок. Зсув рахується так само, як у
            // списку, що перетягують: місце вставки — до зсуву рядків.
            guard let index, desk.plan.items.indices.contains(index),
                  let delta = number("delta").map({ Int($0) }), delta != 0 else {
                return .failed(404, OurWords.t("нет такого пункта"))
            }
            let target = index + delta
            if desk.plan.items.indices.contains(target) {
                desk.movePlan(fromOffsets: IndexSet(integer: index), toOffset: delta > 0 ? target + 1 : target)
            }

        case "bible-search":
            focus(.bible)
            desk.runSearch(text, state: state)
        case "search-hit":
            let hits = desk.hits
            guard let index, hits.indices.contains(index) else {
                return .failed(404, OurWords.t("нет такого пункта"))
            }
            focus(.bible)
            desk.show(hits[index], state: state, live: (body["live"] as? Bool) ?? false)

        default:
            return .unknown
        }
        return .handled
    }
}
