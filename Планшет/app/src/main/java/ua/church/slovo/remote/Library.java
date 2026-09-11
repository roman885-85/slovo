package ua.church.slovo.remote;

import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.database.sqlite.SQLiteOpenHelper;
import android.database.sqlite.SQLiteStatement;

import java.io.File;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/// Своя бібліотека планшета: переклади й пісенники, з якими проповідник
/// складає план удома, без зв'язку з програмою.
///
/// Звідки б модуль не прийшов — зі «Слова» по Wi-Fi, з GitHub чи з файла на
/// планшеті, — він лягає в одну базу однаковими рядками: книга, розділ, вірш,
/// текст. Екран плану тому не знає, якого формату був модуль.
///
/// Разом із модулем з GitHub чи з файла зберігається й сам файл (`original`):
/// якщо в програмі на служінні такого перекладу не виявиться, планшет відвезе
/// їй саме його, і програма поставить модуль собі.
final class Library extends SQLiteOpenHelper {

    static final String BIBLE = "bible";
    static final String SONGS = "songs";

    static final class Module {
        final String id;
        final String kind;
        final String name;
        final String shortName;
        /// «slovo», «github» чи «file».
        final String source;
        /// Шлях до збереженого файла модуля; порожньо — модуль прийшов зі «Слова».
        final String original;

        Module(String id, String kind, String name, String shortName, String source, String original) {
            this.id = id;
            this.kind = kind;
            this.name = name;
            this.shortName = shortName;
            this.source = source;
            this.original = original;
        }
    }

    static final class Book {
        final int index;
        /// Наскрізний номер канону (Буття — 10 … Об'явлення — 730); 0 — невідомо.
        final int canon;
        final String name;
        final String shortName;
        final int chapters;

        Book(int index, int canon, String name, String shortName, int chapters) {
            this.index = index;
            this.canon = canon;
            this.name = name;
            this.shortName = shortName;
            this.chapters = chapters;
        }
    }

    static final class Verse {
        final int number;
        final String text;

        Verse(int number, String text) {
            this.number = number;
            this.text = text;
        }
    }

    static final class Song {
        final int index;
        final String title;

        Song(int index, String title) {
            this.index = index;
            this.title = title;
        }
    }

    static final class Part {
        final int index;
        final String kind;
        final String text;

        Part(int index, String kind, String text) {
            this.index = index;
            this.kind = kind;
            this.text = text;
        }
    }

    Library(Context context) {
        super(context.getApplicationContext(), "library.db", null, 1);
    }

    @Override
    public void onCreate(SQLiteDatabase db) {
        db.execSQL("CREATE TABLE modules (id TEXT PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL,"
            + " short TEXT NOT NULL DEFAULT '', source TEXT NOT NULL DEFAULT '',"
            + " original TEXT NOT NULL DEFAULT '', added INTEGER NOT NULL DEFAULT 0)");
        db.execSQL("CREATE TABLE books (module TEXT NOT NULL, idx INTEGER NOT NULL, canon INTEGER NOT NULL DEFAULT 0,"
            + " name TEXT NOT NULL, short TEXT NOT NULL DEFAULT '', chapters INTEGER NOT NULL DEFAULT 0,"
            + " PRIMARY KEY (module, idx))");
        db.execSQL("CREATE TABLE verses (module TEXT NOT NULL, book INTEGER NOT NULL, chapter INTEGER NOT NULL,"
            + " verse INTEGER NOT NULL, text TEXT NOT NULL)");
        db.execSQL("CREATE INDEX verses_at ON verses (module, book, chapter)");
        db.execSQL("CREATE TABLE songs (module TEXT NOT NULL, idx INTEGER NOT NULL, title TEXT NOT NULL,"
            + " fold TEXT NOT NULL, PRIMARY KEY (module, idx))");
        db.execSQL("CREATE TABLE parts (module TEXT NOT NULL, song INTEGER NOT NULL, idx INTEGER NOT NULL,"
            + " kind TEXT NOT NULL, text TEXT NOT NULL)");
        db.execSQL("CREATE INDEX parts_at ON parts (module, song)");
    }

    @Override
    public void onUpgrade(SQLiteDatabase db, int from, int to) { }

    // MARK: Читання

    List<Module> modules(String kind) {
        List<Module> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT id, kind, name, short, source, original FROM modules WHERE kind = ? ORDER BY name COLLATE NOCASE",
                new String[] { kind })) {
            while (c.moveToNext()) {
                result.add(new Module(c.getString(0), c.getString(1), c.getString(2), c.getString(3),
                    c.getString(4), c.getString(5)));
            }
        }
        return result;
    }

    Module module(String id) {
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT id, kind, name, short, source, original FROM modules WHERE id = ?", new String[] { id })) {
            return c.moveToNext()
                ? new Module(c.getString(0), c.getString(1), c.getString(2), c.getString(3), c.getString(4), c.getString(5))
                : null;
        }
    }

    List<Book> books(String module) {
        List<Book> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT idx, canon, name, short, chapters FROM books WHERE module = ? ORDER BY idx",
                new String[] { module })) {
            while (c.moveToNext()) {
                result.add(new Book(c.getInt(0), c.getInt(1), c.getString(2), c.getString(3), c.getInt(4)));
            }
        }
        return result;
    }

    /// Номери розділів книги — ті, що справді є в базі: у модулях буває й
    /// нульовий розділ, і менше розділів, ніж обіцяє `ChapterQty`.
    List<Integer> chapters(String module, int book) {
        List<Integer> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT DISTINCT chapter FROM verses WHERE module = ? AND book = ? ORDER BY chapter",
                new String[] { module, String.valueOf(book) })) {
            while (c.moveToNext()) result.add(c.getInt(0));
        }
        return result;
    }

    List<Verse> verses(String module, int book, int chapter) {
        List<Verse> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT verse, text FROM verses WHERE module = ? AND book = ? AND chapter = ? ORDER BY verse",
                new String[] { module, String.valueOf(book), String.valueOf(chapter) })) {
            while (c.moveToNext()) result.add(new Verse(c.getInt(0), c.getString(1)));
        }
        return result;
    }

    /// Пісні за номером або словами назви. Порожній фільтр — усі по порядку.
    List<Song> songs(String module, String filter, int limit) {
        List<Song> result = new ArrayList<>();
        String wanted = fold(filter);
        String sql;
        String[] args;
        if (wanted.isEmpty()) {
            sql = "SELECT idx, title FROM songs WHERE module = ? ORDER BY idx LIMIT " + limit;
            args = new String[] { module };
        } else if (wanted.matches("\\d+")) {
            sql = "SELECT idx, title FROM songs WHERE module = ? AND (idx = ? OR fold LIKE ?) ORDER BY idx LIMIT " + limit;
            args = new String[] { module, String.valueOf(Integer.parseInt(wanted) - 1), "%" + wanted + "%" };
        } else {
            sql = "SELECT idx, title FROM songs WHERE module = ? AND fold LIKE ? ORDER BY idx LIMIT " + limit;
            args = new String[] { module, "%" + wanted + "%" };
        }
        try (Cursor c = getReadableDatabase().rawQuery(sql, args)) {
            while (c.moveToNext()) result.add(new Song(c.getInt(0), c.getString(1)));
        }
        return result;
    }

    List<Part> parts(String module, int song) {
        List<Part> result = new ArrayList<>();
        try (Cursor c = getReadableDatabase().rawQuery(
                "SELECT idx, kind, text FROM parts WHERE module = ? AND song = ? ORDER BY idx",
                new String[] { module, String.valueOf(song) })) {
            while (c.moveToNext()) result.add(new Part(c.getInt(0), c.getString(1), c.getString(2)));
        }
        return result;
    }

    /// Прибрати модуль — і рядки, і збережений файл.
    void delete(String id) {
        Module known = module(id);
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        try {
            deleteRows(db, id);
            db.delete("modules", "id = ?", new String[] { id });
            db.setTransactionSuccessful();
        } finally {
            db.endTransaction();
        }
        if (known != null && !known.original.isEmpty()) {
            //noinspection ResultOfMethodCallIgnored
            new File(known.original).delete();
        }
    }

    private static void deleteRows(SQLiteDatabase db, String id) {
        String[] args = { id };
        db.delete("books", "module = ?", args);
        db.delete("verses", "module = ?", args);
        db.delete("songs", "module = ?", args);
        db.delete("parts", "module = ?", args);
    }

    /// Рядок для пошуку: малі літери, «ё» як «е», без розділових знаків.
    static String fold(String text) {
        if (text == null) return "";
        String lower = text.toLowerCase(Locale.ROOT).replace('ё', 'е');
        StringBuilder out = new StringBuilder(lower.length());
        boolean space = false;
        for (int i = 0; i < lower.length(); i++) {
            char ch = lower.charAt(i);
            if (Character.isLetterOrDigit(ch)) {
                out.append(ch);
                space = false;
            } else if (!space && out.length() > 0) {
                out.append(' ');
                space = true;
            }
        }
        return out.toString().trim();
    }

    // MARK: Запис

    /// Запис модуля — одна транзакція: або модуль ліг увесь, або його немає.
    /// Попередня версія того самого модуля при цьому замінюється.
    Writer write(String id, String kind, String name, String shortName, String source, String original) {
        SQLiteDatabase db = getWritableDatabase();
        db.beginTransaction();
        deleteRows(db, id);
        ContentValues row = new ContentValues();
        row.put("id", id);
        row.put("kind", kind);
        row.put("name", name == null || name.isEmpty() ? id : name);
        row.put("short", shortName == null ? "" : shortName);
        row.put("source", source);
        row.put("original", original == null ? "" : original);
        row.put("added", System.currentTimeMillis());
        db.insertWithOnConflict("modules", null, row, SQLiteDatabase.CONFLICT_REPLACE);
        return new Writer(db, id);
    }

    static final class Writer {
        private final SQLiteDatabase db;
        private final String id;
        private final SQLiteStatement book;
        private final SQLiteStatement verse;
        private final SQLiteStatement song;
        private final SQLiteStatement part;
        private boolean finished;
        int verses;
        int songs;

        private Writer(SQLiteDatabase db, String id) {
            this.db = db;
            this.id = id;
            book = db.compileStatement("INSERT OR REPLACE INTO books (module, idx, canon, name, short, chapters) VALUES (?, ?, ?, ?, ?, ?)");
            verse = db.compileStatement("INSERT INTO verses (module, book, chapter, verse, text) VALUES (?, ?, ?, ?, ?)");
            song = db.compileStatement("INSERT OR REPLACE INTO songs (module, idx, title, fold) VALUES (?, ?, ?, ?)");
            part = db.compileStatement("INSERT INTO parts (module, song, idx, kind, text) VALUES (?, ?, ?, ?, ?)");
        }

        void book(int index, int canon, String name, String shortName, int chapters) {
            book.bindString(1, id);
            book.bindLong(2, index);
            book.bindLong(3, canon);
            book.bindString(4, name == null ? "" : name);
            book.bindString(5, shortName == null ? "" : shortName);
            book.bindLong(6, chapters);
            book.executeInsert();
        }

        void verse(int bookIndex, int chapter, int number, String text) {
            verse.bindString(1, id);
            verse.bindLong(2, bookIndex);
            verse.bindLong(3, chapter);
            verse.bindLong(4, number);
            verse.bindString(5, text);
            verse.executeInsert();
            verses++;
        }

        void song(int index, String title) {
            song.bindString(1, id);
            song.bindLong(2, index);
            song.bindString(3, title);
            song.bindString(4, (index + 1) + " " + fold(title));
            song.executeInsert();
            songs++;
        }

        void part(int songIndex, int index, String kind, String text) {
            part.bindString(1, id);
            part.bindLong(2, songIndex);
            part.bindLong(3, index);
            part.bindString(4, kind == null ? "" : kind);
            part.bindString(5, text == null ? "" : text);
            part.executeInsert();
        }

        void commit() {
            if (finished) return;
            finished = true;
            db.setTransactionSuccessful();
            db.endTransaction();
        }

        void abort() {
            if (finished) return;
            finished = true;
            db.endTransaction();
        }
    }
}
