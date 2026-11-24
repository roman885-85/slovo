# =============================================================================
#  5-selftest.ps1 — перевірка того самого файла на тестових даних
# =============================================================================
#  sha256 файла у Windows (звірити з Mac) і --snapshot усіх сцен на теці
#  %LOCALAPPDATA%\slovo-test\data (--data): програма запускається, малює кожне
#  вікно у файл і виходить. Справжня %APPDATA%\Slovo не чіпається —
#  час її зміни звіряється до й після.
#
#  24.11.2026: раніше тут був ключ --selftest, якого переписана (1:1 за Mac)
#  програма вже не знає, — і вона запускалась як звичайно, на справжніх даних.
#  Тому тепер: лише --snapshot і лише з --data; зависання — 10 хв, далі зупинка.
# =============================================================================
$ErrorActionPreference = 'Continue'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test'; $exe = Join-Path $root 'Slovo.exe'
$data = Join-Path $root 'data'; $shots = Join-Path $root 'shots'
New-Item -ItemType Directory -Force -Path $root, $data, $back | Out-Null
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Copy-Item '\\Mac\Home\Documents\Слово\Слово.exe' $exe -Force
"sha256 у Windows: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower())"
$out = Join-Path $root 'selftest.txt'
$p = Start-Process -FilePath $exe -ArgumentList '--snapshot', $shots, '--data', $data, '--quiet-start' -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError (Join-Path $root 'selftest-err.txt')
$null = $p.Handle   # без цього PowerShell 5.1 не віддає ExitCode процесу, запущеного без -Wait
if (-not $p.WaitForExit(600000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue; "ЗАВИСЛО: за 10 хв не скінчилось — зупинено" }
$png = @(Get-ChildItem $shots -Filter *.png -Recurse -ErrorAction SilentlyContinue)
"знімки: код $($p.ExitCode), файлів PNG $($png.Count)"
$lines = Get-Content $out -Encoding UTF8
# Вивід — у кодовій сторінці консолі Windows: «✓» там не видно, тож рахуємо самі файли PNG.
"підозрілі рядки (якщо є):"
$lines | Where-Object { $_ -match '✗|не вийшло|Exception|помилк|ПОМИЛКА' } | Select-Object -First 15
Copy-Item $out (Join-Path $back 'selftest.txt') -Force
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after; Windows: $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
