# =============================================================================
#  ui-check.ps1 — меню в шапці, «Параметри», ім'я .local і дотики пальцем (Windows 1.4.3)
# =============================================================================
#  Скарги власника на 1.4.2: меню в шапці налягали; «Параметри» відкривались довго й не
#  гортались; slovo.local; підтримка сенсорного екрана. Справжня програма у звичайному режимі
#  (test-data-hall), справжні клацання мишею (SetCursorPos/mouse_event), колесо, і дотики
#  пальцем (InjectTouchInput — Windows бачить їх як сенсорний екран). Тека стирається;
#  %APPDATA%\Slovo не чіпається; брандмауер не змінюється.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\ui-check'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-ui'
$exe = Join-Path $root 'Slovo.exe'
foreach ($p0 in @($back, $root)) { if (Test-Path $p0) { Remove-Item $p0 -Recurse -Force -ErrorAction SilentlyContinue } }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-hall') $d -Recurse -Force
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
Add-Type -TypeDefinition @'
using System; using System.Runtime.InteropServices; using System.Text; using System.Threading;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool GetClientRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool ClientToScreen(IntPtr h, ref POINT p);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(int f, int dx, int dy, int data, IntPtr extra);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc p, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  public static IntPtr Find(uint pid, string title) {
    IntPtr best = IntPtr.Zero; long area = 0;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256); if (sb.ToString() != title) return true;
      RECT r; GetWindowRect(h, out r); long a = (long)(r.R - r.L) * (r.B - r.T); if (a > area) { area = a; best = h; } return true; }, IntPtr.Zero);
    return best; }
  public static int CountVisible(uint pid) { int n = 0; EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) n++; return true; }, IntPtr.Zero); return n; }
  public static void Click(int x, int y) { SetCursorPos(x, y); Thread.Sleep(80); mouse_event(0x02, 0, 0, 0, IntPtr.Zero); Thread.Sleep(60); mouse_event(0x04, 0, 0, 0, IntPtr.Zero); }
  public static void Wheel(int x, int y, int delta) { SetCursorPos(x, y); Thread.Sleep(80); mouse_event(0x0800, 0, 0, delta, IntPtr.Zero); }
  // Сенсорний екран: InjectTouchInput.
  [StructLayout(LayoutKind.Sequential)] public struct POINTER_INFO { public int pointerType; public uint pointerId; public uint frameId; public int pointerFlags; public IntPtr sourceDevice; public IntPtr hwndTarget; public POINT ptPixelLocation; public POINT ptHimetricLocation; public POINT ptPixelLocationRaw; public POINT ptHimetricLocationRaw; public uint dwTime; public uint historyCount; public int InputData; public uint dwKeyStates; public ulong PerformanceCount; public int ButtonChangeType; }
  [StructLayout(LayoutKind.Sequential)] public struct POINTER_TOUCH_INFO { public POINTER_INFO pointerInfo; public int touchFlags; public int touchMask; public RECT rcContact; public RECT rcContactRaw; public uint orientation; public uint pressure; }
  [DllImport("user32.dll", SetLastError = true)] public static extern bool InitializeTouchInjection(uint maxCount, int mode);
  [DllImport("user32.dll", SetLastError = true)] public static extern bool InjectTouchInput(uint count, [In] POINTER_TOUCH_INFO[] contacts);
  static bool Touch(int x, int y, int flags) {
    var c = new POINTER_TOUCH_INFO[1];
    c[0].pointerInfo.pointerType = 2; c[0].pointerInfo.pointerId = 0; c[0].pointerInfo.pointerFlags = flags;
    c[0].pointerInfo.ptPixelLocation.X = x; c[0].pointerInfo.ptPixelLocation.Y = y;
    c[0].touchFlags = 0; c[0].touchMask = 0x7; c[0].orientation = 90; c[0].pressure = 32000;
    c[0].rcContact.L = x - 2; c[0].rcContact.R = x + 2; c[0].rcContact.T = y - 2; c[0].rcContact.B = y + 2;
    return InjectTouchInput(1, c); }
  public static string Init() { return InitializeTouchInjection(1, 1) ? "так" : "ні (" + Marshal.GetLastWin32Error() + ")"; }
  public static bool Tap(int x, int y) { bool a = Touch(x, y, 0x10006); Thread.Sleep(60); bool b = Touch(x, y, 0x40000); return a && b; }
  public static bool Hold(int x, int y, int ms) { bool a = Touch(x, y, 0x10006); for (int t = 0; t < ms; t += 50) { Thread.Sleep(50); Touch(x, y, 0x20006); } bool b = Touch(x, y, 0x40000); return a && b; }
  public static bool Drag(int x, int y1, int y2, int steps) { bool ok = Touch(x, y1, 0x10006); for (int i = 1; i <= steps; i++) { Thread.Sleep(16); ok &= Touch(x, y1 + (y2 - y1) * i / steps, 0x20006); } Thread.Sleep(16); ok &= Touch(x, y2, 0x40000); return ok; }
}
'@
[U]::SetProcessDPIAware() | Out-Null
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function State { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:8103/api/state'; return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json) } catch { return $null } }
function PostApp($cmd, $body) { $bytes = [Text.Encoding]::UTF8.GetBytes($body); try { $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 20 ("http://127.0.0.1:8103/api/" + $cmd); return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } catch { return "ERR " + $_.Exception.Message } }
function Shot($h, $name) {
    $r = New-Object U+RECT; [U]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $ht = $r.B - $r.T; if ($w -le 0 -or $ht -le 0) { return "" }
    $bmp = New-Object System.Drawing.Bitmap $w, $ht; $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($r.L, $r.T, 0, 0, (New-Object System.Drawing.Size $w, $ht)); $file = Join-Path $back "$name.png"; $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    return (Get-FileHash $file -Algorithm MD5).Hash.Substring(0, 8) }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
$up = $false
for ($i = 0; $i -lt 90 -and -not $up; $i++) { Start-Sleep 1; if (State) { $up = $true } }
"пульт: $up"
Start-Sleep 8
$appPid = [uint32]$app.Id
$main = [U]::Find($appPid, 'Слово')
$scale = [U]::GetDpiForWindow($main) / 96.0
$origin = New-Object U+POINT; [U]::ClientToScreen($main, [ref]$origin) | Out-Null
$client = New-Object U+RECT; [U]::GetClientRect($main, [ref]$client) | Out-Null
"головне вікно: $($client.R)x$($client.B) пікселів, масштаб $scale"
function At([double]$x, [double]$y) { return @([int]($origin.X + $x * $scale), [int]($origin.Y + $y * $scale)) }
[U]::SetForegroundWindow($main) | Out-Null; Start-Sleep 1
# 1) Меню в шапці.
$n0 = [U]::CountVisible($appPid)
$p = At 28 11; [U]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 900; $n1 = [U]::CountVisible($appPid)
$p = At 85 11; [U]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 900; $n2 = [U]::CountVisible($appPid)
"меню: вікон до $n0, після «Файл» $n1, після «Дії» $n2 (налягання — якщо $n2 > $n1); знімок $(Shot $main 'меню-дії')"
$p = At 85 11; [U]::Click($p[0], $p[1]); Start-Sleep -Milliseconds 700; $n3 = [U]::CountVisible($appPid)
"меню: ще раз «Дії» — вікон $n3 (закрилось — якщо $n3 = $n0)"
(New-Object -ComObject WScript.Shell).SendKeys('{ESC}'); Start-Sleep -Milliseconds 400
# 2) «Параметри».
$clock = [Diagnostics.Stopwatch]::StartNew()
"settings: " + (PostApp 'window-open' '{"text":"settings:1"}') + " за $($clock.ElapsedMilliseconds) мс"
$set = [IntPtr]::Zero; for ($i = 0; $i -lt 40 -and $set -eq [IntPtr]::Zero; $i++) { Start-Sleep -Milliseconds 250; $set = [U]::Find($appPid, 'Параметри') }
"«Параметри» на екрані через $($clock.ElapsedMilliseconds) мс"
Start-Sleep 2
$r = New-Object U+RECT; [U]::GetWindowRect($set, [ref]$r) | Out-Null
"«Параметри»: $($r.R - $r.L)x$($r.B - $r.T) пікселів; екран $([System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Size)"
$h1 = Shot $set 'параметри-медіа-1'
[U]::Wheel([int](($r.L + $r.R) / 2 - 150 * $scale), [int](($r.T + $r.B) / 2), -720); Start-Sleep 1
$h2 = Shot $set 'параметри-медіа-2'
"колесо в «Параметрах»: знімок до $h1, після $h2 (прокрутилось — якщо різні)"
"settings:4 " + (PostApp 'window-open' '{"text":"settings:4"}'); Start-Sleep 2
"Remote API: $(Shot $set 'параметри-remote')"
"close: " + (PostApp 'window-open' '{"text":"close"}'); Start-Sleep 1
# 3) Ім'я .local.
foreach ($k in 1..3) { $c = [Diagnostics.Stopwatch]::StartNew(); try { $rr = Resolve-DnsName slovo.local -Type A -ErrorAction Stop; "Resolve-DnsName slovo.local #$k`: $(($rr | ForEach-Object { $_.IPAddress }) -join ',') за $($c.ElapsedMilliseconds) мс" } catch { "Resolve-DnsName slovo.local #$k`: не вийшло за $($c.ElapsedMilliseconds) мс" }; Clear-DnsClientCache }
try { $w = Invoke-WebRequest -UseBasicParsing -TimeoutSec 8 'http://slovo.local/'; "http://slovo.local/ → $($w.StatusCode), $($w.RawContentLength) байт" } catch { "http://slovo.local/ → $($_.Exception.Message)" }
# 4) Дотики пальцем: список віршів.
"mode: " + (PostApp 'mode' '{"text":"bible"}'); Start-Sleep 2
[U]::SetForegroundWindow($main) | Out-Null; Start-Sleep 1
"InitializeTouchInjection: $([U]::Init())"
$W = $client.R / $scale; $H = $client.B / $scale
$s0 = (State).bible.verses
$p = At ($W * 0.85) ($H * 0.30); $tap = [U]::Tap($p[0], $p[1]); Start-Sleep -Milliseconds 800
$s1 = (State).bible.verses
"дотик (InjectTouchInput $tap): вірші $s0 → $s1 (вибрано — якщо змінилось)"
$b1 = Shot $main 'дотик-до-протяжки'
$p1 = At ($W * 0.85) ($H * 0.55); $p2 = At ($W * 0.85) ($H * 0.12)
$drag = [U]::Drag($p1[0], $p1[1], $p2[1], 20); Start-Sleep 1
$s2 = (State).bible.verses
$b2 = Shot $main 'дотик-після-протяжки'
"протяжка пальцем ($drag): вибір $s1 → $s2 (лишився — якщо однаково), знімок $b1 → $b2 (прокрутилось — якщо різні)"
$l0 = (State).live.reference
$p = At ($W * 0.85) ($H * 0.36); [U]::Tap($p[0], $p[1]) | Out-Null; Start-Sleep -Milliseconds 120; [U]::Tap($p[0], $p[1]) | Out-Null; Start-Sleep 1
$st = State
"подвійний дотик: вибір $($st.bible.verses), зал «$($st.live.reference)» (було «$l0»)"
$c0 = [U]::CountVisible($appPid)
$p = At ($W * 0.85) ($H * 0.30); $hold = [U]::Hold($p[0], $p[1], 1000); Start-Sleep -Milliseconds 600
$c1 = [U]::CountVisible($appPid)
"затримка пальцем ($hold): вікон $c0 → $c1 (меню — якщо більше); знімок $(Shot $main 'дотик-меню')"
(New-Object -ComObject WScript.Shell).SendKeys('{ESC}'); Start-Sleep -Milliseconds 500
# Мережа ззовні: Mac перевіряє slovo.local, сторінку пульта й NDI, поки програма працює.
"брандмауер для цього Slovo.exe: " + ((Get-NetFirewallApplicationFilter -Program $exe -ErrorAction SilentlyContinue | Get-NetFirewallRule -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Action)/$($_.Profile)" }) -join ', ')
"NET-READY"
Start-Sleep 50
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; $app.WaitForExit(10000) | Out-Null; Start-Sleep 2
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "параметри|LibVLC|ім'я|вікно «|головний потік|чекав|виконувався" | Select-Object -Last 16 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
