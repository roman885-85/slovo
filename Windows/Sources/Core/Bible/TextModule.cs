// =============================================================================
//  TextModule.cs — текстовий модуль будь-якого формату (з Bible/TextModule.swift)
// =============================================================================

namespace Slovo.Core;

/// Текстовий модуль — книга, доступна для показу, незалежно від формату файла.
///
/// Оригінальна програма працює і з модулями «Цитати з Біблії» (тека з
/// `bibleqt.ini` і HTML), і з модулями MyBible (одна база SQLite). Решті
/// застосунку різниця байдужа, тому вона закінчується тут: далі йдуть книги,
/// розділи і вірші. (Ім'я — як у Swift, без звичного для .NET «I».)
public interface TextModule
{
    /// Ім'я теки або файлу — ним модуль упізнається в налаштуваннях і в порядку вкладок.
    string Identifier { get; }
    ModuleInfo Info { get; }
    IReadOnlyList<BookInfo> Books { get; }
    TextModuleFormat Format { get; }

    /// Розділи книги (`chapters(ofBook:)`); кидає виняток, як `throws`.
    IReadOnlyList<Chapter> Chapters(BookInfo book);
    /// Уже розібрана книга, якщо вона є в кеші.
    IReadOnlyList<Chapter>? CachedChapters(BookInfo book);
    void ReleaseCache();
}

public enum TextModuleFormat { BibleQuote, MyBible, MySword }

public static class TextModuleExtensions
{
    public static string RawValue(this TextModuleFormat format) => format switch
    {
        TextModuleFormat.BibleQuote => "bibleQuote",
        TextModuleFormat.MyBible => "myBible",
        _ => "mySword",
    };

    public static string Title(this TextModuleFormat format) => format switch
    {
        TextModuleFormat.BibleQuote => OurWords.T("Цитата из Библии"),
        TextModuleFormat.MyBible => "MyBible",
        _ => "MySword",
    };

    extension(TextModule module)
    {
        public string DisplayName => module.Info.Name.Length == 0 ? module.Identifier : module.Info.Name;

        /// Розділ за номером (`chapter(_:ofBook:)`); кидає виняток, як `throws`.
        public Chapter? Chapter(int number, BookInfo book) =>
            module.Chapters(book).FirstOrDefault(chapter => chapter.Number == number);

        /// Пошук книги за будь-яким з її скорочень або за повною назвою.
        public BookInfo? Book(string token)
        {
            var needle = Fold(token);
            return module.Books.FirstOrDefault(book =>
                book.ShortNames.Any(name => Fold(name) == needle) || Fold(book.FullName) == needle);
        }

        /// Та сама книга в іншому перекладі.
        ///
        /// Спершу за наскрізним номером канону, і лише якщо його немає — за
        /// порядковим. Порядковий лишено як запасний шлях для модулів, де книгу
        /// впізнати не вдалося: краще показати сусідню, ніж нічого.
        public BookInfo? Counterpart(BookInfo book)
        {
            if (book.CanonicalNumber is { } canonical
                && module.Books.FirstOrDefault(other => other.CanonicalNumber == canonical) is { } match)
                return match;
            return book.Index >= 0 && book.Index < module.Books.Count ? module.Books[book.Index] : null;
        }
    }

    private static string Fold(string text) =>
        new(SwiftText.Fold(text).Where(c => !char.IsWhiteSpace(c) && c != '.').ToArray());
}
