# =============================================================================
#  1-setup.ps1 — поставити й запустити
# =============================================================================
#  Копіює Слово.exe із спільної теки Mac у %LOCALAPPDATA%\slovo-test, ставить через
#  --import два переклади, два пісенники, шаблони, фони й шрифти з архівів
#  ресурсів (~/Documents/Слово/GitHub/resources-out — тека Library Mac у ВМ не
#  прокинута) і запускає програму звичайним чином. Справжня %APPDATA%\Slovo не
#  чіпається: усе через --data.
# =============================================================================
$ErrorActionPreference = 'Continue'
$root = Join-Path $env:LOCALAPPDATA 'slovo-test'; $data = Join-Path $root 'data'; $exe = Join-Path $root 'Slovo.exe'
Get-Process Slovo -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Force -Path $root, $data | Out-Null
Copy-Item '\\Mac\Home\Documents\Слово\Слово.exe' $exe -Force
foreach ($zip in 'module-UA-Gyzha-39b3d9.zip','module-UA-Ogienko-617588.zip','songbook-glory-5fd90e.zip','songbook-ivangeliya2-2ddf92.zip','Templates.zip','BackGrounds.zip','Fonts.zip') {
  $z = "\\Mac\Home\Documents\Слово\GitHub\resources-out\$zip"
  $sw = [Diagnostics.Stopwatch]::StartNew()
  $p = Start-Process -FilePath $exe -ArgumentList '--data',"`"$data`"",'--import',"`"$z`"" -Wait -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $root 'imp.txt') -RedirectStandardError (Join-Path $root 'imp-err.txt')
  "$zip — exit $($p.ExitCode), $([int]$sw.Elapsed.TotalSeconds) с: " + ((Get-Content (Join-Path $root 'imp.txt') -Encoding UTF8) -join ' ')
}
Start-Process -FilePath $exe -ArgumentList '--data',"`"$data`""
"started: $((Get-Process Slovo -ErrorAction SilentlyContinue | Measure-Object).Count) process"
