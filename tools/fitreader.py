#!/usr/bin/env python3
"""Minimal FIT decoder — just enough to pull SmO2 out of a Garmin activity.

Deliberately dependency-free: this has to run on any machine with a Python 3
without a pip install. It decodes only what the tuning workflow needs — record
messages, lap boundaries and developer field descriptions — and ignores
everything else in the file.

SmO2 can reach a FIT file two ways, and both are handled:

  * native   record.saturated_hemoglobin_percent (field 57, scale 10)
             record.total_hemoglobin_conc        (field 54, scale 100)
    written when the watch has the Moxy paired as a native sensor.

  * developer fields written by this data field itself ("smo2", "smo2Trend",
    ...). Note these are already smoothed, so replaying them re-smooths an
    smoothed signal. Prefer the native fields when both are present.

Run directly to inspect a file:

    ./fitreader.py activity.fit
"""

from __future__ import annotations

import struct
import sys
from dataclasses import dataclass, field as dc_field

# FIT epoch: 1989-12-31T00:00:00Z, in Unix seconds.
FIT_EPOCH = 631065600

# base type id -> (struct char, size, invalid value)
BASE_TYPES = {
    0x00: ("B", 1, 0xFF),          # enum
    0x01: ("b", 1, 0x7F),          # sint8
    0x02: ("B", 1, 0xFF),          # uint8
    0x83: ("h", 2, 0x7FFF),        # sint16
    0x84: ("H", 2, 0xFFFF),        # uint16
    0x85: ("i", 4, 0x7FFFFFFF),    # sint32
    0x86: ("I", 4, 0xFFFFFFFF),    # uint32
    0x07: ("s", 1, 0x00),          # string
    0x88: ("f", 4, 0xFFFFFFFF),    # float32
    0x89: ("d", 8, 0xFFFFFFFFFFFFFFFF),  # float64
    0x0A: ("B", 1, 0x00),          # uint8z
    0x8B: ("H", 2, 0x0000),        # uint16z
    0x8C: ("I", 4, 0x00000000),    # uint32z
    0x0D: ("B", 1, 0xFF),          # byte
    0x8E: ("q", 8, 0x7FFFFFFFFFFFFFFF),  # sint64
    0x8F: ("Q", 8, 0xFFFFFFFFFFFFFFFF),  # uint64
    0x90: ("Q", 8, 0x00000000000000000),  # uint64z
}

MSG_RECORD = 20
MSG_LAP = 19
MSG_SESSION = 18
MSG_FIELD_DESCRIPTION = 206

# record message fields we care about
REC_TIMESTAMP = 253
REC_THB = 54
REC_SMO2 = 57

LAP_TIMESTAMP = 253       # nominally the lap end time
LAP_START_TIME = 2
LAP_ELAPSED = 7           # total_elapsed_time, milliseconds


class FitError(Exception):
    pass


@dataclass
class FieldDef:
    num: int
    size: int
    base_type: int


@dataclass
class DevFieldDef:
    num: int
    size: int
    dev_index: int


@dataclass
class MessageDef:
    global_num: int
    endian: str
    fields: list[FieldDef] = dc_field(default_factory=list)
    dev_fields: list[DevFieldDef] = dc_field(default_factory=list)

    @property
    def size(self) -> int:
        return sum(f.size for f in self.fields) + sum(f.size for f in self.dev_fields)


@dataclass
class FitData:
    """Everything the tuning workflow needs out of one activity."""

    records: list[dict] = dc_field(default_factory=list)   # {t, smo2, thb, dev...}
    laps: list[tuple[float, float]] = dc_field(default_factory=list)  # (start, end)
    dev_names: dict[tuple[int, int], str] = dc_field(default_factory=dict)

    def find_smo2_field(self) -> str | None:
        """Pick the field holding SmO2, native first, else a developer field.

        Third-party Moxy recorders name their field after the sensor, e.g.
        "1st SmO2 Sensor 7929 on L. Leg" — the ID differs per sensor, so match
        on the name rather than making the caller type it.
        """
        keys = self.available_fields()
        if "smo2" in keys:
            return "smo2"
        cands = [k for k in keys
                 if "smo2" in k.lower() and "thb" not in k.lower()]
        if not cands:
            return None
        # Prefer the shortest name: "smo2" beats "smo2 trend", and a plain
        # sensor field beats a derived one.
        return min(cands, key=len)

    def smo2_series(self, prefer: str | None = None) -> list[tuple[float, float]]:
        """(seconds-from-start, SmO2 %) pairs, gaps dropped.

        `prefer` names a developer field to use instead of auto-detection.
        """
        key = prefer or self.find_smo2_field()
        if key is None:
            return []
        out: list[tuple[float, float]] = []
        t0: float | None = None
        for r in self.records:
            t = r.get("t")
            if t is None:
                continue
            v = r.get(key)
            if v is None:
                continue
            if not 0.0 <= v <= 100.0:
                continue    # invalid / ambient marker
            if t0 is None:
                t0 = t
            out.append((t - t0, v))
        return out

    def available_fields(self) -> list[str]:
        keys: set[str] = set()
        for r in self.records:
            keys.update(r.keys())
        return sorted(keys)


def _read_value(buf: bytes, off: int, fd: FieldDef, endian: str):
    spec = BASE_TYPES.get(fd.base_type)
    if spec is None:
        return None
    ch, size, invalid = spec

    if ch == "s":
        raw = buf[off:off + fd.size]
        return raw.split(b"\x00")[0].decode("utf-8", "replace") or None

    count = fd.size // size
    if count < 1:
        return None
    vals = struct.unpack_from(f"{endian}{count}{ch}", buf, off)
    vals = [None if v == invalid else v for v in vals]
    return vals[0] if count == 1 else vals


def decode(path: str) -> FitData:
    with open(path, "rb") as fh:
        buf = fh.read()

    if len(buf) < 14:
        raise FitError(f"{path}: too short to be a FIT file")

    header_size = buf[0]
    if buf[8:12] != b".FIT":
        raise FitError(f"{path}: missing .FIT signature — not a FIT file")
    data_size = struct.unpack_from("<I", buf, 4)[0]

    pos = header_size
    end = min(header_size + data_size, len(buf))

    defs: dict[int, MessageDef] = {}
    data = FitData()
    # developer_data_index, field_def_num -> (name, scale, offset)
    dev_meta: dict[tuple[int, int], tuple[str, float, float]] = {}
    pending_desc: dict[int, object] = {}

    while pos < end:
        header = buf[pos]
        pos += 1

        if header & 0x80:
            # Compressed timestamp header — the local type is in bits 5-6.
            local = (header >> 5) & 0x03
            mdef = defs.get(local)
            if mdef is None:
                raise FitError(f"{path}: data before definition (local {local})")
            pos = _read_data(buf, pos, mdef, data, dev_meta)
            continue

        local = header & 0x0F

        if header & 0x40:
            # Definition message
            pos += 1                       # reserved
            endian = "<" if buf[pos] == 0 else ">"
            pos += 1
            global_num = struct.unpack_from(f"{endian}H", buf, pos)[0]
            pos += 2
            n = buf[pos]
            pos += 1

            mdef = MessageDef(global_num, endian)
            for _ in range(n):
                mdef.fields.append(FieldDef(buf[pos], buf[pos + 1], buf[pos + 2]))
                pos += 3

            if header & 0x20:              # developer data present
                nd = buf[pos]
                pos += 1
                for _ in range(nd):
                    mdef.dev_fields.append(
                        DevFieldDef(buf[pos], buf[pos + 1], buf[pos + 2]))
                    pos += 3

            defs[local] = mdef
            continue

        mdef = defs.get(local)
        if mdef is None:
            raise FitError(f"{path}: data before definition (local {local})")
        pos = _read_data(buf, pos, mdef, data, dev_meta)

    return data


def _read_data(buf: bytes, pos: int, mdef: MessageDef, data: FitData,
               dev_meta: dict) -> int:
    values: dict[int, object] = {}
    dev_values: dict[tuple[int, int], object] = {}

    for fd in mdef.fields:
        values[fd.num] = _read_value(buf, pos, fd, mdef.endian)
        pos += fd.size

    for dfd in mdef.dev_fields:
        meta = dev_meta.get((dfd.dev_index, dfd.num))
        base = 0x84 if meta is None else meta[3]
        v = _read_value(buf, pos, FieldDef(dfd.num, dfd.size, base), mdef.endian)
        dev_values[(dfd.dev_index, dfd.num)] = v
        pos += dfd.size

    g = mdef.global_num

    if g == MSG_FIELD_DESCRIPTION:
        idx = values.get(0)
        num = values.get(1)
        base = values.get(2)
        name = values.get(3)
        scale = values.get(6)
        offset = values.get(7)
        if idx is not None and num is not None and isinstance(name, str):
            dev_meta[(idx, num)] = (
                name,
                float(scale) if isinstance(scale, (int, float)) and scale else 1.0,
                float(offset) if isinstance(offset, (int, float)) and offset else 0.0,
                base if isinstance(base, int) else 0x84,
            )
            data.dev_names[(idx, num)] = name

    elif g == MSG_RECORD:
        ts = values.get(REC_TIMESTAMP)
        rec: dict[str, float] = {}
        if isinstance(ts, int):
            rec["t"] = float(ts)
        smo2 = values.get(REC_SMO2)
        if isinstance(smo2, (int, float)):
            rec["smo2"] = smo2 / 10.0
        thb = values.get(REC_THB)
        if isinstance(thb, (int, float)):
            rec["thb"] = thb / 100.0
        for key, v in dev_values.items():
            meta = dev_meta.get(key)
            if meta is None or not isinstance(v, (int, float)):
                continue
            name, scale, offset = meta[0], meta[1], meta[2]
            rec[name] = v / scale - offset
        if rec:
            data.records.append(rec)

    elif g == MSG_LAP:
        start = values.get(LAP_START_TIME)
        elapsed = values.get(LAP_ELAPSED)
        endt = values.get(LAP_TIMESTAMP)
        if isinstance(start, int):
            # Prefer start + elapsed. Not every writer sets lap.timestamp to
            # the lap end — some Connect IQ recorders leave it at the file
            # creation time, which would collapse every lap to zero length.
            if isinstance(elapsed, (int, float)):
                data.laps.append((float(start), float(start) + elapsed / 1000.0))
            elif isinstance(endt, int) and endt > start:
                data.laps.append((float(start), float(endt)))

    return pos


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 1
    for path in argv:
        try:
            d = decode(path)
        except (FitError, OSError, struct.error) as e:
            print(f"{path}: {e}", file=sys.stderr)
            continue
        series = d.smo2_series()
        print(f"{path}")
        print(f"  records        {len(d.records)}")
        print(f"  laps           {len(d.laps)}")
        print(f"  SmO2 samples   {len(series)}")
        if series:
            vals = [v for _, v in series]
            print(f"  SmO2 range     {min(vals):.1f} – {max(vals):.1f} %")
            print(f"  duration       {series[-1][0]:.0f} s")
        print(f"  fields         {', '.join(d.available_fields())}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
