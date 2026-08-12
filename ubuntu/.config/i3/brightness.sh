#!/usr/bin/env bash
# Ajusta o brilho em passos de 5%, sempre terminando em 0 ou 5 (mesmo
# tratamento de arredondamento do volume em audio-lib.sh). O i3status exibe o
# resultado, atualizado pelo binding (killall -SIGUSR1 i3status).
set -Eeuo pipefail

ACTION="${1:-up}"
STEP=5
MAX_PERCENT=100

current="$(
    brightnessctl -m | awk -F, '$2 == "backlight" { gsub(/%/, "", $4); print $4; exit }'
)"
[[ -n "$current" ]] || exit 1

if [[ "$ACTION" == up ]]; then
    next=$(( (current / STEP + 1) * STEP ))
else
    next=$(( ((current + STEP - 1) / STEP - 1) * STEP ))
fi
((next > MAX_PERCENT)) && next=$MAX_PERCENT
((next < 0)) && next=0

brightnessctl set "${next}%"
