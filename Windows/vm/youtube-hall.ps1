# =============================================================================
#  youtube-hall.ps1 — вбудований YouTube у вікні залу самим програвачем (hostWeb Mac)
# =============================================================================
#  Справжня програма на test-data-yt (yt-dlp немає → вбудований програвач). Ролик —
#  на екран: /api/media має сказати embedInHall=true, знімок екрана — живий програвач
#  у залі. Потім вірш у зал (show): програвач іде з залу (знімок — слайд); hide —
#  вертається. Наприкінці — чи звук іде в канал Wi-Fi (audio-sessions). Тека стирається;
#  %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\yt-hall'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-hall'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
foreach ($old in 'slovo-test-hall', 'slovo-test-wifi', 'slovo-test-yt', 'slovo-test-probe', 'slovo-test-all') { $p0 = Join-Path $env:LOCALAPPDATA $old; if (Test-Path $p0) { Remove-Item $p0 -Recurse -Force -ErrorAction SilentlyContinue; "залишок $old прибрано: $(-not (Test-Path $p0))" } }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-hall') $d -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function Media { try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18103/api/media'; return ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json) } catch { return $null } }
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition 'using System.Runtime.InteropServices; public static class Dpi { [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); }'
[Dpi]::SetProcessDPIAware() | Out-Null
function Screen($name) {
    $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($b.X, $b.Y, 0, 0, $bmp.Size)
    $bmp.Save((Join-Path $back "$name.png"), [System.Drawing.Imaging.ImageFormat]::Png)
}
function Line($label) { $m = Media; "{0}: грає={1} {2:N1}/{3:N1} на екран={4} програвач у залі={5} ({6})" -f $label, $m.playing, $m.position, $m.duration, $m.toScreen, $m.embedInHall, $m.embedNote }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up"
Start-Sleep 4
"media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}')
Start-Sleep 10
Line 'ролик'
Screen '1-ролик-у-залі'
"mode bible: " + (Post 'mode' '{"text":"bible"}')
Start-Sleep 1
"show: " + (Post 'show' '{}')
Start-Sleep 4
Line 'вірш у залі'
Screen '2-вірш-у-залі'
"hide: " + (Post 'hide' '{}')
Start-Sleep 4
Line 'вірш сховано'
Screen '3-знову-ролик'
"audio-sessions: " + (Post 'audio-sessions' '{}')
"media-play: " + (Post 'media-play' '{}')
Start-Sleep 4
Line 'знову пуск'
Screen '4-пуск-знову-в-залі'
"help: " + (Post 'window-open' '{"text":"help"}')
Start-Sleep 6
$name = 'yt-hall\довідка-windows'; $proc = 'slovo-test-hall'; $title = 'Довідка «Слова»'
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\shot-window.ps1'
"close: " + (Post 'window-open' '{"text":"close"}')
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String 'проектор|WebView2|плеєр' | Select-Object -Last 16 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
