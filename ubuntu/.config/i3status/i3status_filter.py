#!/usr/bin/env python3

import glob
import json
import os
import re
import subprocess
import sys
import time

RE_PCT = re.compile(r"(\d+)(?:[.,]\d+)?%")
CPU_LEADING_ZERO = re.compile(r"^(\D*)0(\d+%)")

YELLOW = "#ffd54f"
RED = "#ff6b6b"
GREEN = "#5ad15a"
GRAY = "#8d8d8d"

WIFI_MENU = os.environ.get(
    "WIFI_MENU", os.path.expanduser("~/.config/i3/wifi-menu.sh")
)
BLUETOOTH_MENU = os.environ.get(
    "BLUETOOTH_MENU", os.path.expanduser("~/.config/i3/bluetooth-menu.sh")
)
AUDIO_MENU = os.environ.get(
    "AUDIO_MENU", os.path.expanduser("~/.config/i3/audio-menu.sh")
)
BLUETOOTHCTL = os.environ.get(
    "BLUETOOTHCTL_BIN", os.environ.get("BLUETOOTHCTL", "bluetoothctl")
)

# Frequencias de atualizacao (segundos) dos segmentos que rodam subprocessos.
# A barra inteira e emitida a cada `interval` do i3status/config (5s); esses
# TTLs segmentam o trabalho pesado para nao rodar em todo ciclo:
# - Bluetooth: `bluetoothctl` e o mais custoso; o cache tambem e invalidado
#   imediatamente quando o bluetooth-menu.sh toca BLUETOOTH_EPOCH.
# - Volume: `pactl` e barato, mas nao precisa ser consultado a cada ciclo.
BLUETOOTH_EPOCH = os.environ.get(
    "BLUETOOTH_EPOCH", "/tmp/i3status-bluetooth.epoch"
)
BLUETOOTH_TTL = float(os.environ.get("I3STATUS_BLUETOOTH_TTL", "15"))
VOLUME_TTL = float(os.environ.get("I3STATUS_VOLUME_TTL", "2"))

SEGMENT_CACHE = {}

BATTERY_ICON = "󰁹"
BATTERY_LOW_ICON = "󰂃"
BATTERY_CHARGING_ICON = "󰂄"
BLUETOOTH_ON_ICON = "󰂯"
BLUETOOTH_OFF_ICON = "󰂲"

WIFI_STRENGTH_ICONS = (
    "󰤯",  # 0: wifi-strength-outline
    "󰤟",  # 1: wifi-strength-1
    "󰤢",  # 2: wifi-strength-2
    "󰤥",  # 3: wifi-strength-3
    "󰤨",  # 4: wifi-strength-4
)
WIFI_STRENGTH_ICON_RE = re.compile("|".join(map(re.escape, WIFI_STRENGTH_ICONS)))
BACKLIGHT_ICONS = tuple(chr(codepoint) for codepoint in (0xF00DE, 0xF00DF, 0xF00E0))
DEVICE_LINE_RE = re.compile(
    r"^\s*Device\s+([0-9A-Fa-f:]{17})(?:\s+(.*?))?\s*$"
)
CONTROLLER_LINE_RE = re.compile(r"^\s*Controller\s+\S+", re.MULTILINE)
ANSI_ESCAPE_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def wireless_icon(segment):
    text = segment.get("full_text", "")
    match = RE_PCT.search(text)
    if not match:
        return
    quality = max(0, min(100, int(match.group(1))))
    level = 0 if quality == 0 else min(4, (quality + 24) // 25)
    text = WIFI_STRENGTH_ICON_RE.sub("", text)
    text = re.sub(r"\s+", " ", text).strip()
    segment["full_text"] = f"{WIFI_STRENGTH_ICONS[level]} {text}"


def bluetoothctl_output(*args):
    try:
        result = subprocess.run(
            [BLUETOOTHCTL, *args],
            capture_output=True,
            text=True,
            env=dict(os.environ, LC_ALL="C"),
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return result.stdout


def bluetoothctl_snapshot():
    """Read the controller and device states with one bluetoothctl client."""
    commands = "show\ndevices Paired\ndevices Connected\nquit\n"
    try:
        result = subprocess.run(
            [BLUETOOTHCTL],
            input=commands,
            capture_output=True,
            text=True,
            env=dict(os.environ, LC_ALL="C", TERM="dumb"),
            timeout=4,
        )
    except (OSError, subprocess.TimeoutExpired):
        return "", {}, {}, False

    output = ANSI_ESCAPE_RE.sub("", result.stdout.replace("\r", ""))
    paired_marker = list(re.finditer(r"devices Paired\s*$", output, re.MULTILINE))
    connected_marker = list(
        re.finditer(r"devices Connected\s*$", output, re.MULTILINE)
    )
    if not paired_marker or not connected_marker:
        return output, {}, {}, False

    paired_start = paired_marker[-1].end()
    connected_start = connected_marker[-1].end()
    paired = parse_devices(output[paired_start : connected_marker[-1].start()])
    connected = parse_devices(output[connected_start:])
    return output[: paired_marker[-1].start()], paired, connected, True


def parse_devices(output):
    devices = {}
    for line in output.splitlines():
        match = DEVICE_LINE_RE.match(line)
        if match:
            devices[match.group(1)] = (match.group(2) or "").strip()
    return devices


def _epoch_mtime(path):
    try:
        return os.stat(path).st_mtime
    except OSError:
        return 0.0


def _cache_get(key, ttl, epoch_path):
    entry = SEGMENT_CACHE.get(key)
    if entry is None:
        return None
    when, epoch_mtime, value = entry
    if time.time() - when >= ttl or _epoch_mtime(epoch_path) > epoch_mtime:
        return None
    return value


def _cache_set(key, value, epoch_path):
    SEGMENT_CACHE[key] = (time.time(), _epoch_mtime(epoch_path), value)


def bluetooth_segment():
    cached = _cache_get("bluetooth", BLUETOOTH_TTL, BLUETOOTH_EPOCH)
    if cached is not None:
        return cached

    controller, paired, connected, parsed_snapshot = bluetoothctl_snapshot()
    if not parsed_snapshot:
        # Older bluetoothctl versions may not echo commands in batch mode.
        # The fallback is intentionally used only when the grouped query could
        # not be parsed, avoiding a process fan-out on modern BlueZ versions.
        controller = bluetoothctl_output("show")
        paired = parse_devices(bluetoothctl_output("devices", "Paired"))
        connected = parse_devices(bluetoothctl_output("devices", "Connected"))

    if not CONTROLLER_LINE_RE.search(controller):
        segment = {
            "name": "bluetooth",
            "markup": "none",
            "full_text": f"{BLUETOOTH_OFF_ICON} sem controlador",
        }
        _cache_set("bluetooth", segment, BLUETOOTH_EPOCH)
        return segment

    blocked = re.search(
        r"^\s*PowerState:\s+off-blocked\s*$", controller, re.MULTILINE
    )
    powered_match = re.search(r"^\s*Powered:\s+(yes|no)\s*$", controller, re.MULTILINE)
    if blocked:
        segment = {
            "name": "bluetooth",
            "markup": "none",
            "full_text": f"{BLUETOOTH_OFF_ICON} bloqueado",
        }
        _cache_set("bluetooth", segment, BLUETOOTH_EPOCH)
        return segment
    if not powered_match or powered_match.group(1) != "yes":
        segment = {
            "name": "bluetooth",
            "markup": "none",
            "full_text": f"{BLUETOOTH_OFF_ICON} Desligado",
            "color": GRAY,
        }
        _cache_set("bluetooth", segment, BLUETOOTH_EPOCH)
        return segment

    bluetooth_icon = BLUETOOTH_ON_ICON

    if not paired:
        paired = parse_devices(bluetoothctl_output("paired-devices"))
    names = [name for name in connected.values() if name]

    if not names:
        text = f"{bluetooth_icon} Ligado"
    elif len(names) == 1:
        text = f"{bluetooth_icon} {names[0]}"
    else:
        shown = ", ".join(names[:2])
        if len(names) > 2:
            shown += ", ..."
        text = f"{bluetooth_icon} {len(names)} conectados: {shown}"

    segment = {"name": "bluetooth", "markup": "none", "full_text": text}
    _cache_set("bluetooth", segment, BLUETOOTH_EPOCH)
    return segment


def inject_bluetooth(segments):
    synthetic = bluetooth_segment()
    for index, segment in enumerate(segments):
        if segment.get("name") == "bluetooth":
            segments[index] = synthetic
            return

    insert_at = 0
    for index, segment in enumerate(segments):
        if segment.get("name") in ("wireless", "ethernet"):
            insert_at = index + 1
    segments.insert(insert_at, synthetic)


def pulse_volume_probe():
    try:
        env = dict(os.environ, LC_ALL="C")
        vol = subprocess.run(
            ["pactl", "get-sink-volume", "@DEFAULT_SINK@"],
            capture_output=True,
            text=True,
            env=env,
            timeout=2,
        )
        mut = subprocess.run(
            ["pactl", "get-sink-mute", "@DEFAULT_SINK@"],
            capture_output=True,
            text=True,
            env=env,
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"(\d+)%", vol.stdout)
    if not m:
        return None
    return int(m.group(1)), "yes" in mut.stdout.split()


def wpctl_default_id(role):
    try:
        result = subprocess.run(
            ["wpctl", "status"],
            capture_output=True,
            text=True,
            env=dict(os.environ, LC_ALL="C"),
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return ""
    lines = result.stdout.splitlines()
    inside = False
    for line in lines:
        if line.strip().endswith(role + ":"):
            inside = True
            continue
        if not inside:
            continue
        if re.match(r"^\s*[├└]──", line):
            break
        m = re.match(r"^\s*(?:│\s*)?\*\s*(\d+)\.", line)
        if m:
            return m.group(1)
    return ""


def wpctl_volume_probe():
    node_id = wpctl_default_id("Sinks")
    if not node_id:
        return None
    try:
        result = subprocess.run(
            ["wpctl", "get-volume", node_id],
            capture_output=True,
            text=True,
            env=dict(os.environ, LC_ALL="C"),
            timeout=2,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r"([0-9]+(?:\.[0-9]+)?)", result.stdout)
    if not m:
        return None
    pct = round(float(m.group(1)) * 100)
    return pct, "[MUTED]" in result.stdout


def volume_segment():
    cached = _cache_get("volume", VOLUME_TTL, "")
    if cached is not None:
        return cached
    for probe in (pulse_volume_probe, wpctl_volume_probe):
        result = probe()
        if result is None:
            continue
        pct, muted = result
        if muted or pct == 0:
            icon = chr(0xF075F)
        elif pct > 60:
            icon = chr(0xF057E)
        else:
            icon = chr(0xF0580)
        segment = {"name": "volume", "markup": "none", "full_text": f"{icon} {pct}%"}
        _cache_set("volume", segment, "")
        return segment
    return None


def backlight_segment():
    paths = glob.glob("/sys/class/backlight/*/brightness")
    if not paths:
        return None
    brightness = max_brightness = None
    try:
        with open(paths[0]) as f:
            brightness = int(f.read().strip())
        with open(paths[0].replace("brightness", "max_brightness")) as f:
            max_brightness = int(f.read().strip())
    except (OSError, ValueError):
        return None
    if not max_brightness:
        return None
    pct = round(brightness / max_brightness * 100)
    level = min(2, (pct * 3) // 100)
    icon = BACKLIGHT_ICONS[level]
    return {"name": "backlight", "markup": "none", "full_text": f"{icon} {pct}%"}


def battery_icon(segment, pct):
    status_path = os.path.join(
        os.path.dirname(segment.get("instance", "")), "status"
    )
    try:
        with open(status_path) as f:
            status = f.read().strip()
    except OSError:
        status = ""

    if status in ("Charging", "Full"):
        return BATTERY_CHARGING_ICON
    if pct <= 20:
        return BATTERY_LOW_ICON
    return BATTERY_ICON


def recolor(segments):
    inject_bluetooth(segments)
    for i, seg in enumerate(segments):
        if seg.get("name") == "wireless":
            wireless_icon(seg)
        if seg.get("name") == "cpu_usage":
            seg["full_text"] = CPU_LEADING_ZERO.sub(
                r"\1\2", seg.get("full_text", ""), count=1
            )
        if seg.get("name") != "battery":
            continue
        m = RE_PCT.search(seg.get("full_text", ""))
        if not m:
            continue
        pct = int(m.group(1))
        seg["full_text"] = re.sub(
            r"^\S+", battery_icon(seg, pct), seg.get("full_text", ""), count=1
        )
        if pct <= 10:
            seg["color"] = RED
        elif pct <= 20:
            seg["color"] = YELLOW
        elif pct == 100:
            seg["color"] = GREEN
        else:
            seg.pop("color", None)
    # Volume e brilho ficam antes da data/hora, sem depender da presenca de
    # bateria no host (desktops e notebooks sem bateria tambem tem volume).
    insert_index = len(segments)
    for i, seg in enumerate(segments):
        if seg.get("name") == "tztime":
            insert_index = i
            break
    for seg in (volume_segment(), backlight_segment()):
        if seg is not None:
            segments.insert(insert_index, seg)
            insert_index += 1
    return segments


def handle_click(event):
    menu = {
        "wireless": WIFI_MENU,
        "bluetooth": BLUETOOTH_MENU,
        "volume": AUDIO_MENU,
    }.get(event.get("name"))
    if not menu or event.get("button") != 1:
        return
    if not os.access(menu, os.X_OK):
        return
    try:
        subprocess.Popen(
            [menu],
            env=os.environ.copy(),
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except OSError:
        return


for line in sys.stdin:
    stripped = line.lstrip()
    if stripped.startswith("{"):
        try:
            object_payload = json.loads(stripped)
        except json.JSONDecodeError:
            sys.stdout.write(line)
            sys.stdout.flush()
            continue

        if object_payload.get("version") == 1:
            object_payload["click_events"] = True
            sys.stdout.write(
                json.dumps(object_payload, ensure_ascii=False, separators=(",", ":"))
                + "\n"
            )
        else:
            handle_click(object_payload)
        sys.stdout.flush()
        continue

    leading_comma = stripped.startswith(",[")
    if leading_comma:
        prefix = ","
        payload = line[1:].strip()
    elif stripped.startswith("["):
        prefix = ""
        payload = line.strip()
    else:
        continue

    if payload in ("", "[", "]"):
        sys.stdout.write(line)
        sys.stdout.flush()
        continue

    try:
        segments = json.loads(payload)
        output = json.dumps(
            recolor(segments), ensure_ascii=False, separators=(",", ":")
        )
    except json.JSONDecodeError:
        continue

    sys.stdout.write(f"{prefix}{output}\n")
    sys.stdout.flush()
