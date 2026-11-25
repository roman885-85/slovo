# =============================================================================
#  same-slide.ps1 — «той самий слайд ще раз» у справжньому вікні залу (відбиток кадру, як на Mac)
# =============================================================================
#  Справжня програма (звичайний запуск — вікно залу є): вірш у зал (show), той самий ще раз,
#  сховати (hide), знову той самий. Після кожного кроку — лічильники кадрів (renders у
#  audio-sessions) і знімок вікна «Вікно слайда»: повтор не малює нового кадру, але зал
#  лишається з віршем; після «сховати» — порожньо; потім вірш вертається. Тека стирається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові'
$back = Join-Path $src 'vm\same-slide'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-same'
$exe = Join-Path $root 'Slovo.exe'
if (Test-Path $back) { Remove-Item $back -Recurse -Force -ErrorAction SilentlyContinue }
if (Test-Path $root) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'vm-new\Слово.exe') $exe -Force
$d = Join-Path $root 'data'
Copy-Item -LiteralPath (Join-Path $src 'vm-new\test-data-hall') $d -Recurse -Force
. '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\remote-helpers.ps1'
function Renders { $j = (Post 'audio-sessions' '{}') | ConvertFrom-Json; return "передпоказ $($j.renders.preview), зал $($j.renders.hall)" }
$app = Start-Process -FilePath $exe -ArgumentList '--data', $d, '--remote-port', '18103', '--web-slides-port', '18200', '--remote-api-tcp', '18210', '--remote-api-udp', '18211' -PassThru
$up = $false
for ($i = 0; $i -lt 90 -and -not $up; $i++) { Start-Sleep 1; try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/state' | Out-Null; $up = $true } catch {} }
"пульт: $up"
Start-Sleep 6
"mode: " + (Post 'mode' '{"text":"bible"}')
Start-Sleep 2
$proc = 'slovo-test-same'; $title = 'Вікно слайда'
$steps = @(@('1-вірш', 'show'), @('2-той-самий-ще-раз', 'show'), @('3-сховано', 'hide'), @('4-знову', 'show'), @('5-ще-раз', 'show'))
foreach ($step in $steps) {
    $before2 = Renders
    $r = Post $step[1] '{}'
    Start-Sleep 3
    "$($step[0]) ($($step[1]) $r): було $before2 → стало $(Renders)"
    $name = "same-slide\$($step[0])"
    . '\\Mac\Home\Documents\Слово\Исходники\Windows\vm\shot-window.ps1'
}
Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
$app.WaitForExit(10000) | Out-Null
Start-Sleep 2
for ($i = 0; $i -lt 15 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
