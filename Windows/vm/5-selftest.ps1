# =============================================================================
#  5-selftest.ps1 — самоперевірка того самого файла
# =============================================================================
#  sha256 файла у Windows (звірити з Mac) і --selftest на портах 18103/18105.
# =============================================================================
$ErrorActionPreference = 'Continue'
$back = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test'; $exe = Join-Path $root 'Slovo.exe'
New-Item -ItemType Directory -Force -Path $root | Out-Null
Copy-Item '\\Mac\Home\Documents\Слово\Слово.exe' $exe -Force
"sha256 у Windows: $((Get-FileHash $exe -Algorithm SHA256).Hash.ToLower())"
$p = Start-Process -FilePath $exe -ArgumentList '--selftest','--port','18103' -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root 'selftest.txt') -RedirectStandardError (Join-Path $root 'selftest-err.txt')
"selftest exit: $($p.ExitCode)"
Get-Content (Join-Path $root 'selftest.txt') -Encoding UTF8 | Select-String -Pattern 'ПОМИЛКА|Разом' | ForEach-Object { $_.Line }
Copy-Item (Join-Path $root 'selftest.txt') (Join-Path $back 'selftest.txt') -Force
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
"тестову теку прибрано: $(-not (Test-Path $root)); Windows: $((Get-CimInstance Win32_OperatingSystem).Caption) $([Environment]::OSVersion.Version)"
