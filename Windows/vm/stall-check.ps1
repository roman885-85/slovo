# =============================================================================
#  stall-check.ps1 — чому головний потік стоїть десятки секунд (100 % процесора) у ВМ
# =============================================================================
#  Справжня програма у звичайному режимі (test-data-hall) без жодного введення 70 с: щодві
#  секунди — процесорний час «Слова» (усього й головного потоку) і захисника Windows
#  (MsMpEng); потім меню через пульт (menu:File, menu:Actions) — і ще 20 с. Записи сторожа
#  з журналу. Тека стирається; %APPDATA%\Slovo не чіпається; брандмауер не змінюється.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-ui'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-hall') $d -Recurse -Force
function PostApp($cmd, $body) { $bytes = [Text.Encoding]::UTF8.GetBytes($body); try { $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 60 ("http://127.0.0.1:8103/api/" + $cmd); return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) } catch { return "ERR " + $_.Exception.Message } }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d -PassThru
$mainThread = $null
$prev = @{}; $prevDef = 0; $prevApp = 0
function Sample($label) {
    $p = Get-Process -Id $app.Id -ErrorAction SilentlyContinue; if (-not $p) { return "$label — процесу немає" }
    $threads = $p.Threads | ForEach-Object { [pscustomobject]@{ Id = $_.Id; Cpu = $_.TotalProcessorTime.TotalMilliseconds } }
    if (-not $script:mainThread) { $script:mainThread = ($threads | Sort-Object Id | Select-Object -First 1).Id }
    $top = $threads | ForEach-Object { $delta = $_.Cpu - ($script:prev[$_.Id] | ForEach-Object { $_ }); [pscustomobject]@{ Id = $_.Id; D = [int]$delta } } | Sort-Object D -Descending | Select-Object -First 3
    foreach ($t in $threads) { $script:prev[$t.Id] = $t.Cpu }
    $appCpu = $p.TotalProcessorTime.TotalMilliseconds; $da = [int]($appCpu - $script:prevApp); $script:prevApp = $appCpu
    $def = (Get-Process MsMpEng -ErrorAction SilentlyContinue | Measure-Object -Property CPU -Sum).Sum * 1000; $dd = [int]($def - $script:prevDef); $script:prevDef = $def
    $mt = ($threads | Where-Object Id -eq $script:mainThread).Cpu
    return "$label  Слово +$da мс (головний #$($script:mainThread) усього $([int]$mt)); потоки: " + (($top | ForEach-Object { "#$($_.Id)+$($_.D)" }) -join ' ') + "; захисник +$dd мс"
}
for ($i = 0; $i -lt 35; $i++) { Start-Sleep 2; Sample ("{0,3} с" -f (2 * ($i + 1))) }
"menu:File: " + (PostApp 'window-open' '{"text":"menu:File"}')
Start-Sleep 3; Sample "після File"
"menu:Actions: " + (PostApp 'window-open' '{"text":"menu:Actions"}')
for ($i = 0; $i -lt 8; $i++) { Start-Sleep 2; Sample ("+{0} с" -f (2 * ($i + 1))) }
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue; $app.WaitForExit(10000) | Out-Null; Start-Sleep 2
Get-Content (Join-Path $d 'journal.txt') -Encoding UTF8 | Select-String "головний потік|LibVLC|меню|ім'я" | Select-Object -Last 14 | ForEach-Object { "журнал: $($_.Line)" }
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
