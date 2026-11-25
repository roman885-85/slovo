# =============================================================================
#  audio-probe.ps1 — чи бере захоплення звуку процесу дочірній рушій WebView2
# =============================================================================
#  Ролик YouTube вбудованим програвачем; через 25 с — що прийшло в «Відео по
#  Wi-Fi» (захоплення, запущене ще до появи процесу звуку WebView2), і свіже
#  захоплення (audio-probe): свого дерева й дерева рушія. Тека стирається;
#  %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-probe'
$exe = Join-Path $root 'Slovo.exe'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-yt') $d -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--quiet-start', '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 60 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up"
Start-Sleep 3
"media-url: " + (Post 'media-url' '{"text":"https://www.youtube.com/watch?v=aqz-KE-bpKQ"}')
Start-Sleep 25
"до проби: " + (Post 'audio-sessions' '{}')
"audio-probe: " + (Post 'audio-probe' '{}')
Start-Sleep 5
"після проби: " + (Post 'audio-sessions' '{}')
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like '*Slovo\WebView2*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
