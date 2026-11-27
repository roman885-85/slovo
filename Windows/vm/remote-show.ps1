# =============================================================================
#  remote-show.ps1 — пульт 3.0 / планшет 2.0 проти «Слова» 1.4.4 у справжній Windows
# =============================================================================
#  Що перевіряє (тими самими запитами, що й телефон):
#   1. «Показ — лише кнопкою»: `page` без `live` (старий пульт) — одразу в зал; `page … live:false`
#      — сторінку вибрано, зал той самий; `show` — у залі вибране; `picture … live:false` — так само.
#   2. Файл презентації з пульта: прибрати той, що в залі (зал бере наступний), чужий номер — 404,
#      `decks-clear` — файлів 0.
#   3. Фото: `picture-remove`, `pictures-clear`; стан несе `pictures {count, sign}`.
#  Тестова тека %LOCALAPPDATA%\slovo-test-remote (exe і bench-data з Службові/vm-new); після — процес
#  убито, теку стерто; %APPDATA%\Slovo не чіпається (звіряється час зміни).
# =============================================================================
$ErrorActionPreference = 'Continue'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$dst = Join-Path $env:LOCALAPPDATA 'slovo-test-remote'
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

function J($path) { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 30 ($base + $path); [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function P($cmd, $body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 30 ("$base/api/" + $cmd)
    return "200 " + [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  } catch {
    $code = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
    return "$code " + $_.Exception.Message
  }
}
function Up($file) {
  $bytes = [IO.File]::ReadAllBytes($file)
  $name = [Uri]::EscapeDataString((Split-Path $file -Leaf))
  $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/octet-stream' -Body $bytes -TimeoutSec 120 "$base/api/upload?name=$name"
  [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
}
$script:fails = 0
function Check($name, $cond, $detail) { if ($cond) { "OK   $name — $detail" } else { "FAIL $name — $detail"; $script:fails++ } }
function Hall { $s = J '/api/state'; "$($s.hall.kind)|$($s.hall.title)" }

if ($ok) {
  foreach ($f in 'Оголошення.pdf', 'Проповідь.pdf', 'Хор.jpg', 'Вечеря.jpg') { "upload $f → " + (Up (Join-Path $src "decks\$f")) }
  Start-Sleep -Seconds 2
  $s = J '/api/state'
  $decks = @($s.presentation.decks | ForEach-Object { $_.name })
  "файли: " + ($decks -join ', ')
  "фото в стані: " + ($s.pictures | ConvertTo-Json -Compress)
  Check 'стан несе pictures' ($null -ne $s.pictures -and $s.pictures.count -ge 2) ("count=" + $s.pictures.count)

  # 1. Лише вибрати / «Показати».
  $ann = [array]::IndexOf($decks, 'Оголошення.pdf')
  $null = P 'deck' (ConvertTo-Json @{ index = $ann })
  Start-Sleep -Milliseconds 500
  $first = (J '/api/state').presentation.pages[0].index
  $null = P 'mode' '{"text":"presentation"}'
  "page (старий пульт, без live): " + (P 'page' (ConvertTo-Json @{ index = $first }))
  Start-Sleep -Seconds 1
  $h1 = Hall
  "page live:false: " + (P 'page' (ConvertTo-Json @{ index = $first + 2; live = $false }))
  Start-Sleep -Seconds 1
  $s = J '/api/state'; $h2 = "$($s.hall.kind)|$($s.hall.title)"
  Check 'дотик (live:false) не міняє зал' ($h2 -eq $h1 -and $s.presentation.index -eq $first + 2) "зал «$h1» → «$h2», вибрано $($s.presentation.index)"
  "show: " + (P 'show' '{"tab":"show"}')
  Start-Sleep -Seconds 1
  $h3 = Hall
  Check '«Показати» виводить вибране' ($h3 -ne $h1 -and $h3 -like '*3*') "зал «$h3»"
  $picsBefore = (J '/api/state').pictures
  "picture 0 live:false: " + (P 'picture' (ConvertTo-Json @{ index = 0; live = $false }))
  Start-Sleep -Seconds 1
  $s = J '/api/state'; $h4 = "$($s.hall.kind)|$($s.hall.title)"
  Check 'фото (live:false) не міняє зал' ($h4 -eq $h3 -and $s.mode -eq 'pictures') "режим $($s.mode), зал «$h4»"

  # 2. Файли презентацій.
  $null = P 'mode' '{"text":"presentation"}'
  $decks = @((J '/api/state').presentation.decks | ForEach-Object { $_.name })
  $ann = [array]::IndexOf($decks, 'Оголошення.pdf')
  $null = P 'deck' (ConvertTo-Json @{ index = $ann })
  Start-Sleep -Milliseconds 500
  $first = (J '/api/state').presentation.pages[0].index
  $null = P 'page' (ConvertTo-Json @{ index = $first })
  Start-Sleep -Seconds 1
  $h5 = Hall
  "deck-remove (той, що в залі): " + (P 'deck-remove' (ConvertTo-Json @{ index = $ann }))
  Start-Sleep -Seconds 1
  $s = J '/api/state'; $h6 = "$($s.hall.kind)|$($s.hall.title)"
  $left = @($s.presentation.decks | ForEach-Object { $_.name })
  Check 'прибрати файл у залі' (($left -notcontains 'Оголошення.pdf') -and $h6 -ne $h5 -and $s.hall.kind -eq 'still') "файли: $($left -join ', '); зал «$h5» → «$h6»"
  $miss = P 'deck-remove' '{"index":999}'
  Check 'чужий номер файла — 404' ($miss -like '404*') $miss
  "decks-clear: " + (P 'decks-clear' '{}')
  Start-Sleep -Seconds 1
  $s = J '/api/state'
  Check 'очистити презентації' (@($s.presentation.decks).Count -eq 0) ("файлів " + @($s.presentation.decks).Count + ", зал «$($s.hall.kind)|$($s.hall.title)»")

  # 3. Фото.
  $pics = J '/api/pictures'
  $names = @($pics.pages | ForEach-Object { $_.title })
  "фото: " + ($names -join ', ')
  $sign1 = "$($s.pictures.count):$($s.pictures.sign)"
  "picture-remove 0: " + (P 'picture-remove' '{"index":0}')
  Start-Sleep -Seconds 1
  $s = J '/api/state'; $sign2 = "$($s.pictures.count):$($s.pictures.sign)"
  Check 'прибрати фото — стан помітив' ($sign2 -ne $sign1 -and $s.pictures.count -eq $names.Count - 1) "$sign1 → $sign2"
  "pictures-clear: " + (P 'pictures-clear' '{}')
  Start-Sleep -Seconds 1
  $s = J '/api/state'
  Check 'очистити фото' ($s.pictures.count -eq 0 -and @((J '/api/pictures').pages).Count -eq 0) ("count=" + $s.pictures.count)
}

Get-Process | Where-Object { $_.Path -and $_.Path -like "$dst*" } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
Start-Sleep -Seconds 1
Remove-Item -LiteralPath $dst -Recurse -Force -ErrorAction SilentlyContinue
$after = if (Test-Path -LiteralPath $appdata) { (Get-Item -LiteralPath $appdata).LastWriteTime.ToString('o') } else { 'none' }
"APPDATA Slovo: $before → $after " + $(if ($before -eq $after) { '(не чіпано)' } else { '(ЗМІНИЛОСЯ!)' })
"ПІДСУМОК: помилок $script:fails"
