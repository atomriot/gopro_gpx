# GPX Accuracy Report (diagnostic tool)

A **diagnostic tool** for inspecting the GPS quality of a single GoPro video.
It dumps every GPS point from the file, classifies each one good/bad using the same
rules as the GoPro GPX extraction pipeline, and writes a self-contained HTML report
showing where the data is trustworthy and what would get scrubbed.

> This is a **diagnostic tool**, separate from the main extract → merge pipeline. Run it
> ad hoc to spot-check why a file lost points (e.g. a ride that only tracked part way).
> It changes nothing and only writes an HTML report (which is gitignored, so reports are
> never committed).

Script: `gpx_accuracy_report.ps1`

## What it answers

- What **percentage** of a clip's GPS points are accurate (i.e. would survive cleaning)?
- **Why** are points dropped — no fix, no timestamp, poor precision, or impossible jumps?
- **Where** in the clip is the data good vs bad (e.g. is there GPS "warmup" at the start)?
- What does the good path actually look like on a map, and where do the bad fixes land?

## Requirements

- **Windows PowerShell 5.1+** (same as the pipeline).
- **ExifTool** on your `PATH` (or pass `-ExifTool <path>`). It's used read-only to pull
  the embedded GPS track. No install needed if `exiftool` already runs in your terminal.
- **Internet access to *view* the report** — the HTML loads Chart.js and Leaflet from a
  CDN, and map tiles online. Generating the file needs no internet.

## Usage

```powershell
# Generate and auto-open the report for one file
.\gpx_accuracy_report.ps1 -Path "E:\03-20-2026\GX010578.MP4"

# Tune the thresholds (defaults match the pipeline)
.\gpx_accuracy_report.ps1 -Path "E:\03-20-2026\GX010578.MP4" -MaxDop 10 -MaxPlausibleSpeedMps 60

# Generate without opening a browser (e.g. checking several files in a row)
.\gpx_accuracy_report.ps1 -Path "E:\03-20-2026\GX010578.MP4" -NoOpen
```

The report is written next to the script as `<filename>_accuracy.html` (override with
`-OutHtml`).

### Parameters

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-Path` | *(required)* | The GoPro `.MP4`/`.MOV` to analyze. |
| `-OutHtml` | `<file>_accuracy.html` next to the script | Where to write the HTML report. |
| `-MaxDop` | `10` | GPSDOP above this counts as a bad (low-precision) point. `≤5` is good, `>50` is junk. |
| `-MaxPlausibleSpeedMps` | `60` | A jump implying a higher speed (m/s) from the last good point counts as a spike. |
| `-ExifTool` | auto (PATH) | Explicit path to `exiftool.exe` if it isn't on `PATH`. |
| `-NoOpen` | off | Don't auto-open the report in a browser after generating it. |

## How a point is judged good or bad

Each point is marked **bad** if any of these are true (the same logic the pipeline
uses to clean tracks), so the reported "accurate %" equals what real cleaning keeps:

- **no_fix** — coordinates are exactly `(0, 0)` (GPS hasn't locked).
- **no_time** — the point has no timestamp (a GoPro artifact on the first point of a
  continuation chapter).
- **high_dop** — `GPSDOP` exceeds `-MaxDop` (the receiver reporting low confidence).
- **speed_spike** — the implied speed from the last *good* point exceeds
  `-MaxPlausibleSpeedMps` (a teleport jump).

Everything else is **good**. A single point can fail more than one check, so the
per-reason counts can add up to more than the total bad count.

## What's in the HTML report

- **Summary** — accurate %, good/bad counts, a per-reason breakdown, DOP min/median/max,
  and timing: total file span vs good-data span, plus the **warmup** before the first
  good fix and any trailing after the last one. (A shorter good span than the clip is
  usually just GPS warmup at the start.)
- **Map** — green line = the good path; red dots = bad-fix points (click for the reason).
  `(0, 0)` no-fix points are counted but left off the map so they don't draw a line to
  the ocean.
- **DOP chart** — GPS precision across the file with the drop threshold marked; you can
  see precision spike during warmup and wherever it degrades.
- **Speed chart** (log scale) — implied speed across the file; the spikes are the bad jumps.

## Notes

- Large multi-GB files take a moment — ExifTool scans the whole embedded GPS track.
- The two trend lines are downsampled for a responsive chart, but **all** bad points are
  plotted and **all** points are used for the stats and the map.
- Thresholds default to the pipeline's values, so the report reflects exactly what the
  real extraction would keep or scrub. Lower `-MaxDop` to be stricter, raise it to be
  more lenient.
