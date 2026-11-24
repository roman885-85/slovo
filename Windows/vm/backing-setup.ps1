# Фонограми у ВМ: тестова тека %LOCALAPPDATA%\slovo-test-backing (exe і дані з Службові/vm-new), список із трьох
# файлів (mp3, opus, WavPack), запуск із пультом 18103 і веб-слайдами 18680. Після — убити процес і стерти теку.
$ErrorActionPreference = 'Stop'
$src = '\\Mac\Home\Documents\Слово\Исходники\Windows\Службові\vm-new'
$dst = Join-Path $env:LOCALAPPDATA 'slovo-test-backing'
Get-Process | Where-Object { $_.Path -and $_.Path -like "$dst*" } | ForEach-Object { $_.Kill(); $_.WaitForExit() }
if (Test-Path -LiteralPath $dst) { Remove-Item -LiteralPath $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst | Out-Null
Copy-Item -LiteralPath (Join-Path $src 'Слово.exe') -Destination $dst
# yt-dlp.exe поруч із програмою — для перевірки YouTube (якщо є в тестовій теці).
if (Test-Path -LiteralPath (Join-Path $src 'yt-dlp.exe')) { Copy-Item -LiteralPath (Join-Path $src 'yt-dlp.exe') -Destination $dst }
Copy-Item -LiteralPath (Join-Path $src 'data') -Destination $dst -Recurse
$audio = Join-Path $dst 'data\audio'
$list = @('Ранкова_прогулянка1.mp3', 'Тест opus.opus', 'Тест wavpack.wv') | ForEach-Object { Join-Path $audio $_ }
$path = Join-Path $dst 'data\defaults.json'
$json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
$json | Add-Member -NotePropertyName backingPlaylist -NotePropertyValue ($list -join "`n") -Force
$json | Add-Member -NotePropertyName backingTrackFile -NotePropertyValue $list[0] -Force
$json | Add-Member -NotePropertyName backingPlaysNext -NotePropertyValue $true -Force
$json | Add-Member -NotePropertyName lastMode -NotePropertyValue 'songs' -Force
[IO.File]::WriteAllText($path, ($json | ConvertTo-Json), (New-Object Text.UTF8Encoding $false))
$appdata = Join-Path $env:APPDATA 'Slovo'
"real APPDATA Slovo before: " + $(if (Test-Path -LiteralPath $appdata) { (Get-Item -LiteralPath $appdata).LastWriteTime.ToString('s') } else { 'none' })
$exe = Join-Path $dst 'Слово.exe'
Start-Process -FilePath $exe -ArgumentList @('--data', "`"$(Join-Path $dst 'data')`"", '--remote-port', '18103', '--web-port', '18105', '--web-slides-port', '18680', '--web-socket-port', '18681')
$ok = $false
for ($i = 0; $i -lt 60; $i++) {
  try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 'http://127.0.0.1:18103/api/backing'; $ok = $true; break } catch { Start-Sleep -Seconds 1 }
}
"started: $ok"
if ($ok) { [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) }
