# =============================================================================
#  ndi-check.ps1 — трансляція NDI у справжній Windows 11 (NDI 6 Runtime стоїть у ВМ)
# =============================================================================
#  1) --ndi-check: своє джерело «Слово-тест» і «Слово-тест Wi-Fi» — прийняти кадр тут же;
#     --ndi-audio-check: тон 440 Гц у джерело — приймач рахує порції й рівень.
#  2) Справжня програма (test-data-ndi: NDI увімкнено, yt-dlp немає → вбудований YouTube):
#     ролик грає, службова ndi-probe приймає джерело «Слово» — кадр і звук ролика (захоплення
#     звуку процесу → NDI). Тека стирається; %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\ndi'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-ndi'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
$ndi = [Environment]::GetEnvironmentVariable('NDI_RUNTIME_DIR_V6', 'Machine')
"NDI_RUNTIME_DIR_V6: $ndi; бібліотека є: $(if ($ndi) { Test-Path (Join-Path $ndi 'Processing.NDI.Lib.x64.dll') } else { $false })"
if ($ndi) { $env:NDI_RUNTIME_DIR_V6 = $ndi }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
"sha256: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower().Substring(0,16))"
$d = Join-Path $root 'data-snap'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\bench-data') $d -Recurse -Force
foreach ($check in '--ndi-check', '--ndi-audio-check') {
    $name = $check.Trim('-')
    $p = Start-Process -FilePath $exe -ArgumentList '--snapshot', (Join-Path $root "shots-$name"), '--only', 'головне', '--data', $d, $check -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $back "$name.txt") -RedirectStandardError (Join-Path $root "$name-err.txt")
    $null = $p.Handle
    if (-not $p.WaitForExit(300000)) { Stop-Process -Id $p.Id -Force; "$name ЗАВИСЛО" }
    "[$name] код $($p.ExitCode)"
    Get-Content (Join-Path $back "$name.txt") -Encoding UTF8 | Where-Object { $_ -match 'NDI' } | ForEach-Object { "   $_" }
}
$png = Join-Path $root 'shots-ndi-check\ndi-прийнято.png'
if (Test-Path $png) { Copy-Item $png (Join-Path $back 'ndi-прийнято.png') -Force; '   кадр прийнятий — ndi-прийнято.png' }
# Справжня програма.
$d2 = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-ndi') $d2 -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d2, '--quiet-start', '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 90 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up"
Start-Sleep 4
"media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}')
Start-Sleep 20
"ndi-probe: " + (Post 'ndi-probe' '{}')
Start-Sleep 16
"audio-sessions: " + (Post 'audio-sessions' '{}')
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Content (Join-Path $d2 'journal.txt') -Encoding UTF8 | Select-String 'NDI|звук програми' | Select-Object -Last 8 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
