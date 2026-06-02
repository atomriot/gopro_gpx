<#
GoPro GPX  --  merge_gpxs.ps1 (supplementary: merge per-ride routes)

Merge GPX files in a folder into 1..N unified routes (“sessions”/rides) based on continuity.

Heuristic (uses BOTH a time and a location differential so a stop mid-ride does not
start a new ride, but resuming somewhere else does):
- Sort GPX files by first trackpoint time
- Start a new session when ANY of:
  - the tracks are out of order (next starts >5s before prev ends), OR
  - the time gap (end of prev -> start of next) exceeds -MaxGapSeconds (default 3600s = 1h),
    i.e. a long gap is always a new ride even if you restart from the same place, OR
  - you PAUSED and MOVED: the time gap exceeds -MinGapSeconds (default 120s) AND the
    distance between where you stopped and where you resumed exceeds -MaxGapMeters
    (default 500m). A short stop where you resume in place stays one ride.

Output:
- Writes merged GPX per session: merged_route_YYYYMMDD_HHMMSS_sessionNN.gpx
- Writes merge_results.json with grouping + stats

PS 5.1 compatible. No external deps.

Example:
  .\merge_gpxs.ps1 -InDir .\gpx_out -OutDir .\merged
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string] $InDir,

  [string] $OutDir = "",

  [int] $MaxGapSeconds = 3600,    # 1 hour: a gap longer than this ALWAYS starts a new ride
  [int] $MinGapSeconds = 120,     # 2 min: minimum pause before a "moved away" split applies
  [double] $MaxGapMeters = 500.0, # 500 m: resumed this far from where you stopped (after a pause) = new ride
  [switch] $Recurse
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function Resolve-OutDir([string]$outDir) {
  if ($outDir -and $outDir.Trim().Length -gt 0) {
    if (-not [System.IO.Path]::IsPathRooted($outDir)) {
      return [System.IO.Path]::GetFullPath((Join-Path $PWD.Path $outDir))
    }
    return [System.IO.Path]::GetFullPath($outDir)
  }
  return (Resolve-Path -LiteralPath $InDir).Path
}

function HaversineMeters([double]$lat1, [double]$lon1, [double]$lat2, [double]$lon2) {
  $R = 6371000.0
  $dLat = ([Math]::PI / 180.0) * ($lat2 - $lat1)
  $dLon = ([Math]::PI / 180.0) * ($lon2 - $lon1)
  $a = [Math]::Sin($dLat/2.0) * [Math]::Sin($dLat/2.0) +
       [Math]::Cos(([Math]::PI/180.0)*$lat1) * [Math]::Cos(([Math]::PI/180.0)*$lat2) *
       [Math]::Sin($dLon/2.0) * [Math]::Sin($dLon/2.0)
  $c = 2.0 * [Math]::Atan2([Math]::Sqrt($a), [Math]::Sqrt(1.0-$a))
  return $R * $c
}

function Parse-GpxPoints([xml]$xml) {
  $trkpts = $xml.SelectNodes("//*[local-name()='trkpt']")
  $pts = New-Object System.Collections.Generic.List[object]
  foreach ($p in $trkpts) {
    $lat = [double]$p.GetAttribute("lat")
    $lon = [double]$p.GetAttribute("lon")
    $timeNode = $p.SelectSingleNode("*[local-name()='time']")
    $t = $null
    $raw = $null
    if ($timeNode -and $timeNode.InnerText) {
      $raw = $timeNode.InnerText
      $t = [DateTime]::Parse(
        $raw,
        [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal
      ).ToUniversalTime()
    }
    $pts.Add([pscustomobject]@{ lat=$lat; lon=$lon; time=$t; rawTime=$raw }) | Out-Null
  }
  return ,$pts.ToArray()
}

function Get-GpxMeta([string]$path) {
  [xml]$xml = Get-Content -LiteralPath $path -Raw
  $pts = Parse-GpxPoints $xml
  $count = $pts.Length
  if ($count -eq 0) {
    return [pscustomobject]@{
      path = $path
      points = 0
      startTime = $null
      endTime = $null
      startLat = $null
      startLon = $null
      endLat = $null
      endLon = $null
      xml = $xml
      error = $null
    }
  }

  $start = $pts[0]
  $end   = $pts[$count-1]

  return [pscustomobject]@{
    path = $path
    points = $count
    startTime = $start.time
    endTime = $end.time
    startLat = $start.lat
    startLon = $start.lon
    endLat = $end.lat
    endLon = $end.lon
    xml = $xml
    error = $null
  }
}

function Get-GpxFiles([string]$dir, [switch]$recurse) {
  $p = Resolve-Path -LiteralPath $dir
  $gci = @{ Path = $p.Path; File = $true; Filter = "*.gpx" }
  if ($recurse) { $gci.Recurse = $true }
  return @(Get-ChildItem @gci | ForEach-Object { $_.FullName })
}

function Ensure-TrackContainers([xml]$xml) {
  # Ensure there is at least one trk/trkseg; return the segment node for appending trkpt.
  $trk = $xml.SelectSingleNode("//*[local-name()='trk']")
  if (-not $trk) {
    $gpx = $xml.SelectSingleNode("/*[local-name()='gpx']")
    if (-not $gpx) { throw "Invalid GPX (no <gpx> root)" }
    $trk = $xml.CreateElement("trk", $gpx.NamespaceURI)
    $null = $gpx.AppendChild($trk)
  }

  $trkseg = $xml.SelectSingleNode("//*[local-name()='trkseg']")
  if (-not $trkseg) {
    $gpx = $xml.SelectSingleNode("/*[local-name()='gpx']")
    $trkseg = $xml.CreateElement("trkseg", $gpx.NamespaceURI)
    $null = $trk.AppendChild($trkseg)
  }
  return $trkseg
}

function Build-MergedGpx([object[]]$metas, [string]$sessionName) {
  # Use first GPX as base document (keeps namespaces, metadata, extensions).
  [xml]$outXml = $metas[0].xml.OuterXml

  # Remove all existing trackpoints from base
  $existing = $outXml.SelectNodes("//*[local-name()='trkpt']")
  foreach ($n in @($existing)) { $null = $n.ParentNode.RemoveChild($n) }

  $trkseg = Ensure-TrackContainers $outXml

  $totalPts = 0
  foreach ($m in $metas) {
    $pts = $m.xml.SelectNodes("//*[local-name()='trkpt']")
    foreach ($p in $pts) {
      $imported = $outXml.ImportNode($p, $true)
      $null = $trkseg.AppendChild($imported)
      $totalPts++
    }
  }

  # Set/replace <name> under <trk>
  $trk = $outXml.SelectSingleNode("//*[local-name()='trk']")
  $nameNode = $trk.SelectSingleNode("*[local-name()='name']")
  $gpxRoot = $outXml.SelectSingleNode("/*[local-name()='gpx']")
  $nsUri = $gpxRoot.NamespaceURI
  if (-not $nameNode) {
    $nameNode = $outXml.CreateElement("name", $nsUri)
    $null = $trk.PrependChild($nameNode)
  }
  $nameNode.InnerText = $sessionName

  return @{ xml=$outXml; points=$totalPts }
}

# --- main ---
if (-not (Test-Path -LiteralPath $InDir -PathType Container)) { throw "InDir not found: $InDir" }
$outRoot = Resolve-OutDir $OutDir
Ensure-Dir $outRoot

$files = @(Get-GpxFiles $InDir $Recurse)
if ($files.Length -eq 0) { throw "No .gpx files found under: $InDir" }

# Read meta for each file (including start/end time/coord)
Write-Host ("Reading {0} GPX file(s) from: {1}" -f $files.Length, $InDir)
$metas = New-Object System.Collections.Generic.List[object]
$gpxIndex = 0
foreach ($f in $files) {
  $gpxIndex++
  $pct = [int][Math]::Floor(($gpxIndex / $files.Length) * 100)
  Write-Progress -Activity "Merging GPX" `
    -Status ("[{0}/{1}] {2}" -f $gpxIndex, $files.Length, [IO.Path]::GetFileName($f)) -PercentComplete $pct
  try {
    $metas.Add((Get-GpxMeta $f)) | Out-Null
  } catch {
    $metas.Add([pscustomobject]@{
      path = $f; points = 0; startTime=$null; endTime=$null;
      startLat=$null; startLon=$null; endLat=$null; endLon=$null; xml=$null;
      error = $_.Exception.Message
    }) | Out-Null
  }
}
Write-Progress -Activity "Merging GPX" -Completed

# Keep only those with points>0 and valid times; still report all in JSON
$valid = @($metas | Where-Object { $_.points -gt 0 -and $_.startTime -ne $null -and $_.endTime -ne $null })

if ($valid.Length -eq 0) { throw "Found GPX files but none had usable trackpoints with timestamps." }

$valid = @($valid | Sort-Object startTime)

# Group into sessions
$sessions = New-Object System.Collections.Generic.List[object]
$current = New-Object System.Collections.Generic.List[object]
$current.Add($valid[0]) | Out-Null

for ($i=1; $i -lt $valid.Length; $i++) {
  $prev = $valid[$i-1]
  $next = $valid[$i]

  $gapSec = [double]($next.startTime - $prev.endTime).TotalSeconds
  $gapM = HaversineMeters $prev.endLat $prev.endLon $next.startLat $next.startLon

  # New ride if: out of order, OR a long time gap (always), OR a real pause where you
  # also moved away from where you stopped (time AND location differential together).
  $newSession = ($gapSec -lt -5) -or
                ($gapSec -gt $MaxGapSeconds) -or
                (($gapSec -gt $MinGapSeconds) -and ($gapM -gt $MaxGapMeters))

  if ($newSession) {
    $sessions.Add(@($current.ToArray())) | Out-Null
    $current = New-Object System.Collections.Generic.List[object]
  }
  $current.Add($next) | Out-Null
}
$sessions.Add(@($current.ToArray())) | Out-Null

# Write merged GPX per session
$outItems = New-Object System.Collections.Generic.List[object]
$sessionIdx = 1

foreach ($sess in $sessions) {
  $s = @($sess)
  $start = $s[0].startTime
  $stamp = $start.ToString("yyyyMMdd_HHmmss")
  $name = "merged_route_${stamp}_session{0:D2}" -f $sessionIdx
  $outPath = Join-Path $outRoot ($name + ".gpx")

  $merged = Build-MergedGpx $s $name
  $merged.xml.Save($outPath)

  $outItems.Add([pscustomobject]@{
    session = $sessionIdx
    name = $name
    outPath = $outPath
    fileCount = $s.Length
    points = $merged.points
    startTimeUtc = $s[0].startTime.ToString("o")
    endTimeUtc = $s[$s.Length-1].endTime.ToString("o")
    files = @($s | ForEach-Object { $_.path })
    gaps = @() # optional; fill below if desired
  }) | Out-Null

  $sessionIdx++
}

# Optionally compute gaps for report
foreach ($item in $outItems) {
  $paths = $item.files
  $sessMetas = @($valid | Where-Object { $paths -contains $_.path } | Sort-Object startTime)
  $gaps = New-Object System.Collections.Generic.List[object]
  for ($i=1; $i -lt $sessMetas.Length; $i++) {
    $a = $sessMetas[$i-1]
    $b = $sessMetas[$i]
    $gaps.Add([pscustomobject]@{
      prev = $a.path
      next = $b.path
      gapSeconds = [Math]::Round((($b.startTime - $a.endTime).TotalSeconds), 3)
      gapMeters = [Math]::Round((HaversineMeters $a.endLat $a.endLon $b.startLat $b.startLon), 3)
    }) | Out-Null
  }
  $item.gaps = $gaps.ToArray()
}

$report = [ordered]@{
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  inDir = (Resolve-Path -LiteralPath $InDir).Path
  outDir = $outRoot
  maxGapSeconds = $MaxGapSeconds
  minGapSeconds = $MinGapSeconds
  maxGapMeters = $MaxGapMeters
  totalGpxFilesFound = $files.Length
  totalUsableGpxFiles = $valid.Length
  sessionCount = $outItems.Count
  sessions = $outItems
  skippedOrInvalid = @($metas | Where-Object { $_.points -eq 0 -or $_.startTime -eq $null -or $_.endTime -eq $null } | ForEach-Object {
    [pscustomobject]@{
      path = $_.path
      points = $_.points
      error = $_.error
    }
  })
}

$resultsPath = Join-Path $outRoot "merge_results.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $resultsPath

Write-Host ("Wrote results: " + $resultsPath)
Write-Host ("Merged sessions: {0}, output dir: {1}" -f $outItems.Count, $outRoot)
