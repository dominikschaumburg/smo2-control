---
name: build
description: Build this Connect IQ data field — compile for one device, produce the signed .iq store package, or type-check after an edit. Use when asked to build, compile, package, type-check, or verify the project still compiles.
---

# Build

The project is Monkey C on the Garmin Connect IQ SDK. There is no Makefile or
package.json — `monkeyc` is driven directly by the two shell scripts.

## Type-check after an edit (fastest, do this by default)

Compiling for a single device is the quickest way to confirm an edit is sound.
Always pass `--typecheck 3` (Strict) — the project is written to pass it, so a
new warning is a real regression.

```bash
SDK="${CIQ_SDK:-$HOME/Library/Application Support/Garmin/ConnectIQ/Sdks/connectiq-sdk-mac-9.1.0-2026-03-09-6a872a80b}"
"$SDK/bin/monkeyc" -f monkey.jungle -o bin/test.prg -d fr970 -y developer_key --typecheck 3
```

`fr970` is the reference device (round, 454x454, the one the field is developed
against). Expect exactly `BUILD SUCCESSFUL` and nothing else.

## Full store package

```bash
./build.sh
```

Compiles every product in `manifest.xml` for every declared language and emits
`bin/SmO2Control.iq`. This takes a few minutes and reports
`N OUT OF 92 DEVICES BUILT` as it goes. Run it before publishing, or after
touching `manifest.xml` or anything under `resources/` — a resource that is
fine on one screen shape can fail on another.

## Overriding the SDK

Both scripts honour `CIQ_SDK`:

```bash
CIQ_SDK=/path/to/connectiq-sdk-mac-X.Y.Z ./build.sh
```

## When a build fails

- **`developer_key missing`** — the key is gitignored on purpose. It has to be
  present in the project root; it is not recoverable from the repo.
- **Resource errors on a subset of devices** — almost always a font or colour
  that does not exist on smaller/MIP screens. Check which device failed in the
  output; the count line tells you how far it got.
- **Type errors in `source/`** — the codebase is Strict-clean. Fix the code
  rather than lowering `--typecheck`.

## Validating the algorithm, not just the compile

A green build says nothing about whether the kinetics model still classifies
correctly. After touching `source/Kinetics.mc`, also run:

```bash
./tools/kinetics_replay.py --synthetic
```

This is a Python port of the same model against a session with known ground
truth. The invariant: sustainable intervals (`work1`, `work2`) reach `STEADY`
for a substantial share of their time, unsustainable ones (`work3`, `work4`)
essentially never do (~2 %). If that separation collapses, the change broke the
classification even though it compiled.
