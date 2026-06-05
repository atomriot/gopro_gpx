# GoPro GPX

**GoPro GPX** is a set of Windows PowerShell scripts that extract GPS telemetry from
GoPro video files and turn it into clean GPX track files — one per ride — organized
by date.

## TL;DR — just run this

**[`process_footage.ps1`](process_footage.ps1) is the main entry point.** Point it
at your footage and an output folder and it does everything: extracts GPS from every
video, cleans out bad GPS points, and groups the footage into one GPX route per ride.

```powershell
.\process_footage.ps1 -InRoot "<path-to-your-footage>" -OutRoot .\gpxs
```

That's the whole workflow for normal use. The output folders are created for you if
they don't exist. Read [Requirements](#requirements) first, then
[Main usage](#main-usage-process_footageps1).

## The scripts

| Script | Role |
| --- | --- |
| [`process_footage.ps1`](process_footage.ps1) | **Main entry point.** Walks a root folder of `MM-DD-YYYY` date folders and, for each day, runs the extractor on every video and merges the results into one GPX per ride. This is the one you normally run. |
| [`gopro_telemetry.ps1`](gopro_telemetry.ps1) | *Supplementary.* Extracts GPS from `.MP4`/`.MOV` files into per-video `.gpx`. Called automatically by `process_footage.ps1`; run it directly only to process a single file/folder. |
| [`merge_gpxs.ps1`](merge_gpxs.ps1) | *Supplementary.* Merges a folder of `.gpx` files into one route per ride. Also called automatically by `process_footage.ps1`. |
| [`gpx_accuracy_report.ps1`](gpx_accuracy_report.ps1) | *Diagnostic (optional).* Inspects one video's GPS quality and writes an HTML report (precision/speed charts, map, % usable). Run ad hoc when a ride looks wrong. See [its README](gpx_accuracy_report_README.md). |

The data flows like this:

```
                          process_footage.ps1  (you run this)
                                   |
        +--------------------------+--------------------------+
        v                                                     v
GoPro videos --gopro_telemetry.ps1--> per-video .gpx --merge_gpxs.ps1--> one .gpx per ride
```

## Requirements

- **Windows** with **PowerShell 5.1** or later (scripts are PS 5.1 compatible).
- **ffprobe** (part of [FFmpeg](https://ffmpeg.org/download.html)) available on your `PATH`.
  Used to detect whether a video contains a telemetry data stream.
- **ExifTool** — used to extract the GPS track. You do **not** have to install it
  manually: `gopro_telemetry.ps1` will auto-download a portable `exiftool.exe`
  into `<OutDir>\.tools` on first run if it isn't already on your `PATH`.
- **Internet access on first run**, so the script can download ExifTool (cached
  under `<OutDir>\.tools` afterward). The GPX format template is generated locally,
  not downloaded.

> Check that ffprobe is available:
> ```powershell
> ffprobe -version
> ```
> If this errors, install FFmpeg and add its `bin` folder to your `PATH`.

## Setup

1. Clone or copy this folder to your machine.
2. Confirm `ffprobe` works (see above).
3. Allow local scripts to run. Either set the policy for your user once:
   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```
   …or bypass it per-invocation by launching each script with
   `powershell -ExecutionPolicy Bypass -File ...` (the orchestrator already does
   this internally when it calls the other two scripts).

Run all commands below from the project folder (the folder that contains these
scripts and this README).

## Main usage: process_footage.ps1

This is the script you normally run — it does the whole pipeline. Point `-InRoot` at
wherever your footage lives (often an SD card or external drive) and `-OutRoot` at
where you want the results; `.\gpxs` keeps the output inside this project folder.
**Output folders are created automatically if they don't exist** — only the input
folder needs to exist already.

```powershell
# Process every date folder under the root
.\process_footage.ps1 -InRoot "<path-to-your-footage>" -OutRoot .\gpxs

# Process ONLY one date — same command, scoped to a single day (great for testing)
.\process_footage.ps1 -InRoot "<path-to-your-footage>" -OutRoot .\gpxs -Date "01-08-2026"
```

For each date folder it extracts GPS from every video, cleans out bad GPS points
(see [GPS data cleaning](#gps-data-cleaning-on-by-default)), and merges the results
into one GPX route per ride.

**Re-runs are clean by default.** Before processing a date, that date's previous
output (the `.gpx` and `*_results.json` files in its `gpx_raw\` and `gpx_day\`) is
wiped, so re-running never leaves stale or duplicate route files behind. Only dates
included in the current run are touched, and the ExifTool cache (`.tools\`) is kept.

Two switches control re-run behavior — they answer *different* questions:

| Switch | Question | Effect |
| --- | --- | --- |
| *(default)* | — | Wipe the date's old output, then re-process it. |
| `-KeepExisting` | *Clean before processing, or not?* | Still re-processes the date, but does **not** wipe first (same-named files are overwritten; renamed ones may pile up). |
| `-SkipExisting` | *Process this date at all?* | If the date already has a merged route in `gpx_day\`, **skip it entirely** and move to the next date — nothing is re-extracted. |

Use **`-SkipExisting`** to resume a big run and only do the new dates (fast — finished
days are skipped without re-scanning). Use **`-KeepExisting`** when you do want to
re-process a date but keep whatever's already in its folders. They're independent: with
both set, an already-done date is skipped; a not-yet-done date is processed without a
pre-wipe.

**Expected input layout** — footage organized into `MM-DD-YYYY` date folders:

```
<InRoot>\
  01-08-2026\
    GX010569.MP4
    GX020569.MP4
  07-31-2025\
    ...
```

> Only folders named `MM-DD-YYYY` (e.g. `01-08-2026`) are processed; others are ignored.

**Output layout (under `-OutRoot`):**

```
<OutRoot>\
  01-08-2026\
    gpx_raw\   <- per-video .gpx + telemetry_results.json   (intermediate files)
    gpx_day\   <- one merged_route_*.gpx PER RIDE + merge_results.json   (the finished routes)
  orchestrator_results.json   <- summary of all days processed
```

The files in each `gpx_day\` are the finished routes — one per ride — and are the
deliverable output of this pipeline.

### Multiple rides per day

A single date can contain several separate rides. GoPro splits one continuous
recording into ~4 GB chapters (`GX01..`, `GX02..` with the *same* trailing number)
that have no gap between them, while a *new* recording (different trailing number)
started later in the day is a separate ride.

The orchestrator detects this automatically (same logic as `merge_gpxs.ps1`, described
below): the chapters of a single recording (same file number) are always kept together
as one ride — even if GPS cleaning left a gap at a chapter boundary; a **stop during a
ride** (you resume in place) stays one ride; and a **separate ride** (a long time gap,
or starting a *new* recording somewhere far away) becomes its own `merged_route_*.gpx`.
So a day with a morning and an evening ride produces two route files in that date's
`gpx_day\` — even if one of them was a multi-chapter recording with a mid-ride stop.
Tunable via `-MaxGapSeconds` / `-MinGapSeconds` / `-MaxGapMeters`.

**Parameters:**

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-InRoot` | *(required)* | Root folder containing `MM-DD-YYYY` date folders (must exist). |
| `-OutRoot` | *(required)* | Where all output is written (created if missing). |
| `-Date` | all folders | Process only this single `MM-DD-YYYY` folder (e.g. `01-08-2026`). |
| `-TelemetryScript` | sibling `gopro_telemetry.ps1` | Override path to the extractor. |
| `-MergeScript` | sibling `merge_gpxs.ps1` | Override path to the merger. |
| `-RecurseVideos` | off | Search subfolders inside each date folder for videos. |
| `-KeepExisting` | off (re-runs are clean) | Re-process the date but don't wipe its previous output first. |
| `-SkipExisting` | off | Skip any date that already has a merged route in `gpx_day\` (process only new dates). |
| `-MaxGapSeconds` | `3600` | Time gap (1 h) that always starts a new ride. |
| `-MinGapSeconds` | `120` | Minimum pause (2 min) before a "moved away" split applies. |
| `-MaxGapMeters` | `500` | Resume-distance after a pause that starts a new ride. |
| `-TrimWarmup` | on | Trim GPS warmup noise during extraction. |

## Supplementary scripts

You normally **don't** run these directly — `process_footage.ps1` calls both for you.
Run them standalone only to process a single file/folder, or to re-merge existing
GPX files without re-extracting.

### gopro_telemetry.ps1 — extract GPX from a video or folder

```powershell
# Single file
.\gopro_telemetry.ps1 -Path .\GX010569.MP4 -OutDir .\gpx_out

# A whole folder of videos
.\gopro_telemetry.ps1 -Path .\01-08-2026\ -OutDir .\gpx_out

# Trim early GPS "warmup" noise from the start of each track
.\gopro_telemetry.ps1 -Path .\01-08-2026\ -OutDir .\gpx_out -TrimWarmup
```

**Outputs (in `-OutDir`):**
- One `.gpx` per video that actually contained usable GPS points.
- `telemetry_results.json` — a report for every file processed (including those
  with zero points), with quality heuristics: speed spikes, backwards/duplicate
  timestamps, the detected "first stable" point, and (under `clean`) how many bad
  points were removed.
- `.tools\` — cached ExifTool and the generated `gpx_dop.fmt` template (created
  automatically; safe to delete, it is regenerated/re-downloaded).

#### GPS data cleaning (on by default)

GoPro GPS data often contains garbage: an initial run of `(0, 0)` "no fix" points
before the receiver locks, plus scattered points with a bad fix that can land
thousands of km away. Left in, these draw routes that span continents and report
impossible distances.

To prevent this, the extractor reads GoPro's own per-point **GPSDOP** (dilution of
precision) alongside each coordinate and drops a point when:

- it sits at exactly `(0, 0)` (no GPS fix), **or**
- it has no timestamp (a GoPro artifact on the first point of a continuation
  chapter), **or**
- its `GPSDOP` exceeds `-MaxDop` (default `10`; `≤5` is good, `>50` is junk), **or**
- it implies an impossible speed from the last kept point (faster than
  `-MaxPlausibleSpeedMps`, default 60 m/s).

This typically removes a few hundred junk points and leaves a clean, local track.
Pass `-NoClean` to disable it and write the raw track, or tune `-MaxDop` /
`-MaxPlausibleSpeedMps` if cleaning is too aggressive or too lax for your footage.

> **Re-processing older output:** GPX files produced *before* this cleaning existed
> still contain junk points (and older runs may have dropped some multi-GB chapters
> entirely). Re-run the pipeline on those date folders to regenerate clean tracks
> (use the orchestrator's `-Date` option).

**Parameters:**

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Path` | *(required)* | A video file, or a folder of videos. |
| `-OutDir` | input folder | Where to write `.gpx` files and the JSON report (created if missing). |
| `-Recurse` | off | Also search subfolders for videos. |
| `-NoClean` | off (cleaning ON) | Write the raw, unfiltered track instead of cleaning it. |
| `-MaxDop` | `10` | Max GoPro GPSDOP to keep. Lower = stricter (`≤5` is good, `>50` is junk). |
| `-TrimWarmup` | off | Additionally drop early unstable GPS points from the start. |
| `-MaxPlausibleSpeedMps` | `60` | Jumps implying a higher speed (m/s) are dropped/flagged. |
| `-StableWindowPoints` | `10` | Window size used to detect the first stable GPS run. |
| `-StableMaxSpeedMps` | `5` | Max implied speed (m/s) allowed inside a "stable" window. |
| `-StableMaxJumpM` | `25` | Max per-step jump (m) allowed inside a "stable" window. |

### merge_gpxs.ps1 — merge GPX files into routes

```powershell
.\merge_gpxs.ps1 -InDir .\gpx_out -OutDir .\merged
```

It sorts the GPX files by their first timestamp and groups them into rides:

1. **Chapters of the same GoPro recording are always kept together.** GoPro splits one
   continuous recording into ~4 GB chapters that share the same file number
   (`GX01`**`0487`**, `GX02`**`0487`**, `GX03`**`0487`** …). These are seamless, so they
   are never split — even if GPS cleaning left a gap at a chapter boundary (a dropout
   mid-ride can otherwise look like a "paused and moved away").
2. **Between different recordings**, a new session (ride) starts when:
   - the next track starts before the previous ends (out of order), **or**
   - the time gap exceeds `-MaxGapSeconds` (always — a long gap is a new ride), **or**
   - you paused longer than `-MinGapSeconds` **and** resumed more than `-MaxGapMeters`
     from where you stopped.

So a 25-minute coffee stop where you resume in place stays one ride, the afternoon and
evening rides (hours apart) become two, and the chapters of a single long recording
always stay as one ride.

**Outputs (in `-OutDir`):**
- `merged_route_YYYYMMDD_HHMMSS_sessionNN.gpx` — one file per detected ride.
- `merge_results.json` — grouping details, per-session stats, gaps, and any files
  that were skipped (no points / no timestamps).

**Parameters:**

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-InDir` | *(required)* | Folder of `.gpx` files to merge (must exist). |
| `-OutDir` | input folder | Where to write merged routes and the JSON report (created if missing). |
| `-MaxGapSeconds` | `3600` (1 h) | Time gap that **always** starts a new ride. |
| `-MinGapSeconds` | `120` (2 min) | Minimum pause before a "moved away" split applies. |
| `-MaxGapMeters` | `500` | Resume-distance (after a pause) that starts a new ride. |
| `-Recurse` | off | Also search subfolders for `.gpx` files. |

> **Tip:** To force everything into a single merged route, use a very large
> `-MaxGapSeconds`, e.g. `-MaxGapSeconds 86400`.

## Output folders in this project

This folder already contains example output from prior runs:

- `gpx_out\` — per-video GPX + `telemetry_results.json` from a single-folder run.
- `merged\` — a merged route + `merge_results.json`.
- `gpxs\` — an orchestrator `OutRoot`: one `MM-DD-YYYY` folder per day, each with
  `gpx_raw\` and `gpx_day\` subfolders.

## Progress output

All three scripts report live progress to the console:

- `gopro_telemetry.ps1` prints how many videos it found, then one line per file —
  `[3/4]  75% | GX010578.MP4 -> 14982 pts` (or `no telemetry` / `ERROR`) — plus a
  PowerShell progress bar.
- `merge_gpxs.ps1` prints how many GPX files it's reading and shows a progress bar.
- `process_footage.ps1` prints a cyan `=== Day 3/53 (5%): 03-20-2026 ===` header
  per day and streams the child scripts' per-file progress underneath.

The percentage is **file-level** (files completed / total). There is no
within-a-single-file percentage: each video's telemetry is pulled by one ExifTool
call that runs to completion with no intermediate progress to report.

## Performance & GPU

These scripts do **not** use the GPU, and a GPU would not help. They never decode
or transcode video — `ffprobe` only reads stream metadata, and ExifTool parses the
GoPro telemetry (GPMF) data track, not the H.264/H.265 picture. The work is
CPU- and I/O-bound (ExifTool parsing + XML handling). To go faster, process files
or date folders in parallel rather than reaching for a GPU.

## Troubleshooting

- **A date produced no merged route** — make sure that date's `gpx_day\` folder
  actually contains a `merged_route_*.gpx`. If `gpx_raw\` has GPX files but
  `gpx_day\` is empty, re-run `merge_gpxs.ps1` for that folder (the day's tracks
  merge into one route there).
- **"ffprobe is not recognized"** — FFmpeg isn't on your `PATH`. Install it and add
  its `bin` directory to `PATH`, then restart the terminal.
- **First run is slow / needs internet** — it's downloading ExifTool into
  `<OutDir>\.tools`. Later runs reuse the cache.
- **"running scripts is disabled on this system"** — set the execution policy or
  use `powershell -ExecutionPolicy Bypass -File .\script.ps1 ...`.
- **A route spans continents / reports an impossible distance** — that's raw GoPro
  GPS noise. Cleaning is on by default now; if you see this, the GPX was produced by
  an older run — re-extract it (see [GPS data cleaning](#gps-data-cleaning-on-by-default)).
- **A video produced no GPX** — it had no GPS data stream, GPS never locked, or
  every point was filtered as junk. Check that file's entry in
  `telemetry_results.json` (`hadDataStream`, `points`, `clean`). Multi-GB GoPro
  chapters and files with minor ExifTool warnings (e.g. "gpsaltitude not defined")
  are handled and still extract — if a file with real GPS reports 0 points, that's
  a genuine no-data case, not the warning.
- **Too many / too few rides** — tune the ride-detection thresholds:
  `-MaxGapSeconds` / `-MinGapSeconds` / `-MaxGapMeters`. If a stop keeps splitting a
  ride, raise `-MaxGapSeconds` or `-MaxGapMeters`.
