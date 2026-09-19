package ua.church.slovo.remote;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.Context;
import android.database.Cursor;
import android.database.MatrixCursor;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.provider.OpenableColumns;

import java.io.File;
import java.io.FileNotFoundException;

/// Свій маленький постачальник файлів: віддає завантажений .apk встановлювачу.
///
/// З Android 7 програма не може дати іншій адресу `file://` — летить
/// `FileUriExposedException`. Звичайний шлях — `FileProvider` з AndroidX, але
/// пульт і планшет зібрані без жодної сторонньої бібліотеки (так вони не
/// залежать від чужих версій і збираються без Gradle). Тому постачальник тут
/// свій: три методи, які потрібні встановлювачу, — ім'я, розмір і сам файл.
public final class ApkProvider extends ContentProvider {

    /// Адреса файла оновлення для встановлювача. Назва постачальника — за
    /// іменем пакета, щоб пульт і планшет могли стояти на одному пристрої.
    static Uri uriFor(Context context, File file) {
        return Uri.parse("content://" + context.getPackageName() + ".files/update/" + file.getName());
    }

    private File file(Uri uri) throws FileNotFoundException {
        String name = uri.getLastPathSegment();
        if (name == null || name.contains("/") || name.contains("..")) throw new FileNotFoundException(String.valueOf(uri));
        File file = new File(new File(getContext().getFilesDir(), "update"), name);
        if (!file.exists()) throw new FileNotFoundException(file.getPath());
        return file;
    }

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        return ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.MODE_READ_ONLY);
    }

    /// Встановлювач питає ім'я й розмір — без цього він мовчки відмовляється.
    @Override
    public Cursor query(Uri uri, String[] columns, String selection, String[] args, String order) {
        File file;
        try {
            file = file(uri);
        } catch (FileNotFoundException error) {
            return null;
        }
        String[] names = columns != null ? columns : new String[] { OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE };
        MatrixCursor cursor = new MatrixCursor(names, 1);
        Object[] row = new Object[names.length];
        for (int i = 0; i < names.length; i++) {
            if (OpenableColumns.DISPLAY_NAME.equals(names[i])) row[i] = file.getName();
            else if (OpenableColumns.SIZE.equals(names[i])) row[i] = file.length();
        }
        cursor.addRow(row);
        return cursor;
    }

    @Override
    public String getType(Uri uri) {
        return "application/vnd.android.package-archive";
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        return null;
    }

    @Override
    public int delete(Uri uri, String selection, String[] args) {
        return 0;
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection, String[] args) {
        return 0;
    }
}
