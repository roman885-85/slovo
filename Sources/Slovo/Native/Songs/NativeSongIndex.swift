import AppKit
import SlovoCore

/// Згортка назв для пошуку і сам пошук по байтах.
///
/// `folding(options:locale:)` розбирає рядок за Юнікодом і коштує дорого:
/// на збірнику «Пісня відродження 3400» один прохід по всіх назвах — це
/// 70–80 мс. Тому згорнуті назви рахуються рівно один раз на збірник,
/// і не рядками, а байтами UTF-8.
///
/// Байти, а не `String.contains`, бо пошук підрядка в `String`
/// щоразу заново розбирає обидва боки за графемами: на 3400 назвах
/// це мілісекунди на кожну набрану літеру. Згортка вже прибрала регістр,
/// діакритику і ширину — після неї звіряти можна побайтово, і весь збірник
/// уміщається в півтораста кілобайтів, які перебираються за частки мілісекунди.
enum NativeSongFold {

    /// Згорнуті байти рядка. `ё` у пісенниках пишуть і так і так, тому
    /// її зводимо до `е` до згортки — інакше «моё» не знайдеться за «мое».
    static func bytes(_ text: String) -> [UInt8] {
        guard !text.isEmpty else { return [] }
        let folded = text
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: nil)
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: "Ё", with: "е")
        // Розділові знаки стають пробілами: власник — «при поиске игнорировать
        // знаки пунктуации, брать в поиск только слова». Доти кома в назві
        // («Спаси, Боже») ламала пошук за «спаси боже», а кома в запиті — пошук
        // узагалі. Пробіли поспіль зводяться в один, щоб слова стояли рівно.
        var out: [UInt8] = []
        out.reserveCapacity(folded.utf8.count)
        var space = true
        for character in folded {
            if character.isLetter || character.isNumber {
                out.append(contentsOf: Array(String(character).utf8))
                space = false
            } else if !space {
                out.append(32)
                space = true
            }
        }
        if out.last == 32 { out.removeLast() }
        return out
    }

    /// Слова запиту — згорнуті й без розділових знаків.
    static func words(_ text: String) -> [[UInt8]] {
        bytes(text).split(separator: 32).map(Array.init)
    }

    /// Чи знайшлося кожне слово запиту в рядку — з початку якогось слова.
    ///
    /// Шукаємо за початком слова, а не будь-де: так «рад» знаходить «радість»
    /// і не чіпає «страждання». Порядок слів не важливий — як у пошуку за
    /// віршами: всі слова мають бути, а стояти можуть як завгодно.
    static func matches(_ haystack: [UInt8], words needles: [[UInt8]]) -> Bool {
        for needle in needles where !startsWord(haystack, needle) { return false }
        return true
    }

    /// Чи починається якесь слово рядка з цих байтів.
    static func startsWord(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let need = needle.count
        guard need > 0 else { return true }
        guard haystack.count >= need else { return false }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { want in
                var start = 0
                let last = hay.count - need
                while start <= last {
                    if start == 0 || hay[start - 1] == 32 {
                        var step = 0
                        while step < need, hay[start + step] == want[step] { step += 1 }
                        if step == need { return true }
                    }
                    start += 1
                }
                return false
            }
        }
    }

    /// Чи є `needle` усередині `haystack`. Простий перебір з перевіркою першого
    /// байта: голки тут в один-два знаки, і заводити заради них таблицю зсувів
    /// дорожче, ніж пройти рядок наскрізь.
    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let need = needle.count
        guard need > 0 else { return true }
        let hay = haystack.count
        guard hay >= need else { return false }
        let first = needle[0]
        return haystack.withUnsafeBufferPointer { h in
            needle.withUnsafeBufferPointer { n in
                var start = 0
                let last = hay - need
                while start <= last {
                    if h[start] == first {
                        var step = 1
                        while step < need, h[start + step] == n[step] { step += 1 }
                        if step == need { return true }
                    }
                    start += 1
                }
                return false
            }
        }
    }
}

/// Усе, що список пісень знає про збірник, — і нічого понад.
///
/// Тут немає жодного значення `Song`: лише готові до показу рядки і
/// згорнуті байти для відбору. Саме на перенесенні трьох з половиною тисяч
/// `Song` з усім їхнім текстом колишнє вікно втрачало 70 % головного потоку.
///
/// Важка половина — згортка назв і розбір «Номера в збірнику» зі
/// властивостей пісні — рахується осторонь від головного потоку: зміна Пісенника
/// не має права коштувати вісімдесяти мілісекунд. Поки вона рахується, відбір
/// працює за назвами як є; готове приходить через частки секунди, і
/// набрана за цей час літера перепитується сама.
@MainActor
final class NativeSongIndex {

    /// Розібраний збірник цілком. Готові до показу рядки і згорнуті байти
    /// для відбору — більше про пісні список нічого не знає.
    private struct Bundle {
        let titles: [String]
        let subtitles: [String]
        var folded: [[UInt8]] = []
        var alternates: [[UInt8]] = []
        var catalog: [Int?] = []
        var isReady = false
    }

    private var bundle = Bundle(titles: [], subtitles: [])

    var titles: [String] { bundle.titles }
    var subtitles: [String] { bundle.subtitles }
    var catalogNumbers: [Int?] { bundle.catalog }
    var isReady: Bool { bundle.isReady }

    /// Чий це розбір. Поки не збіглося з відкритим збірником — чужий.
    private(set) var key = ""
    /// Скільки разів довелося згортати назви прямо на головному потоці,
    /// не дочекавшись фонового розбору. Читає самоперевірка.
    private(set) var hurriedFolds = 0

    /// Кого розбудити, коли фоновий розбір доспів.
    var onReady: (() -> Void)?

    /// Розібране за колишніми збірниками. Трьох досить: відкритий, попередній і
    /// той, куди зазирнули мимохідь, — рівно стільки ж тримає `SongLibrary`.
    /// Завдяки запасу повернення до колишнього Пісенника не коштує нічого.
    private static var cache: [String: Bundle] = [:]
    private static var recent: [String] = []
    private static let cacheLimit = 3

    var count: Int { bundle.titles.count }

    /// Відкрити збірник.
    ///
    /// `key` складається з імені збірника, числа пісень і лічильника правок:
    /// після правки пісні розібране застаріло, і брати його із запасу не можна.
    func open(songs: [Song], key: String) {
        self.key = key
        if let ready = Self.cache[key] {
            bundle = ready
            Self.touch(key)
            return
        }

        var titles = [String]()
        var subtitles = [String]()
        titles.reserveCapacity(songs.count)
        subtitles.reserveCapacity(songs.count)
        for song in songs {
            titles.append(song.title)
            subtitles.append(Self.subtitle(author: song.author, composer: song.composer))
        }
        bundle = Bundle(titles: titles, subtitles: subtitles)
        Self.remember(key: key, bundle)
        prepare(songs: songs, key: key)
    }

    /// Підзаголовок пісні — слова і музика.
    ///
    /// Повторює `Song.subtitle`, але без проміжного масиву і множини:
    /// на збірнику в 3400 пісень ці дві недовговічні купки коштують кілька
    /// мілісекунд на кожну зміну Пісенника, а відповідь у них та сама.
    private static func subtitle(author: String, composer: String) -> String {
        if author.isEmpty { return composer }
        if composer.isEmpty || author == composer { return author }
        return author + " / " + composer
    }

    /// Згорнути назви і розібрати номери осторонь від головного потоку.
    private func prepare(songs: [Song], key: String) {
        let titles = songs.map(\.title)
        let alternates = songs.map(\.alternateTitle)
        let properties = songs.map(\.properties)
        Task.detached(priority: .userInitiated) {
            let folded = titles.map(NativeSongFold.bytes)
            let foldedAlternates = alternates.map(NativeSongFold.bytes)
            let catalog = properties.map(NativeSongIndex.catalogNumber(in:))
            await MainActor.run {
                NativeSongIndex.complete(key: key, folded: folded,
                                         alternates: foldedAlternates, catalog: catalog)
                // Поки рахували, могли відкрити інший збірник — тоді
                // пораховане лягає в запас, а нам воно вже ні до чого.
                guard self.key == key, let ready = NativeSongIndex.cache[key] else { return }
                self.bundle = ready
                self.onReady?()
            }
        }
    }

    /// «Номер у збірнику» — рядок `$ID$=1728` у властивостях пісні.
    /// Розбираємо самі, а не через `Song.catalogNumber`: той на кожне
    /// звертання будує словник усіх властивостей, а потрібне одне число.
    nonisolated static func catalogNumber(in properties: String) -> Int? {
        guard !properties.isEmpty else { return nil }
        for line in properties.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("$ID$=") else { continue }
            return Int(trimmed.dropFirst(5).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private static func complete(key: String, folded: [[UInt8]],
                                 alternates: [[UInt8]], catalog: [Int?]) {
        guard var stored = cache[key] else { return }
        stored.folded = folded
        stored.alternates = alternates
        stored.catalog = catalog
        stored.isReady = true
        cache[key] = stored
        touch(key)
    }

    private static func remember(key: String, _ bundle: Bundle) {
        cache[key] = bundle
        touch(key)
        while recent.count > cacheLimit, let oldest = recent.first {
            recent.removeFirst()
            cache[oldest] = nil
        }
    }

    private static func touch(_ key: String) {
        recent.removeAll { $0 == key }
        recent.append(key)
    }

    // MARK: - Відбір

    /// Номери пісень, що підійшли під набране. `nil` — підійшли всі.
    ///
    /// Порядок розбору взято в автора (5.3.5): спершу номер, і якщо за номером
    /// знайшлося — на цьому все; інакше слова в основній і другій назві.
    func filter(query: String, within group: [Int]?) -> [Int]? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return group }

        // Перебір іде або за номерами групи, або за всіма підряд. Складати
        // «усі підряд» у масив не можна: це три з половиною тисячі чисел на
        // кожну набрану літеру, а потрібен один прохід.
        func each(_ body: (Int) -> Void) {
            if let group {
                for index in group { body(index) }
            } else {
                for index in 0..<bundle.titles.count { body(index) }
            }
        }

        if let number = Int(trimmed) {
            var byNumber: [Int] = []
            let catalog = bundle.catalog
            // Номер пісні — це її місце у збірнику, рахуючи з одиниці;
            // тримати під це окремий масив нема чого.
            each { index in
                if index + 1 == number || (index < catalog.count && catalog[index] == number) {
                    byNumber.append(index)
                }
            }
            if !byNumber.isEmpty { return byNumber }
        }

        let needles = NativeSongFold.words(trimmed)
        guard !needles.isEmpty else { return group }
        guard bundle.isReady else { return hurriedFilter(needle: trimmed, each: each) }

        let folded = bundle.folded
        let alternates = bundle.alternates
        var kept: [Int] = []
        kept.reserveCapacity(64)
        each { index in
            guard index < folded.count else { return }
            if NativeSongFold.matches(folded[index], words: needles)
                || NativeSongFold.matches(alternates[index], words: needles) {
                kept.append(index)
            }
        }
        return kept
    }

    /// Відбір, поки фоновий розбір не доспів. Буває лише в перші частки
    /// секунди після відкриття збірника, тому тут можна й дорожче.
    private func hurriedFilter(needle: String, each: ((Int) -> Void) -> Void) -> [Int] {
        hurriedFolds += 1
        var kept: [Int] = []
        let titles = bundle.titles
        each { index in
            guard index < titles.count else { return }
            if titles[index].range(of: needle,
                                   options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                kept.append(index)
            }
        }
        return kept
    }
}
