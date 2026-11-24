// =============================================================================
//  Inflate.cs — розпакування zlib-потоку (з Songs/Inflate.swift)
// =============================================================================
//  На Mac — `compression_decode_buffer(COMPRESSION_ZLIB)`, тут — DeflateStream
//  з System.IO.Compression: обидва розуміють «сирий» DEFLATE без заголовка.
// =============================================================================

using System.IO.Compression;

namespace Slovo.Core;

/// Розпакування zlib-потоку.
///
/// `DeflateStream` (як і `COMPRESSION_ZLIB` від Apple) — це «сирий» DEFLATE
/// без двобайтового заголовка zlib і без контрольної суми в кінці. Дані
/// стара програма записала повноцінним zlib-потоком, тому заголовок знімаємо
/// самі, а adler32 у хвості просто не заважає — розпакування кінчається раніше.
internal static class Inflate
{
    public static byte[] Zlib(byte[] data)
    {
        if (data.Length <= 6) throw SongBookError.InflateFailed();

        // На Mac розмір розпакованого заздалегідь невідомий і буфер росте
        // вчетверо до восьми разів. Потік сам знає, де кінчається, тож тут
        // спроба одна, а межа та сама: що не вліз би в найбільший буфер Mac,
        // того й тут не приймаємо.
        long limit = Math.Max((long)data.Length * 8, 1 << 16);
        for (var attempt = 1; attempt < 8; attempt++) limit *= 4;

        try
        {
            using var input = new MemoryStream(data, 2, data.Length - 2, writable: false);
            using var inflater = new DeflateStream(input, CompressionMode.Decompress);
            using var output = new MemoryStream(Math.Max(data.Length * 8, 1 << 16));
            var buffer = new byte[81920];
            int read;
            while ((read = inflater.Read(buffer, 0, buffer.Length)) > 0)
            {
                output.Write(buffer, 0, read);
                // Рівно врівень з буфером — на Mac це вже «обрізано».
                if (output.Length >= limit) throw SongBookError.InflateFailed();
            }
            if (output.Length == 0) throw SongBookError.InflateFailed();
            return output.ToArray();
        }
        catch (InvalidDataException)
        {
            throw SongBookError.InflateFailed();
        }
    }
}
