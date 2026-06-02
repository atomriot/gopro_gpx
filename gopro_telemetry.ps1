<#
GoPro GPX  --  gopro_telemetry.ps1 (supplementary: per-video extractor)

GoPro MP4 -> GPX extractor (Windows, local; PS 5.1 compatible)

- Input: file or directory of .MP4/.MOV
- Output: one .gpx per file (only if >0 trackpoints; optionally trimmed)
- Results: telemetry_results.json for all processed files (including 0 points)
- Adds quality indicators (heuristics) and optional warmup trimming.

Requirements:
- ffprobe in PATH
- ExifTool: auto-downloads portable exiftool.exe into OutDir\.tools if not present

Examples:
  .\gopro_telemetry.ps1 -Path .\GX010123.MP4 -OutDir .\gpx_out
  .\gopro_telemetry.ps1 -Path .\01-08-2026\ -OutDir .\gpx_out
  .\gopro_telemetry.ps1 -Path .\01-08-2026\ -OutDir .\gpx_out -TrimWarmup
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string] $Path,

  [string] $OutDir = "",

  [switch] $Recurse,

  # If set, trims early “warmup” points from GPX using the first stable window heuristic.
  [switch] $TrimWarmup,

  # GPS cleaning is ON by default: drops no-fix (0,0) points, points whose GoPro
  # GPSDOP (dilution of precision) exceeds -MaxDop, and physically impossible jumps.
  # Use -NoClean to write the raw, unfiltered track instead.
  [switch] $NoClean,
  [double] $MaxDop = 10.0,  # max GoPro GPSDOP to keep (<=5 is good, >50 is junk)

  # Heuristic thresholds (units are meters/seconds)
  [double] $MaxPlausibleSpeedMps = 60.0,  # jumps implying a higher speed are dropped/flagged
  [int]    $StableWindowPoints   = 10,    # window size (points) for “first stable” detection
  [double] $StableMaxSpeedMps    = 5.0,   # stability requires implied speed <= this within window
  [double] $StableMaxJumpM       = 25.0   # stability requires per-step jump <= this within window
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir | Out-Null
  }
}

function Resolve-OutDir([string]$inPath, [string]$outDir) {
  if ($outDir -and $outDir.Trim().Length -gt 0) {
    # Resolve relative OutDir against the current working directory ($PWD), not System32
    if (-not [System.IO.Path]::IsPathRooted($outDir)) {
      return [System.IO.Path]::GetFullPath((Join-Path $PWD.Path $outDir))
    }
    return [System.IO.Path]::GetFullPath($outDir)
  }

  if (Test-Path -LiteralPath $inPath -PathType Container) {
    return (Resolve-Path -LiteralPath $inPath).Path
  }

  return (Split-Path (Resolve-Path -LiteralPath $inPath).Path -Parent)
}

function Ensure-ExifTool([string]$toolsDir) {
  $cmd = Get-Command exiftool -ErrorAction SilentlyContinue
  if ($cmd) { return $cmd.Path }

  Ensure-Dir $toolsDir
  $exiftoolExe = Join-Path $toolsDir "exiftool.exe"
  $exiftoolFilesDir = Join-Path $toolsDir "exiftool_files"

  if ((Test-Path -LiteralPath $exiftoolExe) -and (Test-Path -LiteralPath $exiftoolFilesDir)) {
    return $exiftoolExe
  }

  # Download latest Windows ZIP from official site (parse homepage for exiftool-*.zip link)
  $home = "https://exiftool.org/"
  $html = (Invoke-WebRequest -UseBasicParsing -Uri $home).Content
  $m = [regex]::Match($html, 'href="(?<u>[^"]*exiftool-[0-9.]+\.zip)"', 'IgnoreCase')
  if (-not $m.Success) { throw "Could not find ExifTool Windows zip link on $home" }

  $zipUrl = $m.Groups["u"].Value
  if ($zipUrl -notmatch '^https?://') { $zipUrl = $home.TrimEnd('/') + "/" + $zipUrl.TrimStart('/') }

  $zipPath = Join-Path $toolsDir "exiftool.zip"
  Invoke-WebRequest -UseBasicParsing -Uri $zipUrl -OutFile $zipPath

  $unzipDir = Join-Path $toolsDir "exiftool_unzipped"
  if (Test-Path -LiteralPath $unzipDir) { Remove-Item -Recurse -Force -LiteralPath $unzipDir }
  Expand-Archive -Path $zipPath -DestinationPath $unzipDir -Force

  $root = Get-ChildItem -LiteralPath $unzipDir -Directory | Select-Object -First 1
  if (-not $root) { throw "Unexpected ExifTool zip structure (no directory found)." }

  $kexe = Join-Path $root.FullName "exiftool(-k).exe"
  if (-not (Test-Path -LiteralPath $kexe)) { throw "exiftool(-k).exe not found in extracted archive." }

  Copy-Item -Force -LiteralPath $kexe -Destination $exiftoolExe
  Copy-Item -Recurse -Force -LiteralPath (Join-Path $root.FullName "exiftool_files") -Destination $exiftoolFilesDir

  return $exiftoolExe
}

function Ensure-GpxFmt([string]$toolsDir) {
  # Generate our own ExifTool format file (based on the official gpx.fmt) that ALSO
  # emits the GoPro per-point GPSDOP as an <hdop> element. This lets us filter out
  # low-quality fixes in a single extraction pass. Written fresh each run so an old
  # cached standard gpx.fmt (without hdop) never gets reused.
  Ensure-Dir $toolsDir
  $fmt = Join-Path $toolsDir "gpx_dop.fmt"
  $content = @'
#[HEAD]<?xml version="1.0" encoding="utf-8"?>
#[HEAD]<gpx version="1.0"
#[HEAD] creator="ExifTool $ExifToolVersion"
#[HEAD] xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
#[HEAD] xmlns="http://www.topografix.com/GPX/1/0"
#[HEAD] xsi:schemaLocation="http://www.topografix.com/GPX/1/0 http://www.topografix.com/GPX/1/0/gpx.xsd">
#[HEAD]<trk>
#[HEAD]<number>1</number>
#[HEAD]<trkseg>
#[IF]  $gpslatitude $gpslongitude
#[BODY]<trkpt lat="$gpslatitude#" lon="$gpslongitude#">
#[BODY]  <ele>$gpsaltitude#</ele>
#[BODY]  <time>${gpsdatetime#;DateFmt("%Y-%m-%dT%H:%M:%S%fZ")}</time>
#[BODY]  <hdop>$gpsdop#</hdop>
#[BODY]</trkpt>
#[TAIL]</trkseg>
#[TAIL]</trk>
#[TAIL]</gpx>
'@
  Set-Content -LiteralPath $fmt -Value $content -Encoding ascii
  return $fmt
}

function Get-VideoFiles([string]$p, [switch]$recurse) {
  if (Test-Path -LiteralPath $p -PathType Leaf) {
    return ,(Resolve-Path -LiteralPath $p).Path
  }
  if (-not (Test-Path -LiteralPath $p -PathType Container)) {
    throw "Path not found: $p"
  }

  $gciParams = @{ Path = $p; File = $true }
  if ($recurse) { $gciParams.Recurse = $true }

  $exts = @(".mp4", ".mov")
  return @(Get-ChildItem @gciParams |
           Where-Object { $exts -contains $_.Extension.ToLowerInvariant() } |
           ForEach-Object { $_.FullName })
}

function Has-DataStream([string]$file) {
  $json = & ffprobe -v error -show_entries stream=codec_type,codec_tag_string -of json -- $file 2>$null
  if (-not $json) { return $false }
  $o = $json | ConvertFrom-Json
  if (-not $o.streams) { return $false }
  return @($o.streams | Where-Object { $_.codec_type -eq "data" }).Count -gt 0
}

function Extract-Gpx([string]$exiftool, [string]$gpxFmt, [string]$inFile) {
  # ExifTool emits harmless [Minor] warnings to stderr (e.g. "gpsaltitude not defined"
  # on some points). Under Windows PowerShell 5.1 with $ErrorActionPreference='Stop',
  # ANY native-command stderr write becomes a TERMINATING error -- even with 2>$null --
  # which would wrongly abort extraction and report 0 points. Soften the preference
  # just around this call so warnings are ignored and stdout is still captured.
  # -api LargeFileSupport=1 also keeps GoPro chapters >2GB readable.
  $prevEAP = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $gpx = & $exiftool -ee -api LargeFileSupport=1 -p $gpxFmt -- $inFile 2>$null
  } finally {
    $ErrorActionPreference = $prevEAP
  }
  if (-not $gpx) { return @{ gpxText = ""; points = 0 } }

  $text = ($gpx -join "`n")
  $points = ([regex]::Matches($text, "<trkpt\b", "IgnoreCase")).Count
  return @{ gpxText = $text; points = $points }
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

function Parse-GpxPoints([string]$gpxText) {
  [xml]$xml = $gpxText

  # Namespace-agnostic: GPX 1.0, 1.1, or missing namespace
  $trkpts = $xml.SelectNodes("//*[local-name()='trkpt']")
  $pts = New-Object System.Collections.Generic.List[object]
  $i = 0

  foreach ($p in $trkpts) {
    $lat = [double]$p.GetAttribute("lat")
    $lon = [double]$p.GetAttribute("lon")

    $eleNode  = $p.SelectSingleNode("*[local-name()='ele']")
    $timeNode = $p.SelectSingleNode("*[local-name()='time']")
    $dopNode  = $p.SelectSingleNode("*[local-name()='hdop']")

    $ele = $null
    if ($eleNode -and $eleNode.InnerText) { $ele = [double]$eleNode.InnerText }

    $dop = $null
    if ($dopNode -and $dopNode.InnerText) {
      $tmp = 0.0
      if ([double]::TryParse($dopNode.InnerText, [ref]$tmp)) { $dop = $tmp }
    }

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

    $pts.Add([pscustomobject]@{ idx=$i; lat=$lat; lon=$lon; ele=$ele; dop=$dop; time=$t; rawTime=$raw }) | Out-Null
    $i++
  }

  return ,$pts.ToArray()
}

function Analyze-GpxQuality(
  [object[]]$pts,
  [double]$maxPlausibleSpeedMps,
  [int]$stableWindow,
  [double]$stableMaxSpeedMps,
  [double]$stableMaxJumpM,
  [int]$maxSuspectSamplesToReport = 50
) {
  $n = $pts.Length
  if ($n -lt 2) {
    return [pscustomobject]@{
      points = $n
      timeBackwardsCount = 0
      timeDuplicateCount = 0
      speedSpikeCount = 0
      maxImpliedSpeedMps = 0
      firstStableIndex = $null
      suggestedDiscardSeconds = 0
      suspectSamples = @()
    }
  }

  $timeBack = 0
  $timeDup  = 0
  $speedSpikes = 0
  $maxSpeed = 0.0
  $suspects = New-Object System.Collections.Generic.List[object]

  for ($i=1; $i -lt $n; $i++) {
    $p0 = $pts[$i-1]
    $p1 = $pts[$i]

    $dt = 0.0
    if ($p0.time -and $p1.time) {
      $dt = ($p1.time - $p0.time).TotalSeconds
      if ($dt -lt 0) { $timeBack++ }
      elseif ($dt -eq 0) { $timeDup++ }
    }

    $d = HaversineMeters $p0.lat $p0.lon $p1.lat $p1.lon
    $spd = 0.0
    if ($dt -gt 0) { $spd = $d / $dt }
    if ($spd -gt $maxSpeed) { $maxSpeed = $spd }

    $isSpike = ($dt -gt 0) -and ($spd -gt $maxPlausibleSpeedMps)
    if ($isSpike) {
      $speedSpikes++
      if ($suspects.Count -lt $maxSuspectSamplesToReport) {
        $suspects.Add([pscustomobject]@{
          idx = $i
          time = $p1.rawTime
          lat = $p1.lat
          lon = $p1.lon
          jump_m = [Math]::Round($d,2)
          dt_s = [Math]::Round($dt,3)
          implied_speed_mps = [Math]::Round($spd,3)
          reason = "implied_speed_spike"
        }) | Out-Null
      }
    }
  }

  # First stable index: first window with no big jumps, no high speeds, and monotonic time
  $firstStable = $null
  for ($start=1; $start -le ($n - $stableWindow); $start++) {
    $ok = $true
    for ($j=$start; $j -lt ($start + $stableWindow); $j++) {
      $p0 = $pts[$j-1]
      $p1 = $pts[$j]

      $dt = 0.0
      if ($p0.time -and $p1.time) { $dt = ($p1.time - $p0.time).TotalSeconds }
      $d  = HaversineMeters $p0.lat $p0.lon $p1.lat $p1.lon
      $spd = 0.0
      if ($dt -gt 0) { $spd = $d / $dt }

      if ($dt -lt 0 -or $d -gt $stableMaxJumpM -or $spd -gt $stableMaxSpeedMps) { $ok = $false; break }
    }
    if ($ok) { $firstStable = $start; break }
  }

  $discardSeconds = 0
  if ($firstStable -ne $null -and $pts[0].time -and $pts[$firstStable].time) {
    $discardSeconds = [int][Math]::Max(0, ($pts[$firstStable].time - $pts[0].time).TotalSeconds)
  }

  return [pscustomobject]@{
    points = $n
    timeBackwardsCount = $timeBack
    timeDuplicateCount = $timeDup
    speedSpikeCount = $speedSpikes
    maxImpliedSpeedMps = [Math]::Round($maxSpeed, 3)
    firstStableIndex = $firstStable
    suggestedDiscardSeconds = $discardSeconds
    suspectSamples = $suspects.ToArray()
  }
}

function Trim-GpxByPointIndex([string]$gpxText, [int]$startIdx) {
  if ($startIdx -le 0) { return $gpxText }

  [xml]$xml = $gpxText
  $trkpts = $xml.SelectNodes("//*[local-name()='trkpt']")
  $n = $trkpts.Count
  if ($n -eq 0 -or $startIdx -ge $n) { return "" }

  for ($i=0; $i -lt $startIdx; $i++) {
    $node = $trkpts.Item($i)
    $null = $node.ParentNode.RemoveChild($node)
  }

  return $xml.OuterXml
}

function Get-CleanKeepSet([object[]]$pts, [double]$maxDop, [double]$maxSpeedMps) {
  # Returns the list of point indices to KEEP after dropping:
  #  - no-fix sentinels at exactly (0,0)
  #  - points with no timestamp (a GoPro artifact: the first trkpt of a continuation
  #    chapter has lat/lon but no <time> and a stale position; keeping it as the
  #    anchor would wrongly reject the whole chapter)
  #  - points whose GPSDOP exceeds $maxDop (when DOP is available)
  #  - points implying an impossible speed from the last accepted point (only when
  #    time actually advances; duplicate/backwards timestamps are left to the DOP filter)
  $keep = New-Object System.Collections.Generic.List[int]
  $last = $null
  for ($i = 0; $i -lt $pts.Length; $i++) {
    $p = $pts[$i]

    if ($p.lat -eq 0.0 -and $p.lon -eq 0.0) { continue }
    if ($p.time -eq $null) { continue }
    if (($p.dop -ne $null) -and ($p.dop -gt $maxDop)) { continue }

    if ($last -ne $null -and $last.time -and $p.time) {
      $dt = ($p.time - $last.time).TotalSeconds
      if ($dt -gt 0) {
        $d = HaversineMeters $last.lat $last.lon $p.lat $p.lon
        if (($d / $dt) -gt $maxSpeedMps) { continue }
      }
    }

    $keep.Add($i) | Out-Null
    $last = $p
  }
  return $keep.ToArray()
}

function Build-CleanGpx([string]$gpxText, [int[]]$keepIndices) {
  # Rebuilds the GPX keeping only the given trkpt indices and stripping the
  # temporary <hdop> children, so the written file is clean standard GPX.
  [xml]$xml = $gpxText
  $trkpts = $xml.SelectNodes("//*[local-name()='trkpt']")

  $keepLookup = @{}
  foreach ($k in $keepIndices) { $keepLookup[[int]$k] = $true }

  for ($i = 0; $i -lt $trkpts.Count; $i++) {
    $node = $trkpts.Item($i)
    if ($keepLookup.ContainsKey($i)) {
      $hd = $node.SelectSingleNode("*[local-name()='hdop']")
      if ($hd) { $null = $node.RemoveChild($hd) }
    } else {
      $null = $node.ParentNode.RemoveChild($node)
    }
  }

  return $xml.OuterXml
}

# --- main ---
$outRoot = Resolve-OutDir $Path $OutDir
Ensure-Dir $outRoot

$toolsDir = Join-Path $outRoot ".tools"
$exiftool = Ensure-ExifTool $toolsDir
$gpxFmt   = Ensure-GpxFmt $toolsDir

$files = @(Get-VideoFiles $Path $Recurse)
if ($files.Length -eq 0) { throw "No .mp4/.mov files found under: $Path" }

Write-Host ("Found {0} video file(s) under: {1}" -f $files.Length, $Path)

$results = New-Object System.Collections.Generic.List[object]
$totalFiles = $files.Length
$fileIndex = 0

foreach ($f in $files) {
  $fileIndex++
  $pct = [int][Math]::Floor(($fileIndex / $totalFiles) * 100)
  $fileName = [IO.Path]::GetFileName($f)
  Write-Progress -Activity "Extracting GoPro telemetry" `
    -Status ("[{0}/{1}] {2}" -f $fileIndex, $totalFiles, $fileName) -PercentComplete $pct

  $r = [ordered]@{
    file          = $f
    hadDataStream = $false
    points        = 0
    pointsWritten = 0
    gpxWritten    = $false
    gpxPath       = $null
    quality       = $null
    clean         = $null
    trim          = $null
    error         = $null
  }

  try {
    $r.hadDataStream = Has-DataStream $f

    $x = $null
    if ($r.hadDataStream) {
      $x = Extract-Gpx $exiftool $gpxFmt $f
      $r.points = [int]$x.points
    }

    if ($r.points -gt 0) {
      $pts = Parse-GpxPoints $x.gpxText
      # Quality is computed on the RAW track so the report reflects what the camera produced.
      $r.quality = Analyze-GpxQuality $pts $MaxPlausibleSpeedMps $StableWindowPoints $StableMaxSpeedMps $StableMaxJumpM

      $gpxToWrite = $x.gpxText
      $cleanPts   = $pts
      $writtenPts = $pts.Length

      # --- GPS cleaning (default on): drop (0,0) no-fix, high-DOP, and impossible jumps ---
      if (-not $NoClean) {
        $keep = @(Get-CleanKeepSet $pts $MaxDop $MaxPlausibleSpeedMps)
        if ($keep.Length -lt $pts.Length) {
          $cleaned = Build-CleanGpx $x.gpxText $keep
          $cleanPts = Parse-GpxPoints $cleaned
          $gpxToWrite = $cleaned
          $writtenPts = $cleanPts.Length
          $r.clean = [pscustomobject]@{
            applied       = $true
            keptPoints    = $writtenPts
            removedPoints = ($pts.Length - $writtenPts)
            maxDop        = $MaxDop
            maxSpeedMps   = $MaxPlausibleSpeedMps
          }
        }
      }

      # --- Optional warmup trim, applied AFTER cleaning ---
      if ($TrimWarmup -and $writtenPts -gt 0) {
        $q2 = Analyze-GpxQuality $cleanPts $MaxPlausibleSpeedMps $StableWindowPoints $StableMaxSpeedMps $StableMaxJumpM
        if ($q2.firstStableIndex -ne $null -and $q2.firstStableIndex -gt 0) {
          $trimmed = Trim-GpxByPointIndex $gpxToWrite $q2.firstStableIndex
          if ($trimmed -and $trimmed.Length -gt 0) {
            $trimPts = Parse-GpxPoints $trimmed
            if ($trimPts.Length -gt 0) {
              $beforeTrim = $writtenPts
              $gpxToWrite = $trimmed
              $writtenPts = $trimPts.Length
              $r.trim = [pscustomobject]@{
                applied = $true
                startIndex = $q2.firstStableIndex
                discardedPoints = ($beforeTrim - $writtenPts)
                writtenPoints = $writtenPts
                suggestedDiscardSeconds = $q2.suggestedDiscardSeconds
              }
            }
          }
        }
      }

      if ($writtenPts -gt 0) {
        $base = [IO.Path]::GetFileNameWithoutExtension($f)
        $gpxOut = Join-Path $outRoot ($base + ".gpx")
        [IO.File]::WriteAllText($gpxOut, $gpxToWrite, [Text.Encoding]::UTF8)
        $r.gpxWritten = $true
        $r.gpxPath = $gpxOut
        $r.pointsWritten = $writtenPts
      }
    } else {
      # Keep quality object present even if no points (useful for consistent JSON schema)
      $r.quality = Analyze-GpxQuality @() $MaxPlausibleSpeedMps $StableWindowPoints $StableMaxSpeedMps $StableMaxJumpM
      $r.pointsWritten = 0
    }

  } catch {
    $r.error = $_.Exception.Message
  }

  if ($r.gpxWritten) {
    $removedNote = ""
    if ($r.clean -and $r.clean.removedPoints -gt 0) { $removedNote = (" (cleaned {0} bad)" -f $r.clean.removedPoints) }
    Write-Host ("  [{0}/{1}] {2,3}% | {3} -> {4} pts{5}" -f $fileIndex, $totalFiles, $pct, $fileName, $r.pointsWritten, $removedNote) -ForegroundColor Green
  } elseif ($r.error -and ($r.error -notmatch '^Warning')) {
    Write-Host ("  [{0}/{1}] {2,3}% | {3} -> ERROR: {4}" -f $fileIndex, $totalFiles, $pct, $fileName, $r.error) -ForegroundColor Red
  } else {
    Write-Host ("  [{0}/{1}] {2,3}% | {3} -> no telemetry" -f $fileIndex, $totalFiles, $pct, $fileName) -ForegroundColor DarkYellow
  }

  $results.Add([pscustomobject]$r) | Out-Null
}

Write-Progress -Activity "Extracting GoPro telemetry" -Completed

$summary = [ordered]@{
  generatedAtUtc  = (Get-Date).ToUniversalTime().ToString("o")
  inputPath       = (Resolve-Path -LiteralPath $Path).Path
  outDir          = $outRoot
  totalFiles      = $results.Count
  filesWithGpx    = (@($results | Where-Object { $_.gpxWritten })).Count
  filesZeroPoints = (@($results | Where-Object { $_.points -eq 0 })).Count
  items           = $results
}

$resultsPath = Join-Path $outRoot "telemetry_results.json"
$summary | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $resultsPath

Write-Host ("Wrote results: " + $resultsPath)
Write-Host ("GPX files: {0}/{1}" -f $summary.filesWithGpx, $summary.totalFiles)
