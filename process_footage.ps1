<#
GoPro GPX  --  process_footage.ps1 (main entry point)

Orchestrator: GoPro date-folder -> per-video GPX -> merged GPX (per-day)

Input layout:
  <InRoot>\
    01-08-2026\
      GX010569.MP4
      GX020569.MP4
      ...
    07-31-2025\
      ...

Behavior (per date folder):
  -) With -SkipExisting, a date that already has a merged route in gpx_day\ is skipped
     entirely (resume a run / process only new dates).
  0) Unless -KeepExisting is set, wipes that date's previous output (.gpx and
     *_results.json in gpx_raw\ and gpx_day\) first, so re-runs leave no stale files.
  1) Runs gopro_telemetry.ps1 on the date folder to extract per-video GPX files into:
       <OutRoot>\<date>\gpx_raw\
  2) Merges the day's tracks into one GPX PER RIDE using merge_gpxs.ps1, writing to:
       <OutRoot>\<date>\gpx_day\
     A "ride" is a run of footage with no large gap; a new ride starts when the
     time gap exceeds -MaxGapSeconds OR the distance gap exceeds -MaxGapMeters.
     GoPro splits one recording into ~4GB chapters (GX01.., GX02.., same number) with
     no gap, so those stay in one ride; separate recordings taken hours apart become
     separate rides (e.g. a date with morning/afternoon/evening rides -> 3 GPX files).
  3) Writes orchestrator_results.json summarizing all days processed.

Requirements:
  - ffprobe/ffmpeg available (telemetry script dependency)
  - PowerShell 5.1 compatible

Examples:
  # Process every date folder under the root
  .\process_footage.ps1 -InRoot "D:\GoPro" -OutRoot "D:\GPX_OUT"

  # Process ONLY a single date folder (same command, scoped to one day)
  .\process_footage.ps1 -InRoot "D:\GoPro" -OutRoot "D:\GPX_OUT" -Date "01-08-2026"

  # Override script locations if they aren't next to this orchestrator
  .\process_footage.ps1 -InRoot "D:\GoPro" -OutRoot "D:\GPX_OUT" `
    -TelemetryScript "C:\scripts\gopro_telemetry.ps1" `
    -MergeScript "C:\scripts\merge_gpxs.ps1"
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true, Position=0)]
  [string] $InRoot,

  [Parameter(Mandatory=$true)]
  [string] $OutRoot,

  # Optional: process ONLY this single date folder (e.g. "01-08-2026").
  # Leave empty to process every MM-DD-YYYY folder under -InRoot (default).
  [string] $Date = "",

  # Paths to the two scripts (default: same directory as this orchestrator script)
  [string] $TelemetryScript = "",
  [string] $MergeScript = "",

  # If your date folders can contain subfolders with videos, enable this
  [switch] $RecurseVideos,

  # Ride detection (passed to merge_gpxs.ps1). A new ride starts when the time gap
  # between consecutive tracks exceeds -MaxGapSeconds (always), OR you paused longer
  # than -MinGapSeconds AND resumed more than -MaxGapMeters from where you stopped.
  # This keeps a mid-ride stop (resumed in place) as one ride, while splitting
  # genuinely separate rides. Chapters of one recording have ~no gap and stay together.
  [int] $MaxGapSeconds = 3600,    # 1 hour
  [int] $MinGapSeconds = 120,     # 2 minutes
  [double] $MaxGapMeters = 500.0, # 500 m

  # By default, each date's previous output (the .gpx and *_results.json files in its
  # gpx_raw\ and gpx_day\) is wiped before re-processing, so re-runs leave no stale or
  # duplicate files. Use -KeepExisting to leave old output in place instead (files with
  # the same name are still overwritten). The ExifTool cache (.tools\) is never removed.
  [switch] $KeepExisting,

  # Skip any date that already has a merged route in its gpx_day\ folder, moving on to
  # the next date. Use this to resume a large run and process only NEW dates, without
  # redoing days that are already done. (-KeepExisting controls cleanup of dates that
  # ARE processed; -SkipExisting decides whether a date is processed at all.)
  [switch] $SkipExisting,

  # Recommended: trims early GPS warmup junk within each MP4's GPX extraction
  [switch] $TrimWarmup = $true
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
}

function FullPath([string]$p) {
  if (-not [System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath((Join-Path $PWD.Path $p)) }
  return [System.IO.Path]::GetFullPath($p)
}

function Is-DateFolderName([string]$name) {
  # Accept "MM-DD-YYYY" (your examples). If you also have "M-D-YYYY", loosen this regex.
  return $name -match '^(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])-(19|20)\d\d$'
}

function Get-DateFolders([string]$root) {
  $d = Resolve-Path -LiteralPath $root
  return @(Get-ChildItem -LiteralPath $d.Path -Directory |
           Where-Object { Is-DateFolderName $_.Name } |
           Sort-Object Name |
           ForEach-Object { $_.FullName })
}

function Get-GpxFiles([string]$dir) {
  if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return @() }
  return @(Get-ChildItem -LiteralPath $dir -File -Filter "*.gpx" | ForEach-Object { $_.FullName })
}

# --- main ---
$inRoot = (Resolve-Path -LiteralPath $InRoot).Path
$outRoot = FullPath $OutRoot
Ensure-Dir $outRoot

# Default script locations: same directory as this orchestrator
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $TelemetryScript -or $TelemetryScript.Trim().Length -eq 0) {
  $TelemetryScript = Join-Path $here "gopro_telemetry.ps1"
}
if (-not $MergeScript -or $MergeScript.Trim().Length -eq 0) {
  $MergeScript = Join-Path $here "merge_gpxs.ps1"
}

$TelemetryScript = FullPath $TelemetryScript
$MergeScript     = FullPath $MergeScript

if (-not (Test-Path -LiteralPath $TelemetryScript -PathType Leaf)) { throw "TelemetryScript not found: $TelemetryScript" }
if (-not (Test-Path -LiteralPath $MergeScript     -PathType Leaf)) { throw "MergeScript not found: $MergeScript" }

$dateFolders = @(Get-DateFolders $inRoot)
if ($dateFolders.Length -eq 0) { throw "No date folders (MM-DD-YYYY) found under: $inRoot" }

# Optional: narrow down to a single date folder (-Date "MM-DD-YYYY")
if ($Date -and $Date.Trim().Length -gt 0) {
  if (-not (Is-DateFolderName $Date)) { throw "-Date must be in MM-DD-YYYY format (e.g. 01-08-2026), got: $Date" }
  $dateFolders = @($dateFolders | Where-Object { (Split-Path -Leaf $_) -eq $Date })
  if ($dateFolders.Length -eq 0) { throw "Date folder '$Date' not found under: $inRoot" }
}

$items = New-Object System.Collections.Generic.List[object]
$dayIndex = 0
$totalDays = $dateFolders.Length

foreach ($dayDir in $dateFolders) {
  $dayIndex++
  $dayName = Split-Path -Leaf $dayDir
  $dayPct = [int][Math]::Floor(($dayIndex / $totalDays) * 100)
  Write-Host ""
  Write-Host ("=== Day {0}/{1} ({2,3}%): {3} ===" -f $dayIndex, $totalDays, $dayPct, $dayName) -ForegroundColor Cyan
  Write-Progress -Activity "Processing GoPro footage by day" `
    -Status ("[{0}/{1}] {2}" -f $dayIndex, $totalDays, $dayName) -PercentComplete $dayPct
  $dayOut  = Join-Path $outRoot $dayName
  $rawOut  = Join-Path $dayOut "gpx_raw"
  $dayGpxOut = Join-Path $dayOut "gpx_day"

  # -SkipExisting: if this date already has a merged route, skip it and move on.
  if ($SkipExisting -and (Test-Path -LiteralPath $dayGpxOut)) {
    $existingMerged = @(Get-ChildItem -LiteralPath $dayGpxOut -File -Filter "*.gpx" -ErrorAction SilentlyContinue)
    if ($existingMerged.Count -gt 0) {
      Write-Host ("  {0}: already processed ({1} ride(s)) -- skipping" -f $dayName, $existingMerged.Count) -ForegroundColor DarkGray
      $items.Add([pscustomobject]@{
        dayFolder = $dayDir
        outFolder = $dayOut
        rawGpxFolder = $rawOut
        dayGpxFolder = $dayGpxOut
        telemetryResultsJson = $null
        mergeResultsJson = $null
        rawGpxCount = 0
        mergedGpxCount = $existingMerged.Count
        mergedGpxFiles = @($existingMerged | ForEach-Object { $_.FullName })
        status = "skipped"
        error = $null
      }) | Out-Null
      continue
    }
  }

  Ensure-Dir $dayOut
  Ensure-Dir $rawOut
  Ensure-Dir $dayGpxOut

  $entry = [ordered]@{
    dayFolder = $dayDir
    outFolder = $dayOut
    rawGpxFolder = $rawOut
    dayGpxFolder = $dayGpxOut
    telemetryResultsJson = $null
    mergeResultsJson = $null
    rawGpxCount = 0
    mergedGpxCount = 0
    mergedGpxFiles = @()
    status = "ok"
    error = $null
  }

  try {
    # 0) Unless -KeepExisting, wipe this date's previous output so re-runs are clean
    #    (clears stale per-video GPX and old merged_route_* files; keeps the .tools cache)
    if (-not $KeepExisting) {
      Remove-Item -Path (Join-Path $rawOut "*.gpx"), (Join-Path $rawOut "telemetry_results.json") -Force -ErrorAction SilentlyContinue
      Remove-Item -Path (Join-Path $dayGpxOut "*.gpx"), (Join-Path $dayGpxOut "merge_results.json") -Force -ErrorAction SilentlyContinue
    }

    # 1) Extract per-video GPX into rawOut
    $teleArgs = @(
      "-Path", $dayDir,
      "-OutDir", $rawOut
    )
    if ($RecurseVideos) { $teleArgs += "-Recurse" }
    if ($TrimWarmup)   { $teleArgs += "-TrimWarmup" }

    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $TelemetryScript @teleArgs

    $telemetryJson = Join-Path $rawOut "telemetry_results.json"
    if (Test-Path -LiteralPath $telemetryJson) { $entry.telemetryResultsJson = $telemetryJson }

    $rawGpx = @(Get-GpxFiles $rawOut)
    $entry.rawGpxCount = $rawGpx.Length

    # 2) Merge the day's tracks into one GPX per ride (sessions split on gaps)
    if ($rawGpx.Length -gt 0) {
      $mergeArgs = @(
        "-InDir", $rawOut,
        "-OutDir", $dayGpxOut,
        "-MaxGapSeconds", "$MaxGapSeconds",
        "-MinGapSeconds", "$MinGapSeconds",
        "-MaxGapMeters",  "$MaxGapMeters"
      )

      & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $MergeScript @mergeArgs

      $mergeJson = Join-Path $dayGpxOut "merge_results.json"
      if (Test-Path -LiteralPath $mergeJson) { $entry.mergeResultsJson = $mergeJson }

      $merged = @(Get-ChildItem -LiteralPath $dayGpxOut -File -Filter "*.gpx" |
                  Where-Object { $_.Name -ne "merge_results.json" } |
                  ForEach-Object { $_.FullName })

      $entry.mergedGpxCount = $merged.Length
      $entry.mergedGpxFiles = $merged

      Write-Host ("  {0}: {1} ride(s) from {2} GPX file(s)" -f $dayName, $merged.Length, $rawGpx.Length) -ForegroundColor Green
    } else {
      $entry.status = "no_gpx"
      Write-Host ("  {0}: no GPS telemetry found" -f $dayName) -ForegroundColor DarkYellow
    }

  } catch {
    $entry.status = "error"
    $entry.error = $_.Exception.Message
  }

  $items.Add([pscustomobject]$entry) | Out-Null
}

Write-Progress -Activity "Processing GoPro footage by day" -Completed

$report = [ordered]@{
  generatedAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  inRoot = $inRoot
  outRoot = $outRoot
  telemetryScript = $TelemetryScript
  mergeScript = $MergeScript
  daysFound = $dateFolders.Length
  daysProcessed = $items.Count
  daysWithMergedGpx = (@($items | Where-Object { $_.mergedGpxCount -gt 0 })).Count
  items = $items
}

$reportPath = Join-Path $outRoot "orchestrator_results.json"
$report | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $reportPath

Write-Host ("Wrote orchestrator results: " + $reportPath)
Write-Host ("Days processed: {0}, days with merged GPX: {1}" -f $report.daysProcessed, $report.daysWithMergedGpx)
