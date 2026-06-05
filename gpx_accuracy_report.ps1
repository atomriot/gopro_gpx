<#
GoPro GPX accuracy report  (diagnostic tool, separate from the main extract/merge
pipeline -- run it ad hoc to inspect a single file's GPS quality).

Dumps every GPS point from a single GoPro file, classifies each point good/bad using
the same rules the extractor uses, and writes a self-contained HTML report with:
  - a GPS precision (DOP) chart over the file
  - an implied-speed chart (log) over the file
  - a map: green = good path, red = bad-fix points
  - the percentage of "accurate" (kept) data and a breakdown of why points were dropped

Usage:
  .\gpx_accuracy_report.ps1 -Path "E:\03-20-2026\GX010578.MP4"
  .\gpx_accuracy_report.ps1 -Path "E:\03-20-2026\GX010578.MP4" -MaxDop 10 -MaxPlausibleSpeedMps 60
#>
param(
  [Parameter(Mandatory=$true, Position=0)] [string] $Path,
  [string] $OutHtml = "",
  [double] $MaxDop = 10.0,
  [double] $MaxPlausibleSpeedMps = 60.0,
  [string] $ExifTool = "",
  [switch] $NoOpen
)

$ErrorActionPreference = 'Continue'   # ExifTool writes harmless [Minor] warnings to stderr

function Resolve-ExifTool([string]$override) {
  if ($override -and (Test-Path -LiteralPath $override)) { return $override }
  $cmd = Get-Command exiftool -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Source }
  throw "ExifTool not found. Put exiftool.exe on PATH or pass -ExifTool <path>."
}

function HaversineMeters([double]$lat1,[double]$lon1,[double]$lat2,[double]$lon2) {
  $R = 6371000.0
  $dLat = ([Math]::PI/180.0)*($lat2-$lat1)
  $dLon = ([Math]::PI/180.0)*($lon2-$lon1)
  $a = [Math]::Sin($dLat/2)*[Math]::Sin($dLat/2) +
       [Math]::Cos(([Math]::PI/180.0)*$lat1)*[Math]::Cos(([Math]::PI/180.0)*$lat2)*
       [Math]::Sin($dLon/2)*[Math]::Sin($dLon/2)
  return $R * (2.0*[Math]::Atan2([Math]::Sqrt($a),[Math]::Sqrt(1.0-$a)))
}

function NumStr($v,[int]$digits) {
  if ($null -eq $v) { return 'null' }
  return ([Math]::Round([double]$v,$digits)).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function Parse-Time([string]$s) {
  if (-not $s -or $s -eq '-') { return $null }
  $n = $s -replace '^(\d{4}):(\d{2}):(\d{2})','$1-$2-$3'
  try {
    return [DateTime]::Parse($n,[Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal)
  } catch { return $null }
}

function Fmt-Dur($sec) {
  if ($null -eq $sec) { return 'n/a' }
  $sec = [int][Math]::Round([double]$sec)
  $m = [Math]::Floor($sec/60); $s = $sec % 60
  return ('{0}m {1:00}s' -f $m,$s)
}

# --- resolve inputs ---
$exif = Resolve-ExifTool $ExifTool
if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "File not found: $Path" }
$inFull = (Resolve-Path -LiteralPath $Path).Path
$base = [IO.Path]::GetFileNameWithoutExtension($inFull)
if (-not $OutHtml) {
  $here = Split-Path -Parent $MyInvocation.MyCommand.Path
  $OutHtml = Join-Path $here ($base + "_accuracy.html")
}

Write-Host ("Extracting telemetry from {0} ..." -f $base)
$raw = & $exif -ee -api LargeFileSupport=1 -n -f -p '$GPSDateTime|$GPSLatitude|$GPSLongitude|$GPSAltitude|$GPSDOP' -- $inFull 2>$null

$pts = New-Object System.Collections.Generic.List[object]
foreach ($line in $raw) {
  if (-not $line) { continue }
  $f = $line -split '\|'
  if ($f.Count -lt 3) { continue }
  $latS=$f[0+1]; # placeholder to keep indexing obvious below
  $tS=$f[0]; $latS=$f[1]; $lonS=$f[2]; $eleS=$f[3]; $dopS=$f[4]
  if ($latS -eq '-' -or $lonS -eq '-') { continue }
  $lat=0.0; $lon=0.0
  if (-not [double]::TryParse($latS,[ref]$lat)) { continue }
  if (-not [double]::TryParse($lonS,[ref]$lon)) { continue }
  $dop=$null; $tmp=0.0
  if ($dopS -and $dopS -ne '-' -and [double]::TryParse($dopS,[ref]$tmp)) { $dop=$tmp }
  $ele=$null; if ($eleS -and $eleS -ne '-' -and [double]::TryParse($eleS,[ref]$tmp)) { $ele=$tmp }
  $t = Parse-Time $tS
  $pts.Add([pscustomobject]@{ lat=$lat; lon=$lon; ele=$ele; dop=$dop; time=$t; good=$false; reason=''; speed=$null }) | Out-Null
}

$n = $pts.Count
if ($n -eq 0) { throw "No GPS points found in $base (no telemetry, or GPS never produced a position)." }

# --- classify (mirror the pipeline's cleaning) ---
$goodCount=0; $cntNoFix=0; $cntNoTime=0; $cntHighDop=0; $cntSpike=0
$last=$null
for ($i=0; $i -lt $n; $i++) {
  $p=$pts[$i]; $reasons=@()
  if ($p.lat -eq 0.0 -and $p.lon -eq 0.0) { $reasons+='no_fix' }
  if ($null -eq $p.time) { $reasons+='no_time' }
  if ($null -ne $p.dop -and $p.dop -gt $MaxDop) { $reasons+='high_dop' }
  if ($null -ne $last -and $last.time -and $p.time) {
    $dt = ($p.time - $last.time).TotalSeconds
    if ($dt -gt 0) {
      $d = HaversineMeters $last.lat $last.lon $p.lat $p.lon
      $p.speed = $d/$dt
      if ($p.speed -gt $MaxPlausibleSpeedMps) { $reasons+='speed_spike' }
    }
  }
  if ($reasons.Count -eq 0) { $p.good=$true; $goodCount++; $last=$p }
  else {
    $p.reason = ($reasons -join '+')
    if ($reasons -contains 'no_fix')     { $cntNoFix++ }
    if ($reasons -contains 'no_time')    { $cntNoTime++ }
    if ($reasons -contains 'high_dop')   { $cntHighDop++ }
    if ($reasons -contains 'speed_spike'){ $cntSpike++ }
  }
}
$badCount = $n - $goodCount
$pctGood = if ($n) { [Math]::Round(100.0*$goodCount/$n,1) } else { 0 }

# --- dop + time stats ---
$dopVals = @($pts | Where-Object { $null -ne $_.dop } | ForEach-Object { $_.dop } | Sort-Object)
$dopMin = if ($dopVals.Count) { NumStr $dopVals[0] 2 } else { 'n/a' }
$dopMax = if ($dopVals.Count) { NumStr $dopVals[$dopVals.Count-1] 2 } else { 'n/a' }
$dopMed = if ($dopVals.Count) { NumStr $dopVals[[int][Math]::Floor($dopVals.Count/2)] 2 } else { 'n/a' }

$timed     = @($pts | Where-Object { $_.time })
$goodTimed = @($pts | Where-Object { $_.good -and $_.time })
$totalSpan=$null; $goodSpan=$null; $warmup=$null; $trail=$null
if ($timed.Count -ge 2) { $totalSpan = ($timed[$timed.Count-1].time - $timed[0].time).TotalSeconds }
if ($goodTimed.Count -ge 2) { $goodSpan = ($goodTimed[$goodTimed.Count-1].time - $goodTimed[0].time).TotalSeconds }
if ($timed.Count -and $goodTimed.Count) {
  $warmup = ($goodTimed[0].time - $timed[0].time).TotalSeconds
  $trail  = ($timed[$timed.Count-1].time - $goodTimed[$goodTimed.Count-1].time).TotalSeconds
}

# --- build chart/map data (downsample the trend lines; keep ALL bad points + map) ---
$stride = [Math]::Max(1, [int][Math]::Ceiling($n/4000.0))
$dopLine=New-Object System.Collections.Generic.List[string]
$spdLine=New-Object System.Collections.Generic.List[string]
$dopBad =New-Object System.Collections.Generic.List[string]
$spdBad =New-Object System.Collections.Generic.List[string]
$goodPath=New-Object System.Collections.Generic.List[string]
$badPts =New-Object System.Collections.Generic.List[string]
for ($i=0; $i -lt $n; $i++) {
  $p=$pts[$i]
  if (($i % $stride) -eq 0) {
    $dopLine.Add('{x:'+$i+',y:'+(NumStr $p.dop 2)+'}') | Out-Null
    $sp = if ($null -ne $p.speed -and $p.speed -gt 0) { NumStr $p.speed 2 } else { 'null' }
    $spdLine.Add('{x:'+$i+',y:'+$sp+'}') | Out-Null
  }
  if (-not $p.good) {
    if ($null -ne $p.dop) { $dopBad.Add('{x:'+$i+',y:'+(NumStr $p.dop 2)+'}') | Out-Null }
    if ($null -ne $p.speed -and $p.speed -gt 0) { $spdBad.Add('{x:'+$i+',y:'+(NumStr $p.speed 2)+'}') | Out-Null }
    if (-not ($p.lat -eq 0.0 -and $p.lon -eq 0.0)) {
      $badPts.Add('['+(NumStr $p.lat 7)+','+(NumStr $p.lon 7)+','+$i+',"'+$p.reason+'"]') | Out-Null
    }
  } else {
    $goodPath.Add('['+(NumStr $p.lat 7)+','+(NumStr $p.lon 7)+']') | Out-Null
  }
}

$summary = @"
<div class='big'><span class='good'>$pctGood% accurate</span>&nbsp;<span style='color:#888'>($goodCount of $n points kept)</span></div>
<table>
<tr><td>Total GPS points</td><td>$n</td></tr>
<tr><td>Good (kept)</td><td class='good'>$goodCount</td></tr>
<tr><td>Bad (scrubbed)</td><td class='bad'>$badCount</td></tr>
<tr><td colspan=2><hr style='border-color:#333'></td></tr>
<tr><td>&bull; no fix (0,0)</td><td>$cntNoFix</td></tr>
<tr><td>&bull; no timestamp</td><td>$cntNoTime</td></tr>
<tr><td>&bull; high DOP (&gt; $MaxDop)</td><td>$cntHighDop</td></tr>
<tr><td>&bull; speed spike (&gt; $MaxPlausibleSpeedMps m/s)</td><td>$cntSpike</td></tr>
<tr><td colspan=2><hr style='border-color:#333'></td></tr>
<tr><td>DOP min / median / max</td><td>$dopMin / $dopMed / $dopMax</td></tr>
<tr><td>File time span</td><td>$(Fmt-Dur $totalSpan)</td></tr>
<tr><td>Good-data time span</td><td>$(Fmt-Dur $goodSpan)</td></tr>
<tr><td>Warmup before first good fix</td><td>$(Fmt-Dur $warmup)</td></tr>
<tr><td>Trailing after last good fix</td><td>$(Fmt-Dur $trail)</td></tr>
</table>
"@

$tpl = @'
<!doctype html><html><head><meta charset="utf-8"><title>__TITLE__</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css"/>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.min.js"></script>
<style>
body{font-family:Segoe UI,Arial,sans-serif;margin:20px;background:#111;color:#eee}
h1{font-size:20px} h2{font-size:14px;color:#9cf;margin:0 0 10px}
.card{background:#1b1b1b;border:1px solid #333;border-radius:8px;padding:16px;margin-bottom:18px}
table{border-collapse:collapse} td{padding:2px 12px}
.big{font-size:26px;font-weight:bold;margin-bottom:10px} .good{color:#5f5} .bad{color:#f66}
#map{height:430px;border-radius:6px} canvas{background:#161616;border-radius:6px}
</style></head><body>
<h1>GPS accuracy report &mdash; __TITLE__</h1>
<div class="card">__SUMMARY__</div>
<div class="card"><h2>Path map &mdash; green = good path, red dots = bad-fix points (click for reason)</h2><div id="map"></div></div>
<div class="card"><h2>GPS precision (DOP) over the file &mdash; lower is better; orange = drop threshold</h2><canvas id="dopChart" height="110"></canvas></div>
<div class="card"><h2>Implied speed over the file (log scale) &mdash; spikes are bad jumps</h2><canvas id="spdChart" height="110"></canvas></div>
<script>
var MAXDOP=__MAXDOP__, MAXSPD=__MAXSPD__;
var dopLine=__DOPLINE__, dopBad=__DOPBAD__, spdLine=__SPDLINE__, spdBad=__SPDBAD__;
var goodPath=__GOODPATH__, badPts=__BADPTS__;
var map=L.map('map');
L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',{maxZoom:19,attribution:'&copy; OpenStreetMap &copy; CARTO'}).addTo(map);
if(goodPath.length){var pl=L.polyline(goodPath,{color:'#33ff77',weight:3}).addTo(map);map.fitBounds(pl.getBounds());}
else if(badPts.length){map.setView([badPts[0][0],badPts[0][1]],10);} else {map.setView([0,0],2);}
badPts.forEach(function(b){L.circleMarker([b[0],b[1]],{radius:3,color:'#ff4444',weight:1,fillOpacity:0.6}).addTo(map).bindPopup('idx '+b[2]+': '+b[3]);});
function ends(a,y){return a.length?[{x:a[0].x,y:y},{x:a[a.length-1].x,y:y}]:[{x:0,y:y},{x:1,y:y}];}
new Chart(document.getElementById('dopChart'),{type:'line',data:{datasets:[
 {label:'DOP',data:dopLine,borderColor:'#4aa3ff',borderWidth:1,pointRadius:0,spanGaps:false},
 {label:'bad point',data:dopBad,type:'scatter',backgroundColor:'#ff4444',pointRadius:2,showLine:false},
 {label:'threshold '+MAXDOP,data:ends(dopLine,MAXDOP),borderColor:'#ffaa00',borderDash:[6,4],borderWidth:1,pointRadius:0}
]},options:{animation:false,scales:{x:{type:'linear',title:{display:true,text:'point index',color:'#aaa'},ticks:{color:'#aaa'}},y:{title:{display:true,text:'GPSDOP',color:'#aaa'},ticks:{color:'#aaa'}}},plugins:{legend:{labels:{color:'#ccc'}}}}});
new Chart(document.getElementById('spdChart'),{type:'line',data:{datasets:[
 {label:'speed m/s',data:spdLine,borderColor:'#4aa3ff',borderWidth:1,pointRadius:0,spanGaps:false},
 {label:'spike',data:spdBad,type:'scatter',backgroundColor:'#ff4444',pointRadius:2,showLine:false},
 {label:'threshold '+MAXSPD,data:ends(spdLine,MAXSPD),borderColor:'#ffaa00',borderDash:[6,4],borderWidth:1,pointRadius:0}
]},options:{animation:false,scales:{x:{type:'linear',title:{display:true,text:'point index',color:'#aaa'},ticks:{color:'#aaa'}},y:{type:'logarithmic',title:{display:true,text:'m/s (log)',color:'#aaa'},ticks:{color:'#aaa'}}},plugins:{legend:{labels:{color:'#ccc'}}}}});
</script></body></html>
'@

$html = $tpl.
  Replace('__TITLE__',$base).
  Replace('__SUMMARY__',$summary).
  Replace('__MAXDOP__',(NumStr $MaxDop 2)).
  Replace('__MAXSPD__',(NumStr $MaxPlausibleSpeedMps 2)).
  Replace('__DOPLINE__',('['+($dopLine -join ',')+']')).
  Replace('__DOPBAD__', ('['+($dopBad  -join ',')+']')).
  Replace('__SPDLINE__',('['+($spdLine -join ',')+']')).
  Replace('__SPDBAD__', ('['+($spdBad  -join ',')+']')).
  Replace('__GOODPATH__',('['+($goodPath -join ',')+']')).
  Replace('__BADPTS__', ('['+($badPts  -join ',')+']'))

[IO.File]::WriteAllText($OutHtml,$html,[Text.Encoding]::UTF8)

Write-Host ""
Write-Host ("=== {0} ===" -f $base) -ForegroundColor Cyan
Write-Host ("  points: {0}   good: {1}   bad: {2}   ACCURATE: {3}%" -f $n,$goodCount,$badCount,$pctGood) -ForegroundColor Green
Write-Host ("  bad breakdown -> no_fix:{0}  no_time:{1}  high_dop:{2}  speed_spike:{3}" -f $cntNoFix,$cntNoTime,$cntHighDop,$cntSpike)
Write-Host ("  DOP min/median/max: {0}/{1}/{2}" -f $dopMin,$dopMed,$dopMax)
Write-Host ("  file span: {0}   good span: {1}   warmup: {2}" -f (Fmt-Dur $totalSpan),(Fmt-Dur $goodSpan),(Fmt-Dur $warmup))
Write-Host ("  report: {0}" -f $OutHtml) -ForegroundColor Yellow
if (-not $NoOpen) { Invoke-Item $OutHtml }
