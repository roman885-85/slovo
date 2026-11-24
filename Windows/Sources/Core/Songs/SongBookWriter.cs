// =============================================================================
//  SongBookWriter.cs — запис пісенника у форматі старої програми `.vbm`
//  (з Songs/SongBookWriter.swift)
// =============================================================================
//  Розкладка — байт у байт як на Mac. Сам стиснутий потік може відрізнятися:
//  на Mac пакує `compression_encode_buffer` Apple, тут — DeflateStream .NET;
//  обидва дають правильний DEFLATE, який розпаковує будь-хто (і оригінал).
// =============================================================================

using System.IO.Compression;

namespace Slovo.Core;

/// Запис пісенника у форматі старої програми (`.vbm`).
///
/// Без запису редактор безглуздий, а формат уже розібрано при читанні:
/// шістнадцять байтів підпису, версія, розмір стиснутих даних, потім коротка
/// службова область з назвою і коротким ім'ям — і один zlib-потік з усім
/// вмістом. Рядок усередині — число символів в UInt16 і самі символи
/// в UTF-16LE.
///
/// Пишемо рівно ту саму розкладку, щоб файл відкривався й оригінальною
/// програмою: правка пісень на маку не має відрізати від Windows.
public static class SongBookWriter
{
    public static byte[] Data(SongBook book)
    {
        var body = Body(book);
        var compressed = Deflate.Zlib(body);

        // Заголовок повторюємо байт у байт: оригінал шукає коротке ім'я і
        // назву на фіксованому зсуві 72, а розміри й ознаку читає
        // з 20-го. Помилка тут — і файл відкриється лише в нас.
        var file = new List<byte>(compressed.Length + 256);
        file.AddRange("VisioBibleModule"u8.ToArray());
        Append(file, book.FormatVersion);
        Append(file, (uint)compressed.Length);
        Append(file, (uint)body.Length);
        Append(file, book.Flags);
        Append(file, book.Charset);
        file.AddRange(new byte[36]);
        Append(file, book.ShortName);
        Append(file, book.Title);
        file.AddRange(new byte[4]);

        file.AddRange(compressed);
        file.AddRange(new byte[4]);     // хвіст, як у вихідних файлах
        return file.ToArray();
    }

    /// Розпакований вміст потоку — те, що однаково на Mac і тут байт у байт.
    internal static byte[] Body(SongBook book)
    {
        var body = new List<byte>(1 << 16);
        Append(body, book.Title);
        Append(body, book.ShortName);
        Append(body, book.Publisher);
        Append(body, book.RevisionDate);
        Append(body, book.Comment);
        Append(body, (uint)book.Songs.Count);

        foreach (var song in book.Songs)
        {
            Append(body, song.Title);
            Append(body, song.AlternateTitle);
            Append(body, song.Author);
            Append(body, song.Composer);
            Append(body, song.Note);
            Append(body, song.Properties);
            Append(body, (uint)song.Parts.Count);

            foreach (var part in song.Parts)
            {
                Append(body, part.Kind);
                Append(body, part.Text);
                // Службове поле частини — її вирівнювання (5.3.9.2, кнопки 9–12).
                Append(body, part.Align.RawValue());
            }
        }

        // Хвіст потоку — групи пісень. Навіть коли груп немає, нуль писати
        // обов'язково: оригінал читає це поле завжди.
        Append(body, (uint)book.Groups.Count);
        foreach (var group in book.Groups)
        {
            Append(body, group.Name);
            Append(body, (uint)group.SongIndices.Count);
            foreach (var index in group.SongIndices) Append(body, (uint)Math.Max(0, index));
        }
        return body.ToArray();
    }

    public static void Write(SongBook book, string path) => SwiftPath.WriteAtomically(path, Data(book));

    // ─────────────────────────────────────────────────────────────────────────

    private static void Append(List<byte> data, string text)
    {
        var count = Math.Min(text.Length, ushort.MaxValue);
        Append(data, (ushort)count);
        for (var index = 0; index < count; index++)
        {
            var unit = text[index];
            data.Add((byte)(unit & 0xFF));
            data.Add((byte)(unit >> 8));
        }
    }

    private static void Append(List<byte> data, ushort value)
    {
        data.Add((byte)(value & 0xFF));
        data.Add((byte)(value >> 8));
    }

    private static void Append(List<byte> data, uint value)
    {
        for (var shift = 0; shift < 32; shift += 8) data.Add((byte)((value >> shift) & 0xFF));
    }
}

/// Пакування в zlib. DeflateStream (як і `Compression` Apple) уміє лише
/// «сирий» DEFLATE, тому заголовок і контрольну суму дописуємо самі —
/// інакше оригінальна програма файл не прийме.
internal static class Deflate
{
    public static byte[] Zlib(byte[] data)
    {
        if (data.Length == 0) throw SongBookError.InflateFailed();

        using var packed = new MemoryStream(data.Length / 2 + 1024);
        packed.WriteByte(0x78);                      // заголовок zlib
        packed.WriteByte(0x9C);
        using (var deflater = new DeflateStream(packed, CompressionLevel.Optimal, leaveOpen: true))
            deflater.Write(data, 0, data.Length);
        if (packed.Length <= 2) throw SongBookError.InflateFailed();

        var adler = Adler32(data);
        packed.WriteByte((byte)(adler >> 24));
        packed.WriteByte((byte)(adler >> 16));
        packed.WriteByte((byte)(adler >> 8));
        packed.WriteByte((byte)adler);
        return packed.ToArray();
    }

    private static uint Adler32(byte[] data)
    {
        uint a = 1, b = 0;
        foreach (var value in data)
        {
            a = (a + value) % 65521;
            b = (b + a) % 65521;
        }
        return (b << 16) | a;
    }
}
