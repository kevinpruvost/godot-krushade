#!/usr/bin/env python3
"""Validate GPU pixels against analytic fixture motion (not RID availability only)."""
import argparse
import json
from pathlib import Path


def validate(data, expect_mrt=False):
    errors = []
    phases = {}
    for record in data["records"]:
        phase = record["phase"]
        phases.setdefault(phase, []).append(record)
        if phase == "request_off":
            if record["available"] or record["owned"] or record["rid"]:
                errors.append("request off did not release velocity")
            continue
        if not record["available"] or not record["owned"]:
            errors.append(f"{phase}: native buffer unavailable")
            continue
        if expect_mrt and record.get("separate_depth") is not False:
            errors.append(f"{phase}: separate depth allocated on expected MRT path")
        for axis, (actual, expected) in enumerate(zip(record["measured"], record["expected"])):
            # Half float quantization plus pixel-centre/projected-float rounding.
            tolerance = max(2e-6, abs(expected) * .003)
            if abs(actual - expected) > tolerance:
                errors.append(f"{phase}/{record['tick']}: axis {axis}: {actual} != {expected}")
        if any(abs(x) > 1e-7 for x in record["background"]):
            errors.append(f"{phase}: background contains stale velocities")
    expected_phases = {"stationary", "rigid_xy", "camera_xy", "bone_xy", "bone_stopped", "rigid_depth", "jitter_only", "request_off", "request_on", "resize"}
    if set(phases) != expected_phases or any(len(rows) != 4 for rows in phases.values()):
        errors.append("Incomplete phase/sample coverage")
    if not errors:
        first = phases["stationary"][0]["rid"]
        for phase in expected_phases - {"request_off", "request_on", "resize"}:
            if any(r["rid"] != first for r in phases[phase]):
                errors.append(f"{phase}: texture unexpectedly reallocated")
        on = phases["request_on"][0]["rid"]
        resized = phases["resize"][0]["rid"]
        if first == on or on == resized:
            errors.append("off/on or resize did not create a new texture")
        if len({tuple(r["size"]) for r in phases["resize"]}) != 1 or phases["resize"][0]["size"] == phases["stationary"][0]["size"]:
            errors.append("resize did not update texture dimensions")
    return {"ok": not errors, "records": len(data["records"]), "phases": len(phases), "errors": errors}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("result", type=Path)
    parser.add_argument("--expect-mrt", action="store_true")
    args = parser.parse_args()
    result = validate(json.loads(args.result.read_text()), args.expect_mrt)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result["ok"] else 1)
