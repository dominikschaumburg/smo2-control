# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

A Garmin Connect IQ **data field** in Monkey C. Reads a Moxy muscle-oxygen
sensor over ANT+ and classifies the athlete's SmO2 kinetics in real time:
is the signal falling, holding at a plateau, still drifting, or recovering.

[README.md](README.md) is the user-facing summary and
[docs/functionality-en.md](docs/functionality-en.md) the complete behavioural
reference. Read the header comment of a source file before changing it — they
record *why* each approach was chosen, including approaches that were tried and
rejected.

## Build and run

Use the `build` and `simulate` skills. In short:

- Type-check after an edit: `monkeyc -f monkey.jungle -o bin/test.prg -d fr970 -y developer_key --typecheck 3`
- Full package: `./build.sh` → `bin/SmO2Control.iq` (92 device/language builds)
- Simulator: `./simulate.sh [device]`, default `fr970`
- SDK path is overridable with `CIQ_SDK`

The codebase is **Strict** type-check clean. Keep it that way; fix the code
rather than lowering the level.

## Two things that will mislead you

**1. The simulator cannot produce SmO2 data.** This field owns a generic ANT
channel, and simulator FIT playback does not drive generic ANT channels. A
simulator run sits in `SEARCH` forever — that is correct, not a bug. Live data
needs SimulANT+ with an ANT USB stick.

**2. A green build says nothing about the algorithm.** After touching
`source/Kinetics.mc`, run both references:

```bash
./tools/kinetics_replay.py --synthetic      # ground truth, fast
./tools/kinetics_replay.py ~/path/*.fit     # real sessions, authoritative
```

`tools/kinetics_replay.py` is a Python port of the same model. Keep it in sync.

**The synthetic invariant:** sustainable intervals (`work1`, `work2`) reach
`STEADY` ~55 % of their time; unsustainable ones (`work3`, `work4`) ~4 %.

**The real-data invariant:** in a threshold session, work laps read `STEADY`
45–80 % with `ON-KIN` covering the first minute, and recovery laps read `REOXY`
50–80 %.

Use real `.fit` files as the tiebreaker. An earlier synthetic generator was far
too clean, and thresholds tuned against it were an order of magnitude too tight
— every real interval came out as "never plateaued". Synthetic data can only
catch regressions, it cannot calibrate.

## Architecture

| File | Responsibility |
|---|---|
| `SmO2ControlApp.mc` | `AppBase`; owns the ANT channel for the app's lifetime |
| `SmO2ControlView.mc` | `DataField`: settings, layout tiers, `compute()`, rendering |
| `MoxySensor.mc` | `Ant.GenericChannel`, page-1 parser, state machine, reconnect |
| `Kinetics.mc` | `SlopeWindow` + Holt smoothing + state classification |
| `SessionCalibration.mc` | baseline, session min/max, lap calibration, lap stats |
| `ChartRenderer.mc` | fixed ring buffer + coloured sparkline |
| `SmO2FitContributor.mc` | FIT record / lap / session fields |
| `Palette.mc` | state colours incl. colour-blind variant |

### The core design decision

Two estimators on two timescales, in `Kinetics.mc`:

- **Holt double-exponential** → level, forecast. O(1).
- **60 s rolling least-squares slope** → the state classification, and the
  displayed rate (a number that disagreed with the colour would just confuse).

They are not interchangeable. On real data the Holt trend exceeds 0.15 %/s on
half of all samples inside a solid plateau, so no threshold on it separates
anything. An exponential filter slow enough to resolve the drift never settles
within an interval; a finite window forgets the transient once it slides past.
Measured, not assumed. Do not "simplify" the regression into an EWMA.

The 60 s window length is also measured: at 45 s the plateau band is so loose
(±0.08 %/s) that real drift hides inside it; at 90 s the on-transient dilutes
into the preceding recovery and stops being detected.

### On-transient handling

Rapid desaturation at interval start gets its own state (`STATE_ONKIN`), and the
regression window is restarted once the fall ends so the plateau question is
answered from post-transient data only. Without this, every hard interval reads
`OVER` for its first minute — including sustainable ones. On/off detection runs
off the regression slope (below `2 x thetaDrift`), never off the Holt trend.

### Rules that matter in a data field

- `compute()` runs at ~1 Hz and does *all* the work; `onUpdate()` only paints
  what `compute()` produced. Never read the sensor in `onUpdate()`.
- No allocation in the hot path. Ring buffers are sized once in `initialize()`
  or `onLayout()`.
- Layout tiers, fonts and geometry are decided once in `onLayout()`.
- In `MoxySensor.onMessage()`: call `getPayload()` exactly once (it allocates),
  and never call `Ui.requestUpdate()` — that decouples the ANT tick from the
  render tick.
- Invalid/ambient ANT values must become `null`, never `0` — 0 % SmO2 is a
  physiologically plausible-looking lie. The SDK's own MoxyField sample gets
  this wrong; do not copy it.

## Settings

Defined in `resources/base/properties.xml`. Float settings are stored as
integers (`×100` / `×1000`) because the Connect IQ settings editor has no
reliable float input across devices — `smoothingAlpha100`, `thetaStable1000`,
etc. Convert in `SmO2ControlView.readSettings()`.

## Conventions

- Comments explain *why*, not *what*. Match the existing density.
- British spelling in user-facing strings ("colour").
- `resources/base/` is English, `resources-deu/` is German. Both must define
  every string id that is referenced.
- The `developer_key` is gitignored and must never be committed.
