---
name: simulate
description: Run this Connect IQ data field in the Garmin simulator, check the layout tiers, or feed it SmO2 data. Use when asked to run, simulate, test on a device, take a screenshot, or check how the field looks.
---

# Simulate

```bash
./simulate.sh              # fr970 (reference device)
./simulate.sh fenix847mm
./simulate.sh edge1040
```

The script builds, resets the simulator's stored properties so defaults from
`resources/base/properties.xml` apply, launches `ConnectIQ.app` if it is not
already running, and pushes the app with `monkeydo`.

## The one thing to know before testing

**The simulator cannot feed SmO2 data.** This field owns a generic ANT channel,
and the simulator's FIT playback does not drive generic ANT channels — only
native sensor data. So on a plain simulator run the field will sit in `SEARCH`
forever. That is correct behaviour, not a bug. Do not "fix" it.

What this means in practice:

| Goal | Works in simulator? |
|---|---|
| Layout tiers, fonts, geometry, obscurity | yes |
| Settings UI, property defaults | yes |
| Sensor state machine (SEARCH / STALE / NO ANT) | yes, the failure paths |
| Live SmO2 values, trend, colours, chart | **no** — needs SimulANT+ |
| The kinetics model | use `tools/kinetics_replay.py` instead |

To get real SmO2 into the simulator you need **SimulANT+** plus an ANT USB
stick, broadcasting the Muscle Oxygen profile. Set up an interval ramp
(fast fall → plateau → recovery) to exercise the state machine.

For anything about whether the *algorithm* is right, do not use the simulator —
replay data through `tools/kinetics_replay.py`, which runs the same model
offline against real `.fit` files or synthetic sessions.

## Checking the layout tiers

The field picks one of three layouts in `onLayout()` from the rendered size.
To see all three, in the simulator use **Settings → Data Fields** (or configure
the activity profile) to place the field in a 1-up, 2-up and 4-up layout. The
thresholds live at the top of `source/SmO2ControlView.mc`:

- Full (chart + metrics): >= 200 x 150 px
- Medium (value + mini sparkline): >= 120 x 70 px
- Compact (colour + value): anything smaller

Simulator pixel sizes differ slightly from real hardware, so treat borderline
cases as needing a check on the watch.

## Screenshots

In the simulator: **File → Save Screenshot**. Saved under the simulator's
working directory.

## Settings

Change live via **Edit → Settings** in the simulator UI. Defaults come from
`resources/base/properties.xml`. `simulate.sh` deletes the stored `.SET` file
each run, so edits made in a previous run do not silently persist.
