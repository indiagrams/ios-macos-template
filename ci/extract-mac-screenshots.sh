#!/bin/bash
# ci/extract-mac-screenshots.sh — pull macOS App Store screenshots out of an
# xcresult bundle.
#
# Why this exists: fastlane snapshot is iOS-only. The macOS screenshot pipeline
# is XCUITest + XCTAttachment, which writes attachments into the .xcresult.
# This script extracts the PNGs and copies them into
# fastlane/screenshots/en-US/, where `fastlane upload_screenshots` (deliver)
# infers the macOS device type from the PNG dimensions (2880×1800 → APP_DESKTOP).
#
# Why en-US/ directly and not en-US/Mac/: deliver's loader globs
# `<lang>/*.png` and only expands `iMessage` / `appleTV` subdirectories.
# Files in arbitrary subfolders like `Mac/` are silently ignored.
#
# Usage:
#   ci/extract-mac-screenshots.sh <path-to.xcresult>
#
# Output: fastlane/screenshots/en-US/macos-*.png

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ $# -lt 1 ]; then
  sed -n 's/^# \?//p' "$0" | head -15
  exit 2
fi

XCRESULT="$1"
if [ ! -d "$XCRESULT" ]; then
  echo "error: xcresult bundle not found: $XCRESULT" >&2
  exit 2
fi

# Write into en-US/ directly. Subfolders other than iMessage/appleTV are
# silently ignored by deliver's screenshot loader.
OUT_DIR="$REPO_ROOT/fastlane/screenshots/en-US"
mkdir -p "$OUT_DIR"

# Clear any prior macos-*.png to avoid stale duplicates if attachment names
# changed. Don't touch iOS PNGs — fastlane snapshot writes them flat to the
# same en-US/ folder with device-prefixed names like
# "iPhone 16 Plus-01-home.png".
rm -f "$OUT_DIR"/macos-*.png

# xcrun xcresulttool's --legacy flag is required on Xcode 16+ where the new
# default JSON format dropped attachment listings. Attachments are nested
# inside ActionTestSummary refs reached via References at the test-summary
# level — Python walks the tree, follows References as needed.
python3 - "$XCRESULT" "$OUT_DIR" <<'PY'
import json
import os
import subprocess
import sys

xcresult, out_dir = sys.argv[1], sys.argv[2]


def get_json(*args):
    """Fetch JSON via xcresulttool. Some refs aren't JSON (binary payloads);
    swallow stderr noise and return None so callers can skip them gracefully."""
    cmd = ["xcrun", "xcresulttool", "get", "--legacy",
           "--path", xcresult, "--format", "json", *args]
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL)
        return json.loads(out)
    except (subprocess.CalledProcessError, json.JSONDecodeError):
        return None


def collect_attachments(obj, hits):
    """Walk dict/list and collect every attachment reachable in this object."""
    if isinstance(obj, dict):
        t = obj.get("_type", {}).get("_name", "")
        if "Attachment" in t:
            name = (obj.get("name", {}).get("_value")
                    or obj.get("filename", {}).get("_value", ""))
            payload = obj.get("payloadRef", {}).get("id", {}).get("_value", "")
            if name and payload:
                hits.append((name, payload))
        for v in obj.values():
            collect_attachments(v, hits)
    elif isinstance(obj, list):
        for v in obj:
            collect_attachments(v, hits)


def collect_references(obj, refs):
    """Walk dict/list and collect every Reference's id (for follow-up fetch)."""
    if isinstance(obj, dict):
        t = obj.get("_type", {}).get("_name", "")
        if t == "Reference":
            rid = obj.get("id", {}).get("_value", "")
            if rid:
                refs.append(rid)
        for v in obj.values():
            collect_references(v, refs)
    elif isinstance(obj, list):
        for v in obj:
            collect_references(v, refs)


# Start at the top of the xcresult, find the testsRef, walk down through
# Reference chains until we hit attachments. Cap depth at 5 to avoid cycles.
visited = set()
attachments = []
work = [None]  # None = top-level
depth = 0

while work and depth < 5:
    next_work = []
    for ref_id in work:
        args = ("--id", ref_id) if ref_id else ()
        if ref_id in visited:
            continue
        if ref_id:
            visited.add(ref_id)
        data = get_json(*args)
        if data is None:
            continue  # not a JSON ref — likely a binary payload, skip
        collect_attachments(data, attachments)
        # Find any nested References to recurse into.
        nested = []
        collect_references(data, nested)
        for n in nested:
            if n not in visited:
                next_work.append(n)
    work = next_work
    depth += 1

# Dedupe by name (keep first occurrence).
seen = set()
unique = []
for name, payload in attachments:
    # Strip the xcresult-temp suffix that Xcode appends to attachment filenames:
    # "macos-01-home_0_F8D23318-...png" → keep our XCTAttachment.name "macos-01-home"
    # Logic: prefer the .name (set via attachment.name = "..."); only fall back to filename.
    # Already done above (name preferred), so just normalize PNG suffix here.
    if not name.lower().endswith(".png"):
        name = f"{name}.png"
    if name in seen:
        continue
    seen.add(name)
    unique.append((name, payload))

if not unique:
    print(f"error: no attachments found in {xcresult}", file=sys.stderr)
    sys.exit(1)

# Apple App Store macOS screenshot sizes — exact match required, no flexibility.
APPLE_SIZES = [(2880, 1800), (2560, 1600), (1440, 900), (1280, 800)]

def crop_to_apple_size(path):
    """Crop a window screenshot to the nearest Apple App Store macOS size.
    Window screenshots include the macOS title bar (~64px @2x) above the content,
    which makes them slightly taller than Apple's accepted sizes. Crop the
    bottom (whitespace below content) to preserve the title bar — that's the
    most informative part of the frame for App Store browsers."""
    out = subprocess.check_output(
        ["sips", "-g", "pixelWidth", "-g", "pixelHeight", path]
    ).decode()
    w = h = 0
    for line in out.splitlines():
        if "pixelWidth" in line:  w = int(line.split(":")[1])
        if "pixelHeight" in line: h = int(line.split(":")[1])
    if not (w and h):
        return False
    # Find the largest accepted size that fits within the captured image.
    target = next(((tw, th) for tw, th in APPLE_SIZES
                   if tw <= w and th <= h), None)
    if not target:
        print(f"    warn: {os.path.basename(path)} ({w}x{h}) is smaller than every Apple-accepted size; left as-is",
              file=sys.stderr)
        return False
    tw, th = target
    if (w, h) == (tw, th):
        return True
    # Vertical: shift crop center up by (h-th)/2 so the bottom is dropped.
    # Horizontal: center.
    offset_y = -((h - th) // 2)
    subprocess.run(
        ["sips", "-c", str(th), str(tw),
         "--cropOffset", str(offset_y), "0",
         path, "--out", path],
        check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    print(f"    cropped: {os.path.basename(path)} {w}x{h} → {tw}x{th}")
    return True


count = 0
for name, payload in unique:
    out_path = os.path.join(out_dir, name)
    subprocess.run(
        ["xcrun", "xcresulttool", "get", "--legacy",
         "--path", xcresult, "--id", payload],
        stdout=open(out_path, "wb"),
        check=True,
    )
    size = os.path.getsize(out_path)
    print(f"    extracted: {name} ({size:,} bytes)")
    crop_to_apple_size(out_path)
    count += 1

print(f"    ✓ {count} screenshot(s) → {out_dir}")
PY
