# Список плеєра з посиланнями YouTube і «наступний після кінця» (у ВМ, після backing-setup.ps1).
# Потрібні remote-helpers.ps1 і yt-dlp.exe поруч із тестовою програмою.
function Get-Json($path) { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 ("http://127.0.0.1:18103" + $path); [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json }
function Show-Media($tag) { $m = Get-Json '/api/media'; "  $tag title='$($m.title)' playing=$($m.playing) pos=$([Math]::Round($m.position,1))/$([Math]::Round($m.duration,1)) index=$($m.index) next=$($m.next)" }
"links: " + (Post "media-url" (ConvertTo-Json @{ text = "https://www.youtube.com/watch?v=jNQXAC9IVRw`nhttps://youtu.be/dQw4w9WgXcQ" }))
"next on: " + (Post "media-next" '{}')
foreach ($i in 1..5) { Start-Sleep -Seconds 4; Show-Media "t+$($i*4)s" }
$m = Get-Json '/api/media'
"playlist: " + (($m.playlist | ForEach-Object { "$($_.index):$($_.name)" }) -join ' | ')
"seek to end: " + (Post "media-seek" (ConvertTo-Json @{ x = [Math]::Max(0, $m.duration - 2) }))
foreach ($i in 1..7) { Start-Sleep -Seconds 4; Show-Media "after end +$($i*4)s" }
"stop: " + (Post "media-stop" '{}')
