// =============================================================================
//  ZipArchive.cs — читання архіву ZIP для `.pptx` (з Presentation/ZipArchive.swift)
// =============================================================================
//  Тип названо ZipParts, а не ZipArchive: інакше він затуляв би
//  System.IO.Compression.ZipArchive у всьому просторі Slovo.Core.
//  Розбір той самий, що на Mac (центральний каталог, імена як UTF-8, способи
//  0 і 8); DEFLATE розпаковує DeflateStream.
// =============================================================================

using System.IO.Compression;
using System.Text;

namespace Slovo.Core;

/// Читання архіву ZIP — рівно стільки, скільки потрібно, щоб відкрити `.pptx`.
///
/// Презентація Microsoft — це звичайний ZIP з XML усередині. Кликати чужий
/// розпакувальник посеред служіння не годиться: це чужий процес, тимчасова
/// тека і сміття на диску, яке одного разу лишиться. Тут усе в пам'яті і
/// своїм кодом.
///
/// Читаємо за «центральним каталогом» у кінці файла, а не підряд з початку:
/// так знаходяться рівно ті частини, що потрібні, і не розбирається все підряд —
/// у презентації з сотнею картинок це різниця в секунди.
///
/// Зі способів стиснення підтримано два, й інших у `.pptx` не буває: 0 —
/// «як є» і 8 — DEFLATE.
public static class ZipParts
{
    public sealed class Failure : Exception
    {
        public enum Kind { NotAZip, Unsupported, Damaged }

        public Kind FailureKind { get; }
        public string Entry { get; }
        public int Method { get; }

        private Failure(Kind kind, string entry, int method, string message) : base(message)
        {
            FailureKind = kind;
            Entry = entry;
            Method = method;
        }

        public static Failure NotAZip() => new(Kind.NotAZip, "", 0, OurWords.T("это не архив ZIP — у файла нет оглавления"));
        public static Failure Unsupported(int method, string entry) =>
            new(Kind.Unsupported, entry, method, OurWords.T("«%s»: неизвестный способ сжатия %s", entry, method.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        public static Failure Damaged(string entry) => new(Kind.Damaged, entry, 0, OurWords.T("«%s»: часть архива не распаковалась", entry));

        public override string ToString() => Message;
    }

    /// Що лежить в архіві: ім'я частини → де її шукати.
    internal readonly record struct Entry(string Name, int Method, long CompressedSize, long UncompressedSize, long HeaderOffset);

    /// Зміст архіву. Відкривається один раз, далі частини беруться за іменем.
    public sealed class Reader
    {
        private readonly byte[] data;
        private readonly Dictionary<string, Entry> entries;

        internal Reader(byte[] data, Dictionary<string, Entry> entries)
        {
            this.data = data;
            this.entries = entries;
        }

        public IReadOnlyList<string> Names => entries.Keys.OrderBy(name => name, StringComparer.Ordinal).ToList();

        public bool Contains(string name) => entries.ContainsKey(name);

        /// Дістати частину за іменем. `null` — такої частини в архіві немає.
        public byte[]? Part(string name) => entries.TryGetValue(name, out var entry) ? Extract(entry, data) : null;

        /// Частина текстом. Усі XML усередині `.pptx` записано в UTF-8
        /// (`String(data:encoding: .utf8)`: зламаний UTF-8 — `null`).
        public string? Text(string name) => Part(name) is { } bytes ? CodePage.TryDecode(bytes, CodePage.Utf8) : null;
    }

    // ── Зміст ───────────────────────────────────────────────────────────────

    public static Reader Open(string path) => Open(File.ReadAllBytes(path));

    public static Reader Open(byte[] data)
    {
        // Кінець центрального каталогу — підпис 0x06054b50. Шукаємо його з кінця:
        // після нього буває коментар довжиною до 64 КБ, тому далі не йдемо.
        var limit = Math.Min(data.Length, 66_000);
        long? end = null;
        var at = data.Length - 22;
        var lowest = data.Length - limit;
        while (at >= Math.Max(0, lowest))
        {
            if (data[at] == 0x50 && data[at + 1] == 0x4B && data[at + 2] == 0x05 && data[at + 3] == 0x06)
            {
                end = at;
                break;
            }
            at -= 1;
        }
        if (end is not { } found || found + 22 > data.Length) throw Failure.NotAZip();

        var count = (int)Number(data, found + 10, 2);
        var offset = (long)Number(data, found + 16, 4);

        var entries = new Dictionary<string, Entry>(StringComparer.Ordinal);
        for (var index = 0; index < count; index++)
        {
            if (offset + 46 > data.Length || Number(data, offset, 4) != 0x0201_4b50) break;
            var method = (int)Number(data, offset + 10, 2);
            var compressed = (long)Number(data, offset + 20, 4);
            var uncompressed = (long)Number(data, offset + 24, 4);
            var nameLength = (int)Number(data, offset + 28, 2);
            var extraLength = (int)Number(data, offset + 30, 2);
            var commentLength = (int)Number(data, offset + 32, 2);
            var header = (long)Number(data, offset + 42, 4);

            var nameStart = offset + 46;
            if (nameStart + nameLength > data.Length) break;
            // `String(decoding:as: UTF8.self)` — зламане стає U+FFFD.
            var name = Encoding.UTF8.GetString(data, (int)nameStart, nameLength);
            if (!name.EndsWith('/')) entries[name] = new Entry(name, method, compressed, uncompressed, header);
            offset = nameStart + nameLength + extraLength + commentLength;
        }
        if (entries.Count == 0) throw Failure.NotAZip();
        return new Reader(data, entries);
    }

    // ── Розпакування однієї частини ─────────────────────────────────────────

    private static byte[] Extract(Entry entry, byte[] data)
    {
        // Локальний запис: ім'я і «додаткове поле» в ньому своєї довжини,
        // і брати її з центрального каталогу не можна — вони розходяться.
        var at = entry.HeaderOffset;
        if (at + 30 > data.Length || Number(data, at, 4) != 0x0403_4b50) throw Failure.Damaged(entry.Name);
        var nameLength = Number(data, at + 26, 2);
        var extraLength = Number(data, at + 28, 2);
        var start = at + 30 + nameLength + extraLength;
        var finish = start + entry.CompressedSize;
        if (finish > data.Length) throw Failure.Damaged(entry.Name);
        var payload = data[(int)start..(int)finish];

        switch (entry.Method)
        {
            case 0:
                return payload;
            case 8:
                return Inflate(payload, Math.Max(entry.UncompressedSize, 1)) ?? throw Failure.Damaged(entry.Name);
            default:
                throw Failure.Unsupported(entry.Method, entry.Name);
        }
    }

    /// «Сирий» DEFLATE — той самий, що лежить у ZIP: без заголовка zlib.
    /// Як `compression_decode_buffer`: не більше місткості буфера (розмір із
    /// каталогу плюс запас), порожній вивід ненульової частини — відмова.
    private static byte[]? Inflate(byte[] raw, long capacity)
    {
        // Плюс запас: у порожніх частин розмір нульовий, а буфер потрібен завжди.
        var room = (int)Math.Min(Math.Max(capacity + 64, 1024), int.MaxValue - 64);
        try
        {
            using var input = new MemoryStream(raw, writable: false);
            using var inflater = new DeflateStream(input, CompressionMode.Decompress);
            var buffer = new byte[room];
            var written = 0;
            int read;
            while (written < room && (read = inflater.Read(buffer, written, room - written)) > 0) written += read;
            if (written <= 0 && capacity != 0) return null;
            return buffer[..written];
        }
        catch (InvalidDataException)
        {
            return null;
        }
    }

    /// Ціле з архіву: молодший байт першим, як записано в ZIP.
    private static uint Number(byte[] data, long offset, int bytes)
    {
        if (offset < 0 || offset + bytes > data.Length) return 0;
        uint value = 0;
        for (var index = bytes - 1; index >= 0; index--) value = value << 8 | data[offset + index];
        return value;
    }
}
