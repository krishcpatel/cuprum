#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-3.0-only
"""Reproduce the Apple framework mapping experiment, independently of Minecraft."""
import json
import platform
import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/verification/metal-only"


def run(args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def main():
    if platform.system() != "Darwin":
        raise SystemExit("This experiment requires macOS and Xcode Command Line Tools.")
    OUTPUT.mkdir(parents=True, exist_ok=True)
    results = {"host": run(["sw_vers"]), "linked": {}, "dlopen": {}}
    variants = {
        "baseline": [], "foundation": ["Foundation"], "metal": ["Metal"],
        "quartzcore": ["QuartzCore"], "cocoa": ["Cocoa"],
        "metal_foundation": ["Metal", "Foundation"],
    }
    for name, frameworks in variants.items():
        executable = OUTPUT / name
        command = ["xcrun", "clang", "-O3", "-Wall", "-Wextra", "-Werror",
                   "-mmacosx-version-min=11.0", str(ROOT / "scripts/metal-library-probe.c"),
                   "-o", str(executable)]
        for framework in frameworks:
            command += ["-framework", framework]
        run(command)
        output = run([str(executable)])
        links = run(["otool", "-L", str(executable)])
        (OUTPUT / (name + ".txt")).write_text(output + "\n" + links)
        results["linked"][name] = output
        print(name + ": " + output.splitlines()[-1])
    for name in ("Metal", "QuartzCore", "Cocoa"):
        path = f"/System/Library/Frameworks/{name}.framework/{name}"
        output = run([str(OUTPUT / "baseline"), path])
        (OUTPUT / ("dlopen_" + name + ".txt")).write_text(output)
        results["dlopen"][name] = output
        counts = [line for line in output.splitlines() if line.endswith("OpenGL.framework images")]
        print("dlopen " + name + ": " + "; ".join(counts))
    for name in ("Metal", "QuartzCore", "AppKit"):
        version = "C" if name == "AppKit" else "A"
        path = f"/System/Library/Frameworks/{name}.framework/Versions/{version}/{name}"
        output = run(["xcrun", "dyld_info", "-linked_dylibs", path])
        (OUTPUT / (name + "-linked-dylibs.txt")).write_text(output)
        print(name + " OpenGL load commands: " + "; ".join(
            line.strip() for line in output.splitlines() if "/OpenGL.framework/" in line))
    native = ROOT / "build/generated/metal-native/native/macos-universal/libcuprum_metal.dylib"
    if native.exists():
        output = run(["xcrun", "dyld_info", "-imports", str(native)])
        (OUTPUT / "cuprum-native-imports.txt").write_text(output)
        imports = [line for line in output.splitlines()
                   if re.search(r"\b_?(?:gl[A-Z]\w*|CGL[A-Z]\w*|vk[A-Z]\w*|SDL_GL_\w*)\b", line)]
        results["cuprum_direct_graphics_imports"] = imports
        print("Cuprum direct GL/CGL/Vulkan/SDL_GL imports:", imports)
    (OUTPUT / "matrix.json").write_text(json.dumps(results, indent=2) + "\n")
    print("Evidence:", OUTPUT)


if __name__ == "__main__":
    main()
