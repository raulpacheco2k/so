#!/usr/bin/env bash

# Mantem a saida do i3status e, ao mesmo tempo, recebe os eventos de clique
# enviados pelo i3bar. Em um pipeline comum, o stdin fica preso ao primeiro
# processo e o filtro Python nunca recebe esses eventos.
set -Eeuo pipefail

I3STATUS="${I3STATUS_BIN:-/usr/bin/i3status}"
PYTHON="${PYTHON_BIN:-/usr/bin/python3}"
CONFIG="${I3STATUS_CONFIG:-$HOME/.config/i3status/config}"
FILTER="${I3STATUS_FILTER:-$HOME/.config/i3status/i3status_filter.py}"
WIFI_MENU="${WIFI_MENU:-$HOME/.config/i3/wifi-menu.sh}"
BLUETOOTH_MENU="${BLUETOOTH_MENU:-$HOME/.config/i3/bluetooth-menu.sh}"
AUDIO_MENU="${AUDIO_MENU:-$HOME/.config/i3/audio-menu.sh}"
JQ="${JQ_BIN:-/usr/bin/jq}"
EVENT_LOG="${WIFI_EVENT_LOG:-/tmp/i3status-click-events.log}"
PIPELINE_PID=""

cleanup() {
    if [[ -n "$PIPELINE_PID" ]] && kill -0 "$PIPELINE_PID" 2>/dev/null; then
        kill "$PIPELINE_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM

dispatch_menu() {
    local event="$1"
    local menu="$2"
    local name="$3"

    if [[ ! -x "$menu" || ! -x "$JQ" ]]; then
        return 0
    fi
    if "$JQ" -e --arg expected_name "$name" \
        '(.name == $expected_name and .button == 1)' \
        <<<"$event" >/dev/null 2>&1; then
        # O menu nao pode herdar o stdin da barra: se herdasse, poderia
        # consumir o fluxo de cliques e deixar o i3bar sem eventos depois da
        # primeira abertura.
        "$menu" </dev/null >/dev/null 2>&1 &
    fi
}

"$I3STATUS" -c "$CONFIG" </dev/null \
    | "$PYTHON" "$FILTER" &
PIPELINE_PID=$!

# O i3bar envia um objeto JSON por clique. O wrapper consome somente esse
# canal de controle; a saida do i3status continua indo diretamente para ele.
while IFS= read -r event; do
    # O log de cliques e diagnostico: uma falha de escrita nunca pode derrubar
    # o wrapper da barra.
    printf '%s\n' "$event" >>"$EVENT_LOG" 2>/dev/null || true
    # Em arrays JSON enviados pelo i3bar, o primeiro evento nao tem prefixo
    # e os seguintes comecam por uma virgula. O jq precisa receber o objeto
    # sem esse separador para reconhecer todos os cliques.
    event="${event#,}"
    dispatch_menu "$event" "$WIFI_MENU" wireless
    dispatch_menu "$event" "$BLUETOOTH_MENU" bluetooth
    dispatch_menu "$event" "$AUDIO_MENU" volume
done

wait "$PIPELINE_PID"
