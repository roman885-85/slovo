// =============================================================================
//  Discovery.cs — пошук «Слова» в локальній мережі
// =============================================================================
//  Три шляхи одразу, бо в Windows кожен окремо буває глухим:
//
//  1. Розсилка «SLOVO?» на UDP-порт 8104 — як у пульта на Android. Windows
//     часто не пропускає відповідь на широкомовний запит: брандмауер тримає
//     зворотний шлях лише для того, кому ми писали напряму. Власник
//     19.09.2026: «программа для windows не находит слово по сети,
//     подключение только по ручному вводу адреса».
//  2. Ім'я `slovo.local` — Windows 10 і 11 розбирають `.local` самі.
//  3. Обхід своєї підмережі: TCP-стук у порт 8103 на кожну адресу. Вихідні
//     з'єднання брандмауер пропускає завжди, тож цей шлях працює й тоді,
//     коли обидва перші мовчать.
// =============================================================================

using System;
using System.Collections.Generic;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Http;
using System.Net.Sockets;
using System.Linq;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading;
using System.Threading.Tasks;

namespace Propovidnyk;

public sealed record Found(string Name, string Host, int Port);

public static class Discovery
{
    public const int BeaconPort = 8104;

    public static async Task<List<Found>> Search(CancellationToken cancel = default)
    {
        var found = new List<Found>();
        var seen = new HashSet<string>();
        void Add(Found one)
        {
            lock (found)
            {
                if (seen.Add(one.Host + ":" + one.Port)) found.Add(one);
            }
        }

        // Три шляхи разом: хто відповів першим, той і в списку.
        var beacon = Beacon(Add, cancel);
        var byName = ByName(Add, cancel);
        var sweep = Sweep(Add, cancel);
        await Task.WhenAll(beacon, byName, sweep);
        return found;
    }

    /// Розсилка «SLOVO?» на UDP 8104 — найшвидший шлях, коли він працює.
    static async Task Beacon(Action<Found> add, CancellationToken cancel)
    {
        try
        {
            using var socket = new UdpClient(AddressFamily.InterNetwork);
            socket.EnableBroadcast = true;
            var question = Encoding.UTF8.GetBytes("SLOVO?");
            for (var round = 0; round < 3 && !cancel.IsCancellationRequested; round++)
            {
                foreach (var target in Targets())
                {
                    try { await socket.SendAsync(question, question.Length, new IPEndPoint(target, BeaconPort)); }
                    catch { /* мережа без розсилки — пробуємо наступну */ }
                }
                var until = DateTime.UtcNow.AddMilliseconds(900);
                while (DateTime.UtcNow < until && !cancel.IsCancellationRequested)
                {
                    var left = until - DateTime.UtcNow;
                    if (left <= TimeSpan.Zero) break;
                    using var wait = CancellationTokenSource.CreateLinkedTokenSource(cancel);
                    wait.CancelAfter(left);
                    UdpReceiveResult reply;
                    try { reply = await socket.ReceiveAsync(wait.Token); }
                    catch { break; }
                    try
                    {
                        var json = JsonNode.Parse(Encoding.UTF8.GetString(reply.Buffer)) as JsonObject;
                        if ((string?)json?["app"] != "Slovo") continue;
                        add(new Found((string?)json!["name"] ?? "Слово", reply.RemoteEndPoint.Address.ToString(), (int?)json["port"] ?? 8103));
                    }
                    catch
                    {
                        // Чужий пакет — пропускаємо.
                    }
                }
            }
        }
        catch
        {
            // Немає розсилки — лишаються два інші шляхи.
        }
    }

    /// «slovo.local» — ім'я, яке «Слово» оголошує в мережі.
    static async Task ByName(Action<Found> add, CancellationToken cancel)
    {
        foreach (var name in new[] { "slovo.local", "slovo" })
        {
            try
            {
                var addresses = await Dns.GetHostAddressesAsync(name, cancel);
                foreach (var address in addresses.Where(a => a.AddressFamily == AddressFamily.InterNetwork))
                {
                    var answer = await Ask(address.ToString(), 8103, 1500, cancel);
                    if (answer != null) add(answer);
                }
            }
            catch
            {
                // Імені немає — не біда.
            }
        }
    }

    /// Обхід своєї підмережі: стук у порт 8103 на кожну адресу /24.
    static async Task Sweep(Action<Found> add, CancellationToken cancel)
    {
        var mine = new List<IPAddress>();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up) continue;
            if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var mask = unicast.IPv4Mask;
                // Лише звичайні домашні мережі (/24 і вужчі): ширші обходити довго.
                if (mask == null || mask.GetAddressBytes()[2] != 255) continue;
                mine.Add(unicast.Address);
            }
        }
        using var limit = new SemaphoreSlim(64);
        var work = new List<Task>();
        foreach (var address in mine)
        {
            var bytes = address.GetAddressBytes();
            for (var last = 1; last <= 254; last++)
            {
                if (last == bytes[3]) continue;
                var probe = new IPAddress(new[] { bytes[0], bytes[1], bytes[2], (byte)last });
                work.Add(Knock(probe, limit, add, cancel));
            }
        }
        try { await Task.WhenAll(work); } catch { /* частина адрес просто мовчить */ }
    }

    static async Task Knock(IPAddress address, SemaphoreSlim limit, Action<Found> add, CancellationToken cancel)
    {
        await limit.WaitAsync(cancel);
        try
        {
            using var client = new TcpClient();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            deadline.CancelAfter(500);
            try { await client.ConnectAsync(address, 8103, deadline.Token); }
            catch { return; }
            var answer = await Ask(address.ToString(), 8103, 2000, cancel);
            if (answer != null) add(answer);
        }
        catch
        {
            // Тиша на цій адресі.
        }
        finally
        {
            limit.Release();
        }
    }

    /// Чи це «Слово»: питаємо стан і беремо ім'я комп'ютера з відповіді.
    static async Task<Found?> Ask(string host, int port, int milliseconds, CancellationToken cancel)
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromMilliseconds(milliseconds) };
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            deadline.CancelAfter(milliseconds);
            using var response = await client.GetAsync($"http://{host}:{port}/api/state?since=0", deadline.Token);
            // PIN — теж відповідь: «Слово» там є, лише просить пароль.
            if ((int)response.StatusCode is 401 or 403)
                return new Found(Lang.T("Слово (потрібен PIN)", "Slovo (PIN required)"), host, port);
            if (!response.IsSuccessStatusCode) return null;
            var text = await response.Content.ReadAsStringAsync(deadline.Token);
            if (JsonNode.Parse(text) is not JsonObject state) return null;
            // Стан «Слова» завжди має номер і вкладку — чужий сервер їх не має.
            if (state["seq"] == null || state["mode"] == null) return null;
            var name = (string?)state["name"] ?? "";
            return new Found(name.Length > 0 ? name : "Слово", host, port);
        }
        catch
        {
            return null;
        }
    }

    /// Загальна розсилка й розсилка кожної мережі комп'ютера: у Windows
    /// 255.255.255.255 часто йде не в той адаптер (VPN, віртуальні мережі).
    static IEnumerable<IPAddress> Targets()
    {
        var targets = new HashSet<IPAddress> { IPAddress.Broadcast };
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up) continue;
            if (adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            foreach (var unicast in adapter.GetIPProperties().UnicastAddresses)
            {
                if (unicast.Address.AddressFamily != AddressFamily.InterNetwork) continue;
                var mask = unicast.IPv4Mask;
                if (mask == null || mask.Equals(IPAddress.Any)) continue;
                var address = unicast.Address.GetAddressBytes();
                var bits = mask.GetAddressBytes();
                var broadcast = new byte[4];
                for (var i = 0; i < 4; i++) broadcast[i] = (byte)(address[i] | ~bits[i]);
                targets.Add(new IPAddress(broadcast));
            }
        }
        return targets;
    }
}
