package ua.church.slovo.remote;

import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CharsetDecoder;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.zip.DataFormatException;
import java.util.zip.Inflater;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

/// Читання модулів різних форматів у бібліотеку планшета.
///
/// Правила розбору перенесено з програми «Слово» (SlovoCore: BibleQuoteIni,
/// ChapterHTML, HTMLText, CanonicalBook, CodePage, SongBook), щоб вірш на
/// планшеті був тим самим текстом, що й на слайді в залі.
final class ModuleReaders {

    private ModuleReaders() { }

    /// Файл не той, яким себе називає, або зіпсований — сказати людині словами.
    static final class Refused extends IOException {
        Refused(String reason) { super(reason); }
    }

    // MARK: Переклад від «Слова»

    /// Рядки SLOVO-BIBLE, які віддає програма (`/api/library/bible`).
    static String readSlovoBible(Library library, InputStream in) throws IOException {
        BufferedReader reader = new BufferedReader(new InputStreamReader(in, StandardCharsets.UTF_8), 65536);
        String header = reader.readLine();
        if (header == null || !header.startsWith("SLOVO-BIBLE")) throw new Refused(Lang.t("Це не переклад від «Слова»", "This is not a translation from Slovo"));
        String meta = reader.readLine();
        String[] m = meta == null ? new String[0] : meta.split("\t", -1);
        if (m.length < 4 || !"M".equals(m[0])) throw new Refused(Lang.t("У відповіді немає опису перекладу", "The answer has no translation description"));
        String id = "slovo:" + m[1];
        Library.Writer writer = library.write(id, Library.BIBLE, m[2], m[3], "slovo", "");
        try {
            int book = -1;
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith("V\t")) {
                    String[] v = line.split("\t", 4);
                    if (v.length == 4 && book >= 0) writer.verse(book, number(v[1]), number(v[2]), v[3]);
                } else if (line.startsWith("B\t")) {
                    String[] b = line.split("\t", -1);
                    if (b.length >= 6) {
                        book = number(b[1]);
                        writer.book(book, b[2].isEmpty() ? 0 : number(b[2]), b[3], b[4], number(b[5]));
                    }
                }
            }
            if (writer.verses == 0) throw new Refused(Lang.t("Переклад прийшов порожнім", "The translation arrived empty"));
            writer.commit();
        } catch (IOException | RuntimeException error) {
            writer.abort();
            throw error;
        }
        return id;
    }

    // MARK: «Цитата з Біблії» (BibleQuote)

    /// Модуль у zip-архіві — з GitHub чи з файла.
    static String importBibleQuoteZip(Library library, File zip, String id, String source, File cache) throws IOException {
        File folder = new File(cache, "bq-" + System.nanoTime());
        try {
            unzip(zip, folder);
            File ini = findIni(folder, 0);
            if (ini == null) throw new Refused(Lang.t("В архіві немає bibleqt.ini — це не модуль «Цитати з Біблії»", "The archive has no bibleqt.ini — not a Bible Quote module"));
            return importBibleQuoteFolder(library, ini, id, source, zip.getPath());
        } finally {
            deleteTree(folder);
        }
    }

    private static String importBibleQuoteFolder(Library library, File iniFile, String id, String source,
                                                 String original) throws IOException {
        Ini ini = parseIni(readAll(iniFile));
        if (ini.books.isEmpty()) throw new Refused(Lang.t("У bibleqt.ini немає жодної книги", "bibleqt.ini lists no books"));
        if (!ini.isBible) throw new Refused(Lang.t("Це не Біблія (коментар, словник чи книга) — у план її не взяти", "Not a Bible (a commentary, dictionary or book) — it cannot go into a plan"));
        int[] canon = CanonicalBook.assign(ini.books);
        Library.Writer writer = library.write(id, Library.BIBLE, ini.name, ini.shortName, source, original);
        try {
            File folder = iniFile.getParentFile();
            Set<String> drop = ini.strong ? Collections.singleton("s") : Collections.<String>emptySet();
            for (int index = 0; index < ini.books.size(); index++) {
                IniBook book = ini.books.get(index);
                writer.book(index, canon[index], book.full.isEmpty() ? book.path : book.full,
                    join(book.shorts), book.chapters);
                File file = resolve(folder, book.path);
                if (file == null) continue;
                String html = decode(readAll(file), ini.charset);
                parseBook(html, ini, book.chapters, index, drop, writer);
            }
            if (writer.verses == 0) throw new Refused(Lang.t("У модулі не знайшлося жодного вірша", "No verses were found in the module"));
            writer.commit();
        } catch (IOException | RuntimeException error) {
            writer.abort();
            throw error;
        }
        return id;
    }

    static final class IniBook {
        String path = "";
        String full = "";
        List<String> shorts = new ArrayList<>();
        int chapters;
    }

    static final class Ini {
        String name = "";
        String shortName = "";
        String chapterSign = "";
        String verseSign = "";
        boolean isBible = true;
        boolean strong;
        boolean chapterZero;
        Charset charset;
        final List<IniBook> books = new ArrayList<>();
    }

    /// Розбір `bibleqt.ini`. Кодування ini дізнаємося з нього ж, тому читаємо
    /// двічі: спершу «як вийде», щоб витягти DefaultEncoding/DesiredFontCharset,
    /// потім уже правильно.
    static Ini parseIni(byte[] data) {
        String probe = decode(data, null);
        Charset declared = null;
        Charset font = null;
        for (String raw : probe.split("\r?\n|\r")) {
            int eq = raw.indexOf('=');
            if (eq < 0) continue;
            String key = raw.substring(0, eq).trim().toLowerCase(Locale.ROOT);
            String value = raw.substring(eq + 1).trim();
            if (key.equals("defaultencoding") && declared == null) declared = charsetForName(value);
            if (key.equals("desiredfontcharset") && font == null) {
                try { font = charsetForFont(Integer.parseInt(value)); } catch (NumberFormatException ignored) { }
            }
        }
        Charset chosen = declared != null ? declared : (isStrictUtf8(data) ? StandardCharsets.UTF_8 : font);
        String text = decode(data, chosen);

        Ini ini = new Ini();
        ini.charset = chosen;
        IniBook pending = null;
        for (String raw : text.split("\r?\n|\r")) {
            String line = raw.trim();
            if (line.isEmpty() || line.startsWith("//") || line.startsWith(";")) continue;
            int eq = line.indexOf('=');
            if (eq < 0) continue;
            String key = line.substring(0, eq).trim().toLowerCase(Locale.ROOT);
            String value = line.substring(eq + 1).trim();
            switch (key) {
                case "biblename": ini.name = value; break;
                case "bibleshortname": ini.shortName = value; break;
                case "bible": ini.isBible = isYes(value); break;
                case "strongnumbers": ini.strong = isYes(value); break;
                case "chapterzero": ini.chapterZero = isYes(value); break;
                case "chaptersign": ini.chapterSign = value.toLowerCase(Locale.ROOT); break;
                case "versesign": ini.verseSign = value.toLowerCase(Locale.ROOT); break;
                case "pathname":
                    if (pending != null && !pending.path.isEmpty()) ini.books.add(pending);
                    pending = new IniBook();
                    pending.path = value;
                    break;
                case "fullname":
                    if (pending != null) pending.full = value;
                    break;
                case "shortname":
                    if (pending != null) {
                        pending.shorts.clear();
                        for (String part : value.split(" ")) if (!part.isEmpty()) pending.shorts.add(part);
                    }
                    break;
                case "chapterqty":
                    if (pending != null) pending.chapters = number(value);
                    break;
                default:
                    break;
            }
        }
        if (pending != null && !pending.path.isEmpty()) ini.books.add(pending);
        if (ini.shortName.isEmpty()) {
            ini.shortName = ini.name.isEmpty() ? "?" : ini.name.substring(0, Math.min(8, ini.name.length()));
        }
        return ini;
    }

    private static boolean isYes(String value) {
        String v = value.toLowerCase(Locale.ROOT);
        return v.startsWith("y") || v.equals("1") || v.equals("true");
    }

    // MARK: Розділи й вірші (ChapterHTML)

    /// Файл книги — на розділи й вірші за маркерами `ChapterSign` і `VerseSign`.
    ///
    /// Просто рахувати входження `ChapterSign` не можна: зайвий заголовок у
    /// шапці файла розбиває книгу на зайвий розділ. Але й відкидати входження
    /// без номера не можна: 151-й псалом у Синодальному позначено без цифр.
    /// Тому, як і програма, будуємо обидва прочитання і беремо те, що ближче
    /// до `ChapterQty`.
    static void parseBook(String html, Ini ini, int expected, int bookIndex, Set<String> drop,
                          Library.Writer writer) {
        int first = ini.chapterZero ? 0 : 1;
        List<int[]> starts = chapterStarts(html, ini, expected);
        if (starts.isEmpty()) {
            parseVerses(html, ini.verseSign, bookIndex, first, drop, writer);
            return;
        }
        int number = first;
        for (int i = 0; i < starts.size(); i++) {
            int end = i + 1 < starts.size() ? starts.get(i + 1)[0] : html.length();
            parseVerses(html.substring(starts.get(i)[1], end), ini.verseSign, bookIndex, number, drop, writer);
            number++;
        }
    }

    private static List<int[]> chapterStarts(String text, Ini ini, int expected) {
        List<int[]> chapterMarks = occurrences(ini.chapterSign, text);
        if (chapterMarks.isEmpty()) return chapterMarks;
        List<int[]> verseMarks = occurrences(ini.verseSign, text);
        List<int[]> all = new ArrayList<>(chapterMarks);
        all.addAll(verseMarks);
        Collections.sort(all, (a, b) -> Integer.compare(a[0], b[0]));

        List<int[]> strict = new ArrayList<>();
        for (int[] mark : chapterMarks) {
            int headEnd = text.length();
            for (int[] other : all) {
                if (other[0] >= mark[1]) { headEnd = other[0]; break; }
            }
            if (headEnd <= mark[1]) continue;
            boolean digit = false;
            for (int i = mark[1]; i < headEnd; i++) {
                if (Character.isDigit(text.charAt(i))) { digit = true; break; }
            }
            if (digit) strict.add(mark);
        }
        if (expected <= 0) return strict;
        return Math.abs(chapterMarks.size() - expected) < Math.abs(strict.size() - expected) ? chapterMarks : strict;
    }

    private static void parseVerses(String slice, String verseSign, int bookIndex, int chapter, Set<String> drop,
                                    Library.Writer writer) {
        List<int[]> marks = occurrences(verseSign, slice);
        int fallback = 1;
        for (int i = 0; i < marks.size(); i++) {
            int end = i + 1 < marks.size() ? marks.get(i + 1)[0] : slice.length();
            int cursor = marks.get(i)[1];
            while (cursor < end && (Character.isWhitespace(slice.charAt(cursor)) || slice.charAt(cursor) == '\u200B')) cursor++;
            int digitsStart = cursor;
            while (cursor < end && Character.isDigit(slice.charAt(cursor))) cursor++;
            int number = fallback;
            if (cursor > digitsStart) {
                number = number(slice.substring(digitsStart, cursor));
                // Номер, обгорнутий у тег (`<sup>12</sup>текст`), — з'їдаємо закривальний тег.
                int look = cursor;
                while (look < end && Character.isWhitespace(slice.charAt(look))) look++;
                if (look + 1 < end && slice.charAt(look) == '<' && slice.charAt(look + 1) == '/') {
                    int close = slice.indexOf('>', look);
                    if (close >= 0 && close < end) cursor = close + 1;
                }
            }
            fallback = number + 1;
            String text = plain(slice.substring(cursor, end), drop);
            if (!text.isEmpty()) writer.verse(bookIndex, chapter, number, text);
        }
    }

    /// Усі входження маркера без урахування регістру: [початок, кінець].
    private static List<int[]> occurrences(String marker, String text) {
        List<int[]> found = new ArrayList<>();
        if (marker == null || marker.isEmpty()) return found;
        int length = marker.length();
        int from = 0;
        while (from + length <= text.length()) {
            int at = -1;
            for (int i = from; i + length <= text.length(); i++) {
                if (text.regionMatches(true, i, marker, 0, length)) { at = i; break; }
            }
            if (at < 0) break;
            found.add(new int[] { at, at + length });
            from = at + length;
        }
        return found;
    }

    // MARK: HTML — у чистий текст (HTMLText)

    /// `drop` — теги, у яких викидається й уміст (номери Стронга `<s>7225</s>`).
    static String plain(String html, Set<String> drop) {
        StringBuilder out = new StringBuilder(html.length());
        int i = 0;
        int n = html.length();
        String skipping = null;
        while (i < n) {
            char ch = html.charAt(i);
            if (ch != '<') {
                if (skipping == null) out.append(ch);
                i++;
                continue;
            }
            int close = html.indexOf('>', i);
            if (close < 0) {
                if (skipping == null) out.append(html, i, n);
                break;
            }
            String body = html.substring(i + 1, close);
            String name = tagName(body);
            if (skipping != null) {
                if (body.startsWith("/") && name.equals(skipping)) skipping = null;
            } else if (!body.startsWith("/") && !body.endsWith("/") && drop.contains(name)) {
                skipping = name;
            } else if (isBreak(name)) {
                out.append(' ');
            }
            i = close + 1;
        }
        return condense(decodeEntities(out.toString()).replace("\u200B", ""));
    }

    private static String tagName(String body) {
        String rest = body.startsWith("/") ? body.substring(1) : body;
        int end = rest.length();
        for (int i = 0; i < rest.length(); i++) {
            char c = rest.charAt(i);
            if (c == ' ' || c == '\t' || c == '/' || c == '\n') { end = i; break; }
        }
        return rest.substring(0, end).toLowerCase(Locale.ROOT);
    }

    private static boolean isBreak(String name) {
        return name.equals("br") || name.equals("p") || name.equals("div") || name.equals("pb")
            || name.equals("td") || name.equals("tr");
    }

    private static final Map<String, String> ENTITIES = new HashMap<>();
    static {
        ENTITIES.put("nbsp", "\u00A0");
        ENTITIES.put("amp", "&");
        ENTITIES.put("lt", "<");
        ENTITIES.put("gt", ">");
        ENTITIES.put("quot", "\"");
        ENTITIES.put("apos", "'");
        ENTITIES.put("mdash", "—");
        ENTITIES.put("ndash", "–");
        ENTITIES.put("hellip", "…");
        ENTITIES.put("laquo", "«");
        ENTITIES.put("raquo", "»");
    }

    static String decodeEntities(String text) {
        if (text.indexOf('&') < 0) return text;
        StringBuilder out = new StringBuilder(text.length());
        int i = 0;
        while (i < text.length()) {
            char ch = text.charAt(i);
            int semi = ch == '&' ? text.indexOf(';', i) : -1;
            if (semi > i && semi - i <= 12) {
                String body = text.substring(i + 1, semi);
                String replacement = null;
                if (body.startsWith("#")) {
                    try {
                        int code = body.startsWith("#x") || body.startsWith("#X")
                            ? Integer.parseInt(body.substring(2), 16) : Integer.parseInt(body.substring(1));
                        if (Character.isValidCodePoint(code)) replacement = new String(Character.toChars(code));
                    } catch (NumberFormatException ignored) { }
                } else {
                    replacement = ENTITIES.get(body.toLowerCase(Locale.ROOT));
                }
                if (replacement != null) {
                    out.append(replacement);
                    i = semi + 1;
                    continue;
                }
            }
            out.append(ch);
            i++;
        }
        return out.toString();
    }

    private static String condense(String text) {
        StringBuilder out = new StringBuilder(text.length());
        boolean space = false;
        for (int i = 0; i < text.length(); i++) {
            char ch = text.charAt(i);
            if (Character.isWhitespace(ch) || ch == '\u00A0') {
                if (!space && out.length() > 0) out.append(' ');
                space = true;
            } else {
                out.append(ch);
                space = false;
            }
        }
        int end = out.length();
        while (end > 0 && out.charAt(end - 1) == ' ') end--;
        return out.substring(0, end);
    }

    // MARK: MyBible

    /// Модуль MyBible (`.SQLite3`): таблиці `info`, `books`, `verses`. Номери книг
    /// у ньому — ті самі наскрізні номери канону, що й у програмі.
    static String importMyBible(Library library, File file, String id, String source) throws IOException {
        SQLiteDatabase db;
        try {
            db = SQLiteDatabase.openDatabase(file.getPath(), null,
                SQLiteDatabase.OPEN_READONLY | SQLiteDatabase.NO_LOCALIZED_COLLATORS);
        } catch (RuntimeException error) {
            throw new Refused(Lang.t("Файл не відкривається як модуль MyBible", "The file does not open as a MyBible module"));
        }
        try {
            String name = info(db, "description");
            String base = file.getName().replaceAll("(?i)\\.sqlite3$", "");
            Library.Writer writer = library.write(id, Library.BIBLE, name.isEmpty() ? base : name, base, source, file.getPath());
            try {
                Set<String> drop = new HashSet<>();
                drop.add("s");
                drop.add("m");
                drop.add("f");
                Map<Integer, Integer> position = new HashMap<>();
                try (Cursor c = db.rawQuery("SELECT b.book_number, b.short_name, b.long_name, MAX(v.chapter)"
                        + " FROM books AS b JOIN verses AS v ON v.book_number = b.book_number"
                        + " GROUP BY b.book_number, b.short_name, b.long_name ORDER BY b.book_number", null)) {
                    int index = 0;
                    while (c.moveToNext()) {
                        int number = c.getInt(0);
                        position.put(number, index);
                        writer.book(index, number, c.getString(2), c.getString(1), c.getInt(3));
                        index++;
                    }
                }
                try (Cursor c = db.rawQuery("SELECT book_number, chapter, verse, text FROM verses"
                        + " ORDER BY book_number, chapter, verse", null)) {
                    while (c.moveToNext()) {
                        Integer book = position.get(c.getInt(0));
                        if (book == null) continue;
                        String text = plain(c.getString(3) == null ? "" : c.getString(3), drop);
                        if (!text.isEmpty()) writer.verse(book, c.getInt(1), c.getInt(2), text);
                    }
                }
                if (writer.verses == 0) throw new Refused(Lang.t("У модулі не знайшлося жодного вірша", "No verses were found in the module"));
                writer.commit();
            } catch (IOException | RuntimeException error) {
                writer.abort();
                if (error instanceof IOException) throw (IOException) error;
                throw new Refused(Lang.t("Модуль MyBible не прочитався: ", "The MyBible module could not be read: ") + error.getMessage());
            }
        } finally {
            db.close();
        }
        return id;
    }

    private static String info(SQLiteDatabase db, String key) {
        try (Cursor c = db.rawQuery("SELECT value FROM info WHERE name = ?", new String[] { key })) {
            return c.moveToNext() && c.getString(0) != null ? c.getString(0).trim() : "";
        } catch (RuntimeException error) {
            return "";
        }
    }

    // MARK: Пісенник у старому форматі (.vbm)

    /// Короткий заголовок і один zlib-потік; рядки всередині — UInt16 з числом
    /// символів і самі символи в UTF-16LE (див. SongBook.swift у програмі).
    static String importVbm(Library library, byte[] data, String fileName, String source, String original)
            throws IOException {
        byte[] magic = "VisioBibleModule".getBytes(StandardCharsets.US_ASCII);
        if (data.length <= 24) throw new Refused("«" + fileName + Lang.t("»: це не пісенник .vbm", "»: not a .vbm songbook"));
        for (int i = 0; i < magic.length; i++) {
            if (data[i] != magic[i]) throw new Refused("«" + fileName + Lang.t("»: це не пісенник .vbm", "»: not a .vbm songbook"));
        }
        long compressed = u32(data, 20);
        long start = data.length - 4 - compressed;
        if (start <= 16 || start >= data.length) throw new Refused("«" + fileName + Lang.t("»: файл пошкоджено", "»: the file is damaged"));
        byte[] body = inflate(data, (int) start, fileName);
        Reader reader = new Reader(body);

        String title = reader.string();
        String shortName = reader.string();
        reader.string(); // видавець
        reader.string(); // дата редакції
        reader.string(); // коментар
        long count = reader.u32();
        if (count < 0 || count > 100_000) throw new Refused("«" + fileName + Lang.t("»: файл пошкоджено", "»: the file is damaged"));

        // Ім'я файла — з регістром: під ним пісенник лежить і в програмі.
        String id = "songs:" + fileName;
        Library.Writer writer = library.write(id, Library.SONGS, title.isEmpty() ? fileName : title,
            shortName, source, original);
        try {
            for (int index = 0; index < count; index++) {
                String songTitle = reader.string();
                reader.string(); // друга назва
                reader.string(); // автор слів
                reader.string(); // композитор
                reader.string(); // примітка
                reader.string(); // властивості
                long parts = reader.u32();
                if (parts < 0 || parts > 1000) throw new Refused("«" + fileName + Lang.t("»: файл пошкоджено", "»: the file is damaged"));
                writer.song(index, songTitle);
                for (int part = 0; part < parts; part++) {
                    String kind = reader.string();
                    String text = reader.string();
                    reader.u32(); // вирівнювання тексту частини
                    writer.part(index, part, kind, text);
                }
            }
            writer.commit();
        } catch (IOException | RuntimeException error) {
            writer.abort();
            if (error instanceof IOException) throw (IOException) error;
            throw new Refused("«" + fileName + Lang.t("»: файл пошкоджено", "»: the file is damaged"));
        }
        return id;
    }

    private static long u32(byte[] data, int offset) {
        return (data[offset] & 0xFFL) | (data[offset + 1] & 0xFFL) << 8
            | (data[offset + 2] & 0xFFL) << 16 | (data[offset + 3] & 0xFFL) << 24;
    }

    private static byte[] inflate(byte[] data, int start, String fileName) throws IOException {
        Inflater inflater = new Inflater();
        inflater.setInput(data, start, data.length - start);
        ByteArrayOutputStream out = new ByteArrayOutputStream(data.length * 4);
        byte[] chunk = new byte[65536];
        try {
            while (!inflater.finished()) {
                int count = inflater.inflate(chunk);
                if (count == 0 && (inflater.needsInput() || inflater.needsDictionary())) break;
                out.write(chunk, 0, count);
            }
        } catch (DataFormatException error) {
            throw new Refused("«" + fileName + Lang.t("»: не вдалося розпакувати пісенник", "»: could not unpack the songbook"));
        } finally {
            inflater.end();
        }
        return out.toByteArray();
    }

    private static final class Reader {
        private final byte[] data;
        private int offset;

        Reader(byte[] data) { this.data = data; }

        long u32() {
            if (offset + 4 > data.length) throw new IllegalStateException("кінець даних");
            long value = ModuleReaders.u32(data, offset);
            offset += 4;
            return value;
        }

        String string() {
            if (offset + 2 > data.length) throw new IllegalStateException("кінець даних");
            int count = (data[offset] & 0xFF) | (data[offset + 1] & 0xFF) << 8;
            offset += 2;
            if (offset + count * 2 > data.length) throw new IllegalStateException("кінець даних");
            String value = new String(data, offset, count * 2, StandardCharsets.UTF_16LE);
            offset += count * 2;
            return value;
        }
    }

    // MARK: Кодування (CodePage)

    /// Оголошене кодування, потім суворий UTF-8, потім CP1251 і CP1252.
    static String decode(byte[] data, Charset declared) {
        List<Charset> candidates = new ArrayList<>();
        if (declared != null) candidates.add(declared);
        candidates.add(StandardCharsets.UTF_8);
        Charset cp1251 = charset("windows-1251");
        if (cp1251 != null) candidates.add(cp1251);
        Charset cp1252 = charset("windows-1252");
        if (cp1252 != null) candidates.add(cp1252);
        for (Charset charset : candidates) {
            String text = strict(data, charset);
            if (text != null && !text.isEmpty()) return stripBom(text);
        }
        return stripBom(new String(data, StandardCharsets.UTF_8));
    }

    private static String strict(byte[] data, Charset charset) {
        CharsetDecoder decoder = charset.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT);
        try {
            return decoder.decode(ByteBuffer.wrap(data)).toString();
        } catch (CharacterCodingException error) {
            return null;
        }
    }

    private static boolean isStrictUtf8(byte[] data) {
        return strict(data, StandardCharsets.UTF_8) != null;
    }

    private static String stripBom(String text) {
        return text.startsWith("\uFEFF") ? text.substring(1) : text;
    }

    private static Charset charset(String name) {
        try {
            return Charset.forName(name);
        } catch (RuntimeException error) {
            return null;
        }
    }

    static Charset charsetForName(String raw) {
        String name = raw.trim().toLowerCase(Locale.ROOT);
        if (name.equals("utf-8") || name.equals("utf8")) return StandardCharsets.UTF_8;
        if (name.equals("utf-16") || name.equals("utf16")) return StandardCharsets.UTF_16;
        if (name.startsWith("cp125") && name.length() == 6) return charset("windows-" + name.substring(2));
        if (name.startsWith("windows-125")) return charset(name);
        return null;
    }

    static Charset charsetForFont(int code) {
        switch (code) {
            case 0: return charset("windows-1252");
            case 161: return charset("windows-1253");
            case 162: return charset("windows-1254");
            case 163: return charset("windows-1258");
            case 177: return charset("windows-1255");
            case 178: return charset("windows-1256");
            case 186: return charset("windows-1257");
            case 204: return charset("windows-1251");
            case 238: return charset("windows-1250");
            default: return null;
        }
    }

    // MARK: Файли

    /// Розпакувати архів у теку. Шляхи, що виходять за теку, пропускаємо.
    static void unzip(File zip, File folder) throws IOException {
        if (!folder.mkdirs() && !folder.isDirectory()) throw new IOException("Не вдалося створити теку для розпаковки");
        String root = folder.getCanonicalPath() + File.separator;
        try (ZipInputStream in = new ZipInputStream(new FileInputStream(zip))) {
            ZipEntry entry;
            byte[] chunk = new byte[65536];
            while ((entry = in.getNextEntry()) != null) {
                File target = new File(folder, entry.getName());
                if (!target.getCanonicalPath().startsWith(root)) continue;
                if (entry.isDirectory()) {
                    //noinspection ResultOfMethodCallIgnored
                    target.mkdirs();
                    continue;
                }
                File parent = target.getParentFile();
                if (parent != null) {
                    //noinspection ResultOfMethodCallIgnored
                    parent.mkdirs();
                }
                try (OutputStream out = new FileOutputStream(target)) {
                    int count;
                    while ((count = in.read(chunk)) > 0) out.write(chunk, 0, count);
                }
            }
        } catch (IllegalArgumentException error) {
            // Імена в архіві не в UTF-8 — Android 5–6 інших не читає.
            throw new Refused(Lang.t("Архів не розпаковується: імена файлів у незнайомому кодуванні", "The archive does not unpack: file names use an unknown encoding"));
        }
    }

    private static File findIni(File folder, int depth) {
        File[] files = folder.listFiles();
        if (files == null) return null;
        for (File file : files) {
            if (file.isFile() && file.getName().equalsIgnoreCase("bibleqt.ini")) return file;
        }
        if (depth >= 3) return null;
        for (File file : files) {
            if (file.isDirectory()) {
                File found = findIni(file, depth + 1);
                if (found != null) return found;
            }
        }
        return null;
    }

    /// Регістр імен в ini і на диску збігається не завжди.
    private static File resolve(File folder, String name) {
        File direct = new File(folder, name.replace('\\', '/'));
        if (direct.isFile()) return direct;
        File[] files = folder.listFiles();
        if (files == null) return null;
        for (File file : files) {
            if (file.getName().equalsIgnoreCase(name)) return file;
        }
        return null;
    }

    static byte[] readAll(File file) throws IOException {
        try (InputStream in = new FileInputStream(file)) {
            return readAll(in);
        }
    }

    static byte[] readAll(InputStream in) throws IOException {
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        byte[] chunk = new byte[65536];
        int count;
        while ((count = in.read(chunk)) > 0) out.write(chunk, 0, count);
        return out.toByteArray();
    }

    static void deleteTree(File file) {
        File[] children = file.listFiles();
        if (children != null) for (File child : children) deleteTree(child);
        //noinspection ResultOfMethodCallIgnored
        file.delete();
    }

    private static int number(String text) {
        try {
            return Integer.parseInt(text.trim());
        } catch (NumberFormatException error) {
            return 0;
        }
    }

    private static String join(List<String> parts) {
        StringBuilder out = new StringBuilder();
        for (String part : parts) {
            if (out.length() > 0) out.append(' ');
            out.append(part);
        }
        return out.toString();
    }

    // MARK: Наскрізна нумерація книг (CanonicalBook)

    static final class CanonicalBook {

        private CanonicalBook() { }

        private static final Object[][] TABLE = {
            { 10, "ge gen gn genesis" }, { 20, "ex exo exod exodus" }, { 30, "le lev lv leviticus levit" },
            { 40, "nu num nm numb numbers" }, { 50, "de deu deut dt deuteron deuteronomy" },
            { 60, "jos josh joshua" }, { 70, "jdg judg judge judges" }, { 80, "ru rut rth rt ruth" },
            { 90, "1sa 1s 1sam 1sm 1sml 1samuel" }, { 100, "2sa 2s 2sam 2sm 2sml 2samuel" },
            { 110, "1ki 1k 1kn 1kg 1king 1kng 1kings" }, { 120, "2ki 2k 2kn 2kg 2king 2kng 2kings" },
            { 130, "1ch 1chr 1chron 1chronicles 1par" }, { 140, "2ch 2chr 2chron 2chronicles 2par" },
            { 150, "ezr ezra" }, { 160, "ne neh nehemiah" }, { 190, "es est esth esther" },
            { 220, "job jb" }, { 230, "ps psa psalm psalms psm" }, { 240, "pr pro prov proverbs" },
            { 250, "ec ecc eccl ecclesiastes" }, { 260, "so son song sos songofsongs canticles" },
            { 290, "isa is isaiah" }, { 300, "jer je jeremiah" }, { 310, "la lam lamentations" },
            { 330, "eze ezk ezek ezekiel" }, { 340, "da dan daniel" }, { 350, "ho hos hosea" },
            { 360, "joe jol joel" }, { 370, "am amo amos" }, { 380, "ob oba obad obadiah" },
            { 390, "jon jnh jonah" }, { 400, "mic mi micah" }, { 410, "na nah nahum" },
            { 420, "hab hb habakkuk" }, { 430, "zep zph zephaniah" }, { 440, "hag hg haggai" },
            { 450, "zec zch zechariah" }, { 460, "mal ml malachi" }, { 470, "mt mat matt matthew" },
            { 480, "mr mk mar mark" }, { 490, "lu lk luk luke" }, { 500, "joh jn john" },
            { 510, "ac act acts" }, { 520, "ro rom romans" }, { 530, "1co 1cor 1corinthians" },
            { 540, "2co 2cor 2corinthians" }, { 550, "ga gal galatians" }, { 560, "eph ep ephesians" },
            { 570, "php phil philippians" }, { 580, "col cl colossians" },
            { 590, "1th 1thes 1thess 1thessalonians" }, { 600, "2th 2thes 2thess 2thessalonians" },
            { 610, "1ti 1tim 1timothy" }, { 620, "2ti 2tim 2timothy" }, { 630, "tit tt titus" },
            { 640, "phm phlm philemon" }, { 650, "heb hebrews" }, { 660, "jas jam jm james" },
            { 670, "1pe 1pet 1pt 1peter" }, { 680, "2pe 2pet 2pt 2peter" }, { 690, "1jo 1jn 1john" },
            { 700, "2jo 2jn 2john" }, { 710, "3jo 3jn 3john" }, { 720, "jud jde jude" },
            { 730, "re rev rv revelation apocalypse" },
            // Неканонічні книги — ті самі номери, що в MyBible.
            { 165, "2ezr 2ездр 2езд 2ездра 2ездры 1esd 1esdras" }, { 468, "3ezr 3ездр 3езд 3ездра 3ездры 2esdras" },
            { 170, "tob тов товит tobit tobias tobías" }, { 180, "jdt иудиф иудифь иудф judith judf judth judit" },
            { 270, "wis прем премудр премудрсоломона премудрсоломон премсол wisdom sabiduria" },
            { 280, "sir сир сирах ecclesiasticus eclesiastico" }, { 315, "послиер послиерем послиеремии epjer letjer" },
            { 320, "bar вар варух baruch baruc" }, { 462, "1mac 1макк 1мак 1маккав 1maccabees 1mach" },
            { 464, "2mac 2макк 2мак 2маккав 2maccabees 2mach" }, { 466, "3mac 3макк 3мак 3маккав 3maccabees 3mach" },
            { 790, "молман молитваманассии manasseh prman" },
            // Національні скорочення, зустрінуті в справжніх модулях.
            { 60, "ios iosua joz jozue" }, { 70, "sdz sedz sedziow sędz sędziów judecatori" },
            { 110, "1im 1imp 1imparati 1krl" }, { 120, "2im 2imp 2imparati 2krl" },
            { 130, "1cr 1cron 1cronici 1krn" }, { 140, "2cr 2cron 2cronici 2krn" }, { 220, "iov hi hiob" },
            { 260, "cant cc cantarea pnp" }, { 300, "ie ier ieremia" }, { 310, "plang pl plangerile lm" },
            { 350, "os osea oz" }, { 360, "ioel" }, { 380, "ab abd abdias abdia abdiasza" },
            { 390, "iona jon" }, { 430, "tef tefania sofoniasza sofonia" },
        };

        private static final Map<String, Integer> BY_ALIAS = new HashMap<>();
        private static final int[] ORDER = new int[66];
        static {
            for (int i = 0; i < TABLE.length; i++) {
                int number = (Integer) TABLE[i][0];
                if (i < 66) ORDER[i] = number;
                for (String alias : ((String) TABLE[i][1]).split(" ")) {
                    if (!BY_ALIAS.containsKey(alias)) BY_ALIAS.put(alias, number);
                }
            }
        }

        static int number(String raw) {
            StringBuilder key = new StringBuilder();
            String lower = raw.toLowerCase(Locale.ROOT);
            for (int i = 0; i < lower.length(); i++) {
                char c = lower.charAt(i);
                if (Character.isLetterOrDigit(c)) key.append(c);
            }
            Integer found = BY_ALIAS.get(key.toString());
            return found == null ? 0 : found;
        }

        /// Наскрізні номери книг модуля: спершу за скороченнями, а для повної
        /// Біблії з 66 книг у звичайному порядку — за місцем у списку.
        static int[] assign(List<IniBook> books) {
            int[] recognised = new int[books.size()];
            for (int i = 0; i < books.size(); i++) {
                IniBook book = books.get(i);
                int found = 0;
                for (String alias : book.shorts) {
                    found = number(alias);
                    if (found != 0) break;
                }
                if (found == 0) found = number(book.full);
                recognised[i] = found;
            }
            if (books.size() != ORDER.length) return recognised;
            int agreed = 0;
            int disagreed = 0;
            for (int i = 0; i < ORDER.length; i++) {
                if (recognised[i] == 0) continue;
                if (recognised[i] == ORDER[i]) agreed++; else disagreed++;
            }
            if (agreed < 40 || disagreed * 10 > agreed) return recognised;
            return ORDER.clone();
        }
    }
}
