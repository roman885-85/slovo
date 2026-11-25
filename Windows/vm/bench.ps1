# =============================================================================
#  bench.ps1 — заміри відгуку вікна в справжній Windows (Bench.cs, --bench all)
# =============================================================================
#  Та сама збірка й тестові дані, що й на Mac (Службові/vm-new: Слово.exe і
#  bench-data — копія даних власника тільки для читання). Звіти bench-*.txt —
#  у Службові/vm/ з приставкою windows-. Тека стирається; %APPDATA%\Slovo не
#  чіпається (час зміни звіряється).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-bench'
$exe = Join-Path $root 'Slovo.exe'; $data = Join-Path $root 'data'; $out = Join-Path $root 'out'
New-Item -ItemType Directory -Force -Path $root, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item -LiteralPath (Join-Path $src 'Слово.exe') $exe -Force
Copy-Item -LiteralPath (Join-Path $src 'bench-data') $data -Recurse -Force
$p = Start-Process -FilePath $exe -ArgumentList '--snapshot', $out, '--data', $data, '--bench', 'all' -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root 'bench.txt') -RedirectStandardError (Join-Path $root 'bench-err.txt')
$null = $p.Handle
if (-not $p.WaitForExit(900000)) { Stop-Process -Id $p.Id -Force; 'ЗАВИСЛО: 15 хв' }
"код $($p.ExitCode)"
foreach ($f in Get-ChildItem $out -Filter 'bench-*.txt') { Copy-Item $f.FullName (Join-Path $back ('windows-' + $f.Name)) -Force; "звіт: $($f.Name)" }
Get-Content (Join-Path $root 'bench-err.txt') -Encoding UTF8 -ErrorAction SilentlyContinue | Select-Object -First 5
for ($i = 0; $i -lt 10 -and (Test-Path $root); $i++) { Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue; if (Test-Path $root) { Start-Sleep 1 } }
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after; $((Get-CimInstance Win32_Processor | Select-Object -First 1).Name)"
