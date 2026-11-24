// =============================================================================
//  Beacon.cs — як пульт знаходить програму в мережі
// =============================================================================
//  Два шляхи, як у «Слова» на Mac: крик у мережу — UDP на порт 8104 зі словом
//  `SLOVO?`, на який відповідаємо ім'ям і портом; і mDNS — ім'я `slovo.local`
//  (запис A) та служба `_slovo._tcp` (PTR/SRV/TXT) — для телефона й планшета
//  через Bonjour і для браузера за іменем без адреси. Свій відповідач, бо в
//  Windows немає Bonjour, а резолвити `.local` Windows 10/11 уміють самі.
// =============================================================================

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace Slovo.App;

public sealed class Beacon
{
    public const int Port = 8104;
    public const string Question = "SLOVO?";
    UdpClient? _socket;
    CancellationTokenSource? _stopping;
    public int Answered { get; private set; }
    public string? Error { get; private set; }
    readonly Func<int> _port;

    public Beacon(Func<int> port) => _port = port;

    public void Start()
    {
        Stop();
        try
        {
            _socket = new UdpClient(AddressFamily.InterNetwork);
            _socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _socket.Client.Bind(new IPEndPoint(IPAddress.Any, Port));
            _stopping = new CancellationTokenSource();
            _ = Loop(_stopping.Token);
            Error = null;
        }
        catch (Exception error)
        {
            Error = error.Message;
            Journal.Say("пульт: розсилка не піднялася — " + error.Message);
        }
    }

    public void Stop()
    {
        try { _stopping?.Cancel(); } catch { /* уже */ }
        try { _socket?.Close(); } catch { /* уже */ }
        _socket = null;
        _stopping = null;
    }

    async Task Loop(CancellationToken token)
    {
        var socket = _socket;
        if (socket == null) return;
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult received;
            try { received = await socket.ReceiveAsync(token); }
            catch { break; }
            try
            {
                var text = Encoding.UTF8.GetString(received.Buffer);
                if (!text.StartsWith(Question, StringComparison.Ordinal)) continue;
                Answered++;
                var reply = "{\"app\":\"Slovo\",\"name\":" + Json.Quote(Names.Computer) + ",\"port\":" + _port() + "}";
                var bytes = Encoding.UTF8.GetBytes(reply);
                await socket.SendAsync(bytes, bytes.Length, received.RemoteEndPoint);
            }
            catch { /* одна відповідь не дійшла — не біда */ }
        }
    }
}

public static class Names
{
    /// Ім'я комп'ютера — так програма зветься в списку на телефоні.
    public static string Computer
    {
        get
        {
            try { return Environment.MachineName; } catch { return "Windows"; }
        }
    }

    /// Ім'я, придатне для мережі: латиниця, цифри й дефіс; порожнє — «slovo».
    public static string Clean(string name)
    {
        var text = new string(name.ToLowerInvariant().Where(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-').Take(40).ToArray()).Trim('-');
        return text.Length == 0 ? "slovo" : text;
    }

    /// Живі адреси IPv4 цієї машини.
    public static List<(IPAddress Address, int Index)> Addresses()
    {
        var result = new List<(IPAddress, int)>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                var properties = nic.GetIPProperties();
                int index;
                try { index = properties.GetIPv4Properties().Index; } catch { continue; }
                foreach (var unicast in properties.UnicastAddresses)
                    if (unicast.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(unicast.Address))
                        result.Add((unicast.Address, index));
            }
        }
        catch { /* без списку */ }
        return result;
    }
}

/// Відповідач mDNS: `slovo.local` → наші адреси, `_slovo._tcp.local` → служба.
public sealed class Mdns
{
    static readonly IPAddress Group = IPAddress.Parse("224.0.0.251");
    const int MdnsPort = 5353;
    UdpClient? _socket;
    CancellationTokenSource? _stopping;
    string _host = "slovo";
    int _port = 8103;
    public string? Name { get; private set; }
    public List<string> Announced { get; private set; } = new();
    public int Answered { get; private set; }

    /// `name` — без «.local»; друга копія в мережі своє ім'я не перевіряє.
    public void Start(string name, int port)
    {
        Stop();
        _host = Names.Clean(name);
        _port = port;
        try
        {
            _socket = new UdpClient(AddressFamily.InterNetwork);
            _socket.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            _socket.Client.Bind(new IPEndPoint(IPAddress.Any, MdnsPort));
            foreach (var (address, _) in Names.Addresses())
            {
                try { _socket.JoinMulticastGroup(Group, address); } catch { /* інтерфейс без multicast */ }
            }
            _socket.MulticastLoopback = true;
            _stopping = new CancellationTokenSource();
            Name = _host + ".local";
            Announced = Names.Addresses().Select(a => a.Address.ToString()).ToList();
            _ = Loop(_stopping.Token);
            _ = Announce();
            Journal.Say("ім'я: " + Name + " → " + string.Join(", ", Announced));
        }
        catch (Exception error)
        {
            Name = null;
            Journal.Say("ім'я: mDNS не піднявся — " + error.Message);
        }
    }

    public void Stop()
    {
        try { _stopping?.Cancel(); } catch { /* уже */ }
        try { _socket?.Close(); } catch { /* уже */ }
        _socket = null;
        _stopping = null;
        Name = null;
    }

    async Task Announce()
    {
        // Неспитана відповідь — щоб кеші в мережі дізналися про нас одразу.
        for (var i = 0; i < 2; i++)
        {
            try
            {
                var packet = Response(0, new[] { ("A", _host + ".local"), ("PTR", "_slovo._tcp.local"), ("SRV", Instance), ("TXT", Instance) }, unicast: false);
                var socket = _socket;
                if (socket == null || packet == null) return;
                await socket.SendAsync(packet, packet.Length, new IPEndPoint(Group, MdnsPort));
            }
            catch { /* не дійшло — відповімо на запит */ }
            await Task.Delay(1000);
        }
    }

    string Instance => "Slovo (" + Names.Computer + ")._slovo._tcp.local";

    async Task Loop(CancellationToken token)
    {
        var socket = _socket;
        if (socket == null) return;
        while (!token.IsCancellationRequested)
        {
            UdpReceiveResult received;
            try { received = await socket.ReceiveAsync(token); }
            catch { break; }
            try
            {
                var wanted = Questions(received.Buffer);
                if (wanted.Count == 0) continue;
                var answers = new List<(string Type, string Name)>();
                foreach (var (type, name) in wanted)
                {
                    var lower = name.ToLowerInvariant();
                    if (lower == _host + ".local" && type is 1 or 255) answers.Add(("A", _host + ".local"));
                    else if (lower == "_slovo._tcp.local" && type is 12 or 255) { answers.Add(("PTR", "_slovo._tcp.local")); answers.Add(("SRV", Instance)); answers.Add(("TXT", Instance)); answers.Add(("A", _host + ".local")); }
                    else if (lower == Instance.ToLowerInvariant() && type is 33 or 16 or 255) { answers.Add(("SRV", Instance)); answers.Add(("TXT", Instance)); answers.Add(("A", _host + ".local")); }
                    else if (lower == "_services._dns-sd._udp.local" && type is 12 or 255) answers.Add(("PTRS", "_services._dns-sd._udp.local"));
                }
                if (answers.Count == 0) continue;
                var id = (ushort)((received.Buffer[0] << 8) | received.Buffer[1]);
                var packet = Response(id, answers.Distinct().ToArray(), unicast: false);
                if (packet == null) continue;
                Answered++;
                await socket.SendAsync(packet, packet.Length, new IPEndPoint(Group, MdnsPort));
            }
            catch { /* чужий пакет */ }
        }
    }

    /// Питання з пакета: (тип, ім'я).
    static List<(int Type, string Name)> Questions(byte[] data)
    {
        var result = new List<(int, string)>();
        if (data.Length < 12) return result;
        var flags = (data[2] << 8) | data[3];
        if ((flags & 0x8000) != 0) return result;   // це відповідь, не питання
        int count = (data[4] << 8) | data[5];
        var at = 12;
        for (var i = 0; i < count && i < 20; i++)
        {
            var name = ReadName(data, ref at);
            if (name == null || at + 4 > data.Length) break;
            var type = (data[at] << 8) | data[at + 1];
            at += 4;
            result.Add((type, name));
        }
        return result;
    }

    static string? ReadName(byte[] data, ref int at)
    {
        var parts = new List<string>();
        var jumps = 0;
        var end = -1;
        while (at < data.Length)
        {
            var length = data[at];
            if (length == 0) { at++; break; }
            if ((length & 0xC0) == 0xC0)
            {
                if (at + 1 >= data.Length || ++jumps > 10) return null;
                var pointer = ((length & 0x3F) << 8) | data[at + 1];
                if (end < 0) end = at + 2;
                at = pointer;
                continue;
            }
            at++;
            if (at + length > data.Length) return null;
            parts.Add(Encoding.UTF8.GetString(data, at, length));
            at += length;
        }
        if (end >= 0) at = end;
        return string.Join(".", parts);
    }

    byte[]? Response(ushort id, (string Type, string Name)[] answers, bool unicast)
    {
        var addresses = Names.Addresses();
        if (addresses.Count == 0) return null;
        var records = new List<byte[]>();
        foreach (var (type, name) in answers)
        {
            switch (type)
            {
                case "A":
                    foreach (var (address, _) in addresses)
                        records.Add(Record(name, 1, 120, address.GetAddressBytes(), flush: true));
                    break;
                case "PTR":
                    records.Add(Record(name, 12, 4500, EncodeName(Instance), flush: false));
                    break;
                case "PTRS":
                    records.Add(Record(name, 12, 4500, EncodeName("_slovo._tcp.local"), flush: false));
                    break;
                case "SRV":
                {
                    var target = EncodeName(_host + ".local");
                    var data = new byte[6 + target.Length];
                    data[4] = (byte)(_port >> 8); data[5] = (byte)(_port & 0xFF);
                    Array.Copy(target, 0, data, 6, target.Length);
                    records.Add(Record(name, 33, 120, data, flush: true));
                    break;
                }
                case "TXT":
                {
                    var txt = Encoding.UTF8.GetBytes("app=Slovo");
                    var data = new byte[1 + txt.Length];
                    data[0] = (byte)txt.Length;
                    Array.Copy(txt, 0, data, 1, txt.Length);
                    records.Add(Record(name, 16, 4500, data, flush: true));
                    break;
                }
            }
        }
        if (records.Count == 0) return null;
        var packet = new MemoryStream();
        packet.WriteByte((byte)(id >> 8)); packet.WriteByte((byte)(id & 0xFF));
        packet.WriteByte(0x84); packet.WriteByte(0x00);          // відповідь, authoritative
        packet.WriteByte(0); packet.WriteByte(0);                // питань 0
        packet.WriteByte((byte)(records.Count >> 8)); packet.WriteByte((byte)(records.Count & 0xFF));
        packet.WriteByte(0); packet.WriteByte(0); packet.WriteByte(0); packet.WriteByte(0);
        foreach (var record in records) packet.Write(record);
        return packet.ToArray();
    }

    static byte[] Record(string name, int type, int ttl, byte[] data, bool flush)
    {
        var output = new MemoryStream();
        output.Write(EncodeName(name));
        output.WriteByte((byte)(type >> 8)); output.WriteByte((byte)(type & 0xFF));
        var cls = 1 | (flush ? 0x8000 : 0);
        output.WriteByte((byte)(cls >> 8)); output.WriteByte((byte)(cls & 0xFF));
        output.WriteByte((byte)(ttl >> 24)); output.WriteByte((byte)(ttl >> 16)); output.WriteByte((byte)(ttl >> 8)); output.WriteByte((byte)ttl);
        output.WriteByte((byte)(data.Length >> 8)); output.WriteByte((byte)(data.Length & 0xFF));
        output.Write(data);
        return output.ToArray();
    }

    static byte[] EncodeName(string name)
    {
        var output = new MemoryStream();
        foreach (var part in name.Split('.', StringSplitOptions.RemoveEmptyEntries))
        {
            var bytes = Encoding.UTF8.GetBytes(part);
            var length = Math.Min(63, bytes.Length);
            output.WriteByte((byte)length);
            output.Write(bytes, 0, length);
        }
        output.WriteByte(0);
        return output.ToArray();
    }
}

/// Дрібниці JSON для рядків без System.Text.Json.
public static class Json
{
    public static string Quote(string text)
    {
        var sb = new StringBuilder("\"");
        foreach (var ch in text)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4")); else sb.Append(ch);
                    break;
            }
        }
        return sb.Append('"').ToString();
    }
}
