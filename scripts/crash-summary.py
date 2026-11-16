#!/usr/bin/env python3
"""Summarise an iOS .ips crash report: exception, termination reason and the crashed thread's
frames, with the app's own frames symbolicated by atos against a local build.

Usage: scripts/crash-summary.py <report.ips> [path/to/TactileTexts.app]
Without the .app, app frames are shown as image+offset. The build must be the one that crashed
(the report's image UUIDs are checked against it).
"""
import json
import os
import subprocess
import sys


def load(path):
    with open(path) as f:
        header = f.readline()
        body = f.read()
    try:
        return json.loads(header), json.loads(body)
    except json.JSONDecodeError:
        return {}, json.loads(header + body)


def binary_uuid(path):
    out = subprocess.run(["dwarfdump", "--uuid", path], capture_output=True, text=True).stdout
    return {line.split()[1].lower() for line in out.splitlines() if line.startswith("UUID:")}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    header, r = load(sys.argv[1])
    app = sys.argv[2] if len(sys.argv) > 2 else None
    images = r.get("usedImages", [])

    # Images that belong to the app bundle, mapped to their binary in the local build.
    local = {}
    if app and os.path.isdir(app):
        for i, im in enumerate(images):
            p = im.get("path", "")
            if ".app/" in p and "/Frameworks/" not in p:
                candidate = os.path.join(app, os.path.basename(p))
                if os.path.exists(candidate):
                    ok = im.get("uuid", "").lower() in binary_uuid(candidate)
                    local[i] = (candidate, im, ok)

    print(f"App:        {header.get('app_name', r.get('procName'))} {header.get('app_version', '')} "
          f"({header.get('build_version', '')})  {header.get('timestamp', r.get('captureTime', ''))}")
    print(f"OS:         {header.get('os_version', '')}")
    exc = r.get("exception", {})
    print(f"Exception:  {exc.get('type', '?')} {exc.get('signal', '')} {exc.get('subtype', '')}".rstrip())
    term = r.get("termination", {})
    if term:
        print(f"Termination: {term.get('namespace', '')} {term.get('indicator', '')} "
              f"{' '.join(term.get('reasons', []))}".rstrip())
    asi = r.get("asi")
    if asi:
        for k, v in asi.items():
            for line in v:
                print(f"ASI {k}: {line}")
    if any(not ok for _, _, ok in local.values()):
        print("Note: the local build's UUID does not match the report; app symbols may be wrong.")

    threads = r.get("threads", [])
    ft = r.get("faultingThread")
    crashed = threads[ft] if ft is not None and ft < len(threads) else next(
        (t for t in threads if t.get("triggered")), None)
    if not crashed:
        print("No crashed thread in the report.")
        return 0
    name = crashed.get("name") or crashed.get("queue") or ""
    print(f"\nCrashed thread {ft} {name}:")
    for n, fr in enumerate(crashed.get("frames", [])[:40]):
        idx = fr.get("imageIndex")
        im = images[idx] if idx is not None and idx < len(images) else {}
        imname = im.get("name") or os.path.basename(im.get("path", "?"))
        sym = fr.get("symbol")
        where = ""
        if sym:
            where = f"{sym} + {fr.get('symbolLocation', 0)}"
        if idx in local:
            binary, image, _ = local[idx]
            load_addr = image["base"]
            addr = load_addr + fr["imageOffset"]
            out = subprocess.run(
                ["atos", "-o", binary, "-arch", image.get("arch", "arm64"), "-l", hex(load_addr), hex(addr)],
                capture_output=True, text=True).stdout.strip()
            if out and not out.startswith("0x"):
                where = out
        if not where:
            where = f"+{fr.get('imageOffset', 0):#x}"
        src = ""
        if fr.get("sourceFile"):
            src = f"  ({fr['sourceFile']}:{fr.get('sourceLine', '?')})"
        print(f"  {n:2d} {imname:28.28s} {where}{src}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
