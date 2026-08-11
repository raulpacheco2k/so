#!/usr/bin/env bash
# Ajusta o volume do sink padrao via pactl ou wpctl (a camada comum detecta o
# backend da sessao). O i3status exibe o resultado, atualizado pelo binding
# (killall -SIGUSR1 i3status).
set -Eeuo pipefail

SCRIPT_PATH="$(readlink -f -- "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd -- "$(dirname -- "$SCRIPT_PATH")" && pwd)"
# shellcheck source=audio-lib.sh
. "$SCRIPT_DIR/audio-lib.sh"

ACTION="${1:-toggle}"
STEP=5
MAX_PERCENT=100

case "$ACTION" in
    up|down)
        audio_volume_step sink "$ACTION" "$STEP" "$MAX_PERCENT"
        ;;
    mute)
        audio_mute_toggle sink
        ;;
    source-mute)
        audio_mute_toggle source
        ;;
    *)
        echo "uso: vol {up|down|mute|source-mute}" >&2
        exit 1
        ;;
esac
