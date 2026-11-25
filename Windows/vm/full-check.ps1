# =============================================================================
#  full-check.ps1 — перевірки Windows-«Слова», яких не зробити на Mac, за один раз
# =============================================================================
#  Та сама збірка (Службові/vm-new/Слово.exe) і копії даних (bench-data,
#  test-data-yt, core-data — лише для читання) у %LOCALAPPDATA%\slovo-test-all;
#  результати — у Службові/vm/full/.
#   1) ядро: --core-check (звірка з виводом Mac — на Mac, tools/core-compare.sh);
#   2) захват звуку свого процесу (--loopback-check);
#   3) сторож головного потоку (--watchdog-check);
#   4) «Відео по Wi-Fi»: кодери Media Foundation + свій MPEG-TS (--webvideo-check);
#   5) показ за вкладками Біблія ↔ Презентація (--show-check);
#   6) заміри: --bench all (без вікна) і --live-bench (справжнє вікно);
#   7) ролик YouTube без yt-dlp — вбудований програвач (WebView2) у справжній
#      програмі, і «Відео по Wi-Fi» з його картинкою й звуком (шматки — на Mac).
#  %APPDATA%\Slovo не чіпається (час зміни звіряється до й після); тека стирається.
#  %LOCALAPPDATA%\Slovo\WebView2 (профіль браузера) стирається, лише якщо до
#  перевірки його не було.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\full'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-all'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
$webview = Join-Path $env:LOCALAPPDATA 'Slovo\WebView2'
$webviewBefore = Test-Path $webview
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
"sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower())"
"Windows: $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version); $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name); пам'ять $([int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)) МБ"
"звук: " + ((Get-CimInstance Win32_SoundDevice | ForEach-Object { $_.Name }) -join '; ')

function Fresh($name, $from) {
    $d = Join-Path $root $name
    if (Test-Path $d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue }
    Copy-Item -LiteralPath $from $d -Recurse -Force
    return $d
}
function Run($name, $argv, $minutes) {
    $out = Join-Path $back "$name.txt"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $exe -ArgumentList $argv -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError (Join-Path $root "$name-err.txt")
    $null = $p.Handle
    if (-not $p.WaitForExit($minutes * 60000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; "[$name] ЗАВИСЛО: $minutes хв — зупинено" }
    "[$name] код $($p.ExitCode), $([int]$clock.Elapsed.TotalSeconds) с"
    Get-Content $out -Encoding UTF8 -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s\s\S' -and $_ -notmatch '^\s\s(✓|#)' } | Select-Object -First 12 | ForEach-Object { "   $_" }
    Get-Content (Join-Path $root "$name-err.txt") -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 5 | ForEach-Object { "   stderr: $_" }
}

# 1) Ядро.
$core = Fresh 'core-data' (Join-Path $src 'core-data')
Run 'core-check' @('--core-check', $core) 15
"   рядків ядра: $((Get-Content (Join-Path $back 'core-check.txt') -Encoding UTF8 -ErrorAction SilentlyContinue).Count)"

# 2–5) Перевірки в режимі знімків.
$d = Fresh 'data-snap' (Join-Path $src 'vm-new\bench-data')
$shots = Join-Path $root 'shots'
Run 'loopback' @('--snapshot', $shots, '--only', 'заставка', '--data', $d, '--loopback-check') 3
Run 'watchdog' @('--snapshot', $shots, '--only', 'заставка', '--data', $d, '--watchdog-check') 3
$wifi = Join-Path $root 'wifi-check'
Run 'webvideo' @('--snapshot', $shots, '--only', 'головне', '--data', $d, '--webvideo-check', $wifi) 5
if (Test-Path $wifi) { Copy-Item $wifi (Join-Path $back 'wifi-check') -Recurse -Force; "   шматків скопійовано: $(@(Get-ChildItem $wifi -Filter *.ts).Count)" }
$d = Fresh 'data-show' (Join-Path $src 'vm-new\bench-data')
Run 'show' @('--snapshot', $shots, '--only', 'головне', '--data', $d, '--show-check') 8

# 6) Заміри.
$d = Fresh 'data-bench' (Join-Path $src 'vm-new\bench-data')
$benchOut = Join-Path $root 'bench-out'
Run 'bench' @('--snapshot', $benchOut, '--data', $d, '--bench', 'all') 20
foreach ($f in Get-ChildItem $benchOut -Filter 'bench-*.txt' -ErrorAction SilentlyContinue) { Copy-Item $f.FullName (Join-Path $back ('windows-' + $f.Name)) -Force }
$d = Fresh 'data-live' (Join-Path $src 'vm-new\bench-data')
$report = Join-Path $root 'live-bench.txt'
$clock = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--quiet-start', '--live-bench', $report, '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$null = $p.Handle
if (-not $p.WaitForExit(600000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; '[live-bench] ЗАВИСЛО: 10 хв — зупинено' }
"[live-bench] код $($p.ExitCode), $([int]$clock.Elapsed.TotalSeconds) с"
if (Test-Path $report) { Copy-Item $report (Join-Path $back 'windows-live-bench.txt') -Force; Get-Content $report -Encoding UTF8 | ForEach-Object { "   $_" } } else { '   звіту немає' }
Start-Sleep 2

# 7) YouTube без yt-dlp + «Відео по Wi-Fi».
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function Media { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18103/api/media'; $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json; return $j } catch { return $null } }
function Fetch($url) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 $url; return , $r.RawContentStream.ToArray() } catch { return $null } }
"[youtube] yt-dlp у PATH: $([bool](Get-Command yt-dlp -ErrorAction SilentlyContinue)); WebView2 до перевірки: $webviewBefore"
$d = Fresh 'data-yt' (Join-Path $src 'vm-new\test-data-yt')
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--quiet-start', '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"   пульт відповідає: $up"
Start-Sleep 4
$list = Fetch 'http://127.0.0.1:18200/wifi/stream.m3u8'
"   Wi-Fi до ролика: $(if ($list) { 'список є, ' + ([Text.Encoding]::UTF8.GetString($list) -split "`n" | Where-Object { $_ -like '*.ts' }).Count + ' шматків' } else { 'списку немає' })"
"   media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=jNQXAC9IVRw"}')
$wifiYt = Join-Path $back 'wifi-yt'
New-Item -ItemType Directory -Force -Path $wifiYt | Out-Null
$seen = @{}; $order = New-Object System.Collections.ArrayList
$screenAsked = $false
for ($t = 0; $t -lt 40; $t++) {
    Start-Sleep 1
    $m = Media
    if ($m -and ($t % 3 -eq 0)) { "   {0,2} с: «{1}» грає={2} {3:N1}/{4:N1} відео={5} на екран={6} доріжок={7}" -f $t, $m.title, $m.playing, $m.position, $m.duration, $m.video, $m.toScreen, $m.audioTracks }
    if ($m -and -not $m.toScreen -and -not $screenAsked) { $screenAsked = $true; "   media-screen: " + (Post 'media-screen' '{}') }
    $list = Fetch 'http://127.0.0.1:18200/wifi/stream.m3u8'
    if ($list) {
        foreach ($name in ([Text.Encoding]::UTF8.GetString($list) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '*.ts' })) {
            if (-not $seen.ContainsKey($name)) { $bytes = Fetch "http://127.0.0.1:18200/wifi/$name"; if ($bytes) { [IO.File]::WriteAllBytes((Join-Path $wifiYt $name), $bytes); $seen[$name] = $bytes.Length; [void]$order.Add($name) } }
        }
    }
    if ($t -eq 12) {
        "   window-snapshot: " + (Post 'window-snapshot' '{}')
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
        $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
        $bmp.Save((Join-Path $back 'yt-екран.png'), [System.Drawing.Imaging.ImageFormat]::Png)
    }
}
$order -join "`n" | Set-Content (Join-Path $wifiYt 'order.txt') -Encoding UTF8
"   шматків Wi-Fi під час ролика: $($order.Count), байтів $(($seen.Values | Measure-Object -Sum).Sum)"
$shotsYt = Join-Path $d 'ScreenShots'
if (Test-Path $shotsYt) { Get-ChildItem $shotsYt | ForEach-Object { Copy-Item $_.FullName (Join-Path $back ('yt-' + $_.Name)) -Force } }
"   програма жива: $(-not $app.HasExited)"
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 3
# Процеси браузера тестової копії (профіль Slovo\WebView2) — слідом за програмою.
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1
foreach ($j in Get-ChildItem $root -Recurse -Filter 'journal.txt' -ErrorAction SilentlyContinue) {
    $hits = Get-Content $j.FullName -Encoding UTF8 | Select-String -Pattern 'виняток|Exception|помилк|головний потік|YouTube|Wi-Fi|звук'
    if ($hits) { "журнал $($j.Directory.Name):"; $hits | Select-Object -Last 12 | ForEach-Object { "   $($_.Line)" } }
}

# Прибирання.
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
if (-not $webviewBefore -and (Test-Path $webview)) { for ($i = 0; $i -lt 10 -and (Test-Path $webview); $i++) { Remove-Item $webview -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $webview) { Start-Sleep 1 } } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); WebView2 прибрано/був: $(-not (Test-Path $webview))/$webviewBefore; %APPDATA%\Slovo до $before, після $after; усього $([int]((Get-Date) - (Get-Item $back).CreationTime).TotalMinutes) хв"
