package ua.church.slovo.remote;

import android.os.Build;
import java.io.File;
import java.io.FileOutputStream;
import java.io.OutputStream;

import android.content.ContentResolver;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Matrix;
import android.media.ExifInterface;
import android.net.Uri;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;

/// Фото з галереї — зменшене й повернуте як слід, готове до надсилання.
///
/// Знімок телефона — це 12 мегапікселів і 5–10 МБ; по Wi-Fi таке йде
/// секундами, а стіні більше 2560 точок не треба. Тому зменшуємо тут же, на
/// телефоні. І повертаємо за позначкою орієнтації: телефон пише кадр так,
/// як лежала матриця, а куди його повернути — лише позначкою, і без неї
/// вертикальне фото лягло б на стіну набік.
final class PhotoShrink {

    static final class Result {
        final byte[] bytes;
        final String extension;

        Result(byte[] bytes, String extension) {
            this.bytes = bytes;
            this.extension = extension;
        }
    }

    private PhotoShrink() { }

    static Result prepare(ContentResolver resolver, Uri uri, int longest) throws IOException {
        BitmapFactory.Options bounds = new BitmapFactory.Options();
        bounds.inJustDecodeBounds = true;
        try (InputStream stream = resolver.openInputStream(uri)) {
            if (stream == null) throw new IOException(Lang.t("файл не відкрився", "the file did not open"));
            BitmapFactory.decodeStream(stream, null, bounds);
        }
        // Формат, якого цей телефон не розбирає (HEIC на старому Android), —
        // надсилаємо як є: програма на комп'ютері прочитає його сама.
        if (bounds.outWidth <= 0 || bounds.outHeight <= 0) return new Result(readAll(resolver, uri), "heic");

        int sample = 1;
        while (Math.max(bounds.outWidth, bounds.outHeight) / (sample * 2) >= longest) sample *= 2;
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inSampleSize = sample;
        Bitmap bitmap;
        try (InputStream stream = resolver.openInputStream(uri)) {
            bitmap = BitmapFactory.decodeStream(stream, null, options);
        }
        if (bitmap == null) return new Result(readAll(resolver, uri), "heic");

        Matrix matrix = new Matrix();
        float scale = Math.min(1f, (float) longest / Math.max(bitmap.getWidth(), bitmap.getHeight()));
        if (scale < 1f) matrix.postScale(scale, scale);
        int rotation = rotation(resolver, uri);
        if (rotation != 0) matrix.postRotate(rotation);
        if (!matrix.isIdentity()) {
            Bitmap turned = Bitmap.createBitmap(bitmap, 0, 0, bitmap.getWidth(), bitmap.getHeight(), matrix, true);
            if (turned != bitmap) bitmap.recycle();
            bitmap = turned;
        }
        ByteArrayOutputStream out = new ByteArrayOutputStream();
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out);
        bitmap.recycle();
        return new Result(out.toByteArray(), "jpg");
    }

    /// Позначка орієнтації. Читати її з потоку Android уміє лише з 7-ї
    /// версії; планшет «Слова» працює й на 5-й і 6-й — там знімок спершу
    /// кладемо в тимчасовий файл і читаємо позначку з нього.
    private static int rotation(ContentResolver resolver, Uri uri) {
        try {
            ExifInterface exif;
            if (Build.VERSION.SDK_INT >= 24) {
                try (InputStream stream = resolver.openInputStream(uri)) {
                    if (stream == null) return 0;
                    exif = new ExifInterface(stream);
                }
            } else {
                File copy = File.createTempFile("slovo-exif", ".jpg");
                try {
                    try (InputStream stream = resolver.openInputStream(uri);
                         OutputStream out = new FileOutputStream(copy)) {
                        if (stream == null) return 0;
                        byte[] chunk = new byte[65536];
                        int count;
                        while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
                    }
                    exif = new ExifInterface(copy.getAbsolutePath());
                } finally {
                    //noinspection ResultOfMethodCallIgnored
                    copy.delete();
                }
            }
            switch (exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)) {
                case ExifInterface.ORIENTATION_ROTATE_90: return 90;
                case ExifInterface.ORIENTATION_ROTATE_180: return 180;
                case ExifInterface.ORIENTATION_ROTATE_270: return 270;
                default: return 0;
            }
        } catch (Exception ignored) {
            return 0;
        }
    }

    private static byte[] readAll(ContentResolver resolver, Uri uri) throws IOException {
        try (InputStream stream = resolver.openInputStream(uri)) {
            if (stream == null) throw new IOException(Lang.t("файл не відкрився", "the file did not open"));
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] chunk = new byte[65536];
            int count;
            while ((count = stream.read(chunk)) > 0) out.write(chunk, 0, count);
            return out.toByteArray();
        }
    }
}
