# SmO2 Control — Complete Functional Description

A Garmin Connect IQ data field for muscle oxygenation (SmO₂) with a Moxy sensor.

---

## 1. The core idea

Absolute SmO₂ is barely comparable between sessions. It depends on sensor site
(millimetres matter), adipose tissue thickness over the muscle, strap pressure,
skin perfusion, temperature and day form. A data field that shows "SmO₂ = 34 %"
therefore gives the athlete nothing actionable.

Within a single session the signal is highly informative — not as an absolute
value, but as **kinetics**:

1. **Rapid desaturation** at interval onset: demand exceeds supply. The
   steepness of this fall correlates with metabolic rate.
2. **Plateau or continued drift**: if SmO₂ settles at a stable plateau, supply
   and demand are balanced and the intensity is sustainable. If it keeps
   sliding, supply cannot follow — the intensity is past the sustainable point.
3. **Reoxygenation** during recovery, often overshooting the starting value.

So the field's real-time message to the athlete is not "34 %", but: *falling /
stabilising / still drifting / recovering* — and how fast.

---

## 2. State classification

Five states, each with its own colour:

| State | Colour | Meaning |
|---|---|---|
| **ON-KIN** | Orange | Rapid desaturation — the on-transient at interval start |
| **OVER** | Red | Decline continuing — past the sustainable point |
| **CONTROL** | Yellow | Slow decline — demanding but controlled |
| **STEADY** | Green | Flat — supply matches demand, sustainable |
| **REOXY** | Blue | Rising — recovery, or the effort is too easy |

The distinction that matters most is **ON-KIN versus OVER**. Every hard interval
begins with a steep fall, and that fall is not yet a verdict. What separates a
sustainable interval from an unsustainable one is whether the plateau arrives
afterwards. A field that judges the transient as "overshoot" paints every hard
interval red for its first minute, which makes it useless.

All state boundaries carry ±15 % hysteresis so the colour does not flicker while
sitting on a threshold.

---

## 3. Signal processing

Two estimators on two timescales. They are not interchangeable.

```
raw SmO₂ (~1 Hz, noisy)
      |
      +-- Holt double-exponential smoothing --> level, fast trend
      |                                          `-- forecast, chart
      |
      +-- 60 s regression slope ---------------> state classification
                                                  `-- colour and displayed rate
```

### 3.1 Holt smoothing (level and forecast)

Holt double-exponential smoothing yields level and trend from one O(1)
recursion. The trend is carried in %/s rather than %/update, because `compute()`
is not guaranteed to fire at exactly 1 Hz and the Moxy's own update rate drifts.
Every recursion therefore uses the measured Δt.

Parameters: α (level, default 0.30), β (trend, default 0.15).

The Holt trend drives the **forecast**: `level + h · trend` predicts SmO₂ h
seconds ahead (default 15 s, can be switched off).

### 3.2 Regression slope (classification)

A plain least-squares fit over the last 60 seconds of the smoothed level. It
costs one pass of ~60 multiply-adds per second.

**Why not exponential smoothing here too?** Not CPU cost. On real Moxy data the
fast Holt trend exceeds 0.15 %/s on half of all samples — *inside a rock-solid
plateau*. The signal genuinely moves that fast; this is not a smoothing
artefact, and no threshold on that trend can separate anything. Slowing it down
does not help either: an exponential filter has an infinite tail and keeps
carrying the on-transient forward, so it never settles within an interval. A
finite window *forgets* the transient once it slides past. For "has the plateau
arrived?", forgetting is exactly the behaviour you want.

**Why 60 seconds?** Measured across five real threshold sessions:

- at 45 s the plateau band is ±0.08 %/s — genuine drift disappears inside it
- at 90 s the on-transient dilutes into the recovery that preceded it and stops
  being detected at all
- at 60 s the plateau slope stays within ±0.06 %/s (10th–90th percentile) while
  the transient runs past −0.23 %/s

### 3.3 Thresholds

| Threshold | Default | Origin |
|---|---|---|
| θ_stable | 0.06 %/s | 10th–90th percentile of plateau slope, five sessions |
| θ_drift | 0.15 %/s | edge of normal plateau behaviour |
| θ_onkin | 2 × θ_drift | between the plateau extreme and transient steepness |

The on-kinetics threshold is derived from θ_drift rather than being its own
setting, so it scales automatically when you tune.

### 3.4 On-transient handling

Once the regression slope drops below θ_onkin, the state is treated as an
on-transient. When the fall ends, the regression window is **restarted**, so the
plateau question is answered from post-transient data only. Until the window
refills (one third of its length, i.e. 20 s) the field keeps reporting ON-KIN —
the honest answer, "not decided yet".

A lap press also counts as a load change and restarts the window.

The steepest slope reached during the transient is captured per lap and written
to the FIT file, because it correlates with metabolic rate.

---

## 4. Session-internal calibration

Since absolute values are not comparable between sessions, everything is
referenced to a window calibrated live within the session.

**Stage 1 — Baseline.** Median of the first 60 seconds of valid data (window
configurable), serving as the "reference top". Long windows are sub-sampled; at
most 120 samples are held.

**Stage 2 — Rolling session min/max.** Advanced from *smoothed* values only, so
a single sensor spike cannot define the range. Both extremes relax back toward
the current value at 0.02 %/s once they are more than 3 % away from it, so one
outlier does not distort the scaling for the rest of the session.

**Stage 3 — Lap calibration.** The first lap is treated as a reference interval;
its start and end values anchor the working band. A second lap press within
2 seconds resets the session range — intended for re-seating the sensor
mid-session.

**Stage 4 — Relative thresholds.** θ_stable and θ_drift are defined in %/s, not
as absolute SmO₂ percentages. Rates are considerably more stable between
sessions than absolute values.

**SmO₂ Control Index (SCI).** A dimensionless figure: the magnitude of the
regression slope divided by the session range, which makes it comparable across
sessions and sensor placements.

---

## 5. Display

Three layout tiers, chosen once in `onLayout()` from the rendered area. The
decision is not taken per frame, because the size never changes at runtime.

### Full (from 200 × 150 px)

- Large SmO₂ value on the left, in the state colour
- Three lines on the right: state label, slope in %/s, SCI
- **Sparkline** over the chart window (default 90 s), each line segment coloured
  by the state at that point
- **Lap markers** as vertical lines
- **Calibration bands**: thin horizontal lines at session min and max
- **Forecast marker**: greyed line plus a dot at the right edge
- Bottom line: pace or power, with the session range on the right

### Medium (from 120 × 70 px)

Value on the left in the state colour, trend arrow beneath, mini sparkline on
the right.

### Compact (anything smaller)

No chart. The state is carried entirely by the **background colour**, with the
value in black and a trend arrow on top — readable at a glance from a four-up
layout.

### Displayed rate

The displayed slope is the regression slope, not the fast Holt trend. A number
that disagreed with the colour would only confuse.

### Colours

The default is the intuitive traffic-light mapping. The colour-blind variant
replaces the red/green axis with a blue/magenta axis (cyan / white / violet /
amber / magenta), which stays distinguishable under deuteranopia and protanopia.

---

## 6. Pace/power coupling and decoupling detection

When enabled, the field shows the external load: power in watts if available,
otherwise pace in min/km.

The informative moment is **decoupling**. The coefficient of variation of the
load is computed over a 30-second window. If it is below 4 % — the external load
is constant — while SmO₂ is simultaneously in CONTROL or OVER, the field shows
`DECOUPLING`. That means muscle oxygenation keeps falling at unchanged external
load: the onset of fatigue or efficiency loss, and it is invisible in either
signal on its own.

---

## 7. Sensor link

SmO₂ and THb were never added to the native Connect IQ sensor API. The data
field therefore opens its **own** generic ANT channel and decodes the ANT+
Muscle Oxygen profile (data page 1) itself.

> **Important:** the Moxy must **not** also be paired natively in the watch's
> sensor list. A sensor can hold only one ANT channel; whichever side claims it
> first blocks the other.

**Channel parameters:** device type 31, message period 8192, radio frequency 57,
ANT+ network. The sensor ID is configurable; 0 pairs with the first Moxy found,
while a specific value prevents pairing with someone else's sensor in a studio
or club setting.

**State machine:** `SEARCHING → TRACKING → STALE → TRACKING` and
`→ CLOSED → SEARCHING`.

- **STALE** when the event count stays unchanged for more than 5 seconds. Trend
  computation is then frozen, so a frozen reading is not mistaken for a genuine
  slope of zero. The regression window is cleared, because fitting across a hole
  would invent a slope that never happened.
- On `EVENT_CHANNEL_CLOSED` the channel is reopened automatically.
- On `RX_FAIL_GO_TO_SEARCH` the channel returns to searching.

**Validity handling.** The profile's "invalid" and "ambient light too high"
codes are checked on the *raw* fields before scaling and yield `null` — never
0 %. An SmO₂ reading of 0 % looks physiologically plausible, which makes it a
particularly dangerous falsehood. The SDK's own MoxyField sample gets this
wrong.

**Resource discipline.** `getPayload()` is called exactly once per message
because it allocates. `onMessage()` never triggers `requestUpdate()`; the field
reads the last parsed value in `compute()`, which cleanly decouples the ANT tick
from the render tick.

---

## 8. FIT recording

**Record fields** (~1 Hz, charted in Garmin Connect):

| Field | Unit |
|---|---|
| `smo2` — smoothed muscle oxygenation | % |
| `smo2Trend` — regression slope | %/s |
| `sci` — SmO₂ Control Index | — |
| `smo2State` — state as a number | — |
| `thb` — total haemoglobin | g/dl |

**Lap fields** (in the lap summary):

| Field | Unit |
|---|---|
| `lapDesatRate` — desaturation rate `(end − start) / lap duration` | %/s |
| `lapOnKinRate` — steepest on-transient slope | %/s |
| `lapSmo2Min`, `lapSmo2Max` | % |

**Session field:** `avgSmo2` — session average. The average only advances while
the timer runs, so ten minutes standing around with the sensor on does not skew
it.

`setData()` is called only when a value actually changed, so smart recording
does not inflate the file. Recording can be switched off.

---

## 9. Settings

| Setting | Default | Meaning |
|---|---|---|
| `moxyDeviceNumber` | 0 | ANT ID of the sensor, 0 = first one found |
| `smoothingAlpha100` | 30 | Holt level α × 100. Higher = more reactive, jumpier |
| `smoothingBeta100` | 15 | Holt trend β × 100 |
| `predictHorizon` | 15 | Forecast horizon in seconds, 0 = off |
| `steadyWindowSec` | 60 | Length of the regression window |
| `thetaStable1000` | 60 | θ_stable × 1000, plateau/decline boundary |
| `thetaDrift1000` | 150 | θ_drift × 1000, controlled/overshoot boundary |
| `chartWindowSec` | 90 | Time span of the sparkline |
| `yAxisMode` | Auto | Auto (session range) / fixed 20–80 % / fixed 0–100 % |
| `baselineSec` | 60 | Length of baseline collection |
| `colorBlind` | off | Colour-blind palette |
| `showPace` | on | Pace/power line including the decoupling flag |
| `recordFit` | on | Write SmO₂ fields to the FIT file |

Floating-point settings are stored as integers (× 100 or × 1000) because the
Connect IQ settings editor does not offer reliable float input across all
devices.

In auto mode the y axis scales to the session range plus padding rather than
0–100 %, because in practice a Moxy lives between roughly 20 and 80 %. Spending
half the pixels on values that never occur throws away exactly the resolution
that matters.

---

## 10. Parameter tuning tools

Tuning the thresholds on the watch is slow and imprecise. Two tools allow tuning
against your own recorded intervals.

**`tools/kinetics_replay.py`** is a faithful Python port of
`source/Kinetics.mc`. It reads `.fit` files straight off the watch, or CSV,
breaks the session down by lap and gives a verdict per interval:

```
 per-interval summary
  lap        dur  start    end     rate    onkin    min    max  verdict
  lap02      299   72.0   50.6   -0.072   -0.446   44.3   72.0  sustainable (steady 49%)
  lap04      299   62.8   45.1   -0.059   -0.438   41.6   62.8  sustainable (steady 60%)
```

It also reports the state distribution, RMS residual, a compressed timeline, and
a grid search over α and β (`--sweep`). The parameters map directly onto the app
settings.

**`tools/fitreader.py`** is a dependency-free FIT decoder — no `pip install`
required. It reads SmO₂ from the native record fields and auto-detects developer
fields written by other recording apps, whose field name contains the sensor ID.
Lap end times are derived from `start_time + total_elapsed_time`, because not
every writer sets `lap.timestamp` correctly.

**`--synthetic` mode** generates a session with known ground truth — two
sustainable and two unsustainable intervals — serving as a regression test for
the classification.

---

## 11. Device support

55 products with an ANT+ radio: Forerunner 245–970, Fenix 6 through 8, Epix
Gen 2, Enduro, MARQ Gen 2, and Edge 530 through 1050. Devices without an ANT+
radio cannot talk to a Moxy at all and are deliberately excluded.

Permissions required: ANT, FitContributor. Interface languages: English and
German.

---

## 12. Known limitations

**The simulator cannot supply SmO₂.** The Connect IQ simulator's FIT playback
does not drive generic ANT channels. In the simulator the field sits at `SEARCH`
permanently — that is correct behaviour. Live data needs SimulANT+ with an ANT
USB stick; model work should use the replay tool.

**θ_drift rests on weaker evidence than θ_stable.** In the five sessions used
for calibration, every work interval reached a plateau — they were executed
correctly. That leaves no genuine "above threshold" interval, so the drift
boundary still comes from synthetic data. A session with a deliberately too-hard
start would pin that threshold down empirically.

**Not implemented:** a modelled "SmO₂ cost per unit of pace", and analysis of
the reoxygenation overshoot during recovery.
