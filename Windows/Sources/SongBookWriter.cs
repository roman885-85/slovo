// =============================================================================
//  SongBookWriter.cs — запис пісенника: свій `.songbook` і старий `.vbm`
// =============================================================================
//  Перенесено з SongBookJSON.swift і SongBookWriter.swift. Програма пише лише
//  `.songbook` (JSON у UTF-8), а `.vbm` збирає на льоту для планшета й для
//  старої програми на Windows: шістнадцять байтів підпису, версія, розмір
//  стиснутих даних, службова область з назвою і один zlib-потік, де рядок —
//  UInt16 з числом символів і самі символи в UTF-16LE.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Slovo;

/// Пісенник цілком — те, що читає й пише програма.
public sealed class SongBookData
{
    public string Title { get; set; } = "";
    public string ShortName { get; set; } = "";
    public string Publisher { get; set; } = "";
    public string RevisionDate { get; set; } = "";
    public string Comment { get; set; } = "";
    public List<SongData> Songs { get; } = new();
    public List<(string Name, List<int> Songs)> Groups { get; } = new();
    public uint FormatVersion { get; set; } = 0x0102;
    public uint Flags { get; set; } = 1;
    public uint Charset { get; set; } = 0x200;
}

public sealed class SongData
{
    public int Index { get; set; }
    public string Title { get; set; } = "";
    public string AlternateTitle { get; set; } = "";
    public string Author { get; set; } = "";
    public string Composer { get; set; } = "";
    public string Note { get; set; } = "";
    public string Properties { get; set; } = "";
    public List<PartData> Parts { get; } = new();
}

public sealed class PartData
{
    public int Index { get; set; }
    public string Kind { get; set; } = "";
    public string Text { get; set; } = "";
    /// Вирівнювання частини: 0 — як у шаблоні, 1 — ліворуч, 2 — по центру, 3 — праворуч.
    public int Align { get; set; }
}

public static class SongBookWriter
{
    public const string Extension = "songbook";
    public const string Format = "slovo-songbook";

    static readonly string[] AlignNames = { "default", "left", "center", "right" };

    // MARK: .songbook

    public static string SongbookJson(SongBookData book)
    {
        string? Blank(string text) => text.Length == 0 ? null : text;
        var json = new JsonObject
        {
            ["format"] = Format,
            ["version"] = 1,
            ["title"] = book.Title,
            ["shortName"] = book.ShortName,
            ["publisher"] = book.Publisher,
            ["revisionDate"] = book.RevisionDate,
            ["comment"] = book.Comment,
            ["groups"] = new JsonArray(book.Groups.Select(g => (JsonNode)new JsonObject
            {
                ["name"] = g.Name, ["songs"] = new JsonArray(g.Songs.Select(s => (JsonNode)s).ToArray()),
            }).ToArray()),
            ["songs"] = new JsonArray(book.Songs.Select(song =>
            {
                var record = new JsonObject { ["index"] = song.Index, ["title"] = song.Title };
                if (Blank(song.AlternateTitle) != null) record["alternateTitle"] = song.AlternateTitle;
                if (Blank(song.Author) != null) record["author"] = song.Author;
                if (Blank(song.Composer) != null) record["composer"] = song.Composer;
                if (Blank(song.Note) != null) record["note"] = song.Note;
                if (Blank(song.Properties) != null) record["properties"] = song.Properties;
                record["parts"] = new JsonArray(song.Parts.Select(part =>
                {
                    var p = new JsonObject { ["index"] = part.Index, ["kind"] = part.Kind, ["text"] = part.Text };
                    if (part.Align is > 0 and < 4) p["align"] = AlignNames[part.Align];
                    return (JsonNode)p;
                }).ToArray());
                return (JsonNode)record;
            }).ToArray()),
            ["vbm"] = new JsonObject { ["formatVersion"] = book.FormatVersion, ["flags"] = book.Flags, ["charset"] = book.Charset },
        };
        return json.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping });
    }

    public static void WriteSongbook(SongBookData book, string path)
    {
        var temp = path + ".tmp";
        File.WriteAllText(temp, SongbookJson(book), new UTF8Encoding(false));
        File.Move(temp, path, true);
    }

    /// Читання свого формату — у повну структуру (для редактора й експорту).
    public static SongBookData ReadSongbook(byte[] data, string fileName)
    {
        JsonObject? json;
        try { json = JsonNode.Parse(Encoding.UTF8.GetString(data)) as JsonObject; }
        catch { json = null; }
        if (json == null || (string?)json["format"] != Format)
            throw new RefusedException("«" + fileName + Lang.T("»: це не пісенник .songbook", "»: not a .songbook songbook"));
        var book = new SongBookData
        {
            Title = (string?)json["title"] ?? "", ShortName = (string?)json["shortName"] ?? "",
            Publisher = (string?)json["publisher"] ?? "", RevisionDate = (string?)json["revisionDate"] ?? "",
            Comment = (string?)json["comment"] ?? "",
        };
        if (json["vbm"] is JsonObject header)
        {
            book.FormatVersion = (uint?)header["formatVersion"] ?? book.FormatVersion;
            book.Flags = (uint?)header["flags"] ?? book.Flags;
            book.Charset = (uint?)header["charset"] ?? book.Charset;
        }
        var index = 0;
        foreach (var node in json["songs"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject record) continue;
            var song = new SongData
            {
                Index = (int?)record["index"] ?? index, Title = (string?)record["title"] ?? "",
                AlternateTitle = (string?)record["alternateTitle"] ?? "", Author = (string?)record["author"] ?? "",
                Composer = (string?)record["composer"] ?? "", Note = (string?)record["note"] ?? "",
                Properties = (string?)record["properties"] ?? "",
            };
            var partIndex = 0;
            foreach (var p in record["parts"] as JsonArray ?? new JsonArray())
            {
                if (p is not JsonObject part) continue;
                song.Parts.Add(new PartData
                {
                    Index = (int?)part["index"] ?? partIndex, Kind = (string?)part["kind"] ?? "", Text = (string?)part["text"] ?? "",
                    Align = Math.Max(0, Array.IndexOf(AlignNames, (string?)part["align"] ?? "default")),
                });
                partIndex++;
            }
            book.Songs.Add(song);
            index++;
        }
        foreach (var node in json["groups"] as JsonArray ?? new JsonArray())
        {
            if (node is not JsonObject group) continue;
            book.Groups.Add(((string?)group["name"] ?? "",
                             (group["songs"] as JsonArray ?? new JsonArray()).Select(n => (int?)n ?? 0).ToList()));
        }
        return book;
    }

    // MARK: .vbm

    public static byte[] Vbm(SongBookData book)
    {
        var body = new MemoryStream();
        void Text(string text)
        {
            var units = text.Length > ushort.MaxValue ? text[..ushort.MaxValue] : text;
            U16((ushort)units.Length);
            body.Write(Encoding.Unicode.GetBytes(units));
        }
        void U16(ushort value) { body.WriteByte((byte)(value & 0xFF)); body.WriteByte((byte)(value >> 8)); }
        void U32(uint value) { for (var shift = 0; shift < 32; shift += 8) body.WriteByte((byte)((value >> shift) & 0xFF)); }

        Text(book.Title); Text(book.ShortName); Text(book.Publisher); Text(book.RevisionDate); Text(book.Comment);
        U32((uint)book.Songs.Count);
        foreach (var song in book.Songs)
        {
            Text(song.Title); Text(song.AlternateTitle); Text(song.Author); Text(song.Composer); Text(song.Note); Text(song.Properties);
            U32((uint)song.Parts.Count);
            foreach (var part in song.Parts) { Text(part.Kind); Text(part.Text); U32((uint)Math.Max(0, part.Align)); }
        }
        U32((uint)book.Groups.Count);
        foreach (var (name, songs) in book.Groups)
        {
            Text(name);
            U32((uint)songs.Count);
            foreach (var index in songs) U32((uint)Math.Max(0, index));
        }
        var raw = body.ToArray();

        byte[] compressed;
        using (var packed = new MemoryStream())
        {
            using (var zlib = new ZLibStream(packed, CompressionLevel.Optimal, true)) zlib.Write(raw);
            compressed = packed.ToArray();
        }

        var file = new MemoryStream();
        void FU16(ushort value) { file.WriteByte((byte)(value & 0xFF)); file.WriteByte((byte)(value >> 8)); }
        void FU32(uint value) { for (var shift = 0; shift < 32; shift += 8) file.WriteByte((byte)((value >> shift) & 0xFF)); }
        void FText(string text)
        {
            var units = text.Length > ushort.MaxValue ? text[..ushort.MaxValue] : text;
            FU16((ushort)units.Length);
            file.Write(Encoding.Unicode.GetBytes(units));
        }
        file.Write(Encoding.ASCII.GetBytes("VisioBibleModule"));
        FU32(book.FormatVersion);
        FU32((uint)compressed.Length);
        FU32((uint)raw.Length);
        FU32(book.Flags);
        FU32(book.Charset);
        file.Write(new byte[36]);
        FText(book.ShortName);
        FText(book.Title);
        file.Write(new byte[4]);
        file.Write(compressed);
        file.Write(new byte[4]);
        return file.ToArray();
    }

    /// Читання `.vbm` у повну структуру — для редактора й збереження у своєму форматі.
    public static SongBookData ReadVbm(byte[] data, string fileName)
    {
        var magic = Encoding.ASCII.GetBytes("VisioBibleModule");
        var damaged = "«" + fileName + Lang.T("»: файл пошкоджено", "»: the file is damaged");
        if (data.Length <= 24 || !data.AsSpan(0, magic.Length).SequenceEqual(magic))
            throw new RefusedException("«" + fileName + Lang.T("»: це не пісенник .vbm", "»: not a .vbm songbook"));
        long compressed = BitConverter.ToUInt32(data, 20);
        var start = data.Length - 4 - compressed;
        if (start <= 16 || start >= data.Length) throw new RefusedException(damaged);
        byte[] body;
        try
        {
            using var input = new ZLibStream(new MemoryStream(data, (int)start, data.Length - (int)start), CompressionMode.Decompress);
            using var output = new MemoryStream(data.Length * 4);
            input.CopyTo(output);
            body = output.ToArray();
        }
        catch { throw new RefusedException(damaged); }

        var at = 0;
        uint U32() { if (at + 4 > body.Length) throw new RefusedException(damaged); var v = BitConverter.ToUInt32(body, at); at += 4; return v; }
        string Text()
        {
            if (at + 2 > body.Length) throw new RefusedException(damaged);
            int length = BitConverter.ToUInt16(body, at); at += 2;
            if (at + length * 2 > body.Length) throw new RefusedException(damaged);
            var text = Encoding.Unicode.GetString(body, at, length * 2); at += length * 2;
            return text;
        }
        var book = new SongBookData
        {
            FormatVersion = BitConverter.ToUInt32(data, 16), Flags = BitConverter.ToUInt32(data, 28), Charset = BitConverter.ToUInt32(data, 32),
            Title = Text(), ShortName = Text(), Publisher = Text(), RevisionDate = Text(), Comment = Text(),
        };
        var count = U32();
        if (count > 100_000) throw new RefusedException(damaged);
        for (var index = 0; index < count; index++)
        {
            var song = new SongData { Index = index, Title = Text(), AlternateTitle = Text(), Author = Text(), Composer = Text(), Note = Text(), Properties = Text() };
            var parts = U32();
            if (parts > 1000) throw new RefusedException(damaged);
            for (var p = 0; p < parts; p++)
                song.Parts.Add(new PartData { Index = p, Kind = Text(), Text = Text(), Align = (int)Math.Min(3, U32()) });
            book.Songs.Add(song);
        }
        try
        {
            var groups = U32();
            for (var g = 0; g < groups && g < 1000; g++)
            {
                var name = Text();
                var n = U32();
                var list = new List<int>();
                for (var i = 0; i < n && i < 100_000; i++) list.Add((int)U32());
                book.Groups.Add((name, list));
            }
        }
        catch (RefusedException) { /* груп у старому файлі може й не бути */ }
        return book;
    }
}
