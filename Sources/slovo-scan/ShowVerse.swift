import Foundation
import SlovoCore

/// Показывает один стих в названном модуле.
///
/// Ради него и заводился: спор о нумерации решается настоящим текстом, а не
/// рассуждением о том, чей алгоритм красивее. Движок теперь один, но вопрос
/// «а что там на самом деле написано» никуда не делся.
func runShowVerse(modulesURL: URL, args: [String]) -> Int32 {
    guard let at = args.firstIndex(of: "--verse"), args.count > at + 4 else {
        print("использование: … --verse <модуль> <книга> <глава> <стих>")
        return 2
    }
    let library = ModuleLibrary(modulesDirectory: modulesURL)
    let id = args[at + 1]
    guard let module = library.module(withIdentifier: id) else {
        print("модуль \(id) не найден"); return 1
    }
    let bookNumber = Int(args[at + 2]) ?? 0
    guard let book = module.books.first(where: { $0.canonicalNumber == bookNumber }) else {
        print("книга \(bookNumber) не найдена в \(id)"); return 1
    }
    let chapter = Int(args[at + 3]) ?? 1
    let verse = Int(args[at + 4]) ?? 1
    let text = (try? module.chapter(chapter, ofBook: book))??.verse(verse)?.text ?? "— нет такого стиха —"
    print("\(id) \(book.fullName) \(chapter):\(verse) — \(text.prefix(110))")
    return 0
}
