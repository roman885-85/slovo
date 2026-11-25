# =============================================================================
#  wifi-audio.ps1 — звук вбудованого YouTube у «Відео по Wi-Fi» (наскрізно) і ядро ще раз
# =============================================================================
#  1) --core-check на копії core-data (звірка з Mac — tools/core-compare-vm.py).
#  2) Справжня програма на test-data-yt (Wi-Fi 360p, yt-dlp немає → вбудований програвач):
#     ролик із мовою, щільно забираються список і шматки (без важких запитів WMI, що
#     гальмують ВМ), наприкінці — audio-sessions. Шматки — на Mac для ffmpeg (рівень звуку).
#  Тека стирається; %APPDATA%\Slovo не чіпається (час зміни звіряється).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\wifi-audio'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-wifi'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root, $back, (Join-Path $back 'wifi') | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
"sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower().Substring(0,16))"
$core = Join-Path $root 'core-data'
Copy-Item -LiteralPath (Join-Path $src 'core-data') $core -Recurse -Force
$p = Start-Process -FilePath $exe -ArgumentList '--core-check', $core -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $back 'core-check.txt') -RedirectStandardError (Join-Path $root 'core-err.txt')
$null = $p.Handle
if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force; 'ядро: ЗАВИСЛО' }
"ядро: код $($p.ExitCode)"
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-yt') $d -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function Fetch($url) { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 $url; return , $r.RawContentStream.ToArray() } catch { return $null } }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--quiet-start', '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up"
Start-Sleep 5
"media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=jNQXAC9IVRw"}')
$wifi = Join-Path $back 'wifi'
$order = New-Object System.Collections.ArrayList; $seen = @{}; $fails = 0
$clock = [Diagnostics.Stopwatch]::StartNew()
while ($clock.Elapsed.TotalSeconds -lt 40) {
    Start-Sleep -Milliseconds 400
    $list = Fetch 'http://127.0.0.1:18200/wifi/stream.m3u8'
    if (-not $list) { $fails++; continue }
    foreach ($name in ([Text.Encoding]::UTF8.GetString($list) -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -like '*.ts' })) {
        if (-not $seen.ContainsKey($name)) { $bytes = Fetch "http://127.0.0.1:18200/wifi/$name"; if ($bytes) { [IO.File]::WriteAllBytes((Join-Path $wifi $name), $bytes); $seen[$name] = 1; [void]$order.Add($name) } }
    }
}
$order -join "`n" | Set-Content (Join-Path $wifi 'order.txt') -Encoding ASCII
"шматків Wi-Fi: $($order.Count), невдалих запитів списку: $fails"
"audio-sessions: " + (Post 'audio-sessions' '{}')
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String 'звук програми|головний потік|Wi-Fi' | Select-Object -Last 8 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
