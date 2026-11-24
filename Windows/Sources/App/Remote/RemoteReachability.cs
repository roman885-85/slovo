// =============================================================================
//  RemoteReachability.cs — «Перевірити зв'язок» (як RemoteReachability на Mac)
// =============================================================================
//  Зсередини програми відмову мережі не видно: слухач піднявся — і все ніби
//  гаразд. Тому програма йде до себе дорогою телефона: на 127.0.0.1, на кожну
//  свою адресу в мережі й криком у мережу, — і каже словами, що не вийшло.
//  Поради — для Windows (брандмауер і тип мережі), а не для macOS.
// =============================================================================

using System.Net;
using System.Net.Sockets;
using System.Text;
using Avalonia.Threading;
using Slovo.Core;

namespace Slovo.App;

public static class RemoteReachability
{
    public sealed class Result
    {
        public bool Loopback;
        public string LoopbackNote = "";
        public readonly List<(string Address, bool Answered, string Note)> Addresses = new();
        public bool Beacon;
        public string BeaconNote = "";

        public bool IsFine => Beacon && Addresses.Any(a => a.Answered);

        public string Verdict
        {
            get
            {
                if (!Loopback) return Captions.T("Канал пульта не поднялся в самой программе: ") + LoopbackNote;
                var reachable = Addresses.Where(a => a.Answered).Select(a => a.Address).ToList();
                if (Addresses.Count == 0)
                    return Captions.T("У этой машины нет сетевого адреса, кроме внутреннего: телефон подключиться не сможет. Включите Wi-Fi или сеть по проводу.");
                if (reachable.Count == 0)
                    return Captions.T("Программа отвечает сама себе, но по своему сетевому адресу — нет. Обычная причина — брандмауэр Windows: Параметры → Конфиденциальность и защита → Брандмауэр и защита сети → Разрешить работу с приложением через брандмауэр — у «Слова» должна стоять галочка «Частная». И сеть должна быть «частной», а не «общедоступной».");
                if (!Beacon)
                    return Captions.T("Программа доступна по адресу %s, но на общий вызов по сети не отвечает. Телефон её не найдёт сам — введите адрес в пульте руками. Обычная причина — «изоляция клиентов» в настройках роутера или гостевая сеть.",
                                      string.Join(", ", reachable));
                return Captions.T("Всё в порядке: программа отвечает по адресу %s и откликается на поиск. Если телефон её не находит — он в другой сети.",
                                  string.Join(", ", reachable));
            }
        }
    }

    public static void Probe(int port, string pin, Action<Result> completion)
    {
        Task.Run(async () =>
        {
            var result = new Result();
            (result.Loopback, result.LoopbackNote) = await Ask("127.0.0.1", port, pin);
            foreach (var (address, _) in Names.Addresses())
            {
                var (answered, note) = await Ask(address.ToString(), port, pin);
                result.Addresses.Add((address.ToString(), answered, note));
            }
            (result.Beacon, result.BeaconNote) = await Shout();
            Dispatcher.UIThread.Post(() => completion(result));
        });
    }

    static async Task<(bool, string)> Ask(string host, int port, string pin)
    {
        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
            using var request = new HttpRequestMessage(HttpMethod.Get, $"http://{host}:{port}/api/state");
            if (pin.Length > 0) request.Headers.Add("X-Slovo-Pin", pin);
            using var response = await client.SendAsync(request);
            var code = (int)response.StatusCode;
            if (code == 200) return (true, "");
            return (false, code == 401 ? Captions.T("не подошёл PIN") : $"код {code}");
        }
        catch (Exception error) { return (false, error.Message); }
    }

    /// Крик у мережу тим самим питанням, що й телефон: хто озветься «Slovo».
    static async Task<(bool, string)> Shout()
    {
        try
        {
            using var socket = new UdpClient { EnableBroadcast = true };
            var question = Encoding.UTF8.GetBytes(Beacon.Question);
            await socket.SendAsync(question, question.Length, new IPEndPoint(IPAddress.Broadcast, Beacon.Port));
            var receive = socket.ReceiveAsync();
            if (await Task.WhenAny(receive, Task.Delay(2000)) != receive) return (false, "відповіді на розсилку немає");
            var text = Encoding.UTF8.GetString(receive.Result.Buffer);
            return text.Contains("Slovo") ? (true, "") : (false, "відповідь не наша: " + text[..Math.Min(40, text.Length)]);
        }
        catch (Exception error) { return (false, error.Message); }
    }
}
