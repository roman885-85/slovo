// =============================================================================
//  Firewall.cs — чи пускає брандмауер Windows вхідні з'єднання до «Слова»
// =============================================================================
//  Пульт, сторінка в браузері (slovo.local), веб-слайди й приймачі NDI з інших
//  комп'ютерів приходять до «Слова» ззовні. Коли програма вперше слухає мережу,
//  Windows питає дозволу; і навіть якщо людина дозволила для «приватних мереж»,
//  Windows сама додає ЗАБОРОННЕ правило для «загальнодоступних» (у тестовій ВМ так:
//  «slovo.exe · вхідні · блокувати · Public»). Мережа нового Wi-Fi часто саме
//  «загальнодоступна» — і все мовчки не працює. Тут: перевірка (без прав
//  адміністратора, COM HNetCfg.FwPolicy2) і кнопка «Дозволити» — одне правило на
//  всі мережі й прибрати заборонні для цієї програми (з підтвердженням Windows, UAC).
// =============================================================================

using System.Diagnostics;
using System.Text;

namespace Slovo.App;

public static class Firewall
{
    static string T(string text, params object[] args) => Captions.T(text, args);

    public sealed record State(bool Blocked, string Text);

    /// Програма, для якої правила (той самий шлях, що бачить брандмауер).
    public static string Program => Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "Slovo.exe");

    public static State Check()
    {
        if (!OperatingSystem.IsWindows()) return new(false, "");
        try
        {
            var type = Type.GetTypeFromProgID("HNetCfg.FwPolicy2");
            if (type == null) return new(false, T("брандмауэр: не удалось проверить"));
            dynamic policy = Activator.CreateInstance(type)!;
            int current = policy.CurrentProfileTypes;   // 1 — домен, 2 — приватна, 4 — загальнодоступна
            var on = false;
            foreach (var bit in new[] { 1, 2, 4 })
                if ((current & bit) != 0 && (bool)policy.FirewallEnabled[bit]) on = true;
            var profile = (current & 4) != 0 ? T("общедоступная") : (current & 2) != 0 ? T("частная") : T("доменная");
            if (!on) return new(false, T("брандмауэр Windows выключен (сеть: %s)", profile));
            bool blocked = false, allowed = false;
            var program = Program;
            foreach (dynamic rule in policy.Rules)
            {
                string? app = rule.ApplicationName;
                if (app == null || !string.Equals(Path.GetFullPath(app), program, StringComparison.OrdinalIgnoreCase)) continue;
                if ((int)rule.Direction != 1 || !(bool)rule.Enabled || ((int)rule.Profiles & current) == 0) continue;
                if ((int)rule.Action == 0) blocked = true; else allowed = true;
            }
            if (blocked) return new(true, T("брандмауэр Windows БЛОКИРУЕТ входящие к «Слову» в этой сети (%s): пульт, slovo.local, NDI с других компьютеров не работают", profile));
            if (!allowed) return new(true, T("брандмауэр Windows не разрешил «Слово» для этой сети (%s) — другие устройства не подключатся", profile));
            return new(false, T("брандмауэр Windows: «Слову» разрешено (сеть: %s)", profile));
        }
        catch (Exception error) { return new(false, T("брандмауэр: не удалось проверить (%s)", error.Message)); }
    }

    /// Дозволити «Слову» вхідні в усіх мережах і прибрати заборонні правила саме для нього.
    /// Windows спитає підтвердження (UAC). Повертає, чи команда відпрацювала.
    public static async Task<bool> AllowAsync()
    {
        if (!OperatingSystem.IsWindows()) return false;
        var program = Program.Replace("'", "''");
        var script = $@"$p = '{program}'
Get-NetFirewallApplicationFilter -Program $p -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {{ $_.Direction -eq 'Inbound' -and $_.Action -eq 'Block' }} | Remove-NetFirewallRule
Get-NetFirewallRule -DisplayName 'Слово (Slovo)' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Слово (Slovo)' -Direction Inbound -Program $p -Action Allow -Profile Any | Out-Null";
        var encoded = Convert.ToBase64String(Encoding.Unicode.GetBytes(script));
        try
        {
            using var process = Process.Start(new ProcessStartInfo("powershell.exe", "-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand " + encoded)
            {
                UseShellExecute = true, Verb = "runas", WindowStyle = ProcessWindowStyle.Hidden,
            });
            if (process == null) return false;
            await process.WaitForExitAsync();
            Journal.Say($"брандмауер: правило «Слово (Slovo)» для {Program} — код {process.ExitCode}");
            return process.ExitCode == 0;
        }
        catch (Exception error)
        {
            // Людина відмовила у вікні UAC — це не помилка програми.
            Journal.Say("брандмауер: дозвіл не додано — " + error.Message);
            return false;
        }
    }
}
