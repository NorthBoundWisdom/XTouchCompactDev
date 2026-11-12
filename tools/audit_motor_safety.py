#!/usr/bin/env python3
"""Read-only motor safety review of an app JSONL v1 capture; never opens MIDI.

Exit 0: no recorded violations (not hardware qualification); 1: violations;
2: invalid/unreadable evidence. Release windows end at the next same-fader touch,
connection change, or capture end. Counts include later explicit software writes;
timing alone cannot attribute a command to release reconciliation.
"""

import argparse
import hashlib
import json
import sys
from pathlib import Path


class CaptureError(ValueError):
    pass


def read_capture(data):
    if not data.endswith(b"\n"):
        raise CaptureError("partial final line")
    try:
        rows = [json.loads(line) for line in data.decode("utf-8").splitlines()]
    except (ValueError, UnicodeError) as error:
        raise CaptureError("invalid JSONL") from error
    if not rows or not all(isinstance(row, dict) for row in rows):
        raise CaptureError("expected JSON objects")
    if rows[0].get("kind") != "capture-start" or rows[0].get("schemaVersion") != 1:
        raise CaptureError("expected app capture schema v1")
    events = []
    complete = False
    for row in rows[1:]:
        if complete:
            raise CaptureError("record after capture-end")
        if row.get("kind") == "event":
            if type(row.get("sequence")) is not int or row["sequence"] != len(events) + 1:
                raise CaptureError("invalid event sequence")
            events.append(row)
        elif row.get("kind") == "capture-end" and row.get("eventCount") == len(events):
            complete = True
        else:
            raise CaptureError("invalid record or event count")
    return events, complete


def midi_bytes(row):
    raw = row.get("rawMIDI1Bytes")
    if raw is None:
        if row.get("direction") in ("IN", "OUT"):
            raise CaptureError(f"missing MIDI bytes at sequence {row['sequence']}")
        return None
    if (
        not isinstance(raw, list)
        or not raw
        or any(type(value) is not int or not 0 <= value <= 255 for value in raw)
        or not 0x80 <= raw[0] < 0xF0
        or len(raw) != (2 if raw[0] & 0xF0 in (0xC0, 0xD0) else 3)
        or any(value > 127 for value in raw[1:])
    ):
        raise CaptureError(f"invalid canonical MIDI bytes at sequence {row['sequence']}")
    return raw


def input_layer_and_touch(raw):
    """Decode factory TX space independently of the RX motor addresses."""
    status, number = raw[:2]
    kind = status & 0xF0
    if kind == 0xB0:
        for base in (101, 111):
            if base <= number < base + 9:
                return ("a" if base == 101 else "b"), (number - base + 1, raw[2] > 0)
        if 1 <= number <= 27:
            return "a", None
        if 28 <= number <= 64:
            return "b", None
    if kind in (0x80, 0x90):
        if number <= 54:
            return "a", None
        if number <= 109:
            return "b", None
    return None, None


def audit(data):
    events, complete = read_capture(data)
    touches = {}  # Unknown at prefix start, never assume released.
    observed_layer = None
    releases = []
    active_releases = {}
    under_touch = []
    during_mismatch = []
    layer_under_touch = []
    unknown_touch = []
    unknown_layer = []
    unknown_delivery = []
    motors = 0
    assertions = 0

    def finish_window(fader, reason, sequence):
        if fader in active_releases:
            window = active_releases.pop(fader)
            window.update(endReason=reason, endSequence=sequence, motorCount=len(window["motorSequences"]))

    for row in events:
        sequence = row["sequence"]
        raw = midi_bytes(row)
        if "connection" in row:
            for fader in list(active_releases):
                finish_window(fader, "connection-change", sequence)
            observed_layer = None
            # A disconnect is not a release. Keep any known held state conservatively.
        if raw is None:
            continue
        if row.get("hardwareMode") is not True or row.get("source") == "mock":
            continue
        if row.get("hostLayer") not in ("a", "b"):
            raise CaptureError(f"missing host layer at sequence {sequence}")
        if row.get("direction") == "IN":
            tx = row.get("transmitChannel")
            if type(tx) is not int or not 1 <= tx <= 16:
                raise CaptureError(f"invalid configured TX at sequence {sequence}")
            if raw[0] & 0xF != tx - 1 or row.get("ignored") is True:
                continue
            layer, touch = input_layer_and_touch(raw)
            if layer:
                observed_layer = layer
            if touch:
                fader, pressed = touch
                previous = touches.get(fader)
                touches[fader] = pressed
                if pressed:
                    finish_window(fader, "next-touch", sequence)
                elif previous is not False:
                    window = {"fader": fader, "releaseSequence": sequence, "motorSequences": []}
                    releases.append(window)
                    active_releases[fader] = window
            continue
        if row.get("direction") != "OUT":
            continue
        is_motor = raw[0] & 0xF0 == 0xB0 and 1 <= raw[1] <= 9
        is_layer = raw[0] & 0xF0 == 0xC0 and raw[1] in (0, 1)
        if row.get("delivery") != "sent":
            if (is_motor or is_layer) and row.get("delivery") not in ("suppressed", "failed"):
                unknown_delivery.append(sequence)
            continue
        # Count all sent motor addresses, even on a misconfigured RX: actual RX is unverified.
        if is_motor:
            motors += 1
            fader = raw[1]
            if touches.get(fader) is True:
                under_touch.append(sequence)
            if fader not in touches:
                unknown_touch.append(sequence)
            if observed_layer is None:
                unknown_layer.append(sequence)
            elif observed_layer != row["hostLayer"]:
                during_mismatch.append(sequence)
            if fader in active_releases:
                active_releases[fader]["motorSequences"].append(sequence)
        if is_layer:
            assertions += 1
            if any(touches.values()):
                layer_under_touch.append(sequence)
            # A sent assertion invalidates old layer evidence; it is not acknowledgement.
            observed_layer = None
    for fader in list(active_releases):
        finish_window(fader, "capture-end" if complete else "incomplete-prefix", len(events))
    violations = len(under_touch) + len(during_mismatch) + len(layer_under_touch)
    return {
        "schemaVersion": 1,
        "sha256": hashlib.sha256(data).hexdigest(),
        "eventCount": len(events),
        "complete": complete,
        "motorOutputs": motors,
        "layerAssertions": assertions,
        "motorWhileTouched": under_touch,
        "motorDuringLayerMismatch": during_mismatch,
        "layerAssertionWhileTouched": layer_under_touch,
        "releaseWindows": releases,
        "motorWithUnknownTouch": unknown_touch,
        "motorWithUnknownLayer": unknown_layer,
        "outputsWithUnknownDelivery": unknown_delivery,
        "recordedViolationCount": violations,
        "qualification": "Recorded evidence only; unknown initial state and unreported firmware travel are not verified. 未在实机复核。",
        "releaseWindowMeaning": "Counts until next same-fader touch, connection change or capture end; includes later explicit writes, not proof of release catch-up.",
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("capture", type=Path)
    args = parser.parse_args(argv)
    try:
        result = audit(args.capture.read_bytes())
    except (OSError, CaptureError) as error:
        print(f"motor audit: {error}", file=sys.stderr)
        return 2
    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 1 if result["recordedViolationCount"] else 0


if __name__ == "__main__":
    sys.exit(main())
