# =============================================================================
#  pdf-frame.ps1 — сторінка PDF на весь кадр і з поворотом (Windows, PDFium)
# =============================================================================
#  27.11: на Mac сторінка PDF, нижча за 1080 пт, лягала в зал посередині в білій рамці.
#  Тут — те саме у Windows: дві сторінки (960×540 пт; 400×300 пт з /Rotate 90, ліва половина
#  червона, права синя) надсилаються пульту-подібним /api/upload, картинки сторінок
#  (/api/page?index=…&w=…) кладуться в Службові\vm\pdf-*.png — розбір на Mac.
#  Тестова тека %LOCALAPPDATA%\slovo-test-pdf; %APPDATA%\Slovo не чіпається.
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$out = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm'
$dst = Join-Path $env:LOCALAPPDATA 'slovo-test-pdf'
Get-Process | Where-Object { $_.Path -and $_.Path -like "$dst*" } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst | Out-Null
Copy-Item -LiteralPath (Join-Path $src 'Слово.exe') -Destination $dst
Copy-Item -LiteralPath (Join-Path $src 'bench-data') -Destination (Join-Path $dst 'data') -Recurse
$appdata = Join-Path $env:APPDATA 'Slovo'
$before = if (Test-Path -LiteralPath $appdata) { (Get-Item -LiteralPath $appdata).LastWriteTime.ToString('o') } else { 'none' }
$exe = Join-Path $dst 'Слово.exe'
"exe sha256: " + (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.Substring(0, 16).ToLower()
Start-Process -FilePath $exe -ArgumentList @('--data', "`"$(Join-Path $dst 'data')`"", '--remote-port', '18103', '--web-port', '18105', '--web-slides-port', '18680', '--web-socket-port', '18681')
$base = 'http://127.0.0.1:18103'
$ok = $false
for ($i = 0; $i -lt 120; $i++) { try { $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "$base/api/state"; $ok = $true; break } catch { Start-Sleep -Seconds 1 } }
"started: $ok"
if ($ok) {
  foreach ($f in 'rivna.pdf', 'povernuta.pdf') {
    $bytes = [IO.File]::ReadAllBytes((Join-Path $src "decks\$f"))
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 60 "$base/api/upload?name=$f"
    "upload $f → " + [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  }
  Start-Sleep -Seconds 2
  $s = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest -UseBasicParsing "$base/api/state").RawContentStream.ToArray()) | ConvertFrom-Json
  $decks = @($s.presentation.decks)
  $start = 0
  foreach ($d in $decks) {
    if ($d.name -in 'rivna.pdf', 'povernuta.pdf') {
      $file = Join-Path $out ("pdf-" + [IO.Path]::GetFileNameWithoutExtension($d.name) + ".png")
      Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 "$base/api/page?index=$start&w=960" -OutFile $file
      "сторінка $($d.name) (наскрізна $start) → $file"
    }
    $start += $d.count
  }
}
Get-Process | Where-Object { $_.Path -and $_.Path -like "$dst*" } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
Start-Sleep -Seconds 1
Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
$after = if (Test-Path -LiteralPath $appdata) { (Get-Item -LiteralPath $appdata).LastWriteTime.ToString('o') } else { 'none' }
"APPDATA Slovo: " + $(if ($before -eq $after) { 'не чіпано' } else { 'ЗМІНИЛОСЯ!' })
