# =============================================================================
#  js-runtime.ps1 — рушій JavaScript для yt-dlp у Windows-«Слові»
# =============================================================================
#  Два знімки --youtube на тестових даних: без node (yt-dlp має сказати
#  «JS runtimes: none» і попередити) і з переносним node у PATH (має взяти
#  node). Перший заодно завантажує свій yt-dlp.exe (--ytdlp-update).
#  Тека — %LOCALAPPDATA%\slovo-test-js, після перевірки стирається;
#  %APPDATA%\Slovo не чіпається (звіряється час зміни).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test-js'
$exe = Join-Path $root 'Slovo.exe'; $data = Join-Path $root 'data'
New-Item -ItemType Directory -Force -Path $root, $data | Out-Null
Copy-Item (Join-Path $src 'Слово.exe') $exe -Force
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
Expand-Archive (Join-Path $src 'node-win-x64.zip') (Join-Path $root 'node') -Force
$nodeDir = (Get-ChildItem (Join-Path $root 'node') -Directory | Select-Object -First 1).FullName
$link = 'https://www.youtube.com/watch?v=jNQXAC9IVRw'
function Snap($name, $extra) {
    $out = Join-Path $root "$name.txt"
    $argv = @('--snapshot', (Join-Path $root "shots-$name"), '--only', 'заставка', '--data', $data) + $extra + @('--youtube', $link)
    $p = Start-Process -FilePath $exe -ArgumentList $argv -Wait -PassThru -NoNewWindow -RedirectStandardOutput $out -RedirectStandardError (Join-Path $root "$name-err.txt")
    "== $name (код $($p.ExitCode))"
    Get-Content $out -Encoding UTF8 | Select-String -Pattern 'yt-dlp|ролик|рушій|не вийшло' | ForEach-Object { $_.Line }
}
"node у PATH до перевірки: $([bool](Get-Command node -ErrorAction SilentlyContinue))"
Snap 'без-node' @('--ytdlp-update')
$env:PATH = "$nodeDir;$env:PATH"
"node для другого знімка: $nodeDir\node.exe ($(& "$nodeDir\node.exe" --version))"
Snap 'з-node' @()
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1
Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
$after = if (Test-Path $appdata) { (Get-Item $appdata).LastWriteTime.ToString('o') } else { 'немає' }
"тестову теку прибрано: $(-not (Test-Path $root)); %APPDATA%\Slovo до $before, після $after"
