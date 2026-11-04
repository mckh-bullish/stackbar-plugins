#!/usr/bin/env python3
"""Checks one plugin's demo loop in demos.json (see scripts/publish.sh).

    STACKBARCTL=<stackbarctl> python3 scripts/check_demo.py <plugin.swift> <plugin id>

Records the demo the way publish does, with --verbose, and fails when a step
names an action the plugin has no handler for, or when the loop never
changes (a typo'd event would otherwise record a still picture). Off macOS
stackbarctl prints the frames as text, which is what the comparison reads.
"""
import json, os, re, subprocess, sys, tempfile

source, plugin = sys.argv[1], sys.argv[2]
demos = json.load(open("demos.json"))
spec = demos.get(plugin)
if spec is None:
    sys.exit(0)
problems = []
if not isinstance(spec.get("steps"), list) or not all(isinstance(step, str) for step in spec["steps"]):
    sys.exit(f"demos.json: {plugin} needs \"steps\", a list of stackbarctl render arguments")
with tempfile.TemporaryDirectory() as folder:
    result = subprocess.run(
        [os.environ["STACKBARCTL"], "render", source, "--preview", spec.get("preview", "hero"),
         "--surface", spec.get("surface", "panel"), "--frames", os.path.join(folder, "demo.png"), "--verbose", *spec["steps"]],
        capture_output=True, text=True)
    if result.returncode != 0:
        sys.exit(f"demo for {plugin} failed:\n{result.stderr.strip()}")
    for line in result.stderr.splitlines():
        if "no handler for action" in line or "failed" in line:
            problems.append(line.strip())
    frames = re.split(r"^== frame \d+ \([0-9.]+ s\) ==$", result.stdout, flags=re.M)[1:]
    if frames:
        # Text frames (Linux): the surface part must change at least once.
        surfaces = [frame.split("== commands ==")[0] for frame in frames]
        if len(set(surfaces)) < 2:
            problems.append("every frame is the same; check the steps' action ids")
        print(f"   demo: {len(frames)} frames, {len(set(surfaces))} different")
    elif not os.path.isfile(os.path.join(folder, "demo.png")):
        problems.append("no animated PNG was written")
    else:
        print(f"   demo: {os.path.getsize(os.path.join(folder, 'demo.png')) // 1024} KB")
if problems:
    sys.exit(f"demo for {plugin}:\n  " + "\n  ".join(problems))
