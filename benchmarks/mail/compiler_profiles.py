#!/usr/bin/env python3
"""Invariant: profile comparison never changes the release build settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time

from corpus import corpus
from run import html_semantics, measured_cases, mime_semantics, stats


def binary_identity(path):
    content = path.read_bytes()
    return dict(sha256=hashlib.sha256(content).hexdigest(), bytes=len(content))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--size", type=Path, required=True)
    parser.add_argument("--speed", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    payload = dict(cases=corpus(), samples=31, batch=3, phases=["mime", "readprep"])
    outputs = {}
    paths = {"size": args.size.resolve(), "speed": args.speed.resolve()}
    binaries = {name: binary_identity(path) for name, path in paths.items()}
    load = os.getloadavg()
    for name, path in paths.items():
        result = subprocess.run([str(path)], input=json.dumps(payload), text=True,
                                capture_output=True, check=True, timeout=180)
        outputs[name] = measured_cases(json.loads(result.stdout), payload)
    if any(binary_identity(path) != binaries[name] for name, path in paths.items()):
        raise RuntimeError("Compiler profile executable changed during measurement")
    rows = []
    for size, speed in zip(outputs["size"], outputs["speed"], strict=True):
        normalize = mime_semantics if size["phase"] == "mime" else html_semantics
        if normalize(size["result"]) != normalize(speed["result"]):
            raise RuntimeError("Compiler profiles produced unequal output: " + size["name"])
        rows.append(dict(name=size["name"], phase=size["phase"],
                         size=stats(size), speed=stats(speed)))
    report = dict(measuredAt=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                  conditions="CPU-only diagnostic; 31 samples after five warmups, three operations per sample. "
                  "Identical synthetic input and semantic output. No network, RPC or painting. "
                  "Shared desktop, no CPU isolation. This alone does not justify changing release flags.",
                  loadBefore=load, loadAfter=os.getloadavg(), binaries=binaries, results=rows)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps([{k: v for k, v in row.items() if k not in ("size", "speed")} |
                     {"sizeP95Us": row["size"]["p95Us"], "speedP95Us": row["speed"]["p95Us"]}
                     for row in rows], indent=2))


if __name__ == "__main__":
    main()
