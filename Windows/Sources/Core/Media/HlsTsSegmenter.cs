// =============================================================================
//  HlsTsSegmenter.cs — живий HLS шматками MPEG-TS (для «Відео по Wi-Fi»)
// =============================================================================
//  На Mac шматки ріже AVAssetWriter (fMP4). У Windows кодери Media Foundation
//  дають сирий H.264 (Annex B) і AAC (ADTS) — мультиплексуємо самі в MPEG-TS:
//  кожен шматок починається таблицями PAT/PMT і ключовим кадром (з SPS/PPS), щоб
//  гравець міг почати з будь-якого; PCR — на кожному кадрі відео; мітки часу
//  — у 90 кГц, з запасом 0,7 с над PCR. Шматок закривається на ключовому кадрі,
//  коли назбиралося не менше цілі (1 с); у списку — останні шматки (6).
//  Портабельне: перевіряється на Mac (ffprobe/ffmpeg) ключем --hls-ts-check.
// =============================================================================

using System.Globalization;
using System.Text;

namespace Slovo.Core;

public sealed class HlsTsSegmenter : IHLSStreamProvider
{
    const int VideoPid = 0x100, AudioPid = 0x101, PmtPid = 0x1000;
    /// Відео й звук ідуть на 0,7 с попереду PCR — запас декодерові.
    const long PtsOffset = 63_000;

    readonly object _lock = new();
    readonly double _target;
    readonly int _keep;
    readonly bool _hasAudio;
    readonly string _prefix;
    readonly List<(string Name, byte[] Data, double Duration)> _segments = new();
    MemoryStream? _current;
    long _currentStart = -1;
    int _sequence, _next;
    byte _ccPat, _ccPmt, _ccVideo, _ccAudio;
    byte[]? _sps, _pps;
    long _bytes;

    public HlsTsSegmenter(bool hasAudio, double targetSeconds = 1, int keep = 6)
    {
        _hasAudio = hasAudio;
        _target = targetSeconds;
        _keep = Math.Max(3, keep);
        // Свій початок імен на кожен запуск кодера: гравець не сплутає старий шматок із новим.
        _prefix = "s" + (Environment.TickCount64 & 0xFFFFF).ToString("x", CultureInfo.InvariantCulture);
    }

    public int SegmentCount { get { lock (_lock) return _segments.Count; } }
    public long BytesWritten { get { lock (_lock) return _bytes; } }

    // ── Вхід ────────────────────────────────────────────────────────────────

    /// Кадр відео — одиниця доступу H.264 у вигляді Annex B (00 00 00 01 …), мітка — 90 кГц.
    public void AddVideo(ReadOnlySpan<byte> accessUnit, long pts90k)
    {
        var nals = Nals(accessUnit);
        var keyframe = false;
        foreach (var (start, length) in nals)
        {
            var type = accessUnit[start] & 0x1F;
            if (type == 5) keyframe = true;
            else if (type == 7) _sps = accessUnit.Slice(start, length).ToArray();
            else if (type == 8) _pps = accessUnit.Slice(start, length).ToArray();
        }
        lock (_lock)
        {
            if (keyframe && (_current == null || pts90k - _currentStart >= _target * 90_000)) Cut(pts90k);
            if (_current == null) return;   // чекаємо першого ключового кадру
            // Одиниця доступу: AUD, потім (на ключовому, якщо їх немає) SPS/PPS, потім сам кадр.
            var unit = new MemoryStream(accessUnit.Length + 64);
            var hasAud = nals.Count > 0 && (accessUnit[nals[0].Start] & 0x1F) == 9;
            if (!hasAud) unit.Write(new byte[] { 0, 0, 0, 1, 0x09, 0xF0 });
            var hasSps = false;
            foreach (var (start, _) in nals) if ((accessUnit[start] & 0x1F) == 7) hasSps = true;
            if (keyframe && !hasSps && _sps != null && _pps != null)
            {
                unit.Write(new byte[] { 0, 0, 0, 1 }); unit.Write(_sps);
                unit.Write(new byte[] { 0, 0, 0, 1 }); unit.Write(_pps);
            }
            unit.Write(accessUnit);
            var pes = Pes(0xE0, unit.ToArray(), pts90k + PtsOffset, bounded: false);
            WritePackets(_current, VideoPid, pes, pts90k, keyframe, ref _ccVideo);
        }
    }

    /// Порція AAC з заголовком ADTS (один чи кілька кадрів), мітка — 90 кГц.
    public void AddAudio(ReadOnlySpan<byte> adts, long pts90k)
    {
        if (!_hasAudio) return;
        lock (_lock)
        {
            if (_current == null) return;
            var pes = Pes(0xC0, adts.ToArray(), pts90k + PtsOffset, bounded: true);
            WritePackets(_current, AudioPid, pes, null, false, ref _ccAudio);
        }
    }

    // ── Список і шматки (сервер, будь-який потік) ───────────────────────────

    public string? Playlist()
    {
        lock (_lock)
        {
            if (_segments.Count == 0) return null;
            var target = Math.Max(1, (int)Math.Ceiling(_segments.Max(s => s.Duration)));
            var text = new StringBuilder();
            text.Append("#EXTM3U\n#EXT-X-VERSION:3\n");
            text.Append("#EXT-X-TARGETDURATION:").Append(target).Append('\n');
            text.Append("#EXT-X-MEDIA-SEQUENCE:").Append(_sequence).Append('\n');
            foreach (var (name, _, duration) in _segments)
                text.Append("#EXTINF:").Append(duration.ToString("0.000", CultureInfo.InvariantCulture)).Append(",\n").Append(name).Append('\n');
            return text.ToString();
        }
    }

    public byte[]? InitSegment() => null;

    public byte[]? Segment(string name)
    {
        lock (_lock)
            foreach (var (n, data, _) in _segments) if (n == name) return data;
        return null;
    }

    // ── Нарізка ─────────────────────────────────────────────────────────────

    void Cut(long pts)
    {
        if (_current != null && _currentStart >= 0)
        {
            var data = _current.ToArray();
            _segments.Add(($"{_prefix}-{_next++}.ts", data, (pts - _currentStart) / 90_000.0));
            _bytes += data.Length;
            while (_segments.Count > _keep) { _segments.RemoveAt(0); _sequence++; }
        }
        _current = new MemoryStream(256 * 1024);
        _currentStart = pts;
        WritePsi(_current, 0, Pat(), ref _ccPat);
        WritePsi(_current, PmtPid, Pmt(), ref _ccPmt);
    }

    // ── MPEG-TS ─────────────────────────────────────────────────────────────

    static List<(int Start, int Length)> Nals(ReadOnlySpan<byte> data)
    {
        var result = new List<(int, int)>();
        var i = 0; var start = -1;
        while (i + 3 <= data.Length)
        {
            var code3 = data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1;
            if (code3)
            {
                if (start >= 0) result.Add((start, TrimZeros(data, start, i) - start));
                start = i + 3;
                i += 3;
                continue;
            }
            i++;
        }
        if (start >= 0 && start < data.Length) result.Add((start, data.Length - start));
        return result;
    }

    /// Кінець NAL перед наступним стартовим кодом: зайві нулі (00 00 00 01) — не його.
    static int TrimZeros(ReadOnlySpan<byte> data, int start, int end)
    {
        while (end > start && data[end - 1] == 0) end--;
        return end;
    }

    static byte[] Pes(int streamId, byte[] payload, long pts, bool bounded)
    {
        var length = bounded ? Math.Min(65535, 8 + payload.Length) : 0;
        var pes = new byte[14 + payload.Length];
        pes[0] = 0; pes[1] = 0; pes[2] = 1; pes[3] = (byte)streamId;
        pes[4] = (byte)(length >> 8); pes[5] = (byte)length;
        pes[6] = (byte)(streamId == 0xE0 ? 0x84 : 0x80);   // '10', вирівняне відео
        pes[7] = 0x80;                                        // лише PTS
        pes[8] = 5;
        WriteTimestamp(pes.AsSpan(9), 0x2, pts);
        payload.CopyTo(pes, 14);
        return pes;
    }

    static void WriteTimestamp(Span<byte> to, int prefix, long ts)
    {
        ts &= 0x1FFFFFFFFL;
        to[0] = (byte)((prefix << 4) | (int)((ts >> 29) & 0x0E) | 1);
        to[1] = (byte)(ts >> 22);
        to[2] = (byte)(((ts >> 14) & 0xFE) | 1);
        to[3] = (byte)(ts >> 7);
        to[4] = (byte)(((ts << 1) & 0xFE) | 1);
    }

    static void WritePackets(Stream output, int pid, byte[] pes, long? pcr, bool randomAccess, ref byte cc)
    {
        Span<byte> packet = stackalloc byte[188];
        var offset = 0;
        var first = true;
        while (offset < pes.Length)
        {
            packet.Fill(0xFF);
            var remaining = pes.Length - offset;
            var withPcr = first && pcr != null;
            var flags = (byte)((first && randomAccess ? 0x40 : 0) | (withPcr ? 0x10 : 0));
            var adaptation = withPcr || flags != 0 ? 2 + (withPcr ? 6 : 0) : 0;   // довжина + прапорці + PCR
            var space = 184 - adaptation;
            if (remaining < space)
            {
                var stuffing = space - remaining;
                adaptation = adaptation == 0 ? stuffing : adaptation + stuffing;
                space = remaining;
            }
            packet[0] = 0x47;
            packet[1] = (byte)((first ? 0x40 : 0) | ((pid >> 8) & 0x1F));
            packet[2] = (byte)pid;
            packet[3] = (byte)((adaptation > 0 ? 0x30 : 0x10) | (cc & 0x0F));
            cc = (byte)((cc + 1) & 0x0F);
            var p = 4;
            if (adaptation > 0)
            {
                packet[p] = (byte)(adaptation - 1);
                if (adaptation > 1)
                {
                    packet[p + 1] = flags;
                    if (withPcr)
                    {
                        var b = pcr!.Value & 0x1FFFFFFFFL;
                        packet[p + 2] = (byte)(b >> 25); packet[p + 3] = (byte)(b >> 17);
                        packet[p + 4] = (byte)(b >> 9); packet[p + 5] = (byte)(b >> 1);
                        packet[p + 6] = (byte)(((b & 1) << 7) | 0x7E); packet[p + 7] = 0;
                    }
                }
                p += adaptation;
            }
            pes.AsSpan(offset, space).CopyTo(packet[p..]);
            offset += space;
            output.Write(packet);
            first = false;
        }
    }

    static void WritePsi(Stream output, int pid, byte[] section, ref byte cc)
    {
        Span<byte> packet = stackalloc byte[188];
        packet.Fill(0xFF);
        packet[0] = 0x47;
        packet[1] = (byte)(0x40 | ((pid >> 8) & 0x1F));
        packet[2] = (byte)pid;
        packet[3] = (byte)(0x10 | (cc & 0x0F));
        cc = (byte)((cc + 1) & 0x0F);
        packet[4] = 0;   // pointer_field
        section.CopyTo(packet[5..]);
        output.Write(packet);
    }

    static byte[] Pat()
    {
        var body = new byte[] { 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, (byte)(0xE0 | (PmtPid >> 8)), unchecked((byte)PmtPid) };
        return Section(0x00, body);
    }

    byte[] Pmt()
    {
        const byte videoHigh = 0xE0 | (VideoPid >> 8), videoLow = VideoPid & 0xFF, audioHigh = 0xE0 | (AudioPid >> 8), audioLow = AudioPid & 0xFF;
        var body = new List<byte> { 0x00, 0x01, 0xC1, 0x00, 0x00, videoHigh, videoLow, 0xF0, 0x00 };
        body.AddRange(new byte[] { 0x1B, videoHigh, videoLow, 0xF0, 0x00 });
        if (_hasAudio) body.AddRange(new byte[] { 0x0F, audioHigh, audioLow, 0xF0, 0x00 });
        return Section(0x02, body.ToArray());
    }

    /// Таблиця: table_id, синтаксис і довжина, тіло, CRC32 (MPEG-2).
    static byte[] Section(int tableId, byte[] body)
    {
        var length = body.Length + 4;
        var section = new byte[3 + length];
        section[0] = (byte)tableId;
        section[1] = (byte)(0xB0 | (length >> 8));
        section[2] = (byte)length;
        body.CopyTo(section, 3);
        var crc = Crc32(section.AsSpan(0, 3 + body.Length));
        section[^4] = (byte)(crc >> 24); section[^3] = (byte)(crc >> 16); section[^2] = (byte)(crc >> 8); section[^1] = (byte)crc;
        return section;
    }

    static uint Crc32(ReadOnlySpan<byte> data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data)
        {
            crc ^= (uint)b << 24;
            for (var i = 0; i < 8; i++) crc = (crc & 0x80000000) != 0 ? (crc << 1) ^ 0x04C11DB7 : crc << 1;
        }
        return crc;
    }
}
