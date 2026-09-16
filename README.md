# FitnessTracker

Personal training database for **iOS + macOS**. SwiftUI + SwiftData, built around a
**Suunto → FIT file → analytics** workflow — the watch records, this app stores and
analyzes. No live GPS tracking, no accounts, no backend.

## Run it

```bash
brew install xcodegen
xcodegen generate
open FitnessTracker.xcodeproj
```

Signs ad-hoc out of the box, so the build and the tests below work with no setup.
To run on a real device, switch the target to Automatic signing and pick your
Team. `FitnessTracker.xcodeproj` is **generated** — edit `project.yml` instead,
and re-run `xcodegen generate` after adding files or folders.

Tests:

```bash
xcodebuild -project FitnessTracker.xcodeproj -scheme FitnessTracker -destination 'platform=macOS' test
```

No workouts yet? **Workouts tab → + → Seed demo data** inserts a deterministic
12-week season (40 runs with routes and HR streams, 2 shoes, 16 lifting sessions)
so every screen has something to show.

## What works today

| Area | Status |
|---|---|
| FIT import | Session/Record/Lap parsing, GPS track, HR/cadence/speed/altitude streams, content-hash dedupe |
| Strava sync | Own-app OAuth (`activity:read_all`), paged activity fetch, route from `summary_polyline`, token auto-refresh |
| intervals.icu sync | API-key basic auth, date-windowed activity fetch |
| PDF extraction | Claude reads a PDF and returns structured workouts; mandatory review before anything is saved |
| Workouts | List with pace/HR/shoe/source, detail with route map, HR chart, per-km splits |
| Splits | Interpolated at km boundaries, fastest split highlighted, partial final split |
| Shoes | Assign to runs, mileage rollup, wear % with warning colors, retire/un-retire |
| Strength | Sessions, sets with RPE, Epley e1RM, per-exercise progress chart, add-set flow |
| Routes | Tap-to-build route planner with path snapping, GPX import/export, elevation profile |
| Training load | Per-session stress on one TSS scale across every sport, plus fitness (42-day) / fatigue (7-day) / form curves |
| Cycling | Normalized Power, Intensity Factor, TSS, W/kg, variability index, best-power windows |
| Swimming | Pace per 100 m, stroke rate, lengths, SWOLF |
| Running | Race predictions (Riegel) and derived training-pace bands |
| Recovery | Readiness score with per-component breakdown, HRV/RHR/sleep/weight trends, daily check-in |
| HealthKit | HRV, resting HR, sleep, weight, VO₂max import (iOS only — HealthKit doesn't exist on macOS) |
| HR zones | Five-zone split per workout with time-in-zone, from your max HR |
| Records | Best efforts at 1 km → marathon from stream data, plus longest run / biggest week / most climbing |
| Dashboard | This-week totals, fitness/fatigue/form with a 120-day curve, weekly volume, road pace trend, shoe alerts |
| Finding things | Search across sport/source/notes/shoe, plus a sport filter |

226 tests cover the FIT round-trip (encode → decode → assert), splits math, readiness
scoring (missing-input and flat-baseline cases included), HR zone boundaries and the
time-in-zone invariant, best-effort extraction, haversine distances against known
city pairs, GPX export/parse round-trips and malformed input, NP/IF/TSS against their
defining identities (one hour at FTP = TSS 100), swim SWOLF, Riegel predictions,
strength volume attribution, persistence and dedupe, shoe rollups, polyline decoding,
provider JSON parsing, sync idempotency, the exact Anthropic request shape, and that
every screen renders. Training load is pinned against the identities it claims to
implement — one hour at threshold is 100, one hour at FTP is 100, stress scales with
the square of intensity, constant training converges on its own daily load — and a
`RegressionTests` file holds one test per bug found in the September 2026 audit.

The render tests assert that a screen produced an image without trapping, which
catches bad unwraps, Charts misconfiguration and missing environment values. They do
*not* assert the image has content: `ImageRenderer` renders a `NavigationStack` empty
on macOS, so a blank result isn't a signal either way.

## Connecting services

Everything is configured in **Workouts → gear icon**. This app ships no shared API
credentials — you supply your own, and they go straight to the Keychain.

**Strava.** Register your own (free) app at strava.com/settings/api, set the callback
domain to `localhost`, then paste Client ID + Secret and tap Authorize. Requests
`activity:read_all` so private activities sync too. Access tokens last 6 hours and
refresh automatically; refresh tokens rotate on every use and are re-persisted.

**intervals.icu.** Copy the API key from the bottom of your intervals.icu Settings
page. Athlete ID is optional — blank means "the authenticated athlete".

**Garmin, Suunto, Polar.** Not implemented, and the app says so in Settings with what
to do instead. Garmin's Connect API needs approved-partner status (no self-service
key); Suunto's needs an apizone subscription key; Polar's AccessLink is open but
unbuilt. All three auto-sync to Strava, which *is* supported — and Suunto's `.fit`
export already works at full fidelity.

## PDF extraction

Point it at a coach's plan, a race result, or a training-log export and Claude pulls
the workouts out. Requires an Anthropic API key (console.anthropic.com) in Settings.

- Uses `claude-opus-5` with adaptive thinking and a **strict tool schema**, so the
  response is validated structured data rather than prose to be regex'd.
- The prompt forbids inventing values, requires metric conversion, and asks for a
  `sourceHint` ("page 2, row 4") plus a confidence score per row.
- **Nothing is saved without your approval.** Results land in a review list; rows
  under 0.5 confidence are flagged and left unchecked. Re-importing the same PDF
  dedupes on a document hash.
- Limits enforced before any request: 20 MB and 600 pages.
- The key lives in this device's Keychain and calls go straight to the API — fine for
  a personal app, but a shipping product would proxy through a server instead.

## Routes

Plan on the map, send to the watch:

- **Tap to drop waypoints**; the route builds as you go with a live distance readout.
- **Snap to paths** asks MapKit for walking (or any-mode, for bikes) directions between
  consecutive waypoints, so the line follows real streets and trails instead of cutting
  across blocks. If MapKit can't route a segment — remote terrain, throttling — it falls
  back to a straight line and says so rather than losing your work.
- **Close the loop** in one tap; loops are detected and labelled.
- **GPX export** via the share sheet — AirDrop it or hand it to the Suunto/Garmin app.
  Exported as a `<trk>`, which importers accept near-universally (route `<rte>` support
  is patchier).
- **GPX import** for routes built elsewhere (plotaroute, Strava, a friend's file).
  Out-of-range coordinates are dropped rather than plotted.

## Sport-specific analysis

Each discipline gets the metrics its athletes actually use, and only where they mean
something — a swim doesn't show power, a ride doesn't show pace per km.

**Cycling.** Normalized Power (30 s rolling average, fourth-power mean), Intensity
Factor, TSS, W/kg, and a variability index that tells you whether the ride was steady
or surgey — which is what makes NP-based numbers trustworthy or not. FTP and body
weight are optional: without them you still get average, normalized and max power.

**Swimming.** Pace per 100 m rather than per km, stroke rate, pool lengths, and SWOLF
(length time + strokes) when the pool length is known.

**Running.** Riegel race predictions from your *longest* known best effort — predicting
a marathon up from a 1 km time wildly over-predicts, so long extrapolations are flagged
as speculative. Training-pace bands (easy → interval) derive from a 10 km-equivalent
threshold.

**Strength.** Working-set volume by movement pattern (squat/hinge/push/pull/carry/core),
weekly tonnage, e1RM progression, and PR detection per exercise. Warmups never count
toward volume.

## Training load

Every session gets one number on the **TSS scale — 100 is an hour at threshold** —
so a ride, a swim, a run and a lifting session can be added together. The previous
model summed raw distance, which made an 80 km ride worth four hard runs and a
brutal 2 km swim worth almost nothing.

Load is scored by the best method the session's data supports, and the method is
shown next to the number, because a load derived from power and one guessed from
duration are both "84" and you should know which you're looking at:

| Method | When | How |
|---|---|---|
| Power | Cycling with FTP set | Normalized Power against FTP — the reference standard |
| Heart-rate stream | Any sport with per-second HR | Intensity squared, integrated sample by sample |
| Average heart rate | Synced activities without streams | Same formula over the session average |
| Pace | Runs, no HR, threshold pace known | Threshold pace over actual pace |
| Duration | Nothing measured the effort | Per-sport default intensity, and labelled an estimate |

Intensity is heart-rate **reserve** against threshold (Karvonen, threshold at 85% of
reserve), not raw bpm, so resting HR matters — it's read from Health on iOS or set
by hand. Squaring intensity before integrating is what separates an interval session
from a steady run at the same average heart rate.

Those daily totals feed the standard impulse-response curves:

- **Fitness** — 42-day exponential average. What you've built.
- **Fatigue** — 7-day exponential average. What you're carrying.
- **Form** — the gap. Positive is fresh, deeply negative is overreaching.
- **Ramp** — fitness gained per week. Above ~7 is the classic "too much, too soon".

Rest days are emitted as zero-load days rather than skipped: decay between sessions
is the entire point of the model. Readiness now takes its acute:chronic ratio from
this curve, so a hard ride or a heavy lifting week costs readiness the way it should.

## Readiness

The Recovery tab scores each day 0–100 from whatever inputs exist:

| Component | Weight | Signal |
|---|---|---|
| HRV | 35% | today vs your 7-day baseline, scaled by its own variability |
| Sleep | 25% | duration against target, blended with subjective quality |
| Resting HR | 15% | today vs baseline, inverted (lower is better) |
| Training load | 15% | acute:chronic ratio — a steep ramp costs you |
| How you feel | 10% | soreness (inverted), mood, motivation |

Design decisions worth knowing:

- **Weights renormalize over available inputs.** A missing HRV reading doesn't drag
  the score toward zero; it just lowers reported `confidence`. Below 30% confidence
  the app refuses to show a score instead of inventing one.
- **Baselines need at least 3 prior days** and never see same-day or future data.
- **A flat baseline can't divide by zero** — the z-score denominator is floored.
- **~0.75 per component means "at your baseline."** All-normal reads ~75, not 50.
- It is a **heuristic over your own trends, not a medical measurement**, and the UI
  says so.

## Layout

```
FitnessTracker/
  App.swift                  @main + SwiftData container
  Models/                    Workout, Shoe, Strength, WorkoutSport
  Importers/                 FITImporter (decode), FITPersistence (SwiftData bridge)
  Analysis/                  Splits, Readiness, HRZones, PersonalRecords, CyclingPower,
                             SwimMetrics, RacePrediction, StrengthAnalysis, GeoMath, GPX,
                             Formatting, DemoData
  Sync/                      Providers (Strava, intervals.icu), Keychain, polyline, SyncEngine
  Health/                    HealthKitReader (iOS-only, compiled out on macOS)
  AI/                        AnthropicClient, PDFWorkoutExtractor
  Views/                     Workouts, Recovery, Routes, Strength, Dashboard, Records,
                             Shoes, Settings, PDF import
Tests/                       FIT, splits, readiness, zones, records, persistence, sync, AI, view render
```

**Design notes**

- `FITImporter` is SwiftData-free and returns a plain `FITDecoded`, so parsing is
  testable and swappable (GPX, TCX, Strava API) without touching persistence.
- GPS tracks and sample streams are stored as JSON blobs on `Workout` and decoded
  on demand — list queries stay cheap with years of history.
- `Workout.sport` is backed by a raw `String` so new sports don't need a migration;
  unknown values fall back to `.other`.
- Shoe mileage is computed from the relationship, never a stored counter, so it
  can't drift when workouts are edited or deleted.
- Every `externalID` is namespaced by source (`strava:123`, `fit:<sha>`, `pdf:<hash>`),
  so re-syncing is idempotent and two services can't collide on the same numeric ID.
- Providers normalize into `RemoteActivity`; nothing downstream knows which service
  data came from. Adding Polar or Suunto later means one new file.
- Provider JSON is decoded with every field optional — a service adding or dropping a
  key degrades one row instead of failing the whole sync.
- Heavy work (best-effort scanning) crosses to a background task via `WorkoutSnapshot`,
  a Sendable copy carrying the undecoded blob. SwiftData models must never cross an
  actor boundary — doing so crashes with "this model instance was destroyed".
- Scoring and analysis are pure functions over value types, so they're unit-tested
  directly; HealthKit is a thin adapter around them.
- Zone boundaries fall back to the **highest HR across all history**, never a single
  workout's peak — that would define every session as maximal, putting easy runs in Z5.
- Five tabs is the iOS ceiling before the rest collapse behind "More". Routes earns one
  because it's an active tool; Shoes is set-and-glance so it sits behind the Dashboard,
  which already surfaces its wear alerts.
- `FITSample` has an explicit initializer with defaults for every optional channel, so
  adding a new one (power, later maybe temperature) doesn't break every call site.

## Roadmap

- [x] FIT import from Suunto, workouts, shoes, splits, strength, dashboard
- [x] Strava + intervals.icu sync, AI PDF extraction with review
- [x] HealthKit metrics, readiness score, HR zones, personal records, search
- [x] Route planner with GPX export, cycling power, swim metrics, race prediction
- [x] Unified multi-sport training load with fitness/fatigue/form curves
- [ ] CloudKit sync between iPhone and Mac (models already have defaults for it)
- [ ] Drag-and-drop FIT import on macOS; watch-folder auto-import
- [ ] Route elevation from a terrain API (planned routes have no elevation until imported)
- [ ] Exercise library with form notes
- [ ] Nutrition (last — needs a food database; Open Food Facts or USDA)

## Known gaps

- Suunto's Apple Health sync drops GPS and HR detail, which is why this app reads
  `.fit` files directly. Export from the Suunto app, then import here.
- macOS is sandboxed with read-only access to user-selected files
  (`FitnessTracker.entitlements`) — enough for the file importer.
- `LapMessage` data is parsed and stored but the detail view shows computed km
  splits instead; watch laps aren't surfaced yet. This is the gap that matters
  most for interval work — an 8 × 400 m session wants its laps, not its kilometres.
- Strava activities import with a summary polyline only. Without per-second
  streams there are no best efforts, no zone breakdown, and training load falls
  back to average heart rate. Streams need a second call per activity.
- Everything is metric. There is no unit preference.
- **Strava and intervals.icu sync has not been run against a live account** — parsing
  is tested against realistic fixtures, but the first real connection may surface
  field-shape surprises. Same for PDF extraction: the request shape is tested, the
  round trip against the real API is not.
- intervals.icu activities import without GPS tracks; its streams need a second
  per-activity call that isn't wired up.
- Strava sync caps at 1000 activities per run to stay inside rate limits.
- **HealthKit import is unverified against real data** — the simulator has none, and
  the adapter's queries haven't run against a populated Health store. The scoring it
  feeds is thoroughly tested; the plumbing that fills it is not.
- HealthKit is iOS-only. On macOS the Recovery tab works from manual check-ins, and
  metrics won't appear there until CloudKit sync is wired up.
- Set your max HR in Settings before trusting zones; the estimated fallback is
  labelled in the UI but still only an estimate. Same for FTP and cycling TSS.
- **Routes built in-app have no elevation data** — Apple provides no public elevation
  API, so gain and the profile only appear for imported GPX that carries `<ele>`.
- Path snapping depends on MapKit directions, which are unavailable off-grid and can
  throttle; it degrades to straight segments.
- **Route builder map interaction is verified by render tests, not by a real tap
  session** — synthetic taps don't reach the iOS 26 floating tab bar, so nobody has
  dropped a waypoint by hand yet.
