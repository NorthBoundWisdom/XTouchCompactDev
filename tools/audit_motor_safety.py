#!/usr/bin/env python3
"""Read-only motor safety review of an app JSONL v1 capture; never opens MIDI.

Exit 0: no recorded violations with sufficient recorded state; 1: violations;
2: invalid/unreadable evidence; 3: incomplete or insufficient state evidence.
Release windows include later explicit writes, not just release reconciliation.
No result qualifies physical hardware or measures silent firmware motor travel.
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
    header = rows[0]
    if (
        header.get("kind") != "capture-start"
        or type(header.get("schemaVersion")) is not int
        or header["schemaVersion"] != 1
    ):
        raise CaptureError("expected app capture schema v1")
    if not isinstance(header.get("session"), dict):
        raise CaptureError("missing session metadata")
    events = []
    complete = False
    for row in rows[1:]:
        if complete:
            raise CaptureError("record after capture-end")
        if row.get("kind") == "event":
            if type(row.get("sequence")) is not int or row["sequence"] != len(events) + 1:
                raise CaptureError("invalid event sequence")
            events.append(row)
        elif (
            row.get("kind") == "capture-end" and type(row.get("eventCount")) is int and row["eventCount"] == len(events)
        ):
            complete = True
        else:
            raise CaptureError("invalid record or event count")
    return events, complete, header["session"]


def route_identity(value, generation_key):
    required = (generation_key, "connectedInput", "connectedOutput")
    if not isinstance(value, dict) or any(key not in value for key in required):
        raise CaptureError("missing connection identity metadata")
    generation = value[generation_key]
    if generation is not None and (type(generation) is not int or generation < 0):
        raise CaptureError("invalid connection generation")
    ids = []
    for key in required[1:]:
        endpoint = value[key]
        if endpoint is None:
            ids.append(None)
        elif isinstance(endpoint, dict) and type(endpoint.get("id")) is int and endpoint["id"] != 0:
            ids.append(endpoint["id"])
        else:
            raise CaptureError("invalid endpoint identity")
    return (*ids, generation)


def midi_bytes(row):
    raw = row.get("rawMIDI1Bytes")
    if raw is None:
        if row.get("direction") is not None:
            raise CaptureError(f"missing MIDI bytes at sequence {row['sequence']}")
        return None
    if (
        row.get("direction") not in ("IN", "OUT")
        or not isinstance(raw, list)
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
    events, complete, session = read_capture(data)
    route = route_identity(session, "connectionGeneration")
    if (
        "hardwareMode" not in session
        or session["hardwareMode"] is not None
        and type(session["hardwareMode"]) is not bool
    ):
        raise CaptureError("missing or invalid session mode")
    mode = session["hardwareMode"]
    if "configuredTransmitChannel" not in session:
        raise CaptureError("missing session TX channel")
    tx_channel = session["configuredTransmitChannel"]
    if tx_channel is not None and (type(tx_channel) is not int or not 1 <= tx_channel <= 16):
        raise CaptureError("invalid session TX channel")
    touches = {}  # Unknown at prefix start, never assume released.
    observed_layer = None
    releases = []
    active_releases = {}
    under_touch, during_mismatch, layer_under_touch = [], [], []
    unknown_touch, unknown_layer, unknown_delivery = [], [], []
    unknown_route, layer_unknown_touch, layer_unknown_route = [], [], []
    boundaries = []
    motors = assertions = 0

    def finish_window(fader, reason, sequence):
        if fader in active_releases:
            window = active_releases.pop(fader)
            window.update(endReason=reason, endSequence=sequence, motorCount=len(window["motorSequences"]))

    def boundary(reason, sequence):
        nonlocal observed_layer, touches
        for fader in list(active_releases):
            finish_window(fader, reason, sequence)
        observed_layer = None
        # A hand may have arrived during a gap. Only the conservative held latch survives.
        touches = {fader: True for fader, held in touches.items() if held}
        boundaries.append({"sequence": sequence, "reason": reason})

    for row in events:
        sequence = row["sequence"]
        if (
            type(row.get("hardwareMode")) is not bool
            or type(row.get("ignored")) is not bool
            or row.get("source") not in ("hardware", "mock", "agent", "application")
            or row.get("hostLayer") not in ("a", "b")
            or type(row.get("transmitChannel")) is not int
            or not 1 <= row["transmitChannel"] <= 16
        ):
            raise CaptureError(f"missing or invalid event metadata at sequence {sequence}")
        raw = midi_bytes(row)
        if row["hardwareMode"] != mode:
            boundary("hardware-mode-change", sequence)
            mode = row["hardwareMode"]
        if tx_channel is not None and row["transmitChannel"] != tx_channel:
            boundary("transmit-channel-change", sequence)
        tx_channel = row["transmitChannel"]
        if "connection" in row:
            next_route = route_identity(row["connection"], "generation")
            if next_route != route or None in next_route:
                boundary("connection-change", sequence)
            route = next_route
        if raw is None or row["source"] == "mock":
            continue
        if row["direction"] == "IN":
            if row.get("delivery") != "received" or row["source"] != "hardware":
                raise CaptureError(f"invalid input delivery/source at sequence {sequence}")
            if raw[0] & 0xF != tx_channel - 1 or row["ignored"]:
                continue
            layer, touch = input_layer_and_touch(raw)
            if layer and mode:
                observed_layer = layer
            # Hardware safety touch is authoritative even while the host uses Mock.
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
        if not mode:
            if row["source"] == "hardware":
                raise CaptureError(f"hardware output with Mock mode at sequence {sequence}")
            continue  # Agent feedback in Mock does not reach hardware.
        is_motor = raw[0] & 0xF0 == 0xB0 and 1 <= raw[1] <= 9
        is_layer = raw[0] & 0xF0 == 0xC0 and raw[1] in (0, 1)
        if row.get("delivery") != "sent":
            if (is_motor or is_layer) and row.get("delivery") not in ("suppressed", "failed"):
                unknown_delivery.append(sequence)
            continue
        # Count motor addresses even on a misconfigured RX: actual RX is unverified.
        if is_motor:
            motors += 1
            fader = raw[1]
            if touches.get(fader) is True:
                under_touch.append(sequence)
            if fader not in touches:
                unknown_touch.append(sequence)
            if None in route:
                unknown_route.append(sequence)
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
            if len(touches) < 9:
                layer_unknown_touch.append(sequence)
            if None in route:
                layer_unknown_route.append(sequence)
            observed_layer = None  # Sent assertion invalidates evidence, never acknowledges.
    for fader in list(active_releases):
        finish_window(fader, "capture-end" if complete else "incomplete-prefix", len(events))
    violations = len(under_touch) + len(during_mismatch) + len(layer_under_touch)
    sufficient = complete and not any(
        (unknown_touch, unknown_layer, unknown_delivery, unknown_route, layer_unknown_touch, layer_unknown_route)
    )
    assessment = "violations" if violations else "no-recorded-violations" if sufficient else "inconclusive"
    return {
        "schemaVersion": 1,
        "sha256": hashlib.sha256(data).hexdigest(),
        "eventCount": len(events),
        "complete": complete,
        "evidenceSufficient": sufficient,
        "assessment": assessment,
        "motorOutputs": motors,
        "layerAssertions": assertions,
        "motorWhileTouched": under_touch,
        "motorDuringLayerMismatch": during_mismatch,
        "layerAssertionWhileTouched": layer_under_touch,
        "releaseWindows": releases,
        "motorWithUnknownTouch": unknown_touch,
        "motorWithUnknownLayer": unknown_layer,
        "motorWithUnknownRoute": unknown_route,
        "layerAssertionWithUnknownTouch": layer_unknown_touch,
        "layerAssertionWithUnknownRoute": layer_unknown_route,
        "outputsWithUnknownDelivery": unknown_delivery,
        "stateBoundaries": boundaries,
        "recordedViolationCount": violations,
        "qualification": "Recorded evidence only; unknown initial state and unreported firmware travel are not verified. 未在实机复核。",
        "releaseWindowMeaning": "Counts until next same-fader touch, state boundary or capture end; includes later explicit writes, not proof of release catch-up.",
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
    return {"no-recorded-violations": 0, "violations": 1, "inconclusive": 3}[result["assessment"]]


if __name__ == "__main__":
    sys.exit(main())
