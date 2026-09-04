# SmO2 Control: complete functional description

A Garmin Connect IQ data field for muscle oxygenation (SmO₂) with a Moxy sensor.

---

## 1. The core idea

Absolute SmO₂ is barely comparable between sessions. It depends on sensor site
(millimetres matter), adipose tissue thickness over the muscle, strap pressure,
skin perfusion, temperature and day form. A data field that shows "SmO₂ = 34 %"
therefore gives the athlete nothing actionable.

Within a single session the signal is highly informative, though not as an absolute
value, but as **kinetics**:

1. **Rapid desaturation** at interval onset: demand exceeds supply. The
   steepness of this fall correlates with metabolic rate.
2. **Plateau or continued drift**: if SmO₂ settles at a stable plateau, supply
   and demand are balanced and the intensity is sustainable. If it keeps
   sliding, supply cannot follow. The intensity is past the sustainable point.
3. **Reoxygenation** during recovery, often overshooting the starting value.

So the field's real-time message to the athlete is not "34 %", but: *falling /
stabilising / still drifting / recovering*, and how fast.

---

## 2. State classification

Five states, each with its own colour:

| State | Colour | Meaning | Kinetic name |
|---|---|---|---|
| **ONSET** | Orange | Rapid desaturation, the on-transient at interval start | ON-KIN |
| **FALLING** | Red | Decline continuing, no steady state exists here | OVER |
| **DRIFTING** | Yellow | Slow decline, demanding but still controlled | CONTROL |
| **HOLDING** | Green | Flat, supply matches demand, a sustainable steady state | STEADY |
| **RECOVER** | Blue | Rising, recovery or the effort is too easy | REOXY |

The labels name the behaviour that was measured, in language that needs no
glossary. The kinetic terms in the right-hand column are the alternative, for
readers who want the names the literature uses: turn off *Plain state names*.

### Why not zone numbers

Zone numbers were tried here and removed. Two reasons, and either one is
enough on its own.

The watch already owns the word "zone" for its own five heart rate zones and
seven power zones. This field saying ZONE 2 beside a heart rate field saying
Zone 4 is worse than saying nothing at all.

The deeper problem is that a zone is a statement about intensity and this field
measures a slope. A plateau occurs below LT1 and at threshold alike, and SmO₂
rising under load says supply exceeds demand without saying at what wattage. So
no mapping from slope to zone number can be correct. A correct one needs the
athlete's own muscle oxygenation breakpoints, anchoring the *absolute* level,
which is information the field does not have and cannot infer. What it can tell
you is whether the effort you have chosen has settled, which is a different and
narrower claim, and the one these labels make.

The distinction that matters most is **ONSET versus FALLING**. Every hard interval
begins with a steep fall, and that fall is not yet a verdict. What separates a
sustainable interval from an unsustainable one is whether the plateau arrives
afterwards. A field that judges the transient as "overshoot" paints every hard
interval red for its first minute, which makes it useless.

All state boundaries carry ±15 % hysteresis so the colour does not flicker while
sitting on a threshold.

### Where a colour belongs in time

The live verdict and the chart colours are computed differently, on purpose.

A trailing regression over [t−60, t] estimates the slope at the **centre** of
that window, t−30, not at its end. Painting it at t puts the colour thirty
seconds to the right of the shape it describes: measured on a real interval, the
trace was still green while dropping at −0.785 %/s, and still orange once the
plateau had arrived.

The chart therefore colours each segment from a window **centred** on it, and
near the live edge that window shrinks symmetrically, which is the standard way to
handle an endpoint. Verified against a real interval: every segment's colour now
agrees with the direction the line is actually going, with no exceptions.

Two consequences worth knowing. The newest samples are judged from less
evidence, so a segment can change colour as more arrives. That is honest, because that
is when the evidence turns up. And the very newest few, where no usable window
exists at all, are drawn grey rather than guessed at.

Chart colours also skip the hysteresis that the live verdict uses. Hysteresis
exists to stop the current state flickering; applying it to a finished shape
would make a segment's colour depend on what preceded it rather than on what it
is.

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
fast Holt trend exceeds 0.15 %/s on half of all samples, *inside a rock-solid
plateau*. The signal genuinely moves that fast; this is not a smoothing
artefact, and no threshold on that trend can separate anything. Slowing it down
does not help either: an exponential filter has an infinite tail and keeps
carrying the on-transient forward, so it never settles within an interval. A
finite window *forgets* the transient once it slides past. For "has the plateau
arrived?", forgetting is exactly the behaviour you want.

**Why 60 seconds?** Measured across five real threshold sessions:

- at 45 s the plateau band is ±0.08 %/s, so genuine drift disappears inside it
- at 90 s the on-transient dilutes into the recovery that preceded it and stops
  being detected at all
- at 60 s the plateau slope stays within ±0.06 %/s (10th to 90th percentile) while
  the transient runs past −0.23 %/s

### 3.3 Thresholds

| Threshold | Default | Origin |
|---|---|---|
| θ_stable | 0.06 %/s | 10th to 90th percentile of plateau slope, five sessions |
| θ_drift | 0.15 %/s | edge of normal plateau behaviour |
| θ_onkin | 2 × θ_drift | between the plateau extreme and transient steepness |

The on-kinetics threshold is derived from θ_drift rather than being its own
setting, so it scales automatically when you tune.

### 3.4 On-transient handling

Once the regression slope drops below θ_onkin, the state is treated as an
on-transient. When the fall ends, the regression window is **restarted**, so the
plateau question is answered from post-transient data only. Until the window
refills (one third of its length, i.e. 20 s) the field keeps reporting ON-KIN,
the honest answer, "not decided yet".

A lap press also counts as a load change and restarts the window.

The steepest slope reached during the transient is captured per lap and written
to the FIT file, because it correlates with metabolic rate.

---

## 4. Session-internal calibration

Since absolute values are not comparable between sessions, everything is
referenced to a window calibrated live within the session.

**Stage 1, baseline.** Median of the first 60 seconds of valid data (window
configurable), serving as the "reference top". Long windows are sub-sampled; at
most 120 samples are held.

**Stage 2, rolling session min/max.** Advanced from *smoothed* values only, so
a single sensor spike cannot define the range. Both extremes relax back toward
the current value at 0.02 %/s once they are more than 3 % away from it, so one
outlier does not distort the scaling for the rest of the session.

**Stage 3, lap calibration.** The first lap is treated as a reference interval;
its start and end values anchor the working band. A second lap press within
2 seconds resets the session range, intended for re-seating the sensor
mid-session.

**Stage 4, relative thresholds.** θ_stable and θ_drift are defined in %/s, not
as absolute SmO₂ percentages. Rates are considerably more stable between
sessions than absolute values.

**SmO₂ Control Index (SCI).** A dimensionless figure: the magnitude of the
regression slope divided by the session range, which makes it comparable across
sessions and sensor placements.

---

## 5. Display

Three layout tiers, chosen once in `onLayout()` from the rendered area. The
decision is not taken per frame, because the size never changes at runtime.

### Full: the full-screen and half-screen field

The chart appears **only** in the full-screen field and the half-screen field.
Two conditions have to hold, and both are needed:

- the usable rectangle is at least 180 × 110 px, the smallest a full-screen
  field ever gets on any supported device (the fenix 7S, at 184 × 150), so the
  chart never disappears from the layout it was designed for
- the field covers at least 45 % of the screen height and 90 % of its width

Size alone is the wrong test. The middle strip of a three-up layout is
454 × 158 px on an FR970, wider than a fenix 7S full screen, but it is not
where anyone goes looking for a trend. 45 % of the height clears a half and
excludes a third.

#### The grid

Where the field *is* the screen, four metric rows frame the chart: the state
label and the value above it, the rate and the external load below it. Where
they sit depends on the screen shape, and the rule is to **pack away from
whatever the binding constraint is**.

On a **rectangle** there is no constraint but the edges, so the rows are pinned
to the top and bottom and the chart takes everything between. Splitting a
rectangle into thirds was the first attempt and is wrong on a bike computer for
a reason that is plain in a screenshot: an Edge 1040 is 282 × 470 px, so a
third is 156 px tall while two rows of text need about 100. The chart got a
148 px band in a 470 px screen and roughly 90 px at the bottom was simply
black. Packing to the edges gives the same device a 279 px chart.

On a **round** screen the constraint is the chord, so the rows go inwards and
the tips of the circle are written off. The height is divided into three:
metrics in the top third, the chart in the middle third, metrics in the bottom
third.

A round screen has room for exactly two rows in an outer third, so the bottom
third is the rate and the load sharing one row against each end of the chord,
with **two** cells below them rather than three. At three the bottom row is
83 px of chord per cell and the numbers come out the size they were in the
gutter, which was the whole complaint. The rate's row sits nearer the middle
and is wide enough for two things.

This lays out against the whole field rather than against the inscribed
rectangle, and that is the point. The rectangle exists so that one block of
content is guaranteed to be on the glass. A single row of text needs only the
chord at its own height, and near the middle of a round screen that chord is
the full width. Working row by row is what lets the value be 72 px tall on an
FR970 rather than 78 px squeezed beside a label, and it puts the chart in the
widest part of the display instead of inset from it.

Two rows per outer third, packed against the **inner** edge and growing
outwards: the state label above the value at the top, the rate above the
external load at the bottom. Filling each third from its outer edge was tried
first and fails on a round screen for a reason that is obvious once seen: at
y = 4 on a 454 px circle the glass is 73 px wide, so whichever row got the top
of the top third could not hold a single word. Packing inwards also puts the
largest element nearest the middle, where the chord is widest, so the two
constraints agree.

The two rows of a third are sized **as a pair**, largest first, and the first
combination that fits wins. Sizing them one at a time does not work: the value
takes the largest font it can, which pushes its label into the tip of the
circle, and on an FR970 a 97 px value leaves the label a 167 px chord where
"DRIFTING" plus a light needs 180. Giving up one font step on the value buys
the label two, which is the better trade and not one a greedy search can find.

The rate is capped at three quarters of the value's height rather than at the
band. Its string is three times as long, so at equal heights it takes three
times the ink and reads as the headline. SmO₂ is the headline.

Height caps on the rectangular layout are fractions of the field rather than
of a band, so a tall screen does not produce absurd text. On every current Edge
they do not even bind: the device's largest number font is shorter than the cap,
so the text is as large as the device offers and the chart gets the rest.

Anything smaller than the whole screen falls back to one header row and one
footer row inside the usable rectangle: value beside state, rate beside load,
and the range as `41-71` between them where the two leave space for it. That
last one is not decoration: without it a short chart has no vertical scale at
all.

#### What is in it

- **Value**: the SmO₂ reading in the state colour, with the **coloured state
  light** and its label on the row above. It is the same disc the chart-less
  tiers show, so one visual vocabulary runs across every size of the field
- **Chart**: the trace over the chart window (default 90 s), each segment
  coloured by the state at that point, with the **area beneath it filled** in a
  darkened version of the same colour. A thin line has to be found; a filled
  shape is simply seen.
- **Gridlines** at the top, middle and bottom of the range. No labels in the
  plot: the bounds are cells in the grid below it.
- **Cell grid** under the chart, each cell a small grey caption over the
  number: **MIN** and **MAX**, plus **PACE** where there is a column for it.
  This is where the bounds used to be printed, in a gutter cut out of the
  chart's left edge and set in the axis font. That made the two numbers the
  whole chart is measured against the smallest text in the field, which on an
  Edge is 11 px, and it cost the plot a fifth of its width to do so. In the
  grid they are the same size as every other metric and the plot gets its full
  width back.
- **Lap markers** as vertical lines
- **Forecast needle**: a triangle on the right-hand edge, pointing in at the
  level the trend is heading to, in the state colour. It reads the way a
  dashboard pointer does, which is the whole idea: a mark on the outside of the
  scale saying where the value is going, not a data point of its own. It
  replaced a small grey dot that sat inside the trace and read as a stray
  sample.
- **Rate** in the state colour, and the **external load** below it. Decoupling
  turns the load red and appends `DEC`; the row is sized once for the widest
  string it can ever hold, and spelling the word out in full would cost the
  pace two font steps for a flag the colour already carries.

SCI is not displayed. It is dimensionless and hard to read in motion, and the
rate says the same thing in units you can act on. It is still written to FIT.

### Medium (from 120 × 70 px) and Compact (anything smaller)

A **traffic light** and one number, as a single group centred in the cell:
light first, number after it. Reading order runs left to right, so the verdict
arrives before the value it qualifies. The disc is exactly as tall as the
digits. Anything else and the pair reads as two elements at two scales rather
than as one thing.

A coloured disc is recognised pre-attentively, which a word is not. An unlit
light is drawn as a grey ring rather than as nothing, so a sensor dropout does
not look like a layout fault.

The number is configurable: **SmO₂**, the **rate of change**, **THb** or the
**control index**. The colour never changes meaning with it.

Where there is height for it, the Medium tier adds a **second line**, and its
default is the **rate of change**. That is the more informative number: the
state classification is computed from the rate, so it is what moves before the
colour does. It can also be set to the name of the metric, or switched off. If
the main number is already the rate, the second line falls back to the name
rather than saying the same thing twice.

### Displayed rate

The displayed slope is the regression slope, not the fast Holt trend. A number
that disagreed with the colour would only confuse.

The unit is switchable between **%/s** and **%/min**. %/s is the natural unit
of the regression, but at a plateau it reads −0.01 and every interesting digit
is past the decimal point; %/min moves the numbers into a range that can be
compared at a glance.

### Colours and symbols

The default is the intuitive traffic-light mapping. The colour-blind variant
replaces the red/green axis with a blue/magenta axis (cyan / white / violet /
amber / magenta), which stays distinguishable under deuteranopia and protanopia.

A palette swap is still only one channel, though, and about one man in twelve
cannot read the one this field leans on hardest. So the state light also
carries a **symbol**, and the five form a family: how many chevrons, and which
way up.

| State | Symbol |
|---|---|
| RECOVER | one chevron up |
| HOLDING | one horizontal bar |
| DRIFTING | one chevron down |
| FALLING | two chevrons down, stacked |
| ONSET | a bar with a chevron falling away below it |

They are strokes rather than filled symbols, because a stroke keeps its
identity at twelve pixels across where a filled symbol turns into a blob, and
they are knocked out of the disc in the background colour so each reads as a
hole in the light rather than as a second object on top of it. Connect IQ has
no round line caps, so a disc is drawn at every vertex of the polyline; that is
what gives the rounded ends and corners. The two-element symbols are drawn
slightly smaller and lighter than the one-element ones, or the upper element
runs out through the edge of the circle.

Below a radius of 7 px there is no room for a symbol and the disc carries the
meaning alone.

The same symbols work in bright sun, through a wet screen, and on the greyscale
MIP displays where the palette collapses anyway, so they are on by default
rather than hidden behind the colour-blind setting.

---

## 6. Pace/power coupling and decoupling detection

When enabled, the field shows the external load, chosen by sport: **power in
watts on the bike, pace everywhere else**. Running by watts is a minority taste
and running power from a watch is noisy, so pace is the running default. Pace
follows the watch's own units, so a statute user is not handed min/km.

The informative moment is **decoupling**. The coefficient of variation of the
load is computed over a 30-second window. If it is below 4 %, meaning the external load
is constant, while SmO₂ is simultaneously in CONTROL or OVER, the field shows
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
codes are checked on the *raw* fields before scaling and yield `null`, never
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
| `smo2`, smoothed muscle oxygenation | % |
| `smo2Trend`, regression slope | %/s |
| `sci`, SmO₂ Control Index | none |
| `smo2State`, state as a number | none |
| `thb`, total haemoglobin | g/dl |

**Lap fields** (in the lap summary):

| Field | Unit |
|---|---|
| `lapDesatRate`, desaturation rate `(end − start) / lap duration` | %/s |
| `lapOnKinRate`, steepest on-transient slope | %/s |
| `lapSmo2Min`, `lapSmo2Max` | % |

**Session field:** `avgSmo2`, the session average. The average only advances while
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
| `yAxisMode` | Auto | Auto (last minutes) / session range / fixed 20 to 80 % / fixed 0 to 100 % |
| `baselineSec` | 60 | Length of baseline collection |
| `colorBlind` | off | Colour-blind palette |
| `stateIcons` | on | Draw a symbol inside the state light, so the verdict does not rest on hue alone |
| `plainLabels` | on | Name the states in plain words (RECOVER/HOLDING/DRIFTING/FALLING/ONSET) instead of kinetically (REOXY/STEADY/CONTROL/OVER/ON-KIN) |
| `smallMetric` | SmO₂ | What the chart-less tiers show beside the traffic light: SmO₂, rate of change, THb or the control index |
| `smallSecond` | Rate | Second line under that number: nothing, the name of the metric, or the rate of change |
| `rateUnit` | %/s | Unit of the displayed rate: %/s or %/min |
| `rangeScope` | Session | Whether MIN/MAX and the session y-axis mode report the whole session or the current lap |
| `showPace` | on | Pace/power line including the decoupling flag |
| `recordFit` | on | Write SmO₂ fields to the FIT file |

Floating-point settings are stored as integers (× 100 or × 1000) because the
Connect IQ settings editor does not offer reliable float input across all
devices.

The y axis never uses 0 to 100 %: in practice a Moxy lives between roughly 20 and
80 %, and spending half the pixels on values that never occur throws away
exactly the resolution that matters.

The default **auto** mode scales to what is on screen, with a **floor of 25
percentage points** on the visible span. That floor is the whole safeguard.
Without it a dead-flat plateau would be zoomed until its own noise filled the
chart and looked like violent oscillation, the precise opposite of the reading
the field exists to convey. Measured across five sessions, a 90 s window spans a
median of 4.8 points inside a plateau and 22.5 through an on-transient, so a
floor of 25 keeps a plateau to about a fifth of the height while a genuine
desaturation still fills the frame. **Session range** mode is the alternative:
a scale that never moves, at the cost of the trace often using little of the
chart. Which extremes "session" means is itself a setting: the whole session
answers "where is this sitting in my range today", the current lap answers
"what has this interval done", and which is the useful frame depends on
whether the ride is structured.

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

**`tools/fitreader.py`** is a dependency-free FIT decoder, with no `pip install`
required. It reads SmO₂ from the native record fields and auto-detects developer
fields written by other recording apps, whose field name contains the sensor ID.
Lap end times are derived from `start_time + total_elapsed_time`, because not
every writer sets `lap.timestamp` correctly.

**`--synthetic` mode** generates a session with known ground truth: two
sustainable and two unsustainable intervals, serving as a regression test for
the classification.

---

## 11. Device support

55 products with an ANT+ radio: Forerunner 245 to 970, Fenix 6 through 8, Epix
Gen 2, Enduro, MARQ Gen 2, and Edge 530 through 1050. Devices without an ANT+
radio cannot talk to a Moxy at all and are deliberately excluded.

Permissions required: ANT, FitContributor. Interface languages: English and
German.

---

## 12. Known limitations

**The simulator cannot supply SmO₂.** The Connect IQ simulator's FIT playback
does not drive generic ANT channels. In the simulator the field sits at `SEARCH`
permanently, and that is correct behaviour. Live data needs SimulANT+ with an ANT
USB stick; model work should use the replay tool.

**θ_drift rests on weaker evidence than θ_stable.** In the five sessions used
for calibration, every work interval reached a plateau, because they were executed
correctly. That leaves no genuine "above threshold" interval, so the drift
boundary still comes from synthetic data. A session with a deliberately too-hard
start would pin that threshold down empirically.

**Not implemented:** a modelled "SmO₂ cost per unit of pace", and analysis of
the reoxygenation overshoot during recovery.
