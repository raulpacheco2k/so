#!/usr/bin/env bash
# Omarchy "Vantablack" style lock screen for i3
set -e

generate_image() {
    python3 - <<'EOF'
import os
import re
import subprocess
import tempfile

from PIL import Image

BG = (13, 13, 13)

monitors = []

raw = subprocess.run(["xrandr", "--listmonitors"], capture_output=True, text=True).stdout
for line in raw.splitlines():
    m = re.match(r"^\s*\d+:\s+\S+\s+(\d+)(?:/\d+)?x(\d+)(?:/\d+)?\+(\d+)\+(\d+)", line)
    if m:
        w, h, x, y = map(int, m.groups())
        monitors.append((x, y, w, h))

if not monitors:
    raw = subprocess.run(["xrandr", "--current"], capture_output=True, text=True).stdout
    for line in raw.splitlines():
        m = re.search(r"(\S+) connected(?:\s+primary)??\s+(\d+)x(\d+)\+(\d+)\+(\d+)", line)
        if m:
            w, h, x, y = map(int, m.groups()[1:])
            monitors.append((x, y, w, h))

if not monitors:
    monitors = [(0, 0, 1920, 1080)]

vh = max(y + h for _, y, _, h in monitors)
vw = max(x + w for x, _, w, _ in monitors)

img = Image.new("RGB", (vw, vh), BG)

fd, path = tempfile.mkstemp(suffix=".png", prefix="i3lock-vantablack-")
os.close(fd)
img.save(path)
print(path)
EOF
}

LOCK_IMAGE="$(generate_image)"

exec "$HOME/.local/bin/i3lock" -n -i "$LOCK_IMAGE" \
    --radius=40 \
    --ring-width=4 \
    --ring-color=8d8d8d \
    --inside-color=0d0d0d \
    --line-color=00000000 \
    --keyhl-color=ececec \
    --bshl-color=8d8d8d \
    --ringver-color=3fb950 \
    --insidever-color=0d0d0d \
    --verif-color=3fb950 \
    --ringwrong-color=e5484d \
    --insidewrong-color=2a0a0c \
    --wrong-color=e5484d \
    --wrong-text="" \
    --verif-text="" \
    --noinput-text="" \
    --lock-text="" \
    --lockfailed-text="" \
    --ignore-empty-password