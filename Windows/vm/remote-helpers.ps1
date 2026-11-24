function Post($cmd, $body) {
  $bytes = [Text.Encoding]::UTF8.GetBytes($body)
  try {
    $r = Invoke-WebRequest -UseBasicParsing -Method Post -ContentType 'application/json' -Body $bytes -TimeoutSec 20 ("http://127.0.0.1:18103/api/" + $cmd)
    return [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
  } catch { return "ERR " + $_.Exception.Message + " " + $(if ($_.Exception.Response) { (New-Object IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() }) }
}
function Get-Backing { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 5 'http://127.0.0.1:18103/api/backing'; $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json; "{0} playing={1} pos={2:N2}/{3:N2} tone={4} vol={5} idx={6} err='{7}'" -f $j.title, $j.playing, $j.position, $j.duration, $j.tone, $j.volume, $j.index, $j.error }
