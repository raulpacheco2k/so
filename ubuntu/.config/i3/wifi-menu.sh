#!/usr/bin/env bash

# Menu Wi-Fi do i3status: usa dmenu no X11 (com fallback para Walker) e o
# NetworkManager como backend. O applet de bandeja nao e necessario para
# consultar ou ativar redes. A senha de uma rede nova e informada pelo
# proprio dmenu, sem abrir aplicacoes externas.
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
NOTIFY_SEND="${NOTIFY_SEND_BIN:-notify-send}"
WIFI_DEVICE=""

if [[ ! -x "$NMCLI" ]]; then
    exit 0
fi
if [[ ! -x "$DMENU" && ! -x "$WALKER" ]]; then
    exit 0
fi

# Evita que cliques repetidos abram varios Walkers ou varias operacoes no
# NetworkManager ao mesmo tempo. O lock permanece ativo enquanto os menus
# estao na tela e so e liberado quando uma acao comeca a executar.
LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/wifi-menu-$(id -u).lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    exit 0
fi

command_is_available() {
    local command_name="$1"

    if [[ "$command_name" == */* ]]; then
        [[ -x "$command_name" ]]
    else
        command -v "$command_name" >/dev/null 2>&1
    fi
}

notify_user() {
    local title="$1"
    local body="$2"

    if command_is_available "$NOTIFY_SEND"; then
        "$NOTIFY_SEND" -a Wi-Fi -u normal "$title" "$body" \
            >/dev/null 2>&1 || true
    fi
}

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

    "$NMCLI" -t -e no -f connection.type connection show id "$ssid" 2>/dev/null \
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
declare -A PROFILE_NAMES=()

add_entry() {
    MENU_LABELS+=("$1")
    MENU_KINDS+=("$2")
    MENU_VALUES+=("${3:-}")
}

# Exibe um menu dmenu e usa Walker somente quando dmenu nao esta disponivel.
# A funcao retorna o indice selecionado; fechar a janela retorna uma linha vazia.
menu_choice() {
    local prompt="$1"
    shift
    local labels=("$@")
    local selected="" choice="" lines
    local index

    lines=$(( ${#labels[@]} < 12 ? ${#labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    if [[ -x "$DMENU" ]]; then
        selected="$(
            printf '%s\n' "${labels[@]}" \
                | "$DMENU" -i -l "$lines" -p "$prompt" \
                    -fn 'JetBrainsMono Nerd Font:size=12' \
                    -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000'
        )" || true
        for index in "${!labels[@]}"; do
            if [[ "${labels[$index]}" == "$selected" ]]; then
                choice="$index"
                break
            fi
        done
    elif [[ -x "$WALKER" ]]; then
        choice="$(printf '%s\n' "${labels[@]}" \
            | "$WALKER" --dmenu --index --exit --theme vantablack \
                --width 644 --height 570 --placeholder "$prompt")" || true
    fi
    printf '%s\n' "$choice"
}

# Perfis 802-11-wireless salvos no NetworkManager. O UUID e o identificador
# usado nas acoes porque o nome do perfil pode conter ':'.
load_saved_profiles() {
    local row name uuid
    local -a rows=()

    mapfile -t rows < <(
        "$NMCLI" -t -e no -f NAME,UUID,TYPE connection show 2>/dev/null || true
    )
    for row in "${rows[@]}"; do
        [[ -n "$row" ]] || continue
        [[ "$row" == *:802-11-wireless ]] || continue
        uuid="${row%:802-11-wireless}"
        name="${uuid%:*}"
        uuid="${uuid##*:}"
        [[ -n "$name" && -n "$uuid" ]] || continue
        printf '%s\t%s\n' "$name" "$uuid"
    done
}

connection_uuid_is_active() {
    local uuid="$1"
    local row active_uuid

    while IFS= read -r row; do
        [[ -n "$row" ]] || continue
        active_uuid="${row##*:}"
        [[ "$active_uuid" == "$uuid" ]] && return 0
    done < <("$NMCLI" -t -e no -f NAME,UUID connection show --active 2>/dev/null || true)
    return 1
}

connection_uuid_exists() {
    local uuid="$1"

    "$NMCLI" -t -e no -f UUID connection show 2>/dev/null | grep -Fxq -- "$uuid"
}

connect_profile() {
    local uuid="$1"
    local name="$2"

    if "$NMCLI" connection up uuid "$uuid" >/dev/null 2>&1; then
        notify_user 'Wi-Fi conectado' "Conectado a $name."
        return 0
    fi
    # Sem segredos armazenados, a senha e pedida pelo proprio dmenu.
    connect_new_network "$name" || return 1
    return 0
}

# Pede a senha da rede pelo dmenu, que permite digitar texto livre. Com
# Walker (fallback) a entrada de texto nao e possivel e o fluxo e cancelado.
password_prompt() {
    local ssid="$1"
    local selected=""

    if [[ -x "$DMENU" ]]; then
        selected="$(
            printf '%s\n' 'Cancelar' \
                | "$DMENU" -i -l 1 -p "Senha do Wi-Fi para $ssid" \
                    -fn 'JetBrainsMono Nerd Font:size=12' \
                    -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000'
        )" || true
        if [[ -z "$selected" || "$selected" == 'Cancelar' ]]; then
            return 1
        fi
        printf '%s\n' "$selected"
        return 0
    fi

    menu_choice "Senha do Wi-Fi para $ssid" 'Cancelar' >/dev/null
    return 1
}

connect_new_network() {
    local ssid="$1"
    local password
    local was_saved=0

    if connection_is_saved "$ssid"; then
        was_saved=1
    fi

    notify_user 'Wi-Fi' "Digite a senha de $ssid no campo que abriu."
    if ! password="$(password_prompt "$ssid")"; then
        notify_user 'Wi-Fi' 'Conexão cancelada.'
        return 1
    fi

    if "$NMCLI" device wifi connect "$ssid" password "$password" >/dev/null 2>&1; then
        notify_user 'Wi-Fi conectado' "Conectado a $ssid."
        return 0
    fi

    # Uma senha errada pode criar um perfil que nunca conecta. Remove-o
    # quando a rede nao era salva antes da tentativa.
    if ((was_saved == 0)) && connection_is_saved "$ssid"; then
        "$NMCLI" connection delete id "$ssid" >/dev/null 2>&1 || true
    fi
    notify_user 'Falha ao conectar' \
        "Não foi possível conectar a $ssid. Verifique a senha."
    return 1
}

confirm_forget() {
    local name="$1"
    local choice

    choice="$(menu_choice "Wi-Fi > $name > Esquecer?" \
        '󱛂  Confirmar esquecimento' 'Voltar')"
    case "$choice" in
        0) return 0 ;;
        1) return 2 ;;
        *) return 1 ;;
    esac
}

forget_network() {
    local uuid="$1"
    local name="$2"
    local confirmation_status

    if confirm_forget "$name"; then
        confirmation_status=0
    else
        confirmation_status=$?
    fi
    case "$confirmation_status" in
        0) ;;
        2) return 2 ;;
        *) return 1 ;;
    esac

    # Desativa a conexao antes de remover o perfil, espelhando o fluxo do
    # Bluetooth que desconecta antes de esquecer.
    if connection_uuid_is_active "$uuid"; then
        "$NMCLI" connection down uuid "$uuid" >/dev/null 2>&1 || true
    fi
    "$NMCLI" connection delete uuid "$uuid" >/dev/null 2>&1 || true
    if connection_uuid_exists "$uuid"; then
        notify_user 'Falha ao esquecer rede' \
            "$name continua salva. Consulte o gerenciador de conexões."
        return 1
    fi

    notify_user 'Rede esquecida' "$name foi removida das redes salvas."
    return 0
}

manage_network() {
    local uuid="$1"
    local name="$2"
    local choice action_label forget_status

    while :; do
        if connection_uuid_is_active "$uuid"; then
            action_label='Desconectar'
        else
            action_label='Conectar'
        fi

        choice="$(menu_choice "Wi-Fi > $name" \
            "󱛅  $action_label" '󱛂  Esquecer rede' 'Voltar')"
        case "$choice" in
            0)
                if [[ "$action_label" == 'Desconectar' ]]; then
                    if "$NMCLI" connection down uuid "$uuid" >/dev/null 2>&1; then
                        notify_user 'Wi-Fi desconectado' "$name foi desconectado."
                    else
                        notify_user 'Falha ao desconectar' \
                            "Não foi possível desconectar de $name."
                    fi
                else
                    connect_profile "$uuid" "$name" || true
                fi
                return 0
                ;;
            1)
                forget_status=0
                forget_network "$uuid" "$name" || forget_status=$?
                if ((forget_status == 2)); then
                    continue
                fi
                return 0
                ;;
            *)
                return 2
                ;;
        esac
    done
}

# Descoberta de redes proximas para "Conectar nova rede Wi-Fi". Com dmenu o
# submenu e atualizado em tempo real: a cada iteracao as redes sao consultadas
# de novo e a janela e recriada quando a lista muda. Sem dmenu (fallback
# Walker) a lista e estatica, com um rescan e uma espera curta.
DISCOVERY_MENU_PID=""
DISCOVERY_MENU_RESULT=""
DISCOVERY_MENU_DIR=""
DISCOVERY_SNAPSHOT=""
DISCOVERY_LAST_RESCAN=0
DISCOVERY_LABELS=()
DISCOVERY_SSIDS=()
declare -A DISCOVERY_SAVED=()

discovery_process_is_alive() {
    local process_pid="$1"
    local process_state

    [[ "$process_pid" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$process_pid" 2>/dev/null || return 1
    process_state="$(ps -o stat= -p "$process_pid" 2>/dev/null || true)"
    [[ "$process_state" != Z* ]]
}

close_discovery_menu() {
    local menu_pid="$DISCOVERY_MENU_PID"

    if discovery_process_is_alive "$menu_pid"; then
        kill "$menu_pid" 2>/dev/null || true
    fi
    if [[ "$menu_pid" =~ ^[0-9]+$ ]]; then
        wait "$menu_pid" 2>/dev/null || true
    fi
    DISCOVERY_MENU_PID=""
}

cleanup_discovery() {
    close_discovery_menu
    if [[ -n "$DISCOVERY_MENU_DIR" ]]; then
        rm -rf -- "$DISCOVERY_MENU_DIR" 2>/dev/null || true
    fi
    DISCOVERY_MENU_DIR=""
    DISCOVERY_MENU_RESULT=""
    DISCOVERY_SNAPSHOT=""
}

build_discovery_entries() {
    local output="$1"
    local row active rest security middle signal ssid
    local -A seen_ssids=()

    DISCOVERY_LABELS=()
    DISCOVERY_SSIDS=()

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
        [[ -n "${DISCOVERY_SAVED[$ssid]+present}" ]] && continue
        [[ -n "${seen_ssids[$ssid]+present}" ]] && continue
        seen_ssids["$ssid"]=1
        [[ "$signal" =~ ^[0-9]+$ ]] || signal=0
        if [[ -z "$security" || "$security" == "--" ]]; then
            security="aberta"
        fi
        DISCOVERY_SSIDS+=("$ssid")
        DISCOVERY_LABELS+=("$(signal_icon "$signal")  $ssid · ${signal}% · $security")
    done <<<"$output"

    if ((${#DISCOVERY_LABELS[@]} == 0)); then
        DISCOVERY_SNAPSHOT='__empty__'
    else
        DISCOVERY_SNAPSHOT="$(printf '%s\n' "${DISCOVERY_LABELS[@]}")"
    fi
}

refresh_discovery_entries() {
    local output=""

    # A cada 5s solicita um rescan assincrono para o NetworkManager; a listagem
    # usa o cache (--rescan no) para nao bloquear o submenu.
    if ((DISCOVERY_LAST_RESCAN == 0 || SECONDS - DISCOVERY_LAST_RESCAN >= 5)); then
        "$NMCLI" device wifi rescan >/dev/null 2>&1 || true
        DISCOVERY_LAST_RESCAN=$SECONDS
    fi
    output="$("$NMCLI" -t -e no -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null || true)"
    build_discovery_entries "$output"
}

launch_discovery_menu() {
    local input_file="$DISCOVERY_MENU_DIR/menu.in"
    local result_file="$DISCOVERY_MENU_DIR/menu.out"
    local lines
    local -a menu_labels=()

    if ((${#DISCOVERY_LABELS[@]} == 0)); then
        menu_labels=('Procurando redes...')
    else
        menu_labels=("${DISCOVERY_LABELS[@]}")
    fi
    lines=$(( ${#menu_labels[@]} < 12 ? ${#menu_labels[@]} : 12 ))
    ((lines < 1)) && lines=1
    printf '%s\n' "${menu_labels[@]}" >"$input_file"
    : >"$result_file"
    (
        exec "$DMENU" -i -l "$lines" -p 'Wi-Fi > Conectar nova rede' \
            -fn 'JetBrainsMono Nerd Font:size=12' \
            -nb '#000000' -nf '#ffffff' -sb '#ffffff' -sf '#000000' \
            <"$input_file" >"$result_file" 2>/dev/null
    ) &
    DISCOVERY_MENU_PID=$!
    DISCOVERY_MENU_RESULT="$result_file"
}

selected_discovery_ssid() {
    local selected="$1"
    local index

    for index in "${!DISCOVERY_LABELS[@]}"; do
        if [[ "${DISCOVERY_LABELS[$index]}" == "$selected" ]]; then
            printf '%s\n' "${DISCOVERY_SSIDS[$index]}"
            return 0
        fi
    done
    return 1
}

discover_networks_realtime() {
    local selected ssid current_snapshot previous_snapshot
    local discovery_dir

    DISCOVERY_SAVED=()
    while IFS=$'\t' read -r name uuid; do
        [[ -n "$name" ]] || continue
        DISCOVERY_SAVED["$name"]=1
    done < <(load_saved_profiles)

    discovery_dir="$(mktemp -d "${XDG_RUNTIME_DIR:-/tmp}/wifi-scan.XXXXXX")"
    DISCOVERY_MENU_DIR="$discovery_dir"
    refresh_discovery_entries
    if ! launch_discovery_menu; then
        cleanup_discovery
        return 1
    fi

    while :; do
        if ! discovery_process_is_alive "$DISCOVERY_MENU_PID"; then
            wait "$DISCOVERY_MENU_PID" 2>/dev/null || true
            selected="$(<"$DISCOVERY_MENU_RESULT")"
            if [[ -z "$selected" || "$selected" == 'Procurando redes...' ]]; then
                cleanup_discovery
                return 1
            fi
            refresh_discovery_entries
            if ssid="$(selected_discovery_ssid "$selected")"; then
                cleanup_discovery
                connect_new_network "$ssid"
                return 0
            fi
            # A rede pode ter desaparecido entre a selecao e a consulta.
            launch_discovery_menu
            continue
        fi

        previous_snapshot="$DISCOVERY_SNAPSHOT"
        refresh_discovery_entries
        current_snapshot="$DISCOVERY_SNAPSHOT"
        if [[ "$previous_snapshot" != "$current_snapshot" ]]; then
            close_discovery_menu
            selected="$(<"$DISCOVERY_MENU_RESULT")"
            if [[ -n "$selected" ]] \
                && ssid="$(selected_discovery_ssid "$selected")"; then
                cleanup_discovery
                connect_new_network "$ssid"
                return 0
            fi
            launch_discovery_menu
        fi
        sleep 1
    done
}

discover_networks_blocking() {
    local choice

    DISCOVERY_SAVED=()
    while IFS=$'\t' read -r name uuid; do
        [[ -n "$name" ]] || continue
        DISCOVERY_SAVED["$name"]=1
    done < <(load_saved_profiles)

    "$NMCLI" device wifi rescan >/dev/null 2>&1 || true
    sleep 3
    build_discovery_entries "$("$NMCLI" -t -e no -f IN-USE,SSID,SIGNAL,SECURITY device wifi list --rescan no 2>/dev/null || true)"
    if ((${#DISCOVERY_LABELS[@]} == 0)); then
        notify_user 'Wi-Fi' 'Nenhuma rede próxima foi encontrada.'
        return 1
    fi
    choice="$(menu_choice 'Wi-Fi > Conectar nova rede' "${DISCOVERY_LABELS[@]}")"
    if [[ ! "$choice" =~ ^[0-9]+$ ]] \
        || ((choice >= ${#DISCOVERY_SSIDS[@]})); then
        return 1
    fi
    connect_new_network "${DISCOVERY_SSIDS[$choice]}"
    return 0
}

discover_networks() {
    if [[ -x "$DMENU" ]]; then
        discover_networks_realtime
    else
        discover_networks_blocking
    fi
}

# Garante que uma descoberta interrompida nao deixe o dmenu aberto nem
# diretorios temporarios para tras.
trap cleanup_discovery EXIT

main_menu() {
# refresh=0 reutiliza as entradas ja carregadas ao voltar de um submenu.
local refresh="${1:-1}"
local radio_state choice kind value name uuid current_ssid
local manage_status

if [[ "$refresh" == 1 ]]; then
    MENU_LABELS=()
    MENU_KINDS=()
    MENU_VALUES=()
    PROFILE_NAMES=()

    radio_state="$(wifi_radio_state)"
    if [[ -z "$WIFI_DEVICE" ]]; then
        add_entry '󰖪  Sem dispositivo Wi-Fi' noop
    elif [[ "$radio_state" != enabled ]]; then
        # Desligado: a unica opcao visivel e ligar o radio.
        add_entry "󰖩  Ativar Wi-Fi" radio-on
    else
        add_entry "󰖪  Desativar Wi-Fi" radio-off
        add_entry "󱛃  Conectar nova rede Wi-Fi" discover

        current_ssid="$(current_connection "$WIFI_DEVICE")"
        if [[ -n "$current_ssid" && "$current_ssid" != "--" ]]; then
            add_entry "󰖪  Desconectar de $current_ssid" disconnect "$current_ssid"
        fi

        # Redes salvas (ja conhecidas) ganham um submenu de gerenciamento.
        # Redes novas nao aparecem aqui: elas ficam na descoberta em tempo
        # real de "Conectar nova rede Wi-Fi".
        while IFS=$'\t' read -r name uuid; do
            [[ -n "$name" && -n "$uuid" ]] || continue
            PROFILE_NAMES["$uuid"]="$name"
            add_entry "󱚾  Gerenciar: $name" manage "$uuid"
        done < <(load_saved_profiles)
    fi
fi

choice="$(menu_choice 'Wi-Fi' "${MENU_LABELS[@]}")"
[[ "$choice" =~ ^[0-9]+$ ]] || return 0
((choice < ${#MENU_KINDS[@]})) || return 0

kind="${MENU_KINDS[$choice]}"
value="${MENU_VALUES[$choice]}"

    case "$kind" in
    radio-off)
        exec 9>&-
        if "$NMCLI" radio wifi off >/dev/null 2>&1; then
            notify_user 'Wi-Fi desativado' 'O rádio Wi-Fi foi desligado.'
        else
            notify_user 'Falha ao desativar Wi-Fi' \
                'Não foi possível desligar o rádio Wi-Fi.'
        fi
        ;;
    radio-on)
        exec 9>&-
        if "$NMCLI" radio wifi on >/dev/null 2>&1; then
            notify_user 'Wi-Fi ativado' 'O rádio Wi-Fi foi ligado.'
        else
            notify_user 'Falha ao ativar Wi-Fi' \
                'Não foi possível ligar o rádio Wi-Fi.'
        fi
        ;;
    disconnect)
        exec 9>&-
        if [[ -n "$WIFI_DEVICE" ]] && "$NMCLI" device disconnect "$WIFI_DEVICE" >/dev/null 2>&1; then
            notify_user 'Wi-Fi desconectado' \
                "A conexão com ${value:-a rede atual} foi encerrada."
        else
            notify_user 'Falha ao desconectar' \
                'Não foi possível desconectar do Wi-Fi.'
        fi
        ;;
    discover)
        discover_networks || true
        ;;
    manage)
        manage_status=0
        manage_network "$value" "${PROFILE_NAMES[$value]-$value}" || manage_status=$?
        ((manage_status == 2)) && return 2
        ;;
    noop)
        ;;
esac
}

WIFI_DEVICE="$(wifi_device)"

if main_menu; then
    main_status=0
else
    main_status=$?
fi
while ((main_status == 2)); do
    if main_menu 0; then
        main_status=0
    else
        main_status=$?
    fi
done

pkill -USR1 -x i3status 2>/dev/null || true
