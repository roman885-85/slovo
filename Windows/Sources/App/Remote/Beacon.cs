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

    /// IPv4-адреси комп'ютера — першою справжня локальна мережа. Власник (Windows 1.4.2): «в настройках
    /// remote api не указан текущий ip адрес в локальной сети для быстрого подключения» — першою
    /// бралась будь-яка адреса (віртуальний адаптер Hyper-V/VirtualBox/VPN, 169.254…), і в рядку
    /// стояло не те, що набирати на телефоні. Порядок: адаптер зі шлюзом, Ethernet чи Wi-Fi, не
    /// віртуальний, приватний діапазон; 169.254.x.x (немає DHCP) — лише коли нічого іншого.
    public static List<(IPAddress Address, int Index)> Addresses() => Interfaces().Select(i => (i.Address, i.Index)).ToList();

    public sealed record Interface(IPAddress Address, int Index, string Name, bool Gateway, bool Physical);

    public static List<Interface> Interfaces()
    {
        var result = new List<(Interface Item, int Rank)>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up) continue;
                if (nic.NetworkInterfaceType is NetworkInterfaceType.Loopback or NetworkInterfaceType.Tunnel) continue;
                var properties = nic.GetIPProperties();
                int index;
                try { index = properties.GetIPv4Properties().Index; } catch { continue; }
                var gateway = properties.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                var label = (nic.Name + " " + nic.Description).ToLowerInvariant();
                var virtualish = new[] { "vethernet", "hyper-v", "virtualbox", "vmware", "vmnet", "virtual", "tailscale", "zerotier", "wsl", "vpn", "tap-", "wireguard", "hamachi", "npcap", "bluetooth" }
                    .Any(label.Contains);
                var physical = nic.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.FastEthernetT
                               && !virtualish;
                foreach (var unicast in properties.UnicastAddresses)
                {
                    var address = unicast.Address;
                    if (address.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(address)) continue;
                    var bytes = address.GetAddressBytes();
                    var linkLocal = bytes[0] == 169 && bytes[1] == 254;
                    var privateRange = bytes[0] == 10 || (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] <= 31) || (bytes[0] == 192 && bytes[1] == 168);
                    var rank = (linkLocal ? 1000 : 0) + (gateway ? 0 : 100) + (physical ? 0 : 10) + (privateRange ? 0 : 1);
                    result.Add((new Interface(address, index, nic.Name, gateway, physical), rank));
                }
            }
        }
        catch { /* без списку */ }
        return result.OrderBy(r => r.Rank).Select(r => r.Item).ToList();
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
                await SendToGroup(socket, packet);
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
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            catch (SocketException) { continue; }   // ICMP «порт недосяжний» від чужого відповідача — не кінець
            try
            {
                var questions = Questions(received.Buffer);
                if (questions.Count == 0) continue;
                var answers = new List<(string Type, string Name)>();
                var host = _host + ".local";
                foreach (var (type, name, _) in questions)
                {
                    var lower = name.ToLowerInvariant();
                    if (lower == host && type is 1 or 255) answers.Add(("A", host));
                    // IPv6-адреси немає — так і кажемо (NSEC), інакше Windows чекає відповіді на AAAA секунди.
                    else if (lower == host && type == 28) answers.Add(("NSEC", host));
                    else if (lower == "_slovo._tcp.local" && type is 12 or 255) { answers.Add(("PTR", "_slovo._tcp.local")); answers.Add(("SRV", Instance)); answers.Add(("TXT", Instance)); answers.Add(("A", host)); }
                    else if (lower == Instance.ToLowerInvariant() && type is 33 or 16 or 255) { answers.Add(("SRV", Instance)); answers.Add(("TXT", Instance)); answers.Add(("A", host)); }
                    else if (lower == "_services._dns-sd._udp.local" && type is 12 or 255) answers.Add(("PTRS", "_services._dns-sd._udp.local"));
                }
                if (answers.Count == 0) continue;
                var id = (ushort)((received.Buffer[0] << 8) | received.Buffer[1]);
                var asker = received.RemoteEndPoint;
                // Власник (Windows 1.4.2): «http://slovo.local/ в windows не работает». Запит зі «звичайного»
                // порту (не 5353 — legacy unicast, RFC 6762 §6.7) чекає відповіді особисто, з тим самим
                // номером і питанням; біт QU — теж особисто. Раніше відповідь ішла лише в групу 224.0.0.251.
                var legacy = asker.Port != MdnsPort;
                var personal = legacy || questions.Any(q => q.Unicast);
                Answered++;
                var distinct = answers.Distinct().ToArray();
                if (personal)
                {
                    var direct = Response(legacy ? id : (ushort)0, distinct, unicast: legacy, asker.Address, legacy ? received.Buffer : null);
                    if (direct != null) await socket.SendAsync(direct, direct.Length, asker);
                }
                if (!legacy)
                {
                    var packet = Response(0, distinct, unicast: false, asker.Address, null);
                    if (packet != null) await SendToGroup(socket, packet);
                }
            }
            catch { /* чужий пакет */ }
        }
    }

    /// У групу — через кожен адаптер: інакше відповідь іде лише тим інтерфейсом, що в таблиці маршрутів
    /// перший (Wi-Fi і кабель разом, віртуальні адаптери), і в іншій мережі її не чують.
    static async Task SendToGroup(UdpClient socket, byte[] packet)
    {
        var target = new IPEndPoint(Group, MdnsPort);
        var sent = false;
        foreach (var (address, _) in Names.Addresses())
        {
            try
            {
                socket.Client.SetSocketOption(SocketOptionLevel.IP, SocketOptionName.MulticastInterface, address.GetAddressBytes());
                await socket.SendAsync(packet, packet.Length, target);
                sent = true;
            }
            catch { /* інтерфейс без multicast */ }
        }
        if (!sent) await socket.SendAsync(packet, packet.Length, target);
    }

    /// Питання з пакета: (тип, ім'я, чи просить відповіді особисто — біт QU класу).
    static List<(int Type, string Name, bool Unicast)> Questions(byte[] data)
    {
        var result = new List<(int, string, bool)>();
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
            var cls = (data[at + 2] << 8) | data[at + 3];
            at += 4;
            result.Add((type, name, (cls & 0x8000) != 0));
        }
        return result;
    }

    /// Де закінчується розділ питань (щоб повторити його у відповіді на legacy unicast).
    static int QuestionsEnd(byte[] data)
    {
        if (data.Length < 12) return 12;
        int count = (data[4] << 8) | data[5];
        var at = 12;
        for (var i = 0; i < count && i < 20; i++)
        {
            if (ReadName(data, ref at) == null || at + 4 > data.Length) return 12;
            at += 4;
        }
        return at;
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

    /// `unicast` — відповідь на legacy-запит: TTL не більше 10 с і без біта cache-flush (RFC 6762 §6.7),
    /// з повтором питання (`query`). `asker` — хто питав: адреса з його підмережі йде першою.
    byte[]? Response(ushort id, (string Type, string Name)[] answers, bool unicast, IPAddress? asker = null, byte[]? query = null)
    {
        var addresses = Names.Addresses();
        if (addresses.Count == 0) return null;
        if (asker != null) addresses = addresses.OrderBy(a => SameSubnet(a.Address, asker) ? 0 : 1).ToList();
        int Ttl(int ttl) => unicast ? Math.Min(10, ttl) : ttl;
        var flush = !unicast;
        var records = new List<byte[]>();
        foreach (var (type, name) in answers)
        {
            switch (type)
            {
                case "A":
                    foreach (var (address, _) in addresses)
                        records.Add(Record(name, 1, Ttl(120), address.GetAddressBytes(), flush: flush));
                    break;
                case "NSEC":
                {
                    // Наступне ім'я — саме це; у бітовій карті лише тип A (1): AAAA немає.
                    var next = EncodeName(name);
                    var data = new byte[next.Length + 3];
                    Array.Copy(next, data, next.Length);
                    data[next.Length] = 0; data[next.Length + 1] = 1; data[next.Length + 2] = 0x40;
                    records.Add(Record(name, 47, Ttl(120), data, flush: flush));
                    break;
                }
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
        // Legacy unicast — з питаннями запиту (як звичайний DNS); інакше питань 0.
        var questionEnd = query != null ? QuestionsEnd(query) : 12;
        var questionCount = query != null && questionEnd > 12 ? (query[4] << 8) | query[5] : 0;
        packet.WriteByte((byte)(questionCount >> 8)); packet.WriteByte((byte)(questionCount & 0xFF));
        packet.WriteByte((byte)(records.Count >> 8)); packet.WriteByte((byte)(records.Count & 0xFF));
        packet.WriteByte(0); packet.WriteByte(0); packet.WriteByte(0); packet.WriteByte(0);
        if (questionCount > 0) packet.Write(query!, 12, questionEnd - 12);
        foreach (var record in records) packet.Write(record);
        return packet.ToArray();
    }

    /// Чи в одній підмережі /24 (домашні й церковні мережі — майже завжди /24).
    static bool SameSubnet(IPAddress a, IPAddress b)
    {
        if (a.AddressFamily != AddressFamily.InterNetwork || b.AddressFamily != AddressFamily.InterNetwork) return false;
        var x = a.GetAddressBytes(); var y = b.GetAddressBytes();
        return x[0] == y[0] && x[1] == y[1] && x[2] == y[2];
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
