#!/usr/bin/env bash
set -Eeuo pipefail

case "${1:-}" in
    info)
        printf 'Server Name: PulseAudio (on PipeWire 1.0)\n'
        ;;
    list)
        # No Bluetooth endpoints are exposed. An audio-capable device will
        # therefore wait, while a HID device should return before that wait.
        ;;
    get-default-sink|get-default-source)
        ;;
    set-default-sink|set-default-source|move-sink-input|move-source-output)
        ;;
    *)
        ;;
esac
