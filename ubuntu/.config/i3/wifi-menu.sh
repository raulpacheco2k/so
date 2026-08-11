#!/usr/bin/env bash

# Menu Wi-Fi do i3status: usa dmenu no X11 (com fallback para Walker) e o
# NetworkManager como backend. O applet de bandeja nao e necessario para
# consultar ou ativar redes.
set -Eeuo pipefail

DEBUG_LOG="${WIFI_MENU_DEBUG_LOG:-/tmp/wifi-menu-debug.log}"
exec 8>>"$DEBUG_LOG"
BASH_XTRACEFD=8
PS4='+ ${BASH_SOURCE}:${LINENO}: '
set -x

export LC_ALL=C

WALKER="${WALKER_BIN:-$HOME/.local/bin/walker}"
DMENU="${WIFI_MENU_BIN:-/usr/bin/dmenu}"
NMCLI="${NMCLI_BIN:-/usr/bin/nmcli}"
ALACRITTY="${ALACRITTY_BIN:-/usr/bin/alacritty}"
NM_EDITOR="${NM_CONNECTION_EDITOR_BIN:-/usr/bin/nm-connection-editor}"
WIFI_DEVICE=""

if [[ ! -x "$NMCLI" ]]; then
    exit 0
fi
if [[ ! -x "$DMENU" && ! -x "$WALKER" ]]; then
    exit 0
fi

# Evita que cliques repetidos abram varios Walkers ou varias operacoes no
# NetworkManager ao mesmo tempo.
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/wifi-menu-$(id -u).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

wifi_device() {
    "$NMCLI" -t -e no -f DEVICE,TYPE device status 2>/dev/null \
        | awk -F: '$2 == "wifi" { print $1; exit }'
}

wifi_radio_state() {
    "$NMCLI" -t radio wifi 2>/dev/null || true
}

current_connection() {
    local device="$1"

    [[ -n "$device" ]] || return 0
    "$NMCLI" -t -e no -f GENERAL.CONNECTION device show "$device" 2>/dev/null \
        | sed 's/^GENERAL.CONNECTION://' \
        | sed 's/ (externally managed)$//' \
        | sed -n '1p'
}

connection_is_saved() {
    local ssid="$1"

    "$NMCLI" -t -e no -f profile connection show id "$ssid" 2>/dev/null \
        | grep -Fxq 'connection.type:802-11-wireless'
}

signal_icon() {
    local signal="$1"

    if ((signal >= 75)); then
        printf '󰤨'
    elif ((signal >= 50)); then
        printf '󰤥'
    elif ((signal >= 25)); then
        printf '󰤢'
    else
        printf '󰤟'
    fi
}

MENU_LABELS=()
MENU_KINDS=()
MENU_VALUES=()
NETWORK_COUNT=0

add_entry() {
    MENU_LABELS+=("$1")
    MENU_KINDS+=("$2")
    MENU_VALUES+=("${3:-}")
}

radio_state="$(wifi_radio_state)"
WIFI_DEVICE="$(wifi_device)"
CURRENT_SSID="$(current_connection "$WIFI_DEVICE")"

if [[ "$radio_state" == enabled ]]; then
    add_entry "󰤮  Desativar Wi-Fi" radio-off
else
    add_entry "󰤨  Ativar Wi-Fi" radio-on
fi

add_entry "󰒓  Gerenciar conexoes" editor

if [[ -n "$CURRENT_SSID" && "$CURRENT_SSID" != "--" ]]; then
    add_entry "󰖪  Desconectar de $CURRENT_SSID" disconnect
fi

declare -A SEEN_SSIDS=()
while IFS= read -r row; do
    [[ -n "$row" ]] || continue

    # A SSID pode conter ':'. Por isso os dois ultimos campos sao separados
    # primeiro, preservando o restante como o nome da rede.
    active="${row%%:*}"
    rest="${row#*:}"
    security="${rest##*:}"
    middle="${rest%:*}"
    signal="${middle##*:}"
    ssid="${middle%:*}"

    [[ -n "$ssid" ]] || continue
    [[ "$signal" =~ ^[0-9]+$ ]] || signal=0
    [[ -n "${SEEN_SSIDS[$ssid]+present}" ]] && continue
    SEEN_SSIDS["$ssid"]=1
    NETWORK_COUNT=$((NETWORK_COUNT + 1))

    saved=""
    if connection_is_saved "$ssid"; then
        saved=" · salva"
    fi
    state=""
    if [[ "$active" == '*' ]]; then
        state=" · conectada"
    fi
    security_label=""
    if [[ -n "$security" && "$security" != "--" ]]; then
        security_label=" · $security"
    fi

    add_entry "$(signal_icon "$signal")  $ssid · ${signal}%${security_label}${saved}${state}" connect "$ssid"
done < <(
    "$NMCLI" -t -e no -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null || true
)

if ((NETWORK_COUNT == 0)); then
    add_entry "󰤭  Nenhuma rede encontrada" noop
fi

choice=""
if [[ -x "$DMENU" ]]; then
    # dmenu e nativo do X11/i3. As cores sao argumentos para manter a
    # personalizacao local e evitar depender de um tema GTK/Wayland.
    selected="$(printf '%s\n' "${MENU_LABELS[@]}" \
        | "$DMENU" -i -l 10 -p 'Wi-Fi' \
            -fn 'JetBrainsMono Nerd Font:size=10' \
            -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000')" || true
    for index in "${!MENU_LABELS[@]}"; do
        if [[ "${MENU_LABELS[$index]}" == "$selected" ]]; then
            choice="$index"
            break
        fi
    done
elif [[ -x "$WALKER" ]]; then
    choice="$(printf '%s\n' "${MENU_LABELS[@]}" \
        | "$WALKER" --dmenu --index --exit --theme vantablack \
            --width 644 --height 570 --placeholder 'Wi-Fi')" || true
fi

[[ "$choice" =~ ^[0-9]+$ ]] || exit 0
((choice < ${#MENU_KINDS[@]})) || exit 0

kind="${MENU_KINDS[$choice]}"
value="${MENU_VALUES[$choice]}"

# Nao mantenha o lock aberto nos comandos iniciados pela acao escolhida.
exec 9>&-

case "$kind" in
    radio-off)
        "$NMCLI" radio wifi off
        ;;
    radio-on)
        "$NMCLI" radio wifi on
        ;;
    editor)
        if [[ -x "$NM_EDITOR" ]]; then
            "$NM_EDITOR" >/dev/null 2>&1 &
        fi
        ;;
    disconnect)
        [[ -n "$WIFI_DEVICE" ]] && "$NMCLI" device disconnect "$WIFI_DEVICE"
        ;;
    connect)
        if connection_is_saved "$value"; then
            "$NMCLI" connection up id "$value"
        elif [[ -x "$ALACRITTY" ]]; then
            # A senha de uma rede nova e solicitada dentro de um TTY, sem
            # depender de um agente de segredos residente na bandeja.
            "$ALACRITTY" --title "Conectar ao Wi-Fi" -e "$NMCLI" \
                --ask device wifi connect "$value" >/dev/null 2>&1 &
        fi
        ;;
    noop)
        ;;
esac

pkill -USR1 -x i3status 2>/dev/null || true
